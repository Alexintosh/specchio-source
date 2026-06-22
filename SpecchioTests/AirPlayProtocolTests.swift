import AVFoundation
import BigInt
import CoreGraphics
import CryptoKit
import XCTest
@testable import Specchio

final class AirPlayProtocolTests: XCTestCase {
    func testRTSPRequestParserPreservesBinaryBodyWithCRLF() throws {
        var body = Data([0x62, 0x70, 0x6C, 0x69, 0x73, 0x74, 0x0D, 0x0A, 0x00])
        body.append(Data([0x01, 0x02]))
        var request = Data("SETUP rtsp://specchio.local/stream RTSP/1.0\r\nCSeq: 7\r\nContent-Type: application/x-apple-binary-plist\r\nContent-Length: \(body.count)\r\n\r\n".utf8)
        request.append(body)

        let parsed = try AirPlayControlRequest.parse(from: request)

        XCTAssertEqual(parsed?.request.method, "SETUP")
        XCTAssertEqual(parsed?.request.path, "rtsp://specchio.local/stream")
        XCTAssertEqual(parsed?.request.cseq, "7")
        XCTAssertEqual(parsed?.request.body, body)
        XCTAssertEqual(parsed?.consumedBytes, request.count)
    }

    func testRTSPRequestRoutePathNormalizesAbsoluteURI() throws {
        let request = Data("GET rtsp://specchio.local/info?qualifier=txtAirPlay RTSP/1.0\r\nCSeq: 8\r\n\r\n".utf8)

        let parsed = try XCTUnwrap(AirPlayControlRequest.parse(from: request))

        XCTAssertEqual(parsed.request.path, "rtsp://specchio.local/info?qualifier=txtAirPlay")
        XCTAssertEqual(parsed.request.routePath, "/info")
    }

    func testRTSPRequestRoutePathNormalizesUnbracketedIPv6AbsoluteURI() throws {
        let request = Data("GET_PARAMETER rtsp://fe80::8034:b5ff:fe6c:969b/14578143775306825906?x=1 RTSP/1.0\r\nCSeq: 9\r\n\r\n".utf8)

        let parsed = try XCTUnwrap(AirPlayControlRequest.parse(from: request))

        XCTAssertEqual(parsed.request.routePath, "/14578143775306825906")
    }

    func testRTSPRequestRoutePathWithoutQueryNormalizesRelativeSetPropertyURI() throws {
        let request = Data("PUT /setProperty?selectedMediaArray RTSP/1.0\r\nCSeq: 11\r\n\r\n".utf8)

        let parsed = try XCTUnwrap(AirPlayControlRequest.parse(from: request))

        XCTAssertEqual(parsed.request.routePath, "/setProperty?selectedMediaArray")
        XCTAssertEqual(parsed.request.routePathWithoutQuery, "/setProperty")
        XCTAssertEqual(parsed.request.routeQuery, "selectedMediaArray")
    }

    func testRTSPResponseSerializesCSeqAndBodyLength() {
        let response = AirPlayControlResponse.ok(
            headers: ["Content-Type": "application/x-apple-binary-plist"],
            body: Data([1, 2, 3])
        )

        let data = response.serialized(cseq: "42")
        let text = String(data: data.prefix(data.count - 3), encoding: .utf8)

        XCTAssertTrue(text?.contains("RTSP/1.0 200 OK\r\n") == true)
        XCTAssertTrue(text?.contains("CSeq: 42\r\n") == true)
        XCTAssertTrue(text?.contains("Content-Length: 3\r\n") == true)
        XCTAssertTrue(data.suffix(3).elementsEqual([1, 2, 3]))
    }

    func testRTSPResponseSerializesClientAuthenticationFailure() {
        let response = AirPlayControlResponse.clientAuthenticationFailure("nope")

        let data = response.serialized(cseq: "8")
        let text = String(data: data, encoding: .utf8)

        XCTAssertTrue(text?.contains("RTSP/1.0 470 Client Authentication Failure\r\n") == true)
        XCTAssertTrue(text?.contains("CSeq: 8\r\n") == true)
    }

    func testHTTPReverseUpgradeResponseSerializesSwitchingProtocols() {
        let response = AirPlayControlResponse.switchingProtocols(headers: ["Server": "AirPlay/220.68"])

        let data = response.serialized(protocolVersion: "HTTP/1.1")
        let text = String(data: data, encoding: .utf8)

        XCTAssertTrue(text?.contains("HTTP/1.1 101 Switching Protocols\r\n") == true)
        XCTAssertTrue(text?.contains("Connection: Upgrade\r\n") == true)
        XCTAssertTrue(text?.contains("Upgrade: PTTH/1.0\r\n") == true)
        XCTAssertTrue(text?.contains("Content-Length: 0\r\n") == true)
        XCTAssertTrue(text?.contains("Server: AirPlay/220.68\r\n") == true)
    }

    func testHTTPAirPlayEventRequestsParseWithoutCSeq() throws {
        let serverInfo = Data("GET /server-info HTTP/1.1\r\nContent-Length: 0\r\nX-Apple-Session-ID: secret\r\n\r\n".utf8)
        let reverse = Data("POST /reverse HTTP/1.1\r\nConnection: Upgrade\r\nUpgrade: PTTH/1.0\r\nContent-Length: 0\r\nX-Apple-Purpose: event\r\n\r\n".utf8)

        let parsedServerInfo = try XCTUnwrap(AirPlayControlRequest.parse(from: serverInfo))
        let parsedReverse = try XCTUnwrap(AirPlayControlRequest.parse(from: reverse))

        XCTAssertEqual(parsedServerInfo.request.protocolVersion, "HTTP/1.1")
        XCTAssertEqual(parsedServerInfo.request.routePath, "/server-info")
        XCTAssertNil(parsedServerInfo.request.cseq)
        XCTAssertEqual(parsedReverse.request.protocolVersion, "HTTP/1.1")
        XCTAssertEqual(parsedReverse.request.routePath, "/reverse")
        XCTAssertEqual(parsedReverse.request.headerValue("Upgrade"), "PTTH/1.0")
    }

    func testRTSPResponseSerializesParameterNotUnderstood() {
        let response = AirPlayControlResponse.parameterNotUnderstood("bad parameter")

        let data = response.serialized(cseq: "10")
        let text = String(data: data, encoding: .utf8)

        XCTAssertTrue(text?.contains("RTSP/1.0 451 Parameter Not Understood\r\n") == true)
        XCTAssertTrue(text?.contains("CSeq: 10\r\n") == true)
    }

    func testAirPlayTextParameterVolumeResponseMatchesRTSPParameterFormat() {
        XCTAssertEqual(
            AirPlayTextParameters.volumeResponseText(decibels: 0.0),
            "volume: 0.000000\r\n"
        )
    }

    func testAirPlayTextParameterParsingHandlesVolumeQueryAndAssignments() {
        XCTAssertEqual(AirPlayTextParameters.normalizedContentType(from: "text/parameters; charset=utf-8"), "text/parameters")
        XCTAssertEqual(AirPlayTextParameters.parameterLines(from: "volume\r\nprogress\r\n"), ["volume", "progress"])
        XCTAssertEqual(
            AirPlayTextParameters.parameterAssignments(from: "volume: -12.500000\r\n"),
            [AirPlayTextParameters.Assignment(name: "volume", value: "-12.500000")]
        )
    }

    func testControlRequestSanitizedHeadersRedactsSensitiveValues() {
        let request = AirPlayControlRequest(
            method: "POST",
            path: "/pair-verify",
            protocolVersion: "RTSP/1.0",
            headers: [
                "CSeq": "3",
                "X-Apple-Session-ID": "secret-session",
                "Authorization": "secret-auth"
            ],
            body: Data([1, 2, 3])
        )

        let sanitized = request.sanitizedHeadersForLog

        XCTAssertTrue(sanitized.contains("CSeq=3"))
        XCTAssertTrue(sanitized.contains("X-Apple-Session-ID=<redacted>"))
        XCTAssertTrue(sanitized.contains("Authorization=<redacted>"))
        XCTAssertFalse(sanitized.contains("secret-session"))
        XCTAssertFalse(sanitized.contains("secret-auth"))
    }

    func testPairingSessionPreservesPINFlowAfterTransientControlDisconnect() {
        var session = AirPlayPairingSession(pinGenerator: { "2468" })

        XCTAssertFalse(session.shouldPreservePINOnControlDisconnect)

        let result = session.beginPinPairing()

        XCTAssertEqual(result.visiblePIN, "2468")
        XCTAssertTrue(session.shouldPreservePINOnControlDisconnect)

        session.reset(reason: "full teardown")

        XCTAssertFalse(session.shouldPreservePINOnControlDisconnect)
    }

    func testBonjourTXTRecordsIncludeAirPlayDiscoveryKeys() {
        let config = AirPlayBonjourPublisher.Configuration(
            serviceName: "Specchio",
            controlPort: 7000,
            publicKeyHex: String(repeating: "a", count: 64),
            persistentIdentifier: "11111111-2222-3333-4444-555555555555",
            deviceID: "AA:BB:CC:DD:EE:FF"
        )

        let airPlay = AirPlayBonjourPublisher.airPlayTXTRecord(configuration: config)
        let raop = AirPlayBonjourPublisher.raopTXTRecord(configuration: config)

        XCTAssertEqual(String(data: airPlay["deviceid"]!, encoding: .utf8), "AA:BB:CC:DD:EE:FF")
        XCTAssertEqual(String(data: airPlay["model"]!, encoding: .utf8), "AppleTV5,3")
        XCTAssertEqual(String(data: airPlay["pk"]!, encoding: .utf8)?.count, 64)
        XCTAssertEqual(String(data: airPlay["pw"]!, encoding: .utf8), "false")
        XCTAssertEqual(String(data: airPlay["features"]!, encoding: .utf8), "0x5A7FFFF7,0x1E")
        XCTAssertEqual(String(data: raop["ft"]!, encoding: .utf8), "0x5A7FFFF7,0x1E")
        XCTAssertEqual(String(data: raop["pw"]!, encoding: .utf8), "false")
        XCTAssertEqual(String(data: raop["tp"]!, encoding: .utf8), "TCP")
        XCTAssertEqual(String(data: raop["vv"]!, encoding: .utf8), "2")
    }

