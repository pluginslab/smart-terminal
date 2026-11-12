package com.pluginslab.smartterminal.pad.remote

import android.content.Context
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import android.util.Base64
import net.schmizz.sshj.common.Buffer
import net.schmizz.sshj.common.KeyType
import java.security.KeyFactory
import java.security.KeyPair
import java.security.KeyPairGenerator
import java.security.KeyStore
import java.security.spec.ECGenParameterSpec
import java.security.spec.PKCS8EncodedKeySpec
import java.security.spec.X509EncodedKeySpec
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec

/**
 * This tablet's own SSH key, made on first launch. Its public half goes into the host's
 * authorized_keys.
 *
 * ecdsa-sha2-nistp256, kept encrypted under an AES key in the Android Keystore that never
 * leaves it (this device only). The iPad keeps its ed25519 key in the keychain the same way.
 * A key that signs inside the Keystore itself is a later step (see docs/android-plan.md).
 */
object DeviceKey {
    private const val PREFS = "deviceKey"
    private const val WRAP_ALIAS = "smartterminal.sshkey.wrap"

    @Volatile private var cached: KeyPair? = null

    fun keyPair(context: Context): KeyPair = cached ?: synchronized(this) {
        cached ?: (load(context) ?: create(context)).also { cached = it }
    }

    /** "ecdsa-sha2-nistp256 AAAA… smart-terminal-android" */
    fun publicKeyLine(context: Context): String {
        val pub = keyPair(context).public
        val blob = Buffer.PlainBuffer().putPublicKey(pub).compactData
        return "${KeyType.fromKey(pub)} ${Base64.encodeToString(blob, Base64.NO_WRAP)} smart-terminal-android"
    }

    private fun wrapKey(): SecretKey {
        val ks = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }
        (ks.getKey(WRAP_ALIAS, null) as? SecretKey)?.let { return it }
        val gen = KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, "AndroidKeyStore")
        gen.init(
            KeyGenParameterSpec.Builder(WRAP_ALIAS, KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT)
                .setBlockModes(KeyProperties.BLOCK_MODE_GCM)
                .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
                .build()
        )
        return gen.generateKey()
    }

    private fun load(context: Context): KeyPair? = runCatching {
        val p = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
        val iv = Base64.decode(p.getString("iv", null) ?: return null, Base64.NO_WRAP)
        val sealed = Base64.decode(p.getString("private", null) ?: return null, Base64.NO_WRAP)
        val public = Base64.decode(p.getString("public", null) ?: return null, Base64.NO_WRAP)
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(Cipher.DECRYPT_MODE, wrapKey(), GCMParameterSpec(128, iv))
        val kf = KeyFactory.getInstance("EC")
        KeyPair(kf.generatePublic(X509EncodedKeySpec(public)), kf.generatePrivate(PKCS8EncodedKeySpec(cipher.doFinal(sealed))))
    }.getOrNull()

    private fun create(context: Context): KeyPair {
        val gen = KeyPairGenerator.getInstance("EC")
        gen.initialize(ECGenParameterSpec("secp256r1"))
        val pair = gen.generateKeyPair()
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(Cipher.ENCRYPT_MODE, wrapKey())
        val sealed = cipher.doFinal(pair.private.encoded)
        context.getSharedPreferences(PREFS, Context.MODE_PRIVATE).edit()
            .putString("iv", Base64.encodeToString(cipher.iv, Base64.NO_WRAP))
            .putString("private", Base64.encodeToString(sealed, Base64.NO_WRAP))
            .putString("public", Base64.encodeToString(pair.public.encoded, Base64.NO_WRAP))
            .apply()
        return pair
    }
}
