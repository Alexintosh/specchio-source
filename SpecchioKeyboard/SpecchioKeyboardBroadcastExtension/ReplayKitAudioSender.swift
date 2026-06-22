import Foundation
import Network
import os.log

enum ReplayKitAudioEventName: String {
    case heartbeat
    case broadcastStarted
    case broadcastPaused
    case broadcastResumed
    case broadcastFinished
    case senderReady
    case senderFailed
}

final class ReplayKitAudioSender {
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

    private struct PacketDescriptor {
        let type: ReplayKitPacketType
        let label: String
        let sequenceDescription: String
        let payloadLength: Int
        let packetLength: Int
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

    private let log = OSLog(subsystem: "com.alexintosh.SpecchioKeyboard", category: "ReplayKitAudioSender")
    private let queue = DispatchQueue(label: "com.alexintosh.SpecchioKeyboard.replaykit.audio.sender", qos: .userInitiated)
    private let sharedDefaults = UserDefaults(suiteName: "group.com.alexintosh.SpecchioKeyboard")
    private let jsonEncoder = JSONEncoder()
    private let defaultReplayKitAudioPort: UInt16 = ReplayKitAudioConstants.defaultPort
    private let defaultReplayKitAudioServiceType = "_specchio-replaykit-audio._tcp"
    private let defaultReplayKitAudioServiceName = "Specchio Easy Audio"
    private let defaultReplayKitAudioServiceDomain = "local."

    private var connection: NWConnection?
    private var browser: NWBrowser?
    private var state: SenderState = .idle
    private var endpointAttempts: [EndpointAttempt] = []
    private var endpointAttemptIndex = 0
    private var connectionGeneration = 0
    private var candidateTimeoutWorkItem: DispatchWorkItem?
    private var latestFormatSignature = ""
    private var latestFormatPayload: Data?
    private var latestFormatSequence = 0
    private var sentAudioPackets = 0
    private var droppedAudioPackets = 0
    private var currentTransport: ReplayKitTransport = .unknown

    func start() {
        os_log("[ReplayKitAudioSender] start requested envelopeMagic=%{public}@ version=%d", log: log, type: .info, "SPRK", Int(ReplayKitPacketEnvelope.version))
        updateSenderStatus("start requested")
        queue.async { [weak self] in
            self?.startLocked()
        }
    }

    func stop() {
        os_log("[ReplayKitAudioSender] stop requested", log: log, type: .info)
        updateSenderStatus("stop requested")
        queue.async { [weak self] in
            self?.stopLocked(reason: "stop()")
        }
    }

    func send(_ encodedAudio: ReplayKitEncodedAudioPacket) {
        queue.async { [weak self] in
            self?.sendAudioLocked(encodedAudio)
        }
    }

    func sendStatus(
        event: ReplayKitAudioEventName,
        sequence: Int,
        receivedAudioSamples: Int,
        sentAudioPackets: Int,
        droppedAudioPackets: Int,
        unsupportedAudioSamples: Int,
        reason: String?
    ) {
        queue.async { [weak self] in
            self?.sendHeartbeatLocked(
                event: event.rawValue,
                sequence: sequence,
                receivedAudioSamples: receivedAudioSamples,
                sentAudioPackets: sentAudioPackets,
                droppedAudioPackets: droppedAudioPackets,
                unsupportedAudioSamples: unsupportedAudioSamples,
                reason: reason
            )
        }
    }

