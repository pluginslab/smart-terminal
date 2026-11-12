package com.pluginslab.smartterminal.pad.model

import android.content.Context
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import com.pluginslab.smartterminal.pad.dictation.Dictation
import com.pluginslab.smartterminal.pad.remote.Host
import com.pluginslab.smartterminal.pad.remote.RemoteSession
import com.pluginslab.smartterminal.pad.remote.TerminalPane
import org.json.JSONArray
import org.json.JSONObject
import java.util.UUID

/** What the left column has selected; the middle column lists its sessions. */
sealed interface TabCategory {
    data object All : TabCategory
    data object Ungrouped : TabCategory
    data class Group(val id: UUID) : TabCategory
}

/**
 * The tablet's own state around the host's tmux sessions: groups, names you gave them,
 * and which one is in front. Saved on the device. Process-scoped (lives in the
 * Application), so rotating or resizing never loses it.
 */
class PadModel(private val context: Context) {
    /** supermaschine only, as on the iPad. The LAN address covers Tailscale being off at home. */
    val host = Host(context, "supermaschine", "pluginslab", lanFallback = "192.168.1.132")
    val dictation = Dictation(context)

    var groups: List<TabGroup> by mutableStateOf(emptyList())
        private set
    /** tmux session name -> group */
    var membership: Map<String, UUID> by mutableStateOf(emptyMap())
        private set
    var customTitles: Map<String, String> by mutableStateOf(emptyMap())
        private set

    var category: TabCategory by mutableStateOf(TabCategory.All)
    var selected: String? by mutableStateOf(null)
    /** Session name, or "group:<uuid>", being renamed. */
    var renaming: String? by mutableStateOf(null)
    /** Landscape: whether the groups column shows. Remembered across portrait. */
    var groupsShown: Boolean by mutableStateOf(true)
    /** Portrait: whether the lists are laid over the terminal. */
    var listsOpen: Boolean by mutableStateOf(false)

    private val panes = mutableMapOf<String, TerminalPane>()
    private val prefs = context.getSharedPreferences("padLayout", Context.MODE_PRIVATE)

    init { load() }

    val sessions: List<RemoteSession> get() = host.sessions

    fun sessions(c: TabCategory): List<RemoteSession> = sessions.filter { s ->
        when (c) {
            TabCategory.All -> true
            TabCategory.Ungrouped -> membership[s.name] == null
            is TabCategory.Group -> membership[s.name] == c.id
        }
    }

    fun group(of: RemoteSession): TabGroup? = membership[of.name]?.let { id -> groups.firstOrNull { it.id == id } }

    fun title(of: RemoteSession): String {
        customTitles[of.name]?.takeIf { it.isNotEmpty() }?.let { return it }
        of.agentName?.let { return it }
        if (of.agent != null && of.title.isNotEmpty()) return of.title
        return of.name
    }

    fun groupTitle(g: TabGroup) = g.name.ifEmpty { "Unnamed ${g.color.displayName} Group" }

    fun pane(session: String): TerminalPane = panes.getOrPut(session) { TerminalPane(context, host, session) }

    /** Dictate into the session in front: see [Dictation]. */
    fun dictate(session: String) = dictation.toggle(host, pane(session))

    /** Back in front: reconnect, and re-attach panes whose channel ended. */
    fun resume() {
        host.reconnectIfNeeded()
        panes.values.forEach { if (it.state == TerminalPane.State.Ended) it.reattach() }
    }

    /** Picking a category shows one of its sessions, so the terminal matches the list. */
    fun pick(c: TabCategory) {
        category = c
        val list = sessions(c)
        if (list.none { it.name == selected }) selected = list.firstOrNull()?.name
    }

    fun select(session: String) {
        selected = session
        listsOpen = false   // portrait: picking a session puts the lists away, as Mail does
    }

    fun newSession() {
        val taken = sessions.map { it.name }.toSet()
        var n = 1
        while ("android-$n" in taken) n++
        val name = "android-$n"
        (category as? TabCategory.Group)?.let { membership = membership + (name to it.id); save() }
        host.newSession(name) { select(name) }
    }

    /** Kills the tmux session on the host (and whatever runs in it). Row menu only. */
    fun close(session: String) {
        panes.remove(session)?.close()
        membership = membership - session
        customTitles = customTitles - session
        save()
        if (selected == session) selected = null
        host.kill(session)
    }

    fun rename(session: String, title: String) {
        val t = title.trim()
        customTitles = if (t.isEmpty()) customTitles - session else customTitles + (session to t)
        save()
    }

    fun newGroup(with: String? = null) {
        val used = groups.map { it.color }.toSet()
        val g = TabGroup(color = GroupColor.entries.firstOrNull { it !in used } ?: GroupColor.Blue)
        groups = groups + g
        with?.let { membership = membership + (it to g.id) }
        category = TabCategory.Group(g.id)
        save()
    }

    fun move(session: String, to: UUID?) {
        membership = if (to == null) membership - session else membership + (session to to)
        save()
    }

    fun updateGroup(id: UUID, name: String? = null, color: GroupColor? = null) {
        groups = groups.map { if (it.id != id) it else it.copy(name = name ?: it.name, color = color ?: it.color) }
        save()
    }

    fun deleteGroup(id: UUID) {
        groups = groups.filter { it.id != id }
        membership = membership.filterValues { it != id }
        if (category == TabCategory.Group(id)) category = TabCategory.All
        save()
    }

    // MARK: persistence

    private fun save() {
        val o = JSONObject()
        o.put("groups", JSONArray(groups.map {
            JSONObject().put("id", it.id.toString()).put("name", it.name).put("color", it.color.name)
        }))
        o.put("membership", JSONObject(membership.mapValues { it.value.toString() }))
        o.put("customTitles", JSONObject(customTitles))
        o.put("groupsShown", groupsShown)
        prefs.edit().putString("layout", o.toString()).apply()
    }

    fun saveColumns() = save()

    private fun load() {
        val o = runCatching { JSONObject(prefs.getString("layout", null) ?: return) }.getOrNull() ?: return
        groups = o.optJSONArray("groups")?.let { a ->
            (0 until a.length()).mapNotNull { i ->
                val g = a.getJSONObject(i)
                runCatching { TabGroup(UUID.fromString(g.getString("id")), g.optString("name"), GroupColor.valueOf(g.getString("color"))) }.getOrNull()
            }
        } ?: emptyList()
        membership = o.optJSONObject("membership")?.let { m ->
            m.keys().asSequence().mapNotNull { k -> runCatching { k to UUID.fromString(m.getString(k)) }.getOrNull() }.toMap()
        } ?: emptyMap()
        customTitles = o.optJSONObject("customTitles")?.let { m -> m.keys().asSequence().associateWith { m.getString(it) } } ?: emptyMap()
        groupsShown = o.optBoolean("groupsShown", true)
    }
}
