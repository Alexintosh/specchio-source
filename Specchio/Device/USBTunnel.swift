import Foundation
import os.log

private let log = SpecchioLogger.autoLaunch

class USBTunnel: ObservableObject {
    @Published var isActive = false
    @Published var localPort: Int = 8100
    /// Surfaced to UI when iproxy reports connection issues (e.g. device locked).
    @Published var connectionHint: String?

    private var processes: [Process] = []

    func start(portMappings: [(local: Int, remote: Int)], udid: String? = nil) throws {
        stop()

        guard !portMappings.isEmpty else { return }
        self.localPort = portMappings[0].local

        // Kill any stale iproxy processes to free the ports
        killStaleIproxy(ports: portMappings.map { $0.local })

        guard let iproxyPath = DependencyChecker.iproxyPath() else {
            log.error("USBTunnel: iproxy not found")
            throw USBTunnelError.iproxyNotFound
        }

        log.info("USBTunnel: using iproxy at \(iproxyPath)")

        for mapping in portMappings {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: iproxyPath)

            var args = ["\(mapping.local)", "\(mapping.remote)"]
            if let udid = udid {
                args.append("--udid")
                args.append(udid)
            }
            process.arguments = args

            // Set DYLD_LIBRARY_PATH so bundled dylibs are found
            let toolDir = (iproxyPath as NSString).deletingLastPathComponent
            var env = ProcessInfo.processInfo.environment
            env["DYLD_LIBRARY_PATH"] = toolDir
            process.environment = env

            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = pipe

            process.terminationHandler = { [weak self] proc in
                log.info("USBTunnel: iproxy \(mapping.local):\(mapping.remote) terminated with code \(proc.terminationStatus)")
                DispatchQueue.main.async {
                    guard let self = self else { return }
                    if self.processes.allSatisfy({ !$0.isRunning }) {
                        self.isActive = false
                    }
                    // Non-zero exit right after start likely means port bind failure
                    if proc.terminationStatus != 0 && self.connectionHint == nil {
                        self.connectionHint = "Port \(mapping.local) may be in use by another app"
                    }
                }
            }

            // Log iproxy output and detect connection issues
            pipe.fileHandleForReading.readabilityHandler = { [weak self] fileHandle in
                let data = fileHandle.availableData
                guard !data.isEmpty, let output = String(data: data, encoding: .utf8) else { return }
                for line in output.components(separatedBy: "\n") where !line.isEmpty {
                    log.info("iproxy[\(mapping.local)]: \(line)")
                    let lower = line.lowercased()
                    if lower.contains("address already in use") || lower.contains("bind failed") || lower.contains("could not bind") {
                        DispatchQueue.main.async {
                            self?.connectionHint = "Port \(mapping.local) is in use by another app"
                        }
                    } else if lower.contains("connection refused") || lower.contains("error connecting") {
                        DispatchQueue.main.async {
                            self?.connectionHint = "🔒 Unlock your iPhone to continue"
                        }
                    } else if lower.contains("accepted") || lower.contains("connected") {
                        DispatchQueue.main.async {
                            self?.connectionHint = nil
                        }
                    }
                }
            }

            log.info("USBTunnel: starting iproxy \(mapping.local):\(mapping.remote) udid=\(udid ?? "none")")
            try process.run()
            log.info("USBTunnel: iproxy started (pid: \(process.processIdentifier))")
            processes.append(process)
        }

        self.isActive = true
    }

    func stop() {
        for process in processes {
            if process.isRunning {
                process.terminate()
            }
        }
        processes.removeAll()
        isActive = false
    }

    /// Kills any existing iproxy processes that may be holding our ports.
    private func killStaleIproxy(ports: [Int]) {
        for port in ports {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = ["lsof", "-ti", ":\(port)"]
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = Pipe()
            try? process.run()
            process.waitUntilExit()

            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            guard let output = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !output.isEmpty else { continue }

            for pidStr in output.components(separatedBy: "\n") {
                if let pid = Int32(pidStr.trimmingCharacters(in: .whitespaces)) {
                    log.info("USBTunnel: killing stale process on port \(port) (pid: \(pid))")
                    kill(pid, SIGTERM)
                }
            }
        }
        // Brief wait for ports to free up
        usleep(200_000)
    }

    deinit {
        stop()
    }
}

enum USBTunnelError: Error, LocalizedError {
    case iproxyNotFound

    var errorDescription: String? {
        switch self {
        case .iproxyNotFound:
            return "iproxy not found. The bundled copy is missing and it's not installed via Homebrew."
        }
    }
}
