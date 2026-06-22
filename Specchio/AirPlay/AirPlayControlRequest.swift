import Foundation

struct AirPlayControlRequest: Equatable {
    enum ParseError: Error, Equatable {
        case malformedStartLine(String)
        case malformedHeader(String)
        case invalidContentLength(String)
    }

    let method: String
    let path: String
    let protocolVersion: String
    let headers: [String: String]
    let body: Data

    var cseq: String? {
        headerValue("CSeq")
    }

    var contentLength: Int {
        body.count
    }

    var routePath: String {
        guard path.contains("://") else {
            return path
        }
        if let components = URLComponents(string: path) {
            return components.path.isEmpty ? "/" : components.path
        }

        guard let schemeEnd = path.range(of: "://")?.upperBound else {
            return path
        }
        let authorityAndPath = path[schemeEnd...]
        guard let pathStart = authorityAndPath.firstIndex(of: "/") else {
            return "/"
        }
        let pathAndSuffix = authorityAndPath[pathStart...]
        let queryStart = pathAndSuffix.firstIndex(of: "?") ?? pathAndSuffix.endIndex
        let fragmentStart = pathAndSuffix.firstIndex(of: "#") ?? pathAndSuffix.endIndex
        let pathEnd = min(queryStart, fragmentStart)
        let extractedPath = String(pathAndSuffix[..<pathEnd])
        return extractedPath.isEmpty ? "/" : extractedPath
    }

    var routePathWithoutQuery: String {
        let route = routePath
        let queryStart = route.firstIndex(of: "?") ?? route.endIndex
        let fragmentStart = route.firstIndex(of: "#") ?? route.endIndex
        let pathEnd = min(queryStart, fragmentStart)
        let value = String(route[..<pathEnd])
        return value.isEmpty ? "/" : value
    }

    var routeQuery: String? {
        if path.contains("://"),
           let components = URLComponents(string: path),
           let query = components.percentEncodedQuery {
            return query
        }

        let route = routePath
        guard let queryStart = route.firstIndex(of: "?") else {
            return nil
        }
        let valueStart = route.index(after: queryStart)
        let fragmentStart = route[valueStart...].firstIndex(of: "#") ?? route.endIndex
        return String(route[valueStart..<fragmentStart])
    }

    func headerValue(_ name: String) -> String? {
        let lowercasedName = name.lowercased()
        return headers.first { $0.key.lowercased() == lowercasedName }?.value
    }

    var sanitizedHeadersForLog: String {
        let sensitiveNames: Set<String> = [
            "authorization",
            "x-apple-session-id",
            "x-apple-hkp",
            "x-apple-etu"
        ]
        return headers
            .sorted { $0.key.localizedCaseInsensitiveCompare($1.key) == .orderedAscending }
            .map { key, value in
                if sensitiveNames.contains(key.lowercased()) {
                    return "\(key)=<redacted>"
                }
                return "\(key)=\(value)"
            }
            .joined(separator: ";")
    }

    static func parse(from buffer: Data) throws -> (request: AirPlayControlRequest, consumedBytes: Int)? {
        guard let headerEnd = buffer.range(of: Data("\r\n\r\n".utf8)) else {
            return nil
        }

        let headerData = buffer.subdata(in: buffer.startIndex..<headerEnd.lowerBound)
        guard let headerText = String(data: headerData, encoding: .utf8) else {
            throw ParseError.malformedStartLine("headers are not UTF-8")
        }

        let rows = headerText.components(separatedBy: "\r\n")
        guard let startLine = rows.first else {
            throw ParseError.malformedStartLine("missing start line")
        }

        let startParts = startLine.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: false)
        guard startParts.count == 3 else {
            throw ParseError.malformedStartLine(startLine)
        }

        var headers: [String: String] = [:]
        for row in rows.dropFirst() where !row.isEmpty {
            guard let colonIndex = row.firstIndex(of: ":") else {
                throw ParseError.malformedHeader(row)
            }
            let name = String(row[..<colonIndex]).trimmingCharacters(in: .whitespaces)
            let valueStart = row.index(after: colonIndex)
            let value = String(row[valueStart...]).trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty else {
                throw ParseError.malformedHeader(row)
            }
            headers[name] = value
        }

        let declaredContentLength: Int
        if let contentLengthValue = headers.first(where: { $0.key.lowercased() == "content-length" })?.value {
            guard let parsed = Int(contentLengthValue), parsed >= 0 else {
                throw ParseError.invalidContentLength(contentLengthValue)
            }
            declaredContentLength = parsed
        } else {
            declaredContentLength = 0
        }

        let bodyStart = headerEnd.upperBound
        let requiredEnd = bodyStart + declaredContentLength
        guard buffer.count >= requiredEnd else {
            return nil
        }

        let body = declaredContentLength == 0 ? Data() : buffer.subdata(in: bodyStart..<requiredEnd)
        return (
            AirPlayControlRequest(
                method: String(startParts[0]),
                path: String(startParts[1]),
                protocolVersion: String(startParts[2]),
                headers: headers,
                body: body
            ),
            requiredEnd
        )
    }
}
