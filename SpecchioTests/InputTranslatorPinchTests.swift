import XCTest
@testable import Specchio

// MARK: - URLProtocol stub that captures the last request body

final class CapturingURLProtocol: URLProtocol {
    static var capturedBody: Data?
    static var responseStatusCode: Int = 200
    static var responseBody: Data = """
    {"value": null, "sessionId": "stub-session"}
    """.data(using: .utf8)!

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        if let body = request.httpBodyStream {
            body.open()
            var data = Data()
            let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: 4096)
            defer { buffer.deallocate() }
            while body.hasBytesAvailable {
                let n = body.read(buffer, maxLength: 4096)
                if n <= 0 { break }
                data.append(buffer, count: n)
            }
            body.close()
            CapturingURLProtocol.capturedBody = data
        } else {
            CapturingURLProtocol.capturedBody = request.httpBody
        }

        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: CapturingURLProtocol.responseStatusCode,
            httpVersion: nil,
            headerFields: nil
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: CapturingURLProtocol.responseBody)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

// MARK: - Tests

final class InputTranslatorPinchTests: XCTestCase {

    var wdaClient: WDAClient!
    var mapper: CoordinateMapper!
    var translator: InputTranslator!

    override func setUp() async throws {
        try await super.setUp()

        // Register stub and build a WDAClient that uses it.
        URLProtocol.registerClass(CapturingURLProtocol.self)

        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [CapturingURLProtocol.self]

        let baseURL = URL(string: "http://localhost:8100")!
        wdaClient = WDAClient(baseURL: baseURL, sessionConfig: config)

        // Inject a known session id so the /actions path is reachable.
        await wdaClient.injectSessionID("test-session-pinch")

        // 1:1 mapper, view == phone size.
        mapper = CoordinateMapper(
            phoneScreenSize: CGSize(width: 390, height: 844),
            viewSize: CGSize(width: 390, height: 844)
        )
        translator = InputTranslator(wdaClient: wdaClient, coordinateMapper: mapper)
    }

    override func tearDown() async throws {
        URLProtocol.unregisterClass(CapturingURLProtocol.self)
        CapturingURLProtocol.capturedBody = nil
        try await super.tearDown()
    }

    // MARK: - handlePinch sends two finger pointers

    func testHandlePinchSendsTwoFingerActions() async throws {
        let center = CGPoint(x: 195, y: 422)
        let scale: CGFloat = 1.5

        await translator.handlePinch(center: center, scale: scale)

        guard let body = CapturingURLProtocol.capturedBody else {
            XCTFail("No request body captured — pinch() was not called")
            return
        }

        let json = try JSONSerialization.jsonObject(with: body) as? [String: Any]
        let actions = json?["actions"] as? [[String: Any]]

        XCTAssertEqual(actions?.count, 2, "Expected exactly 2 pointer action sequences (one per finger)")

        let ids = actions?.compactMap { $0["id"] as? String }
        XCTAssertTrue(ids?.contains("finger1") == true, "finger1 id missing from actions")
        XCTAssertTrue(ids?.contains("finger2") == true, "finger2 id missing from actions")
    }

    func testHandlePinchFingersAreSymmetricAboutCenter() async throws {
        let center = CGPoint(x: 195, y: 422) // maps 1:1 to phone center
        let scale: CGFloat = 1.0

        await translator.handlePinch(center: center, scale: scale)

        guard let body = CapturingURLProtocol.capturedBody,
              let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
              let actions = json["actions"] as? [[String: Any]] else {
            XCTFail("No valid JSON body captured")
            return
        }

        // Each finger action list: [pointerMove(start), pointerDown, pointerMove(end), pointerUp]
        func startX(for fingerId: String) -> Double? {
            guard let entry = actions.first(where: { ($0["id"] as? String) == fingerId }),
                  let fingerActions = entry["actions"] as? [[String: Any]],
                  let first = fingerActions.first,
                  first["type"] as? String == "pointerMove"
            else { return nil }
            return first["x"] as? Double
        }

        let f1x = startX(for: "finger1")
        let f2x = startX(for: "finger2")

        XCTAssertNotNil(f1x)
        XCTAssertNotNil(f2x)

        // With scale=1, distance=100, starts should be ±50 from center x (195)
        XCTAssertEqual(f1x!, 145, accuracy: 0.001, "finger1 start x should be center - 50")
        XCTAssertEqual(f2x!, 245, accuracy: 0.001, "finger2 start x should be center + 50")
    }

    func testHandlePinchOutOfBoundsDoesNothing() async throws {
        // A point outside the phone screen should be rejected by the mapper → no request sent.
        CapturingURLProtocol.capturedBody = nil
        let offscreen = CGPoint(x: -100, y: -100)
        await translator.handlePinch(center: offscreen, scale: 1.0)
        XCTAssertNil(CapturingURLProtocol.capturedBody, "No request should be sent for an out-of-bounds point")
    }
}
