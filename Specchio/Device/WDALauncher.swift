import Foundation
import Combine
import os.log

private let log = SpecchioLogger.autoLaunch

@MainActor
class WDALauncher: ObservableObject {
    enum State: Equatable {
        case idle
        case building       // First-time build in progress
        case launching      // test-without-building running
        case running
        case failed(String)
    }

    @Published var state: State = .idle
    /// Last meaningful xcodebuild activity (e.g. "Compiling FBSession.swift")
    @Published var buildActivity: String = ""
    /// True when doing a first-time build (no cache)
    @Published var isFirstBuild: Bool = false

    private var process: Process?
    private var outputPipe: Pipe?
    private var lastBuildOutput: String = ""

    private static let lockedKeychainMessage = "Login keychain is locked. Unlock it in Keychain Access or by logging back into macOS, then retry Dev Mode."

    /// Primary entry point: uses bundled WDA + build cache.
    /// First connect: build-for-testing → test-without-building (~60s).
    /// Subsequent connects: test-without-building only (~5s).
    func launchWithCache(udid: String) async throws {
        guard state != .building && state != .launching && state != .running else {
            log.info("WDALauncher: already active, skipping")
            return
        }

        guard let wdaProjectPath = WDABuildCache.bundledWDAProjectPath else {
            state = .failed("Bundled WebDriverAgent not found in app resources")
            throw WDALauncherError.workspaceNotFound
        }

        killStaleXcodebuild()
        buildActivity = ""

        if WDABuildCache.isCacheValid(), let xctestrun = WDABuildCache.findXCTestRun() {
            // Fast path: cached artifacts exist
            log.info("WDALauncher: using cached build artifacts")
            isFirstBuild = false
            state = .launching
            try runTestWithoutBuilding(xctestrunPath: xctestrun.path, udid: udid)
        } else {
            // Slow path: build first, then run
            log.info("WDALauncher: cache miss — cleaning stale DerivedData and rebuilding")
            WDABuildCache.invalidate()
            isFirstBuild = true
            state = .building

            do {
                try await buildForTesting(projectPath: wdaProjectPath, udid: udid)
            } catch {
                state = .failed(error.localizedDescription)
                throw error
            }
            WDABuildCache.writeCacheKey()

            guard let xctestrun = WDABuildCache.findXCTestRun() else {
                state = .failed("Build succeeded but .xctestrun file not found")
                throw WDALauncherError.buildRequired
            }

            state = .launching
            try runTestWithoutBuilding(xctestrunPath: xctestrun.path, udid: udid)
        }
    }

    /// Legacy entry point for manually-configured WDA path.
    func launch(udid: String, workspacePath: String) async throws {
        guard state != .launching && state != .running else {
            log.info("WDALauncher: already launching/running, skipping")
            return
        }

        guard FileManager.default.fileExists(atPath: workspacePath) else {
            log.error("WDALauncher: project not found at: \(workspacePath)")
            state = .failed("WebDriverAgent project not found at: \(workspacePath)")
            throw WDALauncherError.workspaceNotFound
        }

        state = .launching
        buildActivity = ""
        killStaleXcodebuild()

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        var args = ["xcrun", "xcodebuild", "test"]
        if workspacePath.hasSuffix(".xcworkspace") {
            args += ["-workspace", workspacePath]
        } else {
            args += ["-project", workspacePath]
        }
        args += [
            "-scheme", "WebDriverAgentRunner",
            "-destination", "id=\(udid)",
            "-allowProvisioningUpdates",
            "-allowProvisioningDeviceRegistration",
        ]
        process.arguments = args

        log.info("WDALauncher: command = /usr/bin/env \(args.joined(separator: " "))")

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        let inputPipe = Pipe()
        process.standardInput = inputPipe

        process.terminationHandler = { [weak self] proc in
            log.info("WDALauncher: process terminated with code \(proc.terminationStatus)")
            DispatchQueue.main.async {
                guard let self = self else { return }
                if self.state == .launching || self.state == .running {
                    if proc.terminationStatus != 0 && proc.terminationStatus != 15 {
                        let msg = Self.describeExitCode(proc.terminationStatus, buildOutput: self.lastBuildOutput)
                        log.error("WDALauncher: \(msg)")
                        self.state = .failed(msg)
                    } else {
                        self.state = .idle
                    }
                }
            }
        }

        self.process = process
        self.outputPipe = pipe

        do {
            try process.run()
            inputPipe.fileHandleForWriting.closeFile()
            log.info("WDALauncher: process started (pid: \(process.processIdentifier))")
        } catch {
            log.error("WDALauncher: failed to start process: \(error.localizedDescription)")
            state = .failed("Failed to start xcodebuild: \(error.localizedDescription)")
            throw WDALauncherError.launchFailed(error.localizedDescription)
        }

        monitorOutput(pipe: pipe)
    }

