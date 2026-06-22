import SwiftUI
import os.log

private let log = SpecchioLogger.autoLaunch

struct MainWindow: View {
    @Environment(\.spuUpdater) private var spuUpdater
    @ObservedObject var appState: AppState
    @StateObject private var deviceManager = DeviceManager()
    @StateObject private var iosScreenCaptureMonitor = IOSScreenCaptureDeviceMonitor()
    @StateObject private var iosScreenCapture = IOSScreenCaptureManager()
    @StateObject private var updateChecker = ForceUpdateChecker()
    @ObservedObject private var licenseManager = LicenseManager.shared
    @State private var connectionMonitor: ConnectionMonitor?
    @AppStorage("mjpegQuality") private var mjpegQuality: Int = 50
    @AppStorage("mjpegScalingFactor") private var mjpegScalingFactor: Int = 100
    @AppStorage(AppSettings.Keys.easyUSBTargetFPS) private var easyUSBTargetFPS = AppSettings.Defaults.easyUSBTargetFPS

    var body: some View {
        Group {
            if appState.connectionState.isConnected {
                MirrorView(appState: appState, deviceManager: deviceManager)
            } else {
                DevicePickerView(
                    deviceManager: deviceManager,
                    licenseManager: appState.licenseManager,
                    onConnect: handleConnect
                )
                .background(.ultraThinMaterial)
            }
        }
        .toolbar {
            ToolbarView(
                appState: appState,
                deviceManager: deviceManager
            )
        }
        .overlay(alignment: .top) {
            if let banner = appState.reconnectBanner {
                ReconnectBannerView(
                    message: banner,
                    isReconnecting: appState.isReconnecting
                )
            }
        }
        .overlay {
            if updateChecker.updateRequired, let updater = spuUpdater {
                ForceUpdateView(message: updateChecker.message, updater: updater)
            }
        }
        .overlay(alignment: .topTrailing) {
            DevEasySizeIndicator()
                .padding(8)
        }
        .background(GeometryReader { geo in
            Color.clear
                .onAppear {
                    SpecchioLogger.easyMode.info("[MainWindow] appeared devEasySizePolicy width=\(geo.size.width) height=\(geo.size.height) phoneWidth=\(SpecchioPhoneWindowMetrics.defaultPhoneScreenSize.width) phoneHeight=\(SpecchioPhoneWindowMetrics.defaultPhoneScreenSize.height) reservedHeight=\(EasyControlBarMetrics.windowReservedHeight)")
                }
                .onChange(of: geo.size) { _, newSize in
                    SpecchioLogger.easyMode.info("[MainWindow] geometry changed devEasySizePolicy width=\(newSize.width) height=\(newSize.height) phoneWidth=\(SpecchioPhoneWindowMetrics.defaultPhoneScreenSize.width) phoneHeight=\(SpecchioPhoneWindowMetrics.defaultPhoneScreenSize.height) reservedHeight=\(EasyControlBarMetrics.windowReservedHeight)")
                }
        })
        .ignoresSafeArea()
        .onAppear {
            connectionMonitor = ConnectionMonitor(
                appState: appState,
                deviceManager: deviceManager
            )
            appState.iosScreenCaptureStream = iosScreenCapture
            connectionMonitor?.watchIOSScreenCapture(iosScreenCapture) { reason in
                Task { @MainActor in
                    handleNativeCaptureFailureForDev(reason: reason)
                }
            }
            Task { await updateChecker.check() }
            Task { await appState.licenseManager.validate() }
            // Sync license state to AutoLaunchManager
            deviceManager.autoLauncher.isPremium = appState.licenseManager.isPremium
            applyNativeUSBPolicyForDev(source: "MainWindow appeared")
        }
        .onDisappear {
            iosScreenCapture.onStreamFailed = nil
            if appState.iosScreenCaptureStream === iosScreenCapture {
                appState.iosScreenCaptureStream = nil
            }
            if appState.activeVideoSource == .iosScreenCaptureUSB {
                appState.activeVideoSource = .none
            }
            iosScreenCapture.stopCapture(reason: "MainWindow disappeared", clearFrame: true)
        }
        .onChange(of: iosScreenCapture.streamHealth) { oldValue, newValue in
            handleNativeCaptureHealthChangedForDev(from: oldValue, to: newValue)
        }
        .onChange(of: mjpegQuality) { _, newValue in
            applyMJPEGSettings(quality: newValue, scalingFactor: mjpegScalingFactor)
        }
        .onChange(of: mjpegScalingFactor) { _, newValue in
            applyMJPEGSettings(quality: mjpegQuality, scalingFactor: newValue)
        }
        .onChange(of: easyUSBTargetFPS) { _, newValue in
            let sanitizedValue = AppSettings.sanitizedEasyUSBTargetFPS(newValue)
            if sanitizedValue != newValue {
                log.info("[MainWindow] USB target FPS sanitized requested=\(newValue) applied=\(sanitizedValue)")
                easyUSBTargetFPS = sanitizedValue
                return
            }
            applyNativeUSBPolicyForDev(source: "USB target FPS setting changed")
        }
        .onChange(of: licenseManager.isPremium) { _, isPremium in
            log.info("[MainWindow] license premium changed premium=\(isPremium)")
            deviceManager.autoLauncher.isPremium = isPremium
        }
    }

