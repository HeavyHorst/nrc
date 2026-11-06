package dev.nrc.chat

import io.ktor.client.HttpClient
import io.ktor.client.engine.mock.*
import io.ktor.client.request.HttpRequestData
import io.ktor.client.request.HttpResponseData
import io.ktor.http.*
import io.ktor.client.engine.okhttp.OkHttp
import okhttp3.mockwebserver.MockResponse
import okhttp3.mockwebserver.MockWebServer
import okhttp3.tls.HandshakeCertificates
import okhttp3.tls.HeldCertificate
import kotlinx.coroutines.*
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.test.*
import kotlinx.serialization.json.*
import kotlin.test.*

@OptIn(ExperimentalCoroutinesApi::class)
class VoiceClientTest {
    private class Audio(private val earlySpeech: Boolean = false) : VoiceAudio {
        lateinit var event: (String) -> Unit
        var closed = false
        var muted = false
        var answered = false
        override suspend fun offer(onEvent: (String) -> Unit): String { event = onEvent; return "offer" }
        override suspend fun answer(sdp: String) {
            assertEquals("answer", sdp)
            answered = true
            event("""{"type":"session.started"}""")
            if (earlySpeech) event("""{"type":"session.input_transcript.delta"}""")
        }
        override fun mute(muted: Boolean) { this.muted = muted }
        override fun close() { closed = true }
    }
    private val profile = Profile("https://nrc.example", "studio")
    private fun TestScope.http(handler: suspend MockRequestHandleScope.(HttpRequestData) -> HttpResponseData) =
        HttpClient(MockEngine(MockEngineConfig().apply {
            dispatcher = StandardTestDispatcher(testScheduler)
            addHandler(handler)
        }))
    private fun status(revision: Int, result: String = "null", extra: String = "") =
        """{"revision":$revision,"result":$result,"busy":false,"applying":false,"closed":false$extra}"""
    private val proposal = """{"plan_id":"plan","answer":"Prüfen","proposed_actions":[
        {"id":"a","type":"create_task","title":"Erster","priority":0,"description":""},
        {"id":"b","type":"delete_note","asset_id":18446744073709551614}]}"""

    @Test fun firstUtteranceCanApproveWhenResearchCompletesWithoutAnotherRevision() = runTest {
        val audio = Audio(earlySpeech = true)
        var complete = false
        val writes = mutableListOf<JsonObject>()
        val http = http { request ->
            when (request.url.encodedPath) {
                "/ai/voice/create" -> respond("""{"id":"voice","sdp":"answer"}""")
                "/ai/voice/status" -> respond(if (!audio.answered) status(6)
                    else status(7, if (complete) proposal else "null"))
                "/ai/voice/apply" -> {
                    writes += Json.parseToJsonElement(request.body.toByteArray().decodeToString()).jsonObject
                    respond("""{"ok":true,"applied":[{}],"failed":[]}""")
                }
                else -> respond("""{"ok":true}""")
            }
        }
        val voice = VoiceClient(http, backgroundScope) { audio }
        voice.start(profile); runCurrent()
        assertFalse(voice.state.value.canApprove)
        complete = true
        repeat(3) { advanceTimeBy(501); runCurrent() }
        assertTrue(voice.state.value.canApprove, "Completion at revision 7 must not require another utterance")
        assertTrue(voice.state.value.selected.isEmpty())
        voice.approve(); runCurrent(); assertTrue(writes.isEmpty())
        voice.select("a", true); voice.approve(); runCurrent()
        assertEquals(1, writes.size)
        assertEquals("7", writes.single()["revision"]!!.jsonPrimitive.content)
        assertEquals(JsonArray(listOf(JsonPrimitive("a"))), writes.single()["action_ids"])
        http.close()
    }

    @Test fun stopWhileInitialStatusIsPendingNeverConnectsAudio() = runTest {
        val audio = Audio()
        val baseline = CompletableDeferred<Unit>()
        var closes = 0
        val http = http { request ->
            when (request.url.encodedPath) {
                "/ai/voice/create" -> respond("""{"id":"voice","sdp":"answer"}""")
                "/ai/voice/status" -> { baseline.await(); respond(status(6)) }
                "/ai/voice/close" -> { closes++; respond("""{"ok":true}""") }
                else -> error("Unexpected route")
            }
        }
        val voice = VoiceClient(http, backgroundScope) { audio }
        voice.start(profile); runCurrent()
        assertFalse(audio.answered)
        voice.end(); runCurrent()
        baseline.complete(Unit); runCurrent()
        assertFalse(audio.answered)
        assertTrue(audio.muted)
        assertTrue(audio.closed)
        assertFalse(voice.state.value.active)
        assertFalse(voice.state.value.starting)
        assertEquals(1, closes)
        http.close()
    }

