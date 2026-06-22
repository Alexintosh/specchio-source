import SwiftUI
import AppKit

private enum EasyVideoPremiumGateMetrics {
    static let revealDelaySeconds: UInt64 = 5
    static let nanosecondsPerSecond: UInt64 = 1_000_000_000
    static let revealDelayNanoseconds = revealDelaySeconds * nanosecondsPerSecond
}

private enum EasyUSBIsolationTiming {
    static let readinessPollNanoseconds: UInt64 = 50_000_000
    static let readinessTimeoutSeconds: TimeInterval = 2.0
}

private enum EasyPremiumVideoGateSource: String, Equatable {
    case replayKit
    case airPlay
    case usbNative

    var logName: String {
        switch self {
        case .replayKit:
            return "ReplayKit"
        case .airPlay:
            return "AirPlay"
        case .usbNative:
            return "USB native"
        }
    }

    var fallbackReason: String {
        "\(logName) requires Premium"
    }

    var accessibilityLabel: String {
        "\(logName) Premium required"
    }

    static func make(from source: SpecchioVideoSourceKind) -> EasyPremiumVideoGateSource? {
        switch source {
        case .replayKit:
            return .replayKit
        case .airPlay:
            return .airPlay
        case .iosScreenCaptureUSB:
            return .usbNative
        case .screenshot, .mjpeg, .h264, .none:
            return nil
        }
    }
}

private enum EasyVideoSourceCardKind: String {
    case replayKit
    case airPlay
    case usbNative

    var logName: String {
        switch self {
        case .replayKit:
            return "ReplayKit"
        case .airPlay:
            return "AirPlay"
        case .usbNative:
            return "USB native"
        }
    }
}

private struct EasyVideoSourceCardState: Identifiable {
    let kind: EasyVideoSourceCardKind
    let title: String
    let status: String
    let detail: String
    let systemImage: String
    let dotColor: Color
    let isDisplayed: Bool
    let isDimmed: Bool
    let actionTitle: String
    let help: String

    var id: String {
        kind.rawValue
    }

    var accessibilityLabel: String {
        "\(title). \(status). \(detail)"
    }

    var logSummary: String {
        "kind=\(kind.rawValue) title=\(title) status=\(status) detail=\(detail) displayed=\(isDisplayed) dimmed=\(isDimmed) action=\(actionTitle)"
    }
}

struct EasyModeView: View {
    @ObservedObject var appState: AppState
    @ObservedObject var bluetoothHIDPanel: BluetoothHIDPanelController

    @AppStorage(AppSettings.Keys.easyMouseClutchMode) private var easyMouseClutchMode = true
    @AppStorage(AppSettings.Keys.easyHideLocalCursor) private var easyHideLocalCursor = false
    @AppStorage(AppSettings.Keys.easyPointerSpikeEnabled) private var easyPointerSpikeEnabled = true
    @AppStorage(AppSettings.Keys.easyPointerSpikeOverlayEnabled) private var easyPointerSpikeOverlayEnabled = false
    @AppStorage(AppSettings.Keys.easyPointerSpikeTransportVariant) private var pointerSpikeVariant = AppSettings.EasyPointerSpikeTransport.defaultValue
    @AppStorage(AppSettings.Keys.easyPointerDefaultsMigrated) private var easyPointerDefaultsMigrated = false
    @AppStorage(AppSettings.Keys.easyToolbarCommandOrder) private var easyToolbarCommandOrder = EasyToolbarCommand.defaultOrderStorageValue
    @AppStorage(AppSettings.Keys.easyToolbarVisibleCommandOrder) private var easyToolbarVisibleCommandOrder = EasyToolbarCommand.defaultVisibleOrderStorageValue
    @AppStorage(AppSettings.Keys.easyToolbarOverflowCommandOrder) private var easyToolbarOverflowCommandOrder = EasyToolbarCommand.defaultOverflowOrderStorageValue
    @AppStorage(AppSettings.Keys.easyReplayKitH264TargetFPS) private var easyReplayKitH264TargetFPS = AppSettings.Defaults.easyReplayKitH264TargetFPS
    @AppStorage(AppSettings.Keys.easyAirPlayQuality) private var easyAirPlayQuality = AppSettings.Defaults.easyAirPlayQuality
    @AppStorage(AppSettings.Keys.easyUSBTargetFPS) private var easyUSBTargetFPS = AppSettings.Defaults.easyUSBTargetFPS
    @AppStorage(AppSettings.Keys.bluetoothAutoConnect) private var bluetoothAutoConnect = AppSettings.Defaults.bluetoothAutoConnect
    @StateObject private var stream = ReplayKitScreenStreamManager()
    @StateObject private var airPlayStream = AirPlayScreenStreamManager()
    @StateObject private var iosScreenCapture = IOSScreenCaptureManager()
    @StateObject private var iosScreenCaptureMonitor = IOSScreenCaptureDeviceMonitor()
    @StateObject private var setupTutorial = SpecchioSetupTutorialWindowController()
    @ObservedObject private var licenseManager = LicenseManager.shared
    @State private var mouseLocation: CGPoint = .zero
    @State private var viewSize: CGSize = .zero
    @State private var phoneScreenSize: CGSize = CGSize(width: 390, height: 844)
    @State private var controlBarHeight: CGFloat = 0
    @State private var controlBarWidth: CGFloat = 0
    @State private var phoneSurfaceSize: CGSize = .zero
    @State private var phoneSurfaceAvailableSize: CGSize = .zero
    @State private var replayKitStartupTask: Task<Void, Never>?
    @State private var replayKitStartupGeneration = 0
    @State private var usbNativeIsolationStartupTask: Task<Void, Never>?
    @State private var isUSBNativeIsolationActive = false
    @State private var videoPremiumOverlaySource: EasyPremiumVideoGateSource?
    @State private var videoPremiumOverlayWasPresented = false
    @State private var videoPremiumOverlayTask: Task<Void, Never>?
    @State private var videoPremiumOverlayTaskSource: EasyPremiumVideoGateSource?
    @State private var replayKitPrivacyBlurEnabled = false
    @State private var showEasyShortcutHelp = false
    @State private var phoneDisplayRotationDegrees = 0
    @State private var isUSBNativeStartDeferred = false
    @State private var isEasyModeVisible = false
    @State private var dismissedRotationMismatchWarningKey: String?
    @State private var isPresentationHeaderRevealedByTopEdge = false
    @State private var isPresentationWindowKey = false
    @State private var isPresentationApplicationActive = false
    @State private var presentationHeaderNativeControlsLeadingPadding: CGFloat = 0
    @State private var bluetoothAutoConnectVideoStartAttemptedSources = Set<String>()
    @State private var selectedVideoSourceCardKind: EasyVideoSourceCardKind?
    private var replayKitUISnapshot: EasyReplayKitUISnapshot {
        EasyReplayKitUISnapshot.make(from: stream)
    }

    private var activeFrame: CGImage? {
        switch appState.activeVideoSource {
        case .iosScreenCaptureUSB:
            guard case .live = iosScreenCapture.streamHealth else {
                return nil
            }
            return iosScreenCapture.currentFrame
        case .airPlay:
            switch airPlayStream.streamHealth {
            case .receivingVideo, .screenOff:
                return airPlayStream.currentFrame
            default:
                return nil
            }
        case .replayKit, .none:
            guard case .live = stream.streamHealth else {
                return nil
            }
            return stream.currentFrame
        default:
            return nil
        }
    }

    private var replayKitPrivacyBlurVisible: Bool {
        replayKitPrivacyBlurEnabled && activeFrame != nil
    }

    private var airPlayScreenOffOverlayVisible: Bool {
        guard appState.activeVideoSource == .airPlay,
              airPlayStream.currentFrame != nil,
              case .screenOff = airPlayStream.streamHealth else {
            return false
        }
        return true
    }

    private var videoPremiumGateState: (eligible: Bool, source: EasyPremiumVideoGateSource?, reason: String) {
        if licenseManager.isPremium {
            return (false, nil, "premium-license-active")
        }

        guard let gateSource = EasyPremiumVideoGateSource.make(from: appState.activeVideoSource) else {
            return (false, nil, "active-source-\(appState.activeVideoSource.diagnosticName)")
        }

        switch gateSource {
        case .replayKit:
            guard stream.currentFrame != nil else {
                return (false, gateSource, "replaykit-frame-missing")
            }
        case .airPlay:
            guard airPlayStream.currentFrame != nil else {
                return (false, gateSource, "airplay-frame-missing")
            }
        case .usbNative:
            guard iosScreenCapture.currentFrame != nil else {
                return (false, gateSource, "usb-native-frame-missing")
            }
        }

        return (true, gateSource, "\(gateSource.rawValue)-video-visible")
    }

    private var airPlayScreenOffFrameAgeSeconds: TimeInterval? {
        guard case .screenOff(let lastFrameAge) = airPlayStream.streamHealth else { return nil }
        return airPlayStream.lastFrameReceivedAt.map { Date().timeIntervalSince($0) } ?? lastFrameAge
    }

    private var airPlayMirrorPacketAgeSeconds: TimeInterval? {
        airPlayStream.lastMirrorPacketReceivedAt.map { Date().timeIntervalSince($0) }
    }

    private var displayedPhoneScreenSize: CGSize {
        EasyWindowVideoSizing.displayedPhoneSize(
            phoneScreenSize: phoneScreenSize,
            rotationDegrees: phoneDisplayRotationDegrees
        )
    }

    private var currentVideoFrameSize: CGSize? {
        guard let frame = activeFrame else { return nil }
        return CGSize(width: frame.width, height: frame.height)
    }

    private var videoGeometryReady: Bool {
        guard let frameSize = currentVideoFrameSize else { return false }
        return abs(frameSize.width - phoneScreenSize.width) <= 0.5
            && abs(frameSize.height - phoneScreenSize.height) <= 0.5
    }

    private var videoFrameSizeForSizing: CGSize? {
        guard videoGeometryReady, let frameSize = currentVideoFrameSize else { return nil }
        return EasyWindowVideoSizing.displayedPhoneSize(
            phoneScreenSize: frameSize,
            rotationDegrees: phoneDisplayRotationDegrees
        )
    }

    private var activeVideoIsLive: Bool {
        guard activeFrame != nil else { return false }

        switch appState.activeVideoSource {
        case .iosScreenCaptureUSB:
            if case .live = iosScreenCapture.streamHealth {
                return true
            }
            return false
        case .replayKit:
            if case .live = stream.streamHealth {
                return true
            }
            return false
        case .airPlay:
            switch airPlayStream.streamHealth {
            case .receivingVideo, .screenOff:
                return true
            default:
                return false
            }
        default:
            return false
        }
    }

    private var rotationMismatchWarning: EasyRotationMismatchWarning? {
        guard activeFrame != nil else { return nil }
        return EasyRotationMismatchWarning.resolve(
            activeVideoSource: appState.activeVideoSource,
            displayRotationDegrees: phoneDisplayRotationDegrees,
            replayKitOrientation: stream.lastVideoOrientation,
            nativeOrientation: iosScreenCapture.lastVideoOrientation
        )
    }

    private var visibleRotationMismatchWarning: EasyRotationMismatchWarning? {
        guard let warning = rotationMismatchWarning else { return nil }
        guard dismissedRotationMismatchWarningKey != warning.dismissalKey else { return nil }
        return warning
    }

    private var activeVideoDotColor: Color {
        if isUSBNativeReadyToStart {
            return .cyan
        }

        if airPlayStream.currentPairingPIN != nil {
            return airPlayDotColor
        }

        switch appState.activeVideoSource {
        case .iosScreenCaptureUSB:
            switch iosScreenCapture.streamHealth {
            case .live:
                return .cyan
            case .starting, .discovering:
                return .blue
            case .stale, .interrupted:
                return .orange
            case .disconnected, .failed:
                return .red
            case .idle:
                return .secondary
            }
        case .replayKit:
            return replayKitUISnapshot.dotColor
        case .airPlay:
            return airPlayDotColor
        case .none:
            return replayKitUISnapshot.dotColor
        default:
            return appState.activeVideoSource.statusColor
        }
    }

    private var activeVideoStatusBadge: String {
        if isUSBNativeReadyToStart {
            return "Video Ready"
        }

        if let pin = airPlayStream.currentPairingPIN {
            return "AirPlay PIN: \(pin)"
        }

        switch appState.activeVideoSource {
        case .iosScreenCaptureUSB:
            switch iosScreenCapture.streamHealth {
            case .live:
                return "Cable"
            case .starting:
                return "Cable starting"
            case .discovering:
                return "Cable discovery"
            case .stale:
                return "Cable stale"
            case .interrupted:
                return "Cable interrupted"
            case .disconnected:
                return "Cable disconnected"
            case .failed:
                return "Cable failed"
            case .idle:
                return "Cable idle"
            }
        case .replayKit, .none:
            return replayKitUISnapshot.statusBadge
        case .airPlay:
            return airPlayStream.streamHealth.statusText
        default:
            return appState.activeVideoSource.displayName
        }
    }

    private var activeVideoWaitingDetailText: String {
        if isUSBNativeReadyToStart {
            return "Click here to start cable video"
        }

        if let pin = airPlayStream.currentPairingPIN {
            return "Enter AirPlay PIN \(pin) on iPhone."
        }

        switch appState.activeVideoSource {
        case .iosScreenCaptureUSB:
            return iosScreenCapture.statusMessage
        case .airPlay:
            return airPlayStream.lastError ?? airPlayStream.statusMessage
        case .replayKit, .none:
            return replayKitUISnapshot.waitingDetailText()
        default:
            return appState.activeVideoSource.displayName
        }
    }

    private var activeVideoInstructionText: String {
        if isUSBNativeReadyToStart {
            return "Watch the tutorial, then start the cable video when you are ready."
        }

        switch appState.activeVideoSource {
        case .iosScreenCaptureUSB:
            return "Keep the iPhone unlocked and connected by cable while native video starts."
        case .airPlay:
            return "Open Control Center on iPhone, choose Screen Mirroring, then select Specchio."
        default:
            return "Connect Bluetooth first by clicking the button below, then start the broadcast."
        }
    }

    private var activeVideoWaitingIconName: String {
        if isUSBNativeReadyToStart {
            return "play.circle"
        }

        if airPlayStream.currentPairingPIN != nil {
            return "airplayvideo"
        }

        switch appState.activeVideoSource {
        case .iosScreenCaptureUSB:
            return "cable.connector"
        case .airPlay:
            return "airplayvideo"
        default:
            return stream.isClientConnected ? "iphone.radiowaves.left.and.right" : "dot.radiowaves.left.and.right"
        }
    }

    private var airPlayDotColor: Color {
        switch airPlayStream.streamHealth {
        case .receivingVideo:
            return .indigo
        case .screenOff:
            return .orange
        case .advertising, .waitingForPhone, .pairing, .settingUp:
            return .blue
        case .stale:
            return .orange
        case .failed:
            return .red
        case .idle, .disconnected:
            return .secondary
        }
    }

    private var videoSourceCards: [EasyVideoSourceCardState] {
        [
            replayKitVideoSourceCard,
            airPlayVideoSourceCard,
            usbNativeVideoSourceCard
        ]
    }

    private var videoSourceCardsLogSummary: String {
        videoSourceCards.map(\.logSummary).joined(separator: " | ")
    }

    private var replayKitVideoSourceCard: EasyVideoSourceCardState {
        let snapshot = replayKitUISnapshot
        let isDisplayed = appState.activeVideoSource == .replayKit
        let actionTitle: String
        switch snapshot.kind {
        case .live:
            actionTitle = isDisplayed ? "Live" : "Show"
        case .stale, .paused, .ended, .disconnected, .failed:
            actionTitle = "Restart"
        case .idle, .listening, .connecting:
            actionTitle = "Listen"
        }

        return EasyVideoSourceCardState(
            kind: .replayKit,
            title: "Mobile App",
            status: snapshot.statusBadge,
            detail: snapshot.waitingDetailText(),
            systemImage: stream.isClientConnected ? "iphone.radiowaves.left.and.right" : "dot.radiowaves.left.and.right",
            dotColor: snapshot.dotColor,
            isDisplayed: isDisplayed,
            isDimmed: isVideoSourceCardDimmed(.replayKit),
            actionTitle: actionTitle,
            help: "Mobile app broadcast receiver"
        )
    }

    private var airPlayVideoSourceCard: EasyVideoSourceCardState {
        let isDisplayed = appState.activeVideoSource == .airPlay
        let status: String
        let detail: String
        let actionTitle: String

        if let pin = airPlayStream.currentPairingPIN {
            status = "PIN \(pin)"
            detail = "Enter this PIN on iPhone."
            actionTitle = "Pair"
        } else {
            switch airPlayStream.streamHealth {
            case .idle:
                status = "AirPlay Idle"
                detail = "Receiver is not advertising."
                actionTitle = "Advertise"
            case .advertising:
                status = "AirPlay Ready"
                detail = "Available in Screen Mirroring."
                actionTitle = "Advertise"
            case .waitingForPhone:
                status = "Waiting for iPhone"
                detail = airPlayStream.statusMessage
                actionTitle = "Advertise"
            case .pairing:
                status = "Pairing"
                detail = airPlayStream.statusMessage
                actionTitle = "Pair"
            case .settingUp:
                status = "Setting up"
                detail = airPlayStream.statusMessage
                actionTitle = "Show"
            case .receivingVideo:
                status = "AirPlay Live"
                detail = airPlayStream.currentFPS >= 1 ? "\(Int(airPlayStream.currentFPS.rounded())) FPS" : "Receiving video"
                actionTitle = isDisplayed ? "Live" : "Show"
            case .screenOff:
                status = "Screen Off"
                detail = "AirPlay is connected; iPhone screen appears off."
                actionTitle = isDisplayed ? "Shown" : "Show"
            case .stale:
                status = "AirPlay Stale"
                detail = "AirPlay stopped sending fresh frames."
                actionTitle = "Advertise"
            case .failed(let reason):
                status = "AirPlay Failed"
                detail = reason.isEmpty ? "AirPlay setup failed." : reason
                actionTitle = "Advertise"
            case .disconnected(let reason):
                status = "AirPlay Disconnected"
                detail = reason.isEmpty ? "Waiting for a new AirPlay connection." : reason
                actionTitle = "Advertise"
            }
        }

        return EasyVideoSourceCardState(
            kind: .airPlay,
            title: "AirPlay",
            status: status,
            detail: detail,
            systemImage: "airplayvideo",
            dotColor: airPlayDotColor,
            isDisplayed: isDisplayed,
            isDimmed: isVideoSourceCardDimmed(.airPlay),
            actionTitle: actionTitle,
            help: "AirPlay screen mirroring receiver"
        )
    }

    private var usbNativeVideoSourceCard: EasyVideoSourceCardState {
        let isDisplayed = appState.activeVideoSource == .iosScreenCaptureUSB
        let hasSelectedDevice = iosScreenCaptureMonitor.selectedDevice != nil
        let status: String
        let detail: String
        let dotColor: Color
        let actionTitle: String

        switch iosScreenCapture.streamHealth {
        case .live:
            status = "Cable Live"
            detail = iosScreenCapture.currentFPS >= 1 ? "\(Int(iosScreenCapture.currentFPS.rounded())) FPS" : "Native video is running."
            dotColor = .cyan
            actionTitle = isDisplayed ? "Live" : "Show"
        case .starting(let deviceName):
            status = "Cable Starting"
            detail = "Waiting for video frames from \(deviceName)."
            dotColor = .blue
            actionTitle = "Starting"
        case .discovering:
            status = "Cable Discovery"
            detail = "Looking for a native iPhone video device."
            dotColor = .blue
            actionTitle = "Refresh"
        case .stale:
            status = "Cable Stale"
            detail = "Unplug and reconnect the cable, then try again."
            dotColor = .orange
            actionTitle = "Retry"
        case .interrupted:
            status = "Cable Interrupted"
            detail = "Unplug and reconnect the cable, then try again."
            dotColor = .orange
            actionTitle = "Retry"
        case .disconnected:
            status = "Cable Disconnected"
            detail = "Unplug and reconnect the cable, then try again."
            dotColor = .red
            actionTitle = "Refresh"
        case .failed:
            status = "Cable Failed"
            detail = "Unplug and reconnect the cable, then try again."
            dotColor = .red
            actionTitle = "Retry"
        case .idle:
            if hasSelectedDevice {
                status = isUSBNativeStartDeferred ? "Cable Ready" : "Cable Available"
                detail = isUSBNativeStartDeferred ? "Start cable video when ready." : iosScreenCaptureMonitor.diagnosticReason
                dotColor = .cyan
                actionTitle = "Start"
            } else {
                switch iosScreenCaptureMonitor.availability {
                case .available:
                    status = "Cable Available"
                    detail = iosScreenCaptureMonitor.diagnosticReason
                    dotColor = .cyan
                    actionTitle = "Start"
                case .unavailable:
                    status = "Cable Not Connected"
                    detail = "Connect iPhone by cable."
                    dotColor = .secondary
                    actionTitle = "Refresh"
                case .unknown:
                    status = "Cable Unknown"
                    detail = "Looking for cable video devices."
                    dotColor = .secondary
                    actionTitle = "Refresh"
                }
            }
        }

        return EasyVideoSourceCardState(
            kind: .usbNative,
            title: "Cable",
            status: status,
            detail: detail,
            systemImage: "cable.connector",
            dotColor: dotColor,
            isDisplayed: isDisplayed,
            isDimmed: isVideoSourceCardDimmed(.usbNative),
            actionTitle: actionTitle,
            help: "Cable video"
        )
    }

    private func isVideoSourceCardDimmed(_ kind: EasyVideoSourceCardKind) -> Bool {
        guard activeFrame == nil, let selectedVideoSourceCardKind else {
            return false
        }

        return selectedVideoSourceCardKind != kind
    }

    private var isUSBNativeReadyToStart: Bool {
        isUSBNativeStartDeferred
            && iosScreenCaptureMonitor.selectedDevice != nil
            && appState.activeVideoSource != .iosScreenCaptureUSB
    }

    private var bluetoothSetupButtonTitle: String {
        bluetoothHIDPanel.isBluetoothHIDConnected ? "Keyboard Connected" : "Connect Keyboard"
    }

    private var phoneAspectRatio: CGFloat {
        let displaySize = displayedPhoneScreenSize
        guard displaySize.width > 0, displaySize.height > 0 else { return 390.0 / 844.0 }
        return displaySize.width / displaySize.height
    }

    private var isPhoneDisplaySideways: Bool {
        EasyWindowVideoSizing.isSidewaysRotation(phoneDisplayRotationDegrees)
    }

    private var isPresentationHeaderVisible: Bool {
        isPresentationApplicationActive && isPresentationWindowKey && isPresentationHeaderRevealedByTopEdge
    }

    private var easyToolbarLayout: EasyToolbarCommandLayout {
        EasyToolbarCommandLayout.fromStorage(
            visibleStorageValue: easyToolbarVisibleCommandOrder,
            overflowStorageValue: easyToolbarOverflowCommandOrder,
            legacyOrderStorageValue: easyToolbarCommandOrder,
            hasStoredVisibleOrder: UserDefaults.standard.object(forKey: AppSettings.Keys.easyToolbarVisibleCommandOrder) != nil,
            hasStoredOverflowOrder: UserDefaults.standard.object(forKey: AppSettings.Keys.easyToolbarOverflowCommandOrder) != nil
        )
    }

    var body: some View {
        GeometryReader { geo in
            easyModeContent(size: geo.size, safeAreaInsets: geo.safeAreaInsets)
        }
        .sheet(isPresented: $showEasyShortcutHelp) {
            EasyShortcutHelpPanel()
        }
    }

    private func easyModeContent(size: CGSize, safeAreaInsets: EdgeInsets) -> some View {
        let content = VStack(spacing: 0) {
            presentationHeader

            phoneSurfaceContainer
        }
        .background(.clear)
        .background {
            EasyMirroringPresentationPanelChrome(isVisible: isPresentationHeaderVisible)
        }
        .background {
            EasyPresentationWindowFocusObserver(standardControlsVisible: isPresentationHeaderVisible) { isKey, isApplicationActive, reason in
                handlePresentationWindowFocusChanged(
                    isKey: isKey,
                    isApplicationActive: isApplicationActive,
                    reason: reason
                )
            }
        }
        .contentShape(Rectangle())
        .ignoresSafeArea(.container, edges: [.all])
        .background(EasyWindowAspectRatioAccessor(
            displayedPhoneSize: displayedPhoneScreenSize,
            topChromeHeight: EasyMirroringPresentationMetrics.reservedTopChromeHeight,
            contentSize: size,
            phoneSurfaceAvailableSize: phoneSurfaceAvailableSize,
            videoFrameSize: videoFrameSizeForSizing,
            rotationDegrees: phoneDisplayRotationDegrees,
            minimumTopChromeHeight: EasyMirroringPresentationMetrics.reservedTopChromeHeight,
            countsWindowLayoutInsetAsChrome: false,
            standardControlsVisible: isPresentationHeaderVisible
        ))

        return observeEasyModeContent(content, size: size, safeAreaInsets: safeAreaInsets)
    }

    private func observeEasyModeContent<Content: View>(
        _ content: Content,
        size: CGSize,
        safeAreaInsets: EdgeInsets
    ) -> some View {
        observeEasyModeStream(
            observeEasyModePreferences(
                observeEasyModeLifecycle(content, size: size, safeAreaInsets: safeAreaInsets)
            )
        )
    }

    private func observeEasyModeLifecycle<Content: View>(
        _ content: Content,
        size: CGSize,
        safeAreaInsets: EdgeInsets
    ) -> some View {
        content
        .onAppear {
            handleAppear(size: size, safeAreaInsets: safeAreaInsets)
        }
        .onDisappear(perform: handleDisappear)
        .onChange(of: size) { _, newSize in
            handleGeometryChanged(size: newSize, safeAreaInsets: safeAreaInsets)
        }
        .onChange(of: isPresentationHeaderVisible) { _, isVisible in
            SpecchioLogger.easyMode.info("[EasyPresentationHeader] visibility changed visible=\(isVisible) appActive=\(isPresentationApplicationActive) windowKey=\(isPresentationWindowKey) topEdge=\(isPresentationHeaderRevealedByTopEdge)")
        }
        .background {
            EasyPresentationHeaderHoverTracker { location, reason in
                handlePresentationHeaderTrackingHover(location: location, reason: reason)
            }
        }
        .onContinuousHover { (phase: HoverPhase) in
            handleContinuousHover(phase)
        }
    }

    private func observeEasyModePreferences<Content: View>(_ content: Content) -> some View {
        observeEasyModeOutputPreferences(
            observeEasyModeToolbarPreferences(
                observeEasyModeInputPreferences(
                    observeEasyModeFramePreferences(content)
                )
            )
        )
    }

    private func observeEasyModeFramePreferences<Content: View>(_ content: Content) -> some View {
        content
        .onChange(of: activeFrame == nil) { _, isWaitingForFrame in
            handleActiveFramePresentationChanged(isWaitingForFrame: isWaitingForFrame)
        }
        .onChange(of: stream.currentFrame == nil) { _, isWaitingForFrame in
            handleVideoFramePresenceChanged(source: "ReplayKit", isWaitingForFrame: isWaitingForFrame)
            updateVideoPremiumOverlay(trigger: isWaitingForFrame ? "ReplayKit frame cleared" : "ReplayKit frame visible")
        }
        .onChange(of: iosScreenCapture.currentFrame == nil) { _, isWaitingForFrame in
            handleVideoFramePresenceChanged(source: "USB native", isWaitingForFrame: isWaitingForFrame)
            updateVideoPremiumOverlay(trigger: isWaitingForFrame ? "USB native frame cleared" : "USB native frame visible")
        }
        .onChange(of: airPlayStream.currentFrame == nil) { _, isWaitingForFrame in
            handleVideoFramePresenceChanged(source: "AirPlay", isWaitingForFrame: isWaitingForFrame)
            updateVideoPremiumOverlay(trigger: isWaitingForFrame ? "AirPlay frame cleared" : "AirPlay frame visible")
        }
        .onChange(of: airPlayStream.isAdvertising) { oldValue, newValue in
            handleAirPlayAdvertisingChanged(from: oldValue, to: newValue)
        }
    }

    private func observeEasyModeInputPreferences<Content: View>(_ content: Content) -> some View {
        content
        .onChange(of: easyMouseClutchMode) { _, newValue in
            handleClutchPreferenceChanged(newValue)
        }
        .onChange(of: easyHideLocalCursor) { _, newValue in
            handleHideLocalCursorPreferenceChanged(newValue)
        }
        .onChange(of: easyPointerSpikeEnabled) { _, newValue in
            handlePointerSpikeEnabledChanged(newValue)
        }
        .onChange(of: easyPointerSpikeOverlayEnabled) { _, newValue in
            handlePointerSpikeOverlayChanged(newValue)
        }
        .onChange(of: replayKitPrivacyBlurEnabled) { _, newValue in
            handleReplayKitPrivacyBlurChanged(newValue)
        }
        .onChange(of: pointerSpikeVariant) { _, newValue in
            handlePointerSpikeVariantChanged(newValue)
        }
    }

    private func observeEasyModeToolbarPreferences<Content: View>(_ content: Content) -> some View {
        content
        .onChange(of: easyToolbarCommandOrder) { _, newValue in
            SpecchioLogger.easyMode.info("[EasyModeView] legacy toolbar order changed value=\(newValue, privacy: .public)")
            normalizeEasyToolbarLayoutIfNeeded(reason: "legacy-order-changed")
        }
        .onChange(of: easyToolbarVisibleCommandOrder) { _, newValue in
            SpecchioLogger.easyMode.info("[EasyModeView] toolbar visible order changed value=\(newValue, privacy: .public)")
            normalizeEasyToolbarLayoutIfNeeded(reason: "visible-order-changed")
        }
        .onChange(of: easyToolbarOverflowCommandOrder) { _, newValue in
            SpecchioLogger.easyMode.info("[EasyModeView] toolbar overflow order changed value=\(newValue, privacy: .public)")
            normalizeEasyToolbarLayoutIfNeeded(reason: "overflow-order-changed")
        }
    }

    private func observeEasyModeOutputPreferences<Content: View>(_ content: Content) -> some View {
        content
        .onChange(of: easyReplayKitH264TargetFPS) { _, newValue in
            handleReplayKitH264TargetFPSChanged(newValue)
        }
        .onChange(of: easyAirPlayQuality) { _, newValue in
            handleAirPlayQualityChanged(newValue)
        }
        .onChange(of: easyUSBTargetFPS) { _, newValue in
            handleUSBTargetFPSChanged(newValue)
        }
        .onChange(of: bluetoothAutoConnect) { _, newValue in
            SpecchioLogger.easyMode.info("[BluetoothAutoConnect] preference changed enabled=\(newValue)")
        }
    }

    private func observeEasyModeStream<Content: View>(_ content: Content) -> some View {
        content
        .onChange(of: replayKitUISnapshot) { oldValue, newValue in
            handleReplayKitUISnapshotChanged(from: oldValue, to: newValue)
        }
        .onChange(of: iosScreenCaptureMonitor.availability) { _, newValue in
            handleUSBAvailabilityChanged(newValue, trigger: "monitor availability changed")
        }
        .onChange(of: iosScreenCapture.streamHealth) { oldValue, newValue in
            handleIOSScreenCaptureHealthChanged(from: oldValue, to: newValue)
        }
        .onChange(of: airPlayStream.streamHealth) { oldValue, newValue in
            handleAirPlayHealthChanged(from: oldValue, to: newValue)
        }
        .onChange(of: airPlayScreenOffOverlayVisible) { _, isVisible in
            handleAirPlayScreenOffOverlayVisibilityChanged(isVisible)
        }
        .onChange(of: airPlayStream.currentPairingPIN) { oldValue, newValue in
            handleAirPlayPairingPINChanged(from: oldValue, to: newValue)
        }
        .onChange(of: rotationMismatchWarning) { oldValue, newValue in
            handleRotationMismatchWarningChanged(from: oldValue, to: newValue)
        }
        .onChange(of: appState.activeVideoSource) { oldValue, newValue in
            SpecchioLogger.easyMode.info("[EasyModeView] active video source changed from=\(oldValue.diagnosticName, privacy: .public) to=\(newValue.diagnosticName, privacy: .public)")
            if newValue == .none {
                resetAllBluetoothAutoConnectVideoStartAttempts(reason: "active video source changed to none from \(oldValue.diagnosticName)")
            }
            updateBluetoothInputGate(trigger: "active video source changed")
            updateVideoPremiumOverlay(trigger: "active video source changed")
        }
        .onChange(of: videoSourceCardsLogSummary) { _, newValue in
            SpecchioLogger.easyMode.info("[EasyVideoCards] state changed \(newValue, privacy: .public)")
        }
        .onChange(of: licenseManager.isPremium) { _, isPremium in
            handleReplayKitPremiumChanged(isPremium)
        }
        .onChange(of: stream.resolvedTransport) { _, _ in
            updateVideoPremiumOverlay(trigger: "ReplayKit resolved transport changed")
        }
    }

    private func handleAppear(size: CGSize, safeAreaInsets: EdgeInsets) {
        isEasyModeVisible = true
        normalizeEasyToolbarLayoutIfNeeded(reason: "appear")
        applyEasyPointerDefaultsIfNeeded()
        handleAirPlayQualityChanged(easyAirPlayQuality)
        SpecchioLogger.easyMode.info("[EasyModeView] appeared width=\(size.width) height=\(size.height) safeLeft=\(safeAreaInsets.leading) safeRight=\(safeAreaInsets.trailing) safeBottom=\(safeAreaInsets.bottom)")
        SpecchioLogger.easyMode.info("[EasyModeView] presentation chrome=iPhoneMirroring branch=transparent-floating-panel toolbarReveal=top-edge reservedTopChrome=\(EasyMirroringPresentationMetrics.reservedTopChromeHeight) headerPosition=above-phone")
        SpecchioLogger.easyMode.info("[EasyModeView] preferences clutchEnabled=\(easyMouseClutchMode) hideLocalCursor=\(easyHideLocalCursor) pointerSpikeEnabled=\(easyPointerSpikeEnabled) pointerSpikeOverlayEnabled=\(easyPointerSpikeOverlayEnabled) pointerSpikeVariant=\(pointerSpikeVariant)")
        SpecchioLogger.easyMode.info("[EasyModeView] toolbar layout visible=\(easyToolbarVisibleCommandOrder, privacy: .public) overflow=\(easyToolbarOverflowCommandOrder, privacy: .public) legacy=\(easyToolbarCommandOrder, privacy: .public)")
        SpecchioLogger.easyMode.info("[EasyModeView] ReplayKit H.264 target FPS preference=\(easyReplayKitH264TargetFPS)")
        let airPlayPixels = AppSettings.easyAirPlayDisplayPixels(for: easyAirPlayQuality)
        SpecchioLogger.easyMode.info("[EasyModeView] AirPlay quality preference=\(easyAirPlayQuality, privacy: .public) display=\(airPlayPixels.width)x\(airPlayPixels.height)")
        SpecchioLogger.easyMode.info("[EasyModeView] USB target FPS preference=\(easyUSBTargetFPS)")
        SpecchioLogger.easyMode.info("[BluetoothAutoConnect] initial preference enabled=\(bluetoothAutoConnect)")
        SpecchioLogger.easyMode.info("[EasyModeView] privacy blur initial enabled=\(replayKitPrivacyBlurEnabled) visible=\(replayKitPrivacyBlurVisible)")
        SpecchioLogger.easyMode.info("[EasyModeView] publishing Easy video streams to AppState for menu bar preview")
        appState.replayKitStream = stream
        appState.airPlayStream = airPlayStream
        appState.iosScreenCaptureStream = iosScreenCapture
        if let warning = rotationMismatchWarning {
            recordRotationMismatchWarning(warning, phase: "appeared")
        }
        applyUSBCaptureSettings(source: "EasyModeView appeared")
        Task { @MainActor in
            SpecchioLogger.easyMode.info("[EasyModeView] validating license for Easy paywall state")
            await licenseManager.validate()
            updateVideoPremiumOverlay(trigger: "EasyMode license validation completed")
        }
        iosScreenCapture.onStreamFailed = { reason in
            Task { @MainActor in
                fallbackFromNativeUSBVideo(reason: reason)
            }
        }
        viewSize = size
        bluetoothHIDPanel.setEasyMouseClutchModeEnabled(easyMouseClutchMode)
        bluetoothHIDPanel.setEasyPointerSpikeEnabled(easyPointerSpikeEnabled, variant: pointerSpikeVariant)
        updateBluetoothInputGate(trigger: "EasyModeView appeared")
        airPlayStream.start()
        ensureAirPlayAdvertisingIfNeeded(trigger: "EasyModeView appeared")
        startBestAvailableVideoSource(trigger: "appear", autoStartNativeUSB: false)
        bluetoothHIDPanel.startCalibrationReceiver()
    }

    private func handleDisappear() {
        SpecchioLogger.easyMode.info("[EasyModeView] disappeared; stopping Easy video receivers and suspending Bluetooth HID panel")
        isEasyModeVisible = false
        resetAllBluetoothAutoConnectVideoStartAttempts(reason: "EasyModeView disappeared")
        resetPresentationHeaderReveal(reason: "easy-mode-disappear")
        if appState.replayKitStream === stream {
            SpecchioLogger.easyMode.info("[EasyModeView] clearing AppState ReplayKit stream for menu bar preview")
            appState.replayKitStream = nil
        } else {
            SpecchioLogger.easyMode.info("[EasyModeView] keeping AppState ReplayKit stream because it no longer points at this Easy view")
        }
        replayKitStartupTask?.cancel()
        replayKitStartupTask = nil
        endUSBNativeIsolation(reason: "EasyModeView disappeared", restartAirPlay: false)
        if appState.airPlayStream === airPlayStream {
            SpecchioLogger.easyMode.info("[EasyModeView] clearing AppState AirPlay stream for menu bar preview")
            appState.airPlayStream = nil
        }
        airPlayStream.stop()
        hideVideoPremiumOverlay(trigger: "EasyModeView disappeared", resetPresentation: true)
        bluetoothHIDPanel.setReplayKitInputForwardingEnabled(false, reason: "EasyModeView disappeared")
        if appState.iosScreenCaptureStream === iosScreenCapture {
            SpecchioLogger.easyMode.info("[EasyModeView] clearing AppState USB native stream for menu bar preview")
            appState.iosScreenCaptureStream = nil
        }
        appState.activeVideoSource = .none
        iosScreenCapture.onStreamFailed = nil
        iosScreenCapture.stopCapture(reason: "EasyModeView disappeared", clearFrame: true)
        stream.stop()
        bluetoothHIDPanel.suspendForModeSwitch(reason: "EasyModeView disappeared")
    }

