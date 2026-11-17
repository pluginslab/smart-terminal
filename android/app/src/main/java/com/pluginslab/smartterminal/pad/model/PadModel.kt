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
    /** tmux sessions on the host this device hasn't taken up yet. */
    data object Stray : TabCategory
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
    /**
     * Sessions this device has taken up: made here, opened here, or put in a group. The
     * rest (cc-super, scripts, other devices) wait under Stray. Null until the first list
     * from the host: then everything already there counts as taken up, so the lists don't
     * change under you when this arrives.
     */
    private var adopted: Set<String>? by mutableStateOf(null)
    /** Sessions being made here: taken up already, but not on the host's list yet. */
    private val creating = mutableSetOf<String>()

    var category: TabCategory by mutableStateOf(TabCategory.All)
    var selected: String? by mutableStateOf(null)
    /** Session name, or "group:<uuid>", being renamed. */
    var renaming: String? by mutableStateOf(null)
    /** Landscape: whether the groups column shows. Remembered across portrait. */
    var groupsShown: Boolean by mutableStateOf(true)
    /** Portrait, or landscape with the lists hidden: whether they're laid over the terminal. */
    var listsOpen: Boolean by mutableStateOf(false)
    /**
     * Landscape with the lists put away, as in portrait: they come back laid over the
     * terminal and go again when you pick a session. Pin puts them back beside it. Kept
     * through rotating to portrait and back (the model outlives the activity).
     */
    var listsHidden: Boolean by mutableStateOf(false)
        private set
    /** Set by the root screen from its size. */
    var portrait: Boolean by mutableStateOf(false)

    /** The lists sit over the terminal rather than beside it. */
    val overlaid: Boolean get() = portrait || listsHidden

    fun hideLists() {
        listsHidden = true
        listsOpen = false
        // Laid over, they come back as the sessions column alone, as on the iPad.
        groupsShown = false
        save()
    }

    /** Keeps what's laid over now: the sessions column, and the groups if you opened them. */
    fun pinLists() {
        listsHidden = false
        listsOpen = false
    }

    /** ⇧⌘F on a hardware keyboard (landscape): hide, then show laid over, then pin. */
    fun listsShortcut() {
        if (portrait) return
        when {
            !listsHidden -> hideLists()
            !listsOpen -> listsOpen = true
            else -> pinLists()
        }
    }

    private val panes = mutableMapOf<String, TerminalPane>()
    private val prefs = context.getSharedPreferences("padLayout", Context.MODE_PRIVATE)

    init {
        load()
        host.onList = { list -> reconcile(list.map { it.name }) }
    }

    val sessions: List<RemoteSession> get() = host.sessions

    fun sessions(c: TabCategory): List<RemoteSession> = sessions.filter { s ->
        val mine = isAdopted(s.name)
        when (c) {
            TabCategory.All -> mine
            TabCategory.Ungrouped -> mine && membership[s.name] == null
            is TabCategory.Group -> mine && membership[s.name] == c.id
            TabCategory.Stray -> !mine
        }
    }

    fun isAdopted(name: String): Boolean = adopted?.contains(name) ?: true || membership[name] != null

    /** The Move menu's "Ungrouped" for a stray session: taken up, in no group. */
    fun adoptUngrouped(name: String) = adopt(name)

    private fun adopt(name: String) {
        val a = adopted ?: return
        if (name in a) return
        adopted = a + name
        save()
    }

    /**
     * After each list from the host: the first one takes up everything there; later ones
     * forget sessions that are gone, so a new one under an old name starts stray.
     */
    private fun reconcile(names: List<String>) {
        val now = names.toSet()
        val a = adopted
        val next = if (a == null) {
            if (now.isEmpty()) return
            now
        } else {
            a.filter { it in now || it in creating }.toSet()
        }
        if (next != a) { adopted = next; save() }
        // The last stray one went away on the host: don't leave an empty list showing.
        if (category == TabCategory.Stray && sessions(TabCategory.Stray).isEmpty()) category = TabCategory.All
    }

    /** Pull to refresh on the groups column; [done] ends the spinner. */
    fun refresh(done: () -> Unit) = host.refresh(done)

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
        // Not for Stray: showing one in the terminal would take it up before you chose it.
        if (c == TabCategory.Stray) return
        val list = sessions(c)
        if (list.none { it.name == selected }) selected = list.firstOrNull()?.name
    }

    /** Opening a stray session doesn't take it up: it stays under Stray until you move it. */
    fun select(session: String) {
        selected = session
        listsOpen = false   // portrait: picking a session puts the lists away, as Mail does
    }

    fun newSession() {
        val taken = sessions.map { it.name }.toSet()
        var n = 1
        while ("android-$n" in taken) n++
        val name = "android-$n"
        // Taken up now, and kept through any list fetched before tmux has made it.
        creating += name
        adopted?.let { adopted = it + name }
        (category as? TabCategory.Group)?.let { membership = membership + (name to it.id) }
        if (category == TabCategory.Stray) category = TabCategory.Ungrouped
        save()
        host.newSession(name) { creating -= name; select(name) }
    }

    /** Kills the tmux session on the host (and whatever runs in it). Row menu only. */
    fun close(session: String) {
        // The one in front closes: the row above takes its place (below for the first).
        if (selected == session) {
            val list = sessions(category).map { it.name }
            val i = list.indexOf(session)
            val rest = list - session
            selected = if (i < 0 || rest.isEmpty()) null else rest[(i - 1).coerceIn(0, rest.size - 1)]
        }
        panes.remove(session)?.close()
        membership = membership - session
        customTitles = customTitles - session
        save()
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
        with?.let { membership = membership + (it to g.id); adopt(it) }
        category = TabCategory.Group(g.id)
        save()
    }

    fun move(session: String, to: UUID?) {
        // Taken up for good: leaving the group later shouldn't send it back to Stray.
        adopt(session)
        membership = if (to == null) membership - session else membership + (session to to)
        save()
    }

    fun updateGroup(id: UUID, name: String? = null, color: GroupColor? = null) {
        groups = groups.map { if (it.id != id) it else it.copy(name = name ?: it.name, color = color ?: it.color) }
        save()
    }

    fun deleteGroup(id: UUID) {
        // Its sessions go to Ungrouped, not Stray.
        adopted?.let { a -> adopted = a + membership.filterValues { it == id }.keys }
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
        adopted?.let { o.put("adopted", JSONArray(it.sorted())) }
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
        adopted = o.optJSONArray("adopted")?.let { a -> (0 until a.length()).map { a.getString(it) }.toSet() }
    }
}
