import AVFoundation
import Foundation
import Network

private let replayKitAudioLog = SpecchioLogger.replayKit

enum ReplayKitAudioStreamState: String, Equatable {
    case off
    case waiting
    case live
    case error
}

final class ReplayKitAudioStreamManager: NSObject, ObservableObject {
    static let defaultPort: UInt16 = ReplayKitAudioConstants.defaultPort
    static let bonjourType = "_specchio-replaykit-audio._tcp."
    static let bonjourName = "Specchio Easy Audio"

    @Published var isListening = false
    @Published var isClientConnected = false
    @Published var isAudioPlaying = false
    @Published var audioStatusMessage = "Audio Off"
    @Published var audioState: ReplayKitAudioStreamState = .off
    @Published var lastAudioPacketReceivedAt: Date?
    @Published var receivedAudioPacketCount = 0
    @Published var droppedAudioPacketCount = 0
    @Published var audioSampleRate: Double = 0
    @Published var audioChannelCount = 0
    @Published var audioLatencyMilliseconds: Double = 0

    let port: UInt16

    private let queue = DispatchQueue(label: "com.alexintosh.Specchio.replaykit.audio", qos: .userInteractive)
    private let maximumAudioPayloadBytes = ReplayKitAudioConstants.maximumEnvelopePayloadBytes
    private let envelopeHeaderByteCount = ReplayKitPacketEnvelope.headerByteCount
    private var listener: NWListener?
    private var connection: NWConnection?
    private var bonjourService: NetService?
    private var engine: AVAudioEngine?
    private var player: AVAudioPlayerNode?
    private var currentAVFormat: AVAudioFormat?
    private var currentFormatPayload: ReplayKitAudioFormatPayload?
    private var sequenceTracker = ReplayKitPacketSequenceTracker()
    private var jitterBuffer = ReplayKitAudioJitterBufferState()
    private var silenceTimer: DispatchSourceTimer?
    private var isPlayerStarted = false
    private var lastPCMConversionDescription: String?
    private var lastAudioPacketArrivedAt: Date?

    init(port: UInt16 = ReplayKitAudioStreamManager.defaultPort) {
        self.port = port
        super.init()
        replayKitAudioLog.info("[ReceiverAudio] initialized port=\(self.port) service=\(Self.bonjourName, privacy: .public) type=\(Self.bonjourType, privacy: .public)")
    }

    func startListening() {
        replayKitAudioLog.info("[ReceiverAudio] startListening requested port=\(self.port)")
        queue.async { [weak self] in
            guard let self else { return }

            guard self.listener == nil else {
                replayKitAudioLog.info("[ReceiverAudio] startListening branch=already-listening port=\(self.port)")
                self.publishAudioState(.waiting, message: "Audio Waiting")
                return
            }

            self.resetSessionStateLocked(reason: "startListening")

            guard let nwPort = NWEndpoint.Port(rawValue: self.port) else {
                replayKitAudioLog.error("[ReceiverAudio] startListening branch=invalid-port port=\(self.port)")
                self.publishAudioState(.error, message: "Audio Error")
                return
            }

            do {
                let listener = try NWListener(using: .tcp, on: nwPort)
                self.listener = listener
                replayKitAudioLog.info("[ReceiverAudio] listener created port=\(self.port)")
                listener.stateUpdateHandler = { [weak self] state in
                    self?.handleListenerState(state)
                }
                listener.newConnectionHandler = { [weak self] newConnection in
                    self?.accept(newConnection)
                }
                listener.start(queue: self.queue)
                self.startSilenceMonitorLocked()
            } catch {
                replayKitAudioLog.error("[ReceiverAudio] listener creation failed error=\(error.localizedDescription, privacy: .public)")
                self.publishAudioState(.error, message: "Audio Error")
            }
        }
    }

