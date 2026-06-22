import Foundation
import Combine
import os.log

private let log = SpecchioLogger.autoLaunch

/// Builds and installs the Specchio Companion app onto the connected iOS device.
/// Mirrors WDALauncher patterns but is best-effort — failure is non-fatal.
@MainActor
class KeyboardExtLauncher: ObservableObject {
    enum State: Equatable {
        case idle
        case building
        case installing
        case installed
        case failed(String)
    }

    @Published var state: State = .idle

    // MARK: - Build Cache

    private static var cacheDirectory: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return appSupport.appendingPathComponent("Specchio/KeyboardExtBuild", isDirectory: true)
    }

    private static var derivedDataPath: URL {
        cacheDirectory.appendingPathComponent("DerivedData", isDirectory: true)
    }

    private static var cacheKeyFile: URL {
        cacheDirectory.appendingPathComponent("cache_key.txt")
    }

    /// Path to the bundled SpecchioKeyboard project inside app resources
    static var bundledProjectPath: String? {
        guard let resourcePath = Bundle.main.resourcePath else { return nil }
        let projectPath = (resourcePath as NSString).appendingPathComponent("SpecchioKeyboard/SpecchioKeyboard.xcodeproj")
        guard FileManager.default.fileExists(atPath: projectPath) else { return nil }
        return projectPath
    }

    // MARK: - Public API

    /// Build and install the keyboard extension app. Best-effort — logs errors but doesn't throw.
    func buildAndInstall(udid: String) async {
        guard state != .building && state != .installing else {
            log.info("KeyboardExtLauncher: already active, skipping")
            return
        }

        guard let projectPath = Self.bundledProjectPath else {
            log.info("KeyboardExtLauncher: bundled SpecchioKeyboard not found — skipping")
            return
        }

        state = .building
        log.info("KeyboardExtLauncher: starting build for device \(udid)")

        do {
            let appPath = try await buildApp(projectPath: projectPath)
            state = .installing
            try await installApp(appPath: appPath, udid: udid)
            state = .installed
            log.info("KeyboardExtLauncher: companion app installed successfully")
        } catch {
            log.warning("KeyboardExtLauncher: failed (non-fatal): \(error.localizedDescription)")
            state = .failed(error.localizedDescription)
        }
    }

    // MARK: - Build

    private func buildApp(projectPath: String) async throws -> String {
        let teams = Self.detectDevelopmentTeams()
        guard !teams.isEmpty else {
            throw KeyboardExtError.noSigningTeam
        }

        var lastError: Error?
        for team in teams {
            log.info("KeyboardExtLauncher: trying build with team \(team)")
            do {
                let appPath = try await buildWithTeam(projectPath: projectPath, team: team)
                return appPath
            } catch {
                log.warning("KeyboardExtLauncher: build failed with team \(team): \(error.localizedDescription)")
                lastError = error
                // Clean derived data before retrying
                try? FileManager.default.removeItem(at: Self.derivedDataPath)
            }
        }
        throw lastError!
    }

    private func buildWithTeam(projectPath: String, team: String) async throws -> String {
        let derivedData = Self.derivedDataPath.path

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        proc.arguments = [
            "xcrun", "xcodebuild",
            "build",
            "-project", projectPath,
            "-scheme", "Specchio Companion",
            "-destination", "generic/platform=iOS",
            "-derivedDataPath", derivedData,
            "-allowProvisioningUpdates",
            "DEVELOPMENT_TEAM=\(team)",
        ]

        log.info("KeyboardExtLauncher: xcodebuild = \(proc.arguments!.joined(separator: " "))")

        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = pipe
        monitorOutput(pipe: pipe)

        try proc.run()
        log.info("KeyboardExtLauncher: build started (pid: \(proc.processIdentifier))")

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            proc.terminationHandler = { process in
                if process.terminationStatus == 0 {
                    log.info("KeyboardExtLauncher: build succeeded with team \(team)")
                    continuation.resume()
                } else {
                    let msg = "xcodebuild exited with code \(process.terminationStatus)"
                    log.error("KeyboardExtLauncher: build failed — \(msg)")
                    continuation.resume(throwing: KeyboardExtError.buildFailed(msg))
                }
            }
        }

        // Find the .app bundle in Build/Products
        let productsDir = Self.derivedDataPath.appendingPathComponent("Build/Products")
        let fm = FileManager.default
        guard let configs = try? fm.contentsOfDirectory(at: productsDir, includingPropertiesForKeys: nil) else {
            throw KeyboardExtError.buildFailed("Build products directory not found")
        }

        // Look in Release-iphoneos or Debug-iphoneos
        for config in configs {
            let appDir = config.appendingPathComponent("Specchio Companion.app")
            if fm.fileExists(atPath: appDir.path) {
                return appDir.path
            }
        }

        throw KeyboardExtError.buildFailed("Specchio Companion.app not found in build products")
    }

    // MARK: - Install

    private func installApp(appPath: String, udid: String) async throws {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        proc.arguments = [
            "xcrun", "devicectl", "device", "install", "app",
            "--device", udid,
            appPath,
        ]

        log.info("KeyboardExtLauncher: install = \(proc.arguments!.joined(separator: " "))")

        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = pipe

        try proc.run()
        log.info("KeyboardExtLauncher: install started (pid: \(proc.processIdentifier))")

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            proc.terminationHandler = { process in
                if process.terminationStatus == 0 {
                    log.info("KeyboardExtLauncher: install succeeded")
                    continuation.resume()
                } else {
                    let msg = "devicectl exited with code \(process.terminationStatus)"
                    log.error("KeyboardExtLauncher: install failed — \(msg)")
                    continuation.resume(throwing: KeyboardExtError.installFailed(msg))
                }
            }
        }
    }

    // MARK: - Output Monitoring

    private func monitorOutput(pipe: Pipe) {
        let handle = pipe.fileHandleForReading
        handle.readabilityHandler = { fileHandle in
            let data = fileHandle.availableData
            guard !data.isEmpty else {
                fileHandle.readabilityHandler = nil
                return
            }
            if let output = String(data: data, encoding: .utf8) {
                for line in output.components(separatedBy: "\n") where !line.isEmpty {
                    log.info("KeyboardExt xcodebuild: \(line)")
                }
            }
        }
    }

    // MARK: - Team Detection (reuses WDALauncher pattern)

    nonisolated private static func detectDevelopmentTeams() -> [String] {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        proc.arguments = ["security", "find-certificate", "-a", "-c", "Apple Development", "-p"]
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = Pipe()
        try? proc.run()
        proc.waitUntilExit()

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        guard let allPEM = String(data: data, encoding: .utf8), !allPEM.isEmpty else { return [] }

        var teams = Set<String>()
        let certs = allPEM.components(separatedBy: "-----END CERTIFICATE-----")
        for certChunk in certs {
            let pem = certChunk + "-----END CERTIFICATE-----"
            guard pem.contains("-----BEGIN CERTIFICATE-----") else { continue }

            let ssl = Process()
            ssl.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            ssl.arguments = ["openssl", "x509", "-noout", "-subject"]
            let sslIn = Pipe()
            let sslOut = Pipe()
            ssl.standardInput = sslIn
            ssl.standardOutput = sslOut
            ssl.standardError = Pipe()
            try? ssl.run()
            sslIn.fileHandleForWriting.write(Data(pem.utf8))
            sslIn.fileHandleForWriting.closeFile()
            ssl.waitUntilExit()

            let subjectData = sslOut.fileHandleForReading.readDataToEndOfFile()
            guard let subject = String(data: subjectData, encoding: .utf8) else { continue }

            if let range = subject.range(of: #"OU\s*=\s*([A-Z0-9]+)"#, options: .regularExpression) {
                let teamID = subject[range]
                    .components(separatedBy: "=").last?
                    .trimmingCharacters(in: .whitespaces) ?? ""
                if !teamID.isEmpty {
                    teams.insert(teamID)
                }
            }
        }

        return Array(teams)
    }
}

// MARK: - Errors

enum KeyboardExtError: Error, LocalizedError {
    case noSigningTeam
    case buildFailed(String)
    case installFailed(String)

    var errorDescription: String? {
        switch self {
        case .noSigningTeam:
            return "No Apple Development certificate found for keyboard extension build."
        case .buildFailed(let msg):
            return "Keyboard extension build failed: \(msg)"
        case .installFailed(let msg):
            return "Keyboard extension install failed: \(msg)"
        }
    }
}
