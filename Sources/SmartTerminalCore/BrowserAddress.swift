import Foundation

/// What the embedded browser does with an address-bar entry or an `open` request.
public enum BrowserAddress {
    /// A URL to load: web URLs as they are, `example.com/x` and `localhost:3000`
    /// with a scheme added, anything else as a web search.
    public static func url(from input: String) -> URL? {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        if let url = URL(string: text), let scheme = url.scheme?.lowercased(),
           ["http", "https", "file", "about"].contains(scheme) {
            return url
        }
        if !text.contains(" "), looksLikeHost(text) {
            let local = text.hasPrefix("localhost") || text.hasPrefix("127.") || text.hasPrefix("[::1]")
            return URL(string: (local ? "http://" : "https://") + text)
        }
        var search = URLComponents(string: "https://duckduckgo.com/")!
        search.queryItems = [URLQueryItem(name: "q", value: text)]
        return search.url
    }

    /// "example.com", "example.com/path", "localhost:3000", "10.0.0.2:8080".
    static func looksLikeHost(_ text: String) -> Bool {
        let host = text.split(separator: "/", maxSplits: 1).first.map(String.init) ?? text
        let name = host.split(separator: ":").first.map(String.init) ?? host
        if name == "localhost" { return true }
        return name.contains(".") && !name.hasPrefix(".") && !name.hasSuffix(".")
    }

    /// Only web pages go to the embedded browser; mail, files and app links keep
    /// opening where macOS sends them.
    public static func isWeb(_ link: String) -> Bool {
        guard let scheme = URL(string: link)?.scheme?.lowercased() else { return false }
        return scheme == "http" || scheme == "https"
    }
}

/// One request from the shell integration's `open`: "<tab id> <url>" in a file
/// dropped into the app's inbox folder.
public struct BrowserRequest: Equatable, Sendable {
    public let tabID: UUID?
    public let url: URL

    public init(tabID: UUID?, url: URL) { self.tabID = tabID; self.url = url }

    public static func parse(_ text: String) -> BrowserRequest? {
        let line = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = line.split(separator: " ", maxSplits: 1).map(String.init)
        guard parts.count == 2, BrowserAddress.isWeb(parts[1]), let url = URL(string: parts[1]) else { return nil }
        return BrowserRequest(tabID: UUID(uuidString: parts[0]), url: url)
    }
}
