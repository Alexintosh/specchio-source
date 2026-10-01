import AppKit
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

private let easyAutomationLog = SpecchioLogger.automation

final class EasyAutomationRecorderActivity {
    static let shared = EasyAutomationRecorderActivity()

    private let lock = NSLock()
    private var active = false

    var isRecording: Bool {
        lock.lock()
        defer { lock.unlock() }
        return active
    }

    func setRecording(_ isRecording: Bool) {
        lock.lock()
        active = isRecording
        lock.unlock()
    }
}

@MainActor
final class EasyAutomationRecorder: ObservableObject {
    @Published private(set) var isRecording = false
    @Published private(set) var eventCount = 0
    @Published private(set) var frameCount = 0
    @Published private(set) var statusText = "Ready"
    @Published private(set) var lastSavedURL: URL?

    private var currentSession: EasyAutomationRecordingSession?
    private var lastFrameCaptureTimestamp: TimeInterval = 0

    func start(frame: CGImage?, status: EasyAgentStatusSnapshot, reason: String) {
        guard !isRecording else {
            easyAutomationLog.info("[EasyAutomationRecorder] start skipped reason=already-recording trigger=\(reason, privacy: .public) events=\(self.eventCount)")
            return
        }

        do {
            let session = try EasyAutomationRecordingSession(status: status)
            currentSession = session
            isRecording = true
            eventCount = 0
            frameCount = 0
            statusText = "Recording"
            lastFrameCaptureTimestamp = 0
            EasyAutomationRecorderActivity.shared.setRecording(true)
            easyAutomationLog.info("[EasyAutomationRecorder] started id=\(session.id, privacy: .public) directory=\(session.directory.path, privacy: .public) reason=\(reason, privacy: .public) framePresent=\(frame != nil)")
            appendLifecycleEvent(kind: "recording", phase: "started", frame: frame, status: status, reason: reason, forceFrame: true)
        } catch {
            statusText = "Start failed"
            EasyAutomationRecorderActivity.shared.setRecording(false)
            easyAutomationLog.error("[EasyAutomationRecorder] start failed reason=\(reason, privacy: .public) error=\(error.localizedDescription, privacy: .public)")
        }
    }

    func stop(frame: CGImage?, status: EasyAgentStatusSnapshot, reason: String) {
        guard isRecording, let session = currentSession else {
            easyAutomationLog.info("[EasyAutomationRecorder] stop skipped reason=not-recording trigger=\(reason, privacy: .public)")
            return
        }

        appendLifecycleEvent(kind: "recording", phase: "stopped", frame: frame, status: status, reason: reason, forceFrame: true)
        EasyAutomationRecorderActivity.shared.setRecording(false)
        isRecording = false

        do {
            let manifestURL = try session.finish()
            lastSavedURL = manifestURL
            statusText = "Saved"
            easyAutomationLog.info("[EasyAutomationRecorder] stopped id=\(session.id, privacy: .public) events=\(session.events.count) frames=\(session.frameCount) manifest=\(manifestURL.path, privacy: .public) reason=\(reason, privacy: .public)")
        } catch {
            statusText = "Save failed"
            easyAutomationLog.error("[EasyAutomationRecorder] save failed id=\(session.id, privacy: .public) events=\(session.events.count) error=\(error.localizedDescription, privacy: .public)")
        }

        eventCount = session.events.count
        frameCount = session.frameCount
        currentSession = nil
    }

