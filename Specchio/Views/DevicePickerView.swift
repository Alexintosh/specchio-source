import SwiftUI

struct DevicePickerView: View {
    @ObservedObject var deviceManager: DeviceManager
    @ObservedObject var licenseManager: LicenseManager
    let onConnect: (ConnectionState) -> Void

    @State private var manualHost = ""
    @State private var manualPort = "8100"
    @State private var isScanning = false
    @State private var isAutoLaunching = false
    @State private var scanCompleted = false
    @State private var mouseLocation: CGPoint = .zero
    @State private var viewSize: CGSize = .zero
    @State private var showPremiumSheet = false
    @AppStorage("onboardingStep") private var onboardingStep: Int = 0

    /// Deduplicated WiFi devices — Bonjour and subnet scan can find the same WDA under different addresses.
    private var uniqueWiFiDevices: [WiFiDeviceDiscovery.WiFiDevice] {
        var seenNames = Set<String>()
        return deviceManager.availableWiFiDevices.filter { device in
            let key = device.name ?? device.host
            return seenNames.insert(key).inserted
        }
    }

    var body: some View {
        VStack(spacing: 24) {
            SpecchioMirrorLogo(mouseLocation: mouseLocation, parentSize: viewSize)

            Text("Specchio")
                .font(.largeTitle.weight(.bold))
            Text("Connect your iPhone")
                .font(.title3)
                .foregroundColor(.secondary)

            // Primary: Connect iPhone (auto-detects USB or WiFi)
            ConnectionSection(
                icon: "iphone",
                title: onboardingStep == 0 ? "Setup" : (licenseManager.isPremium ? "Connect USB/WiFi" : "Connect USB-Only")
            ) {
                if onboardingStep == 0 {
                    OnboardingWelcomeView {
                        SpecchioLogger.easyMode.info("[DevicePickerView] onboarding welcome completed; Xcode/WDA prerequisite checks remain manual-only")
                        onboardingStep = 1
                    }
                } else if isAutoLaunching {
                    AutoLaunchProgressView(autoLauncher: deviceManager.autoLauncher) {
                        deviceManager.autoLauncher.stopAll()
                        isAutoLaunching = false
                    }
                } else if case .failed(let message) = deviceManager.autoLauncher.phase {
                    VStack(spacing: 8) {
                        Text(message)
                            .font(.caption)
                            .foregroundColor(.red)
                            .multilineTextAlignment(.center)
                        HStack(spacing: 8) {
                            if let fixAction = errorFixAction(message) {
                                Button {
                                    fixAction.action()
                                } label: {
                                    Text(fixAction.label)
                                        .frame(maxWidth: .infinity)
                                }
                                .buttonStyle(.bordered)
                                .controlSize(.large)
                            }
                            Button {
                                SpecchioLogger.easyMode.info("[DevicePickerView] retry selected; starting explicit legacy WDA connection after previous failure")
                                isAutoLaunching = true
                                deviceManager.autoLauncher.phase = .idle
                                onConnect(.usb(host: "localhost", port: 8100))
                            } label: {
                                Text("Retry")
                                    .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.large)
                        }
                    }
                } else {
                    SpecchioPrimaryButton(
                        title: "Connect iPhone",
                        usesPremiumGradient: licenseManager.isPremium
                    ) {
                        SpecchioLogger.easyMode.info("[DevicePickerView] connect selected; starting explicit legacy WDA connection")
                        isAutoLaunching = true
                        onConnect(.usb(host: "localhost", port: 8100))
                    }
                }
            }

            // WiFi shortcuts: premium only
            if licenseManager.isPremium {
                if !uniqueWiFiDevices.isEmpty {
                    ConnectionSection(
                        icon: "wifi",
                        title: "WiFi"
                    ) {
                        ForEach(uniqueWiFiDevices) { device in
                            Button {
                                onConnect(.wifi(host: device.host, port: device.port))
                            } label: {
                                Text("WiFi Ready")
                                    .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.large)
                        }
                    }
                }

                // Advanced: manual IP entry
                DisclosureGroup("Advanced") {
                    HStack(spacing: 8) {
                        TextField("IP Address", text: $manualHost)
                            .textFieldStyle(.roundedBorder)
                        Button("Connect") {
                            onConnect(.wifi(host: manualHost, port: 8100))
                        }
                        .disabled(manualHost.isEmpty)
                    }
                }
                .font(.caption)
                .foregroundColor(.secondary)
                .padding(.horizontal, 4)
            } else {
                // Free tier: show premium upsell
                Button {
                    showPremiumSheet = true
                } label: {
                    ConnectionSection(
                        icon: "wifi",
                        title: "WiFi"
                    ) {
                        HStack {
                            Text("WiFi, MJPEG & H.264 streaming")
                                .font(.caption)
                                .foregroundColor(.secondary)
                            Spacer()
                            Text("Premium")
                                .font(.caption.weight(.semibold))
                                .foregroundColor(.accentColor)
                        }
                    }
                }
                .buttonStyle(.plain)
                .opacity(0.6)
            }

        }
        .padding(.horizontal, 24)
        .padding(.vertical, 32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .sheet(isPresented: $showPremiumSheet) {
            PremiumUpsellView()
        }
        .background(GeometryReader { geo in
            Color.clear.onChange(of: geo.size) { _, newSize in viewSize = newSize }
                .onAppear { viewSize = geo.size }
        })
        .onContinuousHover { phase in
            switch phase {
            case .active(let location):
                mouseLocation = location
            case .ended:
                mouseLocation = .zero
            }
        }
        .onAppear {
            SpecchioLogger.easyMode.info("[DevicePickerView] appeared onboardingStep=\(onboardingStep) premium=\(licenseManager.isPremium) automaticXcodeChecks=false branch=manual-only")
            Task { await deviceManager.scanForDevices() }
        }
        .onChange(of: onboardingStep) { _, newStep in
            if newStep == 1 {
                SpecchioLogger.easyMode.info("[DevicePickerView] onboarding advanced to setup-ready; skipped automatic Xcode/WDA prerequisite checks branch=manual-only")
            }
        }
        .onChange(of: deviceManager.autoLauncher.phase) { _, newPhase in
            // Only dismiss progress on failure — the handleConnect flow handles
            // the full lifecycle (auto-launch → connect → transition to MirrorView).
            if case .failed = newPhase {
                isAutoLaunching = false
            }
            // Mark onboarding complete on first successful connection
            if case .ready = newPhase, onboardingStep < 2 {
                onboardingStep = 2
            }
        }
    }

    // MARK: - Error Fix Actions

    private struct ErrorFix {
        let label: String
        let action: () -> Void
    }

    private func errorFixAction(_ message: String) -> ErrorFix? {
        if message.contains("No Apple ID account") || message.contains("No provisioning profile") || message.contains("No signing certificate") {
            return ErrorFix(label: "Open Xcode Settings") {
                if let url = URL(string: "xcode://preferences/accounts") {
                    NSWorkspace.shared.open(url)
                }
            }
        }
        if message.contains("keychain is locked") || message.contains("Keychain unlock") {
            return ErrorFix(label: "Open Keychain Access") {
                NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Utilities/Keychain Access.app"))
            }
        }
        if message.contains("iOS platform not installed") {
            return ErrorFix(label: "Open Xcode Settings") {
                if let url = URL(string: "xcode://preferences") {
                    NSWorkspace.shared.open(url)
                }
            }
        }
        return nil
    }
}

// MARK: - Auto-Launch Progress View

private struct AutoLaunchProgressView: View {
    @ObservedObject var autoLauncher: AutoLaunchManager
    let onCancel: () -> Void

