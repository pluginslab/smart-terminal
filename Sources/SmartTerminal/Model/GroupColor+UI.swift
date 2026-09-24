import AppKit
import SwiftUI
import SmartTerminalCore

extension GroupColor {
    /// Chrome's group palette, tuned per appearance.
    var nsColor: NSColor {
        NSColor(name: nil) { appearance in
            let dark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            switch self {
            case .grey:   return dark ? NSColor(hex: 0xDADCE0) : NSColor(hex: 0x5F6368)
            case .blue:   return dark ? NSColor(hex: 0x8AB4F8) : NSColor(hex: 0x1A73E8)
            case .red:    return dark ? NSColor(hex: 0xF28B82) : NSColor(hex: 0xD93025)
            case .yellow: return dark ? NSColor(hex: 0xFDD663) : NSColor(hex: 0xE37400)
            case .green:  return dark ? NSColor(hex: 0x81C995) : NSColor(hex: 0x1E8E3E)
            case .pink:   return dark ? NSColor(hex: 0xFF8BCB) : NSColor(hex: 0xD01884)
            case .purple: return dark ? NSColor(hex: 0xC58AF9) : NSColor(hex: 0x9334E6)
            case .cyan:   return dark ? NSColor(hex: 0x78D9EC) : NSColor(hex: 0x007B83)
            case .orange: return dark ? NSColor(hex: 0xFCAD70) : NSColor(hex: 0xFA903E)
            }
        }
    }

    var color: Color { Color(nsColor: nsColor) }

    /// Text drawn on top of the chip fill.
    var onColor: Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                ? NSColor(hex: 0x202124) : .white
        })
    }
}

extension NSColor {
    convenience init(hex: UInt32, alpha: CGFloat = 1) {
        self.init(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
                  green: CGFloat((hex >> 8) & 0xFF) / 255,
                  blue: CGFloat(hex & 0xFF) / 255,
                  alpha: alpha)
    }
}
