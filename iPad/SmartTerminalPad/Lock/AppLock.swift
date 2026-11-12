import AuthenticationServices
import CryptoKit
import Foundation
import LocalAuthentication
import Observation
import UIKit
import os

/// The app's lock: nothing (not even the SSH connection) starts until you unlock,
/// at launch and again after more than two minutes away.
///
/// Two ways in. A security key (YubiKey) through Apple's passkey API, which reaches
/// it over USB-C on an iPad (iPads have no NFC) and over NFC on an iPhone: set up
/// once, after which the key's public key is kept here and each unlock checks the
/// key's signature over a fresh challenge, on the device, no server. Or Touch ID
/// (Face ID), with the device passcode as fallback.
///
/// The passkey API only works for a web domain tied to the app: pluginslab.com
/// serves `/.well-known/apple-app-site-association` naming this app under
/// `webcredentials`, and the app has the matching associated-domains entitlement.
@MainActor @Observable
final class AppLock: NSObject {
    static let relyingParty = "pluginslab.com"
    nonisolated static let log = Logger(subsystem: "com.pluginslab.smartterminal.pad", category: "lock")
    /// Away longer than this locks again.
    static let graceSeconds: TimeInterval = 120

    /// The lock is for the iPad. Not in the simulator (no security key, no Touch ID
    /// worth the name) and not on an iPhone for now (that comes with the iPhone work).
    static var isRequired: Bool {
        #if targetEnvironment(simulator)
        false
        #else
        UIDevice.current.userInterfaceIdiom == .pad
        #endif
    }

    private(set) var locked = AppLock.isRequired
    private(set) var busy = false
    var message: String?
    private var backgroundedAt: Date?

    /// The registered key: credential ID and P-256 public key (x963), not secrets.
    private struct Registration: Codable { var credentialID: Data; var publicKey: Data }
    private static let registrationKey = "lock.securityKey"
    private var registration: Registration? {
        didSet { UserDefaults.standard.set(try? JSONEncoder().encode(registration), forKey: Self.registrationKey) }
    }
    var hasSecurityKey: Bool { registration != nil }

    private var challenge = Data()
    private var controller: ASAuthorizationController?

    override init() {
        super.init()
        if let d = UserDefaults.standard.data(forKey: Self.registrationKey) {
            registration = try? JSONDecoder().decode(Registration.self, from: d)
        }
    }

    // MARK: - Background

    func didEnterBackground() { backgroundedAt = .now }

    func didBecomeActive() {
        if Self.isRequired, let t = backgroundedAt, Date.now.timeIntervalSince(t) > Self.graceSeconds { locked = true }
        backgroundedAt = nil
    }

    // MARK: - Touch ID / passcode

    var biometryName: String {
        let ctx = LAContext()
        _ = ctx.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: nil)
        return switch ctx.biometryType {
        case .faceID: "Face ID"
        case .touchID: "Touch ID"
        case .opticID: "Optic ID"
        default: "Passcode"
        }
    }

    func unlockWithBiometrics() {
        guard !busy else { return }
        busy = true
        message = nil
        let ctx = LAContext()
        ctx.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: "Unlock Smart Terminal") { ok, error in
            Task { @MainActor in
                self.busy = false
                if ok { self.locked = false }
                else if let e = error as? LAError, e.code != .userCancel, e.code != .appCancel, e.code != .systemCancel {
                    self.message = e.localizedDescription
                }
            }
        }
    }

    // MARK: - Security key

    private var provider: ASAuthorizationSecurityKeyPublicKeyCredentialProvider {
        ASAuthorizationSecurityKeyPublicKeyCredentialProvider(relyingPartyIdentifier: Self.relyingParty)
    }

    /// One-time: makes a credential on the key and keeps its public key.
    func registerSecurityKey() {
        guard !busy else { return }
        challenge = Self.random(32)
        let request = provider.createCredentialRegistrationRequest(
            challenge: challenge, displayName: "Smart Terminal on \(UIDevice.current.name)",
            name: "smart-terminal", userID: Self.random(16))
        request.credentialParameters = [ASAuthorizationPublicKeyCredentialParameters(algorithm: .ES256)]
        request.attestationPreference = .none
        request.residentKeyPreference = .discouraged
        request.userVerificationPreference = .discouraged
        perform(request)
    }

    /// Asks the registered key to sign a fresh challenge.
    func unlockWithSecurityKey() {
        guard !busy, let registration else { return }
        challenge = Self.random(32)
        let request = provider.createCredentialAssertionRequest(challenge: challenge)
        request.allowedCredentials = [ASAuthorizationSecurityKeyPublicKeyCredentialDescriptor(
            credentialID: registration.credentialID, transports: ASAuthorizationSecurityKeyPublicKeyCredentialDescriptor.Transport.allSupported)]
        request.userVerificationPreference = .discouraged
        perform(request)
    }

    func forgetSecurityKey() { registration = nil }

    #if DEBUG
    func debugUnlock() { locked = false }
    #endif

    private func perform(_ request: ASAuthorizationRequest) {
        busy = true
        message = nil
        let c = ASAuthorizationController(authorizationRequests: [request])
        c.delegate = self
        c.presentationContextProvider = self
        controller = c
        c.performRequests()
    }

    private func finish(_ error: String?) {
        if let error { print("LOCK error: \(error)") }
        busy = false
        controller = nil
        message = error
    }

    static func random(_ n: Int) -> Data {
        var b = [UInt8](repeating: 0, count: n)
        _ = SecRandomCopyBytes(kSecRandomDefault, n, &b)
        return Data(b)
    }
}

