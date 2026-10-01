import AppKit
import AVKit
import SwiftUI

enum InteractiveTutorialTarget: String, CaseIterable, Hashable {
    case easyConnectKeyboard
    case easySetupMouseControl
    case bluetoothPrepareButton
    case bluetoothChooseIPhoneButton

    var diagnosticName: String {
        rawValue
    }
}

enum InteractiveTutorialStepID: String, Hashable {
    case welcome
    case openKeyboardPanel
    case prepareBluetooth
    case chooseIPhone
    case macBluetoothSelector
    case restartAlert
    case postBluetoothRestart
    case setupMouseControl
}

enum InteractiveTutorialAttentionStyle: Equatable {
    case standard
    case emphasized
    case critical
    case celebratory

    var diagnosticName: String {
        switch self {
        case .standard:
            return "standard"
        case .emphasized:
            return "emphasized"
        case .critical:
            return "critical"
        case .celebratory:
            return "celebratory"
        }
    }

    var label: String? {
        switch self {
        case .standard:
            return nil
        case .emphasized:
            return "Important"
        case .critical:
            return "Required"
        case .celebratory:
            return "Setup complete"
        }
    }

    var systemImage: String {
        switch self {
        case .standard, .emphasized, .critical:
            return "exclamationmark.triangle.fill"
        case .celebratory:
            return "party.popper.fill"
        }
    }

    var swiftUIColor: Color {
        switch self {
        case .standard:
            return .accentColor
        case .emphasized:
            return .yellow
        case .critical:
            return .orange
        case .celebratory:
            return .green
        }
    }

    var nsColor: NSColor {
        switch self {
        case .standard:
            return .controlAccentColor
        case .emphasized:
            return .systemYellow
        case .critical:
            return .systemOrange
        case .celebratory:
            return .systemGreen
        }
    }
}

enum InteractiveTutorialMediaKind: String, Equatable {
    case image
    case animatedImage
    case loopingVideo
}

struct InteractiveTutorialMedia: Equatable {
    let kind: InteractiveTutorialMediaKind
    let resourceName: String
    let fileExtension: String
    let accessibilityLabel: String
    let resourceSubdirectory: String?
    let preferredDisplayHeight: CGFloat
    let aspectRatio: CGFloat?

    init(
        kind: InteractiveTutorialMediaKind,
        resourceName: String,
        fileExtension: String,
        accessibilityLabel: String,
        resourceSubdirectory: String? = nil,
        preferredDisplayHeight: CGFloat = 180,
        aspectRatio: CGFloat? = nil
    ) {
        self.kind = kind
        self.resourceName = resourceName
        self.fileExtension = fileExtension
        self.accessibilityLabel = accessibilityLabel
        self.resourceSubdirectory = resourceSubdirectory
        self.preferredDisplayHeight = preferredDisplayHeight
        self.aspectRatio = aspectRatio
    }

    var diagnosticName: String {
        "\(kind.rawValue):\(resourceName).\(fileExtension)"
    }

    func bundleURL() -> URL? {
        if let resourceSubdirectory,
           let subdirectoryURL = Bundle.main.url(
            forResource: resourceName,
            withExtension: fileExtension,
            subdirectory: resourceSubdirectory
           ) {
            return subdirectoryURL
        }
        return Bundle.main.url(forResource: resourceName, withExtension: fileExtension)
    }

    var isPortraitVideo: Bool {
        guard kind == .loopingVideo, let aspectRatio else { return false }
        return aspectRatio < 1
    }

    var tutorialVideoAsset: TutorialVideoAsset? {
        guard kind == .loopingVideo else { return nil }
        return TutorialVideoAsset(
            resourceName: resourceName,
            fileExtension: fileExtension,
            resourceSubdirectory: resourceSubdirectory,
            title: accessibilityLabel,
            accessibilityLabel: accessibilityLabel,
            preferredDisplayHeight: preferredDisplayHeight,
            aspectRatio: aspectRatio
        )
    }
}

enum InteractiveTutorialCompletion: Equatable {
    case primaryAction
    case targetAction(InteractiveTutorialTarget)
    case bluetoothPrepared
    case savedBluetoothDevicePresent
    case bluetoothSelectorAccepted
    case firstPairingRestartAlertShown
}

enum InteractiveTutorialEvent: Equatable {
    case primaryAction
    case targetAction(InteractiveTutorialTarget)
    case bluetoothPrepared
    case savedBluetoothDevicePresent
    case bluetoothSelectorAccepted
    case firstPairingRestartAlertShown

    var diagnosticName: String {
        switch self {
        case .primaryAction:
            return "primaryAction"
        case .targetAction(let target):
            return "targetAction:\(target.diagnosticName)"
        case .bluetoothPrepared:
            return "bluetoothPrepared"
        case .savedBluetoothDevicePresent:
            return "savedBluetoothDevicePresent"
        case .bluetoothSelectorAccepted:
            return "bluetoothSelectorAccepted"
        case .firstPairingRestartAlertShown:
            return "firstPairingRestartAlertShown"
        }
    }
}

enum InteractiveTutorialStepKind: Equatable {
    case message(primaryActionTitle: String)
    case spotlight(target: InteractiveTutorialTarget)
    case systemSheetInstructions
    case wait
}

struct InteractiveTutorialStep: Identifiable, Equatable {
    let id: InteractiveTutorialStepID
    let kind: InteractiveTutorialStepKind
    let title: String
    let body: String
    let bullets: [String]
    let attentionStyle: InteractiveTutorialAttentionStyle
    let media: InteractiveTutorialMedia?
    let completion: InteractiveTutorialCompletion?
    let timeoutSeconds: TimeInterval?
    let timeoutMessage: String?
    let retryStepID: InteractiveTutorialStepID?

    init(
        id: InteractiveTutorialStepID,
        kind: InteractiveTutorialStepKind,
        title: String,
        body: String,
        bullets: [String] = [],
        attentionStyle: InteractiveTutorialAttentionStyle = .standard,
        media: InteractiveTutorialMedia? = nil,
        completion: InteractiveTutorialCompletion?,
        timeoutSeconds: TimeInterval?,
        timeoutMessage: String?,
        retryStepID: InteractiveTutorialStepID?
    ) {
        self.id = id
        self.kind = kind
        self.title = title
        self.body = body
        self.bullets = bullets
        self.attentionStyle = attentionStyle
        self.media = media
        self.completion = completion
        self.timeoutSeconds = timeoutSeconds
        self.timeoutMessage = timeoutMessage
        self.retryStepID = retryStepID
    }

    var systemInstructionPanelSize: CGSize {
        if id == .macBluetoothSelector {
            return CGSize(width: 400, height: 700)
        }
        if media != nil {
            return CGSize(width: 380, height: 560)
        }
        if attentionStyle != .standard || bullets.count > 4 {
            return CGSize(width: 380, height: 500)
        }
        return CGSize(width: 340, height: 430)
    }
}

struct InteractiveTutorialFlow: Identifiable, Equatable {
    enum FlowID: String {
        case firstBluetoothSetup
        case postBluetoothRestart
    }

    let id: FlowID
    let steps: [InteractiveTutorialStep]

    static let firstBluetoothSetup = InteractiveTutorialFlow(
        id: .firstBluetoothSetup,
        steps: [
            InteractiveTutorialStep(
                id: .welcome,
                kind: .message(primaryActionTitle: "Let's do it"),
                title: "Welcome to Specchio",
                body: "Thanks for taking a moment to set this up. Specchio needs a short required pairing step so keyboard and mouse control work reliably. We will walk you through it.",
                bullets: [
                    "It is quick.",
                    "You will only need to click what is highlighted.",
                    "If macOS or iPhone takes a second, just stay with the guide."
                ],
                completion: .primaryAction,
                timeoutSeconds: nil,
                timeoutMessage: nil,
                retryStepID: nil
            ),
            InteractiveTutorialStep(
                id: .openKeyboardPanel,
                kind: .spotlight(target: .easyConnectKeyboard),
                title: "Connect keyboard input",
                body: "Click Connect Keyboard to open the Bluetooth keyboard setup.",
                bullets: [],
                completion: .targetAction(.easyConnectKeyboard),
                timeoutSeconds: nil,
                timeoutMessage: nil,
                retryStepID: nil
            ),
            InteractiveTutorialStep(
                id: .prepareBluetooth,
                kind: .spotlight(target: .bluetoothPrepareButton),
                title: "Prepare Bluetooth",
                body: "Click Prepare Bluetooth and wait until Specchio enables iPhone selection.",
                bullets: [],
                completion: .bluetoothPrepared,
                timeoutSeconds: nil,
                timeoutMessage: nil,
                retryStepID: nil
            ),
            InteractiveTutorialStep(
                id: .chooseIPhone,
                kind: .spotlight(target: .bluetoothChooseIPhoneButton),
                title: "Choose your iPhone",
                body: "Click Choose iPhone to open the macOS Bluetooth selector.",
                bullets: [],
                completion: .targetAction(.bluetoothChooseIPhoneButton),
                timeoutSeconds: nil,
                timeoutMessage: nil,
                retryStepID: nil
            ),
            InteractiveTutorialStep(
                id: .macBluetoothSelector,
                kind: .systemSheetInstructions,
                title: "Select your iPhone",
                body: "Some steps happen on your iPhone. Others happen here on this Mac. Follow them in order, then press Select when your iPhone is highlighted.",
                bullets: [
                    "Open Bluetooth Settings on your iPhone.",
                    "Forget this Mac if it is already paired. This is required.",
                    "Find your iPhone in the macOS Bluetooth selector.",
                    "Scroll all the way down if needed. It can take a few seconds for the iPhone to appear.",
                    "Click Connect next to your iPhone.",
                    "Confirm pairing on your iPhone.",
                    "Make sure your iPhone is highlighted, then press Select."
                ],
                attentionStyle: .critical,
                completion: .bluetoothSelectorAccepted,
                timeoutSeconds: nil,
                timeoutMessage: nil,
                retryStepID: .chooseIPhone
            ),
            InteractiveTutorialStep(
                id: .restartAlert,
                kind: .wait,
                title: "Finishing pairing",
                body: "Specchio should now ask to restart. That dialog means the first Bluetooth pairing was captured correctly.",
                bullets: [
                    "If you see the restart dialog, choose Restart Specchio.",
                    "If it does not appear, retry the iPhone selection step."
                ],
                attentionStyle: .emphasized,
                completion: .firstPairingRestartAlertShown,
                timeoutSeconds: 8,
                timeoutMessage: "Specchio saved the device but did not show the restart dialog. Retry the iPhone selection step.",
                retryStepID: .chooseIPhone
            )
        ]
    )

