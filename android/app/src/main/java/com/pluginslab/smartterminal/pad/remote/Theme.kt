package com.pluginslab.smartterminal.pad.remote

import androidx.core.content.res.ResourcesCompat
import com.pluginslab.smartterminal.pad.R
import com.termux.terminal.TerminalColors
import com.termux.view.TerminalView
import java.util.Properties

/** The Mac's terminal profile ("Clear Dark", FiraCode Nerd Font Mono 15), as on the iPad. */
object Theme {
    const val BACKGROUND = 0x102030
    const val TEXT = 0xC8D3DF
    private val ansi = intArrayOf(
        0x35424B, 0xB35547, 0x6CAA70, 0xC4AB62, 0x6D95B3, 0xBD7BCC, 0x7BCACD, 0xDDE5EB,
        0x465C6C, 0xDF6C59, 0x78BD7D, 0xE5C871, 0x66B5EC, 0xD389E5, 0x84DDE0, 0xE5EEF5,
    )

    private fun hex(c: Int) = "#%06x".format(c)

    init {
        val p = Properties()
        ansi.forEachIndexed { i, c -> p["color$i"] = hex(c) }
        p["foreground"] = hex(TEXT)
        p["background"] = hex(BACKGROUND)
        p["cursor"] = hex(TEXT)
        TerminalColors.COLOR_SCHEME.updateWith(p)
    }

    fun apply(view: TerminalView) {
        val ctx = view.context
        // 15 pt on the iPad; sp here, so it follows the tablet's font size setting.
        val px = (15f * ctx.resources.displayMetrics.scaledDensity).toInt()
        view.setTextSize(px)  // creates the renderer; the typeface needs it
        ResourcesCompat.getFont(ctx, R.font.firacode_regular)?.let { view.setTypeface(it) }
        view.setBackgroundColor(0xFF000000.toInt() or BACKGROUND)
    }
}
