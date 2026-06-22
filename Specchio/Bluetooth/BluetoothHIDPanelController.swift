import Cocoa
import IOBluetooth
import IOBluetoothUI
import CoreBluetooth
import Combine
import Network
import QuartzCore

extension Notification.Name {
    static let easyBluetoothPointerFeedback = Notification.Name("SpecchioEasyBluetoothPointerFeedback")
    static let easyBluetoothPairingCompleted = Notification.Name("SpecchioEasyBluetoothPairingCompleted")
    static let easyBluetoothPairingFailed = Notification.Name("SpecchioEasyBluetoothPairingFailed")
    static let easyBluetoothPeerUnpaired = Notification.Name("SpecchioEasyBluetoothPeerUnpaired")
    static let easyPointerSpikeVisualization = Notification.Name("SpecchioEasyPointerSpikeVisualization")
    static let easyPointerSpikeMetrics = Notification.Name("SpecchioEasyPointerSpikeMetrics")
}

enum BluetoothAutoConnectOverlayPhase: String, Equatable {
    case connecting
    case connected
    case failed
    case setupRequired
}

struct BluetoothAutoConnectOverlayState: Equatable {
    let phase: BluetoothAutoConnectOverlayPhase
    let message: String
    let detail: String
    let attemptID: Int
    let cycle: Int

    var opensSetupTutorial: Bool {
        phase == .setupRequired
    }

    var diagnosticDescription: String {
        "phase=\(phase.rawValue) message=\(message) detail=\(detail) attempt=\(attemptID) cycle=\(cycle)"
    }
}

enum InputSurfaceDiagnostics {
    static func intString(_ value: CGFloat) -> String {
        guard value.isFinite else {
            if value.isNaN { return "nan" }
            return value.sign == .minus ? "-inf" : "+inf"
        }
        if value >= CGFloat(Int.max) { return "intMax+" }
        if value <= CGFloat(Int.min) { return "intMin-" }

        return "\(Int(value.rounded(.towardZero)))"
    }

    static func pointString(_ point: CGPoint) -> String {
        "(\(intString(point.x)),\(intString(point.y)))"
    }

    static func sizeString(_ size: CGSize) -> String {
        "(\(intString(size.width)),\(intString(size.height)))"
    }

    static func orientationString(_ size: CGSize) -> String {
        guard isFinite(size), size.width > 0, size.height > 0 else { return "invalid" }
        if abs(size.width - size.height) <= 0.5 { return "square" }
        return size.width > size.height ? "landscape" : "portrait"
    }

    static func rectString(_ rect: CGRect) -> String {
        "(\(intString(rect.minX)),\(intString(rect.minY)),\(intString(rect.width)),\(intString(rect.height)))"
    }

    static func isFinite(_ point: CGPoint) -> Bool {
        point.x.isFinite && point.y.isFinite
    }

    static func isFinite(_ size: CGSize) -> Bool {
        size.width.isFinite && size.height.isFinite
    }

    static func isFinite(_ rect: CGRect) -> Bool {
        rect.minX.isFinite && rect.minY.isFinite && rect.width.isFinite && rect.height.isFinite
    }
}

enum InputSurfaceRotationMapping {
    static func normalizedRotation(_ degrees: Int) -> Int {
        ((degrees % 360) + 360) % 360
    }

    static func phoneNormalizedPoint(displayX: CGFloat, displayY: CGFloat, rotationDegrees: Int) -> CGPoint {
        switch normalizedRotation(rotationDegrees) {
        case 90:
            return CGPoint(x: displayY, y: 1 - displayX)
        case 180:
            return CGPoint(x: 1 - displayX, y: 1 - displayY)
        case 270:
            return CGPoint(x: 1 - displayY, y: displayX)
        default:
            return CGPoint(x: displayX, y: displayY)
        }
    }

    static func relativePointerDelta(_ delta: CGPoint, rotationDegrees: Int) -> CGPoint {
        switch normalizedRotation(rotationDegrees) {
        case 90:
            return CGPoint(x: delta.y, y: -delta.x)
        case 180:
            return CGPoint(x: -delta.x, y: -delta.y)
        case 270:
            return CGPoint(x: -delta.y, y: delta.x)
        default:
            return delta
        }
    }
}

/// KeyPad flow from video:
/// 1. User clicks "Connect device over Bluetooth..." button (prepares BT)
/// 2. This initializes CBClassicManager which takes time to power on
/// 3. THEN the device selector opens (CBClassicManager is already powered on)
///
/// Our fix: add a "Prepare Bluetooth" step with a button,
/// initialize CBClassicManager, wait for poweredOn, THEN show selector.
enum EasyAutoUnlockHIDResult: Equatable {
    case started
    case bluetoothDisconnected
    case unsupportedCharacters(Int)

    var logName: String {
        switch self {
        case .started:
            return "started"
        case .bluetoothDisconnected:
            return "bluetooth-disconnected"
        case .unsupportedCharacters(let count):
            return "unsupported-characters-count-\(count)"
        }
    }
}

private enum EasyAutoUnlockSequenceTiming {
    static let homeToFirstReturn: TimeInterval = 1.75
    static let firstReturnToPIN: TimeInterval = 2.0
    static let keyHoldDuration: TimeInterval = 0.03
    static let keySpacing: TimeInterval = 0.25
}

private enum TrackpadSwipeDragMetrics {
    static let minimumHorizontalCommitDelta: CGFloat = 24
    static let horizontalDominanceRatio: CGFloat = 1.4
    static let maximumSyntheticDragFractionOfSurface: CGFloat = 0.72
    static let dragScale: CGFloat = 1.0
    static let directionMultiplier: CGFloat = 1.0
}

private enum TrackpadSwipeDragPhase: String {
    case idle
    case evaluating
    case delayedReady
    case dragging
}

private enum TrackpadSwipeDragDirection: String {
    case left
    case right
}

final class BluetoothHIDPanelController: NSObject, ObservableObject, NSApplicationDelegate, NSWindowDelegate, CBCentralManagerDelegate, IOBluetoothL2CAPChannelDelegate {
    @Published private(set) var isBluetoothHIDConnected = false
    @Published private(set) var bluetoothAutoConnectOverlay: BluetoothAutoConnectOverlayState?

    var controller: KeyPadController!
    var logWindow: NSWindow!
    var logView: NSTextView!
    var prepareButton: NSButton!
    var resetPrepareButton: NSButton!
    var connectButton: NSButton!
    var reconnectButton: NSButton!
    var forgetButton: NSButton!
    var progressIndicator: NSProgressIndicator!
    var statusLabel: NSTextField!
    var instructionLabel: NSTextField!
    var advancedLogButton: NSButton!
    var logScrollView: NSScrollView!
    var logActionsStack: NSStackView!
    var sendField: NSTextField!
    var sendButton: NSButton!
    var deviceInfoLabel: NSTextField!
    var centralManager: CBCentralManager!
    var classicManagerReady = false
    private var preparedBluetoothSDPPublished = false
    var activeDevice: IOBluetoothDevice?
    var activeDeviceName: String?
    var controlChannel: IOBluetoothL2CAPChannel?
    var interruptChannel: IOBluetoothL2CAPChannel?
    var pendingControlChannel: IOBluetoothL2CAPChannel?
    var pendingInterruptChannel: IOBluetoothL2CAPChannel?
    var incomingControlNotification: IOBluetoothUserNotification?
    var incomingInterruptNotification: IOBluetoothUserNotification?
    var pendingControlChannelOpen = false
    var pendingInterruptChannelOpen = false
    private var connectionAttemptID = 0
    private var controlOpenAttemptID = 0
    private var interruptOpenAttemptID = 0
    private let l2capOpenTimeout: TimeInterval = 8.0
    private var pairingStabilizationAttemptID = 0
    private var pairingStabilizationAddress: String?
    private var pairingStabilizationDeadline: CFTimeInterval = 0
    private let pairingStabilizationPollInterval: TimeInterval = 1.0
    private let pairingStabilizationTimeout: TimeInterval = 20.0
    private var replayKitInputForwardingEnabled = false
    private var replayKitInputForwardingReason = "ReplayKit input gate has not been initialized"
    private var replayKitInputGateDropCount = 0
    private let connectionFallbackQueue = DispatchQueue(label: "com.alexintosh.Specchio.bluetooth-connect-fallback", qos: .userInitiated)
    private let l2capOpenQueue = DispatchQueue(label: "com.alexintosh.Specchio.bluetooth-l2cap-open", qos: .userInitiated)
    private let interactiveTutorialOverlay = InteractiveTutorialBluetoothPanelOverlayController()
    private var pairingNotificationObservers: [NSObjectProtocol] = []
    private var retainedPairingPeersByAddress: [String: NSObject] = [:]
    private var postPairingPrepareResetKeys: Set<String> = []
    private var postPairingPrepareResetAttemptID = 0
    private var pendingConnectAfterPrepareReset: (address: String, name: String, source: String, attemptID: Int)?
    private var bluetoothAutoConnectAttemptID = 0
    private var bluetoothAutoConnectOverlayDismissalID = 0
    private var bluetoothAutoConnectCycle = 0
    private var isBluetoothAutoConnectAttemptActive = false
    private var pendingBluetoothAutoConnectAfterPrepare: (source: String, attemptID: Int)?
    private let bluetoothAutoConnectOverlayCycleInterval: TimeInterval = 1.0
    private let bluetoothAutoConnectOverlayDismissCycles = 2
    var didSendInitialReport = false
    let hidIOQueue = DispatchQueue(label: "com.specchio.bthidapp.hid-io", qos: .userInitiated)

    // Live keystroke monitoring
    var keyEventMonitor: Any?
    var flagsEventMonitor: Any?
    var pressedHIDKeys: Set<UInt8> = []
    var keystrokeStatusLabel: NSTextField!
    var specialKeyButtons: [NSButton] = []

    // Mouse passthrough
    var mouseLocalMonitor: Any?
    var mousePassthroughEnabled = false
    var mouseToggleBtn: NSButton!
    var mouseStatusLabel: NSTextField!
    var mouseButtonState: UInt8 = 0  // bit 0 = left, bit 1 = right
    var mouseEventCount: Int = 0
    var mouseReportCount: Int = 0
    private var isMouseMovementClutched = false
    private var isRightMousePressed = false
    private var isLeftMousePressedForSwipe = false
    private var didCurrentLeftPressBecomeDrag = false
    private var isDragGestureInProgress = false
    private var isSwipeButtonDownOnPhone = false
    private var mouseDeltaRemainderX: CGFloat = 0
    private var mouseDeltaRemainderY: CGFloat = 0
    private var easyMouseClutchModeEnabled = true
    private var trackpadSwipeToDragEnabled = AppSettings.Defaults.easyTrackpadSwipeToDragEnabled
    private var trackpadSwipeToDragMode = AppSettings.Defaults.easyTrackpadSwipeToDragMode
    private var trackpadSwipeDragPhase: TrackpadSwipeDragPhase = .idle
    private var trackpadSwipeDragStartPhonePoint: CGPoint?
    private var trackpadSwipeDragLatestPhonePoint: CGPoint?
    private var trackpadSwipeDragAccumulatedHorizontalDelta: CGFloat = 0
    private var trackpadSwipeDragAccumulatedVerticalDelta: CGFloat = 0
    private var trackpadSwipeDragEventCount = 0
    private var trackpadSwipeDragMoveCount = 0
    private var trackpadSwipeDragGestureID = 0
    private var trackpadSwipeDragStartUptime: TimeInterval = 0
    private var trackpadSwipeDragLastEventUptime: TimeInterval = 0
    private var trackpadSwipeDragSyntheticButtonDown = false
    weak var inputWindow: NSWindow?
    private var inputSurfaceFrameInWindow: CGRect?
    private var inputSurfaceRotationDegrees = 0
    private var pointerSurfaceSize = CGSize(width: 390, height: 844)
    private var virtualPointerPoint = CGPoint.zero
    private var isPointerButtonDown = false
    private var pointerTransportScaleX: CGFloat = 1
    private var pointerTransportScaleY: CGFloat = 1
    private var lastPointerReportDelta = CGPoint.zero
    private var calibrationReportDeltaSinceLastSample = CGPoint.zero
    private var lastCalibrationActualPoint: CGPoint?
    private var calibrationScaleSamplesX: [CGFloat] = []
    private var calibrationScaleSamplesY: [CGFloat] = []
    private let calibrationPort: UInt16 = 9600
    private let calibrationQueue = DispatchQueue(label: "com.alexintosh.Specchio.pointer-calibration", qos: .userInitiated)
    private var calibrationListener: NWListener?
    private var calibrationConnection: NWConnection?
    private var calibrationReceiveBuffer = Data()
    private var easyPointerSpikeEnabled = false
    private var easyPointerSpikeVariant = "REL"
    private var pointerSpikeNextSequence = 1
    private var pendingPointerSpikeAttempts: [PointerSpikeAttempt] = []
    private var pointerSpikeSamples: [PointerSpikeSample] = []
    private var logBuffer: [String] = []
    private var isAdvancedLogVisible = false
    private var inputEventDropCount = 0
    private var interruptWritesInFlight = 0
    private var mouseStatsWindowStartedAt = CACurrentMediaTime()
    private var mouseEventsAtWindowStart = 0
    private var mouseReportsAtWindowStart = 0
    private var mouseWriteCompletionsAtWindowStart = 0
    private var mouseWriteCompletionCount = 0
    private var queueSpaceAvailableCount = 0

    private var targetInputWindow: NSWindow? {
        inputWindow
    }

    func suspendForModeSwitch(reason: String) {
        guard Thread.isMainThread else {
            runOnMain("suspendForModeSwitch") { [weak self] in
                self?.suspendForModeSwitch(reason: reason)
            }
            return
        }

        appendLog("[Lifecycle] suspend requested reason=\(reason) panelVisible=\(logWindow?.isVisible ?? false)")
        stopCalibrationReceiver()
        inputWindow = nil
        inputSurfaceFrameInWindow = nil
        logWindow?.orderOut(nil)
    }

    private struct PointerInputMapping {
        let eventLocationInWindow: CGPoint
        let localPoint: CGPoint
        let normalizedPoint: CGPoint
        let phonePoint: CGPoint
        let surfaceFrameInWindow: CGRect
        let wasClampedToSurface: Bool
    }

    private struct PointerSpikeAttempt {
        let sequence: Int
        let createdAt: TimeInterval
        let eventType: NSEvent.EventType
        let mappingAtDown: PointerInputMapping
        var mappingAtUp: PointerInputMapping?
        let virtualPointAtDown: CGPoint
        var virtualPointAtUp: CGPoint?
    }

    private struct PointerSpikeSample {
        let sequence: Int
        let variant: String
        let targetID: String?
        let index: Int
        let targetPoint: CGPoint
        let mappedClickPoint: CGPoint?
        let virtualPointerPoint: CGPoint?
        let actualPoint: CGPoint
        let targetErrorPoint: CGPoint
        let targetErrorDistance: CGFloat
        let mappedErrorPoint: CGPoint?
        let mappedErrorDistance: CGFloat?
        let virtualErrorPoint: CGPoint?
        let virtualErrorDistance: CGFloat?
        let timestamp: TimeInterval
    }

    private enum PointerMoveOrigin: String {
        case predicted = "predicted"
        case authoritativeActual = "authoritativeActual"
    }

    private enum PointerSpikeTransportVariant {
        case absoluteMouse
        case relativeClosedLoop

        init(label: String) {
            switch label.trimmingCharacters(in: .whitespacesAndNewlines).uppercased() {
            case AppSettings.EasyPointerSpikeTransport.absoluteMouse, "ABS", "ABSOLUTE":
                self = .absoluteMouse
            default:
                self = .relativeClosedLoop
            }
        }

        var label: String {
            switch self {
            case .absoluteMouse:
                return AppSettings.EasyPointerSpikeTransport.absoluteMouse
            case .relativeClosedLoop:
                return AppSettings.EasyPointerSpikeTransport.relativeClosedLoop
            }
        }

        var usesAbsoluteMouseReport: Bool {
            switch self {
            case .absoluteMouse:
                return true
            case .relativeClosedLoop:
                return false
            }
        }
    }

    private static let absolutePointerReportID: UInt8 = 0x0B
    private static let absolutePointerLogicalMax: CGFloat = 32767

    private var pointerSpikeTransportVariant: PointerSpikeTransportVariant {
        PointerSpikeTransportVariant(label: easyPointerSpikeVariant)
    }

    private var absolutePointerTransportEnabled: Bool {
        easyPointerSpikeEnabled && pointerSpikeTransportVariant.usesAbsoluteMouseReport
    }

    private func publishBluetoothConnectionStatus(reason: String) {
        let connected = controlChannel != nil && interruptChannel != nil
        let controlReady = controlChannel != nil
        let interruptReady = interruptChannel != nil
        appendLog("[Status] Bluetooth HID connection evaluated reason=\(reason) connected=\(connected) controlReady=\(controlReady) interruptReady=\(interruptReady)")

        runOnMain("publishBluetoothConnectionStatus") { [weak self] in
            guard let self else { return }
            guard self.isBluetoothHIDConnected != connected else {
                self.appendLog("[Status] Bluetooth HID published state unchanged connected=\(connected) reason=\(reason)")
                return
            }
            self.isBluetoothHIDConnected = connected
            self.appendLog("[Status] Bluetooth HID published state changed connected=\(connected) reason=\(reason)")
        }
    }

    private func runOnMain(_ reason: String, _ work: @escaping () -> Void) {
        if Thread.isMainThread {
            work()
        } else {
            NSLog("[BTUI] Dispatching UI update to main: %@", reason)
            DispatchQueue.main.async(execute: work)
        }
    }

    @discardableResult
    func requestBluetoothAutoConnectIfEnabled(source: String) -> Bool {
        let enabled = AppSettings.bluetoothAutoConnectEnabled()
        appendLog("[AutoConnect] request evaluated source=\(source) enabled=\(enabled) mainThread=\(Thread.isMainThread) connected=\(isBluetoothHIDConnected) active=\(isBluetoothAutoConnectAttemptActive)")

        guard enabled else {
            appendLog("[AutoConnect] request skipped source=\(source) branch=setting-disabled")
            return false
        }

        guard Thread.isMainThread else {
            runOnMain("requestBluetoothAutoConnectIfEnabled") { [weak self] in
                self?.startBluetoothAutoConnect(source: source)
            }
            return true
        }

        startBluetoothAutoConnect(source: source)
        return true
    }

    private func startBluetoothAutoConnect(source: String) {
        guard Thread.isMainThread else {
            runOnMain("startBluetoothAutoConnect") { [weak self] in
                self?.startBluetoothAutoConnect(source: source)
            }
            return
        }

        installBluetoothHIDRuntimeSwizzles()
        installPairingNotificationObservers()

        if isBluetoothAutoConnectAttemptActive {
            appendLog("[AutoConnect] start skipped source=\(source) branch=attempt-already-active attempt=\(bluetoothAutoConnectAttemptID)")
            publishBluetoothAutoConnectOverlay(
                phase: .connecting,
                message: "Bluetooth connecting",
                detail: "Auto-connect is already in progress",
                attemptID: bluetoothAutoConnectAttemptID
            )
            return
        }

        bluetoothAutoConnectAttemptID += 1
        let attemptID = bluetoothAutoConnectAttemptID
        isBluetoothAutoConnectAttemptActive = true
        pendingBluetoothAutoConnectAfterPrepare = nil
        appendLog("[AutoConnect] start source=\(source) attempt=\(attemptID) classicReady=\(classicManagerReady) sdpPublished=\(preparedBluetoothSDPPublished) centralPresent=\(centralManager != nil) connected=\(isBluetoothHIDConnected)")
        publishBluetoothAutoConnectOverlay(
            phase: .connecting,
            message: "Bluetooth connecting",
            detail: "Looking for paired app device",
            attemptID: attemptID
        )

        if isBluetoothHIDConnected {
            appendLog("[AutoConnect] attempt=\(attemptID) branch=already-connected")
            completeBluetoothAutoConnectSuccess(attemptID: attemptID, detail: "Bluetooth input is already connected")
            return
        }

        guard classicManagerReady && preparedBluetoothSDPPublished else {
            pendingBluetoothAutoConnectAfterPrepare = (source: source, attemptID: attemptID)
            appendLog("[AutoConnect] attempt=\(attemptID) branch=prepare-required classicReady=\(classicManagerReady) sdpPublished=\(preparedBluetoothSDPPublished) centralPresent=\(centralManager != nil)")
            if centralManager == nil {
                startBluetoothPreparationRuntime(reason: "auto-connect source=\(source) attempt=\(attemptID)")
            } else {
                appendLog("[AutoConnect] attempt=\(attemptID) waiting for existing Bluetooth preparation state=\(centralManager.state.rawValue)")
                if centralManager.state == .poweredOn && preparedBluetoothSDPPublished {
                    continuePendingBluetoothAutoConnectAfterPrepareIfNeeded(reason: "existing powered-on preparation")
                }
            }
            return
        }

        appendLog("[AutoConnect] attempt=\(attemptID) branch=bluetooth-ready")
        connectBluetoothAutoConnectSavedAppDevice(source: source, attemptID: attemptID)
    }

    private func continuePendingBluetoothAutoConnectAfterPrepareIfNeeded(reason: String) {
        guard Thread.isMainThread else {
            runOnMain("continuePendingBluetoothAutoConnectAfterPrepareIfNeeded") { [weak self] in
                self?.continuePendingBluetoothAutoConnectAfterPrepareIfNeeded(reason: reason)
            }
            return
        }

        guard let pending = pendingBluetoothAutoConnectAfterPrepare else {
            appendLog("[AutoConnect] prepare continuation skipped reason=\(reason) branch=no-pending")
            return
        }

        guard pending.attemptID == bluetoothAutoConnectAttemptID else {
            appendLog("[AutoConnect] prepare continuation ignored reason=\(reason) branch=stale-attempt pending=\(pending.attemptID) current=\(bluetoothAutoConnectAttemptID)")
            pendingBluetoothAutoConnectAfterPrepare = nil
            return
        }

        guard preparedBluetoothSDPPublished && classicManagerReady else {
            appendLog("[AutoConnect] prepare continuation waiting reason=\(reason) attempt=\(pending.attemptID) classicReady=\(classicManagerReady) sdpPublished=\(preparedBluetoothSDPPublished)")
            return
        }

        pendingBluetoothAutoConnectAfterPrepare = nil
        appendLog("[AutoConnect] prepare continuation starting saved app device connect reason=\(reason) attempt=\(pending.attemptID) source=\(pending.source)")
        connectBluetoothAutoConnectSavedAppDevice(source: pending.source, attemptID: pending.attemptID)
    }

    private func connectBluetoothAutoConnectSavedAppDevice(source: String, attemptID: Int) {
        guard Thread.isMainThread else {
            runOnMain("connectBluetoothAutoConnectSavedAppDevice") { [weak self] in
                self?.connectBluetoothAutoConnectSavedAppDevice(source: source, attemptID: attemptID)
            }
            return
        }

        guard attemptID == bluetoothAutoConnectAttemptID else {
            appendLog("[AutoConnect] saved app device lookup skipped source=\(source) branch=stale-attempt attempt=\(attemptID) current=\(bluetoothAutoConnectAttemptID)")
            return
        }

        let rawAddress = UserDefaults.standard.string(forKey: "savedDeviceAddress")?.trimmingCharacters(in: .whitespacesAndNewlines)
        let rawName = UserDefaults.standard.string(forKey: "savedDeviceName")?.trimmingCharacters(in: .whitespacesAndNewlines)
        appendLog("[AutoConnect] saved app device lookup source=\(source) attempt=\(attemptID) hasAddress=\(!(rawAddress ?? "").isEmpty) name=\((rawName?.isEmpty == false ? rawName : nil) ?? "<none>")")

        guard let rawAddress, !rawAddress.isEmpty else {
            let shouldPromptSetup = shouldPromptSetupTutorialForAutoConnect(source: source)
            appendLog("[AutoConnect] saved app device missing source=\(source) attempt=\(attemptID) branch=\(shouldPromptSetup ? "setup-overlay" : "failure-overlay")")
            if shouldPromptSetup {
                promptBluetoothSetupTutorialForAutoConnect(attemptID: attemptID, source: source)
            } else {
                failBluetoothAutoConnect(
                    attemptID: attemptID,
                    message: "Bluetooth unavailable",
                    detail: "No app-paired device",
                    reason: "saved app device missing source=\(source)"
                )
            }
            return
        }

        let address = btNormalizedClassicAddressCandidates(from: rawAddress).first ?? rawAddress
        guard let device = IOBluetoothDevice(addressString: address) else {
            failBluetoothAutoConnect(
                attemptID: attemptID,
                message: "Bluetooth unavailable",
                detail: "Saved device address is invalid",
                reason: "saved app device invalid address=\(rawAddress) source=\(source)"
            )
            return
        }

        let name = (rawName?.isEmpty == false ? rawName : nil) ?? device.nameOrAddress ?? device.name ?? address
        let paired = device.isPaired()
        let connected = device.isConnected()
        let stabilizing = isPairingStabilizing(for: address)
        appendLog("[AutoConnect] selected saved app device source=\(source) attempt=\(attemptID) name=\(name) address=\(address) paired=\(paired) connected=\(connected) stabilizing=\(stabilizing) class=0x\(String(device.classOfDevice, radix: 16)) major=\(device.deviceClassMajor) minor=\(device.deviceClassMinor)")
        publishBluetoothAutoConnectOverlay(
            phase: .connecting,
            message: "Bluetooth connecting",
            detail: name,
            attemptID: attemptID
        )
        connectWhenPairingIsReady(address: address, name: name, source: "auto-connect-saved-app-device-\(source)")
    }

    private func shouldPromptSetupTutorialForAutoConnect(source: String) -> Bool {
        let isVideoPath = source.localizedCaseInsensitiveContains("video path")
        let isLegacyAirPlayTrigger = source.localizedCaseInsensitiveContains("AirPlay")
        let shouldPrompt = isVideoPath || isLegacyAirPlayTrigger
        appendLog("[AutoConnect] setup prompt decision source=\(source) videoPath=\(isVideoPath) legacyAirPlay=\(isLegacyAirPlayTrigger) shouldPrompt=\(shouldPrompt)")
        return shouldPrompt
    }

    private func promptBluetoothSetupTutorialForAutoConnect(attemptID: Int, source: String) {
        guard Thread.isMainThread else {
            runOnMain("promptBluetoothSetupTutorialForAutoConnect") { [weak self] in
                self?.promptBluetoothSetupTutorialForAutoConnect(attemptID: attemptID, source: source)
            }
            return
        }

        guard attemptID == bluetoothAutoConnectAttemptID else {
            appendLog("[AutoConnect] setup tutorial prompt ignored branch=stale-attempt attempt=\(attemptID) current=\(bluetoothAutoConnectAttemptID) source=\(source)")
            return
        }

        appendLog("[AutoConnect] setup tutorial prompt shown attempt=\(attemptID) source=\(source)")
        isBluetoothAutoConnectAttemptActive = false
        pendingBluetoothAutoConnectAfterPrepare = nil
        publishBluetoothAutoConnectOverlay(
            phase: .setupRequired,
            message: "Complete setup tutorial",
            detail: "Pair Bluetooth once to enable auto-connect",
            attemptID: attemptID
        )
    }

    private func publishBluetoothAutoConnectOverlay(
        phase: BluetoothAutoConnectOverlayPhase,
        message: String,
        detail: String,
        attemptID: Int
    ) {
        guard Thread.isMainThread else {
            runOnMain("publishBluetoothAutoConnectOverlay") { [weak self] in
                self?.publishBluetoothAutoConnectOverlay(
                    phase: phase,
                    message: message,
                    detail: detail,
                    attemptID: attemptID
                )
            }
            return
        }

        bluetoothAutoConnectCycle += 1
        let state = BluetoothAutoConnectOverlayState(
            phase: phase,
            message: message,
            detail: detail,
            attemptID: attemptID,
            cycle: bluetoothAutoConnectCycle
        )
        bluetoothAutoConnectOverlay = state
        appendLog("[AutoConnect] overlay published \(state.diagnosticDescription)")
    }

    private func completeBluetoothAutoConnectSuccess(attemptID: Int, detail: String) {
        guard Thread.isMainThread else {
            runOnMain("completeBluetoothAutoConnectSuccess") { [weak self] in
                self?.completeBluetoothAutoConnectSuccess(attemptID: attemptID, detail: detail)
            }
            return
        }

        guard isBluetoothAutoConnectAttemptActive, attemptID == bluetoothAutoConnectAttemptID else {
            appendLog("[AutoConnect] success ignored branch=inactive-or-stale attempt=\(attemptID) current=\(bluetoothAutoConnectAttemptID) active=\(isBluetoothAutoConnectAttemptActive)")
            return
        }

        appendLog("[AutoConnect] success attempt=\(attemptID) detail=\(detail)")
        isBluetoothAutoConnectAttemptActive = false
        pendingBluetoothAutoConnectAfterPrepare = nil
        publishBluetoothAutoConnectOverlay(
            phase: .connected,
            message: "Bluetooth connected",
            detail: detail,
            attemptID: attemptID
        )
        scheduleBluetoothAutoConnectOverlayDismissal(attemptID: attemptID, phase: .connected)
    }

    private func failBluetoothAutoConnect(attemptID: Int, message: String, detail: String, reason: String) {
        guard Thread.isMainThread else {
            runOnMain("failBluetoothAutoConnect") { [weak self] in
                self?.failBluetoothAutoConnect(attemptID: attemptID, message: message, detail: detail, reason: reason)
            }
            return
        }

        guard attemptID == bluetoothAutoConnectAttemptID else {
            appendLog("[AutoConnect] failure ignored branch=stale-attempt attempt=\(attemptID) current=\(bluetoothAutoConnectAttemptID) reason=\(reason)")
            return
        }

        appendLog("[AutoConnect] failure attempt=\(attemptID) message=\(message) detail=\(detail) reason=\(reason)")
        isBluetoothAutoConnectAttemptActive = false
        pendingBluetoothAutoConnectAfterPrepare = nil
        publishBluetoothAutoConnectOverlay(
            phase: .failed,
            message: message,
            detail: detail,
            attemptID: attemptID
        )
        scheduleBluetoothAutoConnectOverlayDismissal(attemptID: attemptID, phase: .failed)
    }

    private func failActiveBluetoothAutoConnectIfNeeded(message: String, detail: String, reason: String) {
        guard isBluetoothAutoConnectAttemptActive else {
            appendLog("[AutoConnect] active failure skipped branch=no-active-attempt reason=\(reason)")
            return
        }

        failBluetoothAutoConnect(
            attemptID: bluetoothAutoConnectAttemptID,
            message: message,
            detail: detail,
            reason: reason
        )
    }

