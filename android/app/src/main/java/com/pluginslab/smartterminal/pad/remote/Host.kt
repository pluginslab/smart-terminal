package com.pluginslab.smartterminal.pad.remote

import android.content.Context
import net.schmizz.sshj.DefaultConfig
import net.schmizz.sshj.SSHClient
import net.schmizz.sshj.common.Buffer
import net.schmizz.sshj.transport.verification.HostKeyVerifier
import net.schmizz.sshj.userauth.keyprovider.KeyPairWrapper
import android.util.Base64
import java.net.InetAddress
import java.security.PublicKey

/**
 * The SSH connection to the host. One connection carries every tab's shell channel and the
 * status commands, as on the iPad.
 */
class Host(private val context: Context, val address: String, val user: String, private val lanFallback: String?) {

    @Volatile var client: SSHClient? = null
        private set

    val isConnected: Boolean get() = client?.isConnected == true && client?.isAuthenticated == true

    /** Blocking; call off the main thread. Throws with a message fit for the screen. */
    @Synchronized
    fun connect(): SSHClient {
        client?.let { if (it.isConnected && it.isAuthenticated) return it }
        client = null
        val c = SSHClient(DefaultConfig())
        c.addHostKeyVerifier(PinnedHostKey(context, address))
        c.connectTimeout = 10_000
        c.connect(resolve())
        try {
            c.authPublickey(user, KeyPairWrapper(DeviceKey.keyPair(context)))
        } catch (e: Exception) {
            runCatching { c.disconnect() }
            throw RefusedKey()
        }
        c.connection.keepAlive.keepAliveInterval = 15
        client = c
        return c
    }

    fun disconnect() {
        runCatching { client?.disconnect() }
        client = null
    }

    /** `supermaschine` resolves only with Tailscale on; at home the LAN address works too. */
    private fun resolve(): String = runCatching { InetAddress.getByName(address); address }
        .getOrElse { lanFallback ?: throw it }

    class RefusedKey : Exception("The host refused this tablet's key. Add it to ~/.ssh/authorized_keys.")

    companion object {
        fun quote(s: String) = "'" + s.replace("'", "'\\''") + "'"
    }
}

/** Trust on first use: the host's key is remembered the first time and must match after. */
class PinnedHostKey(context: Context, private val host: String) : HostKeyVerifier {
    private val prefs = context.getSharedPreferences("hostKeys", Context.MODE_PRIVATE)

    override fun verify(hostname: String, port: Int, key: PublicKey): Boolean {
        val seen = Base64.encodeToString(Buffer.PlainBuffer().putPublicKey(key).compactData, Base64.NO_WRAP)
        val pinned = prefs.getString(host, null)
        if (pinned == null) {
            prefs.edit().putString(host, seen).apply()
            return true
        }
        return pinned == seen
    }

    override fun findExistingAlgorithms(hostname: String, port: Int): List<String> = emptyList()
}
