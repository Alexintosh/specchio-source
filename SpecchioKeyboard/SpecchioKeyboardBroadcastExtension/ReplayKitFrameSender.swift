import Foundation
import Network
import os.log

enum ReplayKitTransport: String, Codable, Equatable {
    case usb
    case wifi
    case cellular
    case other
    case unknown

    static func detect(from path: NWPath) -> ReplayKitTransport {
        if path.usesInterfaceType(.wifi) {
            return .wifi
        }

        if path.usesInterfaceType(.wiredEthernet) {
            return .usb
        }

        if path.usesInterfaceType(.cellular) {
            return .cellular
        }

        if path.usesInterfaceType(.loopback) || path.usesInterfaceType(.other) {
            return .other
        }

        return .unknown
    }
}

struct ReplayKitEncodedFrame {
    let sequenceNumber: UInt64
    let timestampMilliseconds: UInt64
    let width: UInt16
    let height: UInt16
    let quality: UInt8
    let orientation: UInt8
    let captureWallClockMilliseconds: UInt64
    let encodeDurationMilliseconds: UInt32
    let encodedWallClockMilliseconds: UInt64
    let jpegData: Data
}

enum ReplayKitControlEventName: String {
    case broadcastStarted
    case firstFrame
    case videoStalled
    case broadcastPaused
    case broadcastResumed
    case broadcastFinished
    case senderReady
    case senderFailed
}

private struct ReplayKitControlEventPayload: Encodable {
    let event: String
    let sequence: Int
    let receivedVideoFrames: Int
    let sentVideoFrames: Int
    let reason: String?
    let timestamp: Double
    let transport: String
    let maxFramesPerSecond: Double?
    let videoOrientation: ReplayKitVideoOrientationSnapshot?
}

private struct ReplayKitHeartbeatPayload: Encodable {
    let event: String
    let sequence: Int
    let receivedVideoFrames: Int
    let sentVideoFrames: Int
    let senderState: String
    let isBroadcastPaused: Bool
    let isVideoStalled: Bool
    let lastVideoSampleAgeSeconds: Double?
    let timestamp: Double
    let transport: String
    let maxFramesPerSecond: Double?
    let videoOrientation: ReplayKitVideoOrientationSnapshot?
}

final class ReplayKitFrameSender {
    enum SenderState: CustomStringConvertible {
        case idle
        case connecting(String, UInt16)
        case ready(String, UInt16)
        case failed(String)
        case stopped

        var description: String {
            diagnosticDescription
        }

        var diagnosticDescription: String {
            switch self {
            case .idle:
                return "idle"
            case .connecting(let host, let port):
                return "connecting(\(host):\(port))"
            case .ready(let host, let port):
                return "ready(\(host):\(port))"
            case .failed(let reason):
                return "failed(\(reason))"
            case .stopped:
                return "stopped"
            }
        }
    }

    private struct PendingControlPacket {
        let event: ReplayKitControlEventName
        let sequence: Int
        let payload: Data
    }

    private struct PendingH264ConfigPacket {
        let sequence: Int
        let payload: Data
    }

    private struct PacketDescriptor {
        let type: ReplayKitPacketType
        let label: String
        let sequenceDescription: String
        let payloadLength: Int
        let packetLength: Int
    }

    private let log = OSLog(subsystem: "com.alexintosh.SpecchioKeyboard", category: "ReplayKitSender")
    private let queue = DispatchQueue(label: "com.alexintosh.SpecchioKeyboard.replaykit.sender", qos: .userInitiated)
    private let sharedDefaults = UserDefaults(suiteName: "group.com.alexintosh.SpecchioKeyboard")
    private let jsonEncoder = JSONEncoder()
    private let defaultReplayKitPort: UInt16 = 9500
    private let defaultReplayKitServiceType = "_specchio-replaykit._tcp"
    private let defaultReplayKitServiceName = "Specchio Easy"
    private let defaultReplayKitServiceDomain = "local."
    private let maximumPendingControlPackets = 16

    private var connection: NWConnection?
    private var browser: NWBrowser?
    private var state: SenderState = .idle
    private var endpointAttempts: [EndpointAttempt] = []
    private var endpointAttemptIndex = 0
    private var connectionGeneration = 0
    private var candidateTimeoutWorkItem: DispatchWorkItem?
    private var pendingControlPackets: [PendingControlPacket] = []
    private var latestH264ConfigPacket: PendingH264ConfigPacket?
    private var queuedFrames = 0
    private var completedFrames = 0
    private var droppedFrames = 0
    private var inFlightSends = 0
    private var latestReceivedVideoFrames = 0
    private var latestSentVideoFrames = 0
    private var nextInternalControlSequence = 1
    private var lastSummaryTimestamp = Date.distantPast
    private var currentTransport: ReplayKitTransport = .unknown
    private var currentMaxFramesPerSecond: Double?

    func start() {
        os_log("[ReplayKitSender] start requested envelopeMagic=%{public}@ version=%d", log: log, type: .info, "SPRK", Int(ReplayKitPacketEnvelope.version))
        updateSenderStatus("start requested")
        queue.async { [weak self] in
            self?.startLocked()
        }
    }

    func stop() {
        os_log("[ReplayKitSender] stop requested", log: log, type: .info)
        updateSenderStatus("stop requested")
        queue.async { [weak self] in
            self?.stopLocked(reason: "stop()")
        }
    }

    func send(_ frame: ReplayKitEncodedFrame) {
        queue.async { [weak self] in
            self?.sendFrameLocked(frame)
        }
    }

