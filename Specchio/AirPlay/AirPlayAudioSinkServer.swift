import AudioToolbox
import AVFoundation
import CommonCrypto
import Foundation
import Network

private let airPlayAudioSinkLog = SpecchioLogger.airPlay

struct AirPlayAudioPlaybackConfiguration {
    let key: Data
    let iv: Data
    let compressionType: Int
    let audioFormat: Int?
    let samplesPerFrame: Int
    let sampleRate: Double
    let channelCount: Int
    let remoteControlPort: Int?

    var diagnosticDescription: String {
        "mode=playback keyBytes=\(key.count) ivBytes=\(iv.count) ct=\(compressionType) audioFormat=\(audioFormat.map(String.init) ?? "nil") spf=\(samplesPerFrame) sampleRate=\(String(format: "%.0f", sampleRate)) channels=\(channelCount) remoteControlPort=\(remoteControlPort.map(String.init) ?? "nil")"
    }
}

struct AirPlayAudioPlaybackSnapshot: Equatable {
    let state: String
    let receivedPackets: Int
    let decodedPackets: Int
    let droppedPackets: Int
    let bufferedMilliseconds: Double
    let sampleRate: Double
    let channelCount: Int
    let lastDropReason: String?
}

enum AirPlayGStreamerAACELDDecoderSupport {
    static let audioSpecificConfigHex = "f8e85000"

    static func executableCandidates(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> [String] {
        var candidates: [String] = []
        var seen = Set<String>()

        func append(_ path: String?) {
            let normalized = path?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !normalized.isEmpty, !seen.contains(normalized) else { return }
            seen.insert(normalized)
            candidates.append(normalized)
        }

        append(environment["SPECCHIO_AIRPLAY_GST_LAUNCH_1_0"])
        append(environment["GST_LAUNCH_1_0"])

        if let pathValue = environment["PATH"] {
            for directory in pathValue.split(separator: ":") {
                append("\(directory)/gst-launch-1.0")
            }
        }

        append("/opt/homebrew/bin/gst-launch-1.0")
        append("/usr/local/bin/gst-launch-1.0")
        append("/Library/Frameworks/GStreamer.framework/Commands/gst-launch-1.0")
        return candidates
    }

    static func locateExecutable(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        isExecutable: (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) }
    ) -> String? {
        executableCandidates(environment: environment).first(where: isExecutable)
    }

    static func aacELDCaps(sampleRate: Double, channelCount: Int) -> String {
        let roundedSampleRate = max(1, Int(sampleRate.rounded()))
        let sanitizedChannelCount = max(1, channelCount)
        return "audio/mpeg,mpegversion=(int)4,channels=(int)\(sanitizedChannelCount),rate=(int)\(roundedSampleRate),stream-format=(string)raw,codec_data=(buffer)\(audioSpecificConfigHex)"
    }

    static func pcmCaps(sampleRate: Double, channelCount: Int) -> String {
        let roundedSampleRate = max(1, Int(sampleRate.rounded()))
        let sanitizedChannelCount = max(1, channelCount)
        return "audio/x-raw,format=(string)F32LE,layout=(string)interleaved,rate=(int)\(roundedSampleRate),channels=(int)\(sanitizedChannelCount)"
    }

    static func spawnEnvironment(
        base: [String: String] = ProcessInfo.processInfo.environment,
        pathExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }
    ) -> [String: String] {
        var environment = base
        let binDirectories = [
            "/opt/homebrew/bin",
            "/usr/local/bin",
            "/Library/Frameworks/GStreamer.framework/Commands",
        ].filter(pathExists)
        let libraryDirectories = [
            "/opt/homebrew/lib",
            "/usr/local/lib",
            "/Library/Frameworks/GStreamer.framework/Libraries",
        ].filter(pathExists)
        let pluginDirectories = [
            "/opt/homebrew/lib/gstreamer-1.0",
            "/usr/local/lib/gstreamer-1.0",
            "/Library/Frameworks/GStreamer.framework/Libraries/lib/gstreamer-1.0",
        ].filter(pathExists)

        mergeSearchPath(&environment, key: "PATH", prepending: binDirectories)
        mergeSearchPath(&environment, key: "DYLD_LIBRARY_PATH", prepending: libraryDirectories)
        mergeSearchPath(&environment, key: "GST_PLUGIN_PATH", prepending: pluginDirectories)
        mergeSearchPath(&environment, key: "GST_PLUGIN_SYSTEM_PATH", prepending: pluginDirectories)
        return environment
    }

    private static func mergeSearchPath(
        _ environment: inout [String: String],
        key: String,
        prepending additions: [String]
    ) {
        guard !additions.isEmpty else { return }
        let existing = environment[key]?
            .split(separator: ":")
            .map(String.init) ?? []
        var seen = Set<String>()
        var merged: [String] = []
        for path in additions + existing {
            guard !path.isEmpty, !seen.contains(path) else { continue }
            seen.insert(path)
            merged.append(path)
        }
        environment[key] = merged.joined(separator: ":")
    }
}

struct AirPlayAudioRTPPacket: Equatable {
    static let noDataMarker = Data([0x00, 0x68, 0x34, 0x00])

    let version: UInt8
    let payloadType: UInt8
    let marker: Bool
    let sequenceNumber: UInt16
    let timestamp: UInt32
    let ssrc: UInt32
    let headerLength: Int
    let payload: Data

    var isHeaderOnly: Bool {
        payload.isEmpty
    }

    var isNoDataMarker: Bool {
        payload == Self.noDataMarker
    }

    init?(data: Data) {
        guard data.count >= 12 else {
            return nil
        }

        let firstByte = data[0]
        version = firstByte >> 6
        let hasExtension = (firstByte & 0x10) != 0
        let csrcCount = Int(firstByte & 0x0F)
        payloadType = data[1] & 0x7F
        marker = (data[1] & 0x80) != 0
        sequenceNumber = (UInt16(data[2]) << 8) | UInt16(data[3])
        timestamp = (UInt32(data[4]) << 24) | (UInt32(data[5]) << 16) | (UInt32(data[6]) << 8) | UInt32(data[7])
        ssrc = (UInt32(data[8]) << 24) | (UInt32(data[9]) << 16) | (UInt32(data[10]) << 8) | UInt32(data[11])

        var offset = 12 + (csrcCount * 4)
        guard data.count >= offset else {
            return nil
        }

        if hasExtension {
            guard data.count >= offset + 4 else {
                return nil
            }
            let extensionLengthWords = (UInt16(data[offset + 2]) << 8) | UInt16(data[offset + 3])
            offset += 4 + (Int(extensionLengthWords) * 4)
            guard data.count >= offset else {
                return nil
            }
        }

        headerLength = offset
        payload = data.subdata(in: offset..<data.count)
    }
}

enum AirPlayAACEldPayload {
    private static let syncPrefix: UInt8 = 0x8C

    static func isAACEldFrameStart(_ byte: UInt8) -> Bool {
        switch byte {
        case 0x8C, 0x8D, 0x8E, 0x80, 0x81, 0x82:
            return true
        default:
            return false
        }
    }

    static func isALACFrameStart(_ byte: UInt8) -> Bool {
        byte == 0x20
    }

    static func normalizedFrames(from payload: Data, compressionType: Int) -> [Data] {
        guard !payload.isEmpty else {
            airPlayAudioSinkLog.debug("[AirPlayAACEldPayload] normalize branch=EMPTY")
            return []
        }

        guard !isNoDataMarker(payload) else {
            airPlayAudioSinkLog.debug("[AirPlayAACEldPayload] normalize branch=NO_DATA_MARKER")
            return []
        }

        let stripped = stripAirPlaySyncByteIfNeeded(payload, compressionType: compressionType)
        guard !stripped.isEmpty else {
            airPlayAudioSinkLog.debug("[AirPlayAACEldPayload] normalize branch=STRIPPED_EMPTY")
            return []
        }

        if let first = stripped.first, isAACEldFrameStart(first) {
            airPlayAudioSinkLog.debug("[AirPlayAACEldPayload] normalize branch=WHOLE_AAC_ELD bytes=\(stripped.count)")
            return [stripped]
        }

        let frames = extractFrames(from: stripped, compressionType: compressionType)
        guard !frames.isEmpty else {
            airPlayAudioSinkLog.warning("[AirPlayAACEldPayload] normalize branch=NO_FRAMES payloadBytes=\(payload.count) strippedBytes=\(stripped.count) ct=\(compressionType)")
            return []
        }

        airPlayAudioSinkLog.debug("[AirPlayAACEldPayload] normalize branch=AU_HEADERS frames=\(frames.count) payloadBytes=\(payload.count) strippedBytes=\(stripped.count)")
        return frames
            .filter { !$0.isEmpty }
            .map { withSyncPrefixIfNeeded($0) }
    }

    private static func stripAirPlaySyncByteIfNeeded(_ payload: Data, compressionType: Int) -> Data {
        guard payload.count > 1 else {
            airPlayAudioSinkLog.debug("[AirPlayAACEldPayload] strip-sync branch=TOO_SHORT bytes=\(payload.count)")
            return payload
        }

        if let first = payload.first, isAACEldFrameStart(first) || isALACFrameStart(first) {
            airPlayAudioSinkLog.debug("[AirPlayAACEldPayload] strip-sync branch=ALREADY_FRAME first=0x\(String(format: "%02X", first), privacy: .public)")
            return payload
        }

        if !extractFrames(from: payload, compressionType: compressionType).isEmpty {
            airPlayAudioSinkLog.debug("[AirPlayAACEldPayload] strip-sync branch=AU_HEADERS_WITHOUT_SYNC bytes=\(payload.count)")
            return payload
        }

        let rest = payload.dropFirstData()
        if let first = rest.first,
           isAACEldFrameStart(first) || !extractFrames(from: rest, compressionType: compressionType).isEmpty {
            airPlayAudioSinkLog.info("[AirPlayAACEldPayload] strip-sync branch=REMOVED_SYNC_STATUS originalBytes=\(payload.count) strippedBytes=\(rest.count)")
            return rest
        }

        airPlayAudioSinkLog.debug("[AirPlayAACEldPayload] strip-sync branch=UNCHANGED bytes=\(payload.count)")
        return payload
    }

