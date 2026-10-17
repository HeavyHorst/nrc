package dev.nrc.chat

import app.cash.sqldelight.driver.jdbc.sqlite.JdbcSqliteDriver
import dev.nrc.chat.db.ChatDatabase
import io.ktor.client.HttpClient
import io.ktor.client.engine.cio.CIO
import io.ktor.client.plugins.websocket.WebSockets
import kotlinx.coroutines.*
import kotlinx.coroutines.flow.first
import okhttp3.Response
import okhttp3.WebSocket
import okhttp3.WebSocketListener
import okhttp3.mockwebserver.MockResponse
import okhttp3.mockwebserver.MockWebServer
import okhttp3.tls.HandshakeCertificates
import okhttp3.tls.HeldCertificate
import okio.ByteString
import okio.ByteString.Companion.toByteString
import java.io.ByteArrayInputStream
import java.io.ByteArrayOutputStream
import java.io.DataInputStream
import java.io.DataOutputStream
import java.nio.file.Files
import java.util.Properties
import java.util.concurrent.LinkedBlockingQueue
import java.util.concurrent.TimeUnit
import kotlin.test.*

/** Public ChatClient contracts over verified test-only TLS, with real on-disk SQLite. */
class ReviewRegressionTest {
    private class Settings(var saved: Profile, val refuseClear: Boolean = false,
                           val file: java.io.File = Files.createTempFile("nrc-drafts-", ".properties").toFile()) : LocalStore {
        override fun profile() = saved
        override fun saveProfile(profile: Profile) { saved = profile }
        override fun drafts(profile: Profile): Map<String, String> = Properties().apply {
            file.inputStream().use { load(it) }
        }.let { values -> values.stringPropertyNames().associateWith { values.getProperty(it) } }
        override fun saveDraft(profile: Profile, conversationKey: String, text: String) {
            val values = Properties().apply { putAll(drafts(profile)); setProperty(conversationKey, text) }
            file.outputStream().use { values.store(it, null) }
        }
        override fun clearDrafts(profile: Profile) {
            if (refuseClear) error("storage unavailable")
            file.outputStream().use { Properties().store(it, null) }
        }
    }

    private data class Request(val opcode: Int, val id: Long, val cursor: Long, val request: Int)
    private fun frame(opcode: Int, body: DataOutputStream.() -> Unit = {}): ByteArray =
        ByteArrayOutputStream().also { bytes -> DataOutputStream(bytes).apply { writeShort(opcode); body() } }.toByteArray()
    private fun DataOutputStream.text(value: String) { val bytes = value.toByteArray(Charsets.UTF_8); writeShort(bytes.size); write(bytes) }
    private fun message(id: Long, sequence: Long, author: String = "peer") =
        Message("$id:$sequence", id, sequence, author, sequence * 1000, "message-$sequence")

