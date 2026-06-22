import SwiftUI

class AppSettings: ObservableObject {
    enum Keys {
        static let defaultDisplayMode = "defaultDisplayMode"
        static let screenshotFPS = "screenshotFPS"
        static let mjpegQuality = "mjpegQuality"
        static let mjpegScalingFactor = "mjpegScalingFactor"
        static let showDeviceBezel = "showDeviceBezel"
        static let alwaysOnTop = "alwaysOnTop"
        static let scrollSensitivity = "scrollSensitivity"
        static let clipboardSyncEnabled = "clipboardSyncEnabled"
        static let autoReconnect = "autoReconnect"
        static let bluetoothAutoConnect = "bluetoothAutoConnect"
        static let wdaPort = "wdaPort"
        static let h264ResolutionScale = "h264ResolutionScale"
        static let menuBarThumbnailWidth = "menuBarThumbnailWidth"
        static let autoUnlock = "autoUnlock"
        static let selectedTeamID = "selectedTeamID"
        static let onboardingStep = "onboardingStep"
        static let interactiveTutorialPhase = "interactiveTutorialPhase"
        static let easyMouseClutchMode = "easyMouseClutchMode"
        static let easyLiveMouse = "easyLiveMouse"
        static let easyHideLocalCursor = "easyHideLocalCursor"
        static let easyPointerSpikeEnabled = "easyPointerSpikeEnabled"
        static let easyPointerSpikeOverlayEnabled = "easyPointerSpikeOverlayEnabled"
        static let easyPointerSpikeTransportVariant = "easyPointerSpikeTransportVariant"
        static let easyTrackpadSwipeToDragEnabled = "easyTrackpadSwipeToDragEnabled"
        static let easyTrackpadSwipeToDragMode = "easyTrackpadSwipeToDragMode"
        static let easyPointerDefaultsMigrated = "easyPointerDefaultsMigrated"
        static let easyToolbarCommandOrder = "easyToolbarCommandOrder"
        static let easyToolbarVisibleCommandOrder = "easyToolbarVisibleCommandOrder"
        static let easyToolbarOverflowCommandOrder = "easyToolbarOverflowCommandOrder"
        static let easyToolbarStyle = "easyToolbarStyle"
        static let easyToolbarAlwaysVisible = "easyToolbarAlwaysVisible"
        static let easyFloatingToolbarAnchor = "easyFloatingToolbarAnchor"
        static let easyFloatingToolbarAllowsDragging = "easyFloatingToolbarAllowsDragging"
        static let easyShowFPSCounter = "easyShowFPSCounter"
        static let easyReplayKitH264TargetFPS = "easyReplayKitH264TargetFPS"
        static let easyAirPlayQuality = "easyAirPlayQuality"
        static let easyUSBTargetFPS = "easyUSBTargetFPS"
        static let easyAirPlayConnectionTutorialHidden = "easyAirPlayConnectionTutorialHidden"
        static let showDeveloperOptions = "showDeveloperOptions"
    }

    enum Defaults {
        static let bluetoothAutoConnect = true
        static let easyReplayKitH264TargetFPS: Double = 60
        static let easyAirPlayQuality = EasyAirPlayQuality.high
        static let easyUSBTargetFPS: Double = 60
        static let easyToolbarStyle = EasyToolbarStyle.floating
        static let easyToolbarAlwaysVisible = true
        static let easyFloatingToolbarAnchor = EasyFloatingToolbarAnchor.above
        static let easyFloatingToolbarAllowsDragging = true
        static let easyAirPlayConnectionTutorialHidden = false
        static let easyLiveMouse = false
        static let easyTrackpadSwipeToDragEnabled = false
        static let easyTrackpadSwipeToDragMode = EasyTrackpadSwipeToDragMode.live
    }

    static func bluetoothAutoConnectEnabled(defaults: UserDefaults = .standard) -> Bool {
        let storedValue = defaults.object(forKey: Keys.bluetoothAutoConnect)
        if let value = storedValue as? Bool {
            return value
        }
        if let value = storedValue as? NSNumber {
            return value.boolValue
        }
        return Defaults.bluetoothAutoConnect
    }

    enum Ranges {
        static let easyReplayKitH264TargetFPS: ClosedRange<Double> = 1...60
        static let easyUSBTargetFPS: ClosedRange<Double> = 0...60
    }

    static func sanitizedEasyReplayKitH264TargetFPS(_ value: Double) -> Double {
        guard value.isFinite else { return Defaults.easyReplayKitH264TargetFPS }
        let roundedValue = value.rounded()
        return min(
            max(roundedValue, Ranges.easyReplayKitH264TargetFPS.lowerBound),
            Ranges.easyReplayKitH264TargetFPS.upperBound
        )
    }

