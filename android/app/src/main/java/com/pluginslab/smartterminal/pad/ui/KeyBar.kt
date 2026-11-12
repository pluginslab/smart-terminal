package com.pluginslab.smartterminal.pad.ui

import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.core.RepeatMode
import androidx.compose.animation.core.animateFloat
import androidx.compose.animation.core.infiniteRepeatable
import androidx.compose.animation.core.rememberInfiniteTransition
import androidx.compose.animation.core.tween
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.scaleIn
import androidx.compose.animation.scaleOut
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.gestures.detectDragGestures
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.navigationBars
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.layout.windowInsetsPadding
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.KeyboardReturn
import androidx.compose.material.icons.filled.ArrowDownward
import androidx.compose.material.icons.filled.ArrowUpward
import androidx.compose.material.icons.filled.Keyboard
import androidx.compose.material.icons.filled.Mic
import androidx.compose.material.icons.filled.MicOff
import androidx.compose.material.icons.filled.OpenWith
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.automirrored.filled.ArrowForward
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.draw.clip
import androidx.compose.ui.geometry.CornerRadius
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.hapticfeedback.HapticFeedbackType
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.platform.LocalHapticFeedback
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.pluginslab.smartterminal.pad.dictation.Dictation
import com.pluginslab.smartterminal.pad.model.PadModel
import kotlin.math.abs

/**
 * The keys a session needs without a keyboard: answering Claude (arrows, return, esc), its
 * mode (⇧tab), stopping a command (^C); the keyboard toggle; dictation at the right edge.
 * While dictating the keys grey out, return steps aside and a waveform fills the space.
 */
@Composable
fun KeyBar(model: PadModel, session: String, portrait: Boolean) {
    val pane = model.pane(session)
    val d = model.dictation
    val busy = d.isActive
    Column(Modifier.fillMaxWidth().background(Palette.bar)) {
        HorizontalDivider(color = Palette.line, thickness = 0.5.dp)
        Row(
            // Clear of the gesture bar: taps right above it reach the system (the iPad's Siri
            // lesson), so the keys sit higher in portrait.
            Modifier.fillMaxWidth().windowInsetsPadding(WindowInsets.navigationBars)
                .padding(start = 12.dp, end = 12.dp, top = 8.dp, bottom = if (portrait) 18.dp else 10.dp),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(8.dp),
        ) {
            Row(Modifier.alpha(if (busy) 0.35f else 1f), horizontalArrangement = Arrangement.spacedBy(8.dp), verticalAlignment = Alignment.CenterVertically) {
                Key(icon = Icons.Filled.Keyboard, label = "Show Keyboard", enabled = !busy) { pane.showKeyboard() }
                Separator()
                Key(text = "esc", enabled = !busy) { pane.write("\u001b") }
                Key(text = "⇧tab", enabled = !busy) { pane.write("\u001b[Z") }
                Key(text = "tab", enabled = !busy) { pane.write("\t") }
                Key(text = "^C", enabled = !busy) { pane.write("\u0003") }
                ArrowPad(enabled = !busy) { pane.arrow(it) }
            }
            if (d.state == Dictation.State.Recording) {
                Waveform(d.levels, Modifier.weight(1f).height(36.dp).padding(horizontal = 8.dp))
            } else Spacer(Modifier.weight(1f))
            AnimatedVisibility(!busy, enter = scaleIn() + fadeIn(), exit = scaleOut() + fadeOut()) {
                Row(Modifier.height(48.dp).clip(RoundedCornerShape(50)).background(Palette.selection)
                    .clickable { pane.write("\r") }.padding(horizontal = 18.dp), verticalAlignment = Alignment.CenterVertically) {
                    Icon(Icons.AutoMirrored.Filled.KeyboardReturn, "Return", tint = Palette.onSelection, modifier = Modifier.size(20.dp))
                    Spacer(Modifier.width(6.dp))
                    Text("return", color = Palette.onSelection, fontWeight = FontWeight.SemiBold, fontSize = 16.sp)
                }
            }
            Separator()
            DictationButton(model, session)
        }
    }
}

@Composable
private fun Key(icon: ImageVector? = null, text: String? = null, label: String? = null, enabled: Boolean, onClick: () -> Unit) {
    Box(Modifier.height(48.dp).widthIn(min = 56.dp).clip(RoundedCornerShape(50)).background(Palette.key)
        .clickable(enabled = enabled, onClick = onClick).padding(horizontal = 10.dp), contentAlignment = Alignment.Center) {
        if (icon != null) Icon(icon, label ?: text, tint = Palette.text, modifier = Modifier.size(22.dp))
        else Text(text ?: "", color = Palette.text, fontFamily = FontFamily.Monospace, fontWeight = FontWeight.SemiBold, fontSize = 16.sp)
    }
}