    private inner class Fixture(val cached: CachedChat = CachedChat(), val username: String = "alice",
                                var highWater: Long = 0, val refuseClear: Boolean = false) {
        val server = MockWebServer()
        val requests = LinkedBlockingQueue<Request>()
        val sends = LinkedBlockingQueue<ByteArray>()
        var retained = true
        var directMessages: List<Conversation> = emptyList()
        lateinit var wire: WebSocket
        val file = Files.createTempFile("nrc-review-", ".db").toFile()
        var driver = JdbcSqliteDriver("jdbc:sqlite:${file.absolutePath}")
        var disk = SqliteMessageStore(driver)
        var job = SupervisorJob()
        lateinit var scope: CoroutineScope
        val upgrade: MockResponse
        val profile: Profile
        val settings: Settings
        val http: HttpClient
        lateinit var client: ChatClient

        init {
            ChatDatabase.Schema.create(driver)
            val certificate = HeldCertificate.Builder().commonName("localhost").addSubjectAlternativeName("localhost").build()
            val serverTls = HandshakeCertificates.Builder().heldCertificate(certificate).build()
            val clientTls = HandshakeCertificates.Builder().addTrustedCertificate(certificate.certificate).build()
            server.useHttps(serverTls.sslSocketFactory(), false)
            upgrade = MockResponse().withWebSocketUpgrade(object : WebSocketListener() {
                override fun onOpen(webSocket: WebSocket, response: Response) {
                    wire = webSocket
                    emit(frame(100) { text("fixture"); writeInt(9); text("test"); text(username); writeBoolean(true) })
                }
                override fun onClosing(webSocket: WebSocket, code: Int, reason: String) { webSocket.close(code, reason) }
                override fun onMessage(webSocket: WebSocket, bytes: ByteString) {
                    val input = DataInputStream(ByteArrayInputStream(bytes.toByteArray()))
                    when (val op = input.readUnsignedShort()) {
                        49 -> {
                            val ids = List(input.readUnsignedShort()) { input.readLong() }; val req = input.readInt()
                            emit(frame(158) {
                                writeInt(req); writeShort(if (retained) ids.size else 0)
                                if (retained) ids.forEach { writeLong(it); writeLong(highWater); writeLong(0) }
                            })
                        }
                        50, 51 -> {
                            val id = input.readLong(); val cursor = input.readLong(); input.readUnsignedShort()
                            requests.add(Request(op, id, cursor, input.readInt()))
                        }
                        1, 48 -> sends.add(bytes.toByteArray())
                        17 -> emit(frame(122) {
                            writeShort(directMessages.size); writeInt(input.readInt())
                            directMessages.forEach { writeLong(it.id); text(it.name); writeBoolean(false); writeBoolean(false); writeLong(0) }
                        })
                    }
                }
            })
            server.enqueue(upgrade)
            server.start()
            profile = Profile("https://localhost:${server.port}", "review")
            settings = Settings(profile, refuseClear = refuseClear)
            http = HttpClient(CIO) { install(WebSockets); engine { https { trustManager = clientTls.trustManager } } }
        }

        suspend fun start(unreadableCache: Boolean = false) {
            disk.save(profile, cached)
            scope = CoroutineScope(currentCoroutineContext() + job)
            val storage = if (unreadableCache) object : MessageStore {
                override suspend fun load(profile: Profile): CachedChat? = error("unreadable existing database")
                override suspend fun save(profile: Profile, chat: CachedChat) = error("must not overwrite unreadable cache")
            } else disk
            client = ChatClient(http, settings, scope, storage)
            client.connect()
        }
        suspend fun recreateOffline() {
            client.disconnect(); client.flushCache(); job.cancelAndJoin(); driver.close()
            driver = JdbcSqliteDriver("jdbc:sqlite:${file.absolutePath}")
            disk = SqliteMessageStore(driver)
            job = SupervisorJob(); scope = CoroutineScope(currentCoroutineContext() + job)
            client = ChatClient(http, settings, scope, disk)
        }
        fun reconnect() { server.enqueue(upgrade.clone()); client.connect() }
        fun emit(bytes: ByteArray) { check(wire.send(bytes.toByteString())) }
        suspend fun next(): Request = withContext(Dispatchers.IO) { requests.poll(10, TimeUnit.SECONDS) ?: error("No history request") }
        suspend fun quiet() { delay(150); assertTrue(requests.isEmpty(), "Only one history request may be in flight") }
        fun page(request: Request, messages: List<Message> = emptyList(),
                 cursor: Long = messages.lastOrNull()?.sequence ?: 0, more: Boolean = false,
                 snapshot: Long = highWater, truncated: Boolean = false) {
            require(messages.size <= 100)
            require(messages.all { it.sequence <= snapshot }) { "Fixture records must not exceed snapshot high-water" }
            emit(frame(159) {
                writeLong(request.id); writeBoolean(request.opcode == 51 || request.request == 0); writeBoolean(more); writeBoolean(truncated)
                writeLong(snapshot); writeLong(0); writeLong(cursor); writeInt(request.request); writeShort(messages.size)
                messages.forEach { m ->
                    writeLong(m.conversationId); writeLong(m.sequence); write(ByteArray(16))
                    text(m.author); writeLong(m.timestampNanos); writeByte(0); text(m.text)
                }
            })
        }
        fun error(request: Request, reason: String) = emit(frame(104) { writeShort(request.opcode); text(reason); writeInt(request.request) })
        suspend fun settle() { client.await { it.loadingHistory.isEmpty() } }
        suspend fun close() {
            if (::client.isInitialized) { client.disconnect(); client.flushCache() }
            job.cancelAndJoin(); http.close()
            driver.close(); server.shutdown(); file.delete(); settings.file.delete()
        }
    }

    private suspend fun ChatClient.await(predicate: (ChatState) -> Boolean): ChatState =
        withTimeout(10_000) { state.first(predicate) }