    func testBonjourTXTRecordsAdvertiseScreenMultiCodecWhenEnabled() {
        let config = AirPlayBonjourPublisher.Configuration.make(
            serviceName: "Specchio",
            controlPort: 7000,
            publicKeyHex: String(repeating: "a", count: 64),
            supportsScreenMultiCodec: true
        )

        let airPlay = AirPlayBonjourPublisher.airPlayTXTRecord(configuration: config)
        let raop = AirPlayBonjourPublisher.raopTXTRecord(configuration: config)

        XCTAssertEqual(String(data: airPlay["features"]!, encoding: .utf8), "0x5A7FFFF7,0x41E")
        XCTAssertEqual(String(data: raop["ft"]!, encoding: .utf8), "0x5A7FFFF7,0x41E")
        XCTAssertTrue(AirPlayFeatureMask.includesScreenMultiCodec(
            AirPlayFeatureMask.receiverInfoFeatures(supportsScreenMultiCodec: true)
        ))
    }

    func testReceiverInfoIncludesDisplayCapabilities() throws {
        let config = AirPlayBonjourPublisher.Configuration(
            serviceName: "Specchio",
            controlPort: 7000,
            publicKeyHex: String(repeating: "a", count: 64),
            persistentIdentifier: "11111111-2222-3333-4444-555555555555",
            deviceID: "AA:BB:CC:DD:EE:FF"
        )
        let publicKey = Data(repeating: 0x11, count: 32)

        let payload = AirPlayReceiverInfoPayload.make(
            configuration: config,
            publicKey: publicKey,
            requestBody: Data(),
            maximumFPS: 60,
            displayConfiguration: AirPlayReceiverDisplayConfiguration.make(
                quality: AppSettings.EasyAirPlayQuality.balanced
            )
        )

        XCTAssertEqual(payload.branch, "FULL_RECEIVER_INFO")
        XCTAssertEqual(payload.plist["deviceID"] as? String, "AA:BB:CC:DD:EE:FF")
        XCTAssertEqual(payload.plist["pk"] as? Data, publicKey)
        XCTAssertEqual(payload.plist["keepAliveSendStatsAsBody"] as? Bool, true)
        let displays = try XCTUnwrap(payload.plist["displays"] as? [[String: Any]])
        let display = try XCTUnwrap(displays.first)
        XCTAssertEqual(display["width"] as? Int, 1920)
        XCTAssertEqual(display["height"] as? Int, 1080)
        XCTAssertEqual(display["widthPixels"] as? Int, 1920)
        XCTAssertEqual(display["heightPixels"] as? Int, 1080)
        XCTAssertEqual(display["maxFPS"] as? Int, 60)
        XCTAssertEqual(display["features"] as? Int, 14)
        XCTAssertEqual(display["uuid"] as? String, "11111111-2222-3333-4444-555555555555")
        let features = try XCTUnwrap(payload.plist["features"] as? UInt64)
        XCTAssertFalse(AirPlayFeatureMask.includesScreenMultiCodec(features))
    }

    func testEasyH264TargetFPSRangeAllowsAirPlaySixtyFPS() {
        XCTAssertEqual(AppSettings.sanitizedEasyReplayKitH264TargetFPS(60), 60)
        XCTAssertEqual(AppSettings.sanitizedEasyReplayKitH264TargetFPS(61), 60)
    }

    func testAirPlayStaleVideoWithRecentMirrorActivityInfersScreenOff() {
        let health = AirPlayStreamHealth.inferredHealthForStaleVideo(
            lastFrameAge: 3.4,
            mirrorPacketAge: 0.8,
            freshnessThreshold: 3.0
        )

        XCTAssertEqual(health, .screenOff(lastFrameAge: 3.4))
        XCTAssertEqual(health.statusText, "AirPlay: Screen off")
        XCTAssertTrue(health.allowsFrameStalenessEvaluation)
    }

    func testAirPlayStaleVideoWithoutRecentMirrorActivityStaysGenericStale() {
        let oldHeartbeatHealth = AirPlayStreamHealth.inferredHealthForStaleVideo(
            lastFrameAge: 4.2,
            mirrorPacketAge: 3.1,
            freshnessThreshold: 3.0
        )
        let missingHeartbeatHealth = AirPlayStreamHealth.inferredHealthForStaleVideo(
            lastFrameAge: 4.2,
            mirrorPacketAge: nil,
            freshnessThreshold: 3.0
        )

        XCTAssertEqual(oldHeartbeatHealth, .stale(lastFrameAge: 4.2))
        XCTAssertEqual(missingHeartbeatHealth, .stale(lastFrameAge: 4.2))
        XCTAssertFalse(oldHeartbeatHealth.allowsFrameStalenessEvaluation)
        XCTAssertFalse(missingHeartbeatHealth.allowsFrameStalenessEvaluation)
    }

    func testEasyAirPlayQualityUsesHighAdvertisedDisplaySize() {
        XCTAssertEqual(
            AirPlayReceiverDisplayConfiguration.make(),
            AirPlayReceiverDisplayConfiguration(
                quality: AppSettings.EasyAirPlayQuality.balanced,
                width: 1920,
                height: 1080,
                refreshRateHz: 60
            )
        )
        XCTAssertEqual(
            AirPlayReceiverDisplayConfiguration.make(quality: AppSettings.EasyAirPlayQuality.high),
            AirPlayReceiverDisplayConfiguration(
                quality: AppSettings.EasyAirPlayQuality.high,
                width: 2560,
                height: 1440,
                refreshRateHz: 60
            )
        )
        XCTAssertEqual(
            AppSettings.EasyAirPlayQuality.sanitized(AppSettings.EasyAirPlayQuality.high),
            AppSettings.EasyAirPlayQuality.high
        )
        XCTAssertEqual(
            AppSettings.EasyAirPlayQuality.sanitized("unsupported"),
            AppSettings.EasyAirPlayQuality.balanced
        )
        XCTAssertEqual(
            AirPlayReceiverDisplayConfiguration.make(quality: AppSettings.EasyAirPlayQuality.balanced),
            AirPlayReceiverDisplayConfiguration(
                quality: AppSettings.EasyAirPlayQuality.balanced,
                width: 1920,
                height: 1080,
                refreshRateHz: 60
            )
        )
    }

    func testReceiverInfoUsesHighAdvertisedDisplaySizeAndScreenMultiCodec() throws {
        let config = AirPlayBonjourPublisher.Configuration(
            serviceName: "Specchio",
            controlPort: 7000,
            publicKeyHex: String(repeating: "a", count: 64),
            persistentIdentifier: "11111111-2222-3333-4444-555555555555",
            deviceID: "AA:BB:CC:DD:EE:FF"
        )
        let publicKey = Data(repeating: 0x11, count: 32)

        let payload = AirPlayReceiverInfoPayload.make(
            configuration: config,
            publicKey: publicKey,
            requestBody: Data(),
            maximumFPS: 60,
            displayConfiguration: AirPlayReceiverDisplayConfiguration.make(
                quality: AppSettings.EasyAirPlayQuality.high
            )
        )

        XCTAssertEqual(payload.displayConfiguration.quality, AppSettings.EasyAirPlayQuality.high)
        let displays = try XCTUnwrap(payload.plist["displays"] as? [[String: Any]])
        let display = try XCTUnwrap(displays.first)
        XCTAssertEqual(display["width"] as? Int, 2560)
        XCTAssertEqual(display["height"] as? Int, 1440)
        XCTAssertEqual(display["widthPixels"] as? Int, 2560)
        XCTAssertEqual(display["heightPixels"] as? Int, 1440)
        XCTAssertEqual(display["maxFPS"] as? Int, 60)
        let features = try XCTUnwrap(payload.plist["features"] as? UInt64)
        XCTAssertTrue(AirPlayFeatureMask.includesScreenMultiCodec(features))
    }

    func testReceiverInfoQualifierReturnsTXTRecordPayloadsOnly() throws {
        let config = AirPlayBonjourPublisher.Configuration(
            serviceName: "Specchio",
            controlPort: 7000,
            publicKeyHex: String(repeating: "a", count: 64),
            persistentIdentifier: "11111111-2222-3333-4444-555555555555",
            deviceID: "AA:BB:CC:DD:EE:FF"
        )
        let requestBody = try PropertyListSerialization.data(
            fromPropertyList: ["qualifier": ["txtAirPlay", "txtRAOP"]],
            format: .binary,
            options: 0
        )

        let payload = AirPlayReceiverInfoPayload.make(
            configuration: config,
            publicKey: Data(repeating: 0x11, count: 32),
            requestBody: requestBody
        )

        XCTAssertEqual(payload.branch, "QUALIFIER_TXT")
        XCTAssertEqual(payload.keys, ["txtAirPlay", "txtRAOP"])
        XCTAssertNil(payload.plist["deviceID"])
        let airPlayTXTData = try XCTUnwrap(payload.plist["txtAirPlay"] as? Data)
        let raopTXTData = try XCTUnwrap(payload.plist["txtRAOP"] as? Data)
        let airPlayTXT = NetService.dictionary(fromTXTRecord: airPlayTXTData)
        let raopTXT = NetService.dictionary(fromTXTRecord: raopTXTData)
        XCTAssertEqual(String(data: airPlayTXT["deviceid"]!, encoding: .utf8), "AA:BB:CC:DD:EE:FF")
        XCTAssertEqual(String(data: airPlayTXT["pk"]!, encoding: .utf8), String(repeating: "a", count: 64))
        XCTAssertEqual(String(data: raopTXT["pk"]!, encoding: .utf8), String(repeating: "a", count: 64))
    }

