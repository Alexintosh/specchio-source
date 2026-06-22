import XCTest
@testable import Specchio

final class WDAClientTests: XCTestCase {

    func testWDAStatusParsing() throws {
        let json = """
        {"value": {"ready": true, "message": "WebDriverAgent is ready"}}
        """.data(using: .utf8)!

        let status = try JSONDecoder().decode(WDAStatus.self, from: json)
        XCTAssertTrue(status.value.ready)
        XCTAssertEqual(status.value.message, "WebDriverAgent is ready")
    }

    func testWDAStatusNotReady() throws {
        let json = """
        {"value": {"ready": false, "message": null}}
        """.data(using: .utf8)!

        let status = try JSONDecoder().decode(WDAStatus.self, from: json)
        XCTAssertFalse(status.value.ready)
        XCTAssertNil(status.value.message)
    }

    func testWDASessionResponseParsing() throws {
        let json = """
        {"value": {"sessionId": "abc-123-def"}}
        """.data(using: .utf8)!

        let response = try JSONDecoder().decode(WDASessionResponse.self, from: json)
        XCTAssertEqual(response.sessionId, "abc-123-def")
    }

    func testWDAScreenshotResponseParsing() throws {
        let base64 = Data("test image data".utf8).base64EncodedString()
        let json = """
        {"value": "\(base64)"}
        """.data(using: .utf8)!

        let response = try JSONDecoder().decode(WDAScreenshotResponse.self, from: json)
        XCTAssertEqual(response.value, base64)

        let decoded = Data(base64Encoded: response.value)
        XCTAssertNotNil(decoded)
        XCTAssertEqual(String(data: decoded!, encoding: .utf8), "test image data")
    }

    func testWDAWindowSizeResponseParsing() throws {
        let json = """
        {"value": {"width": 390.0, "height": 844.0}}
        """.data(using: .utf8)!

        let response = try JSONDecoder().decode(WDAWindowSizeResponse.self, from: json)
        XCTAssertEqual(response.value.width, 390.0)
        XCTAssertEqual(response.value.height, 844.0)
    }

    func testWDAGenericResponseParsing() throws {
        let json = """
        {"value": null, "sessionId": "test-session"}
        """.data(using: .utf8)!

        let response = try JSONDecoder().decode(WDAGenericResponse.self, from: json)
        XCTAssertEqual(response.sessionId, "test-session")
    }

    func testConnectionStateIsConnected() {
        XCTAssertTrue(ConnectionState.usb(host: "localhost", port: 8100).isConnected)
        XCTAssertTrue(ConnectionState.wifi(host: "192.168.1.1", port: 8100).isConnected)
        XCTAssertFalse(ConnectionState.disconnected.isConnected)
        XCTAssertFalse(ConnectionState.connecting.isConnected)
        XCTAssertFalse(ConnectionState.failed(error: "test").isConnected)
    }

    func testConnectionStateBaseURL() {
        let usb = ConnectionState.usb(host: "localhost", port: 8100)
        XCTAssertEqual(usb.baseURL?.absoluteString, "http://localhost:8100")

        let wifi = ConnectionState.wifi(host: "192.168.1.50", port: 8100)
        XCTAssertEqual(wifi.baseURL?.absoluteString, "http://192.168.1.50:8100")

        XCTAssertNil(ConnectionState.disconnected.baseURL)
    }

    func testAnyCodableDecoding() throws {
        let json = """
        {"value": "hello", "sessionId": null}
        """.data(using: .utf8)!

        let response = try JSONDecoder().decode(WDAGenericResponse.self, from: json)
        XCTAssertNotNil(response.value)
    }

    // MARK: - WDASessionResponse top-level sessionId (real WDA format)

    func testWDASessionResponseTopLevelSessionIdPreferred() throws {
        // Real WDA returns sessionId at the top level as well as inside value.
        let json = """
        {"sessionId": "top-level-id", "value": {"sessionId": "nested-id"}}
        """.data(using: .utf8)!

        let response = try JSONDecoder().decode(WDASessionResponse.self, from: json)
        XCTAssertEqual(response.sessionId, "top-level-id",
                       "Top-level sessionId should be preferred over value.sessionId")
    }

    func testWDASessionResponseFallsBackToNestedSessionId() throws {
        // When there is no top-level sessionId the nested one must still work.
        let json = """
        {"value": {"sessionId": "nested-only-id"}}
        """.data(using: .utf8)!

        let response = try JSONDecoder().decode(WDASessionResponse.self, from: json)
        XCTAssertEqual(response.sessionId, "nested-only-id",
                       "Should fall back to value.sessionId when top-level sessionId is absent")
    }
}
