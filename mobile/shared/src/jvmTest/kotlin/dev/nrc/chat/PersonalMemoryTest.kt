package dev.nrc.chat

import io.ktor.client.HttpClient
import io.ktor.client.engine.mock.*
import io.ktor.http.*
import kotlinx.coroutines.*
import kotlinx.coroutines.test.*
import kotlinx.serialization.json.*
import kotlin.test.*

@OptIn(ExperimentalCoroutinesApi::class)
class PersonalMemoryTest {
    private val profile = Profile("https://nrc.example", "studio")
    @Test fun fullExportNeverOffersPartialStaleOrPreviousAccountData() = runTest {
        for (scenario in listOf("full", "empty", "failure", "epoch", "cursor", "reset")) {
            var pages = 0
            var inspections = 0
            val gate = CompletableDeferred<Unit>()
            val http = HttpClient(MockEngine(MockEngineConfig().apply {
                dispatcher = StandardTestDispatcher(testScheduler)
                addHandler { request ->
                    val body = Json.parseToJsonElement(request.body.toByteArray().decodeToString()).jsonObject
                    if (body["operation"]!!.jsonPrimitive.content == "inspect") {
                        inspections++
                        respond("""{"enabled":true,"epoch":${if (scenario == "epoch" && inspections > 1) 8 else 7}}""")
                    } else {
                        pages++
                        assertEquals(7, body["epoch"]!!.jsonPrimitive.int)
                        if (scenario == "reset") gate.await()
                        when {
                            scenario == "empty" -> respond("[]")
                            pages == 1 -> respond((0..99).joinToString(prefix = "[", postfix = "]") { """{"sequence":$it}""" })
                            scenario == "failure" -> respond("unavailable", HttpStatusCode.ServiceUnavailable)
                            scenario == "cursor" -> respond("""[{"sequence":99}]""")
                            else -> respond("""[{"sequence":100}]""")
                        }
                    }
                }
            }))
            val memory = PersonalMemory(http, backgroundScope)
            memory.refresh(profile); runCurrent()
            var data: String? = null
            var valid: (() -> Boolean)? = null
            memory.export(profile) { value, check -> data = value; valid = check }
            runCurrent()
            if (scenario == "reset") { memory.reset(); gate.complete(Unit); runCurrent() }
            if (scenario == "full" || scenario == "empty") {
                assertEquals(if (scenario == "full") 101 else 0, Json.parseToJsonElement(data!!).jsonArray.size)
                assertTrue(valid!!())
                memory.clearExport()
                assertFalse(valid!!())
                memory.export(profile) { _, _ -> }; runCurrent()
                assertFalse(valid!!(), "An old save grant must not become valid again")
                memory.reset()
                assertEquals(MemoryState(), memory.state.value)
            } else {
                assertNull(data, scenario)
                assertEquals("", memory.state.value.export)
            }
            http.close()
        }
    }

    private class Audio : VoiceAudio {
        override suspend fun offer(onEvent: (String) -> Unit) = "offer"
        override suspend fun answer(sdp: String) = Unit
        override fun mute(muted: Boolean) = Unit
        override fun close() = Unit
    }

    @Test fun forgettingNotifiesOnlyForConfirmedCurrentGenerationSuccess() = runTest {
        var notifications = 0
        var response = """{"enabled":true,"epoch":1}"""
        var code = HttpStatusCode.OK
        var gate: CompletableDeferred<Unit>? = null
        val http = HttpClient(MockEngine(MockEngineConfig().apply {
            dispatcher = StandardTestDispatcher(testScheduler)
            addHandler { gate?.await(); respond(response, code) }
        }))
        val memory = PersonalMemory(http, backgroundScope) { notifications++ }
        memory.refresh(profile); runCurrent()
        code = HttpStatusCode.Conflict
        memory.forgetAll(profile); runCurrent()
        assertEquals(0, notifications)
        code = HttpStatusCode.OK
        memory.refresh(profile); runCurrent()
        response = "{}"
        memory.forgetAll(profile); runCurrent()
        assertEquals(0, notifications)
        response = """{"enabled":true,"epoch":2}"""
        memory.refresh(profile); runCurrent()
        gate = CompletableDeferred()
        memory.forgetAll(profile); runCurrent()
        memory.reset(); gate!!.complete(Unit); runCurrent()
        assertEquals(0, notifications)
        gate = null
        memory.refresh(profile); runCurrent()
        memory.forgetAll(profile); runCurrent()
        assertEquals(1, notifications)
        http.close()
    }

