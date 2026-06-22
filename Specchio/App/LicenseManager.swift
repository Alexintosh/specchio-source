import Foundation
import Combine
import Security
import os.log
import CommonCrypto

private let log = Logger(subsystem: "com.alexintosh.Specchio", category: "License")

@MainActor
class LicenseManager: ObservableObject {

    static let shared = LicenseManager()

    // MARK: - Types

    enum LicenseStatus: Equatable {
        case free
        case licensed(expiration: Date?)
        case validating
        case error(String)

        static func == (lhs: LicenseStatus, rhs: LicenseStatus) -> Bool {
            switch (lhs, rhs) {
            case (.free, .free), (.validating, .validating): return true
            case (.licensed(let a), .licensed(let b)): return a == b
            case (.error(let a), .error(let b)): return a == b
            default: return false
            }
        }
    }

    // MARK: - Published State

    @Published var status: LicenseStatus = .free

    /// Derived from status + grace period. Check this at point of use.
    var isPremium: Bool {
        switch status {
        case .licensed: return true
        case .error:
            // Allow premium during grace period (offline tolerance)
            return isWithinGracePeriod
        default:
            return false
        }
    }

    // MARK: - Constants

    private static let polarBaseURL = "https://api.polar.sh"
    private static let organizationId = "bd3af6a8-7682-4dd7-937b-e5c654e73aa8"
    private static let gracePeriodDays: TimeInterval = 7 * 24 * 60 * 60 // 7 days

    // Keychain service/account identifiers
    private static let keychainService = "com.alexintosh.Specchio.license"
    private static let keychainAccountKey = "licenseKey"
    private static let keychainAccountActivationId = "activationId"
    private static let keychainAccountGrace = "graceData"

    // HMAC key derived from bundle + hardware UUID (not stored anywhere guessable)
    private static var hmacKey: Data {
        let seed = "Specchio-\(hardwareUUID)-grace"
        return Data(seed.utf8)
    }

    // MARK: - Hardware Binding

