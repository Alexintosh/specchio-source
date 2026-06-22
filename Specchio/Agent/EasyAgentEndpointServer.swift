import Combine
import CoreGraphics
import Foundation
import ImageIO
import Network
import UniformTypeIdentifiers

private let easyAgentLog = SpecchioLogger.agent

enum EasyAgentEndpointDefaults {
    static let host = "127.0.0.1"
    static let port: UInt16 = 9600
    static let maximumRequestBytes = 1_048_576
    static let maximumHeaderBytes = 32 * 1024
    static let jpegQuality = 0.82
    static let defaultClickHoldMilliseconds = 50
    static let defaultKeyHoldMilliseconds = 50
    static let defaultDragDurationMilliseconds = 350
    static let defaultDragSteps = 12
    static let maximumDragDurationMilliseconds = 10_000
    static let maximumDragSteps = 240
}

enum EasyAgentHIDTiming {
    static let minimumPointerHoldMilliseconds = 20
    static let maximumPointerHoldMilliseconds = 2_000
    static let minimumKeyHoldMilliseconds = 20
    static let maximumKeyHoldMilliseconds = 1_000
    private static let typingPressStepMilliseconds = 80
    private static let typingReleaseOffsetMilliseconds = 30

    static func typingPressDelay(for index: Int) -> DispatchTimeInterval {
        .milliseconds(max(0, index) * typingPressStepMilliseconds)
    }

    static func typingReleaseDelay(for index: Int) -> DispatchTimeInterval {
        .milliseconds(max(0, index) * typingPressStepMilliseconds + typingReleaseOffsetMilliseconds)
    }

    static func typingCompletionDelay(for characterCount: Int) -> DispatchTimeInterval {
        .milliseconds(max(0, characterCount) * typingPressStepMilliseconds + typingReleaseOffsetMilliseconds)
    }
}

struct EasyAgentInputStatusSnapshot: Encodable {
    let bluetoothHIDConnected: Bool
    let interruptChannelConnected: Bool
    let inputGateEnabled: Bool
    let inputGateReason: String
    let mousePassthroughEnabled: Bool
    let appActive: Bool
    let targetInputWindowBound: Bool
    let targetInputWindowKey: Bool?
    let targetInputWindowNumber: Int?
    let pointerSurfaceWidth: Double
    let pointerSurfaceHeight: Double
    let pointerSurfaceOrientation: String
    let inputSurfaceFrameX: Double?
    let inputSurfaceFrameY: Double?
    let inputSurfaceFrameWidth: Double?
    let inputSurfaceFrameHeight: Double?
    let displayRotationDegrees: Int
    let absolutePointerTransportEnabled: Bool

    var canForwardInput: Bool {
        bluetoothHIDConnected
            && interruptChannelConnected
            && inputGateEnabled
            && pointerSurfaceWidth > 0
            && pointerSurfaceHeight > 0
    }
}

struct EasyAgentStatusSnapshot: Encodable {
    let activeVideoSource: String
    let streamHealth: String
    let framePresent: Bool
    let frameWidth: Int?
    let frameHeight: Int?
    let activeVideoIsLive: Bool
    let input: EasyAgentInputStatusSnapshot
}

struct EasyAgentCommandResult: Encodable {
    let accepted: Bool
    let message: String
    let details: [String: String]

    static func accepted(_ message: String, details: [String: String] = [:]) -> EasyAgentCommandResult {
        EasyAgentCommandResult(accepted: true, message: message, details: details)
    }

    static func rejected(_ message: String, details: [String: String] = [:]) -> EasyAgentCommandResult {
        EasyAgentCommandResult(accepted: false, message: message, details: details)
    }
}

enum EasyAgentEndpointCommand {
    case pointerMove(point: CGPoint, requestID: String)
    case pointerDown(point: CGPoint, requestID: String)
    case pointerUp(point: CGPoint, requestID: String)
    case click(point: CGPoint, holdMilliseconds: Int, requestID: String)
    case drag(points: [CGPoint], durationMilliseconds: Int, requestID: String)
    case scroll(deltaY: CGFloat, requestID: String)
    case typeText(String, requestID: String)
    case pressKey(hidUsage: UInt8, modifiers: UInt8, holdMilliseconds: Int, requestID: String)

    var requestID: String {
        switch self {
        case .pointerMove(_, let requestID),
             .pointerDown(_, let requestID),
             .pointerUp(_, let requestID),
             .click(_, _, let requestID),
             .drag(_, _, let requestID),
             .scroll(_, let requestID),
             .typeText(_, let requestID),
             .pressKey(_, _, _, let requestID):
            return requestID
        }
    }

    var diagnosticName: String {
        switch self {
        case .pointerMove:
            return "mouse.move"
        case .pointerDown:
            return "mouse.down"
        case .pointerUp:
            return "mouse.up"
        case .click:
            return "mouse.click"
        case .drag:
            return "mouse.drag"
        case .scroll:
            return "mouse.scroll"
        case .typeText:
            return "keyboard.type"
        case .pressKey:
            return "keyboard.key"
        }
    }
}