    static let postBluetoothRestart = InteractiveTutorialFlow(
        id: .postBluetoothRestart,
        steps: [
            InteractiveTutorialStep(
                id: .postBluetoothRestart,
                kind: .message(primaryActionTitle: "Continue"),
                title: "Setup complete",
                body: "Specchio saved the Bluetooth pairing. One last required step: set up mouse control so clicks and gestures work on the iPhone.",
                bullets: [
                    "Click Continue, then press Setup Mouse Control.",
                    "Specchio will show the mouse setup video next."
                ],
                attentionStyle: .celebratory,
                completion: .primaryAction,
                timeoutSeconds: nil,
                timeoutMessage: nil,
                retryStepID: nil
            ),
            InteractiveTutorialStep(
                id: .setupMouseControl,
                kind: .spotlight(target: .easySetupMouseControl),
                title: "Setup mouse control",
                body: "Click Setup Mouse Control to configure AssistiveTouch for mouse input.",
                bullets: [],
                attentionStyle: .emphasized,
                completion: .targetAction(.easySetupMouseControl),
                timeoutSeconds: nil,
                timeoutMessage: nil,
                retryStepID: nil
            )
        ]
    )
}

enum InteractiveTutorialPhase: String {
    case fresh
    case bluetoothRestartPending
    case completed
}

private enum InteractiveTutorialOverlayMetrics {
    static let spotlightStrokeWidth: CGFloat = 3
    static let tutorialCardStrokeWidth = spotlightStrokeWidth
    static let tutorialCardStrokeAlpha: CGFloat = 0.46
    static let tutorialCardEdgeInset: CGFloat = 16
    static let messageCardPreferredWidth: CGFloat = 390
    static let spotlightCardPreferredWidth: CGFloat = 340
}

final class InteractiveTutorialCoordinator: ObservableObject {
    static let shared = InteractiveTutorialCoordinator()

    @Published private(set) var activeFlow: InteractiveTutorialFlow?
    @Published private(set) var activeStepIndex = 0
    @Published private(set) var failureMessage: String?
    @Published private(set) var swiftUITargetFrames: [InteractiveTutorialTarget: CGRect] = [:]

    private var didAutoStartThisProcess = false
    private var timeoutGeneration = 0
    private var escapeKeyMonitor: Any?

    var currentStep: InteractiveTutorialStep? {
        guard let activeFlow, activeStepIndex >= 0, activeStepIndex < activeFlow.steps.count else {
            return nil
        }
        return activeFlow.steps[activeStepIndex]
    }

    var isActive: Bool {
        activeFlow != nil
    }

    private init() {}

    func startAutomaticallyIfNeeded(source: String) {
        guard !didAutoStartThisProcess else {
            SpecchioLogger.easyMode.debug("[InteractiveTutorial] auto-start skipped source=\(source, privacy: .public) branch=already-started-this-process")
            return
        }

        didAutoStartThisProcess = true
        let persistedPhase = Self.persistedPhase()
        SpecchioLogger.easyMode.info("[InteractiveTutorial] auto-start evaluated source=\(source, privacy: .public) persistedPhase=\(persistedPhase.rawValue, privacy: .public)")
        switch persistedPhase {
        case .fresh:
            start(flow: .firstBluetoothSetup, source: source)
        case .bluetoothRestartPending:
            start(flow: .postBluetoothRestart, source: source)
        case .completed:
            SpecchioLogger.easyMode.info("[InteractiveTutorial] auto-start skipped source=\(source, privacy: .public) branch=completed")
        }
    }

    func startFirstBluetoothSetup(source: String, resetPhase: Bool) {
        SpecchioLogger.easyMode.info("[InteractiveTutorial] manual start requested source=\(source, privacy: .public) resetPhase=\(resetPhase)")
        if resetPhase {
            setPersistedPhase(.fresh, reason: "manual first Bluetooth setup")
        }
        start(flow: .firstBluetoothSetup, source: source)
    }

    func completePrimaryAction(source: String) {
        recordEvent(.primaryAction, source: source)
    }

    func recordTargetAction(_ target: InteractiveTutorialTarget, source: String) {
        recordEvent(.targetAction(target), source: source)
    }

    func recordBluetoothPrepared(source: String) {
        recordEvent(.bluetoothPrepared, source: source)
    }

    func recordSavedBluetoothDevicePresent(source: String) {
        recordEvent(.savedBluetoothDevicePresent, source: source)
    }

    func recordBluetoothSelectorAccepted(source: String) {
        recordEvent(.bluetoothSelectorAccepted, source: source)
    }

    func recordFirstPairingRestartAlertShown(source: String) {
        setPersistedPhase(.bluetoothRestartPending, reason: source)
        recordEvent(.firstPairingRestartAlertShown, source: source)
    }

    func returnToOpenKeyboardPanelIfBluetoothPanelClosed(isBluetoothConnected: Bool, source: String) {
        guard let activeFlow else {
            SpecchioLogger.easyMode.info("[InteractiveTutorial] Bluetooth panel close ignored source=\(source, privacy: .public) branch=no-active-flow connected=\(isBluetoothConnected)")
            return
        }
        guard activeFlow.id == .firstBluetoothSetup else {
            SpecchioLogger.easyMode.info("[InteractiveTutorial] Bluetooth panel close ignored source=\(source, privacy: .public) branch=non-bluetooth-flow flow=\(activeFlow.id.rawValue, privacy: .public) connected=\(isBluetoothConnected)")
            return
        }
        guard !isBluetoothConnected else {
            SpecchioLogger.easyMode.info("[InteractiveTutorial] Bluetooth panel close ignored source=\(source, privacy: .public) branch=bluetooth-connected step=\(self.currentStep?.id.rawValue ?? "none", privacy: .public)")
            return
        }
        guard let currentStep else {
            SpecchioLogger.easyMode.info("[InteractiveTutorial] Bluetooth panel close ignored source=\(source, privacy: .public) branch=no-current-step connected=\(isBluetoothConnected)")
            return
        }

        let panelStepIDs: Set<InteractiveTutorialStepID> = [
            .prepareBluetooth,
            .chooseIPhone,
            .macBluetoothSelector,
            .restartAlert
        ]
        guard panelStepIDs.contains(currentStep.id) else {
            SpecchioLogger.easyMode.info("[InteractiveTutorial] Bluetooth panel close ignored source=\(source, privacy: .public) branch=step-not-owned-by-panel step=\(currentStep.id.rawValue, privacy: .public)")
            return
        }
        guard let openKeyboardPanelIndex = activeFlow.steps.firstIndex(where: { $0.id == .openKeyboardPanel }) else {
            SpecchioLogger.easyMode.error("[InteractiveTutorial] Bluetooth panel close could not return source=\(source, privacy: .public) branch=missing-open-keyboard-step")
            return
        }

        failureMessage = nil
        activeStepIndex = openKeyboardPanelIndex
        SpecchioLogger.easyMode.info("[InteractiveTutorial] Bluetooth panel close returned to Easy Mode source=\(source, privacy: .public) fromStep=\(currentStep.id.rawValue, privacy: .public) toStep=openKeyboardPanel connected=\(isBluetoothConnected)")
        logCurrentStep(reason: "Bluetooth panel closed")
        scheduleTimeoutIfNeeded(reason: "Bluetooth panel closed")
        publishStateChanged(reason: "Bluetooth panel closed")
    }

    func updateSwiftUITargetFrames(_ frames: [InteractiveTutorialTarget: CGRect], source: String) {
        swiftUITargetFrames = frames
        let summary = frames
            .map { "\($0.key.diagnosticName)=\(Self.rectDescription($0.value))" }
            .sorted()
            .joined(separator: ",")
        SpecchioLogger.easyMode.debug("[InteractiveTutorial] SwiftUI target frames updated source=\(source, privacy: .public) count=\(frames.count) frames=\(summary, privacy: .public)")
        publishStateChanged(reason: "SwiftUI target frames updated")
    }

    func retryCurrentFailure(source: String) {
        guard let activeFlow, let step = currentStep else {
            SpecchioLogger.easyMode.info("[InteractiveTutorial] retry skipped source=\(source, privacy: .public) branch=no-active-step")
            return
        }

        failureMessage = nil
        if let retryStepID = step.retryStepID,
           let retryIndex = activeFlow.steps.firstIndex(where: { $0.id == retryStepID }) {
            SpecchioLogger.easyMode.info("[InteractiveTutorial] retry applied source=\(source, privacy: .public) fromStep=\(step.id.rawValue, privacy: .public) toStep=\(retryStepID.rawValue, privacy: .public)")
            activeStepIndex = retryIndex
        } else {
            SpecchioLogger.easyMode.info("[InteractiveTutorial] retry reapplied same step source=\(source, privacy: .public) step=\(step.id.rawValue, privacy: .public)")
        }
        scheduleTimeoutIfNeeded(reason: "retry")
        publishStateChanged(reason: "retry")
    }

    func dismissActiveTutorialFromEscape(source: String) {
        guard let activeFlow, let step = currentStep else {
            SpecchioLogger.easyMode.info("[InteractiveTutorial] Escape dismiss skipped source=\(source, privacy: .public) branch=no-active-step")
            removeEscapeKeyMonitor(reason: "Escape dismiss skipped no active step")
            return
        }

        timeoutGeneration += 1
        failureMessage = nil
        self.activeFlow = nil
        activeStepIndex = 0
        SpecchioLogger.easyMode.warning("[InteractiveTutorial] dismissed by Escape source=\(source, privacy: .public) flow=\(activeFlow.id.rawValue, privacy: .public) step=\(step.id.rawValue, privacy: .public)")
        publishStateChanged(reason: "Escape dismissed tutorial")
        removeEscapeKeyMonitor(reason: "Escape dismissed tutorial")
    }

    private func start(flow: InteractiveTutorialFlow, source: String) {
        failureMessage = nil
        activeFlow = flow
        activeStepIndex = 0
        SpecchioLogger.easyMode.info("[InteractiveTutorial] started flow=\(flow.id.rawValue, privacy: .public) source=\(source, privacy: .public) stepCount=\(flow.steps.count)")
        installEscapeKeyMonitorIfNeeded(reason: "tutorial started")
        logCurrentStep(reason: "start")
        scheduleTimeoutIfNeeded(reason: "start")
        publishStateChanged(reason: "start")
    }

    private func recordEvent(_ event: InteractiveTutorialEvent, source: String) {
        guard let step = currentStep else {
            SpecchioLogger.easyMode.info("[InteractiveTutorial] event ignored source=\(source, privacy: .public) event=\(event.diagnosticName, privacy: .public) branch=no-active-step")
            return
        }

        SpecchioLogger.easyMode.info("[InteractiveTutorial] event received source=\(source, privacy: .public) event=\(event.diagnosticName, privacy: .public) step=\(step.id.rawValue, privacy: .public) expected=\(Self.completionDescription(step.completion), privacy: .public)")
        guard completion(step.completion, matches: event) else {
            SpecchioLogger.easyMode.info("[InteractiveTutorial] event ignored source=\(source, privacy: .public) event=\(event.diagnosticName, privacy: .public) step=\(step.id.rawValue, privacy: .public) branch=completion-mismatch")
            publishStateChanged(reason: "ignored event")
            return
        }

        advancePastCurrentStep(source: source, event: event)
    }

