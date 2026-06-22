import Foundation

enum ReplayKitPacketEnvelope {
    static let magic = Data([0x53, 0x50, 0x52, 0x4B])
    static let version: UInt8 = 1
    static let headerByteCount = 10
}

enum ReplayKitPacketType: UInt8, CaseIterable {
    case frame = 0x01
    case controlEvent = 0x02
    case heartbeat = 0x03
    case audioFormat = 0x04
    case audioPCM = 0x05
    case audioHeartbeat = 0x06
    case h264Config = 0x07
    case h264AccessUnit = 0x08

    var diagnosticName: String {
        switch self {
        case .frame:
            return "frame"
        case .controlEvent:
            return "control"
        case .heartbeat:
            return "heartbeat"
        case .audioFormat:
            return "audioFormat"
        case .audioPCM:
            return "audioPCM"
        case .audioHeartbeat:
            return "audioHeartbeat"
        case .h264Config:
            return "h264Config"
        case .h264AccessUnit:
            return "h264AccessUnit"
        }
    }
}

enum ReplayKitVideoCodecPreference: String, Codable, Equatable {
    static let storageKey = "replayKitVideoCodecPreference"
    static let defaultValue: ReplayKitVideoCodecPreference = .h264Preferred

    case h264Preferred
    case jpegOnly

    static func resolve(rawValue: String?) -> ReplayKitVideoCodecPreference {
        guard let rawValue,
              let value = ReplayKitVideoCodecPreference(rawValue: rawValue) else {
            return defaultValue
        }
        return value
    }
}

enum ReplayKitActiveVideoCodec: String, Codable, Equatable {
    case unknown
    case jpeg
    case h264

    var diagnosticLabel: String {
        switch self {
        case .unknown:
            return "Video waiting"
        case .jpeg:
            return "JPEG fallback"
        case .h264:
            return "H.264"
        }
    }
}

struct ReplayKitVideoOrientationSnapshot: Codable, Equatable {
    let deviceOrientationRaw: Int
    let deviceOrientationName: String
    let videoOrientationRaw: Int?
    let videoOrientationName: String?
    let frameWidth: Int
    let frameHeight: Int
    let timestamp: Double

    var deviceAxis: String {
        Self.deviceAxis(for: deviceOrientationRaw)
    }

    var videoFrameAxis: String {
        Self.frameAxis(width: frameWidth, height: frameHeight)
    }

    var videoOrientationAxis: String? {
        guard let videoOrientationRaw else { return nil }
        return Self.cgImageOrientationAxis(for: videoOrientationRaw)
    }

    var orientationSignature: String {
        [
            String(deviceOrientationRaw),
            videoOrientationRaw.map(String.init) ?? "nil",
            String(frameWidth),
            String(frameHeight)
        ].joined(separator: ":")
    }

    static func deviceOrientationName(for rawValue: Int) -> String {
        switch rawValue {
        case 1: return "portrait"
        case 2: return "portraitUpsideDown"
        case 3: return "landscapeLeft"
        case 4: return "landscapeRight"
        case 5: return "faceUp"
        case 6: return "faceDown"
        default: return "unknown"
        }
    }

    static func deviceAxis(for rawValue: Int) -> String {
        switch rawValue {
        case 1, 2: return "portrait"
        case 3, 4: return "landscape"
        case 5, 6: return "flat"
        default: return "unknown"
        }
    }

    static func cgImageOrientationName(for rawValue: Int) -> String {
        switch rawValue {
        case 1: return "up"
        case 2: return "upMirrored"
        case 3: return "down"
        case 4: return "downMirrored"
        case 5: return "leftMirrored"
        case 6: return "right"
        case 7: return "rightMirrored"
        case 8: return "left"
        default: return "unknown"
        }
    }

    static func cgImageOrientationAxis(for rawValue: Int) -> String {
        switch rawValue {
        case 1, 2, 3, 4: return "portrait"
        case 5, 6, 7, 8: return "landscape"
        default: return "unknown"
        }
    }