    private func handleGeometryChanged(size: CGSize, safeAreaInsets: EdgeInsets) {
        SpecchioLogger.easyMode.info("[EasyModeView] geometry changed width=\(size.width) height=\(size.height) safeLeft=\(safeAreaInsets.leading) safeRight=\(safeAreaInsets.trailing) safeBottom=\(safeAreaInsets.bottom)")
        viewSize = size
    }

    private func handleVideoFramePresenceChanged(source: String, isWaitingForFrame: Bool) {
        if isWaitingForFrame {
            SpecchioLogger.easyMode.info("[EasyModeView] rendering waiting branch source=\(source, privacy: .public)")
        } else {
            SpecchioLogger.easyMode.info("[EasyModeView] rendering live frame branch source=\(source, privacy: .public)")
        }
        SpecchioLogger.easyMode.info("[EasyModeView] privacy blur frame visibility evaluated enabled=\(replayKitPrivacyBlurEnabled) hasFrame=\(!isWaitingForFrame) visible=\(replayKitPrivacyBlurVisible)")
        updateBluetoothInputGate(trigger: "\(source) frame presence changed")
    }

    private func handleActiveFramePresentationChanged(isWaitingForFrame: Bool) {
        SpecchioLogger.easyMode.info("[EasyModeView] active frame presentation changed waiting=\(isWaitingForFrame) activeSource=\(appState.activeVideoSource.diagnosticName, privacy: .public) replayKitHealth=\(stream.streamHealth.diagnosticDescription, privacy: .public) replayKitRawFrame=\(stream.currentFrame != nil) usbHealth=\(iosScreenCapture.streamHealth.diagnosticDescription, privacy: .public) usbRawFrame=\(iosScreenCapture.currentFrame != nil) airPlayHealth=\(airPlayStream.streamHealth.diagnosticDescription, privacy: .public) airPlayRawFrame=\(airPlayStream.currentFrame != nil)")
        updateBluetoothInputGate(trigger: "Easy active frame presentation changed")
        updateVideoPremiumOverlay(trigger: isWaitingForFrame ? "Easy active frame returned to waiting" : "Easy active frame visible")
    }

    private func handleReplayKitUISnapshotChanged(
        from oldValue: EasyReplayKitUISnapshot,
        to newValue: EasyReplayKitUISnapshot
    ) {
        SpecchioLogger.easyMode.info("[EasyModeView] ReplayKit UI state changed from=\(oldValue.logSummary) to=\(newValue.logSummary)")
        updateBluetoothInputGate(trigger: "ReplayKit UI state changed")
        updateVideoPremiumOverlay(trigger: "ReplayKit UI state changed")
        if oldValue.kind == .live && newValue.kind != .live {
            resetBluetoothAutoConnectVideoStartAttempt(
                source: .replayKit,
                reason: "ReplayKit left live state to \(newValue.kind.rawValue)"
            )
        }
        maybeStartBluetoothAutoConnectForReplayKit(from: oldValue, to: newValue)
    }

    private var bluetoothInputGateAllowsForwarding: Bool {
        activeVideoIsLive
    }

    private func updateBluetoothInputGate(trigger: String) {
        let enabled = bluetoothInputGateAllowsForwarding
        let framePresent = activeFrame != nil
        let reason = "\(trigger); activeSource=\(appState.activeVideoSource.diagnosticName); replayKitHealth=\(stream.streamHealth.diagnosticDescription); usbNativeHealth=\(iosScreenCapture.streamHealth.diagnosticDescription); airPlayHealth=\(airPlayStream.streamHealth.diagnosticDescription); airPlayFramePresent=\(airPlayStream.currentFrame != nil); framePresent=\(framePresent); replayKitClientConnected=\(stream.isClientConnected)"
        SpecchioLogger.easyMode.info("[EasyModeView] Bluetooth input gate update enabled=\(enabled) reason=\(reason, privacy: .public)")
        bluetoothHIDPanel.setReplayKitInputForwardingEnabled(enabled, reason: reason)
    }

    private func requestBluetoothAutoConnectForVideoPath(
        source: SpecchioVideoSourceKind,
        trigger: String
    ) {
        switch source {
        case .airPlay, .replayKit, .iosScreenCaptureUSB:
            break
        case .screenshot, .mjpeg, .h264, .none:
            SpecchioLogger.easyMode.info("[BluetoothAutoConnect] video path trigger skipped source=\(source.diagnosticName, privacy: .public) trigger=\(trigger, privacy: .public) branch=unsupported-source")
            return
        }

        SpecchioLogger.easyMode.info("[BluetoothAutoConnect] video path trigger evaluated source=\(source.diagnosticName, privacy: .public) trigger=\(trigger, privacy: .public) setting=\(bluetoothAutoConnect) connected=\(bluetoothHIDPanel.isBluetoothHIDConnected) activeSource=\(appState.activeVideoSource.diagnosticName, privacy: .public) replayKitHealth=\(stream.streamHealth.diagnosticDescription, privacy: .public) usbNativeHealth=\(iosScreenCapture.streamHealth.diagnosticDescription, privacy: .public) airPlayHealth=\(airPlayStream.streamHealth.diagnosticDescription, privacy: .public)")
        guard markBluetoothAutoConnectVideoStartAttemptIfNeeded(source: source, trigger: trigger) else {
            return
        }
        let claimed = bluetoothHIDPanel.requestBluetoothAutoConnectIfEnabled(
            source: "\(source.displayName) video path \(trigger)"
        )
        SpecchioLogger.easyMode.info("[BluetoothAutoConnect] video path trigger requested source=\(source.diagnosticName, privacy: .public) trigger=\(trigger, privacy: .public) claimed=\(claimed)")
    }

    private func markBluetoothAutoConnectVideoStartAttemptIfNeeded(
        source: SpecchioVideoSourceKind,
        trigger: String
    ) -> Bool {
        let key = source.rawValue
        let alreadyAttempted = bluetoothAutoConnectVideoStartAttemptedSources.contains(key)
        SpecchioLogger.easyMode.info("[BluetoothAutoConnect] video session trigger dedupe evaluated source=\(source.diagnosticName, privacy: .public) trigger=\(trigger, privacy: .public) alreadyAttempted=\(alreadyAttempted) attemptedSources=\(bluetoothAutoConnectVideoStartAttemptedSources.sorted().joined(separator: ","), privacy: .public)")
        guard !alreadyAttempted else {
            SpecchioLogger.easyMode.info("[BluetoothAutoConnect] video path trigger skipped source=\(source.diagnosticName, privacy: .public) trigger=\(trigger, privacy: .public) branch=session-already-attempted")
            return false
        }

        bluetoothAutoConnectVideoStartAttemptedSources.insert(key)
        SpecchioLogger.easyMode.info("[BluetoothAutoConnect] video session trigger marked source=\(source.diagnosticName, privacy: .public) trigger=\(trigger, privacy: .public) attemptedSources=\(bluetoothAutoConnectVideoStartAttemptedSources.sorted().joined(separator: ","), privacy: .public)")
        return true
    }

    private func resetBluetoothAutoConnectVideoStartAttempt(
        source: SpecchioVideoSourceKind,
        reason: String
    ) {
        let removed = bluetoothAutoConnectVideoStartAttemptedSources.remove(source.rawValue) != nil
        SpecchioLogger.easyMode.info("[BluetoothAutoConnect] video session trigger reset source=\(source.diagnosticName, privacy: .public) reason=\(reason, privacy: .public) removed=\(removed) remainingSources=\(bluetoothAutoConnectVideoStartAttemptedSources.sorted().joined(separator: ","), privacy: .public)")
    }

    private func resetAllBluetoothAutoConnectVideoStartAttempts(reason: String) {
        let previousSources = bluetoothAutoConnectVideoStartAttemptedSources.sorted().joined(separator: ",")
        bluetoothAutoConnectVideoStartAttemptedSources.removeAll()
        SpecchioLogger.easyMode.info("[BluetoothAutoConnect] video session trigger reset all reason=\(reason, privacy: .public) previousSources=\(previousSources, privacy: .public)")
    }

    private func maybeStartBluetoothAutoConnectForReplayKit(
        from oldValue: EasyReplayKitUISnapshot,
        to newValue: EasyReplayKitUISnapshot
    ) {
        let didBecomeLive = oldValue.kind != .live && newValue.kind == .live
        let activeSourceMatches = appState.activeVideoSource == .replayKit
        SpecchioLogger.easyMode.info("[BluetoothAutoConnect] ReplayKit video-start trigger evaluated from=\(oldValue.kind.rawValue, privacy: .public) to=\(newValue.kind.rawValue, privacy: .public) didBecomeLive=\(didBecomeLive) activeSourceMatches=\(activeSourceMatches) activeSource=\(appState.activeVideoSource.diagnosticName, privacy: .public) connected=\(bluetoothHIDPanel.isBluetoothHIDConnected)")

        guard didBecomeLive else {
            SpecchioLogger.easyMode.info("[BluetoothAutoConnect] ReplayKit trigger skipped branch=not-video-start")
            return
        }

        guard activeSourceMatches else {
            SpecchioLogger.easyMode.info("[BluetoothAutoConnect] ReplayKit trigger skipped branch=inactive-source activeSource=\(appState.activeVideoSource.diagnosticName, privacy: .public)")
            return
        }

        requestBluetoothAutoConnectForVideoPath(
            source: .replayKit,
            trigger: "replaykit-became-live"
        )
    }

    private func maybeStartBluetoothAutoConnectForNativeUSB(
        from oldValue: IOSScreenCaptureHealth,
        to newValue: IOSScreenCaptureHealth
    ) {
        let didBecomeLive: Bool
        if case .live = newValue {
            if case .live = oldValue {
                didBecomeLive = false
            } else {
                didBecomeLive = true
            }
        } else {
            didBecomeLive = false
        }
        let activeSourceMatches = appState.activeVideoSource == .iosScreenCaptureUSB
        SpecchioLogger.easyMode.info("[BluetoothAutoConnect] USB native video-start trigger evaluated from=\(oldValue.diagnosticDescription, privacy: .public) to=\(newValue.diagnosticDescription, privacy: .public) didBecomeLive=\(didBecomeLive) activeSourceMatches=\(activeSourceMatches) activeSource=\(appState.activeVideoSource.diagnosticName, privacy: .public) connected=\(bluetoothHIDPanel.isBluetoothHIDConnected)")

        guard didBecomeLive else {
            SpecchioLogger.easyMode.info("[BluetoothAutoConnect] USB native trigger skipped branch=not-video-start")
            return
        }

        guard activeSourceMatches else {
            SpecchioLogger.easyMode.info("[BluetoothAutoConnect] USB native trigger skipped branch=inactive-source activeSource=\(appState.activeVideoSource.diagnosticName, privacy: .public)")
            return
        }

        requestBluetoothAutoConnectForVideoPath(
            source: .iosScreenCaptureUSB,
            trigger: "usb-native-became-live"
        )
    }

    private func handleClutchPreferenceChanged(_ isEnabled: Bool) {
        SpecchioLogger.easyMode.info("[EasyModeView] clutch preference changed enabled=\(isEnabled)")
        bluetoothHIDPanel.setEasyMouseClutchModeEnabled(isEnabled)
    }

    private func handleHideLocalCursorPreferenceChanged(_ isEnabled: Bool) {
        SpecchioLogger.easyMode.info("[EasyModeView] hide local cursor preference changed enabled=\(isEnabled)")
    }

    private func handlePointerSpikeEnabledChanged(_ isEnabled: Bool) {
        SpecchioLogger.easyMode.info("[EasyModeView] pointer spike preference changed enabled=\(isEnabled) variant=\(pointerSpikeVariant)")
        bluetoothHIDPanel.setEasyPointerSpikeEnabled(isEnabled, variant: pointerSpikeVariant)
    }

    private func handlePointerSpikeOverlayChanged(_ isEnabled: Bool) {
        SpecchioLogger.easyMode.info("[EasyModeView] pointer spike overlay preference changed enabled=\(isEnabled)")
    }

    private func handleReplayKitPrivacyBlurChanged(_ isEnabled: Bool) {
        SpecchioLogger.easyMode.info("[EasyModeView] privacy blur changed enabled=\(isEnabled) hasFrame=\(activeFrame != nil) activeSource=\(appState.activeVideoSource.diagnosticName, privacy: .public) visible=\(replayKitPrivacyBlurVisible)")
    }

    private func handleAirPlayAdvertisingChanged(from oldValue: Bool, to newValue: Bool) {
        SpecchioLogger.easyMode.info("[EasyAirPlayAdvertising] changed from=\(oldValue) to=\(newValue) visible=\(isEasyModeVisible) activeSource=\(appState.activeVideoSource.diagnosticName, privacy: .public) health=\(airPlayStream.streamHealth.diagnosticDescription, privacy: .public) clientConnected=\(airPlayStream.isClientConnected) framePresent=\(airPlayStream.currentFrame != nil)")
        guard !newValue else { return }
        guard !isUSBNativeIsolationActive else {
            SpecchioLogger.iosScreenCapture.info("[EasyUSBIsolation] AirPlay auto-advertise suppressed trigger=advertising changed false activeSource=\(appState.activeVideoSource.diagnosticName, privacy: .public) health=\(airPlayStream.streamHealth.diagnosticDescription, privacy: .public)")
            return
        }
        ensureAirPlayAdvertisingIfNeeded(trigger: "advertising changed false")
    }

    private func ensureAirPlayAdvertisingIfNeeded(trigger: String) {
        guard !isUSBNativeIsolationActive else {
            SpecchioLogger.iosScreenCapture.info("[EasyUSBIsolation] AirPlay ensure skipped trigger=\(trigger, privacy: .public) reason=usb-native-isolation-active activeSource=\(appState.activeVideoSource.diagnosticName, privacy: .public) health=\(airPlayStream.streamHealth.diagnosticDescription, privacy: .public)")
            return
        }

        guard isEasyModeVisible else {
            SpecchioLogger.easyMode.info("[EasyAirPlayAdvertising] ensure skipped trigger=\(trigger, privacy: .public) reason=easy-mode-not-visible")
            return
        }

        guard !airPlayStream.isAdvertising else {
            SpecchioLogger.easyMode.info("[EasyAirPlayAdvertising] ensure skipped trigger=\(trigger, privacy: .public) reason=already-advertising health=\(airPlayStream.streamHealth.diagnosticDescription, privacy: .public)")
            return
        }

        guard airPlayStream.currentFrame == nil else {
            SpecchioLogger.easyMode.info("[EasyAirPlayAdvertising] ensure skipped trigger=\(trigger, privacy: .public) reason=airplay-frame-visible health=\(airPlayStream.streamHealth.diagnosticDescription, privacy: .public)")
            return
        }

        SpecchioLogger.easyMode.info("[EasyAirPlayAdvertising] ensure requested trigger=\(trigger, privacy: .public) health=\(airPlayStream.streamHealth.diagnosticDescription, privacy: .public) status=\(airPlayStream.statusMessage, privacy: .public)")
        airPlayStream.ensureAdvertising(source: "EasyMode \(trigger)")
    }

    private func handlePointerSpikeVariantChanged(_ variant: String) {
        SpecchioLogger.easyMode.info("[EasyModeView] pointer spike transport changed variant=\(variant) enabled=\(easyPointerSpikeEnabled)")
        bluetoothHIDPanel.setEasyPointerSpikeEnabled(easyPointerSpikeEnabled, variant: variant)
    }

    private func handleReplayKitH264TargetFPSChanged(_ value: Double) {
        let sanitizedValue = AppSettings.sanitizedEasyReplayKitH264TargetFPS(value)
        if sanitizedValue != value {
            SpecchioLogger.easyMode.info("[EasyModeView] ReplayKit H.264 target FPS clamped requested=\(value) applied=\(sanitizedValue)")
            easyReplayKitH264TargetFPS = sanitizedValue
            return
        }

        SpecchioLogger.easyMode.info("[EasyModeView] ReplayKit H.264 target FPS changed value=\(sanitizedValue)")
        stream.updateH264TargetFramesPerSecond(sanitizedValue, source: "EasyModeView setting changed")
        airPlayStream.refreshAdvertisedReceiverInfoPreferences(source: "EasyModeView H.264 target FPS changed")
    }

    private func handleAirPlayQualityChanged(_ value: String) {
        let sanitizedValue = AppSettings.EasyAirPlayQuality.sanitized(value)
        if sanitizedValue != value {
            SpecchioLogger.easyMode.info("[EasyModeView] AirPlay quality sanitized requested=\(value, privacy: .public) applied=\(sanitizedValue, privacy: .public)")
            easyAirPlayQuality = sanitizedValue
            return
        }

        let airPlayPixels = AppSettings.easyAirPlayDisplayPixels(for: sanitizedValue)
        SpecchioLogger.easyMode.info("[EasyModeView] AirPlay quality changed value=\(sanitizedValue, privacy: .public) display=\(airPlayPixels.width)x\(airPlayPixels.height)")
        airPlayStream.refreshAdvertisedReceiverInfoPreferences(source: "EasyModeView AirPlay quality changed")
    }

    private func handleUSBTargetFPSChanged(_ value: Double) {
        let sanitizedValue = AppSettings.sanitizedEasyUSBTargetFPS(value)
        if sanitizedValue != value {
            SpecchioLogger.easyMode.info("[EasyModeView] USB target FPS sanitized requested=\(value) applied=\(sanitizedValue)")
            easyUSBTargetFPS = sanitizedValue
            return
        }

        SpecchioLogger.easyMode.info("[EasyModeView] USB target FPS changed value=\(sanitizedValue)")
        iosScreenCapture.updateTargetFramesPerSecond(sanitizedValue, source: "EasyModeView setting changed")
    }

    private func handleContinuousHover(_ phase: HoverPhase) {
        switch phase {
        case .active(let location):
            mouseLocation = location
            updatePresentationHeaderTopEdge(location: location, reason: "swiftui-hover-active")
        case .ended:
            mouseLocation = .zero
            updatePresentationHeaderTopEdge(location: nil, reason: "swiftui-hover-ended")
        }
    }

    private func updatePresentationHeaderTopEdge(location: CGPoint?, reason: String) {
        guard isPresentationApplicationActive else {
            SpecchioLogger.easyMode.info("[EasyPresentationHeader] top-edge ignored reason=\(reason, privacy: .public) branch=app-inactive appActive=\(isPresentationApplicationActive) windowKey=\(isPresentationWindowKey) wasTopEdge=\(isPresentationHeaderRevealedByTopEdge)")
            resetPresentationHeaderReveal(reason: "\(reason)-app-inactive")
            return
        }

        guard isPresentationWindowKey else {
            SpecchioLogger.easyMode.info("[EasyPresentationHeader] top-edge ignored reason=\(reason, privacy: .public) branch=window-not-key appActive=\(isPresentationApplicationActive) windowKey=\(isPresentationWindowKey) wasTopEdge=\(isPresentationHeaderRevealedByTopEdge)")
            resetPresentationHeaderReveal(reason: "\(reason)-window-not-key")
            return
        }

        let nextIsNearTop: Bool
        let y: CGFloat
        if let location {
            y = location.y
            nextIsNearTop = y >= 0 && y <= EasyMirroringPresentationMetrics.headerRevealHeight
        } else {
            y = -1
            nextIsNearTop = false
        }

        guard nextIsNearTop != isPresentationHeaderRevealedByTopEdge else {
            SpecchioLogger.easyMode.debug("[EasyPresentationHeader] top-edge unchanged reason=\(reason, privacy: .public) y=\(y) revealHeight=\(EasyMirroringPresentationMetrics.headerRevealHeight) nearTop=\(nextIsNearTop)")
            return
        }

        isPresentationHeaderRevealedByTopEdge = nextIsNearTop
        SpecchioLogger.easyMode.info("[EasyPresentationHeader] top-edge changed reason=\(reason, privacy: .public) y=\(y) revealHeight=\(EasyMirroringPresentationMetrics.headerRevealHeight) nearTop=\(nextIsNearTop) appActive=\(isPresentationApplicationActive) windowKey=\(isPresentationWindowKey)")
    }

    private func handlePresentationHeaderTrackingHover(location: CGPoint?, reason: String) {
        guard let location else {
            SpecchioLogger.easyMode.debug("[EasyPresentationHeader] tracking reveal ignored reason=\(reason, privacy: .public) branch=no-location visible=\(isPresentationHeaderVisible) topEdge=\(isPresentationHeaderRevealedByTopEdge)")
            return
        }

        let isInRevealBand = location.y >= 0 && location.y <= EasyMirroringPresentationMetrics.headerRevealHeight
        guard isInRevealBand else {
            SpecchioLogger.easyMode.debug("[EasyPresentationHeader] tracking reveal ignored reason=\(reason, privacy: .public) branch=outside-reveal-band y=\(location.y) revealHeight=\(EasyMirroringPresentationMetrics.headerRevealHeight) visible=\(isPresentationHeaderVisible) topEdge=\(isPresentationHeaderRevealedByTopEdge)")
            return
        }

        SpecchioLogger.easyMode.info("[EasyPresentationHeader] tracking reveal forwarding reason=\(reason, privacy: .public) y=\(location.y) revealHeight=\(EasyMirroringPresentationMetrics.headerRevealHeight) visible=\(isPresentationHeaderVisible) topEdge=\(isPresentationHeaderRevealedByTopEdge)")
        updatePresentationHeaderTopEdge(location: location, reason: reason)
    }

    private func handlePresentationWindowFocusChanged(
        isKey: Bool,
        isApplicationActive: Bool,
        reason: String
    ) {
        let keyChanged = isPresentationWindowKey != isKey
        let appActiveChanged = isPresentationApplicationActive != isApplicationActive
        isPresentationWindowKey = isKey
        isPresentationApplicationActive = isApplicationActive
        SpecchioLogger.easyMode.info("[EasyPresentationHeader] focus state reason=\(reason, privacy: .public) keyChanged=\(keyChanged) appActiveChanged=\(appActiveChanged) appActive=\(isApplicationActive) isKey=\(isKey) topEdge=\(isPresentationHeaderRevealedByTopEdge) visible=\(isPresentationHeaderVisible)")

        if !isApplicationActive || !isKey {
            resetPresentationHeaderReveal(reason: "\(reason)-inactive-or-not-key")
        }
    }

    private func normalizeEasyToolbarLayoutIfNeeded(reason: String) {
        let hasStoredVisibleOrder = UserDefaults.standard.object(forKey: AppSettings.Keys.easyToolbarVisibleCommandOrder) != nil
        let hasStoredOverflowOrder = UserDefaults.standard.object(forKey: AppSettings.Keys.easyToolbarOverflowCommandOrder) != nil
        let layout = EasyToolbarCommandLayout.fromStorage(
            visibleStorageValue: easyToolbarVisibleCommandOrder,
            overflowStorageValue: easyToolbarOverflowCommandOrder,
            legacyOrderStorageValue: easyToolbarCommandOrder,
            hasStoredVisibleOrder: hasStoredVisibleOrder,
            hasStoredOverflowOrder: hasStoredOverflowOrder
        )
        let nextVisibleValue = layout.visibleStorageValue
        let nextOverflowValue = layout.overflowStorageValue
        let nextLegacyValue = layout.legacyStorageValue
        let needsVisibleWrite = !hasStoredVisibleOrder || easyToolbarVisibleCommandOrder != nextVisibleValue
        let needsOverflowWrite = !hasStoredOverflowOrder || easyToolbarOverflowCommandOrder != nextOverflowValue
        let needsLegacyWrite = easyToolbarCommandOrder != nextLegacyValue

        guard needsVisibleWrite || needsOverflowWrite || needsLegacyWrite else {
            SpecchioLogger.easyMode.debug("[EasyToolbarLayout] normalized unchanged reason=\(reason, privacy: .public) visible=\(nextVisibleValue, privacy: .public) overflow=\(nextOverflowValue, privacy: .public) maxVisible=\(EasyToolbarCommandLayout.maximumVisibleCommandCount)")
            return
        }

        SpecchioLogger.easyMode.info("[EasyToolbarLayout] normalizing reason=\(reason, privacy: .public) hadVisibleKey=\(hasStoredVisibleOrder) hadOverflowKey=\(hasStoredOverflowOrder) fromVisible=\(easyToolbarVisibleCommandOrder, privacy: .public) fromOverflow=\(easyToolbarOverflowCommandOrder, privacy: .public) fromLegacy=\(easyToolbarCommandOrder, privacy: .public) toVisible=\(nextVisibleValue, privacy: .public) toOverflow=\(nextOverflowValue, privacy: .public) maxVisible=\(EasyToolbarCommandLayout.maximumVisibleCommandCount)")

        if needsVisibleWrite {
            easyToolbarVisibleCommandOrder = nextVisibleValue
        }
        if needsOverflowWrite {
            easyToolbarOverflowCommandOrder = nextOverflowValue
        }
        if needsLegacyWrite {
            easyToolbarCommandOrder = nextLegacyValue
        }
    }

    private func updatePresentationHeaderNativeControlsLeadingPadding(_ leadingPadding: CGFloat, reason: String) {
        let sanitizedPadding = max(0, leadingPadding)
        guard abs(presentationHeaderNativeControlsLeadingPadding - sanitizedPadding) > 0.5 else {
            SpecchioLogger.easyMode.debug("[EasyPresentationHeader] native controls padding unchanged reason=\(reason, privacy: .public) leadingPadding=\(sanitizedPadding)")
            return
        }

        SpecchioLogger.easyMode.info("[EasyPresentationHeader] native controls padding changed reason=\(reason, privacy: .public) from=\(presentationHeaderNativeControlsLeadingPadding) to=\(sanitizedPadding)")
        presentationHeaderNativeControlsLeadingPadding = sanitizedPadding
    }

    private func disconnectEasyVideoStream(source: String) {
        let hadReplayKitFrame = stream.currentFrame != nil
        let hadAirPlayFrame = airPlayStream.currentFrame != nil
        let hadNativeFrame = iosScreenCapture.currentFrame != nil
        let hadStartupTask = replayKitStartupTask != nil
        let previousSource = appState.activeVideoSource
        SpecchioLogger.easyMode.info("[EasyDisconnect] requested source=\(source, privacy: .public) previousSource=\(previousSource.diagnosticName, privacy: .public) replayKitListening=\(stream.isListening) replayKitClientConnected=\(stream.isClientConnected) replayKitFrame=\(hadReplayKitFrame) airPlayAdvertising=\(airPlayStream.isAdvertising) airPlayClientConnected=\(airPlayStream.isClientConnected) airPlayFrame=\(hadAirPlayFrame) usbCapturing=\(iosScreenCapture.isCapturing) usbFrame=\(hadNativeFrame) startupTask=\(hadStartupTask)")
        resetAllBluetoothAutoConnectVideoStartAttempts(reason: "Easy disconnect command from \(source)")

        if hadStartupTask {
            SpecchioLogger.easyMode.info("[EasyDisconnect] cancelling ReplayKit startup task source=\(source, privacy: .public)")
            replayKitStartupTask?.cancel()
            replayKitStartupTask = nil
        } else {
            SpecchioLogger.easyMode.debug("[EasyDisconnect] startup task cancel skipped source=\(source, privacy: .public) branch=no-task")
        }

        hideVideoPremiumOverlay(trigger: "Easy disconnect command from \(source)", resetPresentation: true)
        appState.lastVideoFallbackReason = nil
        isUSBNativeStartDeferred = false
        selectedVideoSourceCardKind = nil
        endUSBNativeIsolation(reason: "Easy disconnect command from \(source)", restartAirPlay: false)
        resetPresentationHeaderReveal(reason: "disconnect-stream-\(source)")
        bluetoothHIDPanel.setReplayKitInputForwardingEnabled(false, reason: "Easy disconnect command from \(source)")

        appState.activeVideoSource = .none
        if hadReplayKitFrame {
            SpecchioLogger.easyMode.info("[EasyDisconnect] clearing ReplayKit frame source=\(source, privacy: .public)")
        } else {
            SpecchioLogger.easyMode.debug("[EasyDisconnect] ReplayKit frame clear skipped source=\(source, privacy: .public) branch=no-frame")
        }
        stream.currentFrame = nil

        if hadAirPlayFrame {
            SpecchioLogger.easyMode.info("[EasyDisconnect] clearing AirPlay frame source=\(source, privacy: .public)")
        } else {
            SpecchioLogger.easyMode.debug("[EasyDisconnect] AirPlay frame clear skipped source=\(source, privacy: .public) branch=no-frame")
        }
        airPlayStream.currentFrame = nil

        SpecchioLogger.easyMode.info("[EasyDisconnect] stopping stream managers source=\(source, privacy: .public)")
        iosScreenCapture.stopCapture(reason: "Easy disconnect command from \(source)", clearFrame: true)
        stream.stop()
        airPlayStream.stop()

        SpecchioLogger.easyMode.info("[EasyDisconnect] restarting Easy waiting receivers source=\(source, privacy: .public) autoStartNativeUSB=false")
        airPlayStream.start()
        startBestAvailableVideoSource(trigger: "disconnect command from \(source)", autoStartNativeUSB: false)
        updateBluetoothInputGate(trigger: "Easy disconnect command")
    }

    private func handleVideoSourceCardAction(_ kind: EasyVideoSourceCardKind) {
        selectedVideoSourceCardKind = kind
        SpecchioLogger.easyMode.info("[EasyVideoCards] action selected kind=\(kind.rawValue, privacy: .public) cards=\(videoSourceCardsLogSummary, privacy: .public)")

        switch kind {
        case .replayKit:
            handleReplayKitSourceCardAction()
        case .airPlay:
            handleAirPlaySourceCardAction()
        case .usbNative:
            handleUSBSourceCardAction()
        }
    }

    private func handleReplayKitSourceCardAction() {
        endUSBNativeIsolation(reason: "ReplayKit card selected", restartAirPlay: true)

        if stream.currentFrame != nil {
            appState.activeVideoSource = .replayKit
            appState.replayKitStream = stream
            SpecchioLogger.easyMode.info("[EasyVideoCards] ReplayKit card selected branch=show-existing-frame health=\(stream.streamHealth.diagnosticDescription, privacy: .public)")
            return
        }

        SpecchioLogger.easyMode.info("[EasyVideoCards] ReplayKit card selected branch=start-listener health=\(stream.streamHealth.diagnosticDescription, privacy: .public) listening=\(stream.isListening)")
        startReplayKitReceiver(trigger: "ReplayKit card")
    }

    private func handleAirPlaySourceCardAction() {
        endUSBNativeIsolation(reason: "AirPlay card selected", restartAirPlay: false)
        ensureAirPlayAdvertisingIfNeeded(trigger: "AirPlay card")

        if airPlayStream.currentFrame != nil || airPlayStream.currentPairingPIN != nil {
            appState.activeVideoSource = .airPlay
            appState.airPlayStream = airPlayStream
            SpecchioLogger.easyMode.info("[EasyVideoCards] AirPlay card selected branch=show-or-pair health=\(airPlayStream.streamHealth.diagnosticDescription, privacy: .public) framePresent=\(airPlayStream.currentFrame != nil) pinVisible=\(airPlayStream.currentPairingPIN != nil)")
            return
        }

        SpecchioLogger.easyMode.info("[EasyVideoCards] AirPlay card selected branch=advertise-only health=\(airPlayStream.streamHealth.diagnosticDescription, privacy: .public) advertising=\(airPlayStream.isAdvertising)")
    }

    private func handleUSBSourceCardAction() {
        iosScreenCaptureMonitor.refreshDevices(trigger: "EasyMode USB card")

        let usbHealth = iosScreenCapture.streamHealth

        if usbNativeIsolationStartupTask != nil {
            SpecchioLogger.easyMode.info("[EasyVideoCards] USB card selected branch=already-isolating health=\(usbHealth.diagnosticDescription, privacy: .public) replayKitListening=\(stream.isListening) airPlayAdvertising=\(airPlayStream.isAdvertising)")
            return
        }

        if case .live = usbHealth, iosScreenCapture.currentFrame != nil {
            appState.activeVideoSource = .iosScreenCaptureUSB
            appState.iosScreenCaptureStream = iosScreenCapture
            SpecchioLogger.easyMode.info("[EasyVideoCards] USB card selected branch=show-existing-frame health=\(usbHealth.diagnosticDescription, privacy: .public)")
            return
        }

        if iosScreenCapture.currentFrame != nil {
            SpecchioLogger.easyMode.info("[EasyVideoCards] USB card selected branch=retry-with-retained-frame health=\(usbHealth.diagnosticDescription, privacy: .public)")
        }

        if case .starting = usbHealth {
            SpecchioLogger.easyMode.info("[EasyVideoCards] USB card selected branch=already-starting health=\(usbHealth.diagnosticDescription, privacy: .public)")
            return
        }

        guard iosScreenCaptureMonitor.selectedDevice != nil else {
            SpecchioLogger.easyMode.info("[EasyVideoCards] USB card selected branch=no-selected-device availability=\(iosScreenCaptureMonitor.availability.diagnosticDescription, privacy: .public) diagnostic=\(iosScreenCaptureMonitor.diagnosticReason, privacy: .public)")
            return
        }

        SpecchioLogger.easyMode.info("[EasyVideoCards] USB card selected branch=start-native health=\(usbHealth.diagnosticDescription, privacy: .public) diagnostic=\(iosScreenCaptureMonitor.diagnosticReason, privacy: .public)")
        _ = startNativeUSBVideoIfAvailable(trigger: "USB card")
    }

    private func resetPresentationHeaderReveal(reason: String) {
        guard isPresentationHeaderRevealedByTopEdge else {
            SpecchioLogger.easyMode.debug("[EasyPresentationHeader] reset skipped reason=\(reason, privacy: .public) branch=already-hidden appActive=\(isPresentationApplicationActive) windowKey=\(isPresentationWindowKey)")
            return
        }

        isPresentationHeaderRevealedByTopEdge = false
        SpecchioLogger.easyMode.info("[EasyPresentationHeader] reset applied reason=\(reason, privacy: .public) appActive=\(isPresentationApplicationActive) windowKey=\(isPresentationWindowKey)")
    }

    private func handleReplayKitPremiumChanged(_ isPremium: Bool) {
        SpecchioLogger.easyMode.info("[EasyModeView] license premium changed premium=\(isPremium)")
        if isPremium {
            hideVideoPremiumOverlay(trigger: "license premium changed", resetPresentation: true)
        }
        applyUSBCaptureSettings(source: "EasyMode license changed")
        updateVideoPremiumOverlay(trigger: "license premium changed")
    }

    private func applyUSBCaptureSettings(source: String) {
        SpecchioLogger.iosScreenCapture.info("[EasyModeView] USB settings apply source=\(source, privacy: .public) configuredFPS=\(easyUSBTargetFPS)")
        iosScreenCapture.updateTargetFramesPerSecond(easyUSBTargetFPS, source: source)
    }

    private func startReplayKitReceiver(trigger: String) {
        startReplayKitReceiver(trigger: trigger, selectAsActiveSource: true)
    }

    private func startReplayKitReceiverInBackground(trigger: String) {
        startReplayKitReceiver(trigger: trigger, selectAsActiveSource: false)
    }

    private func startReplayKitReceiver(trigger: String, selectAsActiveSource: Bool) {
        SpecchioLogger.easyMode.info("[EasyModeView] ReplayKit receiver start requested trigger=\(trigger, privacy: .public) selectAsActiveSource=\(selectAsActiveSource) previousSource=\(appState.activeVideoSource.diagnosticName, privacy: .public)")
        if selectAsActiveSource {
            appState.activeVideoSource = .replayKit
        } else {
            SpecchioLogger.easyMode.info("[EasyModeView] ReplayKit receiver starting in background trigger=\(trigger, privacy: .public) preservedActiveSource=\(appState.activeVideoSource.diagnosticName, privacy: .public)")
        }
        appState.replayKitStream = stream
        SpecchioLogger.easyMode.info("[BluetoothAutoConnect] ReplayKit receiver start does not auto-connect until video becomes live trigger=\(trigger, privacy: .public)")
        stream.updateH264TargetFramesPerSecond(
            easyReplayKitH264TargetFPS,
            source: "EasyModeView start \(trigger)"
        )
        replayKitStartupTask?.cancel()
        replayKitStartupGeneration += 1
        let startupGeneration = replayKitStartupGeneration
        SpecchioLogger.easyMode.info("[EasyModeView] starting ReplayKit receiver immediately trigger=\(trigger, privacy: .public) startupGeneration=\(startupGeneration)")
        stream.startListening()

        replayKitStartupTask = Task { @MainActor in
            SpecchioLogger.easyMode.info("[EasyModeView] validating license for ReplayKit paywall state trigger=\(trigger, privacy: .public) startupGeneration=\(startupGeneration)")
            await licenseManager.validate()
            guard !Task.isCancelled else {
                SpecchioLogger.easyMode.info("[EasyModeView] ReplayKit paywall validation cancelled trigger=\(trigger, privacy: .public) startupGeneration=\(startupGeneration)")
                return
            }
            guard replayKitStartupGeneration == startupGeneration else {
                SpecchioLogger.easyMode.info("[EasyModeView] ReplayKit paywall validation ignored trigger=\(trigger, privacy: .public) startupGeneration=\(startupGeneration) currentGeneration=\(replayKitStartupGeneration)")
                return
            }

            replayKitStartupTask = nil
            SpecchioLogger.easyMode.info("[EasyModeView] ReplayKit paywall validation completed trigger=\(trigger, privacy: .public) premium=\(licenseManager.isPremium) startupGeneration=\(startupGeneration)")
            updateVideoPremiumOverlay(trigger: "ReplayKit paywall validation completed")
        }
    }

    private func startBestAvailableVideoSource(trigger: String, autoStartNativeUSB: Bool = true) {
        SpecchioLogger.iosScreenCapture.info("[EasyModeView] startBestAvailableVideoSource trigger=\(trigger, privacy: .public) currentSource=\(appState.activeVideoSource.diagnosticName, privacy: .public) autoStartNativeUSB=\(autoStartNativeUSB)")
        iosScreenCaptureMonitor.refreshDevices(trigger: "EasyMode \(trigger)")

        if !autoStartNativeUSB, let selected = iosScreenCaptureMonitor.selectedDevice {
            deferNativeUSBStart(
                selected: selected,
                trigger: trigger,
                reason: "initial USB capture waits for user tutorial"
            )
            return
        }

        if startNativeUSBVideoIfAvailable(trigger: trigger) {
            return
        }

        startReplayKitReceiverForFallback(trigger: "native unavailable during \(trigger): \(iosScreenCaptureMonitor.diagnosticReason)")
    }

