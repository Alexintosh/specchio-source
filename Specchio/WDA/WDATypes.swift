import Foundation

// MARK: - Errors
enum WDAError: Error, LocalizedError {
    case noSession
    case screenshotFailed
    case invalidScreenshotData
    case connectionFailed(String)
    case sessionCreationFailed
    case inputFailed(String)

    var errorDescription: String? {
        switch self {
        case .noSession: return "No active WDA session. Call createSession() first."
        case .screenshotFailed: return "Failed to capture screenshot."
        case .invalidScreenshotData: return "Screenshot data was not valid base64."
        case .connectionFailed(let msg): return "Connection failed: \(msg)"
        case .sessionCreationFailed: return "Failed to create WDA session."
        case .inputFailed(let msg): return "Input command failed: \(msg)"
        }
    }
}

// MARK: - Response Types
struct WDAStatus: Codable {
    let value: WDAStatusValue
    struct WDAStatusValue: Codable {
        let ready: Bool
        let message: String?
        let ios: WDAIOSInfo?
    }
    struct WDAIOSInfo: Codable {
        let ip: String?
    }
}

struct WDASessionResponse: Codable {
    let value: WDASessionValue
    let topLevelSessionId: String?

    enum CodingKeys: String, CodingKey {
        case value
        case topLevelSessionId = "sessionId"
    }

    /// Prefers the top-level sessionId (real WDA behaviour) and falls back to value.sessionId.
    var sessionId: String { topLevelSessionId ?? value.sessionId }

    struct WDASessionValue: Codable {
        let sessionId: String
    }
}

struct WDAScreenshotResponse: Codable {
    let value: String
}

struct WDASourceResponse: Codable {
    let value: String
}

struct WDALockedResponse: Codable {
    let value: Bool
}

struct WDAGenericResponse: Codable {
    let value: AnyCodable?
    let sessionId: String?
}

struct WDAWindowSizeResponse: Codable {
    let value: WDASize
    struct WDASize: Codable {
        let width: Double
        let height: Double
    }
}

// MARK: - Accessibility Tree Types
struct AccessibilityElement {
    let type: String
    let label: String?
    let value: String?
    let frame: CGRect
    let isEnabled: Bool
    let isVisible: Bool
    let identifier: String?
    let children: [AccessibilityElement]
}

// MARK: - Helper for untyped JSON
struct AnyCodable: Codable {
    let value: Any
    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let str = try? container.decode(String.self) { value = str }
        else if let int = try? container.decode(Int.self) { value = int }
        else if let bool = try? container.decode(Bool.self) { value = bool }
        else if let dict = try? container.decode([String: AnyCodable].self) { value = dict }
        else if let arr = try? container.decode([AnyCodable].self) { value = arr }
        else { value = NSNull() }
    }
    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        if let str = value as? String { try container.encode(str) }
        else if let int = value as? Int { try container.encode(int) }
        else if let bool = value as? Bool { try container.encode(bool) }
        else { try container.encodeNil() }
    }
}
