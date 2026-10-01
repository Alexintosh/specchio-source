import AppKit
import Combine
import CoreImage
import Darwin

/// Stable helper codes mapped to actionable text. No guessed diagnosis for
/// missing Bonjour records: Wi-Fi, sleep and discovery failures look identical.
enum CoreDeviceConnectionMessages {
    static func failure(_ code: String?) -> String {
        switch code {
        case "developer-mode-disabled":
            return "Enable Developer Mode on your iPhone in Settings > Privacy & Security > Developer Mode. Restart the iPhone and confirm when prompted, then press Connect again."
        case "developer-mode-status-unavailable":
            return "Specchio could not check Developer Mode. Connect the iPhone by USB, unlock it, and try again."
        case "wifi-device-not-found":
            return "No iPhone was found on the local network. Unlock your iPhone and check that it and this Mac are connected to the same Wi-Fi network, then try again."
        case "wifi-route-unavailable", "network-route-inspection-failed":
            return "No usable local-network route to the iPhone was found. Check the Mac’s Wi-Fi connection and whether a VPN is blocking local-network traffic."
        case "selected-device-not-reachable-on-lan":
            return "An iPhone was discovered, but Specchio could not connect to the paired device. Unlock it, check that both devices are on the same Wi-Fi, and check Specchio’s Local Network permission in System Settings."
        case "selected-device-network-pairing-missing", "select-exactly-one-paired-device":
            return "Specchio could not select a saved iPhone pairing. Connect the iPhone by USB, unlock it, and complete Wi-Fi pairing before trying again."
        case "network-pairing-repair-failed":
            return "The iPhone rejected the renewed Wi-Fi pairing. Keep it connected by USB, unlock it, and check Developer Mode before trying again."
        case "existing-media-session":
            return "The iPhone already has an active mirroring session. Stop the other session, then try again."
        case "connection-timed-out":
            return "The iPhone did not respond in time. Keep it unlocked, check the Wi-Fi connection, and try again."
        case "connection-lost":
            return "The connection to the iPhone ended unexpectedly. Check that both devices are still on the same Wi-Fi network, then reconnect."
        case "consumer-backlog":
            return "Specchio could not process the video quickly enough and stopped the stream. Try connecting again."
        case "primary-display-not-unique":
            return "The iPhone’s display could not be selected. Unlock the iPhone and try again."
        case "selected-usb-device-unavailable":
            return "The selected iPhone is not connected by USB. Reconnect and unlock it, then try again."
        default:
            return "Specchio could not complete the connection to the iPhone. Unlock it and try again. If this continues, share the CoreDevice connection logs."
        }
    }

    static func progress(_ state: String) -> String? {
        switch state {
        case "developer-mode.checking": return "Checking Developer Mode on your iPhone…"
        case "developer-mode.enabled": return "Developer Mode enabled · Connecting…"
        case "pairing.usb-required": return "Connect your iPhone by USB to check or restore Wi-Fi pairing. Specchio will continue automatically."
        case "pairing.unlock-required": return "Unlock your iPhone and accept Trust if prompted. Keep the USB cable connected; Specchio will retry automatically."
        case "pairing.verifying": return "Checking iPhone Wi-Fi pairing over USB…"
        case "pairing.repairing": return "Restoring iPhone Wi-Fi pairing…"
        case "pairing.repaired": return "Wi-Fi pairing restored · Connecting…"
        case "wifi.authentication-unavailable": return "Pairing is verified, but the Wi-Fi connection is still unavailable. Keep the iPhone unlocked on the same network; Specchio is retrying."
        case "wifi.searching": return "Searching for your iPhone on Wi-Fi…"
        case "tunnel.starting": return "Searching for your iPhone and connecting…"
        case "tunnel.connected": return "Connected to iPhone · Preparing video…"
        case "display.selected", "display.capability.response": return "Preparing iPhone display…"
        case "media.started", "video.configured": return "Waiting for the first video frame…"
        default: return nil
        }
    }
}

/// stderr may split JSON records across reads or end without a newline.
struct CoreDeviceDiagnosticBuffer {
    private var pending = Data()
    private(set) var failureCode: String?