    @discardableResult
    private func startNativeUSBVideoIfAvailable(trigger: String) -> Bool {
        guard let selected = iosScreenCaptureMonitor.selectedDevice else {
            SpecchioLogger.iosScreenCapture.info("[EasyModeView] native USB start skipped trigger=\(trigger, privacy: .public) reason=\(iosScreenCaptureMonitor.diagnosticReason, privacy: .public)")
            return false
        }

        isUSBNativeStartDeferred = false
        applyUSBCaptureSettings(source: "EasyMode \(trigger)")
        SpecchioLogger.iosScreenCapture.info("[EasyModeView] USB native start selected trigger=\(trigger, privacy: .public) configuredFPS=\(easyUSBTargetFPS) selected=\(selected.logSummary, privacy: .public)")
        appState.iosScreenCaptureStream = iosScreenCapture
        appState.activeVideoSource = .iosScreenCaptureUSB
        appState.lastVideoFallbackReason = nil
        SpecchioLogger.easyMode.info("[BluetoothAutoConnect] USB native start does not auto-connect until video becomes live trigger=\(trigger, privacy: .public)")
        beginIsolatedNativeUSBStart(selected: selected, trigger: trigger)
        return true
    }

    private func beginIsolatedNativeUSBStart(
        selected: IOSScreenCaptureDeviceDescriptor,
        trigger: String
    ) {
        let hadIsolationTask = usbNativeIsolationStartupTask != nil
        let hadReplayKitStartupTask = replayKitStartupTask != nil
        SpecchioLogger.iosScreenCapture.info("[EasyUSBIsolation] begin trigger=\(trigger, privacy: .public) hadIsolationTask=\(hadIsolationTask) replayKitListening=\(stream.isListening) replayKitClientConnected=\(stream.isClientConnected) replayKitFrame=\(stream.currentFrame != nil) replayKitStartupTask=\(hadReplayKitStartupTask) airPlayAdvertising=\(airPlayStream.isAdvertising) airPlayClientConnected=\(airPlayStream.isClientConnected) airPlayFrame=\(airPlayStream.currentFrame != nil) airPlayHealth=\(airPlayStream.streamHealth.diagnosticDescription, privacy: .public) selected=\(selected.logSummary, privacy: .public)")

        usbNativeIsolationStartupTask?.cancel()
        usbNativeIsolationStartupTask = nil
        isUSBNativeIsolationActive = true

        if hadReplayKitStartupTask {
            SpecchioLogger.iosScreenCapture.info("[EasyUSBIsolation] cancelling ReplayKit startup task before USB start trigger=\(trigger, privacy: .public)")
            replayKitStartupTask?.cancel()
            replayKitStartupTask = nil
            replayKitStartupGeneration += 1
        } else {
            SpecchioLogger.iosScreenCapture.info("[EasyUSBIsolation] ReplayKit startup task cancel skipped trigger=\(trigger, privacy: .public) branch=no-task")
        }

        SpecchioLogger.iosScreenCapture.info("[EasyUSBIsolation] stopping ReplayKit receiver before USB start trigger=\(trigger, privacy: .public) listening=\(stream.isListening) clientConnected=\(stream.isClientConnected)")
        stream.stop()

        SpecchioLogger.iosScreenCapture.info("[EasyUSBIsolation] stopping AirPlay receiver before USB start trigger=\(trigger, privacy: .public) advertising=\(airPlayStream.isAdvertising) clientConnected=\(airPlayStream.isClientConnected) health=\(airPlayStream.streamHealth.diagnosticDescription, privacy: .public)")
        airPlayStream.stop()

        usbNativeIsolationStartupTask = Task { @MainActor in
            let isolationReady = await waitForUSBIsolationReadiness(trigger: trigger)

            guard !Task.isCancelled else {
                SpecchioLogger.iosScreenCapture.info("[EasyUSBIsolation] USB start task cancelled before AVCapture start trigger=\(trigger, privacy: .public)")
                return
            }

            guard isUSBNativeIsolationActive else {
                SpecchioLogger.iosScreenCapture.info("[EasyUSBIsolation] USB start task skipped trigger=\(trigger, privacy: .public) reason=isolation-no-longer-active")
                usbNativeIsolationStartupTask = nil
                return
            }

            SpecchioLogger.iosScreenCapture.info("[EasyUSBIsolation] starting AVCapture after isolation trigger=\(trigger, privacy: .public) isolationReady=\(isolationReady) replayKitListening=\(stream.isListening) replayKitClientConnected=\(stream.isClientConnected) airPlayAdvertising=\(airPlayStream.isAdvertising) airPlayClientConnected=\(airPlayStream.isClientConnected)")
            iosScreenCapture.startCapture(deviceDescriptor: selected, trigger: "EasyMode isolated \(trigger)")
            updateBluetoothInputGate(trigger: "USB native isolated start requested")
            usbNativeIsolationStartupTask = nil
        }
    }

    @MainActor
    private func waitForUSBIsolationReadiness(trigger: String) async -> Bool {
        let startedAt = Date()

        while true {
            let elapsed = Date().timeIntervalSince(startedAt)
            let replayKitReady = !stream.isListening
                && !stream.isClientConnected
                && replayKitStartupTask == nil
                && stream.streamHealth == .idle
            let airPlayReady = !airPlayStream.isAdvertising
                && !airPlayStream.isClientConnected
                && airPlayStream.currentFrame == nil
                && airPlayStream.streamHealth == .idle

            if replayKitReady && airPlayReady {
                SpecchioLogger.iosScreenCapture.info("[EasyUSBIsolation] readiness reached trigger=\(trigger, privacy: .public) elapsed=\(String(format: "%.3f", elapsed), privacy: .public) replayKitReady=\(replayKitReady) replayKitHealth=\(stream.streamHealth.diagnosticDescription, privacy: .public) airPlayReady=\(airPlayReady) airPlayHealth=\(airPlayStream.streamHealth.diagnosticDescription, privacy: .public)")
                return true
            }

            if elapsed >= EasyUSBIsolationTiming.readinessTimeoutSeconds {
                SpecchioLogger.iosScreenCapture.warning("[EasyUSBIsolation] readiness timeout trigger=\(trigger, privacy: .public) elapsed=\(String(format: "%.3f", elapsed), privacy: .public) replayKitReady=\(replayKitReady) replayKitListening=\(stream.isListening) replayKitClientConnected=\(stream.isClientConnected) replayKitStartupTask=\(replayKitStartupTask != nil) replayKitHealth=\(stream.streamHealth.diagnosticDescription, privacy: .public) airPlayReady=\(airPlayReady) airPlayAdvertising=\(airPlayStream.isAdvertising) airPlayClientConnected=\(airPlayStream.isClientConnected) airPlayFrame=\(airPlayStream.currentFrame != nil) airPlayHealth=\(airPlayStream.streamHealth.diagnosticDescription, privacy: .public)")
                return false
            }

            SpecchioLogger.iosScreenCapture.debug("[EasyUSBIsolation] waiting for readiness trigger=\(trigger, privacy: .public) elapsed=\(String(format: "%.3f", elapsed), privacy: .public) replayKitReady=\(replayKitReady) replayKitHealth=\(stream.streamHealth.diagnosticDescription, privacy: .public) airPlayReady=\(airPlayReady) airPlayHealth=\(airPlayStream.streamHealth.diagnosticDescription, privacy: .public)")
            try? await Task.sleep(nanoseconds: EasyUSBIsolationTiming.readinessPollNanoseconds)
        }
    }

    private func endUSBNativeIsolation(reason: String, restartAirPlay: Bool) {
        let hadTask = usbNativeIsolationStartupTask != nil
        let wasActive = isUSBNativeIsolationActive

        guard hadTask || wasActive else {
            SpecchioLogger.iosScreenCapture.debug("[EasyUSBIsolation] end skipped reason=\(reason, privacy: .public) branch=not-active restartAirPlay=\(restartAirPlay)")
            return
        }

        SpecchioLogger.iosScreenCapture.info("[EasyUSBIsolation] end requested reason=\(reason, privacy: .public) restartAirPlay=\(restartAirPlay) hadTask=\(hadTask) wasActive=\(wasActive) replayKitListening=\(stream.isListening) airPlayAdvertising=\(airPlayStream.isAdvertising)")
        usbNativeIsolationStartupTask?.cancel()
        usbNativeIsolationStartupTask = nil
        isUSBNativeIsolationActive = false

        if restartAirPlay {
            SpecchioLogger.iosScreenCapture.info("[EasyUSBIsolation] restarting AirPlay waiting receiver reason=\(reason, privacy: .public)")
            airPlayStream.start()
            ensureAirPlayAdvertisingIfNeeded(trigger: "USB isolation ended: \(reason)")
        } else {
            SpecchioLogger.iosScreenCapture.info("[EasyUSBIsolation] AirPlay restart skipped reason=\(reason, privacy: .public) restartAirPlay=false")
        }
    }

    private func deferNativeUSBStart(
        selected: IOSScreenCaptureDeviceDescriptor,
        trigger: String,
        reason: String
    ) {
        isUSBNativeStartDeferred = true
        appState.lastVideoFallbackReason = nil
        iosScreenCapture.stopCapture(reason: "deferred USB native start: \(reason)", clearFrame: true)
        SpecchioLogger.iosScreenCapture.info("[EasyModeView] native USB start deferred trigger=\(trigger, privacy: .public) reason=\(reason, privacy: .public) selected=\(selected.logSummary, privacy: .public) activeSource=\(appState.activeVideoSource.diagnosticName, privacy: .public) replayKitListening=\(stream.isListening)")

        switch appState.activeVideoSource {
        case .replayKit:
            if stream.isListening {
                SpecchioLogger.iosScreenCapture.info("[EasyModeView] ReplayKit receiver kept alive while USB native start is deferred trigger=\(trigger, privacy: .public)")
            } else {
                startReplayKitReceiver(trigger: "USB native deferred while ReplayKit active: \(reason)")
            }
        case .none, .iosScreenCaptureUSB:
            startReplayKitReceiverForFallback(trigger: "USB native deferred: \(reason)")
        case .airPlay, .screenshot, .mjpeg, .h264:
            SpecchioLogger.iosScreenCapture.info("[EasyModeView] preserving active video source while USB native start is deferred trigger=\(trigger, privacy: .public) activeSource=\(appState.activeVideoSource.diagnosticName, privacy: .public)")
        }
    }

    private func startDeferredNativeUSBVideo(trigger: String) {
        SpecchioLogger.iosScreenCapture.info("[EasyModeView] deferred native USB start requested trigger=\(trigger, privacy: .public) ready=\(isUSBNativeReadyToStart) selectedAvailable=\(iosScreenCaptureMonitor.selectedDevice != nil)")
        guard iosScreenCaptureMonitor.selectedDevice != nil else {
            isUSBNativeStartDeferred = false
            SpecchioLogger.iosScreenCapture.info("[EasyModeView] deferred native USB start falling back trigger=\(trigger, privacy: .public) reason=no-selected-device-after-click")
            startBestAvailableVideoSource(trigger: "\(trigger) no USB candidate", autoStartNativeUSB: true)
            return
        }

        _ = startNativeUSBVideoIfAvailable(trigger: trigger)
    }

    private func startReplayKitReceiverForFallback(trigger: String) {
        SpecchioLogger.iosScreenCapture.info("[EasyModeView] fallback path selected source=ReplayKit trigger=\(trigger, privacy: .public)")
        appState.activeVideoSource = .replayKit
        startReplayKitReceiver(trigger: trigger)
    }

    private func fallbackFromNativeUSBVideo(reason: String) {
        SpecchioLogger.iosScreenCapture.info("[EasyModeView] fallback from USB native requested reason=\(reason, privacy: .public)")
        appState.lastVideoFallbackReason = reason
        endUSBNativeIsolation(reason: "USB native failed: \(reason)", restartAirPlay: true)

        Task { @MainActor in
            if stream.isListening || replayKitStartupTask != nil {
                SpecchioLogger.iosScreenCapture.info("[EasyModeView] USB native failure retained while ReplayKit stays available reason=\(reason, privacy: .public) replayKitListening=\(stream.isListening) startupTask=\(replayKitStartupTask != nil)")
            } else {
                SpecchioLogger.iosScreenCapture.info("[EasyModeView] USB native failure starting ReplayKit listener in background without clearing USB state reason=\(reason, privacy: .public)")
                startReplayKitReceiverInBackground(trigger: "USB native failed; keep ReplayKit available: \(reason)")
            }
        }
    }

    private func handleUSBAvailabilityChanged(
        _ availability: IOSScreenCaptureAvailability,
        trigger: String
    ) {
        SpecchioLogger.iosScreenCapture.info("[EasyModeView] USB native availability changed trigger=\(trigger, privacy: .public) availability=\(availability.diagnosticDescription, privacy: .public) activeSource=\(appState.activeVideoSource.diagnosticName, privacy: .public)")

        switch availability {
        case .available:
            guard appState.activeVideoSource != .iosScreenCaptureUSB else {
                SpecchioLogger.iosScreenCapture.info("[EasyModeView] USB native availability ignored reason=already-active")
                return
            }

            guard let selected = iosScreenCaptureMonitor.selectedDevice else {
                SpecchioLogger.iosScreenCapture.info("[EasyModeView] USB native availability ignored reason=no-selected-device trigger=\(trigger, privacy: .public) diagnostic=\(iosScreenCaptureMonitor.diagnosticReason, privacy: .public)")
                return
            }

            if activeVideoIsLive {
                SpecchioLogger.iosScreenCapture.info("[EasyModeView] USB native availability held reason=active-video-live-waits-for-user trigger=\(trigger, privacy: .public) activeSource=\(appState.activeVideoSource.diagnosticName, privacy: .public) selected=\(selected.logSummary, privacy: .public)")
                return
            }

            deferNativeUSBStart(
                selected: selected,
                trigger: trigger,
                reason: "USB became available while tutorial or waiting state is visible"
            )
        case .unavailable(let reason):
            if isUSBNativeStartDeferred {
                SpecchioLogger.iosScreenCapture.info("[EasyModeView] clearing deferred USB native start reason=availability-unavailable detail=\(reason, privacy: .public)")
            }
            isUSBNativeStartDeferred = false
            endUSBNativeIsolation(reason: "USB availability unavailable: \(reason)", restartAirPlay: true)
            if appState.activeVideoSource == .iosScreenCaptureUSB {
                fallbackFromNativeUSBVideo(reason: reason)
            } else if appState.activeVideoSource == .replayKit {
                updateVideoPremiumOverlay(trigger: "USB native unavailable: \(reason)")
            }
        case .unknown:
            SpecchioLogger.iosScreenCapture.info("[EasyModeView] USB native availability unknown; no source switch")
        }
    }

    private func handleIOSScreenCaptureHealthChanged(
        from oldValue: IOSScreenCaptureHealth,
        to newValue: IOSScreenCaptureHealth
    ) {
        SpecchioLogger.iosScreenCapture.info("[EasyModeView] USB native health changed from=\(oldValue.diagnosticDescription, privacy: .public) to=\(newValue.diagnosticDescription, privacy: .public)")
        updateBluetoothInputGate(trigger: "USB native health changed")

        if case .live = oldValue {
            if case .live = newValue {
                SpecchioLogger.easyMode.debug("[BluetoothAutoConnect] USB native video session kept active branch=still-live")
            } else {
                resetBluetoothAutoConnectVideoStartAttempt(
                    source: .iosScreenCaptureUSB,
                    reason: "USB native left live state to \(newValue.diagnosticDescription)"
                )
            }
        }

        if case .live = newValue {
            appState.activeVideoSource = .iosScreenCaptureUSB
            appState.iosScreenCaptureStream = iosScreenCapture
            appState.lastVideoFallbackReason = nil
            endUSBNativeIsolation(reason: "USB native became live", restartAirPlay: true)
            if stream.isListening {
                SpecchioLogger.iosScreenCapture.info("[EasyModeView] keeping ReplayKit receiver alive while USB native is live")
            } else {
                SpecchioLogger.iosScreenCapture.info("[EasyModeView] restarting ReplayKit receiver in background after isolated USB became live")
                startReplayKitReceiverInBackground(trigger: "USB native became live after isolation")
            }
        }
        maybeStartBluetoothAutoConnectForNativeUSB(from: oldValue, to: newValue)
    }

    private func handleAirPlayHealthChanged(
        from oldValue: AirPlayStreamHealth,
        to newValue: AirPlayStreamHealth
    ) {
        SpecchioLogger.easyMode.info("[EasyModeView] AirPlay health changed from=\(oldValue.diagnosticDescription, privacy: .public) to=\(newValue.diagnosticDescription, privacy: .public) framePresent=\(airPlayStream.currentFrame != nil) activeSource=\(appState.activeVideoSource.diagnosticName, privacy: .public)")
        updateBluetoothInputGate(trigger: "AirPlay health changed")

        switch newValue {
        case .receivingVideo:
            let previousSource = appState.activeVideoSource
            appState.activeVideoSource = .airPlay
            appState.airPlayStream = airPlayStream
            appState.lastVideoFallbackReason = nil
            SpecchioLogger.easyMode.info("[EasyModeView] active video source selected from=\(previousSource.diagnosticName, privacy: .public) to=airPlay reason=AirPlay receiving video framePresent=\(airPlayStream.currentFrame != nil) health=\(newValue.diagnosticDescription, privacy: .public)")
            maybeStartBluetoothAutoConnectForAirPlay(from: oldValue, to: newValue)
        case .failed(let reason):
            resetBluetoothAutoConnectVideoStartAttempt(
                source: .airPlay,
                reason: "AirPlay failed: \(reason)"
            )
            let previousSource = appState.activeVideoSource
            appState.activeVideoSource = .airPlay
            appState.airPlayStream = airPlayStream
            appState.lastVideoFallbackReason = reason
            SpecchioLogger.easyMode.info("[EasyModeView] active video source selected from=\(previousSource.diagnosticName, privacy: .public) to=airPlay reason=AirPlay failed visibleError=\(reason, privacy: .public)")
        case .screenOff(let lastFrameAge):
            let reason = "AirPlay screen off after \(String(format: "%.1f", lastFrameAge))s"
            let airPlayFramePresent = airPlayStream.currentFrame != nil
            let previousSource = appState.activeVideoSource
            SpecchioLogger.easyMode.info("[EasyModeView] AirPlay screen off inferred reason=\(reason, privacy: .public) activeSource=\(previousSource.diagnosticName, privacy: .public) airPlayFramePresent=\(airPlayFramePresent) mirrorPacketAge=\(airPlayMirrorPacketAgeSeconds ?? -1)")
            if airPlayFramePresent {
                appState.activeVideoSource = .airPlay
                appState.airPlayStream = airPlayStream
                appState.lastVideoFallbackReason = nil
                SpecchioLogger.easyMode.info("[EasyModeView] AirPlay screen off retained active source from=\(previousSource.diagnosticName, privacy: .public) to=airPlay branch=FRAME_PRESENT")
            } else {
                appState.lastVideoFallbackReason = reason
                SpecchioLogger.easyMode.info("[EasyModeView] AirPlay screen off branch=NO_FRAME_PRESENT reason=\(reason, privacy: .public)")
            }
        case .stale(let lastFrameAge):
            let reason = "AirPlay stale after \(String(format: "%.1f", lastFrameAge))s"
            let airPlayFramePresent = airPlayStream.currentFrame != nil
            let replayKitFramePresent = stream.currentFrame != nil
            SpecchioLogger.easyMode.info("[EasyModeView] AirPlay fallback considered reason=\(reason, privacy: .public) activeSource=\(appState.activeVideoSource.diagnosticName, privacy: .public) airPlayFramePresent=\(airPlayFramePresent) replayKitFramePresent=\(replayKitFramePresent)")
            if appState.activeVideoSource == .airPlay {
                if airPlayFramePresent {
                    appState.airPlayStream = airPlayStream
                    appState.lastVideoFallbackReason = reason
                    SpecchioLogger.easyMode.info("[EasyModeView] AirPlay stale retained active source branch=AIRPLAY_FRAME_PRESENT reason=\(reason, privacy: .public)")
                } else if replayKitFramePresent {
                    appState.activeVideoSource = .replayKit
                    appState.lastVideoFallbackReason = reason
                    SpecchioLogger.easyMode.info("[EasyModeView] AirPlay stale fallback branch=REPLAYKIT_FRAME_PRESENT reason=\(reason, privacy: .public)")
                } else {
                    appState.activeVideoSource = .none
                    appState.lastVideoFallbackReason = reason
                    SpecchioLogger.easyMode.info("[EasyModeView] AirPlay stale fallback branch=NO_FRAME_PRESENT reason=\(reason, privacy: .public)")
                }
            } else {
                SpecchioLogger.easyMode.info("[EasyModeView] AirPlay stale ignored branch=ACTIVE_SOURCE_NOT_AIRPLAY activeSource=\(appState.activeVideoSource.diagnosticName, privacy: .public) reason=\(reason, privacy: .public)")
            }
        case .disconnected(let reason):
            resetBluetoothAutoConnectVideoStartAttempt(
                source: .airPlay,
                reason: "AirPlay disconnected: \(reason)"
            )
            if appState.activeVideoSource == .airPlay {
                SpecchioLogger.easyMode.info("[EasyModeView] AirPlay disconnected; returning active source to ReplayKit waiting state reason=\(reason, privacy: .public)")
                appState.activeVideoSource = .replayKit
                appState.lastVideoFallbackReason = reason
            }
        default:
            break
        }

        updateVideoPremiumOverlay(trigger: "AirPlay health changed")
        ensureAirPlayAdvertisingIfNeeded(trigger: "AirPlay health changed")
    }

    private func handleAirPlayScreenOffOverlayVisibilityChanged(_ isVisible: Bool) {
        SpecchioLogger.easyMode.info("[EasyAirPlayScreenOff] overlay visibility changed visible=\(isVisible) activeSource=\(appState.activeVideoSource.diagnosticName, privacy: .public) frameAge=\(airPlayScreenOffFrameAgeSeconds ?? -1) mirrorPacketAge=\(airPlayMirrorPacketAgeSeconds ?? -1) health=\(airPlayStream.streamHealth.diagnosticDescription, privacy: .public) framePresent=\(airPlayStream.currentFrame != nil)")
    }

    private func handleAirPlayPairingPINChanged(from oldValue: String?, to newValue: String?) {
        let oldVisible = oldValue != nil
        let newVisible = newValue != nil
        SpecchioLogger.easyMode.info("[EasyModeView] AirPlay PIN visibility changed oldVisible=\(oldVisible) newVisible=\(newVisible) activeSource=\(appState.activeVideoSource.diagnosticName, privacy: .public)")

        if newVisible {
            let previousSource = appState.activeVideoSource
            appState.activeVideoSource = .airPlay
            appState.airPlayStream = airPlayStream
            appState.lastVideoFallbackReason = nil
            SpecchioLogger.easyMode.info("[EasyModeView] active video source selected from=\(previousSource.diagnosticName, privacy: .public) to=airPlay reason=AirPlay PIN requested pinDigits=\(newValue?.count ?? 0)")
        } else {
            SpecchioLogger.easyMode.info("[EasyModeView] AirPlay PIN hidden activeSource=\(appState.activeVideoSource.diagnosticName, privacy: .public) health=\(airPlayStream.streamHealth.diagnosticDescription, privacy: .public)")
        }
    }

    private func maybeStartBluetoothAutoConnectForAirPlay(
        from oldValue: AirPlayStreamHealth,
        to newValue: AirPlayStreamHealth
    ) {
        let didBecomeReceivingVideo: Bool
        if case .receivingVideo = newValue {
            if case .receivingVideo = oldValue {
                didBecomeReceivingVideo = false
            } else {
                didBecomeReceivingVideo = true
            }
        } else {
            didBecomeReceivingVideo = false
        }

        SpecchioLogger.easyMode.info("[BluetoothAutoConnect] AirPlay video-start trigger evaluated enabled=\(bluetoothAutoConnect) from=\(oldValue.diagnosticDescription, privacy: .public) to=\(newValue.diagnosticDescription, privacy: .public) didBecomeReceivingVideo=\(didBecomeReceivingVideo) activeSource=\(appState.activeVideoSource.diagnosticName, privacy: .public) connected=\(bluetoothHIDPanel.isBluetoothHIDConnected)")
        guard didBecomeReceivingVideo else {
            SpecchioLogger.easyMode.info("[BluetoothAutoConnect] AirPlay trigger skipped branch=not-video-start")
            return
        }

        requestBluetoothAutoConnectForVideoPath(
            source: .airPlay,
            trigger: "airplay-receiving-video"
        )
    }

    private func handleRotationMismatchWarningChanged(
        from oldValue: EasyRotationMismatchWarning?,
        to newValue: EasyRotationMismatchWarning?
    ) {
        if let newValue {
            if oldValue?.dismissalKey != newValue.dismissalKey {
                dismissedRotationMismatchWarningKey = nil
            }
            let phase = oldValue == nil ? "appeared" : "updated"
            recordRotationMismatchWarning(newValue, phase: phase)
        } else if let oldValue {
            dismissedRotationMismatchWarningKey = nil
            recordRotationMismatchWarning(oldValue, phase: "cleared")
        }
    }

    private func updateVideoPremiumOverlay(trigger: String) {
        let gateState = videoPremiumGateState
        let gateSourceText = gateState.source?.logName ?? "none"
        let overlaySourceText = videoPremiumOverlaySource?.logName ?? "none"
        let taskSourceText = videoPremiumOverlayTaskSource?.logName ?? "none"
        SpecchioLogger.easyMode.info("[EasyVideoPremiumGate] evaluate trigger=\(trigger, privacy: .public) eligible=\(gateState.eligible) gateSource=\(gateSourceText, privacy: .public) reason=\(gateState.reason, privacy: .public) visible=\(videoPremiumOverlaySource != nil) overlaySource=\(overlaySourceText, privacy: .public) alreadyPresented=\(videoPremiumOverlayWasPresented) timerActive=\(videoPremiumOverlayTask != nil) timerSource=\(taskSourceText, privacy: .public) activeSource=\(appState.activeVideoSource.diagnosticName, privacy: .public) premium=\(licenseManager.isPremium) replayKitFrame=\(stream.currentFrame != nil) usbFrame=\(iosScreenCapture.currentFrame != nil) airPlayFrame=\(airPlayStream.currentFrame != nil)")

        guard gateState.eligible, let source = gateState.source else {
            cancelVideoPremiumOverlayTimer(trigger: trigger, reason: gateState.reason)
            if let visibleSource = videoPremiumOverlaySource {
                videoPremiumOverlaySource = nil
                SpecchioLogger.easyMode.info("[EasyVideoPremiumGate] overlay hidden trigger=\(trigger, privacy: .public) source=\(visibleSource.logName, privacy: .public) reason=\(gateState.reason, privacy: .public)")
            } else {
                SpecchioLogger.easyMode.debug("[EasyVideoPremiumGate] overlay hide skipped trigger=\(trigger, privacy: .public) branch=not-visible reason=\(gateState.reason, privacy: .public)")
            }
            if videoPremiumOverlayWasPresented {
                videoPremiumOverlayWasPresented = false
                SpecchioLogger.easyMode.info("[EasyVideoPremiumGate] presentation reset trigger=\(trigger, privacy: .public) reason=\(gateState.reason, privacy: .public)")
            }
            return
        }

        if let visibleSource = videoPremiumOverlaySource, visibleSource != source {
            SpecchioLogger.easyMode.info("[EasyVideoPremiumGate] overlay source changed trigger=\(trigger, privacy: .public) from=\(visibleSource.logName, privacy: .public) to=\(source.logName, privacy: .public)")
            hideVideoPremiumOverlay(trigger: "\(trigger) source changed", resetPresentation: true)
        }

        guard videoPremiumOverlaySource == nil else {
            SpecchioLogger.easyMode.info("[EasyVideoPremiumGate] schedule skipped trigger=\(trigger, privacy: .public) source=\(source.logName, privacy: .public) reason=overlay-visible")
            return
        }

        if let timerSource = videoPremiumOverlayTaskSource, timerSource != source {
            cancelVideoPremiumOverlayTimer(
                trigger: trigger,
                reason: "source-changed-from-\(timerSource.logName)-to-\(source.logName)"
            )
        }

        guard !videoPremiumOverlayWasPresented else {
            SpecchioLogger.easyMode.info("[EasyVideoPremiumGate] schedule skipped trigger=\(trigger, privacy: .public) source=\(source.logName, privacy: .public) reason=already-presented")
            return
        }

        guard videoPremiumOverlayTask == nil else {
            SpecchioLogger.easyMode.info("[EasyVideoPremiumGate] schedule skipped trigger=\(trigger, privacy: .public) source=\(source.logName, privacy: .public) reason=timer-active")
            return
        }

        scheduleVideoPremiumOverlay(source: source, trigger: trigger)
    }

    private func scheduleVideoPremiumOverlay(source: EasyPremiumVideoGateSource, trigger: String) {
        SpecchioLogger.easyMode.info("[EasyVideoPremiumGate] timer scheduled trigger=\(trigger, privacy: .public) source=\(source.logName, privacy: .public) delaySeconds=\(EasyVideoPremiumGateMetrics.revealDelaySeconds)")
        videoPremiumOverlayTaskSource = source
        videoPremiumOverlayTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: EasyVideoPremiumGateMetrics.revealDelayNanoseconds)

            guard !Task.isCancelled else {
                SpecchioLogger.easyMode.info("[EasyVideoPremiumGate] timer cancelled before expiry trigger=\(trigger, privacy: .public) source=\(source.logName, privacy: .public)")
                return
            }

            videoPremiumOverlayTask = nil
            videoPremiumOverlayTaskSource = nil
            let gateState = videoPremiumGateState
            guard gateState.eligible, gateState.source == source else {
                SpecchioLogger.easyMode.info("[EasyVideoPremiumGate] timer expired without overlay trigger=\(trigger, privacy: .public) scheduledSource=\(source.logName, privacy: .public) currentSource=\(gateState.source?.logName ?? "none", privacy: .public) reason=\(gateState.reason, privacy: .public)")
                return
            }

