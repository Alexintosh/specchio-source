import Foundation

private let airPlayH264DumpLog = SpecchioLogger.airPlay

final class AirPlayH264DumpWriter {
    struct Configuration: Equatable {
        let isEnabled: Bool
        let fileURL: URL
        let byteLimit: Int

        static func make(
            environment: [String: String] = ProcessInfo.processInfo.environment,
            now: Date = Date()
        ) -> Configuration? {
            let enabledValue = environment[enabledEnvironmentKey]?.lowercased()
            let pathValue = environment[pathEnvironmentKey]
            let isEnabled = enabledValue == "1" || enabledValue == "true" || !(pathValue?.isEmpty ?? true)
            guard isEnabled else {
                airPlayH264DumpLog.info("[AirPlayH264Dump] configuration branch=DISABLED")
                return nil
            }

            let byteLimit = Self.byteLimit(from: environment[limitEnvironmentKey])
            let fileURL: URL
            if let pathValue, !pathValue.isEmpty {
                fileURL = URL(fileURLWithPath: pathValue)
            } else {
                let timestamp = String(format: "%.0f", now.timeIntervalSince1970)
                fileURL = URL(fileURLWithPath: NSTemporaryDirectory())
                    .appendingPathComponent("Specchio-AirPlay-\(timestamp).h264")
            }

            airPlayH264DumpLog.info("[AirPlayH264Dump] configuration branch=ENABLED path=\(fileURL.path, privacy: .public) byteLimit=\(byteLimit)")
            return Configuration(isEnabled: true, fileURL: fileURL, byteLimit: byteLimit)
        }

        private static func byteLimit(from value: String?) -> Int {
            guard let value,
                  let parsed = Int(value),
                  parsed > 0 else {
                return defaultByteLimit
            }
            return min(parsed, maximumByteLimit)
        }

        private static let enabledEnvironmentKey = "SPECCHIO_AIRPLAY_H264_DUMP"
        private static let pathEnvironmentKey = "SPECCHIO_AIRPLAY_H264_DUMP_PATH"
        private static let limitEnvironmentKey = "SPECCHIO_AIRPLAY_H264_DUMP_LIMIT_BYTES"
        private static let defaultByteLimit = 8 * 1024 * 1024
        private static let maximumByteLimit = 64 * 1024 * 1024
    }

    private let configuration: Configuration
    private var writtenBytes = 0
    private var didCreateFile = false
    private var didReachLimit = false

    var filePath: String {
        configuration.fileURL.path
    }

    var byteCount: Int {
        writtenBytes
    }

    init(configuration: Configuration) {
        self.configuration = configuration
    }

    func reset(reason: String) {
        airPlayH264DumpLog.info("[AirPlayH264Dump] reset reason=\(reason, privacy: .public) path=\(self.filePath, privacy: .public) bytes=\(self.writtenBytes)")
        writtenBytes = 0
        didCreateFile = false
        didReachLimit = false
    }

    func writeParameterSets(sps: Data?, pps: Data?) {
        airPlayH264DumpLog.info("[AirPlayH264Dump] parameter sets requested spsBytes=\(sps?.count ?? 0) ppsBytes=\(pps?.count ?? 0)")
        if let sps {
            writeAnnexBNAL(sps, label: "sps")
        }
        if let pps {
            writeAnnexBNAL(pps, label: "pps")
        }
    }

    func writeAccessUnit(_ annexBBytes: Data, sequenceNumber: UInt64, isKeyframe: Bool) {
        airPlayH264DumpLog.info("[AirPlayH264Dump] access unit requested sequence=\(sequenceNumber) keyframe=\(isKeyframe) bytes=\(annexBBytes.count)")
        write(annexBBytes, label: "access-unit-\(sequenceNumber)")
    }

    private func writeAnnexBNAL(_ nalUnit: Data, label: String) {
        var data = Data()
        data.append(ReplayKitH264Constants.annexBStartCode)
        data.append(nalUnit)
        write(data, label: label)
    }

    private func write(_ data: Data, label: String) {
        guard !didReachLimit else {
            airPlayH264DumpLog.info("[AirPlayH264Dump] write skipped label=\(label, privacy: .public) reason=limit-reached path=\(self.filePath, privacy: .public)")
            return
        }
        guard !data.isEmpty else {
            airPlayH264DumpLog.info("[AirPlayH264Dump] write skipped label=\(label, privacy: .public) reason=empty")
            return
        }

        let remainingBytes = configuration.byteLimit - writtenBytes
        guard remainingBytes > 0 else {
            didReachLimit = true
            airPlayH264DumpLog.info("[AirPlayH264Dump] write skipped label=\(label, privacy: .public) reason=limit-reached path=\(self.filePath, privacy: .public)")
            return
        }

        let bytesToWrite = min(data.count, remainingBytes)
        let output = bytesToWrite == data.count ? data : Data(data.prefix(bytesToWrite))

        do {
            try createFileIfNeeded()
            let handle = try FileHandle(forWritingTo: configuration.fileURL)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: output)
            writtenBytes += bytesToWrite
            didReachLimit = writtenBytes >= configuration.byteLimit
            airPlayH264DumpLog.info("[AirPlayH264Dump] write branch=OK label=\(label, privacy: .public) wroteBytes=\(bytesToWrite) totalBytes=\(self.writtenBytes) limitReached=\(self.didReachLimit) path=\(self.filePath, privacy: .public)")
        } catch {
            airPlayH264DumpLog.error("[AirPlayH264Dump] write branch=FAILED label=\(label, privacy: .public) error=\(error.localizedDescription, privacy: .public) path=\(self.filePath, privacy: .public)")
        }
    }

    private func createFileIfNeeded() throws {
        guard !didCreateFile else { return }
        let directory = configuration.fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        _ = FileManager.default.createFile(atPath: configuration.fileURL.path, contents: nil)
        didCreateFile = true
        airPlayH264DumpLog.info("[AirPlayH264Dump] file created path=\(self.filePath, privacy: .public)")
    }
}