    func send(_ config: ReplayKitH264ConfigPayload) {
        queue.async { [weak self] in
            guard let self else { return }
            guard let payloadData = self.encodeJSONPayload(config, label: "h264.config", sequence: String(config.sequence)) else {
                return
            }
            self.latestH264ConfigPacket = PendingH264ConfigPacket(sequence: config.sequence, payload: payloadData)
            self.sendH264ConfigLocked(config, payload: payloadData, reason: "encoder output")
        }
    }

    func send(_ accessUnit: ReplayKitEncodedH264AccessUnit) {
        queue.async { [weak self] in
            self?.sendH264AccessUnitLocked(accessUnit)
        }
    }

    func sendControlEvent(
        _ event: ReplayKitControlEventName,
        sequence: Int,
        receivedVideoFrames: Int,
        sentVideoFrames: Int,
        reason: String? = nil,
        videoOrientation: ReplayKitVideoOrientationSnapshot? = nil
    ) {
        queue.async { [weak self] in
            guard let self else { return }
            self.latestReceivedVideoFrames = receivedVideoFrames
            self.latestSentVideoFrames = sentVideoFrames

            let payload = ReplayKitControlEventPayload(
                event: event.rawValue,
                sequence: sequence,
                receivedVideoFrames: receivedVideoFrames,
                sentVideoFrames: sentVideoFrames,
                reason: reason,
                timestamp: Date().timeIntervalSince1970,
                transport: self.currentTransport.rawValue,
                maxFramesPerSecond: self.currentMaxFramesPerSecond,
                videoOrientation: videoOrientation
            )

            guard let payloadData = self.encodeJSONPayload(payload, label: "control.\(event.rawValue)", sequence: String(sequence)) else {
                return
            }

            self.sendControlPacketLocked(
                event: event,
                sequence: sequence,
                payload: payloadData,
                allowQueueIfNotReady: true
            )
        }
    }

    func sendHeartbeat(
        sequence: Int,
        receivedVideoFrames: Int,
        sentVideoFrames: Int,
        isBroadcastPaused: Bool,
        isVideoStalled: Bool,
        lastVideoSampleAgeSeconds: Double?,
        videoOrientation: ReplayKitVideoOrientationSnapshot?
    ) {
        queue.async { [weak self] in
            guard let self else { return }
            self.latestReceivedVideoFrames = receivedVideoFrames
            self.latestSentVideoFrames = sentVideoFrames

            let payload = ReplayKitHeartbeatPayload(
                event: "heartbeat",
                sequence: sequence,
                receivedVideoFrames: receivedVideoFrames,
                sentVideoFrames: sentVideoFrames,
                senderState: self.state.diagnosticDescription,
                isBroadcastPaused: isBroadcastPaused,
                isVideoStalled: isVideoStalled,
                lastVideoSampleAgeSeconds: lastVideoSampleAgeSeconds,
                timestamp: Date().timeIntervalSince1970,
                transport: self.currentTransport.rawValue,
                maxFramesPerSecond: self.currentMaxFramesPerSecond,
                videoOrientation: videoOrientation
            )

            guard let payloadData = self.encodeJSONPayload(payload, label: "heartbeat", sequence: String(sequence)) else {
                return
            }

            let descriptor = PacketDescriptor(
                type: .heartbeat,
                label: "heartbeat",
                sequenceDescription: String(sequence),
                payloadLength: payloadData.count,
                packetLength: ReplayKitPacketEnvelope.headerByteCount + payloadData.count
            )

            guard case .ready = self.state else {
                self.logPacketDecision(descriptor, action: "drop", reason: "connection not ready state=\(self.state.diagnosticDescription)")
                return
            }

            guard let connection = self.connection else {
                self.state = .failed("Missing connection")
                self.logPacketDecision(descriptor, action: "drop", reason: "ready state without NWConnection")
                return
            }

            let packet = self.envelopedPacket(type: .heartbeat, payload: payloadData)
            self.transmitPacketLocked(
                connection: connection,
                packet: packet,
                descriptor: descriptor,
                captureWallClockMilliseconds: nil,
                updatesFrameCounters: false,
                senderFailedReason: "heartbeat send failed"
            )
        }
    }

    func currentTransportForPolicy() -> ReplayKitTransport {
        queue.sync {
            currentTransport
        }
    }

    func updateMaxFramesPerSecondForDiagnostics(_ framesPerSecond: Double?) {
        queue.async { [weak self] in
            self?.currentMaxFramesPerSecond = framesPerSecond
        }
    }

    private enum EndpointAttempt {
        case direct(host: String, port: UInt16)
        case service(name: String, type: String, domain: String)

        var description: String {
            switch self {
            case .direct(let host, let port):
                return "\(host):\(port)"
            case .service(let name, let type, let domain):
                return "\(name).\(type).\(domain)"
            }
        }

        var stateHost: String {
            switch self {
            case .direct(let host, _):
                return host
            case .service(let name, _, _):
                return name
            }
        }

        func statePort(defaultPort: UInt16) -> UInt16 {
            switch self {
            case .direct(_, let port):
                return port
            case .service:
                return defaultPort
            }
        }
    }

