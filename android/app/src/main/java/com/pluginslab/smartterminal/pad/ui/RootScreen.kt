package com.pluginslab.smartterminal.pad.ui

import androidx.activity.compose.BackHandler
import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.slideInHorizontally
import androidx.compose.animation.slideOutHorizontally
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.widthIn
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.unit.dp
import com.pluginslab.smartterminal.pad.model.PadModel
import java.util.UUID

/**
 * The Mac's Mail-style columns: groups | sessions | terminal.
 *
 * Landscape shows them side by side. Portrait gives the terminal the whole screen, as Mail
 * does with a message: the lists slide in over it (the button in the terminal header) and go
 * away when you pick a session or go back. Over it, not beside it, so tmux doesn't reflow.
 * (Not a left-edge swipe as on the iPad: on Android that is the back gesture.)
 */
@Composable
fun RootScreen(model: PadModel, onLock: () -> Unit) {
    BoxWithConstraints(Modifier.fillMaxSize().background(Palette.list)) {
        val portrait = maxHeight > maxWidth
        LaunchedEffect(portrait) { if (!portrait) model.listsOpen = false }
        // The terminal column keeps its place in the tree whatever shows beside it, so
        // rotating never rebuilds it (the iPad's blank-terminal lesson).
        Row(Modifier.fillMaxSize()) {
            if (!portrait) {
                if (model.groupsShown) GroupsColumn(model, Modifier.width(230.dp).fillMaxHeight())
                SessionsColumn(model, portrait = false, Modifier.width(340.dp).fillMaxHeight())
            }
            DetailColumn(model, portrait, onLock, Modifier.weight(1f).fillMaxHeight())
        }
        if (portrait) {
            AnimatedVisibility(model.listsOpen, enter = fadeIn(), exit = fadeOut()) {
                Box(Modifier.fillMaxSize().background(Color.Black.copy(alpha = 0.35f))
                    .clickable(remember { MutableInteractionSource() }, indication = null) { model.listsOpen = false })
            }
            AnimatedVisibility(model.listsOpen, enter = slideInHorizontally { -it }, exit = slideOutHorizontally { -it }) {
                Row(Modifier.fillMaxHeight().widthIn(max = maxWidth - 64.dp)) {
                    if (model.groupsShown) GroupsColumn(model, Modifier.width(230.dp).fillMaxHeight())
                    SessionsColumn(model, portrait = true, Modifier.width(340.dp).fillMaxHeight())
                }
            }
            BackHandler(model.listsOpen) { model.listsOpen = false }
        }
    }
    model.renaming?.let { RenameDialog(model, it) }
}

@Composable
private fun RenameDialog(model: PadModel, target: String) {
    val groupId = target.takeIf { it.startsWith("group:") }?.let { runCatching { UUID.fromString(it.removePrefix("group:")) }.getOrNull() }
    val current = remember(target) {
        if (groupId != null) model.groups.firstOrNull { it.id == groupId }?.name ?: ""
        else model.sessions.firstOrNull { it.name == target }?.let(model::title) ?: ""
    }
    var text by remember(target) { mutableStateOf(current) }
    AlertDialog(
        onDismissRequest = { model.renaming = null },
        title = { Text("Rename") },
        text = { OutlinedTextField(text, { text = it }, singleLine = true, label = { Text("Name") }) },
        confirmButton = {
            TextButton({
                if (groupId != null) model.updateGroup(groupId, name = text) else model.rename(target, text)
                model.renaming = null
            }) { Text("Save") }
        },
        dismissButton = { TextButton({ model.renaming = null }) { Text("Cancel") } },
        containerColor = Palette.head,
    )
}
