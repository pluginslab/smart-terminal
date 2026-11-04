import CryptoKit
import Foundation

/// The little HTTP the gate's endpoint needs: one request per connection, then either a
/// JSON answer or an upgrade to a WebSocket.
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

    public var isWebSocketUpgrade: Bool {
        headers["upgrade"]?.lowercased() == "websocket" && headers["sec-websocket-key"] != nil
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

    /// Accepts a WebSocket upgrade (RFC 6455).
    public static func upgrade(key: String) -> Data {
        Data(("HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n" +
              "Sec-WebSocket-Accept: \(WebSocketCodec.acceptValue(for: key))\r\n\r\n").utf8)
    }
}

/// WebSocket frames, server side: clients mask, we don't.
public struct WebSocketCodec {
    public enum Message: Equatable {
        case text(Data)
        case binary(Data)
        case ping(Data)
        case close
    }

    private var buffer = Data()
    private var fragments = Data()
    private var fragmentOpcode: UInt8 = 0
    /// Frames bigger than this close the connection (a heap snapshot is far smaller).
    public var maxMessageSize = 256 << 20

    public init() {}

    public static func acceptValue(for key: String) -> String {
        let digest = Insecure.SHA1.hash(data: Data((key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11").utf8))
        return Data(digest).base64EncodedString()
    }

    /// Feeds received bytes; returns the complete messages they finished.
    /// Throws on a protocol violation (unmasked or oversized frames).
    public mutating func receive(_ data: Data) throws -> [Message] {
        buffer.append(data)
        var out: [Message] = []
        while let (frame, used) = try nextFrame() {
            buffer.removeSubrange(buffer.startIndex..<buffer.index(buffer.startIndex, offsetBy: used))
            switch frame.opcode {
            case 0x8: out.append(.close)
            case 0x9: out.append(.ping(frame.payload))
            case 0xA: break // pong
            case 0x0, 0x1, 0x2:
                if frame.opcode != 0 { fragmentOpcode = frame.opcode; fragments = Data() }
                fragments.append(frame.payload)
                guard fragments.count <= maxMessageSize else { throw CodecError.tooLarge }
                if frame.fin {
                    out.append(fragmentOpcode == 0x1 ? .text(fragments) : .binary(fragments))
                    fragments = Data()
                }
            default: throw CodecError.badFrame
            }
        }
        buffer = Data(buffer) // re-base indices
        return out
    }

    public enum CodecError: Error { case badFrame, unmasked, tooLarge }

    private func nextFrame() throws -> (frame: (fin: Bool, opcode: UInt8, payload: Data), used: Int)? {
        let b = [UInt8](buffer.prefix(14))
        guard b.count >= 2 else { return nil }
        let fin = b[0] & 0x80 != 0
        let opcode = b[0] & 0x0F
        guard b[1] & 0x80 != 0 else { throw CodecError.unmasked }
        var length = Int(b[1] & 0x7F)
        var offset = 2
        if length == 126 {
            guard b.count >= 4 else { return nil }
            length = Int(b[2]) << 8 | Int(b[3])
            offset = 4
        } else if length == 127 {
            guard b.count >= 10 else { return nil }
            length = (2..<10).reduce(0) { $0 << 8 | Int(b[$1]) }
            offset = 10
        }
        guard length <= maxMessageSize else { throw CodecError.tooLarge }
        guard buffer.count >= offset + 4 + length else { return nil }
        let start = buffer.startIndex
        let mask = [UInt8](buffer[buffer.index(start, offsetBy: offset)..<buffer.index(start, offsetBy: offset + 4)])
        var payload = [UInt8](buffer[buffer.index(start, offsetBy: offset + 4)..<buffer.index(start, offsetBy: offset + 4 + length)])
        for i in payload.indices { payload[i] ^= mask[i & 3] }
        return ((fin, opcode, Data(payload)), offset + 4 + length)
    }

    /// One unmasked frame.
    public static func frame(_ payload: Data, opcode: UInt8 = 0x1) -> Data {
        var head: [UInt8] = [0x80 | opcode]
        switch payload.count {
        case ..<126: head.append(UInt8(payload.count))
        case ..<65536: head += [126, UInt8(payload.count >> 8), UInt8(payload.count & 0xFF)]
        default: head.append(127); head += (0..<8).reversed().map { UInt8((payload.count >> ($0 * 8)) & 0xFF) }
        }
        return Data(head) + payload
    }

    /// A frame as a client sends it (masked), for tests.
    public static func clientFrame(_ payload: Data, opcode: UInt8 = 0x1, fin: Bool = true, mask: [UInt8] = [1, 2, 3, 4]) -> Data {
        var head: [UInt8] = [(fin ? 0x80 : 0) | opcode]
        switch payload.count {
        case ..<126: head.append(0x80 | UInt8(payload.count))
        case ..<65536: head += [UInt8(0x80 | 126), UInt8(payload.count >> 8), UInt8(payload.count & 0xFF)]
        default: head.append(UInt8(0x80 | 127)); head += (0..<8).reversed().map { UInt8((payload.count >> ($0 * 8)) & 0xFF) }
        }
        let masked = payload.enumerated().map { $0.element ^ mask[$0.offset & 3] }
        return Data(head + mask + masked)
    }
}
