import Foundation
import Network

private let airPlayControlLog = SpecchioLogger.airPlay

final class AirPlayControlServer {
    enum Event {
        case ready(port: UInt16)
        case failed(String)
        case clientReady(endpoint: NWEndpoint)
        case clientState(String)
        case trace(String)
        case stopped
    }

    typealias ResponseHandler = (AirPlayControlResponse) -> Void
    typealias RequestHandler = (AirPlayControlRequest, @escaping ResponseHandler) -> Void

    private final class ClientContext {
        let connection: NWConnection
        var buffer = Data()

        init(connection: NWConnection) {
            self.connection = connection
        }
    }

    private let queue: DispatchQueue
    private let onEvent: (Event) -> Void
    private let requestHandler: RequestHandler
    private var listener: NWListener?
    private var clients: [ObjectIdentifier: ClientContext] = [:]

    init(
        queue: DispatchQueue,
        onEvent: @escaping (Event) -> Void,
        requestHandler: @escaping RequestHandler
    ) {
        self.queue = queue
        self.onEvent = onEvent
        self.requestHandler = requestHandler
    }

    func start() {
        guard listener == nil else {
            airPlayControlLog.info("[AirPlayControl] start skipped reason=listener-already-active")
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
            airPlayControlLog.info("[AirPlayControl] listener start requested port=system-assigned")
        } catch {
            airPlayControlLog.error("[AirPlayControl] listener create failed error=\(error.localizedDescription, privacy: .public)")
            onEvent(.failed(error.localizedDescription))
        }
    }

    func stop(reason: String) {
        airPlayControlLog.info("[AirPlayControl] stop requested reason=\(reason, privacy: .public)")
        for context in clients.values {
            context.connection.cancel()
        }
        clients.removeAll()
        listener?.cancel()
        listener = nil
        onEvent(.stopped)
    }

    private func handleListenerState(_ state: NWListener.State) {
        switch state {
        case .ready:
            guard let port = listener?.port?.rawValue else {
                airPlayControlLog.error("[AirPlayControl] listener ready without port")
                onEvent(.failed("control listener ready without a port"))
                return
            }
            airPlayControlLog.info("[AirPlayControl] listener ready port=\(port)")
            onEvent(.ready(port: port))
        case .waiting(let error):
            airPlayControlLog.warning("[AirPlayControl] listener waiting error=\(error.localizedDescription, privacy: .public)")
            onEvent(.failed("control listener waiting: \(error.localizedDescription)"))
        case .failed(let error):
            airPlayControlLog.error("[AirPlayControl] listener failed error=\(error.localizedDescription, privacy: .public)")
            onEvent(.failed(error.localizedDescription))
        case .cancelled:
            airPlayControlLog.info("[AirPlayControl] listener cancelled")
        case .setup:
            airPlayControlLog.info("[AirPlayControl] listener state=setup")
        @unknown default:
            airPlayControlLog.warning("[AirPlayControl] listener unknown state")
        }
    }

    private func accept(_ connection: NWConnection) {
        airPlayControlLog.info("[AirPlayControl] client accepted endpoint=\(String(describing: connection.endpoint), privacy: .public)")
        let context = ClientContext(connection: connection)
        clients[ObjectIdentifier(connection)] = context
        connection.stateUpdateHandler = { [weak self, weak connection] state in
            guard let self, let connection else { return }
            self.handleConnectionState(state, connection: connection)
        }
        connection.start(queue: queue)
    }

    private func handleConnectionState(_ state: NWConnection.State, connection: NWConnection) {
        switch state {
        case .ready:
            airPlayControlLog.info("[AirPlayControl] client ready")
            onEvent(.clientReady(endpoint: connection.endpoint))
            onEvent(.clientState("ready"))
            receive(on: connection)
        case .waiting(let error):
            airPlayControlLog.warning("[AirPlayControl] client waiting error=\(error.localizedDescription, privacy: .public)")
            onEvent(.clientState("waiting: \(error.localizedDescription)"))
        case .failed(let error):
            airPlayControlLog.error("[AirPlayControl] client failed error=\(error.localizedDescription, privacy: .public)")
            clients.removeValue(forKey: ObjectIdentifier(connection))
            onEvent(.clientState("failed: \(error.localizedDescription)"))
        case .cancelled:
            airPlayControlLog.info("[AirPlayControl] client cancelled")
            clients.removeValue(forKey: ObjectIdentifier(connection))
            onEvent(.clientState("cancelled"))
        case .setup, .preparing:
            airPlayControlLog.info("[AirPlayControl] client state=\(String(describing: state), privacy: .public)")
        @unknown default:
            airPlayControlLog.warning("[AirPlayControl] client unknown state")
        }
    }

