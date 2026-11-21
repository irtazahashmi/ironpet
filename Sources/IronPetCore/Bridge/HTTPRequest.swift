import Foundation

/// One parsed HTTP request. `EventServer` reads the bytes off a socket; this type knows only the wire format.
package struct HTTPRequest {
    package init(method: String, path: String, headers: [String: String], body: Data) {
        self.method = method
        self.path = path
        self.headers = headers
        self.body = body
    }

    package let method: String
    package let path: String
    package let headers: [String: String]
    package let body: Data

    package func header(_ name: String) -> String? { headers[name.lowercased()] }

    /// Returns nil until the buffer holds the full headers and `Content-Length` body.
    package static func parse(_ buffer: Data) -> HTTPRequest?? {
        guard let split = buffer.range(of: Data("\r\n\r\n".utf8)) else { return nil }
        guard let head = String(data: buffer[..<split.lowerBound], encoding: .utf8) else { return .some(nil) }
        var lines = head.components(separatedBy: "\r\n")
        let requestLine = lines.removeFirst().split(separator: " ")
        guard requestLine.count >= 2 else { return .some(nil) }
        var headers: [String: String] = [:]
        for line in lines {
            guard let colon = line.firstIndex(of: ":") else { continue }
            headers[line[..<colon].lowercased()] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        let length = Int(headers["content-length"] ?? "0") ?? 0
        let body = buffer[split.upperBound...]
        guard body.count >= length else { return nil }
        return HTTPRequest(method: String(requestLine[0]), path: String(requestLine[1]),
                           headers: headers, body: Data(body.prefix(length)))
    }
}
