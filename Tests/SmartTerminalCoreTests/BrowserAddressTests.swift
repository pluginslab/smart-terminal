import Foundation
import Testing
@testable import SmartTerminalCore

@Suite struct BrowserAddressTests {
    @Test func addressBarEntries() {
        #expect(BrowserAddress.url(from: "https://example.com/a?b=1")?.absoluteString == "https://example.com/a?b=1")
        #expect(BrowserAddress.url(from: "  example.com/docs ")?.absoluteString == "https://example.com/docs")
        #expect(BrowserAddress.url(from: "localhost:3000")?.absoluteString == "http://localhost:3000")
        #expect(BrowserAddress.url(from: "127.0.0.1:8080/x")?.absoluteString == "http://127.0.0.1:8080/x")
        #expect(BrowserAddress.url(from: "swift concurrency")?.host == "duckduckgo.com")
        #expect(BrowserAddress.url(from: "readme")?.host == "duckduckgo.com")
        #expect(BrowserAddress.url(from: "   ") == nil)
    }

    @Test func onlyWebLinksAreTaken() {
        #expect(BrowserAddress.isWeb("https://github.com"))
        #expect(BrowserAddress.isWeb("HTTP://x.dev"))
        #expect(!BrowserAddress.isWeb("mailto:a@b.c"))
        #expect(!BrowserAddress.isWeb("file:///tmp/a"))
        #expect(!BrowserAddress.isWeb("vscode://file/x"))
    }

    @Test func inboxRequests() {
        let id = UUID()
        // Everything after the first space is the URL, spaces and all.
        #expect(BrowserRequest.parse("\(id.uuidString) https://example.com/x y\n")?.url.path == "/x y")
        #expect(BrowserRequest.parse("\(id.uuidString) https://example.com/x\n") == BrowserRequest(tabID: id, url: URL(string: "https://example.com/x")!))
        #expect(BrowserRequest.parse(" https://example.com") == nil)
        #expect(BrowserRequest.parse("- https://example.com")?.tabID == nil)
        #expect(BrowserRequest.parse("\(id.uuidString) mailto:a@b.c") == nil)
    }
}
