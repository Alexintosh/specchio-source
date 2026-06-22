import AppKit
import CoreGraphics
import Foundation
import Network
import QuartzCore

private let airPlayLog = SpecchioLogger.airPlay
private let airPlayReceiverStatusFlagsNoPassword = 68
private let airPlayMirrorStreamType = 110
private let airPlayAudioStreamType = 96
private let airPlayPairingPINMinimumVisibleSeconds: TimeInterval = 5

struct AirPlayReceiverDisplayConfiguration: Equatable {
    let quality: String
    let width: Int
    let height: Int
    let refreshRateHz: Int

    var size: CGSize {
        CGSize(width: width, height: height)
    }

    var diagnosticDescription: String {
        "\(AppSettings.EasyAirPlayQuality.label(for: quality)) \(width)x\(height)@\(refreshRateHz)"
    }

    var supportsScreenMultiCodec: Bool {
        quality == AppSettings.EasyAirPlayQuality.high
    }

    static func make(
        quality: String = AppSettings.Defaults.easyAirPlayQuality,
        refreshRateHz: Int = 60
    ) -> AirPlayReceiverDisplayConfiguration {
        let sanitizedQuality = AppSettings.EasyAirPlayQuality.sanitized(quality)
        let pixels = AppSettings.easyAirPlayDisplayPixels(for: sanitizedQuality)
        return AirPlayReceiverDisplayConfiguration(
            quality: sanitizedQuality,
            width: pixels.width,
            height: pixels.height,
            refreshRateHz: refreshRateHz
        )
    }
}

private enum AirPlayFramePixelDiagnostics {
    private static let bytesPerPixel = 4
    private static let bitsPerComponent = 8
    private static let maximumBandHeight = 96
    private static let minimumBandHeight = 8
    private static let proportionalBandDivisor = 16
    private static let targetHorizontalSamples = 64
    private static let targetVerticalSamplesPerBand = 24
    private static let darkLumaThreshold = 0.08
    private static let opaqueAlphaThreshold = 0.9

    static func describe(
        image: CGImage,
        header: ReplayKitH264AccessUnitHeader,
        bufferSize: CGSize,
        cropSource: String
    ) -> String {
        let width = image.width
        let height = image.height
        guard width > 0, height > 0 else {
            return "branch=invalid-image-size width=\(width) height=\(height)"
        }

        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) else {
            return "branch=missing-srgb width=\(width) height=\(height)"
        }

        let bytesPerRow = width * bytesPerPixel
        var rgbaBytes = [UInt8](repeating: 0, count: height * bytesPerRow)
        let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue
            | CGBitmapInfo.byteOrder32Big.rawValue
        let drewImage = rgbaBytes.withUnsafeMutableBytes { rawBuffer -> Bool in
            guard let baseAddress = rawBuffer.baseAddress else {
                return false
            }

            guard let context = CGContext(
                data: baseAddress,
                width: width,
                height: height,
                bitsPerComponent: bitsPerComponent,
                bytesPerRow: bytesPerRow,
                space: colorSpace,
                bitmapInfo: bitmapInfo
            ) else {
                return false
            }

            context.interpolationQuality = .none
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }

        guard drewImage else {
            return "branch=bitmap-draw-failed width=\(width) height=\(height) bytesPerRow=\(bytesPerRow)"
        }

        let proportionalBandHeight = max(minimumBandHeight, height / proportionalBandDivisor)
        let bandHeight = min(height, maximumBandHeight, proportionalBandHeight)
        let centerStartY = max(0, (height - bandHeight) / 2)
        let lastStartY = max(0, height - bandHeight)

        let firstBand = measureBand(
            rgbaBytes: rgbaBytes,
            width: width,
            bytesPerRow: bytesPerRow,
            startY: 0,
            endY: bandHeight
        )
        let centerBand = measureBand(
            rgbaBytes: rgbaBytes,
            width: width,
            bytesPerRow: bytesPerRow,
            startY: centerStartY,
            endY: min(height, centerStartY + bandHeight)
        )
        let lastBand = measureBand(
            rgbaBytes: rgbaBytes,
            width: width,
            bytesPerRow: bytesPerRow,
            startY: lastStartY,
            endY: height
        )

        return "branch=sampled-rgba image=\(width)x\(height) header=\(header.width)x\(header.height) buffer=\(Int(bufferSize.width))x\(Int(bufferSize.height)) cropSource=\(cropSource) bandHeight=\(bandHeight) row0={\(firstBand.logDescription)} center={\(centerBand.logDescription)} rowLast={\(lastBand.logDescription)}"
    }

    private static func measureBand(
        rgbaBytes: [UInt8],
        width: Int,
        bytesPerRow: Int,
        startY: Int,
        endY: Int
    ) -> BandMeasurement {
        let bandHeight = max(0, endY - startY)
        guard width > 0, bandHeight > 0 else {
            return BandMeasurement(sampleCount: 0, averageLuma: 0, darkRatio: 0, averageAlpha: 0)
        }

        let xStride = max(1, width / targetHorizontalSamples)
        let yStride = max(1, bandHeight / targetVerticalSamplesPerBand)
        var sampleCount = 0
        var darkCount = 0
        var lumaTotal = 0.0
        var alphaTotal = 0.0

        var y = startY
        while y < endY {
            var x = 0
            while x < width {
                let offset = (y * bytesPerRow) + (x * bytesPerPixel)
                guard offset + 3 < rgbaBytes.count else {
                    x += xStride
                    continue
                }

                let red = Double(rgbaBytes[offset]) / 255.0
                let green = Double(rgbaBytes[offset + 1]) / 255.0
                let blue = Double(rgbaBytes[offset + 2]) / 255.0
                let alpha = Double(rgbaBytes[offset + 3]) / 255.0
                let luma = (0.2126 * red) + (0.7152 * green) + (0.0722 * blue)
                sampleCount += 1
                lumaTotal += luma
                alphaTotal += alpha
                if luma <= darkLumaThreshold, alpha >= opaqueAlphaThreshold {
                    darkCount += 1
                }

                x += xStride
            }

            y += yStride
        }

        guard sampleCount > 0 else {
            return BandMeasurement(sampleCount: 0, averageLuma: 0, darkRatio: 0, averageAlpha: 0)
        }

        return BandMeasurement(
            sampleCount: sampleCount,
            averageLuma: lumaTotal / Double(sampleCount),
            darkRatio: Double(darkCount) / Double(sampleCount),
            averageAlpha: alphaTotal / Double(sampleCount)
        )
    }

    private struct BandMeasurement {
        let sampleCount: Int
        let averageLuma: Double
        let darkRatio: Double
        let averageAlpha: Double

        var logDescription: String {
            "samples=\(sampleCount) avgLuma=\(Self.format(averageLuma)) darkRatio=\(Self.format(darkRatio)) avgAlpha=\(Self.format(averageAlpha))"
        }

        private static func format(_ value: Double) -> String {
            String(format: "%.3f", value)
        }
    }
}

struct AirPlaySetupResponsePayload {
    typealias Stream = [String: Any]

    let plist: [String: Any]
    let branch: String
    let keys: [String]

    static func timingOnly(timingPort: UInt16) -> AirPlaySetupResponsePayload {
        let plist: [String: Any] = [
            "eventPort": 0,
            "timingPort": Int(timingPort)
        ]
        return AirPlaySetupResponsePayload(plist: plist, branch: "TIMING_ONLY", keys: plist.keys.sorted())
    }

    static func streams(timingPort: UInt16?, streams: [Stream]) -> AirPlaySetupResponsePayload {
        var plist: [String: Any] = [
            "streams": streams
        ]
        if let timingPort {
            plist["eventPort"] = 0
            plist["timingPort"] = Int(timingPort)
        }
        return AirPlaySetupResponsePayload(plist: plist, branch: "STREAMS", keys: plist.keys.sorted())
    }
}

struct AirPlayTextParameters {
    struct Assignment: Equatable {
        let name: String
        let value: String
    }

    static func normalizedContentType(from value: String?) -> String? {
        value?
            .split(separator: ";", maxSplits: 1, omittingEmptySubsequences: true)
            .first?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
    }

    static func parameterLines(from text: String) -> [String] {
        text.components(separatedBy: "\r\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    static func parameterAssignments(
        from text: String,
        onMalformedLine: ((String) -> Void)? = nil
    ) -> [Assignment] {
        parameterLines(from: text).compactMap { line in
            guard let separator = line.firstIndex(of: ":") else {
                onMalformedLine?(line)
                return nil
            }
            let name = String(line[..<separator]).trimmingCharacters(in: .whitespacesAndNewlines)
            let valueStart = line.index(after: separator)
            let value = String(line[valueStart...]).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else {
                onMalformedLine?(line)
                return nil
            }
            return Assignment(name: name, value: value)
        }
    }

    static func volumeResponseText(decibels: Double) -> String {
        String(format: "volume: %.6f\r\n", decibels)
    }

    static func sanitizedPreview(_ text: String) -> String {
        let flattened = text
            .replacingOccurrences(of: "\r", with: "\\r")
            .replacingOccurrences(of: "\n", with: "\\n")
        if flattened.count <= 120 {
            return flattened
        }
        return String(flattened.prefix(120)) + "...<truncated>"
    }
}

enum AirPlayStreamConnectionID {
    static func normalizedString(from value: Any?) -> String? {
        guard let value else {
            return nil
        }
        if let text = value as? String {
            return normalizedString(fromText: text)
        }
        if let number = value as? NSNumber {
            return String(number.uint64Value)
        }
        if let value = value as? UInt64 {
            return String(value)
        }
        if let value = value as? UInt {
            return String(value)
        }
        if let value = value as? UInt32 {
            return String(value)
        }
        if let value = value as? Int64 {
            return value >= 0 ? String(value) : String(UInt64(bitPattern: value))
        }
        if let value = value as? Int {
            return value >= 0 ? String(value) : String(UInt64(bitPattern: Int64(value)))
        }
        return nil
    }

    static func valueKind(from value: Any?) -> String {
        guard let value else {
            return "nil"
        }
        if value is String {
            return "String"
        }
        if value is NSNumber {
            return "NSNumber"
        }
        if value is UInt64 {
            return "UInt64"
        }
        if value is UInt {
            return "UInt"
        }
        if value is UInt32 {
            return "UInt32"
        }
        if value is Int64 {
            return "Int64"
        }
        if value is Int {
            return "Int"
        }
        return String(describing: type(of: value))
    }

    static func diagnosticPreview(_ value: String?) -> String {
        guard let value else {
            return "nil"
        }
        return "digits=\(value.count) prefix=\(String(value.prefix(4))) suffix=\(String(value.suffix(4))) signed=\(value.hasPrefix("-"))"
    }

    private static func normalizedString(fromText text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return nil
        }
        if let unsigned = UInt64(trimmed) {
            return String(unsigned)
        }
        if let signed = Int64(trimmed), signed < 0 {
            return String(UInt64(bitPattern: signed))
        }
        return trimmed
    }
}

struct AirPlayReceiverInfoPayload {
    let plist: [String: Any]
    let branch: String
    let keys: [String]
    let maximumFPS: Int
    let displayConfiguration: AirPlayReceiverDisplayConfiguration

    static func make(
        configuration: AirPlayBonjourPublisher.Configuration,
        publicKey: Data,
        requestBody: Data,
        maximumFPS: Int = Int(AppSettings.Defaults.easyReplayKitH264TargetFPS),
        displayConfiguration: AirPlayReceiverDisplayConfiguration = .make()
    ) -> AirPlayReceiverInfoPayload {
        let qualifiers = requestedQualifiers(from: requestBody)
        if !qualifiers.isEmpty {
            var plist: [String: Any] = [:]
            if qualifiers.contains(txtAirPlayQualifier) {
                plist[txtAirPlayQualifier] = NetService.data(fromTXTRecord: AirPlayBonjourPublisher.airPlayTXTRecord(configuration: configuration))
            }
            if qualifiers.contains(txtRAOPQualifier) {
                plist[txtRAOPQualifier] = NetService.data(fromTXTRecord: AirPlayBonjourPublisher.raopTXTRecord(configuration: configuration))
            }
            let keys = plist.keys.sorted()
            return AirPlayReceiverInfoPayload(
                plist: plist,
                branch: "QUALIFIER_TXT",
                keys: keys,
                maximumFPS: maximumFPS,
                displayConfiguration: displayConfiguration
            )
        }

        let display: [String: Any] = [
            "features": displayFeatures,
            "height": displayConfiguration.height,
            "heightPhysical": 0,
            "heightPixels": displayConfiguration.height,
            "maxFPS": maximumFPS,
            "overscanned": false,
            "refreshRate": 1.0 / Double(displayConfiguration.refreshRateHz),
            "rotation": false,
            "uuid": configuration.persistentIdentifier,
            "width": displayConfiguration.width,
            "widthPhysical": 0,
            "widthPixels": displayConfiguration.width
        ]
        let plist: [String: Any] = [
            "deviceID": configuration.deviceID,
            "displays": [display],
            "features": AirPlayFeatureMask.receiverInfoFeatures(
                supportsScreenMultiCodec: displayConfiguration.supportsScreenMultiCodec
            ),
            "keepAliveLowPower": false,
            "keepAliveSendStatsAsBody": true,
            "macAddress": configuration.deviceID,
            "model": receiverModel,
            "name": configuration.serviceName,
            "pi": configuration.persistentIdentifier,
            "pk": publicKey,
            "sourceVersion": receiverSourceVersion,
            "statusFlags": airPlayReceiverStatusFlagsNoPassword,
            "vv": receiverVV
        ]
        return AirPlayReceiverInfoPayload(
            plist: plist,
            branch: "FULL_RECEIVER_INFO",
            keys: plist.keys.sorted(),
            maximumFPS: maximumFPS,
            displayConfiguration: displayConfiguration
        )
    }

    private static func requestedQualifiers(from body: Data) -> Set<String> {
        guard !body.isEmpty else {
            airPlayLog.info("[AirPlayInfo] qualifier branch=BODY_EMPTY")
            return []
        }

        do {
            let object = try PropertyListSerialization.propertyList(from: body, options: [], format: nil)
            guard let plist = object as? [String: Any] else {
                airPlayLog.warning("[AirPlayInfo] qualifier branch=NON_DICTIONARY")
                return []
            }
            guard let qualifierValues = plist["qualifier"] as? [Any] else {
                airPlayLog.info("[AirPlayInfo] qualifier branch=MISSING keys=\(plist.keys.sorted().joined(separator: ","), privacy: .public)")
                return []
            }

            let qualifiers = Set(qualifierValues.compactMap { $0 as? String })
            airPlayLog.info("[AirPlayInfo] qualifier branch=PARSED values=\(qualifiers.sorted().joined(separator: ","), privacy: .public)")
            return qualifiers.intersection(Set([txtAirPlayQualifier, txtRAOPQualifier]))
        } catch {
            airPlayLog.warning("[AirPlayInfo] qualifier branch=PARSE_FAILED bytes=\(body.count) error=\(error.localizedDescription, privacy: .public)")
            return []
        }
    }

    private static let txtAirPlayQualifier = "txtAirPlay"
    private static let txtRAOPQualifier = "txtRAOP"
    private static let receiverModel = "AppleTV5,3"
    private static let receiverSourceVersion = "220.68"
    private static let receiverVV = 2
    private static let displayFeatures = 14
}

struct AirPlayMediaSetPropertyPayload: Equatable {
    let propertyName: String?
    let bodyKind: String
    let plistKeys: [String]
    let itemCount: Int?

    var diagnosticDescription: String {
        "property=\(propertyName ?? "nil") bodyKind=\(bodyKind) keys=\(plistKeys.joined(separator: ",")) itemCount=\(itemCount.map(String.init) ?? "nil")"
    }

    static func make(request: AirPlayControlRequest) -> AirPlayMediaSetPropertyPayload {
        let propertyName = propertyName(from: request)
        guard !request.body.isEmpty else {
            return AirPlayMediaSetPropertyPayload(
                propertyName: propertyName,
                bodyKind: "empty",
                plistKeys: [],
                itemCount: nil
            )
        }

        do {
            let object = try PropertyListSerialization.propertyList(
                from: request.body,
                options: [],
                format: nil
            )
            if let plist = object as? [String: Any] {
                return AirPlayMediaSetPropertyPayload(
                    propertyName: propertyName,
                    bodyKind: "dictionary",
                    plistKeys: plist.keys.sorted(),
                    itemCount: nil
                )
            }
            if let array = object as? [Any] {
                return AirPlayMediaSetPropertyPayload(
                    propertyName: propertyName,
                    bodyKind: "array",
                    plistKeys: [],
                    itemCount: array.count
                )
            }
            return AirPlayMediaSetPropertyPayload(
                propertyName: propertyName,
                bodyKind: "plist-\(type(of: object))",
                plistKeys: [],
                itemCount: nil
            )
        } catch {
            airPlayLog.warning("[AirPlayMedia] setProperty plist parse failed property=\(propertyName ?? "nil", privacy: .public) bytes=\(request.body.count) error=\(error.localizedDescription, privacy: .public)")
            return AirPlayMediaSetPropertyPayload(
                propertyName: propertyName,
                bodyKind: "parse-failed",
                plistKeys: [],
                itemCount: nil
            )
        }
    }

    private static func propertyName(from request: AirPlayControlRequest) -> String? {
        guard let query = request.routeQuery, !query.isEmpty else {
            return nil
        }
        let firstItem = query.split(separator: "&", maxSplits: 1, omittingEmptySubsequences: true).first
        guard let firstItem else {
            return nil
        }
        let rawName = firstItem.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false).first
        guard let rawName, !rawName.isEmpty else {
            return nil
        }
        return String(rawName).removingPercentEncoding ?? String(rawName)
    }
}

struct AirPlayTeardownPayload: Equatable {
    let bodyKind: String
    let plistKeys: [String]
    let streamTypes: [Int]
    let streamCount: Int?

    var requestsAudioTeardown: Bool {
        streamTypes.contains(airPlayAudioStreamType)
    }

    var requestsMirrorTeardown: Bool {
        streamTypes.contains(airPlayMirrorStreamType)
    }

