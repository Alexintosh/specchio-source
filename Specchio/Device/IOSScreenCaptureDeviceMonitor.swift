import AVFoundation
import CoreMedia
import CoreMediaIO
import Foundation

enum IOSScreenCaptureAvailability: Equatable {
    case unknown
    case unavailable(reason: String)
    case available(deviceName: String, uniqueID: String, mediaType: String)

    var diagnosticDescription: String {
        switch self {
        case .unknown:
            return "unknown"
        case .unavailable(let reason):
            return "unavailable(reason=\(reason))"
        case .available(let deviceName, let uniqueID, let mediaType):
            return "available(name=\(deviceName), uniqueID=\(uniqueID), mediaType=\(mediaType))"
        }
    }
}

struct IOSScreenCaptureDeviceDescriptor: Identifiable, Equatable {
    let device: AVCaptureDevice
    let mediaType: AVMediaType
    let localizedName: String
    let uniqueID: String
    let modelID: String
    let manufacturer: String
    let formatsCount: Int
    let formatSignatures: [String]
    let hasEmbeddedDeviceScreenRecordingFormat: Bool
    let selectionScore: Int
    let selectionReason: String

    var id: String {
        "\(uniqueID)|\(mediaType.rawValue)"
    }

    var mediaTypeName: String {
        mediaType == .muxed ? "muxed" : mediaType.rawValue
    }

    var isLikelyIOSScreenCapture: Bool {
        selectionScore > 0
    }

    var transportInference: String {
        if isLikelyIOSScreenCapture {
            return "embedded-device-screen-recording"
        }

        if mediaType == .muxed {
            return "external-muxed-not-embedded-screen-recording"
        }

        return "external-video-not-screen-recording"
    }

    var logSummary: String {
        "media=\(mediaType.rawValue) name=\(localizedName) uniqueID=\(uniqueID) modelID=\(modelID) manufacturer=\(manufacturer) transport=\(transportInference) formats=\(formatsCount) formatSignatures=\(formatSignatures.joined(separator: ",")) score=\(selectionScore) reason=\(selectionReason)"
    }

    static func == (lhs: IOSScreenCaptureDeviceDescriptor, rhs: IOSScreenCaptureDeviceDescriptor) -> Bool {
        lhs.mediaType == rhs.mediaType
            && lhs.localizedName == rhs.localizedName
            && lhs.uniqueID == rhs.uniqueID
            && lhs.modelID == rhs.modelID
            && lhs.manufacturer == rhs.manufacturer
            && lhs.formatsCount == rhs.formatsCount
            && lhs.formatSignatures == rhs.formatSignatures
            && lhs.hasEmbeddedDeviceScreenRecordingFormat == rhs.hasEmbeddedDeviceScreenRecordingFormat
            && lhs.selectionScore == rhs.selectionScore
            && lhs.selectionReason == rhs.selectionReason
    }
}

final class IOSScreenCaptureDeviceMonitor: ObservableObject {
    @Published private(set) var discoveredDevices: [IOSScreenCaptureDeviceDescriptor] = []
    @Published private(set) var selectedDevice: IOSScreenCaptureDeviceDescriptor?
    @Published private(set) var availability: IOSScreenCaptureAvailability = .unknown
    @Published private(set) var diagnosticReason = "Discovery has not run yet"

    private var notificationTokens: [NSObjectProtocol] = []

    init() {
        SpecchioLogger.iosScreenCapture.info("[DeviceMonitor] initializing")
        Self.enableCoreMediaIOScreenCaptureDevices(trigger: "monitor init")
        startMonitoring()
    }

    deinit {
        for token in notificationTokens {
            NotificationCenter.default.removeObserver(token)
        }
    }

    func refreshDevices(trigger: String = "manual refresh") {
        SpecchioLogger.iosScreenCapture.info("[DeviceMonitor] discovery started trigger=\(trigger, privacy: .public)")
        let devices = Self.discoverDevices(trigger: trigger)
        let selected = Self.selectBestDevice(from: devices, trigger: trigger)

        discoveredDevices = devices
        selectedDevice = selected

        if let selected {
            availability = .available(
                deviceName: selected.localizedName,
                uniqueID: selected.uniqueID,
                mediaType: selected.mediaType.rawValue
            )
            diagnosticReason = "Selected \(selected.localizedName) because \(selected.selectionReason)"
            SpecchioLogger.iosScreenCapture.info("[DeviceMonitor] availability=available selected=\(selected.logSummary, privacy: .public)")
        } else if devices.isEmpty {
            availability = .unavailable(reason: "No external .muxed or .video AVCaptureDevice was discovered")
            diagnosticReason = "No external capture devices discovered"
            SpecchioLogger.iosScreenCapture.info("[DeviceMonitor] availability=unavailable reason=no-external-devices")
        } else {
            availability = .unavailable(reason: "External devices found, but none exposed CoreMedia embedded device screen recording")
            diagnosticReason = "No external device exposed kCMMuxedStreamType_EmbeddedDeviceScreenRecording"
            SpecchioLogger.iosScreenCapture.info("[DeviceMonitor] availability=unavailable reason=no-ios-candidate count=\(devices.count)")
        }
    }