    static func frameAxis(width: Int, height: Int) -> String {
        guard width > 0, height > 0 else { return "unknown" }
        if width == height { return "square" }
        return width > height ? "landscape" : "portrait"
    }
}

enum ReplayKitBroadcastVideoCodecStatus: String {
    case h264
    case jpegFallback
    case unavailable
}

enum ReplayKitH264Constants {
    static let codecName = "h264"
    static let profileName = "baseline"
    static let timescale = 1000
    static let averageBitrate = 4_000_000
    static let maximumAccessUnitBytes = 2 * 1024 * 1024
    static let annexBStartCode = Data([0x00, 0x00, 0x00, 0x01])
}

enum ReplayKitAudioConstants {
    static let defaultPort: UInt16 = 9501
    static let sourceName = "appAudio"
    static let maximumEnvelopePayloadBytes = 512 * 1024
    static let targetJitterBufferMilliseconds: Double = 80
    static let maximumBufferedAudioMilliseconds: Double = 250
    static let silenceTimeoutSeconds: TimeInterval = 2.0
}

enum ReplayKitAudioSource: UInt8, Equatable {
    case appAudio = 1
}

enum ReplayKitAudioCommonFormat: String, Codable, Equatable {
    case pcmFloat32
    case pcmInt16

    var packetFlag: UInt16 {
        switch self {
        case .pcmFloat32:
            return 1
        case .pcmInt16:
            return 2
        }
    }

    static func resolve(packetFlag: UInt16) -> ReplayKitAudioCommonFormat? {
        switch packetFlag {
        case 1:
            return .pcmFloat32
        case 2:
            return .pcmInt16
        default:
            return nil
        }
    }
}

struct ReplayKitAudioFormatPayload: Codable, Equatable {
    let event: String
    let sequence: Int
    let source: String
    let sampleRate: Double
    let channelCount: Int
    let commonFormat: ReplayKitAudioCommonFormat
    let isInterleaved: Bool
    let timestamp: Double

    var isSupportedForV1: Bool {
        event == "audioFormat"
            && source == ReplayKitAudioConstants.sourceName
            && sampleRate.isFinite
            && sampleRate > 0
            && channelCount > 0
            && channelCount <= Int(UInt16.max)
    }

    init(
        sequence: Int,
        sampleRate: Double,
        channelCount: Int,
        commonFormat: ReplayKitAudioCommonFormat,
        isInterleaved: Bool,
        timestamp: Double
    ) {
        self.event = "audioFormat"
        self.sequence = sequence
        self.source = ReplayKitAudioConstants.sourceName
        self.sampleRate = sampleRate
        self.channelCount = channelCount
        self.commonFormat = commonFormat
        self.isInterleaved = isInterleaved
        self.timestamp = timestamp
    }

    init(
        event: String,
        sequence: Int,
        source: String,
        sampleRate: Double,
        channelCount: Int,
        commonFormat: ReplayKitAudioCommonFormat,
        isInterleaved: Bool,
        timestamp: Double
    ) {
        self.event = event
        self.sequence = sequence
        self.source = source
        self.sampleRate = sampleRate
        self.channelCount = channelCount
        self.commonFormat = commonFormat
        self.isInterleaved = isInterleaved
        self.timestamp = timestamp
    }
}

struct ReplayKitAudioHeartbeatPayload: Codable, Equatable {
    let event: String
    let sequence: Int
    let receivedAudioSamples: Int
    let sentAudioPackets: Int
    let droppedAudioPackets: Int
    let unsupportedAudioSamples: Int
    let senderState: String
    let reason: String?
    let timestamp: Double
    let transport: String
}

struct ReplayKitAudioPCMHeader: Equatable {
    static let byteCount = 50

