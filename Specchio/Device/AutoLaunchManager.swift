import Foundation
import Combine
import os.log

private let log = SpecchioLogger.autoLaunch

@MainActor
class AutoLaunchManager: ObservableObject {
    enum LaunchPhase: Equatable {
        case idle
        case detectingDevice
        case startingTunnel
        case buildingWDA
        case launchingWDA
        case waitingForWDA
        case ready
        case failed(String)
        case externallyManaged
    }

    enum DetectedConnection: Equatable, CustomStringConvertible {
        case usb
        case wifi(host: String)

        var description: String {
            switch self {
            case .usb: return "USB"
            case .wifi(let host): return "WiFi(\(host))"
            }
        }
    }

    @Published var phase: LaunchPhase = .idle
    @Published var statusMessage: String = ""
    /// Forwarded from WDALauncher — last meaningful xcodebuild activity line.
    @Published var buildActivity: String = ""
    /// Hint from iproxy when device connection fails (e.g. phone locked).
    @Published var connectionHint: String?
    /// Result of unified autoLaunch() — how WDA was reached.
    @Published var detectedConnection: DetectedConnection?
    /// True when WDA was built (first build) but hasn't responded — likely needs developer trust.
    @Published var awaitingTrust: Bool = false

    let usbTunnel = USBTunnel()
    let wdaLauncher = WDALauncher()
    /// Set by DeviceManager — used for WiFi subnet scanning during unified auto-launch.
    var wifiDiscovery: WiFiDeviceDiscovery?
    /// Set by DeviceManager from LicenseManager — gates WiFi features.
    var isPremium: Bool = false

    private var pollTask: Task<Void, Never>?
    private var cancellables = Set<AnyCancellable>()

    init() {
        wdaLauncher.$buildActivity
            .receive(on: DispatchQueue.main)
            .sink { [weak self] activity in
                self?.buildActivity = activity
            }
            .store(in: &cancellables)
        wdaLauncher.$state
            .receive(on: DispatchQueue.main)
            .sink { [weak self] wdaState in
                guard let self else { return }
                switch wdaState {
                case .building:
                    self.phase = .buildingWDA
                    self.statusMessage = self.wdaLauncher.isFirstBuild
                        ? "Building WebDriverAgent (first time)…"
                        : "Building WebDriverAgent…"
                case .launching:
                    self.phase = .launchingWDA
                    self.statusMessage = "Launching WebDriverAgent…"
                default:
                    break
                }
            }
            .store(in: &cancellables)
        usbTunnel.$connectionHint
            .receive(on: DispatchQueue.main)
            .sink { [weak self] hint in
                self?.connectionHint = hint
            }
            .store(in: &cancellables)
    }