    func recordInputNotification(
        _ notification: Notification,
        frame: CGImage?,
        status: EasyAgentStatusSnapshot
    ) {
        guard isRecording, let session = currentSession else { return }
        guard let input = EasyAutomationRecordedInput(notification: notification) else {
            easyAutomationLog.info("[EasyAutomationRecorder] input ignored reason=invalid-notification")
            return
        }

        let forceFrame = input.requiresFrameKeypoint
        let sequence = session.nextSequence
        let timestamp = Date().timeIntervalSince1970
        let elapsedMilliseconds = session.elapsedMilliseconds
        let frameReference = captureFrameIfNeeded(
            frame,
            in: session,
            eventSequence: sequence,
            reason: "\(input.kind)-\(input.phase)",
            force: forceFrame
        )
        let motion = session.motionSample(
            for: input,
            timestamp: timestamp,
            elapsedMilliseconds: elapsedMilliseconds
        )
        let event = EasyAutomationRecordedEvent(
            sequence: sequence,
            timestamp: timestamp,
            elapsedMilliseconds: elapsedMilliseconds,
            kind: input.kind,
            phase: input.phase,
            reason: input.source,
            input: input,
            motion: motion,
            geometry: EasyAutomationGeometrySnapshot(status: status),
            frame: frameReference
        )
        session.append(event)
        eventCount = session.events.count
        frameCount = session.frameCount
        statusText = "Recording"
        let speedText = motion?.speedPointsPerSecond.map { String(format: "%.2f", $0) } ?? "nil"
        let impulseText = motion?.impulseMagnitudePointsPerSecond.map { String(format: "%.2f", $0) } ?? "nil"
        easyAutomationLog.info("[EasyAutomationRecorder] recorded input id=\(session.id, privacy: .public) sequence=\(event.sequence) kind=\(input.kind, privacy: .public) phase=\(input.phase, privacy: .public) speed=\(speedText, privacy: .public) impulse=\(impulseText, privacy: .public) frame=\(frameReference?.relativePath ?? "none", privacy: .public) events=\(session.events.count)")
    }

    private func appendLifecycleEvent(
        kind: String,
        phase: String,
        frame: CGImage?,
        status: EasyAgentStatusSnapshot,
        reason: String,
        forceFrame: Bool
    ) {
        guard let session = currentSession else { return }
        let frameReference = captureFrameIfNeeded(
            frame,
            in: session,
            eventSequence: session.nextSequence,
            reason: "\(kind)-\(phase)",
            force: forceFrame
        )
        let event = EasyAutomationRecordedEvent(
            sequence: session.nextSequence,
            timestamp: Date().timeIntervalSince1970,
            elapsedMilliseconds: session.elapsedMilliseconds,
            kind: kind,
            phase: phase,
            reason: reason,
            input: nil,
            motion: nil,
            geometry: EasyAutomationGeometrySnapshot(status: status),
            frame: frameReference
        )
        session.append(event)
        eventCount = session.events.count
        frameCount = session.frameCount
    }

    private func captureFrameIfNeeded(
        _ frame: CGImage?,
        in session: EasyAutomationRecordingSession,
        eventSequence: Int,
        reason: String,
        force: Bool
    ) -> EasyAutomationRecordedFrame? {
        guard let frame else {
            easyAutomationLog.info("[EasyAutomationRecorder] frame skipped reason=no-frame eventSequence=\(eventSequence) captureReason=\(reason, privacy: .public)")
            return nil
        }

        let now = Date().timeIntervalSince1970
        if !force && now - lastFrameCaptureTimestamp < EasyAutomationRecordingDefaults.frameThrottleSeconds {
            easyAutomationLog.debug("[EasyAutomationRecorder] frame throttled eventSequence=\(eventSequence) captureReason=\(reason, privacy: .public)")
            return nil
        }

        do {
            let frameReference = try session.writeFrame(
                frame,
                eventSequence: eventSequence,
                timestamp: now
            )
            lastFrameCaptureTimestamp = now
            easyAutomationLog.info("[EasyAutomationRecorder] frame captured eventSequence=\(eventSequence) path=\(frameReference.relativePath, privacy: .public) width=\(frame.width) height=\(frame.height) reason=\(reason, privacy: .public)")
            return frameReference
        } catch {
            easyAutomationLog.error("[EasyAutomationRecorder] frame write failed eventSequence=\(eventSequence) reason=\(reason, privacy: .public) error=\(error.localizedDescription, privacy: .public)")
            return nil
        }
    }
}

private enum EasyAutomationRecordingDefaults {
    static let schemaVersion = 2
    static let frameThrottleSeconds: TimeInterval = 0.2
    static let jpegQuality = 0.82
}

enum EasyAutomationStorage {
    static func automationRootDirectory(create: Bool = true) throws -> URL {
        let applicationSupport = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: create
        )
        let root = applicationSupport
            .appendingPathComponent("Specchio", isDirectory: true)
            .appendingPathComponent("Automations", isDirectory: true)
        if create {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        }
        return root
    }
}