    let sequenceNumber: UInt64
    let presentationTimestampMilliseconds: UInt64
    let captureWallClockMilliseconds: UInt64
    let sampleRateMilliHz: UInt64
    let frameCount: UInt32
    let channelCount: UInt16
    let formatFlags: UInt16
    let bytesPerFrame: UInt16
    let isInterleaved: Bool
    let source: ReplayKitAudioSource
    let reserved: UInt16
    let pcmByteCount: UInt32

    var commonFormat: ReplayKitAudioCommonFormat? {
        ReplayKitAudioCommonFormat.resolve(packetFlag: formatFlags)
    }

    var sampleRate: Double {
        Double(sampleRateMilliHz) / 1000.0
    }

    init(
        sequenceNumber: UInt64,
        presentationTimestampMilliseconds: UInt64,
        captureWallClockMilliseconds: UInt64,
        sampleRateMilliHz: UInt64,
        frameCount: UInt32,
        channelCount: UInt16,
        formatFlags: UInt16,
        bytesPerFrame: UInt16,
        isInterleaved: Bool,
        source: ReplayKitAudioSource,
        reserved: UInt16 = 0,
        pcmByteCount: UInt32
    ) {
        self.sequenceNumber = sequenceNumber
        self.presentationTimestampMilliseconds = presentationTimestampMilliseconds
        self.captureWallClockMilliseconds = captureWallClockMilliseconds
        self.sampleRateMilliHz = sampleRateMilliHz
        self.frameCount = frameCount
        self.channelCount = channelCount
        self.formatFlags = formatFlags
        self.bytesPerFrame = bytesPerFrame
        self.isInterleaved = isInterleaved
        self.source = source
        self.reserved = reserved
        self.pcmByteCount = pcmByteCount
    }

    init?(payload: Data) {
        guard payload.count >= Self.byteCount else {
            return nil
        }

        let rawSource = payload[43]
        guard let source = ReplayKitAudioSource(rawValue: rawSource) else {
            return nil
        }

        let pcmByteCount = payload.replayKitReadUInt32BE(at: 46)
        guard payload.count == Self.byteCount + Int(pcmByteCount) else {
            return nil
        }

        self.sequenceNumber = payload.replayKitReadUInt64BE(at: 0)
        self.presentationTimestampMilliseconds = payload.replayKitReadUInt64BE(at: 8)
        self.captureWallClockMilliseconds = payload.replayKitReadUInt64BE(at: 16)
        self.sampleRateMilliHz = payload.replayKitReadUInt64BE(at: 24)
        self.frameCount = payload.replayKitReadUInt32BE(at: 32)
        self.channelCount = payload.replayKitReadUInt16BE(at: 36)
        self.formatFlags = payload.replayKitReadUInt16BE(at: 38)
        self.bytesPerFrame = payload.replayKitReadUInt16BE(at: 40)
        self.isInterleaved = payload[42] != 0
        self.source = source
        self.reserved = payload.replayKitReadUInt16BE(at: 44)
        self.pcmByteCount = pcmByteCount
    }
}

struct ReplayKitAudioPCMPacket: Equatable {
    let header: ReplayKitAudioPCMHeader
    let pcmBytes: Data

    init?(payload: Data, maximumAudioPayloadBytes: Int = ReplayKitAudioConstants.maximumEnvelopePayloadBytes) {
        guard let header = ReplayKitAudioPCMHeader(payload: payload) else {
            return nil
        }

        guard header.pcmByteCount > 0,
              Int(header.pcmByteCount) <= maximumAudioPayloadBytes,
              header.frameCount > 0,
              header.channelCount > 0,
              header.commonFormat != nil else {
            return nil
        }

        let pcmStart = ReplayKitAudioPCMHeader.byteCount
        self.header = header
        self.pcmBytes = payload.subdata(in: pcmStart..<payload.count)
    }

    init(header: ReplayKitAudioPCMHeader, pcmBytes: Data) {
        self.header = header
        self.pcmBytes = pcmBytes
    }

