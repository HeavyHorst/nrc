package dev.nrc.chat

import io.ktor.client.HttpClient
import io.ktor.client.request.*
import io.ktor.client.statement.bodyAsText
import io.ktor.http.*
import io.ktor.http.content.OutgoingContent
import io.ktor.utils.io.ByteReadChannel
import kotlinx.coroutines.*
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.datetime.Clock
import kotlinx.serialization.json.*

/** Audio goes directly to the provider; authenticated HTTP stays on NRC's transport. */
interface VoiceAudio {
    suspend fun offer(onEvent: (String) -> Unit): String
    suspend fun answer(sdp: String)
    fun mute(muted: Boolean)
    fun close()
}

data class VoiceAction(val id: String, val title: String, val fields: String)
data class VoiceState(
    val visible: Boolean = false,
    val workspace: String = "",
    val active: Boolean = false,
    val starting: Boolean = false,
    val ready: Boolean = false,
    val muted: Boolean = false,
    val seconds: Int = 0,
    val status: String = "Bereit",
    val answer: String = "",
    val sources: List<String> = emptyList(),
    val actions: List<VoiceAction> = emptyList(),
    val selected: Set<String> = emptySet(),
    val canApprove: Boolean = false,
    val resolving: Boolean = false,
    val submitted: Boolean = false,
    val outcome: String = "",
    val privacy: String = "",
    val contextDelivery: String = "",
)

