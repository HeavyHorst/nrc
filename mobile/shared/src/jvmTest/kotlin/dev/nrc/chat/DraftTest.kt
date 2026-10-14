package dev.nrc.chat

import io.ktor.client.HttpClient
import io.ktor.client.engine.cio.CIO
import io.ktor.client.plugins.websocket.WebSockets
import kotlinx.coroutines.test.runTest
import kotlin.test.*

class DraftTest {
    @Test fun draftsSurviveClientRecreationAndOfflineSendDoesNotEraseThem() = runTest {
        val store = TestStore()
        val http = HttpClient(CIO) { install(WebSockets) }
        try {
            val first = ChatClient(http, store, backgroundScope)
            first.select(2)
            first.draft(2, "A locally saved draft — even offline.")
            first.sendSelected()
            assertTrue(first.state.value.messages.isEmpty())
            val second = ChatClient(http, store, backgroundScope)
            assertEquals("A locally saved draft — even offline.", second.state.value.drafts[2])
            second.draft(2, "é".repeat(25_601))
            assertEquals(first.state.value.drafts[2], second.state.value.drafts[2])
            assertNotNull(second.state.value.notice)
        } finally { http.close() }
    }

    @Test fun workspaceDraftsStayIsolatedAndDMIdentityDoesNotUseEphemeralId() = runTest {
        val store = TestStore()
        val http = HttpClient(CIO) { install(WebSockets) }
        try {
            val client = ChatClient(http, store, backgroundScope)
            client.draft(2, "Private studio draft")
            client.configure(Profile("https://nrc.example", "other"))
            client.disconnect()
            assertTrue(client.state.value.drafts.isEmpty())
            client.configure(Profile("https://nrc.example", "studio"))
            client.disconnect()
            assertEquals("Private studio draft", client.state.value.drafts[2])
            assertEquals(Conversation(Long.MIN_VALUE + 1, "lena", true).draftKey(),
                Conversation(Long.MIN_VALUE + 99, "lena", true).draftKey())
            assertNotEquals(Conversation(Long.MIN_VALUE + 1, "lena", true).draftKey(),
                Conversation(Long.MIN_VALUE + 1, "jonas", true).draftKey())
        } finally { http.close() }
    }
}

private class TestStore : LocalStore {
    private var saved = Profile("https://nrc.example", "studio")
    private val data = mutableMapOf<Pair<Profile, String>, String>()
    override fun profile() = saved
    override fun saveProfile(profile: Profile) { saved = profile }
    override fun drafts(profile: Profile) = data.filterKeys { it.first == profile }.mapKeys { it.key.second }
    override fun saveDraft(profile: Profile, conversationKey: String, text: String) { data[profile to conversationKey] = text }
    override fun clearDrafts(profile: Profile) { data.keys.removeAll { it.first == profile } }
}