    var payload: Data {
        var data = Data(capacity: ReplayKitAudioPCMHeader.byteCount + pcmBytes.count)
        data.appendUInt64BE(header.sequenceNumber)
        data.appendUInt64BE(header.presentationTimestampMilliseconds)
        data.appendUInt64BE(header.captureWallClockMilliseconds)
        data.appendUInt64BE(header.sampleRateMilliHz)
        data.appendUInt32BE(header.frameCount)
        data.appendUInt16BE(header.channelCount)
        data.appendUInt16BE(header.formatFlags)
        data.appendUInt16BE(header.bytesPerFrame)
        data.append(header.isInterleaved ? 1 : 0)
        data.append(header.source.rawValue)
        data.appendUInt16BE(header.reserved)
        data.appendUInt32BE(UInt32(pcmBytes.count))
        data.append(pcmBytes)
        return data
    }
}

struct ReplayKitMediaEnvelopeHeader: Equatable {
    let version: UInt8
    let rawPacketType: UInt8
    let payloadLength: Int

    var packetType: ReplayKitPacketType? {
        ReplayKitPacketType(rawValue: rawPacketType)
    }

    init?(data: Data) {
        guard data.count == ReplayKitPacketEnvelope.headerByteCount,
              data.prefix(4) == ReplayKitPacketEnvelope.magic else {
            return nil
        }

        self.version = data[4]
        self.rawPacketType = data[5]
        self.payloadLength = Int(data.replayKitReadUInt32BE(at: 6))
    }
}

struct ReplayKitMediaEnvelopePacket: Equatable {
    let type: ReplayKitPacketType
    let payload: Data

    var encoded: Data {
        Self.encode(type: type, payload: payload)
    }

    init(type: ReplayKitPacketType, payload: Data) {
        self.type = type
        self.payload = payload
    }

    static func encode(type: ReplayKitPacketType, payload: Data) -> Data {
        var data = Data(capacity: ReplayKitPacketEnvelope.headerByteCount + payload.count)
        data.append(ReplayKitPacketEnvelope.magic)
        data.append(ReplayKitPacketEnvelope.version)
        data.append(type.rawValue)
        data.appendUInt32BE(UInt32(payload.count))
        data.append(payload)
        return data
    }

    init?(encoded data: Data, maximumPayloadBytes: Int) {
        guard data.count >= ReplayKitPacketEnvelope.headerByteCount else {
            return nil
        }

        let headerData = data.prefix(ReplayKitPacketEnvelope.headerByteCount)
        guard let header = ReplayKitMediaEnvelopeHeader(data: Data(headerData)),
              header.version == ReplayKitPacketEnvelope.version,
              header.payloadLength >= 0,
              header.payloadLength <= maximumPayloadBytes,
              data.count == ReplayKitPacketEnvelope.headerByteCount + header.payloadLength,
              let type = header.packetType else {
            return nil
        }

        self.type = type
        self.payload = data.subdata(in: ReplayKitPacketEnvelope.headerByteCount..<data.count)
    }
}

enum ReplayKitSequenceRecordResult: Equatable {
    case first(UInt64)
    case inOrder(previous: UInt64, current: UInt64)
    case gap(previous: UInt64, current: UInt64)
    case nonMonotonic(previous: UInt64, current: UInt64)
}

struct ReplayKitPacketSequenceTracker: Equatable {
    private(set) var lastSequenceNumber: UInt64?

    mutating func record(_ sequenceNumber: UInt64) -> ReplayKitSequenceRecordResult {
        guard let previous = lastSequenceNumber else {
            lastSequenceNumber = sequenceNumber
            return .first(sequenceNumber)
        }

        lastSequenceNumber = sequenceNumber
        if sequenceNumber == previous + 1 {
            return .inOrder(previous: previous, current: sequenceNumber)
        }

        if sequenceNumber > previous + 1 {
            return .gap(previous: previous, current: sequenceNumber)
        }

        return .nonMonotonic(previous: previous, current: sequenceNumber)
    }

