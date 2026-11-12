package com.pluginslab.smartterminal.pad.remote

import android.content.ClipData
import android.content.ClipboardManager
import android.content.Context
import android.os.Handler
import android.os.Looper
import android.util.Log
import android.view.KeyEvent
import android.view.MotionEvent
import android.view.ViewGroup
import android.view.inputmethod.InputMethodManager
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import com.termux.terminal.TerminalSession
import com.termux.terminal.TerminalSessionClient
import com.termux.view.TerminalView
import com.termux.view.TerminalViewClient
import net.schmizz.sshj.connection.channel.direct.Session
import net.schmizz.sshj.connection.channel.direct.SessionChannel
import java.io.OutputStream
import java.util.concurrent.Executors

/**
 * One tab's terminal: Termux's view fed by an SSH shell channel that runs
 * `tmux new-session -A -s <session>` on the host. Lives as long as the process, not the
 * activity, so rotating or resizing the window keeps the screen and the connection.
 */
class TerminalPane(private val appContext: Context, private val host: Host, val session: String) {
    enum class State { Idle, Attaching, Attached, Ended }

    var state by mutableStateOf(State.Idle)
        private set
    var lastError: String? by mutableStateOf(null)
        private set

    private val main = Handler(Looper.getMainLooper())
    /** Writes and resizes go out in order, off the main thread. Never blocks on reading:
     *  the read loop has its own thread, or it would hold this one forever. */
    private val io = Executors.newSingleThreadExecutor()
    @Volatile private var sshSession: Session? = null
    @Volatile private var shell: Session.Command? = null
    @Volatile private var out: OutputStream? = null
    private var size: Pair<Int, Int>? = null

    private val transport = object : TerminalSession.Transport {
        override fun write(data: ByteArray, offset: Int, count: Int) {
            val copy = data.copyOfRange(offset, offset + count)
            io.execute { runCatching { out?.apply { write(copy); flush() } } }
        }

        override fun resize(columns: Int, rows: Int) {
            val first = size == null
            size = columns to rows
            if (first && state == State.Idle) attach()
            // The real size, whenever it changes, including right after the channel opens
            // (the iPad lesson: tmux drew wider than the screen when this was missed).
            io.execute { runCatching { (sshSession as? SessionChannel)?.changeWindowDimensions(columns, rows, 0, 0) } }
        }
    }

    val terminal = TerminalSession(transport, 10_000, SessionClient())

    val view: TerminalView = TerminalView(appContext, null).apply {
        setTerminalViewClient(ViewClient())
        Theme.apply(this)
        isFocusable = true
        isFocusableInTouchMode = true
        attachSession(terminal)
    }

    /** Takes the view out of whatever held it last (a previous layout after rotation). */
    fun detachedView(): TerminalView = view.also { (it.parent as? ViewGroup)?.removeView(it) }

    /** Starts the channel once the view knows its size. */
    fun attach() {
        if (state == State.Attaching || state == State.Attached) return
        val (cols, rows) = size ?: return
        state = State.Attaching
        Thread({
            try {
                val c = host.connectBlocking()
                val s = c.startSession()
                s.allocatePTY("xterm-256color", cols, rows, 0, 0, emptyMap())
                // A login shell first, so a tmux server started here gets the user's PATH.
                val cmd = s.exec("exec \"\$SHELL\" -lc " + Host.quote("exec tmux new-session -A -s " + Host.quote(session)))
                sshSession = s
                shell = cmd
                out = cmd.outputStream
                // Whatever size the view has now, on the writer thread so it stays in order.
                io.execute { size?.let { (w, h) -> runCatching { (s as SessionChannel).changeWindowDimensions(w, h, 0, 0) } } }
                main.post { lastError = null; state = State.Attached }
                val input = cmd.inputStream
                val buf = ByteArray(16 * 1024)
                while (true) {
                    val n = input.read(buf)
                    if (n < 0) break
                    val chunk = buf.copyOf(n)
                    main.post { terminal.feed(chunk, chunk.size) }
                }
            } catch (e: Exception) {
                Log.w(TAG, "attach $session", e)
                main.post { lastError = e.message ?: e.javaClass.simpleName }
            }
            runCatching { sshSession?.close() }
            sshSession = null; shell = null; out = null
            main.post { state = State.Ended }
        }, "ssh-read-$session").start()
    }

    /** Back after the connection dropped: open a new channel. */
    fun reattach() {
        if (state == State.Ended || state == State.Idle) { state = State.Idle; attach() }
    }

