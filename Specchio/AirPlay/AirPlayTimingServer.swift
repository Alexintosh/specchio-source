import Darwin
import Foundation
import Network

private let airPlayTimingLog = SpecchioLogger.airPlay

final class AirPlayTimingServer {
    enum Event {
        case ready(port: UInt16)
        case failed(String)
        case clientState(String)
        case packet(requestBytes: Int, responseBytes: Int)
        case probeSent(remote: String, bytes: Int, count: Int)
        case probeResponse(remote: String, bytes: Int, count: Int)
        case stopped
    }

    private struct RemoteAddress {
        let description: String
        let family: Int32
        let addressData: Data
    }

    private let queue: DispatchQueue
    private let onEvent: (Event) -> Void
    private var socketFD: Int32 = -1
    private var readSource: DispatchSourceRead?
    private var probeTimer: DispatchSourceTimer?
    private var remoteAddress: RemoteAddress?
    private var probeCount = 0
    private var responseCount = 0
    private var lastClientReferenceTimestamp: UInt64?
    private var lastResponseReceivedAt: Date?

    init(queue: DispatchQueue, onEvent: @escaping (Event) -> Void) {
        self.queue = queue
        self.onEvent = onEvent
    }

    func start(remoteHost: NWEndpoint.Host? = nil, remotePort: UInt16? = nil) {
        guard socketFD == -1 else {
            airPlayTimingLog.info("[AirPlayTiming] start skipped reason=socket-already-active")
            return
        }

        do {
            let remoteAddress = try Self.resolveRemoteAddress(host: remoteHost, port: remotePort)
            let family = remoteAddress?.family ?? Int32(AF_INET)
            let descriptor = Darwin.socket(family, SOCK_DGRAM, IPPROTO_UDP)
            guard descriptor >= 0 else {
                throw Self.posixError("socket")
            }

            do {
                try Self.makeNonBlocking(descriptor)
                let localPort = try Self.bindSocket(descriptor, family: family)
                self.socketFD = descriptor
                self.remoteAddress = remoteAddress
                startReadSource(fileDescriptor: descriptor)
                airPlayTimingLog.info("[AirPlayTiming] socket ready localPort=\(localPort) activeProbe=\(remoteAddress != nil) remote=\(remoteAddress?.description ?? "nil", privacy: .public)")
                onEvent(.ready(port: localPort))

                if let remoteAddress {
                    startProbeTimer(remoteAddress: remoteAddress)
                } else {
                    airPlayTimingLog.warning("[AirPlayTiming] active probe disabled reason=remote-host-or-port-missing")
                    onEvent(.clientState("active probe disabled: missing remote timing endpoint"))
                }
            } catch {
                Darwin.close(descriptor)
                throw error
            }
        } catch {
            airPlayTimingLog.error("[AirPlayTiming] socket start failed error=\(error.localizedDescription, privacy: .public)")
            onEvent(.failed(error.localizedDescription))
        }
    }

    func stop(reason: String) {
        airPlayTimingLog.info("[AirPlayTiming] stop requested reason=\(reason, privacy: .public) probeCount=\(self.probeCount) responseCount=\(self.responseCount)")
        probeTimer?.cancel()
        probeTimer = nil
        remoteAddress = nil
        lastClientReferenceTimestamp = nil
        lastResponseReceivedAt = nil

        if let readSource {
            readSource.cancel()
            self.readSource = nil
        } else if socketFD >= 0 {
            Darwin.close(socketFD)
        }
        socketFD = -1
        onEvent(.stopped)
    }