    func testMediaSetPropertyPayloadParsesSelectedMediaArray() throws {
        let body = try PropertyListSerialization.data(
            fromPropertyList: [
                [
                    "type": "audible",
                    "enabled": true
                ]
            ],
            format: .binary,
            options: 0
        )
        let request = AirPlayControlRequest(
            method: "PUT",
            path: "/setProperty?selectedMediaArray",
            protocolVersion: "RTSP/1.0",
            headers: ["Content-Type": "application/x-apple-binary-plist"],
            body: body
        )

        let payload = AirPlayMediaSetPropertyPayload.make(request: request)

        XCTAssertEqual(payload.propertyName, "selectedMediaArray")
        XCTAssertEqual(payload.bodyKind, "array")
        XCTAssertEqual(payload.itemCount, 1)
        XCTAssertEqual(payload.plistKeys, [])
    }

    func testMediaSetPropertyPayloadParsesPreferredMediaSelectionSchemes() throws {
        let body = try PropertyListSerialization.data(
            fromPropertyList: [
                "mediaCharacteristics": ["audible", "legible"]
            ],
            format: .binary,
            options: 0
        )
        let request = AirPlayControlRequest(
            method: "PUT",
            path: "/setProperty?mediaCharacteristicsForPreferredCustomMediaSelectionSchemes",
            protocolVersion: "RTSP/1.0",
            headers: ["Content-Type": "application/x-apple-binary-plist"],
            body: body
        )

        let payload = AirPlayMediaSetPropertyPayload.make(request: request)

        XCTAssertEqual(payload.propertyName, "mediaCharacteristicsForPreferredCustomMediaSelectionSchemes")
        XCTAssertEqual(payload.bodyKind, "dictionary")
        XCTAssertEqual(payload.plistKeys, ["mediaCharacteristics"])
        XCTAssertNil(payload.itemCount)
    }

    func testTeardownPayloadParsesScopedAudioStream() throws {
        let body = try PropertyListSerialization.data(
            fromPropertyList: [
                "streams": [
                    [
                        "streamID": 0,
                        "type": 96
                    ]
                ]
            ],
            format: .binary,
            options: 0
        )
        let request = AirPlayControlRequest(
            method: "TEARDOWN",
            path: "rtsp://fe80::1/5341791999287772321",
            protocolVersion: "RTSP/1.0",
            headers: ["Content-Type": "application/x-apple-binary-plist"],
            body: body
        )

        let payload = AirPlayTeardownPayload.make(request: request)

        XCTAssertEqual(payload.bodyKind, "dictionary")
        XCTAssertEqual(payload.plistKeys, ["streams"])
        XCTAssertEqual(payload.streamCount, 1)
        XCTAssertEqual(payload.streamTypes, [96])
        XCTAssertTrue(payload.requestsAudioTeardown)
        XCTAssertFalse(payload.requestsMirrorTeardown)
        XCTAssertFalse(payload.requestsFullSessionTeardown)
    }

    func testTeardownPayloadTreatsEmptyBodyAsFullSessionTeardown() {
        let request = AirPlayControlRequest(
            method: "TEARDOWN",
            path: "rtsp://fe80::1/5341791999287772321",
            protocolVersion: "RTSP/1.0",
            headers: [:],
            body: Data()
        )

        let payload = AirPlayTeardownPayload.make(request: request)

        XCTAssertEqual(payload.bodyKind, "empty")
        XCTAssertEqual(payload.streamTypes, [])
        XCTAssertFalse(payload.requestsAudioTeardown)
        XCTAssertFalse(payload.requestsMirrorTeardown)
        XCTAssertTrue(payload.requestsFullSessionTeardown)
    }

    func testSetupStreamsResponseCanIncludeTimingMirrorAndAudioPorts() throws {
        let payload = AirPlaySetupResponsePayload.streams(
            timingPort: 49152,
            streams: [
                [
                    "dataPort": 52000,
                    "type": 110
                ],
                [
                    "controlPort": 52002,
                    "dataPort": 52001,
                    "type": 96
                ]
            ]
        )

        XCTAssertEqual(payload.branch, "STREAMS")
        XCTAssertEqual(payload.plist["eventPort"] as? Int, 0)
        XCTAssertEqual(payload.plist["timingPort"] as? Int, 49152)
        let streams = try XCTUnwrap(payload.plist["streams"] as? [[String: Any]])
        XCTAssertEqual(streams.count, 2)
        XCTAssertEqual(streams[0]["type"] as? Int, 110)
        XCTAssertEqual(streams[0]["dataPort"] as? Int, 52000)
        XCTAssertEqual(streams[1]["type"] as? Int, 96)
        XCTAssertEqual(streams[1]["dataPort"] as? Int, 52001)
        XCTAssertEqual(streams[1]["controlPort"] as? Int, 52002)

        let body = try PropertyListSerialization.data(fromPropertyList: payload.plist, format: .binary, options: 0)
        let decoded = try XCTUnwrap(
            PropertyListSerialization.propertyList(from: body, options: [], format: nil) as? [String: Any]
        )
        XCTAssertEqual(decoded["timingPort"] as? Int, 49152)
        XCTAssertEqual((decoded["streams"] as? [[String: Any]])?.count, 2)
    }

    func testBonjourInfoPlistServiceTypesMatchPublisherTypesExactly() throws {
        let plistURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("SupportingFiles/Info.plist")
        let plistData = try Data(contentsOf: plistURL)
        let plist = try XCTUnwrap(
            PropertyListSerialization.propertyList(from: plistData, options: [], format: nil) as? [String: Any]
        )
        let bonjourServices = try XCTUnwrap(plist["NSBonjourServices"] as? [String])

        for serviceType in AirPlayBonjourPublisher.requiredInfoPlistServiceTypes {
            XCTAssertTrue(
                bonjourServices.contains(serviceType),
                "NSBonjourServices must contain the exact NetService type \(serviceType)"
            )
        }
    }

    func testMirrorPacketHeaderParsesLittleEndianVideoAndConfigFields() {
        var videoHeader = Data(repeating: 0, count: AirPlayMirrorPacket.headerByteCount)
        videoHeader.writeUInt32LE(12, at: 0)
        videoHeader.writeUInt16LE(0, at: 4)
        videoHeader.writeUInt64LE(0x0000_0002_8000_0000, at: 8)

        let video = AirPlayMirrorPacket(headerData: videoHeader)
        XCTAssertEqual(video?.payloadSize, 12)
        XCTAssertEqual(video?.payloadType, 0)
        XCTAssertEqual(video?.rawPayloadType, 0)
        XCTAssertEqual(video?.isVideoPayload, true)
        XCTAssertEqual(video?.isIDRVideoPayload, false)
        XCTAssertEqual(video?.presentationTimestampMilliseconds, 2500)

        var idrHeader = Data(repeating: 0, count: AirPlayMirrorPacket.headerByteCount)
        idrHeader.writeUInt32LE(8, at: 0)
        idrHeader.writeUInt16LE(0x1000, at: 4)
        let idr = AirPlayMirrorPacket(headerData: idrHeader)
        XCTAssertEqual(idr?.payloadType, 0)
        XCTAssertEqual(idr?.rawPayloadType, 0x1000)
        XCTAssertEqual(idr?.isVideoPayload, true)
        XCTAssertEqual(idr?.isIDRVideoPayload, true)

        var configHeader = Data(repeating: 0, count: AirPlayMirrorPacket.headerByteCount)
        configHeader.writeUInt32LE(32, at: 0)
        configHeader.writeUInt16LE(1, at: 4)
        configHeader.writeFloat32LE(1170, at: 40)
        configHeader.writeFloat32LE(2532, at: 44)
        configHeader.writeFloat32LE(390, at: 56)
        configHeader.writeFloat32LE(844, at: 60)

        let config = AirPlayMirrorPacket(headerData: configHeader)
        XCTAssertEqual(config?.payloadSize, 32)
        XCTAssertEqual(config?.payloadType, 1)
        XCTAssertEqual(config?.rawPayloadType, 1)
        XCTAssertEqual(config?.isCodecConfigurationPayload, true)
        XCTAssertEqual(config?.sourceDimensions, CGSize(width: 1170, height: 2532))
        XCTAssertEqual(config?.renderDimensions, CGSize(width: 390, height: 844))

        var reportHeader = Data(repeating: 0, count: AirPlayMirrorPacket.headerByteCount)
        reportHeader.writeUInt32LE(32, at: 0)
        reportHeader.writeUInt16LE(5, at: 4)
        let report = AirPlayMirrorPacket(headerData: reportHeader)
        XCTAssertEqual(report?.payloadType, 5)
        XCTAssertEqual(report?.isStreamingReportPayload, true)
    }

