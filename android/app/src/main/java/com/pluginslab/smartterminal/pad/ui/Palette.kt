package com.pluginslab.smartterminal.pad.ui

import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.darkColorScheme
import androidx.compose.runtime.Composable
import androidx.compose.ui.graphics.Color
import com.pluginslab.smartterminal.pad.remote.Theme

/** "Harbor": the panels a step lighter than the terminal, in its hue (the Mac's PanelPalette). */
object Palette {
    val terminal = Color(0xFF000000 or Theme.BACKGROUND.toLong())
    val side = shade(0.040f, 0.94f)
    val list = shade(0.028f, 0.95f)
    val head = shade(0.028f, 0.95f)
    val bar = shade(-0.014f)
    val line = shade(0.12f, 0.85f)
    val text = Color(0xFFE6EDF3)
    val secondary = Color(0xFF8D9BA8)
    val tertiary = Color(0xFF5E6E7C)
    /** The selected session: Claude's amber, with dark text on it. */
    val selection = Color(0xFFE8A33D)
    val onSelection = Color(0xFF1A1205)
    val selectionSoft = selection.copy(alpha = 0.16f)
    val claudeOrange = Color(0xFFD97857)
    val green = Color(0xFF6CC070)
    val red = Color(0xFFE5675A)
    val key = Color.White.copy(alpha = 0.08f)
    /** The light edge of a glass panel or button, and the line between panes. */
    val glassEdge = Color.White.copy(alpha = 0.12f)

    private fun shade(db: Float, sat: Float = 1f): Color {
        val hsv = FloatArray(3)
        android.graphics.Color.colorToHSV(0xFF000000.toInt() or Theme.BACKGROUND, hsv)
        hsv[1] = (hsv[1] * sat).coerceAtMost(1f)
        hsv[2] = (hsv[2] + db).coerceIn(0f, 1f)
        return Color(android.graphics.Color.HSVToColor(hsv))
    }
}

@Composable
fun PadTheme(content: @Composable () -> Unit) = MaterialTheme(
    colorScheme = darkColorScheme(
        primary = Palette.selection, onPrimary = Palette.onSelection,
        background = Palette.list, surface = Palette.side, onSurface = Palette.text,
        surfaceContainer = Palette.side, surfaceContainerHigh = Palette.head,
        onSurfaceVariant = Palette.secondary, outline = Palette.line,
    ),
    content = content,
)
