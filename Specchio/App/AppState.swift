import SwiftUI
import Combine

enum SpecchioVideoSourceKind: String, Equatable {
    case replayKit
    case airPlay
    case iosScreenCaptureUSB
    case screenshot
    case mjpeg
    case h264
    case none

    var displayName: String {
        switch self {
        case .replayKit:
            return "ReplayKit"
        case .airPlay:
            return "AirPlay"
        case .iosScreenCaptureUSB:
            return "USB Native"
        case .screenshot:
            return "Screenshot"
        case .mjpeg:
            return "MJPEG"
        case .h264:
            return "H.264"
        case .none:
            return "None"
        }
    }

    var diagnosticName: String {
        rawValue
    }

    var statusColor: Color {
        switch self {
        case .iosScreenCaptureUSB:
            return .cyan
        case .replayKit:
            return .green
        case .airPlay:
            return .indigo
        case .h264, .mjpeg, .screenshot:
            return .green
        case .none:
            return .secondary
        }
    }
}

@MainActor
class AppState: ObservableObject {
    let licenseManager = LicenseManager.shared

    @Published var connectionState: ConnectionState = .disconnected
    @Published var displayMode: DisplayMode = .auto
    @Published var phoneScreenSize: CGSize = CGSize(width: 390, height: 844)
    @Published var lastScreenshot: NSImage?
    @Published var accessibilityTree: AccessibilityElement?
    @Published var errorMessage: String?
    @Published var isReconnecting: Bool = false
    @Published var reconnectBanner: String?
    @Published var inputWSConnected: Bool = false
    @Published var keyboardExtConnected: Bool = false

    var wdaClient: WDAClient?
    var inputSocket: WDAInputSocket?
    var keyboardExtSocket: KeyboardExtSocket?
    var phoneWiFiIP: String?
    @Published var macWiFiIP: String?
    @Published var screenshotStream: ScreenshotStreamManager?
    @Published var mjpegStream: MJPEGStreamManager?
    @Published var h264Stream: H264StreamManager?
    @Published var replayKitStream: ReplayKitScreenStreamManager?
    @Published var airPlayStream: AirPlayScreenStreamManager?
    @Published var iosScreenCaptureStream: IOSScreenCaptureManager?
    @Published var activeVideoSource: SpecchioVideoSourceKind = .none
    @Published var lastVideoFallbackReason: String?

    init() {
        FrameDropDiagnostics.shared.recordLifecycle(
            source: "app",
            event: "appStateInitialized",
            reason: "Mac app diagnostics ready",
            details: ["diagnosticsPath": FrameDropDiagnostics.latestLogPath]
        )
    }

    func disconnect() {
        SpecchioLogger.easyMode.info("[AppStateDisconnect] requested activeSource=\(self.activeVideoSource.diagnosticName, privacy: .public) connectionState=\(String(describing: self.connectionState), privacy: .public) hasUSB=\(self.iosScreenCaptureStream != nil) hasAirPlay=\(self.airPlayStream != nil) hasReplayKit=\(self.replayKitStream != nil) hasInputSocket=\(self.inputSocket != nil) hasKeyboardExt=\(self.keyboardExtSocket != nil)")
        iosScreenCaptureStream?.stopCapture(reason: "AppState.disconnect", clearFrame: true)
        iosScreenCaptureStream = nil
        activeVideoSource = .none
        lastVideoFallbackReason = nil
        h264Stream?.stop()
        h264Stream = nil
        mjpegStream?.stop()
        mjpegStream = nil
        screenshotStream?.stop()
        screenshotStream = nil
        replayKitStream = nil
        airPlayStream?.stop()
        airPlayStream = nil
        inputSocket?.disconnect()
        inputSocket = nil
        inputWSConnected = false
        keyboardExtSocket?.stopListening()
        keyboardExtSocket = nil
        keyboardExtConnected = false
        wdaClient = nil
        phoneWiFiIP = nil
        connectionState = .disconnected
        lastScreenshot = nil
        accessibilityTree = nil
        errorMessage = nil
        isReconnecting = false
        reconnectBanner = nil
        SpecchioLogger.easyMode.info("[AppStateDisconnect] completed activeSource=\(self.activeVideoSource.diagnosticName, privacy: .public) connectionState=\(String(describing: self.connectionState), privacy: .public)")
    }
}
