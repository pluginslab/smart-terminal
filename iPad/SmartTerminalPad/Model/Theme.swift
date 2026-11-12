import SwiftUI
import UIKit
import SwiftTerm
import SmartTerminalCore

/// The Mac's terminal profile ("Clear Dark", FiraCode Nerd Font Mono 15) and the
/// "Harbor" panels derived from its background, as in the Mac app's PanelPalette.
enum Theme {
    static let background = UIColor(hex: 0x102030)
    static let text = UIColor(hex: 0xC8D3DF)
    static let selectionText = UIColor(hex: 0x334D5E)
    static let ansi: [UInt32] = [0x35424B, 0xB35547, 0x6CAA70, 0xC4AB62, 0x6D95B3, 0xBD7BCC, 0x7BCACD, 0xDDE5EB,
                                 0x465C6C, 0xDF6C59, 0x78BD7D, 0xE5C871, 0x66B5EC, 0xD389E5, 0x84DDE0, 0xE5EEF5]

    static func apply(to view: TerminalView) {
        let size: CGFloat = 15
        let regular = UIFont(name: "FiraCodeNFM-Reg", size: size) ?? .monospacedSystemFont(ofSize: size, weight: .regular)
        let bold = UIFont(name: "FiraCodeNFM-Bold", size: size) ?? .monospacedSystemFont(ofSize: size, weight: .bold)
        view.setFonts(normal: regular, bold: bold, italic: regular, boldItalic: bold)
        view.nativeForegroundColor = text
        view.nativeBackgroundColor = background
        view.selectedTextBackgroundColor = selectionText
        view.caretColor = text
        view.optionAsMetaKey = false
        view.installColors(ansi.map { h in
            SwiftTerm.Color(red: UInt16((h >> 16) & 0xFF) * 257, green: UInt16((h >> 8) & 0xFF) * 257,
                            blue: UInt16(h & 0xFF) * 257)
        })
    }

    // Harbor: a step lighter than the terminal, in its hue.
    static let side = shade(0.040, sat: 0.94)
    static let list = shade(0.028, sat: 0.95)
    static let head = shade(0.028, sat: 0.95)
    static let bar = shade(-0.014)
    static let line = shade(0.12, sat: 0.85)
    /// The selected session: Claude's amber, with dark text on it.
    static let selection = SwiftUI.Color(red: 0xe8 / 255, green: 0xa3 / 255, blue: 0x3d / 255)
    static let onSelection = SwiftUI.Color(red: 0x1a / 255, green: 0x12 / 255, blue: 0x05 / 255)
    static var selectionSoft: SwiftUI.Color { selection.opacity(0.16) }
    static let claudeOrange = SwiftUI.Color(red: 0.85, green: 0.47, blue: 0.34)

    private static func shade(_ db: CGFloat, sat: CGFloat = 1) -> SwiftUI.Color {
        var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        background.getHue(&h, saturation: &s, brightness: &b, alpha: &a)
        return SwiftUI.Color(uiColor: UIColor(hue: h, saturation: min(1, s * sat), brightness: max(0, min(1, b + db)), alpha: 1))
    }
}

extension UIColor {
    convenience init(hex: UInt32) {
        self.init(red: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                  blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
    }
}

extension GroupColor {
    /// Chrome's group palette (dark variant: the panels are always dark here).
    var color: SwiftUI.Color {
        let hex: UInt32 = switch self {
        case .grey: 0xDADCE0
        case .blue: 0x8AB4F8
        case .red: 0xF28B82
        case .yellow: 0xFDD663
        case .green: 0x81C995
        case .pink: 0xFF8BCB
        case .purple: 0xC58AF9
        case .cyan: 0x78D9EC
        case .orange: 0xFCAD70
        }
        return SwiftUI.Color(uiColor: UIColor(hex: hex))
    }
}
