package dev.nrc.chat

import kotlinx.serialization.Serializable
import kotlinx.serialization.json.*
import io.ktor.http.*

enum class Connection { Disconnected, Connecting, Connected, Reconnecting }
enum class Delivery { Received, Sending, Sent, Unconfirmed, Failed }
enum class Retention { Unknown, Enabled, Ephemeral }

@Serializable
data class Profile(val server: String = "", val workspace: String = "workspace1")

@Serializable
data class Conversation(val id: Long, val name: String, val direct: Boolean = false)

fun Conversation.draftKey() = if (direct) "dm:$name" else "room:$id"

@Serializable
data class Message(
    val key: String, val conversationId: Long, val sequence: Long = 0,
    val author: String, val timestampNanos: Long, val text: String,
    val delivery: Delivery = Delivery.Received, val requestId: Int = 0,
    val clientMessageId: String? = null,
)

/** The web client's version-1 attachment envelope, not an arbitrary remote image URL. */
data class ChatAttachment(val fileId: String, val filename: String, val size: Long, val mimeType: String) {
    fun fileUrl(profile: Profile, inline: Boolean = true): String {
        ChatClient.connectionUrl(profile) // Same validated origin/workspace as the chat connection.
        return URLBuilder(profile.server.trim()).apply {
            protocol = URLProtocol.HTTPS
            encodedPath = "/files/$fileId"
            parameters.append("workspace", profile.workspace)
            if (inline) parameters.append("inline", "true")
            parameters.append("filename", filename)
        }.buildString()
    }

    fun messageText(): String = buildJsonObject {
        put("type", "attachment"); put("version", 1); put("fileId", fileId)
        put("filename", filename); put("size", size); put("mimeType", mimeType)
        // The web parser requires exact URLSearchParams serialization, including ~ and *.
        val query = listOf("filename" to filename).formUrlEncode().replace("~", "%7E").replace("%2A", "*")
        put("url", "/files/$fileId?$query")
    }.toString()

    companion object {
        fun parse(content: String): ChatAttachment? = runCatching {
            if (!content.trimStart().startsWith('{')) return null
            val json = Json.parseToJsonElement(content).jsonObject
            fun string(key: String) = json.getValue(key).jsonPrimitive.let { require(it.isString); it.content }
            require(string("type") == "attachment")
            require(json.getValue("version").jsonPrimitive.let { !it.isString && it.int == 1 })
            val id = string("fileId")
            require(Regex("att_[0-9a-f]{32}").matches(id))
            val filename = string("filename")
            require(filename.isNotBlank() && filename.none { it.code < 32 || it.code == 127 })
            val size = json.getValue("size").jsonPrimitive.let { require(!it.isString); it.long }
            require(size in 0..100L * 1024 * 1024)
            val mime = string("mimeType")
            val relative = string("url")
            require(relative.startsWith("/files/$id?"))
            val url = Url("https://attachment.invalid$relative")
            require(url.encodedPath == "/files/$id" && url.fragment.isEmpty() &&
                url.parameters.names() == setOf("filename") &&
                url.parameters.getAll("filename") == listOf(filename))
            ChatAttachment(id, filename, size, mime)
        }.getOrNull()
    }
}

data class ChatState(
    val profile: Profile = Profile(), val connection: Connection = Connection.Disconnected,
    val username: String = "", val conversations: List<Conversation> = defaultRooms,
    val selected: Long? = null, val messages: Map<Long, List<Message>> = emptyMap(),
    val drafts: Map<Long, String> = emptyMap(), val unread: Map<Long, Int> = emptyMap(),
    val members: Map<Long, Set<String>> = emptyMap(), val retention: Map<Long, Retention> = emptyMap(),
    val olderCursor: Map<Long, Long> = emptyMap(), val loadingHistory: Set<Long> = emptySet(),
    val failedHistory: Set<Long> = emptySet(),
    val syncPaused: Set<Long> = emptySet(), val storageBlocked: Boolean = false,
    val liveDMs: Set<Long> = emptySet(),
    val notice: String? = null, val preview: Boolean = false,
    val diagnostics: List<DiagnosticEvent> = emptyList(),
    val fileTransfer: FileTransfer? = null,
)

data class AttachmentTarget(val profile: Profile, val username: String, val conversationId: Long)
data class FileTransfer(val filename: String, val uploading: Boolean, val bytes: Long = 0, val total: Long = 0)

val defaultRooms = listOf(Conversation(2, "engineering"), Conversation(3, "operations"))

fun ByteArray.messageIdString() = joinToString("") { (it.toInt() and 255).toString(16).padStart(2, '0') }

/** Implementations must keep workspace drafts isolated and commit changes before returning. */
interface LocalStore {
    fun profile(): Profile
    fun saveProfile(profile: Profile)
    fun drafts(profile: Profile): Map<String, String>
    fun saveDraft(profile: Profile, conversationKey: String, text: String)
    fun clearDrafts(profile: Profile)
    /** Device-wide, bounded, sanitized operational events; never chat/profile data. */
    fun diagnostics(): List<DiagnosticEvent> = emptyList()
    fun saveDiagnostics(events: List<DiagnosticEvent>) {}
}

/** A device-local copy, not an outbox or a change to server retention policy. */
@Serializable
data class CachedChat(
    val username: String = "",
    val conversations: List<Conversation> = defaultRooms,
    val messages: Map<Long, List<Message>> = emptyMap(),
    val unread: Map<Long, Int> = emptyMap(),
    val replayFrom: Map<Long, Long> = emptyMap(),
    val loadedHistory: Set<Long> = emptySet(),
    val olderCursor: Map<Long, Long> = emptyMap(),
    val seenThrough: Map<Long, Long> = emptyMap(),
    val seenAhead: Map<Long, Set<Long>> = emptyMap(),
    val observedHighWater: Long = 0,
    val baselineEstablished: Set<Long> = emptySet(),
    val replayNeededThrough: Map<Long, Long> = emptyMap(),
    val syncPaused: Set<Long> = emptySet(),
    val receiptsAuthoritative: Boolean = false,
)

interface MessageStore {
    suspend fun load(profile: Profile): CachedChat?
    suspend fun save(profile: Profile, chat: CachedChat)
}
