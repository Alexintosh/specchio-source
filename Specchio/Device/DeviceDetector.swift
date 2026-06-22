import Foundation
import os.log

private let log = SpecchioLogger.autoLaunch

struct DetectedDevice {
    let name: String
    let udid: String
}

struct DeviceDetector {
    /// Runs `xcrun xctrace list devices` and parses physical iOS devices.
    static func detectDevices() async throws -> [DetectedDevice] {
        let result = try await ProcessRunner.run("xcrun", arguments: ["xctrace", "list", "devices"], timeout: 10)

        guard result.exitCode == 0 else {
            throw DeviceDetectorError.xctraceNotFound
        }

        log.info("DeviceDetector: raw xctrace output:\n\(result.output)")
        return parseDevices(from: result.output)
    }

    /// Parses xctrace output. Physical devices appear before the "== Simulators ==" line.
    /// Format: "Device Name (OS Version) (UDID)"
    static func parseDevices(from output: String) -> [DetectedDevice] {
        var devices: [DetectedDevice] = []
        var inSimulators = false
        for line in output.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if trimmed.contains("Simulator") && trimmed.hasPrefix("==") {
                inSimulators = true
                continue
            }

            if trimmed.hasPrefix("== Devices ==") {
                continue
            }

            if inSimulators { continue }
            if trimmed.isEmpty || trimmed.hasPrefix("==") { continue }

            // Match: "Name (version) (UDID)" where UDID is hex+hyphens
            if let device = parseDeviceLine(trimmed) {
                // Filter out Macs and Apple Watches — only keep iPhones/iPads
                // iOS device UDIDs typically start with "0000" (e.g., 00008150-...)
                // Mac UDIDs are standard UUIDs (e.g., 74AAF3A8-03EF-...)
                // Apple Watch UDIDs also start with "0000" but contain "Apple Watch" in name
                let lowerName = device.name.lowercased()
                let isMac = lowerName.contains("mac") || !device.udid.hasPrefix("0000")
                let isWatch = lowerName.contains("watch")

                if isMac || isWatch {
                    log.info("DeviceDetector: skipping non-iPhone: \(device.name) (\(device.udid))")
                    continue
                }

                devices.append(device)
            }
        }

        return devices
    }

    /// Parses a single line like "iPhone 15 Pro (17.4) (00008120-XXXXXXXXXXXX)"
    private static func parseDeviceLine(_ line: String) -> DetectedDevice? {
        // UDID is the last parenthesized group, containing hex chars and hyphens
        guard let lastOpen = line.lastIndex(of: "("),
              let lastClose = line.lastIndex(of: ")"),
              lastOpen < lastClose else { return nil }

        let udid = String(line[line.index(after: lastOpen)..<lastClose])

        // UDID must be hex+hyphens, at least 20 chars
        let udidChars = CharacterSet(charactersIn: "0123456789abcdefABCDEF-")
        guard udid.count >= 20,
              udid.unicodeScalars.allSatisfy({ udidChars.contains($0) }) else {
            return nil
        }

        // Name is everything before the second-to-last "("
        let beforeUDID = line[line.startIndex..<lastOpen].trimmingCharacters(in: .whitespaces)
        // Strip trailing "(version)" if present
        let name: String
        if let versionOpen = beforeUDID.lastIndex(of: "(") {
            name = String(beforeUDID[beforeUDID.startIndex..<versionOpen]).trimmingCharacters(in: .whitespaces)
        } else {
            name = beforeUDID
        }

        guard !name.isEmpty else { return nil }

        return DetectedDevice(name: name, udid: udid)
    }
}

enum DeviceDetectorError: Error, LocalizedError {
    case xctraceNotFound
    case noDeviceFound

    var errorDescription: String? {
        switch self {
        case .xctraceNotFound: return "Xcode command line tools not found. Install Xcode."
        case .noDeviceFound: return "No iOS device connected via USB."
        }
    }
}
