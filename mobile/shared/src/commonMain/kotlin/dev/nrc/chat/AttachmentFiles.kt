package dev.nrc.chat

import io.ktor.client.HttpClient
import io.ktor.client.plugins.expectSuccess
import io.ktor.client.plugins.onUpload
import io.ktor.client.request.*
import io.ktor.client.request.forms.*
import io.ktor.client.statement.bodyAsChannel
import io.ktor.http.*
import io.ktor.utils.io.ByteReadChannel
import io.ktor.utils.io.readAvailable
import kotlinx.coroutines.*
import kotlinx.serialization.json.*
import kotlin.coroutines.CoroutineContext

const val MAX_ATTACHMENT_BYTES = 100L * 1024 * 1024

/** A stable, platform-owned staging file. Readers are children of this transfer's job. */
data class AttachmentUpload(val filename: String, val mimeType: String, val size: Long,
                            val open: (CoroutineContext) -> ByteReadChannel)

/** Uses the chat host's redirect-disabled client and ordinary Tailscale identity, never bot auth. */
class AttachmentFiles(private val http: HttpClient) {
    suspend fun upload(profile: Profile, room: Long, file: AttachmentUpload,
                       progress: suspend (Long, Long) -> Unit): ChatAttachment = coroutineScope {
        ChatClient.connectionUrl(profile)
        require(file.size in 0..MAX_ATTACHMENT_BYTES)
        require(file.filename.isNotBlank() && file.filename.none { it.code < 32 || it.code == 127 })
        require(Regex("[A-Za-z0-9.+_-]+/[A-Za-z0-9.+_-]+").matches(file.mimeType))
        val url = URLBuilder(profile.server.trim()).apply {
            protocol = URLProtocol.HTTPS; encodedPath = "/upload"
            parameters.append("workspace", profile.workspace)
        }.buildString()
        val readers = Job(coroutineContext[Job])
        val readerContext = coroutineContext + readers
        try {
            withTimeout(5 * 60_000L) {
                http.preparePost(url) {
                    expectSuccess = false
                    setBody(MultiPartFormDataContent(formData {
                        append("room", room.toULong().toString())
                        append("file", ChannelProvider(file.size) { file.open(readerContext) }, Headers.build {
                            val quoted = file.filename.replace("\\", "\\\\").replace("\"", "\\\"")
                            append(HttpHeaders.ContentDisposition, "filename=\"$quoted\"")
                            append(HttpHeaders.ContentType, file.mimeType)
                        })
                    }))
                    onUpload { sent, total -> progress(sent, total ?: 0) }
                }.execute { response ->
                    check(response.status.value == 200) { "Upload rejected (HTTP ${response.status.value})" }
                    val channel = response.bodyAsChannel()
                    val buffer = ByteArray(64 * 1024 + 1)
                    var count = 0
                    while (count < buffer.size) {
                        val n = channel.readAvailable(buffer, count, buffer.size - count)
                        if (n < 0) break
                        count += n
                    }
                    channel.closedCause?.let { throw it }
                    check(count <= 64 * 1024) { "Upload response exceeds limit" }
                    val json = Json.parseToJsonElement(buffer.decodeToString(0, count)).jsonObject
                    fun string(key: String) = json.getValue(key).jsonPrimitive.let { require(it.isString); it.content }
                    val attachment = ChatAttachment(
                        string("fileId"), string("filename"),
                        json.getValue("size").jsonPrimitive.let { require(!it.isString); it.long },
                        string("mimeType"),
                    )
                    require(Regex("[A-Za-z0-9.+_-]+/[A-Za-z0-9.+_-]+").matches(attachment.mimeType))
                    check(attachment.size == file.size && ChatAttachment.parse(attachment.messageText()) == attachment) {
                        "Invalid upload response"
                    }
                    attachment
                }
            }
        } finally { readers.cancel() }
    }

    suspend fun download(profile: Profile, attachment: ChatAttachment,
                         progress: suspend (Long, Long) -> Unit,
                         write: suspend (ByteArray, Int) -> Unit) = withTimeout(5 * 60_000L) {
        require(ChatAttachment.parse(attachment.messageText()) == attachment)
        http.prepareGet(attachment.fileUrl(profile, inline = false)) { expectSuccess = false }.execute { response ->
            check(response.status.value == 200) { "Download rejected (HTTP ${response.status.value})" }
            val total = response.headers[HttpHeaders.ContentLength]?.toLongOrNull() ?: 0
            check(total in 0..MAX_ATTACHMENT_BYTES) { "File exceeds 100 MiB" }
            val channel = response.bodyAsChannel()
            val buffer = ByteArray(32 * 1024)
            var count = 0L
            while (true) {
                currentCoroutineContext().ensureActive()
                val n = channel.readAvailable(buffer)
                if (n < 0) break
                count += n
                check(count <= MAX_ATTACHMENT_BYTES) { "File exceeds 100 MiB" }
                write(buffer, n); progress(count, total)
            }
            channel.closedCause?.let { throw it }
            check(total == 0L || count == total) { "Incomplete download" }
            check(count == attachment.size) { "File size does not match attachment" }
        }
    }
}