    private func startLocked() {
        let storedServiceName = sharedDefaults?.string(forKey: "macReplayKitServiceName")
        let storedServiceType = sharedDefaults?.string(forKey: "macReplayKitServiceType") ?? defaultReplayKitServiceType
        let storedServiceDomain = sharedDefaults?.string(forKey: "macReplayKitServiceDomain") ?? defaultReplayKitServiceDomain
        let storedHost = sharedDefaults?.string(forKey: "macHostIP")
        let storedPort = sharedDefaults?.integer(forKey: "macReplayKitPort") ?? 0
        let portValue: UInt16
        if storedPort > 0 && storedPort <= Int(UInt16.max) {
            portValue = UInt16(storedPort)
            os_log("[ReplayKitSender] start path: using App Group port %d", log: log, type: .info, storedPort)
        } else {
            portValue = defaultReplayKitPort
            if storedPort > 0 {
                os_log("[ReplayKitSender] start path: invalid App Group port %d; using default %d", log: log, type: .error, storedPort, Int(defaultReplayKitPort))
            } else {
                os_log("[ReplayKitSender] start path: no App Group port; using default %d", log: log, type: .info, Int(defaultReplayKitPort))
            }
        }

        if connection == nil {
            os_log("[ReplayKitSender] start path: no existing connection pendingControlPackets=%d", log: log, type: .info, pendingControlPackets.count)
        } else {
            os_log("[ReplayKitSender] start path: replacing existing connection pendingControlPackets=%d", log: log, type: .info, pendingControlPackets.count)
            connection?.cancel()
        }

        candidateTimeoutWorkItem?.cancel()
        candidateTimeoutWorkItem = nil
        browser?.cancel()
        browser = nil
        endpointAttempts.removeAll()
        endpointAttemptIndex = 0
        connectionGeneration += 1

        if let serviceName = storedServiceName, !serviceName.isEmpty {
            endpointAttempts.append(.service(name: serviceName, type: storedServiceType, domain: storedServiceDomain))
            updateSenderStatus("queued bonjour \(serviceName)")
            os_log("[ReplayKitSender] start path: queued Bonjour App Group endpoint %{public}@ type=%{public}@ domain=%{public}@", log: log, type: .info, serviceName, storedServiceType, storedServiceDomain)
        } else {
            os_log("[ReplayKitSender] start path: no Bonjour service in App Group", log: log, type: .info)
        }
        if storedServiceName != defaultReplayKitServiceName {
            endpointAttempts.append(.service(name: defaultReplayKitServiceName, type: defaultReplayKitServiceType, domain: defaultReplayKitServiceDomain))
            updateSenderStatus("queued bonjour fallback \(defaultReplayKitServiceName)")
            os_log("[ReplayKitSender] start path: queued default Bonjour endpoint %{public}@ type=%{public}@ domain=%{public}@", log: log, type: .info, defaultReplayKitServiceName, defaultReplayKitServiceType, defaultReplayKitServiceDomain)
        }
        if let host = storedHost, !host.isEmpty {
            if Self.isLinkLocalIPv6(host) {
                os_log("[ReplayKitSender] start path: skipped direct link-local IPv6 endpoint %{public}@ because ReplayKit extension lacks interface scope; using Bonjour", log: log, type: .error, host)
                updateSenderStatus("skipped link-local direct")
            } else {
                endpointAttempts.append(.direct(host: host, port: portValue))
                updateSenderStatus("queued direct \(host):\(portValue)")
                os_log("[ReplayKitSender] start path: queued direct App Group endpoint %{public}@:%d", log: log, type: .info, host, Int(portValue))
            }
        } else {
            os_log("[ReplayKitSender] start path: no direct macHostIP in App Group", log: log, type: .info)
        }

        if endpointAttempts.isEmpty {
            os_log("[ReplayKitSender] start path: no stored endpoint; starting in-extension Bonjour browse", log: log, type: .info)
            updateSenderStatus("browsing bonjour")
            startBonjourBrowseLocked(reason: "no stored endpoint")
            return
        }

        startNextEndpointAttemptLocked(reason: "start")
    }

    private func stopLocked(reason: String) {
        if connection == nil {
            os_log("[ReplayKitSender] stop path: no active connection reason=%{public}@", log: log, type: .info, reason)
        } else {
            os_log("[ReplayKitSender] stop path: cancelling active connection reason=%{public}@", log: log, type: .info, reason)
        }
        connection?.cancel()
        connection = nil
        browser?.cancel()
        browser = nil
        candidateTimeoutWorkItem?.cancel()
        candidateTimeoutWorkItem = nil
        endpointAttempts.removeAll()
        endpointAttemptIndex = 0
        pendingControlPackets.removeAll()
        latestH264ConfigPacket = nil
        connectionGeneration += 1
        state = .stopped
        queuedFrames = 0
        completedFrames = 0
        droppedFrames = 0
        inFlightSends = 0
        latestReceivedVideoFrames = 0
        latestSentVideoFrames = 0
        nextInternalControlSequence = 1
        lastSummaryTimestamp = Date.distantPast
        currentTransport = .unknown
        currentMaxFramesPerSecond = nil
    }

    private func sendFrameLocked(_ frame: ReplayKitEncodedFrame) {
        let framePayload = framePayload(for: frame)
        let descriptor = PacketDescriptor(
            type: .frame,
            label: "frame",
            sequenceDescription: String(frame.sequenceNumber),
            payloadLength: framePayload.count,
            packetLength: ReplayKitPacketEnvelope.headerByteCount + framePayload.count
        )

        guard case .ready = state else {
            droppedFrames += 1
            logPacketDecision(descriptor, action: "drop", reason: "connection not ready state=\(state.diagnosticDescription)")
            maybeLogSummary(reason: "drop-frame-not-ready")
            return
        }

        guard let connection else {
            droppedFrames += 1
            state = .failed("Missing connection")
            logPacketDecision(descriptor, action: "drop", reason: "ready state without NWConnection")
            maybeLogSummary(reason: "drop-frame-missing-connection")
            return
        }

        queuedFrames += 1
        let queueDelayMs: UInt64
        let now = Self.currentWallClockMilliseconds()
        if now >= frame.encodedWallClockMilliseconds {
            queueDelayMs = now - frame.encodedWallClockMilliseconds
        } else {
            queueDelayMs = 0
        }

        let packet = envelopedPacket(type: .frame, payload: framePayload)
        if inFlightSends > 0 || queueDelayMs > 40 || frame.encodeDurationMilliseconds > 20 {
            logPacketDecision(
                descriptor,
                action: "send-start",
                reason: "queueDelayMs=\(queueDelayMs) encodeMs=\(frame.encodeDurationMilliseconds) inFlight=\(inFlightSends)"
            )
        } else {
            logPacketDecision(descriptor, action: "send-start", reason: "steady-state")
        }

        transmitPacketLocked(
            connection: connection,
            packet: packet,
            descriptor: descriptor,
            captureWallClockMilliseconds: frame.captureWallClockMilliseconds,
            updatesFrameCounters: true,
            senderFailedReason: "frame send failed"
        )
    }