    private func startLocked() {
        let storedAudioServiceName = sharedDefaults?.string(forKey: "macReplayKitAudioServiceName")
        let storedAudioServiceType = sharedDefaults?.string(forKey: "macReplayKitAudioServiceType") ?? defaultReplayKitAudioServiceType
        let storedAudioServiceDomain = sharedDefaults?.string(forKey: "macReplayKitAudioServiceDomain") ?? defaultReplayKitAudioServiceDomain
        let storedHost = sharedDefaults?.string(forKey: "macHostIP")
        let directAudioPort = resolvedAudioPortFromDefaults()

        os_log(
            "[ReplayKitAudioSender] start path storedService=%{public}@ storedHost=%{public}@ resolvedPort=%d",
            log: log,
            type: .info,
            storedAudioServiceName ?? "nil",
            storedHost ?? "nil",
            Int(directAudioPort)
        )

        connection?.cancel()
        connection = nil
        browser?.cancel()
        browser = nil
        candidateTimeoutWorkItem?.cancel()
        candidateTimeoutWorkItem = nil
        endpointAttempts.removeAll()
        endpointAttemptIndex = 0
        connectionGeneration += 1

        if let serviceName = storedAudioServiceName, !serviceName.isEmpty {
            endpointAttempts.append(.service(name: serviceName, type: storedAudioServiceType, domain: storedAudioServiceDomain))
            os_log("[ReplayKitAudioSender] start path: queued stored audio Bonjour service=%{public}@ type=%{public}@ domain=%{public}@", log: log, type: .info, serviceName, storedAudioServiceType, storedAudioServiceDomain)
        } else {
            os_log("[ReplayKitAudioSender] start path: no stored audio Bonjour service", log: log, type: .info)
        }

        if storedAudioServiceName != defaultReplayKitAudioServiceName {
            endpointAttempts.append(.service(name: defaultReplayKitAudioServiceName, type: defaultReplayKitAudioServiceType, domain: defaultReplayKitAudioServiceDomain))
            os_log("[ReplayKitAudioSender] start path: queued default audio Bonjour service=%{public}@ type=%{public}@", log: log, type: .info, defaultReplayKitAudioServiceName, defaultReplayKitAudioServiceType)
        }

        if let host = storedHost, !host.isEmpty {
            if Self.isLinkLocalIPv6(host) {
                os_log("[ReplayKitAudioSender] start path: skipped direct link-local IPv6 host=%{public}@ reason=missing-interface-scope", log: log, type: .error, host)
            } else {
                endpointAttempts.append(.direct(host: host, port: directAudioPort))
                os_log("[ReplayKitAudioSender] start path: queued direct audio endpoint=%{public}@:%d", log: log, type: .info, host, Int(directAudioPort))
            }
        } else {
            os_log("[ReplayKitAudioSender] start path: no macHostIP direct fallback", log: log, type: .info)
        }

        guard !endpointAttempts.isEmpty else {
            os_log("[ReplayKitAudioSender] start path: no endpoint candidates; browsing Bonjour", log: log, type: .info)
            updateSenderStatus("browsing audio bonjour")
            startBonjourBrowseLocked(reason: "no endpoint candidates")
            return
        }

        startNextEndpointAttemptLocked(reason: "start")
    }

    private func stopLocked(reason: String) {
        os_log("[ReplayKitAudioSender] stop path reason=%{public}@ connectionPresent=%{public}@", log: log, type: .info, reason, connection == nil ? "NO" : "YES")
        connection?.cancel()
        connection = nil
        browser?.cancel()
        browser = nil
        candidateTimeoutWorkItem?.cancel()
        candidateTimeoutWorkItem = nil
        endpointAttempts.removeAll()
        endpointAttemptIndex = 0
        connectionGeneration += 1
        state = .stopped
        currentTransport = .unknown
        latestFormatSignature = ""
        latestFormatPayload = nil
        latestFormatSequence = 0
        sentAudioPackets = 0
        droppedAudioPackets = 0
    }