    @State private var startTime = Date()
    @State private var elapsedSeconds: Int = 0

    private static let steps = [
        "Detect iPhone",
        "Start USB connection",
        "Build WebDriverAgent",
        "Install on iPhone",
        "Connect",
    ]

    private var currentStepIndex: Int {
        switch autoLauncher.phase {
        case .idle, .detectingDevice: return 0
        case .startingTunnel: return 1
        case .buildingWDA: return 2
        case .launchingWDA: return 3
        case .waitingForWDA: return 4
        case .ready, .externallyManaged: return 5
        case .failed: return -1
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Step list
            ForEach(Array(Self.steps.enumerated()), id: \.offset) { index, label in
                HStack(spacing: 8) {
                    Group {
                        if index < currentStepIndex {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundColor(.green)
                        } else if index == currentStepIndex {
                            ProgressView()
                                .controlSize(.small)
                        } else {
                            Image(systemName: "circle")
                                .foregroundColor(.secondary.opacity(0.3))
                        }
                    }
                    .frame(width: 16, height: 16)

                    Text(label)
                        .foregroundColor(index <= currentStepIndex ? .primary : .secondary)
                        .font(.callout)
                }
            }

            // Connection hint (e.g. phone locked)
            if let hint = autoLauncher.connectionHint, !autoLauncher.awaitingTrust {
                Text(hint)
                    .font(.caption)
                    .foregroundColor(.orange)
                    .padding(.leading, 24)
                    .transition(.opacity)
            }

            // Build activity detail during the build step
            if currentStepIndex == 2 {
                VStack(alignment: .leading, spacing: 3) {
                    if autoLauncher.wdaLauncher.isFirstBuild {
                        Text("First-time build — subsequent launches will be faster")
                            .font(.caption)
                            .foregroundColor(.orange)
                    }
                    if !autoLauncher.buildActivity.isEmpty {
                        Text(autoLauncher.buildActivity)
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    Text(formattedElapsed)
                        .font(.caption2)
                        .foregroundColor(.secondary.opacity(0.7))
                        .monospacedDigit()
                }
                .padding(.leading, 24)
                .transition(.opacity)
            }

            // Trust guidance card — shown after first build when WDA doesn't respond
            if autoLauncher.awaitingTrust {
                trustGuidanceCard
            }

            // Elapsed time during non-build steps
            if currentStepIndex != 2, currentStepIndex >= 1, currentStepIndex < 5 {
                Text(formattedElapsed)
                    .font(.caption2)
                    .foregroundColor(.secondary.opacity(0.7))
                    .monospacedDigit()
                    .padding(.leading, 24)
            }

            // Connecting phase — all auto-launch steps done, establishing WDA session
            if currentStepIndex >= 5 {
                HStack(spacing: 8) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundColor(.green)
                        .frame(width: 16, height: 16)
                    Text("Connected!")
                        .font(.callout)
                        .foregroundColor(.green)
                }
            }

            // Cancel
            HStack {
                Spacer()
                Button("Cancel", action: onCancel)
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                Spacer()
            }
            .padding(.top, 4)
        }
        .animation(.easeInOut(duration: 0.3), value: currentStepIndex)
        .animation(.easeInOut(duration: 0.3), value: autoLauncher.awaitingTrust)
        .onReceive(Timer.publish(every: 1, on: .main, in: .common).autoconnect()) { _ in
            elapsedSeconds = Int(Date().timeIntervalSince(startTime))
        }
    }