    func testMirrorPacketClassifiesWireOrderCodecOptions() throws {
        var hevcConfigHeader = Data(repeating: 0, count: AirPlayMirrorPacket.headerByteCount)
        hevcConfigHeader.writeUInt16LE(1, at: 4)
        hevcConfigHeader.writeUInt16LE(0x011E, at: 6)
        let hevcConfig = try XCTUnwrap(AirPlayMirrorPacket(headerData: hevcConfigHeader))
        let hevcConfigDecision = hevcConfig.codecConfigurationVideoCodecDecision(payload: nil)
        XCTAssertEqual(hevcConfig.payloadOption, 0x011E)
        XCTAssertEqual(hevcConfigDecision.codec, .hevc)
        XCTAssertEqual(hevcConfigDecision.branch, "option-wire-hevc-config")
        XCTAssertFalse(hevcConfig.isCodecStopPayload)

        var hevcStopHeader = Data(repeating: 0, count: AirPlayMirrorPacket.headerByteCount)
        hevcStopHeader.writeUInt16LE(1, at: 4)
        hevcStopHeader.writeUInt16LE(0x015E, at: 6)
        let hevcStop = try XCTUnwrap(AirPlayMirrorPacket(headerData: hevcStopHeader))
        let hevcStopDecision = hevcStop.codecConfigurationVideoCodecDecision(payload: nil)
        XCTAssertEqual(hevcStopDecision.codec, .hevc)
        XCTAssertEqual(hevcStopDecision.branch, "option-wire-hevc-stop")
        XCTAssertTrue(hevcStop.isCodecStopPayload)

        var h264ConfigHeader = Data(repeating: 0, count: AirPlayMirrorPacket.headerByteCount)
        h264ConfigHeader.writeUInt16LE(1, at: 4)
        h264ConfigHeader.writeUInt16LE(0x0116, at: 6)
        let h264Config = try XCTUnwrap(AirPlayMirrorPacket(headerData: h264ConfigHeader))
        let h264ConfigDecision = h264Config.codecConfigurationVideoCodecDecision(payload: nil)
        XCTAssertEqual(h264ConfigDecision.codec, .h264)
        XCTAssertEqual(h264ConfigDecision.branch, "option-wire-h264-config")
    }

    func testMirrorPacketClassifiesHVC1PayloadAsHEVCWhenOptionIsUnrecognized() throws {
        let vps = Data([0x40, 0x01, 0x0C, 0x01])
        let sps = Data([0x42, 0x01, 0x01, 0x60])
        let pps = Data([0x44, 0x01, 0xC0, 0x73])
        var configPayload = Data(repeating: 0, count: 0x75)
        configPayload.replaceSubrange(4..<8, with: Data("hvc1".utf8))
        appendHEVCArray(nalType: 32, nalUnit: vps, to: &configPayload)
        appendHEVCArray(nalType: 33, nalUnit: sps, to: &configPayload)
        appendHEVCArray(nalType: 34, nalUnit: pps, to: &configPayload)

        var header = Data(repeating: 0, count: AirPlayMirrorPacket.headerByteCount)
        header.writeUInt16LE(1, at: 4)
        header.writeUInt16LE(0x0006, at: 6)
        let packet = try XCTUnwrap(AirPlayMirrorPacket(headerData: header))

        let decision = packet.codecConfigurationVideoCodecDecision(payload: configPayload)
        XCTAssertEqual(decision.codec, .hevc)
        XCTAssertEqual(decision.branch, "payload-hevc-signature")
    }

    func testTimingServerBuildsNTPServerResponse() throws {
        var request = Data(repeating: 0, count: 48)
        request[0] = 0x23
        request[2] = 6
        let clientTransmitTimestamp: UInt64 = 0x1122_3344_5566_7788
        request.writeUInt64BE(clientTransmitTimestamp, at: 40)

        let response = try XCTUnwrap(
            AirPlayTimingServer.response(
                for: request,
                now: Date(timeIntervalSince1970: 1)
            )
        )

        let expectedTimestamp = UInt64(2_208_988_801) << 32
        XCTAssertEqual(response.count, 48)
        XCTAssertEqual(response[0], 0x24)
        XCTAssertEqual(response[1], 2)
        XCTAssertEqual(response[2], 6)
        XCTAssertEqual(response.readUInt64BE(at: 16), expectedTimestamp)
        XCTAssertEqual(response.readUInt64BE(at: 24), clientTransmitTimestamp)
        XCTAssertEqual(response.readUInt64BE(at: 32), expectedTimestamp)
        XCTAssertEqual(response.readUInt64BE(at: 40), expectedTimestamp)
    }

    func testTimingServerBuildsActiveProbeRequest() {
        let sentAt = Date(timeIntervalSince1970: 3)
        let receivedAt = Date(timeIntervalSince1970: 2)
        let clientReference: UInt64 = 0x1122_3344_5566_7788

        let request = AirPlayTimingServer.probeRequest(
            sentAt: sentAt,
            previousClientReferenceTimestamp: clientReference,
            previousResponseReceivedAt: receivedAt
        )

        XCTAssertEqual(request.count, 32)
        XCTAssertEqual(request[0], 0x80)
        XCTAssertEqual(request[1], 0xd2)
        XCTAssertEqual(request[2], 0x00)
        XCTAssertEqual(request[3], 0x07)
        XCTAssertEqual(request.readUInt64BE(at: 8), clientReference)
        XCTAssertEqual(request.readUInt64BE(at: 16), UInt64(2_208_988_802) << 32)
        XCTAssertEqual(request.readUInt64BE(at: 24), UInt64(2_208_988_803) << 32)
    }

    func testH264AdapterBuildsReplayKitPacketsFromAirPlayPayloads() throws {
        let sps = Data([0x67, 0x42, 0x00, 0x1F])
        let pps = Data([0x68, 0xCE, 0x06, 0xE2])
        var configPayload = Data([0x01, 0x42, 0x00, 0x1F, 0xFF, 0xE1])
        configPayload.appendUInt16BE(UInt16(sps.count))
        configPayload.append(sps)
        configPayload.append(0x01)
        configPayload.appendUInt16BE(UInt16(pps.count))
        configPayload.append(pps)

        var adapter = AirPlayH264FrameAdapter()
        let config = try adapter.applyConfigurationPayload(configPayload, dimensions: CGSize(width: 390, height: 844))
        XCTAssertEqual(config.spsData, sps)
        XCTAssertEqual(config.ppsData, pps)

        let idr = Data([0x65, 0x88, 0x84])
        var payload = Data()
        payload.appendUInt32BE(UInt32(idr.count))
        payload.append(idr)

        var header = Data(repeating: 0, count: AirPlayMirrorPacket.headerByteCount)
        header.writeUInt32LE(UInt32(payload.count), at: 0)
        header.writeUInt16LE(0, at: 4)
        header.writeUInt64LE(0x0000_0001_0000_0000, at: 8)
        let mirrorPacket = try XCTUnwrap(AirPlayMirrorPacket(headerData: header))

        let adapted = try adapter.adaptAccessUnitPayload(payload, packet: mirrorPacket)
        XCTAssertTrue(adapted.isKeyframe)
        XCTAssertTrue(adapted.includesParameterSets)
        XCTAssertTrue(adapted.packet.header.flags.contains(.keyframe))
        XCTAssertTrue(ReplayKitAnnexBParser.containsIDR(in: adapted.packet.annexBBytes))
        XCTAssertEqual(ReplayKitAnnexBParser.parameterSets(from: adapted.packet.annexBBytes).sps, sps)
        XCTAssertEqual(ReplayKitAnnexBParser.parameterSets(from: adapted.packet.annexBBytes).pps, pps)
    }

    func testHEVCAdapterParsesAirPlayHVC1ConfigurationPayload() throws {
        let vps = Data([0x40, 0x01, 0x0C, 0x01])
        let sps = Data([0x42, 0x01, 0x01, 0x60])
        let pps = Data([0x44, 0x01, 0xC0, 0x73])
        var configPayload = Data(repeating: 0, count: 0x75)
        configPayload.replaceSubrange(4..<8, with: Data("hvc1".utf8))
        appendHEVCArray(nalType: 32, nalUnit: vps, to: &configPayload)
        appendHEVCArray(nalType: 33, nalUnit: sps, to: &configPayload)
        appendHEVCArray(nalType: 34, nalUnit: pps, to: &configPayload)

        var adapter = AirPlayHEVCFrameAdapter()
        let config = try adapter.applyConfigurationPayload(
            configPayload,
            dimensions: CGSize(width: 1170, height: 2532)
        )

        XCTAssertEqual(adapter.lastConfigurationBranch, "hvc1-sample-entry")
        XCTAssertEqual(config.vps, vps)
        XCTAssertEqual(config.sps, sps)
        XCTAssertEqual(config.pps, pps)
        XCTAssertEqual(config.width, 1170)
        XCTAssertEqual(config.height, 2532)
    }