struct EasyAgentEndpointCommandExecutor {
    @MainActor
    static func run(
        _ command: EasyAgentEndpointCommand,
        bluetoothHIDPanel: BluetoothHIDPanelController
    ) async -> EasyAgentCommandResult {
        easyAgentLog.info("[AgentEndpoint] executing command=\(command.diagnosticName, privacy: .public) requestID=\(command.requestID, privacy: .public)")
        switch command {
        case .pointerMove(let point, let requestID):
            return bluetoothHIDPanel.agentMovePointer(to: point, requestID: requestID)
        case .pointerDown(let point, let requestID):
            return bluetoothHIDPanel.agentPointerDown(at: point, requestID: requestID)
        case .pointerUp(let point, let requestID):
            return bluetoothHIDPanel.agentPointerUp(at: point, requestID: requestID)
        case .click(let point, let holdMilliseconds, let requestID):
            return bluetoothHIDPanel.agentClick(
                at: point,
                holdMilliseconds: holdMilliseconds,
                requestID: requestID
            )
        case .drag(let points, let durationMilliseconds, let requestID):
            return await runDrag(
                points: points,
                durationMilliseconds: durationMilliseconds,
                requestID: requestID,
                bluetoothHIDPanel: bluetoothHIDPanel
            )
        case .scroll(let deltaY, let requestID):
            return bluetoothHIDPanel.agentScroll(deltaY: deltaY, requestID: requestID)
        case .typeText(let text, let requestID):
            return bluetoothHIDPanel.agentTypeText(text, requestID: requestID)
        case .pressKey(let hidUsage, let modifiers, let holdMilliseconds, let requestID):
            return bluetoothHIDPanel.agentPressKey(
                hidUsage: hidUsage,
                modifiers: modifiers,
                holdMilliseconds: holdMilliseconds,
                requestID: requestID
            )
        }
    }

    @MainActor
    private static func runDrag(
        points: [CGPoint],
        durationMilliseconds: Int,
        requestID: String,
        bluetoothHIDPanel: BluetoothHIDPanelController
    ) async -> EasyAgentCommandResult {
        guard points.count >= 2 else {
            easyAgentLog.info("[AgentEndpoint] drag rejected requestID=\(requestID, privacy: .public) reason=insufficient-points count=\(points.count)")
            return .rejected("Drag requires at least two points")
        }

        let clampedDuration = min(
            max(durationMilliseconds, 0),
            EasyAgentEndpointDefaults.maximumDragDurationMilliseconds
        )
        let intervalNanoseconds = points.count > 1
            ? UInt64(clampedDuration * 1_000_000 / max(points.count - 1, 1))
            : 0

        easyAgentLog.info("[AgentEndpoint] drag start requestID=\(requestID, privacy: .public) points=\(points.count) durationMs=\(clampedDuration) intervalNs=\(intervalNanoseconds)")
        let down = bluetoothHIDPanel.agentPointerDown(at: points[0], requestID: requestID)
        guard down.accepted else {
            easyAgentLog.info("[AgentEndpoint] drag down rejected requestID=\(requestID, privacy: .public) message=\(down.message, privacy: .public)")
            return down
        }

        for point in points.dropFirst().dropLast() {
            if intervalNanoseconds > 0 {
                try? await Task.sleep(nanoseconds: intervalNanoseconds)
            }
            let step = bluetoothHIDPanel.agentDragStep(to: point, requestID: requestID)
            guard step.accepted else {
                easyAgentLog.info("[AgentEndpoint] drag step rejected requestID=\(requestID, privacy: .public) message=\(step.message, privacy: .public)")
                _ = bluetoothHIDPanel.agentPointerUp(at: point, requestID: requestID)
                return step
            }
        }

        if intervalNanoseconds > 0 {
            try? await Task.sleep(nanoseconds: intervalNanoseconds)
        }
        let up = bluetoothHIDPanel.agentPointerUp(at: points[points.count - 1], requestID: requestID)
        guard up.accepted else {
            easyAgentLog.info("[AgentEndpoint] drag up rejected requestID=\(requestID, privacy: .public) message=\(up.message, privacy: .public)")
            return up
        }

        easyAgentLog.info("[AgentEndpoint] drag completed requestID=\(requestID, privacy: .public) points=\(points.count)")
        return .accepted("Drag completed", details: [
            "points": String(points.count),
            "durationMs": String(clampedDuration),
        ])
    }
}

final class EasyAgentEndpointServer: ObservableObject {
    typealias StatusProvider = @MainActor () -> EasyAgentStatusSnapshot
    typealias FrameProvider = @MainActor () -> CGImage?
    typealias CommandHandler = @MainActor (EasyAgentEndpointCommand) async -> EasyAgentCommandResult

