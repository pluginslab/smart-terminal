package com.pluginslab.smartterminal.pad

import android.Manifest
import android.content.pm.PackageManager
import android.os.Bundle
import android.util.Log
import android.view.WindowManager
import androidx.fragment.app.FragmentActivity
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.activity.result.contract.ActivityResultContracts
import com.pluginslab.smartterminal.pad.remote.DeviceKey
import com.pluginslab.smartterminal.pad.lock.AppLock
import com.pluginslab.smartterminal.pad.lock.LockScreen
import com.pluginslab.smartterminal.pad.ui.PadTheme
import com.pluginslab.smartterminal.pad.ui.RootScreen

class MainActivity : FragmentActivity() {
    private val model get() = (application as PadApp).model
    private val lock get() = (application as PadApp).lock
    private var micAnswer: ((Boolean) -> Unit)? = null
    private val micPermission = registerForActivityResult(ActivityResultContracts.RequestPermission()) { ok ->
        micAnswer?.invoke(ok); micAnswer = null
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        enableEdgeToEdge()
        // The recents thumbnail shows a black card, not the terminal. Release builds only:
        // it would black out adb screenshots too.
        if (!BuildConfig.DEBUG) window.addFlags(WindowManager.LayoutParams.FLAG_SECURE)
        // Debug builds: `--ez nolock true` skips the lock.
        if (BuildConfig.DEBUG && intent.getBooleanExtra("nolock", false)) { AppLock.isRequired = false; lock.onUnlockSkipped() }
        // Nothing connects until the lock opens.
        lock.onUnlock = { model.resume() }
        Log.i("SmartTerminal", "device key: " + DeviceKey.publicKeyLine(this))
        model.dictation.requestMicrophone = { answer ->
            if (checkSelfPermission(Manifest.permission.RECORD_AUDIO) == PackageManager.PERMISSION_GRANTED) answer(true)
            else { micAnswer = answer; micPermission.launch(Manifest.permission.RECORD_AUDIO) }
        }
        // Debug builds: `adb shell am start ... --es session <name>` opens that session.
        intent.getStringExtra("session")?.let { model.selected = it }
        setContent { PadTheme { if (lock.locked) LockScreen(lock) else RootScreen(model, onLock = lock::lock) } }
    }

    override fun onStart() {
        super.onStart()
        lock.didBecomeActive()
    }

    override fun onResume() {
        super.onResume()
        if (!lock.locked) model.resume()
    }

    override fun onStop() {
        super.onStop()
        lock.didEnterBackground()
    }
}
