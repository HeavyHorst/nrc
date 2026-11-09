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
            addHandler { request ->
                if (request.url.encodedPath == "/ai/ask/memory") respond("""{"enabled":true,"epoch":0}""")
                else handler(request)
            }
        }))
    private fun status(revision: Int, result: String = "null", extra: String = "") =
        """{"revision":$revision,"result":$result,"busy":false,"applying":false,"closed":false$extra}"""
    private val proposal = """{"plan_id":"plan","answer":"Prüfen","sources":[{"title":"private source","type":"note","id":12}],"proposed_actions":[
        {"id":"a","type":"create_task","title":"Erster","priority":0,"description":""},
        {"id":"b","type":"delete_note","asset_id":18446744073709551614}]}"""

    @Test fun confirmedForgetClearsEndedEvidenceAndFencesOldAudioEvents() = runTest {
        val audio = Audio()
        val http = http { request ->
            when (request.url.encodedPath) {
                "/ai/voice/create" -> respond("""{"id":"voice","sdp":"answer"}""")
                "/ai/voice/status" -> respond(status(1, proposal))
                "/ai/voice/apply" -> respond("""{"ok":true,"applied":[{"title":"private receipt"}]}""")
                else -> respond("{}")
            }
        }
        val voice = VoiceClient(http, backgroundScope) { audio }
        voice.memory.refresh(profile); runCurrent()
        voice.start(profile); runCurrent()
        voice.select("a", true); voice.approve(); runCurrent()
        voice.end(); runCurrent()
        assertEquals("Prüfen", voice.state.value.answer)
        assertTrue(voice.state.value.sources.isNotEmpty())
        assertContains(voice.state.value.outcome, "private receipt")
        voice.memory.forgetAll(profile); runCurrent()
        assertEquals("", voice.state.value.answer)
        assertTrue(voice.state.value.actions.isEmpty())
        assertTrue(voice.state.value.sources.isEmpty())
        assertFalse(voice.state.value.outcome.contains("private receipt"))
        val cleared = voice.state.value
        audio.event("""{"type":"session.started"}"""); runCurrent()
        assertEquals(cleared, voice.state.value)
        assertTrue(audio.closed)
        http.close()
    }

    @Test fun localAndRemoteForgetKeepOnlyReconciliationAndRejectLateApplyText() = runTest {
        for (remote in listOf(false, true)) {
            val audio = Audio()
            val applied = CompletableDeferred<Unit>()
            var invalidated = false
            var reconciled = false
            var writes = 0
            val receipt = """{"ok":true,"applied":[{"title":"private receipt"}],"failed":[]}"""
            val http = http { request ->
                when (request.url.encodedPath) {
                    "/ai/voice/create" -> respond("""{"id":"voice","sdp":"answer"}""")
                    "/ai/voice/status" -> respond(status(1, proposal, extra =
                        """, "memory_invalidated":$invalidated,"apply_revision":1,"apply_result":${if (reconciled) receipt else "null"}"""))
                    "/ai/voice/apply" -> { writes++; applied.await(); respond(receipt) }
                    else -> respond("{}")
                }
            }
            val voice = VoiceClient(http, backgroundScope) { audio }
            voice.memory.refresh(profile); runCurrent()
            voice.start(profile); runCurrent()
            voice.select("a", true); voice.approve(); runCurrent()
            assertTrue(voice.state.value.resolving)
            if (remote) { invalidated = true; advanceTimeBy(501) }
            else voice.memory.forgetAll(profile)
            runCurrent()
            assertFalse(voice.state.value.active)
            assertTrue(voice.state.value.resolving)
            assertTrue(voice.state.value.submitted)
            assertEquals("", voice.state.value.answer)
            assertTrue(voice.state.value.actions.isEmpty())
            applied.complete(Unit); runCurrent()
            assertTrue(voice.state.value.resolving, "Old apply reply must be fenced")
            assertFalse(voice.state.value.outcome.contains("private receipt"))
            reconciled = true; advanceTimeBy(501); runCurrent()
            assertFalse(voice.state.value.resolving)
            assertContains(voice.state.value.outcome, "1 Aktionen erfolgreich")
            assertFalse(voice.state.value.outcome.contains("private receipt"))
            assertEquals("", voice.state.value.answer)
            assertEquals(1, writes)
            http.close()
        }
    }

    @Test fun forgetDiscardsInFlightStatusAndOldAudioAfterNewSessionStarts() = runTest {
        val oldAudio = Audio()
        val newAudio = Audio()
        val gate = CompletableDeferred<Unit>()
        var hold = false
        var creates = 0
        val http = http { request ->
            when (request.url.encodedPath) {
                "/ai/voice/create" -> { creates++; respond("""{"id":"voice-$creates","sdp":"answer"}""") }
                "/ai/voice/status" -> {
                    val old = hold
                    if (old) withContext(NonCancellable) { gate.await() }
                    respond(status(1, if (old || creates == 1) proposal else "null"))
                }
                else -> respond("{}")
            }
        }
        val voice = VoiceClient(http, backgroundScope) { if (creates == 0) oldAudio else newAudio }
        voice.memory.refresh(profile); runCurrent()
        voice.start(profile); runCurrent()
        hold = true; advanceTimeBy(501); runCurrent()
        voice.memory.forgetAll(profile); runCurrent()
        assertEquals("", voice.state.value.answer)
        hold = false
        voice.start(profile); runCurrent()
        assertTrue(voice.state.value.active)
        gate.complete(Unit)
        oldAudio.event("""{"type":"session.closed"}""")
        runCurrent()
        assertTrue(voice.state.value.active)
        assertEquals("", voice.state.value.answer)
        assertTrue(voice.state.value.actions.isEmpty())
        assertTrue(voice.state.value.sources.isEmpty())
        assertFalse(newAudio.closed)
        voice.end(); runCurrent(); http.close()
    }

    @Test fun forgetFencesLateCreateAndInitialStatusWithoutRestartingAudio() = runTest {
        for (route in listOf("create", "status")) {
            val audio = Audio()
            val gate = CompletableDeferred<Unit>()
            val closed = mutableListOf<String>()
            val http = http { request ->
                if (request.url.encodedPath == "/ai/voice/$route") gate.await()
                when (request.url.encodedPath) {
                    "/ai/voice/create" -> respond("""{"id":"late","sdp":"answer"}""")
                    "/ai/voice/status" -> respond(status(1, proposal))
                    "/ai/voice/close" -> {
                        closed += Json.parseToJsonElement(request.body.toByteArray().decodeToString()).jsonObject["id"]!!.jsonPrimitive.content
                        respond("{}")
                    }
                    else -> error("Unexpected route")
                }
            }
            val voice = VoiceClient(http, backgroundScope) { audio }
            voice.memory.refresh(profile); runCurrent()
            voice.start(profile); runCurrent()
            voice.memory.forgetAll(profile); runCurrent()
            val cleared = voice.state.value
            gate.complete(Unit); runCurrent()
            assertEquals(cleared, voice.state.value)
            assertFalse(audio.answered)
            assertTrue(audio.closed)
            assertEquals(listOf("late"), closed)
            http.close()
        }
    }

    @Test fun audioCloseBeforeInvalidatingStatusStillReconcilesWithoutPendingApproval() = runTest {
        for (invalidated in listOf(false, true)) {
            val audio = Audio()
            val terminal = CompletableDeferred<Unit>()
            var ended = false
            var terminalReads = 0
            val http = http { request ->
                when (request.url.encodedPath) {
                    "/ai/voice/create" -> respond("""{"id":"voice","sdp":"answer"}""")
                    "/ai/voice/status" -> {
                        if (ended) { terminalReads++; terminal.await() }
                        respond(status(1, proposal, """, "closed":$ended,"memory_invalidated":${ended && invalidated}"""))
                    }
                    else -> respond("{}")
                }
            }
            val voice = VoiceClient(http, backgroundScope) { audio }
            voice.start(profile); runCurrent()
            assertEquals("Prüfen", voice.state.value.answer)
            assertFalse(voice.state.value.resolving)
            // Audio closes while the regular poll is sleeping, before HTTP reveals deletion.
            ended = true
            audio.event("""{"type":"session.closed"}"""); runCurrent()
            assertFalse(voice.state.value.active)
            advanceTimeBy(501); runCurrent()
            terminal.complete(Unit); runCurrent()
            assertEquals(1, terminalReads)
            assertEquals(if (invalidated) "" else "Prüfen", voice.state.value.answer)
            assertEquals(invalidated, voice.state.value.actions.isEmpty())
            assertEquals(invalidated, voice.state.value.sources.isEmpty())
            advanceTimeBy(20_000); runCurrent()
            assertEquals(1, terminalReads, "Terminal reconciliation must be bounded")
            http.close()
        }
    }

    @Test fun lateTerminalInvalidationCannotClearANewSession() = runTest {
        val oldAudio = Audio()
        val newAudio = Audio()
        val terminal = CompletableDeferred<Unit>()
        var ended = false
        var creates = 0
        val http = http { request ->
            when (request.url.encodedPath) {
                "/ai/voice/create" -> { creates++; respond("""{"id":"voice-$creates","sdp":"answer"}""") }
                "/ai/voice/status" -> {
                    val oldTerminal = ended && creates == 1
                    if (oldTerminal) terminal.await()
                    respond(status(1, proposal, """, "memory_invalidated":$oldTerminal"""))
                }
                else -> respond("{}")
            }
        }
        val voice = VoiceClient(http, backgroundScope) { if (creates == 0) oldAudio else newAudio }
        voice.start(profile); runCurrent()
        ended = true; oldAudio.event("""{"type":"session.closed"}"""); runCurrent()
        voice.start(profile); runCurrent()
        terminal.complete(Unit); runCurrent()
        assertTrue(voice.state.value.active)
        assertEquals("Prüfen", voice.state.value.answer)
        assertFalse(newAudio.closed)
        voice.end(); runCurrent(); http.close()
    }

    @Test fun terminalStatusTimeoutDoesNotDeleteOrRetry() = runTest {
        val audio = Audio()
        var ended = false
        var terminalReads = 0
        val http = http { request ->
            when (request.url.encodedPath) {
                "/ai/voice/create" -> respond("""{"id":"voice","sdp":"answer"}""")
                "/ai/voice/status" -> {
                    if (ended) { terminalReads++; delay(20_000) }
                    respond(status(1, proposal))
                }
                else -> respond("{}")
            }
        }
        val voice = VoiceClient(http, backgroundScope) { audio }
        voice.start(profile); runCurrent()
        ended = true; audio.event("""{"type":"session.closed"}"""); runCurrent()
        advanceTimeBy(30_000); runCurrent()
        assertEquals(1, terminalReads)
        assertFalse(voice.state.value.active)
        assertFalse(voice.state.value.resolving)
        assertEquals("Prüfen", voice.state.value.answer)
        assertTrue(voice.state.value.actions.isNotEmpty())
        http.close()
    }

    @Test fun ordinaryRemoteCloseKeepsEvidenceWithoutDeletionSignal() = runTest {
        val audio = Audio()
        var closed = false
        val http = http { request ->
            when (request.url.encodedPath) {
                "/ai/voice/create" -> respond("""{"id":"voice","sdp":"answer"}""")
                "/ai/voice/status" -> respond(status(1, proposal, """, "closed":$closed"""))
                else -> respond("{}")
            }
        }
        val voice = VoiceClient(http, backgroundScope) { audio }
        voice.start(profile); runCurrent()
        closed = true; advanceTimeBy(501); runCurrent()
        assertFalse(voice.state.value.active)
        assertEquals("Prüfen", voice.state.value.answer)
        assertTrue(voice.state.value.actions.isNotEmpty())
        http.close()
    }

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
        server.enqueue(MockResponse().setBody("""{"enabled":true,"epoch":0}"""))
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
            assertEquals(2, server.requestCount, "Inspect plus one create; 503 must not replay creation")
            assertEquals("/ai/ask/memory", server.takeRequest().path)
            val request = server.takeRequest()
            assertEquals("/ai/voice/create", request.path)
            assertEquals("application/json", request.getHeader("Content-Type"))
            assertEquals("offer", Json.parseToJsonElement(request.body.readUtf8()).jsonObject["sdp"]!!.jsonPrimitive.content)
            assertTrue(audio.closed)
        } finally { job.cancelAndJoin(); http.close(); server.shutdown() }
    }
}
