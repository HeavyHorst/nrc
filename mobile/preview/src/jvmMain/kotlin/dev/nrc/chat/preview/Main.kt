package dev.nrc.chat.preview

import androidx.compose.foundation.layout.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
import androidx.compose.ui.window.Window
import androidx.compose.ui.window.application
import androidx.compose.ui.window.rememberWindowState
import dev.nrc.chat.*
import dev.nrc.chat.Retention
import dev.nrc.chat.ui.NrcApp
import app.cash.sqldelight.driver.jdbc.sqlite.JdbcSqliteDriver
import dev.nrc.chat.db.ChatDatabase
import io.ktor.client.HttpClient
import io.ktor.client.engine.cio.CIO
import io.ktor.client.plugins.websocket.WebSockets
import kotlinx.coroutines.*
import kotlinx.serialization.encodeToString
import kotlinx.serialization.decodeFromString
import kotlinx.serialization.json.Json
import java.security.MessageDigest
import java.util.prefs.Preferences

/** Desktop host renders the exact Android Compose UI; it is not an Android emulator. */
fun main() = application {
    val window = rememberWindowState(width = 420.dp, height = 900.dp)
    Window(onCloseRequest = ::exitApplication, title = "NRC · Compose preview", state = window) {
        var sample by remember { mutableStateOf(true) }
        var dark by remember { mutableStateOf(false) }
        var fixture by remember { mutableStateOf(sampleState()) }
        val scope = rememberCoroutineScope()
        val http = remember { HttpClient(CIO) { install(WebSockets); followRedirects = false; expectSuccess = true } }
        val driver = remember {
            val directory = java.io.File(System.getProperty("user.home"), ".nrc-chat")
            check(directory.isDirectory || directory.mkdirs())
            val file = java.io.File(directory, "history.db")
            JdbcSqliteDriver("jdbc:sqlite:${file.absolutePath}").also {
                ChatDatabase.Schema.create(it)
            }
        }
        val client = remember { ChatClient(http, PreviewStore(), scope, SqliteMessageStore(driver)) }
        val live by client.state.collectAsState()
        DisposableEffect(Unit) { onDispose {
            client.disconnect()
            scope.launch(start = CoroutineStart.UNDISPATCHED) {
                withContext(NonCancellable) { client.flushCache(); driver.close() }
            }
            http.close()
        } }
        Column {
            MaterialTheme {
                Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.SpaceEvenly) {
                    TextButton(onClick = { dark = !dark }) { Text(if (dark) "Light" else "Dark") }
                    TextButton(onClick = { fixture = fixture.copy(connection = if (fixture.connection == Connection.Connected)
                        Connection.Reconnecting else Connection.Connected, members = emptyMap()) }, enabled = sample) { Text(if (fixture.connection == Connection.Connected) "Go offline" else "Go online") }
                    TextButton(onClick = { sample = !sample; if (sample) client.disconnect() else client.connect() }) {
                        Text(if (sample) "Connect live" else "Sample")
                    }
                }
            }
            Box(Modifier.weight(1f)) {
                if (!sample) NrcApp(live, client::select, client::draft, client::sendSelected, client::configure,
                    client::startDM, client::loadOlder, { client.disconnect(); client.connect() }, client::dismissNotice, dark,
                    onClearDiagnostics = client::clearDiagnostics)
                else NrcApp(fixture, { fixture = fixture.copy(selected = it, unread = fixture.unread - (it ?: 0)) },
                    { id, text -> fixture = fixture.copy(drafts = fixture.drafts + (id to text)) }, {
                        val id = fixture.selected
                        if (id != null) {
                            val text = fixture.drafts[id].orEmpty()
                            val message = Message("sample:${System.nanoTime()}", id, author = "rene", timestampNanos = System.currentTimeMillis() * 1_000_000,
                                text = text, delivery = Delivery.Sent)
                            fixture = fixture.copy(messages = fixture.messages + (id to (fixture.messages[id].orEmpty() + message)), drafts = fixture.drafts - id)
                        }
                    }, { /* sample stays local */ }, { name ->
                        val conversation = fixture.conversations.firstOrNull { it.direct && it.name == name }
                            ?: Conversation(Long.MIN_VALUE + fixture.conversations.size, name, true)
                        fixture = fixture.copy(conversations = (fixture.conversations + conversation).distinctBy { it.id }, selected = conversation.id,
                            liveDMs = fixture.liveDMs + conversation.id, retention = fixture.retention + (conversation.id to Retention.Enabled))
                    }, {}, { fixture = fixture.copy(connection = Connection.Connected) }, { fixture = fixture.copy(notice = null) }, dark,
                    onClearDiagnostics = { fixture = fixture.copy(diagnostics = emptyList()) })
            }
        }
    }
}

