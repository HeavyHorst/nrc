package dev.nrc.chat

import app.cash.sqldelight.driver.jdbc.sqlite.JdbcSqliteDriver
import dev.nrc.chat.db.ChatDatabase
import io.ktor.client.HttpClient
import io.ktor.client.engine.cio.CIO
import io.ktor.client.plugins.websocket.WebSockets
import kotlinx.coroutines.*
import kotlinx.coroutines.flow.first
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json
import java.nio.file.Files
import kotlin.test.*

class MessageCacheTest {
    @Test fun diskHistorySurvivesReopenAndRestoresOfflineWithoutResending() = runBlocking {
        val directory = Files.createTempDirectory("nrc-chat-cache").toFile()
        val url = "jdbc:sqlite:${directory.resolve("history.db")}"
        val profile = Profile("https://nrc.example", "studio")
        val dm = Long.MIN_VALUE + 17
        val room = Conversation(42, "field")
        val direct = Conversation(dm, "lena", true)
        val received = Message("peer:5", 42, 5, "lena", 900, "Grüß dich 🌲")
        val pending = Message("local:unique", dm, author = "rene", timestampNanos = 901,
            text = "Did this arrive?", delivery = Delivery.Sending, requestId = 1, clientMessageId = "abc")
        var driver = JdbcSqliteDriver(url)
        ChatDatabase.Schema.create(driver)
        val seeded = CachedChat("rene", defaultRooms + room + direct,
            mapOf(42L to listOf(received), dm to listOf(pending)), mapOf(42L to 1), mapOf(42L to 3), setOf(42L))
        SqliteMessageStore(driver).save(profile, seeded)
        driver.close()
        driver = JdbcSqliteDriver(url)
        val cache = SqliteMessageStore(driver)
        val job = SupervisorJob()
        val scope = CoroutineScope(coroutineContext + job)
        val http = HttpClient(CIO) { install(WebSockets) }
        val settings = CacheSettings(profile)
        val client = ChatClient(http, settings, scope, cache)
        try {
            val restored = withTimeout(5_000) { client.state.first { it.messages.isNotEmpty() } }
            assertEquals(Connection.Disconnected, restored.connection)
            assertEquals("rene", restored.username)
            assertEquals(received, restored.messages[42]?.single())
            assertTrue(direct in restored.conversations)
            val unknown = restored.messages[dm]!!.single()
            assertEquals(Delivery.Unconfirmed, unknown.delivery)
            assertEquals(0, unknown.requestId)
            assertEquals("abc", unknown.clientMessageId)
            client.select(42)
            client.draft(42, "Offline draft stays editable 🌲")
            assertEquals("Offline draft stays editable 🌲", client.state.value.drafts[42])
            assertEquals("Offline draft stays editable 🌲", settings.drafts(profile)["room:42"])
            client.sendSelected()
            assertEquals("Offline draft stays editable 🌲", client.state.value.drafts[42])
            assertEquals(listOf(received), client.state.value.messages[42])
            val flush = scope.launch(start = CoroutineStart.UNDISPATCHED) { client.flushCache() }
            val nextClient = ChatClient(http, settings, scope, cache)
            val nextState = withTimeout(5_000) { nextClient.state.first { it.messages.isNotEmpty() } }
            assertNull(nextState.unread[42]) // a new activity must read after the queued background flush
            assertEquals("Offline draft stays editable 🌲", nextState.drafts[42])
            flush.join()
            assertNull(cache.load(profile)!!.unread[42])
            assertEquals(mapOf(42L to 3L), cache.load(profile)!!.replayFrom)
            assertEquals(listOf(received), cache.load(profile)!!.messages[42])
            client.configure(profile.copy(workspace = "other")); client.disconnect(); client.flushCache()
            assertTrue(client.state.value.messages.isEmpty())
            client.configure(profile); client.disconnect(); client.flushCache()
            assertEquals(received, client.state.value.messages[42]!!.single())
        } finally { client.disconnect(); job.cancelAndJoin(); http.close(); driver.close(); directory.deleteRecursively() }
    }

    @Test fun sqliteBoundsHistoryAndIsolatesBothServerAndWorkspace() = runBlocking {
        val driver = JdbcSqliteDriver(JdbcSqliteDriver.IN_MEMORY)
        ChatDatabase.Schema.create(driver)
        val cache = SqliteMessageStore(driver)
        val one = Profile("https://one.example", "studio")
        val otherWorkspace = one.copy(workspace = "other")
        val otherServer = one.copy(server = "https://two.example")
        try {
            val messages = (1L..1001L).map { Message("2:$it", 2, it, "bob", it, "record $it") }
            cache.save(one, CachedChat(messages = mapOf(2L to messages)))
            cache.save(otherWorkspace, CachedChat(username = "workspace-owner"))
            cache.save(otherServer, CachedChat(username = "server-owner"))
            val loaded = cache.load(one)!!.messages[2]!!
            assertEquals((2L..1001L).toList(), loaded.map { it.sequence })
            assertEquals("record 2", loaded.first().text)
            assertEquals("workspace-owner", cache.load(otherWorkspace)!!.username)
            assertEquals("server-owner", cache.load(otherServer)!!.username)
            assertNull(cache.load(one.copy(workspace = "absent")))
            val changed = loaded.takeLast(2).reversed().map { it.copy(delivery = Delivery.Sent) }
            cache.save(one, CachedChat(messages = mapOf(2L to changed)))
            assertEquals(changed, cache.load(one)!!.messages[2])
            assertEquals("workspace-owner", cache.load(otherWorkspace)!!.username)
        } finally { driver.close() }
    }

