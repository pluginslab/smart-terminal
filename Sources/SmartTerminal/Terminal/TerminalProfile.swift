import AppKit
import SwiftTerm

/// Look and feel of every terminal. By default it is imported from Terminal.app's
/// default profile (font, colors, translucency, option-as-meta), so the app looks
/// like the terminal the user already configured.
struct TerminalProfile {
    var name: String
    var font: NSFont
    var background: NSColor
    var text: NSColor
    var boldText: NSColor?
    var selection: NSColor
    var cursor: NSColor
    /// 16 ANSI colors (normal 0-7, bright 8-15), nil = SwiftTerm defaults.
    var ansi: [NSColor]?
    var blur: Bool
    var optionAsMeta: Bool

    var isTranslucent: Bool { background.alphaComponent < 0.999 }

    /// Terminal.app's default profile if readable, else a built-in dark/light theme.
    static func load(dark: Bool) -> TerminalProfile {
        TerminalAppImporter.defaultProfile() ?? builtIn(dark: dark)
    }

    static func builtIn(dark: Bool) -> TerminalProfile {
        TerminalProfile(
            name: dark ? "Built-in Dark" : "Built-in Light",
            font: .monospacedSystemFont(ofSize: 13, weight: .regular),
            background: dark ? NSColor(hex: 0x1E1E1E) : .white,
            text: dark ? NSColor(hex: 0xE6E6E6) : NSColor(hex: 0x1D1D1F),
            boldText: nil,
            selection: dark ? NSColor(hex: 0x3F638B) : NSColor(hex: 0xB3D7FF),
            cursor: dark ? NSColor(hex: 0xA0A0A0) : NSColor(hex: 0x7F7F7F),
            ansi: nil, blur: false, optionAsMeta: false)
    }

    func apply(to view: TerminalView, fontSize: CGFloat?) {
        view.font = fontSize.flatMap { NSFont(descriptor: font.fontDescriptor, size: $0) } ?? font
        view.nativeForegroundColor = text
        view.nativeBackgroundColor = background
        view.selectedTextBackgroundColor = selection
        view.caretColor = cursor
        view.optionAsMetaKey = optionAsMeta
        if let ansi, ansi.count == 16 {
            view.installColors(ansi.map(\.swiftTermColor))
        }
    }
}

private extension NSColor {
    var swiftTermColor: SwiftTerm.Color {
        let c = usingColorSpace(.sRGB) ?? self
        return SwiftTerm.Color(red: UInt16(c.redComponent * 65535),
                               green: UInt16(c.greenComponent * 65535),
                               blue: UInt16(c.blueComponent * 65535))
    }
}

/// Reads `com.apple.Terminal` preferences. Values are NSKeyedArchiver blobs.
enum TerminalAppImporter {
    static func defaultProfile() -> TerminalProfile? {
        let domain = "com.apple.Terminal" as CFString
        guard let name = CFPreferencesCopyAppValue("Default Window Settings" as CFString, domain) as? String,
              let all = CFPreferencesCopyAppValue("Window Settings" as CFString, domain) as? [String: Any],
              let p = all[name] as? [String: Any] else { return nil }

        func color(_ key: String) -> NSColor? {
            (p[key] as? Data).flatMap { try? NSKeyedUnarchiver.unarchivedObject(ofClass: NSColor.self, from: $0) }
        }
        let font = (p["Font"] as? Data).flatMap { try? NSKeyedUnarchiver.unarchivedObject(ofClass: NSFont.self, from: $0) }
        let fallback = TerminalProfile.builtIn(dark: true)

        let ansiKeys = ["Black", "Red", "Green", "Yellow", "Blue", "Magenta", "Cyan", "White"]
        let normal = ansiKeys.map { color("ANSI\($0)Color") }
        let bright = ansiKeys.map { color("ANSIBright\($0)Color") }
        let ansi = (normal + bright).allSatisfy { $0 != nil } ? (normal + bright).map { $0! } : nil

        return TerminalProfile(
            name: name,
            font: font ?? fallback.font,
            background: color("BackgroundColor") ?? fallback.background,
            text: color("TextColor") ?? fallback.text,
            boldText: color("TextBoldColor"),
            selection: color("SelectionColor") ?? fallback.selection,
            cursor: color("CursorColor") ?? color("TextColor") ?? fallback.cursor,
            ansi: ansi,
            blur: ((p["BackgroundBlur"] as? Double) ?? 0) > 0,
            optionAsMeta: (p["useOptionAsMetaKey"] as? Bool) ?? false)
    }
}