            videoPremiumOverlayWasPresented = true
            videoPremiumOverlaySource = source
            SpecchioLogger.easyMode.info("[EasyVideoPremiumGate] overlay presented trigger=\(trigger, privacy: .public) source=\(source.logName, privacy: .public) reason=\(gateState.reason, privacy: .public)")
        }
    }

    private func cancelVideoPremiumOverlayTimer(trigger: String, reason: String) {
        guard let videoPremiumOverlayTask else {
            SpecchioLogger.easyMode.debug("[EasyVideoPremiumGate] timer cancel skipped trigger=\(trigger, privacy: .public) reason=\(reason, privacy: .public) branch=no-active-timer")
            return
        }

        let taskSourceText = videoPremiumOverlayTaskSource?.logName ?? "unknown"
        videoPremiumOverlayTask.cancel()
        self.videoPremiumOverlayTask = nil
        self.videoPremiumOverlayTaskSource = nil
        SpecchioLogger.easyMode.info("[EasyVideoPremiumGate] timer cancelled trigger=\(trigger, privacy: .public) source=\(taskSourceText, privacy: .public) reason=\(reason, privacy: .public)")
    }

    private func hideVideoPremiumOverlay(trigger: String, resetPresentation: Bool) {
        cancelVideoPremiumOverlayTimer(trigger: trigger, reason: "hide-requested")
        if let visibleSource = videoPremiumOverlaySource {
            videoPremiumOverlaySource = nil
            SpecchioLogger.easyMode.info("[EasyVideoPremiumGate] overlay hidden trigger=\(trigger, privacy: .public) source=\(visibleSource.logName, privacy: .public) resetPresentation=\(resetPresentation)")
        } else {
            SpecchioLogger.easyMode.debug("[EasyVideoPremiumGate] overlay hide skipped trigger=\(trigger, privacy: .public) branch=not-visible resetPresentation=\(resetPresentation)")
        }

        if resetPresentation {
            videoPremiumOverlayWasPresented = false
            SpecchioLogger.easyMode.info("[EasyVideoPremiumGate] presentation reset trigger=\(trigger, privacy: .public)")
        }
    }

    private func closeVideoPremiumOverlayAndDisconnect() {
        let source = videoPremiumOverlaySource ?? EasyPremiumVideoGateSource.make(from: appState.activeVideoSource)
        let sourceText = source?.logName ?? "unknown"
        SpecchioLogger.easyMode.info("[EasyVideoPremiumGate] close requested source=\(sourceText, privacy: .public) visible=\(videoPremiumOverlaySource != nil) activeSource=\(appState.activeVideoSource.diagnosticName, privacy: .public) replayKitListening=\(stream.isListening) replayKitClientConnected=\(stream.isClientConnected) replayKitFrame=\(stream.currentFrame != nil) usbCapturing=\(iosScreenCapture.isCapturing) usbFrame=\(iosScreenCapture.currentFrame != nil) airPlayAdvertising=\(airPlayStream.isAdvertising) airPlayClientConnected=\(airPlayStream.isClientConnected) airPlayFrame=\(airPlayStream.currentFrame != nil)")
        hideVideoPremiumOverlay(trigger: "\(sourceText) premium close", resetPresentation: true)

        guard let source else {
            SpecchioLogger.easyMode.info("[EasyVideoPremiumGate] close completed branch=no-source activeSource=\(appState.activeVideoSource.diagnosticName, privacy: .public)")
            updateBluetoothInputGate(trigger: "video premium close")
            return
        }

        appState.lastVideoFallbackReason = source.fallbackReason

        switch source {
        case .airPlay:
            closeAirPlayVideoAfterPremiumOverlay()
        case .replayKit:
            closeReplayKitVideoAfterPremiumOverlay()
        case .usbNative:
            closeUSBVideoAfterPremiumOverlay()
        }

        updateBluetoothInputGate(trigger: "\(source.logName) premium close")
    }

    private func closeAirPlayVideoAfterPremiumOverlay() {
        if appState.activeVideoSource == .airPlay {
            appState.activeVideoSource = .replayKit
            appState.replayKitStream = stream
            SpecchioLogger.easyMode.info("[EasyVideoPremiumGate] active source moved to ReplayKit after AirPlay premium close")
        } else {
            SpecchioLogger.easyMode.info("[EasyVideoPremiumGate] AirPlay close left active source unchanged source=\(appState.activeVideoSource.diagnosticName, privacy: .public)")
        }
        airPlayStream.currentFrame = nil
        airPlayStream.stop()
        airPlayStream.ensureAdvertising(source: "EasyMode AirPlay premium close")
    }

    private func closeReplayKitVideoAfterPremiumOverlay() {
        if appState.activeVideoSource == .replayKit {
            appState.replayKitStream = stream
            SpecchioLogger.easyMode.info("[EasyVideoPremiumGate] ReplayKit close retaining ReplayKit as waiting active source")
        } else {
            SpecchioLogger.easyMode.info("[EasyVideoPremiumGate] ReplayKit close left active source unchanged source=\(appState.activeVideoSource.diagnosticName, privacy: .public)")
        }
        stream.currentFrame = nil
        stream.stop()
        startReplayKitReceiverForFallback(trigger: "ReplayKit premium close")
    }

    private func closeUSBVideoAfterPremiumOverlay() {
        if appState.activeVideoSource == .iosScreenCaptureUSB {
            appState.activeVideoSource = .replayKit
            appState.replayKitStream = stream
            SpecchioLogger.easyMode.info("[EasyVideoPremiumGate] active source moved to ReplayKit after USB premium close")
        } else {
            SpecchioLogger.easyMode.info("[EasyVideoPremiumGate] USB close left active source unchanged source=\(appState.activeVideoSource.diagnosticName, privacy: .public)")
        }
        iosScreenCapture.stopCapture(reason: "Easy premium close: USB native", clearFrame: true)
        if stream.isListening || replayKitStartupTask != nil {
            SpecchioLogger.easyMode.info("[EasyVideoPremiumGate] ReplayKit waiting restart skipped after USB close listening=\(stream.isListening) startupTask=\(replayKitStartupTask != nil)")
        } else {
            startReplayKitReceiverForFallback(trigger: "USB premium close")
        }
    }

    private func completeVideoPremiumOverlayAfterActivation() {
        let sourceText = videoPremiumOverlaySource?.logName ?? "unknown"
        SpecchioLogger.easyMode.info("[EasyVideoPremiumGate] premium activation completed; keeping video connected source=\(sourceText, privacy: .public) activeSource=\(appState.activeVideoSource.diagnosticName, privacy: .public)")
        hideVideoPremiumOverlay(trigger: "\(sourceText) premium activation", resetPresentation: true)
    }

    private var videoPremiumOverlay: some View {
        let source = videoPremiumOverlaySource

        return ZStack {
            Rectangle()
                .fill(.black.opacity(0.72))
                .accessibilityHidden(true)

            PremiumUpsellView(
                closeAction: closeVideoPremiumOverlayAndDisconnect,
                completionAction: completeVideoPremiumOverlayAfterActivation
            )
            .background(.regularMaterial)
            .accessibilityLabel(source?.accessibilityLabel ?? "Premium required")
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .transition(.opacity)
        .onAppear {
            SpecchioLogger.easyMode.info("[EasyVideoPremiumGate] overlay view appeared source=\(source?.logName ?? "unknown", privacy: .public) activeSource=\(appState.activeVideoSource.diagnosticName, privacy: .public) replayKitFrame=\(stream.currentFrame != nil) usbFrame=\(iosScreenCapture.currentFrame != nil) airPlayFrame=\(airPlayStream.currentFrame != nil) premium=\(licenseManager.isPremium)")
        }
        .onDisappear {
            SpecchioLogger.easyMode.info("[EasyVideoPremiumGate] overlay view disappeared source=\(source?.logName ?? "unknown", privacy: .public) activeSource=\(appState.activeVideoSource.diagnosticName, privacy: .public) replayKitFrame=\(stream.currentFrame != nil) usbFrame=\(iosScreenCapture.currentFrame != nil) airPlayFrame=\(airPlayStream.currentFrame != nil) premium=\(licenseManager.isPremium)")
        }
    }

    private var phoneSurfaceContainer: some View {
        GeometryReader { geo in
            let availableSize = geo.size
            let layout = EasyPhoneSurfaceLayout.make(
                availableSize: availableSize,
                aspectRatio: phoneAspectRatio
            )

            rotatedPhoneSurface(displaySize: layout.phoneSize)
                .frame(width: layout.phoneSize.width, height: layout.phoneSize.height)
                .overlay {
                    if videoPremiumOverlaySource != nil {
                        videoPremiumOverlay
                    }
                }
                .modifier(EasyMirroringPhoneSurfacePresentation())
                .background(EasyWindowBinder(
                    phoneScreenSize: phoneScreenSize,
                    displayRotationDegrees: phoneDisplayRotationDegrees
                ) { window, frameInWindow, reportedRotationDegrees in
                    let contentBounds = window?.contentView?.bounds ?? .zero
                    let surfaceRightGap = contentBounds.width > 0 ? contentBounds.width - frameInWindow.maxX : -1
                    let surfaceBottomGap = contentBounds.height > 0 ? contentBounds.height - frameInWindow.maxY : -1
                    SpecchioLogger.easyMode.info("[EasyModeView] binding input surface windowPresent=\(window != nil) frameX=\(frameInWindow.origin.x) frameY=\(frameInWindow.origin.y) frameWidth=\(frameInWindow.width) frameHeight=\(frameInWindow.height) contentBoundsWidth=\(contentBounds.width) contentBoundsHeight=\(contentBounds.height) surfaceLeftGap=\(frameInWindow.minX) surfaceRightGap=\(surfaceRightGap) surfaceBottomGap=\(surfaceBottomGap) rotation=\(reportedRotationDegrees)")
                    bluetoothHIDPanel.bindInputSurface(
                        window: window,
                        frameInWindow: frameInWindow,
                        phoneScreenSize: phoneScreenSize,
                        displayRotationDegrees: reportedRotationDegrees
                    )
                })
                .background(EasyPhoneSurfaceSizeReader { size in
                    updatePhoneSurfaceSize(size, availableSize: availableSize, layout: layout)
                })
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .onAppear {
                    SpecchioLogger.easyMode.info("[EasyRotation] layout appeared rotation=\(phoneDisplayRotationDegrees) rawPhoneWidth=\(phoneScreenSize.width) rawPhoneHeight=\(phoneScreenSize.height) displayedPhoneWidth=\(displayedPhoneScreenSize.width) displayedPhoneHeight=\(displayedPhoneScreenSize.height) layoutWidth=\(layout.phoneSize.width) layoutHeight=\(layout.phoneSize.height)")
                    logPhoneSurfaceLayout(reason: "appear", availableSize: availableSize, layout: layout)
                }
                .onChange(of: availableSize) { _, newSize in
                    let newLayout = EasyPhoneSurfaceLayout.make(
                        availableSize: newSize,
                        aspectRatio: phoneAspectRatio
                    )
                    logPhoneSurfaceLayout(reason: "availableSizeChanged", availableSize: newSize, layout: newLayout)
                }
                .onChange(of: layout) { _, newLayout in
                    logPhoneSurfaceLayout(reason: "layoutChanged", availableSize: availableSize, layout: newLayout)
                }
                .onChange(of: phoneDisplayRotationDegrees) { _, newRotation in
                    SpecchioLogger.easyMode.info("[EasyRotation] display rotation changed rotation=\(newRotation) rawPhoneWidth=\(phoneScreenSize.width) rawPhoneHeight=\(phoneScreenSize.height) displayedPhoneWidth=\(displayedPhoneScreenSize.width) displayedPhoneHeight=\(displayedPhoneScreenSize.height) layoutWidth=\(layout.phoneSize.width) layoutHeight=\(layout.phoneSize.height)")
                    logPhoneSurfaceLayout(reason: "rotationChanged", availableSize: availableSize, layout: layout)
                }
        }
    }

    private func rotatedPhoneSurface(displaySize: CGSize) -> some View {
        let sourceSize = phoneRotationSourceSize(for: displaySize)

        return phoneSurface
            .frame(width: sourceSize.width, height: sourceSize.height)
            .rotationEffect(.degrees(Double(phoneDisplayRotationDegrees)))
            .frame(width: displaySize.width, height: displaySize.height)
            .clipped()
            .onAppear {
                SpecchioLogger.easyMode.info("[EasyRotation] visual surface appeared rotation=\(phoneDisplayRotationDegrees) sourceWidth=\(sourceSize.width) sourceHeight=\(sourceSize.height) displayWidth=\(displaySize.width) displayHeight=\(displaySize.height) invertedSize=\(isPhoneDisplaySideways)")
            }
    }

    private func phoneRotationSourceSize(for displaySize: CGSize) -> CGSize {
        guard isPhoneDisplaySideways else {
            SpecchioLogger.easyMode.debug("[EasyRotation] source size branch=upright rotation=\(phoneDisplayRotationDegrees) sourceWidth=\(displaySize.width) sourceHeight=\(displaySize.height) displayWidth=\(displaySize.width) displayHeight=\(displaySize.height)")
            return displaySize
        }

        let sourceSize = CGSize(width: displaySize.height, height: displaySize.width)
        SpecchioLogger.easyMode.debug("[EasyRotation] source size branch=sideways rotation=\(phoneDisplayRotationDegrees) sourceWidth=\(sourceSize.width) sourceHeight=\(sourceSize.height) displayWidth=\(displaySize.width) displayHeight=\(displaySize.height)")
        return sourceSize
    }

    private func rotatePhoneDisplay(source: String) {
        let currentRotation = normalizedScreenRotation(phoneDisplayRotationDegrees)
        let nextRotation = nextScreenRotation(after: currentRotation)
        let orientationChanges = isSidewaysRotation(currentRotation) != isSidewaysRotation(nextRotation)
        SpecchioLogger.easyMode.info("[EasyRotation] toggle selected source=\(source, privacy: .public) from=\(currentRotation) to=\(nextRotation) orientationChanges=\(orientationChanges) measuredSurfaceWidth=\(phoneSurfaceSize.width) measuredSurfaceHeight=\(phoneSurfaceSize.height) availableWidth=\(phoneSurfaceAvailableSize.width) availableHeight=\(phoneSurfaceAvailableSize.height)")
        phoneDisplayRotationDegrees = nextRotation
    }

    private func applyEasyPointerDefaultsIfNeeded() {
        guard !easyPointerDefaultsMigrated else { return }
        easyPointerSpikeEnabled = true
        easyPointerSpikeOverlayEnabled = false
        pointerSpikeVariant = AppSettings.EasyPointerSpikeTransport.absoluteMouse
        easyPointerDefaultsMigrated = true
        SpecchioLogger.easyMode.info("[EasyModeView] migrated Easy pointer defaults enabled=true overlay=false variant=\(AppSettings.EasyPointerSpikeTransport.absoluteMouse)")
    }

    private var phoneSurface: some View {
        ZStack {
            if let frame = activeFrame {
                Image(decorative: frame, scale: 1.0)
                    .resizable()
                    .interpolation(.none)
                    .aspectRatio(contentMode: .fit)
                    .blur(
                        radius: replayKitPrivacyBlurVisible ? EasyReplayKitPrivacyBlurMetrics.streamBlurRadius : 0,
                        opaque: true
                    )
                    .onAppear {
                        updatePhoneScreenSize(from: frame)
                    }
                    .onChange(of: stream.currentFrame) { _, newFrame in
                        if let newFrame {
                            updatePhoneScreenSize(from: newFrame)
                        }
                    }
                    .onChange(of: iosScreenCapture.currentFrame) { _, newFrame in
                        if let newFrame {
                            updatePhoneScreenSize(from: newFrame)
                        }
                    }
                    .onChange(of: airPlayStream.currentFrame) { _, newFrame in
                        if let newFrame {
                            updatePhoneScreenSize(from: newFrame)
                        }
                    }

                if !easyPointerSpikeEnabled {
                    EasyBluetoothGestureFeedbackOverlay(phoneScreenSize: phoneScreenSize)
                }

            } else {
                waitingView(snapshot: replayKitUISnapshot)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }

            EasyLocalCursorVisibilityBridge(hideCursor: easyHideLocalCursor)
                .allowsHitTesting(false)

            if easyPointerSpikeEnabled && easyPointerSpikeOverlayEnabled {
                EasyPointerSpikeOverlay(phoneScreenSize: phoneScreenSize)
                    .allowsHitTesting(false)
            }

            if replayKitPrivacyBlurVisible {
                EasyReplayKitPrivacyBlurVeil()
                    .allowsHitTesting(false)
                    .onAppear {
                        SpecchioLogger.easyMode.info("[EasyPrivacyBlur] veil appeared visible=true hasFrame=\(activeFrame != nil) activeSource=\(appState.activeVideoSource.diagnosticName, privacy: .public) blurRadius=\(EasyReplayKitPrivacyBlurMetrics.streamBlurRadius) veilOpacity=\(EasyReplayKitPrivacyBlurMetrics.veilOpacity)")
                    }
                    .onDisappear {
                        SpecchioLogger.easyMode.info("[EasyPrivacyBlur] veil disappeared enabled=\(replayKitPrivacyBlurEnabled) hasFrame=\(activeFrame != nil) activeSource=\(appState.activeVideoSource.diagnosticName, privacy: .public)")
                    }
            }

            if airPlayScreenOffOverlayVisible {
                EasyAirPlayScreenOffOverlay(lastFrameAgeSeconds: airPlayScreenOffFrameAgeSeconds)
                    .allowsHitTesting(false)
                    .transition(.opacity)
                    .onAppear {
                        SpecchioLogger.easyMode.info("[EasyAirPlayScreenOff] overlay appeared frameAge=\(airPlayScreenOffFrameAgeSeconds ?? -1) mirrorPacketAge=\(airPlayMirrorPacketAgeSeconds ?? -1) activeSource=\(appState.activeVideoSource.diagnosticName, privacy: .public) health=\(airPlayStream.streamHealth.diagnosticDescription, privacy: .public)")
                    }
                    .onDisappear {
                        SpecchioLogger.easyMode.info("[EasyAirPlayScreenOff] overlay disappeared frameAge=\(airPlayScreenOffFrameAgeSeconds ?? -1) mirrorPacketAge=\(airPlayMirrorPacketAgeSeconds ?? -1) activeSource=\(appState.activeVideoSource.diagnosticName, privacy: .public) health=\(airPlayStream.streamHealth.diagnosticDescription, privacy: .public)")
                    }
            }
        }
        .overlay(alignment: .top) {
            VStack(spacing: 8) {
                if let warning = visibleRotationMismatchWarning {
                    EasyRotationMismatchOverlay(warning: warning) {
                        dismissRotationMismatchWarning(warning)
                    }
                }

                if activeFrame != nil,
                   appState.activeVideoSource == .replayKit,
                   replayKitUISnapshot.showsRecoveryOverlay {
                    EasyReplayKitRecoveryOverlay(snapshot: replayKitUISnapshot) {
                        startReplayKitReceiver(trigger: "recovery overlay retry")
                    }
                    .transition(.opacity)
                }
            }
            .padding(.horizontal, 12)
            .padding(.top, 12)
        }
        .overlay(alignment: .bottom) {
            VStack(spacing: 8) {
                if let overlay = bluetoothHIDPanel.bluetoothAutoConnectOverlay {
                    EasyBluetoothAutoConnectOverlay(state: overlay) {
                        handleBluetoothAutoConnectOverlayTapped(overlay)
                    }
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 12)
        }
        .animation(.easeOut(duration: EasyMirroringPresentationMetrics.headerAnimationDuration), value: bluetoothHIDPanel.bluetoothAutoConnectOverlay)
        .clipped()
    }

    private var presentationHeader: some View {
        ZStack {
            if isPresentationHeaderVisible {
                presentationHeaderContent
                    .padding(.leading, presentationHeaderNativeControlsLeadingPadding)
                    .padding(.horizontal, EasyMirroringPresentationMetrics.headerHorizontalPadding)
                    .transition(.opacity)
            }
        }
        .frame(height: EasyMirroringPresentationMetrics.headerHeight)
        .frame(maxWidth: .infinity)
        .background {
            if isPresentationHeaderVisible {
                Rectangle()
                    .fill(.ultraThinMaterial)
            }
        }
        .background {
            if isPresentationHeaderVisible {
                EasyMirroringHeaderDragSurface()
            }
        }
        .background {
            EasyPresentationHeaderNativeControlsReader(
                standardControlsVisible: isPresentationHeaderVisible
            ) { leadingPadding, reason in
                updatePresentationHeaderNativeControlsLeadingPadding(
                    leadingPadding,
                    reason: reason
                )
            }
        }
        .overlay(alignment: .bottom) {
            if isPresentationHeaderVisible {
                Rectangle()
                    .fill(Color.black.opacity(EasyMirroringPresentationMetrics.headerSeparatorOpacity))
                    .frame(height: EasyMirroringPresentationMetrics.headerSeparatorHeight)
            }
        }
        .animation(.easeOut(duration: EasyMirroringPresentationMetrics.headerAnimationDuration), value: isPresentationHeaderVisible)
        .onAppear {
            SpecchioLogger.easyMode.info("[EasyPresentationHeader] installed height=\(EasyMirroringPresentationMetrics.headerHeight) revealHeight=\(EasyMirroringPresentationMetrics.headerRevealHeight) reservedTopChrome=\(EasyMirroringPresentationMetrics.reservedTopChromeHeight) hitSurface=rootContinuousHover nativeControlsLeadingPadding=\(presentationHeaderNativeControlsLeadingPadding)")
        }
    }

    private var presentationHeaderContent: some View {
        let layout = easyToolbarLayout
        return presentationHeaderCandidate(
            visibleCommands: layout.visibleCommands,
            overflowCommands: layout.overflowCommands
        )
    }

    private func presentationHeaderCandidate(
        visibleCommands: [EasyToolbarCommand],
        overflowCommands: [EasyToolbarCommand]
    ) -> some View {
        return HStack(spacing: EasyMirroringPresentationMetrics.headerItemSpacing) {
            Spacer(minLength: EasyControlBarMetrics.spacerMinimum)

            EasyToolbarCommandRow(
                visibleCommands: visibleCommands,
                overflowCommands: overflowCommands,
                bluetoothHIDPanel: bluetoothHIDPanel,
                phoneDisplayRotationDegrees: phoneDisplayRotationDegrees,
                replayKitPrivacyBlurEnabled: $replayKitPrivacyBlurEnabled,
                showEasyShortcutHelp: $showEasyShortcutHelp,
                rotateScreen: rotatePhoneDisplay,
                disconnectStream: disconnectEasyVideoStream
            )
        }
        .environment(\.colorScheme, .dark)
        .tint(.white)
        .onAppear {
            SpecchioLogger.easyMode.info("[EasyPresentationHeader] toolbar layout visibleCount=\(visibleCommands.count) overflowCount=\(overflowCommands.count) visibleCommands=\(EasyToolbarCommand.storageValue(for: visibleCommands), privacy: .public) overflowCommands=\(EasyToolbarCommand.storageValue(for: overflowCommands), privacy: .public) maxVisible=\(EasyToolbarCommandLayout.maximumVisibleCommandCount)")
        }
    }

    private var controlBar: some View {
        let layout = easyToolbarLayout
        return controlBarCandidate(
            visibleCommands: layout.visibleCommands,
            overflowCommands: layout.overflowCommands
        )
        .padding(.horizontal, EasyControlBarMetrics.outerHorizontalPadding)
        .padding(.vertical, EasyControlBarMetrics.outerVerticalPadding)
        .frame(maxWidth: .infinity)
        .background(.ultraThinMaterial)
        .background(EasyControlBarSizeReader { size in
            updateControlBarSize(size)
        })
        .zIndex(1)
    }

    private func controlBarCandidate(
        visibleCommands: [EasyToolbarCommand],
        overflowCommands: [EasyToolbarCommand]
    ) -> some View {
        HStack(spacing: EasyControlBarMetrics.outerSpacing) {
            bluetoothPanelButton

            Spacer(minLength: EasyControlBarMetrics.spacerMinimum)

            EasyToolbarCommandRow(
                visibleCommands: visibleCommands,
                overflowCommands: overflowCommands,
                bluetoothHIDPanel: bluetoothHIDPanel,
                phoneDisplayRotationDegrees: phoneDisplayRotationDegrees,
                replayKitPrivacyBlurEnabled: $replayKitPrivacyBlurEnabled,
                showEasyShortcutHelp: $showEasyShortcutHelp,
                rotateScreen: rotatePhoneDisplay,
                disconnectStream: disconnectEasyVideoStream
            )
        }
        .onAppear {
            SpecchioLogger.easyMode.info("[EasyControlBar] toolbar layout visibleCount=\(visibleCommands.count) overflowCount=\(overflowCommands.count) visibleCommands=\(EasyToolbarCommand.storageValue(for: visibleCommands), privacy: .public) overflowCommands=\(EasyToolbarCommand.storageValue(for: overflowCommands), privacy: .public) maxVisible=\(EasyToolbarCommandLayout.maximumVisibleCommandCount)")
        }
    }

    private var bluetoothPanelButton: some View {
        Button {
            requestBluetoothSetupFromEasy(source: "presentation-header")
        } label: {
            Image(systemName: "keyboard")
                .frame(width: EasyControlBarMetrics.buttonSide, height: EasyControlBarMetrics.buttonSide)
        }
        .buttonStyle(.borderless)
        .help("Open Bluetooth HID controls")
    }

    private func handleBluetoothAutoConnectOverlayTapped(_ state: BluetoothAutoConnectOverlayState) {
        SpecchioLogger.easyMode.info("[BluetoothAutoConnectOverlay] tapped \(state.diagnosticDescription, privacy: .public) opensSetupTutorial=\(state.opensSetupTutorial)")
        guard state.opensSetupTutorial else {
            SpecchioLogger.easyMode.info("[BluetoothAutoConnectOverlay] tap ignored branch=no-action phase=\(state.phase.rawValue, privacy: .public)")
            return
        }

        SpecchioLogger.easyMode.info("[BluetoothAutoConnectOverlay] opening setup tutorial branch=airplay-no-saved-device")
        setupTutorial.show()
    }

    private func requestBluetoothSetupFromEasy(source: String) {
        SpecchioLogger.easyMode.info("[BluetoothAutoConnect] Bluetooth setup requested source=\(source, privacy: .public) preference=\(bluetoothAutoConnect) connected=\(bluetoothHIDPanel.isBluetoothHIDConnected)")
        SpecchioLogger.easyMode.info("[EasyModeView] Bluetooth HID panel requested source=\(source, privacy: .public)")
        bluetoothHIDPanel.show()
        SpecchioLogger.easyMode.info("[BluetoothAutoConnect] Bluetooth setup panel opened without auto-connect source=\(source, privacy: .public) branch=manual-panel-open")
    }

    private func updateControlBarSize(_ size: CGSize) {
        if abs(controlBarHeight - size.height) > 0.5 {
            SpecchioLogger.easyMode.info("[EasyModeView] control bar height=\(size.height)")
            controlBarHeight = size.height
        }

        guard abs(controlBarWidth - size.width) > 0.5 else { return }
        SpecchioLogger.easyMode.info("[EasyControlBar] width=\(size.width) reservedHeight=\(EasyControlBarMetrics.windowReservedHeight) path=stored-toolbar-buckets maxVisible=\(EasyToolbarCommandLayout.maximumVisibleCommandCount)")
        controlBarWidth = size.width
    }

    private func updatePhoneScreenSize(from frame: CGImage) {
        let size = CGSize(width: frame.width, height: frame.height)
        guard size != phoneScreenSize else { return }
        let previousSize = phoneScreenSize
        let previousOrientation = InputSurfaceDiagnostics.orientationString(previousSize)
        let nextOrientation = InputSurfaceDiagnostics.orientationString(size)
        let orientationChanged = previousOrientation != nextOrientation
        SpecchioLogger.easyMode.info("[EasyInputSurface] active video frame size changed source=\(appState.activeVideoSource.diagnosticName, privacy: .public) previousWidth=\(previousSize.width) previousHeight=\(previousSize.height) nextWidth=\(size.width) nextHeight=\(size.height) previousOrientation=\(previousOrientation, privacy: .public) nextOrientation=\(nextOrientation, privacy: .public) orientationChanged=\(orientationChanged) displayRotation=\(phoneDisplayRotationDegrees) measuredSurfaceWidth=\(phoneSurfaceSize.width) measuredSurfaceHeight=\(phoneSurfaceSize.height)")
        FrameDropDiagnostics.shared.recordLifecycle(
            source: "easyInputSurface",
            event: "activeVideoFrameSizeChanged",
            reason: "active-frame-size-change",
            details: [
                "activeSource": appState.activeVideoSource.diagnosticName,
                "previousFrameWidth": String(Int(previousSize.width.rounded())),
                "previousFrameHeight": String(Int(previousSize.height.rounded())),
                "nextFrameWidth": String(Int(size.width.rounded())),
                "nextFrameHeight": String(Int(size.height.rounded())),
                "previousOrientation": previousOrientation,
                "nextOrientation": nextOrientation,
                "orientationChanged": String(orientationChanged),
                "displayRotation": String(EasyWindowVideoSizing.normalizedRotation(phoneDisplayRotationDegrees)),
                "measuredSurfaceWidth": String(Int(phoneSurfaceSize.width.rounded())),
                "measuredSurfaceHeight": String(Int(phoneSurfaceSize.height.rounded())),
                "availableSurfaceWidth": String(Int(phoneSurfaceAvailableSize.width.rounded())),
                "availableSurfaceHeight": String(Int(phoneSurfaceAvailableSize.height.rounded()))
            ]
        )
        phoneScreenSize = size
        bluetoothHIDPanel.bindPointerSurface(
            phoneScreenSize: size,
            reason: orientationChanged ? "easy-active-frame-orientation-changed" : "easy-active-frame-size-changed"
        )
    }

    private func updatePhoneSurfaceSize(
        _ size: CGSize,
        availableSize: CGSize,
        layout: EasyPhoneSurfaceLayout
    ) {
        let surfaceChanged = abs(phoneSurfaceSize.width - size.width) > 0.5
            || abs(phoneSurfaceSize.height - size.height) > 0.5
        let availableChanged = abs(phoneSurfaceAvailableSize.width - availableSize.width) > 0.5
            || abs(phoneSurfaceAvailableSize.height - availableSize.height) > 0.5

        guard surfaceChanged || availableChanged else { return }

        let cornerRadius = EasyMirroringPhoneSurfaceGeometry.cornerRadius(for: size)
        SpecchioLogger.easyMode.info("[EasyGeometry] surface measured branch=\(layout.branch.rawValue, privacy: .public) surfaceWidth=\(size.width) surfaceHeight=\(size.height) availableWidth=\(availableSize.width) availableHeight=\(availableSize.height) rootWidth=\(viewSize.width) rootHeight=\(viewSize.height) controlBarHeight=\(controlBarHeight) horizontalUnused=\(layout.horizontalUnused) verticalUnused=\(layout.verticalUnused) leadingAlignedRightGap=\(layout.horizontalUnused) cornerBasis=short-edge cornerRadius=\(cornerRadius)")
        phoneSurfaceSize = size
        phoneSurfaceAvailableSize = availableSize
    }

    private func logPhoneSurfaceLayout(
        reason: String,
        availableSize: CGSize,
        layout: EasyPhoneSurfaceLayout
    ) {
        let cornerRadius = EasyMirroringPhoneSurfaceGeometry.cornerRadius(for: layout.phoneSize)
        SpecchioLogger.easyMode.info("[EasyGeometry] layout reason=\(reason, privacy: .public) branch=\(layout.branch.rawValue, privacy: .public) availableWidth=\(availableSize.width) availableHeight=\(availableSize.height) rootWidth=\(viewSize.width) rootHeight=\(viewSize.height) phoneWidth=\(layout.phoneSize.width) phoneHeight=\(layout.phoneSize.height) horizontalUnused=\(layout.horizontalUnused) verticalUnused=\(layout.verticalUnused) ratio=\(phoneAspectRatio) cornerBasis=short-edge cornerRadius=\(cornerRadius)")
    }

    private func recordRotationMismatchWarning(
        _ warning: EasyRotationMismatchWarning,
        phase: String
    ) {
        SpecchioLogger.easyMode.info("[EasyRotationWarning] phase=\(phase, privacy: .public) source=\(warning.source, privacy: .public) reason=\(warning.reason, privacy: .public) detail=\(warning.detail, privacy: .public) key=\(warning.dismissalKey, privacy: .public)")
        FrameDropDiagnostics.shared.recordLifecycle(
            source: "easyInputSurface",
            event: "rotationMismatchWarning",
            reason: warning.reason,
            details: [
                "phase": phase,
                "source": warning.source,
                "title": warning.title,
                "message": warning.message,
                "detail": warning.detail,
                "dismissalKey": warning.dismissalKey
            ],
            severity: "warning"
        )
    }

    private func dismissRotationMismatchWarning(_ warning: EasyRotationMismatchWarning) {
        dismissedRotationMismatchWarningKey = warning.dismissalKey
        SpecchioLogger.easyMode.info("[EasyRotationWarning] phase=dismissed source=\(warning.source, privacy: .public) reason=\(warning.reason, privacy: .public) detail=\(warning.detail, privacy: .public) key=\(warning.dismissalKey, privacy: .public)")
        FrameDropDiagnostics.shared.recordLifecycle(
            source: "easyInputSurface",
            event: "rotationMismatchWarningDismissed",
            reason: warning.reason,
            details: [
                "source": warning.source,
                "title": warning.title,
                "message": warning.message,
                "detail": warning.detail,
                "dismissalKey": warning.dismissalKey
            ],
            severity: "info"
        )
    }

    private func waitingView(snapshot: EasyReplayKitUISnapshot) -> some View {
        VStack(spacing: 24) {
            ModeMirrorLogoForEasy(mouseLocation: mouseLocation, parentSize: viewSize)

            Text("Specchio")
                .font(.largeTitle.weight(.bold))
                .swGlowSweep(
                    baseColor: .gray,
                    glowColor: .white,
                    duration: 2.0,
                    bandWidth: 150,
                    debugName: "easy-waiting-title"
                )
                .onAppear {
                    SpecchioLogger.easyMode.info("[EasyGlowSweep] waiting title installed text=Specchio source=ShipSwift")
                }
            Text("Choose the way you are going to connect to Specchio")
                .font(.headline)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 420)

            videoSourceControlStrip

            SpecchioSetupTutorialButton(tutorial: setupTutorial)

            SWPlasmaActionButton(
                title: bluetoothSetupButtonTitle,
                systemImage: "keyboard",
                foregroundColor: .white,
                style: .prism,
                c1: .specchioPlasmaRGB(0x2A0A4A),
                c2: .specchioPlasmaRGB(0x6B4FA0),
                c3: .specchioPlasmaRGB(0x0288FF),
                c4: .specchioPlasmaRGB(0x000387),
                c5: .specchioPlasmaRGB(0x000387),
                scale: 1.25,
                intensity: 1.1,
                distortion: 1.0,
                accessibilityLabel: bluetoothSetupButtonTitle,
                debugName: "easy-bluetooth-button"
            ) {
                SpecchioLogger.easyMode.info("[EasyModeView] Bluetooth HID setup button tapped connected=\(bluetoothHIDPanel.isBluetoothHIDConnected) label=\(bluetoothSetupButtonTitle, privacy: .public)")
                requestBluetoothSetupFromEasy(source: "waiting-state-button")
            }
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 32)
    }

    @ViewBuilder
    private var videoSourceControlStrip: some View {
        VStack(spacing: 10) {
            ForEach(videoSourceCards) { card in
                Button {
                    handleVideoSourceCardAction(card.kind)
                } label: {
                    EasyVideoSourceCard(state: card)
                }
                .buttonStyle(.plain)
                .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .help(card.help)
                .accessibilityLabel(card.accessibilityLabel)
            }
        }
        .frame(maxWidth: 420)
        .onAppear {
            SpecchioLogger.easyMode.info("[EasyVideoCards] appeared \(videoSourceCardsLogSummary, privacy: .public)")
        }
    }
}

private struct EasyVideoSourceCard: View {
    let state: EasyVideoSourceCardState

    private var cardOpacity: Double {
        state.isDimmed ? 0.66 : 1.0
    }

    private var cardSaturation: Double {
        state.isDimmed ? 0.72 : 1.0
    }

    private var strokeOpacity: Double {
        if state.isDisplayed {
            return state.isDimmed ? 0.30 : 0.55
        }
        return state.isDimmed ? 0.14 : 0.24
    }

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: state.systemImage)
                .font(.system(size: 22, weight: .semibold))
                .foregroundColor(state.dotColor)
                .frame(width: 30, height: 30)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Circle()
                        .fill(state.dotColor)
                        .frame(width: 7, height: 7)

                    Text(state.title)
                        .font(.caption.weight(.semibold))
                        .foregroundColor(.secondary)

                    if state.isDisplayed {
                        Text("Displayed")
                            .font(.caption2.weight(.semibold))
                            .foregroundColor(state.dotColor)
                    }
                }

                Text(state.status)
                    .font(.headline)
                    .lineLimit(1)

                Text(state.detail)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .lineLimit(2)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Text(state.actionTitle)
                .font(.caption.weight(.semibold))
                .foregroundColor(state.dotColor)
                .frame(minWidth: 52, alignment: .trailing)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.3))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(state.dotColor.opacity(strokeOpacity), lineWidth: 1)
        }
        .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .saturation(cardSaturation)
        .opacity(cardOpacity)
    }
}

private struct EasyLocalCursorVisibilityBridge: NSViewRepresentable {
    let hideCursor: Bool

    func makeNSView(context: Context) -> CursorBridgeView {
        let view = CursorBridgeView()
        view.hideCursor = hideCursor
        return view
    }

    func updateNSView(_ nsView: CursorBridgeView, context: Context) {
        nsView.hideCursor = hideCursor
        nsView.applyCursorState(reason: "update")
    }

    final class CursorBridgeView: NSView {
        var hideCursor = false {
            didSet {
                guard oldValue != hideCursor else { return }
                SpecchioLogger.easyMode.info("[EasyCursor] hideCursor updated enabled=\(self.hideCursor)")
                applyCursorState(reason: "setting-changed")
            }
        }

        private var trackingAreaRef: NSTrackingArea?
        private var isMouseInside = false
        private var isCursorHiddenByView = false
        private var windowObservers: [NSObjectProtocol] = []

        override var acceptsFirstResponder: Bool { false }

        override func hitTest(_ point: NSPoint) -> NSView? {
            nil
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            removeWindowObservers()
            if let window {
                windowObservers = [
                    NotificationCenter.default.addObserver(
                        forName: NSWindow.didBecomeKeyNotification,
                        object: window,
                        queue: .main
                    ) { [weak self] _ in
                        self?.applyCursorState(reason: "window-became-key")
                    },
                    NotificationCenter.default.addObserver(
                        forName: NSWindow.didResignKeyNotification,
                        object: window,
                        queue: .main
                    ) { [weak self] _ in
                        self?.applyCursorState(reason: "window-resigned-key")
                    }
                ]
            }
            applyCursorState(reason: "viewDidMoveToWindow")
        }

        override func updateTrackingAreas() {
            if let trackingAreaRef {
                removeTrackingArea(trackingAreaRef)
            }
            let trackingArea = NSTrackingArea(
                rect: .zero,
                options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                owner: self,
                userInfo: nil
            )
            addTrackingArea(trackingArea)
            trackingAreaRef = trackingArea
            super.updateTrackingAreas()
        }

        override func mouseEntered(with event: NSEvent) {
            isMouseInside = true
            applyCursorState(reason: "mouse-entered")
        }

        override func mouseExited(with event: NSEvent) {
            isMouseInside = false
            applyCursorState(reason: "mouse-exited")
        }

        func applyCursorState(reason: String) {
            let shouldHide = hideCursor && isMouseInside && window?.isKeyWindow == true
            if shouldHide {
                hideLocalCursor(reason: reason)
            } else {
                revealLocalCursor(reason: reason)
            }
        }

        private func hideLocalCursor(reason: String) {
            guard !isCursorHiddenByView else { return }
            NSCursor.hide()
            isCursorHiddenByView = true
            SpecchioLogger.easyMode.info("[EasyCursor] local cursor hidden reason=\(reason)")
        }

        private func revealLocalCursor(reason: String) {
            guard isCursorHiddenByView else { return }
            NSCursor.unhide()
            isCursorHiddenByView = false
            SpecchioLogger.easyMode.info("[EasyCursor] local cursor restored reason=\(reason)")
        }

        private func removeWindowObservers() {
            for observer in windowObservers {
                NotificationCenter.default.removeObserver(observer)
            }
            windowObservers.removeAll()
        }

        deinit {
            removeWindowObservers()
            revealLocalCursor(reason: "deinit")
        }
    }
}

private struct EasyBluetoothGestureFeedbackOverlay: NSViewRepresentable {
    let phoneScreenSize: CGSize

    func makeNSView(context: Context) -> GestureFeedbackView {
        let view = GestureFeedbackView()
        view.phoneScreenSize = phoneScreenSize
        return view
    }

    func updateNSView(_ nsView: GestureFeedbackView, context: Context) {
        nsView.phoneScreenSize = phoneScreenSize
    }

    final class GestureFeedbackView: NSView {
        var phoneScreenSize = CGSize(width: 390, height: 844)
        private var observer: NSObjectProtocol?
        private var pressLayer: CALayer?
        private var trailLayer: CAShapeLayer?
        private var trailPoints: [CGPoint] = []

        override var wantsLayer: Bool {
            get { true }
            set {}
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if observer == nil {
                observer = NotificationCenter.default.addObserver(
                    forName: .easyBluetoothPointerFeedback,
                    object: nil,
                    queue: .main
                ) { [weak self] note in
                    self?.handle(note)
                }
            }
        }

        deinit {
            if let observer {
                NotificationCenter.default.removeObserver(observer)
            }
        }

        private func handle(_ note: Notification) {
            guard let kind = note.userInfo?["kind"] as? String,
                  let x = note.userInfo?["x"] as? CGFloat,
                  let y = note.userInfo?["y"] as? CGFloat else {
                return
            }

            let point = viewPoint(forPhonePoint: CGPoint(x: x, y: y))
            switch kind {
            case "tap":
                showTapRipple(at: point)
            case "clutchStart":
                showPressIndicator(at: point, color: NSColor.systemBlue)
            case "clutchMove", "clutchMoveAbsolute":
                movePressIndicator(to: point)
            case "clutchEnd":
                hidePressIndicator()
                hideDragTrail()
            case "rotationReset":
                hideDragTrail()
                showTapRipple(at: point)
                showPressIndicator(at: point, color: NSColor.systemOrange)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.28) { [weak self] in
                    self?.hidePressIndicator()
                }
            case "dragStart":
                trailPoints = [point]
                showPressIndicator(at: point, color: NSColor.systemGreen)
                updateDragTrail()
            case "dragMove", "dragMoveAbsolute":
                if let last = trailPoints.last, hypot(point.x - last.x, point.y - last.y) < 2 {
                    movePressIndicator(to: point)
                    return
                }
                trailPoints.append(point)
                movePressIndicator(to: point)
                updateDragTrail()
            case "dragEnd":
                trailPoints.append(point)
                updateDragTrail()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) { [weak self] in
                    self?.hidePressIndicator()
                    self?.hideDragTrail()
                }
            default:
                break
            }
        }

        private func viewPoint(forPhonePoint phonePoint: CGPoint) -> CGPoint {
            guard phoneScreenSize.width > 0, phoneScreenSize.height > 0 else { return .zero }
            let x = (phonePoint.x / phoneScreenSize.width) * bounds.width
            let y = bounds.height - ((phonePoint.y / phoneScreenSize.height) * bounds.height)
            return CGPoint(x: x, y: y)
        }

        private func showPressIndicator(at point: CGPoint, color: NSColor) {
            if pressLayer == nil {
                let size: CGFloat = 24
                let dot = CALayer()
                dot.bounds = CGRect(x: 0, y: 0, width: size, height: size)
                dot.cornerRadius = size / 2
                dot.backgroundColor = color.withAlphaComponent(0.35).cgColor
                dot.borderColor = NSColor.white.withAlphaComponent(0.7).cgColor
                dot.borderWidth = 1.5
                layer?.addSublayer(dot)
                pressLayer = dot
            }
            movePressIndicator(to: point)
        }

        private func movePressIndicator(to point: CGPoint) {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            pressLayer?.position = point
            CATransaction.commit()
        }

        private func hidePressIndicator() {
            pressLayer?.removeFromSuperlayer()
            pressLayer = nil
        }

        private func showTapRipple(at point: CGPoint) {
            let ripple = CALayer()
            let size: CGFloat = 30
            ripple.bounds = CGRect(x: 0, y: 0, width: size, height: size)
            ripple.position = point
            ripple.cornerRadius = size / 2
            ripple.backgroundColor = NSColor.clear.cgColor
            ripple.borderColor = NSColor.white.withAlphaComponent(0.8).cgColor
            ripple.borderWidth = 2
            layer?.addSublayer(ripple)

            let scaleAnim = CABasicAnimation(keyPath: "transform.scale")
            scaleAnim.fromValue = 1.0
            scaleAnim.toValue = 2.4

            let opacityAnim = CABasicAnimation(keyPath: "opacity")
            opacityAnim.fromValue = 1.0
            opacityAnim.toValue = 0.0

            let group = CAAnimationGroup()
            group.animations = [scaleAnim, opacityAnim]
            group.duration = 0.35
            group.timingFunction = CAMediaTimingFunction(name: .easeOut)
            group.isRemovedOnCompletion = false
            group.fillMode = .forwards

            CATransaction.begin()
            CATransaction.setCompletionBlock { ripple.removeFromSuperlayer() }
            ripple.add(group, forKey: "ripple")
            CATransaction.commit()
        }

        private func updateDragTrail() {
            guard trailPoints.count >= 1 else { return }

            let trail: CAShapeLayer
            if let existing = trailLayer {
                trail = existing
            } else {
                trail = CAShapeLayer()
                trail.fillColor = nil
                trail.strokeColor = NSColor.white.withAlphaComponent(0.45).cgColor
                trail.lineWidth = 2
                trail.lineCap = .round
                trail.lineJoin = .round
                layer?.addSublayer(trail)
                trailLayer = trail
            }

            let path = CGMutablePath()
            path.move(to: trailPoints[0])
            for point in trailPoints.dropFirst() {
                path.addLine(to: point)
            }
            trail.path = path
        }

        private func hideDragTrail() {
            trailLayer?.removeFromSuperlayer()
            trailLayer = nil
            trailPoints = []
        }
    }
}

private struct EasyPointerSpikeOverlay: View {
    let phoneScreenSize: CGSize

    @State private var latestSample: PointerSpikeVisualSample?
    @State private var metrics: PointerSpikeMetrics?

    private struct PointerSpikeVisualSample {
        let phase: String
        let sequence: Int
        let variant: String
        let targetPhonePoint: CGPoint
        let mappedPhonePoint: CGPoint?
        let virtualPhonePoint: CGPoint?
        let actualPhonePoint: CGPoint?
        let note: String
    }