    @Test fun versionOneOversizedInlineReceiptsMigrateWithoutTruncationAndReopenInBoundedRows() = runBlocking {
        val directory = Files.createTempDirectory("nrc-cache-migration").toFile()
        val url = "jdbc:sqlite:${directory.resolve("history.db")}"
        val profile = Profile("https://legacy.example", "studio")
        val revoked = Long.MIN_VALUE + 73
        val roomReceipts = (1L..6000L).toSet()
        val revokedReceipts = (10_000_000_000L..10_000_180_000L).toSet()
        val original = CachedChat(username = "lena🌲", conversations = defaultRooms + Conversation(revoked, "saved", true),
            seenAhead = mapOf(2L to roomReceipts, revoked to revokedReceipts))
        val payload = Json.encodeToString(original)
        assertTrue(payload.toByteArray().size > 2 * 1024 * 1024, "fixture crosses a normal Android cursor-window budget")
        // A real version-one database: no receipt table exists until the production migration runs.
        java.sql.DriverManager.getConnection(url).use { connection ->
            connection.createStatement().use { sql ->
                sql.execute("CREATE TABLE chat_cache(server TEXT NOT NULL, workspace TEXT NOT NULL, payload TEXT NOT NULL, PRIMARY KEY(server, workspace))")
                sql.execute("CREATE TABLE chat_message(server TEXT NOT NULL, workspace TEXT NOT NULL, conversation_id INTEGER NOT NULL, message_key TEXT NOT NULL, position INTEGER NOT NULL, payload TEXT NOT NULL, PRIMARY KEY(server, workspace, conversation_id, message_key))")
                sql.execute("PRAGMA user_version=1")
            }
            connection.prepareStatement("INSERT INTO chat_cache VALUES (?, ?, ?)").use {
                it.setString(1, profile.server); it.setString(2, profile.workspace); it.setString(3, payload); it.executeUpdate()
            }
        }
        var driver = JdbcSqliteDriver(url)
        try {
            ChatDatabase.Schema.migrate(driver, 1, ChatDatabase.Schema.version)
            var cache = SqliteMessageStore(driver)
            val loaded = cache.load(profile)!!
            assertEquals(original.username, loaded.username)
            assertEquals(original.seenAhead, loaded.seenAhead)
            val accessible = Message("2:6001", 2, 6001, "peer", 6001, "accessible room still works")
            val compacted = loaded.copy(messages = mapOf(2L to listOf(accessible)),
                seenAhead = loaded.seenAhead + (2L to setOf(6001L)))
            cache.save(profile, compacted)
            java.sql.DriverManager.getConnection(url).use { connection ->
                connection.createStatement().use { sql ->
                    sql.executeQuery("SELECT payload FROM chat_cache").use { rows ->
                        assertTrue(rows.next()); assertTrue(rows.getString(1).length < 4096, "receipt ledger must leave the metadata row")
                    }
                    sql.executeQuery("SELECT payload FROM chat_receipt").use { rows ->
                        var chunks = 0
                        while (rows.next()) {
                            val values = Json.decodeFromString<List<Long>>(rows.getString(1))
                            assertTrue(values.size in 1..1000); chunks++
                        }
                        assertEquals(182, chunks) //181 revoked chunks plus one accessible room chunk
                    }
                }
            }
            driver.close(); driver = JdbcSqliteDriver(url); cache = SqliteMessageStore(driver)
            val reopened = cache.load(profile)!!
            assertEquals(compacted, reopened)
            assertEquals(revokedReceipts, reopened.seenAhead[revoked], "an inaccessible saved DM cannot discard legacy receipts")
            cache.save(profile, reopened.copy(messages = emptyMap(), seenAhead = mapOf(revoked to revokedReceipts)))
            assertEquals(mapOf(revoked to revokedReceipts), cache.load(profile)!!.seenAhead)
            assertTrue(cache.load(profile)!!.messages.isEmpty())
        } finally { driver.close(); directory.deleteRecursively() }
    }
}

private class CacheSettings(private var saved: Profile) : LocalStore {
    private val values = mutableMapOf<Pair<Profile, String>, String>()
    override fun profile() = saved
    override fun saveProfile(profile: Profile) { saved = profile }
    override fun drafts(profile: Profile) = values.filterKeys { it.first == profile }.mapKeys { it.key.second }
    override fun saveDraft(profile: Profile, conversationKey: String, text: String) { values[profile to conversationKey] = text }
    override fun clearDrafts(profile: Profile) { values.keys.removeAll { it.first == profile } }
}
