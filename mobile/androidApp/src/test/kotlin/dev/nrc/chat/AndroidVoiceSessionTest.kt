package dev.nrc.chat

import androidx.lifecycle.ViewModel
import androidx.lifecycle.ViewModelProvider
import androidx.lifecycle.ViewModelStore
import androidx.lifecycle.ViewModelStoreOwner
import io.ktor.client.HttpClient
import io.ktor.client.engine.mock.*
import kotlinx.coroutines.*
import kotlinx.coroutines.test.*
import org.junit.Assert.*
import org.junit.Test

@OptIn(ExperimentalCoroutinesApi::class)
class AndroidVoiceSessionTest {
    @Test fun recreatedOwnerRetainsLostReplyReconciliationButNeverRestartsAudio() = runTest {
        Dispatchers.setMain(StandardTestDispatcher(testScheduler))
        val store = ViewModelStore()
        var recordings = 0
        var closed = false
        var writes = 0
        var completed = false
        val http = HttpClient(MockEngine(MockEngineConfig().apply {
            dispatcher = StandardTestDispatcher(testScheduler)
            addHandler { request ->
                when (request.url.encodedPath) {
                    "/ai/voice/create" -> respond("""{"id":"voice","sdp":"answer"}""")
                    "/ai/voice/status" -> respond(if (completed)
                        """{"revision":1,"apply_revision":1,"apply_result":{"ok":true,"applied":[{}],"failed":[]}}"""
                        else """{"revision":1,"result":{"plan_id":"p","proposed_actions":[{"id":"a","type":"create_task"}]}}""")
                    "/ai/voice/apply" -> { writes++; throw java.io.IOException("reply lost after commit") }
                    else -> respond("""{"ok":true}""")
                }
            }
        }))
        val audio = object : VoiceAudio {
            lateinit var event: (String) -> Unit
            override suspend fun offer(onEvent: (String) -> Unit): String { recordings++; event = onEvent; return "offer" }
            override suspend fun answer(sdp: String) { event("""{"type":"session.started"}""") }
            override fun mute(muted: Boolean) = Unit
            override fun close() { closed = true }
        }
        val factory = object : ViewModelProvider.Factory {
            @Suppress("UNCHECKED_CAST")
            override fun <T : ViewModel> create(modelClass: Class<T>): T =
                AndroidVoiceSession(http, { audio }, {}) as T
        }
        fun recreatedOwner() = object : ViewModelStoreOwner { override val viewModelStore = store }
        val profile = Profile("https://nrc.example", "studio")
        try {
            val original = ViewModelProvider(recreatedOwner(), factory)[AndroidVoiceSession::class.java]
            original.start(profile, "rene"); runCurrent()
            original.client.select("a", true); original.client.approve(); runCurrent()
            assertTrue(original.client.state.value.resolving)
            original.backgrounded(); runCurrent()
            assertTrue(closed)
            // ComponentActivity passes its retained ViewModelStore to the new Activity.
            val recreated = ViewModelProvider(recreatedOwner(), factory)[AndroidVoiceSession::class.java]
            recreated.identityChanged(profile, "")
            recreated.identityChanged(profile, "rene")
            assertTrue(recreated.client.state.value.visible)
            assertTrue(recreated.client.state.value.resolving)
            assertFalse(recreated.client.state.value.active)
            completed = true
            advanceTimeBy(501); runCurrent()
            assertFalse(recreated.client.state.value.resolving)
            assertTrue(recreated.client.state.value.outcome.contains("1 Aktionen erfolgreich"))
            assertEquals(1, recordings)
            assertEquals(1, writes)
            recreated.identityChanged(profile, "another-user")
            assertFalse(recreated.client.state.value.visible)
            store.clear(); runCurrent()
            assertFalse(http.coroutineContext[Job]!!.isActive)
        } finally {
            store.clear(); http.close(); Dispatchers.resetMain()
        }
    }
}