    @Test fun coldConversationsSerializeAndHistoryErrorsHaveBoundedExplicitRecovery() = runBlocking {
        val fixture = Fixture(CachedChat(conversations = (2L..7L).map { Conversation(it, "room-$it") }), highWater = 7)
        try {
            fixture.start()
            val ids = mutableSetOf<Long>()
            repeat(6) {
                val request = fixture.next(); ids.add(request.id); fixture.quiet()
                fixture.page(request, listOf(message(request.id, request.id)))
            }
            fixture.settle(); assertEquals((2L..7L).toSet(), ids)
            assertEquals(6, fixture.client.state.value.messages.size)
            assertEquals((2L..7L).associateWith { listOf(it) }, fixture.client.state.value.messages.mapValues { (_, messages) -> messages.map { it.sequence } })
            // Reconnection must not resend a user message with unknown delivery.
            fixture.client.select(2); fixture.client.draft(2, "never automatically resend"); fixture.client.sendSelected()
            withTimeout(5000) { while (fixture.sends.isEmpty()) delay(10) }
            fixture.recreateOffline(); fixture.reconnect()
            repeat(6) { fixture.page(fixture.next()) }
            fixture.settle(); delay(150)
            assertEquals(1, fixture.sends.size)
        } finally { fixture.close() }
        val retry = Fixture(highWater = 1)
        try {
            retry.start()
            val reasons = listOf("retained history capacity reached", "too many retained message operations", "message storage maintenance; retry")
            var request = retry.next()
            val retryId = request.id
            repeat(5) { attempt ->
                retry.error(request, reasons[attempt % reasons.size])
                if (attempt < 4) {
                    request = retry.next()
                    // Other queued rooms may proceed between retries; respond to them normally.
                    while (request.id != retryId) { retry.page(request); request = retry.next() }
                }
            }
            retry.client.await { retryId in it.failedHistory && retryId !in it.loadingHistory }
            while (retry.requests.isNotEmpty()) retry.page(retry.next())
            retry.settle(); retry.quiet()
            retry.client.loadOlder(retryId)
            val manual = retry.next(); assertEquals(retryId, manual.id)
            retry.page(manual, listOf(message(retryId, 1)))
            retry.client.await { retryId !in it.failedHistory && it.messages[retryId].orEmpty().size == 1 }
            assertTrue(retry.sends.isEmpty())
        } finally { retry.close() }
        val denied = Fixture()
        try {
            denied.start(); val request = denied.next(); denied.error(request, "conversation access denied")
            val other = denied.next(); assertNotEquals(request.id, other.id); denied.page(other)
            denied.settle(); denied.quiet(); assertTrue(denied.client.state.value.failedHistory.isEmpty())
            assertEquals("conversation access denied", denied.client.state.value.notice)
        } finally { denied.close() }
    }

    @Test fun authenticatedIdentityChangeClearsAllDraftKeysAndFailsClosedOnStorageFailure() = runBlocking {
        for (refuse in listOf(false, true)) {
            val fixture = Fixture(CachedChat(username = "previous"), refuseClear = refuse)
            fixture.settings.saveDraft(fixture.profile, "room:2", "old room")
            fixture.settings.saveDraft(fixture.profile, "dm:undiscovered", "private old partner")
            try {
                fixture.start()
                if (refuse) {
                    fixture.client.await { it.notice?.contains("Could not clear") == true }
                    assertNotEquals(Connection.Connected, fixture.client.state.value.connection)
                    assertNotEquals("alice", fixture.client.state.value.username)
                    assertTrue(fixture.client.state.value.storageBlocked)
                    assertTrue(fixture.client.state.value.drafts.isEmpty()); fixture.quiet()
                    assertEquals(2, fixture.settings.drafts(fixture.profile).size)
                    fixture.client.select(2); fixture.client.draft(2, "must not overwrite old identity"); fixture.client.sendSelected()
                    assertEquals("old room", fixture.settings.drafts(fixture.profile)["room:2"])
                    assertEquals("private old partner", fixture.settings.drafts(fixture.profile)["dm:undiscovered"])
                    assertTrue(fixture.client.state.value.drafts.isEmpty())
                    assertTrue(fixture.sends.isEmpty())
                } else {
                    fixture.client.await { it.connection == Connection.Connected }
                    assertFalse(fixture.client.state.value.storageBlocked)
                    assertTrue(fixture.settings.drafts(fixture.profile).isEmpty())
                    assertTrue(fixture.client.state.value.drafts.isEmpty())
                    fixture.client.flushCache()
                    assertEquals("alice", fixture.disk.load(fixture.profile)?.username)
                    assertTrue(fixture.disk.load(fixture.profile)?.messages.orEmpty().isEmpty())
                    assertTrue(Settings(fixture.profile, file = fixture.settings.file).drafts(fixture.profile).isEmpty())
                }
            } finally { fixture.close() }
        }
    }

