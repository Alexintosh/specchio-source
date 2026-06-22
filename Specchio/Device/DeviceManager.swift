import SwiftUI
import Combine
import os.log

private let log = SpecchioLogger.autoLaunch

@MainActor
class DeviceManager: ObservableObject {
    @Published var connectionState: ConnectionState = .disconnected
    @Published var availableWiFiDevices: [WiFiDeviceDiscovery.WiFiDevice] = []
    @Published var usbTunnelDetected = false

    let wifiDiscovery = WiFiDeviceDiscovery()
    let usbTunnel = USBTunnel()
    let autoLauncher = AutoLaunchManager()

    private var cancellables = Set<AnyCancellable>()

    init() {
        autoLauncher.wifiDiscovery = wifiDiscovery
        wifiDiscovery.$discoveredDevices
            .assign(to: &$availableWiFiDevices)
    }

    func connectUSBTunnel() async throws -> WDAClient {
        connectionState = .connecting

        let client = WDAClient(baseURL: URL(string: "http://localhost:8100")!)

        let status = try await client.status()
        guard status.value.ready else {
            connectionState = .failed(error: "WDA not ready")
            throw WDAError.connectionFailed("WDA is not ready")
        }

        _ = try await client.createSession()
        connectionState = .usb(host: "localhost", port: 8100)
        return client
    }

    func connectWiFi(host: String, port: Int = 8100) async throws -> WDAClient {
        connectionState = .connecting

        let client = WDAClient(baseURL: URL(string: "http://\(host):\(port)")!)

        let status = try await client.status()
        guard status.value.ready else {
            connectionState = .failed(error: "WDA not ready at \(host):\(port)")
            throw WDAError.connectionFailed("WDA is not ready")
        }

        _ = try await client.createSession()
        connectionState = .wifi(host: host, port: port)
        return client
    }

    /// Auto-launches iproxy + WDA, then connects.
    func connectUSBAutoLaunch() async throws -> WDAClient {
        log.info("connectUSBAutoLaunch: starting...")
        connectionState = .connecting
        try await autoLauncher.autoLaunchUSB()
        log.info("connectUSBAutoLaunch: auto-launch done, now connecting to WDA...")
        do {
            return try await connectUSBTunnel()
        } catch {
            // Surface connection errors in the auto-launcher so the UI shows them
            autoLauncher.phase = .failed(error.localizedDescription)
            throw error
        }
    }

    /// Unified auto-launch: detects USB or WiFi, launches WDA, connects.
    func connectAutoLaunch() async throws -> WDAClient {
        log.info("connectAutoLaunch: starting unified flow...")
        connectionState = .connecting
        try await autoLauncher.autoLaunch()

        guard let detected = autoLauncher.detectedConnection else {
            autoLauncher.phase = .failed("Could not reach WDA via USB or WiFi")
            throw WDAError.connectionFailed("Could not reach WDA")
        }

        log.info("connectAutoLaunch: auto-launch done (\(detected)), now connecting...")
        do {
            switch detected {
            case .usb:
                return try await connectUSBTunnel()
            case .wifi(let host):
                return try await connectWiFi(host: host)
            }
        } catch {
            autoLauncher.phase = .failed(error.localizedDescription)
            throw error
        }
    }

    /// Auto-launches WDA over WiFi (no USB tunnel), then connects.
    func connectWiFiAutoLaunch(host: String) async throws -> WDAClient {
        log.info("connectWiFiAutoLaunch: starting for \(host)...")
        connectionState = .connecting
        try await autoLauncher.autoLaunchWiFi(deviceIP: host)
        log.info("connectWiFiAutoLaunch: auto-launch done, now connecting to WDA...")
        do {
            return try await connectWiFi(host: host)
        } catch {
            autoLauncher.phase = .failed(error.localizedDescription)
            throw error
        }
    }

    /// Soft disconnect: stop USB tunnel only. WDA stays alive on the phone for WiFi use.
    func disconnectUSBTunnel() {
        usbTunnel.stop()
        autoLauncher.usbTunnel.stop()
    }

    /// Full disconnect: stop everything including WDA.
    func disconnect() {
        log.info("[DeviceManagerDisconnect] requested connectionState=\(String(describing: self.connectionState), privacy: .public) usbTunnelDetected=\(self.usbTunnelDetected)")
        autoLauncher.stopAll()
        usbTunnel.stop()
        connectionState = .disconnected
        log.info("[DeviceManagerDisconnect] completed connectionState=\(String(describing: self.connectionState), privacy: .public)")
    }

    func scanForDevices() async {
        usbTunnelDetected = await probeLocalhost()
        await wifiDiscovery.scanLocalNetwork()
    }

    private func probeLocalhost() async -> Bool {
        guard let url = URL(string: "http://localhost:8100/status") else { return false }
        var request = URLRequest(url: url)
        request.timeoutInterval = 1.0
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { return false }
            let status = try JSONDecoder().decode(WDAStatus.self, from: data)
            return status.value.ready
        } catch {
            return false
        }
    }
}