    private func applyMJPEGSettings(quality: Int, scalingFactor: Int) {
        guard let client = appState.wdaClient else { return }
        let isUSB = { if case .usb = appState.connectionState { return true }; return false }()
        Task {
            try? await client.configureMJPEG(
                framerate: isUSB ? 60 : 30,
                quality: quality,
                scalingFactor: scalingFactor
            )
            log.info("MJPEG settings applied: quality=\(quality) scale=\(scalingFactor)")
        }
    }

    private func handleConnect(_ connection: ConnectionState) {
        log.info("handleConnect called with: \(String(describing: connection))")
        Task {
            do {
                let client: WDAClient
                let actualConnection: ConnectionState

                let premium = appState.licenseManager.isPremium
                deviceManager.autoLauncher.isPremium = premium

                switch connection {
                case .usb:
                    if premium {
                        // Unified auto-launch: detects USB or WiFi automatically
                        log.info("handleConnect: premium — unified path (USB+WiFi)")
                        client = try await deviceManager.connectAutoLaunch()
                        if let detected = deviceManager.autoLauncher.detectedConnection {
                            switch detected {
                            case .usb:
                                actualConnection = .usb(host: "localhost", port: 8100)
                            case .wifi(let host):
                                actualConnection = .wifi(host: host, port: 8100)
                            }
                        } else {
                            actualConnection = connection
                        }
                    } else {
                        // Free tier: USB only
                        log.info("handleConnect: free tier — USB only")
                        client = try await deviceManager.connectUSBAutoLaunch()
                        actualConnection = .usb(host: "localhost", port: 8100)
                    }
                case .wifi(let host, let port):
                    guard premium else {
                        log.warning("handleConnect: WiFi blocked — free tier")
                        appState.errorMessage = "WiFi connection requires a premium license"
                        return
                    }
                    // Direct connect to discovered/manual device
                    client = try await deviceManager.connectWiFi(host: host, port: port)
                    actualConnection = connection
                default:
                    return
                }

                appState.wdaClient = client
                appState.connectionState = actualConnection

                // Save phone WiFi IP for failover if USB disconnects
                if let status = try? await client.status() {
                    appState.phoneWiFiIP = status.value.ios?.ip
                    log.info("Phone WiFi IP: \(appState.phoneWiFiIP ?? "unavailable")")
                }

                // windowSize can fail if WDA's app reference is stale — use a default
                do {
                    appState.phoneScreenSize = try await client.windowSize()
                } catch {
                    log.warning("windowSize unavailable (\(error.localizedDescription)), using default iPhone size")
                    appState.phoneScreenSize = CGSize(width: 390, height: 844)
                }

                let nativeCaptureRequested = await MainActor.run {
                    startNativeCaptureForDevIfAvailable(
                        actualConnection: actualConnection,
                        trigger: "handleConnect"
                    )
                }

                // Configure WDA for high-FPS MJPEG streaming
                let isUSB = { if case .usb = actualConnection { return true }; return false }()
                try? await client.configureMJPEG(
                    framerate: isUSB ? 60 : 30,
                    quality: mjpegQuality,
                    scalingFactor: mjpegScalingFactor
                )

                // Configure H.264 resolution scale from settings
                let h264Scale = AppSettings().h264ResolutionScale
                try? await client.configureH264(resolutionScale: h264Scale)

                // Open input TCP socket for low-latency input
                let inputHost: String
                switch actualConnection {
                case .usb:
                    inputHost = "localhost"
                case .wifi(let host, _):
                    inputHost = host
                default:
                    inputHost = "localhost"
                }
                let socket = WDAInputSocket(host: inputHost, port: 9300)
                socket.onStateChange = { [weak appState] connected in
                    Task { @MainActor in
                        appState?.inputWSConnected = connected
                    }
                }
                appState.inputSocket = socket
                socket.connect()

                // Auto-unlock if device is locked
                do {
                    let autoUnlockEnabled = AppSettings().autoUnlock
                    let hasPasscode = PasscodeManager().hasSavedPasscode
                    log.info("[AutoUnlock] connect: enabled=\(autoUnlockEnabled) hasPasscode=\(hasPasscode) socketConnected=\(socket.isConnected)")
                    if autoUnlockEnabled, let passcode = PasscodeManager().load() {
                        log.info("[AutoUnlock] connect: invoking performAutoUnlock")
                        await Self.performAutoUnlock(client: client, socket: socket, passcode: passcode)
                    }
                }

                // Keyboard extension server — listens on port 9400, iOS extension connects via stored IP
                let kbSocket = KeyboardExtSocket()
                kbSocket.onStateChange = { [weak appState] connected in
                    Task { @MainActor in
                        appState?.keyboardExtConnected = connected
                        if connected {
                            log.info("Keyboard extension connected — text input via fast path")
                        }
                    }
                }
                appState.keyboardExtSocket = kbSocket
                kbSocket.startListening()

                // Resolve Mac's WiFi IP for the keyboard extension to connect to
                appState.macWiFiIP = Self.getLocalWiFiIP()
                if let ip = appState.macWiFiIP {
                    log.info("Mac WiFi IP for keyboard extension: \(ip)")
                }

                // Start screenshot stream immediately so user sees something
                let stream = ScreenshotStreamManager(baseURL: client.baseURL)
                appState.screenshotStream = stream
                stream.start(fps: 15)
                if !nativeCaptureRequested {
                    appState.activeVideoSource = .screenshot
                }

                // Premium: upgrade to MJPEG/H.264. Free: stay on screenshots.
                guard premium else {
                    log.info("handleConnect: free tier — staying on screenshot stream")
                    return
                }

                let mjpegURL: URL?
                switch actualConnection {
                case .usb:
                    mjpegURL = URL(string: "http://localhost:9100")
                case .wifi(let host, _):
                    mjpegURL = URL(string: "http://\(host):9100")
                default:
                    mjpegURL = nil
                }

                if let url = mjpegURL {
                    // H.264 host — only over WiFi (USB has enough bandwidth, MJPEG is faster)
                    let h264Host: String?
                    switch actualConnection {
                    case .wifi(let host, _):
                        h264Host = host
                    default:
                        h264Host = nil
                    }

                    Task {
                        // Give tunnels a moment to establish
                        try? await Task.sleep(nanoseconds: 500_000_000)

                        // Over WiFi: try H.264 first (10-20x bandwidth savings)
                        if let host = h264Host {
                            let h264 = H264StreamManager(host: host, port: 9200)
                            h264.start()
                            try? await Task.sleep(nanoseconds: 2_000_000_000)
                            let h264Ok = await MainActor.run { h264.currentFrame != nil }
                            if h264Ok {
                                await MainActor.run {
                                    appState.h264Stream = h264
                                    appState.screenshotStream?.stop()
                                    if appState.activeVideoSource != .iosScreenCaptureUSB {
                                        appState.activeVideoSource = .h264
                                    }
                                    self.connectionMonitor?.watchH264Stream(h264)
                                }
                                return
                            } else {
                                await MainActor.run { h264.stop() }
                            }
                        }

                        // USB or H.264 failed: use MJPEG
                        let mjpeg = MJPEGStreamManager(url: url)
                        mjpeg.start()
                        try? await Task.sleep(nanoseconds: 2_000_000_000)
                        await MainActor.run {
                            if mjpeg.currentFrame != nil {
                                appState.mjpegStream = mjpeg
                                appState.screenshotStream?.stop()
                                if appState.activeVideoSource != .iosScreenCaptureUSB {
                                    appState.activeVideoSource = .mjpeg
                                }
                                self.connectionMonitor?.watchStream(mjpeg)
                            } else {
                                mjpeg.stop()
                                if appState.activeVideoSource != .iosScreenCaptureUSB {
                                    appState.activeVideoSource = .screenshot
                                }
                            }
                        }
                    }
                }
            } catch {
                log.error("handleConnect FAILED: \(error.localizedDescription)")
                appState.errorMessage = error.localizedDescription
                appState.connectionState = .failed(error: error.localizedDescription)
            }
        }
    }

