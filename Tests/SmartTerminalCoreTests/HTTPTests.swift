import Foundation
import Testing
@testable import SmartTerminalCore

@Suite struct HTTPTests {
    @Test func requestsParseOnceComplete() {
        let raw = Data("POST /v1/commands HTTP/1.1\r\nHost: x\r\nAuthorization: Bearer abc\r\nContent-Length: 2\r\n\r\n{}".utf8)
        #expect(HTTPRequest.parse(raw.dropLast()) == nil)
        let (req, used) = HTTPRequest.parse(raw)!
        #expect(req.method == "POST" && req.path == "/v1/commands")
        #expect(req.bearerToken == "abc" && req.body == Data("{}".utf8) && used == raw.count)
    }
}
