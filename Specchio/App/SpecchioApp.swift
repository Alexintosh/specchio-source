import SwiftUI
import Sparkle
import os.log

// MARK: - Environment key for SPUUpdater

private struct SPUUpdaterKey: EnvironmentKey {
    static let defaultValue: SPUUpdater? = nil
}

extension EnvironmentValues {
    var spuUpdater: SPUUpdater? {
        get { self[SPUUpdaterKey.self] }
        set { self[SPUUpdaterKey.self] = newValue }
    }
}

@main
struct SpecchioApp: App {
    /// Ensure child processes (iproxy, xcodebuild) are terminated when the app quits.
    /// SwiftUI @StateObject deinit is not reliably called on app exit, so we use
    /// NSApplication.willTerminateNotification to catch all exit paths.
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    @StateObject private var appState = AppState()
    @StateObject private var bluetoothHIDPanel = BluetoothHIDPanelController()

    let updaterController = SPUStandardUpdaterController(
        startingUpdater: true,
        updaterDelegate: nil,
        userDriverDelegate: nil
    )

    private var defaultEasyModeWindowSize: CGSize {
        SpecchioPhoneWindowMetrics.preferredLaunchPhoneScreenSize()
    }

    var body: some Scene {
        WindowGroup {
            SpecchioWindowRoot(
                appState: appState,
                bluetoothHIDPanel: bluetoothHIDPanel,
                updater: updaterController.updater
            )
            .preferredColorScheme(.dark)
        }
        .defaultSize(
            width: defaultEasyModeWindowSize.width,
            height: defaultEasyModeWindowSize.height
        )
        .commands {
            SpecchioAppCommands(
                appDelegate: appDelegate,
                appState: appState,
                updaterController: updaterController
            )
        }

        MenuBarExtra {
            MenuBarPopoverView(appState: appState)
                .preferredColorScheme(.dark)
        } label: {
            Image(systemName: "iphone")
        }
        .menuBarExtraStyle(.window)

        #if os(macOS)
        Settings {
            SettingsView(updater: updaterController.updater)
                .preferredColorScheme(.dark)
        }
        .windowResizability(.contentMinSize)
        #endif
    }
}

private struct SpecchioLaunchModeFocusedKey: FocusedValueKey {
    typealias Value = Binding<SpecchioLaunchMode>
}

private struct SpecchioPaywallFocusedKey: FocusedValueKey {
    typealias Value = () -> Void
}

private struct SpecchioInteractiveOnboardingFocusedKey: FocusedValueKey {
    typealias Value = () -> Void
}

extension FocusedValues {
    var specchioLaunchMode: Binding<SpecchioLaunchMode>? {
        get { self[SpecchioLaunchModeFocusedKey.self] }
        set { self[SpecchioLaunchModeFocusedKey.self] = newValue }
    }

    var specchioShowPaywall: (() -> Void)? {
        get { self[SpecchioPaywallFocusedKey.self] }
        set { self[SpecchioPaywallFocusedKey.self] = newValue }
    }

    var specchioStartInteractiveOnboarding: (() -> Void)? {
        get { self[SpecchioInteractiveOnboardingFocusedKey.self] }
        set { self[SpecchioInteractiveOnboardingFocusedKey.self] = newValue }
    }
}

private struct SpecchioWindowRoot: View {
    @ObservedObject var appState: AppState
    @ObservedObject var bluetoothHIDPanel: BluetoothHIDPanelController
    let updater: SPUUpdater?

    @State private var selectedMode: SpecchioLaunchMode = .easy
    @State private var windowID = UUID().uuidString
    @State private var showDevMenuPaywall = false
    @AppStorage(AppSettings.Keys.alwaysOnTop) private var alwaysOnTop = false
    @AppStorage(AppSettings.Keys.easyToolbarStyle) private var easyToolbarStyle = AppSettings.Defaults.easyToolbarStyle

    private var easyMatchedWindowAspectPolicy: SpecchioWindowAspectPolicy {
        .visibleContentPhoneSurface(
            phoneSize: SpecchioPhoneWindowMetrics.defaultPhoneScreenSize,
            reservedTopHeight: EasyControlBarMetrics.windowReservedHeight
        )
    }

