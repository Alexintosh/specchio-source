import AppKit
import CoreGraphics
import Foundation
import ImageIO
import Network
import QuartzCore

private let replayKitLog = SpecchioLogger.replayKit

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

    static func resolve(receiver: ReplayKitTransport, sender: ReplayKitTransport) -> ReplayKitTransport {
        if receiver == .wifi || sender == .wifi {
            return .wifi
        }

        if receiver == .usb && sender == .usb {
            return .usb
        }

        if receiver == .cellular || sender == .cellular {
            return .cellular
        }

        if receiver == .other || sender == .other {
            return .other
        }

        return .unknown
    }
}

private enum ReplayKitReceiverPolicy {
    static let currentJPEGFramesPerSecond: Double = 15
    static let legacyCompatibilityReason = "all ReplayKit transports allowed; paywall handled by Mac UI"
}

struct ReplayKitFrameHeader: Equatable {
    static let byteCount = 18

    let timestamp: UInt64
    let width: UInt16
    let height: UInt16
    let quality: UInt8
    let orientation: UInt8
    let jpegSize: UInt32

    init?(data: Data) {
        guard data.count == Self.byteCount else {
            replayKitLog.error("[FrameHeader] invalid header length: \(data.count), expected \(Self.byteCount)")
            return nil
        }

        timestamp = Self.readUInt64(data, at: 0)
        width = Self.readUInt16(data, at: 8)
        height = Self.readUInt16(data, at: 10)
        quality = data[12]
        orientation = data[13]
        jpegSize = Self.readUInt32(data, at: 14)
    }

    private static func readUInt16(_ data: Data, at offset: Int) -> UInt16 {
        UInt16(data[offset]) << 8 | UInt16(data[offset + 1])
    }

    private static func readUInt32(_ data: Data, at offset: Int) -> UInt32 {
        UInt32(data[offset]) << 24
            | UInt32(data[offset + 1]) << 16
            | UInt32(data[offset + 2]) << 8
            | UInt32(data[offset + 3])
    }

    private static func readUInt64(_ data: Data, at offset: Int) -> UInt64 {
        var value: UInt64 = 0
        for index in offset..<(offset + 8) {
            value = (value << 8) | UInt64(data[index])
        }
        return value
    }
}

enum ReplayKitStaleReason: Equatable {
    case noFramesAfterConnect
    case frameTimeout
    case heartbeatWithoutVideo
    case senderReported(String?)

    var diagnosticDescription: String {
        switch self {
        case .noFramesAfterConnect:
            return "noFramesAfterConnect"
        case .frameTimeout:
            return "frameTimeout"
        case .heartbeatWithoutVideo:
            return "heartbeatWithoutVideo"
        case .senderReported(let reason):
            return "senderReported(\(reason ?? "no reason"))"
        }
    }
}

enum ReplayKitStreamHealth: Equatable {
    case idle
    case listening
    case connecting
    case live
    case stale(reason: ReplayKitStaleReason, lastFrameAge: TimeInterval)
    case broadcastPaused
    case broadcastEnded(reason: String?)
    case disconnected(reason: String)
    case failed(reason: String)

    var diagnosticDescription: String {
        switch self {
        case .idle:
            return "idle"
        case .listening:
            return "listening"
        case .connecting:
            return "connecting"
        case .live:
            return "live"
        case .stale(let reason, let lastFrameAge):
            return "stale(reason=\(reason.diagnosticDescription), lastFrameAge=\(String(format: "%.1f", lastFrameAge)))"
        case .broadcastPaused:
            return "broadcastPaused"
        case .broadcastEnded(let reason):
            return "broadcastEnded(reason=\(reason ?? "none"))"
        case .disconnected(let reason):
            return "disconnected(reason=\(reason))"
        case .failed(let reason):
            return "failed(reason=\(reason))"
        }
    }
}

struct ReplayKitControlEvent: Equatable, Decodable {
    let event: String
    let sequence: Int?
    let receivedVideoFrames: Int?
    let sentVideoFrames: Int?
    let reason: String?
    let timestamp: Double?
    let transport: String?
    let maxFramesPerSecond: Double?
    let videoOrientation: ReplayKitVideoOrientationSnapshot?

    var diagnosticDescription: String {
        let sequenceText = sequence.map { String($0) } ?? "nil"
        let receivedText = receivedVideoFrames.map { String($0) } ?? "nil"
        let sentText = sentVideoFrames.map { String($0) } ?? "nil"
        let timestampText = timestamp.map { String($0) } ?? "nil"
        let maxFPSText = maxFramesPerSecond.map { String(format: "%.1f", $0) } ?? "nil"
        let orientationText = videoOrientation.map {
            "device=\($0.deviceOrientationName)/\($0.deviceAxis) video=\($0.videoOrientationName ?? "nil")/\($0.videoOrientationAxis ?? "nil") frame=\($0.frameWidth)x\($0.frameHeight)/\($0.videoFrameAxis)"
        } ?? "nil"
        return "event=\(event) sequence=\(sequenceText) receivedVideoFrames=\(receivedText) sentVideoFrames=\(sentText) reason=\(reason ?? "nil") timestamp=\(timestampText) transport=\(transport ?? "nil") maxFPS=\(maxFPSText) orientation=\(orientationText)"
    }
}

final class ReplayKitScreenStreamManager: NSObject, ObservableObject {
    static let defaultPort: UInt16 = 9500
    static let bonjourType = "_specchio-replaykit._tcp."

    @Published var currentFrame: CGImage?
    @Published var isListening = false
    @Published var isClientConnected = false
    @Published var currentFPS: Double = 0
    @Published var statusMessage = "Idle"
    @Published var lastFrameSize: CGSize?
    @Published var receiverDecodeMilliseconds: Double = 0
    @Published var receiverPublishDelayMilliseconds: Double = 0
    @Published var streamHealth: ReplayKitStreamHealth = .idle
    @Published var lastFrameReceivedAt: Date?
    @Published var clientConnectedAt: Date?
    @Published var lastControlEventAt: Date?
    @Published var lastBroadcastEvent: ReplayKitControlEvent?
    @Published var lastVideoOrientation: ReplayKitVideoOrientationSnapshot?
    @Published var lastDisconnectReason: String?
    @Published var usesProtocolEnvelope = false
    @Published var legacyFrameCount = 0
    @Published var envelopeFrameCount = 0
    @Published var controlEventCount = 0
    @Published var heartbeatCount = 0
    @Published var frameAgeSeconds: TimeInterval?
    @Published var receiverTransport: ReplayKitTransport = .unknown
    @Published var senderTransport: ReplayKitTransport = .unknown
    @Published var resolvedTransport: ReplayKitTransport = .unknown
    @Published var activeVideoCodec: ReplayKitActiveVideoCodec = .unknown
    @Published var receivedH264AccessUnitCount = 0
    @Published var receivedH264KeyframeCount = 0
    @Published var h264DecoderStatus = "waiting for H.264 config"
    @Published var lastVideoCodecConfigAt: Date?
    @Published var lastVideoPacketReceivedAt: Date?

    let audioStream = ReplayKitAudioStreamManager()
    let port: UInt16

    private let maximumJPEGFrameBytes = 20 * 1024 * 1024
    private let maximumEnvelopePayloadBytes = 20 * 1024 * 1024
    private let maximumH264EnvelopePayloadBytes = ReplayKitH264AccessUnitHeader.byteCount + ReplayKitH264Constants.maximumAccessUnitBytes
    private let envelopeHeaderByteCount = ReplayKitPacketEnvelope.headerByteCount
    private let envelopeMagic = ReplayKitPacketEnvelope.magic
    private let envelopeVersion = ReplayKitPacketEnvelope.version
    private let staleFrameThresholdSeconds: TimeInterval = 3.0
    private let fpsSampleIntervalSeconds: TimeInterval = 1.0
    private let fpsRollingWindowSeconds: TimeInterval = 1.0
    private let fpsLogIntervalSeconds: TimeInterval = 1.0
    private let queue = DispatchQueue(label: "com.alexintosh.Specchio.replaykit.stream", qos: .userInteractive)
    private lazy var h264Decoder = ReplayKitH264VideoDecoder(callbackQueue: queue)
    private var listener: NWListener?
    private var connection: NWConnection?
    private var bonjourService: NetService?
    private var fpsTimer: Timer?
    private var fpsFrameTimestamps: [Date] = []
    private var lastFPSLogAt = Date.distantPast
    private var staleTimer: Timer?
    private var receivedFrameCount = 0
    private var lastMetricsLogTime = Date.distantPast
    private var receiverVideoMetricsWindowStartedAt = Date()
    private var receiverMetricsH264Packets = 0
    private var receiverMetricsH264PacketBytes = 0
    private var receiverMetricsH264Keyframes = 0
    private var receiverMetricsH264DecodedFrames = 0
    private var receiverMetricsJPEGFrames = 0
    private var receiverMetricsJPEGBytes = 0
    private var receiverMetricsParserDrops = 0
    private var receiverMetricsH264DecoderDrops = 0
    private var receiverMetricsH264SequenceDrops = 0
    private var receiverMetricsJPEGDecodeDrops = 0
    private var detectedReceiverTransport: ReplayKitTransport = .unknown
    private var reportedSenderTransport: ReplayKitTransport = .unknown
    private var lastH264AccessUnitSequence: UInt64?
    private var h264TargetFramesPerSecond: Double

    init(port: UInt16 = ReplayKitScreenStreamManager.defaultPort) {
        self.port = port
        let storedTargetFPS = UserDefaults.standard.object(
            forKey: AppSettings.Keys.easyReplayKitH264TargetFPS
        ) as? NSNumber
        self.h264TargetFramesPerSecond = AppSettings.sanitizedEasyReplayKitH264TargetFPS(
            storedTargetFPS?.doubleValue ?? AppSettings.Defaults.easyReplayKitH264TargetFPS
        )
        super.init()
        replayKitLog.info("[ReplayKitPolicy] initialized H.264 target FPS value=\(self.h264TargetFramesPerSecond)")
    }