/** A short hairline between key groups, centred on the keys. */
@Composable
private fun Separator() = Box(Modifier.width(1.dp).height(28.dp).background(Palette.line))

/**
 * All four arrows in one key: swipe from it in a direction to send that arrow, one more for
 * each further step of the same swipe, so a long drag walks down a list. Shows the direction
 * it just sent; each step ticks.
 */
@Composable
private fun ArrowPad(enabled: Boolean, send: (Char) -> Unit) {
    val haptic = LocalHapticFeedback.current
    val step = with(LocalDensity.current) { 22.dp.toPx() }
    var last by remember { mutableStateOf<Char?>(null) }
    val icon = when (last) {
        'A' -> Icons.Filled.ArrowUpward
        'B' -> Icons.Filled.ArrowDownward
        'C' -> Icons.AutoMirrored.Filled.ArrowForward
        'D' -> Icons.AutoMirrored.Filled.ArrowBack
        else -> Icons.Filled.OpenWith
    }
    Box(
        Modifier.height(48.dp).width(64.dp).clip(RoundedCornerShape(50)).background(Palette.key)
            .pointerInput(enabled) {
                if (!enabled) return@pointerInput
                var acc = Offset.Zero
                detectDragGestures(
                    onDragStart = { acc = Offset.Zero },
                    onDragEnd = { last = null },
                    onDragCancel = { last = null },
                ) { change, drag ->
                    change.consume()
                    acc += drag
                    if (maxOf(abs(acc.x), abs(acc.y)) >= step) {
                        val dir = if (abs(acc.x) > abs(acc.y)) (if (acc.x > 0) 'C' else 'D') else (if (acc.y > 0) 'B' else 'A')
                        send(dir); last = dir; acc = Offset.Zero
                        haptic.performHapticFeedback(HapticFeedbackType.TextHandleMove)
                    }
                }
            },
        contentAlignment = Alignment.Center,
    ) { Icon(icon, "Arrow keys: swipe up, down, left or right", tint = Palette.text, modifier = Modifier.size(22.dp)) }
}

/** What the mic hears, as bars scrolling left with the newest at the right edge. */
@Composable
private fun Waveform(levels: List<Float>, modifier: Modifier) {
    Canvas(modifier) {
        val bar = 3.dp.toPx(); val gap = 2.dp.toPx()
        val fits = ((size.width + gap) / (bar + gap)).toInt()
        var x = size.width - bar
        for (level in levels.takeLast(fits).asReversed()) {
            val h = maxOf(3.dp.toPx(), level * size.height)
            drawRoundRect(Color(0xD9E5675A), Offset(x, (size.height - h) / 2), Size(bar, h), CornerRadius(bar / 2))
            x -= bar + gap
        }
    }
}

/** The mic: tap to start, tap to stop; red while recording, a spinner while the server
 *  works, and the reason when it fails. */
@Composable
private fun DictationButton(model: PadModel, session: String) {
    val d = model.dictation
    Row(verticalAlignment = Alignment.CenterVertically) {
        (d.state as? Dictation.State.Failed)?.let {
            Text(it.message, color = Palette.secondary, fontSize = 13.sp, maxLines = 2,
                modifier = Modifier.widthIn(max = 360.dp).padding(end = 8.dp))
        }
        val recording = d.state == Dictation.State.Recording
        val pulse by rememberInfiniteTransition(label = "mic").animateFloat(1f, 0.45f,
            infiniteRepeatable(tween(700), RepeatMode.Reverse), label = "pulse")
        Box(Modifier.size(width = 72.dp, height = 52.dp).clip(RoundedCornerShape(50))
            .background(if (recording) Color(0x59E5675A) else Palette.key)
            .clickable { model.dictate(session) }, contentAlignment = Alignment.Center) {
            when (d.state) {
                Dictation.State.Transcribing -> CircularProgressIndicator(Modifier.size(22.dp), color = Palette.selection, strokeWidth = 2.dp)
                is Dictation.State.Failed -> Icon(Icons.Filled.MicOff, "Dictate", tint = Palette.selection, modifier = Modifier.size(26.dp))
                else -> Icon(Icons.Filled.Mic, if (recording) "Stop dictation" else "Dictate",
                    tint = if (recording) Palette.red else if (d.state == Dictation.State.Starting) Palette.secondary else Palette.text,
                    modifier = Modifier.size(26.dp).alpha(if (recording) pulse else 1f))
            }
        }
    }
}
