import SwiftUI
import Sparkle

private enum SettingsPanel: String, CaseIterable, Hashable, Identifiable {
    case general
    case connection
    case keyboardMouse
    case videoMirroring
    case toolbar
    case licenceUpdates
    case experiments
    case developers

    var id: Self { self }

    var title: String {
        switch self {
        case .general:
            return "General"
        case .connection:
            return "Connection"
        case .keyboardMouse:
            return "Keyboard & Mouse"
        case .videoMirroring:
            return "Video Mirroring"
        case .toolbar:
            return "Toolbar"
        case .licenceUpdates:
            return "Licence & Updates"
        case .experiments:
            return "Experiments"
        case .developers:
            return "Developers"
        }
    }

    var subtitle: String {
        switch self {
        case .general:
            return "Window behavior and app-wide preferences"
        case .connection:
            return "Reconnect, clipboard sync, and device unlock"
        case .keyboardMouse:
            return "Input behavior, cursor visibility, and shortcuts"
        case .videoMirroring:
            return "Streaming quality and frame rates"
        case .toolbar:
            return "Easy toolbar order and visible controls"
        case .licenceUpdates:
            return "Premium status, updates, and app information"
        case .experiments:
            return "Try experimental interaction features"
        case .developers:
            return "Experimental controls and WebDriverAgent tools"
        }
    }

    var systemImage: String {
        switch self {
        case .general:
            return "gearshape"
        case .connection:
            return "antenna.radiowaves.left.and.right"
        case .keyboardMouse:
            return "keyboard"
        case .videoMirroring:
            return "iphone"
        case .toolbar:
            return "rectangle.topthird.inset.filled"
        case .licenceUpdates:
            return "checkmark.seal"
        case .experiments:
            return "testtube.2"
        case .developers:
            return "hammer"
        }
    }

    var logName: String {
        switch self {
        case .general:
            return "general"
        case .connection:
            return "connection"
        case .keyboardMouse:
            return "keyboard-mouse"
        case .videoMirroring:
            return "video-mirroring"
        case .toolbar:
            return "toolbar"
        case .licenceUpdates:
            return "licence-updates"
        case .experiments:
            return "experiments"
        case .developers:
            return "developers"
        }
    }
}

private enum SettingsViewMetrics {
    // The previous settings form used 560pt as its ideal width; the fixed sidebar keeps
    // that content width and adds room for the native sidebar navigation.
    static let previousFormIdealWidth: CGFloat = 560
    static let sidebarNavigationWidth: CGFloat = 240
    static let windowMinimumWidth = previousFormIdealWidth + sidebarNavigationWidth
    static let windowIdealWidth = windowMinimumWidth + 120
    static let windowMinimumHeight: CGFloat = 520
    static let windowIdealHeight = windowMinimumHeight + 160
    static let detailHorizontalPadding: CGFloat = 32
    static let detailTopPadding: CGFloat = 28
    static let headerBottomPadding: CGFloat = 12
    static let formHorizontalInset: CGFloat = 16
    static let headerIconSize: CGFloat = 46
    static let headerIconCornerRadius: CGFloat = 12
    static let activeIndicatorSize: CGFloat = 8
}

struct SettingsView: View {
    @StateObject private var settings = AppSettings()
    @ObservedObject private var licenseManager = LicenseManager.shared
    private let updater: SPUUpdater

    @State private var selectedPanel: SettingsPanel = .general
    @State private var licenseKeyInput = ""
    @State private var showPremiumSheet = false
    @State private var passcodeInput = ""
    @State private var passcodeSaved = PasscodeManager().hasSavedPasscode
    @State private var windowChromeTopInset: CGFloat = 0

    init(updater: SPUUpdater) {
        self.updater = updater
    }

    var body: some View {
        settingsLayout
            .frame(
                minWidth: SettingsViewMetrics.windowMinimumWidth,
                idealWidth: SettingsViewMetrics.windowIdealWidth,
                minHeight: SettingsViewMetrics.windowMinimumHeight,
                idealHeight: SettingsViewMetrics.windowIdealHeight
            )
            .background(SettingsWindowConfigurator(chromeTopInset: $windowChromeTopInset))
            .sheet(isPresented: $showPremiumSheet) {
                PremiumUpsellView()
            }
            .background(settingsChangeObservers)
    }

    private var settingsLayout: some View {
        HStack(spacing: 0) {
            SettingsSidebar(
                selectedPanel: $selectedPanel,
                topInset: windowChromeTopInset
            )

            Divider()

            VStack(alignment: .leading, spacing: 0) {
                SettingsDetailHeader(panel: selectedPanel)
                    .padding(.horizontal, SettingsViewMetrics.detailHorizontalPadding)
                    .padding(.top, SettingsViewMetrics.detailTopPadding)
                    .padding(.bottom, SettingsViewMetrics.headerBottomPadding)

                Form {
                    selectedPanelContent
                }
                .formStyle(.grouped)
                .padding(.horizontal, SettingsViewMetrics.formHorizontalInset)
            }
            .padding(.top, windowChromeTopInset)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(Color(nsColor: .windowBackgroundColor))
            .onAppear {
                SpecchioLogger.ui.info("[SettingsDetail] appeared selected=\(selectedPanel.logName, privacy: .public)")
            }
        }
    }

    private var settingsChangeObservers: some View {
        Group {
            settingsLifecycleObserver
            easyInputSettingsObserver
            easyToolbarSettingsObserver
            easyVideoSettingsObserver
        }
    }

    private var settingsLifecycleObserver: some View {
        Color.clear
        .onAppear {
            handleSettingsAppear()
        }
        .onChange(of: selectedPanel) { oldValue, newValue in
            SpecchioLogger.ui.info("[Settings] selectedPanel changed from=\(oldValue.logName, privacy: .public) to=\(newValue.logName, privacy: .public)")
        }
        .onChange(of: settings.alwaysOnTop) { _, newValue in
            SpecchioLogger.ui.info("[Settings] Always on Top changed enabled=\(newValue)")
        }
        .onChange(of: settings.bluetoothAutoConnect) { _, newValue in
            SpecchioLogger.ui.info("[Settings] Bluetooth auto-connect changed enabled=\(newValue)")
        }
    }

    private var easyInputSettingsObserver: some View {
        Color.clear
        .onChange(of: settings.easyMouseClutchMode) { _, newValue in
            SpecchioLogger.easyMode.info("[Settings] Easy clutch mode changed enabled=\(newValue)")
        }
        .onChange(of: settings.easyHideLocalCursor) { _, newValue in
            SpecchioLogger.easyMode.info("[Settings] Easy hide local cursor changed enabled=\(newValue)")
        }
        .onChange(of: settings.easyPointerSpikeEnabled) { _, newValue in
            SpecchioLogger.easyMode.info("[Settings] Easy pointer spike changed enabled=\(newValue)")
        }
        .onChange(of: settings.easyPointerSpikeOverlayEnabled) { _, newValue in
            SpecchioLogger.easyMode.info("[Settings] Easy pointer spike overlay changed enabled=\(newValue)")
        }
        .onChange(of: settings.easyPointerSpikeTransportVariant) { _, newValue in
            SpecchioLogger.easyMode.info("[Settings] Easy pointer spike transport changed variant=\(newValue)")
        }
        .onChange(of: settings.easyTrackpadSwipeToDragEnabled) { _, newValue in
            SpecchioLogger.easyMode.info("[Settings] Easy trackpad swipe to drag experiment changed enabled=\(newValue)")
            FrameDropDiagnostics.shared.recordLifecycle(
                source: "easyTrackpadGesture",
                event: "settingChanged",
                reason: "settings-toggle",
                details: ["enabled": String(newValue)]
            )
        }
        .onChange(of: settings.easyTrackpadSwipeToDragMode) { _, newValue in
            let sanitizedValue = AppSettings.EasyTrackpadSwipeToDragMode.sanitized(newValue)
            if sanitizedValue != newValue {
                SpecchioLogger.easyMode.info("[Settings] Easy trackpad swipe mode sanitized requested=\(newValue, privacy: .public) applied=\(sanitizedValue, privacy: .public)")
                settings.easyTrackpadSwipeToDragMode = sanitizedValue
                return
            }
            SpecchioLogger.easyMode.info("[Settings] Easy trackpad swipe mode changed mode=\(sanitizedValue, privacy: .public)")
            FrameDropDiagnostics.shared.recordLifecycle(
                source: "easyTrackpadGesture",
                event: "settingChanged",
                reason: "settings-mode-picker",
                details: ["mode": sanitizedValue]
            )
        }
    }