    private func receive(on connection: NWConnection) {
        guard let context = clients[ObjectIdentifier(connection)] else {
            airPlayControlLog.info("[AirPlayControl] receive skipped reason=stale-connection")
            return
        }

        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self, weak connection] data, _, isComplete, error in
            guard let self, let connection else { return }

            if let data, !data.isEmpty {
                airPlayControlLog.info("[AirPlayControl] receive data bytes=\(data.count) isComplete=\(isComplete)")
                context.buffer.append(data)
                self.drainRequests(context)
            }

            if let error {
                airPlayControlLog.error("[AirPlayControl] receive failed error=\(error.localizedDescription, privacy: .public) bufferedBytes=\(context.buffer.count)")
                self.onEvent(.clientState("receive failed: \(error.localizedDescription)"))
                return
            }

            if isComplete {
                airPlayControlLog.info("[AirPlayControl] peer closed control connection finalBufferedBytes=\(context.buffer.count)")
                self.clients.removeValue(forKey: ObjectIdentifier(connection))
                self.onEvent(.clientState("peer closed"))
                return
            }

            self.receive(on: connection)
        }
    }

    private func drainRequests(_ context: ClientContext) {
        while !context.buffer.isEmpty {
            do {
                guard let parsed = try AirPlayControlRequest.parse(from: context.buffer) else {
                    return
                }
                context.buffer.removeSubrange(0..<parsed.consumedBytes)
                dispatch(parsed.request, on: context.connection)
            } catch {
                airPlayControlLog.warning("[AirPlayControl] parse failed error=\(String(describing: error), privacy: .public) bufferedBytes=\(context.buffer.count)")
                onEvent(.trace("parse-failed bufferedBytes=\(context.buffer.count) error=\(String(describing: error))"))
                context.buffer.removeAll()
                let response = AirPlayControlResponse.badRequest("Malformed AirPlay control request")
                send(response, cseq: nil, protocolVersion: "RTSP/1.0", on: context.connection)
                return
            }
        }
    }

    private func dispatch(_ request: AirPlayControlRequest, on connection: NWConnection) {
        airPlayControlLog.info("[AirPlayControl] request method=\(request.method, privacy: .public) path=\(request.path, privacy: .public) cseq=\(request.cseq ?? "nil", privacy: .public) bodyBytes=\(request.body.count) headers=\(request.sanitizedHeadersForLog, privacy: .public)")
        onEvent(.trace("request method=\(request.method) path=\(request.path) cseq=\(request.cseq ?? "nil") bodyBytes=\(request.body.count) headers=\(request.sanitizedHeadersForLog)"))
        requestHandler(request) { [weak self, weak connection] response in
            guard let self, let connection else { return }
            self.send(response, cseq: request.cseq, protocolVersion: request.protocolVersion, on: connection)
        }
    }

    private func send(_ response: AirPlayControlResponse, cseq: String?, protocolVersion: String, on connection: NWConnection) {
        let data = response.serialized(protocolVersion: protocolVersion, cseq: cseq)
        airPlayControlLog.info("[AirPlayControl] response status=\(response.statusCode) reason=\(response.reasonPhrase, privacy: .public) cseq=\(cseq ?? "nil", privacy: .public) bodyBytes=\(response.body.count)")
        onEvent(.trace("response status=\(response.statusCode) reason=\(response.reasonPhrase) cseq=\(cseq ?? "nil") bodyBytes=\(response.body.count)"))
        connection.send(content: data, completion: .contentProcessed { error in
            if let error {
                airPlayControlLog.error("[AirPlayControl] response send failed error=\(error.localizedDescription, privacy: .public)")
            }
        })
    }
}