    @Test fun sqliteReopenPreservesOlderCursorAndBrowsingStopsAtCacheBound() = runBlocking {
        val fixture = Fixture(CachedChat(username = "alice"), highWater = 1000)
        try {
            fixture.start()
            repeat(2) {
                val request = fixture.next()
                fixture.page(request, if (request.id == 2L) (1000L downTo 901L).map { message(2, it) } else emptyList(),
                    cursor = if (request.id == 2L) 901 else 0, more = request.id == 2L)
            }
            fixture.settle(); fixture.recreateOffline()
            val saved = fixture.disk.load(fixture.profile)!!
            assertEquals(901L, saved.olderCursor[2])
            fixture.client.await { it.messages[2].orEmpty().size == 100 }
            assertEquals(901L, fixture.client.state.value.olderCursor[2]); assertEquals(Connection.Disconnected, fixture.client.state.value.connection)
            fixture.reconnect()
            repeat(2) { fixture.page(fixture.next()) }; fixture.settle()
            fixture.client.loadOlder(2); val older = fixture.next(); assertEquals(901L, older.cursor)
            fixture.page(older, (900L downTo 801L).map { message(2, it) }, 801, true); fixture.settle()
            assertEquals((801L..1000L).toList(), fixture.client.state.value.messages[2]?.map { it.sequence })
            assertTrue(fixture.client.state.value.unread.isEmpty(), "initial and older history is not unread")
        } finally { fixture.close() }
        val bounded = Fixture(highWater = 1000)
        try {
            bounded.start()
            repeat(2) { val r = bounded.next(); bounded.page(r, if (r.id == 2L) (1000L downTo 901L).map { message(2, it) } else emptyList(), if (r.id == 2L) 901 else 0, r.id == 2L) }
            bounded.settle()
            for (cursor in 901L downTo 101L step 100) {
                bounded.client.loadOlder(2); val r = bounded.next(); assertEquals(cursor, r.cursor)
                bounded.page(r, ((cursor - 1) downTo (cursor - 100)).map { message(2, it) }, cursor - 100, true)
                bounded.settle()
            }
            assertEquals(1000, bounded.client.state.value.messages[2]?.size)
            assertNull(bounded.client.state.value.olderCursor[2]); bounded.client.loadOlder(2); bounded.quiet()
            bounded.client.flushCache(); assertEquals(1000, bounded.disk.load(bounded.profile)?.messages?.get(2)?.size)
        } finally { bounded.close() }
    }

    @Test fun catchupUnreadIgnoresSeenEvictedSelfSelectedAndRepeatedMessagesButNotAckGaps() = runBlocking {
        val fixture = Fixture(CachedChat(username = "alice", messages = mapOf(2L to (2L..1001L).map { message(2, it) }),
            replayFrom = mapOf(2L to 1L, 3L to 1L), loadedHistory = setOf(2L, 3L),
            seenThrough = mapOf(2L to 1L, 3L to 1L), seenAhead = mapOf(2L to (2L..1001L).toSet())), highWater = 1003)
        try {
            fixture.start(); fixture.client.select(3)
            repeat(2) {
                val request = fixture.next()
                assertEquals(51, request.opcode)
                val records = if (request.id == 2L) listOf(message(2, 2), message(2, 1002), message(2, 1003, "alice"))
                    else listOf(message(3, 1002))
                fixture.page(request, records)
            }
            fixture.settle()
            assertEquals(1, fixture.client.state.value.unread[2]); assertNull(fixture.client.state.value.unread[3])
            val live = Request(50, 2, 0, 0)
            fixture.page(live, listOf(message(2, 2), message(2, 1002)), 0)
            delay(150); assertEquals(1, fixture.client.state.value.unread[2])
            // Higher own ACK arrives before a missing lower peer record.
            fixture.client.select(2); fixture.client.draft(2, "outgoing"); fixture.client.sendSelected()
            val sent = withContext(Dispatchers.IO) { fixture.sends.poll(5, TimeUnit.SECONDS)!! }
            val input = DataInputStream(ByteArrayInputStream(sent)); input.readUnsignedShort(); input.readLong(); input.skipBytes(16)
            val req = input.readInt()
            fixture.highWater = 1005
            fixture.emit(frame(103) { writeInt(req); writeLong(1005); writeLong(1005000) })
            fixture.client.await { it.messages[2].orEmpty().any { m -> m.text == "outgoing" && m.delivery == Delivery.Sent } }
            fixture.client.select(null)
            assertFalse(fixture.client.state.value.messages[2].orEmpty().any { it.sequence == 1004L })
            fixture.recreateOffline(); fixture.reconnect()
            repeat(2) {
                val request = fixture.next()
                if (request.id == 2L) assertEquals(1003L, request.cursor, "higher ACK must not skip missing peer")
                fixture.page(request, if (request.id == 2L) listOf(message(2, 1004), message(2, 1005, "alice")) else emptyList())
            }
            fixture.settle(); assertEquals(1, fixture.client.state.value.unread[2], "missing peer counted once through correlated replay")
            assertEquals(1, fixture.client.state.value.messages[2].orEmpty().count { it.sequence == 1004L })
            fixture.recreateOffline(); fixture.reconnect()
            repeat(2) {
                val request = fixture.next()
                fixture.page(request, emptyList())
            }
            fixture.settle(); assertEquals(1, fixture.client.state.value.unread[2], "repeated replay is not unread twice")
        } finally { fixture.close() }
    }