    private var easyToolbarSettingsObserver: some View {
        Color.clear
        .onChange(of: settings.easyToolbarCommandOrder) { _, newValue in
            SpecchioLogger.easyMode.info("[Settings] Easy toolbar legacy order changed value=\(newValue, privacy: .public)")
        }
        .onChange(of: settings.easyToolbarVisibleCommandOrder) { _, newValue in
            SpecchioLogger.easyMode.info("[Settings] Easy toolbar visible order changed value=\(newValue, privacy: .public)")
        }
        .onChange(of: settings.easyToolbarOverflowCommandOrder) { _, newValue in
            SpecchioLogger.easyMode.info("[Settings] Easy toolbar overflow order changed value=\(newValue, privacy: .public)")
        }
        .onChange(of: settings.easyToolbarStyle) { _, newValue in
            let sanitizedValue = AppSettings.EasyToolbarStyle.sanitized(newValue)
            if sanitizedValue != newValue {
                SpecchioLogger.easyMode.info("[Settings] Easy toolbar style sanitized requested=\(newValue, privacy: .public) applied=\(sanitizedValue, privacy: .public)")
                settings.easyToolbarStyle = sanitizedValue
                return
            }
            SpecchioLogger.easyMode.info("[Settings] Easy toolbar style changed style=\(sanitizedValue, privacy: .public)")
        }
        .onChange(of: settings.easyToolbarAlwaysVisible) { _, newValue in
            SpecchioLogger.easyMode.info("[Settings] Easy toolbar always visible changed enabled=\(newValue)")
        }
        .onChange(of: settings.easyFloatingToolbarAnchor) { _, newValue in
            let sanitizedValue = AppSettings.EasyFloatingToolbarAnchor.sanitized(newValue)
            if sanitizedValue != newValue {
                SpecchioLogger.easyMode.info("[Settings] Easy floating toolbar anchor sanitized requested=\(newValue, privacy: .public) applied=\(sanitizedValue, privacy: .public)")
                settings.easyFloatingToolbarAnchor = sanitizedValue
                return
            }
            SpecchioLogger.easyMode.info("[Settings] Easy floating toolbar anchor changed anchor=\(sanitizedValue, privacy: .public)")
        }
        .onChange(of: settings.easyFloatingToolbarAllowsDragging) { _, newValue in
            SpecchioLogger.easyMode.info("[Settings] Easy floating toolbar dragging changed enabled=\(newValue)")
        }
        .onChange(of: settings.easyShowFPSCounter) { _, newValue in
            SpecchioLogger.easyMode.info("[Settings] Easy status bar FPS counter changed enabled=\(newValue)")
        }
    }

    private var easyVideoSettingsObserver: some View {
        Color.clear
        .onChange(of: settings.easyReplayKitH264TargetFPS) { _, newValue in
            let sanitizedValue = AppSettings.sanitizedEasyReplayKitH264TargetFPS(newValue)
            if sanitizedValue != newValue {
                SpecchioLogger.easyMode.info("[Settings] Easy ReplayKit H.264 target FPS sanitized requested=\(newValue) applied=\(sanitizedValue)")
                settings.easyReplayKitH264TargetFPS = sanitizedValue
                return
            }
            SpecchioLogger.easyMode.info("[Settings] Easy ReplayKit H.264 target FPS changed value=\(sanitizedValue)")
        }
        .onChange(of: settings.easyAirPlayQuality) { _, newValue in
            let sanitizedValue = AppSettings.EasyAirPlayQuality.sanitized(newValue)
            if sanitizedValue != newValue {
                SpecchioLogger.easyMode.info("[Settings] Easy AirPlay quality sanitized requested=\(newValue, privacy: .public) applied=\(sanitizedValue, privacy: .public)")
                settings.easyAirPlayQuality = sanitizedValue
                return
            }
            let pixels = AppSettings.easyAirPlayDisplayPixels(for: sanitizedValue)
            SpecchioLogger.easyMode.info("[Settings] Easy AirPlay quality changed value=\(sanitizedValue, privacy: .public) display=\(pixels.width)x\(pixels.height)")
        }
        .onChange(of: settings.easyUSBTargetFPS) { _, newValue in
            let sanitizedValue = AppSettings.sanitizedEasyUSBTargetFPS(newValue)
            if sanitizedValue != newValue {
                SpecchioLogger.easyMode.info("[Settings] Easy USB target FPS sanitized requested=\(newValue) applied=\(sanitizedValue)")
                settings.easyUSBTargetFPS = sanitizedValue
                return
            }
            SpecchioLogger.easyMode.info("[Settings] Easy USB target FPS changed value=\(sanitizedValue)")
        }
    }

    private func handleSettingsAppear() {
        SpecchioLogger.ui.info("[Settings] appeared layout=fixed-sidebar selectedPanel=\(self.selectedPanel.logName, privacy: .public)")
        SpecchioLogger.ui.info("[Settings] alwaysOnTop=\(self.settings.alwaysOnTop)")
        SpecchioLogger.ui.info("[Settings] bluetoothAutoConnect=\(self.settings.bluetoothAutoConnect)")
        SpecchioLogger.easyMode.info("[Settings] easyToolbarAlwaysVisible=\(self.settings.easyToolbarAlwaysVisible)")
        SpecchioLogger.easyMode.info("[Settings] easyAirPlayConnectionTutorialHidden=\(self.settings.easyAirPlayConnectionTutorialHidden)")
        sanitizeAirPlayQualityPreference(source: "settings appeared")
        SpecchioLogger.easyMode.info("[Settings] easyMouseClutchMode=\(self.settings.easyMouseClutchMode) easyHideLocalCursor=\(self.settings.easyHideLocalCursor) easyPointerSpikeEnabled=\(self.settings.easyPointerSpikeEnabled) easyPointerSpikeOverlayEnabled=\(self.settings.easyPointerSpikeOverlayEnabled) easyPointerSpikeTransport=\(self.settings.easyPointerSpikeTransportVariant)")
        SpecchioLogger.easyMode.info("[Settings] easyTrackpadSwipeToDragEnabled=\(self.settings.easyTrackpadSwipeToDragEnabled) mode=\(self.settings.easyTrackpadSwipeToDragMode, privacy: .public)")
        SpecchioLogger.easyMode.info("[Settings] easyToolbarCommandOrder legacy=\(self.settings.easyToolbarCommandOrder, privacy: .public) visible=\(self.settings.easyToolbarVisibleCommandOrder, privacy: .public) overflow=\(self.settings.easyToolbarOverflowCommandOrder, privacy: .public)")
        SpecchioLogger.easyMode.info("[Settings] easyToolbarStyle=\(self.settings.easyToolbarStyle, privacy: .public)")
        SpecchioLogger.easyMode.info("[Settings] easyFloatingToolbarAnchor=\(self.settings.easyFloatingToolbarAnchor, privacy: .public) allowsDragging=\(self.settings.easyFloatingToolbarAllowsDragging)")
        SpecchioLogger.easyMode.info("[Settings] easyShowFPSCounter=\(self.settings.easyShowFPSCounter)")
        SpecchioLogger.easyMode.info("[Settings] easyReplayKitH264TargetFPS=\(self.settings.easyReplayKitH264TargetFPS)")
        let airPlayPixels = AppSettings.easyAirPlayDisplayPixels(for: self.settings.easyAirPlayQuality)
        SpecchioLogger.easyMode.info("[Settings] easyAirPlayQuality=\(self.settings.easyAirPlayQuality, privacy: .public) display=\(airPlayPixels.width)x\(airPlayPixels.height)")
        SpecchioLogger.easyMode.info("[Settings] easyUSBTargetFPS=\(self.settings.easyUSBTargetFPS)")
        Task { @MainActor in
            await licenseManager.validate()
        }
    }