    mutating func append(_ data: Data) -> [String] {
        pending.append(data)
        var lines: [String] = []
        while let newline = pending.firstIndex(of: 10) {
            let line = Data(pending[..<newline])
            pending.removeSubrange(...newline)
            if let text = consume(line) { lines.append(text) }
        }
        return lines
    }

    mutating func finish() -> [String] {
        defer { pending.removeAll() }
        return consume(pending).map { [$0] } ?? []
    }

    private mutating func consume(_ line: Data) -> String? {
        guard !line.isEmpty, let text = String(data: line, encoding: .utf8) else { return nil }
        if let record = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
           let stage = record["stage"] as? String,
           stage == "session.failed" || stage == "session.cleanup.failed",
           failureCode == nil {
            failureCode = record["code"] as? String ?? "connection-failed"
        }
        return text
    }
}

/// Reproduce physical key transitions: modifier down, key down, key up,
/// modifier up. One combined report loses the modifier-before-key transition.
enum CoreDeviceKeyboardChord {
    static func steps(usages: [Int], hold: Double) -> [[String: Any]] {
        let modifiers = usages.filter { (224...231).contains($0) }
        func report(_ keys: [Int]) -> [String: Any] { ["command": "keys", "usages": keys] }
        var result: [[String: Any]] = []
        if !modifiers.isEmpty { result.append(report(modifiers)) }
        result.append(report(usages))
        result.append(["command": "wait", "seconds": hold])
        if !modifiers.isEmpty { result.append(report(modifiers)) }
        result.append(report([]))
        return result
    }
}

/// Owns one helper process, its media decoder and its ordered shutdown.
@MainActor
final class CoreDeviceStreamManager: ObservableObject {
    @Published private(set) var currentFrame: CGImage?
    @Published private(set) var isActive = false {
        didSet { CoreDeviceDeviceStore.shared.sessionChanged(self, active: isActive) }
    }
    @Published private(set) var isStopping = false
    @Published private(set) var connectionError: String?
    @Published private(set) var showsDeveloperModeGuide = false
    @Published private(set) var status = "CoreDevice Wi-Fi"
    private var toolbarStatus: String?
    private var audioStatus = "Audio starting"
    private var worker: CoreDeviceWorker?

