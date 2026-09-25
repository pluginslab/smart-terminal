import AppKit
import SwiftUI
import SmartTerminalCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuItemValidation, WindowManaging {
    let model = AppModel()
    private var controllers: [UUID: WindowController] = [:]
    private(set) var isTerminating = false
    #if DEBUG
    private var debug: DebugChannel?
    #endif

    func applicationDidFinishLaunching(_ notification: Notification) {
        model.windows = self
        model.notifier = Notifier(model: model)
        NSApp.mainMenu = MainMenu.build(target: self)
        model.restoreOrCreate()
        #if DEBUG
        debug = DebugChannel(model: model, app: self)
        #endif
        NSApp.activate()
    }

    /// Coming back to the app counts as seeing the front tab of the key window.
    func applicationDidBecomeActive(_ notification: Notification) {
        if let t = activeTabID { model.clearIndicators(t, reason: "app activated") }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { model.newWindow() }
        return true
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let busy = model.layout.windows.flatMap(\.tabs).compactMap { model.sessions.runningCommand(of: $0.id) }
        guard Confirm.close(what: "all windows", runningCommands: busy, in: nil) else { return .terminateCancel }
        isTerminating = true
        model.saveNow()
        model.sessions.terminateAll()
        return .terminateNow
    }

    // MARK: - WindowManaging

    func openWindow(for windowID: UUID) {
        if let c = controllers[windowID] { c.showWindow(nil); return }
        let c = WindowController(windowID: windowID, model: model)
        controllers[windowID] = c
        c.showWindow(nil)
        c.window?.makeKeyAndOrderFront(nil)
    }

    func closeWindow(for windowID: UUID) {
        guard let c = controllers[windowID] else { return }
        c.closingProgrammatically = true
        c.close()
    }

    func focusWindow(for windowID: UUID) {
        controllers[windowID]?.window?.makeKeyAndOrderFront(nil)
    }

    func moveWindow(for windowID: UUID, to frame: WindowFrame) {
        controllers[windowID]?.window?.setFrame(
            NSRect(x: frame.x, y: frame.y, width: frame.width, height: frame.height), display: true, animate: true)
    }

    func controllerDidClose(_ controller: WindowController) {
        controllers[controller.windowID] = nil
    }

    // MARK: - Menu actions (target the key window's layout)

    private var keyWindowID: UUID? {
        (NSApp.keyWindow as? TerminalWindow)?.windowID
            ?? (NSApp.mainWindow as? TerminalWindow)?.windowID
            ?? NSApp.orderedWindows.lazy.compactMap { $0 as? TerminalWindow }.first?.windowID
    }

    private var activeTabID: UUID? { keyWindowID.flatMap { model.window($0)?.activeTabID } }

    @objc func newTab(_ sender: Any?) {
        if let id = keyWindowID { model.newTab(in: id) } else { model.newWindow() }
    }

    @objc func newWindow(_ sender: Any?) {
        let cwd = activeTabID.flatMap { model.sessions.currentDirectory(of: $0) }
        model.newWindow(cwd: cwd)
    }

    static let repoURL = URL(string: "https://github.com/pluginslab/smart-terminal")!

    @objc func showAbout(_ sender: Any?) {
        let info = Bundle.main.infoDictionary ?? [:]
        let credits = NSMutableAttributedString()
        let body: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.secondaryLabelColor,
        ]
        let center = NSMutableParagraphStyle()
        center.alignment = .center
        credits.append(NSAttributedString(string: "Terminal.app, plus Chrome-style tab groups and Claude Code awareness.\n\n", attributes: body))
        credits.append(NSAttributedString(string: "github.com/pluginslab/smart-terminal", attributes: [
            .font: NSFont.systemFont(ofSize: 11), .link: Self.repoURL,
        ]))
        credits.append(NSAttributedString(string: "\n\nTerminal emulation by SwiftTerm (MIT), © Miguel de Icaza.\nReleased under the MIT License.", attributes: body))
        credits.addAttribute(.paragraphStyle, value: center, range: NSRange(location: 0, length: credits.length))
        NSApp.orderFrontStandardAboutPanel(options: [
            .applicationName: "Smart Terminal",
            .applicationVersion: info["CFBundleShortVersionString"] as? String ?? "dev",
            .version: "Build " + (info["CFBundleVersion"] as? String ?? "dev"),
            .credits: credits,
        ])
        NSApp.activate()
    }

    @objc func importFromTerminal(_ sender: Any?) {
        let candidates: [ImportCandidate]
        do { candidates = try TerminalAppImport.scan() } catch {
            let alert = NSAlert(error: error)
            alert.runModal()
            return
        }
        guard !candidates.isEmpty else {
            let alert = NSAlert()
            alert.messageText = "No tabs found in Terminal.app."
            alert.runModal()
            return
        }
        let targetWindowID = keyWindowID ?? model.newWindow()
        guard let host = controllersWindow(targetWindowID) else { return }
        var sheetWindow: NSWindow?
        let view = ImportSheet(candidates: candidates, onImport: { [weak self] chosen in
            guard let self, let sheet = sheetWindow else { return }
            host.endSheet(sheet)
            TerminalAppImport.perform(chosen, into: targetWindowID, model: self.model) { report in
                guard !report.failed.isEmpty else { return }
                let alert = NSAlert()
                alert.messageText = "Imported \(report.tabs) tabs, with some problems"
                alert.informativeText = report.failed.joined(separator: "\n")
                alert.beginSheetModal(for: host)
            }
        }, onCancel: {
            if let sheet = sheetWindow { host.endSheet(sheet) }
        })
        let sheet = NSWindow(contentViewController: NSHostingController(rootView: view))
        sheetWindow = sheet
        host.beginSheet(sheet)
    }

    private func controllersWindow(_ id: UUID) -> NSWindow? {
        if controllers[id] == nil { openWindow(for: id) }
        return controllers[id]?.window
    }

    @objc func closeTab(_ sender: Any?) {
        if let t = activeTabID { model.requestCloseTab(t) } else { NSApp.keyWindow?.performClose(nil) }
    }

    @objc func closeWindow(_ sender: Any?) { NSApp.keyWindow?.performClose(nil) }

    @objc func renameTab(_ sender: Any?) { model.renamingTabID = activeTabID }

    @objc func groupActiveTab(_ sender: Any?) {
        guard let t = activeTabID, let wid = keyWindowID else { return }
        if let g = model.window(wid)?.tab(t)?.groupID {
            model.editingGroupID = g
        } else {
            model.createGroup(with: t)
        }
    }

    @objc func removeActiveTabFromGroup(_ sender: Any?) {
        if let t = activeTabID { model.removeFromGroup(t) }
    }

    @objc func toggleActiveGroup(_ sender: Any?) {
        guard let t = activeTabID, let wid = keyWindowID,
              let g = model.window(wid)?.tab(t)?.groupID else { return }
        model.toggleCollapsed(g)
    }

    @objc func shiftTabLeft(_ sender: Any?) { shiftActive(-1) }
    @objc func shiftTabRight(_ sender: Any?) { shiftActive(1) }

    private func shiftActive(_ direction: Int) {
        guard let wid = keyWindowID, let t = activeTabID else { return }
        var moved = false
        model.update(wid) { moved = $0.shift(tab: t, by: direction) }
        if !moved { NSSound.beep() } // at the group's edge
    }

    @objc func moveTabToNewWindow(_ sender: Any?) {
        if let t = activeTabID { model.moveTabToNewWindow(t) }
    }

    @objc func selectNextTab(_ sender: Any?) {
        if let id = keyWindowID { model.update(id) { $0.selectRelative(1) }; clearActive() }
    }

    @objc func selectPreviousTab(_ sender: Any?) {
        if let id = keyWindowID { model.update(id) { $0.selectRelative(-1) }; clearActive() }
    }

    @objc func selectTabByNumber(_ sender: NSMenuItem) {
        if let id = keyWindowID { model.update(id) { $0.selectNumber(sender.tag) }; clearActive() }
    }

    private func clearActive() {
        if let t = activeTabID { model.clearIndicators(t) }
    }

    @objc func biggerFont(_ sender: Any?) { model.sessions.setFontSize(model.sessions.fontSize + 1) }
    @objc func smallerFont(_ sender: Any?) { model.sessions.setFontSize(model.sessions.fontSize - 1) }
    @objc func resetFont(_ sender: Any?) { model.sessions.setFontSize(nil) }

    @objc func toggleSidebar(_ sender: Any?) {
        if let id = keyWindowID { model.toggleSidebar(id) }
    }

    @objc func clearScrollback(_ sender: Any?) {
        guard let t = activeTabID, let s = model.sessions.existing(t) else { return }
        s.view.getTerminal().resetToInitialState()
        s.view.send(txt: "\u{0C}") // ^L: let the shell redraw its prompt
    }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        let wid = keyWindowID
        let tab = activeTabID.flatMap { t in wid.flatMap { model.window($0)?.tab(t) } }
        switch item.action {
        case #selector(toggleSidebar(_:)):
            item.title = wid.map(model.isSidebarOpen) == true ? "Hide Sidebar" : "Show Sidebar"
            return wid != nil
        case #selector(closeTab(_:)), #selector(closeWindow(_:)):
            return NSApp.keyWindow != nil
        case #selector(renameTab(_:)), #selector(groupActiveTab(_:)), #selector(clearScrollback(_:)):
            return tab != nil
        case #selector(removeActiveTabFromGroup(_:)), #selector(toggleActiveGroup(_:)):
            return tab?.groupID != nil
        case #selector(shiftTabLeft(_:)), #selector(shiftTabRight(_:)):
            return tab != nil
        case #selector(moveTabToNewWindow(_:)):
            return (wid.flatMap { model.window($0)?.tabs.count } ?? 0) > 1
        case #selector(selectNextTab(_:)), #selector(selectPreviousTab(_:)), #selector(selectTabByNumber(_:)):
            return wid != nil
        default:
            return true
        }
    }
}
