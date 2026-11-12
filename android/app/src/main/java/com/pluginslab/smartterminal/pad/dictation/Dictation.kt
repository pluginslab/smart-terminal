package com.pluginslab.smartterminal.pad.dictation

import android.annotation.SuppressLint
import android.content.Context
import android.media.AudioFormat
import android.media.AudioRecord
import android.media.MediaRecorder
import android.os.Handler
import android.os.Looper
import android.util.Log
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateListOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import com.pluginslab.smartterminal.pad.remote.Host
import com.pluginslab.smartterminal.pad.remote.TerminalPane
import org.json.JSONObject
import java.io.ByteArrayOutputStream
import java.net.HttpURLConnection
import java.net.URL
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.util.UUID
import kotlin.math.log10
import kotlin.math.sqrt

/**
 * Dictation into the session in front, as on the iPad: record here, send the audio to the
 * Whisper server in the host's Glossa config with the glossary and the text before the
 * cursor as the prompt, and type the result into the tmux pane. Tap to start, tap to stop.
 * No settings on the device: `~/.config/glossa/config.json` and `glossary.txt` are read
 * over the SSH connection, so the Mac's Glossa, the iPad and this share one server.
 */
class Dictation(private val context: Context) {
    sealed interface State {
        data object Idle : State
        data object Starting : State
        data object Recording : State
        data object Transcribing : State
        data class Failed(val message: String) : State
    }

    var state: State by mutableStateOf(State.Idle)
        private set
    /** Recent loudness (0..1, newest last) for the key bar's waveform; cleared per recording. */
    val levels = mutableStateListOf<Float>()

    val isActive: Boolean get() = state == State.Recording || state == State.Transcribing || state == State.Starting

    /** Set by the activity: asks for the microphone, then calls back with the answer. */
    var requestMicrophone: ((granted: (Boolean) -> Unit) -> Unit)? = null

    private val main = Handler(Looper.getMainLooper())
    @Volatile private var config: Config? = null
    @Volatile private var glossary: List<String> = emptyList()
    private var configThread: Thread? = null
    private var recorder: Thread? = null
    @Volatile private var recording = false
    private val pcm = ByteArrayOutputStream()

    fun toggle(host: Host, pane: TerminalPane) = when (state) {
        State.Recording -> stop(pane)
        State.Starting, State.Transcribing -> Unit
        else -> start(host)
    }

    private fun start(host: Host) {
        state = State.Starting
        val ask = requestMicrophone
        if (ask == null) begin(host) else ask { ok -> if (ok) begin(host) else fail("Microphone access is off for Smart Terminal. Turn it on in Settings → Apps → Smart Terminal → Permissions.") }
    }

    @SuppressLint("MissingPermission")
    private fun begin(host: Host) {
        // Config and glossary while you talk: two files, one round trip.
        configThread = Thread {
            val out = host.runBlocking("cat ${Config.PATH} 2>/dev/null; echo '@@GLOSSA@@'; cat ${Config.GLOSSARY_PATH} 2>/dev/null") ?: ""
            val parts = out.split("@@GLOSSA@@\n")
            config = Config.parse(parts[0])
            glossary = if (parts.size > 1) Config.glossary(parts[1]) else emptyList()
        }.apply { start() }
        levels.clear()
        synchronized(pcm) { pcm.reset() }
        val min = AudioRecord.getMinBufferSize(RATE, AudioFormat.CHANNEL_IN_MONO, AudioFormat.ENCODING_PCM_16BIT)
        val rec = try {
            AudioRecord(MediaRecorder.AudioSource.VOICE_RECOGNITION, RATE, AudioFormat.CHANNEL_IN_MONO,
                AudioFormat.ENCODING_PCM_16BIT, maxOf(min, RATE))
        } catch (e: Exception) { fail("No microphone input."); return }
        if (rec.state != AudioRecord.STATE_INITIALIZED) { rec.release(); fail("No microphone input."); return }
        recording = true
        rec.startRecording()
        state = State.Recording
        recorder = Thread({
            val buf = ShortArray(800)   // 50 ms at 16 kHz, one waveform bar each
            // Android's voice-recognition input comes in much quieter than the iPad's (no
            // gain), so a fixed -50…0 dBFS scale barely moved. The bars follow the loudest
            // level so far instead (falling back slowly), over a -60 dBFS floor.
            var peak = -30.0
            var loudest = -120.0
            val bytes = ByteBuffer.allocate(buf.size * 2).order(ByteOrder.LITTLE_ENDIAN)
            while (recording) {
                val n = rec.read(buf, 0, buf.size)
                if (n <= 0) continue
                var sum = 0.0
                bytes.clear()
                for (i in 0 until n) { val v = buf[i] / 32768.0; sum += v * v; bytes.putShort(buf[i]) }
                synchronized(pcm) { pcm.write(bytes.array(), 0, n * 2) }
                val db = 20 * log10(maxOf(sqrt(sum / n), 1e-6))
                loudest = maxOf(loudest, db)
                peak = maxOf(db, peak - 0.05, -30.0)
                val level = ((db + 60) / (peak + 60)).coerceIn(0.0, 1.0).let { it * it }.toFloat()
                main.post { levels.add(level); if (levels.size > 400) levels.removeRange(0, levels.size - 400) }
            }
            rec.stop(); rec.release()
            Log.i(TAG, "loudest %.1f dBFS".format(loudest))
        }, "dictation-rec").apply { start() }
    }