    private func sendAudioLocked(_ encodedAudio: ReplayKitEncodedAudioPacket) {
        sendFormatIfNeededLocked(encodedAudio.format, summary: encodedAudio.formatSummary)

        let payload = encodedAudio.packet.payload
        let header = encodedAudio.packet.header
        let descriptor = PacketDescriptor(
            type: .audioPCM,
            label: "audio.pcm",
            sequenceDescription: String(header.sequenceNumber),
            payloadLength: payload.count,
            packetLength: ReplayKitPacketEnvelope.headerByteCount + payload.count
        )

        guard case .ready = state else {
            droppedAudioPackets += 1
            logPacketDecision(descriptor, action: "drop", reason: "connection not ready state=\(state.diagnosticDescription)")
            updatePacketDiagnostics(formatSummary: encodedAudio.formatSummary)
            return
        }

        guard let connection else {
            droppedAudioPackets += 1
            state = .failed("Missing audio connection")
            logPacketDecision(descriptor, action: "drop", reason: "ready state without NWConnection")
            updatePacketDiagnostics(formatSummary: encodedAudio.formatSummary)
            return
        }

        let packet = ReplayKitMediaEnvelopePacket.encode(type: .audioPCM, payload: payload)
        logPacketDecision(descriptor, action: "send-start", reason: "frames=\(header.frameCount) pcmBytes=\(encodedAudio.packet.pcmBytes.count)")
        transmitPacketLocked(
            connection: connection,
            packet: packet,
            descriptor: descriptor,
            updatesAudioCounters: true,
            senderFailedReason: "audio PCM send failed",
            formatSummary: encodedAudio.formatSummary
        )
    }

    private func sendFormatIfNeededLocked(_ format: ReplayKitAudioFormatPayload, summary: String) {
        let signature = "\(format.sampleRate)-\(format.channelCount)-\(format.commonFormat.rawValue)-\(format.isInterleaved)"
        guard signature != latestFormatSignature else {
            os_log("[ReplayKitAudioSender] format send skipped reason=unchanged summary=%{public}@", log: log, type: .debug, summary)
            return
        }

        guard let payload = encodeJSONPayload(format, label: "audio.format", sequence: String(format.sequence)) else {
            return
        }

        latestFormatSignature = signature
        latestFormatPayload = payload
        latestFormatSequence = format.sequence
        sharedDefaults?.set(summary, forKey: "broadcastAudioFormatSummary")
        sharedDefaults?.synchronize()
        os_log("[ReplayKitAudioSender] format changed sequence=%d summary=%{public}@ payloadBytes=%d", log: log, type: .info, format.sequence, summary, payload.count)
        sendLatestFormatLocked(trigger: "format changed", summary: summary)
    }

    private func sendLatestFormatLocked(trigger: String, summary: String) {
        guard let latestFormatPayload else {
            os_log("[ReplayKitAudioSender] format replay skipped trigger=%{public}@ reason=no-format", log: log, type: .info, trigger)
            return
        }

        let descriptor = PacketDescriptor(
            type: .audioFormat,
            label: "audio.format",
            sequenceDescription: String(latestFormatSequence),
            payloadLength: latestFormatPayload.count,
            packetLength: ReplayKitPacketEnvelope.headerByteCount + latestFormatPayload.count
        )

        guard case .ready = state, let connection else {
            logPacketDecision(descriptor, action: "defer", reason: "state=\(state.diagnosticDescription) trigger=\(trigger)")
            return
        }

        let packet = ReplayKitMediaEnvelopePacket.encode(type: .audioFormat, payload: latestFormatPayload)
        logPacketDecision(descriptor, action: "send-start", reason: "trigger=\(trigger) summary=\(summary)")
        transmitPacketLocked(
            connection: connection,
            packet: packet,
            descriptor: descriptor,
            updatesAudioCounters: false,
            senderFailedReason: "audio format send failed",
            formatSummary: summary
        )
    }

    private func sendHeartbeatLocked(
        event: String,
        sequence: Int,
        receivedAudioSamples: Int,
        sentAudioPackets: Int,
        droppedAudioPackets: Int,
        unsupportedAudioSamples: Int,
        reason: String?
    ) {
        let heartbeat = ReplayKitAudioHeartbeatPayload(
            event: event,
            sequence: sequence,
            receivedAudioSamples: receivedAudioSamples,
            sentAudioPackets: sentAudioPackets,
            droppedAudioPackets: droppedAudioPackets,
            unsupportedAudioSamples: unsupportedAudioSamples,
            senderState: state.diagnosticDescription,
            reason: reason,
            timestamp: Date().timeIntervalSince1970,
            transport: currentTransport.rawValue
        )

        guard let payload = encodeJSONPayload(heartbeat, label: "audio.heartbeat", sequence: String(sequence)) else {
            return
        }

        let descriptor = PacketDescriptor(
            type: .audioHeartbeat,
            label: "audio.heartbeat.\(event)",
            sequenceDescription: String(sequence),
            payloadLength: payload.count,
            packetLength: ReplayKitPacketEnvelope.headerByteCount + payload.count
        )

        guard case .ready = state, let connection else {
            logPacketDecision(descriptor, action: "drop", reason: "connection not ready state=\(state.diagnosticDescription)")
            return
        }

        let packet = ReplayKitMediaEnvelopePacket.encode(type: .audioHeartbeat, payload: payload)
        logPacketDecision(descriptor, action: "send-start", reason: "event=\(event)")
        transmitPacketLocked(
            connection: connection,
            packet: packet,
            descriptor: descriptor,
            updatesAudioCounters: false,
            senderFailedReason: "audio heartbeat send failed",
            formatSummary: sharedDefaults?.string(forKey: "broadcastAudioFormatSummary") ?? "waiting"
        )
    }

