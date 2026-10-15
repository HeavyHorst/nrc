package dev.nrc.chat

import io.ktor.client.HttpClient
import io.ktor.client.engine.cio.CIO
import io.ktor.client.plugins.websocket.WebSockets
import io.ktor.utils.io.ByteReadChannel
import kotlinx.coroutines.*
import kotlinx.coroutines.flow.first
import kotlinx.serialization.json.*
import okhttp3.Response
import okhttp3.WebSocket
import okhttp3.WebSocketListener
import okhttp3.mockwebserver.*
import okhttp3.tls.*
import okio.Buffer
import okio.ByteString
import okio.ByteString.Companion.toByteString
import java.io.*
import java.util.concurrent.LinkedBlockingQueue
import java.util.concurrent.TimeUnit
import kotlin.test.*

/** Public transfers over verified TLS and a live WebSocket protocol peer, not a mocked ChatClient. */
class AttachmentFilesTest {
    private val id = "att_0123456789abcdef0123456789abcdef"
    private val name = "Bäume + plan #2.pdf"
    private val mime = "application/pdf"
    private val bytes = ByteArray(97) { (it * 7 + 3).toByte() }
    private fun response(size: Long = bytes.size.toLong()) =
        """{"fileId":"$id","filename":"$name","size":$size,"mimeType":"$mime"}"""
    private fun upload() = AttachmentUpload(name, mime, bytes.size.toLong()) { ByteReadChannel(bytes) }
    private fun frame(op: Int, body: DataOutputStream.() -> Unit) = ByteArrayOutputStream().also {
        DataOutputStream(it).use { stream -> stream.writeShort(op); stream.body() }
    }.toByteArray()
    private fun DataOutputStream.text(s: String) { val b = s.toByteArray(); writeShort(b.size); write(b) }

    private inner class Fixture : AutoCloseable {
        val server = MockWebServer()
        val responses = LinkedBlockingQueue<MockResponse>()
        val uploads = LinkedBlockingQueue<RecordedRequest>()
        val sends = LinkedBlockingQueue<ByteArray>()
        var retained = true
        var username = "alice"
        lateinit var wire: WebSocket
        val profile: Profile
        val http: HttpClient
        init {
            val certificate = HeldCertificate.Builder().commonName("localhost").addSubjectAlternativeName("localhost").build()
            val serverTls = HandshakeCertificates.Builder().heldCertificate(certificate).build()
            val clientTls = HandshakeCertificates.Builder().addTrustedCertificate(certificate.certificate).build()
            server.useHttps(serverTls.sslSocketFactory(), false)
            server.dispatcher = object : Dispatcher() {
                override fun dispatch(request: RecordedRequest): MockResponse {
                    if (request.getHeader("Upgrade")?.equals("websocket", true) == true)
                        return MockResponse().withWebSocketUpgrade(object : WebSocketListener() {
                            override fun onOpen(socket: WebSocket, response: Response) {
                                wire = socket
                                socket.send(frame(100) { text("fixture"); writeInt(8); text("test"); text(username); writeBoolean(true) }.toByteString())
                            }
                            override fun onClosing(socket: WebSocket, code: Int, reason: String) { socket.close(code, reason) }
                            override fun onMessage(socket: WebSocket, data: ByteString) {
                                val input = DataInputStream(ByteArrayInputStream(data.toByteArray()))
                                when (input.readUnsignedShort()) {
                                    49 -> {
                                        val ids = List(input.readUnsignedShort()) { input.readLong() }; val requestId = input.readInt()
                                        socket.send(frame(158) {
                                            writeInt(requestId); writeShort(if (retained) ids.size else 0)
                                            if (retained) ids.forEach { writeLong(it); writeLong(0); writeLong(0) }
                                        }.toByteString())
                                    }
                                    17 -> socket.send(frame(122) { writeShort(0); writeInt(input.readInt()) }.toByteString())
                                    1, 48 -> sends.add(data.toByteArray())
                                }
                            }
                        })
                    uploads.add(request)
                    return responses.poll(5, TimeUnit.SECONDS) ?: MockResponse().setResponseCode(500)
                }
            }
            server.start()
            profile = Profile("https://localhost:${server.port}", "studio_north")
            http = HttpClient(CIO) {
                followRedirects = false; install(WebSockets)
                engine { https { trustManager = clientTls.trustManager } }
            }
        }
        override fun close() { http.close(); server.shutdown() }
    }