    static func enableCoreMediaIOScreenCaptureDevices(trigger: String) {
        SpecchioLogger.iosScreenCapture.info("[CMIO] enabling screen capture devices trigger=\(trigger, privacy: .public)")
        setCMIOFlag(
            selector: CMIOObjectPropertySelector(kCMIOHardwarePropertyAllowScreenCaptureDevices),
            name: "AllowScreenCaptureDevices"
        )
        setCMIOFlag(
            selector: CMIOObjectPropertySelector(kCMIOHardwarePropertyAllowWirelessScreenCaptureDevices),
            name: "AllowWirelessScreenCaptureDevices"
        )
    }

    static func discoverDevices(trigger: String) -> [IOSScreenCaptureDeviceDescriptor] {
        enableCoreMediaIOScreenCaptureDevices(trigger: "discovery \(trigger)")

        let mediaTypes: [AVMediaType] = [.muxed, .video]
        var candidates: [IOSScreenCaptureDeviceDescriptor] = []

        for mediaType in mediaTypes {
            SpecchioLogger.iosScreenCapture.info("[DeviceMonitor] discovery probing mediaType=\(mediaType.rawValue, privacy: .public) trigger=\(trigger, privacy: .public)")
            let discovery = AVCaptureDevice.DiscoverySession(
                deviceTypes: [.external],
                mediaType: mediaType,
                position: .unspecified
            )

            for device in discovery.devices {
                let descriptor = descriptor(for: device, mediaType: mediaType)
                candidates.append(descriptor)
                SpecchioLogger.iosScreenCapture.info("[DeviceMonitor] discovered \(descriptor.logSummary, privacy: .public)")
            }
        }

        let deduped = deduplicate(candidates)
            .sorted { lhs, rhs in
                if lhs.selectionScore != rhs.selectionScore {
                    return lhs.selectionScore > rhs.selectionScore
                }
                if lhs.mediaType != rhs.mediaType {
                    return lhs.mediaType == .muxed
                }
                return lhs.localizedName < rhs.localizedName
            }

        SpecchioLogger.iosScreenCapture.info("[DeviceMonitor] discovery completed trigger=\(trigger, privacy: .public) rawCount=\(candidates.count) dedupedCount=\(deduped.count)")
        return deduped
    }

    static func selectBestDevice(
        from devices: [IOSScreenCaptureDeviceDescriptor],
        trigger: String
    ) -> IOSScreenCaptureDeviceDescriptor? {
        guard let selected = devices.first(where: { $0.isLikelyIOSScreenCapture }) else {
            SpecchioLogger.iosScreenCapture.info("[DeviceMonitor] no selected device trigger=\(trigger, privacy: .public) reason=no-candidate")
            return nil
        }

        SpecchioLogger.iosScreenCapture.info("[DeviceMonitor] selected device trigger=\(trigger, privacy: .public) \(selected.logSummary, privacy: .public)")
        return selected
    }

    private func startMonitoring() {
        let center = NotificationCenter.default
        notificationTokens.append(center.addObserver(
            forName: .AVCaptureDeviceWasConnected,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            let device = notification.object as? AVCaptureDevice
            SpecchioLogger.iosScreenCapture.info("[DeviceMonitor] device connected name=\(device?.localizedName ?? "unknown", privacy: .public) uniqueID=\(device?.uniqueID ?? "unknown", privacy: .public) modelID=\(device?.modelID ?? "unknown", privacy: .public)")
            self?.refreshDevices(trigger: "AVCaptureDeviceWasConnected")
        })

        notificationTokens.append(center.addObserver(
            forName: .AVCaptureDeviceWasDisconnected,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            let device = notification.object as? AVCaptureDevice
            SpecchioLogger.iosScreenCapture.info("[DeviceMonitor] device disconnected name=\(device?.localizedName ?? "unknown", privacy: .public) uniqueID=\(device?.uniqueID ?? "unknown", privacy: .public) modelID=\(device?.modelID ?? "unknown", privacy: .public)")
            self?.refreshDevices(trigger: "AVCaptureDeviceWasDisconnected")
        })

        refreshDevices(trigger: "monitor start")
    }