    private func windowAspectPolicy(for mode: SpecchioLaunchMode) -> SpecchioWindowAspectPolicy {
        switch mode {
        case .easy:
            return .disabled
        case .dev:
            return easyMatchedWindowAspectPolicy
        }
    }

    private var windowAspectPolicy: SpecchioWindowAspectPolicy {
        windowAspectPolicy(for: selectedMode)
    }

    private var windowChromeStyle: SpecchioWindowChromeStyle {
        switch selectedMode {
        case .easy:
            return .iPhoneMirroringPresentation
        case .dev:
            return .standard
        }
    }

    private var presentationStandardTitlebarEnabled: Bool {
        false
    }

    private var easyLaunchWindowSize: CGSize {
        SpecchioPhoneWindowMetrics.preferredLaunchPhoneScreenSize()
    }

    var body: some View {
        Group {
            switch selectedMode {
            case .easy:
                EasyModeView(appState: appState, bluetoothHIDPanel: bluetoothHIDPanel)
            case .dev:
                MainWindow(appState: appState)
            }
        }
        .environment(\.spuUpdater, updater)
        .sheet(isPresented: $showDevMenuPaywall) {
            PremiumUpsellView()
        }
        .modifier(SpecchioWindowChromeModifier(
            aspectPolicy: windowAspectPolicy,
            chromeStyle: windowChromeStyle,
            alwaysOnTop: alwaysOnTop,
            presentationStandardTitlebarEnabled: presentationStandardTitlebarEnabled
        ))
        .focusedSceneValue(\.specchioLaunchMode, $selectedMode)
        .focusedSceneValue(\.specchioShowPaywall, showPaywallFromDevMenu)
        .focusedSceneValue(\.specchioStartInteractiveOnboarding, startInteractiveOnboardingFromDevMenu)
        .onAppear {
            SpecchioLogger.easyMode.info("[SpecchioWindowRoot] appeared windowID=\(windowID, privacy: .public) mode=\(selectedMode.logName, privacy: .public) windowPolicy=\(windowAspectPolicy.logDescription, privacy: .public) chromeStyle=\(windowChromeStyle.logName, privacy: .public) easyToolbarStyle=\(easyToolbarStyle, privacy: .public) presentationStandardTitlebarEnabled=\(presentationStandardTitlebarEnabled) alwaysOnTop=\(alwaysOnTop)")
            SpecchioLogger.easyMode.info("[SpecchioWindowRoot] easy launch size rule source=\(SpecchioPhoneWindowMetrics.easyModeLaunchMeasurementSource, privacy: .public) launchWidth=\(easyLaunchWindowSize.width) launchHeight=\(easyLaunchWindowSize.height) toolbarWindowSeparate=true")
        }
        .onChange(of: selectedMode) { oldValue, newValue in
            SpecchioLogger.easyMode.info("[SpecchioWindowRoot] mode changed windowID=\(windowID, privacy: .public) from=\(oldValue.logName, privacy: .public) to=\(newValue.logName, privacy: .public) windowPolicy=\(windowAspectPolicy.logDescription, privacy: .public) chromeStyle=\(windowChromeStyle.logName, privacy: .public) easyToolbarStyle=\(easyToolbarStyle, privacy: .public) presentationStandardTitlebarEnabled=\(presentationStandardTitlebarEnabled) alwaysOnTop=\(alwaysOnTop)")
        }
        .onChange(of: alwaysOnTop) { _, newValue in
            SpecchioLogger.easyMode.info("[SpecchioWindowRoot] alwaysOnTop changed windowID=\(windowID, privacy: .public) enabled=\(newValue) chromeStyle=\(windowChromeStyle.logName, privacy: .public)")
        }
        .onChange(of: easyToolbarStyle) { _, newValue in
            SpecchioLogger.easyMode.info("[SpecchioWindowRoot] easy toolbar style changed windowID=\(windowID, privacy: .public) style=\(newValue, privacy: .public) presentationStandardTitlebarEnabled=\(presentationStandardTitlebarEnabled)")
        }
        .onChange(of: showDevMenuPaywall) { _, isPresented in
            SpecchioLogger.ui.info("[SpecchioWindowRoot] Dev menu paywall presentation changed windowID=\(windowID, privacy: .public) presented=\(isPresented)")
        }
    }

