import Foundation
import os.log

private let log = SpecchioLogger.network

@MainActor
class ConnectionMonitor {
    private weak var appState: AppState?
    private weak var deviceManager: DeviceManager?
    private var reconnectTask: Task<Void, Never>?

    init(appState: AppState, deviceManager: DeviceManager) {
        self.appState = appState
        self.deviceManager = deviceManager
    }

    /// Wire up the MJPEG stream's failure callback to trigger WiFi failover.
    func watchStream(_ mjpeg: MJPEGStreamManager) {
        mjpeg.onStreamFailed = { [weak self] error in
            log.warning("MJPEG stream failed: \(error?.localizedDescription ?? "unknown")")
            Task { @MainActor in
                self?.handleStreamFailure()
            }
        }
    }

    /// Wire up the H.264 stream's failure callback to trigger failover.
    func watchH264Stream(_ h264: H264StreamManager) {
        h264.onStreamFailed = { [weak self] error in
            log.warning("H264 stream failed: \(error?.localizedDescription ?? "unknown")")
            Task { @MainActor in
                self?.handleH264StreamFailure()
            }
        }
    }

    /// Wire up native iOS screen capture failure to the caller's mode-specific fallback.
    func watchIOSScreenCapture(
        _ capture: IOSScreenCaptureManager,
        onFailure: @escaping (String) -> Void
    ) {
        capture.onStreamFailed = { reason in
            log.warning("iOS screen capture failed: \(reason)")
            Task { @MainActor in
                onFailure(reason)
            }
        }
    }

    func cancel() {
        reconnectTask?.cancel()
        reconnectTask = nil
    }

    // MARK: - Private

    /// When H.264 fails, try falling back to MJPEG before full WiFi failover.
    private func handleH264StreamFailure() {
        guard let appState else { return }

        log.info("H264 stream failed — falling back to MJPEG")
        appState.h264Stream?.stop()
        appState.h264Stream = nil

        // Try MJPEG on the current connection
        let mjpegURL: URL?
        switch appState.connectionState {
        case .usb:
            mjpegURL = URL(string: "http://localhost:9100")
        case .wifi(let host, _):
            mjpegURL = URL(string: "http://\(host):9100")
        default:
            mjpegURL = nil
        }

        if let url = mjpegURL {
            let mjpeg = MJPEGStreamManager(url: url)
            mjpeg.start()
            appState.mjpegStream = mjpeg
            watchStream(mjpeg)
        }

        // Also restart screenshot polling as safety net
        if appState.screenshotStream == nil, let client = appState.wdaClient {
            let stream = ScreenshotStreamManager(baseURL: client.baseURL)
            appState.screenshotStream = stream
            stream.start(fps: 15)
        }
    }

    private func handleStreamFailure() {
        guard let appState else { return }

        // Only failover from USB connections
        guard case .usb = appState.connectionState else {
            log.info("Stream failed but not on USB — ignoring")
            return
        }

        guard let phoneIP = appState.phoneWiFiIP, !phoneIP.isEmpty else {
            log.warning("No phone WiFi IP available for failover")
            appState.errorMessage = "USB disconnected. No WiFi IP available."
            return
        }

        // Prevent concurrent reconnect attempts
        guard !appState.isReconnecting else { return }

        log.info("Starting WiFi failover to \(phoneIP)")
        appState.isReconnecting = true
        appState.reconnectBanner = "USB disconnected — switching to WiFi…"

        // Stop the dead streams but keep last frame for display
        appState.h264Stream?.stop()
        appState.mjpegStream?.stop()

        reconnectTask = Task {
            await attemptWiFiFailover(phoneIP: phoneIP)
        }
    }

    private func attemptWiFiFailover(phoneIP: String) async {
        guard let appState else { return }

        // Step 1: Verify WDA is reachable over WiFi
        let wifiBaseURL = URL(string: "http://\(phoneIP):8100")!
        let newClient = WDAClient(baseURL: wifiBaseURL)

        do {
            let status = try await newClient.status()
            guard status.value.ready else {
                throw WDAError.connectionFailed("WDA not ready over WiFi")
            }
            _ = try await newClient.createSession()
            log.info("WiFi WDA session created at \(phoneIP)")
        } catch {
            log.error("WiFi failover failed: \(error.localizedDescription)")
            appState.isReconnecting = false
            appState.reconnectBanner = nil
            appState.errorMessage = "WiFi failover failed: \(error.localizedDescription)"
            return
        }

        // Step 2: Configure MJPEG for WiFi (lower quality than USB)
        try? await newClient.configureMJPEG(framerate: 30, quality: 30, scalingFactor: 100)

        // Step 3: Swap in the new client and update connection state
        appState.wdaClient = newClient
        appState.connectionState = .wifi(host: phoneIP, port: 8100)

        // Step 4: Start screenshot stream as immediate fallback
        let screenshotStream = ScreenshotStreamManager(baseURL: newClient.baseURL)
        appState.screenshotStream = screenshotStream
        screenshotStream.start(fps: 10)

        // Step 5: Try H.264 first, then MJPEG over WiFi
        let h264 = H264StreamManager(host: phoneIP, port: 9200)
        h264.start()
        try? await Task.sleep(nanoseconds: 2_000_000_000)

        if h264.currentFrame != nil {
            appState.h264Stream = h264
            appState.screenshotStream?.stop()
            watchH264Stream(h264)
            log.info("WiFi failover complete: H264 streaming")
        } else {
            h264.stop()

            let mjpegURL = URL(string: "http://\(phoneIP):9100")!
            let mjpeg = MJPEGStreamManager(url: mjpegURL)
            mjpeg.start()
            try? await Task.sleep(nanoseconds: 2_000_000_000)

            if mjpeg.currentFrame != nil {
                appState.mjpegStream = mjpeg
                appState.screenshotStream?.stop()
                watchStream(mjpeg)
                log.info("WiFi failover complete: MJPEG streaming")
            } else {
                mjpeg.stop()
                appState.mjpegStream = nil
                log.info("WiFi failover complete: screenshot polling")
            }
        }

        // Step 6: Clean up dead USB tunnel
        deviceManager?.disconnectUSBTunnel()

        // Step 7: Dismiss banner
        appState.isReconnecting = false
        appState.reconnectBanner = "Switched to WiFi"

        Task {
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            if appState.reconnectBanner == "Switched to WiFi" {
                appState.reconnectBanner = nil
            }
        }
    }
}