    private fun request(f: Fixture): RecordedRequest = assertNotNull(f.uploads.poll(5, TimeUnit.SECONDS))
    private fun cleanHeaders(request: RecordedRequest) {
        assertNull(request.getHeader("Authorization")); assertNull(request.getHeader("Cookie"))
    }

    @Test fun serializedEnvelopeMatchesBrowserUrlSearchParamsForSpecialFilename() {
        val attachment = ChatAttachment(id, "~ * % + Grüß.pdf", 97, "application/pdf")
        val json = Json.parseToJsonElement(attachment.messageText()).jsonObject
        // Independently obtained from browser URLSearchParams, not Ktor or the serializer.
        assertEquals("/files/$id?filename=%7E+*+%25+%2B+Gr%C3%BC%C3%9F.pdf", json.getValue("url").jsonPrimitive.content)
        assertEquals("~ * % + Grüß.pdf", json.getValue("filename").jsonPrimitive.content)
        assertEquals("attachment", json.getValue("type").jsonPrimitive.content)
        assertEquals(1, json.getValue("version").jsonPrimitive.int)
    }

    @Test fun uploadStreamsExactMultipartMetadataAndBytesIncludingSignedRoomId() = runBlocking {
        Fixture().use { f ->
            f.responses.add(MockResponse().setBody(response()))
            val progress = mutableListOf<Pair<Long, Long>>()
            val attachment = AttachmentFiles(f.http).upload(f.profile, Long.MIN_VALUE + 17, upload()) { sent, total -> progress.add(sent to total) }
            assertEquals(ChatAttachment(id, name, bytes.size.toLong(), mime), attachment)
            val r = request(f); cleanHeaders(r)
            assertEquals("POST", r.method); assertEquals("/upload?workspace=studio_north", r.path)
            val contentType = assertNotNull(r.getHeader("Content-Type"))
            assertTrue(contentType.startsWith("multipart/form-data;"))
            val body = r.body.readByteArray()
            val text = body.toString(Charsets.UTF_8)
            assertTrue(text.contains("name=room")); assertTrue(text.contains("9223372036854775825"))
            assertTrue(text.contains("filename=\"$name\"")); assertTrue(text.contains("Content-Type: $mime"))
            val start = body.indices.first { i -> i + bytes.size <= body.size && body.copyOfRange(i, i + bytes.size).contentEquals(bytes) }
            assertTrue(start > 0); assertEquals('\r'.code.toByte(), body[start + bytes.size]); assertEquals('\n'.code.toByte(), body[start + bytes.size + 1])
            assertTrue(progress.isNotEmpty()); assertEquals(body.size.toLong(), progress.last().first)
        }
    }

    @Test fun invalidMetadataAndMalformedUploadResponsesCannotBecomeAttachments() = runBlocking {
        Fixture().use { f ->
            val files = AttachmentFiles(f.http)
            for (file in listOf(upload().copy(size = MAX_ATTACHMENT_BYTES + 1), upload().copy(filename = "bad\nname"), upload().copy(mimeType = "image/png\r\nX: y")))
                assertFails { files.upload(f.profile, 2, file) { _, _ -> } }
            assertNull(f.uploads.poll(100, TimeUnit.MILLISECONDS))
            val rejected = listOf(
                MockResponse().setResponseCode(503).setBody(response()),
                MockResponse().setResponseCode(302).setHeader("Location", "${f.profile.server}/must-not-follow"),
                MockResponse().setBody("{broken"), MockResponse().setBody(response(98)),
                MockResponse().setBody(response().replace("\"$name\"", "42")),
                MockResponse().setBody(response().replace("\"size\":97", "\"size\":\"97\"")),
                MockResponse().setBody(response().replace("\"$mime\"", "false")),
                MockResponse().setBody(" ".repeat(65537))
            )
            val accepted = mutableListOf<Int>()
            for ((index, r) in rejected.withIndex()) {
                f.responses.add(r)
                if (runCatching { files.upload(f.profile, 2, upload()) { _, _ -> } }.isSuccess) accepted.add(index)
                request(f)
                assertNull(f.uploads.poll(100, TimeUnit.MILLISECONDS), "No automatic retry or redirect")
            }
            assertEquals(emptyList(), accepted, "Malformed/status/oversized upload responses must all be rejected; accepted case indices")
        }
    }