    private func showPaywallFromDevMenu() {
        SpecchioLogger.ui.info("[SpecchioWindowRoot] Dev menu paywall presentation requested windowID=\(windowID, privacy: .public) previousPresented=\(showDevMenuPaywall)")
        showDevMenuPaywall = true
    }

    private func startInteractiveOnboardingFromDevMenu() {
        SpecchioLogger.easyMode.info("[SpecchioWindowRoot] Dev menu onboarding requested windowID=\(windowID, privacy: .public) currentMode=\(selectedMode.logName, privacy: .public)")
        selectedMode = .easy
        DispatchQueue.main.async {
            InteractiveTutorialCoordinator.shared.startFirstBluetoothSetup(
                source: "Dev menu Onboarding",
                resetPhase: true
            )
        }
    }
}

private struct SpecchioAppCommands: Commands {
    @FocusedBinding(\.specchioLaunchMode) private var focusedMode: SpecchioLaunchMode?
    @FocusedValue(\.specchioShowPaywall) private var showFocusedPaywall
    @FocusedValue(\.specchioStartInteractiveOnboarding) private var startFocusedInteractiveOnboarding

    let appDelegate: AppDelegate
    let appState: AppState
    let updaterController: SPUStandardUpdaterController

    var body: some Commands {
        CommandGroup(replacing: .appInfo) {
            Button("About Specchio") {
                appDelegate.showAboutPanel()
            }
        }
        CommandGroup(after: .appInfo) {
            Button("Check for Updates...") {
                updaterController.checkForUpdates(nil)
            }
        }
        CommandGroup(after: .appSettings) {
            Button("Save Screenshot") {
                NotificationCenter.default.post(name: .saveScreenshot, object: nil)
            }
            .keyboardShortcut("s", modifiers: .command)
        }
        CommandMenu("Dev") {
            Button("Easy Mode") {
                setFocusedMode(.easy, source: "Dev menu Easy Mode")
            }
            Button("Dev Mode") {
                setFocusedMode(.dev, source: "Dev menu Dev Mode")
            }
            Divider()
            Button("Diagnostics") {
                SpecchioLogger.easyMode.info("[SpecchioAppCommands] Dev menu selected Diagnostics")
                appDelegate.showDiagnosticsWindow(appState: appState)
            }
            .keyboardShortcut("d", modifiers: [.command, .shift])

            Button("Onboarding") {
                startInteractiveOnboardingFromDevMenu()
            }

            Button("Paywall") {
                showPaywallFromDevMenu()
            }
        }
    }

    private func setFocusedMode(_ mode: SpecchioLaunchMode, source: String) {
        guard let currentMode = focusedMode else {
            SpecchioLogger.easyMode.info("[SpecchioAppCommands] mode change skipped source=\(source, privacy: .public) target=\(mode.logName, privacy: .public) branch=no-focused-window")
            return
        }

        guard currentMode != mode else {
            SpecchioLogger.easyMode.info("[SpecchioAppCommands] mode change skipped source=\(source, privacy: .public) target=\(mode.logName, privacy: .public) branch=already-selected")
            return
        }

        SpecchioLogger.easyMode.info("[SpecchioAppCommands] mode change applied source=\(source, privacy: .public) from=\(currentMode.logName, privacy: .public) to=\(mode.logName, privacy: .public) branch=focused-window")
        focusedMode = mode
    }

    private func showPaywallFromDevMenu() {
        guard let showFocusedPaywall else {
            SpecchioLogger.ui.info("[SpecchioAppCommands] Dev menu selected Paywall branch=no-focused-window")
            return
        }

        SpecchioLogger.ui.info("[SpecchioAppCommands] Dev menu selected Paywall branch=focused-window")
        showFocusedPaywall()
    }

