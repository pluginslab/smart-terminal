import Foundation
import Crypto
import NIOCore
import NIOSSH
import Security

/// This iPad's own SSH key: an ed25519 key made on first launch and kept in the
/// keychain (this device only). Its public half goes into the host's authorized_keys.
enum DeviceKey {
    private static let service = "com.pluginslab.smartterminal.pad.sshkey"

    static let privateKey: Curve25519.Signing.PrivateKey = load() ?? create()

    /// "ssh-ed25519 AAAA… smart-terminal-ipad"
    static var publicKeyLine: String {
        let pub = NIOSSHPrivateKey(ed25519Key: privateKey).publicKey
        return String(openSSHPublicKey: pub) + " smart-terminal-ipad"
    }

    private static func load() -> Curve25519.Signing.PrivateKey? {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                kSecAttrService as String: service,
                                kSecReturnData as String: true]
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let data = out as? Data else { return nil }
        return try? Curve25519.Signing.PrivateKey(rawRepresentation: data)
    }

    private static func create() -> Curve25519.Signing.PrivateKey {
        let key = Curve25519.Signing.PrivateKey()
        let add: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                  kSecAttrService as String: service,
                                  kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
                                  kSecValueData as String: key.rawRepresentation]
        SecItemAdd(add as CFDictionary, nil)
        return key
    }
}

/// Trust on first use: the host's key is remembered the first time and must match after.
final class PinnedHostKey: NIOSSHClientServerAuthenticationDelegate, @unchecked Sendable {
    struct Mismatch: LocalizedError {
        var errorDescription: String? { "The host's key changed since the first connection. Not connecting." }
    }

    let host: String
    init(host: String) { self.host = host }

    private var defaultsKey: String { "hostKey.\(host)" }

    func validateHostKey(hostKey: NIOSSHPublicKey, validationCompletePromise: EventLoopPromise<Void>) {
        let seen = String(openSSHPublicKey: hostKey)
        if let pinned = UserDefaults.standard.string(forKey: defaultsKey) {
            pinned == seen ? validationCompletePromise.succeed(()) : validationCompletePromise.fail(Mismatch())
        } else {
            UserDefaults.standard.set(seen, forKey: defaultsKey)
            validationCompletePromise.succeed(())
        }
    }
}
