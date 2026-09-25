import AppKit

@MainActor
enum MainMenu {
    static func build(target: AppDelegate) -> NSMenu {
        let main = NSMenu()
        let appName = "Smart Terminal"

        func item(_ title: String, _ action: Selector?, _ key: String = "",
                  _ mods: NSEvent.ModifierFlags = .command, tag: Int = 0, to t: AnyObject? = target) -> NSMenuItem {
            let i = NSMenuItem(title: title, action: action, keyEquivalent: key)
            i.keyEquivalentModifierMask = mods
            i.target = t
            i.tag = tag
            return i
        }

        func submenu(_ title: String, _ items: [NSMenuItem]) -> NSMenuItem {
            let m = NSMenu(title: title)
            items.forEach(m.addItem)
            let top = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            top.submenu = m
            main.addItem(top)
            return top
        }

        // App
        _ = submenu(appName, [
            item("About \(appName)", #selector(AppDelegate.showAbout(_:))),
            .separator(),
            item("Hide \(appName)", #selector(NSApplication.hide(_:)), "h", to: nil),
            item("Hide Others", #selector(NSApplication.hideOtherApplications(_:)), "h", [.command, .option], to: nil),
            item("Show All", #selector(NSApplication.unhideAllApplications(_:)), to: nil),
            .separator(),
            item("Quit \(appName)", #selector(NSApplication.terminate(_:)), "q", to: nil),
        ])

        // Shell
        _ = submenu("Shell", [
            item("New Tab", #selector(AppDelegate.newTab(_:)), "t"),
            item("New Window", #selector(AppDelegate.newWindow(_:)), "n"),
            .separator(),
            item("Import Tabs from Terminal.app…", #selector(AppDelegate.importFromTerminal(_:))),
            .separator(),
            item("Close Tab", #selector(AppDelegate.closeTab(_:)), "w"),
            item("Close Window", #selector(AppDelegate.closeWindow(_:)), "w", [.command, .shift]),
        ])

        // Edit: nil targets so the terminal view handles them via the responder chain.
        let findItem = { (title: String, key: String, tag: NSFindPanelAction, mods: NSEvent.ModifierFlags) in
            item(title, #selector(NSTextView.performFindPanelAction(_:)), key, mods, tag: Int(tag.rawValue), to: nil)
        }
        _ = submenu("Edit", [
            item("Copy", #selector(NSText.copy(_:)), "c", to: nil),
            item("Paste", #selector(NSText.paste(_:)), "v", to: nil),
            item("Select All", #selector(NSText.selectAll(_:)), "a", to: nil),
            .separator(),
            item("Clear to Start", #selector(AppDelegate.clearScrollback(_:)), "k"),
            .separator(),
            findItem("Find…", "f", .showFindPanel, .command),
            findItem("Find Next", "g", .next, .command),
            findItem("Find Previous", "g", .previous, [.command, .shift]),
        ])

        // View
        _ = submenu("View", [
            item("Bigger", #selector(AppDelegate.biggerFont(_:)), "+"),
            item("Bigger", #selector(AppDelegate.biggerFont(_:)), "=", .command).hiddenAlternate(),
            item("Smaller", #selector(AppDelegate.smallerFont(_:)), "-"),
            item("Default Size", #selector(AppDelegate.resetFont(_:)), "0"),
            .separator(),
            item("Show Sidebar", #selector(AppDelegate.toggleSidebar(_:)), "s", [.command, .control]),
            .separator(),
            item("Enter Full Screen", #selector(NSWindow.toggleFullScreen(_:)), "f", [.command, .control], to: nil),
        ])

        // Tab
        let left = String(UnicodeScalar(NSLeftArrowFunctionKey)!)
        let right = String(UnicodeScalar(NSRightArrowFunctionKey)!)
        var tabItems: [NSMenuItem] = [
            item("Rename Tab…", #selector(AppDelegate.renameTab(_:)), "i", [.command, .shift]),
            .separator(),
            item("Add Tab to New Group / Edit Group", #selector(AppDelegate.groupActiveTab(_:)), "g", [.command, .option]),
            item("Collapse or Expand Group", #selector(AppDelegate.toggleActiveGroup(_:)), "c", [.command, .option]),
            item("Remove Tab from Group", #selector(AppDelegate.removeActiveTabFromGroup(_:))),
            .separator(),
            item("Move Tab Left in Group", #selector(AppDelegate.shiftTabLeft(_:)), left, .control),
            item("Move Tab Right in Group", #selector(AppDelegate.shiftTabRight(_:)), right, .control),
            // ⌃←/⌃→ are taken by Mission Control ("Move left/right a space") by default.
            item("Move Tab Left in Group", #selector(AppDelegate.shiftTabLeft(_:)), left, [.control, .option]).hiddenAlternate(),
            item("Move Tab Right in Group", #selector(AppDelegate.shiftTabRight(_:)), right, [.control, .option]).hiddenAlternate(),
            item("Move Tab to New Window", #selector(AppDelegate.moveTabToNewWindow(_:))),
            .separator(),
            item("Show Next Tab", #selector(AppDelegate.selectNextTab(_:)), "]", [.command, .shift]),
            item("Show Previous Tab", #selector(AppDelegate.selectPreviousTab(_:)), "[", [.command, .shift]),
            item("Show Next Tab", #selector(AppDelegate.selectNextTab(_:)), "\t", .control).hiddenAlternate(),
            item("Show Previous Tab", #selector(AppDelegate.selectPreviousTab(_:)), "\t", [.control, .shift]).hiddenAlternate(),
            .separator(),
        ]
        for n in 1...9 {
            tabItems.append(item(n == 9 ? "Show Last Tab" : "Show Tab \(n)",
                                 #selector(AppDelegate.selectTabByNumber(_:)), "\(n)", tag: n))
        }
        _ = submenu("Tab", tabItems)

        // Window
        let window = submenu("Window", [
            item("Minimize", #selector(NSWindow.performMiniaturize(_:)), "m", to: nil),
            item("Zoom", #selector(NSWindow.performZoom(_:)), to: nil),
            .separator(),
            item("Bring All to Front", #selector(NSApplication.arrangeInFront(_:)), to: nil),
        ])
        NSApp.windowsMenu = window.submenu
        return main
    }
}

private extension NSMenuItem {
    /// Keeps the shortcut working without showing a duplicate menu row.
    func hiddenAlternate() -> NSMenuItem {
        isHidden = true
        allowsKeyEquivalentWhenHidden = true
        return self
    }
}
