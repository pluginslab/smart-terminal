package com.pluginslab.smartterminal.pad

import android.app.Application
import com.pluginslab.smartterminal.pad.remote.Host
import com.pluginslab.smartterminal.pad.remote.TerminalPane
import org.bouncycastle.jce.provider.BouncyCastleProvider
import java.security.Security

class PadApp : Application() {
    /** supermaschine only, as on the iPad. The LAN address covers Tailscale being off at home. */
    val host by lazy { Host(this, "supermaschine", "pluginslab", lanFallback = "192.168.1.132") }

    /** Process-scoped, so rotation and window resizes never rebuild a terminal. */
    private val panes = mutableMapOf<String, TerminalPane>()
    fun pane(session: String): TerminalPane = panes.getOrPut(session) { TerminalPane(this, host, session) }
    val allPanes: Collection<TerminalPane> get() = panes.values

    override fun onCreate() {
        super.onCreate()
        // Android ships a cut-down "BC" provider; sshj needs the full one (curve25519, etc.).
        Security.removeProvider("BC")
        Security.insertProviderAt(BouncyCastleProvider(), 1)
    }
}