    private func advancePastCurrentStep(source: String, event: InteractiveTutorialEvent) {
        guard let activeFlow, let step = currentStep else { return }

        failureMessage = nil
        let nextIndex = activeStepIndex + 1
        SpecchioLogger.easyMode.info("[InteractiveTutorial] step completed source=\(source, privacy: .public) event=\(event.diagnosticName, privacy: .public) flow=\(activeFlow.id.rawValue, privacy: .public) step=\(step.id.rawValue, privacy: .public) nextIndex=\(nextIndex)")

        guard nextIndex < activeFlow.steps.count else {
            SpecchioLogger.easyMode.info("[InteractiveTutorial] flow completed flow=\(activeFlow.id.rawValue, privacy: .public) source=\(source, privacy: .public)")
            if activeFlow.id == .postBluetoothRestart {
                setPersistedPhase(.completed, reason: "post Bluetooth restart flow completed")
            }
            self.activeFlow = nil
            self.activeStepIndex = 0
            publishStateChanged(reason: "flow completed")
            removeEscapeKeyMonitor(reason: "flow completed")
            return
        }

        activeStepIndex = nextIndex
        logCurrentStep(reason: "advance")
        scheduleTimeoutIfNeeded(reason: "advance")
        publishStateChanged(reason: "advance")
    }

    private func scheduleTimeoutIfNeeded(reason: String) {
        timeoutGeneration += 1
        guard let step = currentStep, let timeoutSeconds = step.timeoutSeconds else {
            SpecchioLogger.easyMode.debug("[InteractiveTutorial] timeout skipped reason=\(reason, privacy: .public) branch=no-timeout step=\(self.currentStep?.id.rawValue ?? "none", privacy: .public)")
            return
        }

        let stepID = step.id
        let generation = timeoutGeneration
        DispatchQueue.main.asyncAfter(deadline: .now() + timeoutSeconds) { [weak self] in
            guard let self,
                  self.timeoutGeneration == generation,
                  self.currentStep?.id == stepID else {
                return
            }
            let message = step.timeoutMessage ?? "This tutorial step timed out."
            self.failureMessage = message
            SpecchioLogger.easyMode.warning("[InteractiveTutorial] timeout fired step=\(stepID.rawValue, privacy: .public) seconds=\(timeoutSeconds) message=\(message, privacy: .public)")
            self.publishStateChanged(reason: "timeout")
        }
        SpecchioLogger.easyMode.info("[InteractiveTutorial] timeout scheduled reason=\(reason, privacy: .public) step=\(stepID.rawValue, privacy: .public) seconds=\(timeoutSeconds)")
    }

    private func completion(_ completion: InteractiveTutorialCompletion?, matches event: InteractiveTutorialEvent) -> Bool {
        guard let completion else { return false }
        switch (completion, event) {
        case (.primaryAction, .primaryAction):
            return true
        case (.targetAction(let expected), .targetAction(let actual)):
            return expected == actual
        case (.bluetoothPrepared, .bluetoothPrepared):
            return true
        case (.savedBluetoothDevicePresent, .savedBluetoothDevicePresent):
            return true
        case (.bluetoothSelectorAccepted, .bluetoothSelectorAccepted):
            return true
        case (.firstPairingRestartAlertShown, .firstPairingRestartAlertShown):
            return true
        default:
            return false
        }
    }

    private func logCurrentStep(reason: String) {
        guard let activeFlow, let step = currentStep else {
            SpecchioLogger.easyMode.info("[InteractiveTutorial] current step unavailable reason=\(reason, privacy: .public)")
            return
        }
        SpecchioLogger.easyMode.info("[InteractiveTutorial] current step reason=\(reason, privacy: .public) flow=\(activeFlow.id.rawValue, privacy: .public) index=\(self.activeStepIndex) step=\(step.id.rawValue, privacy: .public) kind=\(Self.kindDescription(step.kind), privacy: .public) completion=\(Self.completionDescription(step.completion), privacy: .public)")
    }

    private func publishStateChanged(reason: String) {
        NotificationCenter.default.post(name: .interactiveTutorialDidChange, object: self)
        SpecchioLogger.easyMode.debug("[InteractiveTutorial] state change published reason=\(reason, privacy: .public) active=\(self.isActive) step=\(self.currentStep?.id.rawValue ?? "none", privacy: .public)")
    }

    private func setPersistedPhase(_ phase: InteractiveTutorialPhase, reason: String) {
        UserDefaults.standard.set(phase.rawValue, forKey: AppSettings.Keys.interactiveTutorialPhase)
        SpecchioLogger.easyMode.info("[InteractiveTutorial] persisted phase set phase=\(phase.rawValue, privacy: .public) reason=\(reason, privacy: .public)")
    }

    private func installEscapeKeyMonitorIfNeeded(reason: String) {
        guard escapeKeyMonitor == nil else {
            SpecchioLogger.easyMode.debug("[InteractiveTutorial] Escape monitor install skipped reason=\(reason, privacy: .public) branch=already-installed")
            return
        }

        escapeKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            guard self.isActive else {
                self.removeEscapeKeyMonitor(reason: "inactive tutorial observed by Escape monitor")
                return event
            }
            guard Self.isEscapeKey(event) else { return event }

            SpecchioLogger.easyMode.warning("[InteractiveTutorial] Escape key captured step=\(self.currentStep?.id.rawValue ?? "none", privacy: .public)")
            self.dismissActiveTutorialFromEscape(source: "local Escape key monitor")
            return nil
        }
        SpecchioLogger.easyMode.info("[InteractiveTutorial] Escape monitor installed reason=\(reason, privacy: .public)")
    }

    private func removeEscapeKeyMonitor(reason: String) {
        guard let escapeKeyMonitor else {
            SpecchioLogger.easyMode.debug("[InteractiveTutorial] Escape monitor remove skipped reason=\(reason, privacy: .public) branch=not-installed")
            return
        }

        NSEvent.removeMonitor(escapeKeyMonitor)
        self.escapeKeyMonitor = nil
        SpecchioLogger.easyMode.info("[InteractiveTutorial] Escape monitor removed reason=\(reason, privacy: .public)")
    }

    private static func isEscapeKey(_ event: NSEvent) -> Bool {
        event.charactersIgnoringModifiers == "\u{1B}"
    }

    private static func persistedPhase() -> InteractiveTutorialPhase {
        guard let rawValue = UserDefaults.standard.string(forKey: AppSettings.Keys.interactiveTutorialPhase),
              let phase = InteractiveTutorialPhase(rawValue: rawValue) else {
            return .fresh
        }
        return phase
    }

    private static func completionDescription(_ completion: InteractiveTutorialCompletion?) -> String {
        guard let completion else { return "none" }
        switch completion {
        case .primaryAction:
            return "primaryAction"
        case .targetAction(let target):
            return "targetAction:\(target.diagnosticName)"
        case .bluetoothPrepared:
            return "bluetoothPrepared"
        case .savedBluetoothDevicePresent:
            return "savedBluetoothDevicePresent"
        case .bluetoothSelectorAccepted:
            return "bluetoothSelectorAccepted"
        case .firstPairingRestartAlertShown:
            return "firstPairingRestartAlertShown"
        }
    }

    private static func kindDescription(_ kind: InteractiveTutorialStepKind) -> String {
        switch kind {
        case .message:
            return "message"
        case .spotlight(let target):
            return "spotlight:\(target.diagnosticName)"
        case .systemSheetInstructions:
            return "systemSheetInstructions"
        case .wait:
            return "wait"
        }
    }

    static func rectDescription(_ rect: CGRect) -> String {
        "x=\(Int(rect.minX.rounded())) y=\(Int(rect.minY.rounded())) w=\(Int(rect.width.rounded())) h=\(Int(rect.height.rounded()))"
    }
}

extension Notification.Name {
    static let interactiveTutorialDidChange = Notification.Name("interactiveTutorialDidChange")
}

struct InteractiveTutorialTargetPreferenceKey: PreferenceKey {
    static var defaultValue: [InteractiveTutorialTarget: CGRect] = [:]

    static func reduce(
        value: inout [InteractiveTutorialTarget: CGRect],
        nextValue: () -> [InteractiveTutorialTarget: CGRect]
    ) {
        value.merge(nextValue(), uniquingKeysWith: { _, next in next })
    }
}

extension View {
    func interactiveTutorialTarget(_ target: InteractiveTutorialTarget, visualHeight: CGFloat? = nil) -> some View {
        background {
            GeometryReader { proxy in
                let frame = Self.interactiveTutorialFrame(
                    from: proxy.frame(in: .global),
                    target: target,
                    visualHeight: visualHeight
                )
                Color.clear.preference(
                    key: InteractiveTutorialTargetPreferenceKey.self,
                    value: [target: frame]
                )
            }
        }
    }

    private static func interactiveTutorialFrame(
        from frame: CGRect,
        target: InteractiveTutorialTarget,
        visualHeight: CGFloat?
    ) -> CGRect {
        guard let visualHeight else {
            SpecchioLogger.easyMode.debug("[InteractiveTutorialTarget] frame reported target=\(target.diagnosticName, privacy: .public) branch=full-frame reason=no-visual-height frame=\(InteractiveTutorialCoordinator.rectDescription(frame), privacy: .public)")
            return frame
        }

        guard frame.height > visualHeight else {
            SpecchioLogger.easyMode.debug("[InteractiveTutorialTarget] frame reported target=\(target.diagnosticName, privacy: .public) branch=full-frame reason=frame-not-taller-than-visual-height frame=\(InteractiveTutorialCoordinator.rectDescription(frame), privacy: .public) visualHeight=\(visualHeight)")
            return frame
        }

        let adjustedFrame = CGRect(
            x: frame.minX,
            y: frame.midY - visualHeight / 2,
            width: frame.width,
            height: visualHeight
        )
        SpecchioLogger.easyMode.debug("[InteractiveTutorialTarget] frame adjusted target=\(target.diagnosticName, privacy: .public) branch=visual-height original=\(InteractiveTutorialCoordinator.rectDescription(frame), privacy: .public) adjusted=\(InteractiveTutorialCoordinator.rectDescription(adjustedFrame), privacy: .public) visualHeight=\(visualHeight)")
        return adjustedFrame
    }
}

struct InteractiveTutorialOverlay: View {
    @ObservedObject var coordinator: InteractiveTutorialCoordinator
    @State private var arrowPulse = false

