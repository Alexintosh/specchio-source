import CoreGraphics
import Foundation

struct AirPlayH264FrameAdapter {
    struct AdaptedAccessUnit: Equatable {
        let packet: ReplayKitH264AccessUnitPacket
        let nalCount: Int
        let isKeyframe: Bool
        let includesParameterSets: Bool
        let formatChanged: Bool
    }

    enum AdaptationError: Error, Equatable {
        case malformedConfiguration(String)
        case malformedAccessUnit(String)
        case oversizedAccessUnit(Int)
    }

    private(set) var spsData: Data?
    private(set) var ppsData: Data?
    private(set) var nalLengthByteCount = 4
    private(set) var frameDimensions: CGSize?
    private var sequenceNumber: UInt64 = 0

    static func payloadLooksLikeConfiguration(_ payload: Data) -> Bool {
        var adapter = AirPlayH264FrameAdapter()
        return (try? adapter.applyConfigurationPayload(payload, dimensions: nil)) != nil
    }

    mutating func reset() {
        spsData = nil
        ppsData = nil
        nalLengthByteCount = 4
        frameDimensions = nil
        sequenceNumber = 0
    }

    mutating func applyConfigurationPayload(_ payload: Data, dimensions: CGSize?) throws -> ReplayKitH264ConfigPayload {
        guard payload.count >= 7 else {
            throw AdaptationError.malformedConfiguration("configuration payload too short: \(payload.count)")
        }

        let nextNalLengthByteCount = Int(payload[4] & 0x03) + 1
        guard nextNalLengthByteCount >= 1, nextNalLengthByteCount <= 4 else {
            throw AdaptationError.malformedConfiguration("invalid NAL length byte count: \(nextNalLengthByteCount)")
        }

        var offset = 5
        let spsCount = Int(payload[offset] & 0x1F)
        offset += 1
        guard spsCount > 0 else {
            throw AdaptationError.malformedConfiguration("missing SPS")
        }

        var parsedSPS: Data?
        for index in 0..<spsCount {
            guard offset + 2 <= payload.count else {
                throw AdaptationError.malformedConfiguration("missing SPS length at index \(index)")
            }
            let length = Int(payload.replayKitReadUInt16BE(at: offset))
            offset += 2
            guard length > 0, offset + length <= payload.count else {
                throw AdaptationError.malformedConfiguration("invalid SPS length \(length) at index \(index)")
            }
            let sps = payload.subdata(in: offset..<(offset + length))
            offset += length
            if parsedSPS == nil {
                parsedSPS = sps
            }
        }

        guard offset < payload.count else {
            throw AdaptationError.malformedConfiguration("missing PPS count")
        }

        let ppsCount = Int(payload[offset])
        offset += 1
        guard ppsCount > 0 else {
            throw AdaptationError.malformedConfiguration("missing PPS")
        }

        var parsedPPS: Data?
        for index in 0..<ppsCount {
            guard offset + 2 <= payload.count else {
                throw AdaptationError.malformedConfiguration("missing PPS length at index \(index)")
            }
            let length = Int(payload.replayKitReadUInt16BE(at: offset))
            offset += 2
            guard length > 0, offset + length <= payload.count else {
                throw AdaptationError.malformedConfiguration("invalid PPS length \(length) at index \(index)")
            }
            let pps = payload.subdata(in: offset..<(offset + length))
            offset += length
            if parsedPPS == nil {
                parsedPPS = pps
            }
        }

        guard let parsedSPS, let parsedPPS else {
            throw AdaptationError.malformedConfiguration("configuration did not contain usable SPS/PPS")
        }

        nalLengthByteCount = nextNalLengthByteCount
        spsData = parsedSPS
        ppsData = parsedPPS
        if let dimensions {
            frameDimensions = dimensions
        }

        let size = sanitizedDimensions(dimensions ?? frameDimensions)
        return ReplayKitH264ConfigPayload(
            sequence: Int(sequenceNumber),
            width: Int(size.width),
            height: Int(size.height),
            bitrate: ReplayKitH264Constants.averageBitrate,
            targetFPS: 60,
            keyframeIntervalFrames: 60,
            sps: parsedSPS,
            pps: parsedPPS,
            timestamp: Date().timeIntervalSince1970
        )
    }

