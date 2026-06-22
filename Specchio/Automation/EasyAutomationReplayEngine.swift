import Combine
import CoreGraphics
import Foundation

@MainActor
final class EasyAutomationReplayEngine: ObservableObject {
    @Published private(set) var sessions: [EasyAutomationReplaySessionSummary] = []
    @Published private(set) var isReplaying = false
    @Published private(set) var isLooping = false
    @Published private(set) var currentSessionID: String?
    @Published private(set) var eventIndex = 0
    @Published private(set) var eventCount = 0
    @Published private(set) var loopCount = 0
    @Published private(set) var statusText = "Ready"

    private var replayTask: Task<Void, Never>?

    func refreshSessions(reason: String) {
        do {
            let root = try EasyAutomationStorage.automationRootDirectory(create: false)
            guard FileManager.default.fileExists(atPath: root.path) else {
                sessions = []
                statusText = "No recordings"
                SpecchioLogger.automation.info("[EasyAutomationReplay] refresh complete reason=\(reason, privacy: .public) branch=no-root root=\(root.path, privacy: .public)")
                return
            }

            let directories = try FileManager.default.contentsOfDirectory(
                at: root,
                includingPropertiesForKeys: [.isDirectoryKey, .contentModificationDateKey],
                options: [.skipsHiddenFiles]
            )
            let decodedSessions = directories.compactMap { directory -> EasyAutomationReplaySessionSummary? in
                let manifestURL = directory.appendingPathComponent("automation.json")
                guard FileManager.default.fileExists(atPath: manifestURL.path) else {
                    SpecchioLogger.automation.debug("[EasyAutomationReplay] session skipped reason=missing-manifest directory=\(directory.path, privacy: .public)")
                    return nil
                }
                do {
                    return try Self.loadSessionSummary(manifestURL: manifestURL, directory: directory)
                } catch {
                    SpecchioLogger.automation.warning("[EasyAutomationReplay] session skipped reason=decode-failed manifest=\(manifestURL.path, privacy: .public) error=\(error.localizedDescription, privacy: .public)")
                    return nil
                }
            }
            sessions = decodedSessions.sorted { $0.startedAt > $1.startedAt }
            statusText = sessions.isEmpty ? "No recordings" : "Ready"
            SpecchioLogger.automation.info("[EasyAutomationReplay] refresh complete reason=\(reason, privacy: .public) sessions=\(self.sessions.count)")
        } catch {
            sessions = []
            statusText = "Refresh failed"
            SpecchioLogger.automation.error("[EasyAutomationReplay] refresh failed reason=\(reason, privacy: .public) error=\(error.localizedDescription, privacy: .public)")
        }
    }

    func play(
        _ session: EasyAutomationReplaySessionSummary,
        loop: Bool,
        bluetoothHIDPanel: BluetoothHIDPanelController
    ) {
        if isReplaying {
            SpecchioLogger.automation.info("[EasyAutomationReplay] replacing active replay current=\(self.currentSessionID ?? "nil", privacy: .public) next=\(session.id, privacy: .public)")
            stop(reason: "replace-active-replay")
        }

        let manifest: EasyAutomationReplayManifest
        do {
            manifest = try Self.loadManifest(url: session.manifestURL)
        } catch {
            statusText = "Load failed"
            SpecchioLogger.automation.error("[EasyAutomationReplay] play failed reason=load-manifest session=\(session.id, privacy: .public) error=\(error.localizedDescription, privacy: .public)")
            return
        }

        let replayEvents = manifest.events
            .sorted { $0.elapsedMilliseconds < $1.elapsedMilliseconds }
            .filter(\.isReplayable)

        guard !replayEvents.isEmpty else {
            statusText = "No input events"
            SpecchioLogger.automation.info("[EasyAutomationReplay] play skipped reason=no-replayable-events session=\(session.id, privacy: .public) totalEvents=\(manifest.events.count)")
            return
        }

        isReplaying = true
        isLooping = loop
        currentSessionID = session.id
        eventIndex = 0
        eventCount = replayEvents.count
        loopCount = 0
        statusText = loop ? "Looping" : "Playing"
        SpecchioLogger.automation.info("[EasyAutomationReplay] play started session=\(session.id, privacy: .public) loop=\(loop) replayEvents=\(replayEvents.count) totalEvents=\(manifest.events.count) durationMs=\(manifest.durationMilliseconds)")

        replayTask = Task { @MainActor [weak self, weak bluetoothHIDPanel] in
            guard let self else { return }
            var shouldContinue = true
            var completedLoops = 0

            while shouldContinue && !Task.isCancelled {
                completedLoops += 1
                self.loopCount = completedLoops
                self.eventIndex = 0
                SpecchioLogger.automation.info("[EasyAutomationReplay] loop started session=\(session.id, privacy: .public) loopIndex=\(completedLoops) events=\(replayEvents.count)")

                var previousElapsedMilliseconds = 0
                for (index, event) in replayEvents.enumerated() {
                    if Task.isCancelled {
                        SpecchioLogger.automation.info("[EasyAutomationReplay] loop cancelled before event session=\(session.id, privacy: .public) loopIndex=\(completedLoops) eventSequence=\(event.sequence)")
                        break
                    }

                    let delayMilliseconds = max(0, event.elapsedMilliseconds - previousElapsedMilliseconds)
                    previousElapsedMilliseconds = event.elapsedMilliseconds
                    if delayMilliseconds > 0 {
                        SpecchioLogger.automation.debug("[EasyAutomationReplay] sleeping before event session=\(session.id, privacy: .public) eventSequence=\(event.sequence) delayMs=\(delayMilliseconds)")
                        try? await Task.sleep(nanoseconds: UInt64(delayMilliseconds) * 1_000_000)
                    }
                    if Task.isCancelled { break }

                    guard let bluetoothHIDPanel else {
                        SpecchioLogger.automation.error("[EasyAutomationReplay] event skipped reason=missing-bluetooth-controller session=\(session.id, privacy: .public) eventSequence=\(event.sequence)")
                        self.finishReplay(cancelled: true, reason: "missing-bluetooth-controller")
                        return
                    }

                    self.eventIndex = index + 1
                    let result = Self.execute(event, bluetoothHIDPanel: bluetoothHIDPanel)
                    SpecchioLogger.automation.info("[EasyAutomationReplay] event executed session=\(session.id, privacy: .public) loopIndex=\(completedLoops) index=\(index + 1) sequence=\(event.sequence) kind=\(event.kind, privacy: .public) phase=\(event.phase, privacy: .public) accepted=\(result.accepted) message=\(result.message, privacy: .public)")
                }

                shouldContinue = loop && !Task.isCancelled
            }

            self.finishReplay(cancelled: Task.isCancelled, reason: Task.isCancelled ? "cancelled" : "completed")
        }
    }