    private static func setCMIOFlag(selector: CMIOObjectPropertySelector, name: String) {
        var property = CMIOObjectPropertyAddress(
            mSelector: selector,
            mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
            mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain)
        )
        var allow: UInt32 = 1
        let status = CMIOObjectSetPropertyData(
            CMIOObjectID(kCMIOObjectSystemObject),
            &property,
            0,
            nil,
            UInt32(MemoryLayout<UInt32>.size),
            &allow
        )

        if status == noErr {
            SpecchioLogger.iosScreenCapture.info("[CMIO] flag set name=\(name, privacy: .public) status=success")
        } else {
            SpecchioLogger.iosScreenCapture.error("[CMIO] flag set failed name=\(name, privacy: .public) status=\(status)")
        }
    }

    private static func descriptor(
        for device: AVCaptureDevice,
        mediaType: AVMediaType
    ) -> IOSScreenCaptureDeviceDescriptor {
        let formatSignatures = device.formats.map { formatSignature(for: $0.formatDescription) }
        let hasScreenRecordingFormat = device.formats.contains {
            isEmbeddedDeviceScreenRecordingFormat($0.formatDescription)
        }
        let selection = selectionScore(
            mediaType: mediaType,
            hasEmbeddedDeviceScreenRecordingFormat: hasScreenRecordingFormat
        )

        return IOSScreenCaptureDeviceDescriptor(
            device: device,
            mediaType: mediaType,
            localizedName: device.localizedName,
            uniqueID: device.uniqueID,
            modelID: device.modelID,
            manufacturer: device.manufacturer,
            formatsCount: device.formats.count,
            formatSignatures: formatSignatures,
            hasEmbeddedDeviceScreenRecordingFormat: hasScreenRecordingFormat,
            selectionScore: selection.score,
            selectionReason: selection.reason
        )
    }

    private static func selectionScore(
        mediaType: AVMediaType,
        hasEmbeddedDeviceScreenRecordingFormat: Bool
    ) -> (score: Int, reason: String) {
        if hasEmbeddedDeviceScreenRecordingFormat {
            return (
                100,
                "CoreMedia format includes kCMMuxedStreamType_EmbeddedDeviceScreenRecording"
            )
        }

        if mediaType == .muxed {
            return (
                0,
                "rejected: muxed external device lacks kCMMuxedStreamType_EmbeddedDeviceScreenRecording"
            )
        }

        return (
            0,
            "rejected: external video device is not CoreMedia embedded device screen recording"
        )
    }

    private static func isEmbeddedDeviceScreenRecordingFormat(
        _ description: CMFormatDescription
    ) -> Bool {
        CMFormatDescriptionGetMediaType(description) == kCMMediaType_Muxed
            && CMFormatDescriptionGetMediaSubType(description) == kCMMuxedStreamType_EmbeddedDeviceScreenRecording
    }

    private static func formatSignature(for description: CMFormatDescription) -> String {
        let mediaType = fourCharacterCodeString(CMFormatDescriptionGetMediaType(description))
        let mediaSubType = fourCharacterCodeString(CMFormatDescriptionGetMediaSubType(description))
        return "\(mediaType)/\(mediaSubType)"
    }

    private static func fourCharacterCodeString(_ code: FourCharCode) -> String {
        let bytes = [
            UInt8((code >> 24) & 0xff),
            UInt8((code >> 16) & 0xff),
            UInt8((code >> 8) & 0xff),
            UInt8(code & 0xff)
        ]
        return String(bytes: bytes, encoding: .macOSRoman) ?? String(code)
    }

    private static func deduplicate(
        _ candidates: [IOSScreenCaptureDeviceDescriptor]
    ) -> [IOSScreenCaptureDeviceDescriptor] {
        var byDeviceID: [String: IOSScreenCaptureDeviceDescriptor] = [:]

        for candidate in candidates {
            let key = candidate.uniqueID.isEmpty
                ? "\(candidate.localizedName)|\(candidate.modelID)|\(candidate.mediaType.rawValue)"
                : candidate.uniqueID

            guard let existing = byDeviceID[key] else {
                byDeviceID[key] = candidate
                continue
            }

            let candidateWins = candidate.selectionScore > existing.selectionScore
                || (candidate.selectionScore == existing.selectionScore && candidate.mediaType == .muxed)

            if candidateWins {
                SpecchioLogger.iosScreenCapture.info("[DeviceMonitor] dedupe selected replacement existing=\(existing.logSummary, privacy: .public) replacement=\(candidate.logSummary, privacy: .public)")
                byDeviceID[key] = candidate
            } else {
                SpecchioLogger.iosScreenCapture.info("[DeviceMonitor] dedupe kept existing existing=\(existing.logSummary, privacy: .public) dropped=\(candidate.logSummary, privacy: .public)")
            }
        }

        return Array(byDeviceID.values)
    }
}