    /// Checks if WDA is already running, otherwise orchestrates the full launch sequence.
    func autoLaunchUSB() async throws {
        log.info("=== Auto-launch started ===")

        // Kill orphaned processes from previous app sessions (crash, force-quit, etc.)
        // Only kills if we don't already own processes on these ports.
        cleanupOrphanedProcesses()

        // Step 0: Check if WDA is already responding
        statusMessage = "Checking for existing WDA..."
        log.info("Step 0: Probing for existing WDA at localhost:8100...")
        if await probeWDA() {
            log.info("Step 0: WDA already running, skipping launch")
            phase = .externallyManaged
            statusMessage = "WDA already running"
            return
        }
        log.info("Step 0: No existing WDA found")

        // Step 1: Detect device
        phase = .detectingDevice
        statusMessage = "Detecting iOS device..."
        log.info("Step 1: Detecting iOS device...")

        // Full Xcode.app is required for build-for-testing (iOS SDK + xcodebuild)
        let xcodeInstalled = DependencyChecker.isXcodeAppInstalled()
        log.info("Step 1: Xcode.app installed: \(xcodeInstalled)")
        guard xcodeInstalled else {
            log.error("Step 1: FAILED - Xcode.app not installed")
            phase = .failed("Xcode.app is required to build WebDriverAgent. Install it from the App Store.")
            throw DeviceDetectorError.xctraceNotFound
        }

        let devices: [DetectedDevice]
        do {
            devices = try await DeviceDetector.detectDevices()
            log.info("Step 1: Found \(devices.count) device(s)")
            for d in devices {
                log.info("  - \(d.name) (\(d.udid))")
            }
        } catch {
            log.error("Step 1: FAILED - Device detection error: \(error.localizedDescription)")
            phase = .failed("Xcode command line tools not found.")
            throw error
        }

        guard let device = devices.first else {
            log.error("Step 1: FAILED - No iOS device connected")
            phase = .failed("No iOS device connected via USB.")
            throw DeviceDetectorError.noDeviceFound
        }

        statusMessage = "Found: \(device.name)"
        log.info("Step 1: Using device: \(device.name) (\(device.udid))")

        // Step 2: Start iproxy tunnels
        phase = .startingTunnel
        statusMessage = "Starting USB tunnels..."
        let iproxyPath = DependencyChecker.iproxyPath()
        log.info("Step 2: Starting iproxy tunnels, iproxy path: \(iproxyPath ?? "NOT FOUND")")

        do {
            try usbTunnel.start(
                portMappings: [(local: 8100, remote: 8100), (local: 9100, remote: 9100), (local: 9200, remote: 9200), (local: 9300, remote: 9300)],
                udid: device.udid
            )
            log.info("Step 2: iproxy started successfully")
        } catch {
            log.error("Step 2: FAILED - iproxy error: \(error.localizedDescription)")
            phase = .failed("iproxy not found. The bundled copy may be missing.")
            throw error
        }

        // Brief pause for tunnels to establish
        log.info("Step 2: Waiting 500ms for tunnels to establish...")
        try await Task.sleep(nanoseconds: 500_000_000)

        // Step 3: Launch WDA (build-once-then-cache)
        log.info("Step 3: Launching WDA via build cache...")

        // Show proactive trust reminder during first build
        connectionHint = "First build? After it completes, on your iPhone: Settings > General > VPN & Device Management > Trust your developer account"

        do {
            try await wdaLauncher.launchWithCache(udid: device.udid)
            log.info("Step 3: wdaLauncher.launchWithCache() returned successfully")
        } catch {
            log.error("Step 3: FAILED - WDA launch error: \(error.localizedDescription)")
            phase = .failed(error.localizedDescription)
            throw error
        }

        // Step 4: Poll for WDA readiness
        phase = .waitingForWDA
        statusMessage = "Waiting for WDA to start..."
        log.info("Step 4: Polling for WDA readiness (timeout: 120s)...")

        let ready = await pollUntilReady(timeout: 120)

        if ready {
            log.info("Step 4: WDA is ready!")
            phase = .ready
            statusMessage = "WDA is ready"
        } else {
            log.error("Step 4: FAILED - WDA did not start within 120s")
            phase = .failed("WDA built but won't run. On your iPhone: Settings > General > VPN & Device Management > tap your developer profile > Trust. Then retry.")
            throw WDALauncherError.launchFailed("Timeout waiting for WDA")
        }

        log.info("=== Auto-launch completed successfully ===")
    }

