import Foundation

struct AirPlayControlResponse: Equatable {
    let statusCode: Int
    let reasonPhrase: String
    var headers: [String: String]
    var body: Data

    init(statusCode: Int = 200, reasonPhrase: String = "OK", headers: [String: String] = [:], body: Data = Data()) {
        self.statusCode = statusCode
        self.reasonPhrase = reasonPhrase
        self.headers = headers
        self.body = body
    }

    static func ok(headers: [String: String] = [:], body: Data = Data()) -> AirPlayControlResponse {
        AirPlayControlResponse(headers: headers, body: body)
    }

    static func switchingProtocols(headers: [String: String] = [:]) -> AirPlayControlResponse {
        var mergedHeaders = headers
        mergedHeaders["Connection"] = mergedHeaders["Connection"] ?? "Upgrade"
        mergedHeaders["Upgrade"] = mergedHeaders["Upgrade"] ?? "PTTH/1.0"
        return AirPlayControlResponse(
            statusCode: 101,
            reasonPhrase: "Switching Protocols",
            headers: mergedHeaders
        )
    }

    static func badRequest(_ message: String) -> AirPlayControlResponse {
        AirPlayControlResponse(
            statusCode: 400,
            reasonPhrase: "Bad Request",
            headers: ["Content-Type": "text/plain; charset=utf-8"],
            body: Data(message.utf8)
        )
    }

    static func notFound(_ message: String) -> AirPlayControlResponse {
        AirPlayControlResponse(
            statusCode: 404,
            reasonPhrase: "Not Found",
            headers: ["Content-Type": "text/plain; charset=utf-8"],
            body: Data(message.utf8)
        )
    }

    static func notImplemented(_ message: String) -> AirPlayControlResponse {
        AirPlayControlResponse(
            statusCode: 501,
            reasonPhrase: "Not Implemented",
            headers: ["Content-Type": "text/plain; charset=utf-8"],
            body: Data(message.utf8)
        )
    }

    static func parameterNotUnderstood(_ message: String) -> AirPlayControlResponse {
        AirPlayControlResponse(
            statusCode: 451,
            reasonPhrase: "Parameter Not Understood",
            headers: ["Content-Type": "text/plain; charset=utf-8"],
            body: Data(message.utf8)
        )
    }

    static func clientAuthenticationFailure(_ message: String) -> AirPlayControlResponse {
        AirPlayControlResponse(
            statusCode: 470,
            reasonPhrase: "Client Authentication Failure",
            headers: ["Content-Type": "text/plain; charset=utf-8"],
            body: Data(message.utf8)
        )
    }

    func serialized(protocolVersion: String = "RTSP/1.0", cseq: String? = nil) -> Data {
        var mergedHeaders = headers
        mergedHeaders["Server"] = mergedHeaders["Server"] ?? "AirTunes/220.68"
        mergedHeaders["Content-Length"] = String(body.count)
        if let cseq {
            mergedHeaders["CSeq"] = cseq
        }

        var text = "\(protocolVersion) \(statusCode) \(reasonPhrase)\r\n"
        for key in mergedHeaders.keys.sorted(by: { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }) {
            guard let value = mergedHeaders[key] else { continue }
            text += "\(key): \(value)\r\n"
        }
        text += "\r\n"

        var data = Data(text.utf8)
        data.append(body)
        return data
    }
}