    private func startNextEndpointAttemptLocked(reason: String) {
        candidateTimeoutWorkItem?.cancel()
        candidateTimeoutWorkItem = nil

        guard endpointAttemptIndex < endpointAttempts.count else {
            os_log("[ReplayKitAudioSender] endpoint attempts exhausted reason=%{public}@ count=%d; browsing Bonjour", log: log, type: .error, reason, endpointAttempts.count)
            updateSenderStatus("audio attempts exhausted")
            connection?.cancel()
            connection = nil
            state = .failed("No reachable audio endpoint")
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
                os_log("[ReplayKitAudioSender] endpoint invalid direct port=%d; trying next", log: log, type: .error, Int(portValue))
                startNextEndpointAttemptLocked(reason: "invalid direct port")
                return
            }
            os_log("[ReplayKitAudioSender] endpoint attempt direct=%{public}@:%d reason=%{public}@ attempt=%d/%d", log: log, type: .info, host, Int(portValue), reason, endpointAttemptIndex, endpointAttempts.count)
            updateSenderStatus("trying audio direct \(host):\(portValue)")
            newConnection = NWConnection(host: NWEndpoint.Host(host), port: port, using: .tcp)
        case .service(let name, let type, let domain):
            os_log("[ReplayKitAudioSender] endpoint attempt Bonjour name=%{public}@ type=%{public}@ domain=%{public}@ reason=%{public}@ attempt=%d/%d", log: log, type: .info, name, type, domain, reason, endpointAttemptIndex, endpointAttempts.count)
            updateSenderStatus("trying audio bonjour \(name)")
            newConnection = NWConnection(to: .service(name: name, type: type, domain: domain, interface: nil), using: .tcp)
        }

        connection = newConnection
        let statePort = attempt.statePort(defaultPort: defaultReplayKitAudioPort)
        state = .connecting(attempt.stateHost, statePort)
        let generation = connectionGeneration
        newConnection.stateUpdateHandler = { [weak self, weak newConnection] newState in
            guard let self, let newConnection else { return }
            self.handle(newState, connection: newConnection, attempt: attempt, port: statePort)
        }
        newConnection.start(queue: queue)
        scheduleCandidateTimeoutLocked(for: newConnection, endpoint: attempt.description, generation: generation)
    }

    private func scheduleCandidateTimeoutLocked(for connection: NWConnection, endpoint: String, generation: Int) {
        let workItem = DispatchWorkItem { [weak self, weak connection] in
            guard let self, let connection else { return }
            guard self.connectionGeneration == generation, self.connection === connection else {
                os_log("[ReplayKitAudioSender] endpoint timeout ignored reason=stale endpoint=%{public}@", log: self.log, type: .info, endpoint)
                return
            }
            os_log("[ReplayKitAudioSender] endpoint timeout endpoint=%{public}@; trying fallback", log: self.log, type: .error, endpoint)
            self.updateSenderStatus("audio timeout \(endpoint)")
            connection.cancel()
            self.connection = nil
            self.startNextEndpointAttemptLocked(reason: "timeout \(endpoint)")
        }
        candidateTimeoutWorkItem = workItem
        queue.asyncAfter(deadline: .now() + 4.0, execute: workItem)
    }

