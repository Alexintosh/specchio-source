import Foundation
import Network

private let airPlayMirrorLog = SpecchioLogger.airPlay

final class AirPlayMirrorDataServer {
    enum Event {
        case ready(port: UInt16)
        case failed(String)
        case clientState(String)
        case packet(AirPlayMirrorPacket, Data)
        case stopped
    }

    private let queue: DispatchQueue
    private let onEvent: (Event) -> Void
    private var listener: NWListener?
    private var connection: NWConnection?
    private var receivedPacketCount = 0
    private let maximumPayloadBytes = 20 * 1024 * 1024

    init(queue: DispatchQueue, onEvent: @escaping (Event) -> Void) {
        self.queue = queue
        self.onEvent = onEvent
    }

    func start() {
        guard listener == nil else {
            airPlayMirrorLog.info("[AirPlayMirrorData] start skipped reason=listener-already-active")
            return
        }

        do {
            let listener = try NWListener(using: .tcp)
            self.listener = listener
            listener.stateUpdateHandler = { [weak self] state in
                self?.handleListenerState(state)
            }
            listener.newConnectionHandler = { [weak self] connection in
                self?.accept(connection)
            }
            listener.start(queue: queue)
            airPlayMirrorLog.info("[AirPlayMirrorData] listener start requested port=system-assigned")
        } catch {
            airPlayMirrorLog.error("[AirPlayMirrorData] listener create failed error=\(error.localizedDescription, privacy: .public)")
            onEvent(.failed(error.localizedDescription))
        }
    }

    func stop(reason: String) {
        airPlayMirrorLog.info("[AirPlayMirrorData] stop requested reason=\(reason, privacy: .public) packetCount=\(self.receivedPacketCount)")
        connection?.cancel()
        connection = nil
        listener?.cancel()
        listener = nil
        receivedPacketCount = 0
        onEvent(.stopped)
    }

    private func handleListenerState(_ state: NWListener.State) {
        switch state {
        case .ready:
            guard let port = listener?.port?.rawValue else {
                airPlayMirrorLog.error("[AirPlayMirrorData] listener ready without port")
                onEvent(.failed("mirror listener ready without a port"))
                return
            }
            airPlayMirrorLog.info("[AirPlayMirrorData] listener ready port=\(port)")
            onEvent(.ready(port: port))
        case .waiting(let error):
            airPlayMirrorLog.warning("[AirPlayMirrorData] listener waiting error=\(error.localizedDescription, privacy: .public)")
            onEvent(.failed("mirror listener waiting: \(error.localizedDescription)"))
        case .failed(let error):
            airPlayMirrorLog.error("[AirPlayMirrorData] listener failed error=\(error.localizedDescription, privacy: .public)")
            onEvent(.failed(error.localizedDescription))
        case .cancelled:
            airPlayMirrorLog.info("[AirPlayMirrorData] listener cancelled")
        case .setup:
            airPlayMirrorLog.info("[AirPlayMirrorData] listener state=setup")
        @unknown default:
            airPlayMirrorLog.warning("[AirPlayMirrorData] listener unknown state")
        }
    }

    private func accept(_ newConnection: NWConnection) {
        airPlayMirrorLog.info("[AirPlayMirrorData] client accepted endpoint=\(String(describing: newConnection.endpoint), privacy: .public)")
        connection?.cancel()
        connection = newConnection
        newConnection.stateUpdateHandler = { [weak self, weak newConnection] state in
            guard let self, let newConnection else { return }
            self.handleConnectionState(state, connection: newConnection)
        }
        newConnection.start(queue: queue)
    }

    private func handleConnectionState(_ state: NWConnection.State, connection: NWConnection) {
        switch state {
        case .ready:
            airPlayMirrorLog.info("[AirPlayMirrorData] client ready")
            onEvent(.clientState("ready"))
            let packetCountAtReady = receivedPacketCount
            queue.asyncAfter(deadline: .now() + 3) { [weak self, weak connection] in
                guard let self,
                      let connection,
                      connection === self.connection,
                      self.receivedPacketCount == packetCountAtReady else {
                    return
                }
                airPlayMirrorLog.warning("[AirPlayMirrorData] client ready but no packets after 3s packetCount=\(self.receivedPacketCount)")
                self.onEvent(.clientState("ready-no-packets"))
            }
            receiveHeader(on: connection)
        case .waiting(let error):
            airPlayMirrorLog.warning("[AirPlayMirrorData] client waiting error=\(error.localizedDescription, privacy: .public)")
            onEvent(.clientState("waiting: \(error.localizedDescription)"))
        case .failed(let error):
            airPlayMirrorLog.error("[AirPlayMirrorData] client failed error=\(error.localizedDescription, privacy: .public)")
            onEvent(.clientState("failed: \(error.localizedDescription)"))
        case .cancelled:
            airPlayMirrorLog.info("[AirPlayMirrorData] client cancelled")
            onEvent(.clientState("cancelled"))
        case .setup, .preparing:
            airPlayMirrorLog.info("[AirPlayMirrorData] client state=\(String(describing: state), privacy: .public)")
        @unknown default:
            airPlayMirrorLog.warning("[AirPlayMirrorData] client unknown state")
        }
    }