    static var hardwareUUID: String {
        let port: mach_port_t
        if #available(macOS 12.0, *) {
            port = kIOMainPortDefault
        } else {
            port = kIOMasterPortDefault
        }
        let service = IOServiceGetMatchingService(port,
                                                   IOServiceMatching("IOPlatformExpertDevice"))
        defer { IOObjectRelease(service) }
        guard let uuidData = IORegistryEntryCreateCFProperty(service,
                                                              "IOPlatformUUID" as CFString,
                                                              kCFAllocatorDefault, 0)?.takeRetainedValue() as? String else {
            return ProcessInfo.processInfo.hostName
        }
        return uuidData
    }

    // MARK: - Activate

    func activate(key: String) async {
        let trimmedKey = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedKey.isEmpty else {
            status = .error("License key cannot be empty")
            return
        }

        status = .validating
        log.info("Activating license key...")

        let url = URL(string: "\(Self.polarBaseURL)/v1/customer-portal/license-keys/activate")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let body: [String: Any] = [
            "key": trimmedKey,
            "organization_id": Self.organizationId,
            "label": Self.hardwareUUID
        ]

        do {
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
            let (data, response) = try await URLSession.shared.data(for: request)

            guard let http = response as? HTTPURLResponse else {
                status = .error("Invalid response from server")
                return
            }

            if http.statusCode == 200 {
                let result = try JSONDecoder().decode(PolarActivationResponse.self, from: data)
                let activationId = result.id
                saveToKeychain(key: trimmedKey, activationId: activationId)
                updateGraceTimestamp()

                let expiration = Self.parseISO8601(result.licenseKey.expiresAt)
                status = .licensed(expiration: expiration)
                log.info("License activated successfully (activation: \(activationId))")
            } else {
                let errorBody = String(data: data, encoding: .utf8) ?? "Unknown error"
                log.error("Activation failed (\(http.statusCode)): \(errorBody)")
                let parsed = try? JSONDecoder().decode(PolarErrorResponse.self, from: data)
                let msg = parsed?.detail?.message ?? parsed?.error ?? "Activation failed (HTTP \(http.statusCode))"
                status = .error(msg)
            }
        } catch {
            log.error("Activation request failed: \(error.localizedDescription)")
            status = .error("Network error: \(error.localizedDescription)")
        }
    }

    // MARK: - Validate

    func validate() async {
        guard let (key, activationId) = loadFromKeychain() else {
            log.info("No stored license key, staying on free tier")
            status = .free
            return
        }

        status = .validating
        log.info("Validating license key...")

        let url = URL(string: "\(Self.polarBaseURL)/v1/customer-portal/license-keys/validate")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let body: [String: Any] = [
            "key": key,
            "organization_id": Self.organizationId,
            "activation_id": activationId,
            "label": Self.hardwareUUID
        ]

        do {
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
            let (data, response) = try await URLSession.shared.data(for: request)

            guard let http = response as? HTTPURLResponse else {
                status = .error("Invalid response from server")
                return
            }

            if http.statusCode == 200 {
                let result = try JSONDecoder().decode(PolarLicenseKey.self, from: data)
                if result.status == "granted" {
                    updateGraceTimestamp()
                    let expiration = Self.parseISO8601(result.expiresAt)
                    status = .licensed(expiration: expiration)
                    log.info("License validated successfully (status: \(result.status))")
                } else {
                    clearKeychain()
                    status = .error("License \(result.status)")
                    log.warning("License validation returned status: \(result.status)")
                }
            } else {
                log.warning("Validation request failed (\(http.statusCode)), checking grace period")
                if isWithinGracePeriod {
                    status = .error("Offline — using grace period")
                } else {
                    clearKeychain()
                    status = .free
                    log.warning("Grace period expired, reverting to free tier")
                }
            }
        } catch {
            log.warning("Validation network error: \(error.localizedDescription)")
            if isWithinGracePeriod {
                status = .error("Offline — using grace period")
            } else {
                status = .free
            }
        }
    }

    // MARK: - Deactivate

    func deactivate() async {
        guard let (key, activationId) = loadFromKeychain() else {
            status = .free
            return
        }

        status = .validating
        log.info("Deactivating license...")

        let url = URL(string: "\(Self.polarBaseURL)/v1/customer-portal/license-keys/deactivate")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let body: [String: Any] = [
            "key": key,
            "organization_id": Self.organizationId,
            "activation_id": activationId,
            "label": Self.hardwareUUID
        ]

        do {
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
            let (_, response) = try await URLSession.shared.data(for: request)

            guard let http = response as? HTTPURLResponse else {
                status = .error("Invalid response from server")
                return
            }

            if (200...204).contains(http.statusCode) {
                log.info("License deactivated successfully")
            } else {
                log.warning("Deactivation returned \(http.statusCode), clearing locally anyway")
            }
        } catch {
            log.warning("Deactivation network error: \(error.localizedDescription)")
        }

        clearKeychain()
        status = .free
    }

    // MARK: - Keychain Helpers

    private func saveToKeychain(key: String, activationId: String) {
        setKeychainItem(account: Self.keychainAccountKey, data: Data(key.utf8))
        setKeychainItem(account: Self.keychainAccountActivationId, data: Data(activationId.utf8))
    }

    func loadFromKeychain() -> (key: String, activationId: String)? {
        guard let keyData = getKeychainItem(account: Self.keychainAccountKey),
              let activationData = getKeychainItem(account: Self.keychainAccountActivationId),
              let key = String(data: keyData, encoding: .utf8),
              let activationId = String(data: activationData, encoding: .utf8) else {
            return nil
        }
        return (key, activationId)
    }

    private func clearKeychain() {
        deleteKeychainItem(account: Self.keychainAccountKey)
        deleteKeychainItem(account: Self.keychainAccountActivationId)
        deleteKeychainItem(account: Self.keychainAccountGrace)
    }

    private func setKeychainItem(account: String, data: Data) {
        deleteKeychainItem(account: account)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.keychainService,
            kSecAttrAccount as String: account,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        ]
        let status = SecItemAdd(query as CFDictionary, nil)
        if status != errSecSuccess {
            log.error("Keychain write failed for \(account): \(status)")
        }
    }

    private func getKeychainItem(account: String) -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.keychainService,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess else { return nil }
        return result as? Data
    }

    private func deleteKeychainItem(account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.keychainService,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(query as CFDictionary)
    }

    // MARK: - Grace Period (HMAC-signed)

    private func updateGraceTimestamp() {
        let timestamp = Date().timeIntervalSince1970
        let timestampStr = String(timestamp)
        let signature = hmacSHA256(data: Data(timestampStr.utf8), key: Self.hmacKey)
        let graceData = "\(timestampStr):\(signature.base64EncodedString())"
        setKeychainItem(account: Self.keychainAccountGrace, data: Data(graceData.utf8))
    }

    private var isWithinGracePeriod: Bool {
        guard let graceData = getKeychainItem(account: Self.keychainAccountGrace),
              let graceStr = String(data: graceData, encoding: .utf8) else {
            return false
        }

        let parts = graceStr.split(separator: ":", maxSplits: 1)
        guard parts.count == 2,
              let timestamp = TimeInterval(parts[0]),
              let storedSig = Data(base64Encoded: String(parts[1])) else {
            return false
        }

        // Verify HMAC — prevent tampering
        let expectedSig = hmacSHA256(data: Data(String(parts[0]).utf8), key: Self.hmacKey)
        guard expectedSig == storedSig else {
            log.warning("Grace period signature mismatch — possible tampering")
            return false
        }

        let lastValidated = Date(timeIntervalSince1970: timestamp)
        let elapsed = Date().timeIntervalSince(lastValidated)
        return elapsed < Self.gracePeriodDays
    }

    private static func parseISO8601(_ string: String?) -> Date? {
        guard let string else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: string) ?? ISO8601DateFormatter().date(from: string)
    }

    private func hmacSHA256(data: Data, key: Data) -> Data {
        var hmac = [UInt8](repeating: 0, count: Int(CC_SHA256_DIGEST_LENGTH))
        data.withUnsafeBytes { dataPtr in
            key.withUnsafeBytes { keyPtr in
                CCHmac(CCHmacAlgorithm(kCCHmacAlgSHA256),
                        keyPtr.baseAddress, key.count,
                        dataPtr.baseAddress, data.count,
                        &hmac)
            }
        }
        return Data(hmac)
    }
}

