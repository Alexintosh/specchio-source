import Foundation
import os.log

private let log = Logger(subsystem: Bundle.main.bundleIdentifier ?? "Specchio", category: "ForceUpdate")

@MainActor
final class ForceUpdateChecker: ObservableObject {
    @Published var updateRequired = false
    @Published var message = ""

    private static let timeoutSeconds: TimeInterval = 5

    func check() async {
        guard let urlString = Bundle.main.infoDictionary?["SpecchioMinimumVersionURL"] as? String,
              let url = URL(string: urlString) else {
            log.warning("SpecchioMinimumVersionURL not set in Info.plist — skipping force-update check")
            return
        }

        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = Self.timeoutSeconds
        config.timeoutIntervalForResource = Self.timeoutSeconds
        let session = URLSession(configuration: config)

        do {
            let (data, _) = try await session.data(from: url)
            let payload = try JSONDecoder().decode(MinimumVersionPayload.self, from: data)

            guard let currentString = Bundle.main.infoDictionary?["CFBundleVersion"] as? String,
                  let current = Int(currentString),
                  let minimum = Int(payload.minimumVersion) else {
                log.warning("Could not parse version strings — skipping force-update check")
                return
            }

            if current < minimum {
                updateRequired = true
                message = payload.message ?? "Please update Specchio to continue."
                log.info("Force update required: current \(currentString) < minimum \(payload.minimumVersion)")
            }
        } catch {
            // Fail open — never lock users out because of a network issue
            log.warning("Force-update check failed (allowing launch): \(error.localizedDescription)")
        }
    }
}

private struct MinimumVersionPayload: Decodable {
    let minimumVersion: String
    let message: String?
}