    private static func extractFrames(from payload: Data, compressionType: Int) -> [Data] {
        guard !payload.isEmpty, !isNoDataMarker(payload) else {
            airPlayAudioSinkLog.debug("[AirPlayAACEldPayload] extract branch=EMPTY_OR_NO_DATA bytes=\(payload.count) ct=\(compressionType)")
            return []
        }

        if let first = payload.first, isAACEldFrameStart(first) || isALACFrameStart(first) {
            airPlayAudioSinkLog.debug("[AirPlayAACEldPayload] extract branch=WHOLE_FRAME bytes=\(payload.count) first=0x\(String(format: "%02X", first), privacy: .public)")
            return [payload]
        }

        guard payload.count >= 4 else {
            airPlayAudioSinkLog.debug("[AirPlayAACEldPayload] extract branch=TOO_SHORT bytes=\(payload.count)")
            return []
        }

        let auHeadersLengthBits = (Int(payload[0]) << 8) | Int(payload[1])
        let frameCount = auHeadersLengthBits / 16
        guard frameCount > 0, frameCount <= 32 else {
            airPlayAudioSinkLog.warning("[AirPlayAACEldPayload] extract branch=INVALID_FRAME_COUNT frameCount=\(frameCount) headerBits=\(auHeadersLengthBits) bytes=\(payload.count)")
            return []
        }

        let headerBytes = 2 + (frameCount * 2)
        guard payload.count >= headerBytes + 1 else {
            airPlayAudioSinkLog.warning("[AirPlayAACEldPayload] extract branch=TRUNCATED_HEADERS frameCount=\(frameCount) headerBytes=\(headerBytes) bytes=\(payload.count)")
            return []
        }

        var frames: [Data] = []
        frames.reserveCapacity(frameCount)
        var offset = headerBytes
        for index in 0..<frameCount {
            let hi = payload[2 + (index * 2)]
            let lo = payload[2 + (index * 2) + 1]
            let auHeader = (Int(hi) << 8) | Int(lo)
            let frameLength = auHeader >> 3
            guard frameLength > 0 else {
                airPlayAudioSinkLog.warning("[AirPlayAACEldPayload] extract branch=ZERO_FRAME index=\(index) auHeader=\(auHeader)")
                break
            }
            guard offset + frameLength <= payload.count else {
                airPlayAudioSinkLog.warning("[AirPlayAACEldPayload] extract branch=TRUNCATED_FRAME index=\(index) frameLength=\(frameLength) offset=\(offset) bytes=\(payload.count)")
                break
            }
            frames.append(payload.subdata(in: offset..<(offset + frameLength)))
            offset += frameLength
        }

        airPlayAudioSinkLog.debug("[AirPlayAACEldPayload] extract branch=OK requestedFrames=\(frameCount) parsedFrames=\(frames.count) bytes=\(payload.count)")
        return frames
    }

    private static func withSyncPrefixIfNeeded(_ frame: Data) -> Data {
        guard let first = frame.first, !isAACEldFrameStart(first) else {
            airPlayAudioSinkLog.debug("[AirPlayAACEldPayload] sync-prefix branch=ALREADY_PRESENT bytes=\(frame.count)")
            return frame
        }

        var output = Data([syncPrefix])
        output.append(frame)
        airPlayAudioSinkLog.debug("[AirPlayAACEldPayload] sync-prefix branch=PREPENDED originalBytes=\(frame.count) outputBytes=\(output.count)")
        return output
    }

    private static func isNoDataMarker(_ payload: Data) -> Bool {
        payload == AirPlayAudioRTPPacket.noDataMarker
    }
}

enum AirPlayAudioCryptor {
    private static let aes128ByteCount = kCCKeySizeAES128
    private static let blockByteCount = kCCBlockSizeAES128

    static func decryptCBCPayload(_ payload: Data, key: Data, iv: Data) throws -> Data {
        guard key.count == aes128ByteCount else {
            throw AirPlayAudioPlaybackError.invalidAESKeyLength(key.count)
        }
        guard iv.count == aes128ByteCount else {
            throw AirPlayAudioPlaybackError.invalidAESIVLength(iv.count)
        }
        guard !payload.isEmpty else {
            return Data()
        }

        let encryptedLength = (payload.count / blockByteCount) * blockByteCount
        var output = Data(count: payload.count)

        if encryptedLength > 0 {
            var moved = 0
            let status = output.withUnsafeMutableBytes { outputBuffer in
                payload.withUnsafeBytes { payloadBuffer in
                    key.withUnsafeBytes { keyBuffer in
                        iv.withUnsafeBytes { ivBuffer in
                            CCCrypt(
                                CCOperation(kCCDecrypt),
                                CCAlgorithm(kCCAlgorithmAES),
                                CCOptions(0),
                                keyBuffer.baseAddress,
                                key.count,
                                ivBuffer.baseAddress,
                                payloadBuffer.baseAddress,
                                encryptedLength,
                                outputBuffer.baseAddress,
                                encryptedLength,
                                &moved
                            )
                        }
                    }
                }
            }
            guard status == kCCSuccess else {
                throw AirPlayAudioPlaybackError.aesCBCDecryptFailed(CCCryptorStatus(status))
            }
            guard moved == encryptedLength else {
                throw AirPlayAudioPlaybackError.aesCBCOutputLengthMismatch(expected: encryptedLength, actual: moved)
            }
        }

        if payload.count > encryptedLength {
            payload.withUnsafeBytes { payloadBuffer in
                output.withUnsafeMutableBytes { outputBuffer in
                    guard let source = payloadBuffer.baseAddress,
                          let destination = outputBuffer.baseAddress else {
                        return
                    }
                    destination
                        .advanced(by: encryptedLength)
                        .copyMemory(
                            from: source.advanced(by: encryptedLength),
                            byteCount: payload.count - encryptedLength
                        )
                }
            }
        }

        return output
    }
}

enum AirPlayAudioPlaybackError: LocalizedError {
    case invalidAESKeyLength(Int)
    case invalidAESIVLength(Int)
    case aesCBCDecryptFailed(CCCryptorStatus)
    case aesCBCOutputLengthMismatch(expected: Int, actual: Int)
    case audioConverterCreateFailed(OSStatus)

    var errorDescription: String? {
        switch self {
        case .invalidAESKeyLength(let length):
            return "AES key length \(length) is invalid"
        case .invalidAESIVLength(let length):
            return "AES IV length \(length) is invalid"
        case .aesCBCDecryptFailed(let status):
            return "AES-CBC audio decrypt failed with status \(status)"
        case .aesCBCOutputLengthMismatch(let expected, let actual):
            return "AES-CBC audio decrypt output length \(actual), expected \(expected)"
        case .audioConverterCreateFailed(let status):
            return "AAC-ELD converter create failed with status \(status)"
        }
    }
}

final class AirPlayAudioSinkServer {
    enum Channel: String {
        case data
        case control
    }

    enum Event {
        case ready(dataPort: UInt16, controlPort: UInt16)
        case failed(String)
        case packet(channel: Channel, bytes: Int, count: Int)
        case clientState(channel: Channel, state: String)
        case playback(AirPlayAudioPlaybackSnapshot)
        case stopped
    }

    private final class ListenerContext {
        let channel: Channel
        var listener: NWListener?
        var connections: [ObjectIdentifier: NWConnection] = [:]
        var packetCount = 0

        init(channel: Channel) {
            self.channel = channel
        }
    }

    private let queue: DispatchQueue
    private let onEvent: (Event) -> Void
    private var playbackConfiguration: AirPlayAudioPlaybackConfiguration?
    private let dataContext = ListenerContext(channel: .data)
    private let controlContext = ListenerContext(channel: .control)
    private var dataPort: UInt16?
    private var controlPort: UInt16?
    private var deliveredReady = false
    private var playbackPipeline: AirPlayAudioPlaybackPipeline?

    var modeDescription: String {
        playbackConfiguration == nil ? "no-output" : "playback"
    }

    var canInstallPlaybackConfiguration: Bool {
        playbackConfiguration == nil && playbackPipeline == nil
    }

    init(
        queue: DispatchQueue,
        playbackConfiguration: AirPlayAudioPlaybackConfiguration? = nil,
        onEvent: @escaping (Event) -> Void
    ) {
        self.queue = queue
        self.playbackConfiguration = playbackConfiguration
        self.onEvent = onEvent
    }

    func start() {
        if let playbackConfiguration {
            airPlayAudioSinkLog.info("[AirPlayAudioSink] start requested \(playbackConfiguration.diagnosticDescription, privacy: .public)")
            startPlaybackPipeline(playbackConfiguration, reason: "initial start")
        } else {
            airPlayAudioSinkLog.warning("[AirPlayAudioSink] start requested mode=no-output reason=audio-key-material-unavailable")
            onEvent(.playback(AirPlayAudioPlaybackSnapshot(
                state: "no-output",
                receivedPackets: 0,
                decodedPackets: 0,
                droppedPackets: 0,
                bufferedMilliseconds: 0,
                sampleRate: 0,
                channelCount: 0,
                lastDropReason: "audio key material unavailable"
            )))
        }
        startListener(for: dataContext)
        startListener(for: controlContext)
    }

    @discardableResult
    func installPlaybackConfiguration(
        _ configuration: AirPlayAudioPlaybackConfiguration,
        reason: String
    ) -> Bool {
        guard canInstallPlaybackConfiguration else {
            airPlayAudioSinkLog.info("[AirPlayAudioSink] playback install skipped reason=\(reason, privacy: .public) mode=\(self.modeDescription, privacy: .public) pipelinePresent=\(self.playbackPipeline != nil)")
            return false
        }

        airPlayAudioSinkLog.info("[AirPlayAudioSink] playback install requested reason=\(reason, privacy: .public) \(configuration.diagnosticDescription, privacy: .public)")
        playbackConfiguration = configuration
        startPlaybackPipeline(configuration, reason: reason)
        return true
    }

    func stop(reason: String) {
        airPlayAudioSinkLog.info("[AirPlayAudioSink] stop requested reason=\(reason, privacy: .public) dataPackets=\(self.dataContext.packetCount) controlPackets=\(self.controlContext.packetCount)")
        playbackPipeline?.stop(reason: reason)
        playbackPipeline = nil
        stop(context: dataContext)
        stop(context: controlContext)
        dataPort = nil
        controlPort = nil
        deliveredReady = false
        onEvent(.stopped)
    }

    private func startPlaybackPipeline(
        _ configuration: AirPlayAudioPlaybackConfiguration,
        reason: String
    ) {
        airPlayAudioSinkLog.info("[AirPlayAudioSink] playback pipeline start reason=\(reason, privacy: .public) \(configuration.diagnosticDescription, privacy: .public)")
        let pipeline = AirPlayAudioPlaybackPipeline(
            configuration: configuration,
            callbackQueue: queue
        ) { [weak self] snapshot in
            self?.onEvent(.playback(snapshot))
        }
        playbackPipeline = pipeline
        pipeline.start()
    }

