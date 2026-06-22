import XCTest
@testable import Specchio

final class ReplayKitMediaProtocolTests: XCTestCase {
    func testPacketTypeRawValuesReserveVideoAndAudioIDs() {
        XCTAssertEqual(ReplayKitPacketType.frame.rawValue, 0x01)
        XCTAssertEqual(ReplayKitPacketType.controlEvent.rawValue, 0x02)
        XCTAssertEqual(ReplayKitPacketType.heartbeat.rawValue, 0x03)
        XCTAssertEqual(ReplayKitPacketType.audioFormat.rawValue, 0x04)
        XCTAssertEqual(ReplayKitPacketType.audioPCM.rawValue, 0x05)
        XCTAssertEqual(ReplayKitPacketType.audioHeartbeat.rawValue, 0x06)
        XCTAssertEqual(ReplayKitPacketType.h264Config.rawValue, 0x07)
        XCTAssertEqual(ReplayKitPacketType.h264AccessUnit.rawValue, 0x08)
    }

    func testH264ConfigJSONDecodeAndValidation() throws {
        let sps = Data([0x67, 0x42, 0x00, 0x1F])
        let pps = Data([0x68, 0xCE, 0x06, 0xE2])
        let payload = ReplayKitH264ConfigPayload(
            sequence: 3,
            width: 1170,
            height: 2532,
            bitrate: 4_000_000,
            targetFPS: 15,
            keyframeIntervalFrames: 30,
            sps: sps,
            pps: pps,
            timestamp: 1_778_170_000
        )

        let encoded = try JSONEncoder().encode(payload)
        let decoded = try JSONDecoder().decode(ReplayKitH264ConfigPayload.self, from: encoded)

        XCTAssertTrue(decoded.isUsableForDecoding)
        XCTAssertEqual(decoded.codec, "h264")
        XCTAssertEqual(decoded.profile, "baseline")
        XCTAssertEqual(decoded.spsData, sps)
        XCTAssertEqual(decoded.ppsData, pps)
    }

    func testH264ConfigRejectsMissingParameterSets() throws {
        let json = """
        {
          "event": "videoCodecConfig",
          "sequence": 1,
          "codec": "h264",
          "profile": "baseline",
          "width": 1170,
          "height": 2532,
          "timescale": 1000,
          "bitrate": 4000000,
          "targetFPS": 15,
          "keyframeIntervalFrames": 30,
          "spsBase64": "",
          "ppsBase64": "",
          "timestamp": 1778170000.0
        }
        """.data(using: .utf8)!

        let decoded = try JSONDecoder().decode(ReplayKitH264ConfigPayload.self, from: json)
        XCTAssertFalse(decoded.isUsableForDecoding)
    }

    func testAirPlayH264RecoveryPolicyAllowsDeltaFramesAfterDecodedFrame() {
        let airPlayPolicy = ReplayKitH264VideoDecoder.KeyframeRecoveryPolicy.allowDeltaFramesAfterDecodedFrame
        let replayKitPolicy = ReplayKitH264VideoDecoder.KeyframeRecoveryPolicy.requireKeyframeAfterDecodeFailure

        XCTAssertTrue(airPlayPolicy.shouldWaitForKeyframeAfterDecodeFailure(hasDecodedFrame: false))
        XCTAssertFalse(airPlayPolicy.shouldWaitForKeyframeAfterDecodeFailure(hasDecodedFrame: true))
        XCTAssertTrue(replayKitPolicy.shouldWaitForKeyframeAfterDecodeFailure(hasDecodedFrame: true))
    }

    func testAirPlayH264RecoveryPolicyKeepsSessionOnRepeatedConfigAfterDecodedFrame() {
        let airPlayPolicy = ReplayKitH264VideoDecoder.KeyframeRecoveryPolicy.allowDeltaFramesAfterDecodedFrame
        let replayKitPolicy = ReplayKitH264VideoDecoder.KeyframeRecoveryPolicy.requireKeyframeAfterDecodeFailure

        XCTAssertTrue(airPlayPolicy.shouldKeepSessionOnUnchangedConfigRefresh(hasDecodedFrame: true, sessionActive: true))
        XCTAssertFalse(airPlayPolicy.shouldKeepSessionOnUnchangedConfigRefresh(hasDecodedFrame: false, sessionActive: true))
        XCTAssertFalse(airPlayPolicy.shouldKeepSessionOnUnchangedConfigRefresh(hasDecodedFrame: true, sessionActive: false))
        XCTAssertFalse(replayKitPolicy.shouldKeepSessionOnUnchangedConfigRefresh(hasDecodedFrame: true, sessionActive: true))
    }

