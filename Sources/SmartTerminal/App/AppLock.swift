import AppKit
import LocalAuthentication
import Observation

/// The app's lock: at launch and whenever the screen locks or the Mac sleeps, the
/// windows show the lock instead of the terminals until you unlock. Shells, tmux
/// and Claude keep running behind it; nothing of them is shown and no keystroke
/// reaches them.
///
/// Two ways in. A YubiKey you already use for SSH: `ssh-keygen -Y sign` signs a
/// fresh random challenge with one of `~/.ssh/id_*_sk*` (the key asks for a touch
/// unless it was made without), and `ssh-keygen -Y verify` checks the signature
/// against the key's `.pub`. Any of those keys will do, the first one plugged in.
/// Or Touch ID, with the login password as fallback.
///
/// Only the installed app locks (its bundle id), so dev and test builds don't,
/// unless SMART_TERMINAL_LOCK=1 (SMART_TERMINAL_LOCK_NOKEY=1 hides the keys, for tests). With no security key file and no Touch ID or
/// password policy available it doesn't lock at all, so it can never shut you out.
@MainActor @Observable
final class AppLock {
    static let shared = AppLock()

    private(set) var locked = false
    private(set) var busy = false
    var message: String?

    /// The signature's namespace, so it can't be passed off as a signature for anything else.
    nonisolated private static let namespace = "smart-terminal-unlock"

    let enabled: Bool
    let keys: [URL]

    private init() {
        let installed = Bundle.main.bundleIdentifier == "com.pluginslab.smartterminal"
        let forced = ProcessInfo.processInfo.environment["SMART_TERMINAL_LOCK"] == "1"
        keys = ProcessInfo.processInfo.environment["SMART_TERMINAL_LOCK_NOKEY"] == "1" ? [] : Self.securityKeys()
        enabled = (installed || forced) && (!keys.isEmpty || LAContext().canEvaluatePolicy(.deviceOwnerAuthentication, error: nil))
        locked = enabled
        guard enabled else { return }
        let lock: @Sendable (Notification) -> Void = { [weak self] _ in
            MainActor.assumeIsolated { self?.lock() }
        }
        DistributedNotificationCenter.default().addObserver(forName: .init("com.apple.screenIsLocked"),
                                                            object: nil, queue: .main, using: lock)
        let ws = NSWorkspace.shared.notificationCenter
        ws.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main, using: lock)
        ws.addObserver(forName: NSWorkspace.screensDidSleepNotification, object: nil, queue: .main, using: lock)
    }

    func lock() {
        guard enabled else { return }
        locked = true
        message = nil
    }

    var hasSecurityKey: Bool { !keys.isEmpty }

    /// `~/.ssh/id_*_sk*` with a `.pub` next to them: SSH keys that live on a FIDO key.
    /// The ones made without a touch come first: plugged in, they answer at once,
    /// and absent they fail at once. A key that needs a touch waits ~30 s for it,
    /// even when it isn't there, so it goes last.
    private static func securityKeys() -> [URL] {
        let ssh = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".ssh")
        let names = (try? FileManager.default.contentsOfDirectory(atPath: ssh.path)) ?? []
        return names.filter { $0.hasPrefix("id_") && $0.contains("_sk") && !$0.hasSuffix(".pub")
                              && names.contains($0 + ".pub") }
            .sorted { a, b in
                let ta = a.contains("notouch") || a.contains("auto"), tb = b.contains("notouch") || b.contains("auto")
                return ta == tb ? a < b : ta
            }
            .map { ssh.appendingPathComponent($0) }
    }

    // MARK: - YubiKey

    func unlockWithSecurityKey() {
        guard !busy, !keys.isEmpty else { return }
        busy = true
        message = "Touch your YubiKey if it blinks…"
        let keys = keys
        Shell.queue.async {
            let ok = keys.contains { Self.signAndVerify(with: $0) }
            DispatchQueue.main.async {
                self.busy = false
                if ok { self.locked = false; self.message = nil }
                else { self.message = "No YubiKey answered. Plug one in (and touch it), or use Touch ID." }
            }
        }
    }

    /// One fresh challenge, signed on the key and checked against its `.pub`.
    /// Blocks while the key waits for a touch (ssh-keygen gives up after ~30 s).
    nonisolated private static func signAndVerify(with key: URL) -> Bool {
        guard let keygen = ["/opt/homebrew/bin/ssh-keygen", "/usr/local/bin/ssh-keygen", "/usr/bin/ssh-keygen"]
                .first(where: { FileManager.default.isExecutableFile(atPath: $0) }),
              let pub = try? String(contentsOf: key.appendingPathExtension("pub"), encoding: .utf8) else { return false }
        let fields = pub.split(separator: " ")
        guard fields.count >= 2 else { return false }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("st-unlock-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: dir) }
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        let challenge = dir.appendingPathComponent("challenge")
        let allowed = dir.appendingPathComponent("allowed_signers")
        // Only this namespace is accepted. Whether the key asked for a touch is the
        // key's own business: one made with a touch won't sign without it.
        guard (try? Data(bytes).write(to: challenge)) != nil,
              (try? "smart-terminal namespaces=\"\(namespace)\" \(fields[0]) \(fields[1])\n"
                .write(to: allowed, atomically: true, encoding: .utf8)) != nil,
              Shell.run(keygen, ["-Y", "sign", "-f", key.path, "-n", namespace, challenge.path], timeout: 40) != nil
        else { return false }
        let q = { (s: String) in "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }
        let verify = "\(q(keygen)) -Y verify -f \(q(allowed.path)) -I smart-terminal -n \(namespace) -s \(q(challenge.path + ".sig")) < \(q(challenge.path))"
        return Shell.run("/bin/sh", ["-c", verify], timeout: 10) != nil
    }

    // MARK: - Touch ID / password

    func unlockWithBiometrics() {
        guard !busy else { return }
        busy = true
        message = nil
        LAContext().evaluatePolicy(.deviceOwnerAuthentication, localizedReason: "unlock Smart Terminal") { ok, error in
            DispatchQueue.main.async {
                self.busy = false
                if ok { self.locked = false }
                else if let e = error as? LAError, ![.userCancel, .appCancel, .systemCancel].contains(e.code) {
                    self.message = e.localizedDescription
                }
            }
        }
    }
}
