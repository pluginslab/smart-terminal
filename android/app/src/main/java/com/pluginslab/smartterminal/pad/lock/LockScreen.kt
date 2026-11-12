package com.pluginslab.smartterminal.pad.lock

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.widthIn
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Fingerprint
import androidx.compose.material.icons.filled.Lock
import androidx.compose.material.icons.filled.Usb
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Icon
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.fragment.app.FragmentActivity
import com.pluginslab.smartterminal.pad.ui.Palette

/** Before anything else: the YubiKey (set up once), or the fingerprint / PIN. */
@Composable
fun LockScreen(lock: AppLock) {
    val activity = LocalContext.current as FragmentActivity
    // Listen for the key while this shows; plugging it in starts setup or unlock.
    DisposableEffect(Unit) {
        lock.startKey()
        onDispose { lock.stopKey() }
    }
    Box(Modifier.fillMaxSize().background(Palette.terminal), contentAlignment = Alignment.Center) {
        Column(Modifier.widthIn(max = 460.dp).padding(32.dp), horizontalAlignment = Alignment.CenterHorizontally,
            verticalArrangement = Arrangement.spacedBy(16.dp)) {
            Icon(Icons.Filled.Lock, null, tint = Palette.selection, modifier = Modifier.size(44.dp))
            Text("Smart Terminal is locked", color = Palette.text, fontSize = 22.sp, fontWeight = FontWeight.Bold)
            Text(
                when {
                    lock.waitingForTouch -> "Touch your YubiKey."
                    lock.hasSecurityKey -> "Plug in your YubiKey and touch it, or use your fingerprint."
                    else -> "Plug in your YubiKey and touch it to set it up for Smart Terminal. Or use your fingerprint."
                },
                color = Palette.secondary, fontSize = 16.sp, textAlign = TextAlign.Center,
            )
            if (lock.waitingForTouch) CircularProgressIndicator(color = Palette.selection, modifier = Modifier.size(28.dp))
            else Icon(Icons.Filled.Usb, null, tint = Palette.secondary, modifier = Modifier.size(28.dp))
            lock.message?.let { Text(it, color = Palette.red, fontSize = 14.sp, textAlign = TextAlign.Center) }
            OutlinedButton({ lock.unlockWithBiometrics(activity) }) {
                Icon(Icons.Filled.Fingerprint, null, Modifier.size(20.dp)); Text("  Fingerprint or PIN")
            }
        }
    }
}