    private var trustGuidanceCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Trust required on your iPhone:")
                .font(.callout.weight(.semibold))

            VStack(alignment: .leading, spacing: 6) {
                trustStep(number: 1, text: "Find the WebDriverAgent icon on your home screen and tap it")
                trustStep(number: 2, text: "If you see \"Untrusted Developer\", go to Settings > General > VPN & Device Management")
                trustStep(number: 3, text: "Tap your developer profile, then tap Trust")
            }

            Button {
                Task {
                    await autoLauncher.retryPoll()
                }
            } label: {
                Text("Check Again")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.regular)
        }
        .padding(12)
        .background(Color.accentColor.opacity(0.08))
        .cornerRadius(10)
        .padding(.leading, 24)
        .transition(.opacity.combined(with: .move(edge: .top)))
    }

    private func trustStep(number: Int, text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text("\(number).")
                .font(.caption.weight(.bold))
                .foregroundColor(.accentColor)
                .frame(width: 16, alignment: .leading)
            Text(text)
                .font(.caption)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var formattedElapsed: String {
        let minutes = elapsedSeconds / 60
        let seconds = elapsedSeconds % 60
        if minutes > 0 {
            return String(format: "%d:%02d elapsed", minutes, seconds)
        }
        return "\(seconds)s elapsed"
    }
}

// MARK: - Connection Section

private struct ConnectionSection<Content: View>: View {
    let icon: String
    let title: String
    @ViewBuilder let content: Content

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: icon)
                .font(.system(size: 32))
                .foregroundColor(.secondary)
                .frame(width: 40, alignment: .center)

            VStack(alignment: .leading, spacing: 10) {
                Text(title)
                    .font(.headline)

                content
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(14)
        .background(.quaternary.opacity(0.3))
        .cornerRadius(12)
    }
}