    var body: some View {
        GeometryReader { proxy in
            if let step = coordinator.currentStep {
                overlayContent(step: step, proxy: proxy)
                    .onAppear {
                        arrowPulse = true
                        SpecchioLogger.easyMode.info("[InteractiveTutorialOverlay] appeared step=\(step.id.rawValue, privacy: .public)")
                    }
                    .onChange(of: step.id) { _, newStepID in
                        SpecchioLogger.easyMode.info("[InteractiveTutorialOverlay] step changed step=\(newStepID.rawValue, privacy: .public)")
                    }
            }
        }
        .animation(.easeInOut(duration: 0.18), value: coordinator.currentStep?.id)
    }

    @ViewBuilder
    private func overlayContent(step: InteractiveTutorialStep, proxy: GeometryProxy) -> some View {
        switch step.kind {
        case .message(let primaryActionTitle):
            messageOverlay(step: step, primaryActionTitle: primaryActionTitle, proxy: proxy)
        case .spotlight(let target):
            if let targetFrame = localFrame(for: target, proxy: proxy) {
                spotlightOverlay(step: step, targetFrame: targetFrame, proxy: proxy)
            } else {
                waitingForTargetOverlay(step: step, target: target)
            }
        case .systemSheetInstructions, .wait:
            externalStepBlockingOverlay(step: step)
        }
    }

    private func messageOverlay(
        step: InteractiveTutorialStep,
        primaryActionTitle: String,
        proxy: GeometryProxy
    ) -> some View {
        let cardWidth = responsiveCardWidth(
            preferredWidth: InteractiveTutorialOverlayMetrics.messageCardPreferredWidth,
            in: proxy.size,
            step: step,
            context: "message"
        )

        return ZStack {
            Color.black.opacity(0.72)
                .ignoresSafeArea()
            tutorialCard(step: step, primaryActionTitle: primaryActionTitle)
                .frame(width: cardWidth)
                .onAppear {
                    SpecchioLogger.easyMode.info("[InteractiveTutorialOverlay] responsive message card appeared step=\(step.id.rawValue, privacy: .public) width=\(cardWidth) containerWidth=\(proxy.size.width) containerHeight=\(proxy.size.height)")
                }
                .onChange(of: proxy.size) { _, newSize in
                    let newWidth = responsiveCardWidth(
                        preferredWidth: InteractiveTutorialOverlayMetrics.messageCardPreferredWidth,
                        in: newSize,
                        step: step,
                        context: "message-resize"
                    )
                    SpecchioLogger.easyMode.info("[InteractiveTutorialOverlay] responsive message card resized step=\(step.id.rawValue, privacy: .public) width=\(newWidth) containerWidth=\(newSize.width) containerHeight=\(newSize.height)")
                }
        }
    }

    private func waitingForTargetOverlay(step: InteractiveTutorialStep, target: InteractiveTutorialTarget) -> some View {
        ZStack {
            Color.black.opacity(0.62)
                .ignoresSafeArea()
            VStack(spacing: 12) {
                ProgressView()
                    .controlSize(.small)
                Text(step.title)
                    .font(.headline)
                Text("Waiting for \(target.diagnosticName)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(20)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .onAppear {
                SpecchioLogger.easyMode.info("[InteractiveTutorialOverlay] waiting for SwiftUI target step=\(step.id.rawValue, privacy: .public) target=\(target.diagnosticName, privacy: .public)")
            }
        }
    }

    private func spotlightOverlay(
        step: InteractiveTutorialStep,
        targetFrame: CGRect,
        proxy: GeometryProxy
    ) -> some View {
        let hole = paddedTargetFrame(targetFrame, in: proxy.size)
        let cardWidth = responsiveCardWidth(
            preferredWidth: InteractiveTutorialOverlayMetrics.spotlightCardPreferredWidth,
            in: proxy.size,
            step: step,
            context: "spotlight"
        )
        let panelPosition = cardPosition(for: hole, cardWidth: cardWidth, in: proxy.size)
        let arrowPosition = arrowPosition(for: hole, in: proxy.size)
        return ZStack(alignment: .topLeading) {
            spotlightDimmingVisual(around: hole, size: proxy.size)
            spotlightHitShield(around: hole, size: proxy.size)
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(Color.accentColor, lineWidth: InteractiveTutorialOverlayMetrics.spotlightStrokeWidth)
                .frame(width: hole.width, height: hole.height)
                .position(x: hole.midX, y: hole.midY)
                .shadow(color: .accentColor.opacity(0.8), radius: 12)
                .allowsHitTesting(false)

            Image(systemName: arrowPosition.pointsDown ? "arrow.down" : "arrow.up")
                .font(.system(size: 42, weight: .heavy))
                .foregroundStyle(Color.accentColor)
                .shadow(radius: 8)
                .offset(y: arrowPulse ? 8 : -2)
                .animation(.easeInOut(duration: 0.65).repeatForever(autoreverses: true), value: arrowPulse)
                .position(x: arrowPosition.x, y: arrowPosition.y)
                .allowsHitTesting(false)

            tutorialCard(step: step, primaryActionTitle: nil)
                .frame(width: cardWidth)
                .position(panelPosition)
                .allowsHitTesting(false)
        }
        .onAppear {
            SpecchioLogger.easyMode.info("[InteractiveTutorialOverlay] spotlight installed step=\(step.id.rawValue, privacy: .public) targetFrame=\(InteractiveTutorialCoordinator.rectDescription(targetFrame), privacy: .public) hole=\(InteractiveTutorialCoordinator.rectDescription(hole), privacy: .public) cardWidth=\(cardWidth) cardX=\(panelPosition.x) cardY=\(panelPosition.y) proxyWidth=\(proxy.size.width) proxyHeight=\(proxy.size.height)")
        }
        .onChange(of: proxy.size) { _, newSize in
            let newCardWidth = responsiveCardWidth(
                preferredWidth: InteractiveTutorialOverlayMetrics.spotlightCardPreferredWidth,
                in: newSize,
                step: step,
                context: "spotlight-resize"
            )
            let newHole = paddedTargetFrame(targetFrame, in: newSize)
            let newPosition = cardPosition(for: newHole, cardWidth: newCardWidth, in: newSize)
            SpecchioLogger.easyMode.info("[InteractiveTutorialOverlay] spotlight resized step=\(step.id.rawValue, privacy: .public) hole=\(InteractiveTutorialCoordinator.rectDescription(newHole), privacy: .public) cardWidth=\(newCardWidth) cardX=\(newPosition.x) cardY=\(newPosition.y) proxyWidth=\(newSize.width) proxyHeight=\(newSize.height)")
        }
    }

    private func externalStepBlockingOverlay(step: InteractiveTutorialStep) -> some View {
        Color.black.opacity(0.18)
            .ignoresSafeArea()
            .contentShape(Rectangle())
            .onAppear {
                SpecchioLogger.easyMode.info("[InteractiveTutorialOverlay] Easy Mode blocked for external tutorial step=\(step.id.rawValue, privacy: .public)")
            }
    }

    private func tutorialCard(
        step: InteractiveTutorialStep,
        primaryActionTitle: String?
    ) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            tutorialTitle(for: step)
            attentionBanner(for: step)
            Text(step.body)
                .font(.body)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            mediaView(for: step)
            if !step.bullets.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(step.bullets, id: \.self) { bullet in
                        HStack(alignment: .top, spacing: 8) {
                            Circle()
                                .fill(step.attentionStyle.swiftUIColor)
                                .frame(width: 5, height: 5)
                                .padding(.top, 7)
                            Text(bullet)
                                .font(.callout)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
            if let failureMessage = coordinator.failureMessage {
                Text(failureMessage)
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Retry step") {
                    coordinator.retryCurrentFailure(source: "SwiftUI overlay retry")
                }
                .buttonStyle(.borderedProminent)
            }
            if let primaryActionTitle {
                Button(primaryActionTitle) {
                    coordinator.completePrimaryAction(source: "SwiftUI overlay primary action")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .frame(maxWidth: .infinity, alignment: .trailing)
            }
        }
        .padding(18)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(
                    Color.white.opacity(Double(InteractiveTutorialOverlayMetrics.tutorialCardStrokeAlpha)),
                    lineWidth: InteractiveTutorialOverlayMetrics.tutorialCardStrokeWidth
                )
        }
    }

    @ViewBuilder
    private func tutorialTitle(for step: InteractiveTutorialStep) -> some View {
        if step.id == .welcome {
            Text(step.title)
                .font(.largeTitle.weight(.bold))
                .lineLimit(2)
                .minimumScaleFactor(0.82)
                .fixedSize(horizontal: false, vertical: true)
                .swGlowSweep(
                    baseColor: .gray,
                    glowColor: .white,
                    duration: 2.0,
                    bandWidth: 150,
                    debugName: "interactive-tutorial-welcome-title"
                )
                .onAppear {
                    SpecchioLogger.easyMode.info("[InteractiveTutorialOverlay] welcome title glow installed step=\(step.id.rawValue, privacy: .public)")
                }
        } else {
            Text(step.title)
                .font(.title3.weight(.semibold))
                .foregroundStyle(.primary)
        }
    }