    private func startBonjourBrowseLocked(reason: String) {
        guard browser == nil else {
            os_log("[ReplayKitAudioSender] Bonjour browse already active reason=%{public}@", log: log, type: .info, reason)
            return
        }

        let descriptor = NWBrowser.Descriptor.bonjour(type: defaultReplayKitAudioServiceType, domain: nil)
        let browser = NWBrowser(for: descriptor, using: .tcp)
        self.browser = browser
        os_log("[ReplayKitAudioSender] Bonjour browse starting reason=%{public}@ type=%{public}@", log: log, type: .info, reason, defaultReplayKitAudioServiceType)
        updateSenderStatus("audio bonjour browse starting")

        browser.stateUpdateHandler = { [weak self] browserState in
            guard let self else { return }
            switch browserState {
            case .ready:
                os_log("[ReplayKitAudioSender] Bonjour browse ready", log: self.log, type: .info)
                self.updateSenderStatus("audio bonjour browse ready")
            case .waiting(let error):
                os_log("[ReplayKitAudioSender] Bonjour browse waiting error=%{public}@", log: self.log, type: .error, error.localizedDescription)
                self.updateSenderStatus("audio bonjour waiting \(error.localizedDescription)")
            case .failed(let error):
                os_log("[ReplayKitAudioSender] Bonjour browse failed error=%{public}@", log: self.log, type: .error, error.localizedDescription)
                self.updateSenderStatus("audio bonjour failed \(error.localizedDescription)")
                self.queue.async {
                    self.browser?.cancel()
                    self.browser = nil
                    if self.connection == nil {
                        self.state = .failed("Audio Bonjour browse failed: \(error.localizedDescription)")
                    }
                }
            case .cancelled:
                os_log("[ReplayKitAudioSender] Bonjour browse cancelled", log: self.log, type: .info)
            default:
                break
            }
        }

        browser.browseResultsChangedHandler = { [weak self] _, changes in
            guard let self else { return }
            for change in changes {
                guard case .added(let result) = change else { continue }
                os_log("[ReplayKitAudioSender] Bonjour browse found endpoint=%{public}@", log: self.log, type: .info, String(describing: result.endpoint))
                self.updateSenderStatus("audio bonjour found endpoint")
                self.queue.async {
                    self.browser?.cancel()
                    self.browser = nil
                    self.endpointAttempts.removeAll()
                    self.endpointAttemptIndex = 0
                    if case .service(let name, let type, let domain, _) = result.endpoint {
                        self.sharedDefaults?.set(name, forKey: "macReplayKitAudioServiceName")
                        self.sharedDefaults?.set(type, forKey: "macReplayKitAudioServiceType")
                        self.sharedDefaults?.set(domain, forKey: "macReplayKitAudioServiceDomain")
                        self.sharedDefaults?.synchronize()
                        self.endpointAttempts.append(.service(name: name, type: type, domain: domain))
                        os_log("[ReplayKitAudioSender] Bonjour browse stored service name=%{public}@ type=%{public}@ domain=%{public}@", log: self.log, type: .info, name, type, domain)
                    } else {
                        self.endpointAttempts.append(.service(name: self.defaultReplayKitAudioServiceName, type: self.defaultReplayKitAudioServiceType, domain: self.defaultReplayKitAudioServiceDomain))
                        os_log("[ReplayKitAudioSender] Bonjour result was not service; queued default service", log: self.log, type: .error)
                    }
                    self.startNextEndpointAttemptLocked(reason: "Bonjour browse result")
                }
                return
            }
        }

        browser.start(queue: queue)
    }

