package dev.nrc.chat

import kotlinx.serialization.Serializable

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
)

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