    func stop() {
        if let process = process, process.isRunning {
            log.info("WDALauncher: terminating process (pid: \(process.processIdentifier))")
            process.terminate()
        }
        process = nil
        outputPipe = nil
        state = .idle
        buildActivity = ""
    }

    // MARK: - Build Cache Flow

    /// Returns true if at least one Apple Development signing certificate exists in the keychain.
    nonisolated static func hasSigningCertificate() -> Bool {
        !detectAllTeamIDs().isEmpty
    }

    /// Detects team IDs from Xcode's provisioning profiles.
    /// These are created by Xcode's account system and contain the actual team IDs
    /// that xcodebuild can use — not certificate metadata which can be stale/wrong.
    /// Returns nil if no provisioning profiles exist (no Xcode account or never built).
    nonisolated static func detectXcodeAccountTeam() -> String? {
        let profilesDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Developer/Xcode/UserData/Provisioning Profiles")

        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: profilesDir,
            includingPropertiesForKeys: [.contentModificationDateKey]
        ) else {
            log.info("WDALauncher: no provisioning profiles directory found")
            return nil
        }

        let profiles = contents.filter { $0.pathExtension == "mobileprovision" }
            .sorted {
                let d1 = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                let d2 = (try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                return d1 > d2
            }

        guard let newest = profiles.first else {
            log.info("WDALauncher: no .mobileprovision files found")
            return nil
        }

        // Decode the CMS-signed plist and extract TeamIdentifier
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        proc.arguments = ["security", "cms", "-D", "-i", newest.path]
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = Pipe()
        try? proc.run()
        proc.waitUntilExit()

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        guard let plist = String(data: data, encoding: .utf8) else { return nil }

        // Parse TeamIdentifier array from the plist XML
        // <key>TeamIdentifier</key>
        // <array>
        //     <string>5297SX54T2</string>
        // </array>
        var teams = Set<String>()
        var inTeamArray = false
        for line in plist.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed == "<key>TeamIdentifier</key>" {
                inTeamArray = true
                continue
            }
            if inTeamArray {
                if trimmed == "</array>" { inTeamArray = false; continue }
                if trimmed.hasPrefix("<string>") && trimmed.hasSuffix("</string>") {
                    let team = trimmed
                        .replacingOccurrences(of: "<string>", with: "")
                        .replacingOccurrences(of: "</string>", with: "")
                    if !team.isEmpty && team.count >= 10 {
                        teams.insert(team)
                    }
                }
            }
        }