    @ViewBuilder
    private func attentionBanner(for step: InteractiveTutorialStep) -> some View {
        if let label = step.attentionStyle.label {
            Label(label, systemImage: step.attentionStyle.systemImage)
                .font(.caption.weight(.bold))
                .foregroundStyle(step.attentionStyle.swiftUIColor)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(step.attentionStyle.swiftUIColor.opacity(0.16), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
    }

    @ViewBuilder
    private func mediaView(for step: InteractiveTutorialStep) -> some View {
        if let media = step.media {
            InteractiveTutorialMediaAttachmentView(media: media)
                .frame(height: 180)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(.white.opacity(0.12), lineWidth: 1)
                }
        }
    }

    private func spotlightDimmingVisual(around hole: CGRect, size: CGSize) -> some View {
        InteractiveTutorialSpotlightDimmingShape(hole: hole, cornerRadius: 10)
            .fill(Color.black.opacity(0.66), style: FillStyle(eoFill: true))
            .frame(width: size.width, height: size.height)
            .allowsHitTesting(false)
    }

    private func spotlightHitShield(around hole: CGRect, size: CGSize) -> some View {
        ZStack(alignment: .topLeading) {
            Color.clear
                .frame(width: size.width, height: max(0, hole.minY))
                .contentShape(Rectangle())
                .position(x: size.width / 2, y: max(0, hole.minY) / 2)
            Color.clear
                .frame(width: size.width, height: max(0, size.height - hole.maxY))
                .contentShape(Rectangle())
                .position(x: size.width / 2, y: hole.maxY + max(0, size.height - hole.maxY) / 2)
            Color.clear
                .frame(width: max(0, hole.minX), height: hole.height)
                .contentShape(Rectangle())
                .position(x: max(0, hole.minX) / 2, y: hole.midY)
            Color.clear
                .frame(width: max(0, size.width - hole.maxX), height: hole.height)
                .contentShape(Rectangle())
                .position(x: hole.maxX + max(0, size.width - hole.maxX) / 2, y: hole.midY)
        }
    }

    private func localFrame(for target: InteractiveTutorialTarget, proxy: GeometryProxy) -> CGRect? {
        guard let globalFrame = coordinator.swiftUITargetFrames[target] else { return nil }
        let rootFrame = proxy.frame(in: .global)
        let localFrame = CGRect(
            x: globalFrame.minX - rootFrame.minX,
            y: globalFrame.minY - rootFrame.minY,
            width: globalFrame.width,
            height: globalFrame.height
        )
        guard localFrame.width > 1, localFrame.height > 1 else { return nil }
        return localFrame
    }

    private func paddedTargetFrame(_ frame: CGRect, in size: CGSize) -> CGRect {
        let padded = frame.insetBy(dx: -10, dy: -10)
        return CGRect(
            x: max(0, padded.minX),
            y: max(0, padded.minY),
            width: min(size.width - max(0, padded.minX), padded.width),
            height: min(size.height - max(0, padded.minY), padded.height)
        )
    }

    private func responsiveCardWidth(
        preferredWidth: CGFloat,
        in size: CGSize,
        step: InteractiveTutorialStep,
        context: String
    ) -> CGFloat {
        let edgeInset = InteractiveTutorialOverlayMetrics.tutorialCardEdgeInset
        let availableWidth = max(0, size.width - edgeInset * 2)
        let resolvedWidth = min(preferredWidth, availableWidth)
        let branch = resolvedWidth < preferredWidth ? "clamped-to-container" : "preferred-width"
        SpecchioLogger.easyMode.debug("[InteractiveTutorialOverlay] responsive card width resolved context=\(context, privacy: .public) branch=\(branch, privacy: .public) step=\(step.id.rawValue, privacy: .public) preferredWidth=\(preferredWidth) availableWidth=\(availableWidth) resolvedWidth=\(resolvedWidth) containerWidth=\(size.width)")
        return resolvedWidth
    }

    private func cardPosition(for hole: CGRect, cardWidth: CGFloat, in size: CGSize) -> CGPoint {
        let edgeInset = InteractiveTutorialOverlayMetrics.tutorialCardEdgeInset
        let halfCardWidth = cardWidth / 2
        let minimumX = edgeInset + halfCardWidth
        let maximumX = max(minimumX, size.width - edgeInset - halfCardWidth)
        let unclampedX = hole.midX
        let x: CGFloat
        let horizontalBranch: String
        if maximumX == minimumX {
            x = size.width / 2
            horizontalBranch = "centered-container-too-narrow"
        } else if unclampedX < minimumX {
            x = minimumX
            horizontalBranch = "clamped-leading"
        } else if unclampedX > maximumX {
            x = maximumX
            horizontalBranch = "clamped-trailing"
        } else {
            x = unclampedX
            horizontalBranch = "aligned-to-target"
        }

        let verticalBranch: String
        let y: CGFloat
        if hole.maxY + 190 < size.height {
            y = hole.maxY + 110
            verticalBranch = "below-target"
        } else {
            y = max(110, hole.minY - 110)
            verticalBranch = "above-target"
        }

        SpecchioLogger.easyMode.debug("[InteractiveTutorialOverlay] responsive card position resolved horizontalBranch=\(horizontalBranch, privacy: .public) verticalBranch=\(verticalBranch, privacy: .public) hole=\(InteractiveTutorialCoordinator.rectDescription(hole), privacy: .public) cardWidth=\(cardWidth) x=\(x) y=\(y) containerWidth=\(size.width) containerHeight=\(size.height)")
        return CGPoint(x: x, y: y)
    }

    private func arrowPosition(for hole: CGRect, in size: CGSize) -> (x: CGFloat, y: CGFloat, pointsDown: Bool) {
        if hole.minY > 70 {
            return (hole.midX, hole.minY - 34, true)
        }
        return (hole.midX, min(size.height - 40, hole.maxY + 38), false)
    }
}

private struct InteractiveTutorialSpotlightDimmingShape: Shape {
    let hole: CGRect
    let cornerRadius: CGFloat

    func path(in rect: CGRect) -> Path {
        var path = Path(rect)
        path.addRoundedRect(
            in: hole,
            cornerSize: CGSize(width: cornerRadius, height: cornerRadius)
        )
        return path
    }
}

private struct InteractiveTutorialMediaAttachmentView: View {
    let media: InteractiveTutorialMedia

    var body: some View {
        Group {
            if let url = media.bundleURL() {
                switch media.kind {
                case .image, .animatedImage:
                    InteractiveTutorialImageAttachmentView(url: url, animates: media.kind == .animatedImage)
                case .loopingVideo:
                    if let asset = media.tutorialVideoAsset {
                        TutorialVideoContentView(asset: asset)
                    } else {
                        InteractiveTutorialMediaMissingView(media: media)
                    }
                }
            } else {
                InteractiveTutorialMediaMissingView(media: media)
                .onAppear {
                    SpecchioLogger.easyMode.warning("[InteractiveTutorialMedia] missing bundle resource media=\(media.diagnosticName, privacy: .public)")
                }
            }
        }
        .accessibilityLabel(media.accessibilityLabel)
        .onAppear {
            SpecchioLogger.easyMode.info("[InteractiveTutorialMedia] displayed media=\(media.diagnosticName, privacy: .public)")
        }
    }
}

private struct InteractiveTutorialMediaMissingView: View {
    let media: InteractiveTutorialMedia

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: "photo.on.rectangle.angled")
                .font(.title2)
            Text("Tutorial media missing")
                .font(.caption.weight(.semibold))
            Text(media.diagnosticName)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.white.opacity(0.06))
    }
}

private struct InteractiveTutorialImageAttachmentView: NSViewRepresentable {
    let url: URL
    let animates: Bool

    func makeNSView(context: Context) -> NSImageView {
        let imageView = NSImageView()
        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.imageFrameStyle = .none
        imageView.animates = animates
        return imageView
    }

    func updateNSView(_ nsView: NSImageView, context: Context) {
        nsView.animates = animates
        nsView.image = NSImage(contentsOf: url)
    }
}

private final class InteractiveTutorialLargeMediaPreviewController: NSObject, ObservableObject, NSWindowDelegate {
    private var panel: NSPanel?

    func show(media: InteractiveTutorialMedia, title: String, source: String) {
        guard media.kind == .image || media.kind == .animatedImage else {
            SpecchioLogger.easyMode.warning("[InteractiveTutorialLargeMediaPreview] show skipped source=\(source, privacy: .public) reason=unsupported-media media=\(media.diagnosticName, privacy: .public)")
            return
        }

        guard media.bundleURL() != nil else {
            SpecchioLogger.easyMode.error("[InteractiveTutorialLargeMediaPreview] show skipped source=\(source, privacy: .public) reason=missing-resource media=\(media.diagnosticName, privacy: .public)")
            return
        }

        let panel = panel ?? makePanel()
        self.panel = panel
        let screenFrame = NSApp.keyWindow?.screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? .zero
        let contentSize = resolvedContentSize(for: media, screenFrame: screenFrame)
        panel.title = title
        panel.setContentSize(contentSize)
        panel.contentView = NSHostingView(rootView: InteractiveTutorialLargeMediaPreviewView(media: media, title: title))
        position(panel, in: screenFrame)
        panel.makeKeyAndOrderFront(nil)
        NSApplication.shared.activate(ignoringOtherApps: true)
        SpecchioLogger.easyMode.info("[InteractiveTutorialLargeMediaPreview] shown source=\(source, privacy: .public) title=\(title, privacy: .public) media=\(media.diagnosticName, privacy: .public) width=\(contentSize.width) height=\(contentSize.height) aspectRatio=\(media.aspectRatio ?? 0)")
    }

    func windowWillClose(_ notification: Notification) {
        SpecchioLogger.easyMode.info("[InteractiveTutorialLargeMediaPreview] closed")
        panel = nil
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(
            contentRect: CGRect(
                origin: .zero,
                size: InteractiveTutorialLargeMediaPreviewMetrics.fallbackSize
            ),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.collectionBehavior = [.fullScreenAuxiliary, .moveToActiveSpace]
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.delegate = self
        return panel
    }

    private func resolvedContentSize(for media: InteractiveTutorialMedia, screenFrame: CGRect) -> CGSize {
        guard !screenFrame.isEmpty else {
            SpecchioLogger.easyMode.info("[InteractiveTutorialLargeMediaPreview] size resolved branch=no-screen media=\(media.diagnosticName, privacy: .public)")
            return InteractiveTutorialLargeMediaPreviewMetrics.fallbackSize
        }

        let maximumSize = CGSize(
            width: screenFrame.width * InteractiveTutorialLargeMediaPreviewMetrics.screenCoverage,
            height: screenFrame.height * InteractiveTutorialLargeMediaPreviewMetrics.screenCoverage
        )

        guard let aspectRatio = media.aspectRatio, aspectRatio > 0 else {
            SpecchioLogger.easyMode.info("[InteractiveTutorialLargeMediaPreview] size resolved branch=no-aspect media=\(media.diagnosticName, privacy: .public) width=\(maximumSize.width) height=\(maximumSize.height)")
            return maximumSize
        }

        let size: CGSize
        if aspectRatio < 1 {
            let height = maximumSize.height
            let naturalWidth = height * aspectRatio
            size = CGSize(
                width: clamp(naturalWidth, lower: InteractiveTutorialLargeMediaPreviewMetrics.minimumWidth, upper: maximumSize.width),
                height: height
            )
        } else {
            let widthFromMaximumHeight = maximumSize.height * aspectRatio
            let width = min(maximumSize.width, widthFromMaximumHeight)
            let naturalHeight = width / aspectRatio
            size = CGSize(
                width: width,
                height: clamp(naturalHeight, lower: InteractiveTutorialLargeMediaPreviewMetrics.minimumHeight, upper: maximumSize.height)
            )
        }

        SpecchioLogger.easyMode.info("[InteractiveTutorialLargeMediaPreview] size resolved branch=aspect media=\(media.diagnosticName, privacy: .public) aspectRatio=\(aspectRatio) width=\(size.width) height=\(size.height) maxWidth=\(maximumSize.width) maxHeight=\(maximumSize.height)")
        return size
    }

    private func clamp(_ value: CGFloat, lower: CGFloat, upper: CGFloat) -> CGFloat {
        min(max(value, min(lower, upper)), upper)
    }

    private func position(_ panel: NSPanel, in screenFrame: CGRect) {
        guard !screenFrame.isEmpty else {
            panel.center()
            return
        }

        let frameSize = panel.frame.size
        panel.setFrameOrigin(CGPoint(
            x: screenFrame.midX - frameSize.width / 2,
            y: screenFrame.midY - frameSize.height / 2
        ))
    }
}

private enum InteractiveTutorialLargeMediaPreviewMetrics {
    static let screenCoverage: CGFloat = 0.82
    static let minimumWidth: CGFloat = 420
    static let minimumHeight: CGFloat = 320
    static let fallbackSize = CGSize(width: 720, height: 620)
}

private struct InteractiveTutorialLargeMediaPreviewView: View {
    let media: InteractiveTutorialMedia
    let title: String

