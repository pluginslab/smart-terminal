import Foundation

/// Reads and writes `AppLayout` as JSON. Writes are atomic.
public struct LayoutStore: Sendable {
    public let url: URL

    public init(url: URL) { self.url = url }

    /// `~/Library/Application Support/SmartTerminal/layout.json`
    /// (override the directory with `SMART_TERMINAL_SUPPORT_DIR` for dev builds).
    public static func `default`() -> LayoutStore {
        let dir: URL
        if let override = ProcessInfo.processInfo.environment["SMART_TERMINAL_SUPPORT_DIR"] {
            dir = URL(fileURLWithPath: override, isDirectory: true)
        } else {
            dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("SmartTerminal", isDirectory: true)
        }
        return LayoutStore(url: dir.appendingPathComponent("layout.json"))
    }

    /// The layout as it was before a save that dropped windows: `layout.json.prev`.
    public var backupURL: URL { url.appendingPathExtension("prev") }

    /// Returns nil when there is no file or it cannot be decoded (a corrupt file
    /// is kept aside as `layout.json.corrupt` instead of being silently overwritten).
    public func load() -> AppLayout? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        do {
            let layout = try JSONDecoder().decode(AppLayout.self, from: data)
            let hasTabs = layout.windows.contains { !$0.isEmpty } || !layout.closedWindows.isEmpty
            return hasTabs ? layout : nil
        } catch {
            let aside = url.appendingPathExtension("corrupt")
            try? FileManager.default.removeItem(at: aside)
            try? FileManager.default.moveItem(at: url, to: aside)
            return nil
        }
    }

    public func save(_ layout: AppLayout) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        var copy = layout
        copy.windows.removeAll { $0.isEmpty }
        copy.closedWindows.removeAll { $0.isEmpty }
        backUpIfDroppingWindows(for: copy)
        try encoder.encode(copy).write(to: url, options: .atomic)
    }

    /// Copies the file on disk to `backupURL` when the new layout has fewer windows,
    /// so a layout emptied by mistake can still be put back by hand.
    private func backUpIfDroppingWindows(for layout: AppLayout) {
        guard let data = try? Data(contentsOf: url),
              let old = try? JSONDecoder().decode(AppLayout.self, from: data),
              old.windows.count > layout.windows.count else { return }
        try? data.write(to: backupURL, options: .atomic)
    }
}