    @Test fun downloadsWriteExactBytesAndRejectSizeMismatchStatusAndRedirect() = runBlocking {
        Fixture().use { f ->
            val attachment = ChatAttachment(id, name, bytes.size.toLong(), mime)
            val files = AttachmentFiles(f.http)
            f.responses.add(MockResponse().setBody(Buffer().write(bytes)))
            val sink = ByteArrayOutputStream()
            files.download(f.profile, attachment, { _, _ -> }) { data, n -> sink.write(data, 0, n) }
            assertContentEquals(bytes, sink.toByteArray())
            val r = request(f); cleanHeaders(r)
            assertEquals("GET", r.method); assertEquals("/files/$id", r.requestUrl!!.encodedPath)
            assertEquals("studio_north", r.requestUrl!!.queryParameter("workspace")); assertEquals(name, r.requestUrl!!.queryParameter("filename"))
            assertNull(r.requestUrl!!.queryParameter("inline"))
            for (response in listOf(MockResponse().setBody(Buffer().write(bytes.copyOf(96))),
                MockResponse().setBody(Buffer().write(bytes.copyOf(96))).setHeader("Content-Length", 97).setSocketPolicy(SocketPolicy.DISCONNECT_AT_END),
                MockResponse().setBody(Buffer().write(bytes.copyOf(98))), MockResponse().setResponseCode(503),
                MockResponse().setResponseCode(302).setHeader("Location", "${f.profile.server}/must-not-follow"))) {
                f.responses.add(response)
                assertFails { files.download(f.profile, attachment, { _, _ -> }) { _, _ -> } }
                request(f); assertNull(f.uploads.poll(100, TimeUnit.MILLISECONDS))
            }
        }
    }

    @Test fun downloadAcceptsExactlyOneHundredMiBAndStopsBeforeWritingExcess() = runBlocking {
        Fixture().use { f ->
            val pattern = ByteArray(32 * 1024) { (it % 251).toByte() }
            val body = Buffer().apply { repeat(3200) { write(pattern) } }
            val attachment = ChatAttachment(id, "limit.bin", MAX_ATTACHMENT_BYTES, "application/octet-stream")
            f.responses.add(MockResponse().setBody(body.clone()))
            var count = 0L
            AttachmentFiles(f.http).download(f.profile, attachment, { _, _ -> }) { data, n ->
                for (i in 0 until n) assertEquals(((count + i) % pattern.size % 251).toByte(), data[i])
                count += n
            }
            assertEquals(104857600L, count); request(f)
            f.responses.add(MockResponse().setBody(body.clone().writeByte(1)))
            var written = 0L
            assertFails { AttachmentFiles(f.http).download(f.profile, attachment, { _, _ -> }) { _, n -> written += n } }
            assertEquals(0L, written, "Declared oversize must fail before writing")
            request(f)
            f.responses.add(MockResponse().setChunkedBody(body.clone().writeByte(1), 32768))
            written = 0
            assertFails { AttachmentFiles(f.http).download(f.profile, attachment, { _, _ -> }) { _, n -> written += n } }
            assertTrue(written <= 104857600L); request(f)
            Unit
        }
    }

    private class Settings(private var profile: Profile) : LocalStore {
        val drafts = mutableMapOf<Pair<Profile, String>, String>()
        override fun profile() = profile
        override fun saveProfile(profile: Profile) { this.profile = profile }
        override fun drafts(profile: Profile) = drafts.filterKeys { it.first == profile }.mapKeys { it.key.second }
        override fun saveDraft(profile: Profile, conversationKey: String, text: String) { drafts[profile to conversationKey] = text }
        override fun clearDrafts(profile: Profile) { drafts.keys.removeAll { it.first == profile } }
    }
    private suspend fun ChatClient.ready() = withTimeout(5000) {
        state.first { it.connection == Connection.Connected && it.retention[2] in listOf(Retention.Enabled, Retention.Ephemeral) }
    }

