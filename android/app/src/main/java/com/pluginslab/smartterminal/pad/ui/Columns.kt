package com.pluginslab.smartterminal.pad.ui

import androidx.compose.animation.core.LinearEasing
import androidx.compose.animation.core.RepeatMode
import androidx.compose.animation.core.animateFloat
import androidx.compose.animation.core.infiniteRepeatable
import androidx.compose.animation.core.rememberInfiniteTransition
import androidx.compose.animation.core.tween
import androidx.compose.foundation.ExperimentalFoundationApi
import androidx.compose.foundation.background
import androidx.compose.foundation.combinedClickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.navigationBars
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.statusBars
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.windowInsetsPadding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.itemsIndexed
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.CallSplit
import androidx.compose.material.icons.filled.Add
import androidx.compose.material.icons.filled.Check
import androidx.compose.material.icons.filled.Dns
import androidx.compose.material.icons.filled.Layers
import androidx.compose.material.icons.filled.Terminal
import androidx.compose.material.icons.outlined.ViewSidebar
import androidx.compose.material.icons.filled.Error
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.rotate
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.pluginslab.smartterminal.pad.model.AgentStatus
import com.pluginslab.smartterminal.pad.model.GitStatus
import com.pluginslab.smartterminal.pad.model.GroupColor
import com.pluginslab.smartterminal.pad.model.PadModel
import com.pluginslab.smartterminal.pad.model.TabCategory
import com.pluginslab.smartterminal.pad.model.TabGroup
import com.pluginslab.smartterminal.pad.remote.Host
import com.pluginslab.smartterminal.pad.remote.RemoteSession

// MARK: - Groups column

@Composable
fun GroupsColumn(model: PadModel, modifier: Modifier) {
    val all = model.sessions
    val ungrouped = model.sessions(TabCategory.Ungrouped)
    Column(modifier.background(Palette.side).windowInsetsPadding(WindowInsets.statusBars)) {
        LazyColumn(Modifier.weight(1f).padding(horizontal = 10.dp), contentPadding = androidx.compose.foundation.layout.PaddingValues(top = 14.dp, bottom = 6.dp)) {
            item { HostBadge(model.host) }
            item {
                CategoryRow("All Sessions", RowIcon.Symbol(Icons.Filled.Layers), all.map { it.agent },
                    selected = model.category == TabCategory.All) { model.pick(TabCategory.All) }
            }
            item {
                Text("Groups", color = Palette.secondary, fontSize = 14.sp, fontWeight = FontWeight.SemiBold,
                    modifier = Modifier.padding(start = 8.dp, top = 14.dp, bottom = 2.dp))
            }
            model.groups.forEach { g ->
                item(g.id.toString()) {
                    var menu by remember { mutableStateOf(false) }
                    Box {
                        CategoryRow(model.groupTitle(g), RowIcon.Dot(Color(g.color.argb)),
                            model.sessions(TabCategory.Group(g.id)).map { it.agent },
                            selected = model.category == TabCategory.Group(g.id), dimmed = g.name.isEmpty(),
                            onLongClick = { menu = true }) { model.pick(TabCategory.Group(g.id)) }
                        GroupMenu(model, g, menu) { menu = false }
                    }
                }
            }
            if (ungrouped.isNotEmpty()) item {
                CategoryRow("Ungrouped", RowIcon.Symbol(Icons.Filled.Terminal), ungrouped.map { it.agent },
                    selected = model.category == TabCategory.Ungrouped) { model.pick(TabCategory.Ungrouped) }
            }
        }
        TextButton({ model.newGroup() }, Modifier.padding(horizontal = 6.dp, vertical = 4.dp)
            .windowInsetsPadding(WindowInsets.navigationBars)) {
            Icon(Icons.Filled.Add, null, Modifier.size(18.dp)); Spacer(Modifier.width(6.dp)); Text("New Group")
        }
    }
}

@Composable
private fun HostBadge(host: Host) {
    val color = when (host.state) {
        Host.State.Connected -> Palette.green
        Host.State.Connecting -> Palette.selection
        else -> Palette.red
    }
    Row(Modifier.fillMaxWidth().padding(start = 8.dp, end = 8.dp, bottom = 10.dp), verticalAlignment = Alignment.CenterVertically) {
        Icon(Icons.Filled.Dns, null, tint = Palette.secondary, modifier = Modifier.size(18.dp))
        Spacer(Modifier.width(6.dp))
        Text(host.displayName, color = Palette.text, fontWeight = FontWeight.SemiBold, fontSize = 15.sp, modifier = Modifier.weight(1f))
        Box(Modifier.size(7.dp).clip(CircleShape).background(color))
    }
}

