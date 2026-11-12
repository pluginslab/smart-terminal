package com.pluginslab.smartterminal.pad.remote

import android.content.Context
import android.os.Handler
import android.os.Looper
import android.util.Base64
import android.util.Log
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import com.pluginslab.smartterminal.pad.model.AgentStatus
import com.pluginslab.smartterminal.pad.model.ClaudeSessionRecord
import com.pluginslab.smartterminal.pad.model.ClaudeTitle
import com.pluginslab.smartterminal.pad.model.GitStatus
import net.schmizz.sshj.DefaultConfig
import net.schmizz.sshj.SSHClient
import net.schmizz.sshj.common.Buffer
import net.schmizz.sshj.transport.verification.HostKeyVerifier
import net.schmizz.sshj.userauth.keyprovider.KeyPairWrapper
import java.net.InetAddress
import java.security.PublicKey
import java.util.concurrent.TimeUnit

/** A tmux session on the host: one tab. */
data class RemoteSession(
    val name: String,
    /** The active pane's folder, command and title. */
    val path: String,
    val command: String,
    val title: String,
    val panePid: Int,
    val lastActivity: Long,
    val attachedClients: Int,
    val agent: AgentStatus? = null,
    val agentName: String? = null,
)

/**
 * The SSH connection to the host and what its tmux has, refreshed every few seconds. One
 * connection carries the status commands and every tab's shell channel, as on the iPad.
 */
class Host(private val context: Context, val address: String, val user: String, private val lanFallback: String?) {
    sealed interface State {
        data object Idle : State
        data object Connecting : State
        data object Connected : State
        data class Failed(val message: String) : State
    }

    var state: State by mutableStateOf(State.Idle)
        private set
    var sessions: List<RemoteSession> by mutableStateOf(emptyList())
        private set
    var git: Map<String, GitStatus> by mutableStateOf(emptyMap())
        private set

    val displayName: String get() = address.substringBefore('.')

    @Volatile private var client: SSHClient? = null
    private val main = Handler(Looper.getMainLooper())
    @Volatile private var poller: Thread? = null

    /** Connects in the background and starts polling; no-op while connected or connecting. */
    fun connect() {
        if (state == State.Connecting || (state == State.Connected && client?.isConnected == true)) return
        state = State.Connecting
        Thread({
            try {
                connectBlocking()
                main.post { state = State.Connected; startPolling() }
            } catch (e: Exception) {
                Log.w(TAG, "connect", e)
                main.post { state = State.Failed(describe(e)) }
            }
        }, "ssh-connect").start()
    }

    /** Android may cut the socket while the app is away; come back with a new one. */
    fun reconnectIfNeeded() {
        if (client?.isConnected != true) { client = null; if (state == State.Connected) state = State.Idle; connect() }
    }

    /** Blocking; returns the live client, connecting first if needed. */
    @Synchronized
    fun connectBlocking(): SSHClient {
        client?.let { if (it.isConnected && it.isAuthenticated) return it }
        client = null
        val c = SSHClient(DefaultConfig())
        c.addHostKeyVerifier(PinnedHostKey(context, address))
        c.connectTimeout = 10_000
        c.connect(resolve())
        try {
            c.authPublickey(user, KeyPairWrapper(DeviceKey.keyPair(context)))
        } catch (e: Exception) {
            runCatching { c.disconnect() }
            throw RefusedKey()
        }
        c.connection.keepAlive.keepAliveInterval = 15
        client = c
        return c
    }

    private fun startPolling() {
        poller?.interrupt()
        poller = Thread({
            var tick = 0
            try {
                while (!Thread.currentThread().isInterrupted) {
                    val list = refreshList()
                    if (list == null) {
                        main.post { if (client?.isConnected != true) state = State.Idle }
                        break
                    }
                    if (tick++ % 3 == 0) refreshGitBlocking(list)
                    Thread.sleep(3000)
                }
            } catch (_: InterruptedException) {}
        }, "ssh-poll").apply { isDaemon = true; start() }
    }

    // MARK: commands

    /** Output of a command, or null when it failed. Blocking. */
    fun runBlocking(command: String): String? = runCatching {
        val c = client ?: return null
        c.startSession().use { s ->
            val cmd = s.exec(command)
            val out = cmd.inputStream.readBytes().toString(Charsets.UTF_8)
            cmd.join(10, TimeUnit.SECONDS)
            out
        }
    }.getOrNull()

    /** Runs in the background, then refreshes the list. */
    fun runThenRefresh(command: String, then: (() -> Unit)? = null) {
        Thread({
            runBlocking(command)
            refreshBlocking()
            then?.let { main.post(it) }
        }, "ssh-cmd").start()
    }

    fun newSession(name: String, then: () -> Unit) = runThenRefresh("tmux new-session -d -s ${quote(name)}", then)
    fun kill(session: String) = runThenRefresh("tmux kill-session -t ${quote("=$session")}")

    // MARK: status

    fun refreshBlocking(): Boolean = refreshList() != null