    func testEnvelopePacketRoundTripForAudioPCM() {
        let payload = Data([1, 2, 3, 4])
        let encoded = ReplayKitMediaEnvelopePacket.encode(type: .audioPCM, payload: payload)
        let decoded = ReplayKitMediaEnvelopePacket(encoded: encoded, maximumPayloadBytes: 1024)

        XCTAssertEqual(decoded?.type, .audioPCM)
        XCTAssertEqual(decoded?.payload, payload)
    }

    func testEnvelopeHeaderKeepsUnknownPacketTypeInspectable() {
        var data = Data()
        data.append(ReplayKitPacketEnvelope.magic)
        data.append(ReplayKitPacketEnvelope.version)
        data.append(0xFE)
        data.appendUInt32BE(4)

        let header = ReplayKitMediaEnvelopeHeader(data: data)
        XCTAssertEqual(header?.version, ReplayKitPacketEnvelope.version)
        XCTAssertEqual(header?.rawPacketType, 0xFE)
        XCTAssertNil(header?.packetType)
    }

    func testEnvelopePacketRejectsOversizedPayloadLength() {
        let payload = Data([1, 2, 3, 4])
        let encoded = ReplayKitMediaEnvelopePacket.encode(type: .audioPCM, payload: payload)
        XCTAssertNil(ReplayKitMediaEnvelopePacket(encoded: encoded, maximumPayloadBytes: 3))
    }

    func testAudioFormatJSONDecodeAndValidation() throws {
        let payload = ReplayKitAudioFormatPayload(
            sequence: 9,
            sampleRate: 48_000,
            channelCount: 2,
            commonFormat: .pcmFloat32,
            isInterleaved: false,
            timestamp: 1_778_170_000
        )

        let encoded = try JSONEncoder().encode(payload)
        let decoded = try JSONDecoder().decode(ReplayKitAudioFormatPayload.self, from: encoded)

        XCTAssertTrue(decoded.isSupportedForV1)
        XCTAssertEqual(decoded.event, "audioFormat")
        XCTAssertEqual(decoded.source, ReplayKitAudioConstants.sourceName)
        XCTAssertEqual(decoded.commonFormat, .pcmFloat32)
    }

    func testAudioFormatRejectsUnsupportedSource() {
        let payload = ReplayKitAudioFormatPayload(
            sequence: 1,
            sampleRate: 48_000,
            channelCount: 2,
            commonFormat: .pcmFloat32,
            isInterleaved: false,
            timestamp: 1
        )
        let unsupported = ReplayKitAudioFormatPayload(
            event: payload.event,
            sequence: payload.sequence,
            source: "micAudio",
            sampleRate: payload.sampleRate,
            channelCount: payload.channelCount,
            commonFormat: payload.commonFormat,
            isInterleaved: payload.isInterleaved,
            timestamp: payload.timestamp
        )

        XCTAssertFalse(unsupported.isSupportedForV1)
    }

    func testAudioPCMHeaderParseRoundTrip() {
        let pcm = Data(repeating: 0x7F, count: 384)
        let header = ReplayKitAudioPCMHeader(
            sequenceNumber: 42,
            presentationTimestampMilliseconds: 100,
            captureWallClockMilliseconds: 200,
            sampleRateMilliHz: 48_000_000,
            frameCount: 48,
            channelCount: 2,
            formatFlags: ReplayKitAudioCommonFormat.pcmFloat32.packetFlag,
            bytesPerFrame: 4,
            isInterleaved: false,
            source: .appAudio,
            pcmByteCount: UInt32(pcm.count)
        )
        let packet = ReplayKitAudioPCMPacket(header: header, pcmBytes: pcm)

        let parsed = ReplayKitAudioPCMPacket(payload: packet.payload)
        XCTAssertEqual(parsed?.header, header)
        XCTAssertEqual(parsed?.pcmBytes, pcm)
        XCTAssertEqual(parsed?.header.commonFormat, .pcmFloat32)
        XCTAssertEqual(parsed?.header.sampleRate, 48_000)
    }

