import Foundation
import Network

class WiFiDeviceDiscovery: ObservableObject {
    @Published var discoveredDevices: [WiFiDevice] = []
    @Published var isScanning = false

    struct WiFiDevice: Identifiable {
        let id = UUID()
        let host: String
        let port: Int
        let name: String?
    }

    private var browser: NWBrowser?
    private var scanTask: Task<Void, Never>?

    func scanLocalNetwork() async {
        await MainActor.run {
            isScanning = true
            discoveredDevices = []
        }

        // Use NWBrowser to discover HTTP services on the local network
        let params = NWParameters()
        params.includePeerToPeer = true
        let descriptor = NWBrowser.Descriptor.bonjour(type: "_http._tcp", domain: nil)
        let newBrowser = NWBrowser(for: descriptor, using: params)

        await MainActor.run { self.browser = newBrowser }

        newBrowser.browseResultsChangedHandler = { results, _ in
            Task {
                var devices: [WiFiDevice] = []
                for result in results {
                    if case .service(let name, _, _, _) = result.endpoint {
                        // Resolve the endpoint to get the IP
                        if let device = await self.resolveAndProbe(result: result, name: name),
                           !self.isLocalAddress(device.host) {
                            devices.append(device)
                        }
                    }
                }
                await MainActor.run {
                    self.discoveredDevices = devices
                }
            }
        }

        newBrowser.stateUpdateHandler = { state in
            if case .failed = state {
                Task { await MainActor.run { self.isScanning = false } }
            }
        }

        newBrowser.start(queue: .global(qos: .userInitiated))

        // Also do a targeted probe of common WDA locations
        scanTask = Task {
            // Try to get phone IP from an existing WDA connection
            if let localIP = getLocalIPAddress() {
                let subnet = localIP.components(separatedBy: ".").prefix(3).joined(separator: ".")
                // Probe a few common IPs quickly using NWConnection (doesn't trigger local network popup)
                let candidates = await quickPortScan(subnet: subnet, port: 8100)
                for host in candidates {
                    guard !self.isLocalAddress(host) else { continue }
                    if let device = await probeHost(host, port: 8100) {
                        await MainActor.run {
                            if !self.discoveredDevices.contains(where: { $0.host == host }) {
                                self.discoveredDevices.append(device)
                            }
                        }
                    }
                }
            }

            // Stop browsing after 5 seconds
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            await MainActor.run {
                self.browser?.cancel()
                self.browser = nil
                self.isScanning = false
            }
        }
    }

    func stopScan() {
        scanTask?.cancel()
        browser?.cancel()
        browser = nil
        isScanning = false
    }

    // MARK: - Bonjour Resolution

    private func resolveAndProbe(result: NWBrowser.Result, name: String) async -> WiFiDevice? {
        // Use NWConnection to resolve the endpoint and get the IP
        let connection = NWConnection(to: result.endpoint, using: .tcp)
        return await withCheckedContinuation { continuation in
            var resumed = false
            connection.stateUpdateHandler = { state in
                guard !resumed else { return }
                switch state {
                case .ready:
                    resumed = true
                    if let path = connection.currentPath,
                       let endpoint = path.remoteEndpoint,
                       case .hostPort(let host, let port) = endpoint {
                        let hostStr: String
                        switch host {
                        case .ipv4(let addr):
                            hostStr = "\(addr)"
                        case .ipv6(let addr):
                            hostStr = "\(addr)"
                        case .name(let name, _):
                            hostStr = name
                        @unknown default:
                            hostStr = "\(host)"
                        }
                        let portInt = Int(port.rawValue)
                        connection.cancel()
                        // Now probe to confirm it's WDA
                        Task {
                            let device = await self.probeHost(hostStr, port: portInt)
                            continuation.resume(returning: device)
                        }
                    } else {
                        connection.cancel()
                        continuation.resume(returning: nil)
                    }
                case .failed, .cancelled:
                    resumed = true
                    continuation.resume(returning: nil)
                default:
                    break
                }
            }
            connection.start(queue: .global(qos: .userInitiated))

            // Timeout after 2s
            DispatchQueue.global().asyncAfter(deadline: .now() + 2) {
                guard !resumed else { return }
                resumed = true
                connection.cancel()
                continuation.resume(returning: nil)
            }
        }
    }