    private struct PointerSpikeMetrics {
        let variant: String
        let count: Int
        let meanTargetDistance: Double
        let maxTargetDistance: Double
        let latestTargetDistance: Double
        let latestTargetErrorX: Double
        let latestTargetErrorY: Double
        let meanMappedDistance: Double?
        let maxMappedDistance: Double?
        let latestMappedDistance: Double?
        let latestMappedErrorX: Double?
        let latestMappedErrorY: Double?
        let meanVirtualDistance: Double?
        let maxVirtualDistance: Double?
        let latestVirtualDistance: Double?
        let latestVirtualErrorX: Double?
        let latestVirtualErrorY: Double?
        let targetID: String
        let sequence: Int
    }

    var body: some View {
        GeometryReader { geo in
            ZStack {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Closed-loop positioning active")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.primary)
                    spikeLegendRow(color: .orange, label: "T", description: "Target on iPhone screen")
                    spikeLegendRow(color: .cyan, label: "M", description: "Mapped Mac release point")
                    spikeLegendRow(color: .purple, label: "V", description: "Virtual pointer estimate at release")
                    spikeLegendRow(color: .green, label: "A", description: "Actual iPhone tap point")
                    Text("Yellow: T→A · Red: M→A · Purple: V→A")
                        .font(.caption2.monospaced())
                        .foregroundStyle(.secondary)
                }
                .padding(8)
                .background(.ultraThinMaterial)
                .cornerRadius(8)
                .padding(10)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)

                if let latestSample {
                    let targetPoint = viewPoint(for: latestSample.targetPhonePoint, in: geo.size)
                    if let mappedPhonePoint = latestSample.mappedPhonePoint {
                        let mappedPoint = viewPoint(for: mappedPhonePoint, in: geo.size)
                        pointMarker(at: mappedPoint, color: .cyan, label: "M")
                    }
                    if let virtualPhonePoint = latestSample.virtualPhonePoint {
                        let virtualPoint = viewPoint(for: virtualPhonePoint, in: geo.size)
                        pointMarker(at: virtualPoint, color: .purple, label: "V")
                    }
                    if let actualPhonePoint = latestSample.actualPhonePoint {
                        let actualPoint = viewPoint(for: actualPhonePoint, in: geo.size)
                        if let mappedPhonePoint = latestSample.mappedPhonePoint {
                            let mappedPoint = viewPoint(for: mappedPhonePoint, in: geo.size)
                            Path { path in
                                path.move(to: mappedPoint)
                                path.addLine(to: actualPoint)
                            }
                            .stroke(.red.opacity(0.8), style: StrokeStyle(lineWidth: 2, dash: [5, 3]))
                        }
                        if let virtualPhonePoint = latestSample.virtualPhonePoint {
                            let virtualPoint = viewPoint(for: virtualPhonePoint, in: geo.size)
                            Path { path in
                                path.move(to: virtualPoint)
                                path.addLine(to: actualPoint)
                            }
                            .stroke(.purple.opacity(0.8), style: StrokeStyle(lineWidth: 2, dash: [5, 3]))
                        }
                        Path { path in
                            path.move(to: targetPoint)
                            path.addLine(to: actualPoint)
                        }
                        .stroke(.yellow.opacity(0.8), style: StrokeStyle(lineWidth: 2, dash: [5, 3]))
                        pointMarker(at: actualPoint, color: .green, label: "A")
                    }
                    pointMarker(at: targetPoint, color: .orange, label: "T")

                    VStack(alignment: .trailing, spacing: 4) {
                        Text("#\(latestSample.sequence) \(latestSample.variant)")
                            .font(.caption2.monospaced())
                        Text(latestSample.note)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    .padding(8)
                    .background(.ultraThinMaterial)
                    .cornerRadius(8)
                    .padding(10)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                }

                if let metrics {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Samples \(metrics.count) · \(metrics.variant)")
                            .font(.caption2.monospaced())
                        Text("Target mean \(metrics.meanTargetDistance, specifier: "%.1f") px · max \(metrics.maxTargetDistance, specifier: "%.1f")")
                            .font(.caption2.monospaced())
                        if let meanMappedDistance = metrics.meanMappedDistance,
                           let maxMappedDistance = metrics.maxMappedDistance {
                            Text("Mapped mean \(meanMappedDistance, specifier: "%.1f") px · max \(maxMappedDistance, specifier: "%.1f")")
                                .font(.caption2.monospaced())
                        }
                        if let meanVirtualDistance = metrics.meanVirtualDistance,
                           let maxVirtualDistance = metrics.maxVirtualDistance {
                            Text("Virtual mean \(meanVirtualDistance, specifier: "%.1f") px · max \(maxVirtualDistance, specifier: "%.1f")")
                                .font(.caption2.monospaced())
                        }
                        Text("Last #\(metrics.sequence) \(metrics.targetID)")
                            .font(.caption2.monospaced())
                            .foregroundStyle(.secondary)
                        Text("Target dx \(metrics.latestTargetErrorX, specifier: "%.1f") · dy \(metrics.latestTargetErrorY, specifier: "%.1f") · d \(metrics.latestTargetDistance, specifier: "%.1f")")
                            .font(.caption2.monospaced())
                            .foregroundStyle(.secondary)
                        if let latestMappedDistance = metrics.latestMappedDistance,
                           let latestMappedErrorX = metrics.latestMappedErrorX,
                           let latestMappedErrorY = metrics.latestMappedErrorY {
                            Text("Mapped dx \(latestMappedErrorX, specifier: "%.1f") · dy \(latestMappedErrorY, specifier: "%.1f") · d \(latestMappedDistance, specifier: "%.1f")")
                                .font(.caption2.monospaced())
                                .foregroundStyle(.secondary)
                        }
                        if let latestVirtualDistance = metrics.latestVirtualDistance,
                           let latestVirtualErrorX = metrics.latestVirtualErrorX,
                           let latestVirtualErrorY = metrics.latestVirtualErrorY {
                            Text("Virtual dx \(latestVirtualErrorX, specifier: "%.1f") · dy \(latestVirtualErrorY, specifier: "%.1f") · d \(latestVirtualDistance, specifier: "%.1f")")
                                .font(.caption2.monospaced())
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(8)
                    .background(.ultraThinMaterial)
                    .cornerRadius(8)
                    .padding(10)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .easyPointerSpikeVisualization)) { note in
                apply(note)
            }
            .onReceive(NotificationCenter.default.publisher(for: .easyPointerSpikeMetrics)) { note in
                applyMetrics(note)
            }
        }
    }

    private func apply(_ note: Notification) {
        guard let phase = note.userInfo?["phase"] as? String,
              let sequence = intValue(note.userInfo?["sequence"]),
              let variant = note.userInfo?["variant"] as? String,
              let targetX = cgFloatValue(note.userInfo?["targetX"]),
              let targetY = cgFloatValue(note.userInfo?["targetY"]) else {
            SpecchioLogger.easyMode.info("[EasySpike] overlay ignored malformed notification")
            return
        }

        let mappedPoint: CGPoint?
        if let mappedX = cgFloatValue(note.userInfo?["mappedX"]),
           let mappedY = cgFloatValue(note.userInfo?["mappedY"]) {
            mappedPoint = CGPoint(x: mappedX, y: mappedY)
        } else {
            mappedPoint = nil
        }

        let virtualPoint: CGPoint?
        if let virtualX = cgFloatValue(note.userInfo?["virtualX"]),
           let virtualY = cgFloatValue(note.userInfo?["virtualY"]) {
            virtualPoint = CGPoint(x: virtualX, y: virtualY)
        } else {
            virtualPoint = nil
        }

        let actualPoint: CGPoint?
        if let actualX = cgFloatValue(note.userInfo?["actualX"]),
           let actualY = cgFloatValue(note.userInfo?["actualY"]) {
            actualPoint = CGPoint(x: actualX, y: actualY)
        } else {
            actualPoint = nil
        }

        let noteText = (note.userInfo?["note"] as? String) ?? phase
        latestSample = PointerSpikeVisualSample(
            phase: phase,
            sequence: sequence,
            variant: variant,
            targetPhonePoint: CGPoint(x: targetX, y: targetY),
            mappedPhonePoint: mappedPoint,
            virtualPhonePoint: virtualPoint,
            actualPhonePoint: actualPoint,
            note: noteText
        )
        SpecchioLogger.easyMode.info("[EasySpike] overlay updated phase=\(phase) sequence=\(sequence) variant=\(variant) hasMapped=\(mappedPoint != nil) hasVirtual=\(virtualPoint != nil) hasActual=\(actualPoint != nil)")
    }

    private func applyMetrics(_ note: Notification) {
        if (note.userInfo?["reset"] as? Bool) == true {
            metrics = nil
            SpecchioLogger.easyMode.info("[EasySpike] metrics reset")
            return
        }

        guard let variant = note.userInfo?["variant"] as? String,
              let sequence = intValue(note.userInfo?["sequence"]),
              let count = intValue(note.userInfo?["count"]),
              let meanTargetDistance = doubleValue(note.userInfo?["meanTargetDistance"]),
              let maxTargetDistance = doubleValue(note.userInfo?["maxTargetDistance"]),
              let latestTargetDistance = doubleValue(note.userInfo?["latestTargetDistance"]),
              let latestTargetErrorX = doubleValue(note.userInfo?["latestTargetErrorX"]),
              let latestTargetErrorY = doubleValue(note.userInfo?["latestTargetErrorY"]) else {
            SpecchioLogger.easyMode.info("[EasySpike] metrics ignored malformed notification")
            return
        }

        metrics = PointerSpikeMetrics(
            variant: variant,
            count: count,
            meanTargetDistance: meanTargetDistance,
            maxTargetDistance: maxTargetDistance,
            latestTargetDistance: latestTargetDistance,
            latestTargetErrorX: latestTargetErrorX,
            latestTargetErrorY: latestTargetErrorY,
            meanMappedDistance: doubleValue(note.userInfo?["meanMappedDistance"]),
            maxMappedDistance: doubleValue(note.userInfo?["maxMappedDistance"]),
            latestMappedDistance: doubleValue(note.userInfo?["latestMappedDistance"]),
            latestMappedErrorX: doubleValue(note.userInfo?["latestMappedErrorX"]),
            latestMappedErrorY: doubleValue(note.userInfo?["latestMappedErrorY"]),
            meanVirtualDistance: doubleValue(note.userInfo?["meanVirtualDistance"]),
            maxVirtualDistance: doubleValue(note.userInfo?["maxVirtualDistance"]),
            latestVirtualDistance: doubleValue(note.userInfo?["latestVirtualDistance"]),
            latestVirtualErrorX: doubleValue(note.userInfo?["latestVirtualErrorX"]),
            latestVirtualErrorY: doubleValue(note.userInfo?["latestVirtualErrorY"]),
            targetID: (note.userInfo?["targetID"] as? String) ?? "none",
            sequence: sequence
        )
        SpecchioLogger.easyMode.info("[EasySpike] metrics updated count=\(count) meanTargetDistance=\(meanTargetDistance) maxTargetDistance=\(maxTargetDistance)")
    }

    private func pointMarker(at point: CGPoint, color: Color, label: String) -> some View {
        ZStack {
            Circle()
                .stroke(color, lineWidth: 2)
                .frame(width: 24, height: 24)
            Circle()
                .fill(color.opacity(0.2))
                .frame(width: 12, height: 12)
            Text(label)
                .font(.caption2.monospaced())
                .foregroundStyle(.white)
                .offset(y: -18)
        }
        .position(point)
    }

    private func spikeLegendRow(color: Color, label: String, description: String) -> some View {
        HStack(spacing: 8) {
            ZStack {
                Circle()
                    .stroke(color, lineWidth: 2)
                    .frame(width: 16, height: 16)
                Circle()
                    .fill(color.opacity(0.25))
                    .frame(width: 8, height: 8)
            }
            Text(label)
                .font(.caption2.monospaced())
                .foregroundStyle(.primary)
            Text(description)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    private func viewPoint(for phonePoint: CGPoint, in size: CGSize) -> CGPoint {
        guard phoneScreenSize.width > 0, phoneScreenSize.height > 0 else {
            return .zero
        }
        let x = (phonePoint.x / phoneScreenSize.width) * size.width
        let y = (phonePoint.y / phoneScreenSize.height) * size.height
        return CGPoint(x: x, y: y)
    }

    private func cgFloatValue(_ value: Any?) -> CGFloat? {
        switch value {
        case let number as NSNumber:
            return CGFloat(number.doubleValue)
        case let doubleValue as Double:
            return CGFloat(doubleValue)
        case let floatValue as CGFloat:
            return floatValue
        default:
            return nil
        }
    }

    private func intValue(_ value: Any?) -> Int? {
        switch value {
        case let number as NSNumber:
            return number.intValue
        case let intValue as Int:
            return intValue
        default:
            return nil
        }
    }

    private func doubleValue(_ value: Any?) -> Double? {
        switch value {
        case let number as NSNumber:
            return number.doubleValue
        case let doubleValue as Double:
            return doubleValue
        default:
            return nil
        }
    }
}

struct EasyWindowVideoSizing {
    static let tolerance: CGFloat = 1.0

    static func normalizedRotation(_ degrees: Int) -> Int {
        ((degrees % 360) + 360) % 360
    }

    static func isSidewaysRotation(_ degrees: Int) -> Bool {
        let rotation = normalizedRotation(degrees)
        return rotation == 90 || rotation == 270
    }

    static func nextRotation(after degrees: Int) -> Int {
        switch normalizedRotation(degrees) {
        case 0:
            return 90
        case 90:
            return 270
        default:
            return 0
        }
    }

    static func displayedPhoneSize(phoneScreenSize: CGSize, rotationDegrees: Int) -> CGSize {
        let validPhoneSize = phoneScreenSize.width > 0 && phoneScreenSize.height > 0
            ? phoneScreenSize
            : SpecchioPhoneWindowMetrics.defaultPhoneScreenSize
        guard isSidewaysRotation(rotationDegrees) else { return validPhoneSize }
        return CGSize(width: validPhoneSize.height, height: validPhoneSize.width)
    }

    static func surfaceSize(afterRotating sourceSize: CGSize, from currentRotation: Int, to nextRotation: Int) -> CGSize {
        guard sourceSize.width > 0, sourceSize.height > 0 else { return .zero }
        guard isSidewaysRotation(currentRotation) != isSidewaysRotation(nextRotation) else {
            return sourceSize
        }
        return CGSize(width: sourceSize.height, height: sourceSize.width)
    }

    static func effectiveTopChromeHeight(
        reportedTopChromeHeight: CGFloat,
        contentHeight: CGFloat? = nil,
        phoneSurfaceAvailableHeight: CGFloat? = nil,
        minimumTopChromeHeight: CGFloat = EasyControlBarMetrics.windowReservedHeight
    ) -> CGFloat {
        let reportedHeight = reportedTopChromeHeight.isFinite ? max(0, reportedTopChromeHeight) : 0
        if reportedHeight > 0 {
            return max(reportedHeight, minimumTopChromeHeight)
        }

        let measuredHeight = measuredTopChromeHeight(
            contentHeight: contentHeight,
            phoneSurfaceAvailableHeight: phoneSurfaceAvailableHeight
        ) ?? 0

        return max(reportedHeight, measuredHeight, minimumTopChromeHeight)
    }

    static func measuredTopChromeHeight(
        contentHeight: CGFloat?,
        phoneSurfaceAvailableHeight: CGFloat?
    ) -> CGFloat? {
        guard let contentHeight,
              let phoneSurfaceAvailableHeight,
              contentHeight.isFinite,
              phoneSurfaceAvailableHeight.isFinite,
              contentHeight > 0,
              phoneSurfaceAvailableHeight > 0 else {
            return nil
        }

        let measuredHeight = contentHeight - phoneSurfaceAvailableHeight
        guard measuredHeight.isFinite, measuredHeight > 0 else { return nil }
        return measuredHeight
    }

    static func stableEffectiveTopChromeHeight(
        previousEffectiveTopChromeHeight: CGFloat?,
        reportedTopChromeHeight: CGFloat,
        contentHeight: CGFloat,
        phoneSurfaceAvailableHeight: CGFloat,
        minimumTopChromeHeight: CGFloat = EasyControlBarMetrics.windowReservedHeight
    ) -> EasyWindowTopChromeMeasurement {
        let reportedHeight = reportedTopChromeHeight.isFinite ? max(0, reportedTopChromeHeight) : 0
        if reportedHeight > 0 {
            return EasyWindowTopChromeMeasurement(
                height: max(reportedHeight, minimumTopChromeHeight),
                source: .reported,
                measuredHeight: measuredTopChromeHeight(
                    contentHeight: contentHeight,
                    phoneSurfaceAvailableHeight: phoneSurfaceAvailableHeight
                )
            )
        }

        let fallbackHeight = effectiveTopChromeHeight(
            reportedTopChromeHeight: reportedTopChromeHeight,
            minimumTopChromeHeight: minimumTopChromeHeight
        )
        let previousHeight = previousEffectiveTopChromeHeight.flatMap { height -> CGFloat? in
            guard height.isFinite, height > 0 else { return nil }
            return height
        }

        guard let measuredHeight = measuredTopChromeHeight(
            contentHeight: contentHeight,
            phoneSurfaceAvailableHeight: phoneSurfaceAvailableHeight
        ) else {
            if let previousHeight {
                return EasyWindowTopChromeMeasurement(
                    height: previousHeight,
                    source: .retainedDuringTransientLayout,
                    measuredHeight: nil
                )
            }

            return EasyWindowTopChromeMeasurement(
                height: fallbackHeight,
                source: .fallback,
                measuredHeight: nil
            )
        }

        guard measuredHeight <= phoneSurfaceAvailableHeight || previousHeight == nil else {
            return EasyWindowTopChromeMeasurement(
                height: previousHeight ?? fallbackHeight,
                source: .retainedDuringTransientLayout,
                measuredHeight: measuredHeight
            )
        }

        return EasyWindowTopChromeMeasurement(
            height: max(fallbackHeight, measuredHeight),
            source: .measured,
            measuredHeight: measuredHeight
        )
    }

    static func resizeDriver(
        previousContentSize: CGSize?,
        currentContentSize: CGSize,
        rotationDegrees: Int
    ) -> EasyWindowResizeDriver {
        let fallback = defaultResizeDriver(rotationDegrees: rotationDegrees)
        guard let previousContentSize,
              previousContentSize.width > 0,
              previousContentSize.height > 0,
              currentContentSize.width > 0,
              currentContentSize.height > 0 else {
            return fallback
        }

        let widthDelta = abs(currentContentSize.width - previousContentSize.width)
        let heightDelta = abs(currentContentSize.height - previousContentSize.height)
        guard abs(widthDelta - heightDelta) > tolerance else { return fallback }
        return widthDelta > heightDelta ? .width : .height
    }

    static func resizeDriver(previousContentSize: CGSize?, currentContentSize: CGSize) -> EasyWindowResizeDriver {
        resizeDriver(previousContentSize: previousContentSize, currentContentSize: currentContentSize, rotationDegrees: 0)
    }

    static func defaultResizeDriver(rotationDegrees: Int) -> EasyWindowResizeDriver {
        isSidewaysRotation(rotationDegrees) ? .width : .height
    }

    static func targetContentSizeForResize(
        contentSize: CGSize,
        displayedPhoneSize: CGSize,
        topChromeHeight: CGFloat,
        minimumContentSize: CGSize,
        driver: EasyWindowResizeDriver,
        minimumTopChromeHeight: CGFloat = EasyControlBarMetrics.windowReservedHeight
    ) -> CGSize {
        guard contentSize.width > 0,
              contentSize.height > 0,
              let ratio = aspectRatio(for: displayedPhoneSize) else {
            return .zero
        }

        let safeChromeHeight = effectiveTopChromeHeight(
            reportedTopChromeHeight: topChromeHeight,
            minimumTopChromeHeight: minimumTopChromeHeight
        )

        switch driver {
        case .width:
            return contentSizeForVideoWidth(
                contentSize.width,
                aspectRatio: ratio,
                topChromeHeight: safeChromeHeight,
                minimumContentSize: minimumContentSize
            )
        case .height:
            return contentSizeForVideoHeight(
                contentSize.height - safeChromeHeight,
                aspectRatio: ratio,
                topChromeHeight: safeChromeHeight,
                minimumContentSize: minimumContentSize
            )
        }
    }

    static func targetContentSizeForResize(
        contentSize: CGSize,
        displayedPhoneSize: CGSize,
        topChromeHeight: CGFloat,
        minimumContentWidth: CGFloat,
        driver: EasyWindowResizeDriver,
        minimumTopChromeHeight: CGFloat = EasyControlBarMetrics.windowReservedHeight
    ) -> CGSize {
        targetContentSizeForResize(
            contentSize: contentSize,
            displayedPhoneSize: displayedPhoneSize,
            topChromeHeight: topChromeHeight,
            minimumContentSize: CGSize(width: minimumContentWidth, height: 0),
            driver: driver,
            minimumTopChromeHeight: minimumTopChromeHeight
        )
    }

    static func targetContentSizeForInitialVideoFrame(
        videoFrameSize: CGSize,
        topChromeHeight: CGFloat,
        minimumContentSize: CGSize,
        minimumTopChromeHeight: CGFloat = EasyControlBarMetrics.windowReservedHeight
    ) -> CGSize {
        guard let ratio = aspectRatio(for: videoFrameSize) else { return .zero }
        let safeChromeHeight = effectiveTopChromeHeight(
            reportedTopChromeHeight: topChromeHeight,
            minimumTopChromeHeight: minimumTopChromeHeight
        )
        return contentSizeForVideoWidth(
            videoFrameSize.width,
            aspectRatio: ratio,
            topChromeHeight: safeChromeHeight,
            minimumContentSize: minimumContentSize
        )
    }

    static func contentSizeMatchesVideoAspect(
        contentSize: CGSize,
        displayedPhoneSize: CGSize,
        topChromeHeight: CGFloat,
        minimumContentSize: CGSize,
        minimumTopChromeHeight: CGFloat = EasyControlBarMetrics.windowReservedHeight
    ) -> Bool {
        guard contentSize.width > 0,
              contentSize.height > 0,
              let ratio = aspectRatio(for: displayedPhoneSize) else {
            return false
        }

        let safeChromeHeight = effectiveTopChromeHeight(
            reportedTopChromeHeight: topChromeHeight,
            minimumTopChromeHeight: minimumTopChromeHeight
        )
        let minimumSize = sanitizedMinimumContentSize(minimumContentSize)
        let videoHeight = max(0, contentSize.height - safeChromeHeight)
        let expectedWidth = videoHeight * ratio

        guard contentSize.width >= minimumSize.width - tolerance,
              contentSize.height >= minimumSize.height - tolerance else {
            return false
        }

        return abs(contentSize.width - expectedWidth) <= tolerance
    }

    static func contentSizeMatchesVideoAspect(
        contentSize: CGSize,
        displayedPhoneSize: CGSize,
        topChromeHeight: CGFloat,
        minimumContentWidth: CGFloat,
        minimumTopChromeHeight: CGFloat = EasyControlBarMetrics.windowReservedHeight
    ) -> Bool {
        contentSizeMatchesVideoAspect(
            contentSize: contentSize,
            displayedPhoneSize: displayedPhoneSize,
            topChromeHeight: topChromeHeight,
            minimumContentSize: CGSize(width: minimumContentWidth, height: 0),
            minimumTopChromeHeight: minimumTopChromeHeight
        )
    }

    static func targetContentSizeAfterRotation(
        currentContentSize: CGSize,
        displayedPhoneSize: CGSize,
        topChromeHeight: CGFloat,
        minimumContentSize: CGSize,
        from currentRotation: Int,
        to nextRotation: Int,
        minimumTopChromeHeight: CGFloat = EasyControlBarMetrics.windowReservedHeight
    ) -> CGSize {
        guard currentContentSize.width > 0,
              currentContentSize.height > 0,
              let ratio = aspectRatio(for: displayedPhoneSize) else {
            return .zero
        }

        let safeChromeHeight = effectiveTopChromeHeight(
            reportedTopChromeHeight: topChromeHeight,
            minimumTopChromeHeight: minimumTopChromeHeight
        )
        let currentVideoSize = CGSize(
            width: currentContentSize.width,
            height: max(0, currentContentSize.height - safeChromeHeight)
        )
        let targetVideoSize = surfaceSize(afterRotating: currentVideoSize, from: currentRotation, to: nextRotation)
        return contentSizeForVideoWidth(
            targetVideoSize.width,
            aspectRatio: ratio,
            topChromeHeight: safeChromeHeight,
            minimumContentSize: minimumContentSize
        )
    }

    static func contentSizeByScalingDownToFit(
        _ contentSize: CGSize,
        topChromeHeight: CGFloat,
        maximumContentSize: CGSize,
        minimumTopChromeHeight: CGFloat = EasyControlBarMetrics.windowReservedHeight
    ) -> CGSize {
        guard contentSize.width > 0,
              contentSize.height > 0,
              maximumContentSize.width > 0,
              maximumContentSize.height > 0 else {
            return contentSize
        }

        let safeChromeHeight = effectiveTopChromeHeight(
            reportedTopChromeHeight: topChromeHeight,
            minimumTopChromeHeight: minimumTopChromeHeight
        )
        let videoWidth = contentSize.width
        let videoHeight = max(0, contentSize.height - safeChromeHeight)
        guard videoWidth > 0, videoHeight > 0 else { return contentSize }

        let maxVideoWidth = maximumContentSize.width
        let maxVideoHeight = max(0, maximumContentSize.height - safeChromeHeight)
        guard maxVideoWidth > 0, maxVideoHeight > 0 else { return contentSize }

        let scale = min(1, maxVideoWidth / videoWidth, maxVideoHeight / videoHeight)
        guard scale < 1 else { return contentSize }

        return CGSize(
            width: videoWidth * scale,
            height: safeChromeHeight + (videoHeight * scale)
        )
    }

    private static func aspectRatio(for size: CGSize) -> CGFloat? {
        guard size.width.isFinite,
              size.height.isFinite,
              size.width > 0,
              size.height > 0 else {
            return nil
        }
        return size.width / size.height
    }

    private static func contentSizeForVideoWidth(
        _ requestedVideoWidth: CGFloat,
        aspectRatio: CGFloat,
        topChromeHeight: CGFloat,
        minimumContentSize: CGSize
    ) -> CGSize {
        guard requestedVideoWidth.isFinite, aspectRatio > 0 else { return .zero }
        let minimumSize = sanitizedMinimumContentSize(minimumContentSize)
        var videoWidth = max(0, requestedVideoWidth, minimumSize.width)
        var videoHeight = videoWidth / aspectRatio
        let minimumVideoHeight = max(0, minimumSize.height - topChromeHeight)
        if videoHeight < minimumVideoHeight {
            videoHeight = minimumVideoHeight
            videoWidth = videoHeight * aspectRatio
        }
        return CGSize(width: videoWidth, height: topChromeHeight + videoHeight)
    }

    private static func contentSizeForVideoHeight(
        _ requestedVideoHeight: CGFloat,
        aspectRatio: CGFloat,
        topChromeHeight: CGFloat,
        minimumContentSize: CGSize
    ) -> CGSize {
        guard requestedVideoHeight.isFinite, aspectRatio > 0 else { return .zero }
        let minimumSize = sanitizedMinimumContentSize(minimumContentSize)
        var videoHeight = max(0, requestedVideoHeight, minimumSize.height - topChromeHeight)
        var videoWidth = videoHeight * aspectRatio
        if videoWidth < minimumSize.width {
            videoWidth = minimumSize.width
            videoHeight = videoWidth / aspectRatio
        }
        return CGSize(width: videoWidth, height: topChromeHeight + videoHeight)
    }

    private static func sanitizedMinimumContentSize(_ size: CGSize) -> CGSize {
        CGSize(
            width: size.width.isFinite ? max(0, size.width) : 0,
            height: size.height.isFinite ? max(0, size.height) : 0
        )
    }
}

enum EasyWindowResizeDriver: String {
    case width
    case height
}

enum EasyWindowTopChromeSource: String {
    case reported
    case measured
    case retainedDuringTransientLayout
    case fallback
}

struct EasyWindowTopChromeMeasurement: Equatable {
    let height: CGFloat
    let source: EasyWindowTopChromeSource
    let measuredHeight: CGFloat?
}

private enum EasyPhoneSurfaceLayoutBranch: String {
    case exactFit
    case heightDriven
    case widthDriven
    case invalidGeometry
}

private struct EasyPhoneSurfaceLayout: Equatable {
    static let tolerance: CGFloat = 1.0

    let branch: EasyPhoneSurfaceLayoutBranch
    let phoneSize: CGSize
    let horizontalUnused: CGFloat
    let verticalUnused: CGFloat

    static func make(availableSize: CGSize, aspectRatio: CGFloat) -> EasyPhoneSurfaceLayout {
        guard availableSize.width > 0, availableSize.height > 0, aspectRatio > 0 else {
            return EasyPhoneSurfaceLayout(
                branch: .invalidGeometry,
                phoneSize: .zero,
                horizontalUnused: max(0, availableSize.width),
                verticalUnused: max(0, availableSize.height)
            )
        }

        let heightDrivenWidth = availableSize.height * aspectRatio

        if heightDrivenWidth <= availableSize.width + tolerance {
            let phoneSize = CGSize(width: heightDrivenWidth, height: availableSize.height)
            let horizontalUnused = max(0, availableSize.width - phoneSize.width)
            let branch: EasyPhoneSurfaceLayoutBranch = horizontalUnused <= tolerance ? .exactFit : .heightDriven
            return EasyPhoneSurfaceLayout(
                branch: branch,
                phoneSize: phoneSize,
                horizontalUnused: horizontalUnused,
                verticalUnused: 0
            )
        }

        let widthDrivenHeight = availableSize.width / aspectRatio
        let phoneSize = CGSize(width: availableSize.width, height: widthDrivenHeight)
        let verticalUnused = max(0, availableSize.height - phoneSize.height)
        let branch: EasyPhoneSurfaceLayoutBranch = verticalUnused <= tolerance ? .exactFit : .widthDriven
        return EasyPhoneSurfaceLayout(
            branch: branch,
            phoneSize: phoneSize,
            horizontalUnused: 0,
            verticalUnused: verticalUnused
        )
    }

}

private struct EasyPresentationWindowFocusObserver: NSViewRepresentable {
    let standardControlsVisible: Bool
    let onFocusChange: (Bool, Bool, String) -> Void

    func makeNSView(context: Context) -> FocusObserverView {
        let view = FocusObserverView()
        view.standardControlsVisible = standardControlsVisible
        view.onFocusChange = onFocusChange
        SpecchioLogger.easyMode.info("[EasyPresentationFocus] observer created branch=makeNSView")
        return view
    }

    func updateNSView(_ nsView: FocusObserverView, context: Context) {
        nsView.standardControlsVisible = standardControlsVisible
        nsView.onFocusChange = onFocusChange
        nsView.attachToCurrentWindow(reason: "updateNSView")
    }

    final class FocusObserverView: NSView {
        var onFocusChange: ((Bool, Bool, String) -> Void)?
        var standardControlsVisible = false
        private weak var observedWindow: NSWindow?
        private var windowObservers: [NSObjectProtocol] = []
        private var applicationObservers: [NSObjectProtocol] = []
        private var lastReportedState: (isKey: Bool, isApplicationActive: Bool)?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            attachToCurrentWindow(reason: "viewDidMoveToWindow")
        }

        func attachToCurrentWindow(reason: String) {
            guard observedWindow !== window else {
                SpecchioLogger.easyMode.debug("[EasyPresentationFocus] attach skipped reason=\(reason, privacy: .public) branch=same-window windowNumber=\(self.window?.windowNumber ?? -1)")
                reportCurrentFocus(reason: "\(reason)-same-window")
                return
            }

            removeWindowObservers(reason: "\(reason)-window-changed")
            observedWindow = window
            installApplicationObserversIfNeeded(reason: reason)

            guard let window else {
                SpecchioLogger.easyMode.info("[EasyPresentationFocus] attach branch=no-window reason=\(reason, privacy: .public)")
                reportFocus(isKey: false, isApplicationActive: NSApplication.shared.isActive, reason: "\(reason)-no-window")
                return
            }

            SpecchioPresentationWindowChrome.apply(
                to: window,
                reason: "EasyPresentationFocus-\(reason)-attach",
                standardControlsVisible: standardControlsVisible
            )
            windowObservers = [
                NotificationCenter.default.addObserver(
                    forName: NSWindow.didBecomeKeyNotification,
                    object: window,
                    queue: .main
                ) { [weak self] _ in
                    self?.handleWindowFocusNotification(reason: "window-didBecomeKey")
                },
                NotificationCenter.default.addObserver(
                    forName: NSWindow.didResignKeyNotification,
                    object: window,
                    queue: .main
                ) { [weak self] _ in
                    self?.handleWindowFocusNotification(reason: "window-didResignKey")
                },
                NotificationCenter.default.addObserver(
                    forName: NSWindow.didBecomeMainNotification,
                    object: window,
                    queue: .main
                ) { [weak self] _ in
                    self?.handleWindowFocusNotification(reason: "window-didBecomeMain")
                },
                NotificationCenter.default.addObserver(
                    forName: NSWindow.didResignMainNotification,
                    object: window,
                    queue: .main
                ) { [weak self] _ in
                    self?.handleWindowFocusNotification(reason: "window-didResignMain")
                }
            ]
            SpecchioLogger.easyMode.info("[EasyPresentationFocus] attach branch=installed reason=\(reason, privacy: .public) standardControlsVisible=\(self.standardControlsVisible) windowNumber=\(window.windowNumber) isKey=\(window.isKeyWindow) observerCount=\(self.windowObservers.count)")
            reportCurrentFocus(reason: "\(reason)-installed")
        }

        private func reportCurrentFocus(reason: String) {
            guard let observedWindow else {
                SpecchioLogger.easyMode.info("[EasyPresentationFocus] current focus branch=no-observed-window reason=\(reason, privacy: .public)")
                reportFocus(isKey: false, isApplicationActive: NSApplication.shared.isActive, reason: "\(reason)-no-observed-window")
                return
            }

            reportFocus(
                isKey: observedWindow.isKeyWindow,
                isApplicationActive: NSApplication.shared.isActive,
                reason: reason
            )
        }

        private func reportFocus(isKey: Bool, isApplicationActive: Bool, reason: String) {
            let changed = lastReportedState?.isKey != isKey
                || lastReportedState?.isApplicationActive != isApplicationActive
            let windowNumber = observedWindow?.windowNumber ?? -1
            guard changed else {
                SpecchioLogger.easyMode.debug("[EasyPresentationFocus] focus unchanged reason=\(reason, privacy: .public) appActive=\(isApplicationActive) isKey=\(isKey) windowNumber=\(windowNumber)")
                return
            }

            lastReportedState = (isKey: isKey, isApplicationActive: isApplicationActive)
            SpecchioLogger.easyMode.info("[EasyPresentationFocus] focus reported reason=\(reason, privacy: .public) appActive=\(isApplicationActive) isKey=\(isKey) windowNumber=\(windowNumber)")

            guard let onFocusChange else {
                SpecchioLogger.easyMode.info("[EasyPresentationFocus] callback skipped reason=\(reason, privacy: .public) branch=no-callback appActive=\(isApplicationActive) isKey=\(isKey)")
                return
            }

            onFocusChange(isKey, isApplicationActive, reason)
        }

        private func handleWindowFocusNotification(reason: String) {
            if let observedWindow {
                SpecchioPresentationWindowChrome.reapplyAfterSystemChromeUpdate(
                    to: observedWindow,
                    reason: "EasyPresentationFocus-\(reason)",
                    standardControlsVisible: standardControlsVisible
                )
            }
            reportCurrentFocus(reason: reason)
        }

        private func installApplicationObserversIfNeeded(reason: String) {
            guard applicationObservers.isEmpty else {
                SpecchioLogger.easyMode.debug("[EasyPresentationFocus] app observers skipped reason=\(reason, privacy: .public) branch=already-installed")
                return
            }

            applicationObservers = [
                NotificationCenter.default.addObserver(
                    forName: NSApplication.didBecomeActiveNotification,
                    object: NSApplication.shared,
                    queue: .main
                ) { [weak self] _ in
                    self?.handleApplicationFocusNotification(reason: "app-didBecomeActive")
                },
                NotificationCenter.default.addObserver(
                    forName: NSApplication.didResignActiveNotification,
                    object: NSApplication.shared,
                    queue: .main
                ) { [weak self] _ in
                    self?.handleApplicationFocusNotification(reason: "app-didResignActive")
                }
            ]
            SpecchioLogger.easyMode.info("[EasyPresentationFocus] app observers installed reason=\(reason, privacy: .public) observerCount=\(self.applicationObservers.count) appActive=\(NSApplication.shared.isActive)")
        }

        private func handleApplicationFocusNotification(reason: String) {
            if let observedWindow {
                SpecchioPresentationWindowChrome.reapplyAfterSystemChromeUpdate(
                    to: observedWindow,
                    reason: "EasyPresentationFocus-\(reason)",
                    standardControlsVisible: standardControlsVisible
                )
            }
            reportCurrentFocus(reason: reason)
        }

        private func removeWindowObservers(reason: String) {
            guard !windowObservers.isEmpty else {
                SpecchioLogger.easyMode.debug("[EasyPresentationFocus] remove skipped reason=\(reason, privacy: .public) branch=no-observers")
                return
            }

            windowObservers.forEach(NotificationCenter.default.removeObserver)
            SpecchioLogger.easyMode.info("[EasyPresentationFocus] removed observers reason=\(reason, privacy: .public) count=\(self.windowObservers.count)")
            windowObservers = []
        }

        deinit {
            removeWindowObservers(reason: "deinit")
            applicationObservers.forEach(NotificationCenter.default.removeObserver)
            SpecchioLogger.easyMode.info("[EasyPresentationFocus] removed app observers reason=deinit count=\(self.applicationObservers.count)")
        }
    }
}

private struct EasyPresentationHeaderHoverTracker: NSViewRepresentable {
    let onHoverChange: (CGPoint?, String) -> Void

    func makeNSView(context: Context) -> TrackingView {
        let view = TrackingView()
        view.onHoverChange = onHoverChange
        SpecchioLogger.easyMode.info("[EasyPresentationHover] tracker created branch=makeNSView")
        return view
    }

    func updateNSView(_ nsView: TrackingView, context: Context) {
        nsView.onHoverChange = onHoverChange
        SpecchioLogger.easyMode.debug("[EasyPresentationHover] tracker updated branch=updateNSView")
        DispatchQueue.main.async {
            nsView.reportCurrentMouseLocation(reason: "update")
        }
    }

    final class TrackingView: NSView {
        var onHoverChange: ((CGPoint?, String) -> Void)?
        private var trackingAreaRef: NSTrackingArea?

