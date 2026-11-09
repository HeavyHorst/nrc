package dev.nrc.chat.ui

import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.selection.toggleable
import androidx.compose.foundation.text.selection.SelectionContainer
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.Mic
import androidx.compose.material.icons.outlined.MicOff
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.semantics.*
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.window.Dialog
import androidx.compose.ui.window.DialogProperties
import dev.nrc.chat.VoiceAction
import dev.nrc.chat.VoiceState
import kotlinx.serialization.json.*

private val actionLabels = mapOf(
    "create_task" to "Aufgabe anlegen", "update_task" to "Aufgabe ändern",
    "create_note" to "Notiz anlegen", "update_note" to "Notiz ändern", "delete_note" to "Notiz löschen",
    "create_edge" to "Verknüpfung anlegen", "delete_edge" to "Verknüpfung löschen",
)
private val fieldLabels = mapOf(
    "description" to "Beschreibung", "content" to "Inhalt", "project" to "Projekt", "priority" to "Priorität",
    "tags" to "Schlagwörter", "status" to "Status", "task_status" to "Aufgabenstatus", "format" to "Format",
    "task_id" to "Aufgaben-ID", "asset_id" to "Datensatz-ID", "edge_id" to "Verknüpfungs-ID",
    "blocked_by" to "Blockiert durch Aufgabe", "expected_updated_at" to "Erwartete Datensatzversion",
    "source_type" to "Quelltyp", "source_id" to "Quell-ID", "source_action_id" to "Quellaktion",
    "target_type" to "Zieltyp", "target_id" to "Ziel-ID", "target_action_id" to "Zielaktion",
    "relation" to "Beziehung", "ticket" to "Ticket", "ticket_result_id" to "Ticket-Ergebnis-ID",
)
private val readableJson = Json { prettyPrint = true }