    private func startListener(for context: ListenerContext) {
        guard context.listener == nil else {
            airPlayAudioSinkLog.info("[AirPlayAudioSink] listener start skipped channel=\(context.channel.rawValue, privacy: .public) reason=already-active")
            return
        }

        do {
            let listener = try NWListener(using: .udp)
            context.listener = listener
            listener.stateUpdateHandler = { [weak self, weak context] state in
                guard let self, let context else { return }
                self.handleListenerState(state, context: context)
            }
            listener.newConnectionHandler = { [weak self, weak context] connection in
                guard let self, let context else { return }
                self.accept(connection, context: context)
            }
            listener.start(queue: queue)
            airPlayAudioSinkLog.info("[AirPlayAudioSink] listener start requested channel=\(context.channel.rawValue, privacy: .public) protocol=udp port=system-assigned")
        } catch {
            let reason = "\(context.channel.rawValue) audio sink listener create failed: \(error.localizedDescription)"
            airPlayAudioSinkLog.error("[AirPlayAudioSink] listener create failed channel=\(context.channel.rawValue, privacy: .public) error=\(error.localizedDescription, privacy: .public)")
            onEvent(.failed(reason))
        }
    }

    private func stop(context: ListenerContext) {
        for connection in context.connections.values {
            connection.cancel()
        }
        context.connections.removeAll()
        context.listener?.cancel()
        context.listener = nil
        context.packetCount = 0
    }

    private func handleListenerState(_ state: NWListener.State, context: ListenerContext) {
        switch state {
        case .ready:
            guard let port = context.listener?.port?.rawValue else {
                let reason = "\(context.channel.rawValue) audio sink listener ready without a port"
                airPlayAudioSinkLog.error("[AirPlayAudioSink] listener ready without port channel=\(context.channel.rawValue, privacy: .public)")
                onEvent(.failed(reason))
                return
            }
            switch context.channel {
            case .data:
                dataPort = port
            case .control:
                controlPort = port
            }
            airPlayAudioSinkLog.info("[AirPlayAudioSink] listener ready channel=\(context.channel.rawValue, privacy: .public) port=\(port)")
            deliverReadyIfPossible()
        case .waiting(let error):
            let reason = "\(context.channel.rawValue) audio sink listener waiting: \(error.localizedDescription)"
            airPlayAudioSinkLog.warning("[AirPlayAudioSink] listener waiting channel=\(context.channel.rawValue, privacy: .public) error=\(error.localizedDescription, privacy: .public)")
            onEvent(.failed(reason))
        case .failed(let error):
            let reason = "\(context.channel.rawValue) audio sink listener failed: \(error.localizedDescription)"
            airPlayAudioSinkLog.error("[AirPlayAudioSink] listener failed channel=\(context.channel.rawValue, privacy: .public) error=\(error.localizedDescription, privacy: .public)")
            onEvent(.failed(reason))
        case .cancelled:
            airPlayAudioSinkLog.info("[AirPlayAudioSink] listener cancelled channel=\(context.channel.rawValue, privacy: .public)")
        case .setup:
            airPlayAudioSinkLog.info("[AirPlayAudioSink] listener state=setup channel=\(context.channel.rawValue, privacy: .public)")
        @unknown default:
            airPlayAudioSinkLog.warning("[AirPlayAudioSink] listener unknown state channel=\(context.channel.rawValue, privacy: .public)")
        }
    }

    private func deliverReadyIfPossible() {
        guard !deliveredReady else {
            airPlayAudioSinkLog.info("[AirPlayAudioSink] ready check branch=already-delivered")
            return
        }
        guard let dataPort, let controlPort else {
            airPlayAudioSinkLog.info("[AirPlayAudioSink] ready check branch=waiting dataPort=\(self.dataPort.map(String.init) ?? "nil", privacy: .public) controlPort=\(self.controlPort.map(String.init) ?? "nil", privacy: .public)")
            return
        }

        deliveredReady = true
        airPlayAudioSinkLog.info("[AirPlayAudioSink] ready mode=\(self.modeDescription, privacy: .public) dataPort=\(dataPort) controlPort=\(controlPort)")
        onEvent(.ready(dataPort: dataPort, controlPort: controlPort))
    }

    private func accept(_ connection: NWConnection, context: ListenerContext) {
        let id = ObjectIdentifier(connection)
        context.connections[id] = connection
        airPlayAudioSinkLog.info("[AirPlayAudioSink] client accepted channel=\(context.channel.rawValue, privacy: .public) endpoint=\(String(describing: connection.endpoint), privacy: .public)")
        connection.stateUpdateHandler = { [weak self, weak connection, weak context] state in
            guard let self, let connection, let context else { return }
            self.handleConnectionState(state, connection: connection, context: context)
        }
        connection.start(queue: queue)
    }

    private func handleConnectionState(_ state: NWConnection.State, connection: NWConnection, context: ListenerContext) {
        switch state {
        case .ready:
            airPlayAudioSinkLog.info("[AirPlayAudioSink] client ready channel=\(context.channel.rawValue, privacy: .public)")
            onEvent(.clientState(channel: context.channel, state: "ready"))
            receiveMessage(on: connection, context: context)
        case .waiting(let error):
            airPlayAudioSinkLog.warning("[AirPlayAudioSink] client waiting channel=\(context.channel.rawValue, privacy: .public) error=\(error.localizedDescription, privacy: .public)")
            onEvent(.clientState(channel: context.channel, state: "waiting: \(error.localizedDescription)"))
        case .failed(let error):
            airPlayAudioSinkLog.error("[AirPlayAudioSink] client failed channel=\(context.channel.rawValue, privacy: .public) error=\(error.localizedDescription, privacy: .public)")
            context.connections.removeValue(forKey: ObjectIdentifier(connection))
            onEvent(.clientState(channel: context.channel, state: "failed: \(error.localizedDescription)"))
        case .cancelled:
            airPlayAudioSinkLog.info("[AirPlayAudioSink] client cancelled channel=\(context.channel.rawValue, privacy: .public)")
            context.connections.removeValue(forKey: ObjectIdentifier(connection))
            onEvent(.clientState(channel: context.channel, state: "cancelled"))
        case .setup, .preparing:
            airPlayAudioSinkLog.info("[AirPlayAudioSink] client state=\(String(describing: state), privacy: .public) channel=\(context.channel.rawValue, privacy: .public)")
        @unknown default:
            airPlayAudioSinkLog.warning("[AirPlayAudioSink] client unknown state channel=\(context.channel.rawValue, privacy: .public)")
        }
    }

    private func receiveMessage(on connection: NWConnection, context: ListenerContext) {
        connection.receiveMessage { [weak self, weak connection, weak context] data, _, isComplete, error in
            guard let self, let connection, let context else { return }

            if let error {
                airPlayAudioSinkLog.error("[AirPlayAudioSink] receive failed channel=\(context.channel.rawValue, privacy: .public) error=\(error.localizedDescription, privacy: .public)")
                self.onEvent(.clientState(channel: context.channel, state: "receive failed: \(error.localizedDescription)"))
                return
            }

            let byteCount = data?.count ?? 0
            if byteCount == 0 {
                if isComplete {
                    airPlayAudioSinkLog.info("[AirPlayAudioSink] receive complete channel=\(context.channel.rawValue, privacy: .public) bytes=0 action=wait")
                    self.onEvent(.clientState(channel: context.channel, state: "complete-empty"))
                } else {
                    airPlayAudioSinkLog.debug("[AirPlayAudioSink] receive empty channel=\(context.channel.rawValue, privacy: .public) action=continue")
                    self.receiveMessage(on: connection, context: context)
                }
                return
            }

            context.packetCount += 1
            let actionDescription = self.handlePacket(data ?? Data(), channel: context.channel, count: context.packetCount)
            if context.packetCount <= 20 || context.packetCount % 120 == 0 {
                let rtpDescription = Self.rtpDescription(data)
                airPlayAudioSinkLog.info("[AirPlayAudioSink] packet channel=\(context.channel.rawValue, privacy: .public) count=\(context.packetCount) bytes=\(byteCount) complete=\(isComplete) action=\(actionDescription, privacy: .public) \(rtpDescription, privacy: .public)")
            } else {
                airPlayAudioSinkLog.debug("[AirPlayAudioSink] packet channel=\(context.channel.rawValue, privacy: .public) count=\(context.packetCount) bytes=\(byteCount) action=\(actionDescription, privacy: .public)")
            }
            self.onEvent(.packet(channel: context.channel, bytes: byteCount, count: context.packetCount))
            self.receiveMessage(on: connection, context: context)
        }
    }

    private func handlePacket(_ data: Data, channel: Channel, count: Int) -> String {
        guard channel == .data else {
            airPlayAudioSinkLog.debug("[AirPlayAudioSink] packet branch=CONTROL_IGNORED count=\(count) bytes=\(data.count)")
            return "control-ignored"
        }

        guard let playbackPipeline else {
            airPlayAudioSinkLog.warning("[AirPlayAudioSink] packet branch=NO_PLAYBACK_PIPELINE count=\(count) bytes=\(data.count) action=dropped")
            return "dropped-no-playback-pipeline"
        }

        return playbackPipeline.handlePacket(data, transportPacketCount: count)
    }

    private static func rtpDescription(_ data: Data?) -> String {
        guard let data, data.count >= 12 else {
            return "rtp=too-short"
        }
        let payloadType = data[1] & 0x7F
        let sequenceNumber = (UInt16(data[2]) << 8) | UInt16(data[3])
        let timestamp = (UInt32(data[4]) << 24) | (UInt32(data[5]) << 16) | (UInt32(data[6]) << 8) | UInt32(data[7])
        return "rtpPayloadType=\(payloadType) seq=\(sequenceNumber) timestamp=\(timestamp)"
    }
}

private struct AirPlayDecodedAudioFrame {
    let pcmBytes: Data
    let frameCount: Int
}

enum AirPlayAudioPCMLayoutCopyError: LocalizedError, Equatable {
    case invalidLayout(frameCount: Int, channelCount: Int)
    case pcmByteCountOverflow(frameCount: Int, channelCount: Int)
    case pcmByteCountMismatch(expected: Int, actual: Int)
    case unsupportedPlaybackFormat(commonFormat: AVAudioCommonFormat, isInterleaved: Bool)
    case frameCapacityTooSmall(capacity: AVAudioFrameCount, requested: Int)
    case channelCountMismatch(bufferChannels: Int, requested: Int)
    case missingFloatChannelData

