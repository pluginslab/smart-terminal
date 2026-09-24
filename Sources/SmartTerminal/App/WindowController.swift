import AppKit
import SwiftUI
import SmartTerminalCore

final class TerminalWindow: NSWindow {
    var windowID: UUID!
}

/// One per layout window. Keeps the NSWindow title and frame in sync with the model.
@MainActor
final class WindowController: NSWindowController, NSWindowDelegate {
    let windowID: UUID
    private let model: AppModel
    /// Set when the model closes the window (moved-out last tab); skips cleanup.
    var closingProgrammatically = false

    init(windowID: UUID, model: AppModel) {
        self.windowID = windowID
        self.model = model
        let frame = model.window(windowID)?.frame.map {
            NSRect(x: $0.x, y: $0.y, width: $0.width, height: $0.height)
        } ?? NSRect(x: 0, y: 0, width: 820, height: 520)

        let window = TerminalWindow(contentRect: frame,
                                    styleMask: [.titled, .closable, .miniaturizable, .resizable],
                                    backing: .buffered, defer: false)
        window.windowID = windowID
        window.tabbingMode = .disallowed // we draw our own tabs
        window.isReleasedWhenClosed = false
        if model.sessions.profile.isTranslucent {
            window.isOpaque = false
            window.backgroundColor = .clear
        }
        window.contentView = NSHostingView(rootView: WindowContentView(windowID: windowID, model: model))
        window.setFrame(frame, display: false)
        if model.window(windowID)?.frame == nil {
            // Cascade from the current key window instead of stacking exactly on top.
            if let key = NSApp.keyWindow {
                window.setFrameTopLeftPoint(key.cascadeTopLeft(from: NSPoint(x: key.frame.minX, y: key.frame.maxY)))
            } else {
                window.center()
            }
        }
        super.init(window: window)
        window.delegate = self
        observeTitle()
        storeFrame()
    }

    required init?(coder: NSCoder) { fatalError() }

    /// Re-registers on every change (withObservationTracking fires once).
    private func observeTitle() {
        withObservationTracking {
            updateTitle()
        } onChange: { [weak self] in
            DispatchQueue.main.async { self?.observeTitle() }
        }
    }

    private func updateTitle() {
        guard let w = model.window(windowID), let tab = w.activeTab else { return }
        let group = tab.groupID.flatMap { w.group($0) }
        // Terminal.app's layout: folder — program title (verbatim, so Claude Code's ✳ / ◐◓◑◒
        // animation plays here) — process ◂ command — cols×rows. Group and tab name go in front.
        let info = model.titleBars[tab.id]
        let folder = tab.cwd.map(TerminalSession.prettyFolder)
        let program = info?.programTitle?.trimmingCharacters(in: .whitespaces)
        var parts: [String?] = [group?.name, tab.customTitle]
        parts.append(folder)
        if let program, !program.isEmpty { parts.append(program) }
        else if tab.customTitle == nil, tab.autoTitle != folder { parts.append(tab.autoTitle) }
        parts.append(info?.command)
        if let info, info.cols > 0 { parts.append("\(info.cols)×\(info.rows)") }
        var seen = Set<String>()
        let title = parts.compactMap { $0 }.filter { !$0.isEmpty && seen.insert($0).inserted }.joined(separator: " — ")
        if window?.title != title { window?.title = title }
        if let cwd = tab.cwd, window?.representedURL?.path != cwd {
            window?.representedURL = URL(fileURLWithPath: cwd)
        }
    }

    private func storeFrame() {
        guard let f = window?.frame else { return }
        model.setFrame(WindowFrame(x: f.origin.x, y: f.origin.y, width: f.width, height: f.height), for: windowID)
    }

    // MARK: - NSWindowDelegate

    func windowDidMove(_ notification: Notification) { storeFrame() }
    func windowDidBecomeKey(_ notification: Notification) {
        if let t = model.window(windowID)?.activeTabID { model.clearIndicators(t, reason: "window key") }
    }
    func windowDidEndLiveResize(_ notification: Notification) { storeFrame() }
    func windowDidResize(_ notification: Notification) {
        if window?.inLiveResize == false { storeFrame() } // zoom, tiling, full screen
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        let busy = (model.window(windowID)?.tabs ?? []).compactMap { model.sessions.runningCommand(of: $0.id) }
        return Confirm.close(what: "this window", runningCommands: busy, in: sender)
    }

    func windowWillClose(_ notification: Notification) {
        if !closingProgrammatically, !(NSApp.delegate as? AppDelegate)!.isTerminating {
            model.windowClosedByUser(windowID)
        }
        (NSApp.delegate as? AppDelegate)?.controllerDidClose(self)
    }
}

enum Confirm {
    /// Asks before closing something that runs non-shell processes. Returns true to proceed.
    @MainActor
    static func close(what: String, runningCommands: [String], in window: NSWindow?) -> Bool {
        guard !runningCommands.isEmpty else { return true }
        let alert = NSAlert()
        alert.messageText = "Do you want to close \(what)?"
        let list = Array(Set(runningCommands)).sorted().joined(separator: ", ")
        alert.informativeText = "Closing will terminate the running processes: \(list)."
        alert.addButton(withTitle: "Close")
        alert.addButton(withTitle: "Cancel")
        alert.alertStyle = .warning
        return alert.runModal() == .alertFirstButtonReturn
    }
}