@Composable
internal fun VoicePanel(state: VoiceState, mute: () -> Unit, end: () -> Unit, dismiss: () -> Unit,
    select: (String, Boolean) -> Unit, approve: () -> Unit,
    backHandler: @Composable (Boolean, () -> Unit) -> Unit) {
    var details by remember { mutableStateOf(false) }
    LaunchedEffect(state.actions, state.outcome) {
        if (state.actions.isNotEmpty() || state.outcome.isNotEmpty()) details = true
    }
    val duration = "${state.seconds / 60}:${(state.seconds % 60).toString().padStart(2, '0')}"
    val settled = !state.active && !state.starting && !state.resolving
    Column(Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 8.dp)) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Text("SULLIVAN · $duration", Modifier.weight(1f), fontFamily = FontFamily.Monospace)
            TextButton(onClick = { details = true }, modifier = Modifier.heightIn(min = 48.dp)) { Text("Details") }
        }
        Text(state.status, style = MaterialTheme.typography.bodySmall)
        if (state.privacy.isNotEmpty()) Text(state.privacy, style = MaterialTheme.typography.bodySmall)
        if (state.contextDelivery.isNotEmpty()) Text(state.contextDelivery + " Keine Aussage über Sprache oder Wiedergabe.",
            style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
        if (state.resolving) Text("Bestätigung wird geprüft. Nicht erneut ausführen.",
            style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.primary)
        else if (state.actions.isNotEmpty()) TextButton(onClick = { details = true },
            modifier = Modifier.fillMaxWidth().heightIn(min = 48.dp)) {
            Text("${state.actions.size} ${if (state.actions.size == 1) "Änderung" else "Änderungen"} prüfen →")
        }
        VoiceControls(state, mute, if (settled) dismiss else end, settled)
    }
    HorizontalDivider(color = MaterialTheme.colorScheme.outlineVariant)
    if (details) Dialog(onDismissRequest = { details = false },
        properties = DialogProperties(usePlatformDefaultWidth = false)) {
        Surface(Modifier.fillMaxSize().windowInsetsPadding(WindowInsets.safeDrawing)) {
            Column(Modifier.fillMaxSize().padding(horizontal = 20.dp, vertical = 12.dp)) {
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Text(if (state.actions.isNotEmpty()) "Prüfen" else "Sullivan", Modifier.weight(1f), style = MaterialTheme.typography.titleMedium)
                    TextButton(onClick = { details = false }, modifier = Modifier.heightIn(min = 48.dp)) { Text("Zurück") }
                }
                HorizontalDivider(color = MaterialTheme.colorScheme.outlineVariant)
                Column(Modifier.weight(1f).verticalScroll(rememberScrollState()).padding(vertical = 12.dp),
                    verticalArrangement = Arrangement.spacedBy(8.dp)) {
                    Text("${state.workspace} · $duration / 10:00", style = MaterialTheme.typography.labelMedium,
                        color = MaterialTheme.colorScheme.onSurfaceVariant)
                    if (state.actions.isNotEmpty()) {
                        Text(if (state.submitted) "Bereits bestätigt. Ausführung kann erfolgt sein; nicht erneut ausführen." else "Noch nicht ausgeführt.",
                            style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
                    }
                    state.actions.forEach { action ->
                        key(action.id, action.fields) { VoiceActionCard(action, state.canApprove, action.id in state.selected) { select(action.id, it) } }
                    }
                    Text(state.status, style = MaterialTheme.typography.bodySmall)
                    if (state.answer.isNotEmpty()) {
                        Text("Sullivan", style = MaterialTheme.typography.labelMedium, color = MaterialTheme.colorScheme.primary)
                        SelectionContainer { Text(state.answer, style = MaterialTheme.typography.bodyLarge) }
                    }
                    if (state.sources.isNotEmpty()) {
                        Text("Quellen", style = MaterialTheme.typography.titleSmall)
                        state.sources.forEach { SelectionContainer { Text(it, style = MaterialTheme.typography.bodySmall) } }
                    }
                    if (state.outcome.isNotEmpty()) {
                        Text("Ergebnis", style = MaterialTheme.typography.titleMedium)
                        SelectionContainer { Text(state.outcome.substringBefore('\n')) }
                        if ('\n' in state.outcome) VoiceTechnicalDetails(state.outcome.substringAfter('\n'))
                    }
                    Text("Neue Sprache verwirft die Freigabe. Audio wird bei OpenAI verarbeitet. Stummschalten pausiert das Mikrofon; im Hintergrund endet das Gespräch.",
                        style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
                }
                HorizontalDivider(color = MaterialTheme.colorScheme.outlineVariant)
                Spacer(Modifier.height(8.dp))
                if (state.actions.isNotEmpty()) {
                    Text(if (state.resolving) "Bestätigung wird geprüft …" else if (!state.canApprove) "Vorschlag derzeit nicht freigebbar"
                        else "${state.selected.size} von ${state.actions.size} ausgewählt",
                        style = MaterialTheme.typography.labelMedium, modifier = Modifier.padding(bottom = 8.dp))
                    Button(onClick = approve, enabled = state.canApprove && state.selected.isNotEmpty(),
                        modifier = Modifier.fillMaxWidth().heightIn(min = 48.dp)) { Text("Bestätigen") }
                }
                VoiceControls(state, mute, end, false)
            }
        }
        backHandler(true) { details = false }
    }
}

@Composable
private fun VoiceControls(state: VoiceState, mute: () -> Unit, end: () -> Unit, dismiss: Boolean) {
    val microphone = when {
        !state.active -> "Mikrofon aus"
        state.muted -> "Mikrofon stumm"
        !state.ready -> "Mikrofon wird verbunden …"
        else -> "Mikrofon aktiv"
    }
    Text(microphone, Modifier.padding(top = 12.dp, bottom = 8.dp).semantics { liveRegion = LiveRegionMode.Polite },
        style = MaterialTheme.typography.labelMedium, color = MaterialTheme.colorScheme.onSurfaceVariant)
    // FlowRow keeps both controls reachable when large text no longer fits side by side.
    @OptIn(ExperimentalLayoutApi::class)
    FlowRow(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(8.dp),
        verticalArrangement = Arrangement.spacedBy(4.dp),
        maxItemsInEachRow = if (LocalDensity.current.fontScale >= 1.5f) 1 else 2) {
        OutlinedButton(onClick = mute, enabled = state.active && state.ready,
            modifier = Modifier.heightIn(min = 48.dp), contentPadding = PaddingValues(horizontal = 12.dp)) {
            Icon(if (state.muted) Icons.Outlined.Mic else Icons.Outlined.MicOff, null, Modifier.size(18.dp))
            Spacer(Modifier.width(6.dp))
            Text(if (state.muted) "Aktivieren" else "Stummschalten")
        }
        OutlinedButton(onClick = end, enabled = dismiss || state.active,
            colors = ButtonDefaults.outlinedButtonColors(contentColor = if (dismiss) MaterialTheme.colorScheme.primary else MaterialTheme.colorScheme.error),
            modifier = Modifier.heightIn(min = 48.dp)) { Text(if (dismiss) "Schließen" else "Ende") }
    }
}