private final class EasyAutomationRecordingSession {
    let id: String
    let startedAt: Date
    let directory: URL
    let framesDirectory: URL
    let initialGeometry: EasyAutomationGeometrySnapshot
    private(set) var events: [EasyAutomationRecordedEvent] = []
    private(set) var frameCount = 0
    private var motionTracker = EasyAutomationMotionTracker()

    var nextSequence: Int {
        events.count + 1
    }

    var elapsedMilliseconds: Int {
        Int(Date().timeIntervalSince(startedAt) * 1000)
    }

    init(status: EasyAgentStatusSnapshot) throws {
        startedAt = Date()
        id = Self.makeIdentifier(for: startedAt)
        let root = try EasyAutomationStorage.automationRootDirectory()
        directory = root.appendingPathComponent(id, isDirectory: true)
        framesDirectory = directory.appendingPathComponent("frames", isDirectory: true)
        initialGeometry = EasyAutomationGeometrySnapshot(status: status)
        try FileManager.default.createDirectory(at: framesDirectory, withIntermediateDirectories: true)
    }

    func append(_ event: EasyAutomationRecordedEvent) {
        events.append(event)
    }

    func motionSample(
        for input: EasyAutomationRecordedInput,
        timestamp: TimeInterval,
        elapsedMilliseconds: Int
    ) -> EasyAutomationRecordedMotion? {
        motionTracker.sample(
            for: input,
            recorderTimestamp: timestamp,
            elapsedMilliseconds: elapsedMilliseconds
        )
    }

    func writeFrame(_ frame: CGImage, eventSequence: Int, timestamp: TimeInterval) throws -> EasyAutomationRecordedFrame {
        let filename = String(format: "event-%05d.jpg", eventSequence)
        let url = framesDirectory.appendingPathComponent(filename)
        guard let destination = CGImageDestinationCreateWithURL(
            url as CFURL,
            UTType.jpeg.identifier as CFString,
            1,
            nil
        ) else {
            throw EasyAutomationRecordingError.frameDestinationUnavailable
        }

        let options = [
            kCGImageDestinationLossyCompressionQuality: EasyAutomationRecordingDefaults.jpegQuality
        ] as CFDictionary
        CGImageDestinationAddImage(destination, frame, options)
        guard CGImageDestinationFinalize(destination) else {
            throw EasyAutomationRecordingError.frameFinalizeFailed
        }

        frameCount += 1
        return EasyAutomationRecordedFrame(
            sequence: frameCount,
            eventSequence: eventSequence,
            relativePath: "frames/\(filename)",
            width: frame.width,
            height: frame.height,
            timestamp: timestamp
        )
    }

    func finish() throws -> URL {
        let manifest = EasyAutomationRecordingManifest(
            schemaVersion: EasyAutomationRecordingDefaults.schemaVersion,
            id: id,
            startedAt: startedAt.timeIntervalSince1970,
            endedAt: Date().timeIntervalSince1970,
            durationMilliseconds: elapsedMilliseconds,
            initialGeometry: initialGeometry,
            events: events
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(manifest)
        let url = directory.appendingPathComponent("automation.json")
        try data.write(to: url, options: [.atomic])
        return url
    }

    private static func makeIdentifier(for date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return "easy-automation-\(formatter.string(from: date))-\(UUID().uuidString.prefix(8).lowercased())"
    }
}

private enum EasyAutomationRecordingError: Error {
    case frameDestinationUnavailable
    case frameFinalizeFailed
}

private struct EasyAutomationRecordingManifest: Encodable {
    let schemaVersion: Int
    let id: String
    let startedAt: TimeInterval
    let endedAt: TimeInterval
    let durationMilliseconds: Int
    let initialGeometry: EasyAutomationGeometrySnapshot
    let events: [EasyAutomationRecordedEvent]
}

private struct EasyAutomationRecordedEvent: Encodable {
    let sequence: Int
    let timestamp: TimeInterval
    let elapsedMilliseconds: Int
    let kind: String
    let phase: String
    let reason: String
    let input: EasyAutomationRecordedInput?
    let motion: EasyAutomationRecordedMotion?
    let geometry: EasyAutomationGeometrySnapshot
    let frame: EasyAutomationRecordedFrame?
}

private struct EasyAutomationRecordedInput: Encodable {
    let kind: String
    let phase: String
    let source: String
    let eventType: String?
    let eventNumber: Int?
    let nativeEventTimestamp: TimeInterval?
    let eventDelta: EasyAutomationPoint?
    let eventButtonNumber: Int?
    let eventLocationInWindow: EasyAutomationPoint?
    let scrollingDelta: EasyAutomationPoint?
    let hasPreciseScrollingDeltas: Bool?
    let scrollPhaseRaw: Int?
    let momentumPhaseRaw: Int?
    let localPoint: EasyAutomationPoint?
    let normalizedPoint: EasyAutomationPoint?
    let phonePoint: EasyAutomationPoint?
    let virtualPointerPoint: EasyAutomationPoint?
    let surfaceFrameInWindow: EasyAutomationRect?
    let pointerSurfaceSize: EasyAutomationSize?
    let inputSurfaceFrameInWindow: EasyAutomationRect?
    let displayRotationDegrees: Int?
    let absolutePointerTransportEnabled: Bool?
    let buttons: Int?
    let details: [String: String]

