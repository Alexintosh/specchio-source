import Foundation
import os.log

private let log = SpecchioLogger.autoLaunch

@MainActor
class SetupChecker: ObservableObject {
    enum CheckStatus: Equatable {
        case pending
        case checking
        case passed
        case failed(String)

        var isFailed: Bool {
            if case .failed = self { return true }
            return false
        }
    }

    @Published var xcodeInstalled: CheckStatus = .pending
    @Published var xcodeCliReady: CheckStatus = .pending
    @Published var iosPlatformInstalled: CheckStatus = .pending
    @Published var signingCertificateFound: CheckStatus = .pending
    /// Detected signing teams with human-readable names (populated during signing check).
    @Published var detectedTeamNames: [(teamID: String, certName: String)] = []

    var allPassed: Bool {
        xcodeInstalled == .passed
            && xcodeCliReady == .passed
            && iosPlatformInstalled == .passed
            && signingCertificateFound == .passed
    }

    var hasAnyFailed: Bool {
        xcodeInstalled.isFailed
            || xcodeCliReady.isFailed
            || iosPlatformInstalled.isFailed
            || signingCertificateFound.isFailed
    }

    /// Debug launch arguments to simulate failures (Xcode → Scheme → Arguments Passed On Launch):
    ///   -forceSetupWizard        — fail all checks
    ///   -failXcodeInstall        — fail Xcode.app check
    ///   -failXcodeCli            — fail CLI tools check
    ///   -failIOSPlatform         — fail iOS platform check
    ///   -failSigningCert         — fail signing certificate check
    func runAllChecks() async {
        log.info("SetupChecker: running all prerequisite checks")

        #if DEBUG
        let forceAllFail = ProcessInfo.processInfo.arguments.contains("-forceSetupWizard")
        let failXcode = forceAllFail || ProcessInfo.processInfo.arguments.contains("-failXcodeInstall")
        let failCli = forceAllFail || ProcessInfo.processInfo.arguments.contains("-failXcodeCli")
        let failIOS = forceAllFail || ProcessInfo.processInfo.arguments.contains("-failIOSPlatform")
        let failCert = forceAllFail || ProcessInfo.processInfo.arguments.contains("-failSigningCert")
        #endif

        // 1. Xcode.app installed
        xcodeInstalled = .checking
        var xcodeOK = DependencyChecker.isXcodeAppInstalled()
        #if DEBUG
        if failXcode { xcodeOK = false }
        #endif
        xcodeInstalled = xcodeOK ? .passed : .failed("Install Xcode from the App Store.")
        log.info("SetupChecker: Xcode.app installed = \(xcodeOK)")

        guard xcodeOK else {
            // Remaining checks depend on Xcode
            xcodeCliReady = .failed("Requires Xcode")
            iosPlatformInstalled = .failed("Requires Xcode")
            signingCertificateFound = .failed("Requires Xcode")
            return
        }

        // 2. Xcode CLI ready (license accepted, tools configured)
        xcodeCliReady = .checking
        let cliResult = DependencyChecker.checkXcodeCli()
        var cliOK = { if case .success = cliResult { return true }; return false }()
        #if DEBUG
        if failCli { cliOK = false }
        #endif
        if cliOK {
            xcodeCliReady = .passed
        } else {
            let diagnostic: String
            if case .failure(let error) = cliResult {
                diagnostic = error.detail
            } else {
                diagnostic = "unknown"
            }
            xcodeCliReady = .failed("Open Xcode and accept the license agreement, then restart Specchio.\n\nDiagnostic: \(diagnostic)")
        }
        log.info("SetupChecker: Xcode CLI ready = \(cliOK)")

        guard cliOK else {
            iosPlatformInstalled = .failed("Requires Xcode CLI tools")
            signingCertificateFound = .failed("Requires Xcode CLI tools")
            return
        }

        // 3. iOS platform SDK installed
        iosPlatformInstalled = .checking
        var iosOK = DependencyChecker.isIOSPlatformInstalled()
        #if DEBUG
        if failIOS { iosOK = false }
        #endif
        iosPlatformInstalled = iosOK ? .passed : .failed("Open Xcode \u{2192} Settings \u{2192} Components \u{2192} iOS \u{2192} Install.")
        log.info("SetupChecker: iOS platform installed = \(iosOK)")

        // 4. Signing certificate exists
        signingCertificateFound = .checking
        let teamInfo = await Task.detached { WDALauncher.detectTeamNames() }.value
        #if DEBUG
        let hasTeams = failCert ? false : !teamInfo.isEmpty
        #else
        let hasTeams = !teamInfo.isEmpty
        #endif
        detectedTeamNames = teamInfo
        signingCertificateFound = hasTeams ? .passed : .failed("Open Xcode \u{2192} Settings \u{2192} Accounts \u{2192} Manage Certificates \u{2192} + \u{2192} Apple Development.")
        log.info("SetupChecker: signing certificate found = \(hasTeams), teams = \(teamInfo.map { $0.teamID })")

        log.info("SetupChecker: all checks passed = \(self.allPassed)")
    }
}