    static func response(for request: Data, now: Date = Date()) -> Data? {
        guard request.count >= ntpPacketByteCount else {
            airPlayTimingLog.warning("[AirPlayTiming] ntp response branch=MALFORMED_REQUEST requestBytes=\(request.count)")
            return nil
        }

        let versionBits = (request[0] & 0x38) == 0 ? UInt8(0x20) : (request[0] & 0x38)
        let timestamp = ntpTimestamp(for: now)
        var response = Data(repeating: 0, count: ntpPacketByteCount)
        response[0] = versionBits | ntpServerMode
        response[1] = 2
        response[2] = request[2]
        response[3] = UInt8(bitPattern: Int8(-20))
        response.replaceSubrange(12..<16, with: Data("SPCH".utf8))
        writeUInt64BE(timestamp, into: &response, at: 16)
        response.replaceSubrange(24..<32, with: request[40..<48])
        writeUInt64BE(timestamp, into: &response, at: 32)
        writeUInt64BE(timestamp, into: &response, at: 40)
        airPlayTimingLog.info("[AirPlayTiming] ntp response branch=OK requestBytes=\(request.count) responseBytes=\(response.count)")
        return response
    }

    static func probeRequest(
        sentAt: Date,
        previousClientReferenceTimestamp: UInt64? = nil,
        previousResponseReceivedAt: Date? = nil
    ) -> Data {
        var request = Data(repeating: 0, count: activeProbePacketByteCount)
        request[0] = 0x80
        request[1] = 0xd2
        request[3] = 0x07
        if let previousClientReferenceTimestamp {
            writeUInt64BE(previousClientReferenceTimestamp, into: &request, at: 8)
        }
        if let previousResponseReceivedAt {
            writeUInt64BE(ntpTimestamp(for: previousResponseReceivedAt), into: &request, at: 16)
        }
        writeUInt64BE(ntpTimestamp(for: sentAt), into: &request, at: 24)
        return request
    }

    static func ntpTimestamp(for date: Date) -> UInt64 {
        let unixSeconds = date.timeIntervalSince1970
        let wholeSeconds = UInt64(max(0, floor(unixSeconds))) + ntpUnixEpochOffsetSeconds
        let fractionalSeconds = unixSeconds - floor(unixSeconds)
        let fraction = UInt64(max(0, min(fractionalSeconds, 0.999_999_999)) * Double(UInt32.max) + 0.5)
        return (wholeSeconds << 32) | fraction
    }

    private func startReadSource(fileDescriptor: Int32) {
        let source = DispatchSource.makeReadSource(fileDescriptor: fileDescriptor, queue: queue)
        source.setEventHandler { [weak self] in
            self?.readAvailablePackets()
        }
        source.setCancelHandler {
            Darwin.close(fileDescriptor)
            airPlayTimingLog.info("[AirPlayTiming] socket closed")
        }
        readSource = source
        source.resume()
        airPlayTimingLog.info("[AirPlayTiming] read source started")
    }