/** Main-thread confined. Never retries creation or writes, including after a lost HTTP reply. */
class VoiceClient(private val http: HttpClient, private val scope: CoroutineScope,
    private val audioFactory: () -> VoiceAudio) {
    val memory = PersonalMemory(http, scope) { invalidateMemory() }
    private val mutable = MutableStateFlow(VoiceState())
    val state = mutable.asStateFlow()
    private var audio: VoiceAudio? = null
    private var profile = Profile("", "")
    private var id = ""
    private var revision = ""
    private var plan = ""
    private var speech = false
    private var speechRevision = ""
    private var speechEvents = 0
    private var approvalRevision: String? = null
    private var consumedRevision: String? = null
    private var deadline = 0L
    private var generation = 0
    private var memoryInvalidated = false
    private var poll: Job? = null
    private var clock: Job? = null
    private val pretty = Json { prettyPrint = true }
    private fun now() = Clock.System.now().toEpochMilliseconds()
    private fun update(change: (VoiceState) -> VoiceState) { mutable.value = change(mutable.value) }

    fun start(target: Profile) {
        if (state.value.active || state.value.starting || state.value.resolving || memory.state.value.busy) return
        val temporary = memory.state.value.temporary
        ChatClient.connectionUrl(target) // Same HTTPS-origin validation as chat.
        poll?.cancel(); clock?.cancel()
        val run = ++generation
        memoryInvalidated = false
        profile = target; id = ""; revision = ""; plan = ""
        speech = false; speechRevision = ""; approvalRevision = null; consumedRevision = null
        mutable.value = VoiceState(visible = true, workspace = target.workspace, active = true,
            starting = true, status = "Mikrofon wird verbunden …")
        scope.launch {
            try {
                if (run != generation || !state.value.active) return@launch
                update { it.copy(status = "Gedächtnis-Einstellung wird geprüft …") }
                val remember = !temporary && memory.inspect(target).enabled
                if (run != generation || !state.value.active) return@launch
                update { it.copy(privacy = if (remember) "Persönlich · Gedächtnis aktiviert" else "Temporär · ohne persönliches Gedächtnis") }
                val media = audioFactory().also { audio = it }
                val sdp = media.offer { raw -> scope.launch { if (run == generation) event(raw) } }
                if (run != generation || !state.value.active) return@launch
                val created = request("create", buildJsonObject {
                    put("sdp", sdp)
                    put("execution_policy", if (remember) "private" else "temporary")
                    put("require_memory", remember)
                }, target = target)
                if (run != generation) {
                    requestClose(target, created.text("id"))
                    media.close()
                    return@launch
                }
                id = created.text("id")
                require(id.isNotEmpty())
                if (!state.value.active) {
                    if (created.flag("close_only")) media.answer(created.text("sdp"))
                    requestClose()
                    return@launch
                }
                if (created.flag("close_only")) media.mute(true)
                else {
                    // Establish the revision before remote audio can produce transcript events.
                    // Research completion need not advance the first utterance's revision again.
                    val initial = request("status")
                    if (run != generation || !state.value.active) return@launch
                    if (initial.flag("memory_invalidated")) { memory.reset(); invalidateMemory(); return@launch }
                    check(!initial.flag("closed") && initial.text("error").isEmpty())
                    revision = initial.text("revision")
                    require(revision.toULongOrNull() != null)
                }
                media.answer(created.text("sdp"))
                if (run != generation || !state.value.active) return@launch
                if (created.flag("close_only")) { end("Serververbindung fehlgeschlagen. Gespräch beendet."); return@launch }
                update { it.copy(starting = false, status = if (it.ready) "Verbunden" else "Warte auf Sullivan …") }
                val started = now()
                clock = scope.launch {
                    while (state.value.active) {
                        delay(1000)
                        val seconds = ((now() - started) / 1000).toInt()
                        update { it.copy(seconds = seconds) }
                        if (seconds >= 600 || (!state.value.ready && seconds >= 15))
                            end("Zeitlimit erreicht. Kein automatischer Neustart.")
                    }
                }
                poll = scope.launch { pollStatus(run) }
            } catch (_: TimeoutCancellationException) { if (run == generation) end("Zeitlimit beim Sprachstart. Kein automatischer Neustart.") }
            catch (cancel: CancellationException) { if (run == generation) end(); throw cancel }
            catch (_: Exception) { if (run == generation) end("Sprachverbindung oder Gedächtnis nicht verfügbar. Kein automatischer Wechsel zu temporär. Einstellung und Netzwerk prüfen.") }
            finally {
                if (run == generation) {
                    if (!state.value.active) { audio?.close(); audio = null }
                    update { it.copy(starting = false) }
                }
            }
        }
    }

    fun denied() { mutable.value = VoiceState(visible = true, status = "Mikrofon nicht freigegeben. Erneut über Sullivan Sprache starten.") }
    fun dismiss() { if (!state.value.active && !state.value.starting && !state.value.resolving) update { it.copy(visible = false) } }
    /** Old-account results may still settle, but must not appear in a new account. */
    fun hide() {
        end(); generation++; poll?.cancel(); clock?.cancel()
        audio?.close(); audio = null
        memory.reset(); mutable.value = VoiceState()
    }

    /** Forget evidence, not the fact that an already submitted write may still settle. */
    private fun invalidateMemory() {
        if (memoryInvalidated) return
        end()
        memoryInvalidated = true
        val run = ++generation
        poll?.cancel(); clock?.cancel()
        audio?.close(); audio = null
        plan = ""; revision = ""; speechRevision = ""; speech = false
        val previous = state.value
        mutable.value = VoiceState(visible = previous.visible, workspace = previous.workspace,
            resolving = previous.resolving, submitted = previous.submitted,
            status = "Persönlicher Gesprächskontext gelöscht. Gespräch beendet.",
            outcome = if (previous.resolving || previous.submitted)
                "Bestätigungsausgang prüfen; nicht erneut ausführen." else "")
        if (previous.resolving) poll = scope.launch { pollStatus(run) }
    }
    fun mute() {
        if (!state.value.active || !state.value.ready) return
        val muted = !state.value.muted
        audio?.mute(muted); update { it.copy(muted = muted) }
    }
    fun end(message: String = "Gespräch beendet. Abschlussverbrauch unbestätigt.") {
        if (!state.value.active) return
        // Keep a pending SDP exchange alive long enough to close a late provider
        // session, but stop capture immediately even before create has replied.
        audio?.mute(true)
        if (!state.value.starting) { audio?.close(); audio = null }
        clock?.cancel()
        update { it.copy(active = false, ready = false, canApprove = false, selected = emptySet(), status = message) }
        val target = profile
        val session = id
        val run = generation
        if (session.isNotEmpty()) scope.launch {
            requestClose(target, session)
            // Audio closure can precede the HTTP invalidation signal while the regular
            // poll is sleeping. Always make one bounded terminal read, even without an
            // approval to reconcile. Never infer deletion from ordinary closure/errors.
            if (run != generation || memoryInvalidated) return@launch
            try {
                val data = request("status", target = target, session = session)
                if (run == generation && data.flag("memory_invalidated")) {
                    memory.reset()
                    invalidateMemory()
                }
            } catch (_: TimeoutCancellationException) { /* No automatic retry. */ }
            catch (cancel: CancellationException) { throw cancel }
            catch (_: Exception) { /* Unconfirmed terminal status is not deletion. */ }
        }
    }
    private suspend fun requestClose(target: Profile = profile, session: String = id) {
        try { request("close", target = target, session = session) }
        catch (_: TimeoutCancellationException) { /* Server watchdog expires abandoned sessions. */ }
        catch (cancel: CancellationException) { throw cancel }
        catch (_: Exception) { /* No automatic retry. */ }
    }

    private fun event(raw: String) {
        if (!state.value.active) return
        val data = runCatching { Json.parseToJsonElement(raw).jsonObject }.getOrNull() ?: return
        when (data.text("type")) {
            "session.started" -> update { it.copy(ready = true, status = "Verbunden") }
            "session.input_transcript.delta" -> {
                speechEvents++
                speech = true
                speechRevision = revision
                update { it.copy(canApprove = false, selected = emptySet()) }
            }
            "session.closed" -> end("Gespräch beendet.")
            "error", "transport.closed" -> end("Sprachverbindung unterbrochen. Kein automatischer Neustart.")
        }
    }

    fun select(action: String, selected: Boolean) {
        if (!state.value.canApprove || state.value.actions.none { it.id == action }) return
        update { it.copy(selected = if (selected) it.selected + action else it.selected - action) }
    }

    @OptIn(kotlinx.serialization.ExperimentalSerializationApi::class)
    fun approve() {
        val current = state.value
        if (!current.active || !current.canApprove || current.resolving || current.selected.isEmpty()) return
        val approvedPlan = plan
        val approvedRevision = revision
        val target = profile
        val session = id
        val selected = current.selected
        val run = generation
        approvalRevision = revision; consumedRevision = revision; deadline = now() + 60_000
        update { it.copy(resolving = true, submitted = true, canApprove = false, selected = emptySet(), outcome = "Bestätigung wird geprüft. Nicht erneut ausführen.") }
        scope.launch {
            try {
                val result = request("apply", buildJsonObject {
                    put("plan_id", approvedPlan)
                    put("revision", JsonPrimitive(approvedRevision.toULong()))
                    put("action_ids", JsonArray(selected.map(::JsonPrimitive)))
                }, target = target, session = session)
                if (run == generation) receipt(result, approvedRevision)
            } catch (_: TimeoutCancellationException) { /* Reconcile through status. */ }
            catch (cancel: CancellationException) { throw cancel }
            catch (_: Exception) { /* Status polling reconciles this exact revision, never retries. */ }
        }
    }

    private fun receipt(result: JsonObject, receivedRevision: String) {
        if (!state.value.resolving || receivedRevision != approvalRevision) return
        val failed = !result.flag("ok") || result.array("failed").isNotEmpty()
        update { it.copy(resolving = false, actions = emptyList(), canApprove = false,
            outcome = (if (failed) "Ausgang unbestätigt oder fehlgeschlagen. Datensätze prüfen; nicht erneut ausführen.\n"
                else "${result.array("applied").size} Aktionen erfolgreich.\n") +
                (if (memoryInvalidated) "" else pretty.encodeToString(JsonObject.serializer(), result))) }
        if (failed) end("Ausführung prüfen. Gespräch beendet.")
    }

    private suspend fun pollStatus(run: Int) {
        while (run == generation && (state.value.active || state.value.resolving)) {
            try {
                val beforeRequest = speechEvents
                val data = request("status")
                if (run != generation) return
                if (data.flag("memory_invalidated") && !memoryInvalidated) {
                    memory.reset()
                    invalidateMemory()
                    return
                }
                val delivery = (data["context_delivery"] as? JsonObject)?.values.orEmpty()
                    .mapNotNull { (it as? JsonObject)?.text("state") }
                update { it.copy(contextDelivery = when {
                    memoryInvalidated -> ""
                    "rejected" in delivery -> "Provider-Kontext abgelehnt. Keine automatische Wiederholung."
                    "unconfirmed" in delivery -> "Provider-Kontext unbestätigt. Keine automatische Wiederholung."
                    "pending" in delivery -> "Provider-Kontext: Zustellung ausstehend."
                    else -> ""
                }) }
                (data["apply_result"] as? JsonObject)?.let { receipt(it, data.text("apply_revision")) }
                if (state.value.resolving && !data.flag("applying") && data.text("error").isNotEmpty() &&
                    data.text("apply_revision") == approvalRevision) {
                    update { it.copy(resolving = false, outcome = "Ausgang unbestätigt oder abgelehnt. Datensätze prüfen; nicht erneut ausführen.") }
                }
                if (data.flag("closed") && state.value.active) end("Gespräch beendet.")
                if (state.value.active) {
                    val nextRevision = data.text("revision")
                    val revisionChanged = revision != nextRevision
                    if (speech) {
                        // A response overlapping speech may advance the displayed revision,
                        // but must not consume the transition that acknowledges that speech.
                        if (speechRevision.isEmpty()) speechRevision = nextRevision
                        else if (beforeRequest == speechEvents && speechRevision != nextRevision) speech = false
                    }
                    revision = nextRevision
                    val result = data["result"] as? JsonObject
                    val nextPlan = result?.text("plan_id").orEmpty()
                    val actions = result?.array("proposed_actions").orEmpty().map { value ->
                        val action = value.jsonObject
                        VoiceAction(action.text("id"), action.text("title").ifEmpty { action.text("type") },
                            pretty.encodeToString(JsonObject.serializer(), action))
                    }
                    val allowed = state.value.ready && !speech && data.text("error").isEmpty() && !state.value.resolving && consumedRevision != revision &&
                        !data.flag("busy") && !data.flag("applying") && nextPlan.isNotEmpty() && actions.isNotEmpty()
                    val changed = revisionChanged || plan != nextPlan || state.value.actions != actions
                    plan = nextPlan
                    update { it.copy(answer = result?.text("answer").orEmpty(),
                        sources = result?.array("sources").orEmpty().map { source ->
                            val item = source.jsonObject
                            "${item.text("title")} · ${item.text("type")} #${item.text("id")}"
                        }, actions = actions, canApprove = allowed, submitted = consumedRevision == revision,
                        selected = if (changed || !allowed) emptySet() else it.selected,
                        status = when { data.text("error").isNotEmpty() -> data.text("error")
                            data.flag("applying") -> "Bestätigte Aktionen werden ausgeführt …"
                            data.flag("busy") -> "Sullivan recherchiert …"
                            !it.ready -> "Warte auf Sullivan …"
                            else -> "Verbunden" }) }
                }
                if (!memoryInvalidated && !state.value.active && data.flag("final_usage")) update {
                    it.copy(status = "Gespräch beendet · ${data.text("seconds")} Sekunden Provider-Nutzung")
                }
            } catch (_: TimeoutCancellationException) { if (run == generation && state.value.active) end("Status-Zeitlimit. Gespräch beendet.") }
            catch (cancel: CancellationException) { throw cancel }
            catch (_: Exception) { if (run == generation && state.value.active) end("Status nicht erreichbar. Gespräch beendet.") }
            if (run != generation) return
            if (state.value.resolving && now() >= deadline) {
                update { it.copy(resolving = false, outcome = "Ausgang weiterhin unbestätigt. Datensätze prüfen; Bestätigung nicht wiederholen.") }
                end()
            }
            delay(500)
        }
    }

    private suspend fun request(operation: String, extra: JsonObject = JsonObject(emptyMap()),
        target: Profile = profile, session: String = id): JsonObject {
        return withTimeout(if (operation == "create" || operation == "apply") 45_000 else 10_000) {
            val url = URLBuilder(target.server.trim()).apply {
                protocol = URLProtocol.HTTPS; encodedPath = "/ai/voice/$operation"
            }.buildString()
            val response = http.post(url) {
                val payload = buildJsonObject {
                    put("workspace", target.workspace); put("id", session)
                    extra.forEach { (key, value) -> put(key, value) }
                }.toString().encodeToByteArray()
                // Ktor's OkHttp engine marks channel bodies one-shot. A JSON
                // string body can otherwise be replayed after a 503/Retry-After.
                setBody(object : OutgoingContent.ReadChannelContent() {
                    override val contentType = ContentType.Application.Json
                    override val contentLength = payload.size.toLong()
                    override fun readFrom() = ByteReadChannel(payload)
                })
            }
            check(response.status.isSuccess())
            Json.parseToJsonElement(response.bodyAsText()).jsonObject
        }
    }
}

private fun JsonObject.text(key: String) = (get(key) as? JsonPrimitive)?.contentOrNull.orEmpty()
private fun JsonObject.flag(key: String) = (get(key) as? JsonPrimitive)?.booleanOrNull == true
private fun JsonObject.array(key: String) = (get(key) as? JsonArray).orEmpty()
