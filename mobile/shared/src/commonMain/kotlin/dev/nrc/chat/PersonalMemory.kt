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
import kotlinx.serialization.json.*

data class MemoryPolicy(val epoch: Long, val enabled: Boolean)
data class MemoryState(
    val busy: Boolean = false,
    val policy: MemoryPolicy? = null,
    val temporary: Boolean = false,
    val message: String = "",
    val export: String = "",
)

/** Same authenticated transport as voice. No local retention of exported personal data. */
class PersonalMemory(private val http: HttpClient, private val scope: CoroutineScope,
    private val onForgotten: () -> Unit = {}) {
    private val mutable = MutableStateFlow(MemoryState())
    val state = mutable.asStateFlow()
    private var generation = 0
    private var job: Job? = null
    private val pretty = Json { prettyPrint = true }
    fun reset() { generation++; job?.cancel(); mutable.value = MemoryState() }
    fun temporary(value: Boolean) { mutable.value = state.value.copy(temporary = value) }

    suspend fun inspect(target: Profile): MemoryPolicy = policy(request(target, "inspect"))
    fun refresh(target: Profile) = perform { it.copy(policy = inspect(target), message = "", export = "") }
    fun configure(target: Profile, enabled: Boolean) {
        val current = state.value.policy ?: return
        perform {
            val result = request(target, "configure", buildJsonObject {
                put("confirm", true)
                put("policy", buildJsonObject { put("epoch", current.epoch); put("enabled", enabled) })
            })
            it.copy(policy = policy(result), export = "", message = "Einstellung gespeichert.")
        }
    }
    fun forgetAll(target: Profile) {
        val current = state.value.policy ?: return
        perform(onSuccess = onForgotten) {
            val result = request(target, "forget_all", buildJsonObject {
                put("epoch", current.epoch); put("confirm", true)
            })
            it.copy(policy = policy(result), export = "", message = "Persönliche Erinnerungen gelöscht.")
        }
    }
    fun clearExport() { mutable.value = state.value.copy(export = "") }
    fun export(target: Profile, ready: (String, () -> Boolean) -> Unit = { _, _ -> }) {
        val current = state.value.policy ?: return
        val run = generation
        perform(onSuccess = {
            val data = state.value.export
            ready(data) { run == generation && state.value.policy == current && state.value.export === data }
        }) {
            val all = mutableListOf<JsonElement>()
            var after = -1L
            do {
                val result = request(target, "export", buildJsonObject {
                    put("epoch", current.epoch); put("after", after); put("limit", 100)
                })
                val rows = if (result is JsonNull) JsonArray(emptyList()) else result.jsonArray
                for (row in rows) {
                    val sequence = row.jsonObject["sequence"]!!.jsonPrimitive.long
                    check(sequence > after)
                    after = sequence
                }
                all.addAll(rows)
            } while (rows.size == 100)
            check(inspect(target) == current)
            it.copy(export = pretty.encodeToString(JsonArray.serializer(), JsonArray(all)),
                message = "Export bereit · ${all.size} Einträge.")
        }
    }
    private fun perform(onSuccess: () -> Unit = {}, action: suspend (MemoryState) -> MemoryState) {
        if (state.value.busy) return
        val run = generation
        val before = state.value
        mutable.value = before.copy(busy = true, message = "", export = "")
        job = scope.launch {
            try {
                val result = action(before)
                if (run == generation) {
                    mutable.value = result.copy(busy = false)
                    onSuccess()
                }
            } catch (e: CancellationException) {
                if (e !is TimeoutCancellationException) throw e
                if (run == generation) failed()
            } catch (_: Exception) { if (run == generation) failed() }
        }
    }
    private fun failed() {
        mutable.value = state.value.copy(busy = false, policy = null, export = "",
            message = "Gedächtnis nicht erreichbar oder Stand geändert. Ausgang unbestätigt; Status neu laden. Keine automatische Wiederholung.")
    }
    private fun policy(value: JsonElement): MemoryPolicy {
        val data = value.jsonObject
        return MemoryPolicy(data["epoch"]!!.jsonPrimitive.long.also { require(it >= 0) },
            data["enabled"]!!.jsonPrimitive.boolean)
    }
    private suspend fun request(target: Profile, operation: String, extra: JsonObject = JsonObject(emptyMap())): JsonElement = withTimeout(10_000) {
        ChatClient.connectionUrl(target)
        val url = URLBuilder(target.server.trim()).apply { protocol = URLProtocol.HTTPS; encodedPath = "/ai/ask/memory" }.buildString()
        val payload = buildJsonObject {
            put("workspace", target.workspace); put("operation", operation)
            extra.forEach { (key, value) -> put(key, value) }
        }.toString().encodeToByteArray()
        val response = http.post(url) {
            setBody(object : OutgoingContent.ReadChannelContent() {
                override val contentType = ContentType.Application.Json
                override val contentLength = payload.size.toLong()
                override fun readFrom() = ByteReadChannel(payload)
            })
        }
        check(response.status.isSuccess())
        Json.parseToJsonElement(response.bodyAsText())
    }
}