    @Test fun explicitSelectionRevisionAndLostReplyReconciliationSurviveAudioEnd() = runTest {
        val audio = Audio(earlySpeech = true)
        var status = status(6, proposal)
        val writes = mutableListOf<JsonObject>()
        val http = http { request ->
            assertEquals("nrc.example", request.url.host)
            val body = Json.parseToJsonElement(request.body.toByteArray().decodeToString()).jsonObject
            assertEquals("studio", body["workspace"]!!.jsonPrimitive.content)
            val response = when (request.url.encodedPath) {
                "/ai/voice/create" -> """{"id":"voice-1","sdp":"answer"}"""
                "/ai/voice/status" -> status
                "/ai/voice/close" -> """{"ok":true}"""
                "/ai/voice/apply" -> { writes += body; throw java.io.IOException("lost reply") }
                else -> error("Unexpected route")
            }
            respond(response, HttpStatusCode.OK)
        }
        val voice = VoiceClient(http, backgroundScope) { audio }
        voice.start(profile); runCurrent()
        assertFalse(voice.state.value.canApprove, "The first snapshot cannot clear already observed speech")
        status = status(7, proposal)
        advanceTimeBy(501); runCurrent()
        assertTrue(voice.state.value.canApprove)
        assertTrue(voice.state.value.selected.isEmpty())
        assertContains(voice.state.value.actions[1].fields, "18446744073709551614")
        voice.approve(); runCurrent(); assertTrue(writes.isEmpty())
        voice.select("a", true)
        audio.event("""{"type":"session.input_transcript.delta"}"""); runCurrent()
        voice.approve(); runCurrent(); assertTrue(writes.isEmpty())
        assertTrue(voice.state.value.selected.isEmpty())
        advanceTimeBy(501); runCurrent(); assertFalse(voice.state.value.canApprove)
        status = status(8, proposal)
        advanceTimeBy(501); runCurrent()
        assertTrue(voice.state.value.canApprove)
        voice.select("b", true); voice.approve(); voice.approve(); runCurrent()
        assertEquals(1, writes.size)
        assertEquals(JsonArray(listOf(JsonPrimitive("b"))), writes.single()["action_ids"])
        assertEquals("8", writes.single()["revision"]!!.jsonPrimitive.content)
        voice.end(); runCurrent()
        assertTrue(audio.closed)
        assertTrue(voice.state.value.resolving)
        assertTrue(voice.state.value.submitted)
        // A stale successful receipt must not resolve a newer approval.
        status = status(8, extra = """, "apply_revision":7,"apply_result":{"ok":true,"applied":[{}]}""")
        advanceTimeBy(501); runCurrent(); assertTrue(voice.state.value.resolving)
        status = status(8, extra = """, "apply_revision":8,"apply_result":{"ok":true,"applied":[{"action_id":"b"}],"failed":[]}""")
        advanceTimeBy(501); runCurrent()
        assertFalse(voice.state.value.resolving)
        assertContains(voice.state.value.outcome, "1 Aktionen erfolgreich")
        assertEquals(1, writes.size)
        http.close()
    }

    @Test fun speechDuringStatusDoesNotConsumeTheRevisionNeededToUnlockTheProposal() = runTest {
        val audio = Audio()
        var revision = 3
        var gate: CompletableDeferred<Unit>? = null
        val http = http { request ->
            when (request.url.encodedPath) {
                "/ai/voice/create" -> respond("""{"id":"voice","sdp":"answer"}""")
                "/ai/voice/status" -> { gate?.await(); respond(status(revision, proposal)) }
                else -> respond("""{"ok":true}""")
            }
        }
        val voice = VoiceClient(http, backgroundScope) { audio }
        voice.start(profile); runCurrent()
        voice.select("a", true)
        val response = CompletableDeferred<Unit>()
        gate = response
        advanceTimeBy(501); runCurrent()
        audio.event("""{"type":"session.input_transcript.delta"}"""); runCurrent()
        assertFalse(voice.state.value.canApprove)
        assertTrue(voice.state.value.selected.isEmpty())
        revision = 4
        gate = null; response.complete(Unit); runCurrent()
        assertFalse(voice.state.value.canApprove, "A response overlapping speech is not sufficient")
        advanceTimeBy(501); runCurrent()
        assertTrue(voice.state.value.canApprove, "A clean response with the SAME newer revision must recover")
        assertTrue(voice.state.value.selected.isEmpty(), "Recovery must never restore consent")
        audio.event("""{"type":"session.input_transcript.delta"}"""); runCurrent()
        advanceTimeBy(501); runCurrent()
        assertFalse(voice.state.value.canApprove, "A new utterance still requires a newer revision")
        revision = 5
        advanceTimeBy(501); runCurrent()
        assertTrue(voice.state.value.canApprove)
        http.close()
    }

