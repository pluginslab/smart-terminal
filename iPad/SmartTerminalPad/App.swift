import SwiftUI

@main
struct SmartTerminalPadApp: App {
    @State private var model = PadModel()
    @State private var lock = AppLock()
    @Environment(\.scenePhase) private var phase

    var body: some Scene {
        WindowGroup {
            ZStack {
                RootView(model: model)
                if lock.locked { LockView(lock: lock).transition(.opacity) }
            }
            .animation(.easeOut(duration: 0.2), value: lock.locked)
            // Nothing connects until the first unlock.
            .onChange(of: lock.locked, initial: true) { _, locked in
                if !locked { model.host.connect() }
            }
                .task {
                    // The simulator log shows the key, so it can be added to the host.
                    print("SMART_TERMINAL_PUBKEY \(DeviceKey.publicKeyLine)")
                    #if DEBUG
                    // `-nolock YES` skips the lock, for screenshots and timed tests only.
                    if UserDefaults.standard.bool(forKey: "nolock") { lock.debugUnlock() }
                    SnapshotHook.start()
                    // `-select <session>` at launch opens that session (screenshots).
                    if let s = UserDefaults.standard.string(forKey: "select") { model.selected = s }
                    // `-dictate <start> -dictateSeconds <length>` records into the selected
                    // session on a timer, for testing where the simulator cannot be tapped.
                    let start = UserDefaults.standard.double(forKey: "dictate")
                    if start > 0 {
                        try? await Task.sleep(for: .seconds(start))
                        if let s = model.selected { model.dictate(s) }
                        try? await Task.sleep(for: .seconds(max(1, UserDefaults.standard.double(forKey: "dictateSeconds"))))
                        if let s = model.selected { model.dictate(s) }
                    }
                    #endif
                }
        }
        .onChange(of: phase) { _, new in
            switch new {
            case .background: lock.didEnterBackground()
            case .active:
                lock.didBecomeActive()
                if !lock.locked { model.resume() }
            default: break
            }
        }
    }
}