    private fun stop(pane: TerminalPane) {
        recording = false
        recorder?.join(500)
        val samples = synchronized(pcm) { pcm.toByteArray() }
        val seconds = samples.size / 2.0 / RATE
        val before = pane.textBeforeCursor(config?.contextChars ?: 300)
        state = State.Transcribing
        Thread({
            configThread?.join(10_000)
            val c = config
            if (c == null || c.endpoint.isEmpty()) {
                main.post { fail("No dictation config on the host. Put Glossa's config.json at ~/.config/glossa/ there (endpoint, apiKey, model).") }
                return@Thread
            }
            if (seconds < c.minSeconds) { main.post { state = State.Idle }; return@Thread }
            val prompt = Config.prompt(glossary, if (c.useContext) before else null)
            try {
                val started = System.currentTimeMillis()
                val text = transcribe(c, wav(samples), prompt)
                Log.i(TAG, "transcribed in ${System.currentTimeMillis() - started} ms")
                main.post { insert(text, before, pane); state = State.Idle }
            } catch (e: Exception) {
                Log.w(TAG, "transcribe", e)
                main.post { fail(e.message ?: e.javaClass.simpleName) }
            }
        }, "dictation-send").start()
    }

    private fun insert(raw: String, before: String?, pane: TerminalPane) {
        var text = raw.trim().replace("\n", " ")
        if (text.isEmpty()) return
        // Whisper's non-speech markers: [BLANK_AUDIO], (silence), [Music] …
        if ((text.startsWith("[") && text.endsWith("]")) || (text.startsWith("(") && text.endsWith(")"))) return
        val last = before?.lastOrNull()
        if (last != null && !last.isWhitespace() && last !in "([{\"'“‘") text = " $text"
        pane.write(text)
    }

    private fun fail(message: String) {
        Log.w(TAG, "failed: $message")
        state = State.Failed(message)
        main.postDelayed({ if (state is State.Failed) state = State.Idle }, 6000)
    }

    /** One multipart POST in the OpenAI `/v1/audio/transcriptions` shape. */
    private fun transcribe(c: Config, wav: ByteArray, prompt: String): String {
        val boundary = "----SmartTerminal-${UUID.randomUUID()}"
        val conn = (URL(c.endpoint).openConnection() as HttpURLConnection).apply {
            requestMethod = "POST"; doOutput = true; connectTimeout = 15_000; readTimeout = 60_000
            setRequestProperty("Content-Type", "multipart/form-data; boundary=$boundary")
            if (c.apiKey.isNotEmpty()) setRequestProperty("Authorization", "Bearer ${c.apiKey}")
        }
        val body = ByteArrayOutputStream()
        fun field(name: String, value: String) =
            body.write("--$boundary\r\nContent-Disposition: form-data; name=\"$name\"\r\n\r\n$value\r\n".toByteArray())
        field("model", c.model)
        field("response_format", "json")
        field("temperature", "0.0")
        if (c.language.isNotEmpty()) field("language", c.language)
        if (prompt.isNotEmpty()) field("prompt", prompt)
        body.write("--$boundary\r\nContent-Disposition: form-data; name=\"file\"; filename=\"audio.wav\"\r\nContent-Type: audio/wav\r\n\r\n".toByteArray())
        body.write(wav)
        body.write("\r\n--$boundary--\r\n".toByteArray())
        conn.outputStream.use { it.write(body.toByteArray()) }
        val code = conn.responseCode
        val text = (if (code in 200..299) conn.inputStream else conn.errorStream)?.readBytes()?.toString(Charsets.UTF_8) ?: ""
        if (code !in 200..299) throw Exception("Transcription failed: HTTP $code ${text.take(120)}")
        return JSONObject(text).optString("text", null) ?: throw Exception("Transcription failed: unexpected response.")
    }

    private fun wav(pcm16: ByteArray): ByteArray {
        val b = ByteBuffer.allocate(44 + pcm16.size).order(ByteOrder.LITTLE_ENDIAN)
        b.put("RIFF".toByteArray()).putInt(36 + pcm16.size).put("WAVE".toByteArray())
        b.put("fmt ".toByteArray()).putInt(16).putShort(1).putShort(1).putInt(RATE).putInt(RATE * 2).putShort(2).putShort(16)
        b.put("data".toByteArray()).putInt(pcm16.size).put(pcm16)
        return b.array()
    }

    /** Glossa's config.json; only the keys dictation needs. */
    data class Config(
        val endpoint: String = "", val apiKey: String = "", val model: String = "whisper-1",
        val language: String = "en", val useContext: Boolean = true, val contextChars: Int = 300,
        val minSeconds: Double = 0.4,
    ) {
        companion object {
            const val PATH = "~/.config/glossa/config.json"
            const val GLOSSARY_PATH = "~/.config/glossa/glossary.txt"

            fun parse(json: String): Config? = runCatching {
                val o = JSONObject(json)
                Config(o.optString("endpoint"), o.optString("apiKey"), o.optString("model", "whisper-1"),
                    o.optString("language", "en"), o.optBoolean("useContext", true), o.optInt("contextChars", 300),
                    o.optDouble("minSeconds", 0.4))
            }.getOrNull()

            /** One term per line; `#` lines and blanks skipped (Glossa's format). */
            fun glossary(text: String) = text.split("\n").map { it.trim() }.filter { it.isNotEmpty() && !it.startsWith("#") }

            /** Vocabulary first, the text before the cursor last, so context is what gets cut. */
            fun prompt(glossary: List<String>, before: String?): String = listOfNotNull(
                glossary.takeIf { it.isNotEmpty() }?.let { "Vocabulary: " + it.joinToString(", ") + "." },
                before?.trim()?.takeIf { it.isNotEmpty() },
            ).joinToString("\n")
        }
    }

    companion object {
        private const val TAG = "Dictation"
        private const val RATE = 16_000
    }
}
