package com.pluginslab.smartterminal.pad

import android.app.Application
import com.pluginslab.smartterminal.pad.model.PadModel
import org.bouncycastle.jce.provider.BouncyCastleProvider
import java.security.Security

class PadApp : Application() {
    /** Process-scoped, so rotation and window resizes never rebuild a terminal or lose state. */
    val model by lazy { PadModel(this) }

    override fun onCreate() {
        super.onCreate()
        // Android ships a cut-down "BC" provider; sshj needs the full one (curve25519, etc.).
        Security.removeProvider("BC")
        Security.insertProviderAt(BouncyCastleProvider(), 1)
    }
}