    @Test fun unknownApplyOutcomeKeepsSubmittedStateAfterAudioAndReconciliationEnd() = runTest {
        val audio = Audio()
        var snapshot = status(3, proposal)
        var writes = 0
        val http = http { request ->
            when (request.url.encodedPath) {
                "/ai/voice/create" -> respond("""{"id":"voice","sdp":"answer"}""")
                "/ai/voice/status" -> respond(snapshot)
                "/ai/voice/apply" -> { writes++; throw java.io.IOException("lost reply") }
                else -> respond("""{"ok":true}""")
            }
        }
        val voice = VoiceClient(http, backgroundScope) { audio }
        voice.start(profile); runCurrent()
        assertFalse(voice.state.value.submitted)
        voice.select("a", true); voice.approve(); runCurrent()
        assertTrue(voice.state.value.submitted)
        voice.end(); runCurrent()
        snapshot = status(3, extra = """, "apply_revision":3,"error":"unknown outcome"""")
        advanceTimeBy(501); runCurrent()
        assertFalse(voice.state.value.resolving)
        assertTrue(voice.state.value.actions.isNotEmpty())
        assertTrue(voice.state.value.submitted)
        assertContains(voice.state.value.outcome, "unbestätigt")
        voice.approve(); runCurrent()
        assertEquals(1, writes)
        http.close()
    }

    @Test fun endedCreateClosesLateSessionAndDoesNotRestartMicrophone() = runTest {
        val audio = Audio()
        val created = CompletableDeferred<Unit>()
        var creates = 0
        val closed = mutableListOf<String>()
        val http = http { request ->
            when (request.url.encodedPath) {
                "/ai/voice/create" -> { creates++; created.await(); respond("""{"id":"late","sdp":"answer"}""") }
                "/ai/voice/close" -> {
                    closed += Json.parseToJsonElement(request.body.toByteArray().decodeToString()).jsonObject["id"]!!.jsonPrimitive.content
                    respond("""{"ok":true}""")
                }
                else -> error("No polling after stop")
            }
        }
        val voice = VoiceClient(http, backgroundScope) { audio }
        voice.start(profile); runCurrent()
        voice.end(); voice.start(profile); runCurrent()
        assertTrue(audio.muted)
        assertEquals(1, creates)
        created.complete(Unit); runCurrent()
        assertTrue(audio.closed)
        assertEquals(listOf("late"), closed)
        assertFalse(voice.state.value.active)
        assertFalse(voice.state.value.starting)
        http.close()
    }

    @Test fun statusTimeoutStopsAudioAndFailedApplyNeverBecomesSuccess() = runTest {
        val audio = Audio()
        var timeout = false
        val http = http { request ->
            when (request.url.encodedPath) {
                "/ai/voice/create" -> respond("""{"id":"voice","sdp":"answer"}""")
                "/ai/voice/status" -> { if (timeout) delay(20_000); respond(status(1, proposal)) }
                "/ai/voice/apply" -> respond("""{"ok":false,"applied":[],"failed":[{"action_id":"a","error":"unknown"}]}""")
                else -> respond("""{"ok":true}""")
            }
        }
        val voice = VoiceClient(http, backgroundScope) { audio }
        voice.start(profile); runCurrent()
        voice.mute(); assertTrue(audio.muted)
        voice.select("a", true); voice.approve(); runCurrent()
        assertFalse(voice.state.value.active)
        assertTrue(audio.closed)
        assertContains(voice.state.value.outcome, "nicht erneut ausführen")
        timeout = true
        voice.start(profile); runCurrent()
        advanceTimeBy(10_001); runCurrent()
        assertFalse(voice.state.value.active)
        assertContains(voice.state.value.status, "Zeitlimit")
        http.close()
    }

    @Test fun okHttpDoesNotReplayBillableCreateOnRetryAfterZero() = runBlocking {
        val server = MockWebServer()
        val certificate = HeldCertificate.Builder().commonName("localhost").addSubjectAlternativeName("localhost").build()
        server.useHttps(HandshakeCertificates.Builder().heldCertificate(certificate).build().sslSocketFactory(), false)
        server.enqueue(MockResponse().setResponseCode(503).setHeader("Retry-After", "0"))
        server.enqueue(MockResponse().setResponseCode(503))
        server.start()
        val tls = HandshakeCertificates.Builder().addTrustedCertificate(certificate.certificate).build()
        val http = HttpClient(OkHttp) {
            followRedirects = false
            engine { config { sslSocketFactory(tls.sslSocketFactory(), tls.trustManager); retryOnConnectionFailure(false) } }
        }
        val job = SupervisorJob()
        val audio = Audio()
        val voice = VoiceClient(http, CoroutineScope(coroutineContext + job)) { audio }
        try {
            voice.start(Profile(server.url("/").toString(), "studio"))
            withTimeout(5000) { voice.state.first { !it.active && !it.starting } }
            assertEquals(1, server.requestCount, "503 Retry-After must not replay session creation")
            val request = server.takeRequest()
            assertEquals("/ai/voice/create", request.path)
            assertEquals("application/json", request.getHeader("Content-Type"))
            assertEquals("offer", Json.parseToJsonElement(request.body.readUtf8()).jsonObject["sdp"]!!.jsonPrimitive.content)
            assertTrue(audio.closed)
        } finally { job.cancelAndJoin(); http.close(); server.shutdown() }
    }
}