    private func startInteractiveOnboardingFromDevMenu() {
        guard let startFocusedInteractiveOnboarding else {
            SpecchioLogger.easyMode.info("[SpecchioAppCommands] Dev menu selected Onboarding branch=no-focused-window")
            return
        }

        SpecchioLogger.easyMode.info("[SpecchioAppCommands] Dev menu selected Onboarding branch=focused-window")
        startFocusedInteractiveOnboarding()
    }
}

private extension SpecchioLaunchMode {
    var logName: String {
        switch self {
        case .easy:
            return "easy"
        case .dev:
            return "dev"
        }
    }
}

extension Notification.Name {
    static let saveScreenshot = Notification.Name("saveScreenshot")
    static let showDiagnostics = Notification.Name("showDiagnostics")
}

class AppDelegate: NSObject, NSApplicationDelegate {
    private var diagnosticsWindow: NSWindow?

    func applicationWillFinishLaunching(_ notification: Notification) {
        applyForcedDarkAppearance(source: "willFinishLaunching")
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        applyForcedDarkAppearance(source: "didFinishLaunching")
    }

    private func applyForcedDarkAppearance(source: String) {
        guard let darkAppearance = NSAppearance(named: .darkAqua) else {
            SpecchioLogger.ui.error("[Appearance] forced dark mode failed source=\(source, privacy: .public) reason=darkAqua-unavailable")
            return
        }

        NSApp.appearance = darkAppearance
        SpecchioLogger.ui.info("[Appearance] forced app appearance source=\(source, privacy: .public) appearance=darkAqua effective=\(NSApp.effectiveAppearance.name.rawValue, privacy: .public)")
    }

    func showAboutPanel() {
        let credits = NSMutableAttributedString(
            string: "Made with Love by Alexintosh",
            attributes: [
                .font: NSFont.systemFont(ofSize: 11),
                .foregroundColor: NSColor.secondaryLabelColor,
            ]
        )
        let linkRange = (credits.string as NSString).range(of: "Alexintosh")
        credits.addAttribute(.link, value: URL(string: "https://x.com/Alexintosh")!, range: linkRange)
        credits.addAttribute(.foregroundColor, value: NSColor.linkColor, range: linkRange)

        NSApplication.shared.orderFrontStandardAboutPanel(options: [
            .credits: credits,
        ])
    }

    func showDiagnosticsWindow(appState: AppState) {
        os_log(.info, "AppDelegate: showDiagnosticsWindow called")

        if let window = diagnosticsWindow {
            os_log(.info, "AppDelegate: reusing existing diagnostics window")
            window.makeKeyAndOrderFront(nil)
            NSApplication.shared.activate(ignoringOtherApps: true)
            return
        }

        os_log(.info, "AppDelegate: creating new diagnostics window")
        let view = DiagnosticsView(appState: appState)
            .preferredColorScheme(.dark)
        let hosting = NSHostingView(rootView: view)
        hosting.frame = NSRect(x: 0, y: 0, width: 540, height: 580)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 540, height: 580),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Specchio Diagnostics"
        window.contentView = hosting
        window.isReleasedWhenClosed = false
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApplication.shared.activate(ignoringOtherApps: true)

        self.diagnosticsWindow = window
        os_log(.info, "AppDelegate: diagnostics window created and shown")
    }

    func applicationWillTerminate(_ notification: Notification) {
        // Kill iproxy tunnels we spawned — they're useless without the app.
        // Do NOT kill xcodebuild: WDA runs on the phone and should stay alive
        // so WiFi connections continue working after the Mac app quits.
        for port in [8100, 9100, 9200] {
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            proc.arguments = ["lsof", "-ti", ":\(port)"]
            let pipe = Pipe()
            proc.standardOutput = pipe
            proc.standardError = Pipe()
            try? proc.run()
            proc.waitUntilExit()

            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            guard let output = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !output.isEmpty else { continue }
            for pidStr in output.components(separatedBy: "\n") {
                if let pid = Int32(pidStr.trimmingCharacters(in: .whitespaces)),
                   pid != ProcessInfo.processInfo.processIdentifier {
                    kill(pid, SIGTERM)
                }
            }
        }
    }
}