fun sampleState(): ChatState {
    val rooms = listOf(Conversation(2, "general"), Conversation(42, "design"), Conversation(3, "shipping"),
        Conversation(Long.MIN_VALUE + 1, "lena", true), Conversation(Long.MIN_VALUE + 2, "jonas", true), Conversation(Long.MIN_VALUE + 3, "maya", true))
    fun message(sequence: Long, author: String, minutes: Int, text: String) = Message("42:$sequence", 42, sequence, author,
        java.time.Instant.parse("2026-10-13T07:00:00Z").epochSecond * 1_000_000_000L + minutes * 60_000_000_000L,
        text, if (author == "rene") Delivery.Sent else Delivery.Received)
    val transcript = listOf(
        message(1, "maya", 14, "The new mobile direction is ready. Less noise, more conversation."),
        message(2, "lena", 16, "The warm palette works. Can we make it feel a little more like NRC?"),
        message(3, "jonas", 18, "Keep the terminal character, but make it comfortable on a phone."),
        message(4, "rene", 41, "Agreed. Text first. Clear state. Nothing extra."))
    return ChatState(profile = Profile("https://preview.invalid", "studio"), connection = Connection.Connected,
        username = "rene", conversations = rooms, messages = mapOf(42L to transcript,
            (Long.MIN_VALUE + 3) to listOf(message(1, "maya", 12, "The notes are saved here. We can pick this up later.")
                .copy(key = "cached-dm:1", conversationId = Long.MIN_VALUE + 3))),
        unread = mapOf(42L to 3, (Long.MIN_VALUE + 1) to 1), members = mapOf(42L to setOf("maya", "lena", "jonas", "rene")),
        liveDMs = rooms.filter { it.direct && it.name != "maya" }.map { it.id }.toSet(),
        retention = rooms.filter { it.name != "maya" }.associate { it.id to Retention.Enabled }, preview = true,
        diagnostics = listOf(
            DiagnosticEvent(1791875700000, DiagnosticLevel.Info, "Connecting", "Attempt 1. Opening secure WebSocket transport."),
            DiagnosticEvent(1791875701000, DiagnosticLevel.Error, "Transport failed",
                "DNS resolution failed. Check the server hostname and Tailscale DNS connection.\nUnknownHostException"),
            DiagnosticEvent(1791875702000, DiagnosticLevel.Info, "Reconnect scheduled", "Retry in 1 seconds."),
            DiagnosticEvent(1791875703000, DiagnosticLevel.Info, "Connected", "Authenticated NRC handshake accepted; protocol 8.")))
}

private class PreviewStore : LocalStore {
    private val preferences = Preferences.userRoot().node("dev/nrc/chat/preview")
    private val logFile = java.io.File(System.getProperty("user.home"), ".nrc-chat/system-log.json")
    override fun diagnostics(): List<DiagnosticEvent> = if (logFile.exists()) {
        Json.decodeFromString<List<DiagnosticEvent>>(logFile.readText()).takeLast(MAX_DIAGNOSTIC_EVENTS)
    } else emptyList()
    override fun saveDiagnostics(events: List<DiagnosticEvent>) {
        val temporary = java.nio.file.Files.createTempFile(logFile.parentFile.toPath(), "system-log-", ".json")
        try {
            java.nio.file.Files.writeString(temporary, Json.encodeToString(events.takeLast(MAX_DIAGNOSTIC_EVENTS)))
            java.nio.file.Files.move(temporary, logFile.toPath(), java.nio.file.StandardCopyOption.ATOMIC_MOVE,
                java.nio.file.StandardCopyOption.REPLACE_EXISTING)
        } finally { java.nio.file.Files.deleteIfExists(temporary) }
    }
    override fun profile() = Profile(preferences.get("server", ""), preferences.get("workspace", "workspace1"))
    override fun saveProfile(profile: Profile) { preferences.put("server", profile.server); preferences.put("workspace", profile.workspace); preferences.flush() }
    private fun draftsNode(profile: Profile): Preferences {
        val hash = MessageDigest.getInstance("SHA-256").digest((profile.server + "/" + profile.workspace).toByteArray())
            .joinToString("") { "%02x".format(it) }
        return preferences.node("drafts/$hash")
    }
    override fun drafts(profile: Profile) = draftsNode(profile).let { node -> node.keys().associateWith { node.get(it, "") } }
    override fun saveDraft(profile: Profile, conversationKey: String, text: String) {
        val node = draftsNode(profile); if (text.isEmpty()) node.remove(conversationKey) else node.put(conversationKey, text); node.flush()
    }
    override fun clearDrafts(profile: Profile) { draftsNode(profile).let { it.clear(); it.flush() } }
}