@Composable
private fun VoiceActionCard(action: VoiceAction, enabled: Boolean, selected: Boolean, select: (Boolean) -> Unit) {
    val fields = remember(action.fields) { runCatching { Json.parseToJsonElement(action.fields).jsonObject }.getOrNull() }
    val type = (fields?.get("type") as? JsonPrimitive)?.content.orEmpty()
    OutlinedCard(Modifier.fillMaxWidth(), colors = CardDefaults.outlinedCardColors(containerColor = MaterialTheme.colorScheme.surface)) {
        Column(Modifier.padding(12.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
            Text(actionLabels[type] ?: type.ifEmpty { "Änderungsvorschlag" }, style = MaterialTheme.typography.labelMedium,
                color = MaterialTheme.colorScheme.primary)
            if (action.title != type) SelectionContainer { Text(action.title, style = MaterialTheme.typography.titleMedium, fontWeight = FontWeight.SemiBold) }
            if (fields == null) SelectionContainer { Text(action.fields, style = MaterialTheme.typography.bodySmall) }
            else {
                fields.filterKeys { it !in setOf("id", "type", "title") }.forEach { (key, value) ->
                    Column(verticalArrangement = Arrangement.spacedBy(4.dp)) {
                        Text(fieldLabels[key] ?: key, style = MaterialTheme.typography.labelMedium, color = MaterialTheme.colorScheme.onSurfaceVariant)
                        val text = when {
                            key == "priority" && value is JsonPrimitive && !value.isString && value.intOrNull in 0..254 ->
                                "${when (value.int) { in 200..254 -> "Hoch"; in 128..199 -> "Mittel"; else -> "Niedrig" }} (${value.int})"
                            value is JsonNull -> "Nicht gesetzt"
                            value is JsonPrimitive && value.isString -> value.content.ifEmpty { "Leer" }
                            value is JsonPrimitive -> when (value.booleanOrNull) {
                                true -> "Ja"; false -> "Nein"; null -> value.content.ifEmpty { "Leer" }
                            }
                            value is JsonArray && value.isEmpty() -> "Keine Einträge"
                            else -> readableJson.encodeToString(JsonElement.serializer(), value)
                        }
                        SelectionContainer { Text(text, style = MaterialTheme.typography.bodyMedium) }
                    }
                }
            }
            HorizontalDivider(color = MaterialTheme.colorScheme.outlineVariant)
            Row(Modifier.fillMaxWidth().heightIn(min = 48.dp).toggleable(selected, enabled = enabled, role = Role.Checkbox, onValueChange = select),
                verticalAlignment = Alignment.CenterVertically) {
                Checkbox(checked = selected, onCheckedChange = null, enabled = enabled)
                Spacer(Modifier.width(12.dp))
                Text("Vorschlag auswählen", style = MaterialTheme.typography.bodyMedium)
            }
            if (fields != null) VoiceTechnicalDetails(action.fields)
        }
    }
}

@Composable
private fun VoiceTechnicalDetails(raw: String) {
    var expanded by remember(raw) { mutableStateOf(false) }
    TextButton(onClick = { expanded = !expanded }, modifier = Modifier.heightIn(min = 48.dp)) {
        Text(if (expanded) "Technische Daten verbergen" else "Technische Daten anzeigen")
    }
    if (expanded) SelectionContainer { Text(raw, fontFamily = FontFamily.Monospace, style = MaterialTheme.typography.bodySmall) }
}