    @Test fun retainedSequenceResetKeepsArchivedAndOverlappingRecordsDistinctAfterReopen() = runBlocking {
        val old = message(2, 1).copy(text = "old retained record")
        val fixture = Fixture(CachedChat(username = "alice", messages = mapOf(2L to listOf(old)),
            replayFrom = mapOf(2L to 10L), loadedHistory = setOf(2L), olderCursor = mapOf(2L to 1L)), highWater = 2)
        try {
            fixture.start()
            repeat(4) {
                val request = fixture.next()
                // Reset starts with an empty before1 initial page, followed by ascending replay.
                fixture.page(request, if (request.id == 2L && request.opcode == 51)
                    listOf(message(2, 1).copy(text = "new overlapping record")) else emptyList())
            }
            fixture.settle()
            val records = fixture.client.state.value.messages[2].orEmpty()
            assertEquals(setOf("old retained record", "new overlapping record"), records.map { it.text }.toSet())
            assertEquals(2, records.map { it.key }.distinct().size, "Compose and SQLite keys must not collide after reset")
            assertEquals(0L, records.single { it.text == "old retained record" }.sequence)
            fixture.recreateOffline()
            fixture.client.await { it.messages[2].orEmpty().size == 2 }
            assertEquals(records, fixture.client.state.value.messages[2])
            assertNull(fixture.client.state.value.olderCursor[2])
        } finally { fixture.close() }
    }

    @Test fun unreadableCacheHidesDraftsBlocksConnectionAndPreservesExistingStorage() = runBlocking {
        val old = CachedChat(username = "previous", messages = mapOf(2L to listOf(message(2, 1))))
        val fixture = Fixture(old)
        try {
            fixture.settings.saveDraft(fixture.profile, "room:2", "previous room draft")
            fixture.settings.saveDraft(fixture.profile, "dm:undiscovered", "previous private DM draft")
            fixture.start(unreadableCache = true)
            fixture.client.await { it.notice?.contains("Could not open local chat history") == true }
            delay(200)
            assertEquals(Connection.Disconnected, fixture.client.state.value.connection)
            assertTrue(fixture.client.state.value.storageBlocked)
            assertTrue(fixture.client.state.value.drafts.isEmpty())
            assertEquals(0, fixture.server.requestCount, "No WebSocket may authenticate without checking cached identity")
            fixture.client.select(2); fixture.client.draft(2, "must not overwrite unreadable identity"); fixture.client.sendSelected()
            assertEquals("previous room draft", fixture.settings.drafts(fixture.profile)["room:2"])
            assertEquals("previous private DM draft", fixture.settings.drafts(fixture.profile)["dm:undiscovered"])
            assertTrue(fixture.client.state.value.drafts.isEmpty())
            fixture.client.connect(); fixture.client.flushCache(); delay(150)
            assertEquals(0, fixture.server.requestCount)
            assertEquals(old, fixture.disk.load(fixture.profile))
            assertEquals(2, Settings(fixture.profile, file = fixture.settings.file).drafts(fixture.profile).size)
        } finally { fixture.close() }
    }

    @Test fun retentionDisableAndReenableKeepsOverlappingHistoryThroughSqliteReopen() = runBlocking {
        val fixture = Fixture(highWater = 1)
        try {
            fixture.start()
            repeat(2) {
                val request = fixture.next()
                fixture.page(request, if (request.id == 2L) listOf(message(2, 1).copy(text = "old retained")) else emptyList())
            }
            fixture.settle(); fixture.recreateOffline()
            fixture.retained = false; fixture.reconnect()
            fixture.client.await { it.retention[2] == Retention.Ephemeral }
            fixture.quiet(); fixture.recreateOffline()
            fixture.retained = true; fixture.reconnect()
            repeat(2) {
                val request = fixture.next()
                fixture.page(request, if (request.id == 2L) listOf(message(2, 1).copy(text = "new retained")) else emptyList())
            }
            fixture.settle()
            val messages = fixture.client.state.value.messages[2].orEmpty()
            assertEquals(setOf("old retained", "new retained"), messages.map { it.text }.toSet())
            assertEquals(2, messages.map { it.key }.distinct().size)
            fixture.recreateOffline()
            fixture.client.await { it.messages[2].orEmpty().size == 2 }
            assertEquals(messages, fixture.client.state.value.messages[2])
        } finally { fixture.close() }
    }