    static func sanitizedEasyUSBTargetFPS(_ value: Double) -> Double {
        guard value.isFinite else { return Defaults.easyUSBTargetFPS }
        let roundedValue = value.rounded()
        return min(
            max(roundedValue, Ranges.easyUSBTargetFPS.lowerBound),
            Ranges.easyUSBTargetFPS.upperBound
        )
    }

    enum EasyAirPlayQuality {
        static let high = "high"
        static let balanced = "balanced"
        static let allowedValues = [balanced, high]

        static func label(for value: String) -> String {
            switch sanitized(value) {
            case high:
                return "High"
            case balanced:
                return "Balanced"
            default:
                return "High"
            }
        }

        static func sanitized(_ value: String?) -> String {
            guard let value, allowedValues.contains(value) else {
                return Defaults.easyAirPlayQuality
            }
            return value
        }
    }

    static func easyAirPlayDisplayPixels(for quality: String) -> (width: Int, height: Int) {
        switch EasyAirPlayQuality.sanitized(quality) {
        case EasyAirPlayQuality.high:
            return (width: 2560, height: 1440)
        case EasyAirPlayQuality.balanced:
            return (width: 1920, height: 1080)
        default:
            return (width: 2560, height: 1440)
        }
    }

    enum EasyPointerSpikeTransport {
        static let absoluteMouse = "ABS-MOUSE"
        static let relativeClosedLoop = "REL-CL"
        static let defaultValue = absoluteMouse
    }

    enum EasyTrackpadSwipeToDragMode {
        static let live = "live"
        static let delayed = "delayed"
        static let allowedValues = [live, delayed]

        static func label(for value: String) -> String {
            switch sanitized(value) {
            case delayed:
                return "Delayed"
            case live:
                return "Live"
            default:
                return "Live"
            }
        }

        static func sanitized(_ value: String?) -> String {
            guard let value, allowedValues.contains(value) else {
                return live
            }
            return value
        }
    }

    enum EasyFloatingToolbarAnchor {
        static let above = "above"
        static let below = "below"
        static let allowedValues = [above, below]

        static func label(for value: String) -> String {
            switch sanitized(value) {
            case below:
                return "Below"
            case above:
                return "Above"
            default:
                return "Above"
            }
        }

        static func sanitized(_ value: String?) -> String {
            guard let value, allowedValues.contains(value) else {
                return above
            }
            return value
        }
    }

    enum EasyToolbarStyle {
        static let floating = "floating"
        static let standard = "standard"
        static let allowedValues = [floating]

        static func label(for value: String) -> String {
            switch sanitized(value) {
            case floating:
                return "Floating"
            default:
                return "Floating"
            }
        }

        static func sanitized(_ value: String?) -> String {
            guard let value, allowedValues.contains(value) else {
                return floating
            }
            return value
        }
    }