// MARK: - Polar API Response Types

/// Response from POST /v1/customer-portal/license-keys/activate
private struct PolarActivationResponse: Codable {
    let id: String
    let licenseKey: PolarLicenseKey

    enum CodingKeys: String, CodingKey {
        case id
        case licenseKey = "license_key"
    }
}

/// Response from POST /v1/customer-portal/license-keys/validate
/// Also embedded in activation response as `license_key`
private struct PolarLicenseKey: Codable {
    let id: String
    let status: String          // "granted", "revoked", "disabled"
    let expiresAt: String?      // ISO 8601 or null
    let limitActivations: Int?
    let usage: Int
    let limitUsage: Int?
    let validations: Int

    enum CodingKeys: String, CodingKey {
        case id, status, usage, validations
        case expiresAt = "expires_at"
        case limitActivations = "limit_activations"
        case limitUsage = "limit_usage"
    }
}

private struct PolarErrorResponse: Codable {
    let detail: PolarErrorDetail?
    let error: String?
}

/// Polar errors can be a string or a structured array
private enum PolarErrorDetail: Codable {
    case string(String)
    case array([[String: PolarAnyCodable]])

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let str = try? container.decode(String.self) {
            self = .string(str)
            return
        }
        self = .string("Unknown error")
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let s): try container.encode(s)
        case .array: try container.encode("Unknown error")
        }
    }

    var message: String {
        switch self {
        case .string(let s): return s
        case .array: return "Validation error"
        }
    }
}

// Minimal PolarAnyCodable for error parsing
private struct PolarAnyCodable: Codable {
    init(from decoder: Decoder) throws { }
    func encode(to encoder: Encoder) throws { }
}