extension AppLock: ASAuthorizationControllerDelegate, ASAuthorizationControllerPresentationContextProviding {
    nonisolated func presentationAnchor(for controller: ASAuthorizationController) -> ASPresentationAnchor {
        MainActor.assumeIsolated {
            let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            if let window = scenes.compactMap(\.keyWindow).first { return window }
            // No key window yet (the lock asks at launch): a window on the app's scene.
            return ASPresentationAnchor(windowScene: scenes[0])
        }
    }

    nonisolated func authorizationController(controller: ASAuthorizationController, didCompleteWithAuthorization auth: ASAuthorization) {
        MainActor.assumeIsolated {
            if let reg = auth.credential as? ASAuthorizationSecurityKeyPublicKeyCredentialRegistration {
                let att = reg.rawAttestationObject
                guard let attestation = att else { return finish("The key sent no attestation.") }
                guard let key = WebAuthn.publicKey(fromAttestation: attestation) else {
                    return finish("Couldn't read the key's public key.")
                }
                guard WebAuthn.clientDataMatches(reg.rawClientDataJSON, challenge: challenge, type: "webauthn.create") else {
                    return finish("The key answered a different challenge.")
                }
                registration = Registration(credentialID: reg.credentialID, publicKey: key.x963Representation)
                locked = false
                finish(nil)
            } else if let assertion = auth.credential as? ASAuthorizationSecurityKeyPublicKeyCredentialAssertion {
                guard let registration, assertion.credentialID == registration.credentialID,
                      let key = try? P256.Signing.PublicKey(x963Representation: registration.publicKey),
                      WebAuthn.clientDataMatches(assertion.rawClientDataJSON, challenge: challenge, type: "webauthn.get"),
                      WebAuthn.verify(assertion: assertion, with: key)
                else { return finish("That key's signature didn't check out.") }
                locked = false
                finish(nil)
            } else {
                finish("Unexpected answer from the key.")
            }
        }
    }

    nonisolated func authorizationController(controller: ASAuthorizationController, didCompleteWithError error: Error) {
        MainActor.assumeIsolated {
            if let e = error as? ASAuthorizationError, e.code == .canceled { return finish(nil) }
            finish(error.localizedDescription)
        }
    }
}

/// The few WebAuthn pieces the lock needs, checked on the device.
enum WebAuthn {
    /// The credential's P-256 key from a "none" attestation object: the authData's
    /// attested credential data ends in a COSE EC2 key whose x (-2) and y (-3) are
    /// 32-byte strings.
    static func publicKey(fromAttestation obj: Data) -> P256.Signing.PublicKey? {
        let b = [UInt8](obj)
        func find(_ label: UInt8) -> [UInt8]? {
            // map key (-2 = 0x21, -3 = 0x22), then bstr of 32 bytes (0x58 0x20)
            guard b.count >= 35 else { return nil }  // y ends the object, so its start can be count - 35
            for i in 0...(b.count - 35) where b[i] == label && b[i + 1] == 0x58 && b[i + 2] == 0x20 {
                return Array(b[(i + 3)..<(i + 35)])
            }
            return nil
        }
        guard let x = find(0x21), let y = find(0x22) else { return nil }
        return try? P256.Signing.PublicKey(x963Representation: Data([0x04] + x + y))
    }

    /// clientDataJSON names our challenge (base64url) and the ceremony type.
    static func clientDataMatches(_ json: Data, challenge: Data, type: String) -> Bool {
        guard let obj = try? JSONSerialization.jsonObject(with: json) as? [String: Any],
              obj["type"] as? String == type, let c = obj["challenge"] as? String else { return false }
        let expected = challenge.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        return c == expected
    }

    /// The signature covers authenticatorData followed by SHA-256(clientDataJSON).
    static func verify(assertion a: ASAuthorizationSecurityKeyPublicKeyCredentialAssertion,
                       with key: P256.Signing.PublicKey) -> Bool {
        guard let sig = try? P256.Signing.ECDSASignature(derRepresentation: a.signature) else { return false }
        let signed = a.rawAuthenticatorData + Data(SHA256.hash(data: a.rawClientDataJSON))
        return key.isValidSignature(sig, for: signed)
    }
}
