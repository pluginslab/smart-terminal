import SwiftUI

/// A window's content, with the lock laid over it while the app is locked.
struct LockGate: View {
    let windowID: UUID
    let model: AppModel
    @State private var lock = AppLock.shared

    var body: some View {
        // Laid over, not swapped in: rebuilding the window's columns after unlock
        // left them mis-sized. The terminals refuse keys and focus while locked.
        WindowContentView(windowID: windowID, model: model)
            .overlay {
                if lock.locked {
                    LockView(lock: lock).ignoresSafeArea().transition(.opacity)
                }
            }
            .animation(.easeOut(duration: 0.15), value: lock.locked)
    }
}

struct LockView: View {
    @Bindable var lock: AppLock
    private let amber = Color(red: 0xe8 / 255, green: 0xa3 / 255, blue: 0x3d / 255)

    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "lock.fill")
                .font(.system(size: 32, weight: .semibold))
                .foregroundStyle(amber)
            VStack(spacing: 6) {
                Text("Smart Terminal is locked").font(.title2.weight(.bold))
                Text(lock.hasSecurityKey ? "Touch your YubiKey, or use Touch ID." : "Use Touch ID or your password.")
                    .foregroundStyle(.secondary)
            }
            HStack(spacing: 10) {
                if lock.hasSecurityKey {
                    Button { lock.unlockWithSecurityKey() } label: {
                        Label("YubiKey", systemImage: "key.horizontal.fill").frame(minWidth: 110)
                            .foregroundStyle(Color(red: 0x1a / 255, green: 0x12 / 255, blue: 0x05 / 255))
                    }
                    .buttonStyle(.glassProminent)
                    .tint(amber)
                    .keyboardShortcut(.defaultAction)
                }
                Button { lock.unlockWithBiometrics() } label: {
                    Label("Touch ID", systemImage: "touchid").frame(minWidth: 110)
                        .foregroundStyle(.white)
                }
                .buttonStyle(.glass)
            }
            .controlSize(.large)
            .disabled(lock.busy)
            Text(lock.message ?? " ")
                .font(.callout).foregroundStyle(lock.busy ? Color.secondary : Color.orange)
                .multilineTextAlignment(.center).frame(maxWidth: 360)
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(red: 0x16 / 255, green: 0x28 / 255, blue: 0x3b / 255))
        .contentShape(Rectangle())   // swallows clicks meant for what's behind
        .environment(\.colorScheme, .dark)
        .task {
            // Ask the key at once, as a login would (the Nano answers without a touch).
            if lock.hasSecurityKey { lock.unlockWithSecurityKey() }
        }
    }
}
