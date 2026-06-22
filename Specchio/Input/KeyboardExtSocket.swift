import Foundation
import Network
import os.log

private let log = Logger(subsystem: "com.alexintosh.Specchio", category: "KeyboardExt")

/// TCP server that the Specchio keyboard extension on iOS connects to.
/// Listens on port 9400 via NWListener and advertises `_specchio._tcp` via
/// NetService (older Bonjour API — NWListener.Service fails with -65555 NoAuth).
/// The iOS containing app discovers this service, resolves the IP, and stores it
/// in App Group UserDefaults. The keyboard extension then connects directly.
final class KeyboardExtSocket: @unchecked Sendable {
    private var listener: NWListener?
    private var connection: NWConnection?
    private var bonjourService: NetService?
    private let queue = DispatchQueue(label: "com.specchio.keyboardext")

    /// Called on state changes (connected/disconnected). Fired on arbitrary thread.
    var onStateChange: ((Bool) -> Void)?

    private var _connected = false
    var isConnected: Bool {
        queue.sync { _connected }
    }

    // MARK: - Lifecycle

    func startListening() {
        queue.async { [self] in
            guard listener == nil else { return }

            do {
                listener = try NWListener(using: .tcp, on: 9400)
            } catch {
                log.error("KeyboardExtServer: failed to create listener: \(error.localizedDescription)")
                return
            }

            listener?.stateUpdateHandler = { [weak self] state in
                switch state {
                case .setup:
                    log.info("KeyboardExtServer: listener setup")
                case .ready:
                    log.info("KeyboardExtServer: listening on port 9400")
                    self?.startBonjourAdvertisement()
                case .waiting(let error):
                    log.info("KeyboardExtServer: listener WAITING: \(error.localizedDescription)")
                case .failed(let error):
                    log.error("KeyboardExtServer: listener FAILED: \(error.localizedDescription)")
                    self?.queue.async { self?.listener?.cancel() }
                case .cancelled:
                    log.info("KeyboardExtServer: listener cancelled")
                @unknown default:
                    break
                }
            }

            listener?.newConnectionHandler = { [weak self] newConn in
                self?.acceptConnection(newConn)
            }

            listener?.start(queue: queue)
        }
    }

    func stopListening() {
        queue.async { [self] in
            let conn = connection
            connection = nil
            let wasConnected = _connected
            _connected = false
            conn?.cancel()

            listener?.cancel()
            listener = nil

            bonjourService?.stop()
            bonjourService = nil

            if wasConnected {
                onStateChange?(false)
            }
        }
    }

    // MARK: - Bonjour (NetService)

    private func startBonjourAdvertisement() {
        // NetService is deprecated but reliable — NWListener.Service fails with -65555 NoAuth
        let service = NetService(domain: "", type: "_specchio._tcp.", name: "Specchio", port: 9400)
        bonjourService = service
        service.publish()
        log.info("KeyboardExtServer: Bonjour _specchio._tcp advertised via NetService")
    }

    // MARK: - Send

    func sendText(_ text: String) {
        send(["type": "insert", "text": text])
    }

    /// Paste: keyboard extension reads UIPasteboard and inserts.
    func sendPaste() {
        send(["type": "paste"])
    }

    func sendDelete(count: Int = 1) {
        send(["type": "delete", "count": count])
    }

    func sendMoveCursor(offset: Int) {
        send(["type": "move", "offset": offset])
    }

    // MARK: - Private

    private func acceptConnection(_ newConn: NWConnection) {
        log.info("KeyboardExtServer: incoming connection from extension")

        let oldConn = connection
        connection = nil
        let wasConnected = _connected
        _connected = false
        oldConn?.cancel()

        connection = newConn

        newConn.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                log.info("KeyboardExtServer: extension connected")
                self._connected = true
                self.onStateChange?(true)
            case .failed(let error):
                log.warning("KeyboardExtServer: connection failed: \(error.localizedDescription)")
                self.handleDisconnect(newConn)
            case .cancelled:
                self.handleDisconnect(newConn)
            default:
                break
            }
        }

        newConn.start(queue: queue)

        if wasConnected {
            onStateChange?(false)
        }
    }

    private func send(_ dict: [String: Any]) {
        let connected = queue.sync { _connected }
        guard connected else { return }

        guard let data = try? JSONSerialization.data(withJSONObject: dict),
              var line = String(data: data, encoding: .utf8) else { return }
        line.append("\n")

        queue.async { [self] in
            connection?.send(content: line.data(using: .utf8), completion: .contentProcessed { [weak self] error in
                if let error {
                    log.warning("KeyboardExtServer: send failed: \(error.localizedDescription)")
                    self?.handleDisconnect(self?.connection)
                }
            })
        }
    }

    private func handleDisconnect(_ conn: NWConnection?) {
        queue.async { [self] in
            guard connection === conn else { return }
            let wasConnected = _connected
            connection?.cancel()
            connection = nil
            _connected = false

            if wasConnected {
                log.info("KeyboardExtServer: extension disconnected")
                onStateChange?(false)
            }
        }
    }
}