    var requiresFrameKeypoint: Bool {
        switch phase {
        case "down", "up", "scroll", "keyPress", "keyRelease", "consumerPress", "consumerRelease", "started", "stopped":
            return true
        default:
            return false
        }
    }

    init?(notification: Notification) {
        guard let userInfo = notification.userInfo,
              let kind = userInfo["kind"] as? String,
              let phase = userInfo["phase"] as? String,
              let source = userInfo["source"] as? String else {
            return nil
        }

        self.kind = kind
        self.phase = phase
        self.source = source
        eventType = userInfo["eventType"] as? String
        eventNumber = Self.intValue(userInfo["eventNumber"])
        nativeEventTimestamp = Self.doubleValue(userInfo["nativeEventTimestamp"])
        eventDelta = Self.point(prefix: "eventDelta", userInfo: userInfo)
        eventButtonNumber = Self.intValue(userInfo["eventButtonNumber"])
        eventLocationInWindow = Self.point(prefix: "eventLocationInWindow", userInfo: userInfo)
        scrollingDelta = Self.point(prefix: "scrollingDelta", userInfo: userInfo)
        hasPreciseScrollingDeltas = Self.boolValue(userInfo["hasPreciseScrollingDeltas"])
        scrollPhaseRaw = Self.intValue(userInfo["scrollPhaseRaw"])
        momentumPhaseRaw = Self.intValue(userInfo["momentumPhaseRaw"])
        localPoint = Self.point(prefix: "localPoint", userInfo: userInfo)
        normalizedPoint = Self.point(prefix: "normalizedPoint", userInfo: userInfo)
        phonePoint = Self.point(prefix: "phonePoint", userInfo: userInfo)
        virtualPointerPoint = Self.point(prefix: "virtualPointerPoint", userInfo: userInfo)
        surfaceFrameInWindow = Self.rect(prefix: "surfaceFrameInWindow", userInfo: userInfo)
        pointerSurfaceSize = Self.size(prefix: "pointerSurface", userInfo: userInfo)
        inputSurfaceFrameInWindow = Self.rect(prefix: "inputSurfaceFrameInWindow", userInfo: userInfo)
        displayRotationDegrees = Self.intValue(userInfo["displayRotationDegrees"])
        absolutePointerTransportEnabled = userInfo["absolutePointerTransportEnabled"] as? Bool
        buttons = Self.intValue(userInfo["buttons"])
        details = userInfo["details"] as? [String: String] ?? [:]
    }

    private static func point(prefix: String, userInfo: [AnyHashable: Any]) -> EasyAutomationPoint? {
        guard let x = doubleValue(userInfo["\(prefix)X"]),
              let y = doubleValue(userInfo["\(prefix)Y"]) else {
            return nil
        }
        return EasyAutomationPoint(x: x, y: y)
    }

    private static func size(prefix: String, userInfo: [AnyHashable: Any]) -> EasyAutomationSize? {
        guard let width = doubleValue(userInfo["\(prefix)Width"]),
              let height = doubleValue(userInfo["\(prefix)Height"]) else {
            return nil
        }
        return EasyAutomationSize(width: width, height: height)
    }