    private func handle(_ nwState: NWConnection.State, connection: NWConnection, attempt: EndpointAttempt, port: UInt16) {
        guard self.connection === connection else {
            os_log("[ReplayKitAudioSender] connection state ignored reason=stale", log: log, type: .info)
            return
        }

        switch nwState {
        case .setup:
            os_log("[ReplayKitAudioSender] connection state=setup endpoint=%{public}@ port=%d", log: log, type: .info, attempt.stateHost, Int(port))
        case .preparing:
            os_log("[ReplayKitAudioSender] connection state=preparing endpoint=%{public}@ port=%d", log: log, type: .info, attempt.stateHost, Int(port))
        case .ready:
            candidateTimeoutWorkItem?.cancel()
            candidateTimeoutWorkItem = nil
            browser?.cancel()
            browser = nil
            currentTransport = connection.currentPath.map { ReplayKitTransport.detect(from: $0) } ?? .unknown
            state = .ready(attempt.stateHost, port)
            storeSuccessfulEndpointLocked(attempt, port: port)
            updateSenderStatus("ready \(attempt.stateHost):\(port)")
            sharedDefaults?.set(currentTransport.rawValue, forKey: "replayKitLastAudioSenderTransport")
            sharedDefaults?.synchronize()
            os_log("[ReplayKitAudioSender] connection state=ready endpoint=%{public}@ port=%d transport=%{public}@", log: log, type: .info, attempt.stateHost, Int(port), currentTransport.rawValue)
            sendLatestFormatLocked(trigger: "connection ready", summary: sharedDefaults?.string(forKey: "broadcastAudioFormatSummary") ?? "waiting")
        case .waiting(let error):
            os_log("[ReplayKitAudioSender] connection state=waiting endpoint=%{public}@ port=%d error=%{public}@", log: log, type: .info, attempt.stateHost, Int(port), error.localizedDescription)
            updateSenderStatus("audio waiting \(error.localizedDescription)")
            state = .connecting(attempt.stateHost, port)
        case .failed(let error):
            os_log("[ReplayKitAudioSender] connection state=failed endpoint=%{public}@ port=%d error=%{public}@", log: log, type: .error, attempt.stateHost, Int(port), error.localizedDescription)
            updateSenderStatus("audio failed \(error.localizedDescription)")
            self.connection = nil
            state = .failed(error.localizedDescription)
            startNextEndpointAttemptLocked(reason: "failed \(error.localizedDescription)")
        case .cancelled:
            os_log("[ReplayKitAudioSender] connection state=cancelled endpoint=%{public}@ port=%d", log: log, type: .info, attempt.stateHost, Int(port))
            if self.connection === connection {
                self.connection = nil
                if case .ready = state {
                    state = .stopped
                }
            }
        @unknown default:
            os_log("[ReplayKitAudioSender] connection state=unknown endpoint=%{public}@ port=%d", log: log, type: .error, attempt.stateHost, Int(port))
        }
    }

    private func transmitPacketLocked(
        connection: NWConnection,
        packet: Data,
        descriptor: PacketDescriptor,
        updatesAudioCounters: Bool,
        senderFailedReason: String,
        formatSummary: String
    ) {
        connection.send(content: packet, completion: .contentProcessed { [weak self] error in
            guard let self else { return }
            self.queue.async {
                if let error {
                    self.droppedAudioPackets += updatesAudioCounters ? 1 : 0
                    self.logPacketDecision(descriptor, action: "send-failed", reason: error.localizedDescription)
                    self.handleSendFailureLocked(error.localizedDescription, senderFailedReason: senderFailedReason)
                    self.updatePacketDiagnostics(formatSummary: formatSummary)
                    return
                }

                if updatesAudioCounters {
                    self.sentAudioPackets += 1
                }
                self.logPacketDecision(descriptor, action: "send-complete", reason: "sentAudioPackets=\(self.sentAudioPackets) dropped=\(self.droppedAudioPackets)")
                self.updatePacketDiagnostics(formatSummary: formatSummary)
            }
        })
    }

    private func handleSendFailureLocked(_ errorDescription: String, senderFailedReason: String) {
        updateSenderStatus("audio send failed \(errorDescription)")
        connection?.cancel()
        connection = nil
        state = .failed(errorDescription)
        scheduleReconnectLocked(reason: "\(senderFailedReason): \(errorDescription)")
    }