    var requestsFullSessionTeardown: Bool {
        !requestsAudioTeardown && !requestsMirrorTeardown
    }

    var diagnosticDescription: String {
        "bodyKind=\(bodyKind) keys=\(plistKeys.joined(separator: ",")) streamCount=\(streamCount.map(String.init) ?? "nil") streamTypes=\(streamTypes.map(String.init).joined(separator: ",")) audio=\(requestsAudioTeardown) mirror=\(requestsMirrorTeardown) full=\(requestsFullSessionTeardown)"
    }

    static func make(request: AirPlayControlRequest) -> AirPlayTeardownPayload {
        guard !request.body.isEmpty else {
            return AirPlayTeardownPayload(
                bodyKind: "empty",
                plistKeys: [],
                streamTypes: [],
                streamCount: nil
            )
        }

        do {
            let object = try PropertyListSerialization.propertyList(
                from: request.body,
                options: [],
                format: nil
            )
            guard let plist = object as? [String: Any] else {
                airPlayLog.warning("[AirPlayTeardown] plist branch=NON_DICTIONARY kind=\(String(describing: type(of: object)), privacy: .public) bytes=\(request.body.count)")
                return AirPlayTeardownPayload(
                    bodyKind: "plist-\(type(of: object))",
                    plistKeys: [],
                    streamTypes: [],
                    streamCount: nil
                )
            }

            let streams = plist["streams"] as? [[String: Any]]
            let streamTypes = (streams ?? [])
                .compactMap { Self.integerValue(from: $0["type"]) }
            return AirPlayTeardownPayload(
                bodyKind: "dictionary",
                plistKeys: plist.keys.sorted(),
                streamTypes: streamTypes,
                streamCount: streams?.count
            )
        } catch {
            airPlayLog.warning("[AirPlayTeardown] plist branch=PARSE_FAILED bytes=\(request.body.count) error=\(error.localizedDescription, privacy: .public)")
            return AirPlayTeardownPayload(
                bodyKind: "parse-failed",
                plistKeys: [],
                streamTypes: [],
                streamCount: nil
            )
        }
    }

    private static func integerValue(from value: Any?) -> Int? {
        if let value = value as? Int {
            return value
        }
        if let value = value as? UInt64 {
            return Int(value)
        }
        if let value = value as? NSNumber {
            return value.intValue
        }
        return nil
    }
}

final class AirPlayScreenStreamManager: ObservableObject {
    private typealias AudioSinkPorts = (dataPort: UInt16, controlPort: UInt16)
    private typealias SetupStreamResponse = AirPlaySetupResponsePayload.Stream

    @Published var currentFrame: CGImage?
    @Published var isAdvertising = false
    @Published var isClientConnected = false
    @Published var currentFPS: Double = 0
    @Published var statusMessage = "AirPlay idle"
    @Published var streamHealth: AirPlayStreamHealth = .idle
    @Published var lastError: String?
    @Published var lastFrameSize: CGSize?
    @Published var lastFrameReceivedAt: Date?
    @Published var controlPort: UInt16?
    @Published var timingPort: UInt16?
    @Published var mirrorDataPort: UInt16?
    @Published var audioDataPort: UInt16?
    @Published var audioControlPort: UInt16?
    @Published var audioPlaybackStatus = "off"
    @Published var audioPlaybackPacketCount = 0
    @Published var audioPlaybackDecodedPacketCount = 0
    @Published var audioPlaybackDroppedPacketCount = 0
    @Published var audioPlaybackBufferedMilliseconds: Double = 0
    @Published var audioPlaybackLastDropReason: String?
    @Published var currentClientDescription: String?
    @Published var mirrorPacketCount = 0
    @Published var lastMirrorPacketReceivedAt: Date?
    @Published var advertisedMaximumFPS = Int(AppSettings.Defaults.easyReplayKitH264TargetFPS)
    @Published var advertisedDisplaySize = AirPlayReceiverDisplayConfiguration.make().size
    @Published var advertisedAirPlayQuality = AppSettings.Defaults.easyAirPlayQuality
    @Published var activeAirPlayVideoCodec = AirPlayMirrorVideoCodec.unknown.diagnosticName
    @Published var h264DecoderStatus = "waiting for AirPlay video config"
    @Published var h264DumpPath: String?
    @Published var h264DumpBytes = 0
    @Published var fairPlayProviderStatus = "missing"
    @Published var fairPlayPhaseStatus = AirPlayFairPlaySession.Phase.idle.diagnosticDescription
    @Published var mediaPlaybackStatus = "idle"
    @Published var lastSetupStreamType: Int?
    @Published var currentPairingPIN: String?
    @Published var recentControlTrace: [String] = []

    private let queue = DispatchQueue(label: "com.alexintosh.Specchio.airplay.stream", qos: .userInteractive)
    private lazy var h264Decoder = ReplayKitH264VideoDecoder(
        callbackQueue: queue,
        codec: .h264,
        keyframeRecoveryPolicy: .allowDeltaFramesAfterDecodedFrame
    )
    private lazy var hevcDecoder = ReplayKitH264VideoDecoder(
        callbackQueue: queue,
        codec: .hevc,
        keyframeRecoveryPolicy: .allowDeltaFramesAfterDecodedFrame
    )
    private var controlServer: AirPlayControlServer?
    private var bonjourPublisher: AirPlayBonjourPublisher?
    private var bonjourPublisherID: UUID?
    private var pairingPINDisplayGeneration = 0
    private var pairingPINVisibleUntil: Date?
    private var pairingPINClearWorkItem: DispatchWorkItem?
    private var receiverConfiguration: AirPlayBonjourPublisher.Configuration?
    private var shouldAdvertise = false
    private var pendingBonjourRepublishReason: String?
    private var pendingBonjourRepublishControlPort: UInt16?
    private var timingServer: AirPlayTimingServer?
    private var mirrorDataServer: AirPlayMirrorDataServer?
    private var audioSinkServer: AirPlayAudioSinkServer?
    private var pairingSession = AirPlayPairingSession()
    private var fairPlaySession = AirPlayFairPlaySession()
    private var h264Adapter = AirPlayH264FrameAdapter()
    private var hevcAdapter = AirPlayHEVCFrameAdapter()
    private var negotiatedMirrorVideoCodec = AirPlayMirrorVideoCodec.unknown
    private var h264DumpWriter: AirPlayH264DumpWriter?
    private var pendingAudioPlaybackStream: ParsedSetupStream?
    private var lastMediaSetPropertyPayload: AirPlayMediaSetPropertyPayload?
    private var currentAirPlayVolumeDecibels = 0.0
    private var fpsTimer: Timer?
    private var staleTimer: Timer?
    private var fpsFrameTimestamps: [Date] = []
    private var receivedFrameCount = 0
    private var lastStaleDecisionBranch: String?
    private var activeTimingPort: UInt16?
    private var controlClientHost: NWEndpoint.Host?
    private let staleFrameThresholdSeconds: TimeInterval = 3.0
    private let idleFrameOverlayThresholdSeconds: TimeInterval = 60.0
    private let maximumControlTraceEntries = 80
    private let videoQualitySampleIntervalSeconds: CFTimeInterval = 2.0
    private var videoQualitySampleStartedAt: CFTimeInterval?
    private var videoQualitySamplePayloadBytes = 0
    private var videoQualitySamplePacketCount = 0
    private var videoQualitySampleIDRPacketCount = 0

    init() {
        if let dumpConfiguration = AirPlayH264DumpWriter.Configuration.make() {
            h264DumpWriter = AirPlayH264DumpWriter(configuration: dumpConfiguration)
            h264DumpPath = dumpConfiguration.fileURL.path
        }
        fairPlayProviderStatus = fairPlaySession.providerDiagnosticDescription
        fairPlayPhaseStatus = fairPlaySession.phase.diagnosticDescription
        advertisedMaximumFPS = currentAdvertisedMaximumFPS()
        let displayConfiguration = currentAdvertisedDisplayConfiguration()
        advertisedDisplaySize = displayConfiguration.size
        advertisedAirPlayQuality = displayConfiguration.quality
        publishFairPlayStatus(trigger: "init")
        airPlayLog.info("[AirPlayManager] init")
    }

    deinit {
        airPlayLog.info("[AirPlayManager] deinit")
    }