    @Published private(set) var isListening = false
    @Published private(set) var listeningPort: UInt16?
    @Published private(set) var badgeText = "Agent API off"
    @Published private(set) var lastEventText = "Idle"

    private final class ClientContext {
        let connection: NWConnection
        var buffer = Data()

        init(connection: NWConnection) {
            self.connection = connection
        }
    }

    private let queue = DispatchQueue(label: "com.alexintosh.Specchio.agentEndpoint", qos: .userInitiated)
    private var listener: NWListener?
    private var clients: [ObjectIdentifier: ClientContext] = [:]
    private var statusProvider: StatusProvider?
    private var frameProvider: FrameProvider?
    private var commandHandler: CommandHandler?

    func start(
        port: UInt16 = EasyAgentEndpointDefaults.port,
        statusProvider: @escaping StatusProvider,
        frameProvider: @escaping FrameProvider,
        commandHandler: @escaping CommandHandler
    ) {
        self.statusProvider = statusProvider
        self.frameProvider = frameProvider
        self.commandHandler = commandHandler

        queue.async { [weak self] in
            guard let self else { return }
            guard self.listener == nil else {
                easyAgentLog.info("[AgentEndpoint] start skipped reason=already-listening port=\(self.listeningPort ?? 0)")
                self.publishEvent("Agent API already active", isListening: self.isListening, port: self.listeningPort)
                return
            }

            guard let nwPort = NWEndpoint.Port(rawValue: port),
                  let loopback = IPv4Address(EasyAgentEndpointDefaults.host) else {
                easyAgentLog.error("[AgentEndpoint] start failed reason=invalid-loopback-or-port host=\(EasyAgentEndpointDefaults.host, privacy: .public) port=\(port)")
                self.publishEvent("Agent API failed: invalid host/port", isListening: false, port: nil)
                return
            }

            let parameters = NWParameters.tcp
            parameters.allowLocalEndpointReuse = true
            parameters.requiredLocalEndpoint = .hostPort(
                host: .ipv4(loopback),
                port: nwPort
            )

            do {
                let listener = try NWListener(using: parameters)
                self.listener = listener
                listener.stateUpdateHandler = { [weak self] state in
                    self?.handleListenerState(state)
                }
                listener.newConnectionHandler = { [weak self] connection in
                    self?.accept(connection)
                }
                listener.start(queue: self.queue)
                easyAgentLog.info("[AgentEndpoint] start requested host=\(EasyAgentEndpointDefaults.host, privacy: .public) port=\(port)")
                self.publishEvent("Agent API starting", isListening: false, port: port)
            } catch {
                easyAgentLog.error("[AgentEndpoint] start failed error=\(error.localizedDescription, privacy: .public) host=\(EasyAgentEndpointDefaults.host, privacy: .public) port=\(port)")
                self.listener = nil
                self.publishEvent("Agent API failed: \(error.localizedDescription)", isListening: false, port: nil)
            }
        }
    }

    func stop(reason: String) {
        queue.async { [weak self] in
            guard let self else { return }
            easyAgentLog.info("[AgentEndpoint] stop requested reason=\(reason, privacy: .public) clients=\(self.clients.count)")
            for context in self.clients.values {
                context.connection.cancel()
            }
            self.clients.removeAll()
            self.listener?.cancel()
            self.listener = nil
            self.statusProvider = nil
            self.frameProvider = nil
            self.commandHandler = nil
            self.publishEvent("Agent API stopped", isListening: false, port: nil)
        }
    }

    private func handleListenerState(_ state: NWListener.State) {
        switch state {
        case .ready:
            let port = listener?.port?.rawValue
            easyAgentLog.info("[AgentEndpoint] listener ready host=\(EasyAgentEndpointDefaults.host, privacy: .public) port=\(port ?? 0)")
            publishEvent("Agent API ready", isListening: true, port: port)
        case .waiting(let error):
            easyAgentLog.warning("[AgentEndpoint] listener waiting error=\(error.localizedDescription, privacy: .public)")
            publishEvent("Agent API waiting: \(error.localizedDescription)", isListening: false, port: listener?.port?.rawValue)
        case .failed(let error):
            easyAgentLog.error("[AgentEndpoint] listener failed error=\(error.localizedDescription, privacy: .public)")
            listener = nil
            publishEvent("Agent API failed: \(error.localizedDescription)", isListening: false, port: nil)
        case .cancelled:
            easyAgentLog.info("[AgentEndpoint] listener cancelled")
            publishEvent("Agent API stopped", isListening: false, port: nil)
        case .setup:
            easyAgentLog.info("[AgentEndpoint] listener state=setup")
        @unknown default:
            easyAgentLog.warning("[AgentEndpoint] listener state=unknown")
        }
    }