    @AppStorage(Keys.defaultDisplayMode) var defaultDisplayMode: String = DisplayMode.auto.rawValue
    @AppStorage(Keys.screenshotFPS) var screenshotFPS: Double = 10
    /// MJPEG quality sent to WDA (1–100). Lower = faster encoding, higher = sharper.
    @AppStorage(Keys.mjpegQuality) var mjpegQuality: Int = 50
    /// MJPEG scaling factor (25–100%). Lower = fewer pixels to encode = higher FPS.
    @AppStorage(Keys.mjpegScalingFactor) var mjpegScalingFactor: Int = 100
    @AppStorage(Keys.showDeviceBezel) var showDeviceBezel: Bool = false
    @AppStorage(Keys.alwaysOnTop) var alwaysOnTop: Bool = false
    @AppStorage(Keys.scrollSensitivity) var scrollSensitivity: Double = 8.0
    @AppStorage(Keys.clipboardSyncEnabled) var clipboardSyncEnabled: Bool = true
    @AppStorage(Keys.autoReconnect) var autoReconnect: Bool = true
    /// Automatically connect Bluetooth HID input to the saved app-paired device after Easy video/Bluetooth starts.
    @AppStorage(Keys.bluetoothAutoConnect) var bluetoothAutoConnect: Bool = Defaults.bluetoothAutoConnect
    @AppStorage(Keys.wdaPort) var wdaPort: Int = 8100
    /// H.264 resolution scale: 100 = full retina, 50 = half, etc.
    @AppStorage(Keys.h264ResolutionScale) var h264ResolutionScale: Int = 100
    /// Menu bar thumbnail width in points (200–600).
    @AppStorage(Keys.menuBarThumbnailWidth) var menuBarThumbnailWidth: Int = 480
    /// Auto-unlock device on connect using stored passcode.
    @AppStorage(Keys.autoUnlock) var autoUnlock: Bool = false
    /// Persisted team ID for WDA builds — avoids re-detection on every launch.
    @AppStorage(Keys.selectedTeamID) var selectedTeamID: String = ""
    /// Onboarding step: 0=welcome, 1=setup, 2=done (normal flow)
    @AppStorage(Keys.onboardingStep) var onboardingStep: Int = 0
    /// Easy mode: require right mouse button clutch before forwarding pointer movement.
    @AppStorage(Keys.easyMouseClutchMode) var easyMouseClutchMode: Bool = true
    /// Easy mode: forward mouse movement live while the Easy mirror window is focused.
    @AppStorage(Keys.easyLiveMouse) var easyLiveMouse: Bool = Defaults.easyLiveMouse
    /// Easy mode: hide the local macOS cursor while hovering the mirrored phone surface.
    @AppStorage(Keys.easyHideLocalCursor) var easyHideLocalCursor: Bool = false
    /// Easy mode: enable deterministic absolute pointer input.
    @AppStorage(Keys.easyPointerSpikeEnabled) var easyPointerSpikeEnabled: Bool = true
    /// Easy mode: show on-screen expected vs actual markers while the spike harness is active.
    @AppStorage(Keys.easyPointerSpikeOverlayEnabled) var easyPointerSpikeOverlayEnabled: Bool = false
    /// Easy mode: active HID report strategy for pointer determinism testing.
    @AppStorage(Keys.easyPointerSpikeTransportVariant) var easyPointerSpikeTransportVariant: String = EasyPointerSpikeTransport.defaultValue
    /// Easy mode experiment: convert horizontal precise trackpad scrolls into iPhone drag gestures.
    @AppStorage(Keys.easyTrackpadSwipeToDragEnabled) var easyTrackpadSwipeToDragEnabled: Bool = Defaults.easyTrackpadSwipeToDragEnabled
    /// Easy mode experiment: send trackpad swipes live or after the touchpad gesture ends.
    @AppStorage(Keys.easyTrackpadSwipeToDragMode) var easyTrackpadSwipeToDragMode: String = Defaults.easyTrackpadSwipeToDragMode
    /// Easy mode: legacy ordered toolbar command identifiers. Used to migrate older toolbar settings.
    @AppStorage(Keys.easyToolbarCommandOrder) var easyToolbarCommandOrder: String = EasyToolbarCommand.defaultOrderStorageValue
    /// Easy mode: ordered toolbar command identifiers that should stay visible, capped by EasyToolbarCommandLayout.
    @AppStorage(Keys.easyToolbarVisibleCommandOrder) var easyToolbarVisibleCommandOrder: String = EasyToolbarCommand.defaultVisibleOrderStorageValue
    /// Easy mode: ordered toolbar command identifiers that should live in the overflow menu.
    @AppStorage(Keys.easyToolbarOverflowCommandOrder) var easyToolbarOverflowCommandOrder: String = EasyToolbarCommand.defaultOverflowOrderStorageValue
    /// Easy mode: toolbar presentation style, either external floating panel or standard in-window header.
    @AppStorage(Keys.easyToolbarStyle) var easyToolbarStyle: String = Defaults.easyToolbarStyle
    /// Easy mode: keep the presentation toolbar visible instead of revealing it only near the top edge.
    @AppStorage(Keys.easyToolbarAlwaysVisible) var easyToolbarAlwaysVisible: Bool = Defaults.easyToolbarAlwaysVisible
    /// Easy mode: side of the mirror window used to anchor the external floating toolbar panel.
    @AppStorage(Keys.easyFloatingToolbarAnchor) var easyFloatingToolbarAnchor: String = Defaults.easyFloatingToolbarAnchor
    /// Easy mode: allow users to drag the external floating toolbar panel away from its anchor.
    @AppStorage(Keys.easyFloatingToolbarAllowsDragging) var easyFloatingToolbarAllowsDragging: Bool = Defaults.easyFloatingToolbarAllowsDragging
    /// Easy mode: show the live FPS count in the bottom status bar.
    @AppStorage(Keys.easyShowFPSCounter) var easyShowFPSCounter: Bool = false
    /// Easy mode: ReplayKit H.264 frame gate target advertised to the broadcast extension.
    @AppStorage(Keys.easyReplayKitH264TargetFPS) var easyReplayKitH264TargetFPS: Double = Defaults.easyReplayKitH264TargetFPS
    /// Easy mode: AirPlay virtual display quality advertised during receiver info negotiation.
    @AppStorage(Keys.easyAirPlayQuality) var easyAirPlayQuality: String = Defaults.easyAirPlayQuality
    /// Easy mode: native USB screen capture frame publish target.
    @AppStorage(Keys.easyUSBTargetFPS) var easyUSBTargetFPS: Double = Defaults.easyUSBTargetFPS
    /// Easy mode: hide the AirPlay connection tutorial after the user opts out.
    @AppStorage(Keys.easyAirPlayConnectionTutorialHidden) var easyAirPlayConnectionTutorialHidden: Bool = Defaults.easyAirPlayConnectionTutorialHidden
    /// Reveal development-only controls in Settings.
    @AppStorage(Keys.showDeveloperOptions) var showDeveloperOptions: Bool = false
}
