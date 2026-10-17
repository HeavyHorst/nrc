package dev.nrc.chat

import kotlinx.serialization.json.Json
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive

/** Only chat opcodes; all integers use the server's big-endian wire format. */
object Protocol {
    const val VERSION = 9
    const val MAX_CONTENT_BYTES = 50 * 1024

    fun send(conversation: Long, request: Int, text: String, messageId: ByteArray? = null): ByteArray {
        require(text.isNotBlank() && text.encodeToByteArray().size <= MAX_CONTENT_BYTES)
        return Writer(if (messageId == null) 1 else 48).apply {
            long(conversation)
            if (messageId != null) { require(messageId.size == 16 && messageId.any { it != 0.toByte() }); bytes(messageId) }
            int(request); byte(0); string(text)
        }.result()
    }

    fun subscribe(ids: List<Long>, request: Int) = Writer(49).apply {
        require(ids.size <= 64); short(ids.size); ids.forEach { long(it) }; int(request)
    }.result()
    fun rooms(request: Int, updated: Long? = null, asset: Long = 0) = Writer(35).apply {
        long(0); short(7); byte(1); short(100); byte(if (updated == null) 0 else 1)
        if (updated != null) { long(updated); long(asset); int(request) }
        else { int(request); long(0) } // legacy minimum-size padding
    }.result()
    fun ping(nanos: Long) = Writer(19).apply { long(nanos) }.result()
    fun listDMs(request: Int) = Writer(17).apply { int(request) }.result()
    fun startDM(username: String, request: Int) = Writer(16).apply { string(username); int(request) }.result()
    fun history(id: Long, cursor: Long, request: Int, ascending: Boolean = false) = Writer(if (ascending) 51 else 50).apply {
        long(id); long(cursor); short(100); int(request)
    }.result()

    sealed interface Event
    data class Ready(val version: Int, val username: String, val authenticated: Boolean) : Event
    data class Incoming(val message: Message) : Event
    data class Ack(val request: Int, val sequence: Long, val nanos: Long) : Event
    data class Error(val origin: Int, val text: String, val request: Int) : Event
    data class Subscribed(val entries: List<Subscription>, val request: Int) : Event
    data class Subscription(val id: Long, val highWater: Long, val cutoff: Long)
    data class Page(val id: Long, val ascending: Boolean, val hasMore: Boolean, val truncated: Boolean,
                    val cursor: Long, val request: Int, val messages: List<Message>, val highWater: Long = 0) : Event
    data class DMs(val conversations: List<Conversation>) : Event
    data class DMStarted(val conversation: Conversation, val initiator: Boolean) : Event
    data class DMLeft(val id: Long) : Event
    data class Rooms(val conversations: List<Conversation>, val more: Boolean, val updated: Long, val asset: Long) : Event
    data class Presence(val id: Long, val kind: Int, val sequence: Long, val name: String,
                        val oldName: String, val users: Set<String>) : Event
    data object Pong : Event
    data object Ignored : Event