    var body: some View {
        ZStack {
            Color.black
            if let url = media.bundleURL() {
                switch media.kind {
                case .image, .animatedImage:
                    InteractiveTutorialImageAttachmentView(url: url, animates: media.kind == .animatedImage)
                case .loopingVideo:
                    InteractiveTutorialMediaMissingView(media: media)
                }
            } else {
                VStack(spacing: 8) {
                    Image(systemName: "video.slash")
                        .font(.largeTitle)
                    Text("Tutorial media missing")
                        .font(.headline)
                    Text(media.diagnosticName)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .foregroundStyle(.white)
            }
        }
        .accessibilityLabel("Large tutorial media preview for \(title)")
        .onAppear {
            SpecchioLogger.easyMode.info("[InteractiveTutorialLargeMediaPreview] content appeared title=\(title, privacy: .public) media=\(media.diagnosticName, privacy: .public)")
        }
    }
}

final class InteractiveTutorialBluetoothPanelOverlayController {
    private let coordinator: InteractiveTutorialCoordinator
    private weak var window: NSWindow?
    private let overlayView = BluetoothPanelSpotlightView()
    private let instructionPanel = BluetoothSystemInstructionPanel()
    private var changeObserver: NSObjectProtocol?

    init(coordinator: InteractiveTutorialCoordinator = .shared) {
        self.coordinator = coordinator
        changeObserver = NotificationCenter.default.addObserver(
            forName: .interactiveTutorialDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.refresh(reason: "coordinator notification")
        }
    }

    deinit {
        if let changeObserver {
            NotificationCenter.default.removeObserver(changeObserver)
        }
    }

    func attach(
        window: NSWindow,
        prepareButton: NSButton?,
        chooseIPhoneButton: NSButton?,
        source: String
    ) {
        self.window = window

        guard let contentView = window.contentView else {
            SpecchioLogger.easyMode.info("[InteractiveTutorialBluetoothOverlay] attach skipped source=\(source, privacy: .public) branch=no-content-view")
            return
        }

        overlayView.prepareButton = prepareButton
        overlayView.chooseIPhoneButton = chooseIPhoneButton
        overlayView.contentHostView = contentView

        if overlayView.superview !== contentView {
            overlayView.removeFromSuperview()
            overlayView.translatesAutoresizingMaskIntoConstraints = false
            contentView.addSubview(overlayView)
            NSLayoutConstraint.activate([
                overlayView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
                overlayView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
                overlayView.topAnchor.constraint(equalTo: contentView.topAnchor),
                overlayView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor)
            ])
            SpecchioLogger.easyMode.info("[InteractiveTutorialBluetoothOverlay] attached source=\(source, privacy: .public) windowNumber=\(window.windowNumber)")
        } else {
            SpecchioLogger.easyMode.debug("[InteractiveTutorialBluetoothOverlay] attach reused source=\(source, privacy: .public) windowNumber=\(window.windowNumber)")
        }
        refresh(reason: "attach \(source)")
    }

    func refresh(reason: String) {
        let step = coordinator.currentStep
        overlayView.activeStep = step
        overlayView.failureMessage = coordinator.failureMessage
        overlayView.needsDisplay = true

        if let step, case .systemSheetInstructions = step.kind {
            instructionPanel.show(step: step, failureMessage: coordinator.failureMessage, near: window, coordinator: coordinator, reason: reason)
        } else if let step, case .wait = step.kind {
            instructionPanel.show(step: step, failureMessage: coordinator.failureMessage, near: window, coordinator: coordinator, reason: reason)
        } else {
            instructionPanel.hide(reason: reason)
        }

        SpecchioLogger.easyMode.debug("[InteractiveTutorialBluetoothOverlay] refresh reason=\(reason, privacy: .public) step=\(step?.id.rawValue ?? "none", privacy: .public) failure=\(self.coordinator.failureMessage ?? "none", privacy: .public)")
    }
}

private final class BluetoothPanelSpotlightView: NSView {
    weak var contentHostView: NSView?
    weak var prepareButton: NSButton?
    weak var chooseIPhoneButton: NSButton?
    var activeStep: InteractiveTutorialStep?
    var failureMessage: String?

    override func draw(_ dirtyRect: NSRect) {
        guard let activeStep, case .spotlight(let target) = activeStep.kind else { return }
        guard let hole = targetFrame(for: target) else { return }

        NSColor.black.withAlphaComponent(0.64).setFill()
        let dimPath = NSBezierPath(rect: bounds)
        dimPath.append(NSBezierPath(roundedRect: hole, xRadius: 10, yRadius: 10))
        dimPath.windingRule = .evenOdd
        dimPath.fill()

        NSColor.controlAccentColor.setStroke()
        let strokePath = NSBezierPath(roundedRect: hole, xRadius: 10, yRadius: 10)
        strokePath.lineWidth = InteractiveTutorialOverlayMetrics.spotlightStrokeWidth
        strokePath.stroke()

        drawArrow(near: hole)
        drawCard(for: activeStep, near: hole)
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let activeStep, case .spotlight(let target) = activeStep.kind else { return nil }
        guard let hole = targetFrame(for: target) else { return self }
        if hole.contains(point) {
            return nil
        }
        return self
    }

    private func targetFrame(for target: InteractiveTutorialTarget) -> CGRect? {
        guard let contentHostView else { return nil }
        let targetButton: NSButton?
        switch target {
        case .easyConnectKeyboard, .easySetupMouseControl:
            return nil
        case .bluetoothPrepareButton:
            targetButton = prepareButton
        case .bluetoothChooseIPhoneButton:
            targetButton = chooseIPhoneButton
        }
        guard let button = targetButton, let superview = button.superview else { return nil }
        let frame = superview.convert(button.frame, to: contentHostView).insetBy(dx: -10, dy: -10)
        guard frame.width > 1, frame.height > 1 else { return nil }
        return frame
    }

    private func drawArrow(near hole: CGRect) {
        let arrow = "←"
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 42, weight: .heavy),
            .foregroundColor: NSColor.controlAccentColor
        ]
        let size = arrow.size(withAttributes: attributes)
        let point = NSPoint(
            x: min(hole.maxX + 14, bounds.maxX - size.width - 12),
            y: min(max(hole.midY - size.height / 2, bounds.minY + 12), bounds.maxY - size.height - 12)
        )
        arrow.draw(at: point, withAttributes: attributes)
    }

    private func drawCard(for step: InteractiveTutorialStep, near hole: CGRect) {
        let cardWidth: CGFloat = min(340, bounds.width - 32)
        let cardHeight: CGFloat = failureMessage == nil ? 128 : 174
        let cardX = min(max(16, hole.midX - cardWidth / 2), max(16, bounds.width - cardWidth - 16))
        let cardY: CGFloat
        if hole.maxY + cardHeight + 20 < bounds.height {
            cardY = hole.maxY + 18
        } else {
            cardY = max(16, hole.minY - cardHeight - 18)
        }
        let cardRect = CGRect(x: cardX, y: cardY, width: cardWidth, height: cardHeight)

        NSColor.windowBackgroundColor.withAlphaComponent(0.94).setFill()
        let cardPath = NSBezierPath(roundedRect: cardRect, xRadius: 8, yRadius: 8)
        cardPath.fill()
        NSColor.white.withAlphaComponent(InteractiveTutorialOverlayMetrics.tutorialCardStrokeAlpha).setStroke()
        cardPath.lineWidth = InteractiveTutorialOverlayMetrics.tutorialCardStrokeWidth
        cardPath.stroke()

        let titleRect = CGRect(x: cardRect.minX + 16, y: cardRect.minY + 14, width: cardRect.width - 32, height: 24)
        step.title.draw(in: titleRect, withAttributes: [
            .font: NSFont.systemFont(ofSize: 18, weight: .semibold),
            .foregroundColor: NSColor.labelColor
        ])

        let bodyRect = CGRect(x: cardRect.minX + 16, y: titleRect.maxY + 8, width: cardRect.width - 32, height: 56)
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byWordWrapping
        step.body.draw(in: bodyRect, withAttributes: [
            .font: NSFont.systemFont(ofSize: 13, weight: .regular),
            .foregroundColor: NSColor.secondaryLabelColor,
            .paragraphStyle: paragraph
        ])

        if let failureMessage {
            let failureRect = CGRect(x: cardRect.minX + 16, y: bodyRect.maxY + 8, width: cardRect.width - 32, height: 48)
            failureMessage.draw(in: failureRect, withAttributes: [
                .font: NSFont.systemFont(ofSize: 12, weight: .semibold),
                .foregroundColor: NSColor.systemOrange,
                .paragraphStyle: paragraph
            ])
        }
    }
}

private final class BluetoothSystemInstructionPanel {
    private var panel: NSPanel?
    private let selectorSequenceState = InteractiveTutorialSelectorSequenceState()

    func show(
        step: InteractiveTutorialStep,
        failureMessage: String?,
        near window: NSWindow?,
        coordinator: InteractiveTutorialCoordinator,
        reason: String
    ) {
        guard let window else {
            SpecchioLogger.easyMode.info("[InteractiveTutorialSystemPanel] show skipped reason=\(reason, privacy: .public) branch=no-window")
            return
        }

        let panel = panel ?? makePanel()
        self.panel = panel
        let contentSize = resolvedContentSize(for: step, near: window)
        updateSelectorSequenceOwnership(for: step, reason: reason)
        panel.setContentSize(contentSize)
        panel.contentView = NSHostingView(rootView: InteractiveTutorialSystemInstructionView(
            step: step,
            panelSize: contentSize,
            failureMessage: failureMessage,
            selectorSequenceState: selectorSequenceState,
            retry: {
                coordinator.retryCurrentFailure(source: "Bluetooth system instruction panel retry")
            }
        ))
        position(panel, near: window)
        panel.orderFront(nil)
        SpecchioLogger.easyMode.info("[InteractiveTutorialSystemPanel] shown reason=\(reason, privacy: .public) step=\(step.id.rawValue, privacy: .public) hostWindow=\(window.windowNumber) width=\(contentSize.width) height=\(contentSize.height)")
    }

