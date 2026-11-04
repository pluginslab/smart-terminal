import Foundation
import Testing
@testable import SmartTerminalCore

@Suite struct WebSocketTests {
    @Test func acceptValueMatchesTheRFCExample() {
        #expect(WebSocketCodec.acceptValue(for: "dGhlIHNhbXBsZSBub25jZQ==") == "s3pPLMBiTxaQ9kYGzzhZRbK+xOo=")
    }

    @Test func requestsParseOnceComplete() {
        let raw = Data("POST /v1/browsers HTTP/1.1\r\nHost: x\r\nAuthorization: Bearer abc\r\nContent-Length: 2\r\n\r\n{}".utf8)
        #expect(HTTPRequest.parse(raw.dropLast()) == nil)
        let (req, used) = HTTPRequest.parse(raw)!
        #expect(req.method == "POST" && req.path == "/v1/browsers")
        #expect(req.bearerToken == "abc" && req.body == Data("{}".utf8) && used == raw.count)
        let up = HTTPRequest.parse(Data("GET /devtools/browser/t HTTP/1.1\r\nUpgrade: websocket\r\nSec-WebSocket-Key: k\r\n\r\n".utf8))!.request
        #expect(up.isWebSocketUpgrade)
    }

    @Test func framesOfEverySizeRoundTrip() throws {
        for size in [0, 5, 125, 126, 300, 65535, 65536, 200_000] {
            let payload = Data((0..<size).map { UInt8($0 & 0xFF) })
            var codec = WebSocketCodec()
            #expect(try codec.receive(WebSocketCodec.clientFrame(payload)) == [.text(payload)], "size \(size)")
        }
        // Server frames: header sizes.
        #expect(WebSocketCodec.frame(Data(count: 10)).count == 12)
        #expect(WebSocketCodec.frame(Data(count: 1000)).count == 1004)
        #expect(WebSocketCodec.frame(Data(count: 70000)).count == 70010)
    }

    @Test func splitAndFragmentedMessagesAreReassembled() throws {
        var codec = WebSocketCodec()
        let wire = WebSocketCodec.clientFrame(Data("hel".utf8), fin: false)
            + WebSocketCodec.clientFrame(Data("lo".utf8), opcode: 0x0)
            + WebSocketCodec.clientFrame(Data(), opcode: 0x9)
        var got: [WebSocketCodec.Message] = []
        for byte in wire { got += try codec.receive(Data([byte])) }
        #expect(got == [.text(Data("hello".utf8)), .ping(Data())])
    }

    @Test func unmaskedClientFramesAreRefused() {
        var codec = WebSocketCodec()
        #expect(throws: WebSocketCodec.CodecError.self) { try codec.receive(WebSocketCodec.frame(Data("x".utf8))) }
    }
}