    var errorDescription: String? {
        switch self {
        case let .invalidLayout(frameCount, channelCount):
            "invalid layout frames=\(frameCount) channels=\(channelCount)"
        case let .pcmByteCountOverflow(frameCount, channelCount):
            "PCM byte count overflow frames=\(frameCount) channels=\(channelCount)"
        case let .pcmByteCountMismatch(expected, actual):
            "PCM byte count mismatch expected=\(expected) actual=\(actual)"
        case let .unsupportedPlaybackFormat(commonFormat, isInterleaved):
            "unsupported playback format common=\(commonFormat.rawValue) interleaved=\(isInterleaved)"
        case let .frameCapacityTooSmall(capacity, requested):
            "frame capacity too small capacity=\(capacity) requested=\(requested)"
        case let .channelCountMismatch(bufferChannels, requested):
            "channel count mismatch bufferChannels=\(bufferChannels) requested=\(requested)"
        case .missingFloatChannelData:
            "missing Float32 channel data"
        }
    }
}

enum AirPlayAudioPCMLayout {
    static func copyInterleavedFloat32(
        _ pcmBytes: Data,
        frameCount: Int,
        channelCount: Int,
        into buffer: AVAudioPCMBuffer
    ) throws {
        guard frameCount >= 0, channelCount > 0 else {
            throw AirPlayAudioPCMLayoutCopyError.invalidLayout(
                frameCount: frameCount,
                channelCount: channelCount
            )
        }

        let (sampleCount, sampleCountOverflow) = frameCount.multipliedReportingOverflow(
            by: channelCount
        )
        let (expectedByteCount, byteCountOverflow) = sampleCount.multipliedReportingOverflow(
            by: MemoryLayout<Float>.size
        )
        guard !sampleCountOverflow, !byteCountOverflow else {
            throw AirPlayAudioPCMLayoutCopyError.pcmByteCountOverflow(
                frameCount: frameCount,
                channelCount: channelCount
            )
        }

        guard pcmBytes.count == expectedByteCount else {
            throw AirPlayAudioPCMLayoutCopyError.pcmByteCountMismatch(
                expected: expectedByteCount,
                actual: pcmBytes.count
            )
        }

        guard buffer.format.commonFormat == .pcmFormatFloat32,
              buffer.format.isInterleaved == false else {
            throw AirPlayAudioPCMLayoutCopyError.unsupportedPlaybackFormat(
                commonFormat: buffer.format.commonFormat,
                isInterleaved: buffer.format.isInterleaved
            )
        }

        guard frameCount <= Int(buffer.frameCapacity) else {
            throw AirPlayAudioPCMLayoutCopyError.frameCapacityTooSmall(
                capacity: buffer.frameCapacity,
                requested: frameCount
            )
        }

        let bufferChannelCount = Int(buffer.format.channelCount)
        guard bufferChannelCount >= channelCount else {
            throw AirPlayAudioPCMLayoutCopyError.channelCountMismatch(
                bufferChannels: bufferChannelCount,
                requested: channelCount
            )
        }

        guard let channelData = buffer.floatChannelData else {
            throw AirPlayAudioPCMLayoutCopyError.missingFloatChannelData
        }

        pcmBytes.withUnsafeBytes { rawBuffer in
            guard !rawBuffer.isEmpty else { return }
            for frameIndex in 0..<frameCount {
                for channelIndex in 0..<channelCount {
                    let sampleIndex = frameIndex * channelCount + channelIndex
                    let byteOffset = sampleIndex * MemoryLayout<Float>.size
                    channelData[channelIndex][frameIndex] = rawBuffer.loadUnaligned(
                        fromByteOffset: byteOffset,
                        as: Float.self
                    )
                }
            }
        }

        buffer.frameLength = AVAudioFrameCount(frameCount)
    }
}

private final class AirPlayGStreamerAACELDDecoder {
    private struct PCMMetadata {
        let sequenceNumber: UInt16
        let rtpTimestamp: UInt32
        let submittedAccessUnits: Int
    }

    private let executablePath: String
    private let sampleRate: Double
    private let channelCount: Int
    private let callbackQueue: DispatchQueue
    private let onPCM: (AirPlayDecodedAudioFrame, UInt16, UInt32, Int) -> Void
    private var process: Process?
    private var inputPipe: Pipe?
    private var outputPipe: Pipe?
    private var errorPipe: Pipe?
    private var pcmRemainder = Data()
    private let metadataLock = NSLock()
    private var lastMetadata = PCMMetadata(sequenceNumber: 0, rtpTimestamp: 0, submittedAccessUnits: 0)
    private var submittedAccessUnits = 0
    private var submittedBytes = 0
    private var emittedPCMBytes = 0
    private var emittedPCMChunks = 0
    private var loggedFirstPCM = false
    private var loggedNoPCMYet = false
    private var isStopping = false

    static func makeIfAvailable(
        sampleRate: Double,
        channelCount: Int,
        callbackQueue: DispatchQueue,
        onPCM: @escaping (AirPlayDecodedAudioFrame, UInt16, UInt32, Int) -> Void
    ) -> AirPlayGStreamerAACELDDecoder? {
        let candidates = AirPlayGStreamerAACELDDecoderSupport.executableCandidates()
        guard let executablePath = AirPlayGStreamerAACELDDecoderSupport.locateExecutable() else {
            airPlayAudioSinkLog.warning("[AirPlayGStreamerAACELD] locate branch=NOT_FOUND candidates=\(candidates.prefix(8).joined(separator: ","), privacy: .public)")
            return nil
        }

        airPlayAudioSinkLog.info("[AirPlayGStreamerAACELD] locate branch=FOUND path=\(executablePath, privacy: .public)")
        return AirPlayGStreamerAACELDDecoder(
            executablePath: executablePath,
            sampleRate: sampleRate,
            channelCount: channelCount,
            callbackQueue: callbackQueue,
            onPCM: onPCM
        )
    }

    private init(
        executablePath: String,
        sampleRate: Double,
        channelCount: Int,
        callbackQueue: DispatchQueue,
        onPCM: @escaping (AirPlayDecodedAudioFrame, UInt16, UInt32, Int) -> Void
    ) {
        self.executablePath = executablePath
        self.sampleRate = sampleRate
        self.channelCount = channelCount
        self.callbackQueue = callbackQueue
        self.onPCM = onPCM
    }

    deinit {
        stop(reason: "deinit")
    }

    var isRunning: Bool {
        process?.isRunning == true
    }

    func start() -> Bool {
        if isRunning {
            airPlayAudioSinkLog.debug("[AirPlayGStreamerAACELD] start branch=ALREADY_RUNNING path=\(self.executablePath, privacy: .public)")
            return true
        }

        stopProcessOnly(reason: "restart before start")
        let process = Process()
        let inputPipe = Pipe()
        let outputPipe = Pipe()
        let errorPipe = Pipe()
        let aacCaps = AirPlayGStreamerAACELDDecoderSupport.aacELDCaps(
            sampleRate: sampleRate,
            channelCount: channelCount
        )
        let pcmCaps = AirPlayGStreamerAACELDDecoderSupport.pcmCaps(
            sampleRate: sampleRate,
            channelCount: channelCount
        )
        let useAACParse = ProcessInfo.processInfo.environment["SPECCHIO_AIRPLAY_AUDIO_NO_AACPARSE"] != "1"
        var arguments = [
            "-q",
            "fdsrc",
            "fd=0",
            "blocksize=4096",
            "!",
            "capsfilter",
            "caps=\"\(aacCaps)\"",
            "!",
        ]
        if useAACParse {
            arguments.append(contentsOf: ["aacparse", "!"])
        }
        arguments.append(contentsOf: [
            "queue",
            "max-size-buffers=0",
            "max-size-time=0",
            "!",
            "avdec_aac",
            "!",
            "audioconvert",
            "!",
            "audioresample",
            "!",
            "capsfilter",
            "caps=\"\(pcmCaps)\"",
            "!",
            "fdsink",
            "fd=1",
            "sync=false",
        ])

        process.executableURL = URL(fileURLWithPath: executablePath)
        process.arguments = arguments
        process.environment = AirPlayGStreamerAACELDDecoderSupport.spawnEnvironment()
        process.standardInput = inputPipe
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        outputPipe.fileHandleForReading.readabilityHandler = { [weak self] fileHandle in
            let data = fileHandle.availableData
            guard !data.isEmpty else {
                fileHandle.readabilityHandler = nil
                return
            }
            self?.callbackQueue.async {
                self?.handlePCMOutput(data)
            }
        }

        errorPipe.fileHandleForReading.readabilityHandler = { fileHandle in
            let data = fileHandle.availableData
            guard !data.isEmpty else {
                fileHandle.readabilityHandler = nil
                return
            }
            let message = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !message.isEmpty else { return }
            airPlayAudioSinkLog.warning("[AirPlayGStreamerAACELD] stderr \(message, privacy: .public)")
        }

        process.terminationHandler = { [weak self] terminatedProcess in
            self?.callbackQueue.async {
                self?.handleTermination(status: terminatedProcess.terminationStatus)
            }
        }

        do {
            try process.run()
        } catch {
            outputPipe.fileHandleForReading.readabilityHandler = nil
            errorPipe.fileHandleForReading.readabilityHandler = nil
            airPlayAudioSinkLog.error("[AirPlayGStreamerAACELD] start branch=SPAWN_FAILED path=\(self.executablePath, privacy: .public) error=\(error.localizedDescription, privacy: .public)")
            return false
        }

        self.process = process
        self.inputPipe = inputPipe
        self.outputPipe = outputPipe
        self.errorPipe = errorPipe
        self.pcmRemainder.removeAll(keepingCapacity: true)
        self.isStopping = false
        self.loggedNoPCMYet = false

        airPlayAudioSinkLog.info("[AirPlayGStreamerAACELD] start branch=STARTED pid=\(process.processIdentifier) path=\(self.executablePath, privacy: .public) aacparse=\(useAACParse) aacCaps=\(aacCaps, privacy: .public) pcmCaps=\(pcmCaps, privacy: .public)")
        return true
    }