    @MainActor
    private func startNativeCaptureForDevIfAvailable(
        actualConnection: ConnectionState,
        trigger: String
    ) -> Bool {
        guard case .usb = actualConnection else {
            SpecchioLogger.iosScreenCapture.info("[MainWindow] native USB start skipped trigger=\(trigger, privacy: .public) reason=connection-not-usb connection=\(String(describing: actualConnection), privacy: .public)")
            return false
        }

        iosScreenCaptureMonitor.refreshDevices(trigger: "DevMode \(trigger)")
        guard let selected = iosScreenCaptureMonitor.selectedDevice else {
            SpecchioLogger.iosScreenCapture.info("[MainWindow] native USB start skipped trigger=\(trigger, privacy: .public) reason=\(iosScreenCaptureMonitor.diagnosticReason, privacy: .public)")
            return false
        }

        applyNativeUSBPolicyForDev(source: "DevMode \(trigger)")
        SpecchioLogger.iosScreenCapture.info("[MainWindow] native USB start selected trigger=\(trigger, privacy: .public) selected=\(selected.logSummary, privacy: .public)")
        appState.iosScreenCaptureStream = iosScreenCapture
        appState.activeVideoSource = .iosScreenCaptureUSB
        appState.lastVideoFallbackReason = nil
        iosScreenCapture.startCapture(deviceDescriptor: selected, trigger: "DevMode \(trigger)")
        return true
    }