    // MARK: - Quick Port Scan via NWConnection

    private func quickPortScan(subnet: String, port: Int) async -> [String] {
        await withTaskGroup(of: String?.self) { group in
            for i in 1...255 {
                group.addTask {
                    let host = "\(subnet).\(i)"
                    return await self.isPortOpen(host: host, port: port) ? host : nil
                }
            }
            var open: [String] = []
            for await result in group {
                if let host = result { open.append(host) }
            }
            return open
        }
    }

    private func isPortOpen(host: String, port: Int) async -> Bool {
        let endpoint = NWEndpoint.hostPort(host: .init(host), port: .init(integerLiteral: UInt16(port)))
        let connection = NWConnection(to: endpoint, using: .tcp)

        return await withCheckedContinuation { continuation in
            var resumed = false
            connection.stateUpdateHandler = { state in
                guard !resumed else { return }
                switch state {
                case .ready:
                    resumed = true
                    connection.cancel()
                    continuation.resume(returning: true)
                case .failed, .cancelled:
                    resumed = true
                    continuation.resume(returning: false)
                default:
                    break
                }
            }
            connection.start(queue: .global(qos: .utility))

            DispatchQueue.global().asyncAfter(deadline: .now() + 0.5) {
                guard !resumed else { return }
                resumed = true
                connection.cancel()
                continuation.resume(returning: false)
            }
        }
    }

    /// Returns true for localhost, loopback, or this Mac's own IP — these belong in the USB section, not WiFi.
    private func isLocalAddress(_ host: String) -> Bool {
        if host == "localhost" || host.hasPrefix("127.") || host == "::1" {
            return true
        }
        // Also filter out this Mac's own LAN IP (iproxy binds to all interfaces)
        if let localIP = getLocalIPAddress(), host == localIP {
            return true
        }
        return false
    }

    // MARK: - HTTP Probe

    private func probeHost(_ host: String, port: Int) async -> WiFiDevice? {
        guard let url = URL(string: "http://\(host):\(port)/status") else { return nil }
        var request = URLRequest(url: url)
        request.timeoutInterval = 2.0

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse,
                  httpResponse.statusCode == 200 else { return nil }

            // Only accept if it's actually WDA and reports ready
            guard let json = try? JSONDecoder().decode(WDAStatus.self, from: data),
                  json.value.ready else { return nil }
            return WiFiDevice(host: host, port: port, name: json.value.message)
        } catch {
            return nil
        }
    }

    func addManualDevice(host: String, port: Int = 8100) async -> WiFiDevice? {
        return await probeHost(host, port: port)
    }

    /// Fast subnet scan for WDA — returns the first non-local host with WDA on port 8100.
    /// No Bonjour, no 5s wait — just the quick TCP port scan (~0.5s).
    func quickFindWDA() async -> String? {
        guard let localIP = getLocalIPAddress() else { return nil }
        let subnet = localIP.components(separatedBy: ".").prefix(3).joined(separator: ".")
        let candidates = await quickPortScan(subnet: subnet, port: 8100)
        for host in candidates where !isLocalAddress(host) {
            if let _ = await probeHost(host, port: 8100) {
                return host
            }
        }
        return nil
    }

    private func getLocalIPAddress() -> String? {
        var address: String?
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let firstAddr = ifaddr else { return nil }
        defer { freeifaddrs(ifaddr) }

        for ptr in sequence(first: firstAddr, next: { $0.pointee.ifa_next }) {
            let interface = ptr.pointee
            let addrFamily = interface.ifa_addr.pointee.sa_family
            if addrFamily == UInt8(AF_INET) {
                let name = String(cString: interface.ifa_name)
                if name == "en0" || name == "en1" {
                    var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                    getnameinfo(interface.ifa_addr, socklen_t(interface.ifa_addr.pointee.sa_len),
                                &hostname, socklen_t(hostname.count), nil, 0, NI_NUMERICHOST)
                    address = String(cString: hostname)
                }
            }
        }
        return address
    }
}