    @ViewBuilder
    private var selectedPanelContent: some View {
        switch selectedPanel {
        case .general:
            Group {
                generalSection
            }
            .onAppear {
                SpecchioLogger.ui.info("[SettingsDetail] content branch=general alwaysOnTop=\(settings.alwaysOnTop) easyToolbarAlwaysVisible=\(settings.easyToolbarAlwaysVisible) airPlayTutorialHidden=\(settings.easyAirPlayConnectionTutorialHidden)")
            }

        case .connection:
            Group {
                connectionSection
            }
            .onAppear {
                SpecchioLogger.ui.info("[SettingsDetail] content branch=connection")
            }

        case .keyboardMouse:
            Group {
                easyInputSection
                devInputSection
                shortcutsSection
            }
            .onAppear {
                SpecchioLogger.ui.info("[SettingsDetail] content branch=keyboard-mouse")
            }

        case .videoMirroring:
            Group {
                easyVideoSection
                easyStatusBarSection
            }
            .onAppear {
                SpecchioLogger.ui.info("[SettingsDetail] content branch=video-mirroring")
            }

        case .toolbar:
            Group {
                easyToolbarSection
            }
            .onAppear {
                SpecchioLogger.ui.info("[SettingsDetail] content branch=toolbar")
            }

        case .licenceUpdates:
            Group {
                licenseSection
                updatesSection
                aboutSection
            }
            .onAppear {
                SpecchioLogger.ui.info("[SettingsDetail] content branch=licence-updates")
            }

        case .experiments:
            Group {
                experimentsSection
            }
            .onAppear {
                SpecchioLogger.ui.info("[SettingsDetail] content branch=experiments trackpadSwipeToDrag=\(settings.easyTrackpadSwipeToDragEnabled) mode=\(settings.easyTrackpadSwipeToDragMode, privacy: .public)")
            }

        case .developers:
            Group {
                developerOptionsGateSection
                developerPointerOptionsSection
                devDisplaySection
                developerWDASection
            }
            .onAppear {
                SpecchioLogger.ui.info("[SettingsDetail] content branch=developers showDeveloperOptions=\(settings.showDeveloperOptions)")
            }
        }
    }