    mutating func reset() {
        lastSequenceNumber = nil
    }
}

struct ReplayKitAudioJitterBufferState: Equatable {
    enum IncomingDecision: Equatable {
        case schedule
        case holdUntilTarget
        case dropForOverbuffer
    }

    let targetMilliseconds: Double
    let capMilliseconds: Double
    private(set) var bufferedMilliseconds: Double

    init(
        targetMilliseconds: Double = ReplayKitAudioConstants.targetJitterBufferMilliseconds,
        capMilliseconds: Double = ReplayKitAudioConstants.maximumBufferedAudioMilliseconds,
        bufferedMilliseconds: Double = 0
    ) {
        self.targetMilliseconds = targetMilliseconds
        self.capMilliseconds = capMilliseconds
        self.bufferedMilliseconds = max(0, bufferedMilliseconds)
    }

    mutating func decisionForIncomingPacket(durationMilliseconds: Double) -> IncomingDecision {
        let safeDuration = max(0, durationMilliseconds)
        if bufferedMilliseconds + safeDuration > capMilliseconds {
            return .dropForOverbuffer
        }

        bufferedMilliseconds += safeDuration
        if bufferedMilliseconds >= targetMilliseconds {
            return .schedule
        }

        return .holdUntilTarget
    }

    mutating func markScheduledDurationFinished(_ durationMilliseconds: Double) {
        bufferedMilliseconds = max(0, bufferedMilliseconds - max(0, durationMilliseconds))
    }

    mutating func reset() {
        bufferedMilliseconds = 0
    }
}

struct ReplayKitH264AccessUnitFlags: OptionSet, Equatable {
    let rawValue: UInt16

    static let keyframe = ReplayKitH264AccessUnitFlags(rawValue: 1 << 0)
    static let includesParameterSets = ReplayKitH264AccessUnitFlags(rawValue: 1 << 1)
    static let formatChanged = ReplayKitH264AccessUnitFlags(rawValue: 1 << 2)
}

struct ReplayKitH264ConfigPayload: Codable, Equatable {
    let event: String
    let sequence: Int
    let codec: String
    let profile: String
    let width: Int
    let height: Int
    let timescale: Int
    let bitrate: Int
    let targetFPS: Int
    let keyframeIntervalFrames: Int
    let spsBase64: String
    let ppsBase64: String
    let timestamp: Double

    var spsData: Data? {
        Data(base64Encoded: spsBase64)
    }

    var ppsData: Data? {
        Data(base64Encoded: ppsBase64)
    }

    var isUsableForDecoding: Bool {
        codec == ReplayKitH264Constants.codecName
            && width > 0
            && height > 0
            && spsData?.isEmpty == false
            && ppsData?.isEmpty == false
    }

    init(
        sequence: Int,
        width: Int,
        height: Int,
        bitrate: Int,
        targetFPS: Int,
        keyframeIntervalFrames: Int,
        sps: Data,
        pps: Data,
        timestamp: Double
    ) {
        self.event = "videoCodecConfig"
        self.sequence = sequence
        self.codec = ReplayKitH264Constants.codecName
        self.profile = ReplayKitH264Constants.profileName
        self.width = width
        self.height = height
        self.timescale = ReplayKitH264Constants.timescale
        self.bitrate = bitrate
        self.targetFPS = targetFPS
        self.keyframeIntervalFrames = keyframeIntervalFrames
        self.spsBase64 = sps.base64EncodedString()
        self.ppsBase64 = pps.base64EncodedString()
        self.timestamp = timestamp
    }
}

struct ReplayKitH264AccessUnitHeader: Equatable {
    static let byteCount = 42