    private static func rect(prefix: String, userInfo: [AnyHashable: Any]) -> EasyAutomationRect? {
        guard let x = doubleValue(userInfo["\(prefix)X"]),
              let y = doubleValue(userInfo["\(prefix)Y"]),
              let width = doubleValue(userInfo["\(prefix)Width"]),
              let height = doubleValue(userInfo["\(prefix)Height"]) else {
            return nil
        }
        return EasyAutomationRect(x: x, y: y, width: width, height: height)
    }

    private static func doubleValue(_ value: Any?) -> Double? {
        switch value {
        case let number as NSNumber:
            return number.doubleValue
        case let value as Double:
            return value
        case let value as CGFloat:
            return Double(value)
        case let value as Int:
            return Double(value)
        case let value as String:
            return Double(value)
        default:
            return nil
        }
    }

    private static func intValue(_ value: Any?) -> Int? {
        switch value {
        case let number as NSNumber:
            return number.intValue
        case let value as Int:
            return value
        case let value as UInt8:
            return Int(value)
        case let value as String:
            return Int(value)
        default:
            return nil
        }
    }

    private static func boolValue(_ value: Any?) -> Bool? {
        switch value {
        case let number as NSNumber:
            return number.boolValue
        case let value as Bool:
            return value
        case let value as String:
            let lowercased = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if ["true", "yes", "1"].contains(lowercased) { return true }
            if ["false", "no", "0"].contains(lowercased) { return false }
            return nil
        default:
            return nil
        }
    }
}

private struct EasyAutomationRecordedMotion: Encodable {
    let gestureID: Int
    let sampleIndex: Int
    let phase: String
    let pointSpace: String?
    let timestampKind: String
    let timeDeltaMilliseconds: Double?
    let point: EasyAutomationPoint?
    let pointDelta: EasyAutomationPoint?
    let distancePoints: Double?
    let velocityPointsPerSecond: EasyAutomationPoint?
    let speedPointsPerSecond: Double?
    let accelerationPointsPerSecondSquared: EasyAutomationPoint?
    let accelerationMagnitudePointsPerSecondSquared: Double?
    let impulsePointsPerSecond: EasyAutomationPoint?
    let impulseMagnitudePointsPerSecond: Double?
    let cumulativeDistancePoints: Double
    let cumulativeImpulseMagnitudePointsPerSecond: Double
    let peakSpeedPointsPerSecond: Double
    let peakAccelerationMagnitudePointsPerSecondSquared: Double
    let eventDelta: EasyAutomationPoint?
    let eventDeltaMagnitude: Double?
    let eventDeltaVelocityUnitsPerSecond: EasyAutomationPoint?
    let eventDeltaSpeedUnitsPerSecond: Double?
    let scrollingDelta: EasyAutomationPoint?
    let scrollingDeltaMagnitude: Double?
}

private struct EasyAutomationMotionTracker {
    private struct MotionState {
        let timestamp: TimeInterval
        let timestampKind: String
        let point: CGPoint?
        let velocity: CGPoint?
    }

    private var nextGestureID = 1
    private var currentGestureID: Int?
    private var sampleIndex = 0
    private var cumulativeDistancePoints = 0.0
    private var cumulativeImpulseMagnitudePointsPerSecond = 0.0
    private var peakSpeedPointsPerSecond = 0.0
    private var peakAccelerationMagnitudePointsPerSecondSquared = 0.0
    private var previousState: MotionState?