    private func sendH264ConfigLocked(_ config: ReplayKitH264ConfigPayload, payload: Data, reason: String) {
        let descriptor = PacketDescriptor(
            type: .h264Config,
            label: "h264.config",
            sequenceDescription: String(config.sequence),
            payloadLength: payload.count,
            packetLength: ReplayKitPacketEnvelope.headerByteCount + payload.count
        )

        guard case .ready = state else {
            logPacketDecision(descriptor, action: "defer", reason: "connection not ready state=\(state.diagnosticDescription) reason=\(reason)")
            return
        }

        guard let connection else {
            state = .failed("Missing connection")
            logPacketDecision(descriptor, action: "drop", reason: "ready state without NWConnection")
            return
        }

        let packet = envelopedPacket(type: .h264Config, payload: payload)
        logPacketDecision(
            descriptor,
            action: "send-start",
            reason: "\(reason) width=\(config.width) height=\(config.height) targetFPS=\(config.targetFPS)"
        )
        transmitPacketLocked(
            connection: connection,
            packet: packet,
            descriptor: descriptor,
            captureWallClockMilliseconds: nil,
            updatesFrameCounters: false,
            senderFailedReason: "h264 config send failed"
        )
    }

    private func sendH264AccessUnitLocked(_ accessUnit: ReplayKitEncodedH264AccessUnit) {
        let payload = accessUnit.packet.payload
        let header = accessUnit.packet.header
        let descriptor = PacketDescriptor(
            type: .h264AccessUnit,
            label: "h264.accessUnit",
            sequenceDescription: String(header.sequenceNumber),
            payloadLength: payload.count,
            packetLength: ReplayKitPacketEnvelope.headerByteCount + payload.count
        )

        guard case .ready = state else {
            droppedFrames += 1
            logPacketDecision(descriptor, action: "drop", reason: "connection not ready state=\(state.diagnosticDescription)")
            maybeLogSummary(reason: "drop-h264-not-ready")
            return
        }

        guard let connection else {
            droppedFrames += 1
            state = .failed("Missing connection")
            logPacketDecision(descriptor, action: "drop", reason: "ready state without NWConnection")
            maybeLogSummary(reason: "drop-h264-missing-connection")
            return
        }

        queuedFrames += 1
        let now = Self.currentWallClockMilliseconds()
        let queueDelayMs = now >= header.encodedWallClockMilliseconds ? now - header.encodedWallClockMilliseconds : 0
        let packet = envelopedPacket(type: .h264AccessUnit, payload: payload)
        logPacketDecision(
            descriptor,
            action: "send-start",
            reason: "queueDelayMs=\(queueDelayMs) encodeMs=\(accessUnit.encodeDurationMilliseconds) flags=\(header.flags.rawValue) inFlight=\(inFlightSends)"
        )
        transmitPacketLocked(
            connection: connection,
            packet: packet,
            descriptor: descriptor,
            captureWallClockMilliseconds: header.captureWallClockMilliseconds,
            updatesFrameCounters: true,
            senderFailedReason: "h264 access unit send failed"
        )
    }

    private func sendControlPacketLocked(
        event: ReplayKitControlEventName,
        sequence: Int,
        payload: Data,
        allowQueueIfNotReady: Bool
    ) {
        let descriptor = PacketDescriptor(
            type: .controlEvent,
            label: "control.\(event.rawValue)",
            sequenceDescription: String(sequence),
            payloadLength: payload.count,
            packetLength: ReplayKitPacketEnvelope.headerByteCount + payload.count
        )

        guard case .ready = state else {
            if allowQueueIfNotReady {
                enqueueControlPacketLocked(event: event, sequence: sequence, payload: payload, descriptor: descriptor, reason: "connection not ready state=\(state.diagnosticDescription)")
            } else {
                logPacketDecision(descriptor, action: "drop", reason: "connection not ready state=\(state.diagnosticDescription)")
            }
            return
        }

        guard let connection else {
            if allowQueueIfNotReady {
                enqueueControlPacketLocked(event: event, sequence: sequence, payload: payload, descriptor: descriptor, reason: "ready state without NWConnection")
            } else {
                state = .failed("Missing connection")
                logPacketDecision(descriptor, action: "drop", reason: "ready state without NWConnection")
            }
            return
        }

        let packet = envelopedPacket(type: .controlEvent, payload: payload)
        logPacketDecision(descriptor, action: "send-start", reason: "immediate")
        transmitPacketLocked(
            connection: connection,
            packet: packet,
            descriptor: descriptor,
            captureWallClockMilliseconds: nil,
            updatesFrameCounters: false,
            senderFailedReason: "control send failed"
        )
    }

