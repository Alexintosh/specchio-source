import Foundation
import Network
import os.log

// MARK: - Command model

enum InputCommand {
    case insert(String)
    case delete(Int)
    case move(Int)
    case paste
}

// MARK: - InputServer (direct TCP via App Group IP)

/// Reads the Mac host IP from App Group shared UserDefaults (written by the containing app
/// after Bonjour discovery) and connects directly via plain TCP to port 9400.
/// This avoids NWBrowser which does NOT work from keyboard extension sandboxes (error -65563).
final class InputServer {

    // MARK: Public callbacks

    var onCommand: ((InputCommand) -> Void)?
    var onConnectionChange: ((Bool) -> Void)?
    /// Debug status string for UI overlay (per CLAUDE.md observability requirement)
    var onStatusChange: ((String) -> Void)?

    // MARK: Private state

    private var connection: NWConnection?
    private var receiveBuffer = Data()
    private var isStopped = false
    private var retryWork: DispatchWorkItem?

    private let sharedDefaults = UserDefaults(suiteName: "group.com.alexintosh.SpecchioKeyboard")
    private let log = OSLog(subsystem: "com.alexintosh.SpecchioKeyboard", category: "InputClient")

    // MARK: Lifecycle

    func start() {
        isStopped = false
        os_log("[InputClient] starting — reading Mac IP from App Group (direct TCP, no Bonjour)", log: log, type: .info)
        connectToStoredHost()
    }

    func stop() {
        os_log("[InputClient] stopping", log: log, type: .info)
        isStopped = true
        retryWork?.cancel()
        retryWork = nil
        connection?.cancel()
        connection = nil
        receiveBuffer = Data()
        onConnectionChange?(false)
        onStatusChange?("Stopped")
    }

    // MARK: Connection handling

    private func connectToStoredHost() {
        guard !isStopped else { return }

        guard let ip = sharedDefaults?.string(forKey: "macHostIP"), !ip.isEmpty else {
            os_log("[InputClient] no Mac IP in App Group — open Specchio Companion first", log: log, type: .info)
            onStatusChange?("No Mac IP — open Specchio Companion")
            scheduleRetry()
            return
        }

        os_log("[InputClient] connecting to %{public}@:9400 (direct TCP)", log: log, type: .info, ip)
        onStatusChange?("Connecting to \(ip):9400...")

        connection?.cancel()
        connection = nil
        receiveBuffer = Data()

        let conn = NWConnection(
            host: NWEndpoint.Host(ip),
            port: 9400,
            using: .tcp
        )
        connection = conn

        conn.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .setup:
                os_log("[InputClient] conn: setup", log: self.log, type: .info)
            case .preparing:
                os_log("[InputClient] conn: preparing", log: self.log, type: .info)
            case .ready:
                os_log("[InputClient] conn: READY — connected to Mac at %{public}@:9400", log: self.log, type: .info, ip)
                self.onConnectionChange?(true)
                self.onStatusChange?("Connected to \(ip)")
                self.scheduleReceive(on: conn)
            case .waiting(let error):
                os_log("[InputClient] conn: waiting — %{public}@", log: self.log, type: .info, error.localizedDescription)
                self.onStatusChange?("Waiting: \(error.localizedDescription)")
            case .failed(let error):
                os_log("[InputClient] conn: FAILED — %{public}@", log: self.log, type: .error, error.localizedDescription)
                self.onStatusChange?("Failed: \(error.localizedDescription)")
                self.handleDisconnect(conn)
            case .cancelled:
                os_log("[InputClient] conn: cancelled", log: self.log, type: .info)
                self.handleDisconnect(conn)
            @unknown default:
                break
            }
        }

        conn.start(queue: .main)
    }

    private func handleDisconnect(_ conn: NWConnection) {
        guard connection === conn else { return }
        connection = nil
        receiveBuffer = Data()
        onConnectionChange?(false)

        guard !isStopped else { return }
        scheduleRetry()
    }

    private func scheduleRetry() {
        guard !isStopped else { return }
        retryWork?.cancel()
        os_log("[InputClient] will retry in 3s", log: log, type: .info)
        onStatusChange?("Retrying in 3s...")
        let work = DispatchWorkItem { [weak self] in
            guard let self, !self.isStopped else { return }
            self.connectToStoredHost()
        }
        retryWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.0, execute: work)
    }

    // MARK: Receive loop

    private func scheduleReceive(on connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            guard let self else { return }

            if let data, !data.isEmpty {
                self.receiveBuffer.append(data)
                self.drainBuffer()
            }

            if let error {
                os_log("[InputClient] receive error: %{public}@", log: self.log, type: .error, error.localizedDescription)
                connection.cancel()
                return
            }

            if isComplete {
                os_log("[InputClient] remote closed", log: self.log, type: .info)
                connection.cancel()
                return
            }

            self.scheduleReceive(on: connection)
        }
    }

    // MARK: Buffer / protocol parsing

    private func drainBuffer() {
        while let newlineRange = receiveBuffer.range(of: Data([0x0A])) {
            let lineData = receiveBuffer[receiveBuffer.startIndex..<newlineRange.lowerBound]
            receiveBuffer.removeSubrange(receiveBuffer.startIndex..<newlineRange.upperBound)
            parseLine(lineData)
        }
    }

    private func parseLine(_ data: Data) {
        guard !data.isEmpty else { return }

        guard let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = dict["type"] as? String else {
            os_log("[InputClient] bad JSON (%d bytes)", log: log, type: .error, data.count)
            return
        }

        switch type {
        case "insert":
            if let text = dict["text"] as? String {
                os_log("[InputClient] insert(%{public}@)", log: log, type: .debug, text)
                onCommand?(.insert(text))
            }

        case "keys":
            if let values = dict["value"] as? [String] {
                let joined = values.joined()
                os_log("[InputClient] keys -> insert(%{public}@)", log: log, type: .debug, joined)
                onCommand?(.insert(joined))
            }

        case "delete":
            let count = dict["count"] as? Int ?? 1
            os_log("[InputClient] delete(%d)", log: log, type: .debug, count)
            onCommand?(.delete(count))

        case "move":
            if let offset = dict["offset"] as? Int {
                os_log("[InputClient] move(%d)", log: log, type: .debug, offset)
                onCommand?(.move(offset))
            }

        case "paste":
            os_log("[InputClient] paste", log: log, type: .debug)
            onCommand?(.paste)

        default:
            os_log("[InputClient] unknown type: %{public}@", log: log, type: .info, type)
        }
    }
}