        override var acceptsFirstResponder: Bool { false }

        override func hitTest(_ point: NSPoint) -> NSView? {
            nil
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let window {
                window.acceptsMouseMovedEvents = true
                SpecchioLogger.easyMode.info("[EasyPresentationHover] moved to window branch=attached windowNumber=\(window.windowNumber) acceptsMouseMoved=true boundsWidth=\(self.bounds.width) boundsHeight=\(self.bounds.height)")
            } else {
                SpecchioLogger.easyMode.info("[EasyPresentationHover] moved to window branch=detached boundsWidth=\(self.bounds.width) boundsHeight=\(self.bounds.height)")
            }
            reportCurrentMouseLocation(reason: "viewDidMoveToWindow")
        }

        override func updateTrackingAreas() {
            if let trackingAreaRef {
                removeTrackingArea(trackingAreaRef)
                SpecchioLogger.easyMode.debug("[EasyPresentationHover] tracking area removed branch=replace")
            } else {
                SpecchioLogger.easyMode.debug("[EasyPresentationHover] tracking area remove skipped branch=none")
            }

            let trackingArea = NSTrackingArea(
                rect: .zero,
                options: [.mouseEnteredAndExited, .mouseMoved, .activeInKeyWindow, .inVisibleRect],
                owner: self,
                userInfo: nil
            )
            addTrackingArea(trackingArea)
            trackingAreaRef = trackingArea
            SpecchioLogger.easyMode.info("[EasyPresentationHover] tracking area installed options=mouse-entered-exited-moved-active-key-window-in-visible-rect boundsWidth=\(self.bounds.width) boundsHeight=\(self.bounds.height)")
            super.updateTrackingAreas()
        }

        override func layout() {
            super.layout()
            reportCurrentMouseLocation(reason: "layout")
        }

        override func mouseEntered(with event: NSEvent) {
            report(event: event, reason: "mouse-entered")
        }

        override func mouseMoved(with event: NSEvent) {
            report(event: event, reason: "mouse-moved")
        }

        override func mouseExited(with event: NSEvent) {
            SpecchioLogger.easyMode.info("[EasyPresentationHover] report reason=mouse-exited branch=outside boundsWidth=\(self.bounds.width) boundsHeight=\(self.bounds.height)")
            reportHover(location: nil, reason: "mouse-exited")
        }

        func reportCurrentMouseLocation(reason: String) {
            guard let window else {
                SpecchioLogger.easyMode.info("[EasyPresentationHover] report skipped reason=\(reason, privacy: .public) branch=no-window boundsWidth=\(self.bounds.width) boundsHeight=\(self.bounds.height)")
                reportHover(location: nil, reason: reason)
                return
            }

            let location = convert(window.mouseLocationOutsideOfEventStream, from: nil)
            report(localLocation: location, reason: reason)
        }

        private func report(event: NSEvent, reason: String) {
            let location = convert(event.locationInWindow, from: nil)
            report(localLocation: location, reason: reason)
        }

        private func report(localLocation: CGPoint, reason: String) {
            guard self.bounds.width.isFinite,
                  self.bounds.height.isFinite,
                  self.bounds.width > 0,
                  self.bounds.height > 0 else {
                SpecchioLogger.easyMode.info("[EasyPresentationHover] report skipped reason=\(reason, privacy: .public) branch=invalid-bounds boundsWidth=\(self.bounds.width) boundsHeight=\(self.bounds.height)")
                reportHover(location: nil, reason: reason)
                return
            }

            guard self.bounds.contains(localLocation) else {
                SpecchioLogger.easyMode.debug("[EasyPresentationHover] report reason=\(reason, privacy: .public) branch=outside localX=\(localLocation.x) localY=\(localLocation.y) boundsWidth=\(self.bounds.width) boundsHeight=\(self.bounds.height)")
                reportHover(location: nil, reason: reason)
                return
            }

            let swiftUILocation = CGPoint(
                x: localLocation.x,
                y: self.bounds.height - localLocation.y
            )
            SpecchioLogger.easyMode.debug("[EasyPresentationHover] report reason=\(reason, privacy: .public) branch=inside localX=\(localLocation.x) localY=\(localLocation.y) swiftUIX=\(swiftUILocation.x) swiftUIY=\(swiftUILocation.y) boundsWidth=\(self.bounds.width) boundsHeight=\(self.bounds.height)")
            reportHover(location: swiftUILocation, reason: reason)
        }

        private func reportHover(location: CGPoint?, reason: String) {
            guard let onHoverChange else {
                SpecchioLogger.easyMode.info("[EasyPresentationHover] callback skipped reason=\(reason, privacy: .public) branch=no-callback locationPresent=\(location != nil)")
                return
            }

            SpecchioLogger.easyMode.debug("[EasyPresentationHover] callback reporting reason=\(reason, privacy: .public) locationPresent=\(location != nil) y=\(location?.y ?? -1)")
            onHoverChange(location, "tracking-\(reason)")
        }
    }
}

enum EasyMirroringPhoneSurfaceGeometry {
    static let displayCornerRadiusToShortEdgeRatio: CGFloat = 55.0 / 430.0

    static func cornerRadius(in rect: CGRect) -> CGFloat {
        cornerRadius(for: rect.size)
    }

    static func cornerRadius(for size: CGSize) -> CGFloat {
        guard size.width.isFinite,
              size.height.isFinite,
              size.width > 0,
              size.height > 0 else {
            return 0
        }

        return min(size.width, size.height) * displayCornerRadiusToShortEdgeRatio
    }
}

private enum EasyMirroringPresentationMetrics {
    static let headerHeight = EasyControlBarMetrics.windowReservedHeight
    static let reservedTopChromeHeight = headerHeight
    static let displayCornerRadiusToShortEdgeRatio = EasyMirroringPhoneSurfaceGeometry.displayCornerRadiusToShortEdgeRatio
    static let headerRevealHeight = EasyControlBarMetrics.windowReservedHeight
    static let headerHorizontalPadding = EasyControlBarMetrics.outerHorizontalPadding
    static let headerItemSpacing = EasyControlBarMetrics.outerSpacing
    static let headerAnimationDuration = 0.16
    static let headerSeparatorHeight = EasyControlBarMetrics.dividerWidth
    static let headerSeparatorOpacity = 0.18
    static let panelBorderOpacity = headerSeparatorOpacity
}

private struct EasyMirroringPresentationPanelChrome: View {
    let isVisible: Bool

    var body: some View {
        ZStack {
            if isVisible {
                RoundedRectangle(
                    cornerRadius: EasyControlBarMetrics.toolbarCornerRadius,
                    style: .continuous
                )
                .fill(.ultraThinMaterial)
                .overlay {
                    RoundedRectangle(
                        cornerRadius: EasyControlBarMetrics.toolbarCornerRadius,
                        style: .continuous
                    )
                    .strokeBorder(
                        Color.white.opacity(EasyMirroringPresentationMetrics.panelBorderOpacity),
                        lineWidth: EasyControlBarMetrics.dividerWidth
                    )
                }
                .transition(.opacity)
            }
        }
        .allowsHitTesting(false)
        .animation(.easeOut(duration: EasyMirroringPresentationMetrics.headerAnimationDuration), value: isVisible)
        .onAppear {
            SpecchioLogger.easyMode.info("[EasyPresentationPanel] installed branch=conditional-material cornerRadius=\(EasyControlBarMetrics.toolbarCornerRadius) borderOpacity=\(EasyMirroringPresentationMetrics.panelBorderOpacity) visible=\(isVisible)")
        }
        .onChange(of: isVisible) { _, visible in
            SpecchioLogger.easyMode.info("[EasyPresentationPanel] visibility changed visible=\(visible) materialDrawn=\(visible)")
        }
    }
}

private struct EasyMirroringPhoneSurfacePresentation: ViewModifier {
    func body(content: Content) -> some View {
        content
            .background(Color(nsColor: .windowBackgroundColor))
            .clipShape(EasyMirroringPhoneWindowShape())
            .overlay {
                EasyMirroringPhoneWindowShape()
                    .strokeBorder(
                        Color.black.opacity(0.78),
                        lineWidth: EasyControlBarMetrics.dividerWidth
                    )
            }
            .contentShape(EasyMirroringPhoneWindowShape())
            .onAppear {
                SpecchioLogger.easyMode.info("[EasyPresentation] phone surface shape active cornerBasis=short-edge cornerRatio=\(EasyMirroringPresentationMetrics.displayCornerRadiusToShortEdgeRatio) borderWidth=\(EasyControlBarMetrics.dividerWidth)")
            }
    }
}

private struct EasyMirroringPhoneWindowShape: InsettableShape {
    var insetAmount: CGFloat = 0

    func path(in rect: CGRect) -> Path {
        let insetRect = rect.insetBy(dx: insetAmount, dy: insetAmount)
        let radius = EasyMirroringPhoneSurfaceGeometry.cornerRadius(in: insetRect)
        return Path(roundedRect: insetRect, cornerRadius: radius)
    }

    func inset(by amount: CGFloat) -> EasyMirroringPhoneWindowShape {
        var copy = self
        copy.insetAmount += amount
        return copy
    }
}

private struct EasyMirroringHeaderDragSurface: NSViewRepresentable {
    func makeNSView(context: Context) -> DragView {
        DragView()
    }

    func updateNSView(_ nsView: DragView, context: Context) {}

    final class DragView: NSView {
        override func mouseDown(with event: NSEvent) {
            guard let window else {
                SpecchioLogger.easyMode.info("[EasyPresentationHeader] drag skipped branch=no-window")
                return
            }

            SpecchioLogger.easyMode.info("[EasyPresentationHeader] drag started windowFrameWidth=\(window.frame.width) windowFrameHeight=\(window.frame.height)")
            window.performDrag(with: event)
        }
    }
}

private struct EasyPresentationHeaderNativeControlsReader: NSViewRepresentable {
    let standardControlsVisible: Bool
    let onLeadingPaddingChange: (CGFloat, String) -> Void

    func makeNSView(context: Context) -> ReaderView {
        let view = ReaderView()
        view.standardControlsVisible = standardControlsVisible
        view.onLeadingPaddingChange = onLeadingPaddingChange
        SpecchioLogger.easyMode.info("[EasyPresentationHeader] native controls reader created visible=\(standardControlsVisible)")
        return view
    }

    func updateNSView(_ nsView: ReaderView, context: Context) {
        if nsView.standardControlsVisible != standardControlsVisible {
            SpecchioLogger.easyMode.info("[EasyPresentationHeader] native controls reader visibility changed from=\(nsView.standardControlsVisible) to=\(standardControlsVisible)")
        }
        nsView.standardControlsVisible = standardControlsVisible
        nsView.onLeadingPaddingChange = onLeadingPaddingChange
        nsView.measure(reason: "updateNSView")
    }

    final class ReaderView: NSView {
        var standardControlsVisible = false
        var onLeadingPaddingChange: ((CGFloat, String) -> Void)?
        private var lastReportedLeadingPadding: CGFloat?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            measure(reason: "viewDidMoveToWindow")
        }

        override func layout() {
            super.layout()
            measure(reason: "layout")
        }

        override func hitTest(_ point: NSPoint) -> NSView? {
            nil
        }

        func measure(reason: String) {
            guard standardControlsVisible else {
                SpecchioLogger.easyMode.info("[EasyPresentationHeader] native controls measurement reason=\(reason, privacy: .public) branch=standard-controls-hidden")
                report(leadingPadding: 0, reason: "\(reason)-hidden")
                return
            }

            guard let window else {
                SpecchioLogger.easyMode.info("[EasyPresentationHeader] native controls measurement reason=\(reason, privacy: .public) branch=no-window")
                report(leadingPadding: 0, reason: "\(reason)-no-window")
                return
            }

            guard let frameView = window.contentView?.superview else {
                SpecchioLogger.easyMode.info("[EasyPresentationHeader] native controls measurement reason=\(reason, privacy: .public) branch=no-frame-view windowNumber=\(window.windowNumber)")
                report(leadingPadding: 0, reason: "\(reason)-no-frame-view")
                return
            }

            let buttons = [
                window.standardWindowButton(.closeButton),
                window.standardWindowButton(.miniaturizeButton),
                window.standardWindowButton(.zoomButton)
            ].compactMap { $0 }

            guard !buttons.isEmpty else {
                SpecchioLogger.easyMode.info("[EasyPresentationHeader] native controls measurement reason=\(reason, privacy: .public) branch=no-standard-buttons windowNumber=\(window.windowNumber)")
                report(leadingPadding: 0, reason: "\(reason)-no-buttons")
                return
            }

            let visibleButtons = buttons.filter { button in
                !button.isHidden && button.alphaValue > 0
            }

            guard !visibleButtons.isEmpty else {
                SpecchioLogger.easyMode.info("[EasyPresentationHeader] native controls measurement reason=\(reason, privacy: .public) branch=no-visible-buttons windowNumber=\(window.windowNumber)")
                report(leadingPadding: 0, reason: "\(reason)-no-visible-buttons")
                return
            }

            let framesInFrameView = visibleButtons.compactMap { button -> CGRect? in
                guard let buttonSuperview = button.superview else {
                    SpecchioLogger.easyMode.info("[EasyPresentationHeader] native control frame skipped reason=\(reason, privacy: .public) branch=no-button-superview")
                    return nil
                }
                return buttonSuperview.convert(button.frame, to: frameView)
            }

            guard let controlsMaxX = framesInFrameView.map(\.maxX).max() else {
                SpecchioLogger.easyMode.info("[EasyPresentationHeader] native controls measurement reason=\(reason, privacy: .public) branch=no-converted-frames windowNumber=\(window.windowNumber)")
                report(leadingPadding: 0, reason: "\(reason)-no-converted-frames")
                return
            }

            let leadingPadding = max(
                0,
                controlsMaxX
                    + EasyMirroringPresentationMetrics.headerItemSpacing
                    - EasyMirroringPresentationMetrics.headerHorizontalPadding
            )
            let frameSummary = framesInFrameView
                .map { frame in
                    "x:\(Int(frame.minX))-\(Int(frame.maxX)) y:\(Int(frame.minY))-\(Int(frame.maxY))"
                }
                .joined(separator: ";")

            SpecchioLogger.easyMode.info("[EasyPresentationHeader] native controls measured reason=\(reason, privacy: .public) windowNumber=\(window.windowNumber) buttonCount=\(visibleButtons.count) controlsMaxX=\(controlsMaxX) headerPadding=\(EasyMirroringPresentationMetrics.headerHorizontalPadding) itemSpacing=\(EasyMirroringPresentationMetrics.headerItemSpacing) leadingPadding=\(leadingPadding) frames=\(frameSummary, privacy: .public)")
            report(leadingPadding: leadingPadding, reason: reason)
        }

        private func report(leadingPadding: CGFloat, reason: String) {
            guard lastReportedLeadingPadding.map({ abs($0 - leadingPadding) > 0.5 }) ?? true else {
                SpecchioLogger.easyMode.debug("[EasyPresentationHeader] native controls report skipped reason=\(reason, privacy: .public) branch=unchanged leadingPadding=\(leadingPadding)")
                return
            }

            lastReportedLeadingPadding = leadingPadding
            guard let onLeadingPaddingChange else {
                SpecchioLogger.easyMode.info("[EasyPresentationHeader] native controls report skipped reason=\(reason, privacy: .public) branch=no-callback leadingPadding=\(leadingPadding)")
                return
            }

            SpecchioLogger.easyMode.info("[EasyPresentationHeader] native controls report scheduled reason=\(reason, privacy: .public) leadingPadding=\(leadingPadding)")
            DispatchQueue.main.async {
                onLeadingPaddingChange(leadingPadding, reason)
            }
        }
    }
}

enum EasyControlBarMetrics {
    static let buttonSide: CGFloat = 28
    static let outerSpacing: CGFloat = 8
    static let spacerMinimum: CGFloat = 0
    static let outerHorizontalPadding: CGFloat = 12
    static let outerVerticalPadding: CGFloat = 8
    static let toolbarSpacing: CGFloat = 6
    static let toolbarHorizontalPadding: CGFloat = 8
    static let toolbarVerticalPadding: CGFloat = 0
    static let toolbarCornerRadius: CGFloat = 8
    static let dividerWidth: CGFloat = 1
    static let dividerHeight: CGFloat = 18

    static var windowReservedHeight: CGFloat {
        let expandedToolbarHeight = buttonSide + (toolbarVerticalPadding * 2)
        return max(buttonSide, expandedToolbarHeight) + (outerVerticalPadding * 2)
    }
}

enum EasyToolbarCommand: String, CaseIterable, Identifiable {
    case search
    case volumeDown
    case volumeUp
    case mute
    case home
    case rotateScreen
    case privacyBlur
    case screenshot
    case switchApps
    case appSwitcher
    case disconnect
    case showShortcuts

    var id: String { rawValue }

    static let defaultOrder: [EasyToolbarCommand] = [
        .volumeDown,
        .volumeUp,
        .mute,
        .home,
        .rotateScreen,
        .privacyBlur,
        .search,
        .switchApps,
        .appSwitcher,
        .screenshot,
        .disconnect,
        .showShortcuts,
    ]

    static var defaultVisibleOrder: [EasyToolbarCommand] {
        Array(defaultOrder.prefix(EasyToolbarCommandLayout.maximumVisibleCommandCount))
    }

    static var defaultOverflowOrder: [EasyToolbarCommand] {
        Array(defaultOrder.dropFirst(EasyToolbarCommandLayout.maximumVisibleCommandCount))
    }

    static var defaultOrderStorageValue: String {
        storageValue(for: defaultOrder)
    }

    static var defaultVisibleOrderStorageValue: String {
        storageValue(for: defaultVisibleOrder)
    }

    static var defaultOverflowOrderStorageValue: String {
        storageValue(for: defaultOverflowOrder)
    }

    static func storageValue(for commands: [EasyToolbarCommand]) -> String {
        commands.map(\.rawValue).joined(separator: ",")
    }

    static func parsedCommands(from storageValue: String) -> [EasyToolbarCommand] {
        var seen = Set<EasyToolbarCommand>()
        return storageValue
            .split(separator: ",")
            .compactMap { EasyToolbarCommand(rawValue: String($0)) }
            .filter { seen.insert($0).inserted }
    }

    static func orderedCommands(from storageValue: String) -> [EasyToolbarCommand] {
        var seen = Set<EasyToolbarCommand>()
        let storedCommands = parsedCommands(from: storageValue)
            .filter { seen.insert($0).inserted }
        let missingDefaults = defaultOrder.filter { !seen.contains($0) }
        return storedCommands + missingDefaults
    }

    var title: String {
        switch self {
        case .search: return "Search"
        case .volumeDown: return "Volume Down"
        case .volumeUp: return "Volume Up"
        case .mute: return "Mute"
        case .home: return "Home"
        case .rotateScreen: return "Rotate Screen"
        case .privacyBlur: return "Privacy Blur"
        case .screenshot: return "Screenshot"
        case .switchApps: return "Switch Apps"
        case .appSwitcher: return "App Switcher"
        case .disconnect: return "Disconnect"
        case .showShortcuts: return "Show Shortcuts"
        }
    }

    var systemImage: String {
        switch self {
        case .search: return "magnifyingglass"
        case .volumeDown: return "speaker.wave.1"
        case .volumeUp: return "speaker.wave.3"
        case .mute: return "speaker.slash"
        case .home: return "house"
        case .rotateScreen: return "rotate.right"
        case .privacyBlur: return "eye.slash"
        case .screenshot: return "camera"
        case .switchApps: return "arrow.left.arrow.right"
        case .appSwitcher: return "square.grid.2x2"
        case .disconnect: return "xmark.circle"
        case .showShortcuts: return "command"
        }
    }

    var shortcutDescription: String {
        switch self {
        case .search: return "Command-Space"
        case .volumeDown: return "Consumer Control: Volume Down"
        case .volumeUp: return "Consumer Control: Volume Up"
        case .mute: return "Consumer Control: Mute"
        case .home: return "Consumer Control: Home"
        case .rotateScreen: return "Specchio display rotation"
        case .privacyBlur: return "Specchio privacy blur"
        case .screenshot: return "Command-Shift-3"
        case .switchApps: return "Command-Tab"
        case .appSwitcher: return "Command-Tab hold"
        case .disconnect: return "Stop current stream"
        case .showShortcuts: return "Specchio shortcut panel"
        }
    }
}

struct EasyToolbarCommandLayout: Equatable {
    static let maximumVisibleCommandCount = 4

    let visibleCommands: [EasyToolbarCommand]
    let overflowCommands: [EasyToolbarCommand]

    var allCommands: [EasyToolbarCommand] {
        visibleCommands + overflowCommands
    }

    var visibleStorageValue: String {
        EasyToolbarCommand.storageValue(for: visibleCommands)
    }

    var overflowStorageValue: String {
        EasyToolbarCommand.storageValue(for: overflowCommands)
    }

    var legacyStorageValue: String {
        EasyToolbarCommand.storageValue(for: allCommands)
    }

    init(
        visibleCommands: [EasyToolbarCommand],
        overflowCommands: [EasyToolbarCommand],
        fallbackOrder: [EasyToolbarCommand] = EasyToolbarCommand.defaultOrder
    ) {
        let normalized = Self.normalized(
            visibleCommands: visibleCommands,
            overflowCommands: overflowCommands,
            fallbackOrder: fallbackOrder
        )
        self.visibleCommands = normalized.visibleCommands
        self.overflowCommands = normalized.overflowCommands
    }

    static func fromStorage(
        visibleStorageValue: String,
        overflowStorageValue: String,
        legacyOrderStorageValue: String,
        hasStoredVisibleOrder: Bool,
        hasStoredOverflowOrder: Bool
    ) -> EasyToolbarCommandLayout {
        let legacyOrder = EasyToolbarCommand.orderedCommands(from: legacyOrderStorageValue)
        guard hasStoredVisibleOrder || hasStoredOverflowOrder else {
            return EasyToolbarCommandLayout(
                visibleCommands: Array(legacyOrder.prefix(maximumVisibleCommandCount)),
                overflowCommands: Array(legacyOrder.dropFirst(maximumVisibleCommandCount)),
                fallbackOrder: legacyOrder
            )
        }

        return EasyToolbarCommandLayout(
            visibleCommands: EasyToolbarCommand.parsedCommands(from: visibleStorageValue),
            overflowCommands: EasyToolbarCommand.parsedCommands(from: overflowStorageValue),
            fallbackOrder: legacyOrder
        )
    }

    private static func normalized(
        visibleCommands: [EasyToolbarCommand],
        overflowCommands: [EasyToolbarCommand],
        fallbackOrder: [EasyToolbarCommand]
    ) -> (visibleCommands: [EasyToolbarCommand], overflowCommands: [EasyToolbarCommand]) {
        var seen = Set<EasyToolbarCommand>()
        var normalizedVisible: [EasyToolbarCommand] = []
        var normalizedOverflow: [EasyToolbarCommand] = []

        for command in visibleCommands where seen.insert(command).inserted {
            if normalizedVisible.count < maximumVisibleCommandCount {
                normalizedVisible.append(command)
            } else {
                normalizedOverflow.append(command)
            }
        }

        for command in overflowCommands where seen.insert(command).inserted {
            normalizedOverflow.append(command)
        }

        for command in fallbackOrder + EasyToolbarCommand.defaultOrder where seen.insert(command).inserted {
            normalizedOverflow.append(command)
        }

        return (normalizedVisible, normalizedOverflow)
    }
}

private func recordEasyHomeCommandDiagnostic(source: String, displayRotationDegrees: Int) {
    let normalizedRotation = EasyWindowVideoSizing.normalizedRotation(displayRotationDegrees)
    SpecchioLogger.easyMode.info("[EasyInputSurface] home command dispatch source=\(source, privacy: .public) displayRotation=\(normalizedRotation)")
    FrameDropDiagnostics.shared.recordLifecycle(
        source: "easyInputSurface",
        event: "homeCommand",
        reason: "toolbar-home",
        details: [
            "source": source,
            "displayRotation": String(normalizedRotation)
        ]
    )
}

private struct EasyToolbarCommandRow: View {
    let visibleCommands: [EasyToolbarCommand]
    let overflowCommands: [EasyToolbarCommand]
    let bluetoothHIDPanel: BluetoothHIDPanelController
    let phoneDisplayRotationDegrees: Int
    @Binding var replayKitPrivacyBlurEnabled: Bool
    @Binding var showEasyShortcutHelp: Bool
    let rotateScreen: (String) -> Void
    let disconnectStream: (String) -> Void

    var body: some View {
        HStack(spacing: EasyControlBarMetrics.toolbarSpacing) {
            ForEach(visibleCommands) { command in
                EasyToolbarCommandButton(
                    command: command,
                    bluetoothHIDPanel: bluetoothHIDPanel,
                    phoneDisplayRotationDegrees: phoneDisplayRotationDegrees,
                    replayKitPrivacyBlurEnabled: $replayKitPrivacyBlurEnabled,
                    showEasyShortcutHelp: $showEasyShortcutHelp,
                    rotateScreen: rotateScreen,
                    disconnectStream: disconnectStream,
                    source: "control-bar-visible"
                )
            }

            if !overflowCommands.isEmpty {
                EasyToolbarOverflowMenu(
                    commands: overflowCommands,
                    bluetoothHIDPanel: bluetoothHIDPanel,
                    phoneDisplayRotationDegrees: phoneDisplayRotationDegrees,
                    replayKitPrivacyBlurEnabled: $replayKitPrivacyBlurEnabled,
                    showEasyShortcutHelp: $showEasyShortcutHelp,
                    rotateScreen: rotateScreen,
                    disconnectStream: disconnectStream
                )
            }
        }
        .padding(.horizontal, EasyControlBarMetrics.toolbarHorizontalPadding)
        .padding(.vertical, EasyControlBarMetrics.toolbarVerticalPadding)
        .fixedSize(horizontal: true, vertical: false)
        .onAppear {
            SpecchioLogger.easyMode.debug("[EasyToolbarPriority] candidate visible=\(visibleCommands.count) overflow=\(overflowCommands.count)")
        }
    }
}

private struct EasyToolbarCommandButton: View {
    let command: EasyToolbarCommand
    let bluetoothHIDPanel: BluetoothHIDPanelController
    let phoneDisplayRotationDegrees: Int
    @Binding var replayKitPrivacyBlurEnabled: Bool
    @Binding var showEasyShortcutHelp: Bool
    let rotateScreen: (String) -> Void
    let disconnectStream: (String) -> Void
    let source: String

    var body: some View {
        Button {
            performCommand()
        } label: {
            Label(command.title, systemImage: command.systemImage)
                .labelStyle(.iconOnly)
                .foregroundStyle(foregroundStyle)
                .frame(width: EasyControlBarMetrics.buttonSide, height: EasyControlBarMetrics.buttonSide)
        }
        .buttonStyle(.borderless)
        .help(command.title)
        .accessibilityLabel(command.title)
    }

    private var foregroundStyle: Color {
        switch command {
        case .rotateScreen:
            return phoneDisplayRotationDegrees == 0 ? Color.primary : Color.accentColor
        case .privacyBlur:
            return replayKitPrivacyBlurEnabled ? Color.accentColor : Color.primary
        default:
            return Color.primary
        }
    }

    private func performCommand() {
        SpecchioLogger.easyMode.info("[EasyToolbarCommand] selected source=\(source, privacy: .public) command=\(command.rawValue, privacy: .public) title=\(command.title, privacy: .public)")
        switch command {
        case .search:
            bluetoothHIDPanel.sendKeyboardShortcutCommand(
                name: command.title,
                modifiers: 0x08,
                keyCodes: [0x2C],
                holdDuration: 0.05
            )
        case .volumeDown:
            bluetoothHIDPanel.sendConsumerControlCommand(bit: 9, name: command.title)
        case .volumeUp:
            bluetoothHIDPanel.sendConsumerControlCommand(bit: 10, name: command.title)
        case .mute:
            bluetoothHIDPanel.sendConsumerControlCommand(bit: 8, name: command.title)
        case .home:
            recordEasyHomeCommandDiagnostic(source: source, displayRotationDegrees: phoneDisplayRotationDegrees)
            bluetoothHIDPanel.sendConsumerControlCommand(bit: 2, name: command.title)
        case .rotateScreen:
            rotateScreen(source)
        case .privacyBlur:
            let nextValue = !replayKitPrivacyBlurEnabled
            SpecchioLogger.easyMode.info("[EasyPrivacyBlur] toggle selected source=\(source, privacy: .public) from=\(replayKitPrivacyBlurEnabled) to=\(nextValue)")
            replayKitPrivacyBlurEnabled = nextValue
        case .screenshot:
            bluetoothHIDPanel.sendKeyboardShortcutCommand(
                name: command.title,
                modifiers: 0x0A,
                keyCodes: [0x20],
                holdDuration: 0.05
            )
        case .switchApps:
            bluetoothHIDPanel.sendKeyboardShortcutCommand(
                name: command.title,
                modifiers: 0x08,
                keyCodes: [0x2B],
                holdDuration: 0.12
            )
        case .appSwitcher:
            bluetoothHIDPanel.sendKeyboardShortcutCommand(
                name: command.title,
                modifiers: 0x08,
                keyCodes: [0x2B],
                holdDuration: 0.45
            )
        case .disconnect:
            disconnectStream(source)
        case .showShortcuts:
            SpecchioLogger.easyMode.info("[EasyToolbarCommand] show shortcuts panel requested source=\(source, privacy: .public)")
            showEasyShortcutHelp = true
        }
    }
}

private struct EasyToolbarOverflowMenu: View {
    let commands: [EasyToolbarCommand]
    let bluetoothHIDPanel: BluetoothHIDPanelController
    let phoneDisplayRotationDegrees: Int
    @Binding var replayKitPrivacyBlurEnabled: Bool
    @Binding var showEasyShortcutHelp: Bool
    let rotateScreen: (String) -> Void
    let disconnectStream: (String) -> Void

    var body: some View {
        Menu {
            ForEach(commands) { command in
                Button(command.title, systemImage: command.systemImage) {
                    perform(command)
                }
            }
        } label: {
            Image(systemName: "ellipsis.circle")
                .frame(width: EasyControlBarMetrics.buttonSide, height: EasyControlBarMetrics.buttonSide)
        }
        .menuStyle(.borderlessButton)
        .help("Show more Easy controls")
        .onAppear {
            SpecchioLogger.easyMode.debug("[EasyToolbarOverflow] appeared commands=\(EasyToolbarCommand.storageValue(for: commands), privacy: .public)")
        }
    }

    private func perform(_ command: EasyToolbarCommand) {
        SpecchioLogger.easyMode.info("[EasyToolbarCommand] selected source=control-bar-overflow command=\(command.rawValue, privacy: .public) title=\(command.title, privacy: .public)")
        switch command {
        case .search:
            bluetoothHIDPanel.sendKeyboardShortcutCommand(
                name: command.title,
                modifiers: 0x08,
                keyCodes: [0x2C],
                holdDuration: 0.05
            )
        case .volumeDown:
            bluetoothHIDPanel.sendConsumerControlCommand(bit: 9, name: command.title)
        case .volumeUp:
            bluetoothHIDPanel.sendConsumerControlCommand(bit: 10, name: command.title)
        case .mute:
            bluetoothHIDPanel.sendConsumerControlCommand(bit: 8, name: command.title)
        case .home:
            recordEasyHomeCommandDiagnostic(source: "control-bar-overflow", displayRotationDegrees: phoneDisplayRotationDegrees)
            bluetoothHIDPanel.sendConsumerControlCommand(bit: 2, name: command.title)
        case .rotateScreen:
            rotateScreen("control-bar-overflow")
        case .privacyBlur:
            let nextValue = !replayKitPrivacyBlurEnabled
            SpecchioLogger.easyMode.info("[EasyPrivacyBlur] toggle selected source=control-bar-overflow from=\(replayKitPrivacyBlurEnabled) to=\(nextValue)")
            replayKitPrivacyBlurEnabled = nextValue
        case .screenshot:
            bluetoothHIDPanel.sendKeyboardShortcutCommand(
                name: command.title,
                modifiers: 0x0A,
                keyCodes: [0x20],
                holdDuration: 0.05
            )
        case .switchApps:
            bluetoothHIDPanel.sendKeyboardShortcutCommand(
                name: command.title,
                modifiers: 0x08,
                keyCodes: [0x2B],
                holdDuration: 0.12
            )
        case .appSwitcher:
            bluetoothHIDPanel.sendKeyboardShortcutCommand(
                name: command.title,
                modifiers: 0x08,
                keyCodes: [0x2B],
                holdDuration: 0.45
            )
        case .disconnect:
            disconnectStream("control-bar-overflow")
        case .showShortcuts:
            SpecchioLogger.easyMode.info("[EasyToolbarCommand] show shortcuts panel requested source=control-bar-overflow")
            showEasyShortcutHelp = true
        }
    }
}

private struct EasyShortcutHelpPanel: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Easy Shortcuts")
                    .font(.title2.weight(.semibold))
                Spacer()
                Button {
                    SpecchioLogger.easyMode.info("[EasyShortcutHelpPanel] close tapped")
                    dismiss()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                }
                .buttonStyle(.borderless)
                .help("Close")
            }

            Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 10) {
                ForEach(EasyToolbarCommand.defaultOrder) { command in
                    GridRow {
                        Label(command.title, systemImage: command.systemImage)
                            .frame(width: 160, alignment: .leading)
                        Text(command.shortcutDescription)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .padding(24)
        .frame(width: 420)
        .onAppear {
            SpecchioLogger.easyMode.info("[EasyShortcutHelpPanel] appeared commands=\(EasyToolbarCommand.defaultOrder.map(\.rawValue).joined(separator: ","), privacy: .public)")
        }
    }
}

private struct EasyScreenRotationToolbarButton: View {
    let rotationDegrees: Int
    let rotateScreen: (String) -> Void
    let source: String

    var body: some View {
        Button {
            rotateScreen(source)
        } label: {
            Image(systemName: "rotate.right")
                .foregroundStyle(rotationDegrees == 0 ? Color.primary : Color.accentColor)
                .frame(width: EasyControlBarMetrics.buttonSide, height: EasyControlBarMetrics.buttonSide)
        }
        .buttonStyle(.borderless)
        .help("Rotate screen")
        .accessibilityLabel("Rotate screen")
        .accessibilityValue("\(rotationDegrees) degrees")
    }
}

private func nextScreenRotation(after degrees: Int) -> Int {
    EasyWindowVideoSizing.nextRotation(after: degrees)
}

private func normalizedScreenRotation(_ degrees: Int) -> Int {
    EasyWindowVideoSizing.normalizedRotation(degrees)
}

private func isSidewaysRotation(_ degrees: Int) -> Bool {
    EasyWindowVideoSizing.isSidewaysRotation(degrees)
}

private struct EasyPrivacyBlurToolbarButton: View {
    @Binding var isEnabled: Bool
    let source: String

    var body: some View {
        Button {
            let nextValue = !isEnabled
            SpecchioLogger.easyMode.info("[EasyPrivacyBlur] toggle selected source=\(source, privacy: .public) from=\(isEnabled) to=\(nextValue)")
            isEnabled = nextValue
        } label: {
            Image(systemName: "eye.slash")
                .foregroundStyle(isEnabled ? Color.accentColor : Color.primary)
                .frame(width: EasyControlBarMetrics.buttonSide, height: EasyControlBarMetrics.buttonSide)
        }
        .buttonStyle(.borderless)
        .help(isEnabled ? "Disable privacy blur" : "Enable privacy blur")
        .accessibilityLabel("Privacy blur")
        .accessibilityValue(isEnabled ? "On" : "Off")
    }
}

private struct EasyControlBarSizeReader: NSViewRepresentable {
    let onSizeChange: (CGSize) -> Void

    func makeNSView(context: Context) -> SizeReaderView {
        let view = SizeReaderView()
        view.onSizeChange = onSizeChange
        return view
    }

    func updateNSView(_ nsView: SizeReaderView, context: Context) {
        nsView.onSizeChange = onSizeChange
        DispatchQueue.main.async {
            nsView.reportSizeIfNeeded()
        }
    }

    final class SizeReaderView: NSView {
        var onSizeChange: ((CGSize) -> Void)?
        private var lastSize: CGSize = .zero
        private var pendingSize: CGSize?
        private var isReportScheduled = false

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            reportSizeIfNeeded()
        }

        override func layout() {
            super.layout()
            reportSizeIfNeeded()
        }

        func reportSizeIfNeeded() {
            let size = bounds.size
            guard size != lastSize else { return }
            lastSize = size
            pendingSize = size

            guard !isReportScheduled else { return }
            isReportScheduled = true
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                let size = self.pendingSize
                self.pendingSize = nil
                self.isReportScheduled = false
                guard let size else { return }
                self.onSizeChange?(size)
            }
        }
    }
}

private struct EasyPhoneSurfaceSizeReader: NSViewRepresentable {
    let onSizeChange: (CGSize) -> Void

    func makeNSView(context: Context) -> SizeReaderView {
        let view = SizeReaderView()
        view.onSizeChange = onSizeChange
        return view
    }

    func updateNSView(_ nsView: SizeReaderView, context: Context) {
        nsView.onSizeChange = onSizeChange
        DispatchQueue.main.async {
            nsView.reportSizeIfNeeded(reason: "updateNSView")
        }
    }

    final class SizeReaderView: NSView {
        var onSizeChange: ((CGSize) -> Void)?
        private var lastSize: CGSize = .zero
        private var pendingSize: CGSize?
        private var isReportScheduled = false

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            reportSizeIfNeeded(reason: "viewDidMoveToWindow")
        }

        override func layout() {
            super.layout()
            reportSizeIfNeeded(reason: "layout")
        }

        func reportSizeIfNeeded(reason: String) {
            let size = bounds.size
            guard size != lastSize else { return }
            lastSize = size
            pendingSize = size
            SpecchioLogger.easyMode.info("[EasyGeometry] size reader reason=\(reason, privacy: .public) boundsWidth=\(size.width) boundsHeight=\(size.height)")

            guard !isReportScheduled else { return }
            isReportScheduled = true
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                let size = self.pendingSize
                self.pendingSize = nil
                self.isReportScheduled = false
                guard let size else { return }
                self.onSizeChange?(size)
            }
        }
    }
}

private struct EasyWindowBinder: NSViewRepresentable {
    let phoneScreenSize: CGSize
    let displayRotationDegrees: Int
    let onSurfaceChange: (NSWindow?, CGRect, Int) -> Void

    func makeNSView(context: Context) -> WindowBindingView {
        let view = WindowBindingView()
        view.phoneScreenSize = phoneScreenSize
        view.displayRotationDegrees = displayRotationDegrees
        view.onSurfaceChange = onSurfaceChange
        return view
    }

