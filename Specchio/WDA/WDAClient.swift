import Foundation

actor WDAClient {
    let baseURL: URL
    private var sessionID: String?
    private let session: URLSession

    init(baseURL: URL) {
        self.baseURL = baseURL
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 10
        config.timeoutIntervalForResource = 30
        self.session = URLSession(configuration: config)
    }

    /// Initialiser for tests: accepts a custom URLSessionConfiguration so a
    /// URLProtocol stub can intercept requests without a real server.
    init(baseURL: URL, sessionConfig: URLSessionConfiguration) {
        self.baseURL = baseURL
        self.session = URLSession(configuration: sessionConfig)
    }

    /// For testing only: seed the actor with a known session id so input methods
    /// can be exercised without calling createSession().
    func injectSessionID(_ id: String) {
        self.sessionID = id
    }

    // MARK: - Session Management

    func createSession() async throws -> String {
        let body: [String: Any] = [
            "capabilities": [
                "alwaysMatch": [String: Any]()
            ]
        ]
        let response: WDASessionResponse = try await post("/session", body: body)
        self.sessionID = response.sessionId
        return response.sessionId
    }

    func status() async throws -> WDAStatus {
        return try await get("/status")
    }

    /// Configure WDA settings for optimal MJPEG streaming performance.
    func configureMJPEG(framerate: Int = 60, quality: Int = 40, scalingFactor: Int = 100) async throws {
        guard let sid = sessionID else { throw WDAError.noSession }
        let body: [String: Any] = [
            "settings": [
                "mjpegServerFramerate": framerate,
                "mjpegServerScreenshotQuality": quality,
                "mjpegScalingFactor": scalingFactor
            ]
        ]
        let _: WDAGenericResponse = try await post("/session/\(sid)/appium/settings", body: body)
    }

    /// Configure H.264 resolution scale on the device.
    func configureH264(resolutionScale: Int = 100) async throws {
        guard let sid = sessionID else { throw WDAError.noSession }
        let body: [String: Any] = [
            "settings": [
                "h264ResolutionScale": resolutionScale
            ]
        ]
        let _: WDAGenericResponse = try await post("/session/\(sid)/appium/settings", body: body)
    }

    // MARK: - Screenshot

    func screenshot() async throws -> Data {
        let wrapper: WDAScreenshotResponse = try await get("/screenshot")
        guard let imageData = Data(base64Encoded: wrapper.value) else {
            throw WDAError.invalidScreenshotData
        }
        return imageData
    }

    // MARK: - Accessibility Tree

    func accessibilityTree() async throws -> String {
        // WDA returns JSON: {"value": "<xml string>"}
        let wrapper: WDASourceResponse = try await get("/source")
        guard !wrapper.value.isEmpty else {
            throw WDAError.connectionFailed("Empty accessibility tree response")
        }
        return wrapper.value
    }

    // MARK: - Input

    func tap(x: Double, y: Double) async throws {
        guard let sid = sessionID else { throw WDAError.noSession }
        let body: [String: Any] = [
            "actions": [[
                "type": "pointer",
                "id": "finger1",
                "parameters": ["pointerType": "touch"],
                "actions": [
                    ["type": "pointerMove", "duration": 0, "x": x, "y": y],
                    ["type": "pointerDown", "button": 0],
                    ["type": "pause", "duration": 50],
                    ["type": "pointerUp", "button": 0]
                ]
            ]]
        ]
        let _: WDAGenericResponse = try await post("/session/\(sid)/actions", body: body)
    }

    /// Perform a drag along a path of points with even timing.
    func drag(points: [CGPoint], totalDurationMs: Int = 300) async throws {
        guard let sid = sessionID else { throw WDAError.noSession }
        guard points.count >= 2 else { return }

        let first = points[0]
        let stepDuration = max(1, totalDurationMs / (points.count - 1))

        var actions: [[String: Any]] = [
            ["type": "pointerMove", "duration": 0, "x": first.x, "y": first.y],
            ["type": "pointerDown", "button": 0]
        ]

        for point in points.dropFirst() {
            actions.append(["type": "pointerMove", "duration": stepDuration, "x": point.x, "y": point.y])
        }

        actions.append(["type": "pointerUp", "button": 0])

        let body: [String: Any] = [
            "actions": [[
                "type": "pointer",
                "id": "finger1",
                "parameters": ["pointerType": "touch"],
                "actions": actions
            ]]
        ]
        let _: WDAGenericResponse = try await post("/session/\(sid)/actions", body: body)
    }

    func swipe(fromX: Double, fromY: Double, toX: Double, toY: Double, duration: Int = 300) async throws {
        guard let sid = sessionID else { throw WDAError.noSession }
        let body: [String: Any] = [
            "actions": [[
                "type": "pointer",
                "id": "finger1",
                "parameters": ["pointerType": "touch"],
                "actions": [
                    ["type": "pointerMove", "duration": 0, "x": fromX, "y": fromY],
                    ["type": "pointerDown", "button": 0],
                    ["type": "pointerMove", "duration": duration, "x": toX, "y": toY],
                    ["type": "pointerUp", "button": 0]
                ]
            ]]
        ]
        let _: WDAGenericResponse = try await post("/session/\(sid)/actions", body: body)
    }

    func pinch(finger1Start: CGPoint, finger1End: CGPoint,
               finger2Start: CGPoint, finger2End: CGPoint,
               duration: Int = 300) async throws {
        guard let sid = sessionID else { throw WDAError.noSession }
        let body: [String: Any] = [
            "actions": [
                [
                    "type": "pointer", "id": "finger1",
                    "parameters": ["pointerType": "touch"],
                    "actions": [
                        ["type": "pointerMove", "duration": 0, "x": finger1Start.x, "y": finger1Start.y],
                        ["type": "pointerDown", "button": 0],
                        ["type": "pointerMove", "duration": duration, "x": finger1End.x, "y": finger1End.y],
                        ["type": "pointerUp", "button": 0]
                    ]
                ],
                [
                    "type": "pointer", "id": "finger2",
                    "parameters": ["pointerType": "touch"],
                    "actions": [
                        ["type": "pointerMove", "duration": 0, "x": finger2Start.x, "y": finger2Start.y],
                        ["type": "pointerDown", "button": 0],
                        ["type": "pointerMove", "duration": duration, "x": finger2End.x, "y": finger2End.y],
                        ["type": "pointerUp", "button": 0]
                    ]
                ]
            ]
        ]
        let _: WDAGenericResponse = try await post("/session/\(sid)/actions", body: body)
    }

    func typeText(_ text: String) async throws {
        guard let sid = sessionID else { throw WDAError.noSession }
        let body: [String: Any] = ["value": Array(text).map { String($0) }]
        let _: WDAGenericResponse = try await post("/session/\(sid)/wda/keys", body: body)
    }

    func typeKeyWithModifiers(key: String, modifierFlags: Int) async throws {
        guard let sid = sessionID else { throw WDAError.noSession }
        let body: [String: Any] = ["keys": [["key": key, "modifierFlags": modifierFlags]]]
        let _: WDAGenericResponse = try await post("/session/\(sid)/wda/keys", body: body)
    }

    func pressButton(_ button: String) async throws {
        guard let sid = sessionID else { throw WDAError.noSession }
        let body: [String: Any] = ["name": button]
        let _: WDAGenericResponse = try await post("/session/\(sid)/wda/pressButton", body: body)
    }

    // MARK: - Lock State

    func isLocked() async throws -> Bool {
        guard let sid = sessionID else { throw WDAError.noSession }
        let response: WDALockedResponse = try await get("/session/\(sid)/wda/locked")
        return response.value
    }

    func unlock() async throws {
        guard let sid = sessionID else { throw WDAError.noSession }
        let _: WDAGenericResponse = try await post("/session/\(sid)/wda/unlock", body: [:])
    }

    // MARK: - Device Info

    func windowSize() async throws -> CGSize {
        guard let sid = sessionID else { throw WDAError.noSession }
        let response: WDAWindowSizeResponse = try await get("/session/\(sid)/window/size")
        return CGSize(width: response.value.width, height: response.value.height)
    }

    // MARK: - Private HTTP Helpers

    private func get<T: Decodable>(_ path: String) async throws -> T {
        let url = baseURL.appendingPathComponent(path)
        let (data, response) = try await session.data(from: url)
        if let httpResponse = response as? HTTPURLResponse,
           !(200...299).contains(httpResponse.statusCode) {
            throw WDAError.connectionFailed("HTTP \(httpResponse.statusCode)")
        }
        return try JSONDecoder().decode(T.self, from: data)
    }

    private func getRaw(_ path: String, headers: [String: String] = [:]) async throws -> Data {
        let url = baseURL.appendingPathComponent(path)
        var request = URLRequest(url: url)
        for (key, value) in headers {
            request.addValue(value, forHTTPHeaderField: key)
        }
        let (data, response) = try await session.data(for: request)
        if let httpResponse = response as? HTTPURLResponse,
           !(200...299).contains(httpResponse.statusCode) {
            throw WDAError.connectionFailed("HTTP \(httpResponse.statusCode)")
        }
        return data
    }

    private func post<T: Decodable>(_ path: String, body: [String: Any]) async throws -> T {
        let url = baseURL.appendingPathComponent(path)
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await session.data(for: request)
        if let httpResponse = response as? HTTPURLResponse,
           !(200...299).contains(httpResponse.statusCode) {
            throw WDAError.connectionFailed("HTTP \(httpResponse.statusCode)")
        }
        return try JSONDecoder().decode(T.self, from: data)
    }
}