    @Test fun defaultVoiceInspectsPolicyBeforeAudioAndNeverDowngradesOnFailure() = runTest {
        for (policy in listOf("true", "false", "outage", "malformed")) {
            val requests = mutableListOf<Pair<String, JsonObject>>()
            var recordings = 0
            val http = HttpClient(MockEngine(MockEngineConfig().apply {
                dispatcher = StandardTestDispatcher(testScheduler)
                addHandler { request ->
                    val body = Json.parseToJsonElement(request.body.toByteArray().decodeToString()).jsonObject
                    requests += request.url.encodedPath to body
                    assertEquals("studio", body["workspace"]!!.jsonPrimitive.content)
                    when (request.url.encodedPath) {
                        "/ai/ask/memory" -> {
                            assertEquals(0, recordings)
                            assertEquals("inspect", body["operation"]!!.jsonPrimitive.content)
                            when (policy) {
                                "outage" -> respond("unavailable", HttpStatusCode.ServiceUnavailable)
                                "malformed" -> respond("{}")
                                else -> respond("""{"epoch":0,"enabled":$policy}""")
                            }
                        }
                        "/ai/voice/create" -> respond("""{"id":"v","sdp":"answer"}""")
                        else -> respond("""{"revision":1}""")
                    }
                }
            }))
            val voice = VoiceClient(http, backgroundScope) { recordings++; Audio() }
            voice.start(profile); runCurrent()
            if (policy in listOf("outage", "malformed")) {
                assertEquals(0, recordings)
                assertEquals(1, requests.size)
                assertFalse(voice.state.value.active)
                assertContains(voice.state.value.status, "Kein automatischer Wechsel")
            } else {
                val create = requests.single { it.first == "/ai/voice/create" }.second
                assertEquals(if (policy == "true") "private" else "temporary", create["execution_policy"]!!.jsonPrimitive.content)
                assertEquals(policy == "true", create["require_memory"]!!.jsonPrimitive.boolean)
            }
            voice.end(); runCurrent(); http.close()
        }
    }

    @Test fun explicitTemporarySkipsUnavailableMemoryAndContextDeliveryNeverResends() = runTest {
        val paths = mutableListOf<String>()
        var delivery = "pending"
        val http = HttpClient(MockEngine(MockEngineConfig().apply {
            dispatcher = StandardTestDispatcher(testScheduler)
            addHandler { request ->
                paths += request.url.encodedPath
                when (request.url.encodedPath) {
                    "/ai/voice/create" -> {
                        val body = Json.parseToJsonElement(request.body.toByteArray().decodeToString()).jsonObject
                        assertEquals("temporary", body["execution_policy"]!!.jsonPrimitive.content)
                        assertFalse(body["require_memory"]!!.jsonPrimitive.boolean)
                        respond("""{"id":"v","sdp":"answer"}""")
                    }
                    "/ai/voice/status" -> respond("""{"revision":1,"context_delivery":{"event":{"state":"$delivery"}}}""")
                    "/ai/voice/close" -> respond("{}")
                    else -> error("Temporary must not call memory")
                }
            }
        }))
        val voice = VoiceClient(http, backgroundScope) { Audio() }
        voice.memory.temporary(true)
        voice.start(profile); runCurrent()
        assertContains(voice.state.value.contextDelivery, "ausstehend")
        delivery = "rejected"; advanceTimeBy(501); runCurrent()
        assertContains(voice.state.value.contextDelivery, "abgelehnt")
        delivery = "unconfirmed"; advanceTimeBy(501); runCurrent()
        assertContains(voice.state.value.contextDelivery, "unbestätigt")
        delivery = "acknowledged"; advanceTimeBy(501); runCurrent()
        assertEquals("", voice.state.value.contextDelivery)
        assertEquals(1, paths.count { it == "/ai/voice/create" })
        assertFalse(voice.state.value.resolving)
        voice.end(); runCurrent(); http.close()
    }