    private func accept(_ connection: NWConnection) {
        let context = ClientContext(connection: connection)
        clients[ObjectIdentifier(connection)] = context
        easyAgentLog.info("[AgentEndpoint] accepted client endpoint=\(String(describing: connection.endpoint), privacy: .public) clients=\(self.clients.count)")
        connection.stateUpdateHandler = { [weak self, weak connection] state in
            guard let self, let connection else { return }
            self.handleConnectionState(state, connection: connection)
        }
        connection.start(queue: queue)
    }

    private func handleConnectionState(_ state: NWConnection.State, connection: NWConnection) {
        switch state {
        case .ready:
            easyAgentLog.info("[AgentEndpoint] client ready endpoint=\(String(describing: connection.endpoint), privacy: .public)")
            receive(on: connection)
        case .waiting(let error):
            easyAgentLog.warning("[AgentEndpoint] client waiting error=\(error.localizedDescription, privacy: .public)")
        case .failed(let error):
            easyAgentLog.error("[AgentEndpoint] client failed error=\(error.localizedDescription, privacy: .public)")
            clients.removeValue(forKey: ObjectIdentifier(connection))
        case .cancelled:
            easyAgentLog.info("[AgentEndpoint] client cancelled")
            clients.removeValue(forKey: ObjectIdentifier(connection))
        case .setup, .preparing:
            easyAgentLog.info("[AgentEndpoint] client state=\(String(describing: state), privacy: .public)")
        @unknown default:
            easyAgentLog.warning("[AgentEndpoint] client state=unknown")
        }
    }

    private func receive(on connection: NWConnection) {
        guard let context = clients[ObjectIdentifier(connection)] else {
            easyAgentLog.info("[AgentEndpoint] receive skipped reason=stale-client")
            return
        }

        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self, weak connection] data, _, isComplete, error in
            guard let self, let connection else { return }

            if let data, !data.isEmpty {
                context.buffer.append(data)
                easyAgentLog.info("[AgentEndpoint] received bytes=\(data.count) buffered=\(context.buffer.count)")
                self.drainRequest(context)
            }

            if let error {
                easyAgentLog.error("[AgentEndpoint] receive failed error=\(error.localizedDescription, privacy: .public) buffered=\(context.buffer.count)")
                self.clients.removeValue(forKey: ObjectIdentifier(connection))
                return
            }

            if isComplete {
                easyAgentLog.info("[AgentEndpoint] client closed buffered=\(context.buffer.count)")
                self.clients.removeValue(forKey: ObjectIdentifier(connection))
                return
            }