    func testHEVCAdapterBuildsReplayKitPacketsFromAirPlayPayloads() throws {
        let vps = Data([0x40, 0x01, 0x0C, 0x01])
        let sps = Data([0x42, 0x01, 0x01, 0x60])
        let pps = Data([0x44, 0x01, 0xC0, 0x73])
        var configPayload = Data(repeating: 0, count: 0x75)
        configPayload.replaceSubrange(4..<8, with: Data("hvc1".utf8))
        appendHEVCArray(nalType: 32, nalUnit: vps, to: &configPayload)
        appendHEVCArray(nalType: 33, nalUnit: sps, to: &configPayload)
        appendHEVCArray(nalType: 34, nalUnit: pps, to: &configPayload)

        var adapter = AirPlayHEVCFrameAdapter()
        _ = try adapter.applyConfigurationPayload(configPayload, dimensions: CGSize(width: 1170, height: 2532))

        let idr = Data([0x26, 0x01, 0xAA, 0xBB])
        var payload = Data()
        payload.appendUInt32BE(UInt32(idr.count))
        payload.append(idr)

        var header = Data(repeating: 0, count: AirPlayMirrorPacket.headerByteCount)
        header.writeUInt32LE(UInt32(payload.count), at: 0)
        header.writeUInt16LE(0x1000, at: 4)
        header.writeUInt64LE(0x0000_0001_0000_0000, at: 8)
        let mirrorPacket = try XCTUnwrap(AirPlayMirrorPacket(headerData: header))

        let adapted = try adapter.adaptAccessUnitPayload(payload, packet: mirrorPacket)
        XCTAssertTrue(adapted.isKeyframe)
        XCTAssertTrue(adapted.includesParameterSets)
        XCTAssertTrue(adapted.packet.header.flags.contains(.keyframe))
        XCTAssertTrue(ReplayKitAnnexBParser.containsHEVCRandomAccessPicture(in: adapted.packet.annexBBytes))
        let parameterSets = ReplayKitAnnexBParser.hevcParameterSets(from: adapted.packet.annexBBytes)
        XCTAssertEqual(parameterSets.vps, vps)
        XCTAssertEqual(parameterSets.sps, sps)
        XCTAssertEqual(parameterSets.pps, pps)
    }

    func testStreamConnectionIDNormalizesUnsignedDecimalForms() {
        XCTAssertEqual(
            AirPlayStreamConnectionID.normalizedString(from: "14578143775306825906"),
            "14578143775306825906"
        )
        XCTAssertEqual(
            AirPlayStreamConnectionID.normalizedString(from: NSNumber(value: Int64(-1))),
            "18446744073709551615"
        )
        XCTAssertEqual(
            AirPlayStreamConnectionID.normalizedString(from: "-1"),
            "18446744073709551615"
        )
    }

    func testFairPlayStreamKeyHashesProviderKeyWhenPairVerifySecretIsPresent() {
        let fairPlayKey = Data((0..<16).map(UInt8.init))
        let pairSecret = Data(repeating: 0xA5, count: 32)
        let expectedStreamKey = Data(SHA512.hash(data: fairPlayKey + pairSecret).prefix(16))

        XCTAssertEqual(
            AirPlayFairPlaySession.streamKey(
                fromFairPlayKey: fairPlayKey,
                pairVerifySharedSecret: pairSecret
            ),
            expectedStreamKey
        )
    }

    func testFairPlayStreamKeyUsesProviderKeyWhenPairVerifySecretIsMissing() {
        let fairPlayKey = Data((0..<16).map(UInt8.init))

        XCTAssertEqual(
            AirPlayFairPlaySession.streamKey(
                fromFairPlayKey: fairPlayKey,
                pairVerifySharedSecret: nil
            ),
            fairPlayKey
        )
    }

    func testVideoKeyMaterialNormalizesSignedStreamConnectionID() {
        let audioStreamKey = Data((0..<16).map(UInt8.init))
        let unsigned = AirPlayFairPlaySession.videoKeyMaterial(
            audioStreamKey: audioStreamKey,
            streamConnectionID: "18446744073709551615"
        )
        let signed = AirPlayFairPlaySession.videoKeyMaterial(
            audioStreamKey: audioStreamKey,
            streamConnectionID: "-1"
        )

        XCTAssertEqual(unsigned.key, signed.key)
        XCTAssertEqual(unsigned.iv, signed.iv)
    }

    func testH264DumpWriterIsOptInAndCapsOutput() throws {
        XCTAssertNil(AirPlayH264DumpWriter.Configuration.make(environment: [:]))

        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("Specchio-AirPlay-DumpWriter-\(UUID().uuidString).h264")
        defer { try? FileManager.default.removeItem(at: fileURL) }

        let configuration = try XCTUnwrap(
            AirPlayH264DumpWriter.Configuration.make(
                environment: [
                    "SPECCHIO_AIRPLAY_H264_DUMP_PATH": fileURL.path,
                    "SPECCHIO_AIRPLAY_H264_DUMP_LIMIT_BYTES": "6"
                ]
            )
        )
        let writer = AirPlayH264DumpWriter(configuration: configuration)

        writer.writeAccessUnit(Data([0, 1, 2, 3]), sequenceNumber: 1, isKeyframe: true)
        writer.writeAccessUnit(Data([4, 5, 6, 7]), sequenceNumber: 2, isKeyframe: false)

        XCTAssertEqual(writer.byteCount, 6)
        XCTAssertEqual(try Data(contentsOf: fileURL), Data([0, 1, 2, 3, 4, 5]))
    }

    func testPinSRPServerVerifiesRealClientProofAndCompletesEncryptedKeyExchange() throws {
        let username = "AA:BB:CC:DD:EE:FF"
        let pin = "1234"
        let salt = Data((1...16).map(UInt8.init))
        let serverPrivateKey = Data((33...64).map(UInt8.init))
        var server = try AirPlayPinSRPServer(
            username: username,
            pin: pin,
            salt: salt,
            privateKey: serverPrivateKey
        )

        let clientPrivateValue = BigUInt(Data((65...96).map(UInt8.init)))
        let clientPublicValue = AirPlayPinSRPServer.groupGenerator.power(
            clientPrivateValue,
            modulus: AirPlayPinSRPServer.groupPrime
        )
        let passwordPrivateKey = AirPlayPinSRPServer.passwordPrivateKey(
            username: username,
            pin: pin,
            salt: salt
        )
        let multiplier = AirPlayPinSRPServer.multiplier()
        let scramblingParameter = AirPlayPinSRPServer.scramblingParameter(
            clientPublicValue: clientPublicValue,
            serverPublicValue: BigUInt(server.serverPublicKey)
        )
        let verifierBase = AirPlayPinSRPServer.groupGenerator.power(
            passwordPrivateKey,
            modulus: AirPlayPinSRPServer.groupPrime
        )
        let base = (BigUInt(server.serverPublicKey) + AirPlayPinSRPServer.groupPrime - ((multiplier * verifierBase) % AirPlayPinSRPServer.groupPrime)) % AirPlayPinSRPServer.groupPrime
        let exponent = clientPrivateValue + (scramblingParameter * passwordPrivateKey)
        let clientSharedSecret = base.power(exponent, modulus: AirPlayPinSRPServer.groupPrime)
        let clientSessionKey = AirPlayPinSRPServer.sessionKey(from: clientSharedSecret)
        let clientProof = AirPlayPinSRPServer.clientProof(
            username: username,
            salt: salt,
            clientPublicValue: clientPublicValue,
            serverPublicValue: BigUInt(server.serverPublicKey),
            sessionKey: clientSessionKey
        )

        let serverProof = try server.verify(
            clientPublicKey: AirPlayPinSRPServer.paddedData(clientPublicValue),
            clientProof: clientProof
        )

        XCTAssertEqual(
            serverProof,
            AirPlayPinSRPServer.serverProof(
                clientPublicValue: clientPublicValue,
                clientProof: clientProof,
                sessionKey: clientSessionKey
            )
        )

        let clientPairingPublicKey = Data((101...132).map(UInt8.init))
        let receiverPublicKey = Data((151...182).map(UInt8.init))
        let aesKey = AirPlayPairSetupCrypto.aesKey(from: clientSessionKey)
        var aesIV = AirPlayPairSetupCrypto.aesIV(from: clientSessionKey)
        aesIV[aesIV.index(before: aesIV.endIndex)] &+= 1
        let clientSealedBox = try AES.GCM.seal(
            clientPairingPublicKey,
            using: SymmetricKey(data: aesKey),
            nonce: AES.GCM.Nonce(data: aesIV)
        )

        let response = try server.completePairSetup(
            encryptedClientPublicKey: clientSealedBox.ciphertext,
            authTag: clientSealedBox.tag,
            receiverPublicKey: receiverPublicKey
        )

        aesIV[aesIV.index(before: aesIV.endIndex)] &+= 1
        let responseSealedBox = try AES.GCM.SealedBox(
            nonce: AES.GCM.Nonce(data: aesIV),
            ciphertext: response.encryptedPublicKey,
            tag: response.authTag
        )
        let decryptedReceiverPublicKey = try AES.GCM.open(
            responseSealedBox,
            using: SymmetricKey(data: aesKey)
        )

        XCTAssertEqual(decryptedReceiverPublicKey, receiverPublicKey)
    }

