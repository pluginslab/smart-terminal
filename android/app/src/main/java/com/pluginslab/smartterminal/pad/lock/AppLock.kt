package com.pluginslab.smartterminal.pad.lock

import android.content.Context
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import android.util.Base64
import android.util.Log
import androidx.biometric.BiometricManager.Authenticators.BIOMETRIC_STRONG
import androidx.biometric.BiometricManager.Authenticators.DEVICE_CREDENTIAL
import androidx.biometric.BiometricPrompt
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.core.content.ContextCompat
import androidx.fragment.app.FragmentActivity
import com.yubico.yubikit.android.YubiKitManager
import com.yubico.yubikit.android.transport.usb.UsbConfiguration
import com.yubico.yubikit.core.fido.CtapException
import com.yubico.yubikit.core.fido.FidoConnection
import com.yubico.yubikit.fido.Cose
import com.yubico.yubikit.fido.ctap.Ctap2Session
import com.yubico.yubikit.fido.webauthn.AuthenticatorData
import java.nio.ByteBuffer
import java.security.KeyFactory
import java.security.MessageDigest
import java.security.SecureRandom
import java.security.Signature
import java.security.spec.X509EncodedKeySpec

/**
 * The app's lock: nothing (not even the SSH connection) starts until you unlock, at launch
 * and again after more than two minutes away. As on the iPad.
 *
 * Two ways in. A security key (YubiKey) over USB-C, spoken to directly with FIDO2 (CTAP2)
 * through Yubico's SDK: set up once, after which the key's credential id and public key are
 * kept here (not secrets) and each unlock checks the key's signature over a fresh challenge,
 * on the device. No server and no web domain, unlike Apple's passkey API on the iPad. Or the
 * fingerprint, with the device PIN as fallback.
 */
class AppLock(private val context: Context) {
    var locked by mutableStateOf(isRequired)
        private set
    var busy by mutableStateOf(false)
        private set
    var message: String? by mutableStateOf(null)
    /** The key is plugged in and we are waiting for a touch. */
    var waitingForTouch by mutableStateOf(false)
        private set

    private val prefs = context.getSharedPreferences("lock", Context.MODE_PRIVATE)
    private val main = Handler(Looper.getMainLooper())
    private var backgroundedAt: Long? = null
    private var yubikit: YubiKitManager? = null
    /** Runs once the lock opens (connect to the host, attach panes). */
    var onUnlock: (() -> Unit)? = null

    val hasSecurityKey: Boolean get() = prefs.contains("credentialId")

    // MARK: background

    fun didEnterBackground() { backgroundedAt = SystemClock.elapsedRealtime() }

    fun didBecomeActive() {
        val t = backgroundedAt
        backgroundedAt = null
        if (isRequired && t != null && SystemClock.elapsedRealtime() - t > GRACE_MS) { locked = true; message = null }
    }

    /** The lock was switched off for this run (debug `nolock`). */
    fun onUnlockSkipped() { locked = false }

    /** The lock button: always locks, even where the lock isn't required (debug `nolock`). */
    fun lock() {
        locked = true
        message = null
    }

    private fun open() {
        locked = false
        busy = false
        waitingForTouch = false
        message = null
        stopKey()
        onUnlock?.invoke()
    }

    // MARK: fingerprint / PIN

    fun unlockWithBiometrics(activity: FragmentActivity) {
        val prompt = BiometricPrompt(activity, ContextCompat.getMainExecutor(activity), object : BiometricPrompt.AuthenticationCallback() {
            override fun onAuthenticationSucceeded(result: BiometricPrompt.AuthenticationResult) = open()
            override fun onAuthenticationError(code: Int, err: CharSequence) {
                if (code != BiometricPrompt.ERROR_USER_CANCELED && code != BiometricPrompt.ERROR_NEGATIVE_BUTTON) message = err.toString()
            }
        })
        prompt.authenticate(
            BiometricPrompt.PromptInfo.Builder()
                .setTitle("Unlock Smart Terminal")
                .setAllowedAuthenticators(BIOMETRIC_STRONG or DEVICE_CREDENTIAL)
                .build()
        )
    }

    // MARK: security key