    private func receiveHeader(on connection: NWConnection) {
        guard connection === self.connection else {
            airPlayMirrorLog.info("[AirPlayMirrorData] header receive skipped reason=stale-connection")
            return
        }

        connection.receive(
            minimumIncompleteLength: AirPlayMirrorPacket.headerByteCount,
            maximumLength: AirPlayMirrorPacket.headerByteCount
        ) { [weak self, weak connection] data, _, isComplete, error in
            guard let self, let connection else { return }

            if let error {
                airPlayMirrorLog.error("[AirPlayMirrorData] header receive failed error=\(error.localizedDescription, privacy: .public)")
                self.onEvent(.clientState("header receive failed: \(error.localizedDescription)"))
                return
            }

            if isComplete {
                airPlayMirrorLog.info("[AirPlayMirrorData] peer closed before header")
                self.onEvent(.clientState("peer closed before header"))
                return
            }

            guard let data, data.count == AirPlayMirrorPacket.headerByteCount else {
                airPlayMirrorLog.warning("[AirPlayMirrorData] malformed header bytes=\(data?.count ?? 0)")
                self.receiveHeader(on: connection)
                return
            }

            if data.starts(with: Data("POST".utf8)) || data.starts(with: Data("GET".utf8)) {
                airPlayMirrorLog.info("[AirPlayMirrorData] HTTP-like data request observed on mirror socket; ignoring bytes=\(data.count)")
                self.receiveHeader(on: connection)
                return
            }

            guard let packet = AirPlayMirrorPacket(headerData: data) else {
                airPlayMirrorLog.warning("[AirPlayMirrorData] packet header parse failed bytes=\(data.count)")
                self.receiveHeader(on: connection)
                return
            }

            self.receivePayload(for: packet, on: connection)
        }
    }

    private func receivePayload(for packet: AirPlayMirrorPacket, on connection: NWConnection) {
        guard packet.payloadSize >= 0, packet.payloadSize <= maximumPayloadBytes else {
            airPlayMirrorLog.error("[AirPlayMirrorData] payload too large size=\(packet.payloadSize) max=\(self.maximumPayloadBytes)")
            onEvent(.clientState("payload too large: \(packet.payloadSize)"))
            connection.cancel()
            return
        }

        connection.receive(minimumIncompleteLength: packet.payloadSize, maximumLength: packet.payloadSize) { [weak self, weak connection] data, _, isComplete, error in
            guard let self, let connection else { return }

            if let error {
                airPlayMirrorLog.error("[AirPlayMirrorData] payload receive failed error=\(error.localizedDescription, privacy: .public)")
                self.onEvent(.clientState("payload receive failed: \(error.localizedDescription)"))
                return
            }

            if isComplete {
                airPlayMirrorLog.info("[AirPlayMirrorData] peer closed before payload")
                self.onEvent(.clientState("peer closed before payload"))
                return
            }

            let payload = data ?? Data()
            guard payload.count == packet.payloadSize else {
                airPlayMirrorLog.warning("[AirPlayMirrorData] incomplete payload type=\(packet.payloadType) bytes=\(payload.count) expected=\(packet.payloadSize)")
                self.receiveHeader(on: connection)
                return
            }

            self.receivedPacketCount += 1
            if self.receivedPacketCount <= 20 || self.receivedPacketCount % 120 == 0 {
                airPlayMirrorLog.info("[AirPlayMirrorData] packet count=\(self.receivedPacketCount) \(packet.diagnosticDescription, privacy: .public)")
            } else {
                airPlayMirrorLog.debug("[AirPlayMirrorData] packet count=\(self.receivedPacketCount) \(packet.diagnosticDescription, privacy: .public)")
            }
            self.onEvent(.packet(packet, payload))
            self.receiveHeader(on: connection)
        }
    }
}