            if self.clients[ObjectIdentifier(connection)] != nil {
                self.receive(on: connection)
            }
        }
    }

    private func drainRequest(_ context: ClientContext) {
        guard context.buffer.count <= EasyAgentEndpointDefaults.maximumRequestBytes else {
            easyAgentLog.warning("[AgentEndpoint] request rejected reason=too-large buffered=\(context.buffer.count)")
            send(.jsonError(statusCode: 413, message: "Request too large"), on: context.connection)
            return
        }

        do {
            guard let request = try EasyAgentHTTPRequest.parse(from: context.buffer) else {
                easyAgentLog.debug("[AgentEndpoint] request incomplete buffered=\(context.buffer.count)")
                return
            }

            easyAgentLog.info("[AgentEndpoint] request method=\(request.method, privacy: .public) path=\(request.path, privacy: .public) bodyBytes=\(request.body.count)")
            let connection = context.connection
            Task { @MainActor [weak self] in
                guard let self else { return }
                let response = await self.route(request)
                self.queue.async { [weak self] in
                    guard let self else { return }
                    self.send(response, on: connection)
                }
            }
        } catch {
            easyAgentLog.warning("[AgentEndpoint] parse failed error=\(String(describing: error), privacy: .public) buffered=\(context.buffer.count)")
            send(.jsonError(statusCode: 400, message: "Malformed HTTP request"), on: context.connection)
        }
    }

    @MainActor
    private func route(_ request: EasyAgentHTTPRequest) async -> EasyAgentHTTPResponse {
        guard let statusProvider, let frameProvider, let commandHandler else {
            easyAgentLog.info("[AgentEndpoint] route rejected path=\(request.path, privacy: .public) reason=server-not-ready")
            return .jsonError(statusCode: 503, message: "Agent endpoint server is not ready")
        }

        let path = request.pathWithoutQuery
        easyAgentLog.info("[AgentEndpoint] routing method=\(request.method, privacy: .public) path=\(path, privacy: .public)")

        switch (request.method, path) {
        case ("GET", "/agent/v1/status"):
            let snapshot = statusProvider()
            let response = EasyAgentStatusResponse(
                server: EasyAgentServerStatus(
                    host: EasyAgentEndpointDefaults.host,
                    port: Int(listeningPort ?? EasyAgentEndpointDefaults.port),
                    listening: isListening,
                    lastEvent: lastEventText
                ),
                easyMode: snapshot
            )
            easyAgentLog.info("[AgentEndpoint] status response source=\(snapshot.activeVideoSource, privacy: .public) frame=\(snapshot.framePresent) inputReady=\(snapshot.input.canForwardInput)")
            return .json(statusCode: 200, value: response)

        case ("GET", "/agent/v1/frame/latest.jpg"),
             ("GET", "/agent/v1/frame/latest.jpeg"):
            return latestFrameResponse(format: .jpeg, frameProvider: frameProvider)

        case ("GET", "/agent/v1/frame/latest.png"):
            return latestFrameResponse(format: .png, frameProvider: frameProvider)

        case ("POST", "/agent/v1/mouse/move"),
             ("POST", "/agent/v1/mouse/down"),
             ("POST", "/agent/v1/mouse/up"),
             ("POST", "/agent/v1/mouse/click"),
             ("POST", "/agent/v1/mouse/drag"),
             ("POST", "/agent/v1/mouse/scroll"),
             ("POST", "/agent/v1/keyboard/type"),
             ("POST", "/agent/v1/keyboard/key"):
            do {
                let snapshot = statusProvider()
                let command = try makeCommand(path: path, body: request.body, status: snapshot)
                easyAgentLog.info("[AgentEndpoint] command parsed command=\(command.diagnosticName, privacy: .public) requestID=\(command.requestID, privacy: .public)")
                let result = await commandHandler(command)
                publishEvent("Agent \(command.diagnosticName): \(result.accepted ? "accepted" : "rejected")", isListening: isListening, port: listeningPort)
                return .json(statusCode: result.accepted ? 200 : 409, value: EasyAgentCommandResponse(
                    requestID: command.requestID,
                    command: command.diagnosticName,
                    result: result
                ))
            } catch let error as EasyAgentEndpointError {
                easyAgentLog.info("[AgentEndpoint] command rejected path=\(path, privacy: .public) reason=\(error.message, privacy: .public)")
                return .jsonError(statusCode: error.statusCode, message: error.message)
            } catch {
                easyAgentLog.warning("[AgentEndpoint] command rejected path=\(path, privacy: .public) error=\(String(describing: error), privacy: .public)")
                return .jsonError(statusCode: 400, message: "Invalid command body")
            }

        default:
            easyAgentLog.info("[AgentEndpoint] route rejected method=\(request.method, privacy: .public) path=\(path, privacy: .public) reason=not-found")
            return .jsonError(statusCode: 404, message: "Unknown endpoint")
        }
    }

    @MainActor
    private func latestFrameResponse(
        format: EasyAgentFrameFormat,
        frameProvider: FrameProvider
    ) -> EasyAgentHTTPResponse {
        guard let frame = frameProvider() else {
            easyAgentLog.info("[AgentEndpoint] frame request rejected reason=no-active-frame")
            return .jsonError(statusCode: 409, message: "No active Easy Mode frame is available")
        }

        guard let data = Self.encode(frame: frame, format: format) else {
            easyAgentLog.error("[AgentEndpoint] frame encode failed format=\(format.pathExtension, privacy: .public) width=\(frame.width) height=\(frame.height)")
            return .jsonError(statusCode: 500, message: "Failed to encode frame")
        }

        easyAgentLog.info("[AgentEndpoint] frame response format=\(format.pathExtension, privacy: .public) width=\(frame.width) height=\(frame.height) bytes=\(data.count)")
        return EasyAgentHTTPResponse(
            statusCode: 200,
            reasonPhrase: "OK",
            headers: [
                "Content-Type": format.contentType,
                "Cache-Control": "no-store",
            ],
            body: data
        )
    }

    private func send(_ response: EasyAgentHTTPResponse, on connection: NWConnection) {
        let data = response.serialized()
        easyAgentLog.info("[AgentEndpoint] response status=\(response.statusCode) bodyBytes=\(response.body.count)")
        connection.send(content: data, completion: .contentProcessed { [weak self, weak connection] error in
            if let error {
                easyAgentLog.error("[AgentEndpoint] response send failed error=\(error.localizedDescription, privacy: .public)")
            }
            connection?.cancel()
            if let connection {
                self?.clients.removeValue(forKey: ObjectIdentifier(connection))
            }
        })
    }

    private func publishEvent(_ text: String, isListening: Bool, port: UInt16?) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.isListening = isListening
            self.listeningPort = port
            self.lastEventText = text
            if isListening, let port {
                self.badgeText = "Agent API \(EasyAgentEndpointDefaults.host):\(port) - \(text)"
            } else {
                self.badgeText = text
            }
        }
    }

    private static func encode(frame: CGImage, format: EasyAgentFrameFormat) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            data,
            format.uniformType.identifier as CFString,
            1,
            nil
        ) else {
            return nil
        }

        let options: CFDictionary
        switch format {
        case .jpeg:
            options = [
                kCGImageDestinationLossyCompressionQuality: EasyAgentEndpointDefaults.jpegQuality
            ] as CFDictionary
        case .png:
            options = [:] as CFDictionary
        }

        CGImageDestinationAddImage(destination, frame, options)
        guard CGImageDestinationFinalize(destination) else {
            return nil
        }
        return data as Data
    }
}