    /**
     * Listens for the key on USB while the lock shows: plugging it in (or having it in)
     * starts the setup or the unlock, and a touch finishes it.
     */
    fun startKey() {
        if (yubikit != null || !locked) return
        val kit = YubiKitManager(context)
        yubikit = kit
        kit.startUsbDiscovery(UsbConfiguration()) { device ->
            if (!device.supportsConnection(FidoConnection::class.java)) return@startUsbDiscovery
            main.post { busy = true; waitingForTouch = true; message = null }
            device.requestConnection(FidoConnection::class.java) { result ->
                try {
                    val session = Ctap2Session(result.value)
                    if (hasSecurityKey) assert(session) else register(session)
                    main.post { open() }
                } catch (e: Exception) {
                    Log.w(TAG, "security key", e)
                    main.post { busy = false; waitingForTouch = false; message = describe(e) }
                }
            }
        }
    }

    fun stopKey() {
        yubikit?.stopUsbDiscovery()
        yubikit = null
    }

    /** Make a credential for this app on the key and keep its id and public key. */
    private fun register(session: Ctap2Session) {
        val data = session.makeCredential(
            random(32),
            mapOf("id" to RP_ID, "name" to "Smart Terminal"),
            mapOf("id" to random(16), "name" to "smart-terminal-android", "displayName" to "Smart Terminal (Android)"),
            listOf(mapOf("type" to "public-key", "alg" to -7)),   // ES256
            null, null, null, null, null, null, null,
        )
        val auth = AuthenticatorData.parseFrom(ByteBuffer.wrap(data.authenticatorData))
        val attested = auth.attestedCredentialData ?: throw IllegalStateException("The key's answer has no credential.")
        val key = Cose.getPublicKey(attested.cosePublicKey) ?: throw IllegalStateException("The key sent no public key.")
        prefs.edit()
            .putString("credentialId", Base64.encodeToString(attested.credentialId, Base64.NO_WRAP))
            .putString("publicKey", Base64.encodeToString(key.encoded, Base64.NO_WRAP))
            .apply()
        Log.i(TAG, "security key set up")
    }

    /** Ask the key to sign a fresh challenge with the registered credential, and check it here. */
    private fun assert(session: Ctap2Session) {
        val credentialId = Base64.decode(prefs.getString("credentialId", null), Base64.NO_WRAP)
        val publicKey = KeyFactory.getInstance("EC").generatePublic(
            X509EncodedKeySpec(Base64.decode(prefs.getString("publicKey", null), Base64.NO_WRAP)))
        val challenge = random(32)
        val a = session.getAssertions(RP_ID, challenge,
            listOf(mapOf("type" to "public-key", "id" to credentialId)), null, null, null, null, null).first()
        val authData = a.authenticatorData
        val rpHash = MessageDigest.getInstance("SHA-256").digest(RP_ID.toByteArray())
        require(authData.size >= 37 && authData.copyOfRange(0, 32).contentEquals(rpHash)) { "The key answered for another site." }
        require(authData[32].toInt() and 0x01 != 0) { "The key wasn't touched." }
        val ok = Signature.getInstance("SHA256withECDSA").run {
            initVerify(publicKey); update(authData); update(challenge); verify(a.signature)
        }
        require(ok) { "That's not the key set up for Smart Terminal." }
    }

    private fun describe(e: Exception): String = when {
        e is CtapException && e.ctapError == CtapException.ERR_NO_CREDENTIALS -> "That's not the key set up for Smart Terminal."
        e is CtapException && (e.ctapError == CtapException.ERR_PUAT_REQUIRED || e.ctapError == 0x36.toByte()) ->
            "This key asks for its PIN, which Smart Terminal doesn't support yet. Use the fingerprint or PIN."
        e is CtapException && (e.ctapError == CtapException.ERR_USER_ACTION_TIMEOUT || e.ctapError == CtapException.ERR_ACTION_TIMEOUT) ->
            "The key wasn't touched in time. Unplug it and plug it in again."
        e is CtapException && e.ctapError == CtapException.ERR_OPERATION_DENIED -> "The key said no."
        else -> e.message ?: e.javaClass.simpleName
    }

    private fun random(n: Int) = ByteArray(n).also { SecureRandom().nextBytes(it) }

    companion object {
        private const val TAG = "AppLock"
        /** Not a web domain here: just the name the key files this credential under. */
        private const val RP_ID = "pluginslab.com"
        /** Away longer than this locks again. */
        private const val GRACE_MS = 120_000L
        /** Debug builds: `--ez nolock true` skips the lock (tests, screenshots). */
        @Volatile var isRequired = true
    }
}