    func testAudioPCMHeaderRejectsMalformedPayloadLength() {
        let pcm = Data(repeating: 0x00, count: 8)
        let header = ReplayKitAudioPCMHeader(
            sequenceNumber: 1,
            presentationTimestampMilliseconds: 2,
            captureWallClockMilliseconds: 3,
            sampleRateMilliHz: 48_000_000,
            frameCount: 1,
            channelCount: 2,
            formatFlags: ReplayKitAudioCommonFormat.pcmInt16.packetFlag,
            bytesPerFrame: 2,
            isInterleaved: false,
            source: .appAudio,
            pcmByteCount: 100
        )
        let packet = ReplayKitAudioPCMPacket(header: header, pcmBytes: pcm)

        XCTAssertNil(ReplayKitAudioPCMPacket(payload: packet.payload))
    }

    func testAudioPCMRejectsUnsupportedFormatFlag() {
        let pcm = Data(repeating: 0x00, count: 8)
        let header = ReplayKitAudioPCMHeader(
            sequenceNumber: 1,
            presentationTimestampMilliseconds: 2,
            captureWallClockMilliseconds: 3,
            sampleRateMilliHz: 48_000_000,
            frameCount: 1,
            channelCount: 2,
            formatFlags: 999,
            bytesPerFrame: 2,
            isInterleaved: false,
            source: .appAudio,
            pcmByteCount: UInt32(pcm.count)
        )

        XCTAssertNil(ReplayKitAudioPCMPacket(payload: ReplayKitAudioPCMPacket(header: header, pcmBytes: pcm).payload))
    }

    func testSequenceTrackerReportsGaps() {
        var tracker = ReplayKitPacketSequenceTracker()

        XCTAssertEqual(tracker.record(1), .first(1))
        XCTAssertEqual(tracker.record(2), .inOrder(previous: 1, current: 2))
        XCTAssertEqual(tracker.record(5), .gap(previous: 2, current: 5))
        XCTAssertEqual(tracker.record(4), .nonMonotonic(previous: 5, current: 4))
    }

    func testAudioJitterBufferCapDropsIncomingWithoutResettingPlaybackBuffer() {
        var jitter = ReplayKitAudioJitterBufferState(targetMilliseconds: 80, capMilliseconds: 250, bufferedMilliseconds: 240)

        let decision = jitter.decisionForIncomingPacket(durationMilliseconds: 30)

        XCTAssertEqual(decision, .dropForOverbuffer)
        XCTAssertEqual(jitter.bufferedMilliseconds, 240)
    }

    func testH264AccessUnitHeaderParseRoundTrip() {
        let annexB = Data([0, 0, 0, 1, 0x65, 0x88, 0x84])
        let header = ReplayKitH264AccessUnitHeader(
            sequenceNumber: 42,
            presentationTimestampMilliseconds: 100,
            captureWallClockMilliseconds: 200,
            encodedWallClockMilliseconds: 250,
            width: 390,
            height: 844,
            flags: [.keyframe, .includesParameterSets],
            nalByteCount: UInt32(annexB.count)
        )
        let packet = ReplayKitH264AccessUnitPacket(header: header, annexBBytes: annexB)

        let parsed = ReplayKitH264AccessUnitPacket(payload: packet.payload)
        XCTAssertEqual(parsed?.header, header)
        XCTAssertEqual(parsed?.annexBBytes, annexB)
    }

    func testH264AccessUnitHeaderRejectsMalformedPayloadLength() {
        var payload = Data()
        payload.appendUInt64BE(1)
        payload.appendUInt64BE(2)
        payload.appendUInt64BE(3)
        payload.appendUInt64BE(4)
        payload.appendUInt16BE(390)
        payload.appendUInt16BE(844)
        payload.appendUInt16BE(ReplayKitH264AccessUnitFlags.keyframe.rawValue)
        payload.appendUInt32BE(100)
        payload.append(Data([0, 0, 0, 1, 0x65]))

        XCTAssertNil(ReplayKitH264AccessUnitPacket(payload: payload))
    }