    let sequenceNumber: UInt64
    let presentationTimestampMilliseconds: UInt64
    let captureWallClockMilliseconds: UInt64
    let encodedWallClockMilliseconds: UInt64
    let width: UInt16
    let height: UInt16
    let flags: ReplayKitH264AccessUnitFlags
    let nalByteCount: UInt32

    init(
        sequenceNumber: UInt64,
        presentationTimestampMilliseconds: UInt64,
        captureWallClockMilliseconds: UInt64,
        encodedWallClockMilliseconds: UInt64,
        width: UInt16,
        height: UInt16,
        flags: ReplayKitH264AccessUnitFlags,
        nalByteCount: UInt32
    ) {
        self.sequenceNumber = sequenceNumber
        self.presentationTimestampMilliseconds = presentationTimestampMilliseconds
        self.captureWallClockMilliseconds = captureWallClockMilliseconds
        self.encodedWallClockMilliseconds = encodedWallClockMilliseconds
        self.width = width
        self.height = height
        self.flags = flags
        self.nalByteCount = nalByteCount
    }

    init?(payload: Data) {
        guard payload.count >= Self.byteCount else {
            return nil
        }

        let nalByteCount = payload.replayKitReadUInt32BE(at: 38)
        guard payload.count == Self.byteCount + Int(nalByteCount) else {
            return nil
        }

        self.sequenceNumber = payload.replayKitReadUInt64BE(at: 0)
        self.presentationTimestampMilliseconds = payload.replayKitReadUInt64BE(at: 8)
        self.captureWallClockMilliseconds = payload.replayKitReadUInt64BE(at: 16)
        self.encodedWallClockMilliseconds = payload.replayKitReadUInt64BE(at: 24)
        self.width = payload.replayKitReadUInt16BE(at: 32)
        self.height = payload.replayKitReadUInt16BE(at: 34)
        self.flags = ReplayKitH264AccessUnitFlags(rawValue: payload.replayKitReadUInt16BE(at: 36))
        self.nalByteCount = nalByteCount
    }
}

struct ReplayKitH264AccessUnitPacket: Equatable {
    let header: ReplayKitH264AccessUnitHeader
    let annexBBytes: Data

    init?(payload: Data, maximumAccessUnitBytes: Int = ReplayKitH264Constants.maximumAccessUnitBytes) {
        guard let header = ReplayKitH264AccessUnitHeader(payload: payload) else {
            return nil
        }

        guard header.nalByteCount > 0,
              Int(header.nalByteCount) <= maximumAccessUnitBytes else {
            return nil
        }

        let nalStart = ReplayKitH264AccessUnitHeader.byteCount
        self.header = header
        self.annexBBytes = payload.subdata(in: nalStart..<payload.count)
    }

    init(header: ReplayKitH264AccessUnitHeader, annexBBytes: Data) {
        self.header = header
        self.annexBBytes = annexBBytes
    }

    var payload: Data {
        var data = Data(capacity: ReplayKitH264AccessUnitHeader.byteCount + annexBBytes.count)
        data.appendUInt64BE(header.sequenceNumber)
        data.appendUInt64BE(header.presentationTimestampMilliseconds)
        data.appendUInt64BE(header.captureWallClockMilliseconds)
        data.appendUInt64BE(header.encodedWallClockMilliseconds)
        data.appendUInt16BE(header.width)
        data.appendUInt16BE(header.height)
        data.appendUInt16BE(header.flags.rawValue)
        data.appendUInt32BE(header.nalByteCount)
        data.append(annexBBytes)
        return data
    }
}