    func submit(
        frames: [Data],
        sequenceNumber: UInt16,
        rtpTimestamp: UInt32,
        transportPacketCount: Int
    ) -> Bool {
        guard !frames.isEmpty else {
            airPlayAudioSinkLog.debug("[AirPlayGStreamerAACELD] submit branch=NO_FRAMES seq=\(sequenceNumber) transportCount=\(transportPacketCount)")
            return true
        }

        guard isRunning || start() else {
            airPlayAudioSinkLog.warning("[AirPlayGStreamerAACELD] submit branch=START_FAILED seq=\(sequenceNumber) transportCount=\(transportPacketCount) frames=\(frames.count)")
            return false
        }

        guard let inputPipe else {
            airPlayAudioSinkLog.warning("[AirPlayGStreamerAACELD] submit branch=NO_STDIN seq=\(sequenceNumber) transportCount=\(transportPacketCount)")
            return false
        }

        updateMetadata(sequenceNumber: sequenceNumber, rtpTimestamp: rtpTimestamp)
        var bytesThisPacket = 0
        for frame in frames {
            do {
                try inputPipe.fileHandleForWriting.write(contentsOf: frame)
                bytesThisPacket += frame.count
                submittedBytes += frame.count
                submittedAccessUnits += 1
                updateMetadata(sequenceNumber: sequenceNumber, rtpTimestamp: rtpTimestamp)
            } catch {
                airPlayAudioSinkLog.warning("[AirPlayGStreamerAACELD] submit branch=WRITE_FAILED seq=\(sequenceNumber) transportCount=\(transportPacketCount) error=\(error.localizedDescription, privacy: .public)")
                stop(reason: "stdin write failed")
                return false
            }
        }

        if submittedAccessUnits <= 20 || submittedAccessUnits % 120 == 0 {
            airPlayAudioSinkLog.info("[AirPlayGStreamerAACELD] submit branch=WROTE seq=\(sequenceNumber) timestamp=\(rtpTimestamp) frames=\(frames.count) packetBytes=\(bytesThisPacket) submittedAUs=\(self.submittedAccessUnits) submittedBytes=\(self.submittedBytes) pcmChunks=\(self.emittedPCMChunks)")
        } else {
            airPlayAudioSinkLog.debug("[AirPlayGStreamerAACELD] submit branch=WROTE seq=\(sequenceNumber) frames=\(frames.count) packetBytes=\(bytesThisPacket)")
        }

        if !loggedNoPCMYet, submittedBytes >= 24_000, emittedPCMChunks == 0 {
            loggedNoPCMYet = true
            airPlayAudioSinkLog.warning("[AirPlayGStreamerAACELD] decode branch=NO_PCM_YET submittedBytes=\(self.submittedBytes) submittedAUs=\(self.submittedAccessUnits) hint=verify GStreamer avdec_aac/libav plugin")
        }
        return true
    }

    func stop(reason: String) {
        airPlayAudioSinkLog.info("[AirPlayGStreamerAACELD] stop requested reason=\(reason, privacy: .public) running=\(self.isRunning) submittedAUs=\(self.submittedAccessUnits) submittedBytes=\(self.submittedBytes) pcmChunks=\(self.emittedPCMChunks) pcmBytes=\(self.emittedPCMBytes)")
        stopProcessOnly(reason: reason)
        metadataLock.lock()
        lastMetadata = PCMMetadata(sequenceNumber: 0, rtpTimestamp: 0, submittedAccessUnits: 0)
        metadataLock.unlock()
        submittedAccessUnits = 0
        submittedBytes = 0
        emittedPCMBytes = 0
        emittedPCMChunks = 0
        loggedFirstPCM = false
        loggedNoPCMYet = false
        pcmRemainder.removeAll(keepingCapacity: false)
    }

    private func stopProcessOnly(reason: String) {
        isStopping = true
        outputPipe?.fileHandleForReading.readabilityHandler = nil
        errorPipe?.fileHandleForReading.readabilityHandler = nil
        inputPipe?.fileHandleForWriting.closeFile()
        if process?.isRunning == true {
            airPlayAudioSinkLog.info("[AirPlayGStreamerAACELD] process branch=TERMINATE reason=\(reason, privacy: .public) pid=\(self.process?.processIdentifier ?? -1)")
            process?.terminate()
        }
        process = nil
        inputPipe = nil
        outputPipe = nil
        errorPipe = nil
        isStopping = false
    }

    private func handlePCMOutput(_ data: Data) {
        pcmRemainder.append(data)
        let bytesPerFrame = max(1, channelCount) * MemoryLayout<Float>.size
        let alignedByteCount = (pcmRemainder.count / bytesPerFrame) * bytesPerFrame
        guard alignedByteCount > 0 else { return }

        let pcmBytes = Data(pcmRemainder.prefix(alignedByteCount))
        pcmRemainder.removeFirst(alignedByteCount)
        let frameCount = alignedByteCount / bytesPerFrame
        let metadata = currentMetadata()

        emittedPCMBytes += pcmBytes.count
        emittedPCMChunks += 1
        if !loggedFirstPCM {
            loggedFirstPCM = true
            airPlayAudioSinkLog.info("[AirPlayGStreamerAACELD] decode branch=FIRST_PCM bytes=\(pcmBytes.count) frames=\(frameCount) submittedAUs=\(metadata.submittedAccessUnits) seq=\(metadata.sequenceNumber) timestamp=\(metadata.rtpTimestamp)")
        } else if emittedPCMChunks <= 20 || emittedPCMChunks % 120 == 0 {
            airPlayAudioSinkLog.info("[AirPlayGStreamerAACELD] decode branch=PCM bytes=\(pcmBytes.count) frames=\(frameCount) chunks=\(self.emittedPCMChunks) seq=\(metadata.sequenceNumber) timestamp=\(metadata.rtpTimestamp)")
        }
        onPCM(
            AirPlayDecodedAudioFrame(pcmBytes: pcmBytes, frameCount: frameCount),
            metadata.sequenceNumber,
            metadata.rtpTimestamp,
            metadata.submittedAccessUnits
        )
    }

    private func handleTermination(status: Int32) {
        guard !isStopping else {
            airPlayAudioSinkLog.info("[AirPlayGStreamerAACELD] process branch=EXIT_DURING_STOP status=\(status)")
            return
        }
        let hadPCM = emittedPCMChunks > 0
        airPlayAudioSinkLog.warning("[AirPlayGStreamerAACELD] process branch=EXITED status=\(status) hadPCM=\(hadPCM) submittedAUs=\(self.submittedAccessUnits) submittedBytes=\(self.submittedBytes) pcmChunks=\(self.emittedPCMChunks)")
        outputPipe?.fileHandleForReading.readabilityHandler = nil
        errorPipe?.fileHandleForReading.readabilityHandler = nil
        process = nil
        inputPipe = nil
        outputPipe = nil
        errorPipe = nil
    }

    private func updateMetadata(sequenceNumber: UInt16, rtpTimestamp: UInt32) {
        metadataLock.lock()
        lastMetadata = PCMMetadata(
            sequenceNumber: sequenceNumber,
            rtpTimestamp: rtpTimestamp,
            submittedAccessUnits: submittedAccessUnits
        )
        metadataLock.unlock()
    }

    private func currentMetadata() -> PCMMetadata {
        metadataLock.lock()
        let metadata = lastMetadata
        metadataLock.unlock()
        return metadata
    }
}

private final class AirPlayAudioPlaybackPipeline {
    private let configuration: AirPlayAudioPlaybackConfiguration
    private let callbackQueue: DispatchQueue
    private let onSnapshot: (AirPlayAudioPlaybackSnapshot) -> Void
    private var gstreamerDecoder: AirPlayGStreamerAACELDDecoder?
    private var decoder: AirPlayAACELDDecoder?
    private var engine: AVAudioEngine?
    private var player: AVAudioPlayerNode?
    private var playbackFormat: AVAudioFormat?
    private var seenSequenceNumbers: Set<UInt16> = []
    private var jitterBuffer = ReplayKitAudioJitterBufferState()
    private var isPlayerStarted = false
    private var receivedPackets = 0
    private var decodedPackets = 0
    private var droppedPackets = 0
    private var lastDropReason: String?
    private var lastPacketArrivedAt: Date?

    init(
        configuration: AirPlayAudioPlaybackConfiguration,
        callbackQueue: DispatchQueue,
        onSnapshot: @escaping (AirPlayAudioPlaybackSnapshot) -> Void
    ) {
        self.configuration = configuration
        self.callbackQueue = callbackQueue
        self.onSnapshot = onSnapshot
    }

    func start() {
        airPlayAudioSinkLog.info("[AirPlayAudioPlayback] start requested \(self.configuration.diagnosticDescription, privacy: .public)")
        guard self.configuration.compressionType == 8 else {
            let reason = "unsupported compression type \(self.configuration.compressionType)"
            airPlayAudioSinkLog.warning("[AirPlayAudioPlayback] start branch=UNSUPPORTED_COMPRESSION reason=\(reason, privacy: .public)")
            publishSnapshot(state: "unsupported", dropReason: reason)
            return
        }

        guard self.configuration.key.count == kCCKeySizeAES128,
              self.configuration.iv.count == kCCBlockSizeAES128 else {
            let reason = "invalid AES material keyBytes=\(self.configuration.key.count) ivBytes=\(self.configuration.iv.count)"
            airPlayAudioSinkLog.error("[AirPlayAudioPlayback] start branch=INVALID_KEY_MATERIAL \(reason, privacy: .public)")
            publishSnapshot(state: "error", dropReason: reason)
            return
        }

        guard self.configuration.sampleRate > 0, self.configuration.channelCount > 0 else {
            let reason = "invalid audio format sampleRate=\(self.configuration.sampleRate) channels=\(self.configuration.channelCount)"
            airPlayAudioSinkLog.error("[AirPlayAudioPlayback] start branch=INVALID_FORMAT \(reason, privacy: .public)")
            publishSnapshot(state: "error", dropReason: reason)
            return
        }

        guard let playbackFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: self.configuration.sampleRate,
            channels: AVAudioChannelCount(self.configuration.channelCount),
            interleaved: false
        ) else {
            let reason = "AVAudioFormat creation failed"
            airPlayAudioSinkLog.error("[AirPlayAudioPlayback] engine branch=FORMAT_FAILED reason=\(reason, privacy: .public)")
            publishSnapshot(state: "error", dropReason: reason)
            return
        }
        airPlayAudioSinkLog.info("[AirPlayAudioPlayback] engine branch=FORMAT_READY common=\(playbackFormat.commonFormat.rawValue, privacy: .public) sampleRate=\(playbackFormat.sampleRate) channels=\(playbackFormat.channelCount) interleaved=\(playbackFormat.isInterleaved)")

        let engine = AVAudioEngine()
        let player = AVAudioPlayerNode()
        engine.attach(player)
        let mixerFormat = engine.mainMixerNode.outputFormat(forBus: 0)
        airPlayAudioSinkLog.info("[AirPlayAudioPlayback] engine branch=CONNECT playerFormatRate=\(playbackFormat.sampleRate) playerChannels=\(playbackFormat.channelCount) playerInterleaved=\(playbackFormat.isInterleaved) mixerRate=\(mixerFormat.sampleRate) mixerChannels=\(mixerFormat.channelCount) mixerInterleaved=\(mixerFormat.isInterleaved)")
        engine.connect(player, to: engine.mainMixerNode, format: playbackFormat)