    /// Launches WDA over WiFi — no USB tunnels needed.
    /// Requires the device to be WiFi-paired in Xcode ("Connect via network").
    func autoLaunchWiFi(deviceIP: String) async throws {
        let wdaBaseURL = "http://\(deviceIP):8100"
        log.info("=== WiFi auto-launch started (target: \(wdaBaseURL)) ===")

        // Step 0: Check if WDA is already responding on the device IP
        statusMessage = "Checking for existing WDA..."
        log.info("Step 0: Probing for existing WDA at \(wdaBaseURL)...")
        if await probeWDA(baseURL: wdaBaseURL) {
            log.info("Step 0: WDA already running at \(deviceIP), skipping launch")
            phase = .externallyManaged
            statusMessage = "WDA already running"
            return
        }
        log.info("Step 0: No existing WDA found at \(deviceIP)")

        // Step 1: Detect device (xctrace shows WiFi-paired devices too)
        phase = .detectingDevice
        statusMessage = "Detecting iOS device..."
        log.info("Step 1: Detecting iOS device...")

        let xcodeInstalled = DependencyChecker.isXcodeAppInstalled()
        log.info("Step 1: Xcode.app installed: \(xcodeInstalled)")
        guard xcodeInstalled else {
            log.error("Step 1: FAILED - Xcode.app not installed")
            phase = .failed("Xcode.app is required to build WebDriverAgent. Install it from the App Store.")
            throw DeviceDetectorError.xctraceNotFound
        }

        let devices: [DetectedDevice]
        do {
            devices = try await DeviceDetector.detectDevices()
            log.info("Step 1: Found \(devices.count) device(s)")
            for d in devices {
                log.info("  - \(d.name) (\(d.udid))")
            }
        } catch {
            log.error("Step 1: FAILED - Device detection error: \(error.localizedDescription)")
            phase = .failed("Xcode command line tools not found.")
            throw error
        }

        guard let device = devices.first else {
            log.error("Step 1: FAILED - No iOS device found (USB or WiFi-paired)")
            phase = .failed("No iOS device found. Pair via USB first with 'Connect via network' enabled in Xcode.")
            throw DeviceDetectorError.noDeviceFound
        }

        statusMessage = "Found: \(device.name)"
        log.info("Step 1: Using device: \(device.name) (\(device.udid))")

        // Step 2: SKIP iproxy — WiFi connects directly to device IP

        // Step 3: Launch WDA (same xcodebuild command — works over WiFi)
        log.info("Step 3: Launching WDA via build cache (WiFi)...")

        do {
            try await wdaLauncher.launchWithCache(udid: device.udid)
            log.info("Step 3: wdaLauncher.launchWithCache() returned successfully")
        } catch {
            log.error("Step 3: FAILED - WDA launch error: \(error.localizedDescription)")
            phase = .failed(error.localizedDescription)
            throw error
        }

        // Step 4: Poll device IP for WDA readiness (longer timeout for WiFi)
        phase = .waitingForWDA
        statusMessage = "Waiting for WDA to start..."
        log.info("Step 4: Polling for WDA readiness at \(wdaBaseURL) (timeout: 120s)...")

        let ready = await pollUntilReady(baseURL: wdaBaseURL, timeout: 120)

        if ready {
            log.info("Step 4: WDA is ready at \(deviceIP)!")
            phase = .ready
            statusMessage = "WDA is ready"
        } else {
            log.error("Step 4: FAILED - WDA did not start within 120s")
            phase = .failed("WDA did not start within 120s. Ensure device is WiFi-paired in Xcode.")
            throw WDALauncherError.launchFailed("Timeout waiting for WDA over WiFi")
        }

        log.info("=== WiFi auto-launch completed successfully ===")
    }

