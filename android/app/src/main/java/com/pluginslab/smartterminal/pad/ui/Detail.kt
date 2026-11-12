package com.pluginslab.smartterminal.pad.ui

import android.content.ClipData
import android.content.ClipboardManager
import androidx.compose.foundation.ExperimentalFoundationApi
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ExperimentalLayoutApi
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.ime
import androidx.compose.foundation.layout.isImeVisible
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.statusBars
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.layout.windowInsetsPadding
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Dns
import androidx.compose.material.icons.filled.Lock
import androidx.compose.material.icons.filled.Terminal
import androidx.compose.material.icons.outlined.ViewSidebar
import androidx.compose.material3.Button
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.key
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.ui.viewinterop.AndroidView
import com.pluginslab.smartterminal.pad.model.PadModel
import com.pluginslab.smartterminal.pad.remote.DeviceKey
import com.pluginslab.smartterminal.pad.remote.Host
import com.pluginslab.smartterminal.pad.remote.TerminalPane

/** The terminal column: a header band like the Mac's, the session's terminal (or the
 *  setup card while the host isn't reachable), and the key bar under it. */
@OptIn(ExperimentalLayoutApi::class)
@Composable
fun DetailColumn(model: PadModel, portrait: Boolean, onLock: () -> Unit, modifier: Modifier) {
    val host = model.host
    val name = model.selected?.takeIf { n -> model.sessions.any { it.name == n } }
    val connected = host.state == Host.State.Connected
    Column(modifier.background(Palette.head).windowInsetsPadding(WindowInsets.statusBars)) {
        Header(model, portrait, name, onLock)
        Box(Modifier.weight(1f).fillMaxWidth().background(Palette.terminal), contentAlignment = Alignment.Center) {
            when {
                connected && name != null -> key(name) { Terminal(model.pane(name)) }
                connected -> Column(horizontalAlignment = Alignment.CenterHorizontally) {
                    Icon(Icons.Filled.Terminal, null, tint = Palette.secondary, modifier = Modifier.padding(bottom = 8.dp))
                    Text("No Session", color = Palette.text, fontSize = 20.sp, fontWeight = FontWeight.Bold)
                    Text("Pick a session, or + for a new one.", color = Palette.secondary)
                }
                else -> ConnectCard(host)
            }
        }
        // Hidden while the on-screen keyboard is up, as on the iPad.
        if (connected && name != null && !WindowInsets.isImeVisible) KeyBar(model, name, portrait)
        else Spacer(Modifier.windowInsetsPadding(WindowInsets.ime))
    }
}

@Composable
private fun Header(model: PadModel, portrait: Boolean, name: String?, onLock: () -> Unit) {
    val s = model.sessions.firstOrNull { it.name == name }
    Column {
        Row(Modifier.fillMaxWidth().height(64.dp).padding(start = 12.dp, end = 12.dp), verticalAlignment = Alignment.CenterVertically) {
            if (portrait) {
                HeaderButton(Icons.Outlined.ViewSidebar, "Show Sessions") { model.listsOpen = true }
                Spacer(Modifier.width(12.dp))
            } else Spacer(Modifier.width(8.dp))
            Column(Modifier.weight(1f)) {
                if (s != null) {
                    Text(model.title(s), color = Palette.text, fontSize = 20.sp, fontWeight = FontWeight.Bold, maxLines = 1, overflow = TextOverflow.Ellipsis)
                    Text(s.path.replace("/home/${model.host.user}", "~"), color = Palette.secondary, fontSize = 14.sp, maxLines = 1, overflow = TextOverflow.StartEllipsis)
                } else Text(model.host.displayName, color = Palette.text, fontSize = 20.sp, fontWeight = FontWeight.Bold)
            }
            HeaderButton(Icons.Filled.Lock, "Lock Smart Terminal", onClick = onLock)
            // No close button here: closing kills the tmux session on the host (and the Claude
            // in it), too much for a single tap. The session row's long-press menu has it.
        }
        HorizontalDivider(color = Palette.line, thickness = 0.5.dp)
    }
}

/** The pane's terminal view. The same view moves between layouts (rotation, window size),
 *  so it is taken out of its old parent before it goes in here. */
@Composable
private fun Terminal(pane: TerminalPane) {
    LaunchedEffect(pane, pane.state) { if (pane.state == TerminalPane.State.Ended) pane.reattach() }
    AndroidView(factory = { pane.detachedView() }, modifier = Modifier.fillMaxSize().padding(start = 6.dp, end = 6.dp, top = 4.dp))
}

/** Shown until the host accepts this tablet: its public key to add, and the error. */
@Composable
private fun ConnectCard(host: Host) {
    val ctx = LocalContext.current
    val key = remember { DeviceKey.publicKeyLine(ctx) }
    var copied by remember { mutableStateOf(false) }
    Column(Modifier.widthIn(max = 560.dp).padding(28.dp), verticalArrangement = Arrangement.spacedBy(14.dp)) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Icon(Icons.Filled.Dns, null, tint = Palette.text); Spacer(Modifier.width(8.dp))
            Text(when (host.state) {
                Host.State.Connecting -> "Connecting to ${host.displayName}…"
                is Host.State.Failed -> "Couldn't connect to ${host.displayName}"
                else -> "Not connected to ${host.displayName}"
            }, color = Palette.text, fontSize = 17.sp, fontWeight = FontWeight.SemiBold)
        }
        (host.state as? Host.State.Failed)?.let { Text(it.message, color = Palette.secondary) }
        Text("This tablet's key. Add it to ~/.ssh/authorized_keys on ${host.displayName}:", color = Palette.secondary, fontSize = 14.sp)
        Text(key, color = Palette.text, fontFamily = FontFamily.Monospace, fontSize = 12.sp,
            modifier = Modifier.clip(RoundedCornerShape(8.dp)).background(Palette.key).padding(10.dp))
        Row(horizontalArrangement = Arrangement.spacedBy(12.dp)) {
            OutlinedButton({
                ctx.getSystemService(ClipboardManager::class.java).setPrimaryClip(ClipData.newPlainText("key", key))
                copied = true
            }) { Text(if (copied) "Copied" else "Copy Key") }
            Button({ host.connect() }, enabled = host.state != Host.State.Connecting) { Text("Connect") }
        }
    }
}