        do {
            try engine.start()
            self.engine = engine
            self.player = player
            self.playbackFormat = playbackFormat
            self.jitterBuffer.reset()
            self.isPlayerStarted = false
            airPlayAudioSinkLog.info("[AirPlayAudioPlayback] engine branch=STARTED sampleRate=\(playbackFormat.sampleRate) channels=\(playbackFormat.channelCount) interleaved=\(playbackFormat.isInterleaved)")
            if let decoderError = startDecoderBackend() {
                player.stop()
                engine.stop()
                engine.detach(player)
                self.engine = nil
                self.player = nil
                self.playbackFormat = nil
                airPlayAudioSinkLog.error("[AirPlayAudioPlayback] decoder branch=NO_BACKEND error=\(decoderError, privacy: .public)")
                publishSnapshot(state: "error", dropReason: decoderError)
                return
            }
            publishSnapshot(state: "waiting", dropReason: nil)
        } catch {
            airPlayAudioSinkLog.error("[AirPlayAudioPlayback] engine branch=START_FAILED error=\(error.localizedDescription, privacy: .public)")
            publishSnapshot(state: "error", dropReason: error.localizedDescription)
        }
    }

    private func startDecoderBackend() -> String? {
        if let gstreamerDecoder = AirPlayGStreamerAACELDDecoder.makeIfAvailable(
            sampleRate: self.configuration.sampleRate,
            channelCount: self.configuration.channelCount,
            callbackQueue: callbackQueue,
            onPCM: { [weak self] frame, sequenceNumber, rtpTimestamp, submittedAccessUnits in
                self?.handleGStreamerPCM(
                    frame,
                    sequenceNumber: sequenceNumber,
                    rtpTimestamp: rtpTimestamp,
                    submittedAccessUnits: submittedAccessUnits
                )
            }
        ) {
            if gstreamerDecoder.start() {
                self.gstreamerDecoder = gstreamerDecoder
                self.decoder = nil
                airPlayAudioSinkLog.info("[AirPlayAudioPlayback] decoder branch=GSTREAMER_READY sampleRate=\(self.configuration.sampleRate) channels=\(self.configuration.channelCount) spf=\(self.configuration.samplesPerFrame)")
                return nil
            }
            airPlayAudioSinkLog.warning("[AirPlayAudioPlayback] decoder branch=GSTREAMER_START_FAILED action=fall-back-to-audiotoolbox")
        } else {
            airPlayAudioSinkLog.warning("[AirPlayAudioPlayback] decoder branch=GSTREAMER_UNAVAILABLE action=fall-back-to-audiotoolbox expected=AudioToolbox-may-produce-no-pcm")
        }

        do {
            decoder = try AirPlayAACELDDecoder(
                sampleRate: self.configuration.sampleRate,
                channelCount: self.configuration.channelCount,
                samplesPerFrame: self.configuration.samplesPerFrame
            )
            gstreamerDecoder = nil
            airPlayAudioSinkLog.info("[AirPlayAudioPlayback] decoder branch=AUDIOTOOLBOX_READY sampleRate=\(self.configuration.sampleRate) channels=\(self.configuration.channelCount) spf=\(self.configuration.samplesPerFrame)")
            return nil
        } catch {
            airPlayAudioSinkLog.error("[AirPlayAudioPlayback] decoder branch=AUDIOTOOLBOX_CREATE_FAILED error=\(error.localizedDescription, privacy: .public)")
            return error.localizedDescription
        }
    }

    func stop(reason: String) {
        airPlayAudioSinkLog.info("[AirPlayAudioPlayback] stop requested reason=\(reason, privacy: .public) received=\(self.receivedPackets) decoded=\(self.decodedPackets) dropped=\(self.droppedPackets) bufferedMs=\(self.jitterBuffer.bufferedMilliseconds)")
        gstreamerDecoder?.stop(reason: reason)
        player?.stop()
        engine?.stop()
        if let player, let engine {
            engine.detach(player)
        }
        player = nil
        engine = nil
        playbackFormat = nil
        gstreamerDecoder = nil
        decoder = nil
        self.seenSequenceNumbers.removeAll()
        self.jitterBuffer.reset()
        self.isPlayerStarted = false
        publishSnapshot(state: "stopped", dropReason: nil)
    }

    func handlePacket(_ data: Data, transportPacketCount: Int) -> String {
        self.receivedPackets += 1

        guard let packet = AirPlayAudioRTPPacket(data: data) else {
            recordDrop(reason: "malformed RTP", transportPacketCount: transportPacketCount, keepsPlaybackState: false)
            return "dropped-malformed-rtp"
        }

        guard packet.version == 2 else {
            recordDrop(reason: "unsupported RTP version \(packet.version)", transportPacketCount: transportPacketCount, keepsPlaybackState: false)
            return "dropped-rtp-version"
        }

        if self.seenSequenceNumbers.contains(packet.sequenceNumber) {
            airPlayAudioSinkLog.debug("[AirPlayAudioPlayback] packet branch=DUPLICATE seq=\(packet.sequenceNumber) transportCount=\(transportPacketCount) action=ignored")
            return "ignored-duplicate"
        }
        self.seenSequenceNumbers.insert(packet.sequenceNumber)
        if self.seenSequenceNumbers.count > 2048 {
            airPlayAudioSinkLog.info("[AirPlayAudioPlayback] sequence cache branch=RESET size=\(self.seenSequenceNumbers.count)")
            self.seenSequenceNumbers.removeAll(keepingCapacity: true)
            self.seenSequenceNumbers.insert(packet.sequenceNumber)
        }

        if packet.isHeaderOnly {
            airPlayAudioSinkLog.debug("[AirPlayAudioPlayback] packet branch=HEADER_ONLY seq=\(packet.sequenceNumber) timestamp=\(packet.timestamp) action=ignored")
            publishSnapshot(state: self.isPlayerStarted ? "live" : "waiting", dropReason: nil)
            return "ignored-header-only"
        }

        if packet.isNoDataMarker {
            airPlayAudioSinkLog.debug("[AirPlayAudioPlayback] packet branch=NO_DATA_MARKER seq=\(packet.sequenceNumber) timestamp=\(packet.timestamp) action=ignored")
            publishSnapshot(state: self.isPlayerStarted ? "live" : "waiting", dropReason: nil)
            return "ignored-no-data"
        }

        if self.configuration.compressionType == 2 && data.count == 44 {
            airPlayAudioSinkLog.info("[AirPlayAudioPlayback] packet branch=ALAC_FORMAT_ONLY seq=\(packet.sequenceNumber) bytes=\(data.count) action=ignored")
            publishSnapshot(state: self.isPlayerStarted ? "live" : "waiting", dropReason: nil)
            return "ignored-alac-format"
        }

        let decryptedPayload: Data
        do {
            decryptedPayload = try AirPlayAudioCryptor.decryptCBCPayload(
                packet.payload,
                key: self.configuration.key,
                iv: self.configuration.iv
            )
        } catch {
            recordDrop(reason: "decrypt failed: \(error.localizedDescription)", transportPacketCount: transportPacketCount, keepsPlaybackState: false)
            return "dropped-decrypt"
        }

        guard !decryptedPayload.isEmpty else {
            recordDrop(reason: "empty decrypted payload", transportPacketCount: transportPacketCount, keepsPlaybackState: false)
            return "dropped-empty-decrypted-payload"
        }

        let audioFrames = AirPlayAACEldPayload.normalizedFrames(
            from: decryptedPayload,
            compressionType: self.configuration.compressionType
        )
        guard !audioFrames.isEmpty else {
            recordDrop(reason: "AAC-ELD payload normalization produced no frames", transportPacketCount: transportPacketCount, keepsPlaybackState: false)
            return "dropped-no-aac-frames"
        }

        if let gstreamerDecoder {
            guard gstreamerDecoder.submit(
                frames: audioFrames,
                sequenceNumber: packet.sequenceNumber,
                rtpTimestamp: packet.timestamp,
                transportPacketCount: transportPacketCount
            ) else {
                recordDrop(reason: "GStreamer AAC-ELD submit failed", transportPacketCount: transportPacketCount, keepsPlaybackState: false)
                return "dropped-gstreamer-submit"
            }

            publishSnapshot(state: self.isPlayerStarted ? "live" : "decoding", dropReason: nil)
            return "submitted-gstreamer"
        }

        guard let decoder else {
            recordDrop(reason: "decoder unavailable", transportPacketCount: transportPacketCount, keepsPlaybackState: false)
            return "dropped-no-decoder"
        }

        var decodedFrames: [AirPlayDecodedAudioFrame] = []
        decodedFrames.reserveCapacity(audioFrames.count)
        for (frameIndex, audioFrame) in audioFrames.enumerated() {
            guard let decodedFrame = decoder.decode(
                audioFrame,
                sequenceNumber: packet.sequenceNumber,
                rtpTimestamp: packet.timestamp,
                frameIndex: frameIndex,
                frameCount: audioFrames.count
            ) else {
                recordDrop(reason: "AAC-ELD decode produced no PCM frameIndex=\(frameIndex) frames=\(audioFrames.count)", transportPacketCount: transportPacketCount, keepsPlaybackState: false)
                return "dropped-decode"
            }
            decodedFrames.append(decodedFrame)
        }

        let decodedFrame = AirPlayDecodedAudioFrame(
            pcmBytes: decodedFrames.reduce(into: Data()) { result, frame in
                result.append(frame.pcmBytes)
            },
            frameCount: decodedFrames.reduce(0) { $0 + $1.frameCount }
        )

        guard decodedFrame.frameCount > 0, !decodedFrame.pcmBytes.isEmpty else {
            recordDrop(reason: "AAC-ELD decode returned empty combined PCM", transportPacketCount: transportPacketCount, keepsPlaybackState: false)
            return "dropped-empty-pcm"
        }

        guard schedule(decodedFrame, sequenceNumber: packet.sequenceNumber, rtpTimestamp: packet.timestamp) else {
            recordDrop(reason: "PCM scheduling failed", transportPacketCount: transportPacketCount, keepsPlaybackState: false)
            return "dropped-schedule"
        }

        self.decodedPackets += 1
        if self.decodedPackets <= 20 || self.decodedPackets % 120 == 0 {
            airPlayAudioSinkLog.info("[AirPlayAudioPlayback] packet branch=SCHEDULED seq=\(packet.sequenceNumber) timestamp=\(packet.timestamp) payloadBytes=\(packet.payload.count) decryptedBytes=\(decryptedPayload.count) frames=\(audioFrames.count) pcmBytes=\(decodedFrame.pcmBytes.count) pcmFrames=\(decodedFrame.frameCount) decoded=\(self.decodedPackets) bufferedMs=\(self.jitterBuffer.bufferedMilliseconds)")
        }
        publishSnapshot(state: self.isPlayerStarted ? "live" : "waiting", dropReason: nil)
        return "scheduled"
    }

    private func handleGStreamerPCM(
        _ decodedFrame: AirPlayDecodedAudioFrame,
        sequenceNumber: UInt16,
        rtpTimestamp: UInt32,
        submittedAccessUnits: Int
    ) {
        guard decodedFrame.frameCount > 0, !decodedFrame.pcmBytes.isEmpty else {
            recordDrop(
                reason: "GStreamer AAC-ELD produced empty PCM",
                transportPacketCount: submittedAccessUnits,
                keepsPlaybackState: false
            )
            return
        }

        guard schedule(decodedFrame, sequenceNumber: sequenceNumber, rtpTimestamp: rtpTimestamp) else {
            recordDrop(
                reason: "GStreamer PCM scheduling failed",
                transportPacketCount: submittedAccessUnits,
                keepsPlaybackState: false
            )
            return
        }

        self.decodedPackets += 1
        if self.decodedPackets <= 20 || self.decodedPackets % 120 == 0 {
            airPlayAudioSinkLog.info("[AirPlayAudioPlayback] packet branch=GSTREAMER_SCHEDULED seq=\(sequenceNumber) timestamp=\(rtpTimestamp) pcmBytes=\(decodedFrame.pcmBytes.count) pcmFrames=\(decodedFrame.frameCount) decoded=\(self.decodedPackets) submittedAUs=\(submittedAccessUnits) bufferedMs=\(self.jitterBuffer.bufferedMilliseconds)")
        }
        publishSnapshot(state: self.isPlayerStarted ? "live" : "decoding", dropReason: nil)
    }

    private func schedule(_ frame: AirPlayDecodedAudioFrame, sequenceNumber: UInt16, rtpTimestamp: UInt32) -> Bool {
        guard let player, let playbackFormat else {
            airPlayAudioSinkLog.warning("[AirPlayAudioPlayback] schedule branch=NO_PLAYER seq=\(sequenceNumber) playerPresent=\(self.player != nil) formatPresent=\(self.playbackFormat != nil)")
            return false
        }

        guard let buffer = AVAudioPCMBuffer(
            pcmFormat: playbackFormat,
            frameCapacity: AVAudioFrameCount(frame.frameCount)
        ) else {
            airPlayAudioSinkLog.warning("[AirPlayAudioPlayback] schedule branch=BUFFER_ALLOC_FAILED seq=\(sequenceNumber) frames=\(frame.frameCount)")
            return false
        }

        do {
            try AirPlayAudioPCMLayout.copyInterleavedFloat32(
                frame.pcmBytes,
                frameCount: frame.frameCount,
                channelCount: self.configuration.channelCount,
                into: buffer
            )
        } catch {
            airPlayAudioSinkLog.warning("[AirPlayAudioPlayback] schedule branch=PCM_LAYOUT_COPY_FAILED seq=\(sequenceNumber) error=\(error.localizedDescription, privacy: .public) pcmBytes=\(frame.pcmBytes.count) frames=\(frame.frameCount) channels=\(self.configuration.channelCount) playbackInterleaved=\(playbackFormat.isInterleaved)")
            return false
        }

        let packetArrivedAt = Date()
        let arrivalGapMilliseconds = self.lastPacketArrivedAt
            .map { packetArrivedAt.timeIntervalSince($0) * 1000.0 } ?? -1
        self.lastPacketArrivedAt = packetArrivedAt

        let durationMilliseconds = Double(frame.frameCount) / max(self.configuration.sampleRate, 1) * 1000.0
        let jitterDecision = self.jitterBuffer.decisionForIncomingPacket(durationMilliseconds: durationMilliseconds)
        if jitterDecision == .dropForOverbuffer {
            airPlayAudioSinkLog.warning("[AirPlayAudioPlayback] schedule branch=OVERBUFFER_DROP seq=\(sequenceNumber) durationMs=\(durationMilliseconds) bufferedMs=\(self.jitterBuffer.bufferedMilliseconds) capMs=\(self.jitterBuffer.capMilliseconds) arrivalGapMs=\(arrivalGapMilliseconds)")
            return false
        }

        let bufferedMilliseconds = self.jitterBuffer.bufferedMilliseconds
        player.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { [weak self] _ in
            self?.callbackQueue.async {
                self?.handleScheduledBufferFinished(durationMilliseconds: durationMilliseconds)
            }
        }

        if !self.isPlayerStarted, self.jitterBuffer.bufferedMilliseconds >= self.jitterBuffer.targetMilliseconds {
            player.play()
            self.isPlayerStarted = true
            airPlayAudioSinkLog.info("[AirPlayAudioPlayback] schedule branch=START_PLAYER seq=\(sequenceNumber) bufferedMs=\(self.jitterBuffer.bufferedMilliseconds) targetMs=\(self.jitterBuffer.targetMilliseconds)")
        } else if self.isPlayerStarted, !player.isPlaying {
            player.play()
            airPlayAudioSinkLog.info("[AirPlayAudioPlayback] schedule branch=RESUME_PLAYER seq=\(sequenceNumber) bufferedMs=\(self.jitterBuffer.bufferedMilliseconds)")
        } else {
            airPlayAudioSinkLog.debug("[AirPlayAudioPlayback] schedule branch=\(self.isPlayerStarted ? "ALREADY_PLAYING" : "HOLDING_FOR_JITTER", privacy: .public) seq=\(sequenceNumber) durationMs=\(durationMilliseconds) bufferedMs=\(bufferedMilliseconds) arrivalGapMs=\(arrivalGapMilliseconds) rtpTimestamp=\(rtpTimestamp)")
        }

        return true
    }

    private func handleScheduledBufferFinished(durationMilliseconds: Double) {
        self.jitterBuffer.markScheduledDurationFinished(durationMilliseconds)
        airPlayAudioSinkLog.debug("[AirPlayAudioPlayback] playback finished durationMs=\(durationMilliseconds) remainingBufferedMs=\(self.jitterBuffer.bufferedMilliseconds)")
        publishSnapshot(state: self.isPlayerStarted ? "live" : "waiting", dropReason: nil)
    }

    private func recordDrop(reason: String, transportPacketCount: Int, keepsPlaybackState: Bool) {
        self.droppedPackets += 1
        self.lastDropReason = reason
        let state = keepsPlaybackState ? (self.isPlayerStarted ? "live" : "waiting") : "dropping"
        if self.droppedPackets <= 20 || self.droppedPackets % 120 == 0 {
            airPlayAudioSinkLog.warning("[AirPlayAudioPlayback] packet branch=DROP count=\(transportPacketCount) dropped=\(self.droppedPackets) reason=\(reason, privacy: .public) received=\(self.receivedPackets) decoded=\(self.decodedPackets)")
        } else {
            airPlayAudioSinkLog.debug("[AirPlayAudioPlayback] packet branch=DROP count=\(transportPacketCount) dropped=\(self.droppedPackets) reason=\(reason, privacy: .public)")
        }
        publishSnapshot(state: state, dropReason: reason)
    }

    private func publishSnapshot(state: String, dropReason: String?) {
        onSnapshot(AirPlayAudioPlaybackSnapshot(
            state: state,
            receivedPackets: self.receivedPackets,
            decodedPackets: self.decodedPackets,
            droppedPackets: self.droppedPackets,
            bufferedMilliseconds: self.jitterBuffer.bufferedMilliseconds,
            sampleRate: self.configuration.sampleRate,
            channelCount: self.configuration.channelCount,
            lastDropReason: dropReason ?? self.lastDropReason
        ))
    }
}