    /// Unified auto-launch: detects device, launches WDA, auto-detects USB or WiFi.
    /// Single entry point — no need to choose USB vs WiFi upfront.
    func autoLaunch() async throws {
        log.info("=== Unified auto-launch started ===")
        detectedConnection = nil

        cleanupOrphanedProcesses()

        // Step 0: Check if WDA is already responding on localhost (existing USB tunnel)
        statusMessage = "Checking for existing WDA..."
        log.info("Step 0: Probing for existing WDA at localhost:8100...")
        if await probeWDA() {
            log.info("Step 0: WDA already running on localhost, skipping launch")
            phase = .externallyManaged
            statusMessage = "WDA already running"
            detectedConnection = .usb
            return
        }
        // Also check if WDA is already running on WiFi (premium only)
        if isPremium, let wifiHost = await wifiDiscovery?.quickFindWDA() {
            let wifiBase = "http://\(wifiHost):8100"
            if await probeWDA(baseURL: wifiBase) {
                log.info("Step 0: WDA already running at \(wifiHost), skipping launch")
                phase = .externallyManaged
                statusMessage = "WDA already running"
                detectedConnection = .wifi(host: wifiHost)
                return
            }
        }
        log.info("Step 0: No existing WDA found")

        // Step 1: Detect device
        phase = .detectingDevice
        statusMessage = "Detecting iOS device..."
        log.info("Step 1: Detecting iOS device...")

        let xcodeInstalled = DependencyChecker.isXcodeAppInstalled()
        guard xcodeInstalled else {
            log.error("Step 1: FAILED - Xcode.app not installed")
            phase = .failed("Xcode.app is required to build WebDriverAgent. Install it from the App Store.")
            throw DeviceDetectorError.xctraceNotFound
        }

        let devices: [DetectedDevice]
        do {
            devices = try await DeviceDetector.detectDevices()
            log.info("Step 1: Found \(devices.count) device(s)")
            for d in devices {
                log.info("  - \(d.name) (\(d.udid))")
            }
        } catch {
            log.error("Step 1: FAILED - Device detection error: \(error.localizedDescription)")
            phase = .failed("Xcode command line tools not found.")
            throw error
        }

        guard let device = devices.first else {
            log.error("Step 1: FAILED - No iOS device found")
            phase = .failed("No iOS device found. Connect via USB or enable WiFi pairing in Xcode.")
            throw DeviceDetectorError.noDeviceFound
        }

        statusMessage = "Found: \(device.name)"
        log.info("Step 1: Using device: \(device.name) (\(device.udid))")

        // Step 2: Try iproxy (best-effort — may silently fail if no USB)
        log.info("Step 2: Attempting iproxy tunnels (best-effort)...")
        do {
            try usbTunnel.start(
                portMappings: [(local: 8100, remote: 8100), (local: 9100, remote: 9100), (local: 9200, remote: 9200), (local: 9300, remote: 9300)],
                udid: device.udid
            )
            log.info("Step 2: iproxy started (may or may not establish USB connection)")
        } catch {
            log.info("Step 2: iproxy not available, will rely on WiFi: \(error.localizedDescription)")
            // Not fatal — WiFi path doesn't need iproxy
        }

        try await Task.sleep(nanoseconds: 500_000_000)

        // Step 3: Launch WDA (same xcodebuild command — works over USB and WiFi)
        log.info("Step 3: Launching WDA via build cache...")

        do {
            try await wdaLauncher.launchWithCache(udid: device.udid)
            log.info("Step 3: wdaLauncher.launchWithCache() returned successfully")
        } catch {
            log.error("Step 3: FAILED - WDA launch error: \(error.localizedDescription)")
            phase = .failed(error.localizedDescription)
            throw error
        }

        // Step 4: Poll for WDA readiness
        phase = .waitingForWDA
        statusMessage = "Waiting for WDA to start..."

        if isPremium {
            log.info("Step 4: Race-polling for WDA (localhost + subnet, timeout: 120s)...")
        } else {
            log.info("Step 4: Polling localhost only (free tier, timeout: 120s)...")
        }

        if let connection = await pollUntilReadyAny(timeout: 120) {
            log.info("Step 4: WDA is ready via \(connection)!")
            phase = .ready
            statusMessage = "WDA is ready"
            detectedConnection = connection

            // If connected via WiFi, stop unused iproxy
            if case .wifi = connection {
                usbTunnel.stop()
            }
        } else {
            log.error("Step 4: FAILED - WDA did not start within 120s")
            phase = .failed("WDA built but won't run. On your iPhone: Settings > General > VPN & Device Management > tap your developer profile > Trust. Then retry.")
            throw WDALauncherError.launchFailed("Timeout waiting for WDA")
        }

        log.info("=== Unified auto-launch completed successfully ===")
    }

    /// Stops all spawned processes (iproxy + xcodebuild).
    func stopAll() {
        log.info("stopAll() called")
        pollTask?.cancel()
        pollTask = nil
        wdaLauncher.stop()
        usbTunnel.stop()
        phase = .idle
        statusMessage = ""
        awaitingTrust = false
    }

    /// Re-polls for WDA readiness after the user has trusted the developer on their iPhone.
    /// Does NOT restart the build — just re-runs the poll loop.
    func retryPoll() async {
        log.info("retryPoll: re-polling for WDA readiness after trust")
        awaitingTrust = false
        phase = .waitingForWDA
        statusMessage = "Checking for WDA..."

        let ready = await pollUntilReady(timeout: 120)
        if ready {
            log.info("retryPoll: WDA is ready after trust!")
            phase = .ready
            statusMessage = "WDA is ready"
        } else {
            log.error("retryPoll: WDA still not responding after trust + 120s")
            phase = .failed("WDA still not responding. Make sure you trusted the developer profile on your iPhone, then retry.")
        }
    }

    /// Polls WDA /status every 2s for up to `timeout` seconds.
    /// Uses lightweight status-only check — the full /screenshot probe is too
    /// aggressive for freshly-launched WDA that hasn't fully initialized yet.
    private func pollUntilReady(baseURL: String = "http://localhost:8100", timeout: TimeInterval) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        let trustThreshold: TimeInterval = 15

