import AppKit
import Observation
import SmartTerminalCore

/// Opens and closes real windows on behalf of the model.
@MainActor
protocol WindowManaging: AnyObject {
    func openWindow(for windowID: UUID)
    func closeWindow(for windowID: UUID)
    func focusWindow(for windowID: UUID)
    func moveWindow(for windowID: UUID, to frame: WindowFrame)
}

enum DragPayload: Equatable {
    case tab(UUID)
    case group(UUID)
}

/// Inputs for a Terminal.app-style window title.
struct TitleBarInfo: Equatable {
    /// Verbatim OSC 0/2 title, e.g. "◐ Fix drag bug" (animates with Claude's spinner).
    var programTitle: String?
    var command: String?
    var cols: Int
    var rows: Int
}

struct DropHint: Equatable {
    let windowID: UUID
    let target: DropTarget
}

/// Single source of truth for the UI. Every layout mutation goes through
/// `mutate`, which also schedules a debounced save.
@MainActor
@Observable
final class AppModel {
    private(set) var layout: AppLayout

    // Transient UI state (not persisted).
    var renamingTabID: UUID?
    var editingGroupID: UUID?
    var currentDrag: DragPayload?
    var dropHint: DropHint?
    /// What views draw: a hint only counts while a drag is actually in flight.
    var activeDropHint: DropHint? { currentDrag == nil ? nil : dropHint }
    /// Tabs that rang the bell while in the background.
    private(set) var attention: Set<UUID> = []
    /// Tabs that printed output while in the background.
    private(set) var activity: Set<UUID> = []
    /// Per tab: what Terminal.app would show in the title bar (not persisted).
    private(set) var titleBars: [UUID: TitleBarInfo] = [:]
    /// Claude Code sessions running in tabs.
    private(set) var agents: [UUID: AgentSnapshot] = [:]

    /// Per-window sidebar state; windows never toggled follow the last toggle anywhere.
    private var sidebarOpen: [UUID: Bool] = [:]
    private var sidebarDefault = UserDefaults.standard.bool(forKey: "sidebarOpen")

    @ObservationIgnored let sessions = SessionRegistry()
    @ObservationIgnored let clipboard = ClipboardHistory()
    @ObservationIgnored weak var windows: WindowManaging?
    @ObservationIgnored var notifier: Notifier?
    @ObservationIgnored private let store: LayoutStore
    @ObservationIgnored private var saveTask: Task<Void, Never>?

    init(store: LayoutStore = .default()) {
        self.store = store
        self.layout = store.load() ?? AppLayout()
        sessions.model = self
        clipboard.localSource = { [weak self] in
            guard let self, let wid = (NSApp.keyWindow as? TerminalWindow)?.windowID else { return nil }
            return self.window(wid)?.activeTab?.displayTitle
        }
        clipboard.start()
    }

    // MARK: - Sidebar

    func isSidebarOpen(_ windowID: UUID) -> Bool { sidebarOpen[windowID] ?? sidebarDefault }

    func setSidebar(_ windowID: UUID, open: Bool) {
        sidebarOpen[windowID] = open
        sidebarDefault = open
        UserDefaults.standard.set(open, forKey: "sidebarOpen")
    }

    func toggleSidebar(_ windowID: UUID) { setSidebar(windowID, open: !isSidebarOpen(windowID)) }

    /// Types `text` into the window's active tab as a paste (bracketed when the
    /// program asked for it, so shells and Claude Code don't run it line by line).
    func paste(_ text: String, inWindow windowID: UUID) {
        guard let t = window(windowID)?.activeTabID, let s = sessions.existing(t) else { return }
        let bracketed = s.view.getTerminal().bracketedPasteMode
        if bracketed { s.view.send(txt: "\u{1b}[200~") }
        s.view.send(txt: text)
        if bracketed { s.view.send(txt: "\u{1b}[201~") }
        s.view.window?.makeFirstResponder(s.view)
    }

    // MARK: - Lookup

    func window(_ id: UUID) -> WindowLayout? { layout.window(id) }

    func windowID(containingTab tabID: UUID) -> UUID? { layout.windowID(containingTab: tabID) }

    // MARK: - Mutation plumbing

    private func mutate(_ change: (inout AppLayout) -> Void) {
        change(&layout)
        scheduleSave()
    }