    @MainActor
    private func applyNativeUSBPolicyForDev(source: String) {
        SpecchioLogger.iosScreenCapture.info("[MainWindow] native USB settings apply source=\(source, privacy: .public) configuredFPS=\(easyUSBTargetFPS)")
        iosScreenCapture.updateTargetFramesPerSecond(easyUSBTargetFPS, source: source)
    }

    @MainActor
    private func handleNativeCaptureHealthChangedForDev(
        from oldValue: IOSScreenCaptureHealth,
        to newValue: IOSScreenCaptureHealth
    ) {
        SpecchioLogger.iosScreenCapture.info("[MainWindow] native USB health changed from=\(oldValue.diagnosticDescription, privacy: .public) to=\(newValue.diagnosticDescription, privacy: .public) activeSource=\(appState.activeVideoSource.diagnosticName, privacy: .public)")

        if case .live = newValue {
            appState.activeVideoSource = .iosScreenCaptureUSB
            appState.iosScreenCaptureStream = iosScreenCapture
            if let frameSize = iosScreenCapture.lastFrameSize {
                appState.phoneScreenSize = frameSize
            }
        }
    }

    @MainActor
    private func handleNativeCaptureFailureForDev(reason: String) {
        SpecchioLogger.iosScreenCapture.info("[MainWindow] native USB failure fallback requested reason=\(reason, privacy: .public)")
        appState.lastVideoFallbackReason = reason
        if appState.iosScreenCaptureStream === iosScreenCapture {
            appState.iosScreenCaptureStream = nil
        }
        if appState.activeVideoSource == .iosScreenCaptureUSB {
            if let h264 = appState.h264Stream, h264.currentFrame != nil || h264.isStreaming {
                appState.activeVideoSource = .h264
            } else if let mjpeg = appState.mjpegStream, mjpeg.currentFrame != nil || mjpeg.isStreaming {
                appState.activeVideoSource = .mjpeg
            } else if appState.screenshotStream != nil {
                appState.activeVideoSource = .screenshot
            } else {
                appState.activeVideoSource = .none
            }
        }
        iosScreenCapture.stopCapture(reason: "DevMode fallback: \(reason)", clearFrame: false)
    }