private enum EasyAgentFrameFormat {
    case jpeg
    case png

    var uniformType: UTType {
        switch self {
        case .jpeg:
            return .jpeg
        case .png:
            return .png
        }
    }

    var contentType: String {
        uniformType.preferredMIMEType ?? "application/octet-stream"
    }

    var pathExtension: String {
        switch self {
        case .jpeg:
            return "jpg"
        case .png:
            return "png"
        }
    }
}

private struct EasyAgentServerStatus: Encodable {
    let host: String
    let port: Int
    let listening: Bool
    let lastEvent: String
}

private struct EasyAgentStatusResponse: Encodable {
    let server: EasyAgentServerStatus
    let easyMode: EasyAgentStatusSnapshot
}

private struct EasyAgentCommandResponse: Encodable {
    let requestID: String
    let command: String
    let result: EasyAgentCommandResult
}

private struct EasyAgentErrorResponse: Encodable {
    let error: String
}

private struct EasyAgentEndpointError: Error {
    let statusCode: Int
    let message: String
}

private struct EasyAgentHTTPRequest {
    let method: String
    let path: String
    let headers: [String: String]
    let body: Data

    var pathWithoutQuery: String {
        path.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false)
            .first
            .map(String.init) ?? path
    }

    static func parse(from data: Data) throws -> EasyAgentHTTPRequest? {
        guard let headerRange = data.range(of: Data("\r\n\r\n".utf8)) else {
            if data.count > EasyAgentEndpointDefaults.maximumHeaderBytes {
                throw EasyAgentEndpointError(statusCode: 431, message: "Request headers too large")
            }
            return nil
        }

        let headerEnd = headerRange.upperBound
        let headerData = data.subdata(in: data.startIndex..<headerRange.lowerBound)
        guard let headerText = String(data: headerData, encoding: .utf8) else {
            throw EasyAgentEndpointError(statusCode: 400, message: "Headers are not UTF-8")
        }

        var lines = headerText.components(separatedBy: "\r\n")
        guard !lines.isEmpty else {
            throw EasyAgentEndpointError(statusCode: 400, message: "Missing request line")
        }

        let requestLine = lines.removeFirst().split(separator: " ")
        guard requestLine.count >= 2 else {
            throw EasyAgentEndpointError(statusCode: 400, message: "Malformed request line")
        }

        var headers: [String: String] = [:]
        for line in lines {
            guard let separator = line.firstIndex(of: ":") else { continue }
            let key = String(line[..<separator]).trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let value = String(line[line.index(after: separator)...]).trimmingCharacters(in: .whitespacesAndNewlines)
            headers[key] = value
        }

        let contentLength = Int(headers["content-length"] ?? "0") ?? 0
        guard contentLength >= 0 else {
            throw EasyAgentEndpointError(statusCode: 400, message: "Invalid Content-Length")
        }

        let requestLength = headerEnd + contentLength
        guard data.count >= requestLength else {
            return nil
        }

        let body = contentLength > 0
            ? data.subdata(in: headerEnd..<requestLength)
            : Data()

        return EasyAgentHTTPRequest(
            method: String(requestLine[0]).uppercased(),
            path: String(requestLine[1]),
            headers: headers,
            body: body
        )
    }
}

private struct EasyAgentHTTPResponse {
    let statusCode: Int
    let reasonPhrase: String
    let headers: [String: String]
    let body: Data

    static func json<T: Encodable>(statusCode: Int, value: T) -> EasyAgentHTTPResponse {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let body = (try? encoder.encode(value)) ?? Data("{}".utf8)
        return EasyAgentHTTPResponse(
            statusCode: statusCode,
            reasonPhrase: reasonPhrase(for: statusCode),
            headers: ["Content-Type": "application/json; charset=utf-8"],
            body: body
        )
    }

    static func jsonError(statusCode: Int, message: String) -> EasyAgentHTTPResponse {
        json(statusCode: statusCode, value: EasyAgentErrorResponse(error: message))
    }

    func serialized() -> Data {
        var responseHeaders = headers
        responseHeaders["Content-Length"] = String(body.count)
        responseHeaders["Connection"] = "close"

        var head = "HTTP/1.1 \(statusCode) \(reasonPhrase)\r\n"
        for (key, value) in responseHeaders.sorted(by: { $0.key < $1.key }) {
            head += "\(key): \(value)\r\n"
        }
        head += "\r\n"

        var data = Data(head.utf8)
        data.append(body)
        return data
    }

