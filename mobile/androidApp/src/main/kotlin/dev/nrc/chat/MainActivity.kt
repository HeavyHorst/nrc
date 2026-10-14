package dev.nrc.chat

import android.content.Context
import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.BackHandler
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import app.cash.sqldelight.driver.android.AndroidSqliteDriver
import dev.nrc.chat.db.ChatDatabase
import dev.nrc.chat.ui.NrcApp
import io.ktor.client.HttpClient
import io.ktor.client.engine.okhttp.OkHttp
import io.ktor.client.plugins.websocket.WebSockets
import kotlinx.coroutines.*
import kotlinx.serialization.encodeToString
import kotlinx.serialization.decodeFromString
import kotlinx.serialization.json.Json

class MainActivity : ComponentActivity() {
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)
    private val http = HttpClient(OkHttp) {
        // OkHttp rejects custom maxFrameSize settings after a successful upgrade.
        install(WebSockets)
        followRedirects = false
        expectSuccess = true
    }
    private lateinit var chat: ChatClient

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        enableEdgeToEdge()
        chat = ChatClient(http, AndroidStore(this), scope, AndroidMessageStore.get(this))
        setContent {
            val state by chat.state.collectAsState()
            NrcApp(state, chat::select, chat::draft, chat::sendSelected, chat::configure,
                chat::startDM, chat::loadOlder, { chat.disconnect(); chat.connect() }, chat::dismissNotice,
                darkTheme = isSystemInDarkTheme(), onClearDiagnostics = chat::clearDiagnostics,
                platformBackHandler = { enabled, onBack -> BackHandler(enabled, onBack) })
        }
    }
    override fun onStart() { super.onStart(); chat.connect() }
    override fun onStop() {
        chat.disconnect()
        scope.launch(start = CoroutineStart.UNDISPATCHED) { chat.flushCache() }
        super.onStop()
    }
    override fun onDestroy() { scope.cancel(); http.close(); super.onDestroy() }
}

/** One app-lifetime connection; activities never hold a database Context. */
private object AndroidMessageStore {
    private var instance: SqliteMessageStore? = null
    fun get(context: Context): SqliteMessageStore = instance ?: SqliteMessageStore(
        AndroidSqliteDriver(ChatDatabase.Schema, context.applicationContext, "chat-history.db")
    ).also { instance = it }
}

private class AndroidStore(context: Context) : LocalStore {
    private val preferences = context.getSharedPreferences("nrc-chat", Context.MODE_PRIVATE)
    override fun diagnostics(): List<DiagnosticEvent> = preferences.getString("system-log", null)?.let {
        Json.decodeFromString<List<DiagnosticEvent>>(it).takeLast(MAX_DIAGNOSTIC_EVENTS)
    }.orEmpty()
    override fun saveDiagnostics(events: List<DiagnosticEvent>) {
        preferences.edit().putString("system-log", Json.encodeToString(events.takeLast(MAX_DIAGNOSTIC_EVENTS))).apply()
    }
    override fun profile() = Profile(preferences.getString("server", "").orEmpty(), preferences.getString("workspace", "workspace1").orEmpty())
    override fun saveProfile(profile: Profile) {
        check(preferences.edit().putString("server", profile.server).putString("workspace", profile.workspace).commit())
    }
    private fun prefix(profile: Profile) = "draft:${profile.server}/${profile.workspace}:"
    override fun drafts(profile: Profile): Map<String, String> {
        val prefix = prefix(profile)
        return preferences.all.filterKeys { it.startsWith(prefix) }.map { (key, value) ->
            key.removePrefix(prefix) to value.toString()
        }.toMap()
    }
    override fun saveDraft(profile: Profile, conversationKey: String, text: String) {
        val editor = preferences.edit()
        val key = "${prefix(profile)}$conversationKey"
        if (text.isEmpty()) editor.remove(key) else editor.putString(key, text)
        check(editor.commit())
    }
    override fun clearDrafts(profile: Profile) {
        val editor = preferences.edit()
        preferences.all.keys.filter { it.startsWith(prefix(profile)) }.forEach { editor.remove(it) }
        check(editor.commit())
    }
}