    func testPairVerifyCompletesEncryptedSignatureExchange() throws {
        var session = AirPlayPairingSession(pinGenerator: { "1234" })
        let setupResponse = session.handlePairSetup(AirPlayControlRequest(
            method: "POST",
            path: "/pair-setup",
            protocolVersion: "RTSP/1.0",
            headers: [:],
            body: Data()
        ))
        let receiverSigningPublicKey = setupResponse.response.body
        let clientAgreementKey = Curve25519.KeyAgreement.PrivateKey()
        let clientSigningKey = Curve25519.Signing.PrivateKey()
        let clientAgreementPublicKey = clientAgreementKey.publicKey.rawRepresentation
        let clientSigningPublicKey = clientSigningKey.publicKey.rawRepresentation
        let stepOneBody = Data([1, 0, 0, 0]) + clientAgreementPublicKey + clientSigningPublicKey

        let stepOneResult = session.handlePairVerify(AirPlayControlRequest(
            method: "POST",
            path: "/pair-verify",
            protocolVersion: "RTSP/1.0",
            headers: [:],
            body: stepOneBody
        ))

        XCTAssertEqual(stepOneResult.response.statusCode, 200)
        XCTAssertEqual(stepOneResult.response.body.count, 96)
        let serverAgreementPublicKey = stepOneResult.response.body.prefix(32)
        let encryptedServerSignature = stepOneResult.response.body.suffix(64)
        let serverAgreementKey = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: serverAgreementPublicKey)
        let sharedSecret = try clientAgreementKey.sharedSecretFromKeyAgreement(with: serverAgreementKey)
            .withUnsafeBytes { Data($0) }
        let serverSignature = try AirPlayAESCTR.crypt(
            encryptedServerSignature,
            key: AirPlayPairVerifyCrypto.aesKey(from: sharedSecret),
            iv: AirPlayPairVerifyCrypto.aesIV(from: sharedSecret)
        )
        let receiverSigningKey = try Curve25519.Signing.PublicKey(rawRepresentation: receiverSigningPublicKey)

        XCTAssertTrue(receiverSigningKey.isValidSignature(
            serverSignature,
            for: serverAgreementPublicKey + clientAgreementPublicKey
        ))

        let clientSignature = try clientSigningKey.signature(for: clientAgreementPublicKey + serverAgreementPublicKey)
        let encryptedClientSignature = try AirPlayAESCTR.crypt(
            clientSignature,
            key: AirPlayPairVerifyCrypto.aesKey(from: sharedSecret),
            iv: AirPlayPairVerifyCrypto.aesIV(from: sharedSecret),
            skipBytes: 64
        )
        let stepTwoBody = Data([0, 0, 0, 0]) + encryptedClientSignature

        let stepTwoResult = session.handlePairVerify(AirPlayControlRequest(
            method: "POST",
            path: "/pair-verify",
            protocolVersion: "RTSP/1.0",
            headers: [:],
            body: stepTwoBody
        ))