    mutating func adaptAccessUnitPayload(_ payload: Data, packet: AirPlayMirrorPacket) throws -> AdaptedAccessUnit {
        let nalUnits = try lengthPrefixedNALUnits(from: payload, lengthByteCount: nalLengthByteCount)
        guard !nalUnits.isEmpty else {
            throw AdaptationError.malformedAccessUnit("no NAL units")
        }

        let parameterSets = parameterSets(from: nalUnits)
        let previousSPS = spsData
        let previousPPS = ppsData
        if let sps = parameterSets.sps {
            spsData = sps
        }
        if let pps = parameterSets.pps {
            ppsData = pps
        }

        let isKeyframe = packet.isIDRVideoPayload || nalUnits.contains { ReplayKitAnnexBParser.nalUnitType($0) == 5 }
        let shouldPrependParameterSets = isKeyframe && spsData != nil && ppsData != nil
        var annexB = Data()
        var includesParameterSets = false

        if shouldPrependParameterSets, let spsData, let ppsData {
            appendAnnexBNAL(spsData, to: &annexB)
            appendAnnexBNAL(ppsData, to: &annexB)
            includesParameterSets = true
        }

        for nalUnit in nalUnits {
            appendAnnexBNAL(nalUnit, to: &annexB)
            switch ReplayKitAnnexBParser.nalUnitType(nalUnit) {
            case 7, 8:
                includesParameterSets = true
            default:
                continue
            }
        }

        guard !annexB.isEmpty else {
            throw AdaptationError.malformedAccessUnit("empty Annex B output")
        }
        guard annexB.count <= ReplayKitH264Constants.maximumAccessUnitBytes else {
            throw AdaptationError.oversizedAccessUnit(annexB.count)
        }

        if let sourceDimensions = packet.sourceDimensions {
            frameDimensions = sourceDimensions
        }
        let size = sanitizedDimensions(packet.sourceDimensions ?? frameDimensions)
        var flags = ReplayKitH264AccessUnitFlags()
        if isKeyframe {
            flags.insert(.keyframe)
        }
        if includesParameterSets {
            flags.insert(.includesParameterSets)
        }
        let formatChanged = previousSPS != spsData || previousPPS != ppsData
        if formatChanged {
            flags.insert(.formatChanged)
        }

        sequenceNumber += 1
        let nowMilliseconds = UInt64(Date().timeIntervalSince1970 * 1000)
        let header = ReplayKitH264AccessUnitHeader(
            sequenceNumber: sequenceNumber,
            presentationTimestampMilliseconds: packet.presentationTimestampMilliseconds ?? nowMilliseconds,
            captureWallClockMilliseconds: nowMilliseconds,
            encodedWallClockMilliseconds: nowMilliseconds,
            width: UInt16(clamping: Int(size.width)),
            height: UInt16(clamping: Int(size.height)),
            flags: flags,
            nalByteCount: UInt32(annexB.count)
        )

        return AdaptedAccessUnit(
            packet: ReplayKitH264AccessUnitPacket(header: header, annexBBytes: annexB),
            nalCount: nalUnits.count,
            isKeyframe: isKeyframe,
            includesParameterSets: includesParameterSets,
            formatChanged: formatChanged
        )
    }

    static func annexBData(fromLengthPrefixed payload: Data, lengthByteCount: Int = 4) throws -> Data {
        let nalUnits = try lengthPrefixedNALUnits(from: payload, lengthByteCount: lengthByteCount)
        var annexB = Data()
        for nalUnit in nalUnits {
            appendAnnexBNAL(nalUnit, to: &annexB)
        }
        return annexB
    }

    private static func lengthPrefixedNALUnits(from payload: Data, lengthByteCount: Int) throws -> [Data] {
        try AirPlayH264FrameAdapter().lengthPrefixedNALUnits(from: payload, lengthByteCount: lengthByteCount)
    }

