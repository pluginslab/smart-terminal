import Foundation

/// The little HTTP the gate's endpoint needs: one request per connection, one JSON answer.
public struct HTTPRequest: Equatable {
    public var method: String
    public var path: String
    /// Lowercased names.
    public var headers: [String: String]
    public var body: Data

    /// Parses a complete request from the start of `data`. Nil while more is needed;
    /// `consumed` tells how many bytes it took.
    public static func parse(_ data: Data) -> (request: HTTPRequest, consumed: Int)? {
        guard let end = data.range(of: Data("\r\n\r\n".utf8)) else { return nil }
        let head = String(decoding: data[data.startIndex..<end.lowerBound], as: UTF8.self)
        var lines = head.components(separatedBy: "\r\n")
        let start = lines.removeFirst().split(separator: " ")
        guard start.count >= 2 else { return nil }
        var headers: [String: String] = [:]
        for line in lines {
            guard let colon = line.firstIndex(of: ":") else { continue }
            headers[line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()] =
                line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        let length = Int(headers["content-length"] ?? "") ?? 0
        let bodyStart = end.upperBound
        guard data.distance(from: bodyStart, to: data.endIndex) >= length else { return nil }
        let body = data[bodyStart..<data.index(bodyStart, offsetBy: length)]
        return (HTTPRequest(method: String(start[0]), path: String(start[1]), headers: headers, body: Data(body)),
                data.distance(from: data.startIndex, to: body.endIndex))
    }

    /// The bearer token, if the request carries one.
    public var bearerToken: String? {
        guard let auth = headers["authorization"], auth.lowercased().hasPrefix("bearer ") else { return nil }
        return String(auth.dropFirst("bearer ".count)).trimmingCharacters(in: .whitespaces)
    }
}

public enum HTTPResponse {
    public static func json(_ status: Int, _ object: Any) -> Data {
        let body = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data()
        return make(status, contentType: "application/json", body: body)
    }

    public static func make(_ status: Int, contentType: String = "text/plain", body: Data = Data()) -> Data {
        let reason = [200: "OK", 400: "Bad Request", 401: "Unauthorized", 404: "Not Found",
                      405: "Method Not Allowed", 409: "Conflict", 503: "Service Unavailable"][status] ?? "Error"
        var head = "HTTP/1.1 \(status) \(reason)\r\nContent-Type: \(contentType)\r\n"
        head += "Content-Length: \(body.count)\r\nConnection: close\r\n\r\n"
        return Data(head.utf8) + body
    }
}