    func hide(reason: String) {
        selectorSequenceState.resetIfNeeded(reason: "panel hidden \(reason)")
        guard let panel, panel.isVisible else { return }
        panel.orderOut(nil)
        SpecchioLogger.easyMode.info("[InteractiveTutorialSystemPanel] hidden reason=\(reason, privacy: .public)")
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(
            contentRect: CGRect(x: 0, y: 0, width: 340, height: 430),
            styleMask: [.titled, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.title = "Specchio Onboarding"
        panel.level = .floating
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        return panel
    }

    private func updateSelectorSequenceOwnership(for step: InteractiveTutorialStep, reason: String) {
        selectorSequenceState.updateOwnership(for: step, reason: reason)
    }

    private func resolvedContentSize(for step: InteractiveTutorialStep, near window: NSWindow) -> CGSize {
        let preferredSize = step.systemInstructionPanelSize
        let screenFrame = window.screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? .zero
        guard !screenFrame.isEmpty else {
            SpecchioLogger.easyMode.info("[InteractiveTutorialSystemPanel] size resolved branch=no-screen step=\(step.id.rawValue, privacy: .public) width=\(preferredSize.width) height=\(preferredSize.height)")
            return preferredSize
        }

        let edgeMargin = InteractiveTutorialSystemPanelMetrics.edgeMargin
        let maximumSize = CGSize(
            width: max(320, screenFrame.width - edgeMargin * 2),
            height: max(430, screenFrame.height - edgeMargin * 2)
        )
        let resolvedSize = CGSize(
            width: min(preferredSize.width, maximumSize.width),
            height: min(preferredSize.height, maximumSize.height)
        )
        SpecchioLogger.easyMode.info("[InteractiveTutorialSystemPanel] size resolved branch=clamped step=\(step.id.rawValue, privacy: .public) preferredWidth=\(preferredSize.width) preferredHeight=\(preferredSize.height) resolvedWidth=\(resolvedSize.width) resolvedHeight=\(resolvedSize.height) screenWidth=\(screenFrame.width) screenHeight=\(screenFrame.height)")
        return resolvedSize
    }

    private func position(_ panel: NSPanel, near window: NSWindow) {
        let screenFrame = window.screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? .zero
        let targetSize = panel.frame.size
        let edgeMargin = InteractiveTutorialSystemPanelMetrics.edgeMargin
        var x = window.frame.maxX + edgeMargin
        if x + targetSize.width > screenFrame.maxX {
            x = max(screenFrame.minX + edgeMargin, window.frame.minX - targetSize.width - edgeMargin)
        }
        let y = min(max(screenFrame.minY + edgeMargin, window.frame.midY - targetSize.height / 2), screenFrame.maxY - targetSize.height - edgeMargin)
        panel.setFrameOrigin(CGPoint(x: x, y: y))
    }
}

private enum InteractiveTutorialSystemPanelMetrics {
    static let edgeMargin: CGFloat = 12
}

private final class InteractiveTutorialSelectorSequenceState: ObservableObject {
    @Published private(set) var activeIndex = 0
    private var ownerStepID: InteractiveTutorialStepID?

    func updateOwnership(for step: InteractiveTutorialStep, reason: String) {
        guard step.id == .macBluetoothSelector else {
            resetIfNeeded(reason: "\(reason) leaving selector for \(step.id.rawValue)")
            return
        }

        guard ownerStepID != step.id else {
            SpecchioLogger.easyMode.debug("[InteractiveTutorialSelectorSequence] state preserved reason=\(reason, privacy: .public) step=\(step.id.rawValue, privacy: .public) activeIndex=\(self.activeIndex)")
            return
        }

        ownerStepID = step.id
        activeIndex = 0
        SpecchioLogger.easyMode.info("[InteractiveTutorialSelectorSequence] state initialized reason=\(reason, privacy: .public) step=\(step.id.rawValue, privacy: .public) activeIndex=0")
    }

    func setActiveIndex(_ newValue: Int, step: InteractiveTutorialStep, source: String) {
        let previous = activeIndex
        ownerStepID = step.id
        guard previous != newValue else {
            SpecchioLogger.easyMode.debug("[InteractiveTutorialSelectorSequence] active index unchanged source=\(source, privacy: .public) step=\(step.id.rawValue, privacy: .public) index=\(newValue)")
            return
        }

        activeIndex = newValue
        SpecchioLogger.easyMode.info("[InteractiveTutorialSelectorSequence] active index changed source=\(source, privacy: .public) step=\(step.id.rawValue, privacy: .public) from=\(previous) to=\(newValue)")
    }

    func resetIfNeeded(reason: String) {
        guard ownerStepID != nil || activeIndex != 0 else {
            SpecchioLogger.easyMode.debug("[InteractiveTutorialSelectorSequence] reset skipped reason=\(reason, privacy: .public) branch=already-initial")
            return
        }

        let previousStep = ownerStepID?.rawValue ?? "none"
        let previousIndex = activeIndex
        ownerStepID = nil
        activeIndex = 0
        SpecchioLogger.easyMode.info("[InteractiveTutorialSelectorSequence] state reset reason=\(reason, privacy: .public) previousStep=\(previousStep, privacy: .public) previousIndex=\(previousIndex)")
    }
}

private struct InteractiveTutorialSystemInstructionView: View {
    let step: InteractiveTutorialStep
    let panelSize: CGSize
    let failureMessage: String?
    @ObservedObject var selectorSequenceState: InteractiveTutorialSelectorSequenceState
    let retry: () -> Void

    var body: some View {
        if step.id == .macBluetoothSelector {
            InteractiveTutorialSelectorInstructionSequenceView(
                step: step,
                panelSize: panelSize,
                failureMessage: failureMessage,
                sequenceState: selectorSequenceState,
                retry: retry
            )
        } else {
            standardInstructionView
        }
    }

    private var standardInstructionView: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(step.title)
                .font(.title2.weight(.semibold))
            if let label = step.attentionStyle.label {
                Label(label, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(step.attentionStyle.swiftUIColor)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(step.attentionStyle.swiftUIColor.opacity(0.16), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            }
            Text(step.body)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let media = step.media {
                InteractiveTutorialMediaAttachmentView(media: media)
                    .frame(height: 180)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .stroke(.white.opacity(0.12), lineWidth: 1)
                    }
            }
            VStack(alignment: .leading, spacing: 10) {
                ForEach(Array(step.bullets.enumerated()), id: \.offset) { index, bullet in
                    HStack(alignment: .top, spacing: 10) {
                        Text("\(index + 1)")
                            .font(.caption.weight(.bold))
                            .foregroundStyle(.white)
                            .frame(width: 22, height: 22)
                            .background(Circle().fill(step.attentionStyle.swiftUIColor))
                        Text(bullet)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            if let failureMessage {
                Divider()
                Text(failureMessage)
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Retry step", action: retry)
                    .buttonStyle(.borderedProminent)
            }
            Spacer(minLength: 0)
        }
        .padding(20)
        .frame(
            width: panelSize.width,
            height: panelSize.height,
            alignment: .topLeading
        )
        .preferredColorScheme(.dark)
    }
}

private struct InteractiveTutorialSelectorInstructionSequenceView: View {
    let step: InteractiveTutorialStep
    let panelSize: CGSize
    let failureMessage: String?
    @ObservedObject var sequenceState: InteractiveTutorialSelectorSequenceState
    let retry: () -> Void

    @StateObject private var largeMediaPreview = InteractiveTutorialLargeMediaPreviewController()

    private static let mediaSubdirectory = "InteractiveTutorialVideos"

    private static let introPages = [
        "Some steps happen on your iPhone. Others happen here on this Mac.",
        "Follow them in order. Specchio will keep the next action visible."
    ]

    private static let requiredIndex = introPages.count
    private static let firstInstructionIndex = requiredIndex + 1
    private static let requiredMedia = selectorMedia(
        slideNumber: 3,
        fileExtension: "mp4",
        preferredDisplayHeight: 300,
        aspectRatio: 1144.0 / 1080.0,
        accessibilityLabel: "Required Bluetooth pairing preparation video"
    )

    private static let instructionSteps: [InteractiveTutorialSelectorInstructionStep] = [
        InteractiveTutorialSelectorInstructionStep(
            context: "On your iPhone",
            title: "Open Bluetooth Settings",
            detail: "Open Settings > Bluetooth and keep this screen visible.",
            isRequired: false,
            media: selectorMedia(
                slideNumber: 4,
                fileExtension: "mp4",
                preferredDisplayHeight: 360,
                aspectRatio: 1080.0 / 2346.0,
                accessibilityLabel: "Open iPhone Bluetooth Settings tutorial video"
            )
        ),
        InteractiveTutorialSelectorInstructionStep(
            context: "On your iPhone",
            title: "Forget this Mac if it is already paired",
            detail: "If you already see this Mac in My Devices, tap the info button and choose Forget This Device before continuing.",
            isRequired: true,
            media: selectorMedia(
                slideNumber: 5,
                fileExtension: "mp4",
                preferredDisplayHeight: 360,
                aspectRatio: 1080.0 / 2346.0,
                accessibilityLabel: "Forget the Mac on iPhone Bluetooth tutorial video"
            )
        ),
        InteractiveTutorialSelectorInstructionStep(
            context: "On this Mac",
            title: "Find your iPhone",
            detail: "In the macOS Bluetooth selector, look for your iPhone in the Devices list.",
            isRequired: false
        ),
        InteractiveTutorialSelectorInstructionStep(
            context: "On this Mac",
            title: "Scroll if needed",
            detail: "If your iPhone is not visible, scroll all the way down. It can take a few seconds for the iPhone to appear, and macOS can show it lower in the list.",
            alertLabel: "Important",
            media: selectorMedia(
                slideNumber: 7,
                fileExtension: "mp4",
                preferredDisplayHeight: 300,
                aspectRatio: 1476.0 / 1080.0,
                accessibilityLabel: "Scroll the macOS Bluetooth selector tutorial video"
            )
        ),
        InteractiveTutorialSelectorInstructionStep(
            context: "On this Mac",
            title: "Click Connect",
            detail: "Click Connect next to your iPhone, then wait for the pairing prompt.",
            isRequired: false
        ),
        InteractiveTutorialSelectorInstructionStep(
            context: "Back on your iPhone",
            title: "Confirm pairing on the iPhone",
            detail: "When your iPhone asks for permission, confirm the pairing request.",
            isRequired: false,
            media: selectorMedia(
                slideNumber: 9,
                fileExtension: "mov",
                preferredDisplayHeight: 360,
                aspectRatio: 1206.0 / 2622.0,
                accessibilityLabel: "Confirm Bluetooth pairing on the iPhone tutorial video"
            )
        ),
        InteractiveTutorialSelectorInstructionStep(
            context: "Back on this Mac",
            title: "Select your iPhone, then press Select",
            detail: "Make sure your iPhone is highlighted in the selector, then press Select. Specchio will continue automatically after macOS confirms the selection.",
            isRequired: false,
            media: selectorMedia(
                slideNumber: 10,
                fileExtension: "mp4",
                preferredDisplayHeight: 300,
                aspectRatio: 1236.0 / 1080.0,
                accessibilityLabel: "Select the iPhone in macOS Bluetooth selector tutorial video"
            )
        )
    ]

    private static func selectorMedia(
        slideNumber: Int,
        fileExtension: String,
        preferredDisplayHeight: CGFloat,
        aspectRatio: CGFloat,
        accessibilityLabel: String
    ) -> InteractiveTutorialMedia {
        InteractiveTutorialMedia(
            kind: .loopingVideo,
            resourceName: "slide_\(slideNumber)",
            fileExtension: fileExtension,
            accessibilityLabel: accessibilityLabel,
            resourceSubdirectory: mediaSubdirectory,
            preferredDisplayHeight: preferredDisplayHeight,
            aspectRatio: aspectRatio
        )
    }

    private var totalCount: Int {
        Self.firstInstructionIndex + Self.instructionSteps.count
    }

    private var activeIndex: Int {
        sequenceState.activeIndex
    }

    private var instructionIndex: Int? {
        guard activeIndex >= Self.firstInstructionIndex else { return nil }
        let index = activeIndex - Self.firstInstructionIndex
        guard Self.instructionSteps.indices.contains(index) else { return nil }
        return index
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            Divider()
            activeContent
                .frame(maxWidth: .infinity, alignment: .leading)
            if let failureMessage {
                failureView(failureMessage)
            }
            Spacer(minLength: 0)
            footer
        }
        .padding(20)
        .frame(
            width: panelSize.width,
            height: panelSize.height,
            alignment: .topLeading
        )
        .preferredColorScheme(.dark)
        .onAppear {
            SpecchioLogger.easyMode.info("[InteractiveTutorialSelectorSequence] appeared step=\(step.id.rawValue, privacy: .public) activeIndex=\(activeIndex) total=\(totalCount)")
        }
        .onChange(of: activeIndex) { _, newValue in
            SpecchioLogger.easyMode.info("[InteractiveTutorialSelectorSequence] active item changed step=\(step.id.rawValue, privacy: .public) activeIndex=\(newValue) description=\(activeDescription(for: newValue), privacy: .public)")
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 4) {
                Text(step.title)
                    .font(.title2.weight(.semibold))
                Text(activeProgressLabel)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Text("\(min(activeIndex + 1, totalCount)) / \(totalCount)")
                .font(.caption.monospacedDigit().weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(.white.opacity(0.08), in: Capsule())
        }
    }

    @ViewBuilder
    private var activeContent: some View {
        if activeIndex < Self.introPages.count {
            introCard(Self.introPages[activeIndex])
        } else if activeIndex == Self.requiredIndex {
            requiredCard
        } else if let instructionIndex {
            instructionCard(Self.instructionSteps[instructionIndex], index: instructionIndex)
        } else {
            fallbackCard
        }
    }

    private var footer: some View {
        HStack {
            if activeIndex > 0 {
                Button {
                    let previous = max(0, activeIndex - 1)
                    SpecchioLogger.easyMode.info("[InteractiveTutorialSelectorSequence] back tapped from=\(activeIndex) to=\(previous) description=\(activeDescription(for: activeIndex), privacy: .public)")
                    sequenceState.setActiveIndex(previous, step: step, source: "selector Back button")
                } label: {
                    Label("Back", systemImage: "chevron.left")
                }
                .buttonStyle(.bordered)
            }

            Spacer()

            if activeIndex < totalCount - 1 {
                Button {
                    let next = min(totalCount - 1, activeIndex + 1)
                    SpecchioLogger.easyMode.info("[InteractiveTutorialSelectorSequence] next tapped from=\(activeIndex) to=\(next) description=\(activeDescription(for: activeIndex), privacy: .public)")
                    sequenceState.setActiveIndex(next, step: step, source: "selector Continue button")
                } label: {
                    Label(nextButtonTitle, systemImage: "play.fill")
                }
                .buttonStyle(.borderedProminent)
            } else {
                Text("Now press Select in the macOS selector.")
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var activeProgressLabel: String {
        if activeIndex < Self.introPages.count {
            return "Read this first"
        }
        if activeIndex == Self.requiredIndex {
            return "Required before connecting"
        }
        if let instructionIndex {
            return "Guided step \(instructionIndex + 1) of \(Self.instructionSteps.count)"
        }
        return "Guided setup"
    }

    private var nextButtonTitle: String {
        if activeIndex == Self.requiredIndex {
            return "I understand"
        }
        return "Continue"
    }

    private func introCard(_ text: String) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Image(systemName: "iphone")
                .font(.system(size: 34, weight: .semibold))
                .foregroundStyle(.blue)
            Text(text)
                .font(.title3.weight(.semibold))
                .fixedSize(horizontal: false, vertical: true)
            Text("Take these one at a time. Specchio will keep the next action focused.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(.white.opacity(0.18), lineWidth: 1)
        }
        .onAppear {
            SpecchioLogger.easyMode.info("[InteractiveTutorialSelectorSequence] intro displayed index=\(activeIndex) text=\(text, privacy: .public)")
        }
    }

    private var requiredCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Required before connecting", systemImage: "exclamationmark.triangle.fill")
                .font(.headline.weight(.bold))
                .foregroundStyle(.red)
            Text("Find your iPhone in the macOS Bluetooth selector first.")
                .font(.title3.weight(.bold))
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
            Text("If your iPhone is already listed on the left, remove it by pressing the X before continuing.")
                .font(.callout.weight(.semibold))
                .foregroundStyle(.red)
                .fixedSize(horizontal: false, vertical: true)
            selectorMediaAttachment(
                Self.requiredMedia,
                slideNumber: Self.requiredIndex + 1,
                title: "Required before connecting"
            )
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.red.opacity(0.12), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(.red.opacity(0.9), lineWidth: 2)
        }
        .onAppear {
            SpecchioLogger.easyMode.warning("[InteractiveTutorialSelectorSequence] required warning displayed step=\(step.id.rawValue, privacy: .public)")
        }
    }

    private func instructionCard(_ item: InteractiveTutorialSelectorInstructionStep, index: Int) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Text(item.context)
                    .font(.caption.weight(.bold))
                    .foregroundStyle(item.usesAlertStyle ? .red : .blue)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 5)
                    .background((item.usesAlertStyle ? Color.red : Color.blue).opacity(0.14), in: Capsule())
                if let alertLabel = item.alertLabel {
                    Label(alertLabel, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.red)
                }
            }

            Text(item.title)
                .font(.title3.weight(.bold))
                .fixedSize(horizontal: false, vertical: true)

            Text(item.detail)
                .font(.callout)
                .foregroundStyle(item.usesAlertStyle ? .red : .secondary)
                .fontWeight(item.usesAlertStyle ? .semibold : .regular)
                .fixedSize(horizontal: false, vertical: true)

            selectorMediaView(for: item, index: index)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(item.usesAlertStyle ? Color.red.opacity(0.9) : Color.white.opacity(0.18), lineWidth: item.usesAlertStyle ? 2 : 1)
        }
        .onAppear {
            SpecchioLogger.easyMode.info("[InteractiveTutorialSelectorSequence] instruction displayed index=\(index) context=\(item.context, privacy: .public) title=\(item.title, privacy: .public) required=\(item.isRequired) alertLabel=\(item.alertLabel ?? "none", privacy: .public)")
        }
    }

