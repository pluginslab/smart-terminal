import SwiftUI

@main
struct SmartTerminalPadApp: App {
    @State private var model = PadModel()
    @Environment(\.scenePhase) private var phase

    var body: some Scene {
        WindowGroup {
            RootView(model: model)
                .task {
                    // The simulator log shows the key, so it can be added to the host.
                    print("SMART_TERMINAL_PUBKEY \(DeviceKey.publicKeyLine)")
                    model.host.connect()
                    #if DEBUG
                    // `-select <session>` at launch opens that session (screenshots).
                    if let s = UserDefaults.standard.string(forKey: "select") { model.selected = s }
                    #endif
                }
        }
        .onChange(of: phase) { _, new in
            if new == .active { model.resume() }
        }
    }
}