        let result = teams.first
        if let team = result {
            log.info("WDALauncher: provisioning profile team = \(team) (from \(newest.lastPathComponent))")
        } else {
            log.info("WDALauncher: could not extract TeamIdentifier from provisioning profile")
        }
        return result
    }

    /// Detects all available team IDs.
    /// Priority: Xcode account team first, then certificate-based detection as fallback.
    nonisolated static func detectAllTeamIDs() -> [String] {
        // Source 0: Ask Xcode directly what team it will use
        if let xcodeTeam = detectXcodeAccountTeam() {
            // Xcode knows its team — put it first, add cert-based teams as fallbacks
            var teams = [xcodeTeam]
            let certTeams = detectCertificateTeams()
            for team in certTeams where team != xcodeTeam {
                teams.append(team)
            }
            log.info("WDALauncher: detected teams (Xcode primary): \(teams)")
            return teams
        }

        // Fallback: certificate-based detection
        let teams = detectCertificateTeams()
        log.info("WDALauncher: detected teams (cert-only fallback): \(teams)")
        return teams
    }

    /// Certificate-based team detection (fallback when Xcode account is unavailable).
    nonisolated static func detectCertificateTeams() -> [String] {
        var teams = Set<String>()

        // OU from certificates
        let ouTeams = detectDevelopmentTeams()
        teams.formUnion(ouTeams)

        // security find-identity
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        proc.arguments = ["security", "find-identity", "-v", "-p", "codesigning"]
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = Pipe()
        try? proc.run()
        proc.waitUntilExit()

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        if let output = String(data: data, encoding: .utf8) {
            let pattern = #/\(([A-Z0-9]+)\)/#
            for line in output.components(separatedBy: "\n") {
                if let match = line.firstMatch(of: pattern) {
                    let teamID = String(match.1)
                    if !teamID.isEmpty && teamID.count >= 10 {
                        teams.insert(teamID)
                    }
                }
            }
        }

        return Array(teams)
    }

    /// Detects signing teams with human-readable certificate names.
    /// Returns tuples of (teamID, certName) from `security find-identity`.
    nonisolated static func detectTeamNames() -> [(teamID: String, certName: String)] {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        proc.arguments = ["security", "find-identity", "-v", "-p", "codesigning"]
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = Pipe()
        try? proc.run()
        proc.waitUntilExit()

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        guard let output = String(data: data, encoding: .utf8) else { return [] }

        var results: [(teamID: String, certName: String)] = []
        // Parse lines like: 1) 6428... "Apple Development: user@email.com (N486N3Z6J7)"
        let linePattern = try? NSRegularExpression(pattern: "\"Apple Development:\\s*([^\"]+?)\\s*\\(([A-Z0-9]+)\\)\"")
        for line in output.components(separatedBy: "\n") {
            guard let match = linePattern?.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)),
                  let nameRange = Range(match.range(at: 1), in: line),
                  let teamRange = Range(match.range(at: 2), in: line) else { continue }
            let name = String(line[nameRange]).trimmingCharacters(in: .whitespaces)
            let teamID = String(line[teamRange])
            if !teamID.isEmpty && teamID.count >= 10 {
                results.append((teamID: teamID, certName: name))
            }
        }
        log.info("WDALauncher: detected team names: \(results.map { "\($0.teamID) (\($0.certName))" })")
        return results
    }

    /// Detects available Apple Development team IDs from the keychain.
    /// Extracts the OU (Organizational Unit) from each certificate — that's the real team ID.
    nonisolated static func detectDevelopmentTeams() -> [String] {
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

        // Split concatenated PEM certs and extract OU from each
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

        let result = Array(teams)
        log.info("WDALauncher: detected development teams: \(result)")
        return result
    }

    /// Runs `xcodebuild build-for-testing` and waits for completion.
    /// Tries persisted team first, then detected teams until one succeeds.
    private func buildForTesting(projectPath: String, udid: String) async throws {
        let persistedTeam = UserDefaults.standard.string(forKey: "selectedTeamID") ?? ""
        let detectedTeams = Self.detectAllTeamIDs()

        // Build the team list: persisted first, then the rest
        var teams: [String] = []
        if !persistedTeam.isEmpty {
            teams.append(persistedTeam)
        }
        for team in detectedTeams where team != persistedTeam {
            teams.append(team)
        }

        guard !teams.isEmpty else {
            log.error("WDALauncher: no Apple Development certificate found in keychain")
            state = .failed("No Apple Development certificate found. Open Xcode → Settings → Accounts → Manage Certificates → + → Apple Development.")
            throw WDALauncherError.launchFailed("No signing certificate")
        }

        log.info("WDALauncher: will try teams in order: \(teams)")

        // Clear build log once at the start — all team attempts accumulate in the same log
        lastBuildOutput = ""
        WDABuildCache.clearBuildLog()
        WDABuildCache.appendBuildLog("=== WDA Build: will try teams \(teams.joined(separator: ", ")) ===")

        var lastError: Error?
        for (index, team) in teams.enumerated() {
            if index > 0 {
                WDABuildCache.appendBuildLog("")
                WDABuildCache.appendBuildLog("=== Retrying with team \(team) ===")
                WDABuildCache.clearDerivedData()
            }
            log.info("WDALauncher: trying build with team \(team)")
            do {
                try await buildForTestingWithTeam(projectPath: projectPath, team: team, udid: udid)
                // Success — persist this team for next time
                UserDefaults.standard.set(team, forKey: "selectedTeamID")
                log.info("WDALauncher: persisted working team: \(team)")
                return
            } catch {
                WDABuildCache.appendBuildLog("=== Team \(team) failed: \(error.localizedDescription) ===")
                log.warning("WDALauncher: build failed with team \(team): \(error.localizedDescription)")
                lastError = error
            }
        }

        throw lastError!
    }

    private func buildForTestingWithTeam(projectPath: String, team: String, udid: String) async throws {
        lastBuildOutput = ""
        let derivedDataPath = WDABuildCache.derivedDataPath.path

        // Do not run `security unlock-keychain` here: without a password it
        // prompts on stdin and can leave the app stuck behind an invisible CLI prompt.
        log.info("WDALauncher: keychain unlock preflight skipped branch=avoid-interactive-security-prompt")

        // Use specific device destination for provisioning, fall back to generic if no UDID
        let destination = udid.isEmpty ? "generic/platform=iOS" : "id=\(udid)"

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        proc.arguments = [
            "xcrun", "xcodebuild",
            "build-for-testing",
            "-project", projectPath,
            "-scheme", "WebDriverAgentRunner",
            "-destination", destination,
            "-derivedDataPath", derivedDataPath,
            "-allowProvisioningUpdates",
            "-allowProvisioningDeviceRegistration",
            "DEVELOPMENT_TEAM=\(team)",
            "PRODUCT_BUNDLE_IDENTIFIER=com.specchio.wda.\(team)",
        ]

        log.info("WDALauncher: build-for-testing = \(proc.arguments!.joined(separator: " "))")

        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = pipe
        let inputPipe = Pipe()
        proc.standardInput = inputPipe
        self.process = proc
        self.outputPipe = pipe
        monitorOutput(pipe: pipe)

        do {
            try proc.run()
            inputPipe.fileHandleForWriting.closeFile()
            log.info("WDALauncher: build-for-testing started (pid: \(proc.processIdentifier))")
        } catch {
            throw WDALauncherError.launchFailed(error.localizedDescription)
        }

        // Wait for build completion
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            proc.terminationHandler = { process in
                Task { @MainActor in
                    let buildOutput = self.lastBuildOutput
                    if process.terminationStatus == 0 {
                        log.info("WDALauncher: build-for-testing succeeded with team \(team)")
                        continuation.resume()
                    } else {
                        let msg = Self.describeExitCode(process.terminationStatus, buildOutput: buildOutput, team: team)
                        log.error("WDALauncher: build-for-testing failed with team \(team) — \(msg)")
                        continuation.resume(throwing: WDALauncherError.launchFailed(msg))
                    }
                }
            }
        }
    }

    /// Runs `xcodebuild test-without-building` (long-running, keeps WDA alive on device).
    private func runTestWithoutBuilding(xctestrunPath: String, udid: String) throws {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        proc.arguments = [
            "xcrun", "xcodebuild",
            "test-without-building",
            "-xctestrun", xctestrunPath,
            "-destination", "id=\(udid)",
        ]

        log.info("WDALauncher: test-without-building = \(proc.arguments!.joined(separator: " "))")

        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = pipe
        let inputPipe = Pipe()
        proc.standardInput = inputPipe

        proc.terminationHandler = { [weak self] process in
            log.info("WDALauncher: test-without-building terminated with code \(process.terminationStatus)")
            DispatchQueue.main.async {
                guard let self = self else { return }
                if self.state == .launching || self.state == .running {
                    if process.terminationStatus != 0 && process.terminationStatus != 15 {
                        let msg = Self.describeExitCode(process.terminationStatus, buildOutput: self.lastBuildOutput)
                        log.error("WDALauncher: \(msg)")
                        // Stale cache may be the cause — invalidate for next attempt
                        WDABuildCache.invalidate()
                        self.state = .failed(msg)
                    } else {
                        self.state = .idle
                    }
                }
            }
        }

        self.process = proc
        self.outputPipe = pipe

        try proc.run()
        inputPipe.fileHandleForWriting.closeFile()
        log.info("WDALauncher: test-without-building started (pid: \(proc.processIdentifier))")
        monitorOutput(pipe: pipe)
    }

    // MARK: - Output Monitoring

    private func monitorOutput(pipe: Pipe) {
        let handle = pipe.fileHandleForReading
        handle.readabilityHandler = { [weak self] fileHandle in
            let data = fileHandle.availableData
            guard !data.isEmpty else {
                fileHandle.readabilityHandler = nil
                return
            }
            if let output = String(data: data, encoding: .utf8) {
                for line in output.components(separatedBy: "\n") where !line.isEmpty {
                    log.info("xcodebuild: \(line)")
                    WDABuildCache.appendBuildLog(line)
                    DispatchQueue.main.async {
                        self?.lastBuildOutput += line + "\n"
                    }
                    if let activity = Self.extractBuildActivity(from: line) {
                        DispatchQueue.main.async {
                            self?.buildActivity = activity
                        }
                    }
                    if Self.isKeychainInteractionPrompt(line) {
                        log.error("WDALauncher: detected interactive keychain prompt; terminating xcodebuild branch=locked-keychain")
                        DispatchQueue.main.async {
                            self?.buildActivity = "Keychain unlock required"
                            if self?.state != .building {
                                self?.state = .failed(Self.lockedKeychainMessage)
                            }
                            self?.process?.terminate()
                        }
                    }
                }
                if output.contains("ServerURLHere") {
                    log.info("WDALauncher: detected ServerURLHere — WDA is ready")
                    DispatchQueue.main.async {
                        self?.state = .running
                    }
                }
            }
        }
    }

    // MARK: - Helpers

    private func killStaleXcodebuild() {
        let findProc = Process()
        findProc.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        findProc.arguments = ["pgrep", "-f", "xcodebuild.*WebDriverAgentRunner"]
        let pipe = Pipe()
        findProc.standardOutput = pipe
        findProc.standardError = Pipe()
        try? findProc.run()
        findProc.waitUntilExit()

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        guard let output = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !output.isEmpty else { return }

        for pidStr in output.components(separatedBy: "\n") {
            if let pid = Int32(pidStr.trimmingCharacters(in: .whitespaces)) {
                log.info("WDALauncher: killing stale xcodebuild (pid: \(pid))")
                kill(pid, SIGTERM)
            }
        }
        usleep(500_000)
    }

    /// Maps xcodebuild exit codes to human-readable error messages.
    nonisolated private static func describeExitCode(_ code: Int32, buildOutput: String? = nil, team: String? = nil) -> String {
        let teamLabel = team.map { " (team \($0))" } ?? ""
        if let output = buildOutput, let diagnosis = diagnoseBuildFailure(output) {
            return diagnosis + teamLabel
        }

        switch code {
        case 65:
            // EX_DATAERR — xcodebuild's generic "test/build failed" code.
            // Could be signing, provisioning, device trust, or stale cache.
            return "WDA install failed (code 65)\(teamLabel). Retry — if the problem persists, check Xcode signing and device trust."
        case 70:
            return "iOS platform not installed. Open Xcode \u{2192} Settings \u{2192} Components \u{2192} iOS \u{2192} Install."
        case 72:
            return "Xcode license not accepted. Open Xcode and accept the license agreement."
        default:
            return "xcodebuild exited with code \(code)."
        }
    }

    /// Parses build output to provide specific error diagnostics for code 65 failures.
    nonisolated private static func diagnoseBuildFailure(_ output: String) -> String? {
        if output.components(separatedBy: "\n").contains(where: Self.isKeychainInteractionPrompt)
            || output.localizedCaseInsensitiveContains("User interaction is not allowed")
            || output.localizedCaseInsensitiveContains("errSecInteractionNotAllowed")
            || output.localizedCaseInsensitiveContains("CSSMERR_CSP_NO_USER_INTERACTION") {
            return lockedKeychainMessage
        }
        if output.contains("No Account for Team") {
            return "No Apple ID account configured in Xcode. Open Xcode > Settings > Accounts and sign in."
        }
        if output.contains("cannot be registered") || output.contains("is not available") {
            return "Bundle identifier conflict. Try again — if it persists, open Xcode and change the bundle ID."
        }
        if output.contains("No profiles for") {
            return "No provisioning profile. Connect your iPhone via USB and ensure signing is configured in Xcode."
        }
        if output.contains("developer mode is not enabled") || output.contains("failed to prepare device for development") {
            return "Developer Mode required. On your iPhone: Settings > Privacy & Security > Developer Mode > ON."
        }
        if output.contains("requires a development team") {
            return "No signing certificate. Open Xcode > Settings > Accounts > Manage Certificates > + > Apple Development."
        }
        return nil
    }

    nonisolated private static func isKeychainInteractionPrompt(_ line: String) -> Bool {
        let lower = line.lowercased()
        return lower.contains("password to unlock")
            || lower.contains("unlock default")
            || lower.contains("unlock-keychain")
    }

    nonisolated private static func extractBuildActivity(from line: String) -> String? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }

        if trimmed.hasPrefix("CompileSwift") || trimmed.hasPrefix("CompileC") {
            if let path = trimmed.components(separatedBy: " ").first(where: {
                $0.contains("/") && ($0.hasSuffix(".swift") || $0.hasSuffix(".m") || $0.hasSuffix(".c"))
            }) {
                return "Compiling \((path as NSString).lastPathComponent)"
            }
            return "Compiling sources…"
        }
        if trimmed.hasPrefix("Ld ") { return "Linking…" }
        if trimmed.hasPrefix("CodeSign ") || trimmed.hasPrefix("Sign ") { return "Code signing…" }
        if trimmed.hasPrefix("CopySwiftLibs") { return "Copying Swift libraries…" }
        if trimmed.hasPrefix("ProcessInfoPlistFile") { return "Processing Info.plist…" }
        if trimmed.hasPrefix("RegisterExecutionPolicyException") { return "Registering app…" }
        if trimmed.contains("BUILD SUCCEEDED") { return "Build succeeded" }
        if trimmed.contains("Testing started") { return "Installing on device…" }
        if trimmed.contains("Test Suite") && trimmed.contains("started") { return "Running on device…" }
        return nil
    }

    deinit {
        process?.terminate()
    }
}

enum WDALauncherError: Error, LocalizedError {
    case workspaceNotFound
    case launchFailed(String)
    case buildRequired

    var errorDescription: String? {
        switch self {
        case .workspaceNotFound:
            return "Bundled WebDriverAgent not found."
        case .launchFailed(let msg):
            return "WDA launch failed: \(msg)"
        case .buildRequired:
            return "WDA build artifacts not found."
        }
    }
}