    private func scheduleReconnectLocked(reason: String) {
        guard connection == nil else {
            os_log("[ReplayKitAudioSender] reconnect skipped reason=%{public}@ branch=connection-exists", log: log, type: .info, reason)
            return
        }
        os_log("[ReplayKitAudioSender] reconnect scheduled reason=%{public}@", log: log, type: .info, reason)
        updateSenderStatus("audio reconnect scheduled")
        queue.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            self?.startLocked()
        }
    }

    private func resolvedAudioPortFromDefaults() -> UInt16 {
        let storedAudioPort = sharedDefaults?.integer(forKey: "macReplayKitAudioPort") ?? 0
        if storedAudioPort > 0, storedAudioPort <= Int(UInt16.max) {
            os_log("[ReplayKitAudioSender] port path=stored-audio port=%d", log: log, type: .info, storedAudioPort)
            return UInt16(storedAudioPort)
        }

        let storedVideoPort = sharedDefaults?.integer(forKey: "macReplayKitPort") ?? 0
        if storedVideoPort > 0, storedVideoPort < Int(UInt16.max) {
            let fallbackPort = UInt16(storedVideoPort + 1)
            os_log("[ReplayKitAudioSender] port path=video-plus-one videoPort=%d audioPort=%d", log: log, type: .info, storedVideoPort, Int(fallbackPort))
            return fallbackPort
        }

        os_log("[ReplayKitAudioSender] port path=default port=%d", log: log, type: .info, Int(defaultReplayKitAudioPort))
        return defaultReplayKitAudioPort
    }

    private func storeSuccessfulEndpointLocked(_ attempt: EndpointAttempt, port: UInt16) {
        switch attempt {
        case .direct(let host, let port):
            sharedDefaults?.set(host, forKey: "macHostIP")
            sharedDefaults?.set(Int(port), forKey: "macReplayKitAudioPort")
            os_log("[ReplayKitAudioSender] stored successful direct audio endpoint host=%{public}@ port=%d", log: log, type: .info, host, Int(port))
        case .service(let name, let type, let domain):
            sharedDefaults?.set(name, forKey: "macReplayKitAudioServiceName")
            sharedDefaults?.set(type, forKey: "macReplayKitAudioServiceType")
            sharedDefaults?.set(domain, forKey: "macReplayKitAudioServiceDomain")
            sharedDefaults?.set(Int(port), forKey: "macReplayKitAudioPort")
            os_log("[ReplayKitAudioSender] stored successful service audio endpoint name=%{public}@ type=%{public}@ domain=%{public}@ port=%d", log: log, type: .info, name, type, domain, Int(port))
        }
        sharedDefaults?.synchronize()
    }

    private func encodeJSONPayload<T: Encodable>(_ payload: T, label: String, sequence: String) -> Data? {
        do {
            return try jsonEncoder.encode(payload)
        } catch {
            os_log("[ReplayKitAudioSender] JSON payload encode failed label=%{public}@ seq=%{public}@ error=%{public}@", log: log, type: .error, label, sequence, error.localizedDescription)
            return nil
        }
    }

    private func logPacketDecision(_ descriptor: PacketDescriptor, action: String, reason: String) {
        os_log(
            "[ReplayKitAudioSender] packet action=%{public}@ type=%{public}@ label=%{public}@ seq=%{public}@ payloadBytes=%d packetBytes=%d state=%{public}@ reason=%{public}@",
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

    private func updateSenderStatus(_ status: String) {
        sharedDefaults?.set(status, forKey: "broadcastAudioSenderStatus")
        sharedDefaults?.set(Date().timeIntervalSince1970, forKey: "broadcastAudioSenderStatusTime")
        sharedDefaults?.synchronize()
    }

    private func updatePacketDiagnostics(formatSummary: String) {
        sharedDefaults?.set(sentAudioPackets, forKey: "broadcastAudioPacketsSent")
        sharedDefaults?.set(droppedAudioPackets, forKey: "broadcastAudioPacketsDropped")
        sharedDefaults?.set(formatSummary, forKey: "broadcastAudioFormatSummary")
        sharedDefaults?.synchronize()
    }

    private static func isLinkLocalIPv6(_ host: String) -> Bool {
        let normalizedHost = host
            .trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
            .lowercased()
        return normalizedHost.hasPrefix("fe80:")
    }
}
