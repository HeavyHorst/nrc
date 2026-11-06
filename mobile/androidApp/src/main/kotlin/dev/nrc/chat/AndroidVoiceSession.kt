package dev.nrc.chat

import android.content.Context
import androidx.lifecycle.ViewModel
import io.ktor.client.HttpClient
import kotlinx.coroutines.*

/** Retains approval reconciliation across Activity recreation, never microphone capture. */
internal class AndroidVoiceSession(
    private val http: HttpClient,
    audioFactory: () -> VoiceAudio,
    private val configure: (Profile) -> Unit,
) : ViewModel() {
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)
    val client = VoiceClient(http, scope, audioFactory)
    private var owner: Pair<Profile, String>? = null

    fun start(profile: Profile, username: String) {
        if (client.state.value.active || client.state.value.starting || client.state.value.resolving) return
        configure(profile)
        owner = profile to username
        client.start(profile)
    }

    fun identityChanged(profile: Profile, username: String) {
        val previous = owner ?: return
        // A recreated ChatClient may not have restored/authenticated its username yet.
        if (previous.first != profile || (username.isNotEmpty() && previous.second != username)) client.hide()
    }

    fun backgrounded() { client.end("App im Hintergrund. Gespräch beendet.") }

    override fun onCleared() {
        client.end()
        scope.cancel()
        http.close()
    }
}

/** Chat and voice must share one runtime session: acquiring another supersedes the old one. */
internal class AndroidTransportSession(context: Context) : ViewModel() {
    val transport = NrcTransport(context.applicationContext)
    override fun onCleared() { transport.close() }
}