    private func enqueueControlPacketLocked(
        event: ReplayKitControlEventName,
        sequence: Int,
        payload: Data,
        descriptor: PacketDescriptor,
        reason: String
    ) {
        if pendingControlPackets.count >= maximumPendingControlPackets {
            let droppedPacket = pendingControlPackets.removeFirst()
            os_log(
                "[ReplayKitSender] pending control queue full; dropping oldest event=%{public}@ seq=%d",
                log: log,
                type: .error,
                droppedPacket.event.rawValue,
                droppedPacket.sequence
            )
        }

        pendingControlPackets.append(PendingControlPacket(event: event, sequence: sequence, payload: payload))
        logPacketDecision(descriptor, action: "queue", reason: "\(reason) pendingControlPackets=\(pendingControlPackets.count)")
    }

    private func transmitPacketLocked(
        connection: NWConnection,
        packet: Data,
        descriptor: PacketDescriptor,
        captureWallClockMilliseconds: UInt64?,
        updatesFrameCounters: Bool,
        senderFailedReason: String
    ) {
        inFlightSends += 1
        connection.send(content: packet, completion: .contentProcessed { [weak self] error in
            guard let self else { return }
            self.queue.async {
                self.inFlightSends = max(0, self.inFlightSends - 1)
                if let error {
                    self.logPacketDecision(descriptor, action: "send-failed", reason: error.localizedDescription)
                    self.handleSendFailureLocked(
                        error.localizedDescription,
                        descriptor: descriptor,
                        senderFailedReason: senderFailedReason
                    )
                    return
                }

                if updatesFrameCounters {
                    self.completedFrames += 1
                    if let captureWallClockMilliseconds {
                        let completionNow = Self.currentWallClockMilliseconds()
                        let pipelineAgeMs = completionNow >= captureWallClockMilliseconds ? completionNow - captureWallClockMilliseconds : 0
                        self.logPacketDecision(
                            descriptor,
                            action: "send-complete",
                            reason: "pipelineAgeMs=\(pipelineAgeMs) completedFrames=\(self.completedFrames)"
                        )
                    } else {
                        self.logPacketDecision(descriptor, action: "send-complete", reason: "completedFrames=\(self.completedFrames)")
                    }
                } else {
                    self.logPacketDecision(descriptor, action: "send-complete", reason: "inFlight=\(self.inFlightSends)")
                }
                self.maybeLogSummary(reason: "send-complete-\(descriptor.label)")
            }
        })
    }

    private func handleSendFailureLocked(_ errorDescription: String, descriptor: PacketDescriptor, senderFailedReason: String) {
        if descriptor.label != "control.\(ReplayKitControlEventName.senderFailed.rawValue)" {
            emitInternalControlEventLocked(.senderFailed, reason: "\(senderFailedReason): \(descriptor.label) \(errorDescription)")
        } else {
            os_log("[ReplayKitSender] senderFailed control packet also failed; suppressing recursive senderFailed event", log: log, type: .error)
        }
        connection?.cancel()
        connection = nil
        state = .failed(errorDescription)
        maybeLogSummary(reason: "send-failed-\(descriptor.label)")
        scheduleReconnectLocked(reason: "\(senderFailedReason): \(errorDescription)")
    }

    private func startNextEndpointAttemptLocked(reason: String) {
        candidateTimeoutWorkItem?.cancel()
        candidateTimeoutWorkItem = nil

        guard endpointAttemptIndex < endpointAttempts.count else {
            os_log("[ReplayKitSender] endpoint attempts exhausted reason=%{public}@ count=%d; browsing Bonjour", log: log, type: .error, reason, endpointAttempts.count)
            updateSenderStatus("attempts exhausted")
            emitInternalControlEventLocked(.senderFailed, reason: "No reachable Mac endpoint")
            connection?.cancel()
            connection = nil
            state = .failed("No reachable Mac endpoint")
            startBonjourBrowseLocked(reason: "endpoint attempts exhausted")
            return
        }

        let attempt = endpointAttempts[endpointAttemptIndex]
        endpointAttemptIndex += 1
        connection?.cancel()

        let newConnection: NWConnection
        switch attempt {
        case .direct(let host, let portValue):
            guard let port = NWEndpoint.Port(rawValue: portValue) else {
                os_log("[ReplayKitSender] endpoint invalid direct port %d; trying next", log: log, type: .error, Int(portValue))
                startNextEndpointAttemptLocked(reason: "invalid direct port")
                return
            }
            os_log("[ReplayKitSender] endpoint attempt direct %{public}@:%d reason=%{public}@ attempt=%d/%d", log: log, type: .info, host, Int(portValue), reason, endpointAttemptIndex, endpointAttempts.count)
            updateSenderStatus("trying direct \(host):\(portValue)")
            newConnection = NWConnection(host: NWEndpoint.Host(host), port: port, using: .tcp)
        case .service(let name, let type, let domain):
            os_log("[ReplayKitSender] endpoint attempt Bonjour %{public}@ type=%{public}@ domain=%{public}@ reason=%{public}@ attempt=%d/%d", log: log, type: .info, name, type, domain, reason, endpointAttemptIndex, endpointAttempts.count)
            updateSenderStatus("trying bonjour \(name)")
            let endpoint = NWEndpoint.service(name: name, type: type, domain: domain, interface: nil)
            newConnection = NWConnection(to: endpoint, using: .tcp)
        }

        connection = newConnection
        let statePort = attempt.statePort(defaultPort: defaultReplayKitPort)
        state = .connecting(attempt.stateHost, statePort)
        let generation = connectionGeneration
        os_log("[ReplayKitSender] endpoint attempt creating connection to %{public}@ generation=%d", log: log, type: .info, attempt.description, generation)

        newConnection.stateUpdateHandler = { [weak self, weak newConnection] newState in
            guard let self, let newConnection else { return }
            self.handle(newState, connection: newConnection, host: attempt.stateHost, port: statePort)
        }

        newConnection.start(queue: queue)
        scheduleCandidateTimeoutLocked(for: newConnection, endpoint: attempt.description, generation: generation)
    }

