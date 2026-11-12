import SwiftUI

/// Covers the app until it is unlocked: the security key first when one is set
/// up (it asks for the key straight away), Touch ID or the passcode as the
/// other way in.
struct LockView: View {
    @Bindable var lock: AppLock

    var body: some View {
        ZStack {
            Theme.side.ignoresSafeArea()
            VStack(spacing: 22) {
                Image(systemName: "lock.fill")
                    .font(.system(size: 34, weight: .semibold))
                    .foregroundStyle(Theme.selection)
                VStack(spacing: 6) {
                    Text("Smart Terminal is locked").font(.title2.weight(.bold))
                    Text(lock.hasSecurityKey
                         ? "Plug in your YubiKey and touch it, or use \(lock.biometryName)."
                         : "Set up your YubiKey once, then it unlocks the app. \(lock.biometryName) works too.")
                        .font(.callout).foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 380)
                }
                VStack(spacing: 10) {
                    Button {
                        lock.hasSecurityKey ? lock.unlockWithSecurityKey() : lock.registerSecurityKey()
                    } label: {
                        Label(lock.hasSecurityKey ? "Unlock with YubiKey" : "Set Up YubiKey", systemImage: "key.horizontal.fill")
                            .font(.headline)
                            .foregroundStyle(Theme.onSelection)
                            .frame(width: 260, height: 48)
                    }
                    .buttonStyle(.plain)
                    .glassEffect(.regular.tint(Theme.selection).interactive(), in: .capsule)

                    Button { lock.unlockWithBiometrics() } label: {
                        Label("Use \(lock.biometryName)", systemImage: lock.biometryName == "Face ID" ? "faceid" : "touchid")
                            .font(.headline)
                            .frame(width: 260, height: 48)
                    }
                    .buttonStyle(.plain)
                    .glassEffect(.regular.interactive(), in: .capsule)
                }
                .disabled(lock.busy)
                if let m = lock.message {
                    Text(m).font(.footnote).foregroundStyle(.orange)
                        .multilineTextAlignment(.center).frame(maxWidth: 380)
                }
            }
            .padding(32)
        }
        .preferredColorScheme(.dark)
        .task {
            // Ask for the key at once, as a login prompt would.
            if lock.hasSecurityKey { lock.unlockWithSecurityKey() }
        }
    }
}