    @Test fun partnerRemapArchivesOldSequenceKeysBeforeOverlappingRetainedRecords() = runBlocking {
        val former = -999L
        val current = -7L
        // A previous remap can leave the original wire key while the saved conversation ID changed.
        val old = message(current, 12).copy(conversationId = former, text = "earlier partner history")
        val fixture = Fixture(CachedChat(username = "alice", conversations = defaultRooms + Conversation(former, "bob", true),
            messages = mapOf(former to listOf(old))), highWater = 12)
        fixture.directMessages = listOf(Conversation(current, "bob", true))
        try {
            fixture.start()
            repeat(3) {
                val request = fixture.next()
                fixture.page(request, if (request.id == current) listOf(message(current, 12).copy(text = "current partner history")) else emptyList())
            }
            fixture.settle()
            val messages = fixture.client.state.value.messages[current].orEmpty()
            assertEquals(setOf("earlier partner history", "current partner history"), messages.map { it.text }.toSet())
            assertEquals(2, messages.map { it.key }.distinct().size)
            assertFalse(fixture.client.state.value.messages.containsKey(former))
            fixture.recreateOffline()
            fixture.client.await { it.messages[current].orEmpty().size == 2 }
            assertEquals(messages, fixture.client.state.value.messages[current])
        } finally { fixture.close() }
    }

    @Test fun rollbackAboveReplayCheckpointReplacesSequenceIdentityAndCountsNewPeerOnce() = runBlocking {
        val cached = CachedChat(username = "alice", messages = mapOf(2L to listOf(
            message(2, 12).copy(text = "old twelve"), message(2, 20).copy(text = "old twenty"))),
            replayFrom = mapOf(2L to 10L), loadedHistory = setOf(2L), seenThrough = mapOf(2L to 10L),
            seenAhead = mapOf(2L to setOf(12L, 20L)), baselineEstablished = setOf(2L),
            observedHighWater = 20, receiptsAuthoritative = true)
        for (legacy in listOf(false, true)) {
            // In old caches the highest live record may have been display-evicted;
            // its receipt is still evidence of the previous sequence namespace.
            val seed = if (legacy) cached.copy(messages = mapOf(2L to cached.messages.getValue(2L).take(1)),
                observedHighWater = 0, receiptsAuthoritative = false) else cached
            val fixture = Fixture(seed, highWater = 15)
            try {
                fixture.start()
                val initial = fixture.next()
                assertEquals(2L, initial.id); assertEquals(50, initial.opcode); assertEquals(1L, initial.cursor)
                fixture.page(initial) // zero baseline intentionally selects no initial records
                val other = fixture.next(); fixture.page(other)
                val replay = fixture.next()
                assertEquals(2L, replay.id); assertEquals(51, replay.opcode); assertEquals(0L, replay.cursor)
                val fresh = message(2, 12).copy(text = "different new twelve")
                fixture.page(replay, listOf(fresh))
                // A second room may also scan the newly restored namespace.
                if (!fixture.client.state.value.loadingHistory.isEmpty()) {
                    val next = fixture.next(); fixture.page(next)
                }
                fixture.settle()
                val all = fixture.client.state.value.messages[2].orEmpty()
                val texts = if (legacy) setOf("old twelve", "different new twelve")
                    else setOf("old twelve", "old twenty", "different new twelve")
                assertEquals(texts, all.map { it.text }.toSet())
                assertEquals(texts.size, all.map { it.key }.distinct().size)
                assertEquals(1, fixture.client.state.value.unread[2])
                fixture.page(Request(51, 2, 0, 0), listOf(fresh))
                delay(100); assertEquals(1, fixture.client.state.value.unread[2])
                fixture.recreateOffline()
                fixture.client.await { it.messages[2].orEmpty().size == texts.size }
                assertEquals(all, fixture.client.state.value.messages[2]); assertEquals(1, fixture.client.state.value.unread[2])
            } finally { fixture.close() }
        }
    }

    @Test fun failedInitialReadKeepsOriginalBaselineAcrossProcessRecreationAndCountsCatchup() = runBlocking {
        val fixture = Fixture(highWater = 10)
        try {
            fixture.start(); var request = fixture.next(); val id = request.id
            assertEquals(11L, request.cursor)
            repeat(5) { attempt ->
                fixture.error(request, "message storage maintenance; retry")
                if (attempt < 4) {
                    request = fixture.next()
                    while (request.id != id) { fixture.page(request); request = fixture.next() }
                    assertEquals(11L, request.cursor)
                }
            }
            fixture.client.await { id in it.failedHistory }
            if (fixture.requests.isNotEmpty()) fixture.page(fixture.next())
            fixture.settle(); fixture.recreateOffline()
            fixture.highWater = 20; fixture.reconnect()
            val initial = fixture.next()
            assertEquals(id, initial.id); assertEquals(50, initial.opcode); assertEquals(11L, initial.cursor)
            fixture.page(initial, listOf(message(id, 9)), truncated = true)
            assertEquals("Message history is paged; more may be available.", fixture.client.await { it.messages[id].orEmpty().isNotEmpty() }.notice)
            val next = fixture.next()
            if (next.id != id) { fixture.page(next); request = fixture.next() } else request = next
            assertEquals(id, request.id); assertEquals(51, request.opcode); assertEquals(10L, request.cursor)
            fixture.page(request, listOf(message(id, 12), message(id, 20)))
            fixture.settle()
            assertEquals(2, fixture.client.state.value.unread[id], "new peers after baseline are not silently treated as initial history")
            assertEquals(listOf(9L, 12L, 20L), fixture.client.state.value.messages[id]?.map { it.sequence })
        } finally { fixture.close() }
    }