    private func scheduleCandidateTimeoutLocked(for connection: NWConnection, endpoint: String, generation: Int) {
        let workItem = DispatchWorkItem { [weak self, weak connection] in
            guard let self, let connection else { return }
            guard self.connectionGeneration == generation, self.connection === connection else {
                os_log("[ReplayKitSender] endpoint timeout ignored for stale connection %{public}@", log: self.log, type: .info, endpoint)
                return
            }
            os_log("[ReplayKitSender] endpoint timeout for %{public}@; trying fallback", log: self.log, type: .error, endpoint)
            self.updateSenderStatus("timeout \(endpoint)")
            self.emitInternalControlEventLocked(.senderFailed, reason: "Endpoint timeout \(endpoint)")
            connection.cancel()
            self.connection = nil
            self.startNextEndpointAttemptLocked(reason: "timeout \(endpoint)")
        }
        candidateTimeoutWorkItem = workItem
        queue.asyncAfter(deadline: .now() + 4.0, execute: workItem)
    }

    private func startBonjourBrowseLocked(reason: String) {
        guard browser == nil else {
            os_log("[ReplayKitSender] Bonjour browse already active reason=%{public}@", log: log, type: .info, reason)
            return
        }

        let descriptor = NWBrowser.Descriptor.bonjour(type: defaultReplayKitServiceType, domain: nil)
        let browser = NWBrowser(for: descriptor, using: .tcp)
        self.browser = browser
        os_log("[ReplayKitSender] Bonjour browse starting reason=%{public}@ type=%{public}@", log: log, type: .info, reason, defaultReplayKitServiceType)
        updateSenderStatus("bonjour browse starting")

        browser.stateUpdateHandler = { [weak self] browserState in
            guard let self else { return }
            switch browserState {
            case .ready:
                os_log("[ReplayKitSender] Bonjour browse ready", log: self.log, type: .info)
                self.updateSenderStatus("bonjour browse ready")
            case .waiting(let error):
                os_log("[ReplayKitSender] Bonjour browse waiting: %{public}@", log: self.log, type: .error, error.localizedDescription)
                self.updateSenderStatus("bonjour waiting \(error.localizedDescription)")
            case .failed(let error):
                os_log("[ReplayKitSender] Bonjour browse failed: %{public}@", log: self.log, type: .error, error.localizedDescription)
                self.updateSenderStatus("bonjour failed \(error.localizedDescription)")
                self.queue.async {
                    self.emitInternalControlEventLocked(.senderFailed, reason: "Bonjour browse failed: \(error.localizedDescription)")
                    self.browser?.cancel()
                    self.browser = nil
                    if self.connection == nil {
                        self.state = .failed("Bonjour browse failed: \(error.localizedDescription)")
                    }
                }
            case .cancelled:
                os_log("[ReplayKitSender] Bonjour browse cancelled", log: self.log, type: .info)
            default:
                break
            }
        }

        browser.browseResultsChangedHandler = { [weak self] _, changes in
            guard let self else { return }
            for change in changes {
                guard case .added(let result) = change else { continue }
                os_log("[ReplayKitSender] Bonjour browse found endpoint %{public}@", log: self.log, type: .info, String(describing: result.endpoint))
                self.updateSenderStatus("bonjour found endpoint")
                self.queue.async {
                    self.storeReplayKitPolicyMetadataLocked(result.metadata, source: "extension browse")
                    self.browser?.cancel()
                    self.browser = nil
                    self.endpointAttempts.removeAll()
                    self.endpointAttemptIndex = 0
                    if case .service(let name, let type, let domain, _) = result.endpoint {
                        self.sharedDefaults?.set(name, forKey: "macReplayKitServiceName")
                        self.sharedDefaults?.set(type, forKey: "macReplayKitServiceType")
                        self.sharedDefaults?.set(domain, forKey: "macReplayKitServiceDomain")
                        self.sharedDefaults?.synchronize()
                        self.endpointAttempts.append(.service(name: name, type: type, domain: domain))
                        os_log("[ReplayKitSender] Bonjour browse stored service %{public}@ type=%{public}@ domain=%{public}@", log: self.log, type: .info, name, type, domain)
                    } else {
                        self.endpointAttempts.append(.service(name: self.defaultReplayKitServiceName, type: self.defaultReplayKitServiceType, domain: self.defaultReplayKitServiceDomain))
                        os_log("[ReplayKitSender] Bonjour browse result was not service; queued default service fallback", log: self.log, type: .error)
                    }
                    self.startNextEndpointAttemptLocked(reason: "Bonjour browse result")
                }
                return
            }
        }

        browser.start(queue: queue)
    }