    func stop() {
        replayKitAudioLog.info("[ReceiverAudio] stop requested")
        queue.async { [weak self] in
            guard let self else { return }
            self.connection?.cancel()
            self.connection = nil
            self.listener?.cancel()
            self.listener = nil
            self.bonjourService?.stop()
            self.bonjourService = nil
            self.silenceTimer?.setEventHandler {}
            self.silenceTimer?.cancel()
            self.silenceTimer = nil
            self.stopPlaybackLocked(reason: "stop")
            self.resetSessionStateLocked(reason: "stop")
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.isListening = false
                self.isClientConnected = false
                self.isAudioPlaying = false
                self.audioStatusMessage = "Audio Off"
                self.audioState = .off
            }
        }
    }

    private func handleListenerState(_ state: NWListener.State) {
        switch state {
        case .setup:
            replayKitAudioLog.info("[ReceiverAudio] listener state=setup")
            publishAudioState(.waiting, message: "Audio Preparing")
        case .ready:
            replayKitAudioLog.info("[ReceiverAudio] listener state=ready port=\(self.port)")
            DispatchQueue.main.async { [weak self] in
                self?.isListening = true
                self?.audioStatusMessage = "Audio Waiting"
                self?.audioState = .waiting
            }
            startBonjourAdvertisementLocked()
        case .waiting(let error):
            replayKitAudioLog.warning("[ReceiverAudio] listener state=waiting error=\(error.localizedDescription, privacy: .public)")
            publishAudioState(.error, message: "Audio Error")
        case .failed(let error):
            replayKitAudioLog.error("[ReceiverAudio] listener state=failed error=\(error.localizedDescription, privacy: .public)")
            listener?.cancel()
            listener = nil
            publishAudioState(.error, message: "Audio Error")
            DispatchQueue.main.async { [weak self] in
                self?.isListening = false
            }
        case .cancelled:
            replayKitAudioLog.info("[ReceiverAudio] listener state=cancelled")
            publishAudioState(.off, message: "Audio Off")
            DispatchQueue.main.async { [weak self] in
                self?.isListening = false
            }
        @unknown default:
            replayKitAudioLog.warning("[ReceiverAudio] listener state=unknown")
            publishAudioState(.error, message: "Audio Error")
        }
    }

    private func accept(_ newConnection: NWConnection) {
        replayKitAudioLog.info("[ReceiverAudio] connection incoming")
        if connection == nil {
            replayKitAudioLog.info("[ReceiverAudio] connection branch=accept-first")
        } else {
            replayKitAudioLog.info("[ReceiverAudio] connection branch=replace-existing")
        }

        connection?.cancel()
        connection = newConnection
        sequenceTracker.reset()
        jitterBuffer.reset()
        lastAudioPacketArrivedAt = nil
        isPlayerStarted = false
        DispatchQueue.main.async { [weak self] in
            self?.isClientConnected = false
            self?.isAudioPlaying = false
            self?.audioLatencyMilliseconds = 0
            self?.audioStatusMessage = "Audio Connecting"
            self?.audioState = .waiting
        }

        newConnection.stateUpdateHandler = { [weak self, weak newConnection] state in
            guard let self, let newConnection else { return }
            self.handleConnectionState(state, connection: newConnection)
        }
        newConnection.start(queue: queue)
    }

    private func handleConnectionState(_ state: NWConnection.State, connection: NWConnection) {
        guard self.connection === connection else {
            replayKitAudioLog.info("[ReceiverAudio] connection state ignored reason=stale")
            return
        }

        switch state {
        case .setup:
            replayKitAudioLog.info("[ReceiverAudio] connection state=setup")
            publishAudioState(.waiting, message: "Audio Connecting")
        case .preparing:
            replayKitAudioLog.info("[ReceiverAudio] connection state=preparing")
            publishAudioState(.waiting, message: "Audio Connecting")
        case .ready:
            replayKitAudioLog.info("[ReceiverAudio] connection state=ready")
            DispatchQueue.main.async { [weak self] in
                self?.isClientConnected = true
                self?.audioStatusMessage = "Audio Waiting"
                self?.audioState = .waiting
            }
            receiveEnvelopeHeader(on: connection)
        case .waiting(let error):
            replayKitAudioLog.warning("[ReceiverAudio] connection state=waiting error=\(error.localizedDescription, privacy: .public)")
            publishAudioState(.waiting, message: "Audio Waiting")
        case .failed(let error):
            replayKitAudioLog.error("[ReceiverAudio] connection state=failed error=\(error.localizedDescription, privacy: .public)")
            handleClientDisconnect(connection, reason: "failed: \(error.localizedDescription)")
        case .cancelled:
            replayKitAudioLog.info("[ReceiverAudio] connection state=cancelled")
            handleClientDisconnect(connection, reason: "cancelled")
        @unknown default:
            replayKitAudioLog.warning("[ReceiverAudio] connection state=unknown")
            publishAudioState(.error, message: "Audio Error")
        }
    }

    private func receiveEnvelopeHeader(on connection: NWConnection) {
        guard connection === self.connection else {
            replayKitAudioLog.info("[ReceiverAudio] receive header ignored reason=stale-connection")
            return
        }

        connection.receive(minimumIncompleteLength: envelopeHeaderByteCount, maximumLength: envelopeHeaderByteCount) { [weak self, weak connection] data, _, isComplete, error in
            guard let self, let connection else { return }

            if let error {
                replayKitAudioLog.error("[ReceiverAudio] header receive failed error=\(error.localizedDescription, privacy: .public)")
                self.handleClientDisconnect(connection, reason: "header error: \(error.localizedDescription)")
                return
            }

            if isComplete {
                replayKitAudioLog.info("[ReceiverAudio] header receive complete peerClosed=true")
                self.handleClientDisconnect(connection, reason: "peer closed before header")
                return
            }

            guard let data, data.count == self.envelopeHeaderByteCount else {
                replayKitAudioLog.warning("[ReceiverAudio] header malformed bytes=\(data?.count ?? 0) expected=\(self.envelopeHeaderByteCount)")
                self.receiveEnvelopeHeader(on: connection)
                return
            }

            self.handleEnvelopeHeader(data, on: connection)
        }
    }

    private func handleEnvelopeHeader(_ data: Data, on connection: NWConnection) {
        guard let header = ReplayKitMediaEnvelopeHeader(data: data) else {
            replayKitAudioLog.warning("[ReceiverAudio] header rejected reason=bad-magic bytes=\(data.count)")
            receiveEnvelopeHeader(on: connection)
            return
        }

        replayKitAudioLog.debug("[ReceiverAudio] header parsed version=\(header.version) type=\(header.rawPacketType) length=\(header.payloadLength)")

        guard header.payloadLength > 0 else {
            replayKitAudioLog.warning("[ReceiverAudio] packet rejected reason=empty-payload type=\(header.rawPacketType)")
            receiveEnvelopeHeader(on: connection)
            return
        }

        guard header.payloadLength <= maximumAudioPayloadBytes else {
            replayKitAudioLog.error("[ReceiverAudio] packet rejected reason=oversized-payload length=\(header.payloadLength) max=\(self.maximumAudioPayloadBytes)")
            handleClientDisconnect(connection, reason: "audio payload too large")
            return
        }

        connection.receive(minimumIncompleteLength: header.payloadLength, maximumLength: header.payloadLength) { [weak self, weak connection] data, _, isComplete, error in
            guard let self, let connection else { return }

            if let error {
                replayKitAudioLog.error("[ReceiverAudio] payload receive failed error=\(error.localizedDescription, privacy: .public)")
                self.handleClientDisconnect(connection, reason: "payload error: \(error.localizedDescription)")
                return
            }

            if isComplete {
                replayKitAudioLog.info("[ReceiverAudio] payload receive complete peerClosed=true")
                self.handleClientDisconnect(connection, reason: "peer closed before payload")
                return
            }

            let payload = data ?? Data()
            guard payload.count == header.payloadLength else {
                replayKitAudioLog.warning("[ReceiverAudio] payload rejected reason=incomplete type=\(header.rawPacketType) bytes=\(payload.count) expected=\(header.payloadLength)")
                self.receiveEnvelopeHeader(on: connection)
                return
            }

            guard header.version == ReplayKitPacketEnvelope.version else {
                replayKitAudioLog.warning("[ReceiverAudio] packet dropped reason=unsupported-version version=\(header.version) type=\(header.rawPacketType) payloadBytes=\(payload.count)")
                self.receiveEnvelopeHeader(on: connection)
                return
            }

            guard let packetType = header.packetType else {
                replayKitAudioLog.warning("[ReceiverAudio] packet dropped reason=unknown-type rawType=\(header.rawPacketType) payloadBytes=\(payload.count)")
                self.receiveEnvelopeHeader(on: connection)
                return
            }

            self.handlePacket(type: packetType, payload: payload, on: connection)
        }
    }

    private func handlePacket(type: ReplayKitPacketType, payload: Data, on connection: NWConnection) {
        switch type {
        case .audioFormat:
            handleAudioFormatPayload(payload, on: connection)
        case .audioPCM:
            handleAudioPCMPayload(payload, on: connection)
        case .audioHeartbeat:
            handleAudioHeartbeatPayload(payload)
            receiveEnvelopeHeader(on: connection)
        case .frame, .controlEvent, .heartbeat, .h264Config, .h264AccessUnit:
            replayKitAudioLog.warning("[ReceiverAudio] packet dropped reason=video-type-on-audio-channel type=\(type.diagnosticName, privacy: .public) payloadBytes=\(payload.count)")
            receiveEnvelopeHeader(on: connection)
        }
    }

    private func handleAudioFormatPayload(_ payload: Data, on connection: NWConnection) {
        replayKitAudioLog.info("[ReceiverAudio] format packet received payloadBytes=\(payload.count)")
        do {
            let formatPayload = try JSONDecoder().decode(ReplayKitAudioFormatPayload.self, from: payload)
            guard formatPayload.isSupportedForV1 else {
                replayKitAudioLog.warning("[ReceiverAudio] format rejected reason=unsupported-fields sequence=\(formatPayload.sequence) source=\(formatPayload.source, privacy: .public) sampleRate=\(formatPayload.sampleRate) channels=\(formatPayload.channelCount) commonFormat=\(formatPayload.commonFormat.rawValue, privacy: .public) interleaved=\(formatPayload.isInterleaved)")
                publishAudioState(.error, message: "Audio Error")
                receiveEnvelopeHeader(on: connection)
                return
            }

            guard let avFormat = makeAVAudioFormat(from: formatPayload) else {
                replayKitAudioLog.warning("[ReceiverAudio] format rejected reason=avformat-failed sequence=\(formatPayload.sequence) sampleRate=\(formatPayload.sampleRate) channels=\(formatPayload.channelCount) commonFormat=\(formatPayload.commonFormat.rawValue, privacy: .public) interleaved=\(formatPayload.isInterleaved)")
                publishAudioState(.error, message: "Audio Error")
                receiveEnvelopeHeader(on: connection)
                return
            }

            let shouldRebuild = currentFormatPayload != formatPayload || currentAVFormat == nil || engine == nil || player == nil
            replayKitAudioLog.info("[ReceiverAudio] format accepted sequence=\(formatPayload.sequence) sampleRate=\(formatPayload.sampleRate) channels=\(formatPayload.channelCount) sourceCommonFormat=\(formatPayload.commonFormat.rawValue, privacy: .public) sourceInterleaved=\(formatPayload.isInterleaved) playbackCommonFormat=\(avFormat.commonFormat.rawValue) playbackInterleaved=\(avFormat.isInterleaved) rebuild=\(shouldRebuild)")
            currentFormatPayload = formatPayload
            if shouldRebuild {
                rebuildPlaybackPipelineLocked(format: avFormat, formatPayload: formatPayload)
            }
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.audioSampleRate = formatPayload.sampleRate
                self.audioChannelCount = formatPayload.channelCount
                self.audioStatusMessage = "Audio Waiting"
                self.audioState = .waiting
            }
        } catch {
            replayKitAudioLog.warning("[ReceiverAudio] format rejected reason=json-decode-failed payloadBytes=\(payload.count) error=\(error.localizedDescription, privacy: .public)")
            publishAudioState(.error, message: "Audio Error")
        }

        receiveEnvelopeHeader(on: connection)
    }

    private func handleAudioPCMPayload(_ payload: Data, on connection: NWConnection) {
        guard let packet = ReplayKitAudioPCMPacket(payload: payload, maximumAudioPayloadBytes: maximumAudioPayloadBytes) else {
            replayKitAudioLog.warning("[ReceiverAudio] packet received branch=malformed payloadBytes=\(payload.count)")
            recordDroppedPacket(reason: "malformed")
            receiveEnvelopeHeader(on: connection)
            return
        }

        guard let currentAVFormat, let currentFormatPayload, let player else {
            replayKitAudioLog.warning("[ReceiverAudio] packet received branch=no-format seq=\(packet.header.sequenceNumber) payloadBytes=\(payload.count)")
            recordDroppedPacket(reason: "no format")
            receiveEnvelopeHeader(on: connection)
            return
        }

        guard packetMatchesCurrentFormat(packet, formatPayload: currentFormatPayload) else {
            replayKitAudioLog.warning("[ReceiverAudio] packet received branch=format-mismatch seq=\(packet.header.sequenceNumber) sampleRate=\(packet.header.sampleRate) channels=\(packet.header.channelCount) flags=\(packet.header.formatFlags) interleaved=\(packet.header.isInterleaved)")
            recordDroppedPacket(reason: "format mismatch")
            receiveEnvelopeHeader(on: connection)
            return
        }

        guard let buffer = makePCMBuffer(from: packet, format: currentAVFormat) else {
            replayKitAudioLog.warning("[ReceiverAudio] packet received branch=buffer-copy-failed seq=\(packet.header.sequenceNumber) payloadBytes=\(payload.count)")
            recordDroppedPacket(reason: "buffer copy failed")
            receiveEnvelopeHeader(on: connection)
            return
        }

        let sequenceResult = sequenceTracker.record(packet.header.sequenceNumber)
        logSequenceResult(sequenceResult)

        let packetArrivedAt = Date()
        let arrivalGapMilliseconds = lastAudioPacketArrivedAt
            .map { packetArrivedAt.timeIntervalSince($0) * 1000.0 } ?? -1
        lastAudioPacketArrivedAt = packetArrivedAt

        let durationMilliseconds = Double(packet.header.frameCount) / max(packet.header.sampleRate, 1) * 1000.0
        let jitterDecision = jitterBuffer.decisionForIncomingPacket(durationMilliseconds: durationMilliseconds)
        if jitterDecision == .dropForOverbuffer {
            replayKitAudioLog.warning("[ReceiverAudio] overbuffer drop seq=\(packet.header.sequenceNumber) action=drop-incoming durationMs=\(durationMilliseconds) bufferedMs=\(self.jitterBuffer.bufferedMilliseconds) capMs=\(self.jitterBuffer.capMilliseconds) arrivalGapMs=\(arrivalGapMilliseconds)")
            recordDroppedPacket(reason: "overbuffer cap", keepsPlaybackState: true)
            receiveEnvelopeHeader(on: connection)
            return
        }

        let scheduledLatency = jitterBuffer.bufferedMilliseconds
        replayKitAudioLog.info("[ReceiverAudio] packet received seq=\(packet.header.sequenceNumber) frames=\(packet.header.frameCount) bytes=\(packet.pcmBytes.count) durationMs=\(durationMilliseconds) jitterDecision=\(String(describing: jitterDecision), privacy: .public) bufferedMs=\(scheduledLatency) arrivalGapMs=\(arrivalGapMilliseconds)")
        player.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { [weak self] _ in
            self?.queue.async {
                self?.handleScheduledBufferFinished(durationMilliseconds: durationMilliseconds)
            }
        }

        if !isPlayerStarted, jitterBuffer.bufferedMilliseconds >= jitterBuffer.targetMilliseconds {
            player.play()
            isPlayerStarted = true
            replayKitAudioLog.info("[ReceiverAudio] buffer scheduled branch=start-player bufferedMs=\(self.jitterBuffer.bufferedMilliseconds) targetMs=\(self.jitterBuffer.targetMilliseconds)")
        } else if isPlayerStarted, !player.isPlaying {
            player.play()
            replayKitAudioLog.info("[ReceiverAudio] buffer scheduled branch=resume-player bufferedMs=\(self.jitterBuffer.bufferedMilliseconds)")
        } else {
            replayKitAudioLog.debug("[ReceiverAudio] buffer scheduled branch=\(self.isPlayerStarted ? "already-playing" : "holding-for-jitter", privacy: .public) bufferedMs=\(self.jitterBuffer.bufferedMilliseconds)")
        }

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            let now = Date()
            self.lastAudioPacketReceivedAt = now
            self.receivedAudioPacketCount += 1
            self.audioLatencyMilliseconds = scheduledLatency
            self.isAudioPlaying = self.isPlayerStarted
            self.audioStatusMessage = self.isPlayerStarted ? "Audio Live" : "Audio Waiting"
            self.audioState = self.isPlayerStarted ? .live : .waiting
        }

        receiveEnvelopeHeader(on: connection)
    }

    private func handleAudioHeartbeatPayload(_ payload: Data) {
        do {
            let heartbeat = try JSONDecoder().decode(ReplayKitAudioHeartbeatPayload.self, from: payload)
            replayKitAudioLog.info("[ReceiverAudio] heartbeat received sequence=\(heartbeat.sequence) senderState=\(heartbeat.senderState, privacy: .public) sent=\(heartbeat.sentAudioPackets) dropped=\(heartbeat.droppedAudioPackets) unsupported=\(heartbeat.unsupportedAudioSamples) reason=\(heartbeat.reason ?? "nil", privacy: .public) transport=\(heartbeat.transport, privacy: .public)")
        } catch {
            replayKitAudioLog.warning("[ReceiverAudio] heartbeat decode failed payloadBytes=\(payload.count) error=\(error.localizedDescription, privacy: .public)")
        }
    }

    private func makeAVAudioFormat(from payload: ReplayKitAudioFormatPayload) -> AVAudioFormat? {
        guard payload.channelCount > 0, payload.channelCount <= Int(UInt32.max) else {
            replayKitAudioLog.warning("[ReceiverAudio] makeAVAudioFormat branch=invalid-channel-count channels=\(payload.channelCount)")
            return nil
        }

        replayKitAudioLog.info("[ReceiverAudio] makeAVAudioFormat branch=normalize-to-float32 sourceCommonFormat=\(payload.commonFormat.rawValue, privacy: .public) sourceInterleaved=\(payload.isInterleaved)")
        return AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: payload.sampleRate,
            channels: AVAudioChannelCount(payload.channelCount),
            interleaved: false
        )
    }

    private func rebuildPlaybackPipelineLocked(format: AVAudioFormat, formatPayload: ReplayKitAudioFormatPayload) {
        stopPlaybackLocked(reason: "format change")

        let engine = AVAudioEngine()
        let player = AVAudioPlayerNode()
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: format)

        do {
            try engine.start()
            self.engine = engine
            self.player = player
            self.currentAVFormat = format
            self.sequenceTracker.reset()
            self.jitterBuffer.reset()
            self.isPlayerStarted = false
            self.lastPCMConversionDescription = nil
            replayKitAudioLog.info("[ReceiverAudio] engine start success sampleRate=\(formatPayload.sampleRate) channels=\(formatPayload.channelCount) sourceCommonFormat=\(formatPayload.commonFormat.rawValue, privacy: .public) sourceInterleaved=\(formatPayload.isInterleaved) playbackCommonFormat=\(format.commonFormat.rawValue) playbackInterleaved=\(format.isInterleaved)")
        } catch {
            replayKitAudioLog.error("[ReceiverAudio] engine start failure error=\(error.localizedDescription, privacy: .public)")
            self.engine = nil
            self.player = nil
            self.currentAVFormat = nil
            publishAudioState(.error, message: "Audio Error")
        }
    }

    private func stopPlaybackLocked(reason: String) {
        replayKitAudioLog.info("[ReceiverAudio] engine stop reason=\(reason, privacy: .public) enginePresent=\(self.engine != nil) playerPresent=\(self.player != nil) bufferedMs=\(self.jitterBuffer.bufferedMilliseconds)")
        player?.stop()
        engine?.stop()
        if let player, let engine {
            engine.detach(player)
        }
        player = nil
        engine = nil
        currentAVFormat = nil
        jitterBuffer.reset()
        isPlayerStarted = false
        DispatchQueue.main.async { [weak self] in
            self?.isAudioPlaying = false
            self?.audioLatencyMilliseconds = 0
        }
    }

    private func resetPlayerQueueLocked(reason: String) {
        guard let player else {
            replayKitAudioLog.info("[ReceiverAudio] overbuffer reset skipped reason=\(reason, privacy: .public) branch=no-player")
            jitterBuffer.reset()
            isPlayerStarted = false
            return
        }

        player.stop()
        isPlayerStarted = false
        recordDroppedPacket(reason: "overbuffer \(reason)")
        replayKitAudioLog.warning("[ReceiverAudio] overbuffer reset reason=\(reason, privacy: .public)")
    }

    private func packetMatchesCurrentFormat(_ packet: ReplayKitAudioPCMPacket, formatPayload: ReplayKitAudioFormatPayload) -> Bool {
        guard packet.header.commonFormat == formatPayload.commonFormat else {
            replayKitAudioLog.warning("[ReceiverAudio] packet format check branch=common-format-mismatch packet=\(packet.header.commonFormat?.rawValue ?? "nil", privacy: .public) current=\(formatPayload.commonFormat.rawValue, privacy: .public)")
            return false
        }

        guard abs(packet.header.sampleRate - formatPayload.sampleRate) < 0.5 else {
            replayKitAudioLog.warning("[ReceiverAudio] packet format check branch=sample-rate-mismatch packet=\(packet.header.sampleRate) current=\(formatPayload.sampleRate)")
            return false
        }

        guard Int(packet.header.channelCount) == formatPayload.channelCount else {
            replayKitAudioLog.warning("[ReceiverAudio] packet format check branch=channel-mismatch packet=\(packet.header.channelCount) current=\(formatPayload.channelCount)")
            return false
        }

        guard packet.header.isInterleaved == formatPayload.isInterleaved else {
            replayKitAudioLog.warning("[ReceiverAudio] packet format check branch=interleave-mismatch packet=\(packet.header.isInterleaved) current=\(formatPayload.isInterleaved)")
            return false
        }

        return true
    }

    private func makePCMBuffer(from packet: ReplayKitAudioPCMPacket, format: AVAudioFormat) -> AVAudioPCMBuffer? {
        guard format.commonFormat == .pcmFormatFloat32, !format.isInterleaved else {
            replayKitAudioLog.warning("[ReceiverAudio] buffer copy rejected reason=unsupported-playback-format playbackCommonFormat=\(format.commonFormat.rawValue) playbackInterleaved=\(format.isInterleaved)")
            return nil
        }

        guard let buffer = AVAudioPCMBuffer(
            pcmFormat: format,
            frameCapacity: AVAudioFrameCount(packet.header.frameCount)
        ) else {
            replayKitAudioLog.warning("[ReceiverAudio] buffer allocation failed seq=\(packet.header.sequenceNumber) frames=\(packet.header.frameCount)")
            return nil
        }

        buffer.frameLength = AVAudioFrameCount(packet.header.frameCount)
        guard let commonFormat = packet.header.commonFormat else {
            replayKitAudioLog.warning("[ReceiverAudio] buffer copy rejected reason=missing-common-format seq=\(packet.header.sequenceNumber) flags=\(packet.header.formatFlags)")
            return nil
        }

        let converted: Bool
        switch commonFormat {
        case .pcmFloat32:
            converted = copyFloat32PCM(packet: packet, into: buffer)
        case .pcmInt16:
            converted = copyInt16PCMAsFloat32(packet: packet, into: buffer)
        }

        guard converted else {
            return nil
        }

        logPCMConversionIfNeeded(packet: packet, playbackFormat: format)
        return buffer
    }

    private func copyInt16PCMAsFloat32(packet: ReplayKitAudioPCMPacket, into buffer: AVAudioPCMBuffer) -> Bool {
        let frameCount = Int(packet.header.frameCount)
        let channelCount = Int(packet.header.channelCount)
        let expectedByteCount = frameCount * channelCount * MemoryLayout<Int16>.size
        guard packet.pcmBytes.count == expectedByteCount else {
            replayKitAudioLog.warning("[ReceiverAudio] buffer copy rejected reason=int16-byte-count-mismatch seq=\(packet.header.sequenceNumber) expected=\(expectedByteCount) actual=\(packet.pcmBytes.count) frames=\(frameCount) channels=\(channelCount) interleaved=\(packet.header.isInterleaved)")
            return false
        }

        guard let channelData = buffer.floatChannelData else {
            replayKitAudioLog.warning("[ReceiverAudio] buffer copy rejected reason=missing-float-channel-data seq=\(packet.header.sequenceNumber)")
            return false
        }

        packet.pcmBytes.withUnsafeBytes { rawBuffer in
            guard !rawBuffer.isEmpty else { return }
            for frameIndex in 0..<frameCount {
                for channelIndex in 0..<channelCount {
                    let sampleIndex = packet.header.isInterleaved
                        ? (frameIndex * channelCount + channelIndex)
                        : (channelIndex * frameCount + frameIndex)
                    let byteOffset = sampleIndex * MemoryLayout<Int16>.size
                    let sample = rawBuffer.loadUnaligned(fromByteOffset: byteOffset, as: Int16.self)
                    channelData[channelIndex][frameIndex] = Float(sample) / 32768.0
                }
            }
        }

        return true
    }

    private func copyFloat32PCM(packet: ReplayKitAudioPCMPacket, into buffer: AVAudioPCMBuffer) -> Bool {
        let frameCount = Int(packet.header.frameCount)
        let channelCount = Int(packet.header.channelCount)
        let expectedByteCount = frameCount * channelCount * MemoryLayout<Float>.size
        guard packet.pcmBytes.count == expectedByteCount else {
            replayKitAudioLog.warning("[ReceiverAudio] buffer copy rejected reason=float32-byte-count-mismatch seq=\(packet.header.sequenceNumber) expected=\(expectedByteCount) actual=\(packet.pcmBytes.count) frames=\(frameCount) channels=\(channelCount) interleaved=\(packet.header.isInterleaved)")
            return false
        }

        guard let channelData = buffer.floatChannelData else {
            replayKitAudioLog.warning("[ReceiverAudio] buffer copy rejected reason=missing-float-channel-data seq=\(packet.header.sequenceNumber)")
            return false
        }

        packet.pcmBytes.withUnsafeBytes { rawBuffer in
            guard !rawBuffer.isEmpty else { return }
            for frameIndex in 0..<frameCount {
                for channelIndex in 0..<channelCount {
                    let sampleIndex = packet.header.isInterleaved
                        ? (frameIndex * channelCount + channelIndex)
                        : (channelIndex * frameCount + frameIndex)
                    let byteOffset = sampleIndex * MemoryLayout<Float>.size
                    channelData[channelIndex][frameIndex] = rawBuffer.loadUnaligned(fromByteOffset: byteOffset, as: Float.self)
                }
            }
        }

        return true
    }

    private func logPCMConversionIfNeeded(packet: ReplayKitAudioPCMPacket, playbackFormat: AVAudioFormat) {
        let sourceFormat = packet.header.commonFormat?.rawValue ?? "unknown"
        let sourceLayout = packet.header.isInterleaved ? "interleaved" : "noninterleaved"
        let playbackLayout = playbackFormat.isInterleaved ? "interleaved" : "noninterleaved"
        let description = "\(sourceFormat)-\(sourceLayout)->\(playbackFormat.commonFormat.rawValue)-\(playbackLayout)"
        guard description != lastPCMConversionDescription else { return }

        lastPCMConversionDescription = description
        replayKitAudioLog.info("[ReceiverAudio] buffer copy conversion=\(description, privacy: .public) frames=\(packet.header.frameCount) channels=\(packet.header.channelCount) sourceBytes=\(packet.pcmBytes.count) bytesPerFrame=\(packet.header.bytesPerFrame)")
    }

    private func handleScheduledBufferFinished(durationMilliseconds: Double) {
        jitterBuffer.markScheduledDurationFinished(durationMilliseconds)
        let buffered = jitterBuffer.bufferedMilliseconds
        replayKitAudioLog.debug("[ReceiverAudio] buffer playback finished durationMs=\(durationMilliseconds) remainingBufferedMs=\(buffered)")
        DispatchQueue.main.async { [weak self] in
            self?.audioLatencyMilliseconds = buffered
        }
    }

    private func handleClientDisconnect(_ disconnectedConnection: NWConnection, reason: String) {
        queue.async { [weak self] in
            guard let self else { return }
            guard self.connection === disconnectedConnection else {
                replayKitAudioLog.info("[ReceiverAudio] disconnect ignored reason=stale details=\(reason, privacy: .public)")
                return
            }

            replayKitAudioLog.info("[ReceiverAudio] connection disconnected reason=\(reason, privacy: .public)")
            self.connection?.cancel()
            self.connection = nil
            self.sequenceTracker.reset()
            self.stopPlaybackLocked(reason: "client disconnect")
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.isClientConnected = false
                self.isAudioPlaying = false
                self.audioStatusMessage = self.isListening ? "Audio Waiting" : "Audio Off"
                self.audioState = self.isListening ? .waiting : .off
            }
        }
    }

    private func startBonjourAdvertisementLocked() {
        guard bonjourService == nil else {
            replayKitAudioLog.info("[ReceiverAudio] Bonjour publish skipped reason=already-active")
            return
        }

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            guard self.bonjourService == nil else {
                replayKitAudioLog.info("[ReceiverAudio] Bonjour publish skipped on main reason=already-active")
                return
            }

            let service = NetService(domain: "local.", type: Self.bonjourType, name: Self.bonjourName, port: Int32(self.port))
            service.delegate = self
            service.includesPeerToPeer = true
            self.bonjourService = service
            service.publish(options: [])
            replayKitAudioLog.info("[ReceiverAudio] Bonjour publish requested type=\(Self.bonjourType, privacy: .public) name=\(Self.bonjourName, privacy: .public) port=\(self.port) peerToPeer=true")
        }
    }

    private func startSilenceMonitorLocked() {
        guard silenceTimer == nil else {
            replayKitAudioLog.info("[ReceiverAudio] silence monitor skipped reason=already-running")
            return
        }

        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + ReplayKitAudioConstants.silenceTimeoutSeconds, repeating: 1.0)
        timer.setEventHandler { [weak self] in
            self?.evaluateSilenceTimeoutLocked()
        }
        silenceTimer = timer
        timer.resume()
        replayKitAudioLog.info("[ReceiverAudio] silence monitor started timeoutSeconds=\(ReplayKitAudioConstants.silenceTimeoutSeconds)")
    }

    private func evaluateSilenceTimeoutLocked() {
        let lastPacket = DispatchQueue.main.sync { lastAudioPacketReceivedAt }
        guard let lastPacket else {
            replayKitAudioLog.debug("[ReceiverAudio] underrun check branch=no-packet-yet listening=\(self.listener != nil) connected=\(self.connection != nil)")
            return
        }

        let age = Date().timeIntervalSince(lastPacket)
        guard age >= ReplayKitAudioConstants.silenceTimeoutSeconds else {
            replayKitAudioLog.debug("[ReceiverAudio] underrun check branch=recent-audio age=\(age)")
            return
        }

        replayKitAudioLog.warning("[ReceiverAudio] underrun age=\(age) threshold=\(ReplayKitAudioConstants.silenceTimeoutSeconds) bufferedMs=\(self.jitterBuffer.bufferedMilliseconds)")
        if isPlayerStarted {
            player?.pause()
            isPlayerStarted = false
        }
        jitterBuffer.reset()
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.isAudioPlaying = false
            self.audioLatencyMilliseconds = 0
            self.audioStatusMessage = "Audio Waiting"
            self.audioState = .waiting
        }
    }

    private func recordDroppedPacket(reason: String, keepsPlaybackState: Bool = false) {
        replayKitAudioLog.warning("[ReceiverAudio] packet dropped reason=\(reason, privacy: .public) keepsPlaybackState=\(keepsPlaybackState)")
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.droppedAudioPacketCount += 1
            if !keepsPlaybackState, self.audioState != .error {
                self.audioStatusMessage = "Audio Waiting"
                self.audioState = self.isListening ? .waiting : .off
            }
        }
    }

    private func resetSessionStateLocked(reason: String) {
        replayKitAudioLog.info("[ReceiverAudio] session reset reason=\(reason, privacy: .public)")
        sequenceTracker.reset()
        jitterBuffer.reset()
        lastAudioPacketArrivedAt = nil
        currentFormatPayload = nil
        currentAVFormat = nil
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.isClientConnected = false
            self.isAudioPlaying = false
            self.lastAudioPacketReceivedAt = nil
            self.receivedAudioPacketCount = 0
            self.droppedAudioPacketCount = 0
            self.audioSampleRate = 0
            self.audioChannelCount = 0
            self.audioLatencyMilliseconds = 0
            self.audioStatusMessage = reason == "stop" ? "Audio Off" : "Audio Waiting"
            self.audioState = reason == "stop" ? .off : .waiting
        }
    }

    private func publishAudioState(_ state: ReplayKitAudioStreamState, message: String) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.audioState = state
            self.audioStatusMessage = message
            self.isAudioPlaying = state == .live
        }
    }

    private func logSequenceResult(_ result: ReplayKitSequenceRecordResult) {
        switch result {
        case .first(let current):
            replayKitAudioLog.info("[ReceiverAudio] sequence first current=\(current)")
        case .inOrder(let previous, let current):
            replayKitAudioLog.debug("[ReceiverAudio] sequence in-order previous=\(previous) current=\(current)")
        case .gap(let previous, let current):
            replayKitAudioLog.warning("[ReceiverAudio] sequence gap previous=\(previous) current=\(current)")
        case .nonMonotonic(let previous, let current):
            replayKitAudioLog.warning("[ReceiverAudio] sequence nonmonotonic previous=\(previous) current=\(current)")
        }
    }
}

extension ReplayKitAudioStreamManager: NetServiceDelegate {
    func netServiceDidPublish(_ sender: NetService) {
        replayKitAudioLog.info("[ReceiverAudio] Bonjour published name=\(sender.name, privacy: .public) type=\(sender.type, privacy: .public) port=\(sender.port)")
    }

    func netService(_ sender: NetService, didNotPublish errorDict: [String: NSNumber]) {
        replayKitAudioLog.error("[ReceiverAudio] Bonjour publish failed name=\(sender.name, privacy: .public) error=\(String(describing: errorDict), privacy: .public)")
        publishAudioState(.error, message: "Audio Error")
    }
}