    func stop(reason: String) {
        guard self.isReplaying else {
            SpecchioLogger.automation.info("[EasyAutomationReplay] stop skipped reason=not-replaying trigger=\(reason, privacy: .public)")
            return
        }
        SpecchioLogger.automation.info("[EasyAutomationReplay] stop requested reason=\(reason, privacy: .public) session=\(self.currentSessionID ?? "nil", privacy: .public) eventIndex=\(self.eventIndex) eventCount=\(self.eventCount)")
        self.replayTask?.cancel()
        self.replayTask = nil
        self.finishReplay(cancelled: true, reason: reason)
    }

    private func finishReplay(cancelled: Bool, reason: String) {
        let sessionID = self.currentSessionID ?? "nil"
        self.isReplaying = false
        self.isLooping = false
        self.replayTask = nil
        self.statusText = cancelled ? "Stopped" : "Done"
        SpecchioLogger.automation.info("[EasyAutomationReplay] finished session=\(sessionID, privacy: .public) cancelled=\(cancelled) reason=\(reason, privacy: .public) loops=\(self.loopCount) eventIndex=\(self.eventIndex) eventCount=\(self.eventCount)")
    }

    private static func execute(
        _ event: EasyAutomationReplayEvent,
        bluetoothHIDPanel: BluetoothHIDPanelController
    ) -> EasyAgentCommandResult {
        guard let input = event.input else {
            SpecchioLogger.automation.info("[EasyAutomationReplay] event skipped reason=no-input sequence=\(event.sequence)")
            return .accepted("Lifecycle event skipped")
        }

        let requestID = "automation-replay-\(event.sequence)-\(input.kind)-\(input.phase)"
        switch input.kind {
        case "pointer":
            guard let phonePoint = input.phonePoint?.cgPoint else {
                SpecchioLogger.automation.info("[EasyAutomationReplay] pointer skipped reason=missing-phone-point sequence=\(event.sequence) phase=\(input.phase, privacy: .public)")
                return .rejected("Pointer event has no phone point")
            }
            return bluetoothHIDPanel.automationReplayPointer(
                phase: input.phase,
                phonePoint: phonePoint,
                buttons: input.buttons,
                requestID: requestID
            )

        case "scroll":
            guard let wheel = input.replayWheelDelta else {
                SpecchioLogger.automation.info("[EasyAutomationReplay] scroll skipped reason=missing-wheel sequence=\(event.sequence) details=\(input.details.description, privacy: .public)")
                return .rejected("Scroll event has no wheel delta")
            }
            return bluetoothHIDPanel.automationReplayMouseWheel(
                wheel: wheel,
                requestID: requestID
            )

        case "keyboardReport":
            guard let modifiers = input.replayModifiers,
                  let keys = input.replayKeys else {
                SpecchioLogger.automation.info("[EasyAutomationReplay] keyboard skipped reason=missing-report sequence=\(event.sequence) details=\(input.details.description, privacy: .public)")
                return .rejected("Keyboard event has no report")
            }
            return bluetoothHIDPanel.automationReplayKeyboardReport(
                modifiers: modifiers,
                keys: keys,
                requestID: requestID
            )

        case "consumerControl":
            guard let value = input.replayConsumerValue else {
                SpecchioLogger.automation.info("[EasyAutomationReplay] consumer skipped reason=missing-value sequence=\(event.sequence) details=\(input.details.description, privacy: .public)")
                return .rejected("Consumer event has no value")
            }
            return bluetoothHIDPanel.automationReplayConsumerControlValue(
                value,
                requestID: requestID
            )

        default:
            SpecchioLogger.automation.info("[EasyAutomationReplay] event skipped reason=unsupported-kind sequence=\(event.sequence) kind=\(input.kind, privacy: .public) phase=\(input.phase, privacy: .public)")
            return .accepted("Unsupported input skipped")
        }
    }