private final class AirPlayAACELDDecoder {
    private let sampleRate: Double
    private let channelCount: UInt32
    private let samplesPerFrame: Int
    private var converter: AudioConverterRef?
    private var packetDescriptionPointer: UnsafeMutablePointer<AudioStreamPacketDescription>
    private var inputPointer: UnsafeMutableRawPointer?
    private var inputByteCount: UInt32 = 0
    private var inputConsumed = true

    init(sampleRate: Double, channelCount: Int, samplesPerFrame: Int) throws {
        self.sampleRate = sampleRate
        self.channelCount = UInt32(channelCount)
        self.samplesPerFrame = max(1, samplesPerFrame)
        packetDescriptionPointer = UnsafeMutablePointer<AudioStreamPacketDescription>.allocate(capacity: 1)
        packetDescriptionPointer.initialize(to: AudioStreamPacketDescription(
            mStartOffset: 0,
            mVariableFramesInPacket: 0,
            mDataByteSize: 0
        ))

        var inputDescription = AudioStreamBasicDescription(
            mSampleRate: sampleRate,
            mFormatID: kAudioFormatMPEG4AAC_ELD,
            mFormatFlags: 0,
            mBytesPerPacket: 0,
            mFramesPerPacket: 0,
            mBytesPerFrame: 0,
            mChannelsPerFrame: UInt32(channelCount),
            mBitsPerChannel: 0,
            mReserved: 0
        )
        var outputDescription = AudioStreamBasicDescription(
            mSampleRate: sampleRate,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagsNativeEndian | kAudioFormatFlagIsPacked,
            mBytesPerPacket: UInt32(channelCount * MemoryLayout<Float>.size),
            mFramesPerPacket: 1,
            mBytesPerFrame: UInt32(channelCount * MemoryLayout<Float>.size),
            mChannelsPerFrame: UInt32(channelCount),
            mBitsPerChannel: 32,
            mReserved: 0
        )

        var createdConverter: AudioConverterRef?
        let createStatus = AudioConverterNew(&inputDescription, &outputDescription, &createdConverter)
        guard createStatus == noErr, let createdConverter else {
            packetDescriptionPointer.deinitialize(count: 1)
            packetDescriptionPointer.deallocate()
            throw AirPlayAudioPlaybackError.audioConverterCreateFailed(createStatus)
        }
        converter = createdConverter

        var audioSpecificConfig = [UInt8](arrayLiteral: 0xF8, 0xE8, 0x50, 0x00)
        let cookieStatus = audioSpecificConfig.withUnsafeMutableBytes { bytes in
            guard let baseAddress = bytes.baseAddress else {
                return kAudio_ParamError
            }
            return AudioConverterSetProperty(
                createdConverter,
                kAudioConverterDecompressionMagicCookie,
                UInt32(bytes.count),
                baseAddress
            )
        }
        if cookieStatus == noErr {
            airPlayAudioSinkLog.info("[AirPlayAACELD] magic cookie branch=APPLIED bytes=\(audioSpecificConfig.count)")
        } else {
            airPlayAudioSinkLog.warning("[AirPlayAACELD] magic cookie branch=REJECTED status=\(cookieStatus)")
        }

        var primeMethod = UInt32(kConverterPrimeMethod_None)
        let primeStatus = AudioConverterSetProperty(
            createdConverter,
            kAudioConverterPrimeMethod,
            UInt32(MemoryLayout<UInt32>.size),
            &primeMethod
        )
        if primeStatus == noErr {
            airPlayAudioSinkLog.info("[AirPlayAACELD] prime method branch=NONE_APPLIED")
        } else {
            airPlayAudioSinkLog.warning("[AirPlayAACELD] prime method branch=REJECTED status=\(primeStatus)")
        }

        airPlayAudioSinkLog.info("[AirPlayAACELD] converter branch=READY sampleRate=\(sampleRate) channels=\(channelCount) spf=\(self.samplesPerFrame)")
    }