    @Test fun chatClientOnlySendsConfirmedSuccessfulUploadAndKeepsDraftAcrossRetainedAndPlainSend() = runBlocking {
        for (retained in listOf(true, false)) Fixture().use { f ->
            f.retained = retained
            val job = SupervisorJob(); val settings = Settings(f.profile)
            val client = ChatClient(f.http, settings, CoroutineScope(coroutineContext + job))
            try {
                client.connect(); client.ready(); client.select(2); client.draft(2, "Never replace this draft")
                val target = assertNotNull(client.attachmentTarget())
                assertNull(f.uploads.poll(150, TimeUnit.MILLISECONDS), "Selecting/staging target is not confirmation")
                f.responses.add(MockResponse().setBody(response()))
                assertNotNull(client.uploadAttachment(target, upload())).join(); request(f)
                val sent = DataInputStream(ByteArrayInputStream(assertNotNull(f.sends.poll(5, TimeUnit.SECONDS))))
                assertEquals(if (retained) 48 else 1, sent.readUnsignedShort()); assertEquals(2L, sent.readLong())
                if (retained) assertTrue(ByteArray(16).also { sent.readFully(it) }.any { it != 0.toByte() })
                sent.readInt(); assertEquals(0, sent.readUnsignedByte())
                val text = ByteArray(sent.readUnsignedShort()).also { sent.readFully(it) }.toString(Charsets.UTF_8)
                assertEquals(ChatAttachment(id, name, 97, mime), ChatAttachment.parse(text))
                assertEquals("Never replace this draft", client.state.value.drafts[2]); assertNull(client.state.value.fileTransfer)
                f.responses.add(MockResponse().setResponseCode(503))
                assertNotNull(client.uploadAttachment(target, upload())).join(); request(f)
                assertNull(f.sends.poll(150, TimeUnit.MILLISECONDS)); assertNull(f.uploads.poll(150, TimeUnit.MILLISECONDS))
                assertEquals("Never replace this draft", client.state.value.drafts[2])
            } finally { client.disconnect(); job.cancelAndJoin() }
        }
    }

    @Test fun cancelledChangedRoomProfileAndReconnectedIdentityNeverSendOldUpload() = runBlocking {
        Fixture().use { f ->
            val job = SupervisorJob(); val client = ChatClient(f.http, Settings(f.profile), CoroutineScope(coroutineContext + job))
            try {
                client.connect(); client.ready(); client.select(2); client.draft(2, "Old room draft")
                for (change in listOf("cancel", "room", "disconnect", "session", "identity", "profile")) {
                    if (client.state.value.connection != Connection.Connected) { client.connect(); client.ready() }
                    client.select(2)
                    val target = assertNotNull(client.attachmentTarget())
                    f.responses.add(MockResponse().setBody(response()).setBodyDelay(500, TimeUnit.MILLISECONDS))
                    val transfer = assertNotNull(client.uploadAttachment(target, upload()))
                    withContext(Dispatchers.IO) { request(f) }
                    when (change) {
                        "cancel" -> client.cancelFileTransfer()
                        "room" -> client.select(3)
                        "disconnect" -> client.disconnect()
                        "session" -> { client.disconnect(); client.connect(); client.ready() }
                        "identity" -> { client.disconnect(); f.username = "bob"; client.connect(); client.ready() }
                        "profile" -> client.configure(f.profile.copy(workspace = "other-workspace"))
                    }
                    transfer.join()
                    assertNull(f.sends.poll(150, TimeUnit.MILLISECONDS), "$change must not announce old upload")
                    assertNull(client.state.value.fileTransfer)
                    if (change == "identity") assertNull(client.state.value.drafts[2], "Another account must not inherit the previous draft")
                    else if (change != "profile") assertEquals("Old room draft", client.state.value.drafts[2])
                    assertNull(client.uploadAttachment(target.copy(username = "not-current"), upload()))
                }
            } finally { client.disconnect(); job.cancelAndJoin() }
        }
    }
}