    private func lengthPrefixedNALUnits(from payload: Data, lengthByteCount: Int) throws -> [Data] {
        if payload.starts(with: ReplayKitH264Constants.annexBStartCode) {
            return ReplayKitAnnexBParser.extractNALUnits(from: payload)
        }

        guard (1...4).contains(lengthByteCount) else {
            throw AdaptationError.malformedAccessUnit("invalid NAL length byte count \(lengthByteCount)")
        }

        var offset = 0
        var nalUnits: [Data] = []
        while offset < payload.count {
            guard offset + lengthByteCount <= payload.count else {
                throw AdaptationError.malformedAccessUnit("truncated NAL length at offset \(offset)")
            }

            var length = 0
            for index in 0..<lengthByteCount {
                length = (length << 8) | Int(payload[offset + index])
            }
            offset += lengthByteCount
            guard length > 0, offset + length <= payload.count else {
                throw AdaptationError.malformedAccessUnit("invalid NAL length \(length) at offset \(offset)")
            }
            nalUnits.append(payload.subdata(in: offset..<(offset + length)))
            offset += length
        }
        return nalUnits
    }

    private func parameterSets(from nalUnits: [Data]) -> (sps: Data?, pps: Data?) {
        var sps: Data?
        var pps: Data?
        for nalUnit in nalUnits {
            switch ReplayKitAnnexBParser.nalUnitType(nalUnit) {
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

    private func sanitizedDimensions(_ dimensions: CGSize?) -> CGSize {
        guard let dimensions,
              dimensions.width.isFinite,
              dimensions.height.isFinite,
              dimensions.width > 0,
              dimensions.height > 0 else {
            return CGSize(width: 390, height: 844)
        }
        return dimensions
    }

    private static func appendAnnexBNAL(_ nalUnit: Data, to data: inout Data) {
        data.append(ReplayKitH264Constants.annexBStartCode)
        data.append(nalUnit)
    }

    private func appendAnnexBNAL(_ nalUnit: Data, to data: inout Data) {
        Self.appendAnnexBNAL(nalUnit, to: &data)
    }
}

struct AirPlayHEVCConfigPayload: Equatable {
    let sequence: Int
    let width: Int
    let height: Int
    let targetFPS: Int
    let vps: Data
    let sps: Data
    let pps: Data
    let nalLengthByteCount: Int

    var isUsableForDecoding: Bool {
        width > 0
            && height > 0
            && !vps.isEmpty
            && !sps.isEmpty
            && !pps.isEmpty
            && (1...4).contains(nalLengthByteCount)
    }
}

struct AirPlayHEVCFrameAdapter {
    struct AdaptedAccessUnit: Equatable {
        let packet: ReplayKitH264AccessUnitPacket
        let nalCount: Int
        let isKeyframe: Bool
        let includesParameterSets: Bool
        let formatChanged: Bool
    }

    enum AdaptationError: Error, Equatable {
        case malformedConfiguration(String)
        case malformedAccessUnit(String)
        case oversizedAccessUnit(Int)
    }

    private struct ParsedConfiguration {
        let vps: Data
        let sps: Data
        let pps: Data
        let nalLengthByteCount: Int
        let branch: String
    }

    private(set) var vpsData: Data?
    private(set) var spsData: Data?
    private(set) var ppsData: Data?
    private(set) var nalLengthByteCount = 4
    private(set) var frameDimensions: CGSize?
    private(set) var lastConfigurationBranch = "none"
    private var sequenceNumber: UInt64 = 0

    static func payloadLooksLikeConfiguration(_ payload: Data) -> Bool {
        if payload.count >= 8, matchesASCII("hvc1", in: payload, at: 4) {
            return true
        }
        if findASCII("hvcC", in: payload) != nil {
            return true
        }
        if payload.starts(with: ReplayKitH264Constants.annexBStartCode) {
            let parameterSets = ReplayKitAnnexBParser.hevcParameterSets(from: payload)
            return parameterSets.vps != nil && parameterSets.sps != nil && parameterSets.pps != nil
        }
        if parseHVCCRecord(in: payload, recordOffset: 0, branch: "classification-hvcC-record") != nil {
            return true
        }
        return parseLengthPrefixedParameterSets(in: payload) != nil
    }

    mutating func reset() {
        vpsData = nil
        spsData = nil
        ppsData = nil
        nalLengthByteCount = 4
        frameDimensions = nil
        lastConfigurationBranch = "none"
        sequenceNumber = 0
    }

    mutating func applyConfigurationPayload(_ payload: Data, dimensions: CGSize?) throws -> AirPlayHEVCConfigPayload {
        let parsed = try Self.parseConfigurationPayload(payload)
        vpsData = parsed.vps
        spsData = parsed.sps
        ppsData = parsed.pps
        nalLengthByteCount = parsed.nalLengthByteCount
        lastConfigurationBranch = parsed.branch
        if let dimensions {
            frameDimensions = dimensions
        }

        let size = sanitizedDimensions(dimensions ?? frameDimensions)
        return AirPlayHEVCConfigPayload(
            sequence: Int(sequenceNumber),
            width: Int(size.width),
            height: Int(size.height),
            targetFPS: 60,
            vps: parsed.vps,
            sps: parsed.sps,
            pps: parsed.pps,
            nalLengthByteCount: parsed.nalLengthByteCount
        )
    }

    mutating func adaptAccessUnitPayload(_ payload: Data, packet: AirPlayMirrorPacket) throws -> AdaptedAccessUnit {
        let nalUnits = try lengthPrefixedNALUnits(from: payload, lengthByteCount: nalLengthByteCount)
        guard !nalUnits.isEmpty else {
            throw AdaptationError.malformedAccessUnit("no NAL units")
        }

        let parameterSets = parameterSets(from: nalUnits)
        let previousVPS = vpsData
        let previousSPS = spsData
        let previousPPS = ppsData
        if let vps = parameterSets.vps {
            vpsData = vps
        }
        if let sps = parameterSets.sps {
            spsData = sps
        }
        if let pps = parameterSets.pps {
            ppsData = pps
        }

        let isKeyframe = packet.isIDRVideoPayload || nalUnits.contains { nalUnit in
            guard let type = ReplayKitAnnexBParser.hevcNALUnitType(nalUnit) else { return false }
            return (16...21).contains(type)
        }
        let shouldPrependParameterSets = isKeyframe && vpsData != nil && spsData != nil && ppsData != nil
        var annexB = Data()
        var includesParameterSets = false

        if shouldPrependParameterSets,
           let vpsData,
           let spsData,
           let ppsData {
            appendAnnexBNAL(vpsData, to: &annexB)
            appendAnnexBNAL(spsData, to: &annexB)
            appendAnnexBNAL(ppsData, to: &annexB)
            includesParameterSets = true
        }

        for nalUnit in nalUnits {
            appendAnnexBNAL(nalUnit, to: &annexB)
            switch ReplayKitAnnexBParser.hevcNALUnitType(nalUnit) {
            case 32, 33, 34:
                includesParameterSets = true
            default:
                continue
            }
        }

        guard !annexB.isEmpty else {
            throw AdaptationError.malformedAccessUnit("empty Annex B output")
        }
        guard annexB.count <= ReplayKitH264Constants.maximumAccessUnitBytes else {
            throw AdaptationError.oversizedAccessUnit(annexB.count)
        }

        if let sourceDimensions = packet.sourceDimensions {
            frameDimensions = sourceDimensions
        }
        let size = sanitizedDimensions(packet.sourceDimensions ?? frameDimensions)
        var flags = ReplayKitH264AccessUnitFlags()
        if isKeyframe {
            flags.insert(.keyframe)
        }
        if includesParameterSets {
            flags.insert(.includesParameterSets)
        }
        let formatChanged = previousVPS != vpsData || previousSPS != spsData || previousPPS != ppsData
        if formatChanged {
            flags.insert(.formatChanged)
        }

        sequenceNumber += 1
        let nowMilliseconds = UInt64(Date().timeIntervalSince1970 * 1000)
        let header = ReplayKitH264AccessUnitHeader(
            sequenceNumber: sequenceNumber,
            presentationTimestampMilliseconds: packet.presentationTimestampMilliseconds ?? nowMilliseconds,
            captureWallClockMilliseconds: nowMilliseconds,
            encodedWallClockMilliseconds: nowMilliseconds,
            width: UInt16(clamping: Int(size.width)),
            height: UInt16(clamping: Int(size.height)),
            flags: flags,
            nalByteCount: UInt32(annexB.count)
        )

        return AdaptedAccessUnit(
            packet: ReplayKitH264AccessUnitPacket(header: header, annexBBytes: annexB),
            nalCount: nalUnits.count,
            isKeyframe: isKeyframe,
            includesParameterSets: includesParameterSets,
            formatChanged: formatChanged
        )
    }

    private static func parseConfigurationPayload(_ payload: Data) throws -> ParsedConfiguration {
        if payload.starts(with: ReplayKitH264Constants.annexBStartCode) {
            let parameterSets = ReplayKitAnnexBParser.hevcParameterSets(from: payload)
            if let vps = parameterSets.vps,
               let sps = parameterSets.sps,
               let pps = parameterSets.pps {
                return ParsedConfiguration(vps: vps, sps: sps, pps: pps, nalLengthByteCount: 4, branch: "annexB")
            }
        }

        if let parsed = parseHVCCRecord(in: payload, recordOffset: 0, branch: "hvcC-record-at-zero") {
            return parsed
        }

        if let hvcCOffset = findASCII("hvcC", in: payload),
           let parsed = parseHVCCRecord(in: payload, recordOffset: hvcCOffset + 4, branch: "hvcC-box") {
            return parsed
        }

        if matchesASCII("hvc1", in: payload, at: 4),
           let parsed = parseHVCCArrays(in: payload, startOffset: 0x75, arrayCount: nil, nalLengthByteCount: 4, branch: "hvc1-sample-entry") {
            return parsed
        }

        if let parsed = parseLengthPrefixedParameterSets(in: payload) {
            return parsed
        }

        throw AdaptationError.malformedConfiguration("missing HEVC VPS/SPS/PPS payloadBytes=\(payload.count)")
    }

    private static func parseHVCCRecord(in payload: Data, recordOffset: Int, branch: String) -> ParsedConfiguration? {
        guard recordOffset >= 0,
              recordOffset + 23 <= payload.count,
              payload[recordOffset] == 1 else {
            return nil
        }

        let nalLengthByteCount = Int(payload[recordOffset + 21] & 0x03) + 1
        let arrayCount = Int(payload[recordOffset + 22])
        guard (1...4).contains(nalLengthByteCount), arrayCount > 0 else {
            return nil
        }

        return parseHVCCArrays(
            in: payload,
            startOffset: recordOffset + 23,
            arrayCount: arrayCount,
            nalLengthByteCount: nalLengthByteCount,
            branch: branch
        )
    }

    private static func parseHVCCArrays(
        in payload: Data,
        startOffset: Int,
        arrayCount: Int?,
        nalLengthByteCount: Int,
        branch: String
    ) -> ParsedConfiguration? {
        guard startOffset >= 0, startOffset + 3 <= payload.count else {
            return nil
        }

        var offset = startOffset
        var arraysRead = 0
        var vps: Data?
        var sps: Data?
        var pps: Data?

        while offset + 3 <= payload.count,
              arraysRead < (arrayCount ?? Int.max) {
            let nalType = payload[offset] & 0x3F
            offset += 1
            let nalCount = Int(payload.replayKitReadUInt16BE(at: offset))
            offset += 2
            guard nalCount > 0 else { return nil }

            for _ in 0..<nalCount {
                guard offset + 2 <= payload.count else { return nil }
                let nalLength = Int(payload.replayKitReadUInt16BE(at: offset))
                offset += 2
                guard nalLength > 0, offset + nalLength <= payload.count else { return nil }
                let nalUnit = payload.subdata(in: offset..<(offset + nalLength))
                offset += nalLength

                switch nalType {
                case 32 where vps == nil:
                    vps = nalUnit
                case 33 where sps == nil:
                    sps = nalUnit
                case 34 where pps == nil:
                    pps = nalUnit
                default:
                    continue
                }
            }

            arraysRead += 1
            if arrayCount == nil, vps != nil, sps != nil, pps != nil {
                break
            }
        }

        guard let vps, let sps, let pps else {
            return nil
        }
        return ParsedConfiguration(
            vps: vps,
            sps: sps,
            pps: pps,
            nalLengthByteCount: nalLengthByteCount,
            branch: branch
        )
    }

    private static func parseLengthPrefixedParameterSets(in payload: Data) -> ParsedConfiguration? {
        guard let nalUnits = try? lengthPrefixedNALUnits(from: payload, lengthByteCount: 4) else {
            return nil
        }
        let parameterSets = parameterSets(from: nalUnits)
        guard let vps = parameterSets.vps,
              let sps = parameterSets.sps,
              let pps = parameterSets.pps else {
            return nil
        }
        return ParsedConfiguration(vps: vps, sps: sps, pps: pps, nalLengthByteCount: 4, branch: "length-prefixed-parameter-sets")
    }

    private static func lengthPrefixedNALUnits(from payload: Data, lengthByteCount: Int) throws -> [Data] {
        try AirPlayHEVCFrameAdapter().lengthPrefixedNALUnits(from: payload, lengthByteCount: lengthByteCount)
    }

    private func lengthPrefixedNALUnits(from payload: Data, lengthByteCount: Int) throws -> [Data] {
        if payload.starts(with: ReplayKitH264Constants.annexBStartCode) {
            return ReplayKitAnnexBParser.extractNALUnits(from: payload)
        }

        guard (1...4).contains(lengthByteCount) else {
            throw AdaptationError.malformedAccessUnit("invalid NAL length byte count \(lengthByteCount)")
        }

        var offset = 0
        var nalUnits: [Data] = []
        while offset < payload.count {
            guard offset + lengthByteCount <= payload.count else {
                throw AdaptationError.malformedAccessUnit("truncated NAL length at offset \(offset)")
            }

            var length = 0
            for index in 0..<lengthByteCount {
                length = (length << 8) | Int(payload[offset + index])
            }
            offset += lengthByteCount
            guard length > 0, offset + length <= payload.count else {
                throw AdaptationError.malformedAccessUnit("invalid NAL length \(length) at offset \(offset)")
            }
            nalUnits.append(payload.subdata(in: offset..<(offset + length)))
            offset += length
        }
        return nalUnits
    }

    private static func parameterSets(from nalUnits: [Data]) -> (vps: Data?, sps: Data?, pps: Data?) {
        var vps: Data?
        var sps: Data?
        var pps: Data?
        for nalUnit in nalUnits {
            switch ReplayKitAnnexBParser.hevcNALUnitType(nalUnit) {
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

    private func parameterSets(from nalUnits: [Data]) -> (vps: Data?, sps: Data?, pps: Data?) {
        Self.parameterSets(from: nalUnits)
    }

    private static func matchesASCII(_ text: String, in data: Data, at offset: Int) -> Bool {
        let bytes = Array(text.utf8)
        guard offset >= 0, offset + bytes.count <= data.count else {
            return false
        }
        return data.subdata(in: offset..<(offset + bytes.count)) == Data(bytes)
    }

    private static func findASCII(_ text: String, in data: Data) -> Int? {
        let bytes = Array(text.utf8)
        guard !bytes.isEmpty, data.count >= bytes.count else {
            return nil
        }
        let haystack = Array(data)
        for offset in 0...(haystack.count - bytes.count) where Array(haystack[offset..<(offset + bytes.count)]) == bytes {
            return offset
        }
        return nil
    }

    private func sanitizedDimensions(_ dimensions: CGSize?) -> CGSize {
        guard let dimensions,
              dimensions.width.isFinite,
              dimensions.height.isFinite,
              dimensions.width > 0,
              dimensions.height > 0 else {
            return CGSize(width: 390, height: 844)
        }
        return dimensions
    }

    private static func appendAnnexBNAL(_ nalUnit: Data, to data: inout Data) {
        data.append(ReplayKitH264Constants.annexBStartCode)
        data.append(nalUnit)
    }

    private func appendAnnexBNAL(_ nalUnit: Data, to data: inout Data) {
        Self.appendAnnexBNAL(nalUnit, to: &data)
    }
}