    /// Wakes the screen, sends passcode digits, and verifies unlock.
    /// Uses pressButton("home") to wake (non-blocking) instead of /wda/unlock (which blocks until unlocked).
    static func performAutoUnlock(client: WDAClient, socket: WDAInputSocket, passcode: String) async {
        let log = SpecchioLogger.unlock
        log.info("[AutoUnlock] performAutoUnlock called, passcode length=\(passcode.count), socketConnected=\(socket.isConnected)")
        do {
            log.info("[AutoUnlock] calling GET /wda/locked...")
            let locked = try await client.isLocked()
            log.info("[AutoUnlock] isLocked returned: \(locked)")
            guard locked else {
                log.info("[AutoUnlock] device already unlocked — skipping")
                return
            }

            log.info("[AutoUnlock] device IS locked — pressing home to wake screen")
            try? await client.pressButton("home")
            log.info("[AutoUnlock] home pressed (1st), waiting 1s...")
            try? await Task.sleep(nanoseconds: 1_000_000_000)

            try? await client.pressButton("home")
            log.info("[AutoUnlock] home pressed (2nd), waiting 500ms...")
            try? await Task.sleep(nanoseconds: 500_000_000)

            log.info("[AutoUnlock] sending passcode digits via sendKeys...")
            socket.sendKeys(passcode)
            log.info("[AutoUnlock] passcode sent, waiting 1s for unlock...")
            try? await Task.sleep(nanoseconds: 1_000_000_000)

            log.info("[AutoUnlock] re-checking lock state...")
            let stillLocked = try await client.isLocked()
            if stillLocked {
                log.warning("[AutoUnlock] STILL LOCKED — wrong passcode? Not retrying.")
            } else {
                log.info("[AutoUnlock] SUCCESS — device unlocked")
            }
        } catch {
            log.error("[AutoUnlock] ERROR: \(error.localizedDescription)")
        }
    }

    /// Returns the Mac's WiFi IP address for the keyboard extension to connect to.
    private static func getLocalWiFiIP() -> String? {
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let firstAddr = ifaddr else { return nil }
        defer { freeifaddrs(ifaddr) }

        for ptr in sequence(first: firstAddr, next: { $0.pointee.ifa_next }) {
            let addr = ptr.pointee
            guard addr.ifa_addr.pointee.sa_family == UInt8(AF_INET) else { continue }
            let name = String(cString: addr.ifa_name)
            guard name == "en0" else { continue } // WiFi interface

            var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            if getnameinfo(addr.ifa_addr, socklen_t(addr.ifa_addr.pointee.sa_len),
                           &hostname, socklen_t(hostname.count),
                           nil, 0, NI_NUMERICHOST) == 0 {
                return String(cString: hostname)
            }
        }
        return nil
    }
}

private struct DevEasySizeIndicator: View {
    var body: some View {
        PulsingDot(color: .blue)
            .help("Dev window matched to Easy")
            .accessibilityLabel("Dev window matched to Easy")
            .onAppear {
                SpecchioLogger.easyMode.info("[MainWindow] dev-size indicator visible reservedHeight=\(EasyControlBarMetrics.windowReservedHeight)")
            }
    }
}

// MARK: - Reconnect Banner

private struct ReconnectBannerView: View {
    let message: String
    let isReconnecting: Bool

    var body: some View {
        HStack(spacing: 8) {
            if isReconnecting {
                ProgressView()
                    .controlSize(.small)
            } else {
                Image(systemName: "wifi")
                    .foregroundColor(.green)
            }
            Text(message)
                .font(.caption)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .modifier(GlassBannerModifier())
        .padding(.top, 8)
        .transition(.move(edge: .top).combined(with: .opacity))
        .animation(.easeInOut(duration: 0.3), value: message)
    }
}

private struct GlassBannerModifier: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            content.glassEffect(.regular, in: .capsule)
        } else {
            content
                .background(.ultraThinMaterial)
                .cornerRadius(8)
        }
    }
}

// MARK: - Pulsing Status Dot

struct PulsingDot: View {
    let color: Color
    @State private var pulse = false

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 8, height: 8)
            .scaleEffect(pulse ? 1.3 : 1.0)
            .opacity(pulse ? 0.5 : 1.0)
            .animation(.easeInOut(duration: 1.2).repeatForever(autoreverses: true), value: pulse)
            .onAppear { pulse = true }
    }
}