    mutating func sample(
        for input: EasyAutomationRecordedInput,
        recorderTimestamp: TimeInterval,
        elapsedMilliseconds: Int
    ) -> EasyAutomationRecordedMotion? {
        guard input.kind == "pointer" || input.kind == "scroll" else { return nil }

        let startsGesture = input.kind == "pointer" && ["down", "dragStart"].contains(input.phase)
        let endsGesture = input.kind == "pointer" && ["up", "dragEnd"].contains(input.phase)
        if startsGesture || currentGestureID == nil {
            beginGesture()
        }

        guard let gestureID = currentGestureID else { return nil }

        let pointSelection = selectedPoint(for: input)
        let point = pointSelection.point
        let timestampKind = input.nativeEventTimestamp == nil ? "recorder" : "nativeEvent"
        let timestamp = input.nativeEventTimestamp ?? recorderTimestamp
        let eventDeltaPoint = input.eventDelta?.cgPoint
        let scrollingDeltaPoint = input.scrollingDelta?.cgPoint

        sampleIndex += 1

        let previous = previousState
        let timeDeltaSeconds: Double?
        if let previous, previous.timestampKind == timestampKind {
            let delta = timestamp - previous.timestamp
            timeDeltaSeconds = delta.isFinite && delta > 0 ? delta : nil
        } else {
            timeDeltaSeconds = nil
        }

        let pointDelta = delta(from: previous?.point, to: point)
        let distance = pointDelta.map(Self.magnitude)
        let velocity = vector(pointDelta, dividedBy: timeDeltaSeconds)
        let speed = velocity.map(Self.magnitude)
        let velocityDelta = delta(from: previous?.velocity, to: velocity)
        let acceleration = vector(velocityDelta, dividedBy: timeDeltaSeconds)
        let accelerationMagnitude = acceleration.map(Self.magnitude)
        let impulse = velocityDelta
        let impulseMagnitude = impulse.map(Self.magnitude)
        let eventDeltaVelocity = vector(eventDeltaPoint, dividedBy: timeDeltaSeconds)
        let eventDeltaSpeed = eventDeltaVelocity.map(Self.magnitude)

        if let distance {
            cumulativeDistancePoints += distance
        }
        if let impulseMagnitude {
            cumulativeImpulseMagnitudePointsPerSecond += impulseMagnitude
        }
        if let speed {
            peakSpeedPointsPerSecond = max(peakSpeedPointsPerSecond, speed)
        }
        if let accelerationMagnitude {
            peakAccelerationMagnitudePointsPerSecondSquared = max(
                peakAccelerationMagnitudePointsPerSecondSquared,
                accelerationMagnitude
            )
        }

        let motion = EasyAutomationRecordedMotion(
            gestureID: gestureID,
            sampleIndex: sampleIndex,
            phase: input.phase,
            pointSpace: pointSelection.space,
            timestampKind: timestampKind,
            timeDeltaMilliseconds: timeDeltaSeconds.map { $0 * 1000 },
            point: point.map(EasyAutomationPoint.init),
            pointDelta: pointDelta.map(EasyAutomationPoint.init),
            distancePoints: distance,
            velocityPointsPerSecond: velocity.map(EasyAutomationPoint.init),
            speedPointsPerSecond: speed,
            accelerationPointsPerSecondSquared: acceleration.map(EasyAutomationPoint.init),
            accelerationMagnitudePointsPerSecondSquared: accelerationMagnitude,
            impulsePointsPerSecond: impulse.map(EasyAutomationPoint.init),
            impulseMagnitudePointsPerSecond: impulseMagnitude,
            cumulativeDistancePoints: cumulativeDistancePoints,
            cumulativeImpulseMagnitudePointsPerSecond: cumulativeImpulseMagnitudePointsPerSecond,
            peakSpeedPointsPerSecond: peakSpeedPointsPerSecond,
            peakAccelerationMagnitudePointsPerSecondSquared: peakAccelerationMagnitudePointsPerSecondSquared,
            eventDelta: eventDeltaPoint.map(EasyAutomationPoint.init),
            eventDeltaMagnitude: eventDeltaPoint.map(Self.magnitude),
            eventDeltaVelocityUnitsPerSecond: eventDeltaVelocity.map(EasyAutomationPoint.init),
            eventDeltaSpeedUnitsPerSecond: eventDeltaSpeed,
            scrollingDelta: scrollingDeltaPoint.map(EasyAutomationPoint.init),
            scrollingDeltaMagnitude: scrollingDeltaPoint.map(Self.magnitude)
        )

        previousState = MotionState(
            timestamp: timestamp,
            timestampKind: timestampKind,
            point: point,
            velocity: velocity
        )

        if endsGesture {
            endGesture()
        }

        return motion
    }

    private mutating func beginGesture() {
        currentGestureID = nextGestureID
        nextGestureID += 1
        sampleIndex = 0
        cumulativeDistancePoints = 0
        cumulativeImpulseMagnitudePointsPerSecond = 0
        peakSpeedPointsPerSecond = 0
        peakAccelerationMagnitudePointsPerSecondSquared = 0
        previousState = nil
    }