    private func storeReplayKitPolicyMetadataLocked(_ metadata: NWBrowser.Result.Metadata, source: String) {
        guard case .bonjour(let txtRecord) = metadata else {
            os_log("[ReplayKitPolicy] %{public}@ metadata did not include Bonjour TXT record", log: log, type: .info, source)
            return
        }

        let dictionary = txtRecord.dictionary
        guard dictionary["rkPolicy"] == "1" else {
            os_log("[ReplayKitPolicy] %{public}@ TXT record missing rkPolicy marker", log: log, type: .info, source)
            return
        }

        let tier = dictionary["rkTier"] ?? "unknown"
        let isPremium = dictionary["rkPremium"] == "1"
        let jpegFPS = Double(dictionary["rkJPEGFPS"] ?? "") ?? 15
        let h264FPS = Double(dictionary["rkH264FPS"] ?? "") ?? 30
        let usbCableAttached = dictionary["rkUSBCable"] == "1"
        let usbReason = dictionary["rkUSBReason"] ?? "legacy transport metadata missing"
        sharedDefaults?.set(isPremium, forKey: "replayKitPolicyPremium")
        sharedDefaults?.set(tier, forKey: "replayKitPolicyTier")
        sharedDefaults?.set(jpegFPS, forKey: "replayKitPolicyJPEGFPS")
        sharedDefaults?.set(h264FPS, forKey: "replayKitPolicyH264FPS")
        sharedDefaults?.set(usbCableAttached, forKey: "replayKitPolicyUSBCableAttached")
        sharedDefaults?.set(usbReason, forKey: "replayKitPolicyUSBReason")
        sharedDefaults?.set(Date().timeIntervalSince1970, forKey: "replayKitPolicyStoredAt")
        sharedDefaults?.synchronize()
        currentMaxFramesPerSecond = h264FPS
        os_log("[ReplayKitPolicy] stored source=%{public}@ tier=%{public}@ premiumMetadata=%{public}@ legacyTransportMetadata=%{public}@ legacyTransportReason=%{public}@ jpegFPS=%.1f h264FPS=%.1f", log: log, type: .info, source, tier, isPremium ? "YES" : "NO", usbCableAttached ? "YES" : "NO", usbReason, jpegFPS, h264FPS)
    }

