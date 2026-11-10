import AppKit
import SwiftUI

/// The panels' colours (groups, sessions, title and status bars) when the terminal is
/// dark: "Harbor", a step lighter than the terminal's own background and in its hue,
/// so the panels sit around it like a dock around deep water. Derived from the
/// profile, so another background brings matching panels. A light terminal keeps the
/// system's colours (nil).
struct PanelPalette: Equatable {
    var side: Color
    var list: Color
    var head: Color
    var bar: Color
    var line: Color
    /// The selected session: Claude's amber, with dark text on it.
    var selection = Color(red: 0xe8 / 255, green: 0xa3 / 255, blue: 0x3d / 255)
    var onSelection = Color(red: 0x1a / 255, green: 0x12 / 255, blue: 0x05 / 255)
    var selectionSoft: Color { selection.opacity(0.16) }

    static func derived(from terminal: NSColor) -> PanelPalette? {
        guard let c = terminal.usingColorSpace(.sRGB) else { return nil }
        var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        c.getHue(&h, saturation: &s, brightness: &b, alpha: &a)
        guard b < 0.4 else { return nil }
        func shade(_ db: CGFloat, sat: CGFloat = 1) -> Color {
            Color(nsColor: NSColor(srgbHue: h, saturation: min(1, s * sat), brightness: max(0, min(1, b + db)), alpha: 1))
        }
        // For the profile's #102031: groups #16283b, sessions #142538, status #0e1d2d.
        return PanelPalette(side: shade(0.040, sat: 0.94), list: shade(0.028, sat: 0.95),
                            head: shade(0.028, sat: 0.95), bar: shade(-0.014), line: shade(0.12, sat: 0.85))
    }
}

private struct PanelPaletteKey: EnvironmentKey {
    static let defaultValue: PanelPalette? = nil
}

extension EnvironmentValues {
    var panelPalette: PanelPalette? {
        get { self[PanelPaletteKey.self] }
        set { self[PanelPaletteKey.self] = newValue }
    }
}

extension NSColor {
    convenience init(srgbHue h: CGFloat, saturation s: CGFloat, brightness b: CGFloat, alpha: CGFloat) {
        let hsb = NSColor(hue: h, saturation: s, brightness: b, alpha: alpha)
        let c = hsb.usingColorSpace(.sRGB) ?? hsb
        self.init(srgbRed: c.redComponent, green: c.greenComponent, blue: c.blueComponent, alpha: alpha)
    }
}