enum ReplayKitAnnexBParser {
    static func extractNALUnits(from data: Data) -> [Data] {
        guard data.count >= 4 else { return [] }

        let bytes = [UInt8](data)
        var startCodes: [(offset: Int, length: Int)] = []
        var index = 0

        while index + 2 < bytes.count {
            if index + 3 < bytes.count,
               bytes[index] == 0x00,
               bytes[index + 1] == 0x00,
               bytes[index + 2] == 0x00,
               bytes[index + 3] == 0x01 {
                startCodes.append((offset: index, length: 4))
                index += 4
            } else if bytes[index] == 0x00,
                      bytes[index + 1] == 0x00,
                      bytes[index + 2] == 0x01 {
                startCodes.append((offset: index, length: 3))
                index += 3
            } else {
                index += 1
            }
        }

        guard !startCodes.isEmpty else { return [] }

        return startCodes.enumerated().compactMap { pair in
            let nalStart = pair.element.offset + pair.element.length
            let nalEnd = pair.offset + 1 < startCodes.count ? startCodes[pair.offset + 1].offset : bytes.count
            guard nalStart < nalEnd else { return nil }
            return data.subdata(in: nalStart..<nalEnd)
        }
    }

    static func nalUnitType(_ nalUnit: Data) -> UInt8? {
        nalUnit.first.map { $0 & 0x1F }
    }

    static func hevcNALUnitType(_ nalUnit: Data) -> UInt8? {
        guard let firstByte = nalUnit.first else { return nil }
        return (firstByte & 0x7E) >> 1
    }

    static func containsNALType(_ type: UInt8, in annexBData: Data) -> Bool {
        extractNALUnits(from: annexBData).contains { nalUnitType($0) == type }
    }

    static func containsIDR(in annexBData: Data) -> Bool {
        containsNALType(5, in: annexBData)
    }

    static func containsHEVCRandomAccessPicture(in annexBData: Data) -> Bool {
        extractNALUnits(from: annexBData).contains { nalUnit in
            guard let type = hevcNALUnitType(nalUnit) else { return false }
            return (16...21).contains(type)
        }
    }

    static func parameterSets(from annexBData: Data) -> (sps: Data?, pps: Data?) {
        var sps: Data?
        var pps: Data?
        for nalUnit in extractNALUnits(from: annexBData) {
            switch nalUnitType(nalUnit) {
            case 7:
                sps = nalUnit
            case 8:
                pps = nalUnit
            default:
                continue
            }
        }
        return (sps, pps)
    }

    static func hevcParameterSets(from annexBData: Data) -> (vps: Data?, sps: Data?, pps: Data?) {
        var vps: Data?
        var sps: Data?
        var pps: Data?
        for nalUnit in extractNALUnits(from: annexBData) {
            switch hevcNALUnitType(nalUnit) {
            case 32:
                vps = nalUnit
            case 33:
                sps = nalUnit
            case 34:
                pps = nalUnit
            default:
                continue
            }
        }
        return (vps, sps, pps)
    }
}

extension Data {
    mutating func appendUInt16BE(_ value: UInt16) {
        append(UInt8((value >> 8) & 0xFF))
        append(UInt8(value & 0xFF))
    }

    mutating func appendUInt32BE(_ value: UInt32) {
        append(UInt8((value >> 24) & 0xFF))
        append(UInt8((value >> 16) & 0xFF))
        append(UInt8((value >> 8) & 0xFF))
        append(UInt8(value & 0xFF))
    }

    mutating func appendUInt64BE(_ value: UInt64) {
        for shift in stride(from: 56, through: 0, by: -8) {
            append(UInt8((value >> UInt64(shift)) & 0xFF))
        }
    }

    func replayKitReadUInt16BE(at offset: Int) -> UInt16 {
        UInt16(self[offset]) << 8 | UInt16(self[offset + 1])
    }

    func replayKitReadUInt32BE(at offset: Int) -> UInt32 {
        UInt32(self[offset]) << 24
            | UInt32(self[offset + 1]) << 16
            | UInt32(self[offset + 2]) << 8
            | UInt32(self[offset + 3])
    }

    func replayKitReadUInt64BE(at offset: Int) -> UInt64 {
        var value: UInt64 = 0
        for index in offset..<(offset + 8) {
            value = (value << 8) | UInt64(self[index])
        }
        return value
    }
}