    @Test fun emptyExpiredReplayAdvancesThroughSnapshotRatherThanZeroContinuation() = runBlocking {
        val fixture = Fixture(CachedChat(username = "alice", replayFrom = mapOf(2L to 10L), loadedHistory = setOf(2L),
            baselineEstablished = setOf(2L), seenThrough = mapOf(2L to 10L), observedHighWater = 10,
            receiptsAuthoritative = true), highWater = 20)
        try {
            fixture.start()
            repeat(2) { val request = fixture.next(); if (request.id == 2L) assertEquals(10L, request.cursor); fixture.page(request) }
            fixture.settle(); fixture.quiet(); assertTrue(fixture.client.state.value.unread.isEmpty())
            fixture.recreateOffline(); fixture.reconnect()
            repeat(2) { val request = fixture.next(); assertEquals(51, request.opcode); assertEquals(20L, request.cursor); fixture.page(request) }
            fixture.settle(); fixture.quiet()
            assertTrue(fixture.client.state.value.syncPaused.isEmpty())
        } finally { fixture.close() }
    }

    @Test fun receiptPressureStopsAdmissionAndLiveRetriesUntilExplicitRecoveryAcrossReopen() = runBlocking {
        val fixture = Fixture(CachedChat(username = "alice", replayFrom = mapOf(2L to 10L), loadedHistory = setOf(2L),
            baselineEstablished = setOf(2L), seenThrough = mapOf(2L to 10L), observedHighWater = 10,
            receiptsAuthoritative = true), highWater = 10)
        fun live(sequences: List<Long>, author: String = "peer") {
            fixture.highWater = maxOf(fixture.highWater, sequences.max())
            fixture.page(Request(51, 2, 0, 0), sequences.map { message(2, it, author) })
        }
        try {
            fixture.start(); repeat(2) { fixture.page(fixture.next()) }; fixture.settle()
            fixture.client.select(2); live((11L..110L).toList())
            fixture.client.await { it.messages[2].orEmpty().any { m -> m.sequence == 110L } }
            assertNull(fixture.client.state.value.unread[2]); fixture.client.select(null)
            live((111L..210L).toList()); live((211L..265L).toList())
            fixture.client.await { it.messages[2].orEmpty().any { m -> m.sequence == 265L } }; fixture.quiet()
            live(listOf(266)); var scan = fixture.next(); assertEquals(51, scan.opcode); assertEquals(10L, scan.cursor)
            live(listOf(267), "alice") // own delivery must neither count unread nor consume a peer receipt
            (268L..2059L).toList().chunked(100).forEach { live(it) }
            fixture.client.await { it.messages[2].orEmpty().any { m -> m.sequence == 2059L } }
            assertEquals(1948, fixture.client.state.value.unread[2]) //2048 peers minus100 selected
            live(listOf(2060, 2061, 2062))
            fixture.client.await { 2L in it.syncPaused }
            assertFalse(fixture.client.state.value.messages[2].orEmpty().any { it.sequence in 2060L..2062L })
            repeat(5) { attempt ->
                fixture.error(scan, "retained history capacity reached")
                if (attempt < 4) scan = fixture.next()
            }
            fixture.client.await { 2L in it.failedHistory }; fixture.quiet()
            fixture.client.select(2); fixture.client.draft(2, "own ACK while paused"); fixture.client.sendSelected()
            val sent = withContext(Dispatchers.IO) { fixture.sends.poll(5, TimeUnit.SECONDS)!! }
            val reader = DataInputStream(ByteArrayInputStream(sent)); reader.readUnsignedShort(); reader.readLong(); reader.skipBytes(16)
            val req = reader.readInt(); fixture.highWater = 2063
            fixture.emit(frame(103) { writeInt(req); writeLong(2063); writeLong(2063000) })
            fixture.client.await { it.messages[2].orEmpty().any { m -> m.text == "own ACK while paused" && m.delivery == Delivery.Sent } }
            fixture.client.select(null); fixture.client.flushCache()
            fixture.recreateOffline(); fixture.client.await { it.messages[2].orEmpty().isNotEmpty() }
            assertTrue(2L in fixture.client.state.value.syncPaused)
            fixture.client.flushCache()
            val saved = fixture.disk.load(fixture.profile)!!
            assertEquals(2048, saved.seenAhead[2].orEmpty().size)
            assertFalse(2063L in saved.seenAhead[2].orEmpty(), "fresh-format ACK must not reconstruct a receipt on reopen")
            fixture.reconnect(); scan = fixture.next()
            repeat(5) { attempt -> fixture.error(scan, "message storage maintenance; retry"); if (attempt < 4) {
                scan = fixture.next(); while (scan.id != 2L) { fixture.page(scan); scan = fixture.next() }
            } }
            fixture.client.await { 2L in it.failedHistory }
            while (fixture.requests.isNotEmpty()) fixture.page(fixture.next())
            fixture.settle(); live(listOf(2064)); delay(150); fixture.quiet()
            assertTrue(2L in fixture.client.state.value.failedHistory)
            assertFalse(fixture.client.state.value.messages[2].orEmpty().any { it.sequence == 2064L })
            fixture.client.loadOlder(2); scan = fixture.next(); assertEquals(10L, scan.cursor)
            // Snapshot2063 began before the skipped live2064; completing it must not lose that newer target.
            (11L..2063L).toList().chunked(100).forEachIndexed { index, sequences ->
                if (index > 0) scan = fixture.next()
                fixture.page(scan, sequences.map { message(2, it, if (it == 267L || it == 2063L) "alice" else "peer") },
                    more = sequences.last() < 2063, snapshot = 2063)
            }
            val newer = fixture.next(); assertEquals(51, newer.opcode); assertEquals(2063L, newer.cursor)
            fixture.page(newer, listOf(message(2, 2064)), snapshot = 2064)
            fixture.settle()
            assertEquals(4, fixture.client.state.value.unread[2], "only skipped peers2060/2061/2062/2064, not selected/seen/self")
            assertFalse(2L in fixture.client.state.value.syncPaused)
            assertTrue(fixture.sends.isEmpty(), "ACKed send must never be resent")
            fixture.recreateOffline(); fixture.reconnect()
            repeat(2) { val request = fixture.next(); fixture.page(request) }; fixture.settle()
            assertEquals(4, fixture.client.state.value.unread[2])
        } finally { fixture.close() }
    }