    fun decode(frame: ByteArray): Event {
        val r = Reader(frame)
        val event = when (r.short()) {
            100 -> { r.string(); val version = r.int(); r.string(); Ready(version, r.string(255), r.bool()) }
            102 -> Incoming(r.message(false))
            103 -> Ack(r.int(), r.long(), r.long())
            104 -> Error(r.short(), r.string(), r.int())
            109 -> {
                val id = r.long(); val kind = r.byte(); val sequence = r.long()
                val name = r.string(255); r.bool(); r.byte() // user type
                val old = r.string(255)
                val users = List(r.count(4096)) { val user = r.string(255); r.bool(); r.byte(); user }.toSet()
                Presence(id, kind, sequence, name, old, users)
            }
            121 -> {
                val id = r.long(); val name = r.string(255); r.bool(); r.bool(); val initiator = r.bool(); r.int()
                DMStarted(Conversation(id, name, true), initiator)
            }
            122 -> {
                val count = r.count(4096); r.int()
                DMs(List(count) { val id = r.long(); val name = r.string(255); r.bool(); r.bool(); r.long(); Conversation(id, name, true) })
            }
            123 -> { r.byte(); r.string(255); Error(16, r.string(), r.int()) }
            124 -> { val id = r.long(); r.int(); DMLeft(id) }
            126 -> { r.long(); r.long(); Pong }
            145 -> {
                require(r.long() == 0L && r.bool())
                val more = r.bool(); val updated = r.long(); val asset = r.long(); r.int()
                val count = r.count(100); r.int()
                Rooms(List(count) { r.room() }, more, updated, asset)
            }
            158 -> {
                val request = r.int()
                Subscribed(List(r.count(64)) { Subscription(r.long(), r.long(), r.long()) }, request)
            }
            159 -> {
                val id = r.long(); val ascending = r.bool(); val more = r.bool(); val truncated = r.bool()
                val highWater = r.long(); r.long(); val cursor = r.long(); val request = r.int()
                Page(id, ascending, more, truncated, cursor, request, List(r.count(100)) { r.message(true) }, highWater)
            }
            else -> return Ignored
        }
        require(r.remaining == 0) { "Trailing bytes in chat frame" }
        return event
    }

    private class Writer(opcode: Int) {
        private val data = ArrayList<Byte>()
        init { short(opcode) }
        fun byte(value: Int) { data.add(value.toByte()) }
        fun short(value: Int) { byte(value ushr 8); byte(value) }
        fun int(value: Int) { for (shift in 24 downTo 0 step 8) byte(value ushr shift) }
        fun long(value: Long) { for (shift in 56 downTo 0 step 8) byte((value ushr shift).toInt()) }
        fun bytes(value: ByteArray) { value.forEach { data.add(it) } }
        fun string(value: String) { val encoded = value.encodeToByteArray(); require(encoded.size <= 65535); short(encoded.size); bytes(encoded) }
        fun result() = data.toByteArray()
    }

    private class Reader(private val data: ByteArray) {
        private var position = 0
        val remaining get() = data.size - position
        fun byte(): Int { require(remaining >= 1) { "Truncated chat frame" }; return data[position++].toInt() and 255 }
        fun bool(): Boolean { val b = byte(); require(b <= 1); return b == 1 }
        fun short() = (byte() shl 8) or byte()
        fun int(): Int { var n = 0; repeat(4) { n = (n shl 8) or byte() }; return n }
        fun long(): Long { var n = 0L; repeat(8) { n = (n shl 8) or byte().toLong() }; return n }
        fun count(max: Int): Int = short().also { require(it <= max) }
        fun string(max: Int = 65535): String {
            val size = count(max); require(remaining >= size)
            val text = data.decodeToString(position, position + size, throwOnInvalidSequence = true)
            position += size; return text
        }
        fun room(): Conversation {
            require(short() == 7); long(); short(); long(); string(); long(); long()
            require(long() == 0L && byte() == 0) { "Room mapping must be plain workspace JSON" }
            int(); val preview = string(); val payload = string()
            repeat(count(10)) { string(); string(); long(); string(); long() }
            val mapping = Json.parseToJsonElement(payload).jsonObject
            val id = mapping.getValue("conv_id").jsonPrimitive.content.toULong().toLong()
            require(id > 0)
            val name = (mapping["display_name"] ?: mapping["normalized_name"])?.jsonPrimitive?.content ?: preview
            return Conversation(id, name.lowercase())
        }
        fun message(retained: Boolean): Message {
            val id = long(); val sequence = long()
            val clientId = if (retained) ByteArray(16) { byte().toByte() }.messageIdString() else null
            val name = string(255); val nanos = long(); val type = byte(); require(type <= 2)
            val text = string(MAX_CONTENT_BYTES)
            return Message("$id:$sequence", id, sequence, name, nanos,
                text, clientMessageId = clientId)
        }
    }
}
