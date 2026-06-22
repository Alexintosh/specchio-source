import Foundation
import AppKit
import os.log

private let log = Logger(subsystem: Bundle.main.bundleIdentifier ?? "Specchio", category: "DependencyChecker")

@MainActor
class DependencyChecker: ObservableObject {
    struct Status {
        var xcodeToolsInstalled: Bool
        var iproxyAvailable: Bool
        var iproxyPath: String?
    }

    @Published var status = Status(xcodeToolsInstalled: false, iproxyAvailable: false)

    /// Returns the path to iproxy, preferring the bundled copy.
    nonisolated static func iproxyPath() -> String? {
        // 1. Bundled copy inside app bundle
        if let bundled = bundledToolPath("iproxy"), FileManager.default.fileExists(atPath: bundled) {
            return bundled
        }
        // 2. Fall back to system PATH
        return findInPath("iproxy")
    }

    /// Returns the path to idevice_id when libimobiledevice is installed.
    nonisolated static func ideviceIDPath() -> String? {
        if let bundled = bundledToolPath("idevice_id"), FileManager.default.fileExists(atPath: bundled) {
            return bundled
        }
        return findInPath("idevice_id")
    }

    /// Returns the path to a tool bundled in the app's Resources/BundledTools directory.
    nonisolated static func bundledToolPath(_ tool: String) -> String? {
        guard let resourcePath = Bundle.main.resourcePath else { return nil }
        let path = (resourcePath as NSString).appendingPathComponent("BundledTools/\(tool)")
        return path
    }

    /// Searches PATH for an executable.
    nonisolated private static func findInPath(_ name: String) -> String? {
        let pathDirs = (ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/usr/local/bin")
            .components(separatedBy: ":")
        // Also check common Homebrew locations
        let extraDirs = ["/opt/homebrew/bin", "/usr/local/bin"]
        for dir in pathDirs + extraDirs {
            let fullPath = (dir as NSString).appendingPathComponent(name)
            if FileManager.default.isExecutableFile(atPath: fullPath) {
                return fullPath
            }
        }
        return nil
    }

    /// Checks if Xcode command line tools are installed.
    nonisolated static func isXcodeToolsInstalled() -> Bool {
        FileManager.default.fileExists(atPath: "/usr/bin/xcrun")
    }

    /// Returns the active developer directory from `xcode-select -p`.
    nonisolated static func developerDirectory() -> String? {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/xcode-select")
        proc.arguments = ["-p"]
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = Pipe()
        try? proc.run()
        proc.waitUntilExit()
        guard proc.terminationStatus == 0 else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    struct DiagnosticError: Error {
        let detail: String
    }

    /// Checks if Xcode CLI tools are functional (license accepted, tools configured).
    /// Returns `.success(true)` if ready, or `.failure` with diagnostic detail
    /// that can be shown in the UI so testers can screenshot it.
    nonisolated static func checkXcodeCli() -> Result<Bool, DiagnosticError> {
        let devDir = developerDirectory()

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        proc.arguments = ["--find", "xcodebuild"]
        if let devDir, !devDir.isEmpty {
            proc.environment = ProcessInfo.processInfo.environment.merging(
                ["DEVELOPER_DIR": devDir], uniquingKeysWith: { _, new in new }
            )
        }
        let stdoutPipe = Pipe()
        proc.standardOutput = stdoutPipe
        let stderrPipe = Pipe()
        proc.standardError = stderrPipe
        try? proc.run()
        proc.waitUntilExit()

        if proc.terminationStatus == 0 { return .success(true) }

        let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
        let stderr = String(data: stderrData, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        // Fallback: check if xcodebuild exists directly under the developer dir
        if let devDir {
            let directPath = (devDir as NSString).appendingPathComponent("usr/bin/xcodebuild")
            if FileManager.default.isExecutableFile(atPath: directPath) {
                return .success(true)
            }
        }

        let devDirInfo = devDir ?? "<not set>"
        let detail = "xcrun exit \(proc.terminationStatus) | DEVELOPER_DIR: \(devDirInfo) | \(stderr)"
        log.warning("checkXcodeCli failed: \(detail)")
        return .failure(DiagnosticError(detail: detail))
    }

    /// Simple boolean wrapper for backward compatibility.
    nonisolated static func isXcodeCliReady() -> Bool {
        switch checkXcodeCli() {
        case .success: return true
        case .failure: return false
        }
    }

    /// Checks if the iOS platform SDK is installed in Xcode.
    nonisolated static func isIOSPlatformInstalled() -> Bool {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        proc.arguments = ["xcodebuild", "-showsdks"]
        if let devDir = developerDirectory() {
            proc.environment = ProcessInfo.processInfo.environment.merging(
                ["DEVELOPER_DIR": devDir], uniquingKeysWith: { _, new in new }
            )
        }
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = Pipe()
        try? proc.run()
        proc.waitUntilExit()
        guard proc.terminationStatus == 0 else { return false }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        guard let output = String(data: data, encoding: .utf8) else { return false }
        return output.contains("iphoneos")
    }

    /// Checks if the full Xcode.app is installed (not just CLI tools).
    /// Required for build-for-testing which needs the iOS SDK.
    nonisolated static func isXcodeAppInstalled() -> Bool {
        guard let path = developerDirectory() else { return false }
        return path.contains("Xcode.app")
    }

    /// Prompts the user to install Xcode command line tools via the system dialog.
    nonisolated static func promptInstallXcodeTools() {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xcode-select")
        process.arguments = ["--install"]
        try? process.run()
    }

    /// Refreshes all dependency status checks.
    func checkAll() {
        let xcodeOK = Self.isXcodeToolsInstalled()
        let iproxyResult = Self.iproxyPath()
        status = Status(
            xcodeToolsInstalled: xcodeOK,
            iproxyAvailable: iproxyResult != nil,
            iproxyPath: iproxyResult
        )
    }
}
