package com.pluginslab.smartterminal.pad.model

import org.json.JSONObject
import java.util.UUID

// Kotlin port of the parts of SmartTerminalCore (Swift) the tablet apps use. Keep in step
// with Sources/SmartTerminalCore/{ClaudeCode,GitStatus,Model}.swift; the tests mirror the
// Swift tests case for case.

/** What a Claude Code session in a pane is doing. */
enum class AgentStatus { Busy, Idle, Waiting }

/** Claude Code's terminal title: "◐ <title>" while busy, "✳ <title>" when idle. */
object ClaudeTitle {
    private val busyGlyphs = setOf("◐", "◓", "◑", "◒", "⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏",
        "·", "✢", "✶", "✻", "✽")
    private val idleGlyphs = setOf("✳")

    /** Null when the title doesn't start with Claude's glyph (another program's title). */
    fun parse(raw: String): Pair<AgentStatus, String>? {
        val t = raw.trim()
        if (t.isEmpty()) return null
        val first = String(Character.toChars(t.codePointAt(0)))
        val status = when (first) {
            in idleGlyphs -> AgentStatus.Idle
            in busyGlyphs -> AgentStatus.Busy
            else -> return null
        }
        return status to t.substring(first.length).trim()
    }
}

/** `~/.claude/sessions/<pid>.json` */
data class ClaudeSessionRecord(
    val pid: Int,
    val sessionId: String,
    val cwd: String? = null,
    val status: String? = null,
    val name: String? = null,
    val nameSource: String? = null,
    val statusUpdatedAt: Double? = null,
    val parkedJobId: String? = null,
) {
    /** Parked, or no status change in 10 minutes: the file no longer tracks the process. */
    fun isStale(nowMillis: Long): Boolean {
        if (parkedJobId != null) return true
        val at = statusUpdatedAt ?: return false
        return nowMillis / 1000.0 - at / 1000 > 600
    }

    /** "shell" means Claude is running a `!` command: still working. */
    val agentStatus: AgentStatus?
        get() = when (status) {
            "busy", "shell" -> AgentStatus.Busy
            "idle" -> AgentStatus.Idle
            "waiting" -> AgentStatus.Waiting
            else -> null
        }

    /** Names Claude derives itself ("smart-terminal-92") are folder + noise. */
    val meaningfulName: String?
        get() {
            val n = name ?: return null
            if (n.isEmpty() || nameSource == "derived") return null
            return n.trim { it == '"' || it.isWhitespace() }
        }

    companion object {
        fun parse(json: String): ClaudeSessionRecord? = runCatching {
            val o = JSONObject(json)
            fun str(k: String) = if (o.has(k) && !o.isNull(k)) o.getString(k) else null
            ClaudeSessionRecord(
                pid = o.getInt("pid"),
                sessionId = o.getString("sessionId"),
                cwd = str("cwd"), status = str("status"), name = str("name"), nameSource = str("nameSource"),
                statusUpdatedAt = if (o.has("statusUpdatedAt")) o.optDouble("statusUpdatedAt") else null,
                parkedJobId = str("parkedJobId"),
            )
        }.getOrNull()
    }
}

/** A working copy's state as a row shows it. */
data class GitStatus(
    var branch: String? = null,
    var commit: String? = null,
    var hasUpstream: Boolean = false,
    var ahead: Int = 0,
    var behind: Int = 0,
    var changedFiles: Int = 0,
    var untrackedFiles: Int = 0,
    var insertions: Int = 0,
    var deletions: Int = 0,
) {
    val isClean: Boolean get() = changedFiles == 0 && untrackedFiles == 0

    companion object {
        /** `git status --porcelain=v2 --branch` */
        fun parsePorcelainV2(output: String): GitStatus {
            val s = GitStatus()
            for (line in output.split("\n")) {
                when {
                    line.startsWith("# branch.oid ") -> {
                        val oid = line.removePrefix("# branch.oid ")
                        if (oid != "(initial)") s.commit = oid.take(7)
                    }
                    line.startsWith("# branch.head ") -> {
                        val head = line.removePrefix("# branch.head ")
                        s.branch = if (head == "(detached)") null else head
                    }
                    line.startsWith("# branch.upstream ") -> s.hasUpstream = true
                    line.startsWith("# branch.ab ") -> for (part in line.removePrefix("# branch.ab ").split(" ")) {
                        if (part.startsWith("+")) s.ahead = part.drop(1).toIntOrNull() ?: 0
                        if (part.startsWith("-")) s.behind = part.drop(1).toIntOrNull() ?: 0
                    }
                    line.startsWith("1 ") || line.startsWith("2 ") || line.startsWith("u ") -> s.changedFiles++
                    line.startsWith("? ") -> s.untrackedFiles++
                }
            }
            return s
        }

        /** `git diff --shortstat`: insertions and deletions. */
        fun parseShortstat(output: String): Pair<Int, Int> {
            var ins = 0
            var del = 0
            for (part in output.split(",")) {
                val words = part.trim().split(" ").filter { it.isNotEmpty() }
                val n = words.firstOrNull()?.toIntOrNull() ?: continue
                if (words.size < 2) continue
                if (words[1].startsWith("insertion")) ins = n
                if (words[1].startsWith("deletion")) del = n
            }
            return ins to del
        }
    }
}

/** The nine Chrome tab-group colours, dark variant (the panels are always dark here). */
enum class GroupColor(val argb: Long) {
    Grey(0xFFDADCE0), Blue(0xFF8AB4F8), Red(0xFFF28B82), Yellow(0xFFFDD663), Green(0xFF81C995),
    Pink(0xFFFF8BCB), Purple(0xFFC58AF9), Cyan(0xFF78D9EC), Orange(0xFFFCAD70);

    val displayName: String get() = name
}

data class TabGroup(val id: UUID = UUID.randomUUID(), val name: String = "", val color: GroupColor)
