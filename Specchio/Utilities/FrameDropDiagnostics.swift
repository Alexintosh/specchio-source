import Foundation

struct FrameDropDiagnosticRecord: Encodable {
    let timestamp: String
    let uptimeSeconds: Double
    let processIdentifier: Int32
    let sessionID: String
    let event: String
    let source: String
    let severity: String
    let details: [String: String]
}

final class FrameDropDiagnostics {
    static let shared = FrameDropDiagnostics()

    static var diagnosticsDirectoryURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Specchio", isDirectory: true)
            .appendingPathComponent("FrameDiagnostics", isDirectory: true)
    }

    static var latestLogURL: URL {
        diagnosticsDirectoryURL.appendingPathComponent("frame-diagnostics-latest.jsonl")
    }

    static var latestLogPath: String {
        latestLogURL.path
    }

    private let queue = DispatchQueue(label: "com.alexintosh.Specchio.frameDiagnostics.writer", qos: .utility)
    private let sessionID = UUID().uuidString
    private let processIdentifier = ProcessInfo.processInfo.processIdentifier
    private let startedUptime = ProcessInfo.processInfo.systemUptime
    private let logURL: URL
    private let fileHandle: FileHandle?
    private let timestampFormatter: ISO8601DateFormatter

    private init() {
        let resolvedLogURL = Self.latestLogURL
        logURL = resolvedLogURL

        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        timestampFormatter = formatter

        let handle: FileHandle?
        do {
            try FileManager.default.createDirectory(
                at: Self.diagnosticsDirectoryURL,
                withIntermediateDirectories: true
            )
            FileManager.default.createFile(atPath: resolvedLogURL.path, contents: nil)
            handle = try FileHandle(forWritingTo: resolvedLogURL)
        } catch {
            handle = nil
            SpecchioLogger.frameDiagnostics.error("[FrameDiagnostics] failed to open JSONL log path=\(resolvedLogURL.path, privacy: .public) error=\(error.localizedDescription, privacy: .public)")
        }
        fileHandle = handle

        recordLifecycle(
            source: "diagnostics",
            event: "sessionStart",
            reason: "frame diagnostics initialized",
            details: ["path": resolvedLogURL.path]
        )
    }

    func recordWindow(
        source: String,
        trigger: String,
        windowSeconds: TimeInterval,
        metrics: [String: String]
    ) {
        var details = metrics
        details["trigger"] = trigger
        details["windowSeconds"] = Self.format(windowSeconds)
        record(event: "window", source: source, severity: "info", details: details)
    }

    func recordDrop(
        source: String,
        stage: String,
        reason: String,
        details: [String: String] = [:]
    ) {
        var mergedDetails = details
        mergedDetails["stage"] = stage
        mergedDetails["reason"] = reason
        record(event: "drop", source: source, severity: "warning", details: mergedDetails)
    }

    func recordLifecycle(
        source: String,
        event: String,
        reason: String,
        details: [String: String] = [:],
        severity: String = "info"
    ) {
        var mergedDetails = details
        mergedDetails["reason"] = reason
        record(event: event, source: source, severity: severity, details: mergedDetails)
    }

    static func format(_ value: Double, digits: Int = 2) -> String {
        String(format: "%.\(digits)f", value)
    }

    private func record(
        event: String,
        source: String,
        severity: String,
        details: [String: String]
    ) {
        let sanitizedDetails = details.mapValues(Self.sanitized)
        let summary = Self.summary(sanitizedDetails)
        logToUnifiedLog(event: event, source: source, severity: severity, summary: summary)

        queue.async { [self] in
            let record = FrameDropDiagnosticRecord(
                timestamp: timestampFormatter.string(from: Date()),
                uptimeSeconds: ProcessInfo.processInfo.systemUptime - startedUptime,
                processIdentifier: processIdentifier,
                sessionID: sessionID,
                event: event,
                source: source,
                severity: severity,
                details: sanitizedDetails
            )

            do {
                var data = try JSONEncoder().encode(record)
                data.append(0x0A)
                fileHandle?.seekToEndOfFile()
                fileHandle?.write(data)
                fileHandle?.synchronizeFile()
            } catch {
                SpecchioLogger.frameDiagnostics.error("[FrameDiagnostics] JSONL write failed event=\(event, privacy: .public) source=\(source, privacy: .public) error=\(error.localizedDescription, privacy: .public)")
            }
        }
    }

    private func logToUnifiedLog(event: String, source: String, severity: String, summary: String) {
        switch severity {
        case "error":
            SpecchioLogger.frameDiagnostics.error("[FrameDiagnostics] event=\(event, privacy: .public) source=\(source, privacy: .public) \(summary, privacy: .public) file=\(Self.latestLogPath, privacy: .public)")
        case "warning":
            SpecchioLogger.frameDiagnostics.warning("[FrameDiagnostics] event=\(event, privacy: .public) source=\(source, privacy: .public) \(summary, privacy: .public) file=\(Self.latestLogPath, privacy: .public)")
        default:
            SpecchioLogger.frameDiagnostics.info("[FrameDiagnostics] event=\(event, privacy: .public) source=\(source, privacy: .public) \(summary, privacy: .public) file=\(Self.latestLogPath, privacy: .public)")
        }
    }

    private static func sanitized(_ value: String) -> String {
        let cleaned = value
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "\\r")
        guard cleaned.count > 512 else { return cleaned }
        return String(cleaned.prefix(512)) + "...truncated"
    }

    private static func summary(_ details: [String: String]) -> String {
        details.keys.sorted()
            .map { "\($0)=\(details[$0] ?? "")" }
            .joined(separator: " ")
    }
}