    func updateNSView(_ nsView: WindowBindingView, context: Context) {
        nsView.phoneScreenSize = phoneScreenSize
        nsView.displayRotationDegrees = displayRotationDegrees
        nsView.onSurfaceChange = onSurfaceChange
        DispatchQueue.main.async {
            nsView.reportWindowIfNeeded()
        }
    }

    final class WindowBindingView: NSView {
        var phoneScreenSize: CGSize = CGSize(width: 390, height: 844)
        var displayRotationDegrees = 0
        var onSurfaceChange: ((NSWindow?, CGRect, Int) -> Void)?
        private weak var lastWindow: NSWindow?
        private var lastFrameInWindow: CGRect = .null
        private var lastDisplayRotationDegrees: Int?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            reportWindowIfNeeded()
        }

        override func layout() {
            super.layout()
            reportWindowIfNeeded()
        }

        func reportWindowIfNeeded() {
            let frameInWindow = window == nil ? .zero : convert(bounds, to: nil)
            let normalizedRotation = normalizedScreenRotation(displayRotationDegrees)
            let windowChanged = lastWindow !== window
            let frameChanged = !lastFrameInWindow.equalTo(frameInWindow)
            let rotationChanged = lastDisplayRotationDegrees != normalizedRotation
            guard windowChanged || frameChanged || rotationChanged else {
                SpecchioLogger.easyMode.debug("[EasyGeometry] binder skipped branch=unchanged window=\(self.window?.windowNumber ?? -1) frame=\(InputSurfaceDiagnostics.rectString(frameInWindow), privacy: .public) rotation=\(normalizedRotation)")
                return
            }
            lastWindow = window
            lastFrameInWindow = frameInWindow
            lastDisplayRotationDegrees = normalizedRotation
            if let window {
                let contentRect = window.contentRect(forFrameRect: window.frame)
                let contentViewBounds = window.contentView?.bounds ?? .zero
                let contentLayoutRect = window.contentLayoutRect
                let safeAreaInsets = window.contentView?.safeAreaInsets ?? NSEdgeInsets()
                let surfaceRightGap = contentViewBounds.width > 0 ? contentViewBounds.width - frameInWindow.maxX : -1
                let surfaceBottomGap = contentViewBounds.height > 0 ? contentViewBounds.height - frameInWindow.maxY : -1
                SpecchioLogger.easyMode.info("[EasyGeometry] binder window branch=report windowChanged=\(windowChanged) frameChanged=\(frameChanged) rotationChanged=\(rotationChanged) rotation=\(normalizedRotation) frameX=\(frameInWindow.origin.x) frameY=\(frameInWindow.origin.y) frameWidth=\(frameInWindow.width) frameHeight=\(frameInWindow.height) boundsWidth=\(self.bounds.width) boundsHeight=\(self.bounds.height) contentWidth=\(contentRect.width) contentHeight=\(contentRect.height) contentBoundsWidth=\(contentViewBounds.width) contentBoundsHeight=\(contentViewBounds.height) layoutRectX=\(contentLayoutRect.origin.x) layoutRectY=\(contentLayoutRect.origin.y) layoutRectWidth=\(contentLayoutRect.width) layoutRectHeight=\(contentLayoutRect.height) safeLeft=\(safeAreaInsets.left) safeRight=\(safeAreaInsets.right) safeTop=\(safeAreaInsets.top) safeBottom=\(safeAreaInsets.bottom) surfaceLeftGap=\(frameInWindow.minX) surfaceRightGap=\(surfaceRightGap) surfaceBottomGap=\(surfaceBottomGap) phoneWidth=\(self.phoneScreenSize.width) phoneHeight=\(self.phoneScreenSize.height)")
            } else {
                SpecchioLogger.easyMode.info("[EasyGeometry] binder skipped branch=no-window windowChanged=\(windowChanged) frameChanged=\(frameChanged) rotationChanged=\(rotationChanged) rotation=\(normalizedRotation) boundsWidth=\(self.bounds.width) boundsHeight=\(self.bounds.height)")
            }
            onSurfaceChange?(window, frameInWindow, normalizedRotation)
        }
    }
}

private struct EasyPointerInputOverlay: NSViewRepresentable {
    let phoneScreenSize: CGSize
    let bluetoothHIDPanel: BluetoothHIDPanelController

    func makeNSView(context: Context) -> PointerView {
        let view = PointerView()
        view.phoneScreenSize = phoneScreenSize
        view.bluetoothHIDPanel = bluetoothHIDPanel
        return view
    }

    func updateNSView(_ nsView: PointerView, context: Context) {
        nsView.phoneScreenSize = phoneScreenSize
        nsView.bluetoothHIDPanel = bluetoothHIDPanel
    }

    final class PointerView: NSView {
        weak var bluetoothHIDPanel: BluetoothHIDPanelController?
        var phoneScreenSize: CGSize = CGSize(width: 390, height: 844)
        private var mouseDownPhonePoint: CGPoint?
        private var didDrag = false

        override var acceptsFirstResponder: Bool { true }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            window?.acceptsMouseMovedEvents = true
        }

        override func mouseDown(with event: NSEvent) {
            window?.makeFirstResponder(self)
            guard let point = phonePoint(for: event) else {
                SpecchioLogger.easyMode.info("[EasyPointer] mouseDown outside phone surface")
                return
            }
            mouseDownPhonePoint = point
            didDrag = false
            SpecchioLogger.easyMode.info("[EasyPointer] mouseDown phoneX=\(point.x) phoneY=\(point.y)")
            bluetoothHIDPanel?.beginPointerInteraction(at: point)
        }

        override func mouseDragged(with event: NSEvent) {
            guard mouseDownPhonePoint != nil, let point = phonePoint(for: event) else { return }
            didDrag = true
            SpecchioLogger.easyMode.debug("[EasyPointer] mouseDragged phoneX=\(point.x) phoneY=\(point.y)")
            bluetoothHIDPanel?.dragPointer(to: point)
        }

        override func mouseUp(with event: NSEvent) {
            guard mouseDownPhonePoint != nil else { return }
            let point = phonePoint(for: event) ?? mouseDownPhonePoint!
            SpecchioLogger.easyMode.info("[EasyPointer] mouseUp phoneX=\(point.x) phoneY=\(point.y) didDrag=\(self.didDrag)")
            bluetoothHIDPanel?.endPointerInteraction(at: point, click: !self.didDrag)
            mouseDownPhonePoint = nil
            didDrag = false
        }

        override func scrollWheel(with event: NSEvent) {
            bluetoothHIDPanel?.scrollPointer(deltaY: event.scrollingDeltaY)
        }

        private func phonePoint(for event: NSEvent) -> CGPoint? {
            guard bounds.width > 0, bounds.height > 0,
                  phoneScreenSize.width > 0, phoneScreenSize.height > 0 else {
                SpecchioLogger.easyMode.info("[EasyPointer] invalid geometry bounds=\(String(describing: self.bounds)) phone=\(String(describing: self.phoneScreenSize))")
                return nil
            }

            let local = convert(event.locationInWindow, from: nil)
            guard bounds.contains(local) else { return nil }

            let x = min(max(local.x / bounds.width, 0), 1) * phoneScreenSize.width
            let y = min(max((bounds.height - local.y) / bounds.height, 0), 1) * phoneScreenSize.height
            return CGPoint(x: x, y: y)
        }
    }
}

private struct EasyReplayKitUISnapshot: Equatable {
    enum Kind: String {
        case idle
        case listening
        case connecting
        case live
        case stale
        case paused
        case ended
        case disconnected
        case failed
    }

    let kind: Kind
    let statusBadge: String
    let statusDetail: String
    let overlayTitle: String?
    let overlayMessage: String?
    let overlayGuidance: String?
    let lastFrameAgeSeconds: TimeInterval?
    let lastLifecycleEvent: String?
    let isListening: Bool

    var showsRecoveryOverlay: Bool {
        switch kind {
        case .stale, .paused, .ended, .disconnected, .failed:
            return true
        case .idle, .listening, .connecting, .live:
            return false
        }
    }

    var dotColor: Color {
        switch kind {
        case .live:
            return .green
        case .stale, .paused, .ended, .disconnected:
            return isListening ? .orange : .red
        case .connecting, .listening:
            return .blue
        case .failed:
            return .red
        case .idle:
            return .secondary
        }
    }

    var overlayIndicator: String {
        switch kind {
        case .stale:
            return "S"
        case .paused:
            return "P"
        case .ended:
            return "E"
        case .disconnected:
            return "W"
        case .failed:
            return "F"
        case .idle, .listening, .connecting, .live:
            return "L"
        }
    }

    var statusSupplement: String {
        switch kind {
        case .stale:
            if let lastFrameAgeSeconds {
                return "frame \(Self.formatAge(lastFrameAgeSeconds))"
            }
            return statusDetail
        case .live:
            return "video flowing"
        case .connecting:
            return "waiting for frames"
        default:
            return statusDetail
        }
    }

    var logSummary: String {
        let ageText = lastFrameAgeSeconds.map(Self.formatAge) ?? "n/a"
        let lifecycle = lastLifecycleEvent ?? "n/a"
        return "kind=\(kind.rawValue) badge=\(statusBadge) detail=\(statusDetail) frameAge=\(ageText) lifecycle=\(lifecycle)"
    }

    func waitingDetailText() -> String {
        let lifecycleText = lastLifecycleEvent.map { " · \($0)" } ?? ""
        return "\(statusDetail)\(lifecycleText)"
    }

    static func make(from stream: ReplayKitScreenStreamManager) -> EasyReplayKitUISnapshot {
        let frameAgeSource = stream.frameAgeSeconds == nil ? "lastFrameReceivedAt" : "frameAgeSeconds"
        let rawFrameAge = stream.frameAgeSeconds
            ?? stream.lastFrameReceivedAt.map { Date().timeIntervalSince($0) }
        let frameAge = sanitizedFrameAge(rawFrameAge, source: frameAgeSource)
        let lifecycleEvent = stream.lastBroadcastEvent?.event

        switch stream.streamHealth {
        case .idle:
            return .init(
                kind: .idle,
                statusBadge: "Waiting for broadcast",
                statusDetail: "Waiting for connection",
                overlayTitle: nil,
                overlayMessage: nil,
                overlayGuidance: nil,
                lastFrameAgeSeconds: frameAge,
                lastLifecycleEvent: lifecycleEvent,
                isListening: stream.isListening
            )
        case .listening:
            return .init(
                kind: .listening,
                statusBadge: "Waiting for broadcast",
                statusDetail: "Waiting for connection",
                overlayTitle: nil,
                overlayMessage: nil,
                overlayGuidance: nil,
                lastFrameAgeSeconds: frameAge,
                lastLifecycleEvent: lifecycleEvent,
                isListening: stream.isListening
            )
        case .connecting:
            return .init(
                kind: .connecting,
                statusBadge: "Waiting for broadcast",
                statusDetail: "Waiting for connection",
                overlayTitle: nil,
                overlayMessage: nil,
                overlayGuidance: nil,
                lastFrameAgeSeconds: frameAge,
                lastLifecycleEvent: lifecycleEvent,
                isListening: stream.isListening
            )
        case .live:
            return .init(
                kind: .live,
                statusBadge: "Mobile App Live",
                statusDetail: "streaming",
                overlayTitle: nil,
                overlayMessage: nil,
                overlayGuidance: nil,
                lastFrameAgeSeconds: frameAge,
                lastLifecycleEvent: lifecycleEvent,
                isListening: stream.isListening
            )
        case .stale(let reason, let lastFrameAge):
            let staleFrameAge = sanitizedFrameAge(lastFrameAge, source: "streamHealth.stale.lastFrameAge")
            let ageText = staleFrameAge.map { " Last frame \(formatAge($0))." }
                ?? " No frame has reached Easy yet."
            let reasonText = reason.diagnosticDescription
            let overlayMessage = staleFrameAge == nil
                ? "Easy connected to the mobile app, but no video frame has reached the Mac yet (\(reasonText)).\(ageText)"
                : "The last frame is still visible. The App stopped sending fresh video (\(reasonText)).\(ageText)"
            let statusDetail = staleFrameAge == nil ? "awaiting first frame" : "frozen frame"
            let overlayTitle = staleFrameAge == nil ? "No video frame yet" : "Video stalled"
            return .init(
                kind: .stale,
                statusBadge: "Stale",
                statusDetail: statusDetail,
                overlayTitle: overlayTitle,
                overlayMessage: overlayMessage,
                overlayGuidance: "Wake iPhone · Open companion · Resume Start Screen",
                lastFrameAgeSeconds: staleFrameAge,
                lastLifecycleEvent: lifecycleEvent,
                isListening: stream.isListening
            )
        case .broadcastPaused:
            return .init(
                kind: .paused,
                statusBadge: "Paused",
                statusDetail: "broadcast paused",
                overlayTitle: "Mobile App paused",
                overlayMessage: "The companion reported a paused broadcast.",
                overlayGuidance: "Wake iPhone · Resume the broadcast",
                lastFrameAgeSeconds: frameAge,
                lastLifecycleEvent: lifecycleEvent,
                isListening: stream.isListening
            )
        case .broadcastEnded(let reason):
            return .init(
                kind: .ended,
                statusBadge: "Ended",
                statusDetail: "broadcast ended",
                overlayTitle: "Broadcast ended",
                overlayMessage: reason ?? "The broadcast ended. Easy is still listening for the next session.",
                overlayGuidance: "Wake iPhone · Open companion · Tap Start Screen",
                lastFrameAgeSeconds: frameAge,
                lastLifecycleEvent: lifecycleEvent,
                isListening: stream.isListening
            )
        case .disconnected(let reason):
            return .init(
                kind: .disconnected,
                statusBadge: "Waiting for broadcast",
                statusDetail: "receiver listening for reconnect",
                overlayTitle: "App disconnected",
                overlayMessage: reason.isEmpty ? "The TCP connection closed. Easy is waiting for the next broadcast connection." : reason,
                overlayGuidance: "Wake iPhone · Open companion · Tap Start Screen",
                lastFrameAgeSeconds: frameAge,
                lastLifecycleEvent: lifecycleEvent,
                isListening: stream.isListening
            )
        case .failed(let reason):
            return .init(
                kind: .failed,
                statusBadge: "Fail",
                statusDetail: "receiver error",
                overlayTitle: "Mobile App failed",
                overlayMessage: reason.isEmpty ? "The mobile app reported a sender or receiver failure." : reason,
                overlayGuidance: "Reopen companion · Start Screen again",
                lastFrameAgeSeconds: frameAge,
                lastLifecycleEvent: lifecycleEvent,
                isListening: stream.isListening
            )
        }
    }

    private static func sanitizedFrameAge(_ age: TimeInterval?, source: String) -> TimeInterval? {
        guard let age else {
            SpecchioLogger.easyMode.debug("[EasyReplayKitUISnapshot] frame age omitted source=\(source, privacy: .public) branch=nil")
            return nil
        }

        guard age.isFinite else {
            SpecchioLogger.easyMode.info("[EasyReplayKitUISnapshot] frame age sanitized source=\(source, privacy: .public) branch=nonFinite raw=\(String(describing: age), privacy: .public)")
            return nil
        }

        guard age >= 0 else {
            let formattedAge = String(format: "%.2f", age)
            SpecchioLogger.easyMode.info("[EasyReplayKitUISnapshot] frame age clamped source=\(source, privacy: .public) branch=negative raw=\(formattedAge, privacy: .public)")
            return 0
        }

        let formattedAge = String(format: "%.2f", age)
        SpecchioLogger.easyMode.debug("[EasyReplayKitUISnapshot] frame age accepted source=\(source, privacy: .public) branch=finite age=\(formattedAge, privacy: .public)")
        return age
    }

    private static func formatAge(_ age: TimeInterval) -> String {
        guard let age = sanitizedFrameAge(age, source: "formatAge") else {
            SpecchioLogger.easyMode.info("[EasyReplayKitUISnapshot] formatAge fallback branch=unavailable")
            return "n/a"
        }

        let seconds = Int(age.rounded())
        return "\(seconds)s"
    }
}

private struct EasyWindowAspectRatioAccessor: NSViewRepresentable {
    let displayedPhoneSize: CGSize
    let topChromeHeight: CGFloat
    let contentSize: CGSize
    let phoneSurfaceAvailableSize: CGSize
    let videoFrameSize: CGSize?
    let rotationDegrees: Int
    let minimumTopChromeHeight: CGFloat
    let countsWindowLayoutInsetAsChrome: Bool
    let standardControlsVisible: Bool

    final class AspectRatioView: NSView {
        weak var sizingController: EasyWindowSizingController?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            sizingController?.attach(to: window, reason: "viewDidMoveToWindow")
        }

        override func layout() {
            super.layout()
            sizingController?.noteLayout(reason: "layout")
        }
    }

    final class EasyWindowSizingController: NSObject, NSWindowDelegate {
        private var displayedPhoneSize: CGSize = SpecchioPhoneWindowMetrics.defaultPhoneScreenSize
        private var reportedTopChromeHeight: CGFloat = 0
        private var effectiveTopChromeHeight: CGFloat = 0
        private var minimumTopChromeHeight: CGFloat = 0
        private var countsWindowLayoutInsetAsChrome = true
        private var standardControlsVisible = false
        private var phoneSurfaceAvailableHeight: CGFloat = 0
        private var videoFrameSize: CGSize?
        private var hasHandledInitialVideoFrameSizing = false
        private var skipNextAttachAspectEnforceReason: String?
        private var rotationDegrees = 0
        private var lastAppliedRotationDegrees: Int?
        private weak var window: NSWindow?
        private weak var previousDelegate: NSWindowDelegate?
        private var isApplyingProgrammaticFrame = false
        private var liveResizeStartContentSize: CGSize?

        func update(
            displayedPhoneSize: CGSize,
            topChromeHeight: CGFloat,
            contentSize: CGSize,
            phoneSurfaceAvailableSize: CGSize,
            videoFrameSize: CGSize?,
            rotationDegrees: Int,
            minimumTopChromeHeight: CGFloat,
            countsWindowLayoutInsetAsChrome: Bool,
            standardControlsVisible: Bool,
            reason: String
        ) {
            let nextRotation = EasyWindowVideoSizing.normalizedRotation(rotationDegrees)
            let previousRotation = lastAppliedRotationDegrees
            let hadVideoFrame = self.videoFrameSize != nil
            let hasVideoFrame = videoFrameSize != nil
            let topChromeMeasurement = EasyWindowVideoSizing.stableEffectiveTopChromeHeight(
                previousEffectiveTopChromeHeight: effectiveTopChromeHeight,
                reportedTopChromeHeight: topChromeHeight,
                contentHeight: contentSize.height,
                phoneSurfaceAvailableHeight: phoneSurfaceAvailableSize.height,
                minimumTopChromeHeight: minimumTopChromeHeight
            )
            self.displayedPhoneSize = displayedPhoneSize
            self.reportedTopChromeHeight = topChromeHeight
            self.effectiveTopChromeHeight = topChromeMeasurement.height
            self.minimumTopChromeHeight = minimumTopChromeHeight
            self.countsWindowLayoutInsetAsChrome = countsWindowLayoutInsetAsChrome
            self.standardControlsVisible = standardControlsVisible
            self.phoneSurfaceAvailableHeight = phoneSurfaceAvailableSize.height
            self.videoFrameSize = videoFrameSize
            self.rotationDegrees = nextRotation
            lastAppliedRotationDegrees = nextRotation

            if !hasVideoFrame {
                hasHandledInitialVideoFrameSizing = false
                skipNextAttachAspectEnforceReason = nil
            }

            SpecchioLogger.easyMode.info("[EasySizing] update reason=\(reason, privacy: .public) rotation=\(nextRotation) previousRotation=\(previousRotation ?? -1) displayedPhoneWidth=\(displayedPhoneSize.width) displayedPhoneHeight=\(displayedPhoneSize.height) videoFrameWidth=\(videoFrameSize?.width ?? -1) videoFrameHeight=\(videoFrameSize?.height ?? -1) reportedTopChromeHeight=\(topChromeHeight) minimumTopChromeHeight=\(minimumTopChromeHeight) effectiveTopChromeHeight=\(topChromeMeasurement.height) topChromeSource=\(topChromeMeasurement.source.rawValue, privacy: .public) measuredTopChromeHeight=\(topChromeMeasurement.measuredHeight ?? -1) countsWindowLayoutInsetAsChrome=\(countsWindowLayoutInsetAsChrome) standardControlsVisible=\(standardControlsVisible) contentWidth=\(contentSize.width) contentHeight=\(contentSize.height) availableVideoWidth=\(phoneSurfaceAvailableSize.width) availableVideoHeight=\(phoneSurfaceAvailableSize.height) hasVideoFrame=\(hasVideoFrame) hadVideoFrame=\(hadVideoFrame) initialVideoFrameSizingHandled=\(self.hasHandledInitialVideoFrameSizing) pendingAttachAspectSkip=\(self.skipNextAttachAspectEnforceReason != nil)")

            guard hasVideoFrame else {
                if let previousRotation, previousRotation != nextRotation {
                    SpecchioLogger.easyMode.info("[EasySizing] update branch=no-video-frame-rotation-enforce reason=\(reason, privacy: .public) from=\(previousRotation) to=\(nextRotation)")
                    applyRotationResize(from: previousRotation, to: nextRotation, reason: "default-phone-\(reason)")
                } else {
                    SpecchioLogger.easyMode.info("[EasySizing] update branch=no-video-frame-aspect-enforce reason=\(reason, privacy: .public) displayedPhoneWidth=\(displayedPhoneSize.width) displayedPhoneHeight=\(displayedPhoneSize.height)")
                    enforceCurrentAspectIfNeeded(reason: "default-phone-\(reason)")
                }
                return
            }

            if !hadVideoFrame {
                handleInitialVideoFrameSizingIfNeeded(reason: "first-video-frame-\(reason)")
                return
            }

            guard let previousRotation, previousRotation != nextRotation else {
                SpecchioLogger.easyMode.debug("[EasySizing] update resize skipped reason=\(reason, privacy: .public) branch=no-rotation-change")
                return
            }

            applyRotationResize(from: previousRotation, to: nextRotation, reason: reason)
        }

        func attach(to nextWindow: NSWindow?, reason: String) {
            guard window !== nextWindow else {
                configureWindow(reason: reason)
                handleInitialVideoFrameSizingIfNeeded(reason: reason)
                enforceCurrentAspectAfterAttachIfNeeded(reason: "reattach-\(reason)")
                return
            }

            detachWindow(reason: "reattach-\(reason)")
            window = nextWindow

            guard let nextWindow else {
                SpecchioLogger.easyMode.info("[EasySizing] attach skipped reason=\(reason, privacy: .public) branch=no-window")
                return
            }

            if nextWindow.delegate !== self {
                previousDelegate = nextWindow.delegate
                nextWindow.delegate = self
                SpecchioLogger.easyMode.info("[EasySizing] delegate installed reason=\(reason, privacy: .public) hadPreviousDelegate=\(self.previousDelegate != nil)")
            } else {
                SpecchioLogger.easyMode.debug("[EasySizing] delegate already installed reason=\(reason, privacy: .public)")
            }

            if lastAppliedRotationDegrees == nil {
                lastAppliedRotationDegrees = rotationDegrees
                SpecchioLogger.easyMode.info("[EasySizing] initial rotation seeded rotation=\(self.rotationDegrees)")
            }

            configureWindow(reason: reason)
            handleInitialVideoFrameSizingIfNeeded(reason: reason)
            enforceCurrentAspectAfterAttachIfNeeded(reason: "attach-\(reason)")
        }

        func noteLayout(reason: String) {
            guard let window else {
                SpecchioLogger.easyMode.debug("[EasySizing] layout observed reason=\(reason, privacy: .public) branch=no-window")
                return
            }

            let contentSize = currentContentSize(for: window)
            SpecchioLogger.easyMode.debug("[EasySizing] layout observed reason=\(reason, privacy: .public) contentWidth=\(contentSize.width) contentHeight=\(contentSize.height) hasVideoFrame=\(self.videoFrameSize != nil) videoFrameWidth=\(self.videoFrameSize?.width ?? -1) videoFrameHeight=\(self.videoFrameSize?.height ?? -1) initialVideoFrameSizingHandled=\(self.hasHandledInitialVideoFrameSizing) pendingAttachAspectSkip=\(self.skipNextAttachAspectEnforceReason != nil) rotation=\(self.rotationDegrees)")
        }

        func enforceCurrentAspectIfNeeded(reason: String, forcedDriver: EasyWindowResizeDriver? = nil) {
            guard !isApplyingProgrammaticFrame else {
                SpecchioLogger.easyMode.debug("[EasySizing] enforce skipped reason=\(reason, privacy: .public) branch=programmatic-frame")
                return
            }
            guard let window else {
                SpecchioLogger.easyMode.info("[EasySizing] enforce skipped reason=\(reason, privacy: .public) branch=no-window")
                return
            }
            guard !window.inLiveResize else {
                SpecchioLogger.easyMode.debug("[EasySizing] enforce skipped reason=\(reason, privacy: .public) branch=live-resize")
                return
            }

            let contentSize = currentContentSize(for: window)
            let minimumContentSize = minimumContentSize(for: window)
            let effectiveTopChromeHeight = effectiveNonVideoHeight(for: window)
            guard !EasyWindowVideoSizing.contentSizeMatchesVideoAspect(
                contentSize: contentSize,
                displayedPhoneSize: displayedPhoneSize,
                topChromeHeight: effectiveTopChromeHeight,
                minimumContentSize: minimumContentSize,
                minimumTopChromeHeight: minimumTopChromeHeight
            ) else {
                SpecchioLogger.easyMode.debug("[EasySizing] enforce unchanged reason=\(reason, privacy: .public) contentWidth=\(contentSize.width) contentHeight=\(contentSize.height) rotation=\(self.rotationDegrees)")
                return
            }

            let driver = forcedDriver ?? EasyWindowVideoSizing.defaultResizeDriver(rotationDegrees: rotationDegrees)
            let targetContentSize = EasyWindowVideoSizing.targetContentSizeForResize(
                contentSize: contentSize,
                displayedPhoneSize: displayedPhoneSize,
                topChromeHeight: effectiveTopChromeHeight,
                minimumContentSize: minimumContentSize,
                driver: driver,
                minimumTopChromeHeight: minimumTopChromeHeight
            )

            SpecchioLogger.easyMode.info("[EasySizing] enforce applying reason=\(reason, privacy: .public) driver=\(driver.rawValue, privacy: .public) contentWidth=\(contentSize.width) contentHeight=\(contentSize.height) targetWidth=\(targetContentSize.width) targetHeight=\(targetContentSize.height) effectiveTopChromeHeight=\(effectiveTopChromeHeight) rotation=\(self.rotationDegrees)")
            applyContentSize(targetContentSize, reason: reason, source: "aspect-enforce")
        }

        private func enforceCurrentAspectAfterAttachIfNeeded(reason: String) {
            if let skipReason = skipNextAttachAspectEnforceReason {
                skipNextAttachAspectEnforceReason = nil
                SpecchioLogger.easyMode.info("[EasySizing] attach aspect enforce skipped reason=\(reason, privacy: .public) branch=preserve-first-video-window-size trigger=\(skipReason, privacy: .public) hasVideoFrame=\(self.videoFrameSize != nil)")
                return
            }

            SpecchioLogger.easyMode.debug("[EasySizing] attach aspect enforce continuing reason=\(reason, privacy: .public) branch=normal")
            enforceCurrentAspectIfNeeded(reason: reason)
        }

        private func handleInitialVideoFrameSizingIfNeeded(reason: String) {
            guard let videoFrameSize else {
                SpecchioLogger.easyMode.info("[EasySizing] initial video sizing skipped reason=\(reason, privacy: .public) branch=waiting-for-video-frame")
                return
            }
            guard !hasHandledInitialVideoFrameSizing else {
                SpecchioLogger.easyMode.debug("[EasySizing] initial video sizing skipped reason=\(reason, privacy: .public) branch=already-handled")
                return
            }
            guard let window else {
                SpecchioLogger.easyMode.info("[EasySizing] initial video sizing skipped reason=\(reason, privacy: .public) branch=no-window")
                return
            }
            guard !window.inLiveResize else {
                SpecchioLogger.easyMode.info("[EasySizing] initial video sizing skipped reason=\(reason, privacy: .public) branch=live-resize")
                return
            }

            let contentSize = currentContentSize(for: window)
            let minimumContentSize = minimumContentSize(for: window)
            let effectiveTopChromeHeight = effectiveNonVideoHeight(for: window)
            let targetContentSize = EasyWindowVideoSizing.targetContentSizeForInitialVideoFrame(
                videoFrameSize: videoFrameSize,
                topChromeHeight: effectiveTopChromeHeight,
                minimumContentSize: minimumContentSize,
                minimumTopChromeHeight: minimumTopChromeHeight
            )
            let targetContentSizeIsValid = targetContentSize.width > 0 && targetContentSize.height > 0
            hasHandledInitialVideoFrameSizing = true
            skipNextAttachAspectEnforceReason = reason
            SpecchioLogger.easyMode.info("[EasySizing] initial video sizing handled reason=\(reason, privacy: .public) branch=preserve-existing-window-size sourceFrameWidth=\(videoFrameSize.width) sourceFrameHeight=\(videoFrameSize.height) contentWidth=\(contentSize.width) contentHeight=\(contentSize.height) wouldTargetWidth=\(targetContentSize.width) wouldTargetHeight=\(targetContentSize.height) wouldTargetValid=\(targetContentSizeIsValid) displayedPhoneWidth=\(self.displayedPhoneSize.width) displayedPhoneHeight=\(self.displayedPhoneSize.height) effectiveTopChromeHeight=\(effectiveTopChromeHeight)")
        }

        func windowWillStartLiveResize(_ notification: Notification) {
            guard let window = notification.object as? NSWindow else {
                SpecchioLogger.easyMode.info("[EasySizing] willStartLiveResize skipped branch=invalid-window")
                previousDelegate?.windowWillStartLiveResize?(notification)
                return
            }

            let contentSize = currentContentSize(for: window)
            liveResizeStartContentSize = contentSize
            SpecchioLogger.easyMode.info("[EasySizing] willStartLiveResize contentWidth=\(contentSize.width) contentHeight=\(contentSize.height) rotation=\(self.rotationDegrees)")
            previousDelegate?.windowWillStartLiveResize?(notification)
        }

        func windowWillResize(_ sender: NSWindow, to frameSize: NSSize) -> NSSize {
            guard !isApplyingProgrammaticFrame else {
                SpecchioLogger.easyMode.debug("[EasySizing] willResize passthrough branch=programmatic proposedFrameWidth=\(frameSize.width) proposedFrameHeight=\(frameSize.height)")
                return forwardedWindowWillResize(sender, to: frameSize)
            }

            let currentContentSize = currentContentSize(for: sender)
            let proposedContentSize = contentSize(forFrameSize: frameSize, in: sender)
            let forwardedFrameSize = forwardedWindowWillResize(sender, to: frameSize)
            let forwardedContentSize = contentSize(forFrameSize: forwardedFrameSize, in: sender)
            let driver = EasyWindowVideoSizing.resizeDriver(
                previousContentSize: liveResizeStartContentSize ?? currentContentSize,
                currentContentSize: forwardedContentSize,
                rotationDegrees: rotationDegrees
            )
            let targetContentSize = EasyWindowVideoSizing.targetContentSizeForResize(
                contentSize: forwardedContentSize,
                displayedPhoneSize: displayedPhoneSize,
                topChromeHeight: effectiveNonVideoHeight(for: sender),
                minimumContentSize: minimumContentSize(for: sender),
                driver: driver,
                minimumTopChromeHeight: minimumTopChromeHeight
            )
            guard targetContentSize.width > 0, targetContentSize.height > 0 else {
                SpecchioLogger.easyMode.info("[EasySizing] willResize passthrough branch=invalid-target proposedFrameWidth=\(frameSize.width) proposedFrameHeight=\(frameSize.height) proposedContentWidth=\(proposedContentSize.width) proposedContentHeight=\(proposedContentSize.height) currentContentWidth=\(currentContentSize.width) currentContentHeight=\(currentContentSize.height) forwardedFrameWidth=\(forwardedFrameSize.width) forwardedFrameHeight=\(forwardedFrameSize.height) rotation=\(self.rotationDegrees)")
                return forwardedFrameSize
            }

            let constrainedFrameSize = self.frameSize(forContentSize: targetContentSize, in: sender)
            SpecchioLogger.easyMode.debug("[EasySizing] willResize constrained branch=user-live-resize driver=\(driver.rawValue, privacy: .public) hasVideoFrame=\(self.videoFrameSize != nil) proposedFrameWidth=\(frameSize.width) proposedFrameHeight=\(frameSize.height) proposedContentWidth=\(proposedContentSize.width) proposedContentHeight=\(proposedContentSize.height) currentContentWidth=\(currentContentSize.width) currentContentHeight=\(currentContentSize.height) forwardedFrameWidth=\(forwardedFrameSize.width) forwardedFrameHeight=\(forwardedFrameSize.height) targetContentWidth=\(targetContentSize.width) targetContentHeight=\(targetContentSize.height) constrainedFrameWidth=\(constrainedFrameSize.width) constrainedFrameHeight=\(constrainedFrameSize.height) displayedPhoneWidth=\(self.displayedPhoneSize.width) displayedPhoneHeight=\(self.displayedPhoneSize.height) rotation=\(self.rotationDegrees)")
            return constrainedFrameSize
        }

        func windowDidResize(_ notification: Notification) {
            if let window = notification.object as? NSWindow {
                let contentSize = currentContentSize(for: window)
                SpecchioLogger.easyMode.debug("[EasySizing] didResize contentWidth=\(contentSize.width) contentHeight=\(contentSize.height) inLiveResize=\(window.inLiveResize)")
            }
            previousDelegate?.windowDidResize?(notification)
        }

        func windowDidEndLiveResize(_ notification: Notification) {
            let resizeWindow = notification.object as? NSWindow
            let finalContentSize = resizeWindow.map { currentContentSize(for: $0) } ?? .zero
            let driver = EasyWindowVideoSizing.resizeDriver(
                previousContentSize: liveResizeStartContentSize,
                currentContentSize: finalContentSize,
                rotationDegrees: rotationDegrees
            )
            SpecchioLogger.easyMode.info("[EasySizing] didEndLiveResize startContentWidth=\(self.liveResizeStartContentSize?.width ?? -1) startContentHeight=\(self.liveResizeStartContentSize?.height ?? -1) finalContentWidth=\(finalContentSize.width) finalContentHeight=\(finalContentSize.height) driver=\(driver.rawValue, privacy: .public) rotation=\(self.rotationDegrees)")
            liveResizeStartContentSize = nil
            enforceCurrentAspectIfNeeded(reason: "windowDidEndLiveResize", forcedDriver: driver)
            previousDelegate?.windowDidEndLiveResize?(notification)
        }

        func windowDidBecomeKey(_ notification: Notification) {
            if let window {
                SpecchioPresentationWindowChrome.reapplyAfterSystemChromeUpdate(
                    to: window,
                    reason: "EasySizing-windowDidBecomeKey",
                    standardControlsVisible: standardControlsVisible
                )
            } else {
                configureWindow(reason: "windowDidBecomeKey")
            }
            previousDelegate?.windowDidBecomeKey?(notification)
        }

        func windowDidResignKey(_ notification: Notification) {
            if let window {
                SpecchioPresentationWindowChrome.reapplyAfterSystemChromeUpdate(
                    to: window,
                    reason: "EasySizing-windowDidResignKey",
                    standardControlsVisible: standardControlsVisible
                )
            } else {
                configureWindow(reason: "windowDidResignKey")
            }
            previousDelegate?.windowDidResignKey?(notification)
        }

        func windowDidBecomeMain(_ notification: Notification) {
            if let window {
                SpecchioPresentationWindowChrome.reapplyAfterSystemChromeUpdate(
                    to: window,
                    reason: "EasySizing-windowDidBecomeMain",
                    standardControlsVisible: standardControlsVisible
                )
            } else {
                configureWindow(reason: "windowDidBecomeMain")
            }
            previousDelegate?.windowDidBecomeMain?(notification)
        }

        func windowDidResignMain(_ notification: Notification) {
            if let window {
                SpecchioPresentationWindowChrome.reapplyAfterSystemChromeUpdate(
                    to: window,
                    reason: "EasySizing-windowDidResignMain",
                    standardControlsVisible: standardControlsVisible
                )
            } else {
                configureWindow(reason: "windowDidResignMain")
            }
            previousDelegate?.windowDidResignMain?(notification)
        }

        override func responds(to aSelector: Selector!) -> Bool {
            if super.responds(to: aSelector) { return true }
            return previousDelegate?.responds(to: aSelector) ?? false
        }

        override func forwardingTarget(for aSelector: Selector!) -> Any? {
            guard previousDelegate?.responds(to: aSelector) == true else {
                return super.forwardingTarget(for: aSelector)
            }
            return previousDelegate
        }

        deinit {
            detachWindow(reason: "deinit")
        }

        private func configureWindow(reason: String) {
            guard let window else {
                SpecchioLogger.easyMode.info("[EasySizing] configure skipped reason=\(reason, privacy: .public) branch=no-window")
                return
            }

            SpecchioPresentationWindowChrome.apply(
                to: window,
                reason: "EasySizing-\(reason)",
                standardControlsVisible: standardControlsVisible
            )
            SpecchioLogger.easyMode.info("[EasySizing] configured reason=\(reason, privacy: .public) presentation=iPhoneMirroring standardControlsVisible=\(self.standardControlsVisible) titled=\(window.styleMask.contains(.titled)) toolbarHidden=\(!(window.toolbar?.isVisible ?? true)) contentWidth=\(self.currentContentSize(for: window).width) contentHeight=\(self.currentContentSize(for: window).height) rotation=\(self.rotationDegrees) minimumTopChromeHeight=\(self.minimumTopChromeHeight) transparentPanelBacking=\(!window.isOpaque) windowLevel=\(window.level.rawValue)")
        }

        private func applyRotationResize(from previousRotation: Int, to nextRotation: Int, reason: String) {
            guard let window else {
                SpecchioLogger.easyMode.info("[EasySizing] rotation resize skipped reason=\(reason, privacy: .public) branch=no-window from=\(previousRotation) to=\(nextRotation)")
                return
            }
            guard !window.inLiveResize else {
                SpecchioLogger.easyMode.info("[EasySizing] rotation resize deferred reason=\(reason, privacy: .public) branch=live-resize from=\(previousRotation) to=\(nextRotation)")
                enforceCurrentAspectIfNeeded(reason: "rotation-live-resize")
                return
            }

            let currentContentSize = currentContentSize(for: window)
            let effectiveTopChromeHeight = effectiveNonVideoHeight(for: window)
            let targetContentSize = EasyWindowVideoSizing.targetContentSizeAfterRotation(
                currentContentSize: currentContentSize,
                displayedPhoneSize: displayedPhoneSize,
                topChromeHeight: effectiveTopChromeHeight,
                minimumContentSize: minimumContentSize(for: window),
                from: previousRotation,
                to: nextRotation,
                minimumTopChromeHeight: minimumTopChromeHeight
            )
            guard targetContentSize.width > 0, targetContentSize.height > 0 else {
                SpecchioLogger.easyMode.info("[EasySizing] rotation resize skipped reason=\(reason, privacy: .public) branch=invalid-target from=\(previousRotation) to=\(nextRotation) currentWidth=\(currentContentSize.width) currentHeight=\(currentContentSize.height)")
                return
            }

            SpecchioLogger.easyMode.info("[EasySizing] rotation resize applying reason=\(reason, privacy: .public) from=\(previousRotation) to=\(nextRotation) currentWidth=\(currentContentSize.width) currentHeight=\(currentContentSize.height) targetWidth=\(targetContentSize.width) targetHeight=\(targetContentSize.height) effectiveTopChromeHeight=\(effectiveTopChromeHeight)")
            applyContentSize(targetContentSize, reason: reason, source: "rotation")
        }

        private func applyContentSize(_ targetContentSize: CGSize, reason: String, source: String) {
            guard let window else {
                SpecchioLogger.easyMode.info("[EasySizing] apply skipped reason=\(reason, privacy: .public) source=\(source, privacy: .public) branch=no-window")
                return
            }

            let clampedContentSize = contentSizeByClampingToVisibleScreen(targetContentSize, in: window)
            let targetFrameSize = frameSize(forContentSize: clampedContentSize, in: window)
            let targetFrame = frameCenteredOnCurrentWindow(
                targetFrameSize: targetFrameSize,
                currentFrame: window.frame,
                visibleFrame: (window.screen ?? NSScreen.main)?.visibleFrame
            )

            let currentFrame = window.frame
            guard abs(currentFrame.width - targetFrame.width) > 1
                    || abs(currentFrame.height - targetFrame.height) > 1
                    || abs(currentFrame.origin.x - targetFrame.origin.x) > 1
                    || abs(currentFrame.origin.y - targetFrame.origin.y) > 1 else {
                SpecchioLogger.easyMode.debug("[EasySizing] apply skipped reason=\(reason, privacy: .public) source=\(source, privacy: .public) branch=already-matched frameWidth=\(currentFrame.width) frameHeight=\(currentFrame.height)")
                return
            }

            SpecchioLogger.easyMode.info("[EasySizing] apply frame reason=\(reason, privacy: .public) source=\(source, privacy: .public) requestedContentWidth=\(targetContentSize.width) requestedContentHeight=\(targetContentSize.height) clampedContentWidth=\(clampedContentSize.width) clampedContentHeight=\(clampedContentSize.height) targetFrameX=\(targetFrame.origin.x) targetFrameY=\(targetFrame.origin.y) targetFrameWidth=\(targetFrame.width) targetFrameHeight=\(targetFrame.height)")
            logWindowGeometryProbe(
                window,
                reason: reason,
                source: "\(source)-before-setFrame",
                requestedContentSize: targetContentSize,
                clampedContentSize: clampedContentSize
            )
            isApplyingProgrammaticFrame = true
            defer { isApplyingProgrammaticFrame = false }
            window.setFrame(targetFrame, display: true, animate: false)
            logWindowGeometryProbe(
                window,
                reason: reason,
                source: "\(source)-after-setFrame",
                requestedContentSize: targetContentSize,
                clampedContentSize: clampedContentSize
            )
        }

        private func currentContentSize(for window: NSWindow) -> CGSize {
            window.contentRect(forFrameRect: window.frame).size
        }

        private func contentSize(forFrameSize frameSize: CGSize, in window: NSWindow) -> CGSize {
            window.contentRect(forFrameRect: CGRect(origin: .zero, size: frameSize)).size
        }

        private func frameSize(forContentSize contentSize: CGSize, in window: NSWindow) -> CGSize {
            window.frameRect(forContentRect: CGRect(origin: .zero, size: contentSize)).size
        }

        private func effectiveTopChromeHeight(for window: NSWindow) -> CGFloat {
            let height = EasyWindowVideoSizing.effectiveTopChromeHeight(
                reportedTopChromeHeight: effectiveTopChromeHeight,
                minimumTopChromeHeight: minimumTopChromeHeight
            )
            SpecchioLogger.easyMode.debug("[EasySizing] effective top chrome read storedHeight=\(self.effectiveTopChromeHeight) sanitizedHeight=\(height) reportedTopChromeHeight=\(self.reportedTopChromeHeight) currentContentHeight=\(self.currentContentSize(for: window).height) availableVideoHeight=\(self.phoneSurfaceAvailableHeight)")
            return height
        }

        private func effectiveNonVideoHeight(for window: NSWindow) -> CGFloat {
            let controlBarHeight = effectiveTopChromeHeight(for: window)
            let contentRect = window.contentRect(forFrameRect: window.frame)
            let measuredLayoutInsetHeight = max(0, contentRect.height - window.contentLayoutRect.height)
            let layoutInsetHeight = countsWindowLayoutInsetAsChrome ? measuredLayoutInsetHeight : 0
            let height = controlBarHeight + layoutInsetHeight
            SpecchioLogger.easyMode.debug("[EasySizing] effective non-video height controlBarHeight=\(controlBarHeight) layoutInsetHeight=\(layoutInsetHeight) measuredLayoutInsetHeight=\(measuredLayoutInsetHeight) countsWindowLayoutInsetAsChrome=\(self.countsWindowLayoutInsetAsChrome) totalNonVideoHeight=\(height) contentHeight=\(contentRect.height) contentLayoutHeight=\(window.contentLayoutRect.height)")
            return height
        }

        private func minimumContentSize(for window: NSWindow) -> CGSize {
            let contentMinSize = CGSize(
                width: window.contentMinSize.width.isFinite ? max(0, window.contentMinSize.width) : 0,
                height: window.contentMinSize.height.isFinite ? max(0, window.contentMinSize.height) : 0
            )
            let frameMinSize = window.minSize
            let frameDerivedContentSize = frameMinSize.width.isFinite && frameMinSize.height.isFinite && frameMinSize.width > 0 && frameMinSize.height > 0
                ? window.contentRect(forFrameRect: CGRect(origin: .zero, size: frameMinSize)).size
                : .zero
            let minimumSize = CGSize(
                width: max(contentMinSize.width, frameDerivedContentSize.width, 0),
                height: max(contentMinSize.height, frameDerivedContentSize.height, 0)
            )
            SpecchioLogger.easyMode.debug("[EasySizing] minimum content size contentMinWidth=\(contentMinSize.width) contentMinHeight=\(contentMinSize.height) frameMinWidth=\(frameMinSize.width) frameMinHeight=\(frameMinSize.height) frameContentWidth=\(frameDerivedContentSize.width) frameContentHeight=\(frameDerivedContentSize.height) minimumWidth=\(minimumSize.width) minimumHeight=\(minimumSize.height)")
            return minimumSize
        }

        private func contentSizeByClampingToVisibleScreen(_ contentSize: CGSize, in window: NSWindow) -> CGSize {
            guard let visibleFrame = (window.screen ?? NSScreen.main)?.visibleFrame else {
                SpecchioLogger.easyMode.info("[EasySizing] clamp skipped branch=no-screen contentWidth=\(contentSize.width) contentHeight=\(contentSize.height)")
                return contentSize
            }

            let maximumContentSize = window.contentRect(forFrameRect: CGRect(origin: .zero, size: visibleFrame.size)).size
            let clampedSize = EasyWindowVideoSizing.contentSizeByScalingDownToFit(
                contentSize,
                topChromeHeight: effectiveNonVideoHeight(for: window),
                maximumContentSize: maximumContentSize,
                minimumTopChromeHeight: minimumTopChromeHeight
            )
            let didClamp = abs(clampedSize.width - contentSize.width) > EasyWindowVideoSizing.tolerance
                || abs(clampedSize.height - contentSize.height) > EasyWindowVideoSizing.tolerance
            SpecchioLogger.easyMode.info("[EasySizing] clamp decision didClamp=\(didClamp) contentWidth=\(contentSize.width) contentHeight=\(contentSize.height) maximumContentWidth=\(maximumContentSize.width) maximumContentHeight=\(maximumContentSize.height) clampedWidth=\(clampedSize.width) clampedHeight=\(clampedSize.height)")
            return clampedSize
        }

        private func logWindowGeometryProbe(
            _ window: NSWindow,
            reason: String,
            source: String,
            requestedContentSize: CGSize,
            clampedContentSize: CGSize
        ) {
            let contentRect = window.contentRect(forFrameRect: window.frame)
            let contentViewBounds = window.contentView?.bounds ?? .zero
            let safeAreaInsets = window.contentView?.safeAreaInsets ?? NSEdgeInsets()
            let contentLayoutRect = window.contentLayoutRect
            let nonVideoHeight = effectiveNonVideoHeight(for: window)
            let surfaceHeightFromContent = max(0, contentRect.height - nonVideoHeight)
            let expectedWidthFromSurfaceHeight = displayedPhoneSize.height > 0
                ? surfaceHeightFromContent * (displayedPhoneSize.width / displayedPhoneSize.height)
                : -1
            SpecchioLogger.easyMode.info("[EasyGeometryProbe] window reason=\(reason, privacy: .public) source=\(source, privacy: .public) frameWidth=\(window.frame.width) frameHeight=\(window.frame.height) contentWidth=\(contentRect.width) contentHeight=\(contentRect.height) contentBoundsWidth=\(contentViewBounds.width) contentBoundsHeight=\(contentViewBounds.height) layoutRectX=\(contentLayoutRect.origin.x) layoutRectY=\(contentLayoutRect.origin.y) layoutRectWidth=\(contentLayoutRect.width) layoutRectHeight=\(contentLayoutRect.height) safeLeft=\(safeAreaInsets.left) safeRight=\(safeAreaInsets.right) safeTop=\(safeAreaInsets.top) safeBottom=\(safeAreaInsets.bottom) nonVideoHeight=\(nonVideoHeight) requestedContentWidth=\(requestedContentSize.width) requestedContentHeight=\(requestedContentSize.height) clampedContentWidth=\(clampedContentSize.width) clampedContentHeight=\(clampedContentSize.height) displayedPhoneWidth=\(self.displayedPhoneSize.width) displayedPhoneHeight=\(self.displayedPhoneSize.height) expectedWidthFromSurfaceHeight=\(expectedWidthFromSurfaceHeight)")
        }

        private func frameCenteredOnCurrentWindow(
            targetFrameSize: CGSize,
            currentFrame: CGRect,
            visibleFrame: CGRect?
        ) -> CGRect {
            let center = CGPoint(x: currentFrame.midX, y: currentFrame.midY)
            var targetFrame = CGRect(
                x: center.x - (targetFrameSize.width / 2),
                y: center.y - (targetFrameSize.height / 2),
                width: targetFrameSize.width,
                height: targetFrameSize.height
            )

            guard let visibleFrame else { return targetFrame }

            if targetFrame.width >= visibleFrame.width {
                targetFrame.origin.x = visibleFrame.minX
            } else {
                targetFrame.origin.x = min(
                    max(targetFrame.origin.x, visibleFrame.minX),
                    visibleFrame.maxX - targetFrame.width
                )
            }

            if targetFrame.height >= visibleFrame.height {
                targetFrame.origin.y = visibleFrame.minY
            } else {
                targetFrame.origin.y = min(
                    max(targetFrame.origin.y, visibleFrame.minY),
                    visibleFrame.maxY - targetFrame.height
                )
            }

            return targetFrame
        }

        private func forwardedWindowWillResize(_ sender: NSWindow, to frameSize: NSSize) -> NSSize {
            previousDelegate?.windowWillResize?(sender, to: frameSize) ?? frameSize
        }

        private func detachWindow(reason: String) {
            guard let window else { return }
            if window.delegate === self {
                window.delegate = previousDelegate
                SpecchioLogger.easyMode.info("[EasySizing] delegate restored reason=\(reason, privacy: .public) restoredPreviousDelegate=\(self.previousDelegate != nil)")
            }
            self.window = nil
            previousDelegate = nil
        }
    }

    func makeCoordinator() -> EasyWindowSizingController {
        let controller = EasyWindowSizingController()
        controller.update(
            displayedPhoneSize: displayedPhoneSize,
            topChromeHeight: topChromeHeight,
            contentSize: contentSize,
            phoneSurfaceAvailableSize: phoneSurfaceAvailableSize,
            videoFrameSize: videoFrameSize,
            rotationDegrees: rotationDegrees,
            minimumTopChromeHeight: minimumTopChromeHeight,
            countsWindowLayoutInsetAsChrome: countsWindowLayoutInsetAsChrome,
            standardControlsVisible: standardControlsVisible,
            reason: "makeCoordinator"
        )
        return controller
    }

    func makeNSView(context: Context) -> AspectRatioView {
        let view = AspectRatioView()
        view.sizingController = context.coordinator
        return view
    }

    func updateNSView(_ nsView: AspectRatioView, context: Context) {
        nsView.sizingController = context.coordinator
        context.coordinator.update(
            displayedPhoneSize: displayedPhoneSize,
            topChromeHeight: topChromeHeight,
            contentSize: contentSize,
            phoneSurfaceAvailableSize: phoneSurfaceAvailableSize,
            videoFrameSize: videoFrameSize,
            rotationDegrees: rotationDegrees,
            minimumTopChromeHeight: minimumTopChromeHeight,
            countsWindowLayoutInsetAsChrome: countsWindowLayoutInsetAsChrome,
            standardControlsVisible: standardControlsVisible,
            reason: "updateNSView"
        )
        context.coordinator.attach(to: nsView.window, reason: "updateNSView")
    }
}