    @Test fun stoppingDuringInspectionCannotOpenMicrophoneOrCreateSession() = runTest {
        val gate = CompletableDeferred<Unit>()
        var requests = 0
        var recordings = 0
        val http = HttpClient(MockEngine(MockEngineConfig().apply {
            dispatcher = StandardTestDispatcher(testScheduler)
            addHandler { requests++; gate.await(); respond("""{"enabled":true,"epoch":0}""") }
        }))
        val voice = VoiceClient(http, backgroundScope) { recordings++; Audio() }
        voice.start(profile); runCurrent()
        voice.hide(); gate.complete(Unit); runCurrent()
        assertEquals(1, requests)
        assertEquals(0, recordings)
        assertFalse(voice.state.value.visible)
        assertFalse(voice.state.value.starting)
        http.close()
    }

    @Test fun controlsUseEpochBoundPagesConfirmedWritesAndResetDiscardsOldAccount() = runTest {
        val requests = mutableListOf<JsonObject>()
        var fail = false
        var enabled = true
        var gate: CompletableDeferred<Unit>? = null
        val http = HttpClient(MockEngine(MockEngineConfig().apply {
            dispatcher = StandardTestDispatcher(testScheduler)
            addHandler { request ->
                assertEquals("/ai/ask/memory", request.url.encodedPath)
                val body = Json.parseToJsonElement(request.body.toByteArray().decodeToString()).jsonObject
                requests += body
                gate?.await()
                if (fail) respond("conflict", HttpStatusCode.Conflict)
                else when (body["operation"]!!.jsonPrimitive.content) {
                    "export" -> respond(if (body["after"]!!.jsonPrimitive.long == -1L)
                        (0..99).joinToString(prefix = "[", postfix = "]") { """{"sequence":$it}""" } else "[]")
                    "configure" -> { enabled = false; respond("""{"enabled":false,"epoch":9}""") }
                    "forget_all" -> respond("""{"enabled":false,"epoch":10}""")
                    else -> respond("""{"enabled":$enabled,"epoch":9}""")
                }
            }
        }))
        val memory = PersonalMemory(http, backgroundScope)
        memory.refresh(profile); runCurrent()
        assertEquals(MemoryPolicy(9, true), memory.state.value.policy)
        memory.configure(profile, false); memory.configure(profile, false); runCurrent()
        val configure = requests.last()
        assertTrue(configure["confirm"]!!.jsonPrimitive.boolean)
        assertEquals(9, configure["policy"]!!.jsonObject["epoch"]!!.jsonPrimitive.int)
        assertFalse(memory.state.value.policy!!.enabled)
        var valid: (() -> Boolean)? = null
        var exported = ""
        memory.export(profile) { data, check -> exported = data; valid = check }; runCurrent()
        val pages = requests.filter { it["operation"]!!.jsonPrimitive.content == "export" }
        assertEquals(listOf(-1L, 99L), pages.map { it["after"]!!.jsonPrimitive.long })
        assertTrue(pages.all { it["epoch"]!!.jsonPrimitive.long == 9L && it["limit"]!!.jsonPrimitive.int == 100 })
        assertEquals(100, Json.parseToJsonElement(exported).jsonArray.size)
        assertTrue(valid!!())
        memory.forgetAll(profile); runCurrent()
        assertFalse(valid!!())
        assertTrue(requests.last()["confirm"]!!.jsonPrimitive.boolean)
        assertEquals(9, requests.last()["epoch"]!!.jsonPrimitive.int)
        assertEquals(10L, memory.state.value.policy!!.epoch)
        fail = true
        memory.configure(profile, true); runCurrent()
        assertNull(memory.state.value.policy)
        assertContains(memory.state.value.message, "unbestätigt")
        assertEquals(2, requests.count { it["operation"]!!.jsonPrimitive.content == "configure" })
        fail = false
        gate = CompletableDeferred()
        memory.refresh(profile); runCurrent()
        memory.reset(); gate!!.complete(Unit); runCurrent()
        assertEquals(MemoryState(), memory.state.value)
        http.close()
    }
}