    func start() {
        guard !CoreDeviceDeviceStore.shared.isBusy else {
            connectionError = "Saved devices are being updated. Try connecting again when the operation finishes."
            SpecchioLogger.easyMode.info("[CoreDevice] start blocked branch=device-management-busy")
            return
        }
        guard worker == nil else {
            SpecchioLogger.easyMode.info("[CoreDevice] start ignored: session already owned")
            return
        }
        connectionError = nil
        showsDeveloperModeGuide = false
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let python = support.appendingPathComponent("Specchio/CoreDevice/venv/bin/python3")
        guard FileManager.default.isExecutableFile(atPath: python.path),
              let script = Bundle.main.url(forResource: "session", withExtension: "py", subdirectory: "coredevice") else {
            connectionError = "The CoreDevice component is missing from this installation. Install the CoreDevice runtime before trying again."
            status = "CoreDevice component unavailable"
            SpecchioLogger.easyMode.error("[CoreDevice] runtime unavailable python=\(python.path, privacy: .public)")
            return
        }
        status = "CoreDevice Wi-Fi · Connecting"
        isActive = true
        isStopping = false
        currentFrame = nil
        toolbarStatus = nil
        audioStatus = "Audio starting"
        let next = CoreDeviceWorker()
        worker = next
        next.onFrame = { [weak self, weak next] image in
            guard let self, self.worker === next, !self.isStopping else { return }
            self.currentFrame = image
            let status = "CoreDevice Wi-Fi · Video + input · \(self.audioStatus)" + (self.toolbarStatus.map { " · " + $0 } ?? "")
            if self.status != status { self.status = status }
        }
        next.onStatus = { [weak self, weak next] status in
            guard let self, self.worker === next, !self.isStopping else { return }
            if status.hasPrefix("toolbar.") || status == "input.failed" || status == "input.rejected" {
                switch status {
                case "toolbar.started": self.toolbarStatus = "Command running"
                case "toolbar.completed": self.toolbarStatus = "Command sent"
                case "toolbar.cancelled": self.toolbarStatus = "Command cancelled"
                default: self.toolbarStatus = "Command failed"
                }
                self.status = "CoreDevice Wi-Fi · " + (self.toolbarStatus ?? status)
                SpecchioLogger.easyMode.info("[CoreDevice toolbar] state=\(status, privacy: .public)")
            }
            if status.hasPrefix("audio.") {
                switch status {
                case "audio.playing": self.audioStatus = "Audio playing"
                case "audio.ready": self.audioStatus = "Audio ready"
                case "audio.failed": self.audioStatus = "Audio failed"
                default: self.audioStatus = "Audio starting"
                }
            }
            guard self.currentFrame == nil else { return }
            if let progress = CoreDeviceConnectionMessages.progress(status) {
                self.status = progress
            }
        }
        next.onEnd = { [weak self, weak next] code, failureCode in
            guard let self, self.worker === next else { return }
            let requestedStop = self.isStopping
            if !requestedStop && (code != 0 || failureCode != nil) {
                self.showsDeveloperModeGuide = failureCode == "developer-mode-disabled"
                self.connectionError = CoreDeviceConnectionMessages.failure(failureCode)
                self.status = "CoreDevice connection failed"
                SpecchioLogger.easyMode.error("[CoreDevice] failure surfaced code=\(failureCode ?? "unknown", privacy: .public) exit=\(code)")
            } else {
                self.status = "CoreDevice Wi-Fi"
                SpecchioLogger.easyMode.info("[CoreDevice] session ended requestedStop=\(requestedStop) exit=\(code)")
            }
            self.currentFrame = nil
            self.worker = nil
            self.isStopping = false
            self.isActive = false
            SpecchioLogger.easyMode.info("[CoreDevice] helper ended code=\(code)")
        }
        do {
            try next.start(python: python, script: script)
        } catch {
            worker = nil
            isActive = false
            connectionError = "Specchio could not start the CoreDevice component. Try reopening Specchio. If this continues, reinstall its CoreDevice runtime."
            status = "CoreDevice could not start"
            SpecchioLogger.easyMode.error("[CoreDevice] launch failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    func dismissConnectionError() {
        SpecchioLogger.easyMode.info("[CoreDevice] connection error dismissed")
        connectionError = nil
        showsDeveloperModeGuide = false
    }

    /// Same keyboard usages/timings as the Bluetooth toolbar, delivered as one
    /// cancellable helper sequence. No passcode or key values are logged.
    @discardableResult
    func performToolbar(_ command: EasyToolbarCommand, rotation: Int, dragY: Double, pin: [[Int]] = []) -> Bool {
        guard isActive, !isStopping, currentFrame != nil else {
            toolbarStatus = "Command unavailable: stream not ready"
            status = "CoreDevice Wi-Fi · " + toolbarStatus!
            SpecchioLogger.easyMode.info("[CoreDevice toolbar] rejected command=\(command.rawValue, privacy: .public) reason=stream-not-ready")
            return false
        }
        var steps: [[String: Any]] = []
        func wait(_ seconds: Double) { steps.append(["command": "wait", "seconds": seconds]) }
        func keys(_ usages: [Int], hold: Double) {
            steps.append(contentsOf: CoreDeviceKeyboardChord.steps(usages: usages, hold: hold))
        }
        func button(_ usage: Int) { steps.append(["command": "button", "usage": usage]) }
        switch command {
        case .home: button(0x40) // HID Consumer Menu, as in the validated viewer.
        case .volumeUp: button(0xE9) // IOHIDUsageTables: Volume Increment
        case .volumeDown: button(0xEA) // Volume Decrement
        case .mute: button(0xE2) // Mute
        case .search: keys([227, 0x2C], hold: 0.05)
        case .screenshot: keys([227, 225, 0x20], hold: 0.05)
        case .switchApps: keys([227, 0x2B], hold: 0.12)
        case .appSwitcher: keys([227, 0x2B], hold: 0.45)
        case .dragLeft, .dragRight:
            let count = max(2, EasyAgentEndpointDefaults.defaultDragSteps)
            let half = TrackpadSwipeDragMetrics.maximumSyntheticDragFractionOfSurface / 2
            let start = command == .dragLeft ? 0.5 + half : 0.5 - half
            let end = 1 - start
            let y = AppSettings.sanitizedEasyToolbarDragYCoordinateFraction(dragY)
            for index in 0..<count {
                let fraction = CGFloat(index) / CGFloat(count - 1)
                let point = InputSurfaceRotationMapping.phoneNormalizedPoint(
                    displayX: start + (end - start) * fraction, displayY: CGFloat(y), rotationDegrees: rotation)
                if index > 0 { wait(Double(EasyAgentEndpointDefaults.defaultDragDurationMilliseconds) / 1000 / Double(count - 1)) }
                steps.append(["command": "touch", "down": true, "x": point.x, "y": point.y])
                if index == count - 1 { steps.append(["command": "touch", "down": false, "x": point.x, "y": point.y]) }
            }
        case .autoUnlock:
            guard !pin.isEmpty else {
                SpecchioLogger.easyMode.info("[CoreDevice toolbar] unlock rejected: empty mapped passcode")
                return false
            }
            button(0x40)
            wait(EasyAutoUnlockSequenceTiming.homeToFirstReturn)
            keys([0x28], hold: EasyAutoUnlockSequenceTiming.keyHoldDuration)
            wait(EasyAutoUnlockSequenceTiming.firstReturnToPIN - EasyAutoUnlockSequenceTiming.keyHoldDuration)
            for usages in pin {
                keys(usages, hold: EasyAutoUnlockSequenceTiming.keyHoldDuration)
                wait(EasyAutoUnlockSequenceTiming.keySpacing - EasyAutoUnlockSequenceTiming.keyHoldDuration)
            }
            keys([0x28], hold: EasyAutoUnlockSequenceTiming.keyHoldDuration)
        default:
            SpecchioLogger.easyMode.info("[CoreDevice toolbar] ignored local command=\(command.rawValue, privacy: .public)")
            return false
        }
        SpecchioLogger.easyMode.info("[CoreDevice toolbar] dispatch command=\(command.rawValue, privacy: .public) transport=wifi keyboardTransitions=modifier-key-keyup-modifierup")
        send(["command": "sequence", "action": command.rawValue, "steps": steps])
        return true
    }

    func send(_ command: [String: Any]) { worker?.send(command) }

    func stop() {
        guard let worker, !isStopping else { return }
        SpecchioLogger.easyMode.info("[CoreDevice] ordered stop requested")
        isStopping = true
        status = "CoreDevice Wi-Fi · Stopping"
        currentFrame = nil
        worker.stop()
    }
}

private final class CoreDeviceWorker: @unchecked Sendable {
    let process = Process()
    private let commands = Pipe()
    private let video = Pipe()
    private let errors = Pipe()
    private let queue = DispatchQueue(label: "Specchio.CoreDevice.decode")
    private let diagnosticQueue = DispatchQueue(label: "Specchio.CoreDevice.diagnostics")
    private var diagnostics = CoreDeviceDiagnosticBuffer()
    private let diagnosticsFinished = DispatchGroup()
    private let inputQueue = DispatchQueue(label: "Specchio.CoreDevice.input")
    private let decoder = CoreDeviceHEVCDecoder()
    private let context = CIContext(options: [.useSoftwareRenderer: false])
    private let lock = NSLock()
    private var pendingImage: CGImage?
    private var presentationScheduled = false
    private var receivedFrame = false
    private var lastGeometry: CGRect?
    var onFrame: (@MainActor (CGImage) -> Void)?
    var onStatus: (@MainActor (String) -> Void)?
    var onEnd: (@MainActor (Int32, String?) -> Void)?

    func start(python: URL, script: URL) throws {
        process.executableURL = python
        process.arguments = [script.path, "--connection", "wifi", "--audio"]
        process.standardInput = commands
        process.standardOutput = video
        process.standardError = errors
        // A helper may exit between isRunning and write; keep EPIPE local to this FD.
        _ = fcntl(commands.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
        decoder.onFrame = { [weak self] pixel in
            guard let self else { return }
            let ci = CIImage(cvPixelBuffer: pixel)
            let clean = CVImageBufferGetCleanRect(pixel)
            let validClean = !clean.isEmpty && !clean.isInfinite && !clean.isNull && ci.extent.contains(clean)
            let crop = validClean ? clean : ci.extent
            if self.lastGeometry != crop {
                self.lastGeometry = crop
                SpecchioLogger.easyMode.info("[CoreDevice] display geometry buffer=\(NSStringFromRect(ci.extent), privacy: .public) clean=\(NSStringFromRect(clean), privacy: .public) crop=\(NSStringFromRect(crop), privacy: .public) source=\(validClean ? "clean-aperture" : "full-buffer", privacy: .public)")
            }
            guard let image = self.context.createCGImage(ci, from: crop) else { return }
            self.enqueue(image)
        }
        decoder.onError = { [weak self] status in
            SpecchioLogger.easyMode.error("[CoreDevice] decoder error=\(status)")
            self?.send(["command": "decode-error"])
        }
        process.terminationHandler = { [self] task in
            queue.async { [self] in
                decoder.close()
                try? commands.fileHandleForWriting.close()
                // Drain stderr through EOF before delivering completion. The final
                // structured error must survive a fast helper exit.
                diagnosticsFinished.wait()
                let failure = diagnostics.failureCode
                Task { @MainActor [self] in self.onEnd?(task.terminationStatus, failure) }
                process.terminationHandler = nil
            }
        }
        SpecchioLogger.easyMode.info("[CoreDevice] launching helper transport=wifi input=CoreDevice")
        diagnosticsFinished.enter()
        do { try process.run() }
        catch { diagnosticsFinished.leave(); throw error }
        diagnosticQueue.async { [self] in
            defer { diagnosticsFinished.leave() }
            readDiagnostics()
        }
        queue.async { [self] in readPackets() }
    }

    private func readDiagnostics() {
        func record(_ lines: [String]) {
            for text in lines { SpecchioLogger.easyMode.info("[CoreDevice helper] \(text, privacy: .public)") }
        }
        while true {
            // read(upToCount:) can fill its buffer before returning on pipes.
            // availableData emits the current chunk, keeping diagnostics live.
            let chunk = errors.fileHandleForReading.availableData
            if chunk.isEmpty { break }
            record(diagnostics.append(chunk))
        }
        record(diagnostics.finish())
    }

    private func enqueue(_ image: CGImage) {
        lock.lock()
        pendingImage = image
        let schedule = !presentationScheduled
        presentationScheduled = true
        lock.unlock()
        guard schedule else { return }
        Task { @MainActor [self] in
            let newest = lock.withLock {
                let image = pendingImage
                pendingImage = nil
                presentationScheduled = false
                return image
            }
            guard let newest else { return }
            if !receivedFrame {
                receivedFrame = true
                SpecchioLogger.easyMode.info("[CoreDevice] first frame presented width=\(newest.width) height=\(newest.height)")
                send(["command": "decoded"])
            }
            onFrame?(newest)
        }
    }

    func send(_ command: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: command) else { return }
        inputQueue.async { [self] in
            guard process.isRunning else { return }
            do { try commands.fileHandleForWriting.write(contentsOf: data + Data([10])) }
            catch { SpecchioLogger.easyMode.info("[CoreDevice] input pipe closed") }
        }
    }

    func stop() {
        send(["command": "release"])
        send(["command": "stop"])
        if process.isRunning { process.interrupt() }
    }

    private func readExactly(_ count: Int) throws -> Data {
        var data = Data()
        while data.count < count {
            guard let part = try video.fileHandleForReading.read(upToCount: count - data.count), !part.isEmpty else {
                throw NSError(domain: "CoreDeviceEOF", code: 0)
            }
            data.append(part)
        }
        return data
    }

    private func readPackets() {
        do {
            while true {
                let length = try readExactly(4).reduce(0) { ($0 << 8) | Int($1) }
                guard length > 0, length <= 32 * 1024 * 1024 else {
                    throw NSError(domain: "CoreDevicePacketSize", code: length)
                }
                let body = try readExactly(length)
                if body.first == 3 {
                    let object = try JSONSerialization.jsonObject(with: Data(body.dropFirst())) as? [String: Any]
                    if let state = object?["state"] as? String {
                        Task { @MainActor [self] in onStatus?(state) }
                    }
                } else { try decoder.consume(body) }
            }
        } catch {
            SpecchioLogger.easyMode.info("[CoreDevice] media reader ended: \(error.localizedDescription, privacy: .public)")
            stop()
        }
    }
}

/// Serializes settings mutations against connection startup in this app.
@MainActor
final class CoreDeviceDeviceStore: ObservableObject {
    struct Device: Decodable, Identifiable {
        let id: String
    }
    private struct Response: Decodable {
        let devices: [Device]
    }
    static let shared = CoreDeviceDeviceStore()
    @Published private(set) var devices: [Device] = []
    @Published private(set) var isBusy = false
    @Published private(set) var hasActiveSession = false
    @Published private(set) var message: String?
    private var sessions: Set<ObjectIdentifier> = []

    func sessionChanged(_ owner: CoreDeviceStreamManager, active: Bool) {
        if active { sessions.insert(ObjectIdentifier(owner)) }
        else { sessions.remove(ObjectIdentifier(owner)) }
        hasActiveSession = !sessions.isEmpty
    }

    func refresh() async { await perform(remove: nil) }
    func remove(_ device: Device) async { await perform(remove: device.id) }

    private func perform(remove identifier: String?) async {
        guard !isBusy else {
            SpecchioLogger.easyMode.info("[CoreDevice Devices] operation skipped branch=busy")
            return
        }
        guard identifier == nil || !hasActiveSession else {
            message = "Disconnect your iPhone or cancel the connection before removing its pairing."
            SpecchioLogger.easyMode.info("[CoreDevice Devices] removal blocked branch=active-session")
            return
        }
        isBusy = true
        message = nil
        defer { isBusy = false }
        SpecchioLogger.easyMode.info("[CoreDevice Devices] operation started remove=\(identifier != nil)")
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let python = support.appendingPathComponent("Specchio/CoreDevice/venv/bin/python3")
        guard FileManager.default.isExecutableFile(atPath: python.path),
              let script = Bundle.main.url(forResource: "devices", withExtension: "py", subdirectory: "coredevice") else {
            message = "CoreDevice components are unavailable. Install the CoreDevice runtime to manage devices."
            SpecchioLogger.easyMode.error("[CoreDevice Devices] operation failed branch=runtime-missing")
            return
        }
        do {
            let data = try await Self.run(python: python, script: script, identifier: identifier)
            devices = try JSONDecoder().decode(Response.self, from: data).devices
            if identifier != nil {
                message = "Wi-Fi pairing removed. Connect the iPhone by USB, unlock it, then press Connect to pair it again."
            }
            SpecchioLogger.easyMode.info("[CoreDevice Devices] operation completed count=\(self.devices.count) removed=\(identifier != nil)")
        } catch {
            message = "Could not update saved devices. Refresh the list and try again."
            SpecchioLogger.easyMode.error("[CoreDevice Devices] operation failed")
        }
    }

    private nonisolated static func run(python: URL, script: URL, identifier: String?) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                let output = Pipe()
                process.executableURL = python
                process.arguments = [script.path] + (identifier.map { ["--remove", $0] } ?? [])
                process.standardOutput = output
                process.standardError = FileHandle.nullDevice
                do {
                    try process.run()
                    let data = output.fileHandleForReading.readDataToEndOfFile()
                    process.waitUntilExit()
                    guard process.terminationStatus == 0 else {
                        throw NSError(domain: "CoreDeviceDevices", code: Int(process.terminationStatus))
                    }
                    continuation.resume(returning: data)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }
}
