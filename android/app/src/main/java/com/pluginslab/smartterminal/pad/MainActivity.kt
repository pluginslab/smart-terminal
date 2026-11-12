package com.pluginslab.smartterminal.pad

import android.Manifest
import android.content.pm.PackageManager
import android.os.Bundle
import android.util.Log
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.activity.result.contract.ActivityResultContracts
import com.pluginslab.smartterminal.pad.remote.DeviceKey
import com.pluginslab.smartterminal.pad.ui.PadTheme
import com.pluginslab.smartterminal.pad.ui.RootScreen

class MainActivity : ComponentActivity() {
    private val model get() = (application as PadApp).model
    private var micAnswer: ((Boolean) -> Unit)? = null
    private val micPermission = registerForActivityResult(ActivityResultContracts.RequestPermission()) { ok ->
        micAnswer?.invoke(ok); micAnswer = null
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        enableEdgeToEdge()
        Log.i("SmartTerminal", "device key: " + DeviceKey.publicKeyLine(this))
        model.dictation.requestMicrophone = { answer ->
            if (checkSelfPermission(Manifest.permission.RECORD_AUDIO) == PackageManager.PERMISSION_GRANTED) answer(true)
            else { micAnswer = answer; micPermission.launch(Manifest.permission.RECORD_AUDIO) }
        }
        // Debug builds: `adb shell am start ... --es session <name>` opens that session.
        intent.getStringExtra("session")?.let { model.selected = it }
        setContent { PadTheme { RootScreen(model) } }
    }

    override fun onResume() {
        super.onResume()
        model.resume()
    }
}