    private func scheduleReconnectLocked(reason: String) {
        guard connection == nil else {
            os_log("[ReplayKitSender] reconnect skipped reason=%{public}@: connection exists", log: log, type: .info, reason)
            return
        }
        os_log("[ReplayKitSender] reconnect scheduled reason=%{public}@", log: log, type: .info, reason)
        updateSenderStatus("reconnect scheduled")
        queue.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            self?.startLocked()
        }
    }

    private func handle(_ nwState: NWConnection.State, connection: NWConnection, host: String, port: UInt16) {
        guard self.connection === connection else {
            os_log("[ReplayKitSender] state ignored for stale connection", log: log, type: .info)
            return
        }

        switch nwState {
        case .setup:
            os_log("[ReplayKitSender] connection state=setup host=%{public}@ port=%d", log: log, type: .info, host, Int(port))
        case .preparing:
            os_log("[ReplayKitSender] connection state=preparing host=%{public}@ port=%d", log: log, type: .info, host, Int(port))
        case .ready:
            candidateTimeoutWorkItem?.cancel()
            candidateTimeoutWorkItem = nil
            browser?.cancel()
            browser = nil
            currentTransport = connection.currentPath.map { ReplayKitTransport.detect(from: $0) } ?? .unknown
            sharedDefaults?.set(currentTransport.rawValue, forKey: "replayKitLastSenderTransport")
            sharedDefaults?.synchronize()
            os_log("[ReplayKitTransport] sender path=%{public}@ host=%{public}@ port=%d", log: log, type: .info, currentTransport.rawValue, host, Int(port))
            os_log("[ReplayKitSender] connection READY %{public}@:%d pendingControlPackets=%d", log: log, type: .info, host, Int(port), pendingControlPackets.count)
            updateSenderStatus("ready \(host):\(port)")
            state = .ready(host, port)
            emitInternalControlEventLocked(.senderReady, reason: "\(host):\(port)")
            drainPendingControlPacketsLocked(trigger: "connection ready")
            sendLatestH264ConfigLocked(trigger: "connection ready")
        case .waiting(let error):
            os_log("[ReplayKitSender] connection waiting host=%{public}@ port=%d error=%{public}@", log: log, type: .info, host, Int(port), error.localizedDescription)
            updateSenderStatus("waiting \(error.localizedDescription)")
            state = .connecting(host, port)
        case .failed(let error):
            os_log("[ReplayKitSender] connection failed host=%{public}@ port=%d error=%{public}@", log: log, type: .error, host, Int(port), error.localizedDescription)
            updateSenderStatus("failed \(error.localizedDescription)")
            emitInternalControlEventLocked(.senderFailed, reason: "connection failed \(host):\(port) \(error.localizedDescription)")
            self.connection = nil
            state = .failed(error.localizedDescription)
            startNextEndpointAttemptLocked(reason: "failed \(error.localizedDescription)")
        case .cancelled:
            os_log("[ReplayKitSender] connection cancelled host=%{public}@ port=%d", log: log, type: .info, host, Int(port))
            if self.connection === connection {
                self.connection = nil
                if case .ready = self.state {
                    self.state = .stopped
                }
            }
        @unknown default:
            os_log("[ReplayKitSender] connection unknown state host=%{public}@ port=%d", log: log, type: .error, host, Int(port))
        }
    }

    private func drainPendingControlPacketsLocked(trigger: String) {
        guard !pendingControlPackets.isEmpty else {
            os_log("[ReplayKitSender] pending control queue empty trigger=%{public}@", log: log, type: .debug, trigger)
            return
        }

        guard case .ready = state, let connection else {
            os_log("[ReplayKitSender] pending control drain skipped trigger=%{public}@ state=%{public}@", log: log, type: .info, trigger, state.diagnosticDescription)
            return
        }

        let packets = pendingControlPackets
        pendingControlPackets.removeAll()
        os_log("[ReplayKitSender] draining pending control packets count=%d trigger=%{public}@", log: log, type: .info, packets.count, trigger)

        for pendingPacket in packets {
            let descriptor = PacketDescriptor(
                type: .controlEvent,
                label: "control.\(pendingPacket.event.rawValue)",
                sequenceDescription: String(pendingPacket.sequence),
                payloadLength: pendingPacket.payload.count,
                packetLength: ReplayKitPacketEnvelope.headerByteCount + pendingPacket.payload.count
            )
            let packet = envelopedPacket(type: .controlEvent, payload: pendingPacket.payload)
            logPacketDecision(descriptor, action: "send-start", reason: "drain \(trigger)")
            transmitPacketLocked(
                connection: connection,
                packet: packet,
                descriptor: descriptor,
                captureWallClockMilliseconds: nil,
                updatesFrameCounters: false,
                senderFailedReason: "drained control send failed"
            )
        }
    }

    private func sendLatestH264ConfigLocked(trigger: String) {
        guard let latestH264ConfigPacket else {
            os_log("[ReplayKitSender] h264 config replay skipped trigger=%{public}@ reason=no config cached", log: log, type: .debug, trigger)
            return
        }

        guard case .ready = state, let connection else {
            os_log("[ReplayKitSender] h264 config replay deferred trigger=%{public}@ state=%{public}@", log: log, type: .info, trigger, state.diagnosticDescription)
            return
        }

        let descriptor = PacketDescriptor(
            type: .h264Config,
            label: "h264.config.replay",
            sequenceDescription: String(latestH264ConfigPacket.sequence),
            payloadLength: latestH264ConfigPacket.payload.count,
            packetLength: ReplayKitPacketEnvelope.headerByteCount + latestH264ConfigPacket.payload.count
        )
        let packet = envelopedPacket(type: .h264Config, payload: latestH264ConfigPacket.payload)
        logPacketDecision(descriptor, action: "send-start", reason: "replay latest config trigger=\(trigger)")
        transmitPacketLocked(
            connection: connection,
            packet: packet,
            descriptor: descriptor,
            captureWallClockMilliseconds: nil,
            updatesFrameCounters: false,
            senderFailedReason: "h264 config replay send failed"
        )
    }

    private func emitInternalControlEventLocked(_ event: ReplayKitControlEventName, reason: String?) {
        let sequence = nextInternalControlSequence
        nextInternalControlSequence += 1

        let payload = ReplayKitControlEventPayload(
            event: event.rawValue,
            sequence: sequence,
            receivedVideoFrames: latestReceivedVideoFrames,
            sentVideoFrames: latestSentVideoFrames,
            reason: reason,
            timestamp: Date().timeIntervalSince1970,
            transport: currentTransport.rawValue,
            maxFramesPerSecond: currentMaxFramesPerSecond,
            videoOrientation: nil
        )

        guard let payloadData = encodeJSONPayload(payload, label: "control.\(event.rawValue)", sequence: String(sequence)) else {
            return
        }

        sendControlPacketLocked(
            event: event,
            sequence: sequence,
            payload: payloadData,
            allowQueueIfNotReady: false
        )
    }

    private func framePayload(for frame: ReplayKitEncodedFrame) -> Data {
        var data = Data(capacity: 18 + frame.jpegData.count)
        data.appendUInt64BE(frame.timestampMilliseconds)
        data.appendUInt16BE(frame.width)
        data.appendUInt16BE(frame.height)
        data.append(frame.quality)
        data.append(frame.orientation)
        data.appendUInt32BE(UInt32(frame.jpegData.count))
        data.append(frame.jpegData)
        return data
    }

    private func envelopedPacket(type: ReplayKitPacketType, payload: Data) -> Data {
        var data = Data(capacity: ReplayKitPacketEnvelope.headerByteCount + payload.count)
        data.append(ReplayKitPacketEnvelope.magic)
        data.append(ReplayKitPacketEnvelope.version)
        data.append(type.rawValue)
        data.appendUInt32BE(UInt32(payload.count))
        data.append(payload)
        return data
    }

    private func encodeJSONPayload<T: Encodable>(_ payload: T, label: String, sequence: String) -> Data? {
        do {
            return try jsonEncoder.encode(payload)
        } catch {
            os_log(
                "[ReplayKitSender] JSON payload encode failed label=%{public}@ seq=%{public}@ error=%{public}@",
                log: log,
                type: .error,
                label,
                sequence,
                error.localizedDescription
            )
            return nil
        }
    }

    private func logPacketDecision(_ descriptor: PacketDescriptor, action: String, reason: String) {
        os_log(
            "[ReplayKitSender] packet action=%{public}@ type=%{public}@ label=%{public}@ seq=%{public}@ payloadBytes=%d packetBytes=%d state=%{public}@ reason=%{public}@",
            log: log,
            type: .info,
            action,
            descriptor.type.diagnosticName,
            descriptor.label,
            descriptor.sequenceDescription,
            descriptor.payloadLength,
            descriptor.packetLength,
            state.diagnosticDescription,
            reason
        )
    }

    private func maybeLogSummary(reason: String) {
        let now = Date()
        guard now.timeIntervalSince(lastSummaryTimestamp) >= 1.0 else { return }
        lastSummaryTimestamp = now
        os_log(
            "[ReplayKitSender] summary reason=%{public}@ queuedFrames=%d completedFrames=%d droppedFrames=%d inFlight=%d pendingControlPackets=%d state=%{public}@",
            log: log,
            type: .info,
            reason,
            queuedFrames,
            completedFrames,
            droppedFrames,
            inFlightSends,
            pendingControlPackets.count,
            state.diagnosticDescription
        )
    }

    private static func currentWallClockMilliseconds() -> UInt64 {
        UInt64(Date().timeIntervalSince1970 * 1000)
    }

    private static func isLinkLocalIPv6(_ host: String) -> Bool {
        let normalizedHost = host
            .trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
            .lowercased()
        return normalizedHost.hasPrefix("fe80:")
    }

    private func updateSenderStatus(_ status: String) {
        sharedDefaults?.set(status, forKey: "broadcastSenderStatus")
        sharedDefaults?.set(Date().timeIntervalSince1970, forKey: "broadcastSenderStatusTime")
        sharedDefaults?.synchronize()
    }
}
