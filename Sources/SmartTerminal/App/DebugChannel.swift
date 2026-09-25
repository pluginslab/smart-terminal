#if DEBUG
import AppKit
import SwiftUI
import UserNotifications
import SmartTerminalCore

/// Dev-only remote control, enabled with SMART_TERMINAL_DEBUG=1. Lets scripts
/// drive the app and snapshot windows without Screen Recording permission:
///
///   scripts/debug.sh snapshot /tmp/out.png
///   scripts/debug.sh newTab [end] | newTabInGroup | sidebar | restoreClip N | pasteClip N | group Name color | rename Title | collapse | select N
///   scripts/debug.sh type 'ls -la\n' | dump /tmp/layout.json | moveTabToNewWindow
@MainActor
final class DebugChannel {
    /// One channel per instance, so a test instance never receives commands meant for another.
    static var name: Notification.Name {
        let id = ProcessInfo.processInfo.environment["SMART_TERMINAL_DEBUG_ID"] ?? "dev"
        return Notification.Name("com.pluginslab.smartterminal.debug.\(id)")
    }
    private let model: AppModel
    private weak var app: AppDelegate?

    init?(model: AppModel, app: AppDelegate) {
        guard ProcessInfo.processInfo.environment["SMART_TERMINAL_DEBUG"] == "1" else { return nil }
        self.model = model
        self.app = app
        DistributedNotificationCenter.default().addObserver(
            forName: Self.name, object: nil, queue: .main
        ) { [weak self] note in
            let args = (note.object as? String ?? "").components(separatedBy: "\u{1F}")
            MainActor.assumeIsolated { self?.run(args) }
        }
        NSLog("SmartTerminal: debug channel enabled")
    }

    private var keyWindowID: UUID? {
        (NSApp.keyWindow as? TerminalWindow)?.windowID ?? model.layout.windows.last?.id
    }

    private var activeTab: TerminalTab? { keyWindowID.flatMap { model.window($0)?.activeTab } }