    deinit {
        if let converter {
            AudioConverterDispose(converter)
        }
        inputPointer?.deallocate()
        packetDescriptionPointer.deinitialize(count: 1)
        packetDescriptionPointer.deallocate()
    }

    func decode(
        _ payload: Data,
        sequenceNumber: UInt16,
        rtpTimestamp: UInt32,
        frameIndex: Int,
        frameCount: Int
    ) -> AirPlayDecodedAudioFrame? {
        if let decoded = decodeAttempt(
            payload,
            sequenceNumber: sequenceNumber,
            rtpTimestamp: rtpTimestamp,
            frameIndex: frameIndex,
            frameCount: frameCount,
            attempt: "full-payload"
        ) {
            return decoded
        }

        if let firstByte = payload.first, (firstByte & 0xF0) == 0x80, payload.count > 1 {
            airPlayAudioSinkLog.info("[AirPlayAACELD] decode branch=RETRY_STRIP_SYNC_BYTE seq=\(sequenceNumber) frameIndex=\(frameIndex) frames=\(frameCount) firstByte=\(firstByte)")
            return decodeAttempt(
                payload.dropFirstData(),
                sequenceNumber: sequenceNumber,
                rtpTimestamp: rtpTimestamp,
                frameIndex: frameIndex,
                frameCount: frameCount,
                attempt: "strip-sync-byte"
            )
        }

        airPlayAudioSinkLog.warning("[AirPlayAACELD] decode branch=FAILED_NO_RETRY seq=\(sequenceNumber) frameIndex=\(frameIndex) frames=\(frameCount) payloadBytes=\(payload.count) rtpTimestamp=\(rtpTimestamp)")
        return nil
    }

    private func decodeAttempt(
        _ payload: Data,
        sequenceNumber: UInt16,
        rtpTimestamp: UInt32,
        frameIndex: Int,
        frameCount: Int,
        attempt: String
    ) -> AirPlayDecodedAudioFrame? {
        guard let converter else {
            airPlayAudioSinkLog.warning("[AirPlayAACELD] decode branch=NO_CONVERTER seq=\(sequenceNumber)")
            return nil
        }
        guard !payload.isEmpty else {
            airPlayAudioSinkLog.warning("[AirPlayAACELD] decode branch=EMPTY_PAYLOAD seq=\(sequenceNumber)")
            return nil
        }

        var status: OSStatus = noErr
        var outputPacketCount: UInt32 = 0
        var outputByteCount = 0
        let firstDecoded = fillConverter(
            converter,
            payload: payload,
            status: &status,
            outputPacketCount: &outputPacketCount,
            outputByteCount: &outputByteCount
        )
        if let firstDecoded {
            logDecodedPCM(
                attempt: attempt,
                sequenceNumber: sequenceNumber,
                rtpTimestamp: rtpTimestamp,
                frameIndex: frameIndex,
                frameCount: frameCount,
                payloadBytes: payload.count,
                decodedFrame: firstDecoded,
                outputPacketCount: outputPacketCount,
                outputByteCount: outputByteCount
            )
            return firstDecoded
        }

        if status == noErr && outputPacketCount == 0 {
            airPlayAudioSinkLog.info("[AirPlayAACELD] decode branch=RETRY_PRIME seq=\(sequenceNumber) frameIndex=\(frameIndex) attempt=\(attempt, privacy: .public) payloadBytes=\(payload.count)")
            if let secondDecoded = fillConverter(
                converter,
                payload: payload,
                status: &status,
                outputPacketCount: &outputPacketCount,
                outputByteCount: &outputByteCount
            ) {
                logDecodedPCM(
                    attempt: "\(attempt)-prime-retry",
                    sequenceNumber: sequenceNumber,
                    rtpTimestamp: rtpTimestamp,
                    frameIndex: frameIndex,
                    frameCount: frameCount,
                    payloadBytes: payload.count,
                    decodedFrame: secondDecoded,
                    outputPacketCount: outputPacketCount,
                    outputByteCount: outputByteCount
                )
                return secondDecoded
            }
        }

        airPlayAudioSinkLog.warning("[AirPlayAACELD] decode branch=NO_PCM attempt=\(attempt, privacy: .public) seq=\(sequenceNumber) frameIndex=\(frameIndex) frames=\(frameCount) packets=\(outputPacketCount) outputBytes=\(outputByteCount) payloadBytes=\(payload.count) status=\(status) rtpTimestamp=\(rtpTimestamp)")
        return nil
    }

    private func fillConverter(
        _ converter: AudioConverterRef,
        payload: Data,
        status: inout OSStatus,
        outputPacketCount: inout UInt32,
        outputByteCount: inout Int
    ) -> AirPlayDecodedAudioFrame? {
        inputPointer?.deallocate()
        inputPointer = UnsafeMutableRawPointer.allocate(byteCount: payload.count, alignment: 1)
        payload.withUnsafeBytes { source in
            if let baseAddress = source.baseAddress {
                inputPointer?.copyMemory(from: baseAddress, byteCount: payload.count)
            }
        }
        inputByteCount = UInt32(payload.count)
        inputConsumed = false
        packetDescriptionPointer.pointee = AudioStreamPacketDescription(
            mStartOffset: 0,
            mVariableFramesInPacket: 0,
            mDataByteSize: UInt32(payload.count)
        )
        defer {
            inputPointer?.deallocate()
            inputPointer = nil
            inputByteCount = 0
            inputConsumed = true
        }

        let outputFrameCapacity = max(samplesPerFrame, 480) * 2
        let outputByteCapacity = outputFrameCapacity * Int(channelCount) * MemoryLayout<Float>.size
        var output = Data(count: outputByteCapacity)
        outputPacketCount = UInt32(max(samplesPerFrame, 480))
        outputByteCount = 0

        status = output.withUnsafeMutableBytes { outputBuffer -> OSStatus in
            guard let baseAddress = outputBuffer.baseAddress else {
                return kAudio_ParamError
            }
            var outputBufferList = AudioBufferList(
                mNumberBuffers: 1,
                mBuffers: AudioBuffer(
                    mNumberChannels: channelCount,
                    mDataByteSize: UInt32(outputByteCapacity),
                    mData: baseAddress
                )
            )
            let status = AudioConverterFillComplexBuffer(
                converter,
                Self.inputDataProc,
                Unmanaged.passUnretained(self).toOpaque(),
                &outputPacketCount,
                &outputBufferList,
                nil
            )
            outputByteCount = Int(outputBufferList.mBuffers.mDataByteSize)
            return status
        }

        guard status == noErr else {
            outputPacketCount = 0
            let statusValue = status
            airPlayAudioSinkLog.warning("[AirPlayAACELD] fill branch=CONVERTER_FAILED status=\(statusValue) payloadBytes=\(payload.count)")
            return nil
        }

        guard outputPacketCount > 0 || outputByteCount > 0 else {
            airPlayAudioSinkLog.debug("[AirPlayAACELD] fill branch=NO_OUTPUT payloadBytes=\(payload.count)")
            return nil
        }

        let bytesPerFrame = Int(channelCount) * MemoryLayout<Float>.size
        let frameCount = outputByteCount / max(bytesPerFrame, 1)
        guard frameCount > 0 else {
            let outputBytes = outputByteCount
            airPlayAudioSinkLog.warning("[AirPlayAACELD] fill branch=ZERO_FRAMES outputBytes=\(outputBytes) bytesPerFrame=\(bytesPerFrame)")
            return nil
        }

        return AirPlayDecodedAudioFrame(pcmBytes: Data(output.prefix(outputByteCount)), frameCount: frameCount)
    }

    private func logDecodedPCM(
        attempt: String,
        sequenceNumber: UInt16,
        rtpTimestamp: UInt32,
        frameIndex: Int,
        frameCount: Int,
        payloadBytes: Int,
        decodedFrame: AirPlayDecodedAudioFrame,
        outputPacketCount: UInt32,
        outputByteCount: Int
    ) {
        if sequenceNumber < 20 || sequenceNumber % 120 == 0 {
            airPlayAudioSinkLog.info("[AirPlayAACELD] decode branch=PCM attempt=\(attempt, privacy: .public) seq=\(sequenceNumber) frameIndex=\(frameIndex) frames=\(frameCount) pcmFrames=\(decodedFrame.frameCount) outputBytes=\(outputByteCount) packets=\(outputPacketCount) payloadBytes=\(payloadBytes) rtpTimestamp=\(rtpTimestamp)")
        }
    }

    private static let inputDataProc: AudioConverterComplexInputDataProc = { _, ioNumberDataPackets, ioData, outDataPacketDescription, userData in
        guard let userData else {
            ioNumberDataPackets.pointee = 0
            return kAudio_ParamError
        }

        let decoder = Unmanaged<AirPlayAACELDDecoder>.fromOpaque(userData).takeUnretainedValue()
        guard !decoder.inputConsumed,
              let inputPointer = decoder.inputPointer,
              decoder.inputByteCount > 0 else {
            ioNumberDataPackets.pointee = 0
            return noErr
        }

        decoder.inputConsumed = true
        ioNumberDataPackets.pointee = 1
        ioData.pointee.mNumberBuffers = 1
        ioData.pointee.mBuffers = AudioBuffer(
            mNumberChannels: 0,
            mDataByteSize: decoder.inputByteCount,
            mData: inputPointer
        )
        if let outDataPacketDescription {
            outDataPacketDescription.pointee = decoder.packetDescriptionPointer
        }
        return noErr
    }
}

private extension Data {
    func dropFirstData() -> Data {
        guard !isEmpty else {
            return Data()
        }
        return subdata(in: index(after: startIndex)..<endIndex)
    }
}