    func testH264AccessUnitRejectsOversizedNALPayload() {
        let annexB = Data([0, 0, 0, 1, 0x65])
        let header = ReplayKitH264AccessUnitHeader(
            sequenceNumber: 1,
            presentationTimestampMilliseconds: 2,
            captureWallClockMilliseconds: 3,
            encodedWallClockMilliseconds: 4,
            width: 390,
            height: 844,
            flags: [.keyframe],
            nalByteCount: UInt32(annexB.count)
        )
        let packet = ReplayKitH264AccessUnitPacket(header: header, annexBBytes: annexB)

        XCTAssertNil(ReplayKitH264AccessUnitPacket(payload: packet.payload, maximumAccessUnitBytes: annexB.count - 1))
    }

    func testAnnexBExtractionAndParameterSetDetection() {
        let sps = Data([0x67, 0x42, 0x00, 0x1F])
        let pps = Data([0x68, 0xCE, 0x06, 0xE2])
        let idr = Data([0x65, 0x88, 0x84])
        var annexB = Data()
        annexB.append(ReplayKitH264Constants.annexBStartCode)
        annexB.append(sps)
        annexB.append(ReplayKitH264Constants.annexBStartCode)
        annexB.append(pps)
        annexB.append(Data([0x00, 0x00, 0x01]))
        annexB.append(idr)

        let nalUnits = ReplayKitAnnexBParser.extractNALUnits(from: annexB)
        XCTAssertEqual(nalUnits, [sps, pps, idr])
        XCTAssertTrue(ReplayKitAnnexBParser.containsIDR(in: annexB))
        let parameterSets = ReplayKitAnnexBParser.parameterSets(from: annexB)
        XCTAssertEqual(parameterSets.sps, sps)
        XCTAssertEqual(parameterSets.pps, pps)
    }

    func testHEVCAnnexBParameterSetAndKeyframeDetection() {
        let vps = Data([0x40, 0x01, 0x0C, 0x01])
        let sps = Data([0x42, 0x01, 0x01, 0x60])
        let pps = Data([0x44, 0x01, 0xC0, 0x73])
        let idr = Data([0x26, 0x01, 0xAA, 0xBB])
        var annexB = Data()
        annexB.append(ReplayKitH264Constants.annexBStartCode)
        annexB.append(vps)
        annexB.append(ReplayKitH264Constants.annexBStartCode)
        annexB.append(sps)
        annexB.append(ReplayKitH264Constants.annexBStartCode)
        annexB.append(pps)
        annexB.append(ReplayKitH264Constants.annexBStartCode)
        annexB.append(idr)

        XCTAssertEqual(ReplayKitAnnexBParser.hevcNALUnitType(vps), 32)
        XCTAssertEqual(ReplayKitAnnexBParser.hevcNALUnitType(sps), 33)
        XCTAssertEqual(ReplayKitAnnexBParser.hevcNALUnitType(pps), 34)
        XCTAssertTrue(ReplayKitAnnexBParser.containsHEVCRandomAccessPicture(in: annexB))
        let parameterSets = ReplayKitAnnexBParser.hevcParameterSets(from: annexB)
        XCTAssertEqual(parameterSets.vps, vps)
        XCTAssertEqual(parameterSets.sps, sps)
        XCTAssertEqual(parameterSets.pps, pps)
    }

    func testJPEGFallbackHeaderStillParses() {
        var data = Data()
        data.appendUInt64BE(1234)
        data.appendUInt16BE(390)
        data.appendUInt16BE(844)
        data.append(62)
        data.append(1)
        data.appendUInt32BE(4)

        let header = ReplayKitFrameHeader(data: data)
        XCTAssertEqual(header?.timestamp, 1234)
        XCTAssertEqual(header?.width, 390)
        XCTAssertEqual(header?.height, 844)
        XCTAssertEqual(header?.jpegSize, 4)
    }
}