    private static func loadSessionSummary(
        manifestURL: URL,
        directory: URL
    ) throws -> EasyAutomationReplaySessionSummary {
        let manifest = try loadManifest(url: manifestURL)
        return EasyAutomationReplaySessionSummary(
            id: manifest.id,
            manifestURL: manifestURL,
            directoryURL: directory,
            startedAt: Date(timeIntervalSince1970: manifest.startedAt),
            durationMilliseconds: manifest.durationMilliseconds,
            eventCount: manifest.events.count,
            replayableEventCount: manifest.events.filter(\.isReplayable).count
        )
    }

    private static func loadManifest(url: URL) throws -> EasyAutomationReplayManifest {
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(EasyAutomationReplayManifest.self, from: data)
    }
}

struct EasyAutomationReplaySessionSummary: Identifiable, Equatable {
    let id: String
    let manifestURL: URL
    let directoryURL: URL
    let startedAt: Date
    let durationMilliseconds: Int
    let eventCount: Int
    let replayableEventCount: Int

    var displayTitle: String {
        let formatter = DateFormatter()
        formatter.locale = Locale.current
        formatter.dateStyle = .none
        formatter.timeStyle = .medium
        return formatter.string(from: startedAt)
    }

    var detailText: String {
        "\(replayableEventCount) inputs"
    }
}

private struct EasyAutomationReplayManifest: Decodable {
    let schemaVersion: Int
    let id: String
    let startedAt: TimeInterval
    let endedAt: TimeInterval
    let durationMilliseconds: Int
    let events: [EasyAutomationReplayEvent]
}

private struct EasyAutomationReplayEvent: Decodable {
    let sequence: Int
    let elapsedMilliseconds: Int
    let kind: String
    let phase: String
    let reason: String
    let input: EasyAutomationReplayInput?

    var isReplayable: Bool {
        input?.isReplayable ?? false
    }
}

private struct EasyAutomationReplayInput: Decodable {
    let kind: String
    let phase: String
    let source: String
    let phonePoint: EasyAutomationReplayPoint?
    let buttons: Int?
    let details: [String: String]

    var isReplayable: Bool {
        switch kind {
        case "pointer":
            return phonePoint != nil
                && ["down", "up", "move", "dragStart", "dragMove", "dragEnd"].contains(phase)
        case "scroll":
            return replayWheelDelta != nil
        case "keyboardReport":
            return replayModifiers != nil && replayKeys != nil
        case "consumerControl":
            return replayConsumerValue != nil
        default:
            return false
        }
    }

    var replayWheelDelta: Int8? {
        guard let raw = details["boundedWheelDelta"],
              let value = Double(raw) else {
            return nil
        }
        return Int8(clamping: Int(value.rounded(.towardZero)))
    }

    var replayModifiers: UInt8? {
        Self.parseUInt8(details["modifiers"])
    }

    var replayKeys: [UInt8]? {
        guard let raw = details["keys"] else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        guard !trimmed.isEmpty else { return [] }
        return trimmed
            .split(separator: ",")
            .compactMap { Self.parseUInt8(String($0)) }
    }

    var replayConsumerValue: UInt16? {
        Self.parseUInt16(details["value"])
    }

    private static func parseUInt8(_ raw: String?) -> UInt8? {
        guard let value = parseInt(raw), value >= 0, value <= Int(UInt8.max) else {
            return nil
        }
        return UInt8(value)
    }

    private static func parseUInt16(_ raw: String?) -> UInt16? {
        guard let value = parseInt(raw), value >= 0, value <= Int(UInt16.max) else {
            return nil
        }
        return UInt16(value)
    }

    private static func parseInt(_ raw: String?) -> Int? {
        guard let raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.lowercased().hasPrefix("0x") {
            return Int(trimmed.dropFirst(2), radix: 16)
        }
        return Int(trimmed)
    }
}

private struct EasyAutomationReplayPoint: Decodable {
    let x: Double
    let y: Double

    var cgPoint: CGPoint {
        CGPoint(x: x, y: y)
    }
}