        XCTAssertEqual(stepTwoResult.response.statusCode, 200)
        XCTAssertEqual(stepTwoResult.phase, .verified)
        XCTAssertEqual(session.verifiedPairingSharedSecret, sharedSecret)
    }

    func testFairPlaySetupChallengeReportsProviderMissingWithVersionAndMode() {
        var session = AirPlayFairPlaySession(provider: nil)
        var body = Data([0x46, 0x50, 0x4c, 0x59, 0x03, 0x01, 0x02, 0x00])
        body.append(Data([0x00, 0x00, 0x00, 0x82, 0x02, 0x00, 0x02, 0x00]))

        let response = session.handleFPSetup(AirPlayControlRequest(
            method: "POST",
            path: "/fp-setup",
            protocolVersion: "RTSP/1.0",
            headers: ["X-Apple-ET": "32"],
            body: body
        ))

        XCTAssertEqual(response.statusCode, 501)
        XCTAssertEqual(session.phase, .setupReplyProviderMissing(version: 3, mode: 2, requestBytes: 16))
    }

    func testFairPlayKeyMessageIsRecognizedButProviderRemainsMissing() {
        var session = AirPlayFairPlaySession(provider: nil)
        var body = Data(repeating: 0, count: 164)
        body.replaceSubrange(0..<5, with: Data([0x46, 0x50, 0x4c, 0x59, 0x03]))

        let response = session.handleFPSetup(AirPlayControlRequest(
            method: "POST",
            path: "/fp-setup",
            protocolVersion: "RTSP/1.0",
            headers: [:],
            body: body
        ))

        XCTAssertEqual(response.statusCode, 501)
        XCTAssertEqual(session.phase, .keyMessageReceived(requestBytes: 164))
    }

    func testFairPlaySetup2UsesProviderBackedFairPlayFlow() {
        let setupReply = Data(repeating: 0xA5, count: 142)
        let provider = StubFairPlayProvider(
            setupReply: setupReply,
            keyMessageReply: Data(repeating: 0x5A, count: 32),
            decryptedStreamKey: Data(repeating: 0x11, count: 16)
        )
        var session = AirPlayFairPlaySession(provider: provider)
        var body = Data([0x46, 0x50, 0x4c, 0x59, 0x03, 0x01, 0x02, 0x00])
        body.append(Data([0x00, 0x00, 0x00, 0x82, 0x02, 0x00, 0x02, 0x00]))

        let response = session.handleFPSetup(
            AirPlayControlRequest(
                method: "POST",
                path: "/fp-setup2",
                protocolVersion: "RTSP/1.0",
                headers: ["X-Apple-ET": "32"],
                body: body
            ),
            routeName: "/fp-setup2"
        )

        XCTAssertEqual(response.statusCode, 200)
        XCTAssertEqual(response.body, setupReply)
        XCTAssertEqual(session.phase, .setupReplyProvided(version: 3, mode: 2, responseBytes: 142))
    }

    func testFairPlayDecryptsInstalledStreamKeyAcrossPayloadBoundaries() throws {
        var session = AirPlayFairPlaySession(provider: nil)
        let key = Data((1...16).map(UInt8.init))
        let iv = Data((17...32).map(UInt8.init))
        let firstPlaintext = Data((33...55).map(UInt8.init))
        let secondPlaintext = Data((56...91).map(UInt8.init))
        let encrypted = try AirPlayAESCTR.crypt(firstPlaintext + secondPlaintext, key: key, iv: iv)
        let firstEncrypted = encrypted.prefix(firstPlaintext.count)
        let secondEncrypted = encrypted.suffix(secondPlaintext.count)

        session.installStreamKeyForTestsOnly(key: key, iv: iv)

        XCTAssertEqual(session.decryptVideoPayload(Data(firstEncrypted)), .decrypted(firstPlaintext))
        XCTAssertEqual(session.decryptVideoPayload(Data(secondEncrypted)), .decrypted(secondPlaintext))
    }

    func testFairPlayDecryptsMirrorPacketPartialBlocksAcrossPayloadBoundaries() throws {
        var session = AirPlayFairPlaySession(provider: nil)
        let key = Data((101...116).map(UInt8.init))
        let iv = Data((117...132).map(UInt8.init))
        let packetSizes = [15, 1, 31, 5, 16, 17]
        let plaintext = Data((0..<packetSizes.reduce(0, +)).map { UInt8(($0 * 37 + 11) & 0xff) })
        let encrypted = try AirPlayAESCTR.crypt(plaintext, key: key, iv: iv)

        session.installStreamKeyForTestsOnly(key: key, iv: iv)

        var offset = 0
        for packetSize in packetSizes {
            let range = offset..<(offset + packetSize)
            XCTAssertEqual(
                session.decryptVideoPayload(encrypted.subdata(in: range)),
                .decrypted(plaintext.subdata(in: range)),
                "packetSize=\(packetSize) offset=\(offset)"
            )
            offset += packetSize
        }
    }

    func testFairPlayProviderRepliesAndDerivesVideoKeyMaterial() throws {
        let setupReply = Data(repeating: 0xA5, count: 142)
        let keyMessageReply = Data(repeating: 0x5A, count: 32)
        let fairPlayStreamKey = Data((1...16).map(UInt8.init))
        let provider = StubFairPlayProvider(
            setupReply: setupReply,
            keyMessageReply: keyMessageReply,
            decryptedStreamKey: fairPlayStreamKey
        )
        var session = AirPlayFairPlaySession(provider: provider)
        var challenge = Data([0x46, 0x50, 0x4c, 0x59, 0x03, 0x01, 0x02, 0x00])
        challenge.append(Data([0x00, 0x00, 0x00, 0x82, 0x02, 0x00, 0x02, 0x00]))

        let challengeResponse = session.handleFPSetup(AirPlayControlRequest(
            method: "POST",
            path: "/fp-setup",
            protocolVersion: "RTSP/1.0",
            headers: ["X-Apple-ET": "32"],
            body: challenge
        ))

        XCTAssertEqual(challengeResponse.statusCode, 200)
        XCTAssertEqual(challengeResponse.body, setupReply)
        XCTAssertEqual(session.phase, .setupReplyProvided(version: 3, mode: 2, responseBytes: 142))

        var keyMessage = Data(repeating: 0, count: 164)
        keyMessage.replaceSubrange(0..<5, with: Data([0x46, 0x50, 0x4c, 0x59, 0x03]))
        let keyMessageResponseResult = session.handleFPSetup(AirPlayControlRequest(
            method: "POST",
            path: "/fp-setup",
            protocolVersion: "RTSP/1.0",
            headers: [:],
            body: keyMessage
        ))

        XCTAssertEqual(keyMessageResponseResult.statusCode, 200)
        XCTAssertEqual(keyMessageResponseResult.body, keyMessageReply)

        let pairSecret = Data((101...132).map(UInt8.init))
        let encryptedKey = Data((0..<72).map { UInt8($0 + 21) })
        let encryptedIV = Data((151...166).map(UInt8.init))
        let streamConnectionID = "123456789"

        session.observeEncryptedStreamKey(
            encryptedKey: encryptedKey,
            encryptedIV: encryptedIV,
            encryptionType: 32,
            pairVerifySharedSecret: pairSecret
        )

        let expectedAudioStreamKey = AirPlayFairPlaySession.streamKey(
            fromFairPlayKey: fairPlayStreamKey,
            pairVerifySharedSecret: pairSecret
        )

        XCTAssertEqual(session.unwrappedStreamKey, expectedAudioStreamKey)
        XCTAssertEqual(session.audioKeyMaterial?.key, expectedAudioStreamKey)
        XCTAssertEqual(session.audioKeyMaterial?.iv, encryptedIV)
        XCTAssertTrue(session.canDecryptAudio)
        XCTAssertNil(session.audioReadinessFailureReason(trigger: "unit test"))
        XCTAssertNil(session.streamKeyReadinessFailureReason(trigger: "unit test"))
        XCTAssertFalse(session.canDecryptVideo)
        XCTAssertEqual(
            session.videoReadinessFailureReason(trigger: "unit test"),
            "AirPlay mirror streamConnectionID has not been received"
        )

        session.observeStreamConnectionID(
            streamConnectionID,
            pairVerifySharedSecret: pairSecret
        )

        let expectedVideoKeyMaterial = AirPlayFairPlaySession.videoKeyMaterial(
            audioStreamKey: expectedAudioStreamKey,
            streamConnectionID: streamConnectionID
        )
        XCTAssertEqual(session.streamKey, expectedVideoKeyMaterial.key)
        XCTAssertEqual(session.streamIV, expectedVideoKeyMaterial.iv)
        XCTAssertTrue(session.canDecryptVideo)
        XCTAssertNil(session.videoReadinessFailureReason(trigger: "unit test"))

        let plaintext = Data((201...223).map(UInt8.init))
        let encrypted = try AirPlayAESCTR.crypt(
            plaintext,
            key: expectedVideoKeyMaterial.key,
            iv: expectedVideoKeyMaterial.iv
        )

        XCTAssertEqual(session.decryptVideoPayload(encrypted), .decrypted(plaintext))
    }

    func testAirPlayAudioCBCDecryptsFullBlocksAndCopiesRemainder() throws {
        let key = Data(hex: "2b7e151628aed2a6abf7158809cf4f3c")
        let iv = Data(hex: "000102030405060708090a0b0c0d0e0f")
        let encryptedBlock = Data(hex: "7649abac8119b246cee98e9b12e9197d")
        let remainder = Data([0xAA, 0xBB, 0xCC])

        let decrypted = try AirPlayAudioCryptor.decryptCBCPayload(
            encryptedBlock + remainder,
            key: key,
            iv: iv
        )

        XCTAssertEqual(
            decrypted,
            Data(hex: "6bc1bee22e409f96e93d7e117393172a") + remainder
        )
    }

    func testAirPlayAudioRTPPacketParsesExtensionAndNoDataMarker() throws {
        var packet = Data([
            0x90, 0xE0, 0x12, 0x34,
            0x00, 0x00, 0x01, 0x02,
            0x0A, 0x0B, 0x0C, 0x0D,
            0xBE, 0xDE, 0x00, 0x01,
            0xCA, 0xFE, 0xBA, 0xBE
        ])
        packet.append(AirPlayAudioRTPPacket.noDataMarker)

        let parsed = try XCTUnwrap(AirPlayAudioRTPPacket(data: packet))

        XCTAssertEqual(parsed.version, 2)
        XCTAssertEqual(parsed.payloadType, 96)
        XCTAssertTrue(parsed.marker)
        XCTAssertEqual(parsed.sequenceNumber, 0x1234)
        XCTAssertEqual(parsed.timestamp, 0x00000102)
        XCTAssertEqual(parsed.ssrc, 0x0A0B0C0D)
        XCTAssertEqual(parsed.headerLength, 20)
        XCTAssertTrue(parsed.isNoDataMarker)
    }

    func testAirPlayAudioPayloadNormalizesRFC3640AUHeaders() {
        let payload = Data([
            0x00, 0x10,
            0x00, 0x18,
            0x11, 0x22, 0x33
        ])

        let frames = AirPlayAACEldPayload.normalizedFrames(from: payload, compressionType: 8)

        XCTAssertEqual(frames, [Data([0x8C, 0x11, 0x22, 0x33])])
    }

    func testAirPlayAudioPayloadStripsSyncStatusBeforeAUHeaders() {
        let payload = Data([
            0x00,
            0x00, 0x10,
            0x00, 0x18,
            0x44, 0x55, 0x66
        ])

        let frames = AirPlayAACEldPayload.normalizedFrames(from: payload, compressionType: 8)

        XCTAssertEqual(frames, [Data([0x8C, 0x44, 0x55, 0x66])])
    }

    func testAirPlayAudioPayloadKeepsWholeAACEldFrames() {
        let payload = Data([0x8D, 0xAA, 0xBB, 0xCC])

        let frames = AirPlayAACEldPayload.normalizedFrames(from: payload, compressionType: 8)

        XCTAssertEqual(frames, [payload])
    }

    func testAirPlayAudioPCMLayoutCopiesInterleavedFloat32IntoPlanarBuffer() throws {
        let format = try XCTUnwrap(AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 44_100,
            channels: 2,
            interleaved: false
        ))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 2))
        let samples: [Float] = [0.25, -0.25, 0.5, -0.5]
        let pcmBytes = samples.withUnsafeBufferPointer { pointer in
            Data(bytes: pointer.baseAddress!, count: samples.count * MemoryLayout<Float>.size)
        }

        try AirPlayAudioPCMLayout.copyInterleavedFloat32(
            pcmBytes,
            frameCount: 2,
            channelCount: 2,
            into: buffer
        )

        let channelData = try XCTUnwrap(buffer.floatChannelData)
        XCTAssertEqual(buffer.frameLength, 2)
        XCTAssertEqual(channelData[0][0], 0.25, accuracy: 0.000001)
        XCTAssertEqual(channelData[0][1], 0.5, accuracy: 0.000001)
        XCTAssertEqual(channelData[1][0], -0.25, accuracy: 0.000001)
        XCTAssertEqual(channelData[1][1], -0.5, accuracy: 0.000001)
    }

    func testAirPlayGStreamerDecoderSupportPrefersExplicitExecutable() {
        let candidates = AirPlayGStreamerAACELDDecoderSupport.executableCandidates(
            environment: [
                "SPECCHIO_AIRPLAY_GST_LAUNCH_1_0": "/tmp/custom-gst",
                "GST_LAUNCH_1_0": "/tmp/fallback-gst",
                "PATH": "/bin:/usr/bin",
            ]
        )

        XCTAssertEqual(Array(candidates.prefix(4)), [
            "/tmp/custom-gst",
            "/tmp/fallback-gst",
            "/bin/gst-launch-1.0",
            "/usr/bin/gst-launch-1.0",
        ])
        XCTAssertEqual(
            AirPlayGStreamerAACELDDecoderSupport.locateExecutable(
                environment: ["SPECCHIO_AIRPLAY_GST_LAUNCH_1_0": "/tmp/custom-gst"],
                isExecutable: { $0 == "/tmp/custom-gst" }
            ),
            "/tmp/custom-gst"
        )
    }

    func testAirPlayGStreamerDecoderSupportBuildsUxPlayCapsAndSpawnEnvironment() {
        XCTAssertEqual(
            AirPlayGStreamerAACELDDecoderSupport.aacELDCaps(sampleRate: 44_100, channelCount: 2),
            "audio/mpeg,mpegversion=(int)4,channels=(int)2,rate=(int)44100,stream-format=(string)raw,codec_data=(buffer)f8e85000"
        )
        XCTAssertEqual(
            AirPlayGStreamerAACELDDecoderSupport.pcmCaps(sampleRate: 44_100, channelCount: 2),
            "audio/x-raw,format=(string)F32LE,layout=(string)interleaved,rate=(int)44100,channels=(int)2"
        )

        let environment = AirPlayGStreamerAACELDDecoderSupport.spawnEnvironment(
            base: ["PATH": "/usr/bin", "GST_PLUGIN_PATH": "/existing/plugins"],
            pathExists: { path in
                [
                    "/opt/homebrew/bin",
                    "/opt/homebrew/lib",
                    "/opt/homebrew/lib/gstreamer-1.0",
                ].contains(path)
            }
        )

        XCTAssertEqual(environment["PATH"], "/opt/homebrew/bin:/usr/bin")
        XCTAssertEqual(environment["DYLD_LIBRARY_PATH"], "/opt/homebrew/lib")
        XCTAssertEqual(environment["GST_PLUGIN_PATH"], "/opt/homebrew/lib/gstreamer-1.0:/existing/plugins")
        XCTAssertEqual(environment["GST_PLUGIN_SYSTEM_PATH"], "/opt/homebrew/lib/gstreamer-1.0")
    }

    func testFairPlayProviderPathCandidatesPreferEnvironmentAndIncludeDefaultAppSupportProvider() {
        let applicationSupport = URL(fileURLWithPath: "/tmp/Specchio-AirPlay-AppSupport", isDirectory: true)
        let environmentProvider = URL(fileURLWithPath: "/tmp/env-provider.dylib")
        let bundledProviderDirectory = URL(fileURLWithPath: "/tmp/Specchio-AirPlay-Bundle/Frameworks", isDirectory: true)
        let bundledProvider = bundledProviderDirectory
            .appendingPathComponent("libfairplay.dylib")
        let defaultProvider = applicationSupport
            .appendingPathComponent("Specchio", isDirectory: true)
            .appendingPathComponent("AirPlayFairPlay", isDirectory: true)
            .appendingPathComponent("libSpecchioAirPlayFairPlayProvider.dylib")

        let candidates = AirPlayFairPlayExternalProvider.providerPathCandidates(
            environment: ["SPECCHIO_AIRPLAY_FAIRPLAY_PROVIDER": environmentProvider.path],
            bundledProviderDirectory: bundledProviderDirectory,
            applicationSupportDirectory: applicationSupport,
            fileExists: { $0 == bundledProvider || $0 == defaultProvider }
        )

        XCTAssertEqual(candidates.map(\.source), ["environment", "bundle-frameworks", "application-support"])
        XCTAssertEqual(candidates.map(\.url), [environmentProvider, bundledProvider, defaultProvider])
    }

    func testFairPlayProviderPathCandidatesAreEmptyWhenNoProviderIsConfigured() {
        let candidates = AirPlayFairPlayExternalProvider.providerPathCandidates(
            environment: [:],
            bundledProviderDirectory: URL(fileURLWithPath: "/tmp/Specchio-AirPlay-Bundle/Frameworks", isDirectory: true),
            applicationSupportDirectory: URL(fileURLWithPath: "/tmp/Specchio-AirPlay-AppSupport", isDirectory: true),
            fileExists: { _ in false }
        )

        XCTAssertTrue(candidates.isEmpty)
    }

    func testFairPlayProviderLoadsFairPlayABIFromExternalDylib() throws {
        let dylibURL = try buildTemporaryFairPlayABIDylib()
        defer {
            try? FileManager.default.removeItem(at: dylibURL.deletingLastPathComponent())
        }

        let provider = try AirPlayFairPlayExternalProvider(path: dylibURL.path)
        XCTAssertTrue(provider.diagnosticName.contains("fairplay-abi"))

        let setupReply = try provider.setupReply(for: Data(repeating: 0x03, count: 16), mode: 2)
        XCTAssertEqual(setupReply.count, 142)
        XCTAssertEqual(setupReply[0], 0x10)

        var keyMessage = Data(repeating: 0, count: 164)
        for index in keyMessage.indices {
            keyMessage[index] = UInt8(index & 0xFF)
        }
        let keyReply = try provider.keyMessageReply(for: keyMessage)
        XCTAssertEqual(keyReply.count, 32)
        XCTAssertEqual(keyReply[0], keyMessage[144] ^ 0x33)

        let encryptedKey = Data((0..<72).map { UInt8($0) })
        let decryptedKey = try provider.decryptStreamKey(keyMessage: keyMessage, encryptedKey: encryptedKey)
        XCTAssertEqual(decryptedKey, Data((0..<16).map { UInt8($0) ^ 0x5A }))
    }

    func testFairPlayProviderPathCandidatesIncludeFairPlayDefaultProviderName() {
        let applicationSupport = URL(fileURLWithPath: "/tmp/Specchio-AirPlay-AppSupport", isDirectory: true)
        let fairplayProvider = applicationSupport
            .appendingPathComponent("Specchio", isDirectory: true)
            .appendingPathComponent("AirPlayFairPlay", isDirectory: true)
            .appendingPathComponent("libfairplay.dylib")

        let candidates = AirPlayFairPlayExternalProvider.providerPathCandidates(
            environment: [:],
            applicationSupportDirectory: applicationSupport,
            fileExists: { $0 == fairplayProvider }
        )

        XCTAssertEqual(candidates.map(\.source), ["application-support"])
        XCTAssertEqual(candidates.map(\.url), [fairplayProvider])
    }

    func testFairPlayProviderPathCandidatesIncludeBundledFrameworksProvider() {
        let bundledProviderDirectory = URL(fileURLWithPath: "/tmp/Specchio-AirPlay-Bundle/Frameworks", isDirectory: true)
        let bundledProvider = bundledProviderDirectory.appendingPathComponent("libfairplay.dylib")

        let candidates = AirPlayFairPlayExternalProvider.providerPathCandidates(
            environment: [:],
            bundledProviderDirectory: bundledProviderDirectory,
            applicationSupportDirectory: nil,
            fileExists: { $0 == bundledProvider }
        )

        XCTAssertEqual(candidates.map(\.source), ["bundle-frameworks"])
        XCTAssertEqual(candidates.map(\.url), [bundledProvider])
    }
}

