import Foundation
import Network
import os.log

private let log = Logger(subsystem: "com.specchio", category: "InputSocket")

/// Fire-and-forget TCP channel for low-latency input to WDA.
/// Sends newline-delimited JSON over a plain TCP socket.
/// Falls back silently — callers check `isConnected`.
final class WDAInputSocket: @unchecked Sendable {
    private let host: String
    private let port: UInt16
    private var connection: NWConnection?
    private let queue = DispatchQueue(label: "com.specchio.inputsocket")
    private var reconnectWork: DispatchWorkItem?

    /// Called on state changes (connected/disconnected). Fired on arbitrary thread.
    var onStateChange: ((Bool) -> Void)?

    private var _connected = false
    var isConnected: Bool {
        queue.sync { _connected }
    }

    init(host: String, port: UInt16) {
        self.host = host
        self.port = port
    }

    // MARK: - Lifecycle

    func connect() {
        queue.async { [self] in
            guard connection == nil else { return }

            let conn = NWConnection(
                host: NWEndpoint.Host(host),
                port: NWEndpoint.Port(rawValue: port)!,
                using: .tcp
            )

            conn.stateUpdateHandler = { [weak self] state in
                guard let self else { return }
                switch state {
                case .ready:
                    log.info("Connected to \(self.host):\(self.port)")
                    self.queue.async {
                        self._connected = true
                    }
                    self.onStateChange?(true)
                case .failed(let error):
                    log.warning("Connection failed: \(error.localizedDescription)")
                    self.handleDisconnect()
                case .cancelled:
                    break
                default:
                    break
                }
            }

            connection = conn
            conn.start(queue: queue)
        }
    }

    func disconnect() {
        queue.async { [self] in
            reconnectWork?.cancel()
            reconnectWork = nil
            let conn = connection
            connection = nil
            let wasConnected = _connected
            _connected = false
            conn?.cancel()
            if wasConnected {
                onStateChange?(false)
            }
        }
    }

    // MARK: - Send (fire-and-forget)

    func sendKeys(_ text: String, frequency: Int? = nil, modifierFlags: Int? = nil) {
        var dict: [String: Any] = [
            "type": "keys",
            "value": Array(text).map { String($0) }
        ]
        if let freq = frequency {
            dict["frequency"] = freq
        }
        if let mods = modifierFlags {
            dict["modifierFlags"] = mods
        }
        send(dict)
    }

    func sendTap(x: Double, y: Double) {
        send(["type": "tap", "x": x, "y": y])
    }

    func sendSwipe(fromX: Double, fromY: Double,
                   toX: Double, toY: Double, duration: Int) {
        send([
            "type": "swipe",
            "fromX": fromX, "fromY": fromY,
            "toX": toX, "toY": toY,
            "duration": duration
        ])
    }

    func sendButton(_ name: String) {
        send(["type": "button", "name": name])
    }

    func sendTypeKey(_ keyName: String, modifierFlags: Int = 0) {
        send(["type": "typeKey", "key": keyName, "modifierFlags": modifierFlags])
    }

    // MARK: - Private

    private func send(_ dict: [String: Any]) {
        let connected = queue.sync { _connected }
        guard connected else { return }

        guard let data = try? JSONSerialization.data(withJSONObject: dict),
              var line = String(data: data, encoding: .utf8) else { return }
        line.append("\n")

        queue.async { [self] in
            connection?.send(content: line.data(using: .utf8), completion: .contentProcessed { [weak self] error in
                if let error {
                    log.warning("Send failed: \(error.localizedDescription)")
                    self?.handleDisconnect()
                }
            })
        }
    }

    private func handleDisconnect() {
        queue.async { [self] in
            let wasConnected = _connected
            connection?.cancel()
            connection = nil
            _connected = false

            guard reconnectWork == nil else { return }

            let work = DispatchWorkItem { [weak self] in
                guard let self else { return }
                self.queue.async {
                    self.reconnectWork = nil
                }
                self.connect()
            }
            reconnectWork = work
            queue.asyncAfter(deadline: .now() + 2.0, execute: work)

            if wasConnected {
                log.info("Disconnected, will reconnect in 2s")
                onStateChange?(false)
            } else {
                log.info("Connection failed, will retry in 2s")
            }
        }
    }
}