    func update(_ windowID: UUID, _ change: (inout WindowLayout) -> Void) {
        mutate { $0.update(windowID, change) }
    }

    func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
            self?.saveNow()
        }
    }

    func saveNow() {
        saveTask?.cancel()
        do { try store.save(layout) } catch { NSLog("SmartTerminal: save failed: \(error)") }
    }

    // MARK: - Windows

    /// Makes sure there is at least one window with one tab; opens all windows.
    func restoreOrCreate() {
        if layout.windows.isEmpty { _ = newWindow(open: false) }
        for w in layout.windows { windows?.openWindow(for: w.id) }
    }

    @discardableResult
    func newWindow(cwd: String? = nil, frame: WindowFrame? = nil, open: Bool = true) -> UUID {
        var w = WindowLayout(frame: frame)
        w.addTab(TerminalTab(cwd: cwd ?? TerminalSession.homeDirectory))
        mutate { $0.windows.append(w) }
        if open { windows?.openWindow(for: w.id) }
        return w.id
    }

    /// The user closed a window: kill its sessions and forget it.
    func windowClosedByUser(_ windowID: UUID) {
        guard let w = window(windowID) else { return }
        w.tabs.forEach { sessions.terminate($0.id) }
        mutate { $0.removeWindow(windowID) }
    }

    func setFrame(_ frame: WindowFrame, for windowID: UUID) {
        guard window(windowID)?.frame != frame else { return }
        update(windowID) { $0.frame = frame }
    }

    private func closeIfEmptied(_ emptied: UUID?) {
        guard let emptied else { return }
        mutate { $0.removeWindow(emptied) }
        windows?.closeWindow(for: emptied)
    }

    // MARK: - Tabs

    func newTab(in windowID: UUID, nextToActive: Bool = true) {
        let cwd = window(windowID)?.activeTab.flatMap { sessions.currentDirectory(of: $0.id) ?? $0.cwd }
        update(windowID) { $0.addTab(TerminalTab(cwd: cwd ?? TerminalSession.homeDirectory), nextToActive: nextToActive) }
    }

    /// New tab at the end of a group, starting in the folder of the group's last tab.
    func newTab(inGroup groupID: UUID) {
        guard let wid = layout.windowID(containingGroup: groupID) else { return }
        let cwd = window(wid)?.tabs(in: groupID).last.flatMap { sessions.currentDirectory(of: $0.id) ?? $0.cwd }
        update(wid) { $0.insert(TerminalTab(cwd: cwd ?? TerminalSession.homeDirectory), at: .intoGroup(groupID)) }
    }

    func select(_ tabID: UUID) {
        guard let wid = windowID(containingTab: tabID) else { return }
        update(wid) { $0.select(tabID) }
        clearIndicators(tabID)
    }

    func closeTab(_ tabID: UUID) {
        guard let wid = windowID(containingTab: tabID) else { return }
        sessions.terminate(tabID)
        clearIndicators(tabID)
        agents[tabID] = nil
        titleBars[tabID] = nil
        update(wid) { $0.removeTab(tabID) }
        if window(wid)?.isEmpty == true { closeIfEmptied(wid) }
    }

    /// User-initiated close: asks first when a command (vim, ssh…) is running.
    func requestCloseTab(_ tabID: UUID) {
        let busy = sessions.runningCommand(of: tabID).map { [$0] } ?? []
        guard Confirm.close(what: "this tab", runningCommands: busy, in: NSApp.keyWindow) else { return }
        closeTab(tabID)
    }

    func closeOtherTabs(keeping tabID: UUID) {
        guard let wid = windowID(containingTab: tabID), let w = window(wid) else { return }
        let others = w.tabs.filter { $0.id != tabID }
        let busy = others.compactMap { sessions.runningCommand(of: $0.id) }
        guard Confirm.close(what: "the other tabs", runningCommands: busy, in: NSApp.keyWindow) else { return }
        others.forEach { closeTab($0.id) }
    }

    func rename(tab tabID: UUID, to title: String?) {
        guard let wid = windowID(containingTab: tabID) else { return }
        update(wid) { $0.rename(tab: tabID, to: title) }
    }

    /// Called by sessions when the shell reports a title or cwd.
    func sessionUpdated(tabID: UUID, autoTitle: String?, cwd: String?) {
        guard let wid = windowID(containingTab: tabID), let t = window(wid)?.tab(tabID) else { return }
        let newTitle = autoTitle ?? t.autoTitle
        let newCwd = cwd ?? t.cwd
        guard newTitle != t.autoTitle || newCwd != t.cwd else { return }
        update(wid) { $0.updateTab(tabID) { $0.autoTitle = newTitle; $0.cwd = newCwd } }
    }

    func moveTabToNewWindow(_ tabID: UUID) {
        guard let wid = windowID(containingTab: tabID) else { return }
        if window(wid)?.tabs.count == 1 { return }
        var result: (newWindow: UUID, emptied: UUID?)?
        let frame = cascadedFrame(from: wid) // read before mutate: no access to layout while it is inout
        mutate { result = $0.detachTab(tabID, frame: frame) }
        if let result { windows?.openWindow(for: result.newWindow); closeIfEmptied(result.emptied) }
    }

    // MARK: - Groups

    func createGroup(with tabID: UUID) {
        guard let wid = windowID(containingTab: tabID) else { return }
        var group: TabGroup?
        update(wid) { group = $0.createGroup(with: tabID) }
        editingGroupID = group?.id // open the editor so it can be named right away
    }

    func addTab(_ tabID: UUID, toGroup groupID: UUID) {
        guard let wid = layout.windowID(containingGroup: groupID) else { return }
        closeIfEmptied(mutateReturning { $0.moveTab(tabID, toWindow: wid, at: .intoGroup(groupID)) })
    }

    func removeFromGroup(_ tabID: UUID) {
        guard let wid = windowID(containingTab: tabID) else { return }
        update(wid) { $0.removeFromGroup(tab: tabID) }
    }

    func updateGroup(_ groupID: UUID, _ change: (inout TabGroup) -> Void) {
        guard let wid = layout.windowID(containingGroup: groupID) else { return }
        update(wid) { $0.updateGroup(groupID, change) }
    }

    func toggleCollapsed(_ groupID: UUID) {
        guard let wid = layout.windowID(containingGroup: groupID) else { return }
        update(wid) { $0.toggleCollapsed(groupID) }
    }

    func ungroup(_ groupID: UUID) {
        guard let wid = layout.windowID(containingGroup: groupID) else { return }
        update(wid) { $0.ungroup(groupID) }
    }

    func closeGroup(_ groupID: UUID) {
        guard let wid = layout.windowID(containingGroup: groupID), let w = window(wid) else { return }
        let members = w.tabs(in: groupID)
        let busy = members.compactMap { sessions.runningCommand(of: $0.id) }
        guard Confirm.close(what: "this group", runningCommands: busy, in: NSApp.keyWindow) else { return }
        members.forEach { closeTab($0.id) }
    }

    func moveGroupToNewWindow(_ groupID: UUID) {
        guard let wid = layout.windowID(containingGroup: groupID), let w = window(wid) else { return }
        if w.tabs.allSatisfy({ $0.groupID == groupID }) { return } // already alone
        var result: (newWindow: UUID, emptied: UUID?)?
        let frame = cascadedFrame(from: wid)
        mutate { result = $0.detachGroup(groupID, frame: frame) }
        if let result { windows?.openWindow(for: result.newWindow); closeIfEmptied(result.emptied) }
    }

    // MARK: - Drag and drop

    @ObservationIgnored private var dragWatcher: Timer?

    /// Called from onDrag. SwiftUI has no drag-ended callback, so we watch the
    /// mouse button: released with no accepted drop means cancelled, or, when
    /// the pointer is outside every window of ours, a tear-off.
    func beginDrag(_ payload: DragPayload) {
        currentDrag = payload
        dragWatcher?.invalidate()
        dragWatcher = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard NSEvent.pressedMouseButtons & 1 == 0 else { return }
                self?.dragWatcher?.invalidate()
                self?.dragWatcher = nil
                // Give performDrop (which clears currentDrag) a moment to run first.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { self?.dragEnded(at: NSEvent.mouseLocation) }
            }
        }
    }

    private func dragEnded(at point: NSPoint) {
        dropHint = nil
        guard let payload = currentDrag else { return } // a drop target handled it
        currentDrag = nil
        let overOurWindow = NSApp.windows.contains { $0.isVisible && $0.frame.contains(point) }
        guard !overOurWindow else { return }
        tearOff(payload, at: point)
    }

    /// Chrome-style: the dragged tab/group becomes a new window under the pointer.
    /// Dragging a window's only content just moves that window.
    func tearOff(_ payload: DragPayload, at point: NSPoint) {
        let sourceID: UUID?
        switch payload {
        case .tab(let id): sourceID = windowID(containingTab: id)
        case .group(let id): sourceID = layout.windowID(containingGroup: id)
        }
        guard let sourceID, let source = window(sourceID) else { return }
        let size = source.frame.map { CGSize(width: $0.width, height: $0.height) } ?? CGSize(width: 820, height: 520)
        let frame = WindowFrame(x: point.x - 80, y: point.y - size.height + 30, width: size.width, height: size.height)

        let movesEverything: Bool
        switch payload {
        case .tab: movesEverything = source.tabs.count == 1
        case .group(let g): movesEverything = source.tabs.allSatisfy { $0.groupID == g }
        }
        if movesEverything {
            update(sourceID) { $0.frame = frame }
            windows?.moveWindow(for: sourceID, to: frame)
            return
        }
        var result: (newWindow: UUID, emptied: UUID?)?
        switch payload {
        case .tab(let id): mutate { result = $0.detachTab(id, frame: frame) }
        case .group(let id): mutate { result = $0.detachGroup(id, frame: frame) }
        }
        if let result { windows?.openWindow(for: result.newWindow); closeIfEmptied(result.emptied) }
    }

    func performDrop(_ payload: DragPayload, into windowID: UUID, at target: DropTarget) {
        dropHint = nil
        currentDrag = nil
        switch payload {
        case .tab(let id):
            closeIfEmptied(mutateReturning { $0.moveTab(id, toWindow: windowID, at: target) })
        case .group(let id):
            closeIfEmptied(mutateReturning { $0.moveGroup(id, toWindow: windowID, at: target) })
        }
        windows?.focusWindow(for: windowID)
    }

    private func mutateReturning<T>(_ change: (inout AppLayout) -> T) -> T {
        let result = change(&layout)
        scheduleSave()
        return result
    }

    // MARK: - Indicators

    func titleBarChanged(tabID: UUID, info: TitleBarInfo) {
        if titleBars[tabID] != info { titleBars[tabID] = info }
    }

    func agentUpdated(tabID: UUID, agent: AgentSnapshot?, ref: AgentSessionRef?) {
        let previous = agents[tabID]
        if previous != agent {
            if previous?.status != agent?.status {
                DebugLog.write("agent \(tabID.uuidString.prefix(4)) \(previous?.status.rawValue ?? "nil") -> \(agent?.status.rawValue ?? "nil") visible=\(isVisibleToUser(tabID)) active=\(NSApp.isActive)")
            }
            agents[tabID] = agent
            if let agent, previous?.status != agent.status { agentStatusChanged(tabID, from: previous?.status, to: agent) }
        }
        guard let wid = windowID(containingTab: tabID), let tab = window(wid)?.tab(tabID) else { return }
        if let ref, tab.agentSession != ref {
            update(wid) { $0.updateTab(tabID) { $0.agentSession = ref } }
        } else if agent == nil, previous != nil, tab.agentSession != nil {
            // Claude exited while we watched (/exit, ^C): nothing left to resume.
            // A quit or crash never gets here, so the reference survives for the next launch.
            update(wid) { $0.updateTab(tabID) { $0.agentSession = nil } }
        }
    }

    /// Claude finished a turn, or hit a permission prompt/question, while you could not see it.
    private func agentStatusChanged(_ tabID: UUID, from old: AgentStatus?, to agent: AgentSnapshot) {
        let finished = old == .busy && agent.status == .idle
        let needsInput = agent.status == .waiting
        guard finished || needsInput, !isVisibleToUser(tabID),
              let wid = windowID(containingTab: tabID), let w = window(wid), let tab = w.tab(tabID) else { return }
        markAttention(tabID, force: true)
        let group = tab.groupID.flatMap { w.group($0)?.name }
        notifier?.post(needsInput ? .needsInput : .finished, tabID: tabID, title: tab.displayTitle, group: group,
                       detail: needsInput ? (agent.waitingFor.map { "Waiting: \($0)" } ?? agent.lastPrompt) : agent.lastPrompt)
    }

    /// The tab is on screen in front of you: app active, its window key, and it is the active tab.
    func isVisibleToUser(_ tabID: UUID) -> Bool {
        guard NSApp.isActive, let wid = windowID(containingTab: tabID),
              window(wid)?.activeTabID == tabID else { return false }
        return (NSApp.keyWindow as? TerminalWindow)?.windowID == wid
    }

    /// Brings a tab to the front (notification click).
    func reveal(tabID: UUID) {
        guard let wid = windowID(containingTab: tabID) else { return }
        DebugLog.write("notification click \(tabID.uuidString.prefix(4))")
        select(tabID)
        windows?.focusWindow(for: wid)
        NSApp.activate()
    }

    // MARK: - Resume

    /// Tabs where a resume was just typed; hides the offer until Claude shows up.
    private(set) var resumeLaunched: Set<UUID> = []

    /// A Claude session that ran in this tab before the app restarted.
    func resumableSession(_ tabID: UUID) -> AgentSessionRef? {
        guard agents[tabID] == nil, !resumeLaunched.contains(tabID),
              let wid = windowID(containingTab: tabID) else { return nil }
        return window(wid)?.tab(tabID)?.agentSession
    }

    func resumeAgent(_ tabID: UUID) {
        guard let ref = resumableSession(tabID), let wid = windowID(containingTab: tabID),
              let tab = window(wid)?.tab(tabID) else { return }
        resumeLaunched.insert(tabID)
        let session = sessions.session(for: tabID, cwd: tab.cwd)
        session.view.send(txt: ref.resumeCommand + "\r") // the shell buffers it until its prompt is up
    }

    func dismissResume(_ tabID: UUID) {
        guard let wid = windowID(containingTab: tabID) else { return }
        update(wid) { $0.updateTab(tabID) { $0.agentSession = nil } }
    }

    func markAttention(_ tabID: UUID, force: Bool = false) {
        guard force || !isFrontmost(tabID), !attention.contains(tabID) else { return }
        attention.insert(tabID)
        updateBadge()
        NSApp.requestUserAttention(.informationalRequest)
    }

    func markActivity(_ tabID: UUID) {
        // Claude's spinner redraws constantly; its status glyph already says "working".
        guard agents[tabID] == nil, !isFrontmost(tabID), !activity.contains(tabID) else { return }
        activity.insert(tabID)
    }

    func clearIndicators(_ tabID: UUID, reason: String = "select") {
        if attention.contains(tabID) {
            attention.remove(tabID); updateBadge()
            DebugLog.write("clear attention \(tabID.uuidString.prefix(4)) (\(reason))")
        }
        if activity.contains(tabID) { activity.remove(tabID) }
        notifier?.clear(tabID: tabID)
    }

    /// Dock badge: how many tabs are waiting for you.
    private func updateBadge() {
        notifier?.setBadge(attention.count)
    }

    /// The tab is the active tab of its window (what the user is looking at).
    private func isFrontmost(_ tabID: UUID) -> Bool {
        guard let wid = windowID(containingTab: tabID) else { return false }
        return window(wid)?.activeTabID == tabID
    }

    // MARK: - Helpers

    private func cascadedFrame(from windowID: UUID) -> WindowFrame? {
        guard var f = window(windowID)?.frame else { return nil }
        f.x += 28; f.y -= 28
        return f
    }
}

/// Appends to $SMART_TERMINAL_SUPPORT_DIR/debug.log when SMART_TERMINAL_DEBUG=1.
enum DebugLog {
    static func write(_ line: String) {
        let env = ProcessInfo.processInfo.environment
        guard env["SMART_TERMINAL_DEBUG"] == "1", let dir = env["SMART_TERMINAL_SUPPORT_DIR"] else { return }
        let path = dir + "/debug.log"
        let stamp = String(format: "%.2f", Date().timeIntervalSince1970.truncatingRemainder(dividingBy: 1000))
        let data = Data("\(stamp) \(line)\n".utf8)
        if let h = FileHandle(forWritingAtPath: path) { h.seekToEndOfFile(); h.write(data); try? h.close() }
        else { FileManager.default.createFile(atPath: path, contents: data) }
    }
}
