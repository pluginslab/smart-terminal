import AppKit
import SmartTerminalCore

/// Applies Terminal.app's Option key bindings (`TerminalKeyMap`) to the focused tab.
///
/// Terminal.app applies them in its terminal view. Here that would be SwiftTerm's
/// `keyDown`, which is public, not open, and settles some Option keys before the text
/// system sees them: ⌥⌦ goes out as a plain forward delete, and so does every
/// functional key once a program turns on the kitty keyboard protocol. So the binding
/// is applied on the way in, by a local event monitor.
@MainActor
enum KeyBindings {
    private static var monitor: Any?

    static func install() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            handle(event)
        }
    }

    private static func handle(_ event: NSEvent) -> NSEvent? {
        // Locked: TerminalWindow drops keys aimed at a terminal, but this monitor runs
        // before the window sees the event, so it has to step aside on its own.
        guard !AppLock.shared.locked,
              let view = event.window?.firstResponder as? SmartTerminalView,
              let bytes = bytes(for: event, in: view) else { return event }
        // The app's own shortcuts win, as the menus do in Terminal.app (⌃⌥← moves a tab).
        if NSApp.mainMenu?.performKeyEquivalent(with: event) == true { return nil }
        view.send(data: bytes[...])
        return nil
    }

    private static func bytes(for event: NSEvent, in view: SmartTerminalView) -> [UInt8]? {
        let flags = event.modifierFlags
        // Not while a dead key or an input method is composing: the binding would cut it off.
        guard !view.keyMap.isEmpty, flags.contains(.option), !flags.contains(.command),
              !view.hasMarkedText(), let key = event.charactersIgnoringModifiers?.utf16.first else { return nil }
        // Arrows also carry .function and .numericPad, which Terminal's bindings don't name.
        var modifiers: TerminalKeyMap.Modifiers = [.option]
        if flags.contains(.control) { modifiers.insert(.control) }
        if flags.contains(.shift) { modifiers.insert(.shift) }
        return view.keyMap.bytes(modifiers: modifiers, key: key)
    }
}