    private static func reasonPhrase(for statusCode: Int) -> String {
        switch statusCode {
        case 200:
            return "OK"
        case 400:
            return "Bad Request"
        case 404:
            return "Not Found"
        case 409:
            return "Conflict"
        case 413:
            return "Payload Too Large"
        case 431:
            return "Request Header Fields Too Large"
        case 500:
            return "Internal Server Error"
        case 503:
            return "Service Unavailable"
        default:
            return "Error"
        }
    }
}

private func makeCommand(
    path: String,
    body: Data,
    status: EasyAgentStatusSnapshot
) throws -> EasyAgentEndpointCommand {
    let json = try parseJSONObject(body)
    let requestID = (json["requestID"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? UUID().uuidString

    switch path {
    case "/agent/v1/mouse/move":
        return .pointerMove(point: try parsePoint(json, status: status), requestID: requestID)
    case "/agent/v1/mouse/down":
        return .pointerDown(point: try parsePoint(json, status: status), requestID: requestID)
    case "/agent/v1/mouse/up":
        return .pointerUp(point: try parsePoint(json, status: status), requestID: requestID)
    case "/agent/v1/mouse/click":
        return .click(
            point: try parsePoint(json, status: status),
            holdMilliseconds: parseInt(json["holdMs"], defaultValue: EasyAgentEndpointDefaults.defaultClickHoldMilliseconds),
            requestID: requestID
        )
    case "/agent/v1/mouse/drag":
        return .drag(
            points: try parseDragPoints(json, status: status),
            durationMilliseconds: parseInt(json["durationMs"], defaultValue: EasyAgentEndpointDefaults.defaultDragDurationMilliseconds),
            requestID: requestID
        )
    case "/agent/v1/mouse/scroll":
        guard let deltaY = parseDouble(json["deltaY"]) else {
            throw EasyAgentEndpointError(statusCode: 400, message: "mouse.scroll requires numeric deltaY")
        }
        return .scroll(deltaY: CGFloat(deltaY), requestID: requestID)
    case "/agent/v1/keyboard/type":
        guard let text = json["text"] as? String else {
            throw EasyAgentEndpointError(statusCode: 400, message: "keyboard.type requires text")
        }
        return .typeText(text, requestID: requestID)
    case "/agent/v1/keyboard/key":
        let resolved = try parseKey(json)
        return .pressKey(
            hidUsage: resolved.hidUsage,
            modifiers: resolved.modifiers,
            holdMilliseconds: parseInt(json["holdMs"], defaultValue: EasyAgentEndpointDefaults.defaultKeyHoldMilliseconds),
            requestID: requestID
        )
    default:
        throw EasyAgentEndpointError(statusCode: 404, message: "Unknown command endpoint")
    }
}

private func parseJSONObject(_ data: Data) throws -> [String: Any] {
    guard !data.isEmpty else {
        throw EasyAgentEndpointError(statusCode: 400, message: "JSON body is required")
    }
    guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
        throw EasyAgentEndpointError(statusCode: 400, message: "JSON body must be an object")
    }
    return object
}

private enum EasyAgentCoordinateSpace: String {
    case normalized
    case phone
}

private func parseCoordinateSpace(_ object: [String: Any]) throws -> EasyAgentCoordinateSpace {
    guard let rawValue = object["coordinateSpace"] as? String else {
        throw EasyAgentEndpointError(statusCode: 400, message: "coordinateSpace is required")
    }
    guard let space = EasyAgentCoordinateSpace(rawValue: rawValue) else {
        throw EasyAgentEndpointError(statusCode: 400, message: "coordinateSpace must be normalized or phone")
    }
    return space
}

private func parsePoint(
    _ object: [String: Any],
    status: EasyAgentStatusSnapshot
) throws -> CGPoint {
    try parsePointFields(object, coordinateSpace: parseCoordinateSpace(object), status: status)
}

private func parsePointFields(
    _ object: [String: Any],
    coordinateSpace: EasyAgentCoordinateSpace,
    status: EasyAgentStatusSnapshot
) throws -> CGPoint {
    guard let x = parseDouble(object["x"]), let y = parseDouble(object["y"]) else {
        throw EasyAgentEndpointError(statusCode: 400, message: "Point requires numeric x and y")
    }
    guard x.isFinite, y.isFinite else {
        throw EasyAgentEndpointError(statusCode: 400, message: "Point coordinates must be finite")
    }

    switch coordinateSpace {
    case .phone:
        return CGPoint(x: x, y: y)
    case .normalized:
        guard x >= 0, x <= 1, y >= 0, y <= 1 else {
            throw EasyAgentEndpointError(statusCode: 400, message: "Normalized coordinates must be between 0 and 1")
        }
        guard status.input.pointerSurfaceWidth > 0, status.input.pointerSurfaceHeight > 0 else {
            throw EasyAgentEndpointError(statusCode: 409, message: "Pointer surface is not ready")
        }
        return CGPoint(
            x: x * status.input.pointerSurfaceWidth,
            y: y * status.input.pointerSurfaceHeight
        )
    }
}

private func parseDragPoints(
    _ object: [String: Any],
    status: EasyAgentStatusSnapshot
) throws -> [CGPoint] {
    let coordinateSpace = try parseCoordinateSpace(object)

    if let rawPoints = object["points"] as? [[String: Any]] {
        guard rawPoints.count >= 2 else {
            throw EasyAgentEndpointError(statusCode: 400, message: "Drag points must include at least two points")
        }
        guard rawPoints.count <= EasyAgentEndpointDefaults.maximumDragSteps else {
            throw EasyAgentEndpointError(statusCode: 400, message: "Drag points exceed maximum step count")
        }
        return try rawPoints.map {
            try parsePointFields($0, coordinateSpace: coordinateSpace, status: status)
        }
    }

    guard let from = object["from"] as? [String: Any],
          let to = object["to"] as? [String: Any] else {
        throw EasyAgentEndpointError(statusCode: 400, message: "Drag requires points or from/to")
    }

    let start = try parsePointFields(from, coordinateSpace: coordinateSpace, status: status)
    let end = try parsePointFields(to, coordinateSpace: coordinateSpace, status: status)
    let requestedSteps = parseInt(object["steps"], defaultValue: EasyAgentEndpointDefaults.defaultDragSteps)
    let steps = min(max(requestedSteps, 2), EasyAgentEndpointDefaults.maximumDragSteps)

    return (0..<steps).map { index in
        let progress = steps == 1 ? 1 : CGFloat(index) / CGFloat(steps - 1)
        return CGPoint(
            x: start.x + ((end.x - start.x) * progress),
            y: start.y + ((end.y - start.y) * progress)
        )
    }
}

private func parseKey(_ object: [String: Any]) throws -> (hidUsage: UInt8, modifiers: UInt8) {
    let modifiers = try parseModifiers(object)

    let hidUsage = parseInt(object["hidUsage"], defaultValue: -1)
    if hidUsage >= 1, hidUsage <= Int(UInt8.max) {
        return (UInt8(hidUsage), modifiers)
    }

    guard let key = object["key"] as? String, !key.isEmpty else {
        throw EasyAgentEndpointError(statusCode: 400, message: "keyboard.key requires key or hidUsage")
    }

    let normalizedKey = key.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    if let hidUsage = namedHIDUsage(for: normalizedKey) {
        return (hidUsage, modifiers)
    }
    if key.count == 1, let character = key.first, let mapped = BluetoothHIDPanelController.charToHID(character) {
        return (mapped.0, modifiers | mapped.1)
    }

    throw EasyAgentEndpointError(statusCode: 400, message: "Unsupported key")
}

private func parseModifiers(_ object: [String: Any]) throws -> UInt8 {
    let modifierByte = parseInt(object["modifierByte"], defaultValue: -1)
    if modifierByte >= 0, modifierByte <= Int(UInt8.max) {
        return UInt8(modifierByte)
    }

    guard let names = object["modifiers"] as? [String] else {
        return 0
    }

    var modifiers: UInt8 = 0
    for name in names.map({ $0.lowercased() }) {
        switch name {
        case "control", "ctrl":
            modifiers |= 0x01
        case "shift":
            modifiers |= 0x02
        case "option", "alt":
            modifiers |= 0x04
        case "command", "cmd", "meta":
            modifiers |= 0x08
        default:
            throw EasyAgentEndpointError(statusCode: 400, message: "Unsupported modifier: \(name)")
        }
    }
    return modifiers
}

private func namedHIDUsage(for key: String) -> UInt8? {
    switch key {
    case "return", "enter":
        return 0x28
    case "escape", "esc":
        return 0x29
    case "delete", "backspace":
        return 0x2A
    case "tab":
        return 0x2B
    case "space":
        return 0x2C
    case "right", "arrowright", "rightarrow":
        return 0x4F
    case "left", "arrowleft", "leftarrow":
        return 0x50
    case "down", "arrowdown", "downarrow":
        return 0x51
    case "up", "arrowup", "uparrow":
        return 0x52
    case "home":
        return 0x4A
    case "pageup", "page-up":
        return 0x4B
    case "forwarddelete", "forward-delete":
        return 0x4C
    case "end":
        return 0x4D
    case "pagedown", "page-down":
        return 0x4E
    default:
        return nil
    }
}

private func parseDouble(_ value: Any?) -> Double? {
    switch value {
    case let double as Double:
        return double
    case let int as Int:
        return Double(int)
    case let number as NSNumber:
        return number.doubleValue
    default:
        return nil
    }
}

private func parseInt(_ value: Any?, defaultValue: Int) -> Int {
    switch value {
    case let int as Int:
        return int
    case let double as Double where double.isFinite:
        return Int(double.rounded())
    case let number as NSNumber:
        return number.intValue
    default:
        return defaultValue
    }
}