    @Test fun legacyArchivedWireKeyCannotCollideWithNewRetainedSequenceAfterSqliteReopen() = runBlocking {
        val archived = message(2, 12).copy(sequence = 0, text = "previous namespace twelve", clientMessageId = "kept-client-id")
        val fixture = Fixture(CachedChat(username = "alice", messages = mapOf(2L to listOf(archived)),
            replayFrom = mapOf(2L to 10L), loadedHistory = setOf(2L), seenThrough = mapOf(2L to 10L),
            observedHighWater = 10, baselineEstablished = setOf(2L), receiptsAuthoritative = true), highWater = 15)
        try {
            fixture.start()
            repeat(2) {
                val request = fixture.next()
                fixture.page(request, if (request.id == 2L) listOf(message(2, 12)) else emptyList())
            }
            fixture.settle()
            val before = fixture.client.state.value.messages[2]!!
            assertEquals(2, before.size); assertEquals(2, before.map { it.key }.distinct().size)
            assertEquals("kept-client-id", before.single { it.sequence == 0L }.clientMessageId)
            assertEquals(setOf("previous namespace twelve", "message-12"), before.map { it.text }.toSet())
            fixture.recreateOffline(); fixture.client.await { it.messages[2].orEmpty().size == 2 }
            assertEquals(before, fixture.client.state.value.messages[2])
        } finally { fixture.close() }
    }

    @Test fun oversizedRevokedDmReceiptsCannotGrowOrBlockAccessibleRoom() = runBlocking {
        val revoked = Long.MIN_VALUE + 89
        val receipts = (1L..3000L).toSet()
        val fixture = Fixture(CachedChat(username = "alice", conversations = defaultRooms + Conversation(revoked, "saved", true),
            replayFrom = mapOf(2L to 5000L), loadedHistory = setOf(2L), seenThrough = mapOf(2L to 5000L),
            seenAhead = mapOf(revoked to receipts), observedHighWater = 5000, baselineEstablished = setOf(2L),
            receiptsAuthoritative = true), highWater = 5000)
        try {
            fixture.start(); repeat(2) { fixture.page(fixture.next()) }; fixture.settle()
            assertFalse(revoked in fixture.client.state.value.liveDMs)
            fixture.highWater = 5002
            fixture.page(Request(51, revoked, 0, 0), listOf(message(revoked, 5001)))
            fixture.page(Request(51, 2, 0, 0), listOf(message(2, 5002)))
            fixture.client.await { it.messages[2].orEmpty().any { m -> m.sequence == 5002L } }
            assertEquals(1, fixture.client.state.value.unread[2]); assertNull(fixture.client.state.value.messages[revoked])
            fixture.client.flushCache()
            assertEquals(receipts, fixture.disk.load(fixture.profile)!!.seenAhead[revoked])
            assertFalse(2L in fixture.client.state.value.syncPaused)
        } finally { fixture.close() }
    }
}