    func refreshAdvertisedReceiverInfoPreferences(source: String) {
        let maximumFPS = currentAdvertisedMaximumFPS()
        let displayConfiguration = currentAdvertisedDisplayConfiguration()
        let previousScreenMultiCodec = receiverConfiguration?.supportsScreenMultiCodec
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.advertisedMaximumFPS = maximumFPS
            self.advertisedDisplaySize = displayConfiguration.size
            self.advertisedAirPlayQuality = displayConfiguration.quality
        }
        airPlayLog.info("[AirPlayInfo] advertised preferences refreshed source=\(source, privacy: .public) display=\(displayConfiguration.diagnosticDescription, privacy: .public) maxFPS=\(maximumFPS) screenMultiCodec=\(displayConfiguration.supportsScreenMultiCodec)")
        if let previousScreenMultiCodec,
           previousScreenMultiCodec != displayConfiguration.supportsScreenMultiCodec {
            airPlayLog.info("[AirPlayInfo] Bonjour capability refresh needed branch=SCREEN_MULTI_CODEC_CHANGED source=\(source, privacy: .public) previous=\(previousScreenMultiCodec) next=\(displayConfiguration.supportsScreenMultiCodec)")
            refreshBonjourAdvertisement(reason: "\(source) screen multi codec changed")
        } else {
            airPlayLog.info("[AirPlayInfo] Bonjour capability refresh skipped branch=UNCHANGED_OR_NOT_ADVERTISING source=\(source, privacy: .public) previous=\(previousScreenMultiCodec.map(String.init) ?? "nil", privacy: .public) next=\(displayConfiguration.supportsScreenMultiCodec)")
        }
    }

    func refreshAdvertisement(source: String) {
        airPlayLog.info("[AirPlayManager] manual Bonjour refresh requested source=\(source, privacy: .public)")
        startTimers()
        queue.async { [weak self] in
            guard let self else { return }
            self.shouldAdvertise = true
            guard self.controlServer != nil else {
                airPlayLog.info("[AirPlayManager] manual Bonjour refresh branch=START_LISTENER source=\(source, privacy: .public)")
                self.start()
                return
            }

            self.refreshBonjourAdvertisement(reason: "manual refresh \(source)")
        }
    }

    func start() {
        airPlayLog.info("[AirPlayManager] start requested")
        startTimers()
        queue.async { [weak self] in
            guard let self else { return }
            self.shouldAdvertise = true
            guard self.controlServer == nil else {
                airPlayLog.info("[AirPlayManager] start skipped reason=already-started")
                self.publishStatus("AirPlay already listening")
                self.publishHealth(.waitingForPhone, trigger: "start already active")
                return
            }

            self.resetSessionState(reason: "start")
            let controlServer = AirPlayControlServer(
                queue: self.queue,
                onEvent: { [weak self] event in
                    self?.handleControlServerEvent(event)
                },
                requestHandler: { [weak self] request, respond in
                    self?.handleControlRequest(request, respond: respond)
                }
            )
            self.controlServer = controlServer
            self.publishStatus("Starting AirPlay receiver")
            self.publishHealth(.advertising, trigger: "control listener starting")
            controlServer.start()
        }
    }

    func stop() {
        airPlayLog.info("[AirPlayManager] stop requested")
        DispatchQueue.main.async { [weak self] in
            self?.fpsTimer?.invalidate()
            self?.fpsTimer = nil
            self?.staleTimer?.invalidate()
            self?.staleTimer = nil
        }

        queue.async { [weak self] in
            guard let self else { return }
            self.shouldAdvertise = false
            self.pendingBonjourRepublishReason = nil
            self.pendingBonjourRepublishControlPort = nil
            if let publisher = self.bonjourPublisher {
                airPlayLog.info("[AirPlayManager] stop branch=STOP_BONJOUR_ASYNC publisherID=\(publisher.identifier.uuidString, privacy: .public)")
                let stopRequested = publisher.stop()
                if !stopRequested {
                    airPlayLog.info("[AirPlayManager] stop branch=CLEAR_EMPTY_BONJOUR_PUBLISHER publisherID=\(publisher.identifier.uuidString, privacy: .public)")
                    self.bonjourPublisher = nil
                    self.bonjourPublisherID = nil
                    self.receiverConfiguration = nil
                }
            } else {
                airPlayLog.info("[AirPlayManager] stop branch=NO_BONJOUR_PUBLISHER")
                self.receiverConfiguration = nil
            }
            self.timingServer?.stop(reason: "AirPlay manager stop")
            self.timingServer = nil
            self.activeTimingPort = nil
            self.mirrorDataServer?.stop(reason: "AirPlay manager stop")
            self.mirrorDataServer = nil
            self.audioSinkServer?.stop(reason: "AirPlay manager stop")
            self.audioSinkServer = nil
            self.audioReadyCompletions.removeAll()
            self.audioFailureCompletions.removeAll()
            self.controlServer?.stop(reason: "AirPlay manager stop")
            self.controlServer = nil
            self.resetSessionState(reason: "stop")
            self.h264Decoder.reset(reason: "AirPlay manager stop")
            self.hevcDecoder.reset(reason: "AirPlay manager stop")
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.currentFrame = nil
                self.isAdvertising = false
                self.isClientConnected = false
                self.currentFPS = 0
                self.statusMessage = "AirPlay stopped"
                self.streamHealth = .idle
                self.lastError = nil
                self.lastFrameSize = nil
                self.lastFrameReceivedAt = nil
                self.lastMirrorPacketReceivedAt = nil
                self.lastStaleDecisionBranch = nil
                self.controlPort = nil
                self.timingPort = nil
                self.mirrorDataPort = nil
                self.audioDataPort = nil
                self.audioControlPort = nil
                self.audioPlaybackStatus = "off"
                self.audioPlaybackPacketCount = 0
                self.audioPlaybackDecodedPacketCount = 0
                self.audioPlaybackDroppedPacketCount = 0
                self.audioPlaybackBufferedMilliseconds = 0
                self.audioPlaybackLastDropReason = nil
                self.currentClientDescription = nil
                self.mirrorPacketCount = 0
                self.activeAirPlayVideoCodec = AirPlayMirrorVideoCodec.unknown.diagnosticName
                self.h264DecoderStatus = "waiting for AirPlay video config"
                self.advertisedMaximumFPS = self.currentAdvertisedMaximumFPS()
                let displayConfiguration = self.currentAdvertisedDisplayConfiguration()
                self.advertisedDisplaySize = displayConfiguration.size
                self.advertisedAirPlayQuality = displayConfiguration.quality
                self.h264DumpBytes = self.h264DumpWriter?.byteCount ?? 0
                self.lastSetupStreamType = nil
                self.clearCurrentPairingPINOnMain(trigger: "AirPlay stop", force: true)
                self.recentControlTrace.removeAll()
                self.fpsFrameTimestamps.removeAll()
            }
            airPlayLog.info("[AirPlayManager] stop completed")
        }
    }

    func ensureAdvertising(source: String) {
        airPlayLog.info("[AirPlayManager] ensure advertising requested source=\(source, privacy: .public)")
        startTimers()
        queue.async { [weak self] in
            guard let self else { return }
            self.shouldAdvertise = true

            guard self.controlServer != nil else {
                airPlayLog.info("[AirPlayManager] ensure advertising branch=START_LISTENER source=\(source, privacy: .public)")
                self.start()
                return
            }

            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                let publisherPresent = self.bonjourPublisher != nil
                let advertising = self.isAdvertising
                airPlayLog.info("[AirPlayManager] ensure advertising check source=\(source, privacy: .public) publisherPresent=\(publisherPresent) isAdvertising=\(advertising) controlPort=\(self.controlPort.map(String.init) ?? "nil", privacy: .public)")
                guard !publisherPresent || !advertising else {
                    airPlayLog.info("[AirPlayManager] ensure advertising skipped source=\(source, privacy: .public) reason=already-advertising")
                    return
                }

                self.refreshBonjourAdvertisement(reason: "ensure advertising \(source)")
            }
        }
    }

    private func handleControlServerEvent(_ event: AirPlayControlServer.Event) {
        switch event {
        case .ready(let port):
            airPlayLog.info("[AirPlayManager] control listener ready port=\(port)")
            DispatchQueue.main.async { [weak self] in
                self?.controlPort = port
            }
            startBonjourPublisher(controlPort: port)
            publishHealth(.waitingForPhone, trigger: "control listener ready")
        case .failed(let reason):
            airPlayLog.error("[AirPlayManager] control listener failed reason=\(reason, privacy: .public)")
            publishError(reason, trigger: "control listener failed")
        case .clientReady(let endpoint):
            handleControlClientReady(endpoint: endpoint)
        case .clientState(let state):
            airPlayLog.info("[AirPlayManager] control client state=\(state, privacy: .public)")
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.isClientConnected = state == "ready"
                self.currentClientDescription = state
                if state == "ready" {
                    airPlayLog.info("[AirPlayManager] clearing previous AirPlay error reason=control client ready")
                    self.lastError = nil
                }
            }
            if state == "ready" {
                if mirrorDataServer != nil || audioSinkServer != nil {
                    airPlayLog.info("[AirPlayManager] control client ready branch=MEDIA_ACTIVE_KEEP_HEALTH mirrorActive=\(self.mirrorDataServer != nil) audioActive=\(self.audioSinkServer != nil)")
                } else {
                    publishHealth(.pairing, trigger: "control client ready")
                }
            } else if state.contains("closed") || state.contains("cancelled") || state.contains("failed") {
                handleControlClientDisconnectState(state)
            }
        case .stopped:
            airPlayLog.info("[AirPlayManager] control server stopped")
        case .trace(let message):
            recordControlTrace(message)
        }
    }

    private func handleControlClientDisconnectState(_ state: String) {
        let hasActiveMediaSockets = mirrorDataServer != nil || audioSinkServer != nil || activeTimingPort != nil
        if hasActiveMediaSockets {
            airPlayLog.info("[AirPlayManager] control client disconnect branch=IGNORE_MEDIA_ACTIVE state=\(state, privacy: .public) mirrorActive=\(self.mirrorDataServer != nil) audioActive=\(self.audioSinkServer != nil) timingActive=\(self.activeTimingPort != nil)")
            recordControlTrace("ignored transient control \(state) while media sockets are active")
            return
        }

        airPlayLog.info("[AirPlayManager] control client disconnect branch=TEARDOWN_NO_MEDIA state=\(state, privacy: .public)")
        handleAirPlaySessionTeardown(reason: "control client \(state)")
    }

    private func handleControlClientReady(endpoint: NWEndpoint) {
        switch endpoint {
        case .hostPort(let host, let port):
            controlClientHost = host
            let endpointDescription = "\(host):\(port)"
            airPlayLog.info("[AirPlayManager] control client endpoint branch=HOST_PORT endpoint=\(endpointDescription, privacy: .public)")
            DispatchQueue.main.async { [weak self] in
                self?.currentClientDescription = endpointDescription
            }
        default:
            controlClientHost = nil
            airPlayLog.warning("[AirPlayManager] control client endpoint branch=UNSUPPORTED endpoint=\(String(describing: endpoint), privacy: .public)")
        }
    }

    private func recordControlTrace(_ message: String) {
        let timestamp = String(format: "%.3f", Date().timeIntervalSince1970)
        let line = "\(timestamp) \(message)"
        airPlayLog.info("[AirPlayTrace] \(line, privacy: .public)")
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.recentControlTrace.append(line)
            if self.recentControlTrace.count > self.maximumControlTraceEntries {
                self.recentControlTrace.removeFirst(self.recentControlTrace.count - self.maximumControlTraceEntries)
            }
        }
    }

    private func startBonjourPublisher(controlPort: UInt16) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.startBonjourPublisherOnMain(controlPort: controlPort, trigger: "control listener ready")
        }
    }

    private func refreshBonjourAdvertisement(reason: String) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            guard let controlPort = self.controlPort else {
                airPlayLog.warning("[AirPlayManager] Bonjour refresh skipped branch=NO_CONTROL_PORT reason=\(reason, privacy: .public) publisherPresent=\(self.bonjourPublisher != nil) isAdvertising=\(self.isAdvertising)")
                return
            }
            guard self.controlServer != nil else {
                airPlayLog.warning("[AirPlayManager] Bonjour refresh skipped branch=NO_CONTROL_SERVER reason=\(reason, privacy: .public) controlPort=\(controlPort) publisherPresent=\(self.bonjourPublisher != nil)")
                return
            }

            airPlayLog.info("[AirPlayManager] Bonjour refresh branch=STOP_THEN_REPUBLISH reason=\(reason, privacy: .public) controlPort=\(controlPort) publisherPresent=\(self.bonjourPublisher != nil) isAdvertising=\(self.isAdvertising)")
            self.shouldAdvertise = true
            self.isAdvertising = false
            self.statusMessage = "AirPlay refreshing advertisement"
            self.streamHealth = .advertising
            guard let publisher = self.bonjourPublisher else {
                airPlayLog.info("[AirPlayManager] Bonjour refresh branch=NO_EXISTING_PUBLISHER_START reason=\(reason, privacy: .public) controlPort=\(controlPort)")
                self.startBonjourPublisherOnMain(controlPort: controlPort, trigger: "refresh without publisher after \(reason)")
                return
            }

            self.pendingBonjourRepublishReason = reason
            self.pendingBonjourRepublishControlPort = controlPort
            let stopRequested = publisher.stop()
            airPlayLog.info("[AirPlayManager] Bonjour refresh branch=WAIT_FOR_STOP reason=\(reason, privacy: .public) stopRequested=\(stopRequested) publisherID=\(publisher.identifier.uuidString, privacy: .public)")
            guard stopRequested else {
                self.completeBonjourStopAndRepublishIfNeeded(
                    type: "none",
                    name: "no-services",
                    publisherID: publisher.identifier,
                    remainingServices: 0
                )
                return
            }
        }
    }

    private func startBonjourPublisherOnMain(controlPort: UInt16, trigger: String) {
        if bonjourPublisher != nil {
            airPlayLog.info("[AirPlayManager] Bonjour start skipped reason=already-present trigger=\(trigger, privacy: .public)")
            return
        }
        let displayConfiguration = currentAdvertisedDisplayConfiguration()
        let publisher = AirPlayBonjourPublisher { [weak self] event in
            self?.handleBonjourEvent(event)
        }
        bonjourPublisher = publisher
        bonjourPublisherID = publisher.identifier
        let configuration = AirPlayBonjourPublisher.Configuration.make(
            controlPort: controlPort,
            publicKeyHex: pairingSession.receiverPublicKeyHex,
            supportsScreenMultiCodec: displayConfiguration.supportsScreenMultiCodec
        )
        receiverConfiguration = configuration
        airPlayLog.info("[AirPlayManager] Bonjour start branch=PUBLISH trigger=\(trigger, privacy: .public) serviceName=\(configuration.serviceName, privacy: .public) port=\(controlPort) display=\(displayConfiguration.diagnosticDescription, privacy: .public) screenMultiCodec=\(configuration.supportsScreenMultiCodec)")
        publisher.start(configuration: configuration)
        isAdvertising = true
        streamHealth = .advertising
        statusMessage = "AirPlay advertising as \(configuration.serviceName)"
    }

    private func handleBonjourEvent(_ event: AirPlayBonjourPublisher.Event) {
        switch event {
        case .publishRequested(let type, let name, let port, let txtKeys):
            airPlayLog.info("[AirPlayManager] Bonjour publish requested type=\(type, privacy: .public) name=\(name, privacy: .public) port=\(port) txtKeys=\(txtKeys.joined(separator: ","), privacy: .public)")
        case .didPublish(let type, let name, let port):
            airPlayLog.info("[AirPlayManager] Bonjour did publish type=\(type, privacy: .public) name=\(name, privacy: .public) port=\(port)")
            publishHealth(.waitingForPhone, trigger: "Bonjour published \(type)")
        case .didNotPublish(let type, let name, let error):
            publishError("AirPlay Bonjour publish failed for \(type) \(name): \(error)", trigger: "Bonjour did not publish")
        case .didStop(let type, let name, let publisherID, let remainingServices):
            completeBonjourStopAndRepublishIfNeeded(
                type: type,
                name: name,
                publisherID: publisherID,
                remainingServices: remainingServices
            )
        }
    }

    private func completeBonjourStopAndRepublishIfNeeded(
        type: String,
        name: String,
        publisherID: UUID,
        remainingServices: Int
    ) {
            let isCurrentPublisher = publisherID == bonjourPublisherID
            airPlayLog.info("[AirPlayManager] Bonjour stopped type=\(type, privacy: .public) name=\(name, privacy: .public) remainingServices=\(remainingServices) currentPublisher=\(isCurrentPublisher) shouldAdvertise=\(self.shouldAdvertise) controlServerPresent=\(self.controlServer != nil)")
            guard isCurrentPublisher else {
                airPlayLog.info("[AirPlayManager] Bonjour stop ignored branch=STALE_PUBLISHER type=\(type, privacy: .public) name=\(name, privacy: .public)")
                return
            }
            guard remainingServices == 0 else {
                airPlayLog.info("[AirPlayManager] Bonjour stop ignored branch=PARTIAL_STOP type=\(type, privacy: .public) remainingServices=\(remainingServices)")
                return
            }

            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.isAdvertising = false
                self.bonjourPublisher = nil
                self.bonjourPublisherID = nil
                self.receiverConfiguration = nil
                let pendingReason = self.pendingBonjourRepublishReason
                let pendingControlPort = self.pendingBonjourRepublishControlPort
                self.pendingBonjourRepublishReason = nil
                self.pendingBonjourRepublishControlPort = nil
                guard self.shouldAdvertise else {
                    airPlayLog.info("[AirPlayManager] Bonjour restart skipped branch=INTENTIONAL_STOP type=\(type, privacy: .public) name=\(name, privacy: .public)")
                    return
                }
                guard self.controlServer != nil, let controlPort = pendingControlPort ?? self.controlPort else {
                    airPlayLog.warning("[AirPlayManager] Bonjour restart skipped branch=NO_CONTROL_LISTENER type=\(type, privacy: .public) pendingReason=\(pendingReason ?? "nil", privacy: .public) controlPort=\(self.controlPort.map(String.init) ?? "nil", privacy: .public)")
                    self.statusMessage = "AirPlay advertisement stopped"
                    self.streamHealth = .disconnected(reason: "AirPlay advertisement stopped")
                    return
                }
                let branch = pendingReason == nil ? "AUTO_REPUBLISH" : "PENDING_REPUBLISH"
                let trigger = pendingReason.map { "Bonjour stopped after \($0)" } ?? "Bonjour stopped \(type)"
                airPlayLog.info("[AirPlayManager] Bonjour restart branch=\(branch, privacy: .public) type=\(type, privacy: .public) name=\(name, privacy: .public) controlPort=\(controlPort) pendingReason=\(pendingReason ?? "nil", privacy: .public)")
                self.statusMessage = "AirPlay restarting advertisement"
                self.streamHealth = .advertising
                self.startBonjourPublisherOnMain(
                    controlPort: controlPort,
                    trigger: trigger
                )
            }
    }

    private func handleControlRequest(_ request: AirPlayControlRequest, respond: @escaping AirPlayControlServer.ResponseHandler) {
        let routePath = request.routePath
        let routePathWithoutQuery = request.routePathWithoutQuery
        airPlayLog.info("[AirPlayControlHandler] method=\(request.method, privacy: .public) path=\(request.path, privacy: .public) routePath=\(routePath, privacy: .public) routePathWithoutQuery=\(routePathWithoutQuery, privacy: .public) cseq=\(request.cseq ?? "nil", privacy: .public) bodyBytes=\(request.body.count) headers=\(request.sanitizedHeadersForLog, privacy: .public)")

        switch (request.method, routePathWithoutQuery) {
        case ("OPTIONS", _):
            airPlayLog.info("[AirPlayControlHandler] branch=OPTIONS reason=capability-probe")
            respond(.ok(headers: [
                "Public": "ANNOUNCE, SETUP, RECORD, PAUSE, FLUSH, TEARDOWN, OPTIONS, GET_PARAMETER, SET_PARAMETER, GET, POST"
            ]))

        case ("GET", "/info"):
            airPlayLog.info("[AirPlayControlHandler] branch=GET_INFO reason=receiver-info")
            logInfoRequestBody(request.body)
            respond(receiverInfoResponse(for: request))

        case ("GET", "/server-info"):
            airPlayLog.info("[AirPlayControlHandler] branch=SERVER_INFO reason=http-airplay-info protocol=\(request.protocolVersion, privacy: .public)")
            logInfoRequestBody(request.body)
            respond(receiverInfoResponse(for: request))

        case ("POST", "/reverse"):
            airPlayLog.info("[AirPlayControlHandler] branch=REVERSE_EVENT_CHANNEL reason=ptth-upgrade upgrade=\(request.headerValue("Upgrade") ?? "nil", privacy: .public) purpose=\(request.headerValue("X-Apple-Purpose") ?? "nil", privacy: .public) connection=\(request.headerValue("Connection") ?? "nil", privacy: .public)")
            respond(.switchingProtocols(headers: [
                "Connection": "Upgrade",
                "Server": "AirPlay/220.68",
                "Upgrade": request.headerValue("Upgrade") ?? "PTTH/1.0"
            ]))

        case ("POST", "/pair-setup"):
            airPlayLog.info("[AirPlayControlHandler] branch=PAIR_SETUP bodyBytes=\(request.body.count)")
            publishHealth(.pairing, trigger: "pair-setup")
            let result = pairingSession.handlePairSetup(request)
            handlePairingResult(result, trigger: "pair-setup")
            respond(result.response)

        case ("POST", "/pair-verify"):
            airPlayLog.info("[AirPlayControlHandler] branch=PAIR_VERIFY bodyBytes=\(request.body.count)")
            publishHealth(.pairing, trigger: "pair-verify")
            let result = pairingSession.handlePairVerify(request)
            handlePairingResult(result, trigger: "pair-verify")
            respond(result.response)

        case ("POST", "/pair-pin-start"):
            airPlayLog.info("[AirPlayControlHandler] branch=PAIR_PIN_START reason=client-requested-pin-authentication advertisedPassword=false bodyBytes=\(request.body.count)")
            publishHealth(.pairing, trigger: "pair-pin-start")
            let result = pairingSession.beginPinPairing()
            handlePairingResult(result, trigger: "pair-pin-start")
            respond(result.response)

        case ("POST", "/pair-setup-pin"):
            airPlayLog.info("[AirPlayControlHandler] branch=PAIR_SETUP_PIN reason=client-requested-pin-srp advertisedPassword=false bodyBytes=\(request.body.count)")
            publishHealth(.pairing, trigger: "pair-setup-pin")
            logPairSetupPinRequestBody(request.body)
            let result = pairingSession.handlePairSetupPin(request)
            handlePairingResult(result, trigger: "pair-setup-pin")
            respond(result.response)

        case ("POST", "/fp-setup"), ("POST", "/fp-setup2"):
            let routeName = routePathWithoutQuery
            let branch = routeName == "/fp-setup2" ? "FP_SETUP2" : "FP_SETUP"
            airPlayLog.info("[AirPlayControlHandler] branch=\(branch, privacy: .public) bodyBytes=\(request.body.count)")
            respond(handleFairPlaySetupRequest(request, routeName: routeName, branch: branch))

        case ("SETUP", _):
            airPlayLog.info("[AirPlayControlHandler] branch=SETUP bodyBytes=\(request.body.count)")
            handleSetupRequest(request, respond: respond)

        case ("RECORD", _):
            airPlayLog.info("[AirPlayControlHandler] branch=RECORD reason=stream-start")
            publishHealth(.settingUp, trigger: "record")
            respond(.ok(headers: [
                "Audio-Jack-Status": "connected; type=analog",
                "Audio-Latency": "0"
            ]))

        case ("GET_PARAMETER", _):
            airPlayLog.info("[AirPlayControlHandler] branch=GET_PARAMETER reason=text-parameter-query")
            respond(handleGetParameterRequest(request))

        case ("FLUSH", _):
            airPlayLog.info("[AirPlayControlHandler] branch=FLUSH reason=audio-or-stream-reset rtpInfo=\(request.headerValue("RTP-Info") ?? "nil", privacy: .public)")
            respond(.ok())

        case ("SET_PARAMETER", _):
            airPlayLog.info("[AirPlayControlHandler] branch=SET_PARAMETER bodyBytes=\(request.body.count) reason=parameter-update")
            respond(handleSetParameterRequest(request))

        case ("POST", "/feedback"):
            airPlayLog.info("[AirPlayControlHandler] branch=FEEDBACK reason=client-telemetry bodyBytes=\(request.body.count)")
            respond(.ok())

        case ("POST", "/audioMode"):
            airPlayLog.info("[AirPlayControlHandler] branch=AUDIO_MODE reason=client-audio-mode bodyBytes=\(request.body.count)")
            logAudioModeRequestBody(request.body)
            respond(.ok())

        case ("PUT", "/setProperty"):
            airPlayLog.info("[AirPlayControlHandler] branch=SET_PROPERTY reason=media-property-update routePath=\(routePath, privacy: .public) bodyBytes=\(request.body.count)")
            respond(handleSetPropertyRequest(request))

        case ("TEARDOWN", _):
            airPlayLog.info("[AirPlayControlHandler] branch=TEARDOWN reason=sender-requested bodyBytes=\(request.body.count)")
            respond(handleTeardownRequest(request))

        default:
            airPlayLog.warning("[AirPlayControlHandler] branch=UNSUPPORTED method=\(request.method, privacy: .public) path=\(request.path, privacy: .public) routePath=\(routePath, privacy: .public) routePathWithoutQuery=\(routePathWithoutQuery, privacy: .public)")
            respond(.notFound("Unsupported AirPlay control request \(request.method) \(routePathWithoutQuery)"))
        }
    }

    private func handleTeardownRequest(_ request: AirPlayControlRequest) -> AirPlayControlResponse {
        let payload = AirPlayTeardownPayload.make(request: request)
        airPlayLog.info("[AirPlayTeardown] parsed \(payload.diagnosticDescription, privacy: .public)")

        if payload.requestsFullSessionTeardown {
            airPlayLog.info("[AirPlayTeardown] branch=FULL_SESSION reason=no-scoped-stream-type bodyKind=\(payload.bodyKind, privacy: .public) streamTypes=\(payload.streamTypes.map(String.init).joined(separator: ","), privacy: .public)")
            handleAirPlaySessionTeardown(reason: "RTSP TEARDOWN full session")
            refreshBonjourAdvertisement(reason: "RTSP TEARDOWN full session")
            return .ok()
        }

        if payload.requestsAudioTeardown {
            airPlayLog.info("[AirPlayTeardown] branch=AUDIO_STREAM reason=type-\(airPlayAudioStreamType)")
            stopAudioStream(reason: "RTSP TEARDOWN stream type \(airPlayAudioStreamType)")
        }

        if payload.requestsMirrorTeardown {
            airPlayLog.info("[AirPlayTeardown] branch=MIRROR_STREAM reason=type-\(airPlayMirrorStreamType)")
            stopMirrorStream(reason: "RTSP TEARDOWN stream type \(airPlayMirrorStreamType)")
        }

        publishMediaPlaybackStatus("teardown handled for stream types \(payload.streamTypes.map(String.init).joined(separator: ","))")
        return .ok()
    }

    private func handleFairPlaySetupRequest(
        _ request: AirPlayControlRequest,
        routeName: String,
        branch: String
    ) -> AirPlayControlResponse {
        let response = fairPlaySession.handleFPSetup(request, routeName: routeName)
        airPlayLog.warning("[AirPlayFairPlay] phase=\(self.fairPlaySession.phase.diagnosticDescription, privacy: .public) route=\(routeName, privacy: .public)")
        publishFairPlayStatus(trigger: routeName)
        if routeName == "/fp-setup2" {
            publishMediaPlaybackStatus("FairPlay setup2 \(response.statusCode < 400 ? "advanced" : "blocked")")
        }
        if response.statusCode >= 400 {
            let reason = fairPlaySession.setupFailureDescription
            airPlayLog.error("[AirPlayFairPlay] setup blocked route=\(routeName, privacy: .public) status=\(response.statusCode) provider=\(self.fairPlaySession.providerDiagnosticDescription, privacy: .public) reason=\(reason, privacy: .public)")
            publishError(reason, trigger: routeName)
        } else {
            publishHealth(.settingUp, trigger: routeName)
            publishStatus("AirPlay FairPlay setup advanced")
            retryPendingAudioPlaybackIfPossible(trigger: routeName)
        }
        airPlayLog.info("[AirPlayControlHandler] branch=\(branch, privacy: .public) responseStatus=\(response.statusCode)")
        return response
    }

    private func handleSetPropertyRequest(_ request: AirPlayControlRequest) -> AirPlayControlResponse {
        let payload = AirPlayMediaSetPropertyPayload.make(request: request)
        lastMediaSetPropertyPayload = payload
        airPlayLog.info("[AirPlayMedia] setProperty branch=PARSED \(payload.diagnosticDescription, privacy: .public)")

        switch payload.propertyName {
        case "mediaCharacteristicsForPreferredCustomMediaSelectionSchemes":
            publishMediaPlaybackStatus("preferred media selection received")
            airPlayLog.info("[AirPlayMedia] setProperty branch=PREFERRED_MEDIA_SELECTION bodyKind=\(payload.bodyKind, privacy: .public) keys=\(payload.plistKeys.joined(separator: ","), privacy: .public) itemCount=\(payload.itemCount.map(String.init) ?? "nil", privacy: .public)")
        case "selectedMediaArray":
            publishMediaPlaybackStatus("selected media received")
            airPlayLog.info("[AirPlayMedia] setProperty branch=SELECTED_MEDIA_ARRAY bodyKind=\(payload.bodyKind, privacy: .public) keys=\(payload.plistKeys.joined(separator: ","), privacy: .public) itemCount=\(payload.itemCount.map(String.init) ?? "nil", privacy: .public)")
        case .some(let propertyName):
            publishMediaPlaybackStatus("setProperty \(propertyName)")
            airPlayLog.warning("[AirPlayMedia] setProperty branch=UNKNOWN_PROPERTY property=\(propertyName, privacy: .public) bodyKind=\(payload.bodyKind, privacy: .public)")
        case .none:
            publishMediaPlaybackStatus("setProperty missing property")
            airPlayLog.warning("[AirPlayMedia] setProperty branch=MISSING_PROPERTY routePath=\(request.routePath, privacy: .public) bodyKind=\(payload.bodyKind, privacy: .public)")
        }

        return .ok()
    }

    private func receiverInfoResponse(for request: AirPlayControlRequest) -> AirPlayControlResponse {
        let configuration = receiverConfiguration ?? AirPlayBonjourPublisher.Configuration.make(
            controlPort: controlPort ?? 0,
            publicKeyHex: pairingSession.receiverPublicKeyHex,
            supportsScreenMultiCodec: currentAdvertisedDisplayConfiguration().supportsScreenMultiCodec
        )
        let payload = AirPlayReceiverInfoPayload.make(
            configuration: configuration,
            publicKey: pairingSession.receiverPublicKey,
            requestBody: request.body,
            maximumFPS: currentAdvertisedMaximumFPS(),
            displayConfiguration: currentAdvertisedDisplayConfiguration()
        )
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.advertisedMaximumFPS = payload.maximumFPS
            self.advertisedDisplaySize = payload.displayConfiguration.size
            self.advertisedAirPlayQuality = payload.displayConfiguration.quality
        }
        do {
            let body = try PropertyListSerialization.data(fromPropertyList: payload.plist, format: .binary, options: 0)
            airPlayLog.info("[AirPlayInfo] response branch=\(payload.branch, privacy: .public) keys=\(payload.keys.joined(separator: ","), privacy: .public) display=\(payload.displayConfiguration.diagnosticDescription, privacy: .public) maxFPS=\(payload.maximumFPS) bodyBytes=\(body.count)")
            var headers = ["Content-Type": "application/x-apple-binary-plist"]
            if request.protocolVersion.hasPrefix("HTTP") {
                headers["Server"] = "AirPlay/220.68"
            } else if request.cseq != nil {
                headers["Audio-Jack-Status"] = "connected; type=digital"
            }
            return .ok(headers: headers, body: body)
        } catch {
            airPlayLog.error("[AirPlayControlHandler] receiver info plist serialization failed error=\(error.localizedDescription, privacy: .public)")
            return .badRequest("Could not build receiver info")
        }
    }

    private func currentAdvertisedMaximumFPS() -> Int {
        let rawValueObject = UserDefaults.standard.object(forKey: AppSettings.Keys.easyReplayKitH264TargetFPS)
        let rawValue: Double
        let branch: String
        if let number = rawValueObject as? NSNumber {
            rawValue = number.doubleValue
            branch = "USER_DEFAULTS"
        } else {
            rawValue = AppSettings.Defaults.easyReplayKitH264TargetFPS
            branch = rawValueObject == nil ? "DEFAULT_MISSING" : "DEFAULT_UNSUPPORTED_TYPE"
        }
        let sanitizedValue = AppSettings.sanitizedEasyReplayKitH264TargetFPS(rawValue)
        let maximumFPS = Int(sanitizedValue)
        airPlayLog.info("[AirPlayInfo] maxFPS decision branch=\(branch, privacy: .public) raw=\(rawValue) sanitized=\(sanitizedValue) advertised=\(maximumFPS)")
        return maximumFPS
    }

    private func currentAdvertisedDisplayConfiguration() -> AirPlayReceiverDisplayConfiguration {
        let rawValueObject = UserDefaults.standard.object(forKey: AppSettings.Keys.easyAirPlayQuality)
        let rawValue: String
        let branch: String
        if let value = rawValueObject as? String {
            rawValue = value
            branch = "USER_DEFAULTS"
        } else {
            rawValue = AppSettings.Defaults.easyAirPlayQuality
            branch = rawValueObject == nil ? "DEFAULT_MISSING" : "DEFAULT_UNSUPPORTED_TYPE"
        }

        let sanitizedValue = AppSettings.EasyAirPlayQuality.sanitized(rawValue)
        let displayConfiguration = AirPlayReceiverDisplayConfiguration.make(quality: sanitizedValue)
        if sanitizedValue == AppSettings.EasyAirPlayQuality.high {
            airPlayLog.info("[AirPlayInfo] display decision branch=HEVC_HIGH raw=\(rawValue, privacy: .public) sanitized=\(sanitizedValue, privacy: .public) advertised=\(displayConfiguration.diagnosticDescription, privacy: .public) screenMultiCodec=true")
        } else {
            airPlayLog.info("[AirPlayInfo] display decision branch=\(branch, privacy: .public) raw=\(rawValue, privacy: .public) sanitized=\(sanitizedValue, privacy: .public) advertised=\(displayConfiguration.diagnosticDescription, privacy: .public)")
        }
        return displayConfiguration
    }

    private func logInfoRequestBody(_ body: Data) {
        guard !body.isEmpty else {
            airPlayLog.info("[AirPlayInfo] request body branch=empty")
            return
        }

        do {
            let object = try PropertyListSerialization.propertyList(from: body, options: [], format: nil)
            if let plist = object as? [String: Any] {
                airPlayLog.info("[AirPlayInfo] request plistKeys=\(plist.keys.sorted().joined(separator: ","), privacy: .public)")
            } else {
                airPlayLog.warning("[AirPlayInfo] request body branch=non-dictionary-plist bytes=\(body.count)")
            }
        } catch {
            airPlayLog.warning("[AirPlayInfo] request plist parse failed bytes=\(body.count) error=\(error.localizedDescription, privacy: .public)")
        }
    }

    private func logAudioModeRequestBody(_ body: Data) {
        guard !body.isEmpty else {
            airPlayLog.info("[AirPlayAudio] audioMode body branch=empty")
            return
        }

        do {
            let object = try PropertyListSerialization.propertyList(from: body, options: [], format: nil)
            guard let plist = object as? [String: Any] else {
                airPlayLog.warning("[AirPlayAudio] audioMode body branch=non-dictionary-plist bytes=\(body.count)")
                return
            }
            let keys = plist.keys.sorted()
            let mode = plist["audioMode"] as? String ?? "nil"
            airPlayLog.info("[AirPlayAudio] audioMode plistKeys=\(keys.joined(separator: ","), privacy: .public) mode=\(mode, privacy: .public)")
        } catch {
            airPlayLog.warning("[AirPlayAudio] audioMode plist parse failed bytes=\(body.count) error=\(error.localizedDescription, privacy: .public)")
        }
    }

    private func logPairSetupPinRequestBody(_ body: Data) {
        guard !body.isEmpty else {
            airPlayLog.info("[AirPlayPairing] pair-setup-pin body branch=empty")
            return
        }

        do {
            let object = try PropertyListSerialization.propertyList(from: body, options: [], format: nil)
            guard let plist = object as? [String: Any] else {
                airPlayLog.warning("[AirPlayPairing] pair-setup-pin body branch=non-dictionary-plist bytes=\(body.count)")
                return
            }
            let keys = plist.keys.sorted()
            let method = plist["method"] as? String ?? "nil"
            let userPresent = plist["user"] != nil
            let pkBytes = (plist["pk"] as? Data)?.count ?? 0
            let proofBytes = (plist["proof"] as? Data)?.count ?? 0
            let epkBytes = (plist["epk"] as? Data)?.count ?? 0
            let authTagBytes = (plist["authTag"] as? Data)?.count ?? 0
            airPlayLog.info("[AirPlayPairing] pair-setup-pin plistKeys=\(keys.joined(separator: ","), privacy: .public) method=\(method, privacy: .public) userPresent=\(userPresent) pkBytes=\(pkBytes) proofBytes=\(proofBytes) epkBytes=\(epkBytes) authTagBytes=\(authTagBytes)")
        } catch {
            airPlayLog.warning("[AirPlayPairing] pair-setup-pin plist parse failed bytes=\(body.count) error=\(error.localizedDescription, privacy: .public)")
        }
    }

    private func handleGetParameterRequest(_ request: AirPlayControlRequest) -> AirPlayControlResponse {
        let contentType = AirPlayTextParameters.normalizedContentType(from: request.headerValue("Content-Type"))
        airPlayLog.info("[AirPlayParameter] get branch=BEGIN contentType=\(contentType ?? "nil", privacy: .public) bodyBytes=\(request.body.count)")
        guard contentType == "text/parameters" else {
            airPlayLog.warning("[AirPlayParameter] get branch=UNSUPPORTED_CONTENT_TYPE contentType=\(contentType ?? "nil", privacy: .public)")
            return .parameterNotUnderstood("AirPlay GET_PARAMETER requires text/parameters")
        }
        guard let bodyText = String(data: request.body, encoding: .utf8) else {
            airPlayLog.warning("[AirPlayParameter] get branch=NON_UTF8_BODY bodyBytes=\(request.body.count)")
            return .parameterNotUnderstood("AirPlay GET_PARAMETER body was not UTF-8")
        }

        let parameterNames = AirPlayTextParameters.parameterLines(from: bodyText)
        airPlayLog.info("[AirPlayParameter] get branch=PARSED names=\(parameterNames.joined(separator: ","), privacy: .public) rawPreview=\(AirPlayTextParameters.sanitizedPreview(bodyText), privacy: .public)")
        guard !parameterNames.isEmpty else {
            airPlayLog.info("[AirPlayParameter] get branch=EMPTY_PARAMETER_LIST")
            return .ok(headers: ["Content-Type": "text/parameters"])
        }

        var responseLines: [String] = []
        for name in parameterNames {
            switch name {
            case "volume":
                airPlayLog.info("[AirPlayParameter] get branch=VOLUME_RESPONSE decibels=\(self.currentAirPlayVolumeDecibels)")
                responseLines.append("volume: \(String(format: "%.6f", currentAirPlayVolumeDecibels))")
            default:
                airPlayLog.warning("[AirPlayParameter] get branch=UNKNOWN_PARAMETER name=\(name, privacy: .public)")
            }
        }

        let responseText = responseLines.isEmpty ? "" : responseLines.joined(separator: "\r\n") + "\r\n"
        airPlayLog.info("[AirPlayParameter] get branch=RESPONSE lineCount=\(responseLines.count) bodyBytes=\(responseText.utf8.count)")
        return .ok(headers: ["Content-Type": "text/parameters"], body: Data(responseText.utf8))
    }

    private func handleSetParameterRequest(_ request: AirPlayControlRequest) -> AirPlayControlResponse {
        let contentType = AirPlayTextParameters.normalizedContentType(from: request.headerValue("Content-Type"))
        airPlayLog.info("[AirPlayParameter] set branch=BEGIN contentType=\(contentType ?? "nil", privacy: .public) bodyBytes=\(request.body.count)")
        guard !request.body.isEmpty else {
            airPlayLog.info("[AirPlayParameter] set branch=EMPTY_BODY")
            return .ok()
        }
        guard contentType == "text/parameters" else {
            airPlayLog.info("[AirPlayParameter] set branch=NON_TEXT_CONTENT_TYPE contentType=\(contentType ?? "nil", privacy: .public) action=acknowledge")
            return .ok()
        }
        guard let bodyText = String(data: request.body, encoding: .utf8) else {
            airPlayLog.warning("[AirPlayParameter] set branch=NON_UTF8_BODY bodyBytes=\(request.body.count)")
            return .parameterNotUnderstood("AirPlay SET_PARAMETER body was not UTF-8")
        }

        let assignments = AirPlayTextParameters.parameterAssignments(from: bodyText) { line in
            airPlayLog.warning("[AirPlayParameter] assignment branch=MALFORMED line=\(line, privacy: .public)")
        }
        airPlayLog.info("[AirPlayParameter] set branch=PARSED names=\(assignments.map { $0.name }.joined(separator: ","), privacy: .public) rawPreview=\(AirPlayTextParameters.sanitizedPreview(bodyText), privacy: .public)")
        for assignment in assignments {
            switch assignment.name {
            case "volume":
                if let volume = Double(assignment.value.trimmingCharacters(in: .whitespaces)) {
                    currentAirPlayVolumeDecibels = volume
                    airPlayLog.info("[AirPlayParameter] set branch=VOLUME_UPDATED decibels=\(volume)")
                } else {
                    airPlayLog.warning("[AirPlayParameter] set branch=VOLUME_PARSE_FAILED value=\(assignment.value, privacy: .public)")
                }
            case "progress":
                airPlayLog.info("[AirPlayParameter] set branch=PROGRESS_OBSERVED value=\(assignment.value, privacy: .public)")
            default:
                airPlayLog.warning("[AirPlayParameter] set branch=UNKNOWN_PARAMETER name=\(assignment.name, privacy: .public)")
            }
        }
        return .ok()
    }

    private func showCurrentPairingPINOnMain(_ pin: String, trigger: String) {
        pairingPINClearWorkItem?.cancel()
        pairingPINClearWorkItem = nil
        pairingPINDisplayGeneration += 1
        pairingPINVisibleUntil = Date().addingTimeInterval(airPlayPairingPINMinimumVisibleSeconds)
        currentPairingPIN = pin
        statusMessage = "AirPlay PIN: \(pin)"
        airPlayLog.warning("[AirPlayPairing] UI branch=SHOW_PIN_MINIMUM trigger=\(trigger, privacy: .public) pinDigits=\(pin.count) generation=\(self.pairingPINDisplayGeneration) minimumSeconds=\(airPlayPairingPINMinimumVisibleSeconds)")
    }

    private func clearCurrentPairingPINOnMain(trigger: String, force: Bool = false) {
        guard currentPairingPIN != nil else {
            pairingPINClearWorkItem?.cancel()
            pairingPINClearWorkItem = nil
            pairingPINVisibleUntil = nil
            airPlayLog.info("[AirPlayPairing] UI branch=CLEAR_PIN_SKIPPED trigger=\(trigger, privacy: .public) reason=no-visible-pin force=\(force)")
            return
        }

        if force {
            pairingPINClearWorkItem?.cancel()
            pairingPINClearWorkItem = nil
            pairingPINVisibleUntil = nil
            currentPairingPIN = nil
            airPlayLog.info("[AirPlayPairing] UI branch=CLEAR_PIN_FORCED trigger=\(trigger, privacy: .public)")
            return
        }

        guard let visibleUntil = pairingPINVisibleUntil else {
            currentPairingPIN = nil
            airPlayLog.info("[AirPlayPairing] UI branch=CLEAR_PIN_IMMEDIATE trigger=\(trigger, privacy: .public) reason=no-visible-until")
            return
        }

        let remainingSeconds = visibleUntil.timeIntervalSinceNow
        guard remainingSeconds > 0 else {
            pairingPINVisibleUntil = nil
            currentPairingPIN = nil
            airPlayLog.info("[AirPlayPairing] UI branch=CLEAR_PIN_AFTER_MINIMUM trigger=\(trigger, privacy: .public)")
            return
        }

        pairingPINClearWorkItem?.cancel()
        let generation = pairingPINDisplayGeneration
        let workItem = DispatchWorkItem { [weak self] in
            guard let self else { return }
            guard self.pairingPINDisplayGeneration == generation else {
                airPlayLog.info("[AirPlayPairing] UI branch=DEFERRED_CLEAR_SKIPPED trigger=\(trigger, privacy: .public) reason=generation-changed expected=\(generation) actual=\(self.pairingPINDisplayGeneration)")
                return
            }
            self.pairingPINVisibleUntil = nil
            self.currentPairingPIN = nil
            self.pairingPINClearWorkItem = nil
            airPlayLog.info("[AirPlayPairing] UI branch=DEFERRED_CLEAR_APPLIED trigger=\(trigger, privacy: .public) generation=\(generation)")
        }
        pairingPINClearWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + remainingSeconds, execute: workItem)
        airPlayLog.info("[AirPlayPairing] UI branch=DEFERRED_CLEAR_SCHEDULED trigger=\(trigger, privacy: .public) generation=\(generation) remainingSeconds=\(remainingSeconds)")
    }

    private func handlePairingResult(_ result: AirPlayPairingSession.Result, trigger: String) {
        airPlayLog.info("[AirPlayPairing] result trigger=\(trigger, privacy: .public) status=\(result.response.statusCode) phase=\(result.phase.diagnosticDescription, privacy: .public) message=\(result.message, privacy: .public) visiblePINPresent=\(result.visiblePIN != nil) clearPIN=\(result.shouldClearVisiblePIN)")

        if result.response.statusCode >= 400 {
            airPlayLog.warning("[AirPlayPairing] branch=ERROR trigger=\(trigger, privacy: .public) status=\(result.response.statusCode) reason=\(result.message, privacy: .public)")
            publishError(result.message, trigger: trigger)
        } else {
            airPlayLog.info("[AirPlayPairing] branch=OK trigger=\(trigger, privacy: .public) status=\(result.response.statusCode)")
        }

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            if let pin = result.visiblePIN {
                airPlayLog.info("[AirPlayPairing] UI branch=SHOW_PIN trigger=\(trigger, privacy: .public) pinDigits=\(pin.count)")
                self.showCurrentPairingPINOnMain(pin, trigger: trigger)
            } else {
                airPlayLog.info("[AirPlayPairing] UI branch=NO_NEW_PIN trigger=\(trigger, privacy: .public)")
            }

            if result.shouldClearVisiblePIN {
                airPlayLog.info("[AirPlayPairing] UI branch=CLEAR_PIN trigger=\(trigger, privacy: .public)")
                self.clearCurrentPairingPINOnMain(trigger: "\(trigger) result clear")
            } else {
                airPlayLog.info("[AirPlayPairing] UI branch=KEEP_PIN_STATE trigger=\(trigger, privacy: .public) pinVisible=\(self.currentPairingPIN != nil)")
            }

            switch result.phase {
            case .verified:
                airPlayLog.info("[AirPlayPairing] UI branch=VERIFIED trigger=\(trigger, privacy: .public)")
                self.clearCurrentPairingPINOnMain(trigger: "\(trigger) verified")
                self.statusMessage = "AirPlay paired; waiting for video setup"
            case .pinSetupComplete:
                airPlayLog.info("[AirPlayPairing] UI branch=PIN_SETUP_COMPLETE trigger=\(trigger, privacy: .public)")
                self.clearCurrentPairingPINOnMain(trigger: "\(trigger) pin setup complete")
                self.statusMessage = "AirPlay PIN accepted; verifying session"
            case .rejected:
                airPlayLog.info("[AirPlayPairing] UI branch=REJECTED trigger=\(trigger, privacy: .public)")
            default:
                airPlayLog.info("[AirPlayPairing] UI branch=PHASE_NO_STATUS_OVERRIDE trigger=\(trigger, privacy: .public) phase=\(result.phase.diagnosticDescription, privacy: .public)")
            }
        }
    }

    private func handleSetupRequest(
        _ request: AirPlayControlRequest,
        respond: @escaping AirPlayControlServer.ResponseHandler
    ) {
        let setup = parseSetupBody(request.body)
        airPlayLog.info("[AirPlaySetup] plistKeys=\(setup.keys.joined(separator: ","), privacy: .public) streamType=\(setup.streamType.map(String.init) ?? "nil", privacy: .public) streamConnectionIDBytes=\(setup.streamConnectionID?.utf8.count ?? 0) ekeyBytes=\(setup.encryptedKey?.count ?? 0) eivBytes=\(setup.encryptedIV?.count ?? 0) et=\(setup.encryptionType.map(String.init) ?? "nil", privacy: .public) timingPort=\(setup.timingPort.map(String.init) ?? "nil", privacy: .public) timingProtocol=\(setup.timingProtocol ?? "nil", privacy: .public) remoteControlOnly=\(setup.isRemoteControlOnly.map(String.init) ?? "nil", privacy: .public)")
        DispatchQueue.main.async { [weak self] in
            self?.lastSetupStreamType = setup.streamType
        }

        if setup.hasEncryptedKeyMaterial {
            airPlayLog.info("[AirPlaySetup] branch=KEY_MATERIAL ekeyBytes=\(setup.encryptedKey?.count ?? 0) eivBytes=\(setup.encryptedIV?.count ?? 0) isScreenMirroring=\(setup.isScreenMirroringSession.map(String.init) ?? "nil", privacy: .public) timingPort=\(setup.timingPort.map(String.init) ?? "nil", privacy: .public)")
            fairPlaySession.observeEncryptedStreamKey(
                encryptedKey: setup.encryptedKey,
                encryptedIV: setup.encryptedIV,
                encryptionType: setup.encryptionType,
                pairVerifySharedSecret: pairingSession.verifiedPairingSharedSecret
            )
            publishFairPlayStatus(trigger: "SETUP key material")
            retryPendingAudioPlaybackIfPossible(trigger: "SETUP key material")
            if let reason = fairPlaySession.streamKeyReadinessFailureReason(trigger: "SETUP key material") {
                airPlayLog.warning("[AirPlaySetup] branch=KEY_MATERIAL_STREAM_KEY_UNAVAILABLE reason=\(reason, privacy: .public)")
                publishError(reason, trigger: "SETUP key material")
                respond(.notImplemented(reason))
                return
            }

            startTimingServer(remoteTimingPort: setup.timingPort, timingProtocol: setup.timingProtocol) { [weak self] result in
                guard let self else { return }
                switch result {
                case .success(let timingPort):
                    airPlayLog.info("[AirPlaySetup] branch=KEY_MATERIAL_TIMING_READY timingPort=\(timingPort) streamCount=\(setup.streams.count)")
                    self.handleSetupStreamsOrTimingOnly(setup, timingPort: timingPort, respond: respond)
                case .failure(let error):
                    self.publishError(error.localizedDescription, trigger: "timing listener failed")
                    respond(.badRequest("AirPlay timing listener failed: \(error.localizedDescription)"))
                }
            }
            return
        }

        handleSetupStreamsOrTimingOnly(setup, timingPort: activeTimingPort, respond: respond)
    }

    private func handleSetupStreamsOrTimingOnly(
        _ setup: ParsedSetupBody,
        timingPort: UInt16?,
        respond: @escaping AirPlayControlServer.ResponseHandler
    ) {
        guard !setup.streams.isEmpty else {
            if setup.hasEncryptedKeyMaterial, let timingPort {
                airPlayLog.info("[AirPlaySetup] branch=TIMING_ONLY noStreams=true timingPort=\(timingPort)")
                respond(setupTimingResponse(timingPort: timingPort))
                return
            }

            airPlayLog.warning("[AirPlaySetup] branch=NO_STREAMS_UNSUPPORTED keyMaterial=\(setup.hasEncryptedKeyMaterial) timingPort=\(timingPort.map(String.init) ?? "nil", privacy: .public)")
            respond(.badRequest("AirPlay SETUP did not include a supported stream description"))
            return
        }

        let streamTypes = setup.streams.map { $0.type.map(String.init) ?? "nil" }.joined(separator: ",")
        airPlayLog.info("[AirPlaySetup] branch=STREAMS_BEGIN streamCount=\(setup.streams.count) streamTypes=\(streamTypes, privacy: .public) keyMaterial=\(setup.hasEncryptedKeyMaterial) timingPort=\(timingPort.map(String.init) ?? "nil", privacy: .public)")
        processSetupStreams(
            setup,
            timingPort: timingPort,
            streamIndex: 0,
            accumulatedResponses: [],
            respond: respond
        )
    }

    private func processSetupStreams(
        _ setup: ParsedSetupBody,
        timingPort: UInt16?,
        streamIndex: Int,
        accumulatedResponses: [SetupStreamResponse],
        respond: @escaping AirPlayControlServer.ResponseHandler
    ) {
        guard streamIndex < setup.streams.count else {
            airPlayLog.info("[AirPlaySetup] branch=STREAMS_COMPLETE responseCount=\(accumulatedResponses.count) timingPort=\(timingPort.map(String.init) ?? "nil", privacy: .public)")
            respond(setupStreamsResponse(timingPort: timingPort, streams: accumulatedResponses))
            return
        }

        let stream = setup.streams[streamIndex]
        switch stream.type {
        case airPlayMirrorStreamType:
            airPlayLog.info("[AirPlaySetup] streamIndex=\(streamIndex) branch=MIRROR_STREAM \(stream.diagnosticDescription, privacy: .public)")
            prepareMirrorSetupResponse(stream: stream, setup: setup) { [weak self] result in
                guard let self else { return }
                switch result {
                case .success(let streamResponse):
                    var nextResponses = accumulatedResponses
                    nextResponses.append(streamResponse)
                    self.processSetupStreams(
                        setup,
                        timingPort: timingPort,
                        streamIndex: streamIndex + 1,
                        accumulatedResponses: nextResponses,
                        respond: respond
                    )
                case .failure(let failure):
                    airPlayLog.warning("[AirPlaySetup] streamIndex=\(streamIndex) branch=MIRROR_STREAM_FAILED reason=\(failure.localizedDescription, privacy: .public)")
                    respond(failure.response)
                }
            }
        case airPlayAudioStreamType:
            airPlayLog.info("[AirPlaySetup] streamIndex=\(streamIndex) branch=AUDIO_STREAM \(stream.diagnosticDescription, privacy: .public)")
            prepareAudioSetupResponse(stream) { [weak self] result in
                guard let self else { return }
                switch result {
                case .success(let streamResponse):
                    var nextResponses = accumulatedResponses
                    nextResponses.append(streamResponse)
                    self.processSetupStreams(
                        setup,
                        timingPort: timingPort,
                        streamIndex: streamIndex + 1,
                        accumulatedResponses: nextResponses,
                        respond: respond
                    )
                case .failure(let failure):
                    airPlayLog.warning("[AirPlaySetup] streamIndex=\(streamIndex) branch=AUDIO_STREAM_FAILED reason=\(failure.localizedDescription, privacy: .public)")
                    respond(failure.response)
                }
            }
        case .some(let unsupportedType):
            airPlayLog.warning("[AirPlaySetup] streamIndex=\(streamIndex) branch=UNSUPPORTED_STREAM_TYPE type=\(unsupportedType)")
            respond(.badRequest("Unsupported AirPlay stream type \(unsupportedType)"))
        case .none:
            airPlayLog.warning("[AirPlaySetup] streamIndex=\(streamIndex) branch=MISSING_STREAM_TYPE keys=\(stream.keys.joined(separator: ","), privacy: .public)")
            respond(.badRequest("AirPlay SETUP stream did not include a type"))
        }
    }

    private func prepareMirrorSetupResponse(
        stream: ParsedSetupStream,
        setup: ParsedSetupBody,
        completion: @escaping (Result<SetupStreamResponse, SetupStreamFailure>) -> Void
    ) {
        let streamConnectionID = stream.streamConnectionID ?? setup.streamConnectionID
        let streamConnectionSource: String
        if stream.streamConnectionID != nil {
            streamConnectionSource = "stream"
        } else if setup.streamConnectionID != nil {
            streamConnectionSource = "setup"
        } else {
            streamConnectionSource = "missing"
        }
        airPlayLog.info("[AirPlaySetup] branch=MIRROR_STREAM_CONNECTION source=\(streamConnectionSource, privacy: .public) streamConnectionIDBytes=\(streamConnectionID?.utf8.count ?? 0)")
        fairPlaySession.observeStreamConnectionID(
            streamConnectionID,
            pairVerifySharedSecret: pairingSession.verifiedPairingSharedSecret
        )
        publishFairPlayStatus(trigger: "SETUP stream connection")
        retryPendingAudioPlaybackIfPossible(trigger: "SETUP stream connection")
        if let reason = fairPlaySession.videoReadinessFailureReason(trigger: "SETUP stream type \(airPlayMirrorStreamType)") {
            airPlayLog.warning("[AirPlaySetup] branch=MIRROR_STREAM_KEY_UNAVAILABLE reason=\(reason, privacy: .public)")
            publishError(reason, trigger: "SETUP stream type \(airPlayMirrorStreamType)")
            completion(.failure(SetupStreamFailure(response: .notImplemented(reason), description: reason)))
            return
        }

        publishHealth(.settingUp, trigger: "SETUP stream type \(airPlayMirrorStreamType)")
        startMirrorDataServer { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let dataPort):
                airPlayLog.info("[AirPlaySetup] branch=MIRROR_STREAM_READY dataPort=\(dataPort)")
                completion(.success([
                    "dataPort": Int(dataPort),
                    "type": airPlayMirrorStreamType
                ]))
            case .failure(let error):
                self.publishError(error.localizedDescription, trigger: "mirror data listener failed")
                completion(.failure(SetupStreamFailure(
                    response: .badRequest("Mirror data listener failed: \(error.localizedDescription)"),
                    description: error.localizedDescription
                )))
            }
        }
    }

    private func prepareAudioSetupResponse(
        _ audioStream: ParsedSetupStream,
        completion: @escaping (Result<SetupStreamResponse, SetupStreamFailure>) -> Void
    ) {
        let playbackConfiguration = makeAudioPlaybackConfiguration(
            from: audioStream,
            trigger: "SETUP stream type \(airPlayAudioStreamType)"
        )
        if playbackConfiguration == nil {
            pendingAudioPlaybackStream = audioStream
            publishMediaPlaybackStatus("audio waiting for FairPlay key")
            airPlayLog.warning("[AirPlayAudio] setup branch=PENDING_PLAYBACK_CONFIG stream=\(audioStream.diagnosticDescription, privacy: .public)")
        } else {
            pendingAudioPlaybackStream = nil
        }

        startAudioSinkServer(configuration: playbackConfiguration) { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let ports):
                airPlayLog.info("[AirPlayAudio] setup branch=SINK_READY mode=\(playbackConfiguration == nil ? "no-output" : "playback", privacy: .public) dataPort=\(ports.dataPort) controlPort=\(ports.controlPort)")
                completion(.success([
                    "controlPort": Int(ports.controlPort),
                    "dataPort": Int(ports.dataPort),
                    "type": airPlayAudioStreamType
                ]))
            case .failure(let error):
                self.publishError(error.localizedDescription, trigger: "audio sink listener failed")
                completion(.failure(SetupStreamFailure(
                    response: .badRequest("AirPlay audio sink listener failed: \(error.localizedDescription)"),
                    description: error.localizedDescription
                )))
            }
        }
    }

    private func makeAudioPlaybackConfiguration(
        from audioStream: ParsedSetupStream,
        trigger: String
    ) -> AirPlayAudioPlaybackConfiguration? {
        if let reason = fairPlaySession.audioReadinessFailureReason(trigger: trigger) {
            airPlayLog.warning("[AirPlayAudio] config branch=PLAYBACK_KEY_UNAVAILABLE trigger=\(trigger, privacy: .public) reason=\(reason, privacy: .public)")
            return nil
        }

        guard let keyMaterial = fairPlaySession.audioKeyMaterial else {
            airPlayLog.warning("[AirPlayAudio] config branch=PLAYBACK_KEY_MISSING_AFTER_READY_CHECK trigger=\(trigger, privacy: .public)")
            return nil
        }

        let samplesPerFrame = audioStream.samplesPerFrame ?? 480
        let sampleRate = Double(audioStream.sampleRate ?? 44_100)
        let playbackConfiguration = AirPlayAudioPlaybackConfiguration(
            key: keyMaterial.key,
            iv: keyMaterial.iv,
            compressionType: audioStream.compressionType ?? 8,
            audioFormat: audioStream.audioFormat,
            samplesPerFrame: samplesPerFrame,
            sampleRate: sampleRate,
            channelCount: 2,
            remoteControlPort: audioStream.controlPort
        )
        airPlayLog.info("[AirPlayAudio] config branch=PLAYBACK_CONFIG_READY trigger=\(trigger, privacy: .public) \(playbackConfiguration.diagnosticDescription, privacy: .public)")
        return playbackConfiguration
    }

    private func retryPendingAudioPlaybackIfPossible(trigger: String) {
        guard let pendingAudioPlaybackStream else {
            airPlayLog.debug("[AirPlayAudio] pending upgrade branch=NO_PENDING_STREAM trigger=\(trigger, privacy: .public)")
            return
        }

        guard let audioSinkServer else {
            airPlayLog.warning("[AirPlayAudio] pending upgrade branch=NO_AUDIO_SINK trigger=\(trigger, privacy: .public)")
            return
        }

        guard audioSinkServer.canInstallPlaybackConfiguration else {
            airPlayLog.info("[AirPlayAudio] pending upgrade branch=SINK_NOT_UPGRADABLE trigger=\(trigger, privacy: .public) mode=\(audioSinkServer.modeDescription, privacy: .public)")
            return
        }

        guard let playbackConfiguration = makeAudioPlaybackConfiguration(
            from: pendingAudioPlaybackStream,
            trigger: "pending audio upgrade after \(trigger)"
        ) else {
            airPlayLog.warning("[AirPlayAudio] pending upgrade branch=KEYS_STILL_UNAVAILABLE trigger=\(trigger, privacy: .public)")
            publishMediaPlaybackStatus("audio still waiting for FairPlay key")
            return
        }

        if audioSinkServer.installPlaybackConfiguration(
            playbackConfiguration,
            reason: "pending audio upgrade after \(trigger)"
        ) {
            self.pendingAudioPlaybackStream = nil
            publishMediaPlaybackStatus("audio playback pipeline ready")
            airPlayLog.info("[AirPlayAudio] pending upgrade branch=INSTALLED trigger=\(trigger, privacy: .public)")
        } else {
            airPlayLog.warning("[AirPlayAudio] pending upgrade branch=INSTALL_SKIPPED trigger=\(trigger, privacy: .public) mode=\(audioSinkServer.modeDescription, privacy: .public)")
        }
    }

    private func setupTimingResponse(timingPort: UInt16) -> AirPlayControlResponse {
        let payload = AirPlaySetupResponsePayload.timingOnly(timingPort: timingPort)
        do {
            let body = try PropertyListSerialization.data(fromPropertyList: payload.plist, format: .binary, options: 0)
            airPlayLog.info("[AirPlaySetup] response branch=\(payload.branch, privacy: .public) keys=\(payload.keys.joined(separator: ","), privacy: .public) eventPort=0 timingPort=\(timingPort)")
            return .ok(headers: [
                "Audio-Jack-Status": "connected; type=digital",
                "Content-Type": "application/x-apple-binary-plist"
            ], body: body)
        } catch {
            airPlayLog.error("[AirPlaySetup] response branch=TIMING_ONLY serialization failed error=\(error.localizedDescription, privacy: .public)")
            return .badRequest("Could not build AirPlay key setup response")
        }
    }

    private func setupStreamsResponse(timingPort: UInt16?, streams: [SetupStreamResponse]) -> AirPlayControlResponse {
        let payload = AirPlaySetupResponsePayload.streams(timingPort: timingPort, streams: streams)
        let streamTypes = streams
            .map { Self.integerValue(from: $0["type"]).map(String.init) ?? "nil" }
            .joined(separator: ",")
        do {
            let body = try PropertyListSerialization.data(fromPropertyList: payload.plist, format: .binary, options: 0)
            airPlayLog.info("[AirPlaySetup] response branch=\(payload.branch, privacy: .public) keys=\(payload.keys.joined(separator: ","), privacy: .public) streamCount=\(streams.count) streamTypes=\(streamTypes, privacy: .public) timingPort=\(timingPort.map(String.init) ?? "nil", privacy: .public)")
            return .ok(headers: [
                "Audio-Jack-Status": "connected; type=digital",
                "Content-Type": "application/x-apple-binary-plist"
            ], body: body)
        } catch {
            airPlayLog.error("[AirPlaySetup] response branch=STREAMS serialization failed error=\(error.localizedDescription, privacy: .public)")
            return .badRequest("Could not build AirPlay setup response")
        }
    }

    private struct SetupStreamFailure: LocalizedError {
        let response: AirPlayControlResponse
        let description: String

        var errorDescription: String? {
            description
        }
    }

    private struct ParsedSetupStream {
        let keys: [String]
        let type: Int?
        let streamConnectionID: String?
        let audioFormat: Int?
        let controlPort: Int?
        let compressionType: Int?
        let samplesPerFrame: Int?
        let sampleRate: Int?
        let isMedia: Bool?
        let usingScreen: Bool?

        var diagnosticDescription: String {
            "streamKeys=\(keys.joined(separator: ",")) type=\(type.map(String.init) ?? "nil") streamConnectionIDBytes=\(streamConnectionID?.utf8.count ?? 0) audioFormat=\(audioFormat.map(String.init) ?? "nil") controlPort=\(controlPort.map(String.init) ?? "nil") ct=\(compressionType.map(String.init) ?? "nil") spf=\(samplesPerFrame.map(String.init) ?? "nil") sr=\(sampleRate.map(String.init) ?? "nil") isMedia=\(isMedia.map(String.init) ?? "nil") usingScreen=\(usingScreen.map(String.init) ?? "nil")"
        }
    }

    private struct ParsedSetupBody {
        let keys: [String]
        let streams: [ParsedSetupStream]
        let streamType: Int?
        let streamConnectionID: String?
        let encryptedKey: Data?
        let encryptedIV: Data?
        let encryptionType: Int?
        let isScreenMirroringSession: Bool?
        let isRemoteControlOnly: Bool?
        let timingPort: Int?
        let timingProtocol: String?

        var hasEncryptedKeyMaterial: Bool {
            encryptedKey != nil || encryptedIV != nil
        }

        var firstMirrorStream: ParsedSetupStream? {
            streams.first { $0.type == airPlayMirrorStreamType }
        }

        var firstAudioStream: ParsedSetupStream? {
            streams.first { $0.type == airPlayAudioStreamType }
        }
    }

    private func parseSetupBody(_ body: Data) -> ParsedSetupBody {
        guard !body.isEmpty else {
            airPlayLog.warning("[AirPlaySetup] empty setup body")
            return ParsedSetupBody(
                keys: [],
                streams: [],
                streamType: nil,
                streamConnectionID: nil,
                encryptedKey: nil,
                encryptedIV: nil,
                encryptionType: nil,
                isScreenMirroringSession: nil,
                isRemoteControlOnly: nil,
                timingPort: nil,
                timingProtocol: nil
            )
        }

        do {
            let object = try PropertyListSerialization.propertyList(from: body, options: [], format: nil)
            guard let plist = object as? [String: Any] else {
                airPlayLog.warning("[AirPlaySetup] setup body was not dictionary")
                return ParsedSetupBody(
                    keys: [],
                    streams: [],
                    streamType: nil,
                    streamConnectionID: nil,
                    encryptedKey: nil,
                    encryptedIV: nil,
                    encryptionType: nil,
                    isScreenMirroringSession: nil,
                    isRemoteControlOnly: nil,
                    timingPort: nil,
                    timingProtocol: nil
                )
            }
            let keys = plist.keys.sorted()
            let streams = (plist["streams"] as? [[String: Any]] ?? []).map { stream in
                let rawStreamConnectionID = stream["streamConnectionID"]
                let streamConnectionID = AirPlayStreamConnectionID.normalizedString(from: rawStreamConnectionID)
                let streamConnectionIDBranch = streamConnectionID == nil ? "MISSING_OR_UNPARSED" : "PARSED"
                airPlayLog.info("[AirPlaySetup] streamConnectionID branch=\(streamConnectionIDBranch, privacy: .public) rawKind=\(AirPlayStreamConnectionID.valueKind(from: rawStreamConnectionID), privacy: .public) normalized=\(AirPlayStreamConnectionID.diagnosticPreview(streamConnectionID), privacy: .public)")
                return ParsedSetupStream(
                    keys: stream.keys.sorted(),
                    type: Self.integerValue(from: stream["type"]),
                    streamConnectionID: streamConnectionID,
                    audioFormat: Self.integerValue(from: stream["audioFormat"]),
                    controlPort: Self.integerValue(from: stream["controlPort"]),
                    compressionType: Self.integerValue(from: stream["ct"]),
                    samplesPerFrame: Self.integerValue(from: stream["spf"]),
                    sampleRate: Self.integerValue(from: stream["sr"]),
                    isMedia: Self.boolValue(from: stream["isMedia"]),
                    usingScreen: Self.boolValue(from: stream["usingScreen"])
                )
            }
            if streams.isEmpty {
                airPlayLog.info("[AirPlaySetup] streams branch=ABSENT_OR_EMPTY")
            } else {
                for stream in streams {
                    airPlayLog.info("[AirPlaySetup] parsed \(stream.diagnosticDescription, privacy: .public)")
                }
            }
            let streamType = streams.compactMap(\.type).first
            let streamConnectionID = streams.compactMap(\.streamConnectionID).first
            return ParsedSetupBody(
                keys: keys,
                streams: streams,
                streamType: streamType,
                streamConnectionID: streamConnectionID,
                encryptedKey: plist["ekey"] as? Data,
                encryptedIV: plist["eiv"] as? Data,
                encryptionType: Self.integerValue(from: plist["et"]),
                isScreenMirroringSession: Self.boolValue(from: plist["isScreenMirroringSession"]),
                isRemoteControlOnly: Self.boolValue(from: plist["isRemoteControlOnly"]),
                timingPort: Self.integerValue(from: plist["timingPort"]),
                timingProtocol: plist["timingProtocol"] as? String
            )
        } catch {
            airPlayLog.warning("[AirPlaySetup] setup plist parse failed error=\(error.localizedDescription, privacy: .public)")
            return ParsedSetupBody(
                keys: [],
                streams: [],
                streamType: nil,
                streamConnectionID: nil,
                encryptedKey: nil,
                encryptedIV: nil,
                encryptionType: nil,
                isScreenMirroringSession: nil,
                isRemoteControlOnly: nil,
                timingPort: nil,
                timingProtocol: nil
            )
        }
    }

    private static func integerValue(from value: Any?) -> Int? {
        if let value = value as? Int {
            return value
        }
        if let value = value as? UInt64 {
            return Int(value)
        }
        if let value = value as? NSNumber {
            return value.intValue
        }
        return nil
    }

    private static func boolValue(from value: Any?) -> Bool? {
        if let value = value as? Bool {
            return value
        }
        if let value = value as? NSNumber {
            return value.boolValue
        }
        return nil
    }

    private func startTimingServer(
        remoteTimingPort: Int?,
        timingProtocol: String?,
        completion: @escaping (Result<UInt16, Error>) -> Void
    ) {
        if let activeTimingPort {
            airPlayLog.info("[AirPlayTiming] start skipped reason=already-ready localTimingPort=\(activeTimingPort) remoteTimingPort=\(remoteTimingPort.map(String.init) ?? "nil", privacy: .public) timingProtocol=\(timingProtocol ?? "nil", privacy: .public)")
            completion(.success(activeTimingPort))
            return
        }

        airPlayLog.info("[AirPlayTiming] start requested remoteTimingPort=\(remoteTimingPort.map(String.init) ?? "nil", privacy: .public) timingProtocol=\(timingProtocol ?? "nil", privacy: .public)")
        let remotePort = remoteTimingPort.flatMap(UInt16.init(exactly:))
        if remoteTimingPort != nil, remotePort == nil {
            let reason = "AirPlay timingPort \(remoteTimingPort.map(String.init) ?? "nil") is outside the UDP port range"
            airPlayLog.error("[AirPlayTiming] start branch=INVALID_REMOTE_PORT reason=\(reason, privacy: .public)")
            completion(.failure(NSError(domain: "Specchio.AirPlayTiming", code: 2, userInfo: [NSLocalizedDescriptionKey: reason])))
            return
        }
        if controlClientHost == nil {
            airPlayLog.warning("[AirPlayTiming] start branch=REMOTE_HOST_MISSING remoteTimingPort=\(remoteTimingPort.map(String.init) ?? "nil", privacy: .public)")
        }
        timingServer?.stop(reason: "replacing timing listener for key setup")
        let server = AirPlayTimingServer(queue: queue) { [weak self] event in
            self?.handleTimingEvent(event)
        }
        timingServer = server

        var didComplete = false
        timingReadyCompletions.append { port in
            guard !didComplete else { return }
            didComplete = true
            completion(.success(port))
        }
        timingFailureCompletions.append { error in
            guard !didComplete else { return }
            didComplete = true
            completion(.failure(NSError(domain: "Specchio.AirPlayTiming", code: 1, userInfo: [NSLocalizedDescriptionKey: error])))
        }

        server.start(remoteHost: controlClientHost, remotePort: remotePort)
    }

    private var timingReadyCompletions: [(UInt16) -> Void] = []
    private var timingFailureCompletions: [(String) -> Void] = []

    private func handleTimingEvent(_ event: AirPlayTimingServer.Event) {
        switch event {
        case .ready(let port):
            airPlayLog.info("[AirPlayTiming] listener ready port=\(port)")
            activeTimingPort = port
            DispatchQueue.main.async { [weak self] in
                self?.timingPort = port
            }
            let completions = timingReadyCompletions
            timingReadyCompletions.removeAll()
            timingFailureCompletions.removeAll()
            completions.forEach { $0(port) }
        case .failed(let reason):
            airPlayLog.error("[AirPlayTiming] listener failed reason=\(reason, privacy: .public)")
            let completions = timingFailureCompletions
            timingReadyCompletions.removeAll()
            timingFailureCompletions.removeAll()
            completions.forEach { $0(reason) }
            publishError(reason, trigger: "timing listener failed")
        case .clientState(let state):
            airPlayLog.info("[AirPlayTiming] client state=\(state, privacy: .public)")
        case .packet(let requestBytes, let responseBytes):
            airPlayLog.info("[AirPlayTiming] packet requestBytes=\(requestBytes) responseBytes=\(responseBytes)")
        case .probeSent(let remote, let bytes, let count):
            airPlayLog.info("[AirPlayTiming] active probe sent remote=\(remote, privacy: .public) bytes=\(bytes) count=\(count)")
        case .probeResponse(let remote, let bytes, let count):
            airPlayLog.info("[AirPlayTiming] active probe response remote=\(remote, privacy: .public) bytes=\(bytes) count=\(count)")
        case .stopped:
            airPlayLog.info("[AirPlayTiming] server stopped")
        }
    }

    private func startAudioSinkServer(
        configuration: AirPlayAudioPlaybackConfiguration?,
        completion: @escaping (Result<AudioSinkPorts, Error>) -> Void
    ) {
        if let audioDataPort, let audioControlPort {
            airPlayLog.info("[AirPlayAudio] start skipped reason=already-ready mode=\(self.audioSinkServer?.modeDescription ?? "unknown", privacy: .public) dataPort=\(audioDataPort) controlPort=\(audioControlPort) remoteControlPort=\(configuration?.remoteControlPort.map(String.init) ?? "nil", privacy: .public)")
            completion(.success((dataPort: audioDataPort, controlPort: audioControlPort)))
            return
        }

        airPlayLog.info("[AirPlayAudio] start requested mode=\(configuration == nil ? "no-output" : "playback", privacy: .public) remoteControlPort=\(configuration?.remoteControlPort.map(String.init) ?? "nil", privacy: .public)")
        audioSinkServer?.stop(reason: "replacing audio sink for setup")
        let server = AirPlayAudioSinkServer(queue: queue, playbackConfiguration: configuration) { [weak self] event in
            self?.handleAudioSinkEvent(event)
        }
        audioSinkServer = server

        var didComplete = false
        audioReadyCompletions.append { ports in
            guard !didComplete else { return }
            didComplete = true
            completion(.success(ports))
        }
        audioFailureCompletions.append { error in
            guard !didComplete else { return }
            didComplete = true
            completion(.failure(NSError(domain: "Specchio.AirPlayAudio", code: 1, userInfo: [NSLocalizedDescriptionKey: error])))
        }

        server.start()
    }

    private var audioReadyCompletions: [(AudioSinkPorts) -> Void] = []
    private var audioFailureCompletions: [(String) -> Void] = []

    private func handleAudioSinkEvent(_ event: AirPlayAudioSinkServer.Event) {
        switch event {
        case .ready(let dataPort, let controlPort):
            airPlayLog.info("[AirPlayAudio] sink ready mode=\(self.audioSinkServer?.modeDescription ?? "unknown", privacy: .public) dataPort=\(dataPort) controlPort=\(controlPort)")
            DispatchQueue.main.async { [weak self] in
                self?.audioDataPort = dataPort
                self?.audioControlPort = controlPort
            }
            let completions = audioReadyCompletions
            audioReadyCompletions.removeAll()
            audioFailureCompletions.removeAll()
            completions.forEach { $0((dataPort: dataPort, controlPort: controlPort)) }
        case .failed(let reason):
            airPlayLog.error("[AirPlayAudio] sink failed reason=\(reason, privacy: .public)")
            let completions = audioFailureCompletions
            audioReadyCompletions.removeAll()
            audioFailureCompletions.removeAll()
            completions.forEach { $0(reason) }
            publishError(reason, trigger: "audio sink failed")
        case .packet(let channel, let bytes, let count):
            airPlayLog.info("[AirPlayAudio] sink packet channel=\(channel.rawValue, privacy: .public) count=\(count) bytes=\(bytes)")
        case .clientState(let channel, let state):
            airPlayLog.info("[AirPlayAudio] sink client channel=\(channel.rawValue, privacy: .public) state=\(state, privacy: .public)")
        case .playback(let snapshot):
            airPlayLog.info("[AirPlayAudio] playback state=\(snapshot.state, privacy: .public) received=\(snapshot.receivedPackets) decoded=\(snapshot.decodedPackets) dropped=\(snapshot.droppedPackets) bufferedMs=\(snapshot.bufferedMilliseconds) sampleRate=\(snapshot.sampleRate) channels=\(snapshot.channelCount) lastDrop=\(snapshot.lastDropReason ?? "nil", privacy: .public)")
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.audioPlaybackStatus = snapshot.state
                self.audioPlaybackPacketCount = snapshot.receivedPackets
                self.audioPlaybackDecodedPacketCount = snapshot.decodedPackets
                self.audioPlaybackDroppedPacketCount = snapshot.droppedPackets
                self.audioPlaybackBufferedMilliseconds = snapshot.bufferedMilliseconds
                self.audioPlaybackLastDropReason = snapshot.lastDropReason
            }
        case .stopped:
            airPlayLog.info("[AirPlayAudio] sink stopped")
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.audioPlaybackStatus = "off"
                self.audioPlaybackPacketCount = 0
                self.audioPlaybackDecodedPacketCount = 0
                self.audioPlaybackDroppedPacketCount = 0
                self.audioPlaybackBufferedMilliseconds = 0
                self.audioPlaybackLastDropReason = nil
            }
        }
    }

    private func startMirrorDataServer(completion: @escaping (Result<UInt16, Error>) -> Void) {
        mirrorDataServer?.stop(reason: "replacing mirror data listener for new setup")
        let server = AirPlayMirrorDataServer(queue: queue) { [weak self] event in
            self?.handleMirrorDataEvent(event)
        }
        mirrorDataServer = server

        var didComplete = false
        mirrorReadyCompletions.append { port in
            guard !didComplete else { return }
            didComplete = true
            completion(.success(port))
        }
        mirrorFailureCompletions.append { error in
            guard !didComplete else { return }
            didComplete = true
            completion(.failure(NSError(domain: "Specchio.AirPlay", code: 1, userInfo: [NSLocalizedDescriptionKey: error])))
        }

        server.start()
    }

    private var mirrorReadyCompletions: [(UInt16) -> Void] = []
    private var mirrorFailureCompletions: [(String) -> Void] = []

    private func handleMirrorDataEvent(_ event: AirPlayMirrorDataServer.Event) {
        switch event {
        case .ready(let port):
            airPlayLog.info("[AirPlayManager] mirror data listener ready port=\(port)")
            DispatchQueue.main.async { [weak self] in
                self?.mirrorDataPort = port
            }
            let completions = mirrorReadyCompletions
            mirrorReadyCompletions.removeAll()
            mirrorFailureCompletions.removeAll()
            completions.forEach { $0(port) }
        case .failed(let reason):
            airPlayLog.error("[AirPlayManager] mirror data listener failed reason=\(reason, privacy: .public)")
            let completions = mirrorFailureCompletions
            mirrorReadyCompletions.removeAll()
            mirrorFailureCompletions.removeAll()
            completions.forEach { $0(reason) }
            publishError(reason, trigger: "mirror data failed")
        case .clientState(let state):
            airPlayLog.info("[AirPlayManager] mirror data client state=\(state, privacy: .public)")
            DispatchQueue.main.async { [weak self] in
                self?.currentClientDescription = "mirror \(state)"
            }
        case .packet(let packet, let payload):
            handleMirrorPacket(packet, payload: payload)
        case .stopped:
            airPlayLog.info("[AirPlayManager] mirror data server stopped")
        }
    }

    private func handleMirrorPacket(_ packet: AirPlayMirrorPacket, payload: Data) {
        let packetReceivedAt = Date()
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.mirrorPacketCount += 1
            self.lastMirrorPacketReceivedAt = packetReceivedAt
        }

        if packet.isCodecConfigurationPayload {
            let codecDecision = packet.codecConfigurationVideoCodecDecision(payload: payload)
            do {
                let displayConfiguration = currentAdvertisedDisplayConfiguration()
                let codec = codecDecision.codec
                airPlayLog.info("[AirPlayVideo] config codec decision branch=\(codecDecision.branch, privacy: .public) codec=\(codec.diagnosticName, privacy: .public) option=\(String(format: "0x%04X", packet.payloadOption), privacy: .public) payloadBytes=\(payload.count)")
                logAirPlayQualityNegotiation(
                    packet: packet,
                    codec: codec,
                    displayConfiguration: displayConfiguration,
                    payloadBytes: payload.count
                )
                guard !payload.isEmpty else {
                    let reason = "AirPlay \(codec.diagnosticName) config payload was empty"
                    airPlayLog.error("[AirPlayVideo] config rejected codec=\(codec.diagnosticName, privacy: .public) option=\(String(format: "0x%04X", packet.payloadOption), privacy: .public) reason=empty-payload")
                    publishError(reason, trigger: "video config")
                    return
                }
                switch codec {
                case .h264:
                    try handleH264ConfigurationPayload(payload, packet: packet)
                case .hevc:
                    try handleHEVCConfigurationPayload(payload, packet: packet)
                case .unknown:
                    let reason = "AirPlay video config used unknown codec option \(String(format: "0x%04X", packet.payloadOption))"
                    airPlayLog.warning("[AirPlayVideo] config rejected codec=unknown option=\(String(format: "0x%04X", packet.payloadOption), privacy: .public) payloadBytes=\(payload.count)")
                    publishError(reason, trigger: "video config")
                }
            } catch {
                airPlayLog.warning("[AirPlayVideo] config parse failed codec=\(codecDecision.codec.diagnosticName, privacy: .public) decisionBranch=\(codecDecision.branch, privacy: .public) payloadBytes=\(payload.count) option=\(String(format: "0x%04X", packet.payloadOption), privacy: .public) error=\(String(describing: error), privacy: .public)")
                publishError("AirPlay video config parse failed: \(error)", trigger: "video config")
            }

        } else if packet.isVideoPayload {
            recordVideoQualitySample(packet: packet, payloadBytes: payload.count)
            airPlayLog.debug("[AirPlayMirrorData] handling video rawType=\(String(format: "0x%04X", packet.rawPayloadType), privacy: .public) payloadBytes=\(payload.count) idr=\(packet.isIDRVideoPayload)")
            switch fairPlaySession.decryptVideoPayload(payload) {
            case .decrypted(let decryptedPayload):
                handleDecryptedVideoPayload(decryptedPayload, packet: packet)
            case .unavailable(let reason):
                airPlayLog.warning("[AirPlayCrypto] decrypt skipped reason=\(reason, privacy: .public) payloadBytes=\(payload.count)")
                DispatchQueue.main.async { [weak self] in
                    self?.lastError = reason
                    self?.h264DecoderStatus = "waiting for AirPlay decryption"
                }
            }

        } else if packet.isStreamingReportPayload {
            airPlayLog.debug("[AirPlayMirrorData] streaming report heartbeat bytes=\(payload.count) option=\(String(format: "0x%04X", packet.payloadOption), privacy: .public)")
        } else if packet.isOldProtocolKeepAlivePayload {
            airPlayLog.debug("[AirPlayMirrorData] old-protocol keepalive heartbeat bytes=\(payload.count) option=\(String(format: "0x%04X", packet.payloadOption), privacy: .public)")
        } else {
            airPlayLog.info("[AirPlayMirrorData] unsupported payload type=\(packet.payloadType) rawType=\(String(format: "0x%04X", packet.rawPayloadType), privacy: .public) bytes=\(payload.count)")
        }
    }

    private func handleDecryptedVideoPayload(_ payload: Data, packet: AirPlayMirrorPacket) {
        switch negotiatedMirrorVideoCodec {
        case .h264:
            handleDecryptedH264Payload(payload, packet: packet)
        case .hevc:
            handleDecryptedHEVCPayload(payload, packet: packet)
        case .unknown:
            airPlayLog.warning("[AirPlayVideo] access unit dropped codec=unknown reason=no codec config payloadBytes=\(payload.count)")
            DispatchQueue.main.async { [weak self] in
                self?.h264DecoderStatus = "waiting for AirPlay video config"
            }
        }
    }

    private func handleH264ConfigurationPayload(_ payload: Data, packet: AirPlayMirrorPacket) throws {
        if negotiatedMirrorVideoCodec != .h264 {
            airPlayLog.info("[AirPlayVideo] codec switch branch=H264 previous=\(self.negotiatedMirrorVideoCodec.diagnosticName, privacy: .public)")
            hevcAdapter.reset()
            hevcDecoder.reset(reason: "AirPlay codec switched to H.264")
        }
        negotiatedMirrorVideoCodec = .h264
        let config = try h264Adapter.applyConfigurationPayload(payload, dimensions: packet.sourceDimensions)
        airPlayLog.info("[AirPlayH264] config payloadBytes=\(payload.count) spsBytes=\(self.h264Adapter.spsData?.count ?? 0) ppsBytes=\(self.h264Adapter.ppsData?.count ?? 0) dimensions=\(packet.sourceDimensions.map { "\(Int($0.width))x\(Int($0.height))" } ?? "nil", privacy: .public)")
        h264DumpWriter?.writeParameterSets(sps: h264Adapter.spsData, pps: h264Adapter.ppsData)
        publishH264DumpStatus(trigger: "config payload")
        let accepted = h264Decoder.apply(config: config)
        let decoderStatus = h264Decoder.statusDescription
        DispatchQueue.main.async { [weak self] in
            self?.activeAirPlayVideoCodec = AirPlayMirrorVideoCodec.h264.diagnosticName
            self?.h264DecoderStatus = decoderStatus
            self?.statusMessage = accepted ? "AirPlay H.264 config ready" : "AirPlay H.264 config rejected"
            self?.lastFrameSize = packet.sourceDimensions
        }
    }

    private func handleHEVCConfigurationPayload(_ payload: Data, packet: AirPlayMirrorPacket) throws {
        if negotiatedMirrorVideoCodec != .hevc {
            airPlayLog.info("[AirPlayVideo] codec switch branch=HEVC previous=\(self.negotiatedMirrorVideoCodec.diagnosticName, privacy: .public)")
            h264Adapter.reset()
            h264Decoder.reset(reason: "AirPlay codec switched to HEVC")
        }
        negotiatedMirrorVideoCodec = .hevc
        let config = try hevcAdapter.applyConfigurationPayload(payload, dimensions: packet.sourceDimensions)
        airPlayLog.info("[AirPlayHEVC] config branch=\(self.hevcAdapter.lastConfigurationBranch, privacy: .public) payloadBytes=\(payload.count) vpsBytes=\(self.hevcAdapter.vpsData?.count ?? 0) spsBytes=\(self.hevcAdapter.spsData?.count ?? 0) ppsBytes=\(self.hevcAdapter.ppsData?.count ?? 0) nalLengthBytes=\(self.hevcAdapter.nalLengthByteCount) dimensions=\(packet.sourceDimensions.map { "\(Int($0.width))x\(Int($0.height))" } ?? "nil", privacy: .public)")
        let accepted = hevcDecoder.apply(config: config)
        let decoderStatus = hevcDecoder.statusDescription
        DispatchQueue.main.async { [weak self] in
            self?.activeAirPlayVideoCodec = AirPlayMirrorVideoCodec.hevc.diagnosticName
            self?.h264DecoderStatus = decoderStatus
            self?.statusMessage = accepted ? "AirPlay HEVC config ready" : "AirPlay HEVC config rejected"
            self?.lastFrameSize = packet.sourceDimensions
        }
    }

    private func handleDecryptedH264Payload(_ payload: Data, packet: AirPlayMirrorPacket) {
        do {
            let adapted = try h264Adapter.adaptAccessUnitPayload(payload, packet: packet)
            airPlayLog.debug("[AirPlayH264] access unit seq=\(adapted.packet.header.sequenceNumber) bytes=\(adapted.packet.annexBBytes.count) nalCount=\(adapted.nalCount) keyframe=\(adapted.isKeyframe) includesParameterSets=\(adapted.includesParameterSets) formatChanged=\(adapted.formatChanged)")
            h264DumpWriter?.writeAccessUnit(
                adapted.packet.annexBBytes,
                sequenceNumber: adapted.packet.header.sequenceNumber,
                isKeyframe: adapted.isKeyframe
            )
            if h264DumpWriter != nil {
                publishH264DumpStatus(trigger: "access unit")
            }
            let receivedAt = CACurrentMediaTime()
            let submission = h264Decoder.decode(packet: adapted.packet, receivedAt: receivedAt) { [weak self] result in
                guard let self else { return }
                switch result {
                case .decoded(let frame):
                    self.publishDecodedFrame(frame, codec: .h264)
                case .failed(let reason):
                    airPlayLog.warning("[AirPlayH264] decode failed reason=\(reason, privacy: .public)")
                    DispatchQueue.main.async { [weak self] in
                        self?.h264DecoderStatus = reason
                    }
                }
            }

            if case .dropped(let reason) = submission {
                airPlayLog.warning("[AirPlayH264] decode dropped reason=\(reason, privacy: .public)")
                DispatchQueue.main.async { [weak self] in
                    self?.h264DecoderStatus = reason
                }
            }
        } catch {
            airPlayLog.warning("[AirPlayH264] access unit adaptation failed error=\(String(describing: error), privacy: .public) payloadBytes=\(payload.count)")
            DispatchQueue.main.async { [weak self] in
                self?.h264DecoderStatus = "AirPlay H.264 adaptation failed"
            }
        }
    }

    private func handleDecryptedHEVCPayload(_ payload: Data, packet: AirPlayMirrorPacket) {
        do {
            let adapted = try hevcAdapter.adaptAccessUnitPayload(payload, packet: packet)
            airPlayLog.debug("[AirPlayHEVC] access unit seq=\(adapted.packet.header.sequenceNumber) bytes=\(adapted.packet.annexBBytes.count) nalCount=\(adapted.nalCount) keyframe=\(adapted.isKeyframe) includesParameterSets=\(adapted.includesParameterSets) formatChanged=\(adapted.formatChanged)")
            let receivedAt = CACurrentMediaTime()
            let submission = hevcDecoder.decode(packet: adapted.packet, receivedAt: receivedAt) { [weak self] result in
                guard let self else { return }
                switch result {
                case .decoded(let frame):
                    self.publishDecodedFrame(frame, codec: .hevc)
                case .failed(let reason):
                    airPlayLog.warning("[AirPlayHEVC] decode failed reason=\(reason, privacy: .public)")
                    DispatchQueue.main.async { [weak self] in
                        self?.h264DecoderStatus = reason
                    }
                }
            }

            if case .dropped(let reason) = submission {
                airPlayLog.warning("[AirPlayHEVC] decode dropped reason=\(reason, privacy: .public)")
                DispatchQueue.main.async { [weak self] in
                    self?.h264DecoderStatus = reason
                }
            }
        } catch {
            airPlayLog.warning("[AirPlayHEVC] access unit adaptation failed error=\(String(describing: error), privacy: .public) payloadBytes=\(payload.count)")
            DispatchQueue.main.async { [weak self] in
                self?.h264DecoderStatus = "AirPlay HEVC adaptation failed"
            }
        }
    }

    private func publishDecodedFrame(_ frame: ReplayKitH264VideoDecoder.DecodedFrame, codec: AirPlayMirrorVideoCodec) {
        let now = Date()
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            let firstFrame = self.currentFrame == nil
            self.currentFrame = frame.image
            self.receivedFrameCount += 1
            self.lastFrameReceivedAt = now
            self.lastFrameSize = frame.displaySize
            self.activeAirPlayVideoCodec = codec.diagnosticName
            self.h264DecoderStatus = "decoded AirPlay \(codec == .hevc ? "HEVC" : "H.264") frame"
            self.statusMessage = "AirPlay receiving video"
            self.lastStaleDecisionBranch = nil
            self.recordFPSFrame(now: now)
            self.streamHealth = .receivingVideo
            if firstFrame {
                let advertised = self.advertisedDisplaySize
                let advertisedText = "\(Int(advertised.width))x\(Int(advertised.height))"
                let decodedText = "\(Int(frame.displaySize.width))x\(Int(frame.displaySize.height))"
                let matchedAdvertisedEdge = Self.matchesAdvertisedEdge(
                    source: frame.displaySize,
                    advertisedWidth: Int(advertised.width),
                    advertisedHeight: Int(advertised.height)
                )
                airPlayLog.info("[AirPlayQuality] first decoded frame codec=\(codec.diagnosticName, privacy: .public) quality=\(self.advertisedAirPlayQuality, privacy: .public) advertised=\(advertisedText, privacy: .public) decoded=\(decodedText, privacy: .public) matchedAdvertisedEdge=\(matchedAdvertisedEdge)")
                let pixelDiagnostics = AirPlayFramePixelDiagnostics.describe(
                    image: frame.image,
                    header: frame.header,
                    bufferSize: frame.bufferSize,
                    cropSource: frame.displayCropSource
                )
                airPlayLog.info("[AirPlayFramePixels] first published frame codec=\(codec.diagnosticName, privacy: .public) \(pixelDiagnostics, privacy: .public)")
            }
        }
    }

    private func logAirPlayQualityNegotiation(
        packet: AirPlayMirrorPacket,
        codec: AirPlayMirrorVideoCodec,
        displayConfiguration: AirPlayReceiverDisplayConfiguration,
        payloadBytes: Int
    ) {
        let sourceText = Self.dimensionText(packet.sourceDimensions)
        let renderText = Self.dimensionText(packet.renderDimensions)
        let optionText = String(format: "0x%04X", packet.payloadOption)
        let matchedAdvertisedEdge = Self.matchesAdvertisedEdge(
            source: packet.sourceDimensions,
            advertisedWidth: displayConfiguration.width,
            advertisedHeight: displayConfiguration.height
        )
        airPlayLog.info("[AirPlayQuality] config negotiated codec=\(codec.diagnosticName, privacy: .public) advertised=\(displayConfiguration.diagnosticDescription, privacy: .public) screenMultiCodec=\(displayConfiguration.supportsScreenMultiCodec) source=\(sourceText, privacy: .public) render=\(renderText, privacy: .public) option=\(optionText, privacy: .public) payloadBytes=\(payloadBytes) matchedAdvertisedEdge=\(matchedAdvertisedEdge)")
    }

    private func recordVideoQualitySample(packet: AirPlayMirrorPacket, payloadBytes: Int) {
        let now = CACurrentMediaTime()
        if videoQualitySampleStartedAt == nil {
            videoQualitySampleStartedAt = now
        }
        videoQualitySamplePayloadBytes += payloadBytes
        videoQualitySamplePacketCount += 1
        if packet.isIDRVideoPayload {
            videoQualitySampleIDRPacketCount += 1
        }

        guard let startedAt = videoQualitySampleStartedAt else { return }
        let elapsed = now - startedAt
        guard elapsed >= videoQualitySampleIntervalSeconds else { return }

        let bitrateMbps = (Double(videoQualitySamplePayloadBytes) * 8.0) / max(elapsed, 0.001) / 1_000_000.0
        let averagePacketKB = Double(videoQualitySamplePayloadBytes) / Double(max(videoQualitySamplePacketCount, 1)) / 1024.0
        airPlayLog.info("[AirPlayQuality] video sample codec=\(self.negotiatedMirrorVideoCodec.diagnosticName, privacy: .public) intervalMs=\(String(format: "%.0f", elapsed * 1000.0), privacy: .public) packets=\(self.videoQualitySamplePacketCount) bytes=\(self.videoQualitySamplePayloadBytes) bitrateMbps=\(String(format: "%.2f", bitrateMbps), privacy: .public) avgPacketKB=\(String(format: "%.1f", averagePacketKB), privacy: .public) idrPackets=\(self.videoQualitySampleIDRPacketCount)")

        videoQualitySampleStartedAt = now
        videoQualitySamplePayloadBytes = 0
        videoQualitySamplePacketCount = 0
        videoQualitySampleIDRPacketCount = 0
    }

    private func resetVideoQualitySampleCounters() {
        videoQualitySampleStartedAt = nil
        videoQualitySamplePayloadBytes = 0
        videoQualitySamplePacketCount = 0
        videoQualitySampleIDRPacketCount = 0
    }

    private static func dimensionText(_ size: CGSize?) -> String {
        guard let size else { return "nil" }
        return "\(Int(size.width.rounded()))x\(Int(size.height.rounded()))"
    }

    private static func matchesAdvertisedEdge(
        source: CGSize?,
        advertisedWidth: Int,
        advertisedHeight: Int
    ) -> Bool {
        guard let source else { return false }
        let sourceWidth = Int(source.width.rounded())
        let sourceHeight = Int(source.height.rounded())
        return sourceWidth == advertisedWidth
            || sourceWidth == advertisedHeight
            || sourceHeight == advertisedWidth
            || sourceHeight == advertisedHeight
    }

    private func clearDecodedVideoStateOnMain(reason: String) {
        let framePresent = currentFrame != nil
        let timestampCount = fpsFrameTimestamps.count
        let lastFrameSizeDescription = lastFrameSize.map { "\($0.width)x\($0.height)" } ?? "nil"
        airPlayLog.info("[AirPlayManager] clearing decoded video state reason=\(reason, privacy: .public) framePresent=\(framePresent) currentFPS=\(self.currentFPS) fpsSamples=\(timestampCount) lastFrameSize=\(lastFrameSizeDescription, privacy: .public)")
        resetVideoQualitySampleCounters()
        currentFrame = nil
        currentFPS = 0
        fpsFrameTimestamps.removeAll()
        lastFrameReceivedAt = nil
        lastFrameSize = nil
    }

    private func stopAudioStream(reason: String) {
        guard audioSinkServer != nil || audioDataPort != nil || audioControlPort != nil || pendingAudioPlaybackStream != nil else {
            airPlayLog.info("[AirPlayTeardown] audio branch=NO_ACTIVE_AUDIO reason=\(reason, privacy: .public)")
            publishMediaPlaybackStatus("audio teardown ignored; no active audio stream")
            return
        }

        airPlayLog.info("[AirPlayTeardown] audio branch=STOP_STREAM reason=\(reason, privacy: .public) dataPort=\(self.audioDataPort.map(String.init) ?? "nil", privacy: .public) controlPort=\(self.audioControlPort.map(String.init) ?? "nil", privacy: .public) pendingPlayback=\(self.pendingAudioPlaybackStream != nil)")
        audioSinkServer?.stop(reason: reason)
        audioSinkServer = nil
        pendingAudioPlaybackStream = nil
        audioReadyCompletions.removeAll()
        audioFailureCompletions.removeAll()
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.audioDataPort = nil
            self.audioControlPort = nil
            self.audioPlaybackStatus = "off"
            self.audioPlaybackPacketCount = 0
            self.audioPlaybackDecodedPacketCount = 0
            self.audioPlaybackDroppedPacketCount = 0
            self.audioPlaybackBufferedMilliseconds = 0
            self.audioPlaybackLastDropReason = nil
            self.mediaPlaybackStatus = "audio stream stopped"
        }
    }

    private func stopMirrorStream(reason: String) {
        guard mirrorDataServer != nil || mirrorDataPort != nil else {
            airPlayLog.info("[AirPlayTeardown] mirror branch=NO_ACTIVE_MIRROR reason=\(reason, privacy: .public)")
            publishMediaPlaybackStatus("mirror teardown ignored; no active mirror stream")
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                guard self.currentFrame != nil else {
                    airPlayLog.info("[AirPlayTeardown] mirror UI branch=NO_ACTIVE_MIRROR_NO_FRAME reason=\(reason, privacy: .public)")
                    return
                }
                airPlayLog.info("[AirPlayTeardown] mirror UI branch=NO_ACTIVE_MIRROR_CLEAR_STALE_FRAME reason=\(reason, privacy: .public)")
                self.clearDecodedVideoStateOnMain(reason: "no active mirror teardown: \(reason)")
                self.h264DecoderStatus = "mirror stream stopped"
                self.activeAirPlayVideoCodec = AirPlayMirrorVideoCodec.unknown.diagnosticName
                self.mediaPlaybackStatus = "mirror stream stopped"
                self.streamHealth = self.isAdvertising ? .waitingForPhone : .disconnected(reason: reason)
                self.statusMessage = self.isAdvertising ? "AirPlay waiting for iPhone" : "AirPlay mirror stopped"
            }
            return
        }

        airPlayLog.info("[AirPlayTeardown] mirror branch=STOP_STREAM reason=\(reason, privacy: .public) dataPort=\(self.mirrorDataPort.map(String.init) ?? "nil", privacy: .public) packets=\(self.mirrorPacketCount)")
        mirrorDataServer?.stop(reason: reason)
        mirrorDataServer = nil
        mirrorReadyCompletions.removeAll()
        mirrorFailureCompletions.removeAll()
        h264Adapter.reset()
        hevcAdapter.reset()
        negotiatedMirrorVideoCodec = .unknown
        h264Decoder.reset(reason: "AirPlay \(reason)")
        hevcDecoder.reset(reason: "AirPlay \(reason)")
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.mirrorDataPort = nil
            self.lastMirrorPacketReceivedAt = nil
            self.lastStaleDecisionBranch = nil
            self.clearDecodedVideoStateOnMain(reason: "mirror teardown: \(reason)")
            self.h264DecoderStatus = "mirror stream stopped"
            self.activeAirPlayVideoCodec = AirPlayMirrorVideoCodec.unknown.diagnosticName
            self.mediaPlaybackStatus = "mirror stream stopped"
            let nextHealth: AirPlayStreamHealth = self.isAdvertising ? .waitingForPhone : .disconnected(reason: reason)
            airPlayLog.info("[AirPlayTeardown] mirror UI branch=CLEAR_VIDEO_STATE reason=\(reason, privacy: .public) audioActive=\(self.audioSinkServer != nil) nextHealth=\(nextHealth.diagnosticDescription, privacy: .public)")
            self.streamHealth = nextHealth
            self.statusMessage = self.isAdvertising ? "AirPlay waiting for iPhone" : "AirPlay mirror stopped"
        }
    }

    private func handleAirPlaySessionTeardown(reason: String) {
        let preservePINPairing = pairingSession.shouldPreservePINOnControlDisconnect
        let pairingPhase = pairingSession.phase.diagnosticDescription
        airPlayLog.info("[AirPlayManager] session teardown reason=\(reason, privacy: .public) pairingPhase=\(pairingPhase, privacy: .public) preservePINPairing=\(preservePINPairing)")
        timingServer?.stop(reason: reason)
        timingServer = nil
        activeTimingPort = nil
        controlClientHost = nil
        timingReadyCompletions.removeAll()
        timingFailureCompletions.removeAll()
        mirrorDataServer?.stop(reason: reason)
        mirrorDataServer = nil
        audioSinkServer?.stop(reason: reason)
        audioSinkServer = nil
        audioReadyCompletions.removeAll()
        audioFailureCompletions.removeAll()

        if preservePINPairing {
            airPlayLog.info("[AirPlayManager] session teardown branch=PRESERVE_PIN_PAIRING reason=\(reason, privacy: .public)")
            resetMediaStatePreservingPairing(reason: reason)
        } else {
            airPlayLog.info("[AirPlayManager] session teardown branch=RESET_FULL_SESSION reason=\(reason, privacy: .public)")
            resetSessionState(reason: reason)
        }

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.isClientConnected = false
            self.currentClientDescription = nil
            self.timingPort = nil
            self.mirrorDataPort = nil
            self.audioDataPort = nil
            self.audioControlPort = nil
            self.audioPlaybackStatus = "off"
            self.audioPlaybackPacketCount = 0
            self.audioPlaybackDecodedPacketCount = 0
            self.audioPlaybackDroppedPacketCount = 0
            self.audioPlaybackBufferedMilliseconds = 0
            self.audioPlaybackLastDropReason = nil
            self.mediaPlaybackStatus = "idle"
            self.clearDecodedVideoStateOnMain(reason: "session teardown: \(reason)")
            if preservePINPairing {
                airPlayLog.info("[AirPlayManager] teardown UI branch=PRESERVE_PIN_PAIRING reason=\(reason, privacy: .public) pinVisible=\(self.currentPairingPIN != nil)")
                self.statusMessage = "AirPlay PIN required"
                self.streamHealth = .pairing
            } else if let lastError = self.lastError {
                airPlayLog.info("[AirPlayManager] teardown UI branch=PRESERVE_ERROR reason=\(reason, privacy: .public) error=\(lastError, privacy: .public)")
                self.clearCurrentPairingPINOnMain(trigger: "session teardown preserve error: \(reason)", force: true)
                self.statusMessage = lastError
                self.streamHealth = .failed(reason: lastError)
            } else if self.isAdvertising {
                airPlayLog.info("[AirPlayManager] teardown UI branch=RETURN_TO_WAITING reason=\(reason, privacy: .public)")
                self.clearCurrentPairingPINOnMain(trigger: "session teardown return to waiting: \(reason)", force: true)
                self.statusMessage = "AirPlay waiting for iPhone"
                self.streamHealth = .waitingForPhone
            } else {
                airPlayLog.info("[AirPlayManager] teardown UI branch=CLEAR_PIN reason=\(reason, privacy: .public)")
                self.clearCurrentPairingPINOnMain(trigger: "session teardown disconnected: \(reason)", force: true)
                self.statusMessage = "AirPlay waiting for iPhone"
                self.streamHealth = .disconnected(reason: reason)
            }
        }
    }

    private func resetSessionState(reason: String) {
        airPlayLog.info("[AirPlayManager] reset session state reason=\(reason, privacy: .public)")
        pairingSession.reset(reason: reason)
        fairPlaySession.reset(reason: reason)
        pendingAudioPlaybackStream = nil
        lastMediaSetPropertyPayload = nil
        publishFairPlayStatus(trigger: "reset session \(reason)")
        h264Adapter.reset()
        hevcAdapter.reset()
        negotiatedMirrorVideoCodec = .unknown
        h264Decoder.reset(reason: "AirPlay \(reason)")
        hevcDecoder.reset(reason: "AirPlay \(reason)")
        DispatchQueue.main.async { [weak self] in
            airPlayLog.info("[AirPlayManager] reset UI pairing PIN reason=\(reason, privacy: .public)")
            guard let self else { return }
            self.clearCurrentPairingPINOnMain(trigger: "reset session: \(reason)", force: true)
            self.lastMirrorPacketReceivedAt = nil
            self.lastStaleDecisionBranch = nil
            self.clearDecodedVideoStateOnMain(reason: "session reset: \(reason)")
            self.activeAirPlayVideoCodec = AirPlayMirrorVideoCodec.unknown.diagnosticName
            self.mediaPlaybackStatus = "idle"
        }
    }

    private func resetMediaStatePreservingPairing(reason: String) {
        airPlayLog.info("[AirPlayManager] reset media state preserving pairing reason=\(reason, privacy: .public)")
        fairPlaySession.reset(reason: reason)
        pendingAudioPlaybackStream = nil
        lastMediaSetPropertyPayload = nil
        publishFairPlayStatus(trigger: "reset media \(reason)")
        h264Adapter.reset()
        hevcAdapter.reset()
        negotiatedMirrorVideoCodec = .unknown
        h264Decoder.reset(reason: "AirPlay \(reason)")
        hevcDecoder.reset(reason: "AirPlay \(reason)")
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.clearDecodedVideoStateOnMain(reason: "media reset preserving pairing: \(reason)")
            self.activeAirPlayVideoCodec = AirPlayMirrorVideoCodec.unknown.diagnosticName
            self.mediaPlaybackStatus = "idle"
        }
    }

    private func publishStatus(_ message: String) {
        DispatchQueue.main.async { [weak self] in
            self?.statusMessage = message
        }
    }

    private func publishMediaPlaybackStatus(_ message: String) {
        airPlayLog.info("[AirPlayMedia] status=\(message, privacy: .public)")
        DispatchQueue.main.async { [weak self] in
            self?.mediaPlaybackStatus = message
        }
    }

    private func publishH264DumpStatus(trigger: String) {
        guard let h264DumpWriter else {
            airPlayLog.debug("[AirPlayH264Dump] status skipped trigger=\(trigger, privacy: .public) reason=disabled")
            return
        }
        let path = h264DumpWriter.filePath
        let bytes = h264DumpWriter.byteCount
        airPlayLog.info("[AirPlayH264Dump] status trigger=\(trigger, privacy: .public) path=\(path, privacy: .public) bytes=\(bytes)")
        DispatchQueue.main.async { [weak self] in
            self?.h264DumpPath = path
            self?.h264DumpBytes = bytes
        }
    }

    private func publishFairPlayStatus(trigger: String) {
        let providerStatus = fairPlaySession.providerDiagnosticDescription
        let phaseStatus = fairPlaySession.phase.diagnosticDescription
        airPlayLog.info("[AirPlayFairPlay] status trigger=\(trigger, privacy: .public) provider=\(providerStatus, privacy: .public) phase=\(phaseStatus, privacy: .public)")
        DispatchQueue.main.async { [weak self] in
            self?.fairPlayProviderStatus = providerStatus
            self?.fairPlayPhaseStatus = phaseStatus
        }
    }

    private func publishHealth(_ health: AirPlayStreamHealth, trigger: String) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            guard self.streamHealth != health else {
                airPlayLog.info("[AirPlayHealth] unchanged health=\(health.diagnosticDescription, privacy: .public) trigger=\(trigger, privacy: .public)")
                return
            }
            airPlayLog.info("[AirPlayHealth] transition from=\(self.streamHealth.diagnosticDescription, privacy: .public) to=\(health.diagnosticDescription, privacy: .public) trigger=\(trigger, privacy: .public)")
            self.streamHealth = health
        }
    }

    private func publishError(_ reason: String, trigger: String) {
        airPlayLog.error("[AirPlayError] trigger=\(trigger, privacy: .public) reason=\(reason, privacy: .public)")
        DispatchQueue.main.async { [weak self] in
            self?.lastError = reason
            self?.statusMessage = reason
            self?.streamHealth = .failed(reason: reason)
        }
    }

    private func startTimers() {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            if self.fpsTimer == nil {
                self.fpsTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
                    self?.updateFPS()
                }
            }
            if self.staleTimer == nil {
                self.staleTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
                    self?.updateStaleState()
                }
            }
        }
    }

    private func recordFPSFrame(now: Date) {
        fpsFrameTimestamps.append(now)
        fpsFrameTimestamps.removeAll { now.timeIntervalSince($0) > 1.0 }
        currentFPS = Double(fpsFrameTimestamps.count)
    }

    private func updateFPS() {
        let now = Date()
        fpsFrameTimestamps.removeAll { now.timeIntervalSince($0) > 1.0 }
        let nextFPS = Double(fpsFrameTimestamps.count)
        if abs(currentFPS - nextFPS) > 0.1 {
            airPlayLog.info("[AirPlayFPS] update previous=\(self.currentFPS) next=\(nextFPS) frames=\(self.receivedFrameCount)")
        }
        currentFPS = nextFPS
    }

    private func updateStaleState() {
        guard streamHealth.allowsFrameStalenessEvaluation else {
            logStaleDecision(branch: "NOT_ACTIVE_VIDEO_SESSION")
            return
        }

        guard let lastFrameReceivedAt else {
            logStaleDecision(branch: "NO_FRAME_TIMESTAMP")
            return
        }

        let now = Date()
        let frameAge = now.timeIntervalSince(lastFrameReceivedAt)
        guard frameAge > staleFrameThresholdSeconds else {
            logStaleDecision(branch: "FRAME_FRESH", frameAge: frameAge)
            return
        }

        if let lastMirrorPacketReceivedAt {
            let mirrorPacketAge = now.timeIntervalSince(lastMirrorPacketReceivedAt)
            if mirrorPacketAge <= staleFrameThresholdSeconds {
                guard frameAge >= idleFrameOverlayThresholdSeconds else {
                    logStaleDecision(
                        branch: "MIRROR_ACTIVITY_WITHOUT_VIDEO_BELOW_IDLE_THRESHOLD",
                        frameAge: frameAge,
                        mirrorPacketAge: mirrorPacketAge
                    )
                    return
                }

                if case .videoIdle = streamHealth {
                    logStaleDecision(
                        branch: "AIRPLAY_VIDEO_IDLE_STILL_INFERRED",
                        frameAge: frameAge,
                        mirrorPacketAge: mirrorPacketAge
                    )
                } else {
                    let nextHealth = AirPlayStreamHealth.inferredHealthForStaleVideo(
                        lastFrameAge: frameAge,
                        mirrorPacketAge: mirrorPacketAge,
                        freshnessThreshold: staleFrameThresholdSeconds
                    )
                    airPlayLog.warning("[AirPlayHealth] video idle inferred branch=MIRROR_ACTIVITY_WITHOUT_VIDEO lastFrameAge=\(frameAge) mirrorPacketAge=\(mirrorPacketAge) staleThreshold=\(self.staleFrameThresholdSeconds) idleThreshold=\(self.idleFrameOverlayThresholdSeconds) nextHealth=\(nextHealth.diagnosticDescription, privacy: .public)")
                    streamHealth = nextHealth
                }
                statusMessage = "AirPlay idle"
                return
            }
            airPlayLog.warning("[AirPlayHealth] stale candidate branch=MIRROR_ACTIVITY_STALE lastFrameAge=\(frameAge) mirrorPacketAge=\(mirrorPacketAge) threshold=\(self.staleFrameThresholdSeconds)")
        } else {
            airPlayLog.warning("[AirPlayHealth] stale candidate branch=NO_MIRROR_ACTIVITY_TIMESTAMP lastFrameAge=\(frameAge) threshold=\(self.staleFrameThresholdSeconds)")
        }

        let mirrorPacketAge = lastMirrorPacketReceivedAt.map { now.timeIntervalSince($0) }
        let nextHealth = AirPlayStreamHealth.inferredHealthForStaleVideo(
            lastFrameAge: frameAge,
            mirrorPacketAge: mirrorPacketAge,
            freshnessThreshold: staleFrameThresholdSeconds
        )
        airPlayLog.warning("[AirPlayHealth] stale detected branch=NO_RECENT_FRAME_OR_MIRROR_ACTIVITY lastFrameAge=\(frameAge) mirrorPacketAge=\(mirrorPacketAge ?? -1) nextHealth=\(nextHealth.diagnosticDescription, privacy: .public)")
        streamHealth = nextHealth
        statusMessage = "AirPlay video stale"
    }

    private func logStaleDecision(
        branch: String,
        frameAge: TimeInterval? = nil,
        mirrorPacketAge: TimeInterval? = nil
    ) {
        guard lastStaleDecisionBranch != branch else { return }
        lastStaleDecisionBranch = branch
        let frameAgeText = frameAge.map { String(format: "%.3f", $0) } ?? "nil"
        let mirrorPacketAgeText = mirrorPacketAge.map { String(format: "%.3f", $0) } ?? "nil"
        airPlayLog.debug("[AirPlayHealth] stale check branch=\(branch, privacy: .public) health=\(self.streamHealth.diagnosticDescription, privacy: .public) lastFrameAge=\(frameAgeText, privacy: .public) mirrorPacketAge=\(mirrorPacketAgeText, privacy: .public) threshold=\(self.staleFrameThresholdSeconds)")
    }
}