    private func startProbeTimer(remoteAddress: RemoteAddress) {
        airPlayTimingLog.info("[AirPlayTiming] active probe start remote=\(remoteAddress.description, privacy: .public) intervalSeconds=3")
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: .seconds(3), leeway: .milliseconds(250))
        timer.setEventHandler { [weak self] in
            self?.sendProbe(to: remoteAddress)
        }
        probeTimer = timer
        timer.resume()
    }

    private func sendProbe(to remoteAddress: RemoteAddress) {
        guard socketFD >= 0 else {
            airPlayTimingLog.warning("[AirPlayTiming] probe skipped reason=socket-closed remote=\(remoteAddress.description, privacy: .public)")
            return
        }

        let request = Self.probeRequest(
            sentAt: Date(),
            previousClientReferenceTimestamp: lastClientReferenceTimestamp,
            previousResponseReceivedAt: lastResponseReceivedAt
        )
        let sentBytes = request.withUnsafeBytes { requestBytes in
            remoteAddress.addressData.withUnsafeBytes { addressBytes in
                Darwin.sendto(
                    socketFD,
                    requestBytes.baseAddress,
                    request.count,
                    0,
                    addressBytes.baseAddress?.assumingMemoryBound(to: sockaddr.self),
                    socklen_t(remoteAddress.addressData.count)
                )
            }
        }

        if sentBytes == request.count {
            probeCount += 1
            airPlayTimingLog.info("[AirPlayTiming] probe sent count=\(self.probeCount) bytes=\(request.count) remote=\(remoteAddress.description, privacy: .public) previousClientRef=\(self.lastClientReferenceTimestamp != nil) previousReceive=\(self.lastResponseReceivedAt != nil)")
            onEvent(.probeSent(remote: remoteAddress.description, bytes: request.count, count: probeCount))
        } else if sentBytes >= 0 {
            airPlayTimingLog.warning("[AirPlayTiming] probe partial count=\(self.probeCount + 1) sentBytes=\(sentBytes) expectedBytes=\(request.count) remote=\(remoteAddress.description, privacy: .public)")
            onEvent(.clientState("probe partial send: \(sentBytes)/\(request.count)"))
        } else {
            let error = Self.posixError("sendto")
            airPlayTimingLog.error("[AirPlayTiming] probe send failed remote=\(remoteAddress.description, privacy: .public) error=\(error.localizedDescription, privacy: .public)")
            onEvent(.clientState("probe send failed: \(error.localizedDescription)"))
        }
    }

    private func readAvailablePackets() {
        while socketFD >= 0 {
            var buffer = [UInt8](repeating: 0, count: 128)
            let bufferCapacity = buffer.count
            var sender = sockaddr_storage()
            var senderLength = socklen_t(MemoryLayout<sockaddr_storage>.size)
            let receivedBytes = withUnsafeMutablePointer(to: &sender) { senderPointer in
                senderPointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
                    buffer.withUnsafeMutableBytes { bufferBytes in
                        Darwin.recvfrom(
                            socketFD,
                            bufferBytes.baseAddress,
                            bufferCapacity,
                            0,
                            sockaddrPointer,
                            &senderLength
                        )
                    }
                }
            }

            if receivedBytes > 0 {
                let packet = Data(buffer.prefix(receivedBytes))
                handleIncomingPacket(packet, sender: sender, senderLength: senderLength)
            } else if receivedBytes == 0 {
                airPlayTimingLog.info("[AirPlayTiming] recvfrom returned zero bytes")
                return
            } else if errno == EWOULDBLOCK || errno == EAGAIN {
                return
            } else {
                let error = Self.posixError("recvfrom")
                airPlayTimingLog.error("[AirPlayTiming] receive failed error=\(error.localizedDescription, privacy: .public)")
                onEvent(.clientState("receive failed: \(error.localizedDescription)"))
                return
            }
        }
    }

    private func handleIncomingPacket(_ packet: Data, sender: sockaddr_storage, senderLength: socklen_t) {
        let senderDescription = Self.addressDescription(sender, length: senderLength)
        if Self.isPassiveTimingRequest(packet), let response = Self.response(for: packet) {
            sendPassiveResponse(response, to: sender, senderLength: senderLength, senderDescription: senderDescription, requestBytes: packet.count)
            return
        }

        responseCount += 1
        if packet.count >= Self.activeProbePacketByteCount {
            lastClientReferenceTimestamp = Self.readUInt64BE(packet, at: 24)
            lastResponseReceivedAt = Date()
            airPlayTimingLog.info("[AirPlayTiming] probe response count=\(self.responseCount) bytes=\(packet.count) remote=\(senderDescription, privacy: .public) clientReference=present")
        } else {
            airPlayTimingLog.warning("[AirPlayTiming] short probe response count=\(self.responseCount) bytes=\(packet.count) remote=\(senderDescription, privacy: .public)")
        }
        onEvent(.probeResponse(remote: senderDescription, bytes: packet.count, count: responseCount))
    }

    private func sendPassiveResponse(
        _ response: Data,
        to sender: sockaddr_storage,
        senderLength: socklen_t,
        senderDescription: String,
        requestBytes: Int
    ) {
        guard socketFD >= 0 else {
            airPlayTimingLog.warning("[AirPlayTiming] passive response skipped reason=socket-closed remote=\(senderDescription, privacy: .public)")
            return
        }

        var sender = sender
        let sentBytes = response.withUnsafeBytes { responseBytes in
            withUnsafePointer(to: &sender) { senderPointer in
                senderPointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
                    Darwin.sendto(
                        socketFD,
                        responseBytes.baseAddress,
                        response.count,
                        0,
                        sockaddrPointer,
                        senderLength
                    )
                }
            }
        }

        if sentBytes == response.count {
            airPlayTimingLog.info("[AirPlayTiming] passive response sent requestBytes=\(requestBytes) responseBytes=\(response.count) remote=\(senderDescription, privacy: .public)")
            onEvent(.packet(requestBytes: requestBytes, responseBytes: response.count))
        } else if sentBytes >= 0 {
            airPlayTimingLog.warning("[AirPlayTiming] passive response partial sentBytes=\(sentBytes) expectedBytes=\(response.count) remote=\(senderDescription, privacy: .public)")
            onEvent(.clientState("passive response partial send: \(sentBytes)/\(response.count)"))
        } else {
            let error = Self.posixError("sendto passive response")
            airPlayTimingLog.error("[AirPlayTiming] passive response failed remote=\(senderDescription, privacy: .public) error=\(error.localizedDescription, privacy: .public)")
            onEvent(.clientState("passive response failed: \(error.localizedDescription)"))
        }
    }

    private static func resolveRemoteAddress(host: NWEndpoint.Host?, port: UInt16?) throws -> RemoteAddress? {
        guard let host, let port else {
            airPlayTimingLog.warning("[AirPlayTiming] remote resolve branch=MISSING hostPresent=\(host != nil) portPresent=\(port != nil)")
            return nil
        }

        let hostName = hostString(host)
        var hints = addrinfo(
            ai_flags: AI_NUMERICSERV,
            ai_family: AF_UNSPEC,
            ai_socktype: SOCK_DGRAM,
            ai_protocol: IPPROTO_UDP,
            ai_addrlen: 0,
            ai_canonname: nil,
            ai_addr: nil,
            ai_next: nil
        )
        var result: UnsafeMutablePointer<addrinfo>?
        let status = getaddrinfo(hostName, String(port), &hints, &result)
        guard status == 0, let result else {
            let message = String(cString: gai_strerror(status))
            airPlayTimingLog.error("[AirPlayTiming] remote resolve branch=FAILED host=\(hostName, privacy: .public) port=\(port) error=\(message, privacy: .public)")
            throw NSError(domain: "Specchio.AirPlayTiming", code: Int(status), userInfo: [NSLocalizedDescriptionKey: "Could not resolve AirPlay timing endpoint \(hostName):\(port): \(message)"])
        }
        defer { freeaddrinfo(result) }

        var cursor: UnsafeMutablePointer<addrinfo>? = result
        while let current = cursor {
            let info = current.pointee
            if (info.ai_family == AF_INET || info.ai_family == AF_INET6), let address = info.ai_addr {
                let data = Data(bytes: address, count: Int(info.ai_addrlen))
                let description = "\(hostName):\(port)"
                airPlayTimingLog.info("[AirPlayTiming] remote resolve branch=OK host=\(hostName, privacy: .public) port=\(port) family=\(info.ai_family)")
                return RemoteAddress(description: description, family: Int32(info.ai_family), addressData: data)
            }
            cursor = info.ai_next
        }

        airPlayTimingLog.error("[AirPlayTiming] remote resolve branch=NO_SUPPORTED_ADDRESS host=\(hostName, privacy: .public) port=\(port)")
        throw NSError(domain: "Specchio.AirPlayTiming", code: Int(EAFNOSUPPORT), userInfo: [NSLocalizedDescriptionKey: "AirPlay timing endpoint \(hostName):\(port) did not resolve to IPv4 or IPv6"])
    }

    private static func hostString(_ host: NWEndpoint.Host) -> String {
        switch host {
        case .name(let name, _):
            return name
        case .ipv4(let address):
            return "\(address)"
        case .ipv6(let address):
            return "\(address)"
        @unknown default:
            return "\(host)"
        }
    }

    private static func makeNonBlocking(_ descriptor: Int32) throws {
        let flags = fcntl(descriptor, F_GETFL, 0)
        guard flags >= 0 else {
            throw posixError("fcntl(F_GETFL)")
        }
        guard fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) >= 0 else {
            throw posixError("fcntl(F_SETFL)")
        }
    }

    private static func bindSocket(_ descriptor: Int32, family: Int32) throws -> UInt16 {
        switch family {
        case Int32(AF_INET6):
            var address = sockaddr_in6()
            address.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size)
            address.sin6_family = sa_family_t(AF_INET6)
            address.sin6_port = in_port_t(0).bigEndian
            address.sin6_addr = in6addr_any
            let status = withUnsafePointer(to: &address) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in6>.size))
                }
            }
            guard status == 0 else {
                throw posixError("bind IPv6")
            }
        default:
            var address = sockaddr_in()
            address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            address.sin_family = sa_family_t(AF_INET)
            address.sin_port = in_port_t(0).bigEndian
            address.sin_addr = in_addr(s_addr: INADDR_ANY)
            let status = withUnsafePointer(to: &address) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
            guard status == 0 else {
                throw posixError("bind IPv4")
            }
        }

        return try localPort(for: descriptor)
    }

    private static func localPort(for descriptor: Int32) throws -> UInt16 {
        var storage = sockaddr_storage()
        var length = socklen_t(MemoryLayout<sockaddr_storage>.size)
        let status = withUnsafeMutablePointer(to: &storage) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.getsockname(descriptor, $0, &length)
            }
        }
        guard status == 0 else {
            throw posixError("getsockname")
        }

        switch Int32(storage.ss_family) {
        case Int32(AF_INET):
            return withUnsafePointer(to: storage) { pointer in
                pointer.withMemoryRebound(to: sockaddr_in.self, capacity: 1) {
                    UInt16(bigEndian: $0.pointee.sin_port)
                }
            }
        case Int32(AF_INET6):
            return withUnsafePointer(to: storage) { pointer in
                pointer.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) {
                    UInt16(bigEndian: $0.pointee.sin6_port)
                }
            }
        default:
            throw NSError(domain: "Specchio.AirPlayTiming", code: Int(EAFNOSUPPORT), userInfo: [NSLocalizedDescriptionKey: "Unsupported local timing socket family \(storage.ss_family)"])
        }
    }

    private static func isPassiveTimingRequest(_ packet: Data) -> Bool {
        packet.count >= ntpPacketByteCount && (packet[0] & 0x07) == 0x03
    }

    private static func addressDescription(_ storage: sockaddr_storage, length: socklen_t) -> String {
        var storage = storage
        var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        var service = [CChar](repeating: 0, count: Int(NI_MAXSERV))
        let status = withUnsafePointer(to: &storage) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getnameinfo($0, length, &host, socklen_t(host.count), &service, socklen_t(service.count), NI_NUMERICHOST | NI_NUMERICSERV)
            }
        }
        guard status == 0 else {
            return "unknown"
        }
        return "\(String(cString: host)):\(String(cString: service))"
    }

    private static func readUInt64BE(_ data: Data, at offset: Int) -> UInt64 {
        var value: UInt64 = 0
        for index in offset..<(offset + 8) {
            value = (value << 8) | UInt64(data[index])
        }
        return value
    }

    private static func writeUInt64BE(_ value: UInt64, into data: inout Data, at offset: Int) {
        for index in 0..<8 {
            data[offset + index] = UInt8((value >> UInt64((7 - index) * 8)) & 0xFF)
        }
    }

    private static func posixError(_ operation: String) -> NSError {
        NSError(
            domain: NSPOSIXErrorDomain,
            code: Int(errno),
            userInfo: [NSLocalizedDescriptionKey: "\(operation) failed: \(String(cString: strerror(errno)))"]
        )
    }

    private static let ntpPacketByteCount = 48
    private static let activeProbePacketByteCount = 32
    private static let ntpServerMode: UInt8 = 0x04
    private static let ntpUnixEpochOffsetSeconds: UInt64 = 2_208_988_800
}