@Composable
private fun GroupMenu(model: PadModel, g: TabGroup, open: Boolean, dismiss: () -> Unit) {
    var colors by remember { mutableStateOf(false) }
    DropdownMenu(open, dismiss, containerColor = Palette.head) {
        DropdownMenuItem({ Text("Color…") }, { colors = true; dismiss() })
        DropdownMenuItem({ Text("Rename…") }, { model.renaming = "group:${g.id}"; dismiss() })
        DropdownMenuItem({ Text("Ungroup", color = Palette.red) }, { model.deleteGroup(g.id); dismiss() })
    }
    DropdownMenu(colors, { colors = false }, containerColor = Palette.head) {
        GroupColor.entries.forEach { c ->
            DropdownMenuItem(
                { Text(c.displayName) },
                { model.updateGroup(g.id, color = c); colors = false },
                leadingIcon = { Box(Modifier.size(11.dp).clip(CircleShape).background(Color(c.argb))) },
            )
        }
    }
}

private sealed interface RowIcon {
    data class Symbol(val icon: ImageVector) : RowIcon
    data class Dot(val color: Color) : RowIcon
}

@OptIn(ExperimentalFoundationApi::class)
@Composable
private fun CategoryRow(
    title: String, icon: RowIcon, agents: List<AgentStatus?>, selected: Boolean, dimmed: Boolean = false,
    onLongClick: (() -> Unit)? = null, onClick: () -> Unit,
) {
    Row(
        Modifier.fillMaxWidth().heightIn(min = 44.dp).clip(RoundedCornerShape(9.dp))
            .background(if (selected) Palette.selectionSoft else Color.Transparent)
            .combinedClickable(onLongClick = onLongClick, onClick = onClick)
            .padding(horizontal = 10.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Box(Modifier.width(22.dp), contentAlignment = Alignment.Center) {
            when (icon) {
                is RowIcon.Symbol -> Icon(icon.icon, null, tint = Palette.secondary, modifier = Modifier.size(18.dp))
                is RowIcon.Dot -> Box(Modifier.size(11.dp).clip(CircleShape).background(icon.color))
            }
        }
        Spacer(Modifier.width(8.dp))
        Text(title, color = if (dimmed) Palette.secondary else Palette.text, fontSize = 15.sp, maxLines = 1,
            overflow = TextOverflow.Ellipsis, modifier = Modifier.weight(1f))
        if (agents.any { it == AgentStatus.Waiting }) {
            Box(Modifier.size(7.dp).clip(CircleShape).background(Palette.claudeOrange)); Spacer(Modifier.width(6.dp))
        }
        Text("${agents.size}", color = Palette.secondary, fontSize = 14.sp)
    }
}

// MARK: - Sessions column

@Composable
fun SessionsColumn(model: PadModel, portrait: Boolean, modifier: Modifier) {
    val list = model.sessions(model.category)
    Column(modifier.background(Palette.list).windowInsetsPadding(WindowInsets.statusBars)) {
        Row(Modifier.fillMaxWidth().height(64.dp).padding(start = 12.dp, end = 12.dp), verticalAlignment = Alignment.CenterVertically) {
            // The groups column's toggle, amber while it shows.
            HeaderButton(Icons.Outlined.ViewSidebar, if (model.groupsShown) "Hide Groups" else "Show Groups",
                tint = if (model.groupsShown) Palette.selection else Palette.text) {
                model.groupsShown = !model.groupsShown; model.saveColumns()
            }
            Spacer(Modifier.width(10.dp))
            Column(Modifier.weight(1f)) {
                Text(categoryTitle(model), color = Palette.text, fontSize = 20.sp, fontWeight = FontWeight.Bold, maxLines = 1, overflow = TextOverflow.Ellipsis)
                Text(if (list.size == 1) "1 session" else "${list.size} sessions", color = Palette.secondary, fontSize = 14.sp)
            }
            HeaderButton(Icons.Filled.Add, "New Session") { model.newSession() }
        }
        LazyColumn(Modifier.weight(1f).padding(horizontal = 10.dp),
            contentPadding = androidx.compose.foundation.layout.PaddingValues(top = 4.dp, bottom = 8.dp)) {
            itemsIndexed(list, key = { _, s -> s.name }) { i, s ->
                val active = model.selected == s.name
                SessionRow(model, s, showGroup = model.category == TabCategory.All, isActive = active)
                if (i + 1 < list.size && !active && model.selected != list[i + 1].name) {
                    HorizontalDivider(Modifier.padding(horizontal = 12.dp), color = Palette.line, thickness = 0.5.dp)
                }
            }
        }
    }
}

private fun categoryTitle(model: PadModel) = when (val c = model.category) {
    TabCategory.All -> "All Sessions"
    TabCategory.Ungrouped -> "Ungrouped"
    is TabCategory.Group -> model.groups.firstOrNull { it.id == c.id }?.let(model::groupTitle) ?: ""
}

/** A Mail-style row: title, then folder with git state, then what runs there. */
@OptIn(ExperimentalFoundationApi::class)
@Composable
private fun SessionRow(model: PadModel, s: RemoteSession, showGroup: Boolean, isActive: Boolean) {
    var menu by remember { mutableStateOf(false) }
    var moveMenu by remember { mutableStateOf(false) }
    val group = model.group(s)
    val fg = if (isActive) Palette.onSelection else Palette.text
    val dim = if (isActive) Palette.onSelection.copy(alpha = 0.8f) else Palette.secondary
    val dimmer = if (isActive) Palette.onSelection.copy(alpha = 0.7f) else Palette.tertiary
    Box {
        Row(
            Modifier.fillMaxWidth().heightIn(min = 72.dp).clip(RoundedCornerShape(10.dp))
                .background(if (isActive) Palette.selection else Color.Transparent)
                .combinedClickable(onLongClick = { menu = true }) { model.select(s.name) }
                .padding(horizontal = 12.dp, vertical = 10.dp),
        ) {
            if (showGroup && group != null) {
                Box(Modifier.width(3.dp).height(52.dp).clip(RoundedCornerShape(2.dp)).background(Color(group.color.argb)))
                Spacer(Modifier.width(8.dp))
            }
            Column(verticalArrangement = Arrangement.spacedBy(3.dp)) {
                Row(verticalAlignment = Alignment.CenterVertically) {
                    s.agent?.let { ClaudeGlyph(it, onAccent = isActive); Spacer(Modifier.width(6.dp)) }
                    Text(model.title(s), color = fg, fontSize = 16.sp, fontWeight = FontWeight.SemiBold, maxLines = 1,
                        overflow = TextOverflow.Ellipsis, modifier = Modifier.weight(1f))
                    Text(relative(s.lastActivity), color = dim, fontSize = 12.sp)
                }
                val folder = s.path.substringAfterLast('/').takeIf { it.isNotEmpty() && it != model.title(s) }
                val git = model.host.git[s.path]
                if (git != null) GitLine(git, folder, isActive)
                else Text(folder ?: " ", color = dim, fontSize = 14.sp, maxLines = 1, overflow = TextOverflow.Ellipsis)
                Text(detail(model, s), color = dimmer, fontSize = 14.sp, maxLines = 1, overflow = TextOverflow.Ellipsis)
            }
        }
        DropdownMenu(menu, { menu = false }, containerColor = Palette.head) {
            DropdownMenuItem({ Text("Rename…") }, { model.renaming = s.name; menu = false })
            DropdownMenuItem({ Text("Move to Group…") }, { moveMenu = true; menu = false })
            HorizontalDivider(color = Palette.line)
            // Kills the tmux session on the host, and the Claude in it: only here, never one tap away.
            DropdownMenuItem({ Text("Close Session", color = Palette.red) }, { model.close(s.name); menu = false })
        }
        DropdownMenu(moveMenu, { moveMenu = false }, containerColor = Palette.head) {
            DropdownMenuItem({ Text("New Group") }, { model.newGroup(with = s.name); moveMenu = false })
            model.groups.forEach { g ->
                DropdownMenuItem({ Text(model.groupTitle(g)) }, { model.move(s.name, g.id); moveMenu = false },
                    leadingIcon = { Box(Modifier.size(11.dp).clip(CircleShape).background(Color(g.color.argb))) })
            }
            if (group != null) DropdownMenuItem({ Text("Remove from Group") }, { model.move(s.name, null); moveMenu = false })
        }
    }
}

private fun detail(model: PadModel, s: RemoteSession): String {
    val parts = mutableListOf("tmux ${s.name}")
    if (s.agent == null && s.command !in setOf("zsh", "bash", "sh", "fish")) parts += s.command
    if (s.attachedClients > (if (model.selected == s.name) 1 else 0)) parts += "also open elsewhere"
    return parts.joinToString(" · ")
}

private fun relative(millis: Long): String {
    val s = ((System.currentTimeMillis() - millis) / 1000).coerceAtLeast(0)
    return when {
        s < 60 -> "now"
        s < 3600 -> "${s / 60}m"
        s < 86_400 -> "${s / 3600}h"
        else -> "${s / 86_400}d"
    }
}

@Composable
fun ClaudeGlyph(status: AgentStatus, onAccent: Boolean = false) {
    when (status) {
        AgentStatus.Busy -> {
            val angle by rememberInfiniteTransition(label = "busy").animateFloat(0f, 360f,
                infiniteRepeatable(tween(2000, easing = LinearEasing), RepeatMode.Restart), label = "spin")
            Text("✳", color = if (onAccent) Palette.onSelection else Palette.claudeOrange, fontSize = 13.sp,
                fontWeight = FontWeight.Bold, modifier = Modifier.rotate(angle))
        }
        AgentStatus.Waiting -> Icon(Icons.Filled.Error, "Waiting for you", tint = if (onAccent) Palette.onSelection else Palette.claudeOrange, modifier = Modifier.size(15.dp))
        AgentStatus.Idle -> Text("✳", color = if (onAccent) Palette.onSelection.copy(alpha = 0.7f) else Palette.secondary, fontSize = 13.sp, fontWeight = FontWeight.Bold)
    }
}

/** Folder, branch chip, ahead/behind, then the uncommitted diff (or a check when clean). */
@Composable
private fun GitLine(status: GitStatus, folder: String?, onAccent: Boolean) {
    val c = if (onAccent) Palette.onSelection.copy(alpha = 0.85f) else Palette.secondary
    Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(6.dp)) {
        folder?.let { Text(it, color = c, fontSize = 14.sp, maxLines = 1, overflow = TextOverflow.Ellipsis, modifier = Modifier.weight(1f, fill = false)) }
        Row(Modifier.clip(RoundedCornerShape(50)).background(if (onAccent) Palette.onSelection.copy(alpha = 0.2f) else Color.White.copy(alpha = 0.08f))
            .padding(horizontal = 6.dp, vertical = 1.dp), verticalAlignment = Alignment.CenterVertically) {
            Icon(Icons.AutoMirrored.Filled.CallSplit, null, tint = c, modifier = Modifier.size(11.dp))
            Spacer(Modifier.width(3.dp))
            Text(status.branch ?: status.commit ?: "no commits", color = c, fontSize = 12.sp, fontFamily = FontFamily.Monospace, maxLines = 1)
        }
        if (status.ahead > 0) Text("↑${status.ahead}", color = c, fontSize = 13.sp)
        if (status.behind > 0) Text("↓${status.behind}", color = c, fontSize = 13.sp)
        Spacer(Modifier.weight(1f))
        if (status.isClean) Icon(Icons.Filled.Check, "Clean", tint = c, modifier = Modifier.size(13.dp))
        else Row(horizontalArrangement = Arrangement.spacedBy(4.dp)) {
            val mono = 12.sp
            if (status.insertions > 0 || status.deletions > 0) {
                Text("+${status.insertions}", color = if (onAccent) Palette.onSelection else Palette.green, fontSize = mono, fontFamily = FontFamily.Monospace, fontWeight = FontWeight.SemiBold)
                Text("−${status.deletions}", color = if (onAccent) Palette.onSelection else Palette.red, fontSize = mono, fontFamily = FontFamily.Monospace, fontWeight = FontWeight.SemiBold)
            }
            if (status.untrackedFiles > 0) Text("?${status.untrackedFiles}", color = c, fontSize = mono, fontFamily = FontFamily.Monospace, fontWeight = FontWeight.SemiBold)
        }
    }
}

@Composable
fun HeaderButton(icon: ImageVector, label: String, tint: Color = Palette.text, onClick: () -> Unit) {
    Box(Modifier.size(width = 44.dp, height = 38.dp).clip(RoundedCornerShape(50)).background(Palette.key)
        .combinedClickable(onClick = onClick), contentAlignment = Alignment.Center) {
        Icon(icon, label, tint = tint, modifier = Modifier.size(20.dp))
    }
}