private enum EasyReplayKitPrivacyBlurMetrics {
    static let streamBlurRadius = EasyControlBarMetrics.buttonSide
    static let veilOpacity: Double = 0.14
}

private struct EasyReplayKitPrivacyBlurVeil: View {
    var body: some View {
        Rectangle()
            .fill(Color.black.opacity(EasyReplayKitPrivacyBlurMetrics.veilOpacity))
    }
}

private enum EasyAirPlayScreenOffMetrics {
    static let dimOpacity = EasyReplayKitPrivacyBlurMetrics.veilOpacity
    static let spacing = EasyControlBarMetrics.outerSpacing
    static let iconSide = EasyControlBarMetrics.buttonSide
    static let horizontalPadding = EasyControlBarMetrics.outerHorizontalPadding
    static let verticalPadding = EasyControlBarMetrics.outerVerticalPadding
    static let cornerRadius = EasyControlBarMetrics.toolbarCornerRadius
}

private struct EasyAirPlayScreenOffOverlay: View {
    let lastFrameAgeSeconds: TimeInterval?

    private var ageText: String {
        guard let lastFrameAgeSeconds else { return "Waiting for the iPhone display" }
        return "Last frame \(String(format: "%.0f", lastFrameAgeSeconds))s ago"
    }

    var body: some View {
        ZStack {
            Rectangle()
                .fill(Color.black.opacity(EasyAirPlayScreenOffMetrics.dimOpacity))

            VStack(spacing: EasyAirPlayScreenOffMetrics.spacing) {
                Image(systemName: "lock.fill")
                    .font(.system(size: EasyAirPlayScreenOffMetrics.iconSide, weight: .semibold))
                    .foregroundStyle(.primary)
                    .frame(
                        width: EasyAirPlayScreenOffMetrics.iconSide,
                        height: EasyAirPlayScreenOffMetrics.iconSide
                    )

                Text("iPhone screen is off")
                    .font(.callout.weight(.semibold))
                    .multilineTextAlignment(.center)

                Text(ageText)
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .padding(.horizontal, EasyAirPlayScreenOffMetrics.horizontalPadding)
            .padding(.vertical, EasyAirPlayScreenOffMetrics.verticalPadding)
            .background(.regularMaterial)
            .clipShape(RoundedRectangle(
                cornerRadius: EasyAirPlayScreenOffMetrics.cornerRadius,
                style: .continuous
            ))
            .overlay {
                RoundedRectangle(
                    cornerRadius: EasyAirPlayScreenOffMetrics.cornerRadius,
                    style: .continuous
                )
                .stroke(Color.white.opacity(EasyAirPlayScreenOffMetrics.dimOpacity), lineWidth: EasyControlBarMetrics.dividerWidth)
            }
        }
    }
}

private struct EasyRotationMismatchWarning: Equatable {
    let source: String
    let reason: String
    let title: String
    let message: String
    let detail: String

    var dismissalKey: String {
        [source, reason, detail].joined(separator: "|")
    }

    static func resolve(
        activeVideoSource: SpecchioVideoSourceKind,
        displayRotationDegrees: Int,
        replayKitOrientation: ReplayKitVideoOrientationSnapshot?,
        nativeOrientation: NativeAVCaptureVideoOrientationSnapshot?
    ) -> EasyRotationMismatchWarning? {
        switch activeVideoSource {
        case .replayKit:
            guard let replayKitOrientation else { return nil }
            return replayKitWarning(
                snapshot: replayKitOrientation,
                displayRotationDegrees: displayRotationDegrees
            )
        case .iosScreenCaptureUSB:
            guard let nativeOrientation else { return nil }
            return nativeWarning(
                snapshot: nativeOrientation,
                displayRotationDegrees: displayRotationDegrees
            )
        default:
            return nil
        }
    }

    private static func replayKitWarning(
        snapshot: ReplayKitVideoOrientationSnapshot,
        displayRotationDegrees: Int
    ) -> EasyRotationMismatchWarning? {
        guard let deviceScreenAxis = snapshot.videoOrientationAxis else {
            return nil
        }

        let specchioAxis = displayedAxis(
            frameAxis: snapshot.videoFrameAxis,
            displayRotationDegrees: displayRotationDegrees
        )
        let source = "Mobile App"

        if axesCanBeCompared(deviceScreenAxis, specchioAxis), deviceScreenAxis != specchioAxis {
            return EasyRotationMismatchWarning(
                source: source,
                reason: "device-specchio-axis-mismatch",
                title: "Mouse axis may be affected",
                message: "The iPhone screen is \(deviceScreenAxis), but Specchio is displaying it as \(specchioAxis).",
                detail: "Device: \(deviceScreenAxis) · Specchio: \(specchioAxis) · Mobile App: \(snapshot.videoOrientationName ?? "nil")"
            )
        }

        return nil
    }

    private static func nativeWarning(
        snapshot: NativeAVCaptureVideoOrientationSnapshot,
        displayRotationDegrees: Int
    ) -> EasyRotationMismatchWarning? {
        let specchioAxis = displayedAxis(
            frameAxis: snapshot.frameAxis,
            displayRotationDegrees: displayRotationDegrees
        )
        let source = "Cable"

        if let deviceScreenAxis = snapshot.rotationAngleAxis,
           axesCanBeCompared(deviceScreenAxis, specchioAxis),
           deviceScreenAxis != specchioAxis {
            return EasyRotationMismatchWarning(
                source: source,
                reason: "device-specchio-axis-mismatch",
                title: "Mouse axis may be affected",
                message: "The iPhone screen is \(deviceScreenAxis), but Specchio is displaying it as \(specchioAxis).",
                detail: "Device: \(deviceScreenAxis) · Specchio: \(specchioAxis) · Cable rotation: \(snapshot.videoRotationAngleDegrees.map { FrameDropDiagnostics.format($0, digits: 1) } ?? "nil")"
            )
        }

        if let deviceScreenAxis = snapshot.videoOrientationAxis,
           axesCanBeCompared(deviceScreenAxis, specchioAxis),
           deviceScreenAxis != specchioAxis {
            return EasyRotationMismatchWarning(
                source: source,
                reason: "device-specchio-axis-mismatch",
                title: "Mouse axis may be affected",
                message: "The iPhone screen is \(deviceScreenAxis), but Specchio is displaying it as \(specchioAxis).",
                detail: "Device: \(deviceScreenAxis) · Specchio: \(specchioAxis) · Metadata: \(snapshot.videoOrientationName ?? "nil")"
            )
        }

        return nil
    }

    private static func displayedAxis(frameAxis: String, displayRotationDegrees: Int) -> String {
        guard axesCanBeCompared(frameAxis, "portrait") else {
            return frameAxis
        }

        if EasyWindowVideoSizing.isSidewaysRotation(displayRotationDegrees) {
            return frameAxis == "portrait" ? "landscape" : "portrait"
        }

        return frameAxis
    }

    private static func axesCanBeCompared(_ lhs: String, _ rhs: String) -> Bool {
        (lhs == "portrait" || lhs == "landscape")
            && (rhs == "portrait" || rhs == "landscape")
    }
}

private struct EasyRotationMismatchOverlay: View {
    let warning: EasyRotationMismatchWarning
    let onDismiss: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .frame(width: 18, height: 18)

            VStack(alignment: .leading, spacing: 4) {
                Text(warning.title)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)

                Text(warning.message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)

                Text(warning.detail)
                    .font(.caption2.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Button(action: onDismiss) {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 22, height: 22)
            }
            .buttonStyle(.plain)
            .help("Dismiss rotation warning")
            .accessibilityLabel("Dismiss rotation warning")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Color.orange.opacity(0.45), lineWidth: 1)
        }
        .accessibilityLabel("\(warning.title). \(warning.message)")
    }
}

private struct EasyReplayKitRecoveryOverlay: View {
    let snapshot: EasyReplayKitUISnapshot
    let onRetry: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Circle()
                    .fill(snapshot.dotColor)
                    .frame(width: 10, height: 10)

                ZStack(alignment: .leading) {
                    Text("Mobile App Pause")
                        .font(.caption.weight(.semibold))
                        .hidden()
                    Text(snapshot.statusBadge)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(snapshot.dotColor)
                }

                Text(snapshot.overlayTitle ?? snapshot.statusDetail)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)

                Spacer(minLength: 8)

            }

            Text(snapshot.overlayMessage ?? snapshot.statusDetail)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)

            Text(snapshot.overlayGuidance ?? " ")
                .font(.caption2.monospaced())
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(snapshot.dotColor.opacity(0.35), lineWidth: 1)
        }
    }
}

private struct EasyBluetoothAutoConnectOverlay: View {
    let state: BluetoothAutoConnectOverlayState
    let action: () -> Void

    private var foregroundColor: Color {
        switch state.phase {
        case .connecting:
            return .blue
        case .connected:
            return .green
        case .failed:
            return .orange
        case .setupRequired:
            return .orange
        }
    }

    var body: some View {
        Group {
            if state.opensSetupTutorial {
                Button {
                    SpecchioLogger.easyMode.info("[BluetoothAutoConnectOverlay] setup action selected \(state.diagnosticDescription, privacy: .public)")
                    action()
                } label: {
                    overlayContent
                }
                .buttonStyle(.plain)
                .help("Open setup tutorial")
                .accessibilityLabel("Complete setup tutorial")
            } else {
                overlayContent
            }
        }
        .onAppear {
            SpecchioLogger.easyMode.info("[BluetoothAutoConnectOverlay] appeared \(state.diagnosticDescription, privacy: .public)")
        }
        .onDisappear {
            SpecchioLogger.easyMode.info("[BluetoothAutoConnectOverlay] disappeared \(state.diagnosticDescription, privacy: .public)")
        }
        .onChange(of: state) { _, newValue in
            SpecchioLogger.easyMode.info("[BluetoothAutoConnectOverlay] changed \(newValue.diagnosticDescription, privacy: .public)")
        }
    }

    private var overlayContent: some View {
        HStack(spacing: 8) {
            indicator

            VStack(alignment: .leading, spacing: 2) {
                Text(state.message)
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)
                Text(state.detail)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(foregroundColor.opacity(0.35), lineWidth: 1)
        }
    }

    @ViewBuilder
    private var indicator: some View {
        switch state.phase {
        case .connecting:
            ProgressView()
                .controlSize(.small)
        case .connected:
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(foregroundColor)
        case .failed:
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(foregroundColor)
        case .setupRequired:
            Image(systemName: "play.rectangle.fill")
                .foregroundStyle(foregroundColor)
        }
    }
}

private struct EasyVideoStatusBar: View {
    @ObservedObject var replayKitStream: ReplayKitScreenStreamManager
    @ObservedObject var airPlayStream: AirPlayScreenStreamManager
    @ObservedObject var iosScreenCapture: IOSScreenCaptureManager
    let activeVideoSource: SpecchioVideoSourceKind
    @ObservedObject var bluetoothHIDPanel: BluetoothHIDPanelController
    @AppStorage(AppSettings.Keys.easyShowFPSCounter) private var showFPSCounter = false
    private let minimumNumericFPS: Double = 2.0

    private var snapshot: EasyReplayKitUISnapshot {
        EasyReplayKitUISnapshot.make(from: replayKitStream)
    }

    private var dotColor: Color {
        switch activeVideoSource {
        case .iosScreenCaptureUSB:
            switch iosScreenCapture.streamHealth {
            case .live:
                return .cyan
            case .starting, .discovering:
                return .blue
            case .stale, .interrupted:
                return .orange
            case .disconnected, .failed:
                return .red
            case .idle:
                return .secondary
            }
        case .replayKit:
            return snapshot.dotColor
        case .airPlay:
            switch airPlayStream.streamHealth {
            case .receivingVideo:
                return .indigo
            case .screenOff:
                return .orange
            case .advertising, .waitingForPhone, .pairing, .settingUp:
                return .blue
            case .stale:
                return .orange
            case .failed:
                return .red
            case .idle, .disconnected:
                return .secondary
            }
        default:
            return activeVideoSource.statusColor
        }
    }

    private var fpsText: String {
        if activeVideoSource == .iosScreenCaptureUSB {
            guard case .live = iosScreenCapture.streamHealth else {
                return "Waiting"
            }
            guard iosScreenCapture.currentFPS >= minimumNumericFPS else {
                return "Live"
            }
            return "\(Int(iosScreenCapture.currentFPS.rounded())) FPS"
        }

        if activeVideoSource == .airPlay {
            guard case .receivingVideo = airPlayStream.streamHealth else {
                switch airPlayStream.streamHealth {
                case .failed:
                    return "Failed"
                case .screenOff:
                    return "Screen Off"
                case .stale:
                    return "Stale"
                default:
                    return "Waiting"
                }
            }
            guard airPlayStream.currentFPS >= minimumNumericFPS else {
                return "Live"
            }
            return "\(Int(airPlayStream.currentFPS.rounded())) FPS"
        }

        switch snapshot.kind {
        case .live:
            guard replayKitStream.currentFPS >= minimumNumericFPS else {
                return "Live"
            }
            return "\(Int(replayKitStream.currentFPS.rounded())) FPS"
        case .connecting, .listening, .idle:
            return "Waiting"
        case .stale:
            return "Stale"
        case .paused:
            return "Paused"
        case .ended:
            return "Ended"
        case .disconnected:
            return "Waiting"
        case .failed:
            return "Failed"
        }
    }

    private var sourceText: String {
        if airPlayStream.currentPairingPIN != nil {
            return "AirPlay · PIN Required"
        }

        switch activeVideoSource {
        case .iosScreenCaptureUSB:
            return "Cable"
        case .replayKit:
            return "Mobile App \(replayKitTransportLabel) · \(replayKitStream.activeVideoCodec.diagnosticLabel)"
        case .airPlay:
            return "AirPlay · \(airPlayStream.streamHealth.statusText.replacingOccurrences(of: "AirPlay: ", with: ""))"
        default:
            return activeVideoSource.displayName
        }
    }

    private var replayKitTransportLabel: String {
        switch replayKitStream.resolvedTransport {
        case .usb:
            return "Cable"
        case .wifi:
            return "Wi-Fi"
        case .cellular:
            return "Cellular"
        case .other:
            return "Other"
        case .unknown:
            return "Unknown"
        }
    }

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(dotColor)
                .frame(width: 8, height: 8)
            Text(sourceText)
                .font(.caption2)
            if activeVideoSource == .iosScreenCaptureUSB {
                EasyNativeUSBAudioIndicator(iosScreenCapture: iosScreenCapture)
            }
            if activeVideoSource == .replayKit {
                EasyReplayKitAudioIndicator(audioStream: replayKitStream.audioStream)
            }
            if showFPSCounter {
                Text(fpsText)
                    .font(.caption2.monospacedDigit())
            }
            if !bluetoothHIDPanel.isBluetoothHIDConnected {
                BluetoothDisconnectedIcon()
                    .help("Bluetooth input disconnected")
                    .accessibilityLabel("Bluetooth input disconnected")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
        .background(.ultraThinMaterial)
        .cornerRadius(8)
        .padding(.bottom, 8)
        .onAppear {
            SpecchioLogger.easyMode.info("[EasyVideoStatusBar] appeared showFPSCounter=\(showFPSCounter) fpsText=\(fpsText, privacy: .public) sourceText=\(sourceText, privacy: .public) activeSource=\(activeVideoSource.diagnosticName, privacy: .public) replayKitFPS=\(replayKitStream.currentFPS) usbNativeFPS=\(iosScreenCapture.currentFPS) airPlayFPS=\(airPlayStream.currentFPS) replayKitHealth=\(replayKitStream.streamHealth.diagnosticDescription, privacy: .public) usbNativeHealth=\(iosScreenCapture.streamHealth.diagnosticDescription, privacy: .public) airPlayHealth=\(airPlayStream.streamHealth.diagnosticDescription, privacy: .public) bluetoothConnected=\(bluetoothHIDPanel.isBluetoothHIDConnected) bluetoothDisconnectedIconVisible=\(!bluetoothHIDPanel.isBluetoothHIDConnected) minimumNumericFPS=\(minimumNumericFPS)")
        }
        .onChange(of: fpsText) { _, newValue in
            SpecchioLogger.easyMode.info("[EasyVideoStatusBar] display changed fpsText=\(newValue, privacy: .public) sourceText=\(sourceText, privacy: .public) activeSource=\(activeVideoSource.diagnosticName, privacy: .public) showFPSCounter=\(showFPSCounter) replayKitFPS=\(replayKitStream.currentFPS) usbNativeFPS=\(iosScreenCapture.currentFPS) airPlayFPS=\(airPlayStream.currentFPS) replayKitHealth=\(replayKitStream.streamHealth.diagnosticDescription, privacy: .public) usbNativeHealth=\(iosScreenCapture.streamHealth.diagnosticDescription, privacy: .public) airPlayHealth=\(airPlayStream.streamHealth.diagnosticDescription, privacy: .public) bluetoothConnected=\(bluetoothHIDPanel.isBluetoothHIDConnected)")
        }
        .onChange(of: sourceText) { _, newValue in
            SpecchioLogger.easyMode.info("[EasyVideoStatusBar] source display changed sourceText=\(newValue, privacy: .public) activeSource=\(activeVideoSource.diagnosticName, privacy: .public) replayKitCodec=\(replayKitStream.activeVideoCodec.rawValue, privacy: .public) replayKitTransport=\(replayKitStream.resolvedTransport.rawValue, privacy: .public) airPlayHealth=\(airPlayStream.streamHealth.diagnosticDescription, privacy: .public)")
        }
        .onChange(of: showFPSCounter) { _, newValue in
            SpecchioLogger.easyMode.info("[EasyVideoStatusBar] FPS counter preference changed visible=\(newValue) fpsText=\(fpsText, privacy: .public) activeSource=\(activeVideoSource.diagnosticName, privacy: .public)")
        }
        .onChange(of: bluetoothHIDPanel.isBluetoothHIDConnected) { _, newValue in
            SpecchioLogger.easyMode.info("[EasyVideoStatusBar] Bluetooth icon state changed connected=\(newValue) disconnectedIconVisible=\(!newValue)")
        }
    }
}

private struct EasyNativeUSBAudioIndicator: View {
    @ObservedObject var iosScreenCapture: IOSScreenCaptureManager

    private var label: String {
        switch iosScreenCapture.audioState {
        case .live:
            return "Audio Live"
        case .waiting:
            return "Audio Waiting"
        case .off:
            return "Audio Off"
        case .error:
            return "Audio Error"
        }
    }

    private var color: Color {
        switch iosScreenCapture.audioState {
        case .live:
            return .green
        case .waiting:
            return .orange
        case .off:
            return .secondary
        case .error:
            return .red
        }
    }

    var body: some View {
        HStack(spacing: 4) {
            Circle()
                .fill(color)
                .frame(width: 8, height: 8)
            Text(label)
                .font(.caption2)
        }
        .help(iosScreenCapture.audioStatusMessage)
        .accessibilityLabel(label)
        .onAppear {
            SpecchioLogger.easyMode.info("[EasyNativeUSBAudioIndicator] appeared label=\(label, privacy: .public) message=\(iosScreenCapture.audioStatusMessage, privacy: .public) playing=\(iosScreenCapture.isAudioPlaying) sampleRate=\(iosScreenCapture.audioSampleRate) channels=\(iosScreenCapture.audioChannelCount) received=\(iosScreenCapture.receivedAudioSampleBufferCount) dropped=\(iosScreenCapture.droppedAudioSampleBufferCount)")
        }
        .onChange(of: iosScreenCapture.audioState) { _, newValue in
            SpecchioLogger.easyMode.info("[EasyNativeUSBAudioIndicator] state changed state=\(newValue.rawValue, privacy: .public) label=\(label, privacy: .public) message=\(iosScreenCapture.audioStatusMessage, privacy: .public) playing=\(iosScreenCapture.isAudioPlaying) bufferedMs=\(iosScreenCapture.audioBufferedMilliseconds) received=\(iosScreenCapture.receivedAudioSampleBufferCount) dropped=\(iosScreenCapture.droppedAudioSampleBufferCount)")
        }
        .onChange(of: iosScreenCapture.audioStatusMessage) { _, newValue in
            SpecchioLogger.easyMode.info("[EasyNativeUSBAudioIndicator] message changed message=\(newValue, privacy: .public) label=\(label, privacy: .public)")
        }
    }
}

private struct EasyReplayKitAudioIndicator: View {
    @ObservedObject var audioStream: ReplayKitAudioStreamManager

    private var label: String {
        switch audioStream.audioState {
        case .live:
            return "Audio Live"
        case .waiting:
            return "Audio Waiting"
        case .off:
            return "Audio Off"
        case .error:
            return "Audio Error"
        }
    }

    private var color: Color {
        switch audioStream.audioState {
        case .live:
            return .green
        case .waiting:
            return .orange
        case .off:
            return .secondary
        case .error:
            return .red
        }
    }

    var body: some View {
        HStack(spacing: 4) {
            Circle()
                .fill(color)
                .frame(width: 8, height: 8)
            Text(label)
                .font(.caption2)
        }
        .help(audioStream.audioStatusMessage)
        .accessibilityLabel(label)
        .onAppear {
            SpecchioLogger.easyMode.info("[EasyReplayKitAudioIndicator] appeared label=\(label, privacy: .public) message=\(audioStream.audioStatusMessage, privacy: .public) listening=\(audioStream.isListening) connected=\(audioStream.isClientConnected) playing=\(audioStream.isAudioPlaying)")
        }
        .onChange(of: audioStream.audioState) { _, newValue in
            SpecchioLogger.easyMode.info("[EasyReplayKitAudioIndicator] state changed state=\(newValue.rawValue, privacy: .public) label=\(label, privacy: .public) message=\(audioStream.audioStatusMessage, privacy: .public) packets=\(audioStream.receivedAudioPacketCount) dropped=\(audioStream.droppedAudioPacketCount) latencyMs=\(audioStream.audioLatencyMilliseconds)")
        }
        .onChange(of: audioStream.audioStatusMessage) { _, newValue in
            SpecchioLogger.easyMode.info("[EasyReplayKitAudioIndicator] message changed message=\(newValue, privacy: .public) label=\(label, privacy: .public)")
        }
    }
}

private struct BluetoothDisconnectedIcon: View {
    private static let bluetoothTemplate = NSImage(named: NSImage.Name("NSBluetoothTemplate"))

    private var iconSize: CGSize {
        guard let template = Self.bluetoothTemplate, template.size.height > 0 else {
            let fallbackHeight = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize).capHeight
            return CGSize(width: fallbackHeight, height: fallbackHeight)
        }

        let height = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize).capHeight
        return CGSize(width: height * (template.size.width / template.size.height), height: height)
    }

    var body: some View {
        Group {
            if let template = Self.bluetoothTemplate {
                Image(nsImage: template)
                    .renderingMode(.template)
                    .resizable()
                    .scaledToFit()
            } else {
                Image(systemName: "keyboard")
                    .resizable()
                    .scaledToFit()
            }
        }
        .foregroundStyle(.red)
        .frame(width: iconSize.width, height: iconSize.height)
        .overlay {
            GeometryReader { proxy in
                Path { path in
                    path.move(to: CGPoint(x: 0, y: proxy.size.height))
                    path.addLine(to: CGPoint(x: proxy.size.width, y: 0))
                }
                .stroke(.red, style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
            }
        }
        .onAppear {
            SpecchioLogger.easyMode.info("[EasyReplayKitStatusBar] Bluetooth disconnected icon appeared assetAvailable=\(Self.bluetoothTemplate != nil) width=\(iconSize.width) height=\(iconSize.height)")
        }
    }
}

private struct ModeMirrorLogoForEasy: View {
    let mouseLocation: CGPoint
    var parentSize: CGSize

    private var rotation: (x: Double, y: Double) {
        guard mouseLocation != .zero, parentSize.width > 0 else {
            return (0, 0)
        }

        let nx = (mouseLocation.x / parentSize.width - 0.5) * 2
        let ny = (mouseLocation.y / parentSize.height - 0.5) * 2
        let maxTilt: Double = 30
        return (x: -ny * maxTilt, y: nx * maxTilt)
    }

    var body: some View {
        Text("🪞")
            .font(.system(size: 128))
            .rotation3DEffect(
                .degrees(rotation.x),
                axis: (x: 1, y: 0, z: 0),
                perspective: 0.5
            )
            .rotation3DEffect(
                .degrees(rotation.y),
                axis: (x: 0, y: 1, z: 0),
                perspective: 0.5
            )
            .animation(.easeOut(duration: 0.15), value: mouseLocation.x)
            .animation(.easeOut(duration: 0.15), value: mouseLocation.y)
            .onAppear {
                SpecchioLogger.easyMode.info("[ModeMirrorLogoForEasy] appeared emoji=mirror fontSize=128 parentWidth=\(parentSize.width) parentHeight=\(parentSize.height)")
            }
    }
}
