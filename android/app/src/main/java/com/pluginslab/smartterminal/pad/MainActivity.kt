package com.pluginslab.smartterminal.pad

import android.content.ClipData
import android.content.ClipboardManager
import android.os.Bundle
import android.util.Log
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.ui.viewinterop.AndroidView
import com.pluginslab.smartterminal.pad.remote.DeviceKey
import com.pluginslab.smartterminal.pad.remote.Host
import com.pluginslab.smartterminal.pad.remote.TerminalPane

class MainActivity : ComponentActivity() {
    private val app get() = application as PadApp

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        enableEdgeToEdge()
        Log.i("SmartTerminal", "device key: " + DeviceKey.publicKeyLine(this))
        val session = intent.getStringExtra("session") ?: "android-test"
        val pane = app.pane(session)
        setContent { Spike(pane) }
    }

    override fun onResume() {
        super.onResume()
        app.allPanes.forEach { it.reattach() }
    }
}

private val bg = Color(0xFF102030)
private val bar = Color(0xFF0C1926)
private val amber = Color(0xFFE8A33D)

@Composable
private fun Spike(pane: TerminalPane) {
    var state by remember { mutableStateOf(pane.state) }
    var title by remember { mutableStateOf("") }
    DisposableEffect(pane) {
        pane.onState = { state = it }
        pane.onTitle = { title = it }
        onDispose { pane.onState = null; pane.onTitle = null }
    }
    Column(Modifier.fillMaxSize().background(bg).systemBarsPadding().imePadding()) {
        Row(Modifier.fillMaxWidth().background(bar).padding(horizontal = 16.dp, vertical = 10.dp),
            verticalAlignment = Alignment.CenterVertically) {
            Text(pane.session, color = Color(0xFFC8D3DF), fontSize = 15.sp)
            Spacer(Modifier.width(12.dp))
            Text(title, color = Color(0xFF7B8C9C), fontSize = 13.sp, maxLines = 1, modifier = Modifier.weight(1f))
            Text(state.name.lowercase(), color = if (state == TerminalPane.State.Attached) Color(0xFF6CAA70) else amber, fontSize = 13.sp)
        }
        Box(Modifier.weight(1f).fillMaxWidth()) {
            AndroidView(factory = { pane.detachedView() }, modifier = Modifier.fillMaxSize())
            if (state == TerminalPane.State.Ended && pane.lastError != null) Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) { SetupCard(pane) }
        }
        KeyRow(pane)
    }
}

@Composable
private fun SetupCard(pane: TerminalPane) {
    val ctx = androidx.compose.ui.platform.LocalContext.current
    val key = remember { DeviceKey.publicKeyLine(ctx) }
    Card(Modifier.padding(32.dp).widthIn(max = 640.dp)) {
        Column(Modifier.padding(20.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
            Text("Couldn't connect", style = MaterialTheme.typography.titleMedium)
            Text(pane.lastError ?: "")
            Text(key, fontFamily = FontFamily.Monospace, fontSize = 12.sp)
            Row(horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                Button(onClick = {
                    ctx.getSystemService(ClipboardManager::class.java).setPrimaryClip(ClipData.newPlainText("key", key))
                }) { Text("Copy Key") }
                OutlinedButton(onClick = { pane.reattach() }) { Text("Connect") }
            }
        }
    }
}

@Composable
private fun KeyRow(pane: TerminalPane) {
    Row(Modifier.fillMaxWidth().background(bar).navigationBarsPadding().padding(horizontal = 12.dp, vertical = 8.dp),
        horizontalArrangement = Arrangement.spacedBy(8.dp)) {
        listOf("⌨" to null, "esc" to "\u001b", "⇧tab" to "\u001b[Z", "tab" to "\t", "^C" to "\u0003",
            "↑" to "\u001b[A", "↓" to "\u001b[B", "return" to "\r").forEach { (label, seq) ->
            FilledTonalButton(onClick = { if (seq == null) pane.showKeyboard() else pane.write(seq) },
                contentPadding = PaddingValues(horizontal = 16.dp)) { Text(label) }
        }
    }
}