private struct StubFairPlayProvider: AirPlayFairPlayProvider {
    let diagnosticName = "stub-fairplay-provider"
    let setupReply: Data
    let keyMessageReply: Data
    let decryptedStreamKey: Data

    func setupReply(for request: Data, mode: Int) throws -> Data {
        setupReply
    }

    func keyMessageReply(for request: Data) throws -> Data {
        keyMessageReply
    }

    func decryptStreamKey(keyMessage: Data, encryptedKey: Data) throws -> Data {
        decryptedStreamKey
    }
}

private func buildTemporaryFairPlayABIDylib() throws -> URL {
    let clangPath = "/usr/bin/clang"
    guard FileManager.default.isExecutableFile(atPath: clangPath) else {
        throw XCTSkip("clang is not available for the external FairPlay ABI smoke test")
    }

    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("Specchio-FairPlayABI-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

    let sourceURL = directory.appendingPathComponent("fairplay_provider.c")
    let dylibURL = directory.appendingPathComponent("libfairplay.dylib")
    let source = """
    #include <stdint.h>
    #include <stdlib.h>
    #include <string.h>

    typedef struct {
        unsigned char keymsg[164];
        int has_keymsg;
    } fairplay_ctx_t;

    void *fairplay_init(void *logger) {
        (void)logger;
        return calloc(1, sizeof(fairplay_ctx_t));
    }

    int fairplay_setup(void *opaque, const unsigned char *req, unsigned char *res) {
        if (!opaque || !req || !res) {
            return -1;
        }
        for (int index = 0; index < 142; index++) {
            res[index] = (unsigned char)(0x10 + (index % 31));
        }
        return 0;
    }

    int fairplay_handshake(void *opaque, const unsigned char *req, unsigned char *res) {
        fairplay_ctx_t *ctx = (fairplay_ctx_t *)opaque;
        if (!ctx || !req || !res) {
            return -1;
        }
        memcpy(ctx->keymsg, req, 164);
        ctx->has_keymsg = 1;
        for (int index = 0; index < 32; index++) {
            res[index] = (unsigned char)(req[144 + (index % 20)] ^ 0x33);
        }
        return 0;
    }

    int fairplay_decrypt(void *opaque, const unsigned char *input, unsigned char *output) {
        fairplay_ctx_t *ctx = (fairplay_ctx_t *)opaque;
        if (!ctx || !ctx->has_keymsg || !input || !output) {
            return -1;
        }
        for (int index = 0; index < 16; index++) {
            output[index] = (unsigned char)(input[index] ^ 0x5a);
        }
        return 0;
    }

    void fairplay_destroy(void *opaque) {
        free(opaque);
    }
    """
    try source.write(to: sourceURL, atomically: true, encoding: .utf8)

    let process = Process()
    process.executableURL = URL(fileURLWithPath: clangPath)
    process.arguments = [
        "-dynamiclib",
        sourceURL.path,
        "-o",
        dylibURL.path
    ]
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = pipe
    try process.run()
    process.waitUntilExit()

    guard process.terminationStatus == 0 else {
        let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? "(no compiler output)"
        XCTFail("Failed to build FairPlay ABI test dylib: \(output)")
        throw AirPlayTestError.externalProviderBuildFailed
    }

    return dylibURL
}

private enum AirPlayTestError: Error {
    case externalProviderBuildFailed
}

private func appendHEVCArray(nalType: UInt8, nalUnit: Data, to data: inout Data) {
    data.append(0x80 | (nalType & 0x3F))
    data.appendUInt16BE(1)
    data.appendUInt16BE(UInt16(nalUnit.count))
    data.append(nalUnit)
}

private extension Data {
    init(hex: String) {
        precondition(hex.count.isMultiple(of: 2), "hex strings must have an even number of characters")
        self.init()
        var index = hex.startIndex
        while index < hex.endIndex {
            let nextIndex = hex.index(index, offsetBy: 2)
            let byteText = String(hex[index..<nextIndex])
            guard let byte = UInt8(byteText, radix: 16) else {
                preconditionFailure("invalid hex byte \(byteText)")
            }
            append(byte)
            index = nextIndex
        }
    }

    mutating func writeUInt16LE(_ value: UInt16, at offset: Int) {
        self[offset] = UInt8(value & 0xFF)
        self[offset + 1] = UInt8((value >> 8) & 0xFF)
    }

    mutating func writeUInt32LE(_ value: UInt32, at offset: Int) {
        self[offset] = UInt8(value & 0xFF)
        self[offset + 1] = UInt8((value >> 8) & 0xFF)
        self[offset + 2] = UInt8((value >> 16) & 0xFF)
        self[offset + 3] = UInt8((value >> 24) & 0xFF)
    }

    mutating func writeUInt64LE(_ value: UInt64, at offset: Int) {
        for index in 0..<8 {
            self[offset + index] = UInt8((value >> UInt64(index * 8)) & 0xFF)
        }
    }

    mutating func writeUInt64BE(_ value: UInt64, at offset: Int) {
        for index in 0..<8 {
            self[offset + index] = UInt8((value >> UInt64((7 - index) * 8)) & 0xFF)
        }
    }

    func readUInt64BE(at offset: Int) -> UInt64 {
        var value: UInt64 = 0
        for index in 0..<8 {
            value = (value << 8) | UInt64(self[offset + index])
        }
        return value
    }

    mutating func writeFloat32LE(_ value: Float32, at offset: Int) {
        writeUInt32LE(value.bitPattern, at: offset)
    }
}