    private mutating func endGesture() {
        currentGestureID = nil
        sampleIndex = 0
        previousState = nil
    }

    private func selectedPoint(for input: EasyAutomationRecordedInput) -> (space: String?, point: CGPoint?) {
        if let point = input.phonePoint {
            return ("phonePoint", point.cgPoint)
        }
        if let point = input.virtualPointerPoint {
            return ("virtualPointerPoint", point.cgPoint)
        }
        if let point = input.localPoint {
            return ("localPoint", point.cgPoint)
        }
        return (nil, nil)
    }

    private func delta(from previous: CGPoint?, to current: CGPoint?) -> CGPoint? {
        guard let previous, let current else { return nil }
        let result = CGPoint(x: current.x - previous.x, y: current.y - previous.y)
        guard result.x.isFinite, result.y.isFinite else { return nil }
        return result
    }

    private func vector(_ value: CGPoint?, dividedBy interval: Double?) -> CGPoint? {
        guard let value, let interval, interval > .ulpOfOne else { return nil }
        let result = CGPoint(x: value.x / interval, y: value.y / interval)
        guard result.x.isFinite, result.y.isFinite else { return nil }
        return result
    }

    private static func magnitude(_ point: CGPoint) -> Double {
        hypot(Double(point.x), Double(point.y))
    }
}

private struct EasyAutomationGeometrySnapshot: Encodable {
    let activeVideoSource: String
    let streamHealth: String
    let framePresent: Bool
    let frameSize: EasyAutomationSize?
    let activeVideoIsLive: Bool
    let bluetoothHIDConnected: Bool
    let interruptChannelConnected: Bool
    let inputGateEnabled: Bool
    let inputGateReason: String
    let pointerSurfaceSize: EasyAutomationSize
    let pointerSurfaceOrientation: String
    let inputSurfaceFrame: EasyAutomationRect?
    let displayRotationDegrees: Int
    let absolutePointerTransportEnabled: Bool

    init(status: EasyAgentStatusSnapshot) {
        activeVideoSource = status.activeVideoSource
        streamHealth = status.streamHealth
        framePresent = status.framePresent
        if let width = status.frameWidth, let height = status.frameHeight {
            frameSize = EasyAutomationSize(width: Double(width), height: Double(height))
        } else {
            frameSize = nil
        }
        activeVideoIsLive = status.activeVideoIsLive
        bluetoothHIDConnected = status.input.bluetoothHIDConnected
        interruptChannelConnected = status.input.interruptChannelConnected
        inputGateEnabled = status.input.inputGateEnabled
        inputGateReason = status.input.inputGateReason
        pointerSurfaceSize = EasyAutomationSize(
            width: status.input.pointerSurfaceWidth,
            height: status.input.pointerSurfaceHeight
        )
        pointerSurfaceOrientation = status.input.pointerSurfaceOrientation
        if let x = status.input.inputSurfaceFrameX,
           let y = status.input.inputSurfaceFrameY,
           let width = status.input.inputSurfaceFrameWidth,
           let height = status.input.inputSurfaceFrameHeight {
            inputSurfaceFrame = EasyAutomationRect(x: x, y: y, width: width, height: height)
        } else {
            inputSurfaceFrame = nil
        }
        displayRotationDegrees = status.input.displayRotationDegrees
        absolutePointerTransportEnabled = status.input.absolutePointerTransportEnabled
    }
}

private struct EasyAutomationRecordedFrame: Encodable {
    let sequence: Int
    let eventSequence: Int
    let relativePath: String
    let width: Int
    let height: Int
    let timestamp: TimeInterval
}

private struct EasyAutomationPoint: Encodable {
    let x: Double
    let y: Double

    var cgPoint: CGPoint {
        CGPoint(x: x, y: y)
    }

    init(x: Double, y: Double) {
        self.x = x
        self.y = y
    }

    init(_ point: CGPoint) {
        x = Double(point.x)
        y = Double(point.y)
    }
}

private struct EasyAutomationSize: Encodable {
    let width: Double
    let height: Double
}

private struct EasyAutomationRect: Encodable {
    let x: Double
    let y: Double
    let width: Double
    let height: Double
}