    func updateH264TargetFramesPerSecond(_ rawValue: Double, source: String) {
        let targetFPS = AppSettings.sanitizedEasyReplayKitH264TargetFPS(rawValue)
        replayKitLog.info("[ReplayKitPolicy] H.264 target FPS update requested source=\(source, privacy: .public) raw=\(rawValue) sanitized=\(targetFPS)")
        queue.async { [weak self] in
            guard let self else { return }
            let previousFPS = self.h264TargetFramesPerSecond
            guard previousFPS != targetFPS else {
                replayKitLog.info("[ReplayKitPolicy] H.264 target FPS unchanged source=\(source, privacy: .public) value=\(targetFPS)")
                return
            }

            self.h264TargetFramesPerSecond = targetFPS
            let effectiveFPS = self.effectiveH264TargetFramesPerSecond()
            replayKitLog.info("[ReplayKitPolicy] H.264 target FPS applied source=\(source, privacy: .public) previous=\(previousFPS) next=\(targetFPS) effective=\(effectiveFPS) listenerActive=\(self.listener != nil) clientActive=\(self.connection != nil)")
            self.publishReceiverPolicy(trigger: "H.264 target FPS changed")

            let txtRecord = self.replayKitPolicyTXTRecordData()
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                guard let bonjourService = self.bonjourService else {
                    replayKitLog.info("[ReplayKitPolicy] Bonjour policy refresh skipped source=\(source, privacy: .public) reason=no-active-service h264FPS=\(targetFPS)")
                    return
                }
                bonjourService.setTXTRecord(txtRecord)
                replayKitLog.info("[ReplayKitPolicy] Bonjour policy refreshed source=\(source, privacy: .public) configuredH264FPS=\(targetFPS) effectiveH264FPS=\(effectiveFPS)")
            }
        }
    }

    private func effectiveH264TargetFramesPerSecond() -> Double {
        AppSettings.sanitizedEasyReplayKitH264TargetFPS(h264TargetFramesPerSecond)
    }

    private func updateReplayKitAudioStream(trigger: String) {
        guard listener != nil || isListening else {
            replayKitLog.info("[ReceiverAudio] start skipped trigger=\(trigger, privacy: .public) branch=video-listener-not-active")
            return
        }

        replayKitLog.info("[ReceiverAudio] start requested trigger=\(trigger, privacy: .public)")
        audioStream.startListening()
    }

    func startListening() {
        replayKitLog.info("[Receiver] startListening requested on port \(self.port)")
        replayKitLog.info("[ReceiverAudio] grouped lifecycle start requested with video receiver audioPort=\(self.audioStream.port)")
        FrameDropDiagnostics.shared.recordLifecycle(
            source: "replayKit",
            event: "startListening",
            reason: "receiver requested",
            details: replayKitDiagnosticDetails(["port": String(port)])
        )
        queue.async { [weak self] in
            guard let self else { return }

            guard self.listener == nil else {
                replayKitLog.info("[Receiver] listener already exists; keeping current listener")
                self.updateReplayKitAudioStream(trigger: "startListening already active")
                self.publishStatus("Listening on \(self.port)")
                self.publishHealth(.listening, trigger: "startListening listener already exists")
                return
            }

            self.detectedReceiverTransport = .unknown
            self.reportedSenderTransport = .unknown
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.receiverTransport = .unknown
                self.senderTransport = .unknown
                self.resolvedTransport = .unknown
                self.lastDisconnectReason = nil
                self.lastVideoOrientation = nil
                self.activeVideoCodec = .unknown
                self.receivedH264AccessUnitCount = 0
                self.receivedH264KeyframeCount = 0
                self.h264DecoderStatus = "waiting for H.264 config"
                self.lastVideoCodecConfigAt = nil
                self.lastVideoPacketReceivedAt = nil
                self.resetReceiverVideoMetrics(reason: "startListening")
                self.updateFrameAge(now: Date())
            }

            guard let nwPort = NWEndpoint.Port(rawValue: self.port) else {
                replayKitLog.error("[Receiver] invalid TCP port \(self.port)")
                self.publishStatus("Invalid port \(self.port)")
                self.publishHealth(.failed(reason: "invalid TCP port \(self.port)"), trigger: "startListening invalid port")
                return
            }

            do {
                let listener = try NWListener(using: .tcp, on: nwPort)
                self.listener = listener
                replayKitLog.info("[Receiver] NWListener created")
                self.updateReplayKitAudioStream(trigger: "startListening listener created")

                listener.stateUpdateHandler = { [weak self] state in
                    self?.handleListenerState(state)
                }

                listener.newConnectionHandler = { [weak self] newConnection in
                    self?.accept(newConnection)
                }

                listener.start(queue: self.queue)
                self.startFPSCounter()
                self.startStaleDetectionTimer()
            } catch {
                replayKitLog.error("[Receiver] failed to create listener: \(error.localizedDescription)")
                self.publishStatus("Receiver failed: \(error.localizedDescription)")
                self.publishHealth(.failed(reason: error.localizedDescription), trigger: "startListening listener creation failed")
            }
        }
    }

    func stop() {
        replayKitLog.info("[Receiver] stop requested")
        replayKitLog.info("[ReceiverAudio] grouped lifecycle stop requested with video receiver")
        FrameDropDiagnostics.shared.recordLifecycle(
            source: "replayKit",
            event: "stopRequested",
            reason: "receiver requested",
            details: replayKitDiagnosticDetails(["port": String(port)])
        )
        audioStream.stop()
        queue.async { [weak self] in
            guard let self else { return }

            if self.connection == nil {
                replayKitLog.info("[Receiver] stop: no active client connection")
            } else {
                replayKitLog.info("[Receiver] stop: cancelling active client connection")
            }
            self.connection?.cancel()
            self.connection = nil
            self.detectedReceiverTransport = .unknown
            self.reportedSenderTransport = .unknown
            self.lastH264AccessUnitSequence = nil
            self.h264Decoder.reset(reason: "receiver stop")

            if self.listener == nil {
                replayKitLog.info("[Receiver] stop: no active listener")
            } else {
                replayKitLog.info("[Receiver] stop: cancelling listener")
            }
            self.listener?.cancel()
            self.listener = nil

            if self.bonjourService == nil {
                replayKitLog.info("[Receiver] stop: no Bonjour service to stop")
            } else {
                replayKitLog.info("[Receiver] stop: stopping Bonjour service")
            }
            self.bonjourService?.stop()
            self.bonjourService = nil

            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.fpsTimer?.invalidate()
                self.fpsTimer = nil
                self.resetFPSCounterState(reason: "receiver stop")
                self.staleTimer?.invalidate()
                self.staleTimer = nil
                self.isListening = false
                self.isClientConnected = false
                self.clientConnectedAt = nil
                self.currentFPS = 0
                self.statusMessage = "Stopped"
                self.receiverTransport = .unknown
                self.senderTransport = .unknown
                self.resolvedTransport = .unknown
                self.lastVideoOrientation = nil
                self.activeVideoCodec = .unknown
                self.receivedH264AccessUnitCount = 0
                self.receivedH264KeyframeCount = 0
                self.h264DecoderStatus = "waiting for H.264 config"
                self.lastVideoCodecConfigAt = nil
                self.lastVideoPacketReceivedAt = nil
                self.resetReceiverVideoMetrics(reason: "receiver stop")
                self.updateFrameAge(now: Date())
                self.transitionHealth(.idle, trigger: "stop requested")
            }
        }
    }

    private func handleListenerState(_ state: NWListener.State) {
        switch state {
        case .setup:
            replayKitLog.info("[Receiver] listener state=setup")
            publishStatus("Preparing receiver")
            publishHealth(.idle, trigger: "listener state setup")
        case .ready:
            replayKitLog.info("[Receiver] listener ready on port \(self.port)")
            DispatchQueue.main.async { [weak self] in
                self?.isListening = true
                self?.statusMessage = "Listening on \(self?.port ?? 0)"
            }
            publishHealth(.listening, trigger: "listener ready")
            startBonjourAdvertisement()
        case .waiting(let error):
            replayKitLog.warning("[Receiver] listener waiting: \(error.localizedDescription)")
            publishStatus("Waiting: \(error.localizedDescription)")
            publishHealth(.failed(reason: "listener waiting: \(error.localizedDescription)"), trigger: "listener waiting")
        case .failed(let error):
            replayKitLog.error("[Receiver] listener failed: \(error.localizedDescription)")
            publishStatus("Receiver failed: \(error.localizedDescription)")
            publishHealth(.failed(reason: error.localizedDescription), trigger: "listener failed")
            listener?.cancel()
            listener = nil
            DispatchQueue.main.async { [weak self] in
                self?.isListening = false
            }
        case .cancelled:
            replayKitLog.info("[Receiver] listener cancelled")
            publishStatus("Stopped")
            publishHealth(.idle, trigger: "listener cancelled")
            DispatchQueue.main.async { [weak self] in
                self?.isListening = false
            }
        @unknown default:
            replayKitLog.warning("[Receiver] listener entered unknown state")
            publishStatus("Unknown receiver state")
        }
    }

    private func accept(_ newConnection: NWConnection) {
        replayKitLog.info("[Receiver] incoming ReplayKit TCP connection")
        FrameDropDiagnostics.shared.recordLifecycle(
            source: "replayKit",
            event: "clientAccepted",
            reason: "incoming ReplayKit TCP connection",
            details: replayKitDiagnosticDetails(["port": String(port)])
        )

        if connection == nil {
            replayKitLog.info("[Receiver] no existing client; accepting connection")
        } else {
            replayKitLog.info("[Receiver] replacing existing client connection")
        }
        connection?.cancel()
        connection = newConnection
        detectedReceiverTransport = .unknown
        reportedSenderTransport = .unknown
        lastH264AccessUnitSequence = nil
        h264Decoder.reset(reason: "new client connection")
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.resetFPSCounterState(reason: "new client connection")
            self.lastVideoOrientation = nil
            self.activeVideoCodec = .unknown
            self.receivedH264AccessUnitCount = 0
            self.receivedH264KeyframeCount = 0
            self.h264DecoderStatus = "waiting for H.264 config"
            self.lastVideoCodecConfigAt = nil
            self.lastVideoPacketReceivedAt = nil
            self.resetReceiverVideoMetrics(reason: "new client connection")
        }

        newConnection.stateUpdateHandler = { [weak self, weak newConnection] state in
            guard let self, let newConnection else { return }
            self.handleConnectionState(state, connection: newConnection)
        }

        newConnection.start(queue: queue)
    }

    private func handleConnectionState(_ state: NWConnection.State, connection: NWConnection) {
        switch state {
        case .setup:
            replayKitLog.info("[Receiver] client state=setup")
            publishStatus("Client preparing")
            publishHealth(.connecting, trigger: "client state setup")
        case .preparing:
            replayKitLog.info("[Receiver] client state=preparing")
            publishStatus("Client preparing")
            publishHealth(.connecting, trigger: "client state preparing")
        case .ready:
            let transport = connection.currentPath.map { ReplayKitTransport.detect(from: $0) } ?? .unknown
            detectedReceiverTransport = transport
            replayKitLog.info("[ReplayKitTransport] receiver path=\(transport.rawValue, privacy: .public)")
            publishReceiverPolicy(trigger: "client ready")
            DispatchQueue.main.async { [weak self] in
                self?.isClientConnected = true
                self?.clientConnectedAt = Date()
                self?.statusMessage = "iPhone stream connected"
            }
            publishHealth(.connecting, trigger: "client ready")
            receivePacketPrefix(on: connection)
        case .waiting(let error):
            replayKitLog.warning("[Receiver] client waiting: \(error.localizedDescription)")
            publishStatus("Client waiting: \(error.localizedDescription)")
            publishHealth(.connecting, trigger: "client waiting: \(error.localizedDescription)")
        case .failed(let error):
            replayKitLog.error("[Receiver] client failed: \(error.localizedDescription)")
            handleClientDisconnect(connection, reason: "failed: \(error.localizedDescription)")
        case .cancelled:
            replayKitLog.info("[Receiver] client cancelled")
            handleClientDisconnect(connection, reason: "cancelled")
        @unknown default:
            replayKitLog.warning("[Receiver] client entered unknown state")
            publishStatus("Unknown client state")
        }
    }

    private func receivePacketPrefix(on connection: NWConnection) {
        guard connection === self.connection else {
            replayKitLog.info("[ReceiverParser] prefix receive ignored for stale connection")
            return
        }

        connection.receive(
            minimumIncompleteLength: envelopeHeaderByteCount,
            maximumLength: envelopeHeaderByteCount
        ) { [weak self, weak connection] data, _, isComplete, error in
            guard let self, let connection else { return }

            if let error {
                replayKitLog.error("[ReceiverParser] prefix receive failed: \(error.localizedDescription)")
                self.handleClientDisconnect(connection, reason: "prefix error: \(error.localizedDescription)")
                return
            }

            if isComplete {
                replayKitLog.info("[ReceiverParser] prefix receive completed by peer")
                self.handleClientDisconnect(connection, reason: "peer closed before packet prefix")
                return
            }

            guard let data else {
                replayKitLog.warning("[ReceiverParser] prefix receive returned nil data; continuing")
                self.receivePacketPrefix(on: connection)
                return
            }

            guard data.count == self.envelopeHeaderByteCount else {
                replayKitLog.warning("[ReceiverParser] malformed prefix bytes=\(data.count), expected=\(self.envelopeHeaderByteCount); continuing")
                self.receivePacketPrefix(on: connection)
                return
            }

            if data.prefix(4) == self.envelopeMagic {
                self.handleEnvelopeHeader(data, on: connection)
            } else {
                replayKitLog.info("[ReceiverParser] legacy-frame-path selected; prefixMagic=\(data.prefix(4).map { String(format: "%02X", $0) }.joined())")
                self.receiveLegacyHeaderRemainder(prefix: data, on: connection)
            }
        }
    }

    private func handleEnvelopeHeader(_ data: Data, on connection: NWConnection) {
        let version = data[4]
        let packetType = data[5]
        let payloadLength = Int(Self.readUInt32(data, at: 6))

        replayKitLog.debug("[ReceiverParser] envelope header version=\(version) type=\(packetType) length=\(payloadLength)")

        guard version == envelopeVersion else {
            replayKitLog.warning("[ReceiverParser] unsupported envelope version=\(version), expected=\(self.envelopeVersion); dropping packet")
            recordReplayKitDrop(
                stage: "parser",
                reason: "unsupported envelope version",
                details: [
                    "version": String(version),
                    "expectedVersion": String(envelopeVersion),
                    "packetType": String(packetType),
                    "payloadBytes": String(payloadLength)
                ],
                metric: "parser"
            )
            receivePacketPrefix(on: connection)
            return
        }

        guard payloadLength >= 0, payloadLength <= maximumEnvelopePayloadBytes else {
            replayKitLog.error("[ReceiverParser] envelope payload too large length=\(payloadLength), max=\(self.maximumEnvelopePayloadBytes)")
            recordReplayKitDrop(
                stage: "parser",
                reason: "envelope payload too large",
                details: [
                    "packetType": String(packetType),
                    "payloadBytes": String(payloadLength),
                    "maximumEnvelopePayloadBytes": String(maximumEnvelopePayloadBytes)
                ],
                metric: "parser"
            )
            handleClientDisconnect(connection, reason: "envelope payload too large")
            return
        }

        if packetType == ReplayKitPacketType.h264AccessUnit.rawValue, payloadLength > maximumH264EnvelopePayloadBytes {
            replayKitLog.error("[ReceiverParser] h264 access unit payload too large length=\(payloadLength), max=\(self.maximumH264EnvelopePayloadBytes)")
            recordReplayKitDrop(
                stage: "parser",
                reason: "h264 access unit payload too large",
                details: [
                    "payloadBytes": String(payloadLength),
                    "maximumH264EnvelopePayloadBytes": String(maximumH264EnvelopePayloadBytes)
                ],
                metric: "parser"
            )
            handleClientDisconnect(connection, reason: "h264 access unit payload too large")
            return
        }

        guard payloadLength > 0 else {
            replayKitLog.warning("[ReceiverParser] envelope payload empty type=\(packetType); dropping")
            recordReplayKitDrop(
                stage: "parser",
                reason: "empty envelope payload",
                details: ["packetType": String(packetType)],
                metric: "parser"
            )
            receivePacketPrefix(on: connection)
            return
        }

        connection.receive(minimumIncompleteLength: payloadLength, maximumLength: payloadLength) { [weak self, weak connection] data, _, isComplete, error in
            guard let self, let connection else { return }

            if let error {
                replayKitLog.error("[ReceiverParser] envelope payload receive failed: \(error.localizedDescription)")
                self.handleClientDisconnect(connection, reason: "envelope payload error: \(error.localizedDescription)")
                return
            }

            if isComplete {
                replayKitLog.info("[ReceiverParser] envelope payload receive completed by peer")
                self.handleClientDisconnect(connection, reason: "peer closed before envelope payload")
                return
            }

            let payload = data ?? Data()
            guard payload.count == payloadLength else {
                replayKitLog.warning("[ReceiverParser] incomplete envelope payload type=\(packetType) bytes=\(payload.count), expected=\(payloadLength); dropping")
                self.recordReplayKitDrop(
                    stage: "parser",
                    reason: "incomplete envelope payload",
                    details: [
                        "packetType": String(packetType),
                        "receivedBytes": String(payload.count),
                        "expectedBytes": String(payloadLength)
                    ],
                    metric: "parser"
                )
                self.receivePacketPrefix(on: connection)
                return
            }

            DispatchQueue.main.async { [weak self] in
                self?.usesProtocolEnvelope = true
            }

            guard let typedPacket = ReplayKitPacketType(rawValue: packetType) else {
                replayKitLog.warning("[ReceiverParser] unknown envelope packet type=\(packetType); payloadBytes=\(payload.count); dropping")
                self.recordReplayKitDrop(
                    stage: "parser",
                    reason: "unknown envelope packet type",
                    details: [
                        "packetType": String(packetType),
                        "payloadBytes": String(payload.count)
                    ],
                    metric: "parser"
                )
                self.receivePacketPrefix(on: connection)
                return
            }

            switch typedPacket {
            case .frame:
                self.handleFramePacketPayload(payload, pathName: "envelope-frame-path", on: connection)
            case .controlEvent:
                self.handleControlPayload(payload, packetKind: "control")
                self.receivePacketPrefix(on: connection)
            case .heartbeat:
                self.handleControlPayload(payload, packetKind: "heartbeat")
                self.receivePacketPrefix(on: connection)
            case .h264Config:
                self.handleH264ConfigPayload(payload, on: connection)
            case .h264AccessUnit:
                self.handleH264AccessUnitPayload(payload, on: connection)
            case .audioFormat, .audioPCM, .audioHeartbeat:
                replayKitLog.warning("[ReceiverParser] audio packet type=\(typedPacket.diagnosticName, privacy: .public) arrived on video connection; payloadBytes=\(payload.count); dropping")
                self.recordReplayKitDrop(
                    stage: "parser",
                    reason: "audio packet arrived on video connection",
                    details: [
                        "packetType": typedPacket.diagnosticName,
                        "payloadBytes": String(payload.count)
                    ],
                    metric: "parser"
                )
                self.receivePacketPrefix(on: connection)
            }
        }
    }

    private func handleH264ConfigPayload(_ payload: Data, on connection: NWConnection) {
        replayKitLog.info("[ReceiverVideo] packet h264Config payloadBytes=\(payload.count)")
        do {
            let config = try JSONDecoder().decode(ReplayKitH264ConfigPayload.self, from: payload)
            let accepted = h264Decoder.apply(config: config)
            let status = h264Decoder.statusDescription
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.activeVideoCodec = .h264
                self.h264DecoderStatus = status
                self.lastVideoCodecConfigAt = Date()
                self.statusMessage = accepted ? "H.264 video ready" : "H.264 config invalid"
            }
            receivePacketPrefix(on: connection)
        } catch {
            replayKitLog.warning("[ReceiverVideo] packet h264Config decode failed payloadBytes=\(payload.count) error=\(error.localizedDescription)")
            DispatchQueue.main.async { [weak self] in
                self?.h264DecoderStatus = "H.264 config decode failed"
            }
            receivePacketPrefix(on: connection)
        }
    }

    private func handleH264AccessUnitPayload(_ payload: Data, on connection: NWConnection) {
        let receivedAt = CACurrentMediaTime()
        publishReceiverPolicy(trigger: "h264 access unit")

        guard let packet = ReplayKitH264AccessUnitPacket(payload: payload) else {
            replayKitLog.warning("[ReceiverVideo] packet h264AccessUnit malformed payloadBytes=\(payload.count)")
            recordReplayKitDrop(
                stage: "h264-parser",
                reason: "malformed H.264 access unit payload",
                details: ["payloadBytes": String(payload.count)],
                metric: "parser"
            )
            DispatchQueue.main.async { [weak self] in
                self?.h264DecoderStatus = "malformed H.264 packet"
            }
            receivePacketPrefix(on: connection)
            return
        }

        recordH264PacketReceived(packet)
        let submission = h264Decoder.decode(packet: packet, receivedAt: receivedAt) { [weak self, weak connection] result in
            guard let self, let connection, connection === self.connection else {
                replayKitLog.info("[ReceiverH264] decode callback ignored reason=stale connection")
                return
            }

            switch result {
            case .decoded(let frame):
                self.publishH264Frame(frame)
            case .failed(let reason):
                self.recordReplayKitDrop(
                    stage: "h264-decoder",
                    reason: reason,
                    metric: "h264Decoder"
                )
                DispatchQueue.main.async { [weak self] in
                    self?.h264DecoderStatus = reason
                }
            }
        }

        switch submission {
        case .submitted:
            receivePacketPrefix(on: connection)
        case .dropped(let reason):
            recordReplayKitDrop(
                stage: "h264-decoder",
                reason: reason,
                details: ["payloadBytes": String(payload.count)],
                metric: "h264Decoder"
            )
            DispatchQueue.main.async { [weak self] in
                self?.h264DecoderStatus = reason
            }
            receivePacketPrefix(on: connection)
        }
    }

    private func receiveLegacyHeaderRemainder(prefix: Data, on connection: NWConnection) {
        let remainderBytes = ReplayKitFrameHeader.byteCount - prefix.count
        guard remainderBytes > 0 else {
            handleFramePacketPayload(prefix, pathName: "legacy-frame-path", on: connection)
            return
        }

        connection.receive(minimumIncompleteLength: remainderBytes, maximumLength: remainderBytes) { [weak self, weak connection] data, _, isComplete, error in
            guard let self, let connection else { return }

            if let error {
                replayKitLog.error("[ReceiverParser] legacy header remainder receive failed: \(error.localizedDescription)")
                self.handleClientDisconnect(connection, reason: "legacy header remainder error: \(error.localizedDescription)")
                return
            }

            if isComplete {
                replayKitLog.info("[ReceiverParser] legacy header remainder receive completed by peer")
                self.handleClientDisconnect(connection, reason: "peer closed before legacy header remainder")
                return
            }

            guard let data, data.count == remainderBytes else {
                replayKitLog.warning("[ReceiverParser] incomplete legacy header remainder bytes=\(data?.count ?? 0), expected=\(remainderBytes); continuing")
                self.recordReplayKitDrop(
                    stage: "parser",
                    reason: "incomplete legacy frame header",
                    details: [
                        "receivedBytes": String(data?.count ?? 0),
                        "expectedBytes": String(remainderBytes)
                    ],
                    metric: "parser"
                )
                self.receivePacketPrefix(on: connection)
                return
            }

            var headerData = prefix
            headerData.append(data)
            self.handleFramePacketPayload(headerData, pathName: "legacy-frame-path", on: connection)
        }
    }

    private func handleFramePacketPayload(_ payload: Data, pathName: String, on connection: NWConnection) {
        guard payload.count >= ReplayKitFrameHeader.byteCount else {
            replayKitLog.warning("[ReceiverParser] \(pathName) malformed frame payload bytes=\(payload.count), minimum=\(ReplayKitFrameHeader.byteCount); dropping")
            recordReplayKitDrop(
                stage: "jpeg-parser",
                reason: "malformed frame payload",
                details: [
                    "path": pathName,
                    "payloadBytes": String(payload.count),
                    "minimumBytes": String(ReplayKitFrameHeader.byteCount)
                ],
                metric: "parser"
            )
            receivePacketPrefix(on: connection)
            return
        }

        let headerData = payload.prefix(ReplayKitFrameHeader.byteCount)
        guard let header = ReplayKitFrameHeader(data: Data(headerData)) else {
            replayKitLog.warning("[ReceiverParser] \(pathName) malformed frame header; waiting for next packet")
            recordReplayKitDrop(
                stage: "jpeg-parser",
                reason: "malformed frame header",
                details: ["path": pathName],
                metric: "parser"
            )
            receivePacketPrefix(on: connection)
            return
        }

        guard header.jpegSize > 0 else {
            replayKitLog.warning("[ReceiverParser] \(pathName) dropping frame with empty JPEG payload")
            recordReplayKitDrop(
                stage: "jpeg-parser",
                reason: "empty JPEG payload",
                details: [
                    "path": pathName,
                    "width": String(header.width),
                    "height": String(header.height)
                ],
                metric: "parser"
            )
            receivePacketPrefix(on: connection)
            return
        }

        guard header.jpegSize <= maximumJPEGFrameBytes else {
            replayKitLog.error("[ReceiverParser] \(pathName) JPEG payload too large: \(header.jpegSize) bytes")
            recordReplayKitDrop(
                stage: "jpeg-parser",
                reason: "JPEG payload too large",
                details: [
                    "path": pathName,
                    "jpegBytes": String(header.jpegSize),
                    "maximumJPEGFrameBytes": String(maximumJPEGFrameBytes)
                ],
                metric: "parser"
            )
            handleClientDisconnect(connection, reason: "\(pathName) frame too large")
            return
        }

        let frameBytes = Int(header.jpegSize)
        let inlineJPEGBytes = payload.count - ReplayKitFrameHeader.byteCount
        replayKitLog.debug("[ReceiverParser] \(pathName) header ok width=\(header.width) height=\(header.height) jpegBytes=\(header.jpegSize) inlineJPEGBytes=\(inlineJPEGBytes)")

        if inlineJPEGBytes == frameBytes {
            let jpegData = payload.suffix(frameBytes)
            decodeAndPublishJPEGFrame(Data(jpegData), header: header, pathName: pathName)
            receivePacketPrefix(on: connection)
            return
        }

        guard inlineJPEGBytes == 0 else {
            replayKitLog.warning("[ReceiverParser] \(pathName) payload/header length mismatch inlineJPEGBytes=\(inlineJPEGBytes), expected=\(frameBytes); dropping")
            recordReplayKitDrop(
                stage: "jpeg-parser",
                reason: "payload/header length mismatch",
                details: [
                    "path": pathName,
                    "inlineJPEGBytes": String(inlineJPEGBytes),
                    "expectedBytes": String(frameBytes)
                ],
                metric: "parser"
            )
            receivePacketPrefix(on: connection)
            return
        }

        receiveJPEGFrame(on: connection, header: header, pathName: pathName)
    }

    private func receiveJPEGFrame(on connection: NWConnection, header: ReplayKitFrameHeader, pathName: String) {
        let frameBytes = Int(header.jpegSize)
        connection.receive(minimumIncompleteLength: frameBytes, maximumLength: frameBytes) { [weak self, weak connection] data, _, isComplete, error in
            guard let self, let connection else { return }

            if let error {
                replayKitLog.error("[ReceiverParser] \(pathName) frame receive failed: \(error.localizedDescription)")
                self.handleClientDisconnect(connection, reason: "frame error: \(error.localizedDescription)")
                return
            }

            if isComplete {
                replayKitLog.info("[ReceiverParser] \(pathName) frame receive completed by peer")
                self.handleClientDisconnect(connection, reason: "peer closed before frame")
                return
            }

            guard let data else {
                replayKitLog.warning("[ReceiverParser] \(pathName) frame receive returned nil data; continuing")
                self.receivePacketPrefix(on: connection)
                return
            }

            guard data.count == frameBytes else {
                replayKitLog.warning("[ReceiverParser] \(pathName) incomplete frame bytes=\(data.count), expected=\(frameBytes); dropping")
                self.recordReplayKitDrop(
                    stage: "jpeg-parser",
                    reason: "incomplete JPEG frame",
                    details: [
                        "path": pathName,
                        "receivedBytes": String(data.count),
                        "expectedBytes": String(frameBytes)
                    ],
                    metric: "parser"
                )
                self.receivePacketPrefix(on: connection)
                return
            }

            self.decodeAndPublishJPEGFrame(data, header: header, pathName: pathName)
            self.receivePacketPrefix(on: connection)
        }
    }

    private static func decodeJPEG(_ data: Data) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else {
            replayKitLog.warning("[Receiver] CGImageSourceCreateWithData failed")
            return nil
        }

        let options: [CFString: Any] = [
            kCGImageSourceShouldCache: true,
            kCGImageSourceShouldAllowFloat: false,
        ]
        let image = CGImageSourceCreateImageAtIndex(source, 0, options as CFDictionary)
        if image == nil {
            replayKitLog.warning("[Receiver] CGImageSourceCreateImageAtIndex failed")
        }
        return image
    }

    private static func readUInt32(_ data: Data, at offset: Int) -> UInt32 {
        UInt32(data[offset]) << 24
            | UInt32(data[offset + 1]) << 16
            | UInt32(data[offset + 2]) << 8
            | UInt32(data[offset + 3])
    }

    private func decodeAndPublishJPEGFrame(_ data: Data, header: ReplayKitFrameHeader, pathName: String) {
        publishReceiverPolicy(trigger: "\(pathName) frame")

        let receiveCompletedAt = CACurrentMediaTime()
        let decodeStart = CACurrentMediaTime()
        guard let image = Self.decodeJPEG(data) else {
            replayKitLog.warning("[Receiver] \(pathName) JPEG decode failed for \(data.count) bytes")
            recordReplayKitDrop(
                stage: "jpeg-decode",
                reason: "CGImage decode failed",
                details: [
                    "path": pathName,
                    "jpegBytes": String(data.count),
                    "width": String(header.width),
                    "height": String(header.height)
                ],
                metric: "jpegDecode"
            )
            return
        }
        let decodeMilliseconds = (CACurrentMediaTime() - decodeStart) * 1000
        let totalReceiveToDecodeMilliseconds = (CACurrentMediaTime() - receiveCompletedAt) * 1000
        let decodeFinishedAt = CACurrentMediaTime()

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            let publishDelayMilliseconds = (CACurrentMediaTime() - decodeFinishedAt) * 1000
            self.currentFrame = image
            self.lastFrameSize = CGSize(width: Int(header.width), height: Int(header.height))
            let frameReceivedAt = Date()
            self.lastFrameReceivedAt = frameReceivedAt
            self.lastVideoPacketReceivedAt = frameReceivedAt
            self.activeVideoCodec = .jpeg
            self.h264DecoderStatus = "JPEG fallback active"
            self.updateFrameAge(now: frameReceivedAt)
            self.receivedFrameCount += 1
            self.recordReceiverJPEGFrameMetrics(byteCount: data.count, now: frameReceivedAt, pathName: pathName)
            self.recordFrameForFPS(now: frameReceivedAt, pathName: pathName)
            if pathName == "legacy-frame-path" {
                self.legacyFrameCount += 1
            } else {
                self.envelopeFrameCount += 1
            }
            self.statusMessage = "Streaming"
            self.receiverDecodeMilliseconds = decodeMilliseconds
            self.receiverPublishDelayMilliseconds = publishDelayMilliseconds
            self.transitionHealth(.live, trigger: "\(pathName) decoded frame")
            self.maybeLogReceiverMetrics(
                header: header,
                decodeMilliseconds: decodeMilliseconds,
                receiveToDecodeMilliseconds: totalReceiveToDecodeMilliseconds,
                publishDelayMilliseconds: publishDelayMilliseconds
            )
        }
    }

    private func recordH264PacketReceived(_ packet: ReplayKitH264AccessUnitPacket) {
        let header = packet.header
        if let lastH264AccessUnitSequence, header.sequenceNumber > lastH264AccessUnitSequence + 1 {
            replayKitLog.warning("[ReceiverH264] sequence gap previous=\(lastH264AccessUnitSequence) current=\(header.sequenceNumber)")
            recordReplayKitDrop(
                stage: "h264-sequence",
                reason: "sequence gap",
                details: [
                    "previousSequence": String(lastH264AccessUnitSequence),
                    "currentSequence": String(header.sequenceNumber),
                    "missingPackets": String(header.sequenceNumber - lastH264AccessUnitSequence - 1)
                ],
                metric: "h264Sequence"
            )
        } else if let lastH264AccessUnitSequence, header.sequenceNumber <= lastH264AccessUnitSequence {
            replayKitLog.warning("[ReceiverH264] sequence nonmonotonic previous=\(lastH264AccessUnitSequence) current=\(header.sequenceNumber)")
            recordReplayKitDrop(
                stage: "h264-sequence",
                reason: "sequence nonmonotonic",
                details: [
                    "previousSequence": String(lastH264AccessUnitSequence),
                    "currentSequence": String(header.sequenceNumber)
                ],
                metric: "h264Sequence"
            )
        } else {
            replayKitLog.debug("[ReceiverH264] sequence accepted current=\(header.sequenceNumber)")
        }
        lastH264AccessUnitSequence = header.sequenceNumber
        let decoderStatus = h264Decoder.statusDescription

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            let now = Date()
            self.activeVideoCodec = .h264
            self.receivedH264AccessUnitCount += 1
            if header.flags.contains(.keyframe) {
                self.receivedH264KeyframeCount += 1
            }
            self.lastVideoPacketReceivedAt = now
            self.h264DecoderStatus = decoderStatus
            self.recordReceiverH264PacketMetrics(header: header, byteCount: packet.annexBBytes.count, now: now)
        }
    }

    private func publishH264Frame(_ frame: ReplayKitH264VideoDecoder.DecodedFrame) {
        let decoderStatus = h264Decoder.statusDescription
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            let publishDelayMilliseconds = (CACurrentMediaTime() - frame.decodedAt) * 1000
            self.currentFrame = frame.image
            self.lastFrameSize = frame.displaySize
            let frameReceivedAt = Date()
            self.lastFrameReceivedAt = frameReceivedAt
            self.lastVideoPacketReceivedAt = frameReceivedAt
            self.activeVideoCodec = .h264
            self.h264DecoderStatus = decoderStatus
            self.updateFrameAge(now: frameReceivedAt)
            self.receivedFrameCount += 1
            self.envelopeFrameCount += 1
            self.recordReceiverH264DecodedFrameMetrics(frame: frame, now: frameReceivedAt)
            self.recordFrameForFPS(now: frameReceivedAt, pathName: "h264-access-unit-path")
            self.statusMessage = "Streaming H.264"
            self.receiverDecodeMilliseconds = frame.decodeMilliseconds
            self.receiverPublishDelayMilliseconds = publishDelayMilliseconds
            self.transitionHealth(.live, trigger: "h264 access unit decoded frame")
            replayKitLog.info("[ReceiverH264Geometry] published seq=\(frame.header.sequenceNumber) headerWidth=\(frame.header.width) headerHeight=\(frame.header.height) bufferWidth=\(frame.bufferSize.width) bufferHeight=\(frame.bufferSize.height) displayWidth=\(frame.displaySize.width) displayHeight=\(frame.displaySize.height) cropSource=\(frame.displayCropSource, privacy: .public)")
            self.maybeLogH264ReceiverMetrics(
                frame: frame,
                publishDelayMilliseconds: publishDelayMilliseconds
            )
        }
    }

    private func recordSenderTransport(from event: ReplayKitControlEvent, packetKind: String) {
        if let rawTransport = event.transport, let transport = ReplayKitTransport(rawValue: rawTransport) {
            if transport != .unknown || reportedSenderTransport == .unknown {
                reportedSenderTransport = transport
                replayKitLog.info("[ReplayKitTransport] sender path=\(transport.rawValue, privacy: .public) source=\(packetKind, privacy: .public)")
            } else {
                replayKitLog.info("[ReplayKitTransport] sender path=unknown ignored source=\(packetKind, privacy: .public) current=\(self.reportedSenderTransport.rawValue, privacy: .public)")
            }
        } else if event.transport != nil {
            reportedSenderTransport = .unknown
            replayKitLog.warning("[ReplayKitTransport] sender path=unknown source=\(packetKind, privacy: .public) raw=\(event.transport ?? "nil", privacy: .public)")
        }

        publishReceiverPolicy(trigger: "\(packetKind) \(event.event)")
    }

    private func publishReceiverPolicy(trigger: String) {
        let resolvedTransport = ReplayKitTransport.resolve(
            receiver: detectedReceiverTransport,
            sender: reportedSenderTransport
        )
        replayKitLog.info("[ReplayKitPolicy] allowed trigger=\(trigger, privacy: .public) receiver=\(self.detectedReceiverTransport.rawValue, privacy: .public) sender=\(self.reportedSenderTransport.rawValue, privacy: .public) resolved=\(resolvedTransport.rawValue, privacy: .public) h264FPS=\(self.effectiveH264TargetFramesPerSecond()) reason=\(ReplayKitReceiverPolicy.legacyCompatibilityReason, privacy: .public)")
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.receiverTransport = self.detectedReceiverTransport
            self.senderTransport = self.reportedSenderTransport
            self.resolvedTransport = resolvedTransport
        }
    }

    private func handleControlPayload(_ payload: Data, packetKind: String) {
        replayKitLog.debug("[ReceiverControl] received \(packetKind) payloadBytes=\(payload.count)")
        do {
            let event = try JSONDecoder().decode(ReplayKitControlEvent.self, from: payload)
            recordSenderTransport(from: event, packetKind: packetKind)
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                let now = Date()
                self.lastControlEventAt = now
                self.lastBroadcastEvent = event
                self.updateReplayKitVideoOrientation(event.videoOrientation, packetKind: packetKind)
                if packetKind == "heartbeat" {
                    self.heartbeatCount += 1
                } else {
                    self.controlEventCount += 1
                }
                self.updateFrameAge(now: now)
                replayKitLog.info("[ReceiverControl] \(packetKind) decoded \(event.diagnosticDescription) lastFrameAge=\(self.formatFrameAge(self.frameAgeSeconds))")
                self.applyControlEvent(event, packetKind: packetKind)
            }
        } catch {
            replayKitLog.warning("[ReceiverControl] failed to decode \(packetKind) payloadBytes=\(payload.count) error=\(error.localizedDescription)")
            recordReplayKitDrop(
                stage: "control-parser",
                reason: "failed to decode control payload",
                details: [
                    "packetKind": packetKind,
                    "payloadBytes": String(payload.count),
                    "error": error.localizedDescription
                ],
                metric: "parser"
            )
        }
    }

    private func applyControlEvent(_ event: ReplayKitControlEvent, packetKind: String) {
        switch event.event {
        case "broadcastStarted":
            statusMessage = "Broadcast started"
            transitionHealth(.connecting, trigger: "\(packetKind) broadcastStarted")
        case "firstFrame":
            statusMessage = "First frame announced"
            transitionHealth(lastFrameReceivedAt == nil ? .connecting : .live, trigger: "\(packetKind) firstFrame")
        case "videoStalled":
            statusMessage = "Video stalled"
            transitionHealth(.stale(reason: .senderReported(event.reason), lastFrameAge: frameAgeSeconds ?? .infinity), trigger: "\(packetKind) videoStalled")
        case "broadcastPaused":
            statusMessage = "Broadcast paused"
            transitionHealth(.broadcastPaused, trigger: "\(packetKind) broadcastPaused")
        case "broadcastResumed":
            statusMessage = "Broadcast resumed"
            transitionHealth(.connecting, trigger: "\(packetKind) broadcastResumed")
        case "broadcastFinished":
            statusMessage = "Broadcast finished"
            transitionHealth(.broadcastEnded(reason: event.reason), trigger: "\(packetKind) broadcastFinished")
        case "senderReady":
            statusMessage = event.reason.map { "Sender ready: \($0)" } ?? "Sender ready"
            transitionHealth(lastFrameReceivedAt == nil ? .connecting : .live, trigger: "\(packetKind) senderReady")
        case "senderFailed":
            statusMessage = event.reason.map { "Sender failed: \($0)" } ?? "Sender failed"
            let age = frameAgeSeconds ?? .infinity
            if lastFrameReceivedAt == nil || age >= staleFrameThresholdSeconds {
                transitionHealth(.failed(reason: event.reason ?? "senderFailed"), trigger: "\(packetKind) senderFailed")
            } else {
                replayKitLog.info("[ReceiverControl] senderFailed received while recent frames exist; preserving live health frameAge=\(self.formatFrameAge(self.frameAgeSeconds))")
            }
        default:
            statusMessage = "Receiver heartbeat"
            evaluateHealthFromTimer(trigger: "\(packetKind) \(event.event)")
        }
    }

    private func updateReplayKitVideoOrientation(
        _ snapshot: ReplayKitVideoOrientationSnapshot?,
        packetKind: String
    ) {
        guard let snapshot else { return }
        guard lastVideoOrientation?.orientationSignature != snapshot.orientationSignature else { return }

        let previous = lastVideoOrientation
        lastVideoOrientation = snapshot
        replayKitLog.info("[ReplayKitOrientation] changed packet=\(packetKind, privacy: .public) previousDevice=\(previous?.deviceOrientationName ?? "nil", privacy: .public) previousVideo=\(previous?.videoOrientationName ?? "nil", privacy: .public) device=\(snapshot.deviceOrientationName, privacy: .public) deviceAxis=\(snapshot.deviceAxis, privacy: .public) video=\(snapshot.videoOrientationName ?? "nil", privacy: .public) videoAxis=\(snapshot.videoOrientationAxis ?? "nil", privacy: .public) frameWidth=\(snapshot.frameWidth) frameHeight=\(snapshot.frameHeight) frameAxis=\(snapshot.videoFrameAxis, privacy: .public)")
        FrameDropDiagnostics.shared.recordLifecycle(
            source: "replayKitOrientation",
            event: "orientationChanged",
            reason: packetKind,
            details: [
                "previousDeviceOrientation": previous?.deviceOrientationName ?? "nil",
                "previousVideoOrientation": previous?.videoOrientationName ?? "nil",
                "deviceOrientation": snapshot.deviceOrientationName,
                "deviceAxis": snapshot.deviceAxis,
                "videoOrientation": snapshot.videoOrientationName ?? "nil",
                "videoAxis": snapshot.videoOrientationAxis ?? "nil",
                "frameWidth": String(snapshot.frameWidth),
                "frameHeight": String(snapshot.frameHeight),
                "frameAxis": snapshot.videoFrameAxis
            ]
        )
    }

    private func handleClientDisconnect(_ disconnectedConnection: NWConnection, reason: String) {
        queue.async { [weak self] in
            guard let self else { return }

            guard self.connection === disconnectedConnection else {
                replayKitLog.info("[Receiver] disconnect ignored for stale connection: \(reason)")
                return
            }

            replayKitLog.info("[Receiver] client disconnected: \(reason)")
            self.connection?.cancel()
            self.connection = nil
            self.detectedReceiverTransport = .unknown
            self.reportedSenderTransport = .unknown
            self.lastH264AccessUnitSequence = nil
            self.h264Decoder.reset(reason: "client disconnect")
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.isClientConnected = false
                self.clientConnectedAt = nil
                self.lastDisconnectReason = reason
                self.receiverTransport = .unknown
                self.senderTransport = .unknown
                self.resolvedTransport = .unknown
                self.lastVideoOrientation = nil
                self.activeVideoCodec = .unknown
                self.h264DecoderStatus = "waiting for H.264 config"
                self.resetReceiverVideoMetrics(reason: "client disconnect")
                self.updateFrameAge(now: Date())
                self.statusMessage = self.isListening ? "Listening on \(self.port)" : "Stopped"
                self.transitionHealth(self.isListening ? .disconnected(reason: reason) : .idle, trigger: "client disconnect")
            }
        }
    }

    private func startBonjourAdvertisement() {
        if bonjourService != nil {
            replayKitLog.info("[Receiver] Bonjour already advertised")
            return
        }

        let txtRecord = replayKitPolicyTXTRecordData()
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            if self.bonjourService != nil {
                replayKitLog.info("[Receiver] Bonjour already advertised on main queue")
                return
            }
            let service = NetService(domain: "local.", type: Self.bonjourType, name: "Specchio Easy", port: Int32(self.port))
            service.delegate = self
            service.includesPeerToPeer = true
            service.setTXTRecord(txtRecord)
            self.bonjourService = service
            service.publish(options: [])
            replayKitLog.info("[Receiver] Bonjour NetService publish requested type=\(Self.bonjourType) name=Specchio Easy port=\(self.port) peerToPeer=true policy=all-transports-allowed")
        }
    }

    private func replayKitPolicyTXTRecordData() -> Data {
        let effectiveH264FPS = effectiveH264TargetFramesPerSecond()
        let txt: [String: Data] = [
            "rkPolicy": Data("1".utf8),
            "rkTier": Data("pro".utf8),
            "rkPremium": Data("1".utf8),
            "rkJPEGFPS": Data(String(format: "%.0f", ReplayKitReceiverPolicy.currentJPEGFramesPerSecond).utf8),
            "rkH264FPS": Data(String(format: "%.0f", effectiveH264FPS).utf8),
            "rkUSBCable": Data("1".utf8),
            "rkUSBReason": Data(ReplayKitReceiverPolicy.legacyCompatibilityReason.utf8)
        ]
        replayKitLog.info("[ReplayKitPolicy] publishing Bonjour compatibility policy tier=pro jpegFPS=\(ReplayKitReceiverPolicy.currentJPEGFramesPerSecond) configuredH264FPS=\(self.h264TargetFramesPerSecond) effectiveH264FPS=\(effectiveH264FPS) reason=\(ReplayKitReceiverPolicy.legacyCompatibilityReason, privacy: .public)")
        return NetService.data(fromTXTRecord: txt)
    }

    private func publishStatus(_ message: String) {
        DispatchQueue.main.async { [weak self] in
            self?.statusMessage = message
        }
    }

    private func publishHealth(_ health: ReplayKitStreamHealth, trigger: String) {
        DispatchQueue.main.async { [weak self] in
            self?.transitionHealth(health, trigger: trigger)
        }
    }

    private func startFPSCounter() {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            guard self.fpsTimer == nil else {
                replayKitLog.info("[Receiver] FPS counter already running")
                return
            }

            replayKitLog.info("[ReceiverFPS] starting counter intervalSeconds=\(String(format: "%.1f", self.fpsSampleIntervalSeconds)) rollingWindowSeconds=\(String(format: "%.1f", self.fpsRollingWindowSeconds)) staleHoldThresholdSeconds=\(String(format: "%.1f", self.staleFrameThresholdSeconds))")
            self.resetFPSCounterState(reason: "counter start")
            let timer = Timer(timeInterval: self.fpsSampleIntervalSeconds, repeats: true) { [weak self] _ in
                guard let self else { return }
                self.refreshFPS(now: Date(), trigger: "timer")
            }
            self.fpsTimer = timer
            RunLoop.main.add(timer, forMode: .common)
        }
    }

    private func resetFPSCounterState(reason: String) {
        fpsFrameTimestamps.removeAll()
        lastFPSLogAt = Date.distantPast
        currentFPS = 0
        replayKitLog.info("[ReceiverFPS] reset reason=\(reason, privacy: .public)")
    }

    private func resetReceiverVideoMetrics(reason: String) {
        receiverVideoMetricsWindowStartedAt = Date()
        receiverMetricsH264Packets = 0
        receiverMetricsH264PacketBytes = 0
        receiverMetricsH264Keyframes = 0
        receiverMetricsH264DecodedFrames = 0
        receiverMetricsJPEGFrames = 0
        receiverMetricsJPEGBytes = 0
        receiverMetricsParserDrops = 0
        receiverMetricsH264DecoderDrops = 0
        receiverMetricsH264SequenceDrops = 0
        receiverMetricsJPEGDecodeDrops = 0
        replayKitLog.info("[ReceiverVideoMetrics] reset reason=\(reason, privacy: .public)")
    }

    private func replayKitDiagnosticDetails(_ details: [String: String] = [:]) -> [String: String] {
        var merged = details
        merged["port"] = merged["port"] ?? String(port)
        merged["isListening"] = merged["isListening"] ?? String(isListening)
        merged["isClientConnected"] = merged["isClientConnected"] ?? String(isClientConnected)
        merged["activeVideoCodec"] = merged["activeVideoCodec"] ?? activeVideoCodec.rawValue
        merged["currentFPS"] = merged["currentFPS"] ?? FrameDropDiagnostics.format(currentFPS)
        merged["health"] = merged["health"] ?? streamHealth.diagnosticDescription
        merged["receiverTransport"] = merged["receiverTransport"] ?? receiverTransport.rawValue
        merged["senderTransport"] = merged["senderTransport"] ?? senderTransport.rawValue
        merged["resolvedTransport"] = merged["resolvedTransport"] ?? resolvedTransport.rawValue
        merged["receiverAllowsStream"] = merged["receiverAllowsStream"] ?? String(true)
        merged["receiverPolicyReason"] = merged["receiverPolicyReason"] ?? ReplayKitReceiverPolicy.legacyCompatibilityReason
        merged["h264DecoderStatus"] = merged["h264DecoderStatus"] ?? h264DecoderStatus
        return merged
    }

    private func recordReplayKitDrop(
        stage: String,
        reason: String,
        details: [String: String] = [:],
        metric: String
    ) {
        DispatchQueue.main.async { [weak self] in
            self?.incrementReplayKitDropMetric(metric)
        }

        FrameDropDiagnostics.shared.recordDrop(
            source: "replayKit",
            stage: stage,
            reason: reason,
            details: replayKitDiagnosticDetails(details)
        )
    }

    private func incrementReplayKitDropMetric(_ metric: String) {
        switch metric {
        case "parser":
            receiverMetricsParserDrops += 1
        case "h264Decoder":
            receiverMetricsH264DecoderDrops += 1
        case "h264Sequence":
            receiverMetricsH264SequenceDrops += 1
        case "jpegDecode":
            receiverMetricsJPEGDecodeDrops += 1
        default:
            receiverMetricsParserDrops += 1
        }
    }

    private func recordReceiverH264PacketMetrics(header: ReplayKitH264AccessUnitHeader, byteCount: Int, now: Date) {
        receiverMetricsH264Packets += 1
        receiverMetricsH264PacketBytes += byteCount
        if header.flags.contains(.keyframe) {
            receiverMetricsH264Keyframes += 1
        }
        logReceiverVideoMetricsIfNeeded(now: now, trigger: "h264-packet")
    }

    private func recordReceiverH264DecodedFrameMetrics(frame: ReplayKitH264VideoDecoder.DecodedFrame, now: Date) {
        receiverMetricsH264DecodedFrames += 1
        logReceiverVideoMetricsIfNeeded(now: now, trigger: "h264-decoded-frame")
    }

    private func recordReceiverJPEGFrameMetrics(byteCount: Int, now: Date, pathName: String) {
        receiverMetricsJPEGFrames += 1
        receiverMetricsJPEGBytes += byteCount
        logReceiverVideoMetricsIfNeeded(now: now, trigger: pathName)
    }

    private func logReceiverVideoMetricsIfNeeded(now: Date, trigger: String) {
        guard isClientConnected
                || receiverMetricsH264Packets > 0
                || receiverMetricsH264DecodedFrames > 0
                || receiverMetricsJPEGFrames > 0
                || receiverMetricsParserDrops > 0
                || receiverMetricsH264DecoderDrops > 0
                || receiverMetricsH264SequenceDrops > 0
                || receiverMetricsJPEGDecodeDrops > 0 else {
            return
        }

        let elapsed = now.timeIntervalSince(receiverVideoMetricsWindowStartedAt)
        guard elapsed >= 1.0 else { return }

        let safeElapsed = max(elapsed, 0.001)
        let h264PacketFPS = Double(receiverMetricsH264Packets) / safeElapsed
        let h264DecodedFPS = Double(receiverMetricsH264DecodedFrames) / safeElapsed
        let jpegFPS = Double(receiverMetricsJPEGFrames) / safeElapsed
        let h264KBps = Double(receiverMetricsH264PacketBytes) / 1024.0 / safeElapsed
        let jpegKBps = Double(receiverMetricsJPEGBytes) / 1024.0 / safeElapsed

        replayKitLog.info("[ReceiverVideoMetrics] trigger=\(trigger, privacy: .public) windowSeconds=\(String(format: "%.2f", safeElapsed), privacy: .public) codec=\(self.activeVideoCodec.rawValue, privacy: .public) h264Packets=\(self.receiverMetricsH264Packets) h264PacketFPS=\(String(format: "%.2f", h264PacketFPS), privacy: .public) h264DecodedFrames=\(self.receiverMetricsH264DecodedFrames) h264DecodedFPS=\(String(format: "%.2f", h264DecodedFPS), privacy: .public) h264Keyframes=\(self.receiverMetricsH264Keyframes) h264KBps=\(String(format: "%.1f", h264KBps), privacy: .public) jpegFrames=\(self.receiverMetricsJPEGFrames) jpegFPS=\(String(format: "%.2f", jpegFPS), privacy: .public) jpegKBps=\(String(format: "%.1f", jpegKBps), privacy: .public) parserDrops=\(self.receiverMetricsParserDrops) h264DecoderDrops=\(self.receiverMetricsH264DecoderDrops) h264SequenceDrops=\(self.receiverMetricsH264SequenceDrops) jpegDecodeDrops=\(self.receiverMetricsJPEGDecodeDrops) displayedFPS=\(String(format: "%.2f", self.currentFPS), privacy: .public) totalDisplayedFrames=\(self.receivedFrameCount) decoderStatus=\(self.h264DecoderStatus, privacy: .public) health=\(self.streamHealth.diagnosticDescription, privacy: .public)")

        FrameDropDiagnostics.shared.recordWindow(
            source: "replayKit",
            trigger: trigger,
            windowSeconds: safeElapsed,
            metrics: replayKitDiagnosticDetails([
                "h264Packets": String(receiverMetricsH264Packets),
                "h264PacketFPS": FrameDropDiagnostics.format(h264PacketFPS),
                "h264DecodedFrames": String(receiverMetricsH264DecodedFrames),
                "h264DecodedFPS": FrameDropDiagnostics.format(h264DecodedFPS),
                "h264Keyframes": String(receiverMetricsH264Keyframes),
                "h264KBps": FrameDropDiagnostics.format(h264KBps, digits: 1),
                "jpegFrames": String(receiverMetricsJPEGFrames),
                "jpegFPS": FrameDropDiagnostics.format(jpegFPS),
                "jpegKBps": FrameDropDiagnostics.format(jpegKBps, digits: 1),
                "parserDrops": String(receiverMetricsParserDrops),
                "h264DecoderDrops": String(receiverMetricsH264DecoderDrops),
                "h264SequenceDrops": String(receiverMetricsH264SequenceDrops),
                "jpegDecodeDrops": String(receiverMetricsJPEGDecodeDrops),
                "displayedFPS": FrameDropDiagnostics.format(currentFPS),
                "totalDisplayedFrames": String(receivedFrameCount)
            ])
        )

        receiverVideoMetricsWindowStartedAt = now
        receiverMetricsH264Packets = 0
        receiverMetricsH264PacketBytes = 0
        receiverMetricsH264Keyframes = 0
        receiverMetricsH264DecodedFrames = 0
        receiverMetricsJPEGFrames = 0
        receiverMetricsJPEGBytes = 0
        receiverMetricsParserDrops = 0
        receiverMetricsH264DecoderDrops = 0
        receiverMetricsH264SequenceDrops = 0
        receiverMetricsJPEGDecodeDrops = 0
    }

    private func recordFrameForFPS(now: Date?, pathName: String) {
        let timestamp = now ?? Date()
        fpsFrameTimestamps.append(timestamp)
        pruneFPSFrameTimestamps(now: timestamp)

        let rollingFPS = measuredFPS()
        if timestamp.timeIntervalSince(lastFPSLogAt) >= fpsLogIntervalSeconds {
            lastFPSLogAt = timestamp
            replayKitLog.info("[ReceiverFPS] frame recorded path=\(pathName, privacy: .public) rollingFrames=\(self.fpsFrameTimestamps.count) windowSeconds=\(String(format: "%.1f", self.fpsRollingWindowSeconds)) measuredFPS=\(String(format: "%.2f", rollingFPS)) totalFrames=\(self.receivedFrameCount) currentFPS=\(String(format: "%.2f", self.currentFPS))")
        } else {
            replayKitLog.debug("[ReceiverFPS] frame recorded path=\(pathName, privacy: .public) rollingFrames=\(self.fpsFrameTimestamps.count) measuredFPS=\(String(format: "%.2f", rollingFPS)) totalFrames=\(self.receivedFrameCount) currentFPS=\(String(format: "%.2f", self.currentFPS))")
        }
    }

    private func refreshFPS(now: Date, trigger: String) {
        pruneFPSFrameTimestamps(now: now)
        logReceiverVideoMetricsIfNeeded(now: now, trigger: trigger)
        let sampledFrameCount = fpsFrameTimestamps.count

        guard sampledFrameCount > 0 else {
            refreshFPSWithoutNewFrames(now: now, trigger: trigger)
            return
        }

        let nextFPS = measuredFPS()
        replayKitLog.info("[ReceiverFPS] sample applied trigger=\(trigger, privacy: .public) branch=rolling-window frames=\(sampledFrameCount) windowSeconds=\(String(format: "%.1f", self.fpsRollingWindowSeconds)) previousFPS=\(String(format: "%.2f", self.currentFPS)) nextFPS=\(String(format: "%.2f", nextFPS))")
        currentFPS = nextFPS
    }

    private func pruneFPSFrameTimestamps(now: Date) {
        let cutoff = now.addingTimeInterval(-fpsRollingWindowSeconds)
        let beforeCount = fpsFrameTimestamps.count
        fpsFrameTimestamps.removeAll { $0 < cutoff }
        let prunedCount = beforeCount - fpsFrameTimestamps.count
        if prunedCount > 0 {
            replayKitLog.debug("[ReceiverFPS] pruned old frames count=\(prunedCount) remaining=\(self.fpsFrameTimestamps.count) cutoffAgeSeconds=\(String(format: "%.1f", self.fpsRollingWindowSeconds))")
        }
    }

    private func measuredFPS() -> Double {
        Double(fpsFrameTimestamps.count) / fpsRollingWindowSeconds
    }

    private func refreshFPSWithoutNewFrames(now: Date, trigger: String) {
        guard let lastFrameReceivedAt else {
            if currentFPS != 0 {
                replayKitLog.info("[ReceiverFPS] reset trigger=\(trigger, privacy: .public) branch=no-frame-ever previousFPS=\(String(format: "%.2f", self.currentFPS))")
            } else {
                replayKitLog.debug("[ReceiverFPS] unchanged trigger=\(trigger, privacy: .public) branch=no-frame-ever")
            }
            currentFPS = 0
            return
        }

        let frameAge = now.timeIntervalSince(lastFrameReceivedAt)
        if currentFPS != 0 {
            replayKitLog.info("[ReceiverFPS] reset trigger=\(trigger, privacy: .public) branch=no-frames-in-rolling-window frameAge=\(String(format: "%.2f", frameAge)) previousFPS=\(String(format: "%.2f", self.currentFPS)) health=\(self.streamHealth.diagnosticDescription, privacy: .public)")
        } else {
            replayKitLog.debug("[ReceiverFPS] unchanged trigger=\(trigger, privacy: .public) branch=no-frames-in-rolling-window frameAge=\(String(format: "%.2f", frameAge)) health=\(self.streamHealth.diagnosticDescription, privacy: .public)")
        }
        currentFPS = 0
    }

    private func startStaleDetectionTimer() {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            guard self.staleTimer == nil else {
                replayKitLog.info("[ReceiverHealth] stale detection timer already running")
                return
            }

            replayKitLog.info("[ReceiverHealth] starting stale detection timer thresholdSeconds=\(String(format: "%.1f", self.staleFrameThresholdSeconds))")
            self.staleTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
                self?.evaluateHealthFromTimer(trigger: "stale timer")
            }
        }
    }

    private func evaluateHealthFromTimer(trigger: String) {
        let now = Date()
        updateFrameAge(now: now)
        replayKitLog.debug("[ReceiverHealth] evaluating trigger=\(trigger) isListening=\(self.isListening) isClientConnected=\(self.isClientConnected) lastFrameAge=\(self.formatFrameAge(self.frameAgeSeconds)) lastControlAge=\(self.formatDateAge(self.lastControlEventAt, now: now)) current=\(self.streamHealth.diagnosticDescription)")

        guard isListening else {
            transitionHealth(.idle, trigger: "\(trigger): listener inactive")
            return
        }

        guard isClientConnected else {
            switch streamHealth {
            case .broadcastEnded, .disconnected, .failed:
                replayKitLog.debug("[ReceiverHealth] preserving terminal visible health=\(self.streamHealth.diagnosticDescription) while listener remains available")
            default:
                transitionHealth(.listening, trigger: "\(trigger): no active client")
            }
            return
        }

        guard let lastFrameReceivedAt else {
            let connectedAge = clientConnectedAt.map { now.timeIntervalSince($0) } ?? 0
            if connectedAge >= staleFrameThresholdSeconds {
                let reason: ReplayKitStaleReason = lastControlEventAt == nil ? .noFramesAfterConnect : .heartbeatWithoutVideo
                transitionHealth(.stale(reason: reason, lastFrameAge: .infinity), trigger: "\(trigger): connected without first frame")
            } else {
                transitionHealth(.connecting, trigger: "\(trigger): connected with no frames")
            }
            return
        }

        let age = now.timeIntervalSince(lastFrameReceivedAt)
        if age >= staleFrameThresholdSeconds {
            let reason: ReplayKitStaleReason = lastControlEventAt.map { $0 > lastFrameReceivedAt } == true ? .heartbeatWithoutVideo : .frameTimeout
            transitionHealth(.stale(reason: reason, lastFrameAge: age), trigger: "\(trigger): frame age exceeded threshold")
        } else {
            switch streamHealth {
            case .broadcastPaused, .broadcastEnded, .failed:
                replayKitLog.debug("[ReceiverHealth] recent frame exists but preserving control-driven health=\(self.streamHealth.diagnosticDescription)")
            default:
                transitionHealth(.live, trigger: "\(trigger): recent frame")
            }
        }
    }

    private func updateFrameAge(now: Date?) {
        guard let now, let lastFrameReceivedAt else {
            frameAgeSeconds = nil
            return
        }
        frameAgeSeconds = now.timeIntervalSince(lastFrameReceivedAt)
    }

    private func transitionHealth(_ newHealth: ReplayKitStreamHealth, trigger: String) {
        let previousHealth = streamHealth
        updateFrameAge(now: Date())
        guard previousHealth != newHealth else {
            replayKitLog.debug("[ReceiverHealth] unchanged=\(newHealth.diagnosticDescription) trigger=\(trigger) lastFrameAge=\(self.formatFrameAge(self.frameAgeSeconds)) isListening=\(self.isListening) isClientConnected=\(self.isClientConnected) lastControl=\(self.lastBroadcastEvent?.event ?? "nil")")
            return
        }

        streamHealth = newHealth
        replayKitLog.info("[ReceiverHealth] transition previous=\(previousHealth.diagnosticDescription) new=\(newHealth.diagnosticDescription) trigger=\(trigger) lastFrameAge=\(self.formatFrameAge(self.frameAgeSeconds)) isListening=\(self.isListening) isClientConnected=\(self.isClientConnected) lastControl=\(self.lastBroadcastEvent?.event ?? "nil") lastDisconnect=\(self.lastDisconnectReason ?? "nil") envelopeFrames=\(self.envelopeFrameCount) legacyFrames=\(self.legacyFrameCount) controls=\(self.controlEventCount) heartbeats=\(self.heartbeatCount)")
        FrameDropDiagnostics.shared.recordLifecycle(
            source: "replayKit",
            event: "healthTransition",
            reason: trigger,
            details: replayKitDiagnosticDetails([
                "previousHealth": previousHealth.diagnosticDescription,
                "newHealth": newHealth.diagnosticDescription,
                "lastFrameAge": formatFrameAge(frameAgeSeconds),
                "lastControl": lastBroadcastEvent?.event ?? "nil",
                "lastDisconnect": lastDisconnectReason ?? "nil",
                "envelopeFrames": String(envelopeFrameCount),
                "legacyFrames": String(legacyFrameCount),
                "controls": String(controlEventCount),
                "heartbeats": String(heartbeatCount)
            ])
        )
    }

    private func formatFrameAge(_ age: TimeInterval?) -> String {
        guard let age else { return "nil" }
        guard age.isFinite else { return "infinity" }
        return String(format: "%.1fs", age)
    }

    private func formatDateAge(_ date: Date?, now: Date) -> String {
        guard let date else { return "nil" }
        return String(format: "%.1fs", now.timeIntervalSince(date))
    }

    private func maybeLogReceiverMetrics(
        header: ReplayKitFrameHeader,
        decodeMilliseconds: Double,
        receiveToDecodeMilliseconds: Double,
        publishDelayMilliseconds: Double
    ) {
        let now = Date()
        guard now.timeIntervalSince(lastMetricsLogTime) >= 1.0
                || decodeMilliseconds > 20
                || publishDelayMilliseconds > 20
                || receiveToDecodeMilliseconds > 30 else {
            return
        }
        lastMetricsLogTime = now
        let decodeText = String(format: "%.1f", decodeMilliseconds)
        let receiveText = String(format: "%.1f", receiveToDecodeMilliseconds)
        let publishText = String(format: "%.1f", publishDelayMilliseconds)
        replayKitLog.info("[ReceiverMetrics] frames=\(self.receivedFrameCount) width=\(header.width) height=\(header.height) decodeMs=\(decodeText) receiveToDecodeMs=\(receiveText) publishDelayMs=\(publishText)")
    }

    private func maybeLogH264ReceiverMetrics(
        frame: ReplayKitH264VideoDecoder.DecodedFrame,
        publishDelayMilliseconds: Double
    ) {
        let now = Date()
        guard now.timeIntervalSince(lastMetricsLogTime) >= 1.0
                || frame.decodeMilliseconds > 20
                || publishDelayMilliseconds > 20
                || frame.receiveToDecodeMilliseconds > 30 else {
            return
        }
        lastMetricsLogTime = now
        let decodeText = String(format: "%.1f", frame.decodeMilliseconds)
        let receiveText = String(format: "%.1f", frame.receiveToDecodeMilliseconds)
        let publishText = String(format: "%.1f", publishDelayMilliseconds)
        replayKitLog.info("[ReceiverMetrics] codec=h264 frames=\(self.receivedFrameCount) width=\(frame.header.width) height=\(frame.header.height) decodeMs=\(decodeText) receiveToDecodeMs=\(receiveText) publishDelayMs=\(publishText) h264Packets=\(self.receivedH264AccessUnitCount) keyframes=\(self.receivedH264KeyframeCount)")
    }
}

extension ReplayKitScreenStreamManager: NetServiceDelegate {
    func netServiceDidPublish(_ sender: NetService) {
        replayKitLog.info("[Receiver] Bonjour NetService did publish name=\(sender.name) type=\(sender.type) domain=\(sender.domain) port=\(sender.port)")
    }

    func netService(_ sender: NetService, didNotPublish errorDict: [String : NSNumber]) {
        replayKitLog.error("[Receiver] Bonjour NetService did not publish name=\(sender.name) error=\(String(describing: errorDict))")
    }

    func netServiceDidStop(_ sender: NetService) {
        replayKitLog.info("[Receiver] Bonjour NetService stopped name=\(sender.name)")
    }
}