    private func scheduleBluetoothAutoConnectOverlayDismissal(attemptID: Int, phase: BluetoothAutoConnectOverlayPhase) {
        bluetoothAutoConnectOverlayDismissalID += 1
        let dismissalID = bluetoothAutoConnectOverlayDismissalID
        let delay = bluetoothAutoConnectOverlayCycleInterval * TimeInterval(bluetoothAutoConnectOverlayDismissCycles)
        appendLog("[AutoConnect] overlay dismissal scheduled attempt=\(attemptID) phase=\(phase.rawValue) dismissal=\(dismissalID) cycles=\(bluetoothAutoConnectOverlayDismissCycles) interval=\(bluetoothAutoConnectOverlayCycleInterval)")

        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self else { return }
            guard self.bluetoothAutoConnectOverlayDismissalID == dismissalID else {
                self.appendLog("[AutoConnect] overlay dismissal ignored branch=stale-dismissal dismissal=\(dismissalID) current=\(self.bluetoothAutoConnectOverlayDismissalID)")
                return
            }
            guard self.bluetoothAutoConnectOverlay?.attemptID == attemptID else {
                self.appendLog("[AutoConnect] overlay dismissal ignored branch=attempt-changed dismissal=\(dismissalID) attempt=\(attemptID) current=\(self.bluetoothAutoConnectOverlay?.attemptID ?? -1)")
                return
            }

            self.appendLog("[AutoConnect] overlay dismissed attempt=\(attemptID) phase=\(phase.rawValue) dismissal=\(dismissalID)")
            self.bluetoothAutoConnectOverlay = nil
        }
    }

    func setEasyMouseClutchModeEnabled(_ enabled: Bool) {
        guard easyMouseClutchModeEnabled != enabled else {
            appendLog("[Mouse] clutch preference unchanged enabled=\(enabled)")
            return
        }

        easyMouseClutchModeEnabled = enabled
        appendLog("[Mouse] clutch preference updated enabled=\(enabled)")

        if !enabled {
            isMouseMovementClutched = false
            appendLog("[Mouse] clutch latch cleared because continuous movement mode is enabled")
        }
    }

    func setTrackpadSwipeToDragEnabled(_ enabled: Bool, reason: String) {
        guard Thread.isMainThread else {
            runOnMain("setTrackpadSwipeToDragEnabled") { [weak self] in
                self?.setTrackpadSwipeToDragEnabled(enabled, reason: reason)
            }
            return
        }

        let previous = trackpadSwipeToDragEnabled
        trackpadSwipeToDragEnabled = enabled
        appendLog("[TrackpadSwipeDrag] setting sync reason=\(reason) previous=\(previous) enabled=\(enabled) mode=\(trackpadSwipeToDragMode) phase=\(trackpadSwipeDragPhase.rawValue) syntheticButtonDown=\(trackpadSwipeDragSyntheticButtonDown)")
        recordTrackpadSwipeDiagnostic(
            event: "settingChanged",
            reason: reason,
            details: [
                "previousEnabled": String(previous),
                "enabled": String(enabled),
                "mode": trackpadSwipeToDragMode,
                "phase": trackpadSwipeDragPhase.rawValue,
                "syntheticButtonDown": String(trackpadSwipeDragSyntheticButtonDown)
            ]
        )

        guard previous != enabled else { return }
        if !enabled {
            cancelTrackpadSwipeDrag(reason: "setting-disabled")
        }
    }

    func setTrackpadSwipeToDragMode(_ mode: String, reason: String) {
        guard Thread.isMainThread else {
            runOnMain("setTrackpadSwipeToDragMode") { [weak self] in
                self?.setTrackpadSwipeToDragMode(mode, reason: reason)
            }
            return
        }

        let sanitizedMode = AppSettings.EasyTrackpadSwipeToDragMode.sanitized(mode)
        let previous = trackpadSwipeToDragMode
        trackpadSwipeToDragMode = sanitizedMode
        appendLog("[TrackpadSwipeDrag] mode sync reason=\(reason) requested=\(mode) previous=\(previous) mode=\(sanitizedMode) enabled=\(trackpadSwipeToDragEnabled) phase=\(trackpadSwipeDragPhase.rawValue) syntheticButtonDown=\(trackpadSwipeDragSyntheticButtonDown)")
        recordTrackpadSwipeDiagnostic(
            event: "settingChanged",
            reason: reason,
            details: [
                "previousMode": previous,
                "requestedMode": mode,
                "mode": sanitizedMode,
                "enabled": String(trackpadSwipeToDragEnabled),
                "phase": trackpadSwipeDragPhase.rawValue,
                "syntheticButtonDown": String(trackpadSwipeDragSyntheticButtonDown)
            ]
        )

        guard previous != sanitizedMode else { return }
        cancelTrackpadSwipeDrag(reason: "mode-changed")
    }

    func setReplayKitInputForwardingEnabled(_ enabled: Bool, reason: String) {
        guard Thread.isMainThread else {
            runOnMain("setReplayKitInputForwardingEnabled") { [weak self] in
                self?.setReplayKitInputForwardingEnabled(enabled, reason: reason)
            }
            return
        }

        let previous = replayKitInputForwardingEnabled
        replayKitInputForwardingEnabled = enabled
        replayKitInputForwardingReason = reason

        if previous != enabled {
            appendLog("[InputGate] ReplayKit input forwarding \(enabled ? "ENABLED" : "DISABLED") reason=\(reason) interruptConnected=\(interruptChannel != nil) mouseEnabled=\(mousePassthroughEnabled) pressedKeys=\(pressedHIDKeys.count) mouseButtons=\(mouseButtonState)")
            replayKitInputGateDropCount = 0
            if !enabled {
                releaseUserInputForReplayKitGate(reason: reason)
            }
        } else if replayKitInputGateDropCount == 0 {
            appendLog("[InputGate] ReplayKit input forwarding unchanged enabled=\(enabled) reason=\(reason)")
        }

        refreshInputGateStatusLabels(reason: reason)
    }

    private func canForwardUserHIDInput(source: String) -> Bool {
        guard replayKitInputForwardingEnabled else {
            replayKitInputGateDropCount += 1
            if replayKitInputGateDropCount <= 5 || replayKitInputGateDropCount % 100 == 0 {
                appendLog("[InputGate] \(source) input blocked: ReplayKit is not live reason=\(replayKitInputForwardingReason) drops=\(replayKitInputGateDropCount)")
            }
            return false
        }

        if replayKitInputGateDropCount != 0 {
            appendLog("[InputGate] \(source) input forwarding resumed after blockedEvents=\(replayKitInputGateDropCount)")
            replayKitInputGateDropCount = 0
        }
        return true
    }

    private func refreshInputGateStatusLabels(reason: String) {
        guard interruptChannel != nil else { return }

        if replayKitInputForwardingEnabled {
            keystrokeStatusLabel?.stringValue = "Keyboard input active in the Easy screen"
            keystrokeStatusLabel?.textColor = .systemGreen
            if mousePassthroughEnabled {
                mouseStatusLabel?.stringValue = "Mouse input active in the Easy screen"
                mouseStatusLabel?.textColor = .systemGreen
            }
        } else {
            keystrokeStatusLabel?.stringValue = "Keyboard input paused until broadcast is live"
            keystrokeStatusLabel?.textColor = .systemOrange
            mouseStatusLabel?.stringValue = "Mouse input paused until broadcast is live"
            mouseStatusLabel?.textColor = .systemOrange
        }

        appendLog("[InputGate] status labels refreshed enabled=\(replayKitInputForwardingEnabled) reason=\(reason)")
    }

    private func releaseUserInputForReplayKitGate(reason: String) {
        guard let channel = interruptChannel else {
            appendLog("[InputGate] release skipped: no interrupt channel reason=\(reason)")
            pressedHIDKeys.removeAll()
            resetLocalPointerStateAfterInputGateClose()
            return
        }

        appendLog("[InputGate] releasing keyboard and pointer state because ReplayKit input gate closed reason=\(reason)")

        var keyboardRelease: [UInt8] = [0xA1, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00]
        let keyboardResult = channel.writeAsync(&keyboardRelease, length: UInt16(keyboardRelease.count), refcon: nil)
        appendLog("[InputGate] keyboard release writeAsync result=\(keyboardResult)")

        var mouseRelease: [UInt8] = [0xA1, 0x0A, 0x00, 0x00, 0x00, 0x00, 0x00]
        let mouseResult = channel.writeAsync(&mouseRelease, length: UInt16(mouseRelease.count), refcon: nil)
        appendLog("[InputGate] relative pointer release writeAsync result=\(mouseResult)")

        var consumerRelease: [UInt8] = [0xA1, 0x02, 0x00, 0x00]
        let consumerResult = channel.writeAsync(&consumerRelease, length: UInt16(consumerRelease.count), refcon: nil)
        appendLog("[InputGate] consumer release writeAsync result=\(consumerResult)")

        if absolutePointerTransportEnabled, pointerSurfaceSize.width > 0, pointerSurfaceSize.height > 0 {
            let clamped = clampPhonePointToSurface(virtualPointerPoint)
            let logicalX = absolutePointerLogicalValue(clamped.x, extent: pointerSurfaceSize.width)
            let logicalY = absolutePointerLogicalValue(clamped.y, extent: pointerSurfaceSize.height)
            var absoluteRelease: [UInt8] = [
                0xA1,
                Self.absolutePointerReportID,
                0x00,
                UInt8(logicalX & 0x00FF),
                UInt8((logicalX & 0xFF00) >> 8),
                UInt8(logicalY & 0x00FF),
                UInt8((logicalY & 0xFF00) >> 8),
            ]
            let absoluteResult = channel.writeAsync(&absoluteRelease, length: UInt16(absoluteRelease.count), refcon: nil)
            appendLog("[InputGate] absolute pointer release writeAsync result=\(absoluteResult) point=\(InputSurfaceDiagnostics.pointString(clamped))")
        }

        pressedHIDKeys.removeAll()
        resetLocalPointerStateAfterInputGateClose()
    }

    private func resetLocalPointerStateAfterInputGateClose() {
        resetTrackpadSwipeDragState(reason: "input-gate-closed")
        mouseButtonState = 0
        isMouseMovementClutched = false
        isRightMousePressed = false
        isLeftMousePressedForSwipe = false
        didCurrentLeftPressBecomeDrag = false
        isDragGestureInProgress = false
        isSwipeButtonDownOnPhone = false
        mouseDeltaRemainderX = 0
        mouseDeltaRemainderY = 0
        lastPointerReportDelta = .zero
    }

    func setEasyPointerSpikeEnabled(_ enabled: Bool, variant: String = "REL") {
        let transport = PointerSpikeTransportVariant(label: variant)
        let normalizedVariant = transport.label
        let changed = easyPointerSpikeEnabled != enabled || easyPointerSpikeVariant != normalizedVariant
        easyPointerSpikeEnabled = enabled
        easyPointerSpikeVariant = normalizedVariant

        guard changed else {
            appendLog("[PointerSpike] preference unchanged enabled=\(enabled) variant=\(normalizedVariant) absoluteMouseReport=\(transport.usesAbsoluteMouseReport)")
            return
        }

        if !enabled {
            pendingPointerSpikeAttempts.removeAll()
            pointerSpikeSamples.removeAll()
            resetPointerCalibrationInfluence(reason: "spike-disabled")
            appendLog("[PointerSpike] disabled variant=\(normalizedVariant) absoluteMouseReport=\(transport.usesAbsoluteMouseReport); cleared pending tap attempts")
            postPointerSpikeMetricsReset()
        } else {
            pendingPointerSpikeAttempts.removeAll()
            pointerSpikeSamples.removeAll()
            resetPointerCalibrationInfluence(reason: "spike-enabled")
            appendLog("[PointerSpike] enabled variant=\(normalizedVariant) absoluteMouseReport=\(transport.usesAbsoluteMouseReport) absoluteReportID=\(Self.absolutePointerReportID) closedLoopTapPositioning=true manualRightRealignment=true descriptorRequiresForgetAndRepair=\(transport.usesAbsoluteMouseReport)")
            postPointerSpikeMetricsReset()
        }
    }

    private func resetPointerCalibrationInfluence(reason: String) {
        pointerTransportScaleX = 1
        pointerTransportScaleY = 1
        calibrationScaleSamplesX.removeAll()
        calibrationScaleSamplesY.removeAll()
        calibrationReportDeltaSinceLastSample = .zero
        lastCalibrationActualPoint = nil
        appendLog("[PointerSpike] reset calibration influence reason=\(reason) scale=(1.000,1.000)")
    }

    private var movementForwardingEnabled: Bool {
        easyMouseClutchModeEnabled ? isMouseMovementClutched : true
    }

    private var deterministicPointerPositioningEnabled: Bool {
        easyPointerSpikeEnabled
    }

    func show() {
        guard Thread.isMainThread else {
            runOnMain("show Bluetooth HID panel") { [weak self] in
                self?.show()
            }
            return
        }

        installBluetoothHIDRuntimeSwizzles()
        installPairingNotificationObservers()
        if let logWindow {
            appendLog("[Panel] Reusing existing Bluetooth HID panel")
            refreshSavedDeviceUI()
            interactiveTutorialOverlay.attach(
                window: logWindow,
                prepareButton: prepareButton,
                chooseIPhoneButton: connectButton,
                source: "Bluetooth panel reused"
            )
            syncInteractiveTutorialPreparationState(reason: "Bluetooth panel reused")
            logWindow.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        createUI()
        syncInteractiveTutorialPreparationState(reason: "Bluetooth panel created")
        NSApp.activate(ignoringOtherApps: true)

        appendLog("=== Specchio Bluetooth HID ===")
        appendLog("[BTFlow] Consumer pairing panel opened")
        appendLog("[BTFlow] Waiting for user to prepare Bluetooth")
    }

    private func syncInteractiveTutorialPreparationState(reason: String) {
        appendLog("[Tutorial] preparation sync reason=\(reason) classicReady=\(classicManagerReady) sdpPublished=\(preparedBluetoothSDPPublished) connected=\(isBluetoothHIDConnected)")
        guard classicManagerReady && preparedBluetoothSDPPublished else {
            appendLog("[Tutorial] preparation sync skipped reason=\(reason) branch=not-ready")
            return
        }
        InteractiveTutorialCoordinator.shared.recordBluetoothPrepared(
            source: "Bluetooth preparation sync: \(reason)"
        )
    }

    private func installPairingNotificationObservers() {
        guard pairingNotificationObservers.isEmpty else {
            appendLog("[Pairing] notification observers already installed")
            return
        }

        let center = NotificationCenter.default
        pairingNotificationObservers.append(center.addObserver(
            forName: .easyBluetoothPairingCompleted,
            object: nil,
            queue: .main
        ) { [weak self] note in
            self?.handlePairingCompleted(note)
        })
        pairingNotificationObservers.append(center.addObserver(
            forName: .easyBluetoothPairingFailed,
            object: nil,
            queue: .main
        ) { [weak self] note in
            self?.handlePairingFailed(note)
        })
        pairingNotificationObservers.append(center.addObserver(
            forName: .easyBluetoothPeerUnpaired,
            object: nil,
            queue: .main
        ) { [weak self] note in
            self?.handlePeerUnpaired(note)
        })
        appendLog("[Pairing] installed notification observers for CoreBluetoothUI callbacks")
    }

    func bindInputWindow(_ window: NSWindow?) {
        runOnMain("bindInputWindow") { [weak self] in
            guard let self else { return }
            self.inputWindow = window
            self.appendLog("[InputSurface] Bound Easy input window present=\(window != nil) title=\(window?.title ?? "<untitled>") number=\(window?.windowNumber ?? -1)")
        }
    }

    func bindInputSurface(window: NSWindow?, frameInWindow: CGRect, phoneScreenSize: CGSize, displayRotationDegrees: Int = 0) {
        runOnMain("bindInputSurface") { [weak self] in
            guard let self else { return }
            let previousFrame = self.inputSurfaceFrameInWindow
            let previousSurfaceSize = self.pointerSurfaceSize
            let previousSurfaceOrientation = InputSurfaceDiagnostics.orientationString(previousSurfaceSize)
            self.inputWindow = window
            let frameIsUsable = InputSurfaceDiagnostics.isFinite(frameInWindow)
                && frameInWindow.width > 0
                && frameInWindow.height > 0
            if frameIsUsable {
                self.inputSurfaceFrameInWindow = frameInWindow
            } else {
                self.inputSurfaceFrameInWindow = nil
                self.appendLog("[InputSurface] Ignored invalid video surface frame=\(InputSurfaceDiagnostics.rectString(frameInWindow)) branch=invalid-frame")
            }
            let previousRotation = self.inputSurfaceRotationDegrees
            let nextRotation = InputSurfaceRotationMapping.normalizedRotation(displayRotationDegrees)
            let rotationChanged = previousRotation != nextRotation
            self.inputSurfaceRotationDegrees = nextRotation
            var acceptedPhoneSurfaceSize = false
            if InputSurfaceDiagnostics.isFinite(phoneScreenSize), phoneScreenSize.width > 0, phoneScreenSize.height > 0 {
                self.pointerSurfaceSize = phoneScreenSize
                acceptedPhoneSurfaceSize = true
                self.appendLog("[InputSurface] accepted phone surface size=\(InputSurfaceDiagnostics.sizeString(phoneScreenSize)) branch=valid-phone-size")
            } else {
                self.appendLog("[InputSurface] Ignored invalid phone surface size=\(InputSurfaceDiagnostics.sizeString(phoneScreenSize)) branch=invalid-phone-size")
            }
            let nextSurfaceSize = self.pointerSurfaceSize
            let nextSurfaceOrientation = InputSurfaceDiagnostics.orientationString(nextSurfaceSize)
            let surfaceSizeChanged = abs(previousSurfaceSize.width - nextSurfaceSize.width) > 0.5
                || abs(previousSurfaceSize.height - nextSurfaceSize.height) > 0.5
            let surfaceOrientationChanged = previousSurfaceOrientation != nextSurfaceOrientation
            let previousFrameString = previousFrame.map(InputSurfaceDiagnostics.rectString) ?? "nil"
            let previousFrameChanged = previousFrame.map { previous in
                abs(previous.origin.x - frameInWindow.origin.x) > 0.5
                    || abs(previous.origin.y - frameInWindow.origin.y) > 0.5
                    || abs(previous.width - frameInWindow.width) > 0.5
                    || abs(previous.height - frameInWindow.height) > 0.5
            } ?? frameIsUsable
            if rotationChanged {
                self.handleInputSurfaceRotationChanged(from: previousRotation, to: nextRotation)
            } else {
                self.appendLog("[InputSurface] rotation unchanged rotation=\(nextRotation) branch=no-pointer-reset")
            }
            self.appendLog("[InputSurface] Bound video surface window=\(window?.windowNumber ?? -1) frame=\(InputSurfaceDiagnostics.rectString(frameInWindow)) frameUsable=\(frameIsUsable) phone=\(InputSurfaceDiagnostics.sizeString(self.pointerSurfaceSize)) rotation=\(self.inputSurfaceRotationDegrees) rotationChanged=\(rotationChanged)")
            self.recordInputSurfaceDiagnostic(
                event: "bindInputSurface",
                reason: rotationChanged ? "display-rotation-changed" : "surface-bound",
                details: [
                    "windowPresent": String(window != nil),
                    "windowNumber": String(window?.windowNumber ?? -1),
                    "frameUsable": String(frameIsUsable),
                    "frame": InputSurfaceDiagnostics.rectString(frameInWindow),
                    "previousFrame": previousFrameString,
                    "frameChanged": String(previousFrameChanged),
                    "acceptedPhoneSurfaceSize": String(acceptedPhoneSurfaceSize),
                    "previousPhoneSurface": InputSurfaceDiagnostics.sizeString(previousSurfaceSize),
                    "nextPhoneSurface": InputSurfaceDiagnostics.sizeString(nextSurfaceSize),
                    "previousPhoneOrientation": previousSurfaceOrientation,
                    "nextPhoneOrientation": nextSurfaceOrientation,
                    "phoneSurfaceSizeChanged": String(surfaceSizeChanged),
                    "phoneSurfaceOrientationChanged": String(surfaceOrientationChanged),
                    "previousRotation": String(previousRotation),
                    "nextRotation": String(nextRotation),
                    "rotationChanged": String(rotationChanged),
                    "pointerTransportScaleX": FrameDropDiagnostics.format(Double(self.pointerTransportScaleX), digits: 4),
                    "pointerTransportScaleY": FrameDropDiagnostics.format(Double(self.pointerTransportScaleY), digits: 4)
                ]
            )
        }
    }

    private func handleInputSurfaceRotationChanged(from previousRotation: Int, to nextRotation: Int) {
        appendLog("[InputSurface] rotation changed from=\(previousRotation) to=\(nextRotation) branch=reset-pointer-state")
        recordInputSurfaceDiagnostic(
            event: "inputSurfaceReferenceReset",
            reason: "display-rotation-changed",
            details: [
                "previousRotation": String(previousRotation),
                "nextRotation": String(nextRotation),
                "phoneSurface": InputSurfaceDiagnostics.sizeString(pointerSurfaceSize),
                "phoneOrientation": InputSurfaceDiagnostics.orientationString(pointerSurfaceSize),
                "frame": inputSurfaceFrameInWindow.map(InputSurfaceDiagnostics.rectString) ?? "nil",
                "interruptConnected": String(interruptChannel != nil),
                "mouseButtonState": String(mouseButtonState),
                "clutched": String(isMouseMovementClutched),
                "rightPressed": String(isRightMousePressed),
                "leftSwipePressed": String(isLeftMousePressedForSwipe),
                "dragInProgress": String(isDragGestureInProgress)
            ]
        )

        let hadActivePointerState = mouseButtonState != 0
            || isMouseMovementClutched
            || isRightMousePressed
            || isLeftMousePressedForSwipe
            || didCurrentLeftPressBecomeDrag
            || isDragGestureInProgress
            || isSwipeButtonDownOnPhone
            || isPointerButtonDown

        if interruptChannel != nil, hadActivePointerState {
            appendLog("[InputSurface] rotation reset releasing active pointer buttons from=\(previousRotation) to=\(nextRotation)")
            sendAllPointerButtonsReleased(reason: "inputSurfaceRotationChanged:\(previousRotation)->\(nextRotation)")
        } else if interruptChannel == nil {
            appendLog("[InputSurface] rotation reset skipped release branch=no-interrupt-channel from=\(previousRotation) to=\(nextRotation)")
        } else {
            appendLog("[InputSurface] rotation reset skipped release branch=no-active-pointer-state from=\(previousRotation) to=\(nextRotation)")
        }

        mouseButtonState = 0
        isMouseMovementClutched = false
        isRightMousePressed = false
        isLeftMousePressedForSwipe = false
        didCurrentLeftPressBecomeDrag = false
        isDragGestureInProgress = false
        isSwipeButtonDownOnPhone = false
        isPointerButtonDown = false
        mouseDeltaRemainderX = 0
        mouseDeltaRemainderY = 0
        lastPointerReportDelta = .zero
        pendingPointerSpikeAttempts.removeAll()
        pointerSpikeSamples.removeAll()
        resetPointerCalibrationInfluence(reason: "input-surface-rotation-\(previousRotation)-to-\(nextRotation)")

        if InputSurfaceDiagnostics.isFinite(pointerSurfaceSize), pointerSurfaceSize.width > 0, pointerSurfaceSize.height > 0 {
            virtualPointerPoint = CGPoint(x: pointerSurfaceSize.width / 2, y: pointerSurfaceSize.height / 2)
            postPointerFeedback(kind: "rotationReset", point: virtualPointerPoint)
            postPointerSpikeVisualization(
                phase: "rotationReset",
                sequence: pointerSpikeNextSequence,
                targetPhonePoint: virtualPointerPoint,
                mappedPhonePoint: virtualPointerPoint,
                virtualPhonePoint: virtualPointerPoint,
                actualPhonePoint: nil,
                note: "Rotation \(previousRotation)->\(nextRotation)"
            )
            appendLog("[InputSurface] rotation reset anchored virtual pointer center=\(InputSurfaceDiagnostics.pointString(virtualPointerPoint)) surface=\(InputSurfaceDiagnostics.sizeString(pointerSurfaceSize))")
        } else {
            virtualPointerPoint = .zero
            appendLog("[InputSurface] rotation reset could not anchor virtual pointer branch=invalid-surface surface=\(InputSurfaceDiagnostics.sizeString(pointerSurfaceSize))")
        }

        postPointerSpikeMetricsReset()
    }

    func bindPointerSurface(phoneScreenSize: CGSize, reason: String = "unspecified") {
        runOnMain("bindPointerSurface") { [weak self] in
            guard let self else { return }
            guard InputSurfaceDiagnostics.isFinite(phoneScreenSize), phoneScreenSize.width > 0, phoneScreenSize.height > 0 else {
                self.appendLog("[Pointer] Ignoring invalid surface size \(InputSurfaceDiagnostics.sizeString(phoneScreenSize))")
                self.recordInputSurfaceDiagnostic(
                    event: "bindPointerSurface",
                    reason: "invalid-phone-surface-\(reason)",
                    details: [
                        "requestedPhoneSurface": InputSurfaceDiagnostics.sizeString(phoneScreenSize),
                        "requestedPhoneOrientation": InputSurfaceDiagnostics.orientationString(phoneScreenSize),
                        "currentPhoneSurface": InputSurfaceDiagnostics.sizeString(self.pointerSurfaceSize),
                        "currentPhoneOrientation": InputSurfaceDiagnostics.orientationString(self.pointerSurfaceSize),
                        "displayRotation": String(self.inputSurfaceRotationDegrees)
                    ],
                    severity: "warning"
                )
                return
            }
            let previousSurfaceSize = self.pointerSurfaceSize
            let previousOrientation = InputSurfaceDiagnostics.orientationString(previousSurfaceSize)
            let nextOrientation = InputSurfaceDiagnostics.orientationString(phoneScreenSize)
            let sizeChanged = abs(previousSurfaceSize.width - phoneScreenSize.width) > 0.5
                || abs(previousSurfaceSize.height - phoneScreenSize.height) > 0.5
            let orientationChanged = previousOrientation != nextOrientation
            self.pointerSurfaceSize = phoneScreenSize
            self.virtualPointerPoint = CGPoint(x: phoneScreenSize.width / 2, y: phoneScreenSize.height / 2)
            self.appendLog("[Pointer] Bound phone surface width=\(phoneScreenSize.width) height=\(phoneScreenSize.height)")
            self.recordInputSurfaceDiagnostic(
                event: "bindPointerSurface",
                reason: reason,
                details: [
                    "previousPhoneSurface": InputSurfaceDiagnostics.sizeString(previousSurfaceSize),
                    "nextPhoneSurface": InputSurfaceDiagnostics.sizeString(phoneScreenSize),
                    "previousPhoneOrientation": previousOrientation,
                    "nextPhoneOrientation": nextOrientation,
                    "phoneSurfaceSizeChanged": String(sizeChanged),
                    "phoneSurfaceOrientationChanged": String(orientationChanged),
                    "displayRotation": String(self.inputSurfaceRotationDegrees),
                    "frame": self.inputSurfaceFrameInWindow.map(InputSurfaceDiagnostics.rectString) ?? "nil",
                    "interruptConnected": String(self.interruptChannel != nil),
                    "mouseButtonState": String(self.mouseButtonState),
                    "clutched": String(self.isMouseMovementClutched),
                    "virtualPointer": InputSurfaceDiagnostics.pointString(self.virtualPointerPoint)
                ]
            )
        }
    }

    func startCalibrationReceiver() {
        calibrationQueue.async { [weak self] in
            guard let self else { return }
            guard self.calibrationListener == nil else {
                self.appendLog("[Calibration] listener already active on port \(self.calibrationPort)")
                return
            }
            guard let port = NWEndpoint.Port(rawValue: self.calibrationPort) else {
                self.appendLog("[Calibration] invalid port \(self.calibrationPort)")
                return
            }

            do {
                let listener = try NWListener(using: .tcp, on: port)
                self.calibrationListener = listener
                listener.stateUpdateHandler = { [weak self] state in
                    self?.handleCalibrationListenerState(state)
                }
                listener.newConnectionHandler = { [weak self] connection in
                    self?.acceptCalibrationConnection(connection)
                }
                listener.start(queue: self.calibrationQueue)
                self.appendLog("[Calibration] starting listener on port \(self.calibrationPort)")
            } catch {
                self.appendLog("[Calibration] failed to start listener: \(error.localizedDescription)")
            }
        }
    }

    func stopCalibrationReceiver() {
        calibrationQueue.async { [weak self] in
            guard let self else { return }
            self.appendLog("[Calibration] stopping listener")
            self.calibrationConnection?.cancel()
            self.calibrationConnection = nil
            self.calibrationListener?.cancel()
            self.calibrationListener = nil
            self.calibrationReceiveBuffer.removeAll()
        }
    }

    func beginPointerInteraction(at phonePoint: CGPoint) {
        appendLog("[Pointer] begin at=\(InputSurfaceDiagnostics.pointString(phonePoint)) absoluteMouseReport=\(absolutePointerTransportEnabled)")
        if absolutePointerTransportEnabled {
            isPointerButtonDown = true
            sendAbsolutePointerReport(point: phonePoint, buttons: 0x01, reason: "begin")
            return
        }
        movePointer(to: phonePoint, reason: "begin")
        isPointerButtonDown = true
        sendMouseReport(buttons: 0x01, dx: 0, dy: 0, dz: 0, wheel: 0)
    }

    func dragPointer(to phonePoint: CGPoint) {
        guard isPointerButtonDown else {
            appendLog("[Pointer] drag ignored because button is not down")
            return
        }
        if absolutePointerTransportEnabled {
            sendAbsolutePointerReport(point: phonePoint, buttons: 0x01, reason: "drag")
            return
        }
        movePointer(to: phonePoint, reason: "drag", buttons: 0x01)
    }

    func endPointerInteraction(at phonePoint: CGPoint, click: Bool) {
        appendLog("[Pointer] end at=\(InputSurfaceDiagnostics.pointString(phonePoint)) click=\(click) absoluteMouseReport=\(absolutePointerTransportEnabled)")
        if absolutePointerTransportEnabled {
            isPointerButtonDown = false
            sendAbsolutePointerReport(point: phonePoint, buttons: 0x00, reason: "end")
            return
        }
        movePointer(to: phonePoint, reason: "end", buttons: isPointerButtonDown ? 0x01 : 0x00)
        isPointerButtonDown = false
        sendMouseReport(buttons: 0x00, dx: 0, dy: 0, dz: 0, wheel: 0)
    }

    func scrollPointer(deltaY: CGFloat) {
        guard deltaY.isFinite else {
            appendLog("[Pointer] scroll ignored because deltaY is non-finite deltaY=\(deltaY)")
            return
        }

        let boundedWheelDelta = max(CGFloat(Int8.min), min(CGFloat(Int8.max), -deltaY))
        let wheel = Int8(clamping: Int(boundedWheelDelta.rounded(.towardZero)))
        appendLog("[Pointer] scroll deltaY=\(deltaY) wheel=\(wheel)")
        sendMouseReport(buttons: 0, dx: 0, dy: 0, dz: 0, wheel: wheel)
    }

    func sendConsumerControlCommand(bit: UInt8, name: String) {
        appendLog("[EasyToolbar] \(name) tapped bit=\(bit)")
        sendConsumerControl(bit: bit)
    }

    func performEasyAutoUnlock(passcode: String, source: String) -> EasyAutoUnlockHIDResult {
        let passcodeCharacters = Array(passcode)
        appendLog("[EasyAutoUnlock] controller request source=\(source) mainThread=\(Thread.isMainThread) connected=\(isBluetoothHIDConnected) interruptConnected=\(interruptChannel != nil) inputGate=\(replayKitInputForwardingEnabled) passcodeLength=\(passcodeCharacters.count)")

        guard isBluetoothHIDConnected, interruptChannel != nil else {
            appendLog("[EasyAutoUnlock] controller blocked source=\(source) reason=bluetooth-disconnected connected=\(isBluetoothHIDConnected) interruptConnected=\(interruptChannel != nil)")
            return .bluetoothDisconnected
        }

        var mappedPasscode: [(code: UInt8, modifiers: UInt8)] = []
        var unsupportedCharacters: [Character] = []
        for character in passcodeCharacters {
            if let (code, modifiers) = Self.charToHID(character) {
                mappedPasscode.append((code, modifiers))
            } else {
                unsupportedCharacters.append(character)
            }
        }

        guard unsupportedCharacters.isEmpty else {
            appendLog("[EasyAutoUnlock] controller blocked source=\(source) reason=unsupported-characters unsupportedCount=\(unsupportedCharacters.count)")
            return .unsupportedCharacters(unsupportedCharacters.count)
        }

        appendLog("[EasyAutoUnlock] controller scheduling source=\(source) homeToFirstReturn=\(EasyAutoUnlockSequenceTiming.homeToFirstReturn) firstReturnToPIN=\(EasyAutoUnlockSequenceTiming.firstReturnToPIN) keyHold=\(EasyAutoUnlockSequenceTiming.keyHoldDuration) keySpacing=\(EasyAutoUnlockSequenceTiming.keySpacing) pinCharacters=\(mappedPasscode.count)")

        sendConsumerControl(
            bit: 2,
            source: "EasyAutoUnlock home",
            bypassInputGate: true
        )

        scheduleKeyboardUsage(
            0x28,
            modifiers: 0x00,
            source: "EasyAutoUnlock first-return",
            delay: EasyAutoUnlockSequenceTiming.homeToFirstReturn,
            bypassInputGate: true
        )

        var delay = EasyAutoUnlockSequenceTiming.homeToFirstReturn + EasyAutoUnlockSequenceTiming.firstReturnToPIN
        for (index, key) in mappedPasscode.enumerated() {
            scheduleKeyboardUsage(
                key.code,
                modifiers: key.modifiers,
                source: "EasyAutoUnlock pin-\(index + 1)",
                delay: delay,
                bypassInputGate: true
            )
            delay += EasyAutoUnlockSequenceTiming.keySpacing
        }

        scheduleKeyboardUsage(
            0x28,
            modifiers: 0x00,
            source: "EasyAutoUnlock final-return",
            delay: delay,
            bypassInputGate: true
        )

        appendLog("[EasyAutoUnlock] controller scheduled source=\(source) finalReturnDelay=\(String(format: "%.2f", delay))")
        return .started
    }

    func sendKeyboardShortcutCommand(
        name: String,
        modifiers: UInt8,
        keyCodes: [UInt8],
        holdDuration: TimeInterval
    ) {
        appendLog("[EasyToolbar] shortcut requested name=\(name) modifiers=0x\(String(format: "%02X", modifiers)) keys=\(Self.hidKeyListDescription(keyCodes)) holdDuration=\(String(format: "%.2f", holdDuration))")
        guard !keyCodes.isEmpty else {
            appendLog("[EasyToolbar] shortcut ignored name=\(name) reason=no-key-codes")
            return
        }
        guard writeKeyboardReport(
            modifiers: modifiers,
            keys: keyCodes,
            source: "ToolbarShortcut press \(name)"
        ) else {
            appendLog("[EasyToolbar] shortcut press dropped name=\(name)")
            return
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + holdDuration) { [weak self] in
            guard let self else { return }
            let released = self.writeKeyboardReport(
                modifiers: 0x00,
                keys: [],
                source: "ToolbarShortcut release \(name)"
            )
            self.appendLog("[EasyToolbar] shortcut release name=\(name) released=\(released)")
        }
    }

    func sendModifierHoldCommand(name: String, modifiers: UInt8, duration: TimeInterval) {
        appendLog("[EasyToolbar] modifier hold requested name=\(name) modifiers=0x\(String(format: "%02X", modifiers)) duration=\(String(format: "%.2f", duration))")
        guard writeKeyboardReport(
            modifiers: modifiers,
            keys: [],
            source: "ToolbarModifierHold press \(name)"
        ) else {
            appendLog("[EasyToolbar] modifier hold press dropped name=\(name)")
            return
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + duration) { [weak self] in
            guard let self else { return }
            let released = self.writeKeyboardReport(
                modifiers: 0x00,
                keys: [],
                source: "ToolbarModifierHold release \(name)"
            )
            self.appendLog("[EasyToolbar] modifier hold release name=\(name) released=\(released)")
        }
    }

    // MARK: - UI

    private func createUI() {
        logWindow = NSWindow(
            contentRect: NSRect(x: 100, y: 100, width: 520, height: 560),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered, defer: false
        )
        logWindow.title = "Connect Bluetooth Input"
        logWindow.isReleasedWhenClosed = false
        logWindow.delegate = self

        let root = NSStackView()
        root.orientation = .vertical
        root.alignment = .leading
        root.spacing = 18
        root.edgeInsets = NSEdgeInsets(top: 24, left: 24, bottom: 24, right: 24)
        root.translatesAutoresizingMaskIntoConstraints = false

        let header = NSTextField(labelWithString: "Connect Bluetooth")
        header.font = .systemFont(ofSize: 28, weight: .bold)
        root.addArrangedSubview(header)

        instructionLabel = wrappingLabel("We’ll prepare this Mac as a Bluetooth keyboard and mouse. On your iPhone, keep Bluetooth settings open and select this Mac when it appears.")
        root.addArrangedSubview(instructionLabel)

        statusLabel = NSTextField(labelWithString: "Ready to prepare Bluetooth")
        statusLabel?.font = .systemFont(ofSize: 13, weight: .semibold)
        statusLabel?.textColor = .secondaryLabelColor
        root.addArrangedSubview(statusLabel)

        progressIndicator = NSProgressIndicator()
        progressIndicator?.style = .spinning
        progressIndicator?.controlSize = .small
        progressIndicator?.isDisplayedWhenStopped = false

        prepareButton = NSButton(title: "Prepare Bluetooth", target: self, action: #selector(prepareTapped))
        prepareButton.bezelStyle = .rounded
        prepareButton.controlSize = .large

        resetPrepareButton = NSButton(title: "Reset", target: self, action: #selector(resetPrepareTapped))
        resetPrepareButton.bezelStyle = .rounded
        resetPrepareButton.controlSize = .large

        let prepareRow = NSStackView(views: [prepareButton, resetPrepareButton, progressIndicator])
        prepareRow.orientation = .horizontal
        prepareRow.spacing = 10
        prepareRow.alignment = .centerY
        root.addArrangedSubview(prepareRow)

        let deviceCard = NSStackView()
        deviceCard.orientation = .horizontal
        deviceCard.alignment = .centerY
        deviceCard.spacing = 12
        deviceCard.edgeInsets = NSEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)
        deviceCard.wantsLayer = true
        deviceCard.layer?.cornerRadius = 8
        deviceCard.layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor

        let phoneIcon = NSImageView(image: NSImage(systemSymbolName: "iphone", accessibilityDescription: "Saved phone") ?? NSImage())
        phoneIcon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 28, weight: .regular)
        phoneIcon.translatesAutoresizingMaskIntoConstraints = false
        phoneIcon.widthAnchor.constraint(equalToConstant: 34).isActive = true

        deviceInfoLabel = NSTextField(labelWithString: "No saved iPhone yet")
        deviceInfoLabel.font = .systemFont(ofSize: 13, weight: .medium)
        deviceInfoLabel.lineBreakMode = .byTruncatingMiddle

        reconnectButton = NSButton(title: "Connect", target: self, action: #selector(reconnectTapped))
        reconnectButton?.bezelStyle = .rounded

        forgetButton = NSButton(title: "Forget", target: self, action: #selector(forgetSavedDeviceTapped))
        forgetButton.bezelStyle = .rounded

        deviceCard.addArrangedSubview(phoneIcon)
        deviceCard.addArrangedSubview(deviceInfoLabel)
        deviceCard.addArrangedSubview(reconnectButton)
        deviceCard.addArrangedSubview(forgetButton)
        root.addArrangedSubview(deviceCard)

        connectButton = NSButton(title: "Choose iPhone…", target: self, action: #selector(connectTapped))
        connectButton?.bezelStyle = .rounded
        connectButton?.isEnabled = false
        root.addArrangedSubview(connectButton)

        keystrokeStatusLabel = NSTextField(labelWithString: "Keyboard and mouse will activate in the Easy screen after connection.")
        keystrokeStatusLabel?.font = .systemFont(ofSize: 12)
        keystrokeStatusLabel?.textColor = .secondaryLabelColor
        root.addArrangedSubview(keystrokeStatusLabel)

        mouseStatusLabel = NSTextField(labelWithString: "Mouse passthrough: waiting for connection")
        mouseStatusLabel?.font = .systemFont(ofSize: 12)
        mouseStatusLabel?.textColor = .secondaryLabelColor
        root.addArrangedSubview(mouseStatusLabel)

        sendField = NSTextField()
        sendField.isHidden = true
        sendButton = NSButton(title: "Send", target: self, action: #selector(sendTapped))
        sendButton?.isHidden = true
        sendButton?.isEnabled = false
        mouseToggleBtn = NSButton(title: "Mouse", target: self, action: #selector(mouseToggleTapped))
        mouseToggleBtn?.isHidden = true
        mouseToggleBtn?.isEnabled = false

        let hiddenControls = NSStackView(views: [sendField, sendButton, mouseToggleBtn])
        hiddenControls.isHidden = true
        root.addArrangedSubview(hiddenControls)

        advancedLogButton = NSButton(title: "Show Advanced Logs", target: self, action: #selector(toggleAdvancedLogs))
        advancedLogButton.setButtonType(.switch)
        root.addArrangedSubview(advancedLogButton)

        logScrollView = NSScrollView()
        logScrollView.hasVerticalScroller = true
        logScrollView.isHidden = true
        logScrollView.translatesAutoresizingMaskIntoConstraints = false
        logScrollView.heightAnchor.constraint(equalToConstant: 180).isActive = true

        logView = NSTextView(frame: .zero)
        logView.isEditable = false
        logView.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        logView.backgroundColor = .textBackgroundColor
        logView.textColor = .labelColor
        logScrollView.documentView = logView
        root.addArrangedSubview(logScrollView)

        logActionsStack = NSStackView()
        logActionsStack.orientation = .horizontal
        logActionsStack.spacing = 8
        let copyButton = NSButton(title: "Copy Logs", target: self, action: #selector(copyLogs))
        let saveButton = NSButton(title: "Save Logs…", target: self, action: #selector(saveLogs))
        logActionsStack.addArrangedSubview(copyButton)
        logActionsStack.addArrangedSubview(saveButton)
        logActionsStack.isHidden = true
        root.addArrangedSubview(logActionsStack)

        let cv = NSView()
        cv.addSubview(root)
        NSLayoutConstraint.activate([
            root.leadingAnchor.constraint(equalTo: cv.leadingAnchor),
            root.trailingAnchor.constraint(equalTo: cv.trailingAnchor),
            root.topAnchor.constraint(equalTo: cv.topAnchor),
            root.bottomAnchor.constraint(lessThanOrEqualTo: cv.bottomAnchor)
        ])

        logWindow.contentView = cv
        refreshSavedDeviceUI()
        interactiveTutorialOverlay.attach(
            window: logWindow,
            prepareButton: prepareButton,
            chooseIPhoneButton: connectButton,
            source: "Bluetooth panel created"
        )
        logWindow.makeKeyAndOrderFront(nil)
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard sender === logWindow else { return true }
        appendLog("[Panel] close requested; hiding Bluetooth HID panel for reuse connected=\(isBluetoothHIDConnected)")
        InteractiveTutorialCoordinator.shared.returnToOpenKeyboardPanelIfBluetoothPanelClosed(
            isBluetoothConnected: isBluetoothHIDConnected,
            source: "Bluetooth HID panel close button"
        )
        sender.orderOut(nil)
        return false
    }

    private func wrappingLabel(_ text: String) -> NSTextField {
        let label = NSTextField(wrappingLabelWithString: text)
        label.font = .systemFont(ofSize: 14)
        label.textColor = .secondaryLabelColor
        return label
    }

    private func refreshSavedDeviceUI() {
        guard deviceInfoLabel != nil, reconnectButton != nil, forgetButton != nil else { return }
        if let addr = UserDefaults.standard.string(forKey: "savedDeviceAddress"),
           let name = UserDefaults.standard.string(forKey: "savedDeviceName") {
            if let device = IOBluetoothDevice(addressString: addr) {
                let paired = device.isPaired()
                let stabilizing = isPairingStabilizing(for: addr)
                let pairingState = paired ? "paired on Mac" : (stabilizing ? "finishing pairing" : "not paired on Mac")
                deviceInfoLabel.stringValue = "\(name) · \(addr) · \(pairingState)"
                reconnectButton?.isEnabled = classicManagerReady && (paired || stabilizing)
                forgetButton.isEnabled = true
                let reconnectEnabled = reconnectButton?.isEnabled ?? false
                appendLog("[SavedDevice] refresh name=\(name) address=\(addr) macPaired=\(paired) stabilizing=\(stabilizing) reconnectEnabled=\(reconnectEnabled)")
            } else {
                appendLog("[SavedDevice] invalid saved address=\(addr); clearing local saved device")
                clearSavedDevice(reason: "invalid saved address")
            }
        } else {
            deviceInfoLabel.stringValue = "No saved iPhone yet"
            reconnectButton?.isEnabled = false
            forgetButton.isEnabled = false
        }
    }

    @objc private func forgetSavedDeviceTapped() {
        clearSavedDevice(reason: "user tapped Forget")
    }

    private func clearSavedDevice(reason: String) {
        let oldAddress = UserDefaults.standard.string(forKey: "savedDeviceAddress") ?? "<none>"
        let oldName = UserDefaults.standard.string(forKey: "savedDeviceName") ?? "<none>"
        UserDefaults.standard.removeObject(forKey: "savedDeviceAddress")
        UserDefaults.standard.removeObject(forKey: "savedDeviceName")
        appendLog("[SavedDevice] cleared reason=\(reason) oldName=\(oldName) oldAddress=\(oldAddress)")
        removeRetainedPairingPeerIfMatching(address: oldAddress == "<none>" ? nil : oldAddress, reason: "saved device cleared: \(reason)")
        clearPostPairingPrepareReset(address: oldAddress == "<none>" ? nil : oldAddress, reason: "saved device cleared: \(reason)")
        cancelPairingStabilization(reason: "saved device cleared: \(reason)")
        if deviceInfoLabel != nil {
            deviceInfoLabel.stringValue = "No saved iPhone yet"
        }
        reconnectButton?.isEnabled = false
        forgetButton?.isEnabled = false
    }

    private func saveDeviceForReconnect(address: String, name: String, source: String) {
        let trimmedAddress = address.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedAddress = btNormalizedClassicAddressCandidates(from: trimmedAddress).first ?? trimmedAddress
        let normalizedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedAddress.isEmpty else {
            appendLog("[SavedDevice] refusing to save empty address source=\(source) name=\(name)")
            return
        }

        UserDefaults.standard.set(normalizedAddress, forKey: "savedDeviceAddress")
        UserDefaults.standard.set(normalizedName.isEmpty ? normalizedAddress : normalizedName, forKey: "savedDeviceName")
        appendLog("[SavedDevice] saved source=\(source) name=\(normalizedName.isEmpty ? normalizedAddress : normalizedName) rawAddress=\(trimmedAddress) address=\(normalizedAddress)")
        InteractiveTutorialCoordinator.shared.recordSavedBluetoothDevicePresent(
            source: "Bluetooth saved device \(source)"
        )
        refreshSavedDeviceUI()
    }

    private func addressesMatch(_ left: String?, _ right: String?) -> Bool {
        let leftCandidates = btNormalizedClassicAddressCandidates(from: left)
        let rightCandidates = btNormalizedClassicAddressCandidates(from: right)
        guard !leftCandidates.isEmpty, !rightCandidates.isEmpty else { return false }
        return leftCandidates.contains { rightCandidates.contains($0) }
    }

    private func normalizedAddressKeys(_ address: String?) -> [String] {
        btNormalizedClassicAddressCandidates(from: address).map { $0.lowercased() }
    }

    private func markNeedsPostPairingPrepareReset(address: String, reason: String) {
        let keys = normalizedAddressKeys(address)
        guard !keys.isEmpty else {
            appendLog("[BTPrepare] post-pairing reset mark skipped reason=\(reason): no normalized keys raw=\(address)")
            return
        }

        for key in keys {
            postPairingPrepareResetKeys.insert(key)
        }
        appendLog("[BTPrepare] post-pairing reset marked reason=\(reason) address=\(address) keys=\(keys)")
    }

    private func clearPostPairingPrepareReset(address: String?, reason: String) {
        if let pending = pendingConnectAfterPrepareReset,
           address == nil || address.map({ addressesMatch(pending.address, $0) }) == true {
            pendingConnectAfterPrepareReset = nil
            appendLog("[BTPrepare] cleared pending post-pairing reset connect reason=\(reason) address=\(address ?? "<all>") attempt=\(pending.attemptID)")
        }

        guard !postPairingPrepareResetKeys.isEmpty else {
            appendLog("[BTPrepare] no post-pairing reset keys to clear reason=\(reason)")
            return
        }

        guard let address else {
            let count = postPairingPrepareResetKeys.count
            postPairingPrepareResetKeys.removeAll()
            appendLog("[BTPrepare] cleared all post-pairing reset keys reason=\(reason) count=\(count)")
            return
        }

        let keys = normalizedAddressKeys(address)
        var removed = 0
        for key in keys {
            if postPairingPrepareResetKeys.remove(key) != nil {
                removed += 1
            }
        }
        appendLog("[BTPrepare] cleared post-pairing reset keys reason=\(reason) address=\(address) keys=\(keys) removed=\(removed)")
    }

    private func consumePostPairingPrepareResetIfNeeded(address: String, source: String) -> Bool {
        let keys = normalizedAddressKeys(address)
        let shouldReset = keys.contains { postPairingPrepareResetKeys.contains($0) }
        appendLog("[BTPrepare] post-pairing reset lookup source=\(source) address=\(address) keys=\(keys) shouldReset=\(shouldReset)")
        guard shouldReset else { return false }

        for key in keys {
            postPairingPrepareResetKeys.remove(key)
        }
        return true
    }

    private func rememberPairingPeer(from note: Notification, address: String, source: String) {
        guard Thread.isMainThread else {
            runOnMain("rememberPairingPeer") { [weak self] in
                self?.rememberPairingPeer(from: note, address: address, source: source)
            }
            return
        }

        guard let peer = note.userInfo?["peer"] as? NSObject else {
            let keys = note.userInfo?.keys.map { String(describing: $0) } ?? []
            appendLog("[PairingPeer] no peer object in notification source=\(source) address=\(address) keys=\(keys)")
            return
        }

        let peerLogger: BTDiagnosticLogger = { [weak self] message in
            self?.appendLog("[PairingPeer] \(message)")
        }
        let addressKeys = normalizedAddressKeys(address)
        let peerKeys = btClassicPeerAddressCandidates(peer, log: peerLogger).map { $0.lowercased() }
        let allKeys = Array(Set(addressKeys + peerKeys))
        guard !allKeys.isEmpty else {
            appendLog("[PairingPeer] refusing to retain peer without address keys source=\(source) peer=\(peer)")
            return
        }

        if !addressKeys.isEmpty, !peerKeys.isEmpty, Set(addressKeys).isDisjoint(with: Set(peerKeys)) {
            appendLog("[PairingPeer] retained peer address mismatch source=\(source) notification=\(addressKeys) peer=\(peerKeys); storing by notification address for first-connect recovery")
        }

        for key in allKeys {
            retainedPairingPeersByAddress[key] = peer
        }
        appendLog("[PairingPeer] retained peer source=\(source) address=\(address) keys=\(allKeys) peer=\(peer)")
    }

    private func retainedPairingPeer(for address: String, source: String) -> NSObject? {
        let keys = normalizedAddressKeys(address)
        guard !keys.isEmpty else {
            appendLog("[PairingPeer] lookup skipped source=\(source): address has no normalized keys raw=\(address)")
            return nil
        }

        for key in keys {
            if let peer = retainedPairingPeersByAddress[key] {
                appendLog("[PairingPeer] lookup hit source=\(source) address=\(address) key=\(key) peer=\(peer)")
                return peer
            }
        }

        appendLog("[PairingPeer] lookup miss source=\(source) address=\(address) keys=\(keys)")
        return nil
    }

    @discardableResult
    private func attachClassicPeerIfAvailable(to device: IOBluetoothDevice, address: String, source: String) -> Bool {
        let peerLogger: BTDiagnosticLogger = { [weak self] message in
            self?.appendLog("[PairingPeer] \(message)")
        }

        if let retainedPeer = retainedPairingPeer(for: address, source: source) {
            appendLog("[PairingPeer] attempting retained peer attachment source=\(source) address=\(address)")
            guard btClassicPeerMatches(retainedPeer, expectedAddress: address, log: peerLogger) else {
                appendLog("[PairingPeer] retained peer rejected because address did not match source=\(source) address=\(address)")
                return attachResolvedClassicPeer(to: device, address: address, source: "\(source)-retained-mismatch", log: peerLogger)
            }

            let attached = btAttachClassicPeer(retainedPeer, to: device, log: peerLogger)
            appendLog("[PairingPeer] retained peer attachment result source=\(source) address=\(address) attached=\(attached)")
            return attached
        }

        appendLog("[PairingPeer] no retained peer available source=\(source) address=\(address); trying coordinator lookup")
        return attachResolvedClassicPeer(to: device, address: address, source: "\(source)-coordinator", log: peerLogger)
    }

    private func attachResolvedClassicPeer(
        to device: IOBluetoothDevice,
        address: String,
        source: String,
        log peerLogger: BTDiagnosticLogger
    ) -> Bool {
        guard let coordinator = btClassicCoordinator(log: peerLogger) else {
            appendLog("[PairingPeer] coordinator lookup failed source=\(source) address=\(address)")
            return false
        }

        guard let peer = btResolveClassicPeer(for: device, coordinator: coordinator, log: peerLogger) else {
            appendLog("[PairingPeer] coordinator peer lookup failed source=\(source) address=\(address)")
            return false
        }

        let attached = btAttachClassicPeer(peer, to: device, log: peerLogger)
        appendLog("[PairingPeer] coordinator peer attachment result source=\(source) address=\(address) attached=\(attached)")
        return attached
    }

    private func removeRetainedPairingPeerIfMatching(address: String?, reason: String) {
        guard !retainedPairingPeersByAddress.isEmpty else {
            appendLog("[PairingPeer] no retained peers to remove reason=\(reason)")
            return
        }

        guard let address else {
            let count = retainedPairingPeersByAddress.count
            retainedPairingPeersByAddress.removeAll()
            appendLog("[PairingPeer] removed all retained peers reason=\(reason) count=\(count)")
            return
        }

        let keys = normalizedAddressKeys(address)
        guard !keys.isEmpty else {
            appendLog("[PairingPeer] retained peer removal skipped reason=\(reason): no normalized keys raw=\(address)")
            return
        }

        var removed = 0
        for key in keys {
            if retainedPairingPeersByAddress.removeValue(forKey: key) != nil {
                removed += 1
            }
        }
        appendLog("[PairingPeer] removed retained peers reason=\(reason) address=\(address) keys=\(keys) removed=\(removed)")
    }

    private func isPairingStabilizing(for address: String) -> Bool {
        guard let pairingStabilizationAddress else { return false }
        guard CACurrentMediaTime() < pairingStabilizationDeadline else { return false }
        return addressesMatch(pairingStabilizationAddress, address)
    }

    private func cancelPairingStabilization(reason: String) {
        guard pairingStabilizationAddress != nil else { return }
        appendLog("[Pairing] stabilization cancelled reason=\(reason) address=\(pairingStabilizationAddress ?? "<none>") attempt=\(pairingStabilizationAttemptID)")
        pairingStabilizationAttemptID += 1
        pairingStabilizationAddress = nil
        pairingStabilizationDeadline = 0
    }

    private func connectWhenPairingIsReady(address: String, name: String, source: String) {
        guard Thread.isMainThread else {
            runOnMain("connectWhenPairingIsReady") { [weak self] in
                self?.connectWhenPairingIsReady(address: address, name: name, source: source)
            }
            return
        }

        guard let device = IOBluetoothDevice(addressString: address) else {
            appendLog("[Pairing] connect readiness failed source=\(source): invalid address=\(address)")
            clearSavedDeviceIfMatching(address: address, reason: "connect readiness invalid address")
            return
        }

        let paired = device.isPaired()
        let stabilizing = isPairingStabilizing(for: address)
        appendLog("[Pairing] connect readiness source=\(source) name=\(name) address=\(address) paired=\(paired) stabilizing=\(stabilizing) connected=\(device.isConnected()) classicReady=\(classicManagerReady)")

        if paired {
            if !device.isConnected() {
                let peerReady = attachClassicPeerIfAvailable(to: device, address: address, source: "connect-readiness-\(source)")
                appendLog("[Pairing] connect readiness peer check source=\(source) address=\(address) peerReady=\(peerReady)")
                guard peerReady else {
                    appendLog("[Pairing] paired record visible but classic peer is not ready source=\(source); waiting before first HID connect")
                    beginPairingStabilization(address: address, name: name, source: "\(source)-peer-wait", autoConnect: true)
                    return
                }
            } else {
                appendLog("[Pairing] connect readiness peer check skipped source=\(source): ACL already connected")
            }

            if stabilizing {
                cancelPairingStabilization(reason: "pairing became ready before connect source=\(source)")
                refreshSavedDeviceUI()
            }
            connectToAddress(address, name: name)
            return
        }

        if stabilizing {
            beginPairingStabilization(address: address, name: name, source: "\(source)-connect-wait", autoConnect: true)
            return
        }

        connectToAddress(address, name: name)
    }

    private func beginPairingStabilization(address: String, name: String, source: String, autoConnect: Bool) {
        guard Thread.isMainThread else {
            runOnMain("beginPairingStabilization") { [weak self] in
                self?.beginPairingStabilization(address: address, name: name, source: source, autoConnect: autoConnect)
            }
            return
        }

        pairingStabilizationAttemptID += 1
        let attemptID = pairingStabilizationAttemptID
        pairingStabilizationAddress = address
        pairingStabilizationDeadline = CACurrentMediaTime() + pairingStabilizationTimeout

        appendLog("[Pairing] stabilization started source=\(source) attempt=\(attemptID) name=\(name) address=\(address) autoConnect=\(autoConnect) timeout=\(String(format: "%.1f", pairingStabilizationTimeout))s interval=\(String(format: "%.1f", pairingStabilizationPollInterval))s")
        statusLabel?.stringValue = "Finishing Bluetooth pairing…"
        statusLabel?.textColor = .controlAccentColor
        if autoConnect {
            instructionLabel?.stringValue = "macOS is finalizing the Bluetooth pairing. Specchio will connect as soon as the paired record is available."
        } else if isDeviceSelectorSheetOpen {
            instructionLabel?.stringValue = "macOS is finalizing the Bluetooth pairing. Select the iPhone in the Bluetooth selector to open the HID connection."
        } else {
            instructionLabel?.stringValue = "macOS is finalizing the Bluetooth pairing. Specchio captured the device and is waiting for the next connect action."
        }
        appendLog("[Pairing] stabilization UI mode source=\(source) attempt=\(attemptID) autoConnect=\(autoConnect) selectorOpen=\(isDeviceSelectorSheetOpen)")
        refreshSavedDeviceUI()
        checkPairingStabilization(address: address, name: name, attemptID: attemptID, pollIndex: 0, autoConnect: autoConnect, source: source)
    }

    private func checkPairingStabilization(
        address: String,
        name: String,
        attemptID: Int,
        pollIndex: Int,
        autoConnect: Bool,
        source: String
    ) {
        guard Thread.isMainThread else {
            runOnMain("checkPairingStabilization") { [weak self] in
                self?.checkPairingStabilization(address: address, name: name, attemptID: attemptID, pollIndex: pollIndex, autoConnect: autoConnect, source: source)
            }
            return
        }

        guard pairingStabilizationAttemptID == attemptID else {
            appendLog("[Pairing] stabilization check ignored stale attempt=\(attemptID) current=\(pairingStabilizationAttemptID)")
            return
        }

        guard let savedAddress = UserDefaults.standard.string(forKey: "savedDeviceAddress"),
              addressesMatch(savedAddress, address) else {
            appendLog("[Pairing] stabilization stopped attempt=\(attemptID): saved device changed saved=\(UserDefaults.standard.string(forKey: "savedDeviceAddress") ?? "<none>") target=\(address)")
            cancelPairingStabilization(reason: "saved device changed during stabilization")
            refreshSavedDeviceUI()
            return
        }

        let now = CACurrentMediaTime()
        let remaining = max(0, pairingStabilizationDeadline - now)
        let device = IOBluetoothDevice(addressString: address)
        let paired = device?.isPaired() ?? false
        let connected = device?.isConnected() ?? false
        let classicPeerReady: Bool
        if paired, let device, !connected {
            classicPeerReady = attachClassicPeerIfAvailable(to: device, address: address, source: "stabilization-\(source)-poll-\(pollIndex)")
        } else if connected {
            classicPeerReady = true
            appendLog("[Pairing] stabilization peer check skipped attempt=\(attemptID) poll=\(pollIndex): ACL already connected")
        } else {
            classicPeerReady = false
            appendLog("[Pairing] stabilization peer check skipped attempt=\(attemptID) poll=\(pollIndex): paired=\(paired) deviceObject=\(device != nil)")
        }
        appendLog("[Pairing] stabilization check attempt=\(attemptID) poll=\(pollIndex) source=\(source) paired=\(paired) connected=\(connected) deviceObject=\(device != nil) classicReady=\(classicManagerReady) classicPeerReady=\(classicPeerReady) remaining=\(String(format: "%.1f", remaining))s")

        if paired, classicPeerReady {
            pairingStabilizationAddress = nil
            pairingStabilizationDeadline = 0
            appendLog("[Pairing] stabilization complete attempt=\(attemptID) polls=\(pollIndex) address=\(address) autoConnect=\(autoConnect)")
            statusLabel?.stringValue = "Pairing complete"
            statusLabel?.textColor = .systemGreen
            instructionLabel?.stringValue = autoConnect ? "Pairing is ready. Specchio is opening the HID connection." : "Pairing is ready. Press Connect to open the HID connection."
            refreshSavedDeviceUI()
            if autoConnect {
                guard classicManagerReady else {
                    appendLog("[Pairing] auto-connect deferred after stabilization because Bluetooth is not ready")
                    return
                }
                connectToAddress(address, name: name)
            }
            return
        }

        if paired {
            appendLog("[Pairing] paired record is visible but classic peer is not ready attempt=\(attemptID) poll=\(pollIndex); continuing stabilization")
            statusLabel?.stringValue = "Preparing first Bluetooth connection…"
            statusLabel?.textColor = .controlAccentColor
            instructionLabel?.stringValue = "Pairing is complete. Specchio is waiting for macOS to expose the Bluetooth peer needed for the first HID connection."
        }

        guard now < pairingStabilizationDeadline else {
            pairingStabilizationAddress = nil
            pairingStabilizationDeadline = 0
            appendLog("[Pairing] stabilization timed out attempt=\(attemptID) address=\(address); keeping saved device but not treating isPaired=false as a crash path")
            statusLabel?.stringValue = "Bluetooth pairing is not ready"
            statusLabel?.textColor = .systemOrange
            instructionLabel?.stringValue = "macOS has not finalized the pairing yet. Try Connect again shortly, or restart Specchio if this state persists."
            failActiveBluetoothAutoConnectIfNeeded(
                message: "Bluetooth unavailable",
                detail: "Pairing is not ready",
                reason: "pairing stabilization timed out address=\(address) attempt=\(attemptID)"
            )
            refreshSavedDeviceUI()
            return
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + pairingStabilizationPollInterval) { [weak self] in
            self?.checkPairingStabilization(
                address: address,
                name: name,
                attemptID: attemptID,
                pollIndex: pollIndex + 1,
                autoConnect: autoConnect,
                source: source
            )
        }
    }

    private func pairingAddress(from note: Notification) -> String? {
        guard let address = note.userInfo?["address"] as? String else { return nil }
        let trimmed = address.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private func pairingName(from note: Notification, fallbackAddress: String) -> String {
        guard let name = note.userInfo?["name"] as? String else { return fallbackAddress }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? fallbackAddress : trimmed
    }

    private func handlePairingCompleted(_ note: Notification) {
        guard Thread.isMainThread else {
            runOnMain("handlePairingCompleted") { [weak self] in
                self?.handlePairingCompleted(note)
            }
            return
        }

        guard let address = pairingAddress(from: note) else {
            appendLog("[Pairing] completed notification missing address userInfo=\(note.userInfo ?? [:])")
            return
        }

        let name = pairingName(from: note, fallbackAddress: address)
        let shouldAutoConnect = classicManagerReady && !isDeviceSelectorSheetOpen
        appendLog("[Pairing] completed notification name=\(name) address=\(address) classicReady=\(classicManagerReady) selectorOpen=\(isDeviceSelectorSheetOpen) autoConnect=\(shouldAutoConnect)")
        rememberPairingPeer(from: note, address: address, source: "pairing-completed-notification")
        saveDeviceForReconnect(address: address, name: name, source: "pairing-completed-notification")
        statusLabel?.stringValue = "Pairing complete"
        statusLabel?.textColor = .systemGreen
        if isDeviceSelectorSheetOpen {
            pairingCompletedDuringCurrentSelector = (address: address, name: name)
            instructionLabel?.stringValue = "Pairing completed. Select the iPhone in the Bluetooth selector to open the HID connection."
            appendLog("[Pairing] auto-connect deferred because selector sheet is still open")
            appendLog("[BTPrepare] automatic post-pairing preparation reset skipped; manual Reset remains available")
        } else {
            instructionLabel?.stringValue = "Pairing completed. Specchio is waiting for macOS to finalize the paired device record."
        }
        beginPairingStabilization(address: address, name: name, source: "pairing-completed-notification", autoConnect: shouldAutoConnect)
    }

    private func handlePairingFailed(_ note: Notification) {
        guard Thread.isMainThread else {
            runOnMain("handlePairingFailed") { [weak self] in
                self?.handlePairingFailed(note)
            }
            return
        }

        let address = pairingAddress(from: note)
        appendLog("[Pairing] failed notification address=\(address ?? "<unknown>") error=\(note.userInfo?["error"] ?? "<none>")")
        removeRetainedPairingPeerIfMatching(address: address, reason: "pairing failed")
        clearPostPairingPrepareReset(address: address, reason: "pairing failed")
        clearSavedDeviceIfMatching(address: address, reason: "pairing failed")
        statusLabel?.stringValue = "Pairing failed"
        statusLabel?.textColor = .systemRed
    }

    private func handlePeerUnpaired(_ note: Notification) {
        guard Thread.isMainThread else {
            runOnMain("handlePeerUnpaired") { [weak self] in
                self?.handlePeerUnpaired(note)
            }
            return
        }

        let address = pairingAddress(from: note)
        appendLog("[Pairing] unpaired notification address=\(address ?? "<unknown>")")
        removeRetainedPairingPeerIfMatching(address: address, reason: "peer unpaired")
        clearPostPairingPrepareReset(address: address, reason: "peer unpaired")
        clearSavedDeviceIfMatching(address: address, reason: "peer unpaired")
    }

    private func clearSavedDeviceIfMatching(address: String?, reason: String) {
        guard let savedAddress = UserDefaults.standard.string(forKey: "savedDeviceAddress") else {
            appendLog("[SavedDevice] no saved device to clear for \(reason)")
            return
        }

        guard let address else {
            clearSavedDevice(reason: "\(reason); notification had no address")
            return
        }

        let matches = addressesMatch(savedAddress, address)
        appendLog("[SavedDevice] clear-if-matching reason=\(reason) saved=\(savedAddress) event=\(address) matches=\(matches)")
        if matches {
            clearSavedDevice(reason: reason)
        }
    }

    @objc private func toggleAdvancedLogs() {
        isAdvancedLogVisible = advancedLogButton.state == .on
        appendLog("[BTFlow] advancedLogsVisible=\(isAdvancedLogVisible)")
        logScrollView.isHidden = !isAdvancedLogVisible
        logActionsStack.isHidden = !isAdvancedLogVisible
        if isAdvancedLogVisible {
            refreshVisibleLogView()
        }
        logWindow.layoutIfNeeded()
    }

    @objc private func copyLogs() {
        let text = logBuffer.joined()
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        appendLog("[BTFlow] copiedLogs length=\(text.count)")
    }

    @objc private func saveLogs() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "Specchio-Bluetooth-\(Int(Date().timeIntervalSince1970)).log"
        panel.allowedContentTypes = [.plainText]
        panel.beginSheetModal(for: logWindow) { [weak self] response in
            guard let self else { return }
            guard response == .OK, let url = panel.url else {
                self.appendLog("[BTFlow] saveLogs cancelled")
                return
            }
            do {
                try self.logBuffer.joined().write(to: url, atomically: true, encoding: .utf8)
                self.appendLog("[BTFlow] savedLogs url=\(url.path)")
            } catch {
                self.appendLog("[BTFlow] saveLogs error=\(error.localizedDescription)")
            }
        }
    }

    /// Creates a generic test button for mouse testing.
    @discardableResult
    private func addMouseButton(to view: NSView, title: String, action: Selector, x: CGFloat, y: CGFloat, w: CGFloat, h: CGFloat) -> CGFloat {
        let btn = NSButton(title: title, target: self, action: action)
        btn.frame = NSRect(x: x, y: y, width: w, height: h)
        btn.bezelStyle = .rounded
        btn.font = .systemFont(ofSize: 10)
        btn.isEnabled = false
        btn.tag = 99  // tag 99 = mouse test button
        view.addSubview(btn)
        specialKeyButtons.append(btn)  // reuse same array for enable/disable
        return x + w
    }

    // MARK: - Mouse Test Actions (no CGEvent tap needed)

    @objc private func testMouseClick() {
        appendLog("[MouseTest] Sending left click (press + release)")
        sendMouseReport(buttons: 0x01, dx: 0, dy: 0, dz: 0, wheel: 0)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            self?.sendMouseReport(buttons: 0x00, dx: 0, dy: 0, dz: 0, wheel: 0)
        }
    }

    @objc private func testMouseMoveLeft() {
        appendLog("[MouseTest] Sending move left dx=-20")
        sendMouseReport(buttons: 0, dx: -20, dy: 0, dz: 0, wheel: 0)
    }

    @objc private func testMouseMoveRight() {
        appendLog("[MouseTest] Sending move right dx=+20")
        sendMouseReport(buttons: 0, dx: 20, dy: 0, dz: 0, wheel: 0)
    }

    @objc private func testMouseMoveUp() {
        appendLog("[MouseTest] Sending move up dy=-20")
        sendMouseReport(buttons: 0, dx: 0, dy: -20, dz: 0, wheel: 0)
    }

    @objc private func testMouseMoveDown() {
        appendLog("[MouseTest] Sending move down dy=+20")
        sendMouseReport(buttons: 0, dx: 0, dy: 20, dz: 0, wheel: 0)
    }

    @objc private func testMouseScroll() {
        appendLog("[MouseTest] Sending scroll down wheel=-3")
        sendMouseReport(buttons: 0, dx: 0, dy: 0, dz: 0, wheel: -3)
    }

    @objc private func testMouseJiggle() {
        appendLog("[MouseTest] Sending jiggle sequence (5 moves)")
        let moves: [(Int8, Int8)] = [(10, 0), (-10, 0), (0, 10), (0, -10), (5, 5)]
        for (i, (dx, dy)) in moves.enumerated() {
            DispatchQueue.main.asyncAfter(deadline: .now() + Double(i) * 0.1) { [weak self] in
                self?.sendMouseReport(buttons: 0, dx: dx, dy: dy, dz: 0, wheel: 0)
                self?.appendLog("[MouseTest] Jiggle step \(i): dx=\(dx) dy=\(dy)")
            }
        }
    }

    /// Creates a special key button, adds it to the view, tracks it, and returns the right edge x position.
    @discardableResult
    private func addSpecialKeyButton(to view: NSView, title: String, bit: Int, x: CGFloat, y: CGFloat, w: CGFloat, h: CGFloat) -> CGFloat {
        let btn = NSButton(title: title, target: self, action: #selector(specialKeyTapped(_:)))
        btn.frame = NSRect(x: x, y: y, width: w, height: h)
        btn.tag = bit
        btn.bezelStyle = .rounded
        btn.font = .systemFont(ofSize: 10)
        btn.isEnabled = false
        view.addSubview(btn)
        specialKeyButtons.append(btn)
        return x + w
    }

    // MARK: - Step 1: Prepare (initialize CBClassicManager before selector)

    @objc private func prepareTapped() {
        guard Thread.isMainThread else {
            runOnMain("prepareTapped") { [weak self] in
                self?.prepareTapped()
            }
            return
        }

        appendLog("[BTUI] prepareTapped mainThread=\(Thread.isMainThread)")
        InteractiveTutorialCoordinator.shared.recordTargetAction(
            .bluetoothPrepareButton,
            source: "Bluetooth panel Prepare Bluetooth button"
        )
        statusLabel?.stringValue = "Preparing Bluetooth…"
        statusLabel?.textColor = .controlAccentColor
        instructionLabel?.stringValue = "Keep your iPhone nearby. When preparation finishes, choose your iPhone from the Bluetooth selector."
        progressIndicator?.startAnimation(nil)
        appendLog("Step 1: Initializing Bluetooth...")
        prepareButton.isEnabled = false
        connectButton?.isEnabled = false
        reconnectButton?.isEnabled = false

        startBluetoothPreparationRuntime(reason: "prepareTapped")
        appendLog("  (Click 'Connect Device' when you see 'READY')")
        appendLog("")
    }

    @objc private func resetPrepareTapped() {
        guard Thread.isMainThread else {
            runOnMain("resetPrepareTapped") { [weak self] in
                self?.resetPrepareTapped()
            }
            return
        }

        appendLog("[BTUI] resetPrepareTapped mainThread=\(Thread.isMainThread)")
        pendingConnectAfterPrepareReset = nil
        clearPostPairingPrepareReset(address: nil, reason: "manual reset button")
        cancelPairingStabilization(reason: "manual Bluetooth preparation reset")
        resetBluetoothPreparationRuntime(reason: "manual reset button")

        progressIndicator?.stopAnimation(nil)
        statusLabel?.stringValue = "Bluetooth preparation reset"
        statusLabel?.textColor = .secondaryLabelColor
        instructionLabel?.stringValue = "Press Prepare Bluetooth to initialize Bluetooth again."
        prepareButton.isEnabled = true
        connectButton?.isEnabled = false
        refreshSavedDeviceUI()
        appendLog("[BTPrepare] manual reset complete; waiting for Prepare Bluetooth")
    }

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        guard let activeCentralManager = centralManager, central === activeCentralManager else {
            appendLog("[BTPrepare] ignored CBCentralManager state from stale manager state=\(central.state.rawValue)")
            return
        }

        appendLog("  CBCentralManager state: \(central.state.rawValue) (5=poweredOn)")
        if central.state == .poweredOn {
            classicManagerReady = preparedBluetoothSDPPublished
            appendLog("[BTPrepare] poweredOn readiness evaluated sdpPublished=\(preparedBluetoothSDPPublished) classicReady=\(classicManagerReady)")
            runOnMain("centralManagerDidUpdateState ready UI") { [weak self] in
                guard let self else { return }
                self.progressIndicator?.stopAnimation(nil)
                if self.preparedBluetoothSDPPublished {
                    self.statusLabel?.stringValue = "Bluetooth is ready"
                    self.statusLabel?.textColor = .systemGreen
                    self.instructionLabel?.stringValue = "Now open Bluetooth Settings on the iPhone, select this Mac, then choose the same iPhone here."
                } else {
                    self.statusLabel?.stringValue = "Bluetooth preparation failed"
                    self.statusLabel?.textColor = .systemRed
                    self.instructionLabel?.stringValue = "Specchio could not publish the Bluetooth HID service record. Press Prepare Bluetooth again."
                    self.pendingConnectAfterPrepareReset = nil
                    self.failActiveBluetoothAutoConnectIfNeeded(
                        message: "Bluetooth unavailable",
                        detail: "Bluetooth preparation failed",
                        reason: "centralManager poweredOn without SDP"
                    )
                }
                self.connectButton?.isEnabled = self.preparedBluetoothSDPPublished
                if self.preparedBluetoothSDPPublished {
                    InteractiveTutorialCoordinator.shared.recordBluetoothPrepared(
                        source: "Bluetooth central powered on with SDP"
                    )
                }
                self.refreshSavedDeviceUI()
                if let stabilizingAddress = self.pairingStabilizationAddress,
                   let savedAddress = UserDefaults.standard.string(forKey: "savedDeviceAddress"),
                   self.addressesMatch(stabilizingAddress, savedAddress),
                   self.preparedBluetoothSDPPublished {
                    let savedName = UserDefaults.standard.string(forKey: "savedDeviceName") ?? savedAddress
                    self.appendLog("[Pairing] Bluetooth became ready while pairing stabilization is active; enabling auto-connect address=\(savedAddress)")
                    self.beginPairingStabilization(address: savedAddress, name: savedName, source: "bluetooth-ready-after-pairing", autoConnect: true)
                }
                if let pending = self.pendingConnectAfterPrepareReset {
                    guard self.preparedBluetoothSDPPublished else {
                        self.appendLog("[BTPrepare] post-pairing reset connect cancelled attempt=\(pending.attemptID): SDP is not published")
                        self.pendingConnectAfterPrepareReset = nil
                        return
                    }
                    guard pending.attemptID == self.postPairingPrepareResetAttemptID else {
                        self.appendLog("[BTPrepare] post-pairing reset connect ignored stale attempt=\(pending.attemptID) current=\(self.postPairingPrepareResetAttemptID)")
                        self.pendingConnectAfterPrepareReset = nil
                        return
                    }
                    self.pendingConnectAfterPrepareReset = nil
                    self.appendLog("[BTPrepare] post-pairing reset complete attempt=\(pending.attemptID); starting HID connect source=\(pending.source) address=\(pending.address)")
                    self.connectWhenPairingIsReady(address: pending.address, name: pending.name, source: "\(pending.source)-after-prepare-reset")
                }
                self.continuePendingBluetoothAutoConnectAfterPrepareIfNeeded(reason: "central manager powered on")
            }
            appendLog("")
            if preparedBluetoothSDPPublished {
                appendLog("  *** READY — Click 'Connect Device' now ***")
            } else {
                appendLog("[BTPrepare] READY withheld because SDP is not published")
            }
            appendLog("")
        } else {
            classicManagerReady = false
            runOnMain("centralManagerDidUpdateState not ready UI") { [weak self] in
                guard let self else { return }
                self.statusLabel?.stringValue = "Waiting for Bluetooth…"
                self.statusLabel?.textColor = .controlAccentColor
                self.connectButton?.isEnabled = false
                self.refreshSavedDeviceUI()
            }
        }
    }

    private func startBluetoothPreparationRuntime(reason: String) {
        guard Thread.isMainThread else {
            runOnMain("startBluetoothPreparationRuntime") { [weak self] in
                self?.startBluetoothPreparationRuntime(reason: reason)
            }
            return
        }

        classicManagerReady = false
        preparedBluetoothSDPPublished = false
        appendLog("[BTPrepare] starting Bluetooth preparation runtime reason=\(reason)")
        appendLog("  Creating CBCentralManager (triggers TCC + BLE power on)...")
        centralManager = CBCentralManager(delegate: self, queue: nil)

        controller = KeyPadController()
        let published = controller.publishSDP()
        preparedBluetoothSDPPublished = published
        appendLog("  SDP published: \(published)")
        appendLog("[BTPrepare] SDP publish result reason=\(reason) published=\(published)")
        registerIncomingHIDChannelNotifications(reason: reason)

        guard let host = IOBluetoothHostController.default() else {
            appendLog("[BTPrepare] device class skipped reason=\(reason): no host controller")
            return
        }

        controller.bluetoothHost = host
        host.setClassOfDevice(0x2540, forTimeInterval: 120)
        appendLog("  Device class set to 0x2540")
        appendLog("[BTPrepare] device class set reason=\(reason) class=0x2540")
        appendLog("  Waiting for Bluetooth to power on...")
    }

    private func resetBluetoothPreparationAfterPairing(address: String, name: String, source: String) {
        guard Thread.isMainThread else {
            runOnMain("resetBluetoothPreparationAfterPairing") { [weak self] in
                self?.resetBluetoothPreparationAfterPairing(address: address, name: name, source: source)
            }
            return
        }

        postPairingPrepareResetAttemptID += 1
        let attemptID = postPairingPrepareResetAttemptID
        pendingConnectAfterPrepareReset = (address: address, name: name, source: source, attemptID: attemptID)

        appendLog("[BTPrepare] post-pairing reset starting attempt=\(attemptID) source=\(source) name=\(name) address=\(address)")
        statusLabel?.stringValue = "Preparing Bluetooth again…"
        statusLabel?.textColor = .controlAccentColor
        instructionLabel?.stringValue = "Pairing is complete. Specchio is resetting Bluetooth preparation before opening the HID connection."
        progressIndicator?.startAnimation(nil)
        connectButton?.isEnabled = false
        reconnectButton?.isEnabled = false

        resetBluetoothPreparationRuntime(reason: "post-pairing reset attempt=\(attemptID)")
        startBluetoothPreparationRuntime(reason: "post-pairing reset attempt=\(attemptID)")
    }

    private func resetBluetoothPreparationRuntime(reason: String) {
        guard Thread.isMainThread else {
            runOnMain("resetBluetoothPreparationRuntime") { [weak self] in
                self?.resetBluetoothPreparationRuntime(reason: reason)
            }
            return
        }

        appendLog("[BTPrepare] resetting Bluetooth preparation runtime reason=\(reason)")
        resetTrackedConnectionState(reason: "Bluetooth preparation reset \(reason)", closeChannels: true, closeConnection: true)
        removeRetainedPairingPeerIfMatching(address: nil, reason: "Bluetooth preparation reset \(reason)")

        if let incomingControlNotification {
            incomingControlNotification.unregister()
            appendLog("[BTPrepare] unregistered incoming control listener reason=\(reason)")
        } else {
            appendLog("[BTPrepare] no incoming control listener to unregister reason=\(reason)")
        }
        incomingControlNotification = nil

        if let incomingInterruptNotification {
            incomingInterruptNotification.unregister()
            appendLog("[BTPrepare] unregistered incoming interrupt listener reason=\(reason)")
        } else {
            appendLog("[BTPrepare] no incoming interrupt listener to unregister reason=\(reason)")
        }
        incomingInterruptNotification = nil

        if let existingService = controller?.service {
            let removeResult = existingService.remove()
            appendLog("[BTPrepare] removed published SDP service reason=\(reason) result=\(removeResult)")
        } else {
            appendLog("[BTPrepare] no published SDP service to remove reason=\(reason)")
        }
        controller = nil
        preparedBluetoothSDPPublished = false
        classicManagerReady = false

        if let existingCentralManager = centralManager {
            appendLog("[BTPrepare] releasing CBCentralManager reason=\(reason) state=\(existingCentralManager.state.rawValue)")
            existingCentralManager.delegate = nil
        } else {
            appendLog("[BTPrepare] no CBCentralManager to release reason=\(reason)")
        }
        centralManager = nil

        resetBluetoothHIDProcessRuntime(reason: reason) { [weak self] message in
            self?.appendLog(message)
        }
    }

    private func registerIncomingHIDChannelNotifications(reason: String) {
        appendLog("[L2CAP] register incoming HID channel notifications reason=\(reason) controlRegistered=\(incomingControlNotification != nil) interruptRegistered=\(incomingInterruptNotification != nil)")

        if incomingControlNotification == nil {
            incomingControlNotification = IOBluetoothL2CAPChannel.register(
                forChannelOpenNotifications: self,
                selector: #selector(incomingHIDChannel(_:channel:)),
                withPSM: 17,
                direction: kIOBluetoothUserNotificationChannelDirectionIncoming
            )
            appendLog("[L2CAP] incoming control listener PSM 17 registered=\(incomingControlNotification != nil)")
        }

        if incomingInterruptNotification == nil {
            incomingInterruptNotification = IOBluetoothL2CAPChannel.register(
                forChannelOpenNotifications: self,
                selector: #selector(incomingHIDChannel(_:channel:)),
                withPSM: 19,
                direction: kIOBluetoothUserNotificationChannelDirectionIncoming
            )
            appendLog("[L2CAP] incoming interrupt listener PSM 19 registered=\(incomingInterruptNotification != nil)")
        }
    }

    @objc private func incomingHIDChannel(_ notification: IOBluetoothUserNotification, channel: IOBluetoothL2CAPChannel) {
        runOnMain("incomingHIDChannel") { [weak self] in
            self?.handleIncomingHIDChannel(notification, channel: channel)
        }
    }

    private func handleIncomingHIDChannel(_ notification: IOBluetoothUserNotification, channel: IOBluetoothL2CAPChannel) {
        let psm = channel.psm
        let device = channel.device
        let address = device?.addressString ?? "?"
        let name = device?.nameOrAddress ?? activeDeviceName ?? "?"
        appendLog("[L2CAP] incoming channel PSM \(psm) from \(name) [\(address)] mainThread=\(Thread.isMainThread)")

        guard let device else {
            appendLog("[L2CAP] incoming PSM \(psm) has no device; closing")
            channel.close()
            return
        }

        if activeDevice == nil {
            activeDevice = device
            activeDeviceName = name
            saveDeviceForReconnect(address: address, name: name, source: "incoming-l2cap-psm-\(psm)")
            appendLog("[L2CAP] incoming PSM \(psm) established active device from channel")
        } else if !isTrackedDevice(device) {
            appendLog("[L2CAP] incoming PSM \(psm) ignored from untracked device \(name) [\(address)]")
            channel.close()
            return
        }

        let delegateResult = channel.setDelegate(self)
        appendLog("[L2CAP] incoming PSM \(psm) setDelegate(self)=\(delegateResult)")

        if psm == 17 {
            if let existing = controlChannel, existing !== channel {
                appendLog("[L2CAP] replacing existing control channel \(describeL2CAPChannel(existing)) with incoming \(describeL2CAPChannel(channel))")
                existing.setDelegate(nil)
                existing.close()
            }
            pendingControlChannelOpen = false
            pendingControlChannel = nil
            controlChannel = channel
            appendLog("[L2CAP] Control channel ready from incoming \(describeL2CAPChannel(channel))")
        } else if psm == 19 {
            if let existing = interruptChannel, existing !== channel {
                appendLog("[L2CAP] replacing existing interrupt channel \(describeL2CAPChannel(existing)) with incoming \(describeL2CAPChannel(channel))")
                existing.setDelegate(nil)
                existing.close()
            }
            pendingInterruptChannelOpen = false
            pendingInterruptChannel = nil
            interruptChannel = channel
            appendLog("[L2CAP] Interrupt channel ready from incoming \(describeL2CAPChannel(channel))")
        } else {
            appendLog("[L2CAP] incoming unsupported PSM \(psm); closing")
            channel.close()
            return
        }

        finishConnectionIfReady(reason: "incoming L2CAP PSM \(psm)")
    }

    // MARK: - Step 2: Connect (show selector AFTER BT is ready)

    var deviceSelector: IOBluetoothDeviceSelectorController?
    private var isDeviceSelectorSheetOpen = false
    private var pairingCompletedDuringCurrentSelector: (address: String, name: String)?

    @objc private func connectTapped() {
        guard Thread.isMainThread else {
            runOnMain("connectTapped") { [weak self] in
                self?.connectTapped()
            }
            return
        }

        appendLog("[BTUI] connectTapped mainThread=\(Thread.isMainThread)")
        if !classicManagerReady {
            statusLabel?.stringValue = "Prepare Bluetooth first"
            statusLabel?.textColor = .systemOrange
            appendLog("ERROR: Click 'Prepare Bluetooth' first and wait for READY")
            return
        }
        guard !isDeviceSelectorSheetOpen else {
            appendLog("[BTUI] connectTapped ignored because the Bluetooth selector sheet is already open")
            return
        }

        InteractiveTutorialCoordinator.shared.recordTargetAction(
            .bluetoothChooseIPhoneButton,
            source: "Bluetooth panel Choose iPhone button"
        )
        pairingCompletedDuringCurrentSelector = nil
        clearSavedDevice(reason: "starting fresh selector flow")
        statusLabel?.stringValue = "Choose your iPhone"
        statusLabel?.textColor = .controlAccentColor
        instructionLabel?.stringValue = "In the system sheet, select the iPhone you paired from iOS Bluetooth settings."
        appendLog("Step 2: Opening device selector as SHEET...")
        appendLog("  On iPhone: Settings > Bluetooth")
        appendLog("")

        guard let selector = IOBluetoothDeviceSelectorController.deviceSelector() else {
            statusLabel?.stringValue = "Bluetooth selector unavailable"
            statusLabel?.textColor = .systemRed
            appendLog("[BTUI] ERROR: IOBluetoothDeviceSelectorController.deviceSelector() returned nil")
            return
        }

        isDeviceSelectorSheetOpen = true
        deviceSelector = selector
        selector.setTitle("Connect before pressing the Select Button")

        // Try as sheet on our window instead of runModal
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.appendLog("[BTUI] beginSheetModal dispatch mainThread=\(Thread.isMainThread)")
            let result = selector.beginSheetModal(
                for: self.logWindow,
                modalDelegate: self,
                didEnd: #selector(self.selectorSheetDidEnd(_:returnCode:contextInfo:)),
                contextInfo: nil
            )
            self.appendLog("beginSheetModal returned: \(result)")
            if result != kIOReturnSuccess {
                self.isDeviceSelectorSheetOpen = false
                self.pairingCompletedDuringCurrentSelector = nil
                self.statusLabel?.stringValue = "Bluetooth selector failed to open"
                self.statusLabel?.textColor = .systemRed
                self.appendLog("[BTUI] ERROR: beginSheetModal failed result=\(result)")
            }
        }
    }

    @objc func selectorSheetDidEnd(_ controller: IOBluetoothDeviceSelectorController, returnCode: Int32, contextInfo: UnsafeMutableRawPointer?) {
        guard Thread.isMainThread else {
            runOnMain("selectorSheetDidEnd") { [weak self, weak controller] in
                guard let controller else { return }
                self?.selectorSheetDidEnd(controller, returnCode: returnCode, contextInfo: contextInfo)
            }
            return
        }

        appendLog("[BTUI] selectorSheetDidEnd mainThread=\(Thread.isMainThread)")
        appendLog("Sheet ended with code: \(returnCode) (-1000=success)")
        isDeviceSelectorSheetOpen = false
        let justPairedDevice = pairingCompletedDuringCurrentSelector
        pairingCompletedDuringCurrentSelector = nil

        if returnCode == -1000, let results = controller.getResults() as? [IOBluetoothDevice] {
            for device in results {
                let name = device.name ?? "?"
                let addr = device.addressString ?? ""
                appendLog("Selected: \(name) (\(addr))")

                saveDeviceForReconnect(address: addr, name: name, source: "selector-success")
                runOnMain("selected device label") { [weak self] in
                    guard let self else { return }
                    self.refreshSavedDeviceUI()
                    self.statusLabel?.stringValue = "Connecting to \(name)…"
                    self.statusLabel?.textColor = .controlAccentColor
                }
                appendLog("Device selected for reconnection")
                InteractiveTutorialCoordinator.shared.recordBluetoothSelectorAccepted(
                    source: "Bluetooth selector accepted device"
                )

                if let justPairedDevice, addressesMatch(justPairedDevice.address, addr) {
                    appendLog("[BTPrepare] first pairing completed and selected; restart required before HID connect address=\(addr)")
                    showFirstPairingRestartAlert(address: addr, name: name)
                    return
                }

                if consumePostPairingPrepareResetIfNeeded(address: addr, source: "selector-success") {
                    resetBluetoothPreparationAfterPairing(address: addr, name: name, source: "selector-success")
                } else {
                    connectWhenPairingIsReady(address: addr, name: name, source: "selector-success")
                }
            }
        } else {
            if let savedAddress = UserDefaults.standard.string(forKey: "savedDeviceAddress") {
                let savedName = UserDefaults.standard.string(forKey: "savedDeviceName") ?? savedAddress
                appendLog("[BTUI] selector ended without selection, but a saved device exists from pairing/incoming flow name=\(savedName) address=\(savedAddress); selectorClosedAutoConnect=\(classicManagerReady)")
                if activeDevice == nil {
                    statusLabel?.stringValue = "Pairing captured"
                    statusLabel?.textColor = .controlAccentColor
                    instructionLabel?.stringValue = classicManagerReady
                        ? "Pairing was captured from the Bluetooth callback. Specchio is opening the HID connection now."
                        : "Pairing was captured from the Bluetooth callback. Prepare Bluetooth before reconnecting."
                }
                refreshSavedDeviceUI()
                if classicManagerReady {
                    appendLog("[BTUI] starting deferred saved-device connect after selector closed without selection")
                    if consumePostPairingPrepareResetIfNeeded(address: savedAddress, source: "selector-ended-saved-device") {
                        resetBluetoothPreparationAfterPairing(address: savedAddress, name: savedName, source: "selector-ended-saved-device")
                    } else {
                        connectWhenPairingIsReady(address: savedAddress, name: savedName, source: "selector-ended-saved-device")
                    }
                } else {
                    appendLog("[BTUI] deferred saved-device connect skipped because classicManagerReady=false")
                }
                return
            }
            statusLabel?.stringValue = "No device selected"
            statusLabel?.textColor = .secondaryLabelColor
            appendLog("No device selected")
        }
    }

    private func showFirstPairingRestartAlert(address: String, name: String) {
        guard Thread.isMainThread else {
            runOnMain("showFirstPairingRestartAlert") { [weak self] in
                self?.showFirstPairingRestartAlert(address: address, name: name)
            }
            return
        }

        statusLabel?.stringValue = "Restart required"
        statusLabel?.textColor = .systemOrange
        instructionLabel?.stringValue = "Pairing is complete. Restart Specchio before opening the Bluetooth HID connection."
        refreshSavedDeviceUI()

        appendLog("[BTPrepare] showing restart-required alert after first pairing name=\(name) address=\(address)")
        InteractiveTutorialCoordinator.shared.recordFirstPairingRestartAlertShown(
            source: "Bluetooth first pairing restart alert"
        )

        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = "Restart Specchio"
        alert.informativeText = "The first Bluetooth pairing is complete. Specchio needs to restart before it can open the HID connection."
        alert.addButton(withTitle: "Restart Specchio")
        alert.addButton(withTitle: "Later")

        let response = alert.runModal()
        appendLog("[BTPrepare] restart-required alert dismissed response=\(response.rawValue)")
        if response == .alertFirstButtonReturn {
            restartSpecchioAfterFirstPairing()
        }
    }

    private func restartSpecchioAfterFirstPairing() {
        let bundlePath = Bundle.main.bundlePath
        appendLog("[BTPrepare] restarting app after first Bluetooth pairing bundlePath=\(bundlePath)")

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = [
            "-c",
            "sleep 0.5; /usr/bin/open -n \"$1\"",
            "specchio-restart",
            bundlePath
        ]

        do {
            try process.run()
            NSApp.terminate(nil)
        } catch {
            appendLog("[BTPrepare] restart launch failed error=\(error.localizedDescription)")
            statusLabel?.stringValue = "Restart failed"
            statusLabel?.textColor = .systemRed
            instructionLabel?.stringValue = "Quit and reopen Specchio to continue with the Bluetooth HID connection."
        }
    }

    // MARK: - Step 3: Reconnect to saved device

    @objc private func reconnectTapped() {
        guard classicManagerReady else {
            statusLabel?.stringValue = "Prepare Bluetooth first"
            statusLabel?.textColor = .systemOrange
            appendLog("ERROR: Click 'Prepare Bluetooth' first")
            return
        }
        guard let addr = UserDefaults.standard.string(forKey: "savedDeviceAddress") else {
            statusLabel?.stringValue = "Choose an iPhone first"
            statusLabel?.textColor = .systemOrange
            appendLog("No saved device — use 'Connect Device' first")
            return
        }
        let name = UserDefaults.standard.string(forKey: "savedDeviceName") ?? addr
        statusLabel?.stringValue = "Connecting to \(name)…"
        statusLabel?.textColor = .controlAccentColor
        appendLog("Reconnecting to \(name)...")
        connectWhenPairingIsReady(address: addr, name: name, source: "reconnect-button")
    }

    private func connectToAddress(_ address: String, name: String) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.connectionAttemptID += 1
            let attemptID = self.connectionAttemptID
            self.appendLog("[Connect] Starting KeyPad-aligned connect for \(name) [\(address)]")
            self.appendLog("[Connect] Running on main thread = \(Thread.isMainThread) attempt=\(attemptID)")

            guard let device = IOBluetoothDevice(addressString: address) else {
                self.appendLog("[Connect] ERROR: Invalid address \(address)")
                self.clearSavedDeviceIfMatching(address: address, reason: "connect invalid saved address")
                self.failActiveBluetoothAutoConnectIfNeeded(
                    message: "Bluetooth unavailable",
                    detail: "Invalid paired device address",
                    reason: "connect invalid address \(address)"
                )
                return
            }

            if let previousDevice = self.activeDevice {
                let previousAddress = previousDevice.addressString ?? "?"
                let sameTarget = self.addressesMatch(previousAddress, address)
                self.appendLog("[Connect] Existing tracked device = \(self.activeDeviceName ?? previousDevice.nameOrAddress ?? "?") [\(previousAddress)] target=[\(address)] sameTarget=\(sameTarget)")
            } else {
                self.appendLog("[Connect] No existing tracked device")
            }

            let shouldCloseExistingConnection = !self.addressesMatch(self.activeDevice?.addressString, address)
            self.resetTrackedConnectionState(
                reason: "starting new connect attempt for \(name) [\(address)]",
                closeChannels: true,
                closeConnection: shouldCloseExistingConnection
            )

            self.activeDevice = device
            self.activeDeviceName = name
            self.sendButton?.isEnabled = false
            self.statusLabel?.stringValue = "Connecting to \(name)…"
            self.statusLabel?.textColor = .controlAccentColor

            self.appendLog("[Connect] Created IOBluetoothDevice for \(name) [\(address)]")
            let paired = device.isPaired()
            let stabilizing = self.isPairingStabilizing(for: address)
            self.appendLog("[Connect] device.isPaired = \(paired) stabilizing=\(stabilizing)")
            self.appendLog("[Connect] device.isConnected = \(device.isConnected())")
            self.logPeerState(device, prefix: "[Connect]")

            guard paired else {
                if stabilizing {
                    self.appendLog("[Connect] pairing record is not visible yet; waiting instead of clearing saved device")
                    self.statusLabel?.stringValue = "Finishing Bluetooth pairing…"
                    self.statusLabel?.textColor = .controlAccentColor
                    self.instructionLabel?.stringValue = "macOS is still finalizing this pairing. Specchio will connect automatically when it becomes available."
                    self.beginPairingStabilization(address: address, name: name, source: "connect-saw-unpaired-during-stabilization", autoConnect: true)
                    return
                }
                self.appendLog("[Connect] saved device is not paired on macOS; clearing local saved device")
                self.clearSavedDeviceIfMatching(address: address, reason: "connect target not paired on macOS")
                self.statusLabel?.stringValue = "Pair the iPhone again"
                self.statusLabel?.textColor = .systemOrange
                self.failActiveBluetoothAutoConnectIfNeeded(
                    message: "Bluetooth unavailable",
                    detail: "First device is not paired",
                    reason: "connect target not paired address=\(address)"
                )
                return
            }

            if !device.isConnected() {
                let peerReady = self.attachClassicPeerIfAvailable(to: device, address: address, source: "connect-start-attempt-\(attemptID)")
                self.appendLog("[Connect] classic peer readiness before ACL open attempt=\(attemptID) peerReady=\(peerReady)")
                guard peerReady else {
                    self.appendLog("[Connect] deferring ACL open because classic peer is not ready attempt=\(attemptID)")
                    self.statusLabel?.stringValue = "Preparing first Bluetooth connection…"
                    self.statusLabel?.textColor = .controlAccentColor
                    self.instructionLabel?.stringValue = "Pairing is complete. Specchio is waiting for macOS to expose the Bluetooth peer needed for the first HID connection."
                    self.beginPairingStabilization(address: address, name: name, source: "connect-start-peer-wait", autoConnect: true)
                    return
                }
            } else {
                self.appendLog("[Connect] classic peer readiness skipped before ACL open attempt=\(attemptID): device already connected")
            }

            if device.isConnected() {
                self.appendLog("[Connect] Device already ACL-connected; requesting control channel open next")
                self.requestControlChannelOpen(for: device, reason: "device already ACL-connected")
                return
            }

            let openResult = device.openConnection(self)
            self.appendLog("[Connect] device.openConnection(self) = \(openResult)")
            let connectedAfterOpen = device.isConnected()
            self.appendLog("[Connect] post-open device.isConnected = \(connectedAfterOpen) attempt=\(attemptID)")
            if openResult != kIOReturnSuccess {
                self.appendLog("[Connect] ERROR: openConnection(self) failed immediately; not falling back to manual peer connect because that diverges from KeyPad's path")
                self.logPeerState(device, prefix: "[Connect]")
                self.failActiveBluetoothAutoConnectIfNeeded(
                    message: "Bluetooth unavailable",
                    detail: "Connection failed",
                    reason: "openConnection returned \(openResult) address=\(address)"
                )
            } else if connectedAfterOpen {
                self.appendLog("[Connect] ACL connected immediately after openConnection; opening control channel without waiting for connectionComplete")
                self.requestControlChannelOpen(for: device, reason: "post-open connected attempt=\(attemptID)")
            } else {
                self.appendLog("[Connect] Waiting for connectionComplete callback before opening L2CAP attempt=\(attemptID)")
                self.scheduleConnectionCompleteTimeout(for: device, name: name, address: address, attemptID: attemptID)
            }
        }
    }

    private func scheduleConnectionCompleteTimeout(for device: IOBluetoothDevice, name: String, address: String, attemptID: Int) {
        appendLog("[Connect] scheduling connectionComplete timeout attempt=\(attemptID) delay=3.0s")
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) { [weak self, weak device] in
            guard let self else { return }
            guard self.connectionAttemptID == attemptID else {
                self.appendLog("[Connect] timeout ignored for stale attempt=\(attemptID) current=\(self.connectionAttemptID)")
                return
            }
            guard let device else {
                self.appendLog("[Connect] timeout fired but device object was released attempt=\(attemptID)")
                self.failActiveBluetoothAutoConnectIfNeeded(
                    message: "Bluetooth unavailable",
                    detail: "Device was released during connection",
                    reason: "connection timeout device released attempt=\(attemptID)"
                )
                return
            }
            guard self.isTrackedDevice(device) else {
                self.appendLog("[Connect] timeout ignored because device is no longer tracked attempt=\(attemptID)")
                self.failActiveBluetoothAutoConnectIfNeeded(
                    message: "Bluetooth unavailable",
                    detail: "Device changed during connection",
                    reason: "connection timeout tracked device changed attempt=\(attemptID)"
                )
                return
            }

            let connected = device.isConnected()
            self.appendLog("[Connect] timeout check attempt=\(attemptID) device.isConnected=\(connected) control=\(self.controlChannel != nil) interrupt=\(self.interruptChannel != nil)")
            if connected {
                self.requestControlChannelOpen(for: device, reason: "timeout observed connected attempt=\(attemptID)")
                return
            }

            self.statusLabel?.stringValue = "Connecting to \(name)…"
            self.statusLabel?.textColor = .controlAccentColor
            self.appendLog("[Connect] no connectionComplete and ACL is still down; invoking direct peer-backed connect fallback attempt=\(attemptID)")
            let preferredPeer = self.retainedPairingPeer(for: address, source: "connection-fallback-attempt-\(attemptID)")

            self.connectionFallbackQueue.async { [weak self, weak device] in
                guard let self, let device else { return }
                let fallbackLogger: BTDiagnosticLogger = { [weak self] message in
                    self?.appendLog("[ConnectFallback] \(message)")
                }
                let success = btConnectDeviceViaClassicPeer(device, preferredPeer: preferredPeer, pollCount: 12, pollIntervalUsec: 250_000, log: fallbackLogger)
                DispatchQueue.main.async { [weak self, weak device] in
                    guard let self else { return }
                    guard self.connectionAttemptID == attemptID else {
                        self.appendLog("[ConnectFallback] result ignored for stale attempt=\(attemptID) current=\(self.connectionAttemptID)")
                        return
                    }
                    guard let device else {
                        self.appendLog("[ConnectFallback] result ignored because device was released attempt=\(attemptID)")
                        return
                    }
                    self.appendLog("[ConnectFallback] completed attempt=\(attemptID) success=\(success) device.isConnected=\(device.isConnected())")
                    if success || device.isConnected() {
                        self.requestControlChannelOpen(for: device, reason: "peer-backed timeout fallback attempt=\(attemptID)")
                    } else {
                        self.statusLabel?.stringValue = "Bluetooth connection timed out"
                        self.statusLabel?.textColor = .systemRed
                        self.appendLog("[Connect] ERROR: connection did not complete for \(name) [\(address)]")
                        self.failActiveBluetoothAutoConnectIfNeeded(
                            message: "Bluetooth unavailable",
                            detail: "Connection timed out",
                            reason: "peer-backed fallback failed name=\(name) address=\(address) attempt=\(attemptID)"
                        )
                    }
                }
            }
        }
    }

    // MARK: - Step 4: Send keystrokes

    @objc private func sendTapped() {
        guard let text = sendField?.stringValue, !text.isEmpty else { return }
        guard interruptChannel != nil else {
            appendLog("No interrupt channel — connect first")
            return
        }
        guard canForwardUserHIDInput(source: "Manual text") else {
            appendLog("[InputGate] Manual text send ignored because ReplayKit broadcast is not live")
            return
        }

        appendLog("Sending: \(text)")
        sendField.stringValue = ""
        sendButton?.isEnabled = false

        let chars = Array(text)
        var delay: TimeInterval = 0
        for char in chars {
            guard let (code, mod) = Self.charToHID(char) else { continue }
            // Key down
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                guard let self, self.canForwardUserHIDInput(source: "Manual text keyDown") else { return }
                guard let channel = self.interruptChannel else { return }
                var press: [UInt8] = [0xA1, 0x01, mod, 0x00, code, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00]
                channel.writeAsync(&press, length: UInt16(press.count), refcon: nil)
            }
            delay += 0.03
            // Key up
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                guard let self, self.canForwardUserHIDInput(source: "Manual text keyUp") else { return }
                guard let channel = self.interruptChannel else { return }
                var release: [UInt8] = [0xA1, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00]
                channel.writeAsync(&release, length: UInt16(release.count), refcon: nil)
            }
            delay += 0.05
        }
        // Re-enable send button after all characters sent
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            self?.appendLog("Sent \(chars.count) characters")
            if self?.interruptChannel != nil {
                self?.sendButton?.isEnabled = true
            }
        }
    }

    // MARK: - Special Keys (Consumer Control)

    @objc private func specialKeyTapped(_ sender: NSButton) {
        let bit = UInt8(sender.tag)
        appendLog("[Consumer] Button tapped: \(sender.title) (bit \(bit))")
        sendConsumerControl(bit: bit)
    }

    private func sendConsumerControl(bit: UInt8, source: String = "Consumer", bypassInputGate: Bool = false) {
        guard let channel = interruptChannel else {
            appendLog("[Consumer] \(source) no interrupt channel — not connected")
            return
        }
        guard bypassInputGate || canForwardUserHIDInput(source: source) else {
            appendLog("[InputGate] \(source) consumer control bit \(bit) ignored because ReplayKit broadcast is not live")
            return
        }
        if bypassInputGate {
            appendLog("[InputGate] \(source) consumer control bypassing ReplayKit gate bit=\(bit) reason=EasyAutoUnlock")
        }

        let value: UInt16 = 1 << UInt16(bit)
        appendLog("[Consumer] \(source) sending consumer control bit \(bit) value=0x\(String(format: "%04X", value))")

        // Press
        var press: [UInt8] = [0xA1, 0x02, UInt8(value & 0xFF), UInt8(value >> 8)]
        let pressResult = channel.writeAsync(&press, length: UInt16(press.count), refcon: nil)
        if pressResult != kIOReturnSuccess {
            appendLog("[Consumer] Press writeAsync failed: \(pressResult)")
        }

        // Release after 50ms (on main thread to avoid concurrent writes)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            guard let self else { return }
            guard bypassInputGate || self.canForwardUserHIDInput(source: "\(source) release") else { return }
            if bypassInputGate {
                self.appendLog("[InputGate] \(source) release bypassing ReplayKit gate reason=EasyAutoUnlock")
            }
            guard let channel = self.interruptChannel else { return }
            var release: [UInt8] = [0xA1, 0x02, 0x00, 0x00]
            let releaseResult = channel.writeAsync(&release, length: UInt16(release.count), refcon: nil)
            if releaseResult != kIOReturnSuccess {
                self.appendLog("[Consumer] Release writeAsync failed: \(releaseResult)")
            }
        }
    }

    // MARK: - Live Keystroke Monitoring

    private func startKeyMonitoring() {
        guard Thread.isMainThread else {
            runOnMain("startKeyMonitoring") { [weak self] in
                self?.startKeyMonitoring()
            }
            return
        }

        guard keyEventMonitor == nil else {
            appendLog("[KeyMonitor] Already active")
            return
        }

        appendLog("[KeyMonitor] Starting live keystroke capture")
        appendLog("[KeyMonitor] Focus the Easy window and type — keystrokes forward to device")
        refreshInputGateStatusLabels(reason: "startKeyMonitoring")

        keyEventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp]) { [weak self] event in
            guard let self else { return event }
            guard self.interruptChannel != nil else { return event }
            guard self.canForwardUserHIDInput(source: "Keyboard") else { return event }
            guard self.shouldForwardInputEvent(event, source: "Keyboard") else { return event }

            if let responder = self.targetInputWindow?.firstResponder,
               responder is NSTextView,
               responder !== self.logView {
                return event
            }

            let keyCode = event.keyCode

            // Consumer control keys (volume/mute from keyboard hardware keys)
            if let consumerBit = Self.macKeyToConsumerBit[keyCode] {
                if event.type == .keyDown {
                    self.sendConsumerControl(bit: consumerBit)
                }
                return nil
            }

            guard let hidCode = Self.macKeyToHID[keyCode] else {
                self.appendLog("[KeyMonitor] Unmapped macOS keyCode=0x\(String(format: "%02X", keyCode))")
                return nil
            }

            if event.type == .keyDown {
                self.pressedHIDKeys.insert(hidCode)
            } else {
                self.pressedHIDKeys.remove(hidCode)
            }

            let modifiers = Self.modifierByteFromFlags(event.modifierFlags)
            self.sendKeyboardReport(modifiers: modifiers)

            return nil
        }

        flagsEventMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            guard let self else { return event }
            guard self.interruptChannel != nil else { return event }
            guard self.canForwardUserHIDInput(source: "Flags") else { return event }
            guard self.shouldForwardInputEvent(event, source: "Flags") else { return event }

            if let responder = self.targetInputWindow?.firstResponder,
               responder is NSTextView,
               responder !== self.logView {
                return event
            }

            let modifiers = Self.modifierByteFromFlags(event.modifierFlags)
            self.sendKeyboardReport(modifiers: modifiers)

            return event
        }
    }

    private func stopKeyMonitoring() {
        guard Thread.isMainThread else {
            runOnMain("stopKeyMonitoring") { [weak self] in
                self?.stopKeyMonitoring()
            }
            return
        }

        // Send all-keys-released report before stopping, so remote device doesn't have stuck keys
        if !pressedHIDKeys.isEmpty || keyEventMonitor != nil {
            if let channel = interruptChannel {
                var release: [UInt8] = [0xA1, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00]
                channel.writeAsync(&release, length: UInt16(release.count), refcon: nil)
                appendLog("[KeyMonitor] Sent all-keys-released report")
            }
        }

        if let monitor = keyEventMonitor {
            NSEvent.removeMonitor(monitor)
            keyEventMonitor = nil
        }
        if let monitor = flagsEventMonitor {
            NSEvent.removeMonitor(monitor)
            flagsEventMonitor = nil
        }
        pressedHIDKeys.removeAll()

        keystrokeStatusLabel?.stringValue = "Live keys: not connected"
        keystrokeStatusLabel?.textColor = .secondaryLabelColor
        appendLog("[KeyMonitor] Stopped")
    }

    // MARK: - Mouse Passthrough

    @objc private func mouseToggleTapped() {
        if mousePassthroughEnabled {
            stopMousePassthrough()
        } else {
            startMousePassthrough()
        }
    }

    private func startMousePassthrough() {
        guard Thread.isMainThread else {
            runOnMain("startMousePassthrough") { [weak self] in
                self?.startMousePassthrough()
            }
            return
        }

        guard interruptChannel != nil else {
            appendLog("[Mouse] No interrupt channel — connect first")
            return
        }

        appendLog("[Mouse] Starting relative NSEvent monitor for mouse passthrough")
        appendLog("[Mouse] Input mode clutchEnabled=\(easyMouseClutchModeEnabled)")
        appendLog("[TrackpadSwipeDrag] mouse monitor starting enabled=\(trackpadSwipeToDragEnabled) mode=\(trackpadSwipeToDragMode) phase=\(trackpadSwipeDragPhase.rawValue)")
        appendLog("[PointerTransport] activeVariant=\(easyPointerSpikeVariant) spikeEnabled=\(easyPointerSpikeEnabled) absoluteMouseReport=\(absolutePointerTransportEnabled) absoluteReportID=\(Self.absolutePointerReportID)")
        if easyMouseClutchModeEnabled {
            appendLog("[Mouse] Movement clutch enabled: hold right mouse button to forward movement; left button clicks only")
        } else {
            appendLog("[Mouse] Continuous movement enabled: pointer deltas forward immediately; right button stays suppressed locally")
        }

        mouseLocalMonitor = NSEvent.addLocalMonitorForEvents(matching: [
            .mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged,
            .leftMouseDown, .leftMouseUp,
            .rightMouseDown, .rightMouseUp,
            .otherMouseDown, .otherMouseUp,
            .scrollWheel
        ]) { [weak self] event in
            guard let self, self.mousePassthroughEnabled, self.interruptChannel != nil else { return event }
            guard self.canForwardUserHIDInput(source: "Mouse") else { return event }
            guard self.shouldForwardInputEvent(event, source: "Mouse") else { return event }
            self.handleNSEvent(event)
            return event  // keep the Mac UI interactive while forwarding to iPhone
        }

        mousePassthroughEnabled = true
        mouseEventCount = 0
        mouseReportCount = 0
        mouseWriteCompletionCount = 0
        queueSpaceAvailableCount = 0
        interruptWritesInFlight = 0
        mouseStatsWindowStartedAt = CACurrentMediaTime()
        mouseEventsAtWindowStart = 0
        mouseReportsAtWindowStart = 0
        mouseWriteCompletionsAtWindowStart = 0
        mouseToggleBtn?.title = "Mouse: ON"
        mouseToggleBtn?.contentTintColor = .systemGreen
        refreshInputGateStatusLabels(reason: "startMousePassthrough")
    }

    private func shouldForwardInputEvent(_ event: NSEvent, source: String) -> Bool {
        guard let targetInputWindow else {
            inputEventDropCount += 1
            if inputEventDropCount <= 5 || inputEventDropCount % 100 == 0 {
                appendLog("[InputSurface] \(source) drop: Easy input window is not bound eventWindow=\(event.window?.windowNumber ?? -1)")
            }
            return false
        }

        guard event.window === targetInputWindow else {
            inputEventDropCount += 1
            if inputEventDropCount <= 5 || inputEventDropCount % 100 == 0 {
                appendLog("[InputSurface] \(source) drop: eventWindow=\(event.window?.windowNumber ?? -1) targetWindow=\(targetInputWindow.windowNumber) targetKey=\(targetInputWindow.isKeyWindow)")
            }
            return false
        }

        guard targetInputWindow.isKeyWindow else {
            inputEventDropCount += 1
            if inputEventDropCount <= 5 || inputEventDropCount % 100 == 0 {
                appendLog("[InputSurface] \(source) drop: Easy input window is not key targetWindow=\(targetInputWindow.windowNumber)")
            }
            return false
        }

        if inputEventDropCount != 0 {
            appendLog("[InputSurface] \(source) forwarding resumed after drops=\(inputEventDropCount)")
            inputEventDropCount = 0
        }
        return true
    }

    private func stopMousePassthrough() {
        guard Thread.isMainThread else {
            runOnMain("stopMousePassthrough") { [weak self] in
                self?.stopMousePassthrough()
            }
            return
        }

        if let monitor = mouseLocalMonitor {
            NSEvent.removeMonitor(monitor)
            mouseLocalMonitor = nil
        }

        // Send mouse-all-released before stopping
        if interruptChannel != nil && mousePassthroughEnabled {
            sendAllPointerButtonsReleased(reason: "stopMousePassthrough")
        }

        mousePassthroughEnabled = false
        mouseButtonState = 0
        isMouseMovementClutched = false
        isRightMousePressed = false
        isLeftMousePressedForSwipe = false
        didCurrentLeftPressBecomeDrag = false
        isDragGestureInProgress = false
        isSwipeButtonDownOnPhone = false
        mouseDeltaRemainderX = 0
        mouseDeltaRemainderY = 0
        mouseToggleBtn?.title = "Mouse: OFF"
        mouseToggleBtn?.contentTintColor = nil
        maybeLogMousePerformance(force: true, reason: "stop")
        if interruptChannel != nil {
            mouseStatusLabel?.stringValue = "Mouse passthrough: disabled"
        } else {
            mouseStatusLabel?.stringValue = "Mouse passthrough: not connected"
        }
        mouseStatusLabel?.textColor = .secondaryLabelColor
        appendLog("[Mouse] Stopped (captured \(mouseEventCount) events, sent \(mouseReportCount) reports)")
    }

    private func handleNSEvent(_ event: NSEvent) {
        mouseEventCount += 1
        maybeLogMousePerformance(reason: "event")
        let shouldLog = mouseEventCount <= 5 || mouseEventCount % 100 == 0
        let movementForwardingEnabled = easyPointerSpikeEnabled ? isRightMousePressed : self.movementForwardingEnabled

        switch event.type {
        case .mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged:
            let isAbsoluteLeftDragEvent = absolutePointerTransportEnabled && event.type == .leftMouseDragged && isLeftMousePressedForSwipe
            guard movementForwardingEnabled || isAbsoluteLeftDragEvent else {
                if shouldLog {
                    appendLog("[Mouse] Event #\(mouseEventCount): move ignored because right-button clutch is not active clutchEnabled=\(easyMouseClutchModeEnabled) absoluteLeftDrag=\(isAbsoluteLeftDragEvent)")
                }
                return
            }

            if absolutePointerTransportEnabled {
                let allowClampedMapping = isAbsoluteLeftDragEvent || (isDragGestureInProgress && isLeftMousePressedForSwipe)
                guard let mapping = pointerInputMapping(for: event, allowClampedOutOfBounds: allowClampedMapping) else {
                    appendLog("[PointerABS] movement ignored: no valid input mapping eventType=\(event.type.rawValue) absoluteLeftDrag=\(isAbsoluteLeftDragEvent) allowClamped=\(allowClampedMapping)")
                    return
                }

                if isAbsoluteLeftDragEvent && !isDragGestureInProgress {
                    beginAbsoluteLeftDragIfNeeded(mapping: mapping, trigger: "leftMouseDragged")
                } else if isLeftMousePressedForSwipe && isRightMousePressed && !isDragGestureInProgress {
                    appendLog("[PointerABS] Event #\(mouseEventCount): drag armed on movement because both buttons are down")
                    startDragGestureIfNeeded(mapping: mapping, trigger: "movement-both-buttons")
                }

                if isLeftMousePressedForSwipe && !isDragGestureInProgress {
                    if shouldLog {
                        appendLog("[PointerABS] Event #\(mouseEventCount): movement ignored because left button is down but no drag sequence is active")
                    }
                    return
                }

                let dragActive = isDragGestureInProgress && isLeftMousePressedForSwipe && isSwipeButtonDownOnPhone
                let forwardedButtons: UInt8 = dragActive ? 0x01 : 0x00
                postPointerFeedback(kind: dragActive ? "dragMoveAbsolute" : "clutchMoveAbsolute", point: mapping.phonePoint)
                appendLog(
                    "[PointerABS] movement event #\(mouseEventCount) " +
                    "window=\(InputSurfaceDiagnostics.pointString(mapping.eventLocationInWindow)) " +
                    "local=\(InputSurfaceDiagnostics.pointString(mapping.localPoint)) " +
                    "phoneTopLeft=\(InputSurfaceDiagnostics.pointString(mapping.phonePoint)) " +
                    "buttons=\(forwardedButtons) dragActive=\(dragActive) absoluteLeftDrag=\(isAbsoluteLeftDragEvent) clamped=\(mapping.wasClampedToSurface)"
                )
                sendAbsolutePointerReport(
                    point: mapping.phonePoint,
                    buttons: forwardedButtons,
                    reason: dragActive ? "dragMoveAbsolute" : "clutchMoveAbsolute"
                )
                return
            }

            if isLeftMousePressedForSwipe && isRightMousePressed && !isDragGestureInProgress {
                appendLog("[Mouse] Event #\(mouseEventCount): drag armed on movement because both buttons are down")
                startDragGestureIfNeeded(mapping: nil, trigger: "movement-both-buttons")
            }
            if isLeftMousePressedForSwipe && !isDragGestureInProgress {
                if shouldLog {
                    appendLog("[Mouse] Event #\(mouseEventCount): move ignored because left button is down without drag modifier")
                }
                return
            }

            let rawMouseDelta = CGPoint(x: event.deltaX, y: event.deltaY)
            let rotatedMouseDelta = rotatedRelativePointerDelta(rawMouseDelta)
            guard rawMouseDelta.x.isFinite,
                  rawMouseDelta.y.isFinite,
                  rotatedMouseDelta.x.isFinite,
                  rotatedMouseDelta.y.isFinite,
                  pointerTransportScaleX.isFinite,
                  pointerTransportScaleY.isFinite,
                  abs(pointerTransportScaleX) > .ulpOfOne,
                  abs(pointerTransportScaleY) > .ulpOfOne else {
                appendLog("[Mouse] Event #\(mouseEventCount): movement dropped because delta or scale is non-finite raw=\(InputSurfaceDiagnostics.pointString(rawMouseDelta)) rotated=\(InputSurfaceDiagnostics.pointString(rotatedMouseDelta)) rotation=\(inputSurfaceRotationDegrees) scale=(\(pointerTransportScaleX),\(pointerTransportScaleY))")
                return
            }
            let dx = rotatedMouseDelta.x / pointerTransportScaleX
            let dy = rotatedMouseDelta.y / pointerTransportScaleY
            if dx != 0 || dy != 0 {
                let dragActive = isDragGestureInProgress && isLeftMousePressedForSwipe && isRightMousePressed
                let forwardedButtons: UInt8 = dragActive ? 0x01 : 0x00
                lastPointerReportDelta = CGPoint(x: dx, y: dy)
                calibrationReportDeltaSinceLastSample.x += dx
                calibrationReportDeltaSinceLastSample.y += dy
                virtualPointerPoint.x = min(max(virtualPointerPoint.x + (dx * pointerTransportScaleX), 0), pointerSurfaceSize.width)
                virtualPointerPoint.y = min(max(virtualPointerPoint.y + (dy * pointerTransportScaleY), 0), pointerSurfaceSize.height)
                postPointerFeedback(kind: dragActive ? "dragMove" : "clutchMove", point: virtualPointerPoint)
                if shouldLog {
                    appendLog("[Mouse] Event #\(mouseEventCount): move raw=\(InputSurfaceDiagnostics.pointString(rawMouseDelta)) rotated=\(InputSurfaceDiagnostics.pointString(rotatedMouseDelta)) rotation=\(inputSurfaceRotationDegrees) report=(\(dx),\(dy)) virtual=\(InputSurfaceDiagnostics.pointString(virtualPointerPoint)) dragActive=\(dragActive) forwardedButtons=\(forwardedButtons) clutchEnabled=\(easyMouseClutchModeEnabled) clutchLatched=\(isMouseMovementClutched) rightPressed=\(isRightMousePressed)")
                    recordInputSurfaceDiagnostic(
                        event: "relativeMouseDeltaMapped",
                        reason: dragActive ? "drag-move" : "clutch-move",
                        details: [
                            "rawDelta": InputSurfaceDiagnostics.pointString(rawMouseDelta),
                            "rotatedDelta": InputSurfaceDiagnostics.pointString(rotatedMouseDelta),
                            "reportDX": FrameDropDiagnostics.format(Double(dx), digits: 4),
                            "reportDY": FrameDropDiagnostics.format(Double(dy), digits: 4),
                            "virtualPointer": InputSurfaceDiagnostics.pointString(virtualPointerPoint),
                            "dragActive": String(dragActive),
                            "forwardedButtons": String(forwardedButtons),
                            "clutchEnabled": String(easyMouseClutchModeEnabled),
                            "clutchLatched": String(isMouseMovementClutched),
                            "rightPressed": String(isRightMousePressed),
                            "transportScaleX": FrameDropDiagnostics.format(Double(pointerTransportScaleX), digits: 4),
                            "transportScaleY": FrameDropDiagnostics.format(Double(pointerTransportScaleY), digits: 4)
                        ]
                    )
                }
                if dragActive, !isSwipeButtonDownOnPhone {
                    isSwipeButtonDownOnPhone = true
                    isDragGestureInProgress = true
                    sendMouseReport(buttons: 0x01, dx: 0, dy: 0, dz: 0, wheel: 0)
                    appendLog("[Mouse] Drag button DOWN before movement")
                }
                sendMouseDeltaWithRemainder(dx: dx, dy: dy, buttons: forwardedButtons, reason: dragActive ? "dragMove" : "clutchMove")
            }

        case .leftMouseDown:
            isLeftMousePressedForSwipe = true
            didCurrentLeftPressBecomeDrag = false
            mouseButtonState |= 0x01
            lastPointerReportDelta = .zero
            let mapping = pointerInputMapping(for: event)
            let shouldStartDrag = isRightMousePressed && movementForwardingEnabled

            if shouldStartDrag {
                startDragGestureIfNeeded(mapping: mapping, trigger: "leftMouseDown")
            } else {
                if let mapping {
                    capturePointerSpikeAttemptIfNeeded(event: event, mapping: mapping)
                    positionPointerForDeterministicTapIfNeeded(mapping: mapping, trigger: "leftMouseDown")
                } else if easyPointerSpikeEnabled {
                    appendLog("[PointerSpike] leftDown has no valid input mapping for tap positioning")
                }
                sendPointerButtonReport(buttons: 0x01, mapping: mapping, reason: "tap-button-down")
                if absolutePointerTransportEnabled {
                    isSwipeButtonDownOnPhone = true
                    appendLog("[PointerABS] primary button DOWN tracked for possible click-or-drag")
                }
                appendLog("[Mouse] Tap button DOWN")
            }
            appendLog("[Mouse] Event #\(mouseEventCount): left DOWN btns=\(mouseButtonState) clutchEnabled=\(easyMouseClutchModeEnabled) clutchLatched=\(isMouseMovementClutched) rightPressed=\(isRightMousePressed) movementForwarding=\(movementForwardingEnabled) dragStart=\(shouldStartDrag) dragInProgress=\(isDragGestureInProgress)")

        case .leftMouseUp:
            let wasDragSequence = didCurrentLeftPressBecomeDrag
            isLeftMousePressedForSwipe = false
            mouseButtonState &= ~0x01
            lastPointerReportDelta = .zero
            let mapping = pointerInputMapping(for: event, allowClampedOutOfBounds: wasDragSequence && absolutePointerTransportEnabled)

            if wasDragSequence {
                appendLog("[Mouse] left UP ending drag sequence dragInProgress=\(isDragGestureInProgress)")
                finishDragGestureIfNeeded(trigger: "leftMouseUp", mapping: mapping)
            } else {
                updatePendingPointerSpikeAttemptOnMouseUpIfNeeded(event: event)
                if let mapping {
                    postPointerFeedback(kind: "tap", point: mapping.phonePoint)
                } else {
                    appendLog("[Mouse] left UP could not map tap point from input surface")
                }
                sendPointerButtonReport(buttons: 0x00, mapping: mapping, reason: "tap-button-up")
                if absolutePointerTransportEnabled {
                    isSwipeButtonDownOnPhone = false
                    appendLog("[PointerABS] primary button UP tracked for tap release")
                }
                appendLog("[Mouse] Tap button UP")
            }

            didCurrentLeftPressBecomeDrag = false
            isDragGestureInProgress = false
            appendLog("[Mouse] Event #\(mouseEventCount): left UP btns=\(mouseButtonState) clutchEnabled=\(easyMouseClutchModeEnabled) clutchLatched=\(isMouseMovementClutched) rightPressed=\(isRightMousePressed) movementForwarding=\(movementForwardingEnabled) dragSequence=\(wasDragSequence)")

        case .rightMouseDown:
            isRightMousePressed = true
            mouseButtonState &= ~0x02
            lastPointerReportDelta = .zero
            mouseDeltaRemainderX = 0
            mouseDeltaRemainderY = 0

            if easyMouseClutchModeEnabled {
                isMouseMovementClutched = true
            }

            let mapping = pointerInputMapping(for: event)
            if let mapping {
                realignPointerToCurrentMouseLocationIfNeeded(mapping: mapping, trigger: "rightMouseDown")
                if !deterministicPointerPositioningEnabled {
                    virtualPointerPoint = mapping.phonePoint
                }
                postPointerFeedback(kind: "clutchStart", point: virtualPointerPoint)
            } else {
                appendLog("[Mouse] right DOWN has no valid input mapping for manual realignment")
            }

            appendLog("[Mouse] Event #\(mouseEventCount): right DOWN suppressed locally clutchEnabled=\(easyMouseClutchModeEnabled) clutchLatched=\(isMouseMovementClutched) rightPressed=\(isRightMousePressed) movementForwarding=\(self.movementForwardingEnabled) dragInProgress=\(isDragGestureInProgress)")

        case .rightMouseUp:
            isRightMousePressed = false
            mouseButtonState &= ~0x02
            if easyMouseClutchModeEnabled {
                isMouseMovementClutched = false
            }
            if isDragGestureInProgress {
                let mapping = pointerInputMapping(for: event, allowClampedOutOfBounds: absolutePointerTransportEnabled)
                finishDragGestureIfNeeded(trigger: "rightMouseUp", mapping: mapping)
            }
            mouseDeltaRemainderX = 0
            mouseDeltaRemainderY = 0
            lastPointerReportDelta = .zero
            postPointerFeedback(kind: "clutchEnd", point: virtualPointerPoint)
            appendLog("[Mouse] Event #\(mouseEventCount): right UP suppressed locally clutchEnabled=\(easyMouseClutchModeEnabled) clutchLatched=\(isMouseMovementClutched) rightPressed=\(isRightMousePressed) movementForwarding=\(self.movementForwardingEnabled) dragInProgress=\(isDragGestureInProgress)")

        case .scrollWheel:
            if handleTrackpadSwipeToDragIfNeeded(event) {
                return
            }

            let scrollDelta = event.scrollingDeltaY
            guard scrollDelta.isFinite else {
                appendLog("[Mouse] Event #\(mouseEventCount): scroll ignored because delta is non-finite raw=\(scrollDelta)")
                return
            }
            if scrollDelta != 0 {
                let inverted = -scrollDelta
                let boundedWheelDelta = max(CGFloat(Int8.min), min(CGFloat(Int8.max), inverted))
                if shouldLog {
                    appendLog("[Mouse] Event #\(mouseEventCount): scroll raw=\(scrollDelta) inv=\(inverted) bounded=\(boundedWheelDelta)")
                }
                sendMouseReport(buttons: mouseButtonState, dx: 0, dy: 0, dz: 0,
                                wheel: Int8(clamping: Int(boundedWheelDelta.rounded(.towardZero))))
            }

        default:
            if shouldLog {
                appendLog("[Mouse] Ignoring event type=\(event.type.rawValue)")
            }
            break
        }
    }

    private func handleTrackpadSwipeToDragIfNeeded(_ event: NSEvent) -> Bool {
        guard trackpadSwipeToDragEnabled else {
            if trackpadSwipeDragPhase != .idle || trackpadSwipeDragSyntheticButtonDown {
                cancelTrackpadSwipeDrag(reason: "setting-disabled-during-scroll")
                return true
            }
            rejectTrackpadSwipeToDrag(
                event: event,
                reason: "experiment-disabled",
                fallbackWheel: true
            )
            return false
        }

        guard event.type == .scrollWheel else {
            rejectTrackpadSwipeToDrag(
                event: event,
                reason: "not-scroll-wheel",
                fallbackWheel: false
            )
            return false
        }

        guard let targetInputWindow else {
            rejectTrackpadSwipeToDrag(
                event: event,
                reason: "missing-target-window",
                fallbackWheel: true
            )
            return false
        }

        guard event.window === targetInputWindow else {
            rejectTrackpadSwipeToDrag(
                event: event,
                reason: "event-window-mismatch",
                fallbackWheel: true
            )
            return false
        }

        guard targetInputWindow.isKeyWindow else {
            rejectTrackpadSwipeToDrag(
                event: event,
                reason: "target-window-not-key",
                fallbackWheel: true
            )
            return false
        }

        guard interruptChannel != nil else {
            rejectTrackpadSwipeToDrag(
                event: event,
                reason: "interrupt-channel-missing",
                fallbackWheel: true
            )
            return false
        }

        guard replayKitInputForwardingEnabled else {
            rejectTrackpadSwipeToDrag(
                event: event,
                reason: "input-gate-closed",
                fallbackWheel: true
            )
            return false
        }

        guard event.scrollingDeltaX.isFinite, event.scrollingDeltaY.isFinite else {
            rejectTrackpadSwipeToDrag(
                event: event,
                reason: "non-finite-delta",
                fallbackWheel: true
            )
            return false
        }

        guard let mapping = pointerInputMapping(for: event) else {
            rejectTrackpadSwipeToDrag(
                event: event,
                reason: "outside-video-surface",
                fallbackWheel: true
            )
            return false
        }

        recordTrackpadSwipeDiagnostic(
            event: "eventReceived",
            reason: "scroll-wheel",
            sourceEvent: event,
            mapping: mapping
        )

        guard event.hasPreciseScrollingDeltas else {
            rejectTrackpadSwipeToDrag(
                event: event,
                reason: "not-precise-scroll-deltas",
                fallbackWheel: true,
                mapping: mapping
            )
            return false
        }

        if !event.momentumPhase.isEmpty {
            let hadActiveGesture = trackpadSwipeDragPhase != .idle || trackpadSwipeDragSyntheticButtonDown
            if hadActiveGesture {
                finishTrackpadSwipeDrag(
                    event: event,
                    mapping: mapping,
                    reason: "momentum-phase-started",
                    cancelled: true
                )
                return true
            }
            rejectTrackpadSwipeToDrag(
                event: event,
                reason: "momentum-without-active-gesture",
                fallbackWheel: true,
                mapping: mapping
            )
            return false
        }

        let phase = event.phase
        if phase.contains(.ended) || phase.contains(.cancelled) {
            let hadActiveGesture = trackpadSwipeDragPhase != .idle || trackpadSwipeDragSyntheticButtonDown
            guard hadActiveGesture else {
                rejectTrackpadSwipeToDrag(
                    event: event,
                    reason: "phase-ended-without-active-gesture",
                    fallbackWheel: false,
                    mapping: mapping
                )
                return false
            }
            if trackpadSwipeToDragMode == AppSettings.EasyTrackpadSwipeToDragMode.delayed {
                finishDelayedTrackpadSwipeDrag(
                    event: event,
                    mapping: mapping,
                    reason: phase.contains(.cancelled) ? "phase-cancelled" : "phase-ended",
                    cancelled: phase.contains(.cancelled)
                )
                return true
            }
            finishTrackpadSwipeDrag(
                event: event,
                mapping: mapping,
                reason: phase.contains(.cancelled) ? "phase-cancelled" : "phase-ended",
                cancelled: phase.contains(.cancelled)
            )
            return true
        }

        if phase.contains(.began) || phase.contains(.mayBegin) {
            if trackpadSwipeDragPhase != .idle || trackpadSwipeDragSyntheticButtonDown {
                finishTrackpadSwipeDrag(
                    event: event,
                    mapping: mapping,
                    reason: "new-phase-began",
                    cancelled: true
                )
            }
            startTrackpadSwipeEvaluation(event: event, mapping: mapping, reason: trackpadEventPhaseDescription(phase))
        } else if trackpadSwipeDragPhase == .idle {
            startTrackpadSwipeEvaluation(
                event: event,
                mapping: mapping,
                reason: phase.isEmpty ? "empty-phase-fallback" : "changed-without-began"
            )
        }

        trackpadSwipeDragEventCount += 1
        trackpadSwipeDragLastEventUptime = ProcessInfo.processInfo.systemUptime
        trackpadSwipeDragAccumulatedHorizontalDelta += event.scrollingDeltaX
        trackpadSwipeDragAccumulatedVerticalDelta += event.scrollingDeltaY

        let absHorizontal = abs(trackpadSwipeDragAccumulatedHorizontalDelta)
        let absVertical = abs(trackpadSwipeDragAccumulatedVerticalDelta)
        let horizontalDominates = absHorizontal >= absVertical * TrackpadSwipeDragMetrics.horizontalDominanceRatio
        let hasCommitDistance = absHorizontal >= TrackpadSwipeDragMetrics.minimumHorizontalCommitDelta

        guard absHorizontal >= absVertical else {
            rejectActiveTrackpadSwipeEvaluation(
                event: event,
                mapping: mapping,
                reason: "vertical-dominant",
                fallbackWheel: true,
                details: [
                    "absHorizontal": FrameDropDiagnostics.format(Double(absHorizontal), digits: 2),
                    "absVertical": FrameDropDiagnostics.format(Double(absVertical), digits: 2)
                ]
            )
            return false
        }

        switch trackpadSwipeDragPhase {
        case .idle:
            rejectTrackpadSwipeToDrag(
                event: event,
                reason: "unexpected-idle-after-evaluation",
                fallbackWheel: true,
                mapping: mapping
            )
            return false

        case .evaluating:
            guard hasCommitDistance else {
                recordTrackpadSwipeDiagnostic(
                    event: "evaluationStarted",
                    reason: "waiting-for-horizontal-threshold",
                    sourceEvent: event,
                    mapping: mapping,
                    details: [
                        "minimumHorizontalCommitDelta": FrameDropDiagnostics.format(Double(TrackpadSwipeDragMetrics.minimumHorizontalCommitDelta), digits: 2),
                        "horizontalDominates": String(horizontalDominates),
                        "absHorizontal": FrameDropDiagnostics.format(Double(absHorizontal), digits: 2),
                        "absVertical": FrameDropDiagnostics.format(Double(absVertical), digits: 2)
                    ]
                )
                return true
            }

            guard horizontalDominates else {
                rejectActiveTrackpadSwipeEvaluation(
                    event: event,
                    mapping: mapping,
                    reason: "horizontal-dominance-threshold-not-met",
                    fallbackWheel: true,
                    details: [
                        "horizontalDominanceRatio": FrameDropDiagnostics.format(Double(TrackpadSwipeDragMetrics.horizontalDominanceRatio), digits: 2),
                        "absHorizontal": FrameDropDiagnostics.format(Double(absHorizontal), digits: 2),
                        "absVertical": FrameDropDiagnostics.format(Double(absVertical), digits: 2)
                    ]
                )
                return false
            }

            if trackpadSwipeToDragMode == AppSettings.EasyTrackpadSwipeToDragMode.delayed {
                markDelayedTrackpadSwipeReady(event: event, mapping: mapping)
                return true
            }

            commitTrackpadSwipeDrag(event: event, mapping: mapping)
            return true

        case .delayedReady:
            guard horizontalDominates else {
                rejectActiveTrackpadSwipeEvaluation(
                    event: event,
                    mapping: mapping,
                    reason: "delayed-horizontal-dominance-lost",
                    fallbackWheel: false,
                    details: [
                        "horizontalDominanceRatio": FrameDropDiagnostics.format(Double(TrackpadSwipeDragMetrics.horizontalDominanceRatio), digits: 2),
                        "absHorizontal": FrameDropDiagnostics.format(Double(absHorizontal), digits: 2),
                        "absVertical": FrameDropDiagnostics.format(Double(absVertical), digits: 2)
                    ]
                )
                return true
            }
            recordTrackpadSwipeDiagnostic(
                event: "delayedGestureReady",
                reason: "waiting-for-phase-ended",
                sourceEvent: event,
                mapping: mapping,
                details: trackpadSwipeTargetDetails(trackpadSwipeDelayedEndPoint() ?? mapping.phonePoint)
            )
            return true

        case .dragging:
            moveTrackpadSwipeDrag(event: event, mapping: mapping)
            return true
        }
    }

    private func startTrackpadSwipeEvaluation(event: NSEvent, mapping: PointerInputMapping, reason: String) {
        trackpadSwipeDragGestureID += 1
        trackpadSwipeDragPhase = .evaluating
        trackpadSwipeDragStartPhonePoint = mapping.phonePoint
        trackpadSwipeDragLatestPhonePoint = mapping.phonePoint
        trackpadSwipeDragAccumulatedHorizontalDelta = 0
        trackpadSwipeDragAccumulatedVerticalDelta = 0
        trackpadSwipeDragEventCount = 0
        trackpadSwipeDragMoveCount = 0
        trackpadSwipeDragStartUptime = ProcessInfo.processInfo.systemUptime
        trackpadSwipeDragLastEventUptime = trackpadSwipeDragStartUptime
        trackpadSwipeDragSyntheticButtonDown = false
        appendLog("[TrackpadSwipeDrag] evaluation started gesture=\(trackpadSwipeDragGestureID) reason=\(reason) start=\(InputSurfaceDiagnostics.pointString(mapping.phonePoint)) phase=\(trackpadEventPhaseDescription(event.phase))")
        recordTrackpadSwipeDiagnostic(
            event: "evaluationStarted",
            reason: reason,
            sourceEvent: event,
            mapping: mapping,
            details: [
                "minimumHorizontalCommitDelta": FrameDropDiagnostics.format(Double(TrackpadSwipeDragMetrics.minimumHorizontalCommitDelta), digits: 2),
                "horizontalDominanceRatio": FrameDropDiagnostics.format(Double(TrackpadSwipeDragMetrics.horizontalDominanceRatio), digits: 2),
                "dragScale": FrameDropDiagnostics.format(Double(TrackpadSwipeDragMetrics.dragScale), digits: 2),
                "directionMultiplier": FrameDropDiagnostics.format(Double(TrackpadSwipeDragMetrics.directionMultiplier), digits: 2)
            ]
        )
    }

    private func commitTrackpadSwipeDrag(event: NSEvent, mapping: PointerInputMapping) {
        guard let direction = trackpadSwipeResolvedDirection() else {
            rejectTrackpadSwipeToDrag(
                event: event,
                reason: "missing-direction-on-live-commit",
                fallbackWheel: true,
                mapping: mapping
            )
            return
        }
        let anchors = trackpadSwipeAnchorPoints(for: direction)
        let startPoint = anchors.start
        trackpadSwipeDragStartPhonePoint = startPoint
        trackpadSwipeDragLatestPhonePoint = startPoint

        let targetPoint = trackpadSwipeTargetPoint() ?? mapping.phonePoint
        appendLog("[TrackpadSwipeDrag] committed gesture=\(trackpadSwipeDragGestureID) mode=\(trackpadSwipeToDragMode) direction=\(direction.rawValue) accumulated=(\(trackpadSwipeDragAccumulatedHorizontalDelta),\(trackpadSwipeDragAccumulatedVerticalDelta)) anchorStart=\(InputSurfaceDiagnostics.pointString(startPoint)) target=\(InputSurfaceDiagnostics.pointString(targetPoint)) anchorEnd=\(InputSurfaceDiagnostics.pointString(anchors.end)) rotation=\(inputSurfaceRotationDegrees)")
        recordTrackpadSwipeDiagnostic(
            event: "gestureCommitted",
            reason: "live-horizontal-threshold-met",
            sourceEvent: event,
            mapping: mapping,
            details: trackpadSwipeTargetDetails(targetPoint)
        )

        beginPointerInteraction(at: startPoint)
        trackpadSwipeDragSyntheticButtonDown = true
        trackpadSwipeDragPhase = .dragging
        recordTrackpadSwipeDiagnostic(
            event: "dragStarted",
            reason: "synthetic-button-down",
            sourceEvent: event,
            mapping: mapping,
            details: trackpadSwipeTargetDetails(targetPoint)
        )

        trackpadSwipeDragLatestPhonePoint = targetPoint
        trackpadSwipeDragMoveCount += 1
        dragPointer(to: targetPoint)
        recordTrackpadSwipeDiagnostic(
            event: "dragMoved",
            reason: "commit-initial-move",
            sourceEvent: event,
            mapping: mapping,
            details: trackpadSwipeTargetDetails(targetPoint)
        )
    }

    private func moveTrackpadSwipeDrag(event: NSEvent, mapping: PointerInputMapping) {
        let targetPoint = trackpadSwipeTargetPoint() ?? mapping.phonePoint
        trackpadSwipeDragLatestPhonePoint = targetPoint
        trackpadSwipeDragMoveCount += 1
        appendLog("[TrackpadSwipeDrag] move gesture=\(trackpadSwipeDragGestureID) move=\(trackpadSwipeDragMoveCount) rawDelta=(\(event.scrollingDeltaX),\(event.scrollingDeltaY)) accumulated=(\(trackpadSwipeDragAccumulatedHorizontalDelta),\(trackpadSwipeDragAccumulatedVerticalDelta)) target=\(InputSurfaceDiagnostics.pointString(targetPoint))")
        dragPointer(to: targetPoint)
        recordTrackpadSwipeDiagnostic(
            event: "dragMoved",
            reason: "phase-changed",
            sourceEvent: event,
            mapping: mapping,
            details: trackpadSwipeTargetDetails(targetPoint)
        )
    }

    private func markDelayedTrackpadSwipeReady(event: NSEvent, mapping: PointerInputMapping) {
        guard let direction = trackpadSwipeResolvedDirection() else {
            rejectActiveTrackpadSwipeEvaluation(
                event: event,
                mapping: mapping,
                reason: "missing-direction-on-delayed-ready",
                fallbackWheel: false
            )
            return
        }

        let anchors = trackpadSwipeAnchorPoints(for: direction)
        trackpadSwipeDragPhase = .delayedReady
        trackpadSwipeDragStartPhonePoint = anchors.start
        trackpadSwipeDragLatestPhonePoint = anchors.start
        appendLog("[TrackpadSwipeDrag] delayed ready gesture=\(trackpadSwipeDragGestureID) direction=\(direction.rawValue) accumulated=(\(trackpadSwipeDragAccumulatedHorizontalDelta),\(trackpadSwipeDragAccumulatedVerticalDelta)) anchorStart=\(InputSurfaceDiagnostics.pointString(anchors.start)) anchorEnd=\(InputSurfaceDiagnostics.pointString(anchors.end))")
        recordTrackpadSwipeDiagnostic(
            event: "delayedGestureReady",
            reason: "horizontal-threshold-met",
            sourceEvent: event,
            mapping: mapping,
            details: trackpadSwipeTargetDetails(anchors.end)
        )
    }

    private func finishDelayedTrackpadSwipeDrag(
        event: NSEvent?,
        mapping: PointerInputMapping?,
        reason: String,
        cancelled: Bool
    ) {
        let absHorizontal = abs(trackpadSwipeDragAccumulatedHorizontalDelta)
        let absVertical = abs(trackpadSwipeDragAccumulatedVerticalDelta)
        let horizontalDominates = absHorizontal >= absVertical * TrackpadSwipeDragMetrics.horizontalDominanceRatio
        let hasCommitDistance = absHorizontal >= TrackpadSwipeDragMetrics.minimumHorizontalCommitDelta

        if cancelled {
            appendLog("[TrackpadSwipeDrag] delayed cancelled gesture=\(trackpadSwipeDragGestureID) reason=\(reason) accumulated=(\(trackpadSwipeDragAccumulatedHorizontalDelta),\(trackpadSwipeDragAccumulatedVerticalDelta))")
            recordTrackpadSwipeDiagnostic(
                event: "dragCancelled",
                reason: "delayed-\(reason)",
                sourceEvent: event,
                mapping: mapping,
                details: [
                    "absHorizontal": FrameDropDiagnostics.format(Double(absHorizontal), digits: 2),
                    "absVertical": FrameDropDiagnostics.format(Double(absVertical), digits: 2),
                    "hasCommitDistance": String(hasCommitDistance),
                    "horizontalDominates": String(horizontalDominates)
                ]
            )
            resetTrackpadSwipeDragState(reason: "delayed-\(reason)")
            return
        }

        guard hasCommitDistance else {
            appendLog("[TrackpadSwipeDrag] delayed rejected gesture=\(trackpadSwipeDragGestureID) reason=ended-before-threshold absHorizontal=\(absHorizontal) absVertical=\(absVertical)")
            recordTrackpadSwipeDiagnostic(
                event: "guardRejected",
                reason: "delayed-ended-before-threshold",
                sourceEvent: event,
                mapping: mapping,
                details: [
                    "minimumHorizontalCommitDelta": FrameDropDiagnostics.format(Double(TrackpadSwipeDragMetrics.minimumHorizontalCommitDelta), digits: 2),
                    "absHorizontal": FrameDropDiagnostics.format(Double(absHorizontal), digits: 2),
                    "absVertical": FrameDropDiagnostics.format(Double(absVertical), digits: 2),
                    "fallbackWheel": "false"
                ],
                severity: "info"
            )
            resetTrackpadSwipeDragState(reason: "delayed-ended-before-threshold")
            return
        }

        guard horizontalDominates else {
            appendLog("[TrackpadSwipeDrag] delayed rejected gesture=\(trackpadSwipeDragGestureID) reason=dominance-not-met absHorizontal=\(absHorizontal) absVertical=\(absVertical)")
            recordTrackpadSwipeDiagnostic(
                event: "guardRejected",
                reason: "delayed-horizontal-dominance-threshold-not-met",
                sourceEvent: event,
                mapping: mapping,
                details: [
                    "horizontalDominanceRatio": FrameDropDiagnostics.format(Double(TrackpadSwipeDragMetrics.horizontalDominanceRatio), digits: 2),
                    "absHorizontal": FrameDropDiagnostics.format(Double(absHorizontal), digits: 2),
                    "absVertical": FrameDropDiagnostics.format(Double(absVertical), digits: 2),
                    "fallbackWheel": "false"
                ],
                severity: "info"
            )
            resetTrackpadSwipeDragState(reason: "delayed-horizontal-dominance-threshold-not-met")
            return
        }

        guard let direction = trackpadSwipeResolvedDirection() else {
            appendLog("[TrackpadSwipeDrag] delayed rejected gesture=\(trackpadSwipeDragGestureID) reason=missing-direction accumulated=(\(trackpadSwipeDragAccumulatedHorizontalDelta),\(trackpadSwipeDragAccumulatedVerticalDelta))")
            recordTrackpadSwipeDiagnostic(
                event: "guardRejected",
                reason: "delayed-missing-direction",
                sourceEvent: event,
                mapping: mapping,
                details: ["fallbackWheel": "false"],
                severity: "warning"
            )
            resetTrackpadSwipeDragState(reason: "delayed-missing-direction")
            return
        }

        let anchors = trackpadSwipeAnchorPoints(for: direction)
        trackpadSwipeDragPhase = .dragging
        trackpadSwipeDragStartPhonePoint = anchors.start
        trackpadSwipeDragLatestPhonePoint = anchors.start
        appendLog("[TrackpadSwipeDrag] delayed committed gesture=\(trackpadSwipeDragGestureID) direction=\(direction.rawValue) start=\(InputSurfaceDiagnostics.pointString(anchors.start)) end=\(InputSurfaceDiagnostics.pointString(anchors.end)) accumulated=(\(trackpadSwipeDragAccumulatedHorizontalDelta),\(trackpadSwipeDragAccumulatedVerticalDelta))")
        recordTrackpadSwipeDiagnostic(
            event: "gestureCommitted",
            reason: "delayed-phase-ended",
            sourceEvent: event,
            mapping: mapping,
            details: trackpadSwipeTargetDetails(anchors.end)
        )

        beginPointerInteraction(at: anchors.start)
        trackpadSwipeDragSyntheticButtonDown = true
        recordTrackpadSwipeDiagnostic(
            event: "dragStarted",
            reason: "delayed-synthetic-button-down",
            sourceEvent: event,
            mapping: mapping,
            details: trackpadSwipeTargetDetails(anchors.end)
        )

        trackpadSwipeDragMoveCount += 1
        trackpadSwipeDragLatestPhonePoint = anchors.end
        dragPointer(to: anchors.end)
        recordTrackpadSwipeDiagnostic(
            event: "dragMoved",
            reason: "delayed-anchor-to-anchor",
            sourceEvent: event,
            mapping: mapping,
            details: trackpadSwipeTargetDetails(anchors.end)
        )

        endPointerInteraction(at: anchors.end, click: false)
        trackpadSwipeDragSyntheticButtonDown = false
        recordTrackpadSwipeDiagnostic(
            event: "dragEnded",
            reason: "delayed-anchor-to-anchor",
            sourceEvent: event,
            mapping: mapping,
            details: trackpadSwipeTargetDetails(anchors.end).merging(
                [
                    "buttonUpSent": "true",
                    "moveCount": String(trackpadSwipeDragMoveCount)
                ],
                uniquingKeysWith: { current, _ in current }
            )
        )
        moveTrackpadSwipePointerToNeutral(reason: "delayed-anchor-to-anchor")
        resetTrackpadSwipeDragState(reason: "delayed-anchor-to-anchor")
    }

    private func finishTrackpadSwipeDrag(
        event: NSEvent?,
        mapping: PointerInputMapping?,
        reason: String,
        cancelled: Bool
    ) {
        let targetPoint = trackpadSwipeDragLatestPhonePoint
            ?? trackpadSwipeTargetPoint()
            ?? mapping?.phonePoint
            ?? trackpadSwipeDragStartPhonePoint
            ?? virtualPointerPoint
        let hadSyntheticButtonDown = trackpadSwipeDragSyntheticButtonDown
        appendLog("[TrackpadSwipeDrag] \(cancelled ? "cancel" : "end") gesture=\(trackpadSwipeDragGestureID) reason=\(reason) phase=\(trackpadSwipeDragPhase.rawValue) buttonDown=\(hadSyntheticButtonDown) target=\(InputSurfaceDiagnostics.pointString(targetPoint)) moves=\(trackpadSwipeDragMoveCount)")
        if hadSyntheticButtonDown {
            endPointerInteraction(at: targetPoint, click: false)
        }
        recordTrackpadSwipeDiagnostic(
            event: cancelled ? "dragCancelled" : "dragEnded",
            reason: reason,
            sourceEvent: event,
            mapping: mapping,
            details: trackpadSwipeTargetDetails(targetPoint).merging(
                [
                    "buttonUpSent": String(hadSyntheticButtonDown),
                    "moveCount": String(trackpadSwipeDragMoveCount)
                ],
                uniquingKeysWith: { current, _ in current }
            )
        )
        if hadSyntheticButtonDown, !cancelled {
            moveTrackpadSwipePointerToNeutral(reason: reason)
        }
        resetTrackpadSwipeDragState(reason: reason)
    }

    private func cancelTrackpadSwipeDrag(reason: String) {
        guard trackpadSwipeDragPhase != .idle || trackpadSwipeDragSyntheticButtonDown else {
            resetTrackpadSwipeDragState(reason: reason)
            return
        }
        finishTrackpadSwipeDrag(
            event: nil,
            mapping: nil,
            reason: reason,
            cancelled: true
        )
    }

    private func rejectActiveTrackpadSwipeEvaluation(
        event: NSEvent,
        mapping: PointerInputMapping,
        reason: String,
        fallbackWheel: Bool,
        details: [String: String] = [:]
    ) {
        rejectTrackpadSwipeToDrag(
            event: event,
            reason: reason,
            fallbackWheel: fallbackWheel,
            mapping: mapping,
            details: details
        )
        resetTrackpadSwipeDragState(reason: reason)
    }

    private func rejectTrackpadSwipeToDrag(
        event: NSEvent,
        reason: String,
        fallbackWheel: Bool,
        mapping: PointerInputMapping? = nil,
        details: [String: String] = [:]
    ) {
        appendLog("[TrackpadSwipeDrag] rejected reason=\(reason) fallbackWheel=\(fallbackWheel) enabled=\(trackpadSwipeToDragEnabled) mode=\(trackpadSwipeToDragMode) phase=\(trackpadSwipeDragPhase.rawValue) precise=\(event.hasPreciseScrollingDeltas) phase=\(trackpadEventPhaseDescription(event.phase)) momentum=\(trackpadEventPhaseDescription(event.momentumPhase)) rawDelta=(\(event.scrollingDeltaX),\(event.scrollingDeltaY))")
        recordTrackpadSwipeDiagnostic(
            event: "guardRejected",
            reason: reason,
            sourceEvent: event,
            mapping: mapping,
            details: details.merging(["fallbackWheel": String(fallbackWheel)], uniquingKeysWith: { current, _ in current }),
            severity: fallbackWheel ? "info" : "warning"
        )
        if fallbackWheel {
            recordTrackpadSwipeDiagnostic(
                event: "fallbackWheel",
                reason: reason,
                sourceEvent: event,
                mapping: mapping,
                details: details
            )
        }
    }

    private func resetTrackpadSwipeDragState(reason: String) {
        if trackpadSwipeDragPhase != .idle || trackpadSwipeDragSyntheticButtonDown {
            appendLog("[TrackpadSwipeDrag] reset reason=\(reason) previousPhase=\(trackpadSwipeDragPhase.rawValue) syntheticButtonDown=\(trackpadSwipeDragSyntheticButtonDown)")
        }
        trackpadSwipeDragPhase = .idle
        trackpadSwipeDragStartPhonePoint = nil
        trackpadSwipeDragLatestPhonePoint = nil
        trackpadSwipeDragAccumulatedHorizontalDelta = 0
        trackpadSwipeDragAccumulatedVerticalDelta = 0
        trackpadSwipeDragEventCount = 0
        trackpadSwipeDragMoveCount = 0
        trackpadSwipeDragStartUptime = 0
        trackpadSwipeDragLastEventUptime = 0
        trackpadSwipeDragSyntheticButtonDown = false
    }

    private func trackpadSwipeScaledHorizontalDelta() -> CGFloat {
        trackpadSwipeDragAccumulatedHorizontalDelta
            * TrackpadSwipeDragMetrics.dragScale
            * TrackpadSwipeDragMetrics.directionMultiplier
    }

    private func trackpadSwipeResolvedDirection() -> TrackpadSwipeDragDirection? {
        let scaledHorizontal = trackpadSwipeScaledHorizontalDelta()
        guard scaledHorizontal.isFinite, scaledHorizontal != 0 else { return nil }
        return scaledHorizontal < 0 ? .left : .right
    }

    private func trackpadSwipeAnchorPoints(for direction: TrackpadSwipeDragDirection) -> (start: CGPoint, end: CGPoint, neutral: CGPoint) {
        guard InputSurfaceDiagnostics.isFinite(pointerSurfaceSize), pointerSurfaceSize.width > 0, pointerSurfaceSize.height > 0 else {
            let fallback = clampPhonePointToSurface(virtualPointerPoint)
            appendLog("[TrackpadSwipeDrag] anchor fallback direction=\(direction.rawValue) invalidSurface=\(InputSurfaceDiagnostics.sizeString(pointerSurfaceSize)) fallback=\(InputSurfaceDiagnostics.pointString(fallback))")
            return (start: fallback, end: fallback, neutral: fallback)
        }

        let neutral = CGPoint(x: pointerSurfaceSize.width / 2, y: pointerSurfaceSize.height / 2)
        let halfSwipeDistance = pointerSurfaceSize.width * TrackpadSwipeDragMetrics.maximumSyntheticDragFractionOfSurface / 2
        let leftAnchor = clampPhonePointToSurface(CGPoint(x: neutral.x - halfSwipeDistance, y: neutral.y))
        let rightAnchor = clampPhonePointToSurface(CGPoint(x: neutral.x + halfSwipeDistance, y: neutral.y))
        let neutralAnchor = clampPhonePointToSurface(neutral)

        switch direction {
        case .left:
            return (start: rightAnchor, end: leftAnchor, neutral: neutralAnchor)
        case .right:
            return (start: leftAnchor, end: rightAnchor, neutral: neutralAnchor)
        }
    }

    private func trackpadSwipeDelayedEndPoint() -> CGPoint? {
        guard let direction = trackpadSwipeResolvedDirection() else { return nil }
        return trackpadSwipeAnchorPoints(for: direction).end
    }

    private func trackpadSwipeNeutralPoint() -> CGPoint {
        if let direction = trackpadSwipeResolvedDirection() {
            return trackpadSwipeAnchorPoints(for: direction).neutral
        }
        guard InputSurfaceDiagnostics.isFinite(pointerSurfaceSize), pointerSurfaceSize.width > 0, pointerSurfaceSize.height > 0 else {
            return clampPhonePointToSurface(virtualPointerPoint)
        }
        return clampPhonePointToSurface(CGPoint(x: pointerSurfaceSize.width / 2, y: pointerSurfaceSize.height / 2))
    }

    private func moveTrackpadSwipePointerToNeutral(reason: String) {
        let neutralPoint = trackpadSwipeNeutralPoint()
        appendLog("[TrackpadSwipeDrag] neutralize reason=\(reason) point=\(InputSurfaceDiagnostics.pointString(neutralPoint)) mode=\(trackpadSwipeToDragMode)")
        recordTrackpadSwipeDiagnostic(
            event: "pointerNeutralized",
            reason: reason,
            details: ["neutralPoint": InputSurfaceDiagnostics.pointString(neutralPoint)]
        )
        movePointer(to: neutralPoint, reason: "trackpad-swipe-neutral:\(reason)")
    }

    private func trackpadSwipeTargetPoint() -> CGPoint? {
        guard let startPoint = trackpadSwipeDragStartPhonePoint else { return nil }
        guard InputSurfaceDiagnostics.isFinite(pointerSurfaceSize), pointerSurfaceSize.width > 0 else {
            return clampPhonePointToSurface(startPoint)
        }
        let maximumDistance = pointerSurfaceSize.width * TrackpadSwipeDragMetrics.maximumSyntheticDragFractionOfSurface
        let scaledHorizontal = trackpadSwipeScaledHorizontalDelta()
        let clampedHorizontal = min(max(scaledHorizontal, -maximumDistance), maximumDistance)
        return clampPhonePointToSurface(
            CGPoint(
                x: startPoint.x + clampedHorizontal,
                y: startPoint.y
            )
        )
    }

    private func trackpadSwipeTargetDetails(_ targetPoint: CGPoint) -> [String: String] {
        var details: [String: String] = [
            "mode": trackpadSwipeToDragMode,
            "targetPhonePoint": InputSurfaceDiagnostics.pointString(targetPoint),
            "scaledHorizontalDelta": FrameDropDiagnostics.format(Double(trackpadSwipeScaledHorizontalDelta()), digits: 2),
            "maximumSyntheticDragFractionOfSurface": FrameDropDiagnostics.format(Double(TrackpadSwipeDragMetrics.maximumSyntheticDragFractionOfSurface), digits: 2),
            "dragScale": FrameDropDiagnostics.format(Double(TrackpadSwipeDragMetrics.dragScale), digits: 2),
            "directionMultiplier": FrameDropDiagnostics.format(Double(TrackpadSwipeDragMetrics.directionMultiplier), digits: 2)
        ]
        if let direction = trackpadSwipeResolvedDirection() {
            let anchors = trackpadSwipeAnchorPoints(for: direction)
            details["resolvedDirection"] = direction.rawValue
            details["anchorStartPoint"] = InputSurfaceDiagnostics.pointString(anchors.start)
            details["anchorEndPoint"] = InputSurfaceDiagnostics.pointString(anchors.end)
            details["neutralPoint"] = InputSurfaceDiagnostics.pointString(anchors.neutral)
        } else {
            details["resolvedDirection"] = "nil"
            details["neutralPoint"] = InputSurfaceDiagnostics.pointString(trackpadSwipeNeutralPoint())
        }
        return details
    }

    private func recordTrackpadSwipeDiagnostic(
        event: String,
        reason: String,
        sourceEvent: NSEvent? = nil,
        mapping: PointerInputMapping? = nil,
        details: [String: String] = [:],
        severity: String = "info"
    ) {
        var merged: [String: String] = [
            "enabled": String(trackpadSwipeToDragEnabled),
            "mode": trackpadSwipeToDragMode,
            "phase": trackpadSwipeDragPhase.rawValue,
            "gestureID": String(trackpadSwipeDragGestureID),
            "eventCount": String(trackpadSwipeDragEventCount),
            "moveCount": String(trackpadSwipeDragMoveCount),
            "syntheticButtonDown": String(trackpadSwipeDragSyntheticButtonDown),
            "accumulatedX": FrameDropDiagnostics.format(Double(trackpadSwipeDragAccumulatedHorizontalDelta), digits: 2),
            "accumulatedY": FrameDropDiagnostics.format(Double(trackpadSwipeDragAccumulatedVerticalDelta), digits: 2),
            "inputGateEnabled": String(replayKitInputForwardingEnabled),
            "inputGateReason": replayKitInputForwardingReason,
            "interruptConnected": String(interruptChannel != nil),
            "mousePassthroughEnabled": String(mousePassthroughEnabled),
            "targetWindow": targetInputWindow.map { String($0.windowNumber) } ?? "nil",
            "targetWindowKey": targetInputWindow.map { String($0.isKeyWindow) } ?? "nil",
            "inputSurfaceFrame": inputSurfaceFrameInWindow.map(InputSurfaceDiagnostics.rectString) ?? "nil",
            "phoneSurfaceSize": InputSurfaceDiagnostics.sizeString(pointerSurfaceSize),
            "displayRotation": String(inputSurfaceRotationDegrees),
            "startPhonePoint": trackpadSwipeDragStartPhonePoint.map(InputSurfaceDiagnostics.pointString) ?? "nil",
            "latestPhonePoint": trackpadSwipeDragLatestPhonePoint.map(InputSurfaceDiagnostics.pointString) ?? "nil"
        ]

        if let sourceEvent {
            merged["eventType"] = String(sourceEvent.type.rawValue)
            merged["eventWindow"] = sourceEvent.window.map { String($0.windowNumber) } ?? "nil"
            merged["eventPhase"] = trackpadEventPhaseDescription(sourceEvent.phase)
            merged["momentumPhase"] = trackpadEventPhaseDescription(sourceEvent.momentumPhase)
            merged["hasPreciseDeltas"] = String(sourceEvent.hasPreciseScrollingDeltas)
            merged["rawDeltaX"] = FrameDropDiagnostics.format(Double(sourceEvent.scrollingDeltaX), digits: 2)
            merged["rawDeltaY"] = FrameDropDiagnostics.format(Double(sourceEvent.scrollingDeltaY), digits: 2)
            merged["eventLocationInWindow"] = InputSurfaceDiagnostics.pointString(sourceEvent.locationInWindow)
        }

        if let mapping {
            merged["mappedEventLocation"] = InputSurfaceDiagnostics.pointString(mapping.eventLocationInWindow)
            merged["mappedLocalPoint"] = InputSurfaceDiagnostics.pointString(mapping.localPoint)
            merged["mappedPhonePoint"] = InputSurfaceDiagnostics.pointString(mapping.phonePoint)
            merged["mappedSurfaceFrame"] = InputSurfaceDiagnostics.rectString(mapping.surfaceFrameInWindow)
            merged["mappedWasClamped"] = String(mapping.wasClampedToSurface)
        }

        for (key, value) in details {
            merged[key] = value
        }

        FrameDropDiagnostics.shared.recordLifecycle(
            source: "easyTrackpadGesture",
            event: event,
            reason: reason,
            details: merged,
            severity: severity
        )
    }

    private func trackpadEventPhaseDescription(_ phase: NSEvent.Phase) -> String {
        guard !phase.isEmpty else { return "none" }
        var parts: [String] = []
        if phase.contains(.mayBegin) { parts.append("mayBegin") }
        if phase.contains(.began) { parts.append("began") }
        if phase.contains(.stationary) { parts.append("stationary") }
        if phase.contains(.changed) { parts.append("changed") }
        if phase.contains(.ended) { parts.append("ended") }
        if phase.contains(.cancelled) { parts.append("cancelled") }
        return parts.isEmpty ? "unknown(\(phase.rawValue))" : parts.joined(separator: "|")
    }

    private func beginAbsoluteLeftDragIfNeeded(mapping: PointerInputMapping, trigger: String) {
        guard absolutePointerTransportEnabled else {
            appendLog("[PointerABS] left-drag start ignored trigger=\(trigger): absolute transport disabled")
            return
        }
        guard isLeftMousePressedForSwipe else {
            appendLog("[PointerABS] left-drag start ignored trigger=\(trigger): left button not tracked as down")
            return
        }
        guard !isDragGestureInProgress else {
            appendLog("[PointerABS] left-drag start ignored trigger=\(trigger): drag already active")
            return
        }

        clearPendingPointerSpikeTapAttempts(reason: "absolute left drag began trigger=\(trigger)")
        didCurrentLeftPressBecomeDrag = true
        isDragGestureInProgress = true
        postPointerFeedback(kind: "dragStart", point: mapping.phonePoint)
        postPointerSpikeVisualization(
            phase: "dragStartAbsolute",
            sequence: pendingPointerSpikeAttempts.last?.sequence ?? pointerSpikeNextSequence,
            targetPhonePoint: mapping.phonePoint,
            mappedPhonePoint: mapping.phonePoint,
            virtualPhonePoint: virtualPointerPoint,
            actualPhonePoint: lastCalibrationActualPoint,
            note: "ABS left-drag start \(trigger)"
        )

        if isSwipeButtonDownOnPhone {
            appendLog("[PointerABS] left-drag start trigger=\(trigger) continuing existing primary button down at phone=\(InputSurfaceDiagnostics.pointString(mapping.phonePoint)) clamped=\(mapping.wasClampedToSurface)")
        } else {
            isSwipeButtonDownOnPhone = true
            appendLog("[PointerABS] left-drag start trigger=\(trigger) recovered missing primary button state; sending button down at phone=\(InputSurfaceDiagnostics.pointString(mapping.phonePoint)) clamped=\(mapping.wasClampedToSurface)")
            sendPointerButtonReport(buttons: 0x01, mapping: mapping, reason: "absolute-left-drag-recovery-button-down:\(trigger)")
        }
    }

    private func startDragGestureIfNeeded(mapping: PointerInputMapping?, trigger: String) {
        clearPendingPointerSpikeTapAttempts(reason: "drag began trigger=\(trigger)")
        if let mapping {
            if absolutePointerTransportEnabled && isSwipeButtonDownOnPhone {
                appendLog("[PointerABS] drag start trigger=\(trigger) skipping button-up realignment because primary button is already down")
            } else {
                realignPointerToCurrentMouseLocationIfNeeded(mapping: mapping, trigger: "drag-start-\(trigger)")
            }
        } else {
            appendLog("[Mouse] Drag start trigger=\(trigger) has no valid surface mapping; using current virtual pointer")
        }

        didCurrentLeftPressBecomeDrag = true
        isDragGestureInProgress = true
        postPointerFeedback(kind: "dragStart", point: mapping?.phonePoint ?? virtualPointerPoint)
        if isSwipeButtonDownOnPhone {
            appendLog("[Mouse] Drag button already down trigger=\(trigger)")
            return
        }

        isSwipeButtonDownOnPhone = true
        sendPointerButtonReport(buttons: 0x01, mapping: mapping, reason: "drag-button-down:\(trigger)")
        appendLog("[Mouse] Drag button DOWN trigger=\(trigger)")
    }

    private func finishDragGestureIfNeeded(trigger: String, mapping: PointerInputMapping?) {
        let releasePoint = mapping?.phonePoint ?? virtualPointerPoint
        postPointerFeedback(kind: "dragEnd", point: releasePoint)
        guard isSwipeButtonDownOnPhone else {
            isDragGestureInProgress = false
            appendLog("[Mouse] Drag finish trigger=\(trigger) found no phone button down")
            return
        }

        isSwipeButtonDownOnPhone = false
        isDragGestureInProgress = false
        postPointerSpikeVisualization(
            phase: absolutePointerTransportEnabled ? "dragEndAbsolute" : "dragEnd",
            sequence: pendingPointerSpikeAttempts.last?.sequence ?? pointerSpikeNextSequence,
            targetPhonePoint: releasePoint,
            mappedPhonePoint: mapping?.phonePoint,
            virtualPhonePoint: virtualPointerPoint,
            actualPhonePoint: lastCalibrationActualPoint,
            note: "Drag end \(trigger)"
        )
        sendPointerButtonReport(buttons: 0x00, mapping: mapping, reason: "drag-button-up:\(trigger)")
        appendLog("[Mouse] Drag button UP trigger=\(trigger) release=\(InputSurfaceDiagnostics.pointString(releasePoint)) mapped=\(mapping != nil) clamped=\(mapping?.wasClampedToSurface ?? false)")
    }

    private func positionPointerForDeterministicTapIfNeeded(mapping: PointerInputMapping, trigger: String) {
        guard deterministicPointerPositioningEnabled else {
            appendLog("[PointerSpike] deterministic tap positioning skipped trigger=\(trigger): spike disabled")
            return
        }

        appendLog(
            "[PointerSpike] deterministic tap positioning trigger=\(trigger) " +
            "target=\(InputSurfaceDiagnostics.pointString(mapping.phonePoint)) " +
            "virtualBefore=\(InputSurfaceDiagnostics.pointString(virtualPointerPoint)) " +
            "lastActual=\(lastCalibrationActualPoint.map(InputSurfaceDiagnostics.pointString) ?? "n/a")"
        )
        postPointerSpikeVisualization(
            phase: "tapPrealign",
            sequence: pendingPointerSpikeAttempts.last?.sequence ?? pointerSpikeNextSequence,
            targetPhonePoint: mapping.phonePoint,
            mappedPhonePoint: mapping.phonePoint,
            virtualPhonePoint: virtualPointerPoint,
            actualPhonePoint: lastCalibrationActualPoint,
            note: "Tap prealign \(trigger)"
        )
        movePointer(to: mapping.phonePoint, reason: "tap-prealign:\(trigger)")
    }

    private func realignPointerToCurrentMouseLocationIfNeeded(mapping: PointerInputMapping, trigger: String) {
        guard deterministicPointerPositioningEnabled else {
            appendLog("[PointerSpike] manual realignment skipped trigger=\(trigger): spike disabled")
            return
        }

        appendLog(
            "[PointerSpike] manual realignment trigger=\(trigger) " +
            "target=\(InputSurfaceDiagnostics.pointString(mapping.phonePoint)) " +
            "virtualBefore=\(InputSurfaceDiagnostics.pointString(virtualPointerPoint)) " +
            "lastActual=\(lastCalibrationActualPoint.map(InputSurfaceDiagnostics.pointString) ?? "n/a")"
        )
        postPointerSpikeVisualization(
            phase: "manualRealign",
            sequence: pendingPointerSpikeAttempts.last?.sequence ?? pointerSpikeNextSequence,
            targetPhonePoint: mapping.phonePoint,
            mappedPhonePoint: mapping.phonePoint,
            virtualPhonePoint: virtualPointerPoint,
            actualPhonePoint: lastCalibrationActualPoint,
            note: "Manual realign \(trigger)"
        )
        movePointer(to: mapping.phonePoint, reason: "manual-realign:\(trigger)", origin: .authoritativeActual)
    }

    private func sendMouseDeltaWithRemainder(dx: CGFloat, dy: CGFloat, buttons: UInt8, reason: String) {
        guard dx.isFinite, dy.isFinite, mouseDeltaRemainderX.isFinite, mouseDeltaRemainderY.isFinite else {
            appendLog("[Mouse] \(reason) dropped non-finite delta dx=\(dx) dy=\(dy) remainder=(\(mouseDeltaRemainderX),\(mouseDeltaRemainderY)); resetting remainder")
            mouseDeltaRemainderX = 0
            mouseDeltaRemainderY = 0
            return
        }

        let totalX = dx + mouseDeltaRemainderX
        let totalY = dy + mouseDeltaRemainderY
        guard totalX.isFinite, totalY.isFinite else {
            appendLog("[Mouse] \(reason) dropped non-finite accumulated delta total=(\(totalX),\(totalY)); resetting remainder")
            mouseDeltaRemainderX = 0
            mouseDeltaRemainderY = 0
            return
        }

        let wholeX = Int(totalX.rounded(.towardZero))
        let wholeY = Int(totalY.rounded(.towardZero))
        mouseDeltaRemainderX = totalX - CGFloat(wholeX)
        mouseDeltaRemainderY = totalY - CGFloat(wholeY)
        let shouldLog = mouseEventCount <= 5 || mouseEventCount % 200 == 0

        guard wholeX != 0 || wholeY != 0 else {
            if shouldLog {
                appendLog("[Mouse] \(reason) accumulated subpixel delta remainder=(\(String(format: "%.3f", mouseDeltaRemainderX)),\(String(format: "%.3f", mouseDeltaRemainderY)))")
            }
            return
        }

        if shouldLog || abs(wholeX) > 64 || abs(wholeY) > 64 {
            appendLog("[Mouse] \(reason) sending wholeDelta=(\(wholeX),\(wholeY)) remainder=(\(String(format: "%.3f", mouseDeltaRemainderX)),\(String(format: "%.3f", mouseDeltaRemainderY))) buttons=\(buttons)")
        }
        sendRelativePointerDelta(dx: CGFloat(wholeX), dy: CGFloat(wholeY), buttons: buttons)
    }

    private func alignPointerForClickIfCalibrated(_ event: NSEvent, reason: String) {
        guard lastCalibrationActualPoint != nil else {
            appendLog("[PointerAlign] skipped reason=\(reason): no calibration sample yet")
            return
        }
        guard let target = phonePointForInputEvent(event) else {
            appendLog("[PointerAlign] skipped reason=\(reason): no phone point for event")
            return
        }
        appendLog("[PointerAlign] reason=\(reason) target=\(InputSurfaceDiagnostics.pointString(target)) virtualBefore=\(InputSurfaceDiagnostics.pointString(virtualPointerPoint))")
        movePointer(to: target, reason: "click-align:\(reason)")
    }

    private func pointerInputMapping(for event: NSEvent, allowClampedOutOfBounds: Bool = false) -> PointerInputMapping? {
        guard let targetInputWindow, event.window === targetInputWindow else {
            appendLog("[InputSurface] phonePoint failed: event window does not match target")
            return nil
        }
        guard let frame = inputSurfaceFrameInWindow, InputSurfaceDiagnostics.isFinite(frame), frame.width > 0, frame.height > 0 else {
            appendLog("[InputSurface] phonePoint failed: missing or invalid video frame in window frame=\(inputSurfaceFrameInWindow.map(InputSurfaceDiagnostics.rectString) ?? "nil")")
            return nil
        }
        guard InputSurfaceDiagnostics.isFinite(pointerSurfaceSize), pointerSurfaceSize.width > 0, pointerSurfaceSize.height > 0 else {
            appendLog("[InputSurface] phonePoint failed: invalid pointer surface size=\(InputSurfaceDiagnostics.sizeString(pointerSurfaceSize))")
            return nil
        }

        let location = event.locationInWindow
        guard InputSurfaceDiagnostics.isFinite(location) else {
            appendLog("[InputSurface] phonePoint failed: event location is non-finite location=\(InputSurfaceDiagnostics.pointString(location)) frame=\(InputSurfaceDiagnostics.rectString(frame))")
            return nil
        }
        var localX = location.x - frame.minX
        var localY = location.y - frame.minY
        guard localX.isFinite, localY.isFinite else {
            appendLog("[InputSurface] phonePoint failed: local point is non-finite local=\(InputSurfaceDiagnostics.pointString(CGPoint(x: localX, y: localY))) location=\(InputSurfaceDiagnostics.pointString(location)) frame=\(InputSurfaceDiagnostics.rectString(frame))")
            return nil
        }
        let isInsideSurface = localX >= 0 && localX <= frame.width && localY >= 0 && localY <= frame.height
        if !isInsideSurface {
            guard allowClampedOutOfBounds else {
                appendLog("[InputSurface] phonePoint outside surface local=\(InputSurfaceDiagnostics.pointString(CGPoint(x: localX, y: localY))) frame=\(InputSurfaceDiagnostics.rectString(frame)) allowClamp=false")
                return nil
            }
            let originalLocalX = localX
            let originalLocalY = localY
            localX = min(max(localX, 0), frame.width)
            localY = min(max(localY, 0), frame.height)
            appendLog("[InputSurface] phonePoint clamped for drag originalLocal=\(InputSurfaceDiagnostics.pointString(CGPoint(x: originalLocalX, y: originalLocalY))) clampedLocal=\(InputSurfaceDiagnostics.pointString(CGPoint(x: localX, y: localY))) frame=\(InputSurfaceDiagnostics.rectString(frame))")
        }

        let displayNormalizedX = localX / frame.width
        let displayNormalizedY = 1 - (localY / frame.height)
        guard displayNormalizedX.isFinite, displayNormalizedY.isFinite else {
            appendLog("[InputSurface] phonePoint failed: normalized point is non-finite normalized=(\(displayNormalizedX),\(displayNormalizedY)) local=\(InputSurfaceDiagnostics.pointString(CGPoint(x: localX, y: localY))) frame=\(InputSurfaceDiagnostics.rectString(frame))")
            return nil
        }
        let normalizedPoint = phoneNormalizedPoint(displayX: displayNormalizedX, displayY: displayNormalizedY)
        let phonePoint = CGPoint(
            x: normalizedPoint.x * pointerSurfaceSize.width,
            y: normalizedPoint.y * pointerSurfaceSize.height
        )
        guard InputSurfaceDiagnostics.isFinite(normalizedPoint), InputSurfaceDiagnostics.isFinite(phonePoint) else {
            appendLog("[InputSurface] phonePoint failed: mapped point is non-finite normalized=\(InputSurfaceDiagnostics.pointString(normalizedPoint)) phone=\(InputSurfaceDiagnostics.pointString(phonePoint)) surface=\(InputSurfaceDiagnostics.sizeString(pointerSurfaceSize))")
            return nil
        }

        return PointerInputMapping(
            eventLocationInWindow: location,
            localPoint: CGPoint(x: localX, y: localY),
            normalizedPoint: normalizedPoint,
            phonePoint: phonePoint,
            surfaceFrameInWindow: frame,
            wasClampedToSurface: !isInsideSurface
        )
    }

    private func phoneNormalizedPoint(displayX: CGFloat, displayY: CGFloat) -> CGPoint {
        InputSurfaceRotationMapping.phoneNormalizedPoint(
            displayX: displayX,
            displayY: displayY,
            rotationDegrees: inputSurfaceRotationDegrees
        )
    }

    private func rotatedRelativePointerDelta(_ delta: CGPoint) -> CGPoint {
        let normalizedRotation = InputSurfaceRotationMapping.normalizedRotation(inputSurfaceRotationDegrees)
        switch normalizedRotation {
        case 0, 90, 180, 270:
            return InputSurfaceRotationMapping.relativePointerDelta(delta, rotationDegrees: normalizedRotation)
        default:
            appendLog("[MouseRotation] unsupported rotation=\(normalizedRotation); forwarding unrotated delta=\(InputSurfaceDiagnostics.pointString(delta))")
            return delta
        }
    }

    private func phonePointForInputEvent(_ event: NSEvent) -> CGPoint? {
        guard let mapping = pointerInputMapping(for: event) else {
            return nil
        }

        let shouldLog = easyPointerSpikeEnabled || mouseEventCount <= 5 || mouseEventCount % 200 == 0
        if shouldLog {
            appendLog(
                "[InputSurface] phonePoint event=\(InputSurfaceDiagnostics.pointString(mapping.eventLocationInWindow)) " +
                "local=\(InputSurfaceDiagnostics.pointString(mapping.localPoint)) " +
                "normalized=(\(String(format: "%.3f", mapping.normalizedPoint.x)),\(String(format: "%.3f", mapping.normalizedPoint.y))) " +
                "phoneTopLeft=\(InputSurfaceDiagnostics.pointString(mapping.phonePoint))"
            )
        }
        return mapping.phonePoint
    }

    private func capturePointerSpikeAttemptIfNeeded(event: NSEvent, mapping: PointerInputMapping) {
        guard easyPointerSpikeEnabled else { return }
        if !pendingPointerSpikeAttempts.isEmpty {
            appendLog("[PointerSpike] dropping \(pendingPointerSpikeAttempts.count) stale pending tap attempts before queueing a new one")
            pendingPointerSpikeAttempts.removeAll()
        }

        let sequence = pointerSpikeNextSequence
        pointerSpikeNextSequence += 1
        let virtualPointAtTap = virtualPointerPoint
        let attempt = PointerSpikeAttempt(
            sequence: sequence,
            createdAt: Date().timeIntervalSince1970,
            eventType: event.type,
            mappingAtDown: mapping,
            mappingAtUp: nil,
            virtualPointAtDown: virtualPointAtTap,
            virtualPointAtUp: nil
        )
        pendingPointerSpikeAttempts.append(attempt)
        appendLog(
            "[PointerSpike] queued tap sequence=\(sequence) variant=\(easyPointerSpikeVariant) " +
            "window=\(InputSurfaceDiagnostics.pointString(mapping.eventLocationInWindow)) " +
            "local=\(InputSurfaceDiagnostics.pointString(mapping.localPoint)) " +
            "frame=\(InputSurfaceDiagnostics.rectString(mapping.surfaceFrameInWindow)) " +
            "normalized=(\(String(format: "%.4f", mapping.normalizedPoint.x)),\(String(format: "%.4f", mapping.normalizedPoint.y))) " +
            "phone=\(InputSurfaceDiagnostics.pointString(mapping.phonePoint)) " +
            "virtualAtDown=\(InputSurfaceDiagnostics.pointString(virtualPointAtTap))"
        )
        postPointerSpikeVisualization(
            phase: "pendingTap",
            sequence: sequence,
            targetPhonePoint: mapping.phonePoint,
            mappedPhonePoint: mapping.phonePoint,
            virtualPhonePoint: virtualPointAtTap,
            actualPhonePoint: nil,
            note: "Queued tap attempt"
        )
    }

    private func clearPendingPointerSpikeTapAttempts(reason: String) {
        guard easyPointerSpikeEnabled else { return }
        guard !pendingPointerSpikeAttempts.isEmpty else {
            appendLog("[PointerSpike] no pending tap attempts to clear reason=\(reason)")
            return
        }
        appendLog("[PointerSpike] clearing \(pendingPointerSpikeAttempts.count) pending tap attempt(s) reason=\(reason)")
        pendingPointerSpikeAttempts.removeAll()
    }

    private func updatePendingPointerSpikeAttemptOnMouseUpIfNeeded(event: NSEvent) {
        guard easyPointerSpikeEnabled else { return }
        guard !pendingPointerSpikeAttempts.isEmpty else {
            appendLog("[PointerSpike] leftUp had no pending tap attempt to update")
            return
        }

        let mappingAtUp = pointerInputMapping(for: event)
        let virtualPointAtUp = virtualPointerPoint
        let lastIndex = pendingPointerSpikeAttempts.count - 1
        pendingPointerSpikeAttempts[lastIndex].mappingAtUp = mappingAtUp
        pendingPointerSpikeAttempts[lastIndex].virtualPointAtUp = virtualPointAtUp

        if let mappingAtUp {
            appendLog(
                "[PointerSpike] updated tap sequence=\(pendingPointerSpikeAttempts[lastIndex].sequence) on mouseUp " +
                "phoneUp=\(InputSurfaceDiagnostics.pointString(mappingAtUp.phonePoint)) " +
                "virtualAtUp=\(InputSurfaceDiagnostics.pointString(virtualPointAtUp))"
            )
        } else {
            appendLog(
                "[PointerSpike] updated tap sequence=\(pendingPointerSpikeAttempts[lastIndex].sequence) on mouseUp " +
                "without valid surface mapping virtualAtUp=\(InputSurfaceDiagnostics.pointString(virtualPointAtUp))"
            )
        }
    }

    private func postPointerFeedback(kind: String, point: CGPoint) {
        guard InputSurfaceDiagnostics.isFinite(point), InputSurfaceDiagnostics.isFinite(pointerSurfaceSize) else {
            appendLog("[PointerFeedback] skipped non-finite feedback kind=\(kind) point=\(InputSurfaceDiagnostics.pointString(point)) surface=\(InputSurfaceDiagnostics.sizeString(pointerSurfaceSize))")
            return
        }

        DispatchQueue.main.async {
            NotificationCenter.default.post(
                name: .easyBluetoothPointerFeedback,
                object: nil,
                userInfo: [
                    "kind": kind,
                    "x": point.x,
                    "y": point.y,
                    "width": self.pointerSurfaceSize.width,
                    "height": self.pointerSurfaceSize.height,
                ]
            )
        }
    }

    private func postPointerSpikeVisualization(
        phase: String,
        sequence: Int,
        targetPhonePoint: CGPoint,
        mappedPhonePoint: CGPoint?,
        virtualPhonePoint: CGPoint?,
        actualPhonePoint: CGPoint?,
        note: String
    ) {
        guard easyPointerSpikeEnabled else { return }
        guard InputSurfaceDiagnostics.isFinite(targetPhonePoint),
              mappedPhonePoint.map(InputSurfaceDiagnostics.isFinite) ?? true,
              virtualPhonePoint.map(InputSurfaceDiagnostics.isFinite) ?? true,
              actualPhonePoint.map(InputSurfaceDiagnostics.isFinite) ?? true,
              InputSurfaceDiagnostics.isFinite(pointerSurfaceSize) else {
            appendLog("[PointerSpike] visualization skipped non-finite phase=\(phase) target=\(InputSurfaceDiagnostics.pointString(targetPhonePoint)) mapped=\(mappedPhonePoint.map(InputSurfaceDiagnostics.pointString) ?? "nil") virtual=\(virtualPhonePoint.map(InputSurfaceDiagnostics.pointString) ?? "nil") actual=\(actualPhonePoint.map(InputSurfaceDiagnostics.pointString) ?? "nil") surface=\(InputSurfaceDiagnostics.sizeString(pointerSurfaceSize))")
            return
        }

        DispatchQueue.main.async {
            var userInfo: [String: Any] = [
                "phase": phase,
                "sequence": sequence,
                "variant": self.easyPointerSpikeVariant,
                "targetX": targetPhonePoint.x,
                "targetY": targetPhonePoint.y,
                "surfaceWidth": self.pointerSurfaceSize.width,
                "surfaceHeight": self.pointerSurfaceSize.height,
                "note": note,
            ]
            if let mappedPhonePoint {
                userInfo["mappedX"] = mappedPhonePoint.x
                userInfo["mappedY"] = mappedPhonePoint.y
            }
            if let virtualPhonePoint {
                userInfo["virtualX"] = virtualPhonePoint.x
                userInfo["virtualY"] = virtualPhonePoint.y
            }
            if let actualPhonePoint {
                userInfo["actualX"] = actualPhonePoint.x
                userInfo["actualY"] = actualPhonePoint.y
            }
            NotificationCenter.default.post(
                name: .easyPointerSpikeVisualization,
                object: nil,
                userInfo: userInfo
            )
        }
    }

    private func clampPhonePointToSurface(_ point: CGPoint) -> CGPoint {
        let width = pointerSurfaceSize.width.isFinite ? max(0, pointerSurfaceSize.width) : 0
        let height = pointerSurfaceSize.height.isFinite ? max(0, pointerSurfaceSize.height) : 0
        let fallbackX = virtualPointerPoint.x.isFinite ? virtualPointerPoint.x : width / 2
        let fallbackY = virtualPointerPoint.y.isFinite ? virtualPointerPoint.y : height / 2
        let rawX = point.x.isFinite ? point.x : fallbackX
        let rawY = point.y.isFinite ? point.y : fallbackY
        return CGPoint(
            x: min(max(rawX, 0), width),
            y: min(max(rawY, 0), height)
        )
    }

    private func movePointer(to phonePoint: CGPoint, reason: String, buttons: UInt8 = 0, origin: PointerMoveOrigin = .predicted) {
        guard interruptChannel != nil else {
            appendLog("[Pointer] move ignored, interrupt channel not connected")
            return
        }

        let clamped = clampPhonePointToSurface(phonePoint)
        if absolutePointerTransportEnabled {
            appendLog(
                "[PointerABS] move reason=\(reason) origin=\(origin.rawValue) " +
                "toTopLeft=\(InputSurfaceDiagnostics.pointString(clamped)) buttons=\(buttons)"
            )
            sendAbsolutePointerReport(point: clamped, buttons: buttons, reason: reason)
            return
        }

        let sourcePoint: CGPoint
        switch origin {
        case .predicted:
            sourcePoint = virtualPointerPoint
        case .authoritativeActual:
            sourcePoint = lastCalibrationActualPoint.map(clampPhonePointToSurface) ?? virtualPointerPoint
        }

        let deltaX = clamped.x - sourcePoint.x
        let deltaY = clamped.y - sourcePoint.y
        guard pointerTransportScaleX.isFinite,
              pointerTransportScaleY.isFinite,
              abs(pointerTransportScaleX) > .ulpOfOne,
              abs(pointerTransportScaleY) > .ulpOfOne,
              deltaX.isFinite,
              deltaY.isFinite else {
            appendLog("[Pointer] move dropped reason=\(reason) branch=non-finite-delta-or-scale source=\(InputSurfaceDiagnostics.pointString(sourcePoint)) target=\(InputSurfaceDiagnostics.pointString(clamped)) scale=(\(pointerTransportScaleX),\(pointerTransportScaleY))")
            return
        }
        let reportDeltaX = deltaX / pointerTransportScaleX
        let reportDeltaY = deltaY / pointerTransportScaleY
        guard reportDeltaX.isFinite, reportDeltaY.isFinite else {
            appendLog("[Pointer] move dropped reason=\(reason) branch=non-finite-report-delta reportDelta=(\(reportDeltaX),\(reportDeltaY)) scale=(\(pointerTransportScaleX),\(pointerTransportScaleY))")
            return
        }
        lastPointerReportDelta = CGPoint(x: reportDeltaX, y: reportDeltaY)
        calibrationReportDeltaSinceLastSample.x += reportDeltaX
        calibrationReportDeltaSinceLastSample.y += reportDeltaY
        appendLog("[Pointer] move reason=\(reason) origin=\(origin.rawValue) from=\(InputSurfaceDiagnostics.pointString(sourcePoint)) predictedBefore=\(InputSurfaceDiagnostics.pointString(virtualPointerPoint)) lastActual=\(lastCalibrationActualPoint.map(InputSurfaceDiagnostics.pointString) ?? "n/a") to=\(InputSurfaceDiagnostics.pointString(clamped)) logicalDelta=\(InputSurfaceDiagnostics.pointString(CGPoint(x: deltaX, y: deltaY))) reportDelta=\(InputSurfaceDiagnostics.pointString(CGPoint(x: reportDeltaX, y: reportDeltaY))) scale=(\(String(format: "%.3f", pointerTransportScaleX)),\(String(format: "%.3f", pointerTransportScaleY))) buttons=\(buttons)")

        sendRelativePointerDelta(dx: reportDeltaX, dy: reportDeltaY, buttons: buttons)
        virtualPointerPoint = clamped
    }

    private func sendRelativePointerDelta(dx: CGFloat, dy: CGFloat, buttons: UInt8) {
        guard dx.isFinite, dy.isFinite else {
            appendLog("[Pointer] relative delta dropped branch=non-finite dx=\(dx) dy=\(dy)")
            return
        }

        var remainingX = Int(dx.rounded())
        var remainingY = Int(dy.rounded())
        var steps = 0

        while remainingX != 0 || remainingY != 0 {
            let stepX = max(-127, min(127, remainingX))
            let stepY = max(-127, min(127, remainingY))
            sendMouseReport(
                buttons: buttons,
                dx: Int8(clamping: stepX),
                dy: Int8(clamping: stepY),
                dz: 0,
                wheel: 0
            )
            remainingX -= stepX
            remainingY -= stepY
            steps += 1
        }

        if steps > 1 || mouseEventCount <= 5 || mouseEventCount % 200 == 0 {
            appendLog("[Pointer] relative delta sent steps=\(steps)")
        }
    }

    private func sendPointerButtonReport(buttons: UInt8, mapping: PointerInputMapping?, reason: String) {
        if absolutePointerTransportEnabled {
            let point = mapping?.phonePoint ?? virtualPointerPoint
            if mapping == nil {
                appendLog("[PointerABS] \(reason) has no event mapping; reusing virtual pointer topLeft=\(InputSurfaceDiagnostics.pointString(point))")
            }
            sendAbsolutePointerReport(point: point, buttons: buttons, reason: reason)
        } else {
            appendLog("[Pointer] \(reason) using relative mouse button report buttons=\(buttons)")
            sendMouseReport(buttons: buttons, dx: 0, dy: 0, dz: 0, wheel: 0)
        }
    }

    private func sendAllPointerButtonsReleased(reason: String) {
        appendLog("[Pointer] releasing all pointer buttons reason=\(reason) absoluteMouseReport=\(absolutePointerTransportEnabled)")
        sendMouseReport(buttons: 0, dx: 0, dy: 0, dz: 0, wheel: 0)
        if absolutePointerTransportEnabled {
            sendAbsolutePointerReport(point: virtualPointerPoint, buttons: 0, reason: "\(reason):absolute-release")
        }
    }

    private func sendAbsolutePointerReport(point: CGPoint, buttons: UInt8, reason: String) {
        guard let channel = interruptChannel else {
            appendLog("[PointerABS] ERROR: sendAbsolutePointerReport called but interruptChannel is nil reason=\(reason)")
            return
        }
        guard canForwardUserHIDInput(source: "PointerABS") else {
            appendLog("[InputGate] absolute pointer report ignored reason=\(reason)")
            return
        }
        guard InputSurfaceDiagnostics.isFinite(pointerSurfaceSize), pointerSurfaceSize.width > 0, pointerSurfaceSize.height > 0 else {
            appendLog("[PointerABS] ERROR: invalid pointer surface size=\(InputSurfaceDiagnostics.sizeString(pointerSurfaceSize)) reason=\(reason)")
            return
        }

        let clamped = clampPhonePointToSurface(point)
        let logicalX = absolutePointerLogicalValue(clamped.x, extent: pointerSurfaceSize.width)
        let logicalY = absolutePointerLogicalValue(clamped.y, extent: pointerSurfaceSize.height)
        let buttonByte = buttons & 0x03
        var report: [UInt8] = [
            0xA1,
            Self.absolutePointerReportID,
            buttonByte,
            UInt8(logicalX & 0x00FF),
            UInt8((logicalX & 0xFF00) >> 8),
            UInt8(logicalY & 0x00FF),
            UInt8((logicalY & 0xFF00) >> 8),
        ]

        lastPointerReportDelta = .zero
        virtualPointerPoint = clamped
        mouseReportCount += 1
        interruptWritesInFlight += 1
        let shouldLog = mouseReportCount <= 10 || mouseReportCount % 100 == 0 || easyPointerSpikeEnabled
        if shouldLog {
            let hex = report.map { String(format: "%02X", $0) }.joined(separator: " ")
            appendLog(
                "[PointerABS] Report #\(mouseReportCount) reason=\(reason) bytes=[\(hex)] " +
                "buttons=\(buttonByte) phoneTopLeft=\(InputSurfaceDiagnostics.pointString(clamped)) " +
                "logical=(\(logicalX),\(logicalY)) surface=\(InputSurfaceDiagnostics.sizeString(pointerSurfaceSize))"
            )
        }
        if interruptWritesInFlight > 8 {
            appendLog("[MousePerf] interrupt writes backing up inFlight=\(interruptWritesInFlight) reports=\(mouseReportCount) events=\(mouseEventCount)")
        }

        let result = channel.writeAsync(&report, length: UInt16(report.count), refcon: nil)
        if result != kIOReturnSuccess {
            interruptWritesInFlight = max(0, interruptWritesInFlight - 1)
            appendLog("[PointerABS] writeAsync FAILED: \(result) (report #\(mouseReportCount)) reason=\(reason)")
        }
    }

    private func absolutePointerLogicalValue(_ value: CGFloat, extent: CGFloat) -> UInt16 {
        guard value.isFinite, extent.isFinite, extent > 0 else {
            return 0
        }

        let normalized = min(max(value / extent, 0), 1)
        guard normalized.isFinite else { return 0 }
        return UInt16(clamping: Int((normalized * Self.absolutePointerLogicalMax).rounded()))
    }

    private struct PointerCalibrationEvent: Decodable {
        let type: String
        let sequence: Int?
        let kind: String?
        let targetID: String?
        let coordinateOrigin: String?
        let index: Int
        let expectedX: Double
        let expectedY: Double
        let actualX: Double
        let actualY: Double
        let width: Double
        let height: Double
        let timestamp: Double
    }

    private func handleCalibrationListenerState(_ state: NWListener.State) {
        switch state {
        case .ready:
            appendLog("[Calibration] listener ready on port \(calibrationPort)")
        case .waiting(let error):
            appendLog("[Calibration] listener waiting: \(error.localizedDescription)")
        case .failed(let error):
            appendLog("[Calibration] listener failed: \(error.localizedDescription)")
            calibrationListener?.cancel()
            calibrationListener = nil
        case .cancelled:
            appendLog("[Calibration] listener cancelled")
        case .setup:
            appendLog("[Calibration] listener setup")
        @unknown default:
            appendLog("[Calibration] listener unknown state")
        }
    }

    private func acceptCalibrationConnection(_ connection: NWConnection) {
        appendLog("[Calibration] incoming iOS calibration connection")
        calibrationConnection?.cancel()
        calibrationConnection = connection
        calibrationReceiveBuffer.removeAll()

        connection.stateUpdateHandler = { [weak self, weak connection] state in
            guard let self, let connection else { return }
            switch state {
            case .ready:
                self.appendLog("[Calibration] connection ready")
                self.receiveCalibrationData(on: connection)
            case .waiting(let error):
                self.appendLog("[Calibration] connection waiting: \(error.localizedDescription)")
            case .failed(let error):
                self.appendLog("[Calibration] connection failed: \(error.localizedDescription)")
            case .cancelled:
                self.appendLog("[Calibration] connection cancelled")
            case .setup, .preparing:
                break
            @unknown default:
                self.appendLog("[Calibration] connection unknown state")
            }
        }
        connection.start(queue: calibrationQueue)
    }

    private func receiveCalibrationData(on connection: NWConnection) {
        guard connection === calibrationConnection else {
            appendLog("[Calibration] receive ignored for stale connection")
            return
        }

        connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) { [weak self, weak connection] data, _, isComplete, error in
            guard let self, let connection else { return }
            if let data, !data.isEmpty {
                self.calibrationReceiveBuffer.append(data)
                self.processCalibrationBuffer()
            }
            if let error {
                self.appendLog("[Calibration] receive failed: \(error.localizedDescription)")
                return
            }
            if isComplete {
                self.appendLog("[Calibration] connection completed receive")
                return
            }
            self.receiveCalibrationData(on: connection)
        }
    }

    private func processCalibrationBuffer() {
        while let newline = calibrationReceiveBuffer.firstIndex(of: 0x0A) {
            let packet = calibrationReceiveBuffer[..<newline]
            calibrationReceiveBuffer.removeSubrange(...newline)
            guard !packet.isEmpty else { continue }
            do {
                let event = try JSONDecoder().decode(PointerCalibrationEvent.self, from: Data(packet))
                applyCalibrationEvent(event)
            } catch {
                let text = String(data: Data(packet), encoding: .utf8) ?? "<non-utf8>"
                appendLog("[Calibration] decode failed: \(error.localizedDescription) packet=\(text)")
            }
        }
    }

    private func applyCalibrationEvent(_ event: PointerCalibrationEvent) {
        guard event.type == "pointerCalibrationTap" || event.type == "pointerCalibrationMeasurement" else {
            appendLog("[Calibration] ignoring event type=\(event.type)")
            return
        }
        guard event.width > 0, event.height > 0 else {
            appendLog("[Calibration] invalid iOS surface width=\(event.width) height=\(event.height)")
            return
        }

        let expectedRaw = CGPoint(
            x: CGFloat(event.expectedX / event.width) * pointerSurfaceSize.width,
            y: CGFloat(event.expectedY / event.height) * pointerSurfaceSize.height
        )
        let actualRaw = CGPoint(
            x: CGFloat(event.actualX / event.width) * pointerSurfaceSize.width,
            y: CGFloat(event.actualY / event.height) * pointerSurfaceSize.height
        )
        let expected = clampPhonePointToSurface(expectedRaw)
        let actual = clampPhonePointToSurface(actualRaw)
        if expected != expectedRaw || actual != actualRaw {
            appendLog(
                "[Calibration] clamped raw coordinates expectedRaw=(\(Int(expectedRaw.x)),\(Int(expectedRaw.y))) " +
                "actualRaw=(\(Int(actualRaw.x)),\(Int(actualRaw.y))) " +
                "expected=(\(Int(expected.x)),\(Int(expected.y))) actual=(\(Int(actual.x)),\(Int(actual.y)))"
            )
        }
        let targetError = CGPoint(x: actual.x - expected.x, y: actual.y - expected.y)
        let sequence = event.sequence ?? event.index
        let matchedAttempt = pendingPointerSpikeAttempts.isEmpty ? nil : pendingPointerSpikeAttempts.removeFirst()
        let mappedPoint = matchedAttempt?.mappingAtUp?.phonePoint ?? matchedAttempt?.mappingAtDown.phonePoint
        let mappedError = mappedPoint.map { CGPoint(x: actual.x - $0.x, y: actual.y - $0.y) }
        let virtualPoint = matchedAttempt?.virtualPointAtUp ?? matchedAttempt?.virtualPointAtDown
        let virtualError = virtualPoint.map { CGPoint(x: actual.x - $0.x, y: actual.y - $0.y) }

        let reportDelta = calibrationReportDeltaSinceLastSample
        appendLog(
            "[Calibration] sample sequence=\(sequence) index=\(event.index) kind=\(event.kind ?? "tap") " +
            "coordinateOrigin=\(event.coordinateOrigin ?? "topLeft-assumed") " +
            "expectedTopLeft=(\(Int(expected.x)),\(Int(expected.y))) actualTopLeft=(\(Int(actual.x)),\(Int(actual.y))) " +
            "targetError=(\(Int(targetError.x)),\(Int(targetError.y))) accumulatedReportDelta=(\(Int(reportDelta.x)),\(Int(reportDelta.y)))"
        )
        if let matchedAttempt {
            appendLog(
                "[PointerSpike] matched calibration sequence=\(sequence) to tap sequence=\(matchedAttempt.sequence) " +
                "queuedAt=\(String(format: "%.3f", matchedAttempt.createdAt)) eventType=\(matchedAttempt.eventType.rawValue) " +
                "mappedDown=(\(Int(matchedAttempt.mappingAtDown.phonePoint.x)),\(Int(matchedAttempt.mappingAtDown.phonePoint.y))) " +
                "mappedUp=\(matchedAttempt.mappingAtUp.map { "(\(Int($0.phonePoint.x)),\(Int($0.phonePoint.y)))" } ?? "n/a") " +
                "virtualDown=(\(Int(matchedAttempt.virtualPointAtDown.x)),\(Int(matchedAttempt.virtualPointAtDown.y))) " +
                "virtualUp=\(matchedAttempt.virtualPointAtUp.map { "(\(Int($0.x)),\(Int($0.y)))" } ?? "n/a")"
            )
        } else if easyPointerSpikeEnabled {
            appendLog("[PointerSpike] calibration sample sequence=\(sequence) arrived with no pending Mac tap attempt")
        }
        if let mappedError {
            appendLog("[PointerSpike] mappedError=(\(Int(mappedError.x)),\(Int(mappedError.y)))")
        }
        if let virtualError {
            appendLog("[PointerSpike] virtualError=(\(Int(virtualError.x)),\(Int(virtualError.y)))")
        }

        if let previousActual = lastCalibrationActualPoint {
            let actualDelta = CGPoint(x: actual.x - previousActual.x, y: actual.y - previousActual.y)
            if absolutePointerTransportEnabled {
                appendLog("[PointerABS] scale update skipped for absolute report transport actualDelta=(\(Int(actualDelta.x)),\(Int(actualDelta.y)))")
            } else {
                updateTransportScale(actualDelta: actualDelta, reportDelta: reportDelta)
            }
        } else {
            appendLog(easyPointerSpikeEnabled
                      ? "[PointerSpike] first sample anchors closed-loop actual pointer state"
                      : "[Calibration] first sample anchors virtual pointer state")
        }

        lastCalibrationActualPoint = actual
        calibrationReportDeltaSinceLastSample = .zero
        virtualPointerPoint = actual
        if easyPointerSpikeEnabled {
            appendLog(
                "[PointerSpike] closed-loop sync actual=(\(Int(actual.x)),\(Int(actual.y))) " +
                "reportDelta=(\(Int(reportDelta.x)),\(Int(reportDelta.y))) " +
                "scale=(\(String(format: "%.3f", pointerTransportScaleX)),\(String(format: "%.3f", pointerTransportScaleY)))"
            )
        } else {
            appendLog("[Calibration] virtual pointer synced to actual=(\(Int(actual.x)),\(Int(actual.y)))")
        }
        recordPointerSpikeSample(
            sequence: matchedAttempt?.sequence ?? sequence,
            targetID: event.targetID,
            index: event.index,
            target: expected,
            mappedPoint: mappedPoint,
            virtualPoint: virtualPoint,
            actual: actual,
            targetError: targetError,
            mappedError: mappedError,
            virtualError: virtualError,
            timestamp: event.timestamp
        )
        postPointerSpikeVisualization(
            phase: "measuredTap",
            sequence: matchedAttempt?.sequence ?? sequence,
            targetPhonePoint: expected,
            mappedPhonePoint: mappedPoint,
            virtualPhonePoint: virtualPoint,
            actualPhonePoint: actual,
            note: "Calibration sample \(event.index + 1)"
        )
    }

    private func recordPointerSpikeSample(
        sequence: Int,
        targetID: String?,
        index: Int,
        target: CGPoint,
        mappedPoint: CGPoint?,
        virtualPoint: CGPoint?,
        actual: CGPoint,
        targetError: CGPoint,
        mappedError: CGPoint?,
        virtualError: CGPoint?,
        timestamp: TimeInterval
    ) {
        guard easyPointerSpikeEnabled else { return }

        let targetDistance = hypot(targetError.x, targetError.y)
        let mappedDistance = mappedError.map { hypot($0.x, $0.y) }
        let virtualDistance = virtualError.map { hypot($0.x, $0.y) }
        let sample = PointerSpikeSample(
            sequence: sequence,
            variant: easyPointerSpikeVariant,
            targetID: targetID,
            index: index,
            targetPoint: target,
            mappedClickPoint: mappedPoint,
            virtualPointerPoint: virtualPoint,
            actualPoint: actual,
            targetErrorPoint: targetError,
            targetErrorDistance: targetDistance,
            mappedErrorPoint: mappedError,
            mappedErrorDistance: mappedDistance,
            virtualErrorPoint: virtualError,
            virtualErrorDistance: virtualDistance,
            timestamp: timestamp
        )
        pointerSpikeSamples.append(sample)
        if pointerSpikeSamples.count > 100 {
            pointerSpikeSamples.removeFirst(pointerSpikeSamples.count - 100)
        }

        let count = pointerSpikeSamples.count
        let meanTargetDistance = pointerSpikeSamples.reduce(CGFloat.zero) { $0 + $1.targetErrorDistance } / CGFloat(max(count, 1))
        let maxTargetDistance = pointerSpikeSamples.map(\.targetErrorDistance).max() ?? targetDistance
        let mappedDistances = pointerSpikeSamples.compactMap(\.mappedErrorDistance)
        let meanMappedDistance = mappedDistances.isEmpty ? nil : mappedDistances.reduce(CGFloat.zero, +) / CGFloat(mappedDistances.count)
        let maxMappedDistance = mappedDistances.max()
        let virtualDistances = pointerSpikeSamples.compactMap(\.virtualErrorDistance)
        let meanVirtualDistance = virtualDistances.isEmpty ? nil : virtualDistances.reduce(CGFloat.zero, +) / CGFloat(virtualDistances.count)
        let maxVirtualDistance = virtualDistances.max()
        appendLog(
            "[PointerSpike] recorded sample sequence=\(sequence) targetID=\(targetID ?? "none") index=\(index) " +
            "targetError=(\(Int(targetError.x)),\(Int(targetError.y))) targetDistance=\(String(format: "%.2f", targetDistance)) " +
            "mappedDistance=\(mappedDistance.map { String(format: "%.2f", $0) } ?? "n/a") " +
            "virtualDistance=\(virtualDistance.map { String(format: "%.2f", $0) } ?? "n/a") " +
            "count=\(count) meanTargetDistance=\(String(format: "%.2f", meanTargetDistance)) " +
            "maxTargetDistance=\(String(format: "%.2f", maxTargetDistance)) " +
            "meanMappedDistance=\(meanMappedDistance.map { String(format: "%.2f", $0) } ?? "n/a") " +
            "maxMappedDistance=\(maxMappedDistance.map { String(format: "%.2f", $0) } ?? "n/a") " +
            "meanVirtualDistance=\(meanVirtualDistance.map { String(format: "%.2f", $0) } ?? "n/a") " +
            "maxVirtualDistance=\(maxVirtualDistance.map { String(format: "%.2f", $0) } ?? "n/a")"
        )
        postPointerSpikeMetrics(
            latestSample: sample,
            count: count,
            meanTargetDistance: meanTargetDistance,
            maxTargetDistance: maxTargetDistance,
            meanMappedDistance: meanMappedDistance,
            maxMappedDistance: maxMappedDistance,
            meanVirtualDistance: meanVirtualDistance,
            maxVirtualDistance: maxVirtualDistance
        )
    }

    private func postPointerSpikeMetrics(
        latestSample: PointerSpikeSample,
        count: Int,
        meanTargetDistance: CGFloat,
        maxTargetDistance: CGFloat,
        meanMappedDistance: CGFloat?,
        maxMappedDistance: CGFloat?,
        meanVirtualDistance: CGFloat?,
        maxVirtualDistance: CGFloat?
    ) {
        DispatchQueue.main.async {
            var userInfo: [String: Any] = [
                "variant": latestSample.variant,
                "sequence": latestSample.sequence,
                "targetID": latestSample.targetID ?? "none",
                "index": latestSample.index,
                "count": count,
                "meanTargetDistance": Double(meanTargetDistance),
                "maxTargetDistance": Double(maxTargetDistance),
                "latestTargetDistance": Double(latestSample.targetErrorDistance),
                "latestTargetErrorX": Double(latestSample.targetErrorPoint.x),
                "latestTargetErrorY": Double(latestSample.targetErrorPoint.y),
                "timestamp": latestSample.timestamp,
            ]
            if let mappedErrorDistance = latestSample.mappedErrorDistance,
               let mappedErrorPoint = latestSample.mappedErrorPoint,
               let meanMappedDistance,
               let maxMappedDistance {
                userInfo["meanMappedDistance"] = Double(meanMappedDistance)
                userInfo["maxMappedDistance"] = Double(maxMappedDistance)
                userInfo["latestMappedDistance"] = Double(mappedErrorDistance)
                userInfo["latestMappedErrorX"] = Double(mappedErrorPoint.x)
                userInfo["latestMappedErrorY"] = Double(mappedErrorPoint.y)
            }
            if let virtualErrorDistance = latestSample.virtualErrorDistance,
               let virtualErrorPoint = latestSample.virtualErrorPoint,
               let meanVirtualDistance,
               let maxVirtualDistance {
                userInfo["meanVirtualDistance"] = Double(meanVirtualDistance)
                userInfo["maxVirtualDistance"] = Double(maxVirtualDistance)
                userInfo["latestVirtualDistance"] = Double(virtualErrorDistance)
                userInfo["latestVirtualErrorX"] = Double(virtualErrorPoint.x)
                userInfo["latestVirtualErrorY"] = Double(virtualErrorPoint.y)
            }
            NotificationCenter.default.post(
                name: .easyPointerSpikeMetrics,
                object: nil,
                userInfo: userInfo
            )
        }
    }

    private func postPointerSpikeMetricsReset() {
        DispatchQueue.main.async {
            NotificationCenter.default.post(
                name: .easyPointerSpikeMetrics,
                object: nil,
                userInfo: [
                    "reset": true,
                    "variant": self.easyPointerSpikeVariant,
                ]
            )
        }
    }

    private func updateTransportScale(actualDelta: CGPoint, reportDelta: CGPoint) {
        let minMovement: CGFloat = 24
        if abs(reportDelta.x) >= minMovement, abs(actualDelta.x) >= minMovement {
            let sample = actualDelta.x / reportDelta.x
            if sample.isFinite, sample > 0.25, sample < 8 {
                calibrationScaleSamplesX.append(sample)
                pointerTransportScaleX = median(calibrationScaleSamplesX)
                appendLog("[Calibration] updated X scale sample=\(String(format: "%.3f", sample)) median=\(String(format: "%.3f", pointerTransportScaleX)) count=\(calibrationScaleSamplesX.count)")
            } else {
                appendLog("[Calibration] rejected X scale sample=\(String(describing: sample))")
            }
        } else {
            appendLog("[Calibration] skipped X scale actualDelta=\(Int(actualDelta.x)) reportDelta=\(Int(reportDelta.x))")
        }

        if abs(reportDelta.y) >= minMovement, abs(actualDelta.y) >= minMovement {
            let sample = actualDelta.y / reportDelta.y
            if sample.isFinite, sample > 0.25, sample < 8 {
                calibrationScaleSamplesY.append(sample)
                pointerTransportScaleY = median(calibrationScaleSamplesY)
                appendLog("[Calibration] updated Y scale sample=\(String(format: "%.3f", sample)) median=\(String(format: "%.3f", pointerTransportScaleY)) count=\(calibrationScaleSamplesY.count)")
            } else {
                appendLog("[Calibration] rejected Y scale sample=\(String(describing: sample))")
            }
        } else {
            appendLog("[Calibration] skipped Y scale actualDelta=\(Int(actualDelta.y)) reportDelta=\(Int(reportDelta.y))")
        }
    }

    private func median(_ values: [CGFloat]) -> CGFloat {
        guard !values.isEmpty else { return 1 }
        let sorted = values.sorted()
        let middle = sorted.count / 2
        if sorted.count.isMultiple(of: 2) {
            return (sorted[middle - 1] + sorted[middle]) / 2
        }
        return sorted[middle]
    }

    /// HID Report ID 10 (0x0A): Mouse report
    /// Format: [0xA1, 0x0A, buttons, dx, dy, dz, wheel]
    /// buttons: bit 0 = left, bit 1 = right
    /// dx/dy/dz/wheel: signed -127 to 127
    private func sendMouseReport(buttons: UInt8, dx: Int8, dy: Int8, dz: Int8, wheel: Int8) {
        guard let channel = interruptChannel else {
            appendLog("[Mouse] ERROR: sendMouseReport called but interruptChannel is nil")
            return
        }
        guard canForwardUserHIDInput(source: "MouseReport") else {
            appendLog("[InputGate] relative mouse report ignored buttons=\(buttons) dx=\(dx) dy=\(dy) wheel=\(wheel)")
            return
        }

        var report: [UInt8] = [
            0xA1,              // DATA | INPUT (BT HID header)
            0x0A,              // Report ID 10 (mouse)
            buttons,           // button state
            UInt8(bitPattern: dx),
            UInt8(bitPattern: dy),
            UInt8(bitPattern: dz),
            UInt8(bitPattern: wheel),
        ]

        mouseReportCount += 1
        interruptWritesInFlight += 1
        let shouldLog = mouseReportCount <= 10 || mouseReportCount % 100 == 0
        if shouldLog {
            let hex = report.map { String(format: "%02X", $0) }.joined(separator: " ")
            appendLog("[Mouse] Report #\(mouseReportCount): [\(hex)] btns=\(buttons) dx=\(dx) dy=\(dy) wheel=\(wheel)")
        }
        if interruptWritesInFlight > 8 {
            appendLog("[MousePerf] interrupt writes backing up inFlight=\(interruptWritesInFlight) reports=\(mouseReportCount) events=\(mouseEventCount)")
        }

        let result = channel.writeAsync(&report, length: UInt16(report.count), refcon: nil)
        if result != kIOReturnSuccess {
            interruptWritesInFlight = max(0, interruptWritesInFlight - 1)
            appendLog("[Mouse] writeAsync FAILED: \(result) (report #\(mouseReportCount))")
        }
    }

    private func maybeLogMousePerformance(force: Bool = false, reason: String) {
        let now = CACurrentMediaTime()
        let elapsed = now - mouseStatsWindowStartedAt
        guard force || elapsed >= 1.0 else { return }

        let events = mouseEventCount - mouseEventsAtWindowStart
        let reports = mouseReportCount - mouseReportsAtWindowStart
        let completions = mouseWriteCompletionCount - mouseWriteCompletionsAtWindowStart
        appendLog(
            "[MousePerf] reason=\(reason) windowMs=\(Int(elapsed * 1000)) events=\(events) reports=\(reports) completions=\(completions) inFlight=\(interruptWritesInFlight) clutchEnabled=\(easyMouseClutchModeEnabled) clutchLatched=\(isMouseMovementClutched) dragButtonDown=\(isSwipeButtonDownOnPhone)"
        )

        mouseStatsWindowStartedAt = now
        mouseEventsAtWindowStart = mouseEventCount
        mouseReportsAtWindowStart = mouseReportCount
        mouseWriteCompletionsAtWindowStart = mouseWriteCompletionCount
    }

    private func sendKeyboardReport(modifiers: UInt8) {
        let keys = Array(pressedHIDKeys.prefix(6))
        _ = writeKeyboardReport(modifiers: modifiers, keys: keys, source: "KeyboardReport")
    }

    private func scheduleKeyboardUsage(
        _ keyCode: UInt8,
        modifiers: UInt8,
        source: String,
        delay: TimeInterval,
        bypassInputGate: Bool
    ) {
        appendLog("[EasyAutoUnlock] schedule keyboard usage source=\(source) delay=\(String(format: "%.2f", delay)) key=0x\(String(format: "%02X", keyCode)) modifiers=0x\(String(format: "%02X", modifiers)) bypass=\(bypassInputGate)")
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self else { return }
            let pressed = self.writeKeyboardReport(
                modifiers: modifiers,
                keys: [keyCode],
                source: "\(source) press",
                bypassInputGate: bypassInputGate
            )
            self.appendLog("[EasyAutoUnlock] keyboard press source=\(source) result=\(pressed)")

            DispatchQueue.main.asyncAfter(deadline: .now() + EasyAutoUnlockSequenceTiming.keyHoldDuration) { [weak self] in
                guard let self else { return }
                let released = self.writeKeyboardReport(
                    modifiers: 0x00,
                    keys: [],
                    source: "\(source) release",
                    bypassInputGate: bypassInputGate
                )
                self.appendLog("[EasyAutoUnlock] keyboard release source=\(source) result=\(released)")
            }
        }
    }

    @discardableResult
    private func writeKeyboardReport(modifiers: UInt8, keys: [UInt8], source: String, bypassInputGate: Bool = false) -> Bool {
        guard let channel = interruptChannel else {
            appendLog("[KeyboardReport] \(source) ignored: no interrupt channel modifiers=0x\(String(format: "%02X", modifiers)) keys=\(Self.hidKeyListDescription(keys))")
            return false
        }
        guard bypassInputGate || canForwardUserHIDInput(source: source) else {
            appendLog("[InputGate] \(source) keyboard report ignored modifiers=0x\(String(format: "%02X", modifiers)) keys=\(Self.hidKeyListDescription(keys))")
            return false
        }
        if bypassInputGate {
            appendLog("[InputGate] \(source) keyboard report bypassing ReplayKit gate reason=EasyAutoUnlock modifiers=0x\(String(format: "%02X", modifiers)) keys=\(Self.hidKeyListDescription(keys))")
        }

        let reportKeys = Array(keys.prefix(6))
        if keys.count > reportKeys.count {
            appendLog("[KeyboardReport] \(source) truncated keys requested=\(keys.count) sent=\(reportKeys.count)")
        }

        var report: [UInt8] = [
            0xA1, 0x01,
            modifiers,
            0x00,
            reportKeys.count > 0 ? reportKeys[0] : 0x00,
            reportKeys.count > 1 ? reportKeys[1] : 0x00,
            reportKeys.count > 2 ? reportKeys[2] : 0x00,
            reportKeys.count > 3 ? reportKeys[3] : 0x00,
            reportKeys.count > 4 ? reportKeys[4] : 0x00,
            reportKeys.count > 5 ? reportKeys[5] : 0x00,
            0x00
        ]

        let result = channel.writeAsync(&report, length: UInt16(report.count), refcon: nil)
        appendLog("[KeyboardReport] \(source) writeAsync result=\(result) modifiers=0x\(String(format: "%02X", modifiers)) keys=\(Self.hidKeyListDescription(reportKeys))")
        return result == kIOReturnSuccess
    }

    static func modifierByteFromFlags(_ flags: NSEvent.ModifierFlags) -> UInt8 {
        var mods: UInt8 = 0
        if flags.contains(.control) { mods |= 0x01 }
        if flags.contains(.shift)   { mods |= 0x02 }
        if flags.contains(.option)  { mods |= 0x04 }
        if flags.contains(.command) { mods |= 0x08 }
        return mods
    }

    private static func hidKeyListDescription(_ keys: [UInt8]) -> String {
        "[" + keys.map { String(format: "0x%02X", $0) }.joined(separator: ",") + "]"
    }

    // MARK: - macOS KeyCode → HID Usage Mapping

    /// macOS virtual keyCode → USB HID keyboard usage code.
    /// Reference: USB HID Usage Tables §10 (Keyboard/Keypad Page 0x07)
    static let macKeyToHID: [UInt16: UInt8] = [
        // Letters (macOS ANSI keyCode → HID usage)
        0x00: 0x04, 0x0B: 0x05, 0x08: 0x06, 0x02: 0x07, // A B C D
        0x0E: 0x08, 0x03: 0x09, 0x05: 0x0A, 0x04: 0x0B, // E F G H
        0x22: 0x0C, 0x26: 0x0D, 0x28: 0x0E, 0x25: 0x0F, // I J K L
        0x2E: 0x10, 0x2D: 0x11, 0x1F: 0x12, 0x23: 0x13, // M N O P
        0x0C: 0x14, 0x0F: 0x15, 0x01: 0x16, 0x11: 0x17, // Q R S T
        0x20: 0x18, 0x09: 0x19, 0x0D: 0x1A, 0x07: 0x1B, // U V W X
        0x10: 0x1C, 0x06: 0x1D,                           // Y Z
        // Numbers
        0x12: 0x1E, 0x13: 0x1F, 0x14: 0x20, 0x15: 0x21, // 1 2 3 4
        0x17: 0x22, 0x16: 0x23, 0x1A: 0x24, 0x1C: 0x25, // 5 6 7 8
        0x19: 0x26, 0x1D: 0x27,                           // 9 0
        // Editing keys
        0x24: 0x28, // Return
        0x35: 0x29, // Escape
        0x33: 0x2A, // Delete (Backspace)
        0x30: 0x2B, // Tab
        0x31: 0x2C, // Space
        // Symbols
        0x1B: 0x2D, 0x18: 0x2E, 0x21: 0x2F, 0x1E: 0x30, // - = [ ]
        0x2A: 0x31, // Backslash
        0x29: 0x33, // Semicolon
        0x27: 0x34, // Quote
        0x32: 0x35, // Grave accent
        0x2B: 0x36, 0x2F: 0x37, 0x2C: 0x38,              // , . /
        0x39: 0x39, // Caps Lock
        // F-keys
        0x7A: 0x3A, 0x78: 0x3B, 0x63: 0x3C, 0x76: 0x3D, // F1 F2 F3 F4
        0x60: 0x3E, 0x61: 0x3F, 0x62: 0x40, 0x64: 0x41, // F5 F6 F7 F8
        0x65: 0x42, 0x6D: 0x43, 0x67: 0x44, 0x6F: 0x45, // F9 F10 F11 F12
        0x69: 0x68, 0x6B: 0x69, 0x71: 0x6A, 0x6A: 0x6B, // F13 F14 F15 F16
        0x40: 0x6C, 0x4F: 0x6D, 0x50: 0x6E,              // F17 F18 F19
        // Navigation
        0x73: 0x4A, // Home
        0x74: 0x4B, // Page Up
        0x75: 0x4C, // Forward Delete
        0x77: 0x4D, // End
        0x79: 0x4E, // Page Down
        0x7C: 0x4F, // Right Arrow
        0x7B: 0x50, // Left Arrow
        0x7D: 0x51, // Down Arrow
        0x7E: 0x52, // Up Arrow
        // Keypad
        0x47: 0x53, 0x4B: 0x54, 0x43: 0x55, 0x4E: 0x56, // Clear / * -
        0x45: 0x57, 0x4C: 0x58, 0x53: 0x59, 0x54: 0x5A, // + Enter KP1 KP2
        0x55: 0x5B, 0x56: 0x5C, 0x57: 0x5D, 0x58: 0x5E, // KP3 KP4 KP5 KP6
        0x59: 0x5F, 0x5B: 0x60, 0x5C: 0x61, 0x52: 0x62, // KP7 KP8 KP9 KP0
        0x41: 0x63, 0x51: 0x67,                            // KP. KP=
    ]

    /// macOS keyCode → consumer control bit position.
    /// Maps hardware media keys to consumer control report bits.
    static let macKeyToConsumerBit: [UInt16: UInt8] = [
        0x48: 10,  // VolumeUp
        0x49: 9,   // VolumeDown
        0x4A: 8,   // Mute
    ]

    static func charToHID(_ char: Character) -> (UInt8, UInt8)? {
        let lower = char.lowercased().first ?? char
        let shift: UInt8 = char.isUppercase ? 0x02 : 0x00
        let map: [Character: UInt8] = [
            "a": 0x04, "b": 0x05, "c": 0x06, "d": 0x07, "e": 0x08,
            "f": 0x09, "g": 0x0A, "h": 0x0B, "i": 0x0C, "j": 0x0D,
            "k": 0x0E, "l": 0x0F, "m": 0x10, "n": 0x11, "o": 0x12,
            "p": 0x13, "q": 0x14, "r": 0x15, "s": 0x16, "t": 0x17,
            "u": 0x18, "v": 0x19, "w": 0x1A, "x": 0x1B, "y": 0x1C,
            "z": 0x1D, "1": 0x1E, "2": 0x1F, "3": 0x20, "4": 0x21,
            "5": 0x22, "6": 0x23, "7": 0x24, "8": 0x25, "9": 0x26,
            "0": 0x27, " ": 0x2C, "-": 0x2D, "=": 0x2E, "[": 0x2F,
            "]": 0x30, "\\": 0x31, ";": 0x33, "'": 0x34, "`": 0x35,
            ",": 0x36, ".": 0x37, "/": 0x38,
        ]
        if let code = map[lower] { return (code, shift) }
        return nil
    }

    private func describeL2CAPChannel(_ channel: IOBluetoothL2CAPChannel?) -> String {
        guard let channel else { return "nil" }
        return "\(channel) PSM:\(channel.psm) objectID:\(channel.objectID)"
    }

    private func resetTrackedConnectionState(reason: String, closeChannels: Bool, closeConnection: Bool) {
        appendLog("[State] resetTrackedConnectionState reason=\(reason) closeChannels=\(closeChannels) closeConnection=\(closeConnection)")

        pendingControlChannelOpen = false
        pendingInterruptChannelOpen = false
        controlOpenAttemptID += 1
        interruptOpenAttemptID += 1
        didSendInitialReport = false
        runOnMain("resetTrackedConnectionState controls") { [weak self] in
            guard let self else { return }
            self.sendButton?.isEnabled = false
            self.specialKeyButtons.forEach { $0.isEnabled = false }
            self.mouseToggleBtn?.isEnabled = false
            self.stopMousePassthrough()
            self.stopKeyMonitoring()
        }

        let trackedControl = controlChannel
        let trackedInterrupt = interruptChannel
        let trackedPendingControl = pendingControlChannel
        let trackedPendingInterrupt = pendingInterruptChannel
        let trackedDevice = activeDevice
        let trackedDeviceName = activeDeviceName

        controlChannel = nil
        interruptChannel = nil
        pendingControlChannel = nil
        pendingInterruptChannel = nil
        publishBluetoothConnectionStatus(reason: "resetTrackedConnectionState \(reason)")

        if closeChannels {
            if let trackedControl {
                appendLog("[State] Clearing tracked control channel \(describeL2CAPChannel(trackedControl))")
                trackedControl.setDelegate(nil)
                let closeResult = trackedControl.close()
                appendLog("[State] controlChannel.close() = \(closeResult)")
            } else {
                appendLog("[State] No tracked control channel to close")
            }

            if let trackedInterrupt {
                appendLog("[State] Clearing tracked interrupt channel \(describeL2CAPChannel(trackedInterrupt))")
                trackedInterrupt.setDelegate(nil)
                let closeResult = trackedInterrupt.close()
                appendLog("[State] interruptChannel.close() = \(closeResult)")
            } else {
                appendLog("[State] No tracked interrupt channel to close")
            }

            if let trackedPendingControl, trackedPendingControl !== trackedControl {
                appendLog("[State] Clearing pending control channel \(describeL2CAPChannel(trackedPendingControl))")
                trackedPendingControl.setDelegate(nil)
                let closeResult = trackedPendingControl.close()
                appendLog("[State] pendingControlChannel.close() = \(closeResult)")
            } else {
                appendLog("[State] No separate pending control channel to close")
            }

            if let trackedPendingInterrupt, trackedPendingInterrupt !== trackedInterrupt {
                appendLog("[State] Clearing pending interrupt channel \(describeL2CAPChannel(trackedPendingInterrupt))")
                trackedPendingInterrupt.setDelegate(nil)
                let closeResult = trackedPendingInterrupt.close()
                appendLog("[State] pendingInterruptChannel.close() = \(closeResult)")
            } else {
                appendLog("[State] No separate pending interrupt channel to close")
            }
        } else {
            appendLog("[State] Leaving existing channel objects untouched")
        }

        if closeConnection, let trackedDevice {
            let trackedAddress = trackedDevice.addressString ?? "?"
            appendLog("[State] Tracked device before close = \(trackedDeviceName ?? trackedDevice.nameOrAddress ?? "?") [\(trackedAddress)] connected=\(trackedDevice.isConnected())")
            if trackedDevice.isConnected() {
                let closeResult = trackedDevice.closeConnection()
                appendLog("[State] trackedDevice.closeConnection() = \(closeResult)")
            } else {
                appendLog("[State] Tracked device was not ACL-connected; skipping closeConnection()")
            }
        } else if closeConnection {
            appendLog("[State] No tracked device to close")
        } else {
            appendLog("[State] Leaving ACL connection untouched")
        }

        activeDevice = nil
        activeDeviceName = nil
    }

    private func isTrackedDevice(_ device: IOBluetoothDevice) -> Bool {
        guard let activeDevice else { return false }
        return activeDevice == device || addressesMatch(activeDevice.addressString, device.addressString)
    }

    private func logPeerState(_ device: IOBluetoothDevice, prefix: String) {
        let peerLogger: BTDiagnosticLogger = { [weak self] message in
            self?.appendLog("\(prefix) \(message)")
        }
        btLogDevicePeerState(device, log: peerLogger)
    }

    private func requestControlChannelOpen(for device: IOBluetoothDevice, reason: String) {
        let address = device.addressString ?? "?"
        appendLog("[L2CAP] requestControlChannelOpen reason=\(reason) tracked=\(isTrackedDevice(device)) pendingControl=\(pendingControlChannelOpen) existingControl=\(controlChannel != nil)")
        logPeerState(device, prefix: "[L2CAP]")

        guard isTrackedDevice(device) else {
            appendLog("[L2CAP] Refusing control open for stale device [\(address)]")
            return
        }
        let peerAttached = attachClassicPeerIfAvailable(to: device, address: address, source: "l2cap-control-\(reason)")
        appendLog("[L2CAP] classic peer attach before control open reason=\(reason) attached=\(peerAttached)")
        guard controlChannel == nil else {
            appendLog("[L2CAP] Control channel already tracked; skipping duplicate request")
            requestInterruptChannelOpen(for: device, reason: "control already tracked")
            return
        }
        guard !pendingControlChannelOpen else {
            appendLog("[L2CAP] Control channel open already pending")
            return
        }

        pendingControlChannelOpen = true
        controlOpenAttemptID += 1
        let openAttemptID = controlOpenAttemptID
        appendLog("[L2CAP] opening control channel with KeyPad-style sync API PSM 17 attempt=\(openAttemptID) reason=\(reason)")
        openL2CAPChannelSync(for: device, psm: 17, attemptID: openAttemptID, reason: reason)
    }

    private func requestInterruptChannelOpen(for device: IOBluetoothDevice, reason: String) {
        let address = device.addressString ?? "?"
        appendLog("[L2CAP] requestInterruptChannelOpen reason=\(reason) tracked=\(isTrackedDevice(device)) pendingInterrupt=\(pendingInterruptChannelOpen) existingInterrupt=\(interruptChannel != nil)")
        logPeerState(device, prefix: "[L2CAP]")

        guard isTrackedDevice(device) else {
            appendLog("[L2CAP] Refusing interrupt open for stale device [\(address)]")
            return
        }
        let peerAttached = attachClassicPeerIfAvailable(to: device, address: address, source: "l2cap-interrupt-\(reason)")
        appendLog("[L2CAP] classic peer attach before interrupt open reason=\(reason) attached=\(peerAttached)")
        guard interruptChannel == nil else {
            appendLog("[L2CAP] Interrupt channel already tracked; skipping duplicate request")
            finishConnectionIfReady(reason: "interrupt already tracked")
            return
        }
        guard !pendingInterruptChannelOpen else {
            appendLog("[L2CAP] Interrupt channel open already pending")
            return
        }

        pendingInterruptChannelOpen = true
        interruptOpenAttemptID += 1
        let openAttemptID = interruptOpenAttemptID
        appendLog("[L2CAP] opening interrupt channel with KeyPad-style sync API PSM 19 attempt=\(openAttemptID) reason=\(reason)")
        openL2CAPChannelSync(for: device, psm: 19, attemptID: openAttemptID, reason: reason)
    }

    private func openL2CAPChannelSync(
        for device: IOBluetoothDevice,
        psm: BluetoothL2CAPPSM,
        attemptID: Int,
        reason: String
    ) {
        l2capOpenQueue.async { [weak self, weak device] in
            guard let self, let device else { return }

            var openedChannel: IOBluetoothL2CAPChannel?
            self.appendLog("[L2CAP] sync open worker started PSM \(psm) attempt=\(attemptID) reason=\(reason)")
            let openResult = device.openL2CAPChannelSync(&openedChannel, withPSM: psm, delegate: self)
            self.appendLog("[L2CAP] sync open worker finished PSM \(psm) attempt=\(attemptID) result=\(openResult) channel=\(self.describeL2CAPChannel(openedChannel))")

            DispatchQueue.main.async { [weak self, weak device, openedChannel] in
                guard let self else { return }
                guard let device else {
                    self.appendLog("[L2CAP] sync open result ignored PSM \(psm) attempt=\(attemptID): device released")
                    return
                }
                self.handleL2CAPSyncOpenResult(
                    psm: psm,
                    attemptID: attemptID,
                    result: openResult,
                    channel: openedChannel,
                    device: device,
                    reason: reason
                )
            }
        }
    }

    private func handleL2CAPSyncOpenResult(
        psm: BluetoothL2CAPPSM,
        attemptID: Int,
        result: IOReturn,
        channel: IOBluetoothL2CAPChannel?,
        device: IOBluetoothDevice,
        reason: String
    ) {
        let isControl = psm == 17
        let currentAttemptID = isControl ? controlOpenAttemptID : interruptOpenAttemptID
        guard currentAttemptID == attemptID else {
            appendLog("[L2CAP] sync open result ignored PSM \(psm) attempt=\(attemptID): currentAttempt=\(currentAttemptID)")
            return
        }

        guard isTrackedDevice(device) else {
            appendLog("[L2CAP] sync open result ignored PSM \(psm) attempt=\(attemptID): device no longer tracked")
            channel?.close()
            return
        }

        if isControl {
            pendingControlChannelOpen = false
            pendingControlChannel = nil
        } else {
            pendingInterruptChannelOpen = false
            pendingInterruptChannel = nil
        }

        appendLog("[L2CAP] openL2CAPChannelSync PSM \(psm) attempt=\(attemptID) = \(result) channel=\(describeL2CAPChannel(channel)) reason=\(reason)")
        guard result == kIOReturnSuccess, let channel else {
            statusLabel?.stringValue = "Bluetooth HID channel failed"
            statusLabel?.textColor = .systemOrange
            instructionLabel?.stringValue = "The Bluetooth link opened, but the HID channel did not finish. You can retry Connect or forget and pair again."
            appendLog("[L2CAP] ERROR: sync open failed PSM \(psm) attempt=\(attemptID) result=\(result)")
            failActiveBluetoothAutoConnectIfNeeded(
                message: "Bluetooth unavailable",
                detail: "HID channel failed",
                reason: "sync open failed PSM \(psm) result=\(result) attempt=\(attemptID)"
            )
            return
        }

        if isControl, let existing = controlChannel {
            appendLog("[L2CAP] sync open result ignored PSM \(psm) attempt=\(attemptID) branch=control-already-tracked existing=\(describeL2CAPChannel(existing)) duplicate=\(describeL2CAPChannel(channel)) reason=\(reason)")
            if interruptChannel == nil {
                requestInterruptChannelOpen(for: device, reason: "control already tracked after sync result")
            }
            publishBluetoothConnectionStatus(reason: "duplicate openL2CAPChannelSync PSM \(psm)")
            finishConnectionIfReady(reason: "duplicate openL2CAPChannelSync PSM \(psm)")
            return
        }

        if !isControl, let existing = interruptChannel {
            appendLog("[L2CAP] sync open result ignored PSM \(psm) attempt=\(attemptID) branch=interrupt-already-tracked existing=\(describeL2CAPChannel(existing)) duplicate=\(describeL2CAPChannel(channel)) reason=\(reason)")
            publishBluetoothConnectionStatus(reason: "duplicate openL2CAPChannelSync PSM \(psm)")
            finishConnectionIfReady(reason: "duplicate openL2CAPChannelSync PSM \(psm)")
            return
        }

        let delegateResult = channel.setDelegate(self)
        appendLog("[L2CAP] sync open PSM \(psm) setDelegate(self)=\(delegateResult)")

        if isControl {
            guard controlChannel !== channel else { return }
            controlChannel = channel
            appendLog("[L2CAP] Control channel ready from sync \(describeL2CAPChannel(channel))")
            requestInterruptChannelOpen(for: device, reason: "control channel opened by sync")
        } else {
            guard interruptChannel !== channel else { return }
            interruptChannel = channel
            appendLog("[L2CAP] Interrupt channel ready from sync \(describeL2CAPChannel(channel))")
        }

        publishBluetoothConnectionStatus(reason: "openL2CAPChannelSync PSM \(psm)")
        finishConnectionIfReady(reason: "openL2CAPChannelSync PSM \(psm)")
    }

    private func scheduleL2CAPOpenTimeout(
        psm: BluetoothL2CAPPSM,
        attemptID: Int,
        channel: IOBluetoothL2CAPChannel?,
        device: IOBluetoothDevice,
        reason: String
    ) {
        appendLog("[L2CAP] scheduling open timeout PSM \(psm) attempt=\(attemptID) delay=\(String(format: "%.1f", l2capOpenTimeout))s reason=\(reason)")
        DispatchQueue.main.asyncAfter(deadline: .now() + l2capOpenTimeout) { [weak self, weak channel, weak device] in
            guard let self else { return }
            guard let device else {
                self.appendLog("[L2CAP] timeout ignored PSM \(psm) attempt=\(attemptID): device released")
                return
            }
            guard self.isTrackedDevice(device) else {
                self.appendLog("[L2CAP] timeout ignored PSM \(psm) attempt=\(attemptID): device is no longer tracked")
                return
            }

            let isControl = psm == 17
            let currentAttemptID = isControl ? self.controlOpenAttemptID : self.interruptOpenAttemptID
            guard currentAttemptID == attemptID else {
                self.appendLog("[L2CAP] timeout ignored PSM \(psm) attempt=\(attemptID): currentAttempt=\(currentAttemptID)")
                return
            }

            let pendingOpen = isControl ? self.pendingControlChannelOpen : self.pendingInterruptChannelOpen
            guard pendingOpen else {
                self.appendLog("[L2CAP] timeout ignored PSM \(psm) attempt=\(attemptID): open no longer pending")
                return
            }

            let pendingChannel = isControl ? self.pendingControlChannel : self.pendingInterruptChannel
            if let channel, let pendingChannel, channel !== pendingChannel {
                self.appendLog("[L2CAP] timeout ignored PSM \(psm) attempt=\(attemptID): pending channel changed")
                return
            }

            self.appendLog("[L2CAP] TIMEOUT opening PSM \(psm) attempt=\(attemptID) after \(String(format: "%.1f", self.l2capOpenTimeout))s channel=\(self.describeL2CAPChannel(pendingChannel))")
            pendingChannel?.setDelegate(nil)
            if let pendingChannel {
                let closeResult = pendingChannel.close()
                self.appendLog("[L2CAP] timeout close PSM \(psm) result=\(closeResult)")
            }

            if isControl {
                self.pendingControlChannelOpen = false
                self.pendingControlChannel = nil
            } else {
                self.pendingInterruptChannelOpen = false
                self.pendingInterruptChannel = nil
            }

            self.statusLabel?.stringValue = "Bluetooth HID channel timed out"
            self.statusLabel?.textColor = .systemOrange
            self.instructionLabel?.stringValue = "The Bluetooth link opened, but the HID channel did not finish. You can retry Connect or forget and pair again."
            self.sendButton?.isEnabled = false
            self.specialKeyButtons.forEach { $0.isEnabled = false }
            self.mouseToggleBtn?.isEnabled = false
            self.failActiveBluetoothAutoConnectIfNeeded(
                message: "Bluetooth unavailable",
                detail: "HID channel timed out",
                reason: "L2CAP timeout PSM \(psm) attempt=\(attemptID)"
            )
            self.appendLog("[L2CAP] Gracefully stopped pending HID channel open; app remains recoverable")
        }
    }

    private func finishConnectionIfReady(reason: String) {
        guard controlChannel != nil, let interruptChannel else {
            return
        }

        runOnMain("finishConnectionIfReady controls") { [weak self] in
            guard let self else { return }
            self.statusLabel?.stringValue = "Connected"
            self.statusLabel?.textColor = .systemGreen
            self.instructionLabel?.stringValue = "Return to the Easy screen. Keyboard and mouse input are active whenever that window has focus."
            self.sendButton?.isEnabled = true
            self.specialKeyButtons.forEach { $0.isEnabled = true }
            self.mouseToggleBtn?.isEnabled = true
            self.mouseStatusLabel?.stringValue = "Mouse input active in the Easy screen"
            self.mouseStatusLabel?.textColor = .systemGreen
            self.startKeyMonitoring()
            self.startMousePassthrough()
        }

        guard !didSendInitialReport else {
            return
        }

        didSendInitialReport = true
        appendLog("=== CONNECTED — KEYBOARD READY! ===")
        var emptyReport: [UInt8] = [0xA1, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00]
        let writeResult = interruptChannel.writeAsync(&emptyReport, length: UInt16(emptyReport.count), refcon: nil)
        appendLog("[L2CAP] Sent initial empty HID report on PSM 19 result=\(writeResult)")
        completeBluetoothAutoConnectSuccess(
            attemptID: bluetoothAutoConnectAttemptID,
            detail: activeDeviceName ?? activeDevice?.nameOrAddress ?? "Bluetooth input ready"
        )
    }

    private func respondToControlMessage(_ channel: IOBluetoothL2CAPChannel, messageType: UInt8, param: UInt8) {
        hidIOQueue.async { [weak self] in
            guard let self else { return }

            var response: [UInt8]
            let description: String

            switch messageType {
            case 0x04:
                if (param & 0x03) == 1 {
                    response = [0xA1, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00]
                    description = "GET_REPORT input request -> empty keyboard report"
                } else {
                    response = [0x00]
                    description = "GET_REPORT non-input request -> handshake success"
                }
            case 0x05:
                response = [0x00]
                description = "SET_REPORT -> handshake success"
            case 0x06:
                response = [0xA0, 0x01]
                description = "GET_PROTOCOL -> report protocol"
            case 0x07:
                response = [0x00]
                description = "SET_PROTOCOL -> handshake success"
            default:
                response = [0x00]
                description = "Unhandled control type \(messageType) -> handshake success"
            }

            let responseHex = response.map { String(format: "%02X", $0) }.joined(separator: " ")
            self.appendLog("[HID] Responding on control channel: \(description) bytes=[\(responseHex)]")
            let writeResult = channel.writeSync(&response, length: UInt16(response.count))
            self.appendLog("[HID] control writeSync result = \(writeResult)")
        }
    }

    @objc func connectionComplete(_ device: IOBluetoothDevice, status: IOReturn) {
        let address = device.addressString ?? "?"
        let name = activeDeviceName ?? device.nameOrAddress ?? "?"
        appendLog("[Connect] connectionComplete for \(name) [\(address)] status=\(status) mainThread=\(Thread.isMainThread)")
        logPeerState(device, prefix: "[Connect]")

        guard isTrackedDevice(device) else {
            appendLog("[Connect] Ignoring connectionComplete from stale device [\(address)]")
            return
        }

        if status == kIOReturnSuccess || device.isConnected() {
            appendLog("[Connect] ACL is ready after connectionComplete; requesting control channel open")
            requestControlChannelOpen(for: device, reason: "connectionComplete status=\(status)")
        } else {
            appendLog("[Connect] ERROR: connectionComplete reported failure and device is not connected")
        }
    }

    @objc func l2capChannelOpenComplete(_ channel: IOBluetoothL2CAPChannel!, status error: IOReturn) {
        let psm = channel?.psm ?? 0
        let address = channel?.device?.addressString ?? "?"
        let name = activeDeviceName ?? channel?.device?.nameOrAddress ?? "?"

        if psm == 17 {
            pendingControlChannelOpen = false
            pendingControlChannel = nil
        } else if psm == 19 {
            pendingInterruptChannelOpen = false
            pendingInterruptChannel = nil
        }

        guard let channel else { return }
        guard let device = channel.device else { return }

        guard isTrackedDevice(device) else {
            channel.close()
            return
        }

        guard error == kIOReturnSuccess else { return }

        if psm == 17, let existing = controlChannel {
            if existing === channel {
                appendLog("[L2CAP] openComplete ignored PSM \(psm) branch=control-already-tracked-same channel=\(describeL2CAPChannel(channel))")
            } else {
                appendLog("[L2CAP] openComplete ignored PSM \(psm) branch=duplicate-control-open-complete existing=\(describeL2CAPChannel(existing)) duplicate=\(describeL2CAPChannel(channel))")
            }
            if interruptChannel == nil {
                requestInterruptChannelOpen(for: device, reason: "duplicate control openComplete with missing interrupt")
            }
            publishBluetoothConnectionStatus(reason: "duplicate l2capChannelOpenComplete PSM \(psm)")
            finishConnectionIfReady(reason: "duplicate l2capChannelOpenComplete PSM \(psm)")
            return
        }

        if psm == 19, let existing = interruptChannel {
            if existing === channel {
                appendLog("[L2CAP] openComplete ignored PSM \(psm) branch=interrupt-already-tracked-same channel=\(describeL2CAPChannel(channel))")
            } else {
                appendLog("[L2CAP] openComplete ignored PSM \(psm) branch=duplicate-interrupt-open-complete existing=\(describeL2CAPChannel(existing)) duplicate=\(describeL2CAPChannel(channel))")
            }
            publishBluetoothConnectionStatus(reason: "duplicate l2capChannelOpenComplete PSM \(psm)")
            finishConnectionIfReady(reason: "duplicate l2capChannelOpenComplete PSM \(psm)")
            return
        }

        let delegateResult = channel.setDelegate(self)
        appendLog("[L2CAP] openComplete PSM \(psm) device=\(name) [\(address)] status=\(error) setDelegate=\(delegateResult)")

        if psm == 17 {
            controlChannel = channel
            appendLog("[L2CAP] Control channel ready \(describeL2CAPChannel(channel))")
            requestInterruptChannelOpen(for: device, reason: "control channel opened")
        } else if psm == 19 {
            interruptChannel = channel
            appendLog("[L2CAP] Interrupt channel ready \(describeL2CAPChannel(channel))")
        }

        publishBluetoothConnectionStatus(reason: "l2capChannelOpenComplete PSM \(psm)")
        finishConnectionIfReady(reason: "l2capChannelOpenComplete PSM \(psm)")
    }

    @objc func l2capChannelData(_ channel: IOBluetoothL2CAPChannel!, data: UnsafeMutableRawPointer!, length: Int) {
        let psm = channel?.psm ?? 0
        appendLog("[L2CAP] l2capChannelData PSM \(psm) length=\(length) mainThread=\(Thread.isMainThread)")

        guard let channel else {
            appendLog("[L2CAP] ERROR: data callback arrived with nil channel")
            return
        }
        guard let device = channel.device, isTrackedDevice(device) else {
            appendLog("[L2CAP] Ignoring data callback from stale or missing device on PSM \(psm)")
            return
        }
        guard length > 0, let data else {
            appendLog("[L2CAP] Ignoring empty data callback on PSM \(psm)")
            return
        }

        let bytes = Array(UnsafeBufferPointer(start: data.assumingMemoryBound(to: UInt8.self), count: length))
        let header = bytes[0]
        let messageType = header >> 4
        let param = header & 0x0F
        let preview = bytes.prefix(8).map { String(format: "%02X", $0) }.joined(separator: " ")
        appendLog("[L2CAP] Recv PSM \(psm): type=\(messageType) param=\(param) len=\(length) bytes=[\(preview)]")

        if psm == 17 {
            respondToControlMessage(channel, messageType: messageType, param: param)
        } else {
            appendLog("[L2CAP] Interrupt/data channel payload observed; no control response needed")
        }
    }

    @objc func l2capChannelClosed(_ channel: IOBluetoothL2CAPChannel!) {
        let psm = channel?.psm ?? 0
        appendLog("[L2CAP] l2capChannelClosed PSM \(psm) mainThread=\(Thread.isMainThread)")

        if channel === controlChannel {
            appendLog("[L2CAP] Clearing tracked control channel after close")
            controlChannel = nil
        }
        if channel === interruptChannel {
            appendLog("[L2CAP] Clearing tracked interrupt channel after close")
            interruptChannel = nil
        }
        if channel === pendingControlChannel {
            appendLog("[L2CAP] Clearing pending control channel after close")
            pendingControlChannel = nil
            pendingControlChannelOpen = false
        }
        if channel === pendingInterruptChannel {
            appendLog("[L2CAP] Clearing pending interrupt channel after close")
            pendingInterruptChannel = nil
            pendingInterruptChannelOpen = false
        }

        publishBluetoothConnectionStatus(reason: "l2capChannelClosed PSM \(psm)")

        if controlChannel == nil || interruptChannel == nil {
            didSendInitialReport = false
            runOnMain("l2capChannelClosed controls") { [weak self] in
                guard let self else { return }
                self.sendButton?.isEnabled = false
                self.specialKeyButtons.forEach { $0.isEnabled = false }
                self.mouseToggleBtn?.isEnabled = false
                self.stopMousePassthrough()
                self.mouseStatusLabel?.stringValue = "Mouse passthrough: not connected"
                self.mouseStatusLabel?.textColor = .secondaryLabelColor
                self.stopKeyMonitoring()
            }
            appendLog("[L2CAP] Connection no longer fully open after close")
        }
    }

    @objc func l2capChannelWriteComplete(_ channel: IOBluetoothL2CAPChannel!, refcon: UnsafeMutableRawPointer!, status error: IOReturn) {
        if channel === interruptChannel {
            interruptWritesInFlight = max(0, interruptWritesInFlight - 1)
            mouseWriteCompletionCount += 1
            maybeLogMousePerformance(reason: "write-complete")
        }
        if error != kIOReturnSuccess {
            appendLog("[L2CAP] l2capChannelWriteComplete PSM \(channel?.psm ?? 0) status=\(error)")
        } else if channel === interruptChannel,
                  (mouseWriteCompletionCount <= 5 || mouseWriteCompletionCount % 250 == 0) {
            appendLog("[L2CAP] interrupt writeComplete count=\(mouseWriteCompletionCount) inFlight=\(interruptWritesInFlight)")
        }
    }

    @objc func l2capChannelQueueSpaceAvailable(_ channel: IOBluetoothL2CAPChannel!) {
        if channel === interruptChannel {
            queueSpaceAvailableCount += 1
            if queueSpaceAvailableCount <= 5 || queueSpaceAvailableCount % 250 == 0 {
                appendLog("[L2CAP] interrupt queue space available count=\(queueSpaceAvailableCount) inFlight=\(interruptWritesInFlight)")
            }
        } else {
            appendLog("[L2CAP] l2capChannelQueueSpaceAvailable PSM \(channel?.psm ?? 0)")
        }
    }

    private func recordInputSurfaceDiagnostic(
        event: String,
        reason: String,
        details: [String: String],
        severity: String = "info"
    ) {
        var merged = details
        merged["mouseEventCount"] = String(mouseEventCount)
        merged["inputSurfaceRotation"] = String(inputSurfaceRotationDegrees)
        merged["pointerSurface"] = InputSurfaceDiagnostics.sizeString(pointerSurfaceSize)
        merged["pointerSurfaceOrientation"] = InputSurfaceDiagnostics.orientationString(pointerSurfaceSize)
        merged["inputSurfaceFrame"] = inputSurfaceFrameInWindow.map(InputSurfaceDiagnostics.rectString) ?? "nil"
        FrameDropDiagnostics.shared.recordLifecycle(
            source: "easyInputSurface",
            event: event,
            reason: reason,
            details: merged,
            severity: severity
        )
        SpecchioLogger.input.info("[EasyInputSurface] event=\(event, privacy: .public) reason=\(reason, privacy: .public) rotation=\(self.inputSurfaceRotationDegrees) pointerSurface=\(InputSurfaceDiagnostics.sizeString(self.pointerSurfaceSize), privacy: .public) orientation=\(InputSurfaceDiagnostics.orientationString(self.pointerSurfaceSize), privacy: .public) frame=\(self.inputSurfaceFrameInWindow.map(InputSurfaceDiagnostics.rectString) ?? "nil", privacy: .public)")
    }

    // MARK: - Log

    private func isBluetoothPanelLogMessage(_ msg: String) -> Bool {
        let trimmed = msg.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return true }

        if trimmed.hasPrefix("[BTFlow]") {
            return trimmed.hasPrefix("[BTFlow] Consumer pairing panel opened")
                || trimmed.hasPrefix("[BTFlow] Waiting for user to prepare Bluetooth")
        }

        let bracketPrefixes = [
            "[AutoConnect]",
            "[BTUI]",
            "[BTPrepare]",
            "[Pairing",
            "[SavedDevice]",
            "[Connect",
            "[L2CAP]",
            "[HID]",
            "[State]",
            "[Status] Bluetooth HID",
            "[InputSurface]",
            "[MouseRotation]",
            "[Pointer]",
            "[EasyToolbar]",
        ]
        if bracketPrefixes.contains(where: { trimmed.hasPrefix($0) }) {
            return true
        }

        let flowPrefixes = [
            "=== Specchio Bluetooth HID ===",
            "=== CONNECTED",
            "Step 1:",
            "Step 2:",
            "Creating CBCentralManager",
            "SDP published:",
            "Device class set",
            "Waiting for Bluetooth",
            "(Click 'Connect Device'",
            "CBCentralManager state:",
            "*** READY",
            "On iPhone:",
            "beginSheetModal returned:",
            "Sheet ended with code:",
            "Selected:",
            "Device selected for reconnection",
            "No device selected",
            "No saved device",
            "No interrupt channel",
            "Sending:",
            "Sent ",
            "Reconnecting to",
            "ERROR: Click 'Prepare Bluetooth'",
        ]
        return flowPrefixes.contains { trimmed.hasPrefix($0) }
    }

    private func appendLog(_ msg: String) {
        if !Thread.isMainThread {
            DispatchQueue.main.async { [weak self] in self?.appendLog(msg) }
            return
        }
        guard isBluetoothPanelLogMessage(msg) else { return }

        NSLog("%@", msg)
        let line = "[\(DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .medium))] \(msg)\n"
        logBuffer.append(line)
        guard isAdvancedLogVisible, let storage = logView?.textStorage else { return }
        storage.append(NSAttributedString(string: line, attributes: [
            .font: NSFont.monospacedSystemFont(ofSize: 11, weight: .regular),
            .foregroundColor: NSColor.labelColor,
        ]))
        logView.scrollToEndOfDocument(nil)
    }

    private func refreshVisibleLogView() {
        guard let textStorage = logView?.textStorage else { return }
        textStorage.setAttributedString(NSAttributedString(string: ""))
        for line in logBuffer {
            textStorage.append(NSAttributedString(string: line, attributes: [
                .font: NSFont.monospacedSystemFont(ofSize: 11, weight: .regular),
                .foregroundColor: NSColor.labelColor,
            ]))
        }
        logView.scrollToEndOfDocument(nil)
    }
}