    fun write(text: String) = terminal.write(text)

    /** An arrow key, in the form the program in front asked for (application cursor mode). */
    fun arrow(direction: Char) {
        val app = terminal.emulator?.isCursorKeysApplicationMode == true
        write((if (app) "\u001bO" else "\u001b[") + direction)
    }

    /** The cursor's line before the cursor, for Whisper's prompt: in a Claude Code prompt
     *  box that is the sentence being dictated so far. */
    fun textBeforeCursor(maxChars: Int): String? {
        val e = terminal.emulator ?: return null
        val x = e.cursorCol
        if (x <= 0) return null
        val text = e.screen.getSelectedText(0, e.cursorRow, x - 1, e.cursorRow).trimEnd()
        return text.takeLast(maxChars).ifEmpty { null }
    }

    /** The session went away on the host: stop reading. */
    fun close() {
        runCatching { sshSession?.close() }
        io.shutdown()
    }

    fun showKeyboard() {
        view.requestFocus()
        appContext.getSystemService(InputMethodManager::class.java).showSoftInput(view, 0)
    }

    private inner class SessionClient : TerminalSessionClient {
        override fun onTextChanged(changedSession: TerminalSession) = view.onScreenUpdated()
        override fun onTitleChanged(changedSession: TerminalSession) {}
        override fun onSessionFinished(finishedSession: TerminalSession) {}
        override fun onCopyTextToClipboard(session: TerminalSession, text: String) {
            appContext.getSystemService(ClipboardManager::class.java).setPrimaryClip(ClipData.newPlainText("terminal", text))
        }
        override fun onPasteTextFromClipboard(session: TerminalSession?) {
            val clip = appContext.getSystemService(ClipboardManager::class.java).primaryClip ?: return
            val text = clip.getItemAt(0)?.coerceToText(appContext)?.toString() ?: return
            terminal.emulator?.paste(text)
        }
        override fun onBell(session: TerminalSession) {}
        override fun onColorsChanged(session: TerminalSession) {}
        override fun onTerminalCursorStateChange(state: Boolean) {}
        override fun getTerminalCursorStyle(): Int? = null
        override fun logError(tag: String?, message: String?) { Log.e(tag, message ?: "") }
        override fun logWarn(tag: String?, message: String?) { Log.w(tag, message ?: "") }
        override fun logInfo(tag: String?, message: String?) {}
        override fun logDebug(tag: String?, message: String?) {}
        override fun logVerbose(tag: String?, message: String?) {}
        override fun logStackTraceWithMessage(tag: String?, message: String?, e: Exception?) { Log.e(tag, message, e) }
        override fun logStackTrace(tag: String?, e: Exception?) { Log.e(tag, "", e) }
    }

    private inner class ViewClient : TerminalViewClient {
        private var scale = 1f
        override fun onScale(scale: Float): Float = 1f
        /** Only a tap on the terminal raises the keyboard (never picking a session). */
        override fun onSingleTapUp(e: MotionEvent?) = showKeyboard()
        override fun shouldBackButtonBeMappedToEscape() = false
        /** Plain characters from the IME: no autocorrect or composing over a terminal. */
        override fun shouldEnforceCharBasedInput() = true
        override fun shouldUseCtrlSpaceWorkaround() = false
        override fun isTerminalViewSelected() = true
        override fun copyModeChanged(copyMode: Boolean) {}
        override fun onKeyDown(keyCode: Int, e: KeyEvent?, session: TerminalSession?) = false
        override fun onKeyUp(keyCode: Int, e: KeyEvent?) = false
        override fun onLongPress(event: MotionEvent?) = false
        override fun readControlKey() = false
        override fun readAltKey() = false
        override fun readShiftKey() = false
        override fun readFnKey() = false
        override fun onCodePoint(codePoint: Int, ctrlDown: Boolean, session: TerminalSession?) = false
        override fun onEmulatorSet() {}
        override fun logError(tag: String?, message: String?) { Log.e(tag, message ?: "") }
        override fun logWarn(tag: String?, message: String?) { Log.w(tag, message ?: "") }
        override fun logInfo(tag: String?, message: String?) {}
        override fun logDebug(tag: String?, message: String?) {}
        override fun logVerbose(tag: String?, message: String?) {}
        override fun logStackTraceWithMessage(tag: String?, message: String?, e: Exception?) { Log.e(tag, message, e) }
        override fun logStackTrace(tag: String?, e: Exception?) { Log.e(tag, "", e) }
    }

    companion object { private const val TAG = "TerminalPane" }
}