    private var fallbackCard: some View {
        Text(step.body)
            .font(.callout)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .onAppear {
                SpecchioLogger.easyMode.error("[InteractiveTutorialSelectorSequence] fallback displayed activeIndex=\(activeIndex) total=\(totalCount)")
            }
    }

    private func failureView(_ message: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Divider()
            Text(message)
                .font(.callout.weight(.semibold))
                .foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
            Button("Retry step", action: retry)
                .buttonStyle(.borderedProminent)
        }
    }

    @ViewBuilder
    private func selectorMediaView(for item: InteractiveTutorialSelectorInstructionStep, index: Int) -> some View {
        let slideNumber = Self.firstInstructionIndex + index + 1
        if let media = item.media {
            selectorMediaAttachment(media, slideNumber: slideNumber, title: item.title)
        } else {
            Color.clear
                .frame(height: 0)
                .onAppear {
                    SpecchioLogger.easyMode.info("[InteractiveTutorialSelectorSequence] media skipped slide=\(slideNumber) index=\(index) title=\(item.title, privacy: .public) reason=no-local-video-configured")
                }
        }
    }

    private func selectorMediaAttachment(
        _ media: InteractiveTutorialMedia,
        slideNumber: Int,
        title: String
    ) -> some View {
        Group {
            if let videoAsset = media.tutorialVideoAsset {
                TutorialVideoPlayerView(
                    asset: videoAsset,
                    displayHeight: media.preferredDisplayHeight,
                    source: "selector-slide-\(slideNumber)"
                )
            } else {
                ZStack(alignment: .topTrailing) {
                    InteractiveTutorialMediaAttachmentView(media: media)

                    Button {
                        SpecchioLogger.easyMode.info("[InteractiveTutorialSelectorSequence] large media preview tapped slide=\(slideNumber) title=\(title, privacy: .public) media=\(media.diagnosticName, privacy: .public)")
                        largeMediaPreview.show(media: media, title: title, source: "selector-slide-\(slideNumber)")
                    } label: {
                        Image(systemName: "arrow.up.left.and.arrow.down.right")
                            .font(.system(size: 13, weight: .bold))
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .help("Open large preview")
                    .accessibilityLabel("Open large preview for \(title)")
                    .padding(8)
                }
                .frame(height: media.preferredDisplayHeight)
                .background(Color.black.opacity(0.9), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(.white.opacity(0.12), lineWidth: 1)
                }
            }
        }
        .onAppear {
            SpecchioLogger.easyMode.info("[InteractiveTutorialSelectorSequence] local media attached slide=\(slideNumber) title=\(title, privacy: .public) media=\(media.diagnosticName, privacy: .public) height=\(media.preferredDisplayHeight) isPortrait=\(media.isPortraitVideo)")
        }
    }

    private func activeDescription(for index: Int) -> String {
        if index < Self.introPages.count {
            return "intro-\(index + 1)"
        }
        if index == Self.requiredIndex {
            return "required-warning"
        }
        let instruction = index - Self.firstInstructionIndex
        if Self.instructionSteps.indices.contains(instruction) {
            return "instruction-\(instruction + 1)-\(Self.instructionSteps[instruction].title)"
        }
        return "unknown"
    }
}

private struct InteractiveTutorialSelectorInstructionStep: Equatable {
    let context: String
    let title: String
    let detail: String
    let isRequired: Bool
    let alertLabel: String?
    let media: InteractiveTutorialMedia?

    init(
        context: String,
        title: String,
        detail: String,
        isRequired: Bool = false,
        alertLabel: String? = nil,
        media: InteractiveTutorialMedia? = nil
    ) {
        self.context = context
        self.title = title
        self.detail = detail
        self.isRequired = isRequired
        self.alertLabel = alertLabel ?? (isRequired ? "Required" : nil)
        self.media = media
    }

    var usesAlertStyle: Bool {
        alertLabel != nil
    }
}