        while Date() < deadline {
            if Task.isCancelled {
                log.info("Poll cancelled")
                return false
            }

            if await checkWDAStatus(baseURL: baseURL) {
                log.info("Poll: WDA responded ready!")
                awaitingTrust = false
                return true
            }

            let elapsed = -Date().timeIntervalSince(deadline) + timeout

            // Detect trust-needed state: first build, WDA not responding after threshold
            if wdaLauncher.isFirstBuild && elapsed > trustThreshold && !awaitingTrust {
                log.info("Poll: first build not responding after \(Int(trustThreshold))s — likely needs developer trust")
                awaitingTrust = true
            }

            statusMessage = "Waiting for WDA... (\(Int(elapsed))s)"

            try? await Task.sleep(nanoseconds: 2_000_000_000)
        }

        return false
    }

    /// Race-polls both localhost (USB tunnel) and subnet (WiFi) for WDA readiness.
    /// Returns the first connection type that responds, or nil on timeout.
    private func pollUntilReadyAny(timeout: TimeInterval) async -> DetectedConnection? {
        let deadline = Date().addingTimeInterval(timeout)

        while Date() < deadline {
            if Task.isCancelled {
                log.info("Poll cancelled")
                return nil
            }

            // Race: check USB and WiFi in parallel (WiFi only if premium)
            async let usbReady = checkWDAStatus(baseURL: "http://localhost:8100")
            async let wifiHost = isPremium ? wifiDiscovery?.quickFindWDA() : nil

            let usb = await usbReady
            let wifi = await wifiHost

            if usb {
                log.info("Poll: WDA responded on localhost (USB)")
                return .usb
            }
            if let host = wifi {
                log.info("Poll: WDA found on WiFi at \(host)")
                return .wifi(host: host)
            }

            let elapsed = Int(-Date().timeIntervalSince(deadline) + timeout)
            statusMessage = "Waiting for WDA... (\(elapsed)s)"

            try? await Task.sleep(nanoseconds: 2_000_000_000)
        }

        return nil
    }

    /// Kills orphaned iproxy tunnels from previous app sessions.
    /// Only kills if the current session doesn't own processes on these ports.
    /// Does NOT kill xcodebuild — WDA runs on the phone and should stay alive
    /// for WiFi use even after USB disconnect or app restart.
    private func cleanupOrphanedProcesses() {
        guard !usbTunnel.isActive else { return }

        for port in [8100, 9100] {
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
                    log.info("Killing orphaned process on port \(port) (pid: \(pid))")
                    kill(pid, SIGTERM)
                }
            }
        }
        usleep(300_000)
    }

    /// Lightweight check: only /status endpoint. Used for post-launch polling
    /// where WDA was just started and /screenshot may not be ready yet.
    private func checkWDAStatus(baseURL: String = "http://localhost:8100") async -> Bool {
        guard let url = URL(string: "\(baseURL)/status") else { return false }
        var request = URLRequest(url: url)
        request.timeoutInterval = 2.0
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { return false }
            let status = try JSONDecoder().decode(WDAStatus.self, from: data)
            return status.value.ready
        } catch {
            return false
        }
    }

    /// Strict probe: checks /status AND /screenshot to detect stale/degraded WDA.
    /// Used for Step 0 (detecting existing WDA before launching a new one).
    private func probeWDA(baseURL: String = "http://localhost:8100") async -> Bool {
        guard await checkWDAStatus(baseURL: baseURL) else { return false }

        // Verify WDA can actually interact with the device
        guard let ssURL = URL(string: "\(baseURL)/screenshot") else { return false }
        var ssRequest = URLRequest(url: ssURL)
        ssRequest.timeoutInterval = 5.0
        do {
            let (_, ssResponse) = try await URLSession.shared.data(for: ssRequest)
            guard let ssHTTP = ssResponse as? HTTPURLResponse,
                  (200...299).contains(ssHTTP.statusCode) else {
                log.warning("WDA /status is ready but /screenshot failed — WDA is degraded, will restart")
                return false
            }
            return true
        } catch {
            log.warning("WDA /status is ready but /screenshot timed out — will restart")
            return false
        }
    }
}