    /** The session list (also published to [sessions]), or null when the host is gone. */
    private fun refreshList(): List<RemoteSession>? {
        val out = runBlocking("sh -c " + quote(STATUS_SCRIPT)) ?: return null
        val parts = out.split("$SEP\n")
        if (parts.size != 3) return sessions
        val parents = parseParents(parts[1])
        val claude = parts[2].split("\n").mapNotNull { if (it.isBlank()) null else ClaudeSessionRecord.parse(it) }
        val now = System.currentTimeMillis()
        val list = parts[0].split("\n").mapNotNull { line ->
            val f = line.split("\t", limit = 9)
            if (f.size < 8 || f[1] != "1" || f[2] != "1") return@mapNotNull null
            val pid = f[5].toIntOrNull() ?: return@mapNotNull null
            var s = RemoteSession(
                name = f[0], path = f[3], command = f[4], title = f.getOrElse(8) { "" }, panePid = pid,
                lastActivity = (f[6].toLongOrNull() ?: 0) * 1000, attachedClients = f[7].toIntOrNull() ?: 0,
            )
            ClaudeTitle.parse(s.title)?.let { (st, t) -> s = s.copy(agent = st, title = t) }
            val record = claude.firstOrNull { isDescendant(it.pid, pid, parents) }
            val st = record?.takeUnless { it.isStale(now) }?.agentStatus
            if (record != null && st != null) {
                // Only the file knows a dialog is waiting for an answer.
                s = s.copy(agent = if (st == AgentStatus.Waiting || s.agent == null) st else s.agent,
                    agentName = record.meaningfulName)
            }
            s
        }.sortedWith(compareBy(String.CASE_INSENSITIVE_ORDER) { it.name })
        main.post { sessions = list }
        return list
    }

    private fun refreshGitBlocking(list: List<RemoteSession>) {
        val paths = list.map { it.path }.toSortedSet()
        if (paths.isEmpty()) return
        val script = "export GIT_OPTIONAL_LOCKS=0\n" + paths.joinToString("\n") { p ->
            val q = quote(p)
            "echo '$SEP'; echo $q\nif git -C $q status --porcelain=v2 --branch 2>/dev/null; then echo '@@STAT@@'; git -C $q diff --shortstat HEAD 2>/dev/null; fi"
        } + "\ntrue"
        val out = runBlocking("sh -c " + quote(script)) ?: return
        val result = mutableMapOf<String, GitStatus>()
        for (chunk in out.split("$SEP\n").drop(1)) {
            val nl = chunk.indexOf('\n')
            if (nl < 0 || !chunk.contains("@@STAT@@")) continue
            val body = chunk.substring(nl + 1).split("@@STAT@@\n")
            val status = GitStatus.parsePorcelainV2(body[0])
            if (body.size > 1) GitStatus.parseShortstat(body[1]).let { (i, d) -> status.insertions = i; status.deletions = d }
            result[chunk.substring(0, nl)] = status
        }
        main.post { git = result }
    }

    /** `supermaschine` resolves only with Tailscale on; at home the LAN address works too. */
    private fun resolve(): String = runCatching { InetAddress.getByName(address); address }
        .getOrElse { lanFallback ?: throw it }

    class RefusedKey : Exception("The host refused this tablet's key. Add it to ~/.ssh/authorized_keys.")

    companion object {
        private const val TAG = "Host"
        private const val SEP = "@@ST@@"

        /** One round trip: every session's front pane, the process tree, Claude's session files. */
        private val STATUS_SCRIPT = """
            tmux list-panes -a -F '#{session_name}	#{window_active}	#{pane_active}	#{pane_current_path}	#{pane_current_command}	#{pane_pid}	#{session_activity}	#{session_attached}	#{pane_title}' 2>/dev/null
            echo '$SEP'
            ps -eo pid=,ppid=
            echo '$SEP'
            for f in "${'$'}HOME"/.claude/sessions/*.json; do [ -f "${'$'}f" ] && cat "${'$'}f" && echo; done
            true
        """.trimIndent()

        fun quote(s: String) = "'" + s.replace("'", "'\\''") + "'"

        fun describe(e: Throwable): String = when {
            e is RefusedKey -> e.message!!
            e is java.net.UnknownHostException -> "Can't find the host. Is Tailscale on?"
            e is java.net.ConnectException || e is java.net.SocketTimeoutException -> "The host didn't answer. Is Tailscale on?"
            else -> e.message ?: e.javaClass.simpleName
        }

        private fun parseParents(ps: String): Map<Int, Int> = ps.split("\n").mapNotNull { line ->
            val f = line.trim().split(Regex("\\s+"))
            if (f.size == 2) f[0].toIntOrNull()?.let { p -> f[1].toIntOrNull()?.let { p to it } } else null
        }.toMap()

        private fun isDescendant(pid: Int, root: Int, parents: Map<Int, Int>): Boolean {
            var p = pid
            repeat(12) {
                if (p == root) return true
                val next = parents[p] ?: return false
                if (next <= 1) return false
                p = next
            }
            return false
        }
    }
}

/** Trust on first use: the host's key is remembered the first time and must match after. */
class PinnedHostKey(context: Context, private val host: String) : HostKeyVerifier {
    private val prefs = context.getSharedPreferences("hostKeys", Context.MODE_PRIVATE)

    override fun verify(hostname: String, port: Int, key: PublicKey): Boolean {
        val seen = Base64.encodeToString(Buffer.PlainBuffer().putPublicKey(key).compactData, Base64.NO_WRAP)
        val pinned = prefs.getString(host, null)
        if (pinned == null) {
            prefs.edit().putString(host, seen).apply()
            return true
        }
        return pinned == seen
    }

    override fun findExistingAlgorithms(hostname: String, port: Int): List<String> = emptyList()
}