    private func run(_ args: [String]) {
        guard let cmd = args.first else { return }
        let a1 = args.count > 1 ? args[1] : ""
        let a2 = args.count > 2 ? args[2] : ""
        switch cmd {
        case "snapshot":
            snapshot(to: a1)
        case "newTab":
            if let w = keyWindowID { model.newTab(in: w, nextToActive: a1 != "end") }
        case "newTabInGroup":
            if let g = activeTab?.groupID { model.newTab(inGroup: g) }
        case "sidebar":
            if let w = keyWindowID { model.toggleSidebar(w) }
        case "restoreClip":
            // Puts history entry N back on the clipboard, as clicking the row does.
            if let i = Int(a1), model.clipboard.entries.indices.contains(i) {
                model.clipboard.restore(model.clipboard.entries[i])
            }
        case "pasteClip":
            // Pastes history entry N (0 = newest) into the active tab, as the row's context menu does.
            if let w = keyWindowID, let i = Int(a1), model.clipboard.entries.indices.contains(i),
               let text = model.clipboard.pasteText(for: model.clipboard.entries[i]) {
                model.paste(text, inWindow: w)
            }
        case "snapshotClaude":
            // Renders the Claude cards for a transcript (read only), in each status:
            // snapshotClaude <transcript.jsonl> <out-prefix>
            let url = URL(fileURLWithPath: a1), out = a2
            Task {
                let usage = await TranscriptScanner.shared.usage(of: url, upTo: .max)
                for status in [AgentStatus.busy, .waiting, .idle] {
                    var agent = AgentSnapshot(status: status, title: "Claude panel for the sidebar")
                    agent.usage = usage
                    agent.startedAt = Date().addingTimeInterval(-7_900)
                    if status == .waiting { agent.waitingFor = "permission prompt" }
                    let r = ImageRenderer(content: ClaudeSessionCards(agent: agent, title: "Claude panel for the sidebar", needsYou: false)
                        .padding(10).frame(width: 300).background(.background).environment(\.colorScheme, .dark))
                    r.scale = 2
                    if let img = r.nsImage, let tiff = img.tiffRepresentation,
                       let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
                        try? png.write(to: URL(fileURLWithPath: "\(out)-\(status.rawValue).png"))
                    }
                }
            }
        case "snapshotSidebar":
            // Renders the panel on its own, e.g. to check rows at a fixed size.
            guard let w = keyWindowID else { return }
            // ImageRenderer draws ScrollViews as placeholders, so rows go in a plain stack.
            let entries = model.clipboard.entries
            let panel = entries.isEmpty ? AnyView(SidebarView(windowID: w, model: model)) : AnyView(
                VStack(spacing: 6) {
                    ForEach(Array(entries.enumerated()), id: \.element.id) { i, e in
                        ClipRow(entry: e, isConfirmed: a2 == "confirm" && i == 1, isFlashing: i == 0,
                                copy: {}, paste: {}, delete: {})
                    }
                    Spacer()
                }.padding(10))
            let r = ImageRenderer(content: panel
                .frame(width: 280, height: 520).background(.background).environment(\.colorScheme, .dark))
            r.scale = 2
            if let img = r.nsImage, let tiff = img.tiffRepresentation,
               let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
                try? png.write(to: URL(fileURLWithPath: a1))
            }
        case "newWindow":
            model.newWindow()
        case "select":
            if let w = keyWindowID, let n = Int(a1) {
                model.update(w) { $0.selectNumber(n) }
                if let t = model.window(w)?.activeTabID { model.select(t) } // same path as a click
            }
        case "rename":
            if let t = activeTab { model.rename(tab: t.id, to: a1) }
        case "group":
            guard let t = activeTab else { return }
            model.createGroup(with: t.id)
            model.editingGroupID = nil
            if let g = keyWindowID.flatMap({ model.window($0)?.tab(t.id)?.groupID }) {
                model.updateGroup(g) { g in
                    g.name = a1
                    if let c = GroupColor(rawValue: a2) { g.color = c }
                }
            }
        case "joinPrevGroup":
            // Moves the active tab into the group of the tab left of it.
            guard let w = keyWindowID, let win = model.window(w), let t = win.activeTab,
                  let i = win.index(of: t.id), i > 0, let g = win.tabs[i - 1].groupID else { return }
            model.addTab(t.id, toGroup: g)
        case "collapse":
            if let g = activeTab?.groupID { model.toggleCollapsed(g) }
        case "editGroup":
            model.editingGroupID = activeTab?.groupID
        case "renaming":
            model.renamingTabID = activeTab?.id
        case "moveTabToNewWindow":
            if let t = activeTab { model.moveTabToNewWindow(t.id) }
        case "type":
            if let t = activeTab, let s = model.sessions.existing(t.id) {
                s.view.send(txt: a1.replacingOccurrences(of: "\\n", with: "\r"))
            }
        case "dump":
            let enc = JSONEncoder()
            enc.outputFormatting = [.prettyPrinted, .sortedKeys]
            try? enc.encode(model.layout).write(to: URL(fileURLWithPath: a1))
        case "probe":
            // Writes view/layer facts about the active terminal to a file.
            guard let t = activeTab, let v = model.sessions.existing(t.id)?.view else { return }
            var lines = ["frame=\(v.frame) superview=\(String(describing: v.superview)) window=\(v.window != nil)",
                         "wantsLayer=\(v.wantsLayer) layer=\(String(describing: v.layer))",
                         "layerBG=\(String(describing: v.layer?.backgroundColor))",
                         "nativeBG=\(v.nativeBackgroundColor) font=\(v.font)",
                         "shellTitle=\(model.sessions.existing(t.id)?.shellTitle ?? "nil") fg=\(model.sessions.existing(t.id)?.foregroundProcess ?? "nil") fgpid=\(ProcessInspector.foregroundGroup(ptyFD: v.process.childfd) ?? 0)",
                         "windowOpaque=\(v.window?.isOpaque ?? true) firstResponder=\(v.window?.firstResponder === v)"]
            var p: NSView? = v.superview
            while let x = p { lines.append("  ancestor \(type(of: x)) opaque=\(x.isOpaque) layerBG=\(String(describing: x.layer?.backgroundColor))"); p = x.superview }
            try? lines.joined(separator: "\n").write(toFile: a1, atomically: true, encoding: .utf8)
        case "shift":
            // Same path as the menu item (⌃←/⌃→).
            if Int(a1) == -1 { app?.shiftTabLeft(nil) } else { app?.shiftTabRight(nil) }
        case "key":
            // key <keyCode> <mods: c=ctrl o=opt s=shift m=cmd>. Goes through the real event queue.
            guard let code = UInt16(a1), let window = NSApp.orderedWindows.first(where: { $0 is TerminalWindow }) else { return }
            var flags: NSEvent.ModifierFlags = []
            if a2.contains("c") { flags.insert(.control) }
            if a2.contains("o") { flags.insert(.option) }
            if a2.contains("s") { flags.insert(.shift) }
            if a2.contains("m") { flags.insert(.command) }
            let arrows: [UInt16: Int] = [123: NSLeftArrowFunctionKey, 124: NSRightArrowFunctionKey,
                                         125: NSDownArrowFunctionKey, 126: NSUpArrowFunctionKey]
            if arrows[code] != nil { flags.formUnion([.function, .numericPad]) }
            let chars = arrows[code].map { String(UnicodeScalar($0)!) } ?? ""
            for type in [NSEvent.EventType.keyDown, .keyUp] {
                if let e = NSEvent.keyEvent(with: type, location: .zero, modifierFlags: flags, timestamp: ProcessInfo.processInfo.systemUptime,
                                            windowNumber: window.windowNumber, context: nil, characters: chars,
                                            charactersIgnoringModifiers: chars, isARepeat: false, keyCode: code) {
                    NSApp.postEvent(e, atStart: false)
                }
            }
        case "resize":
            if let w = Double(a1), let h = Double(a2), let win = NSApp.orderedWindows.first(where: { $0 is TerminalWindow }) {
                win.setContentSize(NSSize(width: w, height: h))
            }
        case "wintitle":
            // Appends the front window's title to a file (sample it repeatedly to see animation).
            let t = (NSApp.orderedWindows.first { $0 is TerminalWindow }?.title ?? "-") + "\n"
            if let h = FileHandle(forWritingAtPath: a1) { h.seekToEndOfFile(); h.write(Data(t.utf8)); try? h.close() }
            else { try? t.write(toFile: a1, atomically: true, encoding: .utf8) }
        case "resume":
            if let t = activeTab { model.resumeAgent(t.id) }
        case "state":
            // agents, attention and badge, as JSON lines
            var out = ["badge=\(NSApp.dockTile.badgeLabel ?? "-") attention=\(model.attention.count)"]
            let titles = Dictionary(model.layout.windows.flatMap(\.tabs).map { ($0.id, $0.displayTitle) }, uniquingKeysWith: { a, _ in a })
            out.append("activity dots: " + model.activity.compactMap { titles[$0] }.sorted().joined(separator: ", "))
            for (id, a) in model.agents {
                let title = model.layout.windows.lazy.compactMap { $0.tab(id) }.first?.displayTitle ?? "?"
                out.append("\(title): \(a.status.rawValue) waitingFor=\(a.waitingFor ?? "-") attention=\(model.attention.contains(id))")
            }
            let path = a1
            UNUserNotificationCenter.current().getNotificationSettings { settings in
                out.insert("notifications=\(settings.authorizationStatus.rawValue) (2=authorized, 1=denied, 0=not asked) alerts=\(settings.alertSetting.rawValue)", at: 0)
                try? out.joined(separator: "\n").write(toFile: path, atomically: true, encoding: .utf8)
            }
        case "importScan":
            // Dry run: what an import would do, without touching anything.
            let text: String
            do {
                let found = try TerminalAppImport.scan()
                text = TerminalImportPlan.groups(found).map { g in
                    "[\(g.name)]\n" + g.members.map { c in
                        "  \(c.tty) win=\(c.terminalWindowID) sel=\(c.selectedByDefault) title=\(c.tabTitle ?? "-") kind=\(c.kind)"
                    }.joined(separator: "\n")
                }.joined(separator: "\n")
            } catch { text = "error: \(error.localizedDescription)" }
            try? text.write(toFile: a1, atomically: true, encoding: .utf8)
        case "importTTYs":
            // Real import, restricted to the given ttys (comma-separated), for tests on throwaway windows.
            let ttys = Set(a1.split(separator: ",").map(String.init))
            if let w = keyWindowID, let found = try? TerminalAppImport.scan() {
                TerminalAppImport.perform(found.filter { ttys.contains($0.tty) }, into: w, model: model) { r in
                    DebugLog.write("import done tabs=\(r.tabs) handedOver=\(r.handedOver) tmux=\(r.tmux) failed=\(r.failed)")
                }
            }
        case "quit":
            NSApp.terminate(nil)
        default:
            NSLog("SmartTerminal debug: unknown command \(cmd)")
        }
    }

    /// Renders every window (frame view + content) to PNG via the layer tree, which
    /// composites translucent layers correctly. Behind-window blur is not captured.
    /// Multiple windows get -0, -1… suffixes.
    private func snapshot(to path: String) {
        let windows = NSApp.windows.compactMap { $0 as? TerminalWindow }.filter(\.isVisible)
        for (i, window) in windows.enumerated() {
            guard let view = window.contentView?.superview ?? window.contentView else { continue }
            view.wantsLayer = true
            guard let layer = view.layer else { continue }
            let scale = window.backingScaleFactor
            let size = view.bounds.size
            guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * scale),
                                             pixelsHigh: Int(size.height * scale), bitsPerSample: 8,
                                             samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                             colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
                  let ctx = NSGraphicsContext(bitmapImageRep: rep)?.cgContext else { continue }
            ctx.scaleBy(x: scale, y: scale)
            // Layer rendering drops SwiftTerm's background; paint it underneath.
            ctx.setFillColor(model.sessions.profile.background.withAlphaComponent(1).cgColor)
            ctx.fill(CGRect(origin: .zero, size: size))
            if !layer.isGeometryFlipped, view.isFlipped {
                ctx.translateBy(x: 0, y: size.height); ctx.scaleBy(x: 1, y: -1)
            }
            layer.render(in: ctx)
            // Layer rendering loses the terminal's content; draw it on top from cacheDisplay.
            if let term = model.window(window.windowID)?.activeTab.flatMap({ model.sessions.existing($0.id)?.view }),
               term.window === window, let trep = term.bitmapImageRepForCachingDisplay(in: term.bounds) {
                term.cacheDisplay(in: term.bounds, to: trep)
                let r = term.convert(term.bounds, to: view)
                let flippedY = view.isFlipped ? r.minY : r.minY
                let dst = CGRect(x: r.minX, y: flippedY, width: r.width, height: r.height)
                ctx.setFillColor(model.sessions.profile.background.withAlphaComponent(1).cgColor)
                ctx.fill(dst)
                if let cg = trep.cgImage { ctx.draw(cg, in: dst) }
            }
            let out = windows.count == 1 ? path : path.replacingOccurrences(of: ".png", with: "-\(i).png")
            try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: out))
        }
    }
}

#endif
