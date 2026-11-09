package dev.nrc.chat.ui

import androidx.compose.foundation.layout.*
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.unit.dp
import dev.nrc.chat.MemoryState

@Composable
internal fun MemoryControls(state: MemoryState, action: (String) -> Unit) {
    var forget by remember { mutableStateOf(false) }
    Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
        Text("Persönliches Gedächtnis", style = MaterialTheme.typography.titleMedium)
        Text("Nur für dieses Konto und diesen Workspace.", style = MaterialTheme.typography.bodySmall,
            color = MaterialTheme.colorScheme.onSurfaceVariant)
        Text(when (state.policy?.enabled) { true -> "Gedächtnis aktiviert"; false -> "Gedächtnis deaktiviert"; null -> "Einstellung unbekannt" })
        if (state.busy) Text("Wird geladen …")
        if (state.message.isNotEmpty()) Text(state.message, style = MaterialTheme.typography.bodySmall)
        if (state.policy == null && !state.busy) TextButton(onClick = { action("inspect") }) { Text("Erneut versuchen") }
        TextButton(onClick = { action(if (state.policy?.enabled == true) "disable" else "enable") }, enabled = !state.busy && state.policy != null) {
            Text(if (state.policy?.enabled == true) "Gedächtnis deaktivieren" else "Gedächtnis aktivieren")
        }
        Text("Deaktivieren löscht keine vorhandenen Erinnerungen.", style = MaterialTheme.typography.bodySmall)
        TextButton(onClick = { action("export") }, enabled = !state.busy && state.policy != null) { Text("Export speichern …") }
        Text("Exportierte Kopien werden beim Vergessen nicht mitgelöscht.", style = MaterialTheme.typography.bodySmall)
        HorizontalDivider(color = MaterialTheme.colorScheme.outlineVariant)
        TextButton(onClick = { forget = true }, enabled = !state.busy && state.policy != null,
            colors = ButtonDefaults.textButtonColors(contentColor = MaterialTheme.colorScheme.error)) { Text("Alles vergessen …") }
    }
    if (forget) AlertDialog(onDismissRequest = { forget = false },
        shape = RoundedCornerShape(4.dp), containerColor = MaterialTheme.colorScheme.surfaceVariant,
        title = { Text("Alle persönlichen Erinnerungen löschen?") },
        text = { Text("Nur dieses Konto in diesem Workspace. Nicht rückgängig zu machen. Geteilte Datensätze und exportierte Kopien bleiben erhalten.") },
        confirmButton = { TextButton(enabled = !state.busy && state.policy != null,
            colors = ButtonDefaults.textButtonColors(contentColor = MaterialTheme.colorScheme.error),
            onClick = { forget = false; action("forget_all") }) { Text("Endgültig vergessen") } },
        dismissButton = { TextButton(onClick = { forget = false }) { Text("Abbrechen") } })
}