    private var generalSection: some View {
        Group {
            Section("Window") {
                Toggle("Always on Top", isOn: $settings.alwaysOnTop)
                Toggle("Toolbar Always Visible", isOn: $settings.easyToolbarAlwaysVisible)
            }
            .onAppear {
                SpecchioLogger.ui.info("[SettingsGeneral] window section visible alwaysOnTop=\(settings.alwaysOnTop) easyToolbarAlwaysVisible=\(settings.easyToolbarAlwaysVisible)")
            }

            Section("Tutorials") {
                Button("Reset Tutorial Preferences") {
                    settings.easyAirPlayConnectionTutorialHidden = AppSettings.Defaults.easyAirPlayConnectionTutorialHidden
                    SpecchioLogger.easyMode.info("[SettingsTutorials] reset requested airPlayTutorialHidden=\(settings.easyAirPlayConnectionTutorialHidden)")
                }
                Text("Shows hidden tutorial prompts again, including the AirPlay connection guide.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .onAppear {
                SpecchioLogger.ui.info("[SettingsTutorials] section visible airPlayTutorialHidden=\(settings.easyAirPlayConnectionTutorialHidden)")
            }
        }
    }

    @ViewBuilder
    private var developerPointerOptionsSection: some View {
        if settings.showDeveloperOptions {
            easyPointerDevelopmentSection
                .onAppear {
                    SpecchioLogger.ui.info("[SettingsDevelopers] pointer options branch=visible")
                }
        } else {
            Section("Easy Pointer Development") {
                Text("Enable Show Development Options to reveal pointer diagnostics.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .onAppear {
                SpecchioLogger.ui.info("[SettingsDevelopers] pointer options branch=hidden")
            }
        }
    }

    private var easyInputSection: some View {
        Section("Bluetooth Input") {
            Toggle("Right-Button Clutch Mode", isOn: $settings.easyMouseClutchMode)
            Text("When enabled, Easy forwards mouse movement only while the right mouse button is held. Disable it to send movement continuously.")
                .font(.caption)
                .foregroundColor(.secondary)

            Toggle("Hide Mac Cursor Over Video", isOn: $settings.easyHideLocalCursor)
            Text("Hide the local macOS pointer while hovering the Easy mirror surface.")
                .font(.caption)
                .foregroundColor(.secondary)
        }
    }

    private var easyToolbarSection: some View {
        Section("Easy Toolbar") {
            Picker("Toolbar Style", selection: $settings.easyToolbarStyle) {
                ForEach(AppSettings.EasyToolbarStyle.allowedValues, id: \.self) { value in
                    Text(AppSettings.EasyToolbarStyle.label(for: value))
                        .tag(value)
                }
            }
            .pickerStyle(.segmented)

            if AppSettings.EasyToolbarStyle.sanitized(settings.easyToolbarStyle) == AppSettings.EasyToolbarStyle.floating {
                Picker("Floating Toolbar Anchor", selection: $settings.easyFloatingToolbarAnchor) {
                    ForEach(AppSettings.EasyFloatingToolbarAnchor.allowedValues, id: \.self) { value in
                        Text(AppSettings.EasyFloatingToolbarAnchor.label(for: value))
                            .tag(value)
                    }
                }
                Toggle("Drag Window from Toolbar", isOn: $settings.easyFloatingToolbarAllowsDragging)
            }

            EasyToolbarOrderSettingsView(
                legacyStorageValue: Binding(
                    get: { settings.easyToolbarCommandOrder },
                    set: { settings.easyToolbarCommandOrder = $0 }
                ),
                visibleStorageValue: Binding(
                    get: { settings.easyToolbarVisibleCommandOrder },
                    set: { settings.easyToolbarVisibleCommandOrder = $0 }
                ),
                overflowStorageValue: Binding(
                    get: { settings.easyToolbarOverflowCommandOrder },
                    set: { settings.easyToolbarOverflowCommandOrder = $0 }
                )
            )
            Text("Drag icons between rows. Up to four stay visible; the rest appear in the overflow menu.")
                .font(.caption)
                .foregroundColor(.secondary)
        }
    }

    private var easyVideoSection: some View {
        Section("Easy Video") {
            HStack {
                Text("H.264 Target FPS: \(Int(settings.easyReplayKitH264TargetFPS))")
                Slider(value: Binding(
                    get: { settings.easyReplayKitH264TargetFPS },
                    set: { settings.easyReplayKitH264TargetFPS = AppSettings.sanitizedEasyReplayKitH264TargetFPS($0) }
                ), in: AppSettings.Ranges.easyReplayKitH264TargetFPS, step: 1)
            }
            Text("Applies to AirPlay mirroring and the ReplayKit H.264 broadcast path; JPEG fallback keeps its separate target.")
                .font(.caption)
                .foregroundColor(.secondary)

            Picker("AirPlay Quality", selection: $settings.easyAirPlayQuality) {
                Text(AppSettings.EasyAirPlayQuality.label(for: AppSettings.EasyAirPlayQuality.balanced))
                    .tag(AppSettings.EasyAirPlayQuality.balanced)
                Text(AppSettings.EasyAirPlayQuality.label(for: AppSettings.EasyAirPlayQuality.high))
                    .tag(AppSettings.EasyAirPlayQuality.high)
            }
            Text("Reconnect AirPlay after changing video settings.")
                .font(.caption)
                .foregroundColor(.secondary)

            HStack {
                Text("USB Target FPS: \(Int(settings.easyUSBTargetFPS))")
                Slider(value: Binding(
                    get: { settings.easyUSBTargetFPS },
                    set: { settings.easyUSBTargetFPS = AppSettings.sanitizedEasyUSBTargetFPS($0) }
                ), in: AppSettings.Ranges.easyUSBTargetFPS, step: 1)
            }
            Text("Applies to native USB screen capture. Set 0 to pause USB frame publishing while keeping the receiver connected.")
                .font(.caption)
                .foregroundColor(.secondary)
        }
    }

    private var easyStatusBarSection: some View {
        Section("Easy Status Bar") {
            Toggle("Show FPS Counter", isOn: $settings.easyShowFPSCounter)
            Text("Shows the live ReplayKit frame rate in the bottom status bar.")
                .font(.caption)
                .foregroundColor(.secondary)
        }
    }

    private var experimentsSection: some View {
        Section("Input Experiments") {
            Toggle("Trackpad Swipe Controls iPhone", isOn: $settings.easyTrackpadSwipeToDragEnabled)
            Text("When enabled, horizontal two-finger trackpad swipes over the Easy video surface are converted into iPhone mouse drags.")
                .font(.caption)
                .foregroundColor(.secondary)
            Picker("Swipe Delivery", selection: $settings.easyTrackpadSwipeToDragMode) {
                ForEach(AppSettings.EasyTrackpadSwipeToDragMode.allowedValues, id: \.self) { mode in
                    Text(AppSettings.EasyTrackpadSwipeToDragMode.label(for: mode)).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .disabled(!settings.easyTrackpadSwipeToDragEnabled)
            Text("Live sends the drag while the trackpad gesture is moving. Delayed waits until the gesture ends, then sends one anchored swipe.")
                .font(.caption)
                .foregroundColor(.secondary)
            Text("Bluetooth mouse control and AssistiveTouch must already be configured on the iPhone.")
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .onAppear {
            SpecchioLogger.easyMode.info("[SettingsExperiments] section visible trackpadSwipeToDrag=\(settings.easyTrackpadSwipeToDragEnabled) mode=\(settings.easyTrackpadSwipeToDragMode, privacy: .public)")
        }
    }

    private var developerOptionsGateSection: some View {
        Section("Development") {
            Toggle("Show Development Options", isOn: $settings.showDeveloperOptions)
            Text("Reveals diagnostics and experimental controls used while developing Specchio.")
                .font(.caption)
                .foregroundColor(.secondary)
        }
    }

    private var easyPointerDevelopmentSection: some View {
        Section("Easy Pointer Development") {
            Toggle("Pointer Spike Mode", isOn: $settings.easyPointerSpikeEnabled)
            Text("Enable deterministic Easy pointer input and the measurement harness.")
                .font(.caption)
                .foregroundColor(.secondary)

            Picker("Pointer Spike Transport", selection: $settings.easyPointerSpikeTransportVariant) {
                Text("Absolute Mouse").tag(AppSettings.EasyPointerSpikeTransport.absoluteMouse)
                Text("Relative Closed Loop").tag(AppSettings.EasyPointerSpikeTransport.relativeClosedLoop)
            }
            .disabled(!settings.easyPointerSpikeEnabled)
            Text("Absolute Mouse sends Report ID 11 with absolute X/Y coordinates. After changing descriptor-capable builds, forget and re-pair the Bluetooth device so iOS reads the updated HID descriptor.")
                .font(.caption)
                .foregroundColor(.secondary)

            Toggle("Show Spike Overlay", isOn: $settings.easyPointerSpikeOverlayEnabled)
                .disabled(!settings.easyPointerSpikeEnabled)
            Text("Render expected and actual calibration points directly over the Easy video surface.")
                .font(.caption)
                .foregroundColor(.secondary)
        }
    }

    private var devDisplaySection: some View {
        Section("Display") {
            Picker("Default Display Mode", selection: $settings.defaultDisplayMode) {
                ForEach(DisplayMode.allCases, id: \.self) { mode in
                    Text(mode.rawValue).tag(mode.rawValue)
                }
            }

            HStack {
                Text("Screenshot FPS: \(Int(settings.screenshotFPS))")
                Slider(value: $settings.screenshotFPS, in: 1...30, step: 1)
                    .disabled(!licenseManager.isPremium && settings.screenshotFPS >= 15)
                if !licenseManager.isPremium {
                    premiumBadge
                }
            }
            .onChange(of: settings.screenshotFPS) { _, newValue in
                if !licenseManager.isPremium && newValue > 15 {
                    settings.screenshotFPS = 15
                }
            }
            .onChange(of: licenseManager.isPremium) { _, isPremium in
                if !isPremium && settings.screenshotFPS > 15 {
                    settings.screenshotFPS = 15
                }
            }

            HStack {
                Text("MJPEG Quality: \(settings.mjpegQuality)%")
                Slider(value: Binding(
                    get: { Double(settings.mjpegQuality) },
                    set: { settings.mjpegQuality = Int($0) }
                ), in: 10...100, step: 5)
            }

            HStack {
                Text("MJPEG Scale: \(settings.mjpegScalingFactor)%")
                Slider(value: Binding(
                    get: { Double(settings.mjpegScalingFactor) },
                    set: { settings.mjpegScalingFactor = Int($0) }
                ), in: 25...100, step: 25)
            }
            Text("Lower quality or scale raises throughput for the WDA video path.")
                .font(.caption)
                .foregroundColor(.secondary)

            HStack {
                Text("H.264 Resolution: \(settings.h264ResolutionScale)%")
                Slider(value: Binding(
                    get: { Double(settings.h264ResolutionScale) },
                    set: { settings.h264ResolutionScale = Int($0) }
                ), in: 25...100, step: 25)
                    .disabled(!licenseManager.isPremium)
                if !licenseManager.isPremium {
                    premiumBadge
                }
            }
            Text("Lower values trade sharpness for faster Wi-Fi streaming.")
                .font(.caption)
                .foregroundColor(.secondary)

            HStack {
                Text("Menu Bar Preview: \(settings.menuBarThumbnailWidth)pt")
                Slider(value: Binding(
                    get: { Double(settings.menuBarThumbnailWidth) },
                    set: { settings.menuBarThumbnailWidth = Int($0) }
                ), in: 200...600, step: 20)
            }

            Toggle("Show Device Bezel", isOn: $settings.showDeviceBezel)
        }
        .onAppear {
            SpecchioLogger.ui.info("[SettingsDevelopers] display section visible scope=wda")
        }
    }

    private var devInputSection: some View {
        Section("Input") {
            HStack {
                Text("Scroll Sensitivity: \(Int(settings.scrollSensitivity))")
                Slider(value: $settings.scrollSensitivity, in: 1...20, step: 1)
            }
        }
    }

    private var connectionSection: some View {
        Section("Connection") {
            Toggle("Auto-Reconnect", isOn: $settings.autoReconnect)
            Toggle("Clipboard Sync", isOn: $settings.clipboardSyncEnabled)
            Toggle("Bluetooth Auto-Connect", isOn: $settings.bluetoothAutoConnect)
            Text("After AirPlay or Bluetooth starts, connect Bluetooth input to the saved app-paired device automatically.")
                .font(.caption)
                .foregroundColor(.secondary)

            Toggle("Auto-Unlock on Connect", isOn: $settings.autoUnlock)
            if settings.autoUnlock {
                HStack {
                    SecureField("Device Passcode", text: $passcodeInput)
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 160)
                    Button("Save") {
                        PasscodeManager().save(passcode: passcodeInput)
                        passcodeInput = ""
                        passcodeSaved = true
                    }
                    .disabled(passcodeInput.isEmpty)
                    if passcodeSaved {
                        Button("Clear") {
                            PasscodeManager().delete()
                            passcodeSaved = false
                        }
                    }
                }
                Text(passcodeSaved ? "Passcode saved in Keychain" : "No passcode stored")
                    .font(.caption)
                    .foregroundColor(passcodeSaved ? .green : .secondary)
            }
        }
        .onAppear {
            SpecchioLogger.ui.info("[SettingsConnection] section visible scope=general")
        }
    }

    private var developerWDASection: some View {
        Section("WebDriverAgent") {
            HStack {
                Text("WDA Port:")
                TextField("Port", value: $settings.wdaPort, format: .number)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 80)
            }

            Button("Clear WDA Build Cache") {
                SpecchioLogger.wda.info("[Settings] Clear WDA build cache requested")
                WDABuildCache.invalidate()
            }
            Text("Forces a full rebuild on the next Dev connection.")
                .font(.caption)
                .foregroundColor(.secondary)
        }
    }

    private var shortcutsSection: some View {
        Section("Shortcuts") {
            VStack(alignment: .leading, spacing: 4) {
                shortcutRow("Cmd+Shift+H", "Home Button")
                shortcutRow("Cmd+S", "Save Screenshot")
                shortcutRow("Option+Click", "Two-finger Pinch")
                shortcutRow("Option+Drag", "Pinch/Spread")
                shortcutRow("Shift+Drag", "Two-finger Scroll")
            }
        }
    }

    private var updatesSection: some View {
        Section("Updates") {
            Toggle("Automatically check for updates", isOn: Binding(
                get: { updater.automaticallyChecksForUpdates },
                set: { updater.automaticallyChecksForUpdates = $0 }
            ))
            Button("Check for Updates...") {
                SpecchioLogger.ui.info("[Settings] Check for updates requested")
                updater.checkForUpdates()
            }
        }
    }

    private var licenseSection: some View {
        Section("License") {
            switch licenseManager.status {
            case .free:
                HStack {
                    TextField("License Key", text: $licenseKeyInput)
                        .textFieldStyle(.roundedBorder)
                    Button("Activate") {
                        Task { await licenseManager.activate(key: licenseKeyInput) }
                    }
                    .disabled(licenseKeyInput.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                Button("Buy License") {
                    showPremiumSheet = true
                }
                .font(.caption)

            case .licensed(let expiration):
                HStack {
                    Label("Licensed", systemImage: "checkmark.seal.fill")
                        .foregroundColor(.green)
                    Spacer()
                    if let exp = expiration {
                        Text("Expires \(exp, style: .date)")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
                if let (key, _) = licenseManager.loadFromKeychain() {
                    licenseKeyRow(key)
                }
                Button("Deactivate") {
                    Task { await licenseManager.deactivate() }
                }

            case .validating:
                HStack {
                    ProgressView()
                        .controlSize(.small)
                    Text("Validating license...")
                        .foregroundColor(.secondary)
                }

            case .error(let message):
                HStack {
                    if licenseManager.isPremium {
                        Label("Offline Grace Period", systemImage: "clock.badge.checkmark")
                            .foregroundColor(.orange)
                    } else {
                        Label(message, systemImage: "exclamationmark.triangle")
                            .foregroundColor(.red)
                    }
                }
                if let (key, _) = licenseManager.loadFromKeychain() {
                    licenseKeyRow(key)
                }
                HStack {
                    TextField("License Key", text: $licenseKeyInput)
                        .textFieldStyle(.roundedBorder)
                    Button("Activate") {
                        Task { await licenseManager.activate(key: licenseKeyInput) }
                    }
                    .disabled(licenseKeyInput.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                Button("Deactivate") {
                    Task { await licenseManager.deactivate() }
                }
            }
        }
    }

    private func licenseKeyRow(_ key: String) -> some View {
        let masked = String(key.prefix(4)) + "..." + String(key.suffix(4))
        return HStack {
            Text("Key: \(masked)")
                .font(.caption)
                .foregroundColor(.secondary)
            Button {
                copyLicenseKey(key)
            } label: {
                Image(systemName: "doc.on.doc")
            }
            .buttonStyle(.borderless)
            .controlSize(.small)
            .help("Copy license key")
            Spacer()
        }
    }

    private func copyLicenseKey(_ key: String) {
        SpecchioLogger.ui.info("[Settings] Copy license key requested")
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(key, forType: .string)
    }

    private func sanitizeAirPlayQualityPreference(source: String) {
        let sanitizedValue = AppSettings.EasyAirPlayQuality.sanitized(settings.easyAirPlayQuality)
        guard sanitizedValue != settings.easyAirPlayQuality else { return }
        SpecchioLogger.easyMode.info("[Settings] Easy AirPlay quality sanitized source=\(source, privacy: .public) requested=\(settings.easyAirPlayQuality, privacy: .public) applied=\(sanitizedValue, privacy: .public)")
        settings.easyAirPlayQuality = sanitizedValue
    }

    private var aboutSection: some View {
        Section("About") {
            HStack {
                Spacer()
                VStack(spacing: 4) {
                    Text("Specchio")
                        .font(.headline)
                    Link(
                        "Made with Love by Alexintosh",
                        destination: URL(string: "https://x.com/Alexintosh")!
                    )
                    .font(.caption)
                }
                Spacer()
            }
        }
    }

    private var premiumBadge: some View {
        Button {
            showPremiumSheet = true
        } label: {
            Text("Premium")
                .font(.caption2.weight(.semibold))
                .foregroundColor(.white)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(.blue.gradient, in: Capsule())
        }
        .buttonStyle(.plain)
    }

    private func shortcutRow(_ shortcut: String, _ description: String) -> some View {
        HStack {
            Text(shortcut)
                .font(.system(.body, design: .monospaced))
                .frame(width: 140, alignment: .leading)
            Text(description)
                .foregroundColor(.secondary)
        }
    }
}

private struct SettingsSidebar: View {
    @Binding var selectedPanel: SettingsPanel
    let topInset: CGFloat

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Color.clear
                .frame(height: topInset)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 4) {
                ForEach(SettingsPanel.allCases) { panel in
                    SettingsSidebarRow(
                        panel: panel,
                        isSelected: selectedPanel == panel
                    ) {
                        let previousPanel = selectedPanel
                        selectedPanel = panel
                        SpecchioLogger.ui.info("[SettingsSidebar] selected from=\(previousPanel.logName, privacy: .public) to=\(panel.logName, privacy: .public)")
                    }
                }
            }
            .padding(.horizontal, 12)

            Spacer(minLength: 0)
        }
        .frame(width: SettingsViewMetrics.sidebarNavigationWidth)
        .background(.bar)
        .onAppear {
            SpecchioLogger.ui.info("[SettingsSidebar] appeared layout=fixed items=\(SettingsPanel.allCases.map(\.logName).joined(separator: ","), privacy: .public) selected=\(selectedPanel.logName, privacy: .public) topInset=\(topInset)")
        }
        .onChange(of: topInset) { _, newValue in
            SpecchioLogger.ui.info("[SettingsSidebar] topInset changed value=\(newValue)")
        }
    }
}

private struct SettingsSidebarRow: View {
    let panel: SettingsPanel
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label {
                Text(panel.title)
                    .font(.body.weight(isSelected ? .semibold : .regular))
                    .lineLimit(1)
                    .truncationMode(.tail)
            } icon: {
                Image(systemName: panel.systemImage)
                    .font(.system(size: 15, weight: .medium))
                    .frame(width: 22, alignment: .center)
            }
            .foregroundColor(isSelected ? .white : .primary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .contentShape(Rectangle())
            .background {
                if isSelected {
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(Color.accentColor)
                }
            }
        }
        .buttonStyle(.plain)
        .help(panel.subtitle)
        .accessibilityLabel(panel.title)
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }
}

private struct SettingsDetailHeader: View {
    let panel: SettingsPanel

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            Image(systemName: panel.systemImage)
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: SettingsViewMetrics.headerIconSize, height: SettingsViewMetrics.headerIconSize)
                .background(.blue.gradient, in: RoundedRectangle(
                    cornerRadius: SettingsViewMetrics.headerIconCornerRadius,
                    style: .continuous
                ))
                .shadow(color: .blue.opacity(0.24), radius: 8, x: 0, y: 3)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    Text(panel.title)
                        .font(.largeTitle.weight(.bold))
                        .lineLimit(1)
                        .minimumScaleFactor(0.78)

                    SettingsActiveIndicator(panel: panel)
                }

                Text(panel.subtitle)
                    .font(.title3)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
        .onAppear {
            SpecchioLogger.ui.info("[SettingsDetailHeader] appeared panel=\(panel.logName, privacy: .public)")
        }
    }
}

private struct SettingsActiveIndicator: View {
    let panel: SettingsPanel

    var body: some View {
        Circle()
            .fill(.green)
            .frame(
                width: SettingsViewMetrics.activeIndicatorSize,
                height: SettingsViewMetrics.activeIndicatorSize
            )
            .help("Settings fixed sidebar active")
            .accessibilityLabel("Settings fixed sidebar active for \(panel.title)")
            .onAppear {
                SpecchioLogger.ui.info("[SettingsActiveIndicator] visible panel=\(panel.logName, privacy: .public)")
            }
    }
}

private enum EasyToolbarSettingsBucket: String {
    case visible
    case overflow

    var title: String {
        switch self {
        case .visible: return "Always Visible"
        case .overflow: return "Collapsible Menu"
        }
    }
}

private struct EasyToolbarDropTarget: Equatable {
    let bucket: EasyToolbarSettingsBucket
    let command: EasyToolbarCommand?
}

private struct EasyToolbarOrderSettingsView: View {
    @Binding var legacyStorageValue: String
    @Binding var visibleStorageValue: String
    @Binding var overflowStorageValue: String
    @State private var targetedDrop: EasyToolbarDropTarget?

    private var layout: EasyToolbarCommandLayout {
        EasyToolbarCommandLayout.fromStorage(
            visibleStorageValue: visibleStorageValue,
            overflowStorageValue: overflowStorageValue,
            legacyOrderStorageValue: legacyStorageValue,
            hasStoredVisibleOrder: UserDefaults.standard.object(forKey: AppSettings.Keys.easyToolbarVisibleCommandOrder) != nil,
            hasStoredOverflowOrder: UserDefaults.standard.object(forKey: AppSettings.Keys.easyToolbarOverflowCommandOrder) != nil
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: EasyToolbarOrderChipMetrics.bucketSpacing) {
            bucketRow(.visible, commands: layout.visibleCommands)
            bucketRow(.overflow, commands: layout.overflowCommands)
        }
        .padding(.vertical, EasyToolbarOrderChipMetrics.groupVerticalPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .onAppear {
            SpecchioLogger.easyMode.info("[EasyToolbarSettings] appeared layout=two-buckets visible=\(visibleStorageValue, privacy: .public) overflow=\(overflowStorageValue, privacy: .public) legacy=\(legacyStorageValue, privacy: .public) maxVisible=\(EasyToolbarCommandLayout.maximumVisibleCommandCount)")
            normalizeStorageIfNeeded(reason: "appear")
        }
    }

    private func bucketRow(_ bucket: EasyToolbarSettingsBucket, commands: [EasyToolbarCommand]) -> some View {
        let rowTarget = EasyToolbarDropTarget(bucket: bucket, command: nil)

        return VStack(alignment: .leading, spacing: EasyToolbarOrderChipMetrics.rowLabelSpacing) {
            HStack(spacing: 6) {
                Text(bucket.title)
                    .font(.caption.weight(.semibold))
                if bucket == .visible {
                    Text("\(commands.count)/\(EasyToolbarCommandLayout.maximumVisibleCommandCount)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                } else {
                    Text("\(commands.count)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: EasyToolbarOrderChipMetrics.gridSpacing) {
                    ForEach(commands) { command in
                        let chipTarget = EasyToolbarDropTarget(bucket: bucket, command: command)
                        EasyToolbarOrderChip(
                            command: command,
                            isTargeted: targetedDrop == chipTarget
                        )
                        .draggable(command.rawValue) {
                            EasyToolbarOrderChip(command: command, isTargeted: false)
                        }
                        .dropDestination(for: String.self) { items, _ in
                            guard let sourceRawValue = items.first else {
                                SpecchioLogger.easyMode.info("[EasyToolbarSettings] drop ignored reason=no-items bucket=\(bucket.rawValue, privacy: .public) destination=\(command.rawValue, privacy: .public)")
                                return false
                            }
                            return moveCommand(
                                sourceRawValue: sourceRawValue,
                                to: bucket,
                                before: command
                            )
                        } isTargeted: { isTargeted in
                            updateTargetedDrop(isTargeted, target: chipTarget)
                        }
                    }
                }
                .padding(EasyToolbarOrderChipMetrics.rowInnerPadding)
                .frame(minHeight: EasyToolbarOrderChipMetrics.rowMinimumHeight, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(targetedDrop == rowTarget ? Color.accentColor.opacity(0.12) : Color(nsColor: .controlBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: EasyToolbarOrderChipMetrics.cornerRadius, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: EasyToolbarOrderChipMetrics.cornerRadius, style: .continuous)
                    .stroke(targetedDrop == rowTarget ? Color.accentColor : Color.secondary.opacity(0.18), lineWidth: 1)
            }
            .dropDestination(for: String.self) { items, _ in
                guard let sourceRawValue = items.first else {
                    SpecchioLogger.easyMode.info("[EasyToolbarSettings] row-drop ignored reason=no-items bucket=\(bucket.rawValue, privacy: .public)")
                    return false
                }
                return moveCommand(sourceRawValue: sourceRawValue, to: bucket, before: nil)
            } isTargeted: { isTargeted in
                updateTargetedDrop(isTargeted, target: rowTarget)
            }
        }
    }

    private func updateTargetedDrop(_ isTargeted: Bool, target: EasyToolbarDropTarget) {
        if isTargeted {
            targetedDrop = target
        } else if targetedDrop == target {
            targetedDrop = nil
        }
    }

    private func moveCommand(
        sourceRawValue: String,
        to targetBucket: EasyToolbarSettingsBucket,
        before destination: EasyToolbarCommand?
    ) -> Bool {
        guard let source = EasyToolbarCommand(rawValue: sourceRawValue) else {
            SpecchioLogger.easyMode.info("[EasyToolbarSettings] drop ignored reason=unknown-source source=\(sourceRawValue, privacy: .public) targetBucket=\(targetBucket.rawValue, privacy: .public) destination=\(destination?.rawValue ?? "<end>", privacy: .public)")
            return false
        }

        guard destination != source else {
            SpecchioLogger.easyMode.info("[EasyToolbarSettings] drop ignored reason=same-command source=\(source.rawValue, privacy: .public) targetBucket=\(targetBucket.rawValue, privacy: .public)")
            return true
        }

        let currentLayout = layout
        let sourceBucket = currentLayout.visibleCommands.contains(source) ? EasyToolbarSettingsBucket.visible :
            (currentLayout.overflowCommands.contains(source) ? EasyToolbarSettingsBucket.overflow : nil)
        guard let sourceBucket else {
            SpecchioLogger.easyMode.info("[EasyToolbarSettings] drop ignored reason=missing-source source=\(source.rawValue, privacy: .public) targetBucket=\(targetBucket.rawValue, privacy: .public) visible=\(currentLayout.visibleStorageValue, privacy: .public) overflow=\(currentLayout.overflowStorageValue, privacy: .public)")
            return false
        }

        var visibleCommands = currentLayout.visibleCommands.filter { $0 != source }
        var overflowCommands = currentLayout.overflowCommands.filter { $0 != source }

        if targetBucket == .visible,
           sourceBucket != .visible,
           visibleCommands.count >= EasyToolbarCommandLayout.maximumVisibleCommandCount {
            SpecchioLogger.easyMode.info("[EasyToolbarSettings] drop rejected reason=visible-row-full source=\(source.rawValue, privacy: .public) maxVisible=\(EasyToolbarCommandLayout.maximumVisibleCommandCount) visible=\(currentLayout.visibleStorageValue, privacy: .public) overflow=\(currentLayout.overflowStorageValue, privacy: .public)")
            return false
        }

        switch targetBucket {
        case .visible:
            guard insert(source, before: destination, into: &visibleCommands, bucket: targetBucket) else {
                return false
            }
        case .overflow:
            guard insert(source, before: destination, into: &overflowCommands, bucket: targetBucket) else {
                return false
            }
        }

        let nextLayout = EasyToolbarCommandLayout(
            visibleCommands: visibleCommands,
            overflowCommands: overflowCommands,
            fallbackOrder: currentLayout.allCommands
        )
        guard nextLayout != currentLayout else {
            SpecchioLogger.easyMode.info("[EasyToolbarSettings] drop ignored reason=unchanged source=\(source.rawValue, privacy: .public) sourceBucket=\(sourceBucket.rawValue, privacy: .public) targetBucket=\(targetBucket.rawValue, privacy: .public) destination=\(destination?.rawValue ?? "<end>", privacy: .public)")
            return true
        }

        commit(
            nextLayout,
            reason: destination == nil ? "drop-row-end" : "drop-before",
            source: source,
            sourceBucket: sourceBucket,
            targetBucket: targetBucket,
            destination: destination
        )
        return true
    }

    private func insert(
        _ source: EasyToolbarCommand,
        before destination: EasyToolbarCommand?,
        into commands: inout [EasyToolbarCommand],
        bucket: EasyToolbarSettingsBucket
    ) -> Bool {
        guard let destination else {
            commands.append(source)
            return true
        }

        guard let destinationIndex = commands.firstIndex(of: destination) else {
            SpecchioLogger.easyMode.info("[EasyToolbarSettings] drop ignored reason=missing-destination source=\(source.rawValue, privacy: .public) targetBucket=\(bucket.rawValue, privacy: .public) destination=\(destination.rawValue, privacy: .public)")
            return false
        }

        commands.insert(source, at: destinationIndex)
        return true
    }

    private func normalizeStorageIfNeeded(reason: String) {
        let hasStoredVisibleOrder = UserDefaults.standard.object(forKey: AppSettings.Keys.easyToolbarVisibleCommandOrder) != nil
        let hasStoredOverflowOrder = UserDefaults.standard.object(forKey: AppSettings.Keys.easyToolbarOverflowCommandOrder) != nil
        let normalizedLayout = layout
        let needsVisibleWrite = !hasStoredVisibleOrder || visibleStorageValue != normalizedLayout.visibleStorageValue
        let needsOverflowWrite = !hasStoredOverflowOrder || overflowStorageValue != normalizedLayout.overflowStorageValue
        let needsLegacyWrite = legacyStorageValue != normalizedLayout.legacyStorageValue

        guard needsVisibleWrite || needsOverflowWrite || needsLegacyWrite else {
            SpecchioLogger.easyMode.debug("[EasyToolbarSettings] normalized unchanged reason=\(reason, privacy: .public) visible=\(normalizedLayout.visibleStorageValue, privacy: .public) overflow=\(normalizedLayout.overflowStorageValue, privacy: .public)")
            return
        }

        SpecchioLogger.easyMode.info("[EasyToolbarSettings] normalizing reason=\(reason, privacy: .public) hadVisibleKey=\(hasStoredVisibleOrder) hadOverflowKey=\(hasStoredOverflowOrder) fromVisible=\(visibleStorageValue, privacy: .public) fromOverflow=\(overflowStorageValue, privacy: .public) fromLegacy=\(legacyStorageValue, privacy: .public) toVisible=\(normalizedLayout.visibleStorageValue, privacy: .public) toOverflow=\(normalizedLayout.overflowStorageValue, privacy: .public) maxVisible=\(EasyToolbarCommandLayout.maximumVisibleCommandCount)")
        if needsVisibleWrite {
            visibleStorageValue = normalizedLayout.visibleStorageValue
        }
        if needsOverflowWrite {
            overflowStorageValue = normalizedLayout.overflowStorageValue
        }
        if needsLegacyWrite {
            legacyStorageValue = normalizedLayout.legacyStorageValue
        }
    }

    private func commit(
        _ nextLayout: EasyToolbarCommandLayout,
        reason: String,
        source: EasyToolbarCommand,
        sourceBucket: EasyToolbarSettingsBucket,
        targetBucket: EasyToolbarSettingsBucket,
        destination: EasyToolbarCommand?
    ) {
        SpecchioLogger.easyMode.info("[EasyToolbarSettings] reordered reason=\(reason, privacy: .public) source=\(source.rawValue, privacy: .public) sourceBucket=\(sourceBucket.rawValue, privacy: .public) targetBucket=\(targetBucket.rawValue, privacy: .public) destination=\(destination?.rawValue ?? "<end>", privacy: .public) visible=\(nextLayout.visibleStorageValue, privacy: .public) overflow=\(nextLayout.overflowStorageValue, privacy: .public) maxVisible=\(EasyToolbarCommandLayout.maximumVisibleCommandCount)")
        visibleStorageValue = nextLayout.visibleStorageValue
        overflowStorageValue = nextLayout.overflowStorageValue
        legacyStorageValue = nextLayout.legacyStorageValue
    }
}

private enum EasyToolbarOrderChipMetrics {
    static let gridSpacing: CGFloat = 8
    static let bucketSpacing: CGFloat = 10
    static let rowLabelSpacing: CGFloat = 5
    static let groupVerticalPadding: CGFloat = 4
    static let rowInnerPadding: CGFloat = 4
    static let titleWidth: CGFloat = 72
    static let horizontalPadding: CGFloat = 6
    static let verticalPadding: CGFloat = 7
    static let iconWidth: CGFloat = 28
    static let iconHeight: CGFloat = 24
    static let iconTextSpacing: CGFloat = 5
    static let captionTextHeight: CGFloat = 14
    static let cornerRadius: CGFloat = 8

    static var minimumGridWidth: CGFloat {
        titleWidth + (horizontalPadding * 2)
    }

    static var chipHeight: CGFloat {
        iconHeight + iconTextSpacing + captionTextHeight + (verticalPadding * 2)
    }

    static var rowMinimumHeight: CGFloat {
        chipHeight + (rowInnerPadding * 2)
    }
}

private struct EasyToolbarOrderChip: View {
    let command: EasyToolbarCommand
    let isTargeted: Bool

    var body: some View {
        VStack(spacing: EasyToolbarOrderChipMetrics.iconTextSpacing) {
            Image(systemName: command.systemImage)
                .font(.system(size: 17, weight: .medium))
                .frame(width: EasyToolbarOrderChipMetrics.iconWidth, height: EasyToolbarOrderChipMetrics.iconHeight)
            Text(command.title)
                .font(.caption2)
                .lineLimit(1)
                .frame(width: EasyToolbarOrderChipMetrics.titleWidth)
        }
        .padding(.horizontal, EasyToolbarOrderChipMetrics.horizontalPadding)
        .padding(.vertical, EasyToolbarOrderChipMetrics.verticalPadding)
        .background(isTargeted ? Color.accentColor.opacity(0.16) : Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: EasyToolbarOrderChipMetrics.cornerRadius, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: EasyToolbarOrderChipMetrics.cornerRadius, style: .continuous)
                .stroke(isTargeted ? Color.accentColor : Color.secondary.opacity(0.18), lineWidth: 1)
        }
        .help(command.title)
    }
}

/// Invisible helper that observes the Settings window chrome without changing
/// the user's chosen size.
private struct SettingsWindowConfigurator: NSViewRepresentable {
    @Binding var chromeTopInset: CGFloat

    final class ConfiguratorView: NSView {
        private var didConfigure = false
        private var lastReportedTopInset: CGFloat?
        var onChromeTopInsetChange: ((CGFloat, String) -> Void)?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            configureWindow(reason: "viewDidMoveToWindow")
        }

        override func layout() {
            super.layout()
            configureWindow(reason: "layout")
        }

        func configureWindow(reason: String) {
            guard let window else {
                SpecchioLogger.ui.info("[SettingsWindowConfigurator] skipped reason=\(reason, privacy: .public) branch=no-window")
                return
            }

            window.titleVisibility = .hidden
            if !didConfigure {
                window.styleMask.insert(.resizable)
                didConfigure = true
                SpecchioLogger.ui.info("[SettingsWindowConfigurator] chrome ensured reason=\(reason, privacy: .public) resizable=\(window.styleMask.contains(.resizable)) titleVisibility=\(String(describing: window.titleVisibility), privacy: .public)")
            }

            let contentRect = window.contentRect(forFrameRect: window.frame)
            let layoutTopInset = max(0, contentRect.height - window.contentLayoutRect.height)
            let buttonTopInset = standardWindowButtonTopInset(in: window, reason: reason)
            let chromeTopInset = max(layoutTopInset, buttonTopInset)
            let shouldReport = lastReportedTopInset.map { abs($0 - chromeTopInset) > 0.5 } ?? true
            guard shouldReport else {
                SpecchioLogger.ui.debug("[SettingsWindowConfigurator] inset unchanged reason=\(reason, privacy: .public) chromeTopInset=\(chromeTopInset)")
                return
            }
            lastReportedTopInset = chromeTopInset
            onChromeTopInsetChange?(chromeTopInset, reason)
            SpecchioLogger.ui.info("[SettingsWindowConfigurator] inset reported reason=\(reason, privacy: .public) frameWidth=\(window.frame.width) frameHeight=\(window.frame.height) contentWidth=\(contentRect.width) contentHeight=\(contentRect.height) contentLayoutHeight=\(window.contentLayoutRect.height) layoutTopInset=\(layoutTopInset) buttonTopInset=\(buttonTopInset) chromeTopInset=\(chromeTopInset)")
        }

        private func standardWindowButtonTopInset(in window: NSWindow, reason: String) -> CGFloat {
            guard let frameView = window.contentView?.superview else {
                SpecchioLogger.ui.info("[SettingsWindowConfigurator] button inset skipped reason=\(reason, privacy: .public) branch=no-frame-view")
                return 0
            }

            let buttons = [
                window.standardWindowButton(.closeButton),
                window.standardWindowButton(.miniaturizeButton),
                window.standardWindowButton(.zoomButton)
            ].compactMap { $0 }

            guard !buttons.isEmpty else {
                SpecchioLogger.ui.info("[SettingsWindowConfigurator] button inset skipped reason=\(reason, privacy: .public) branch=no-standard-buttons")
                return 0
            }

            let framesInContent = buttons.compactMap { button -> CGRect? in
                guard let buttonSuperview = button.superview else {
                    SpecchioLogger.ui.info("[SettingsWindowConfigurator] button frame skipped reason=\(reason, privacy: .public) branch=no-button-superview")
                    return nil
                }
                return buttonSuperview.convert(button.frame, to: frameView)
            }

            guard let lowestButtonMinY = framesInContent.map(\.minY).min(),
                  let tallestButtonHeight = framesInContent.map(\.height).max() else {
                SpecchioLogger.ui.info("[SettingsWindowConfigurator] button inset skipped reason=\(reason, privacy: .public) branch=no-converted-frames")
                return 0
            }

            let topInset = max(0, frameView.bounds.maxY - lowestButtonMinY + tallestButtonHeight)
            SpecchioLogger.ui.debug("[SettingsWindowConfigurator] button inset measured reason=\(reason, privacy: .public) frameViewHeight=\(frameView.bounds.height) lowestButtonMinY=\(lowestButtonMinY) tallestButtonHeight=\(tallestButtonHeight) topInset=\(topInset)")
            return topInset
        }
    }

    func makeNSView(context: Context) -> ConfiguratorView {
        let view = ConfiguratorView()
        view.onChromeTopInsetChange = { inset, reason in
            chromeTopInset = inset
            SpecchioLogger.ui.info("[SettingsWindowConfigurator] SwiftUI inset applied reason=\(reason, privacy: .public) chromeTopInset=\(inset)")
        }
        return view
    }

    func updateNSView(_ nsView: ConfiguratorView, context: Context) {
        nsView.onChromeTopInsetChange = { inset, reason in
            chromeTopInset = inset
            SpecchioLogger.ui.info("[SettingsWindowConfigurator] SwiftUI inset applied reason=\(reason, privacy: .public) chromeTopInset=\(inset)")
        }
        nsView.configureWindow(reason: "updateNSView")
    }
}
