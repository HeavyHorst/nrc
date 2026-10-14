package dev.nrc.chat

import app.cash.sqldelight.db.SqlDriver
import dev.nrc.chat.db.ChatDatabase
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json

/** Atomic, bounded history. Each message has its own row, below Android's cursor-window limit. */
class SqliteMessageStore(driver: SqlDriver) : MessageStore {
    private val database = ChatDatabase(driver)
    private val mutex = Mutex()
    private val json = Json { ignoreUnknownKeys = true }
    private val previous = mutableMapOf<Profile, CachedChat>()
    private val inlineReceipts = mutableSetOf<Profile>()

    // Take the lock before dispatching: a background flush must precede a new activity's read.
    override suspend fun load(profile: Profile): CachedChat? = mutex.withLock {
        withContext(Dispatchers.IO) {
            val queries = database.chatCacheQueries
            queries.cacheLength(profile.server, profile.workspace).executeAsOneOrNull()
                ?.let { length ->
                    // Old versions put the entire ledger in this row. Read slices so an
                    // oversized legacy payload can migrate without an Android CursorWindow failure.
                    val metadata = buildString {
                        var start = 1L
                        while (start <= length) {
                            append(queries.readCacheChunk(start.toString(), "65536", profile.server, profile.workspace).executeAsOne())
                            start += 65536L // SQLite offsets/counts are Unicode code points, not UTF-16 units.
                        }
                    }
                    val cached = json.decodeFromString<CachedChat>(metadata)
                    if (cached.seenAhead.values.any { it.isNotEmpty() }) inlineReceipts.add(profile)
                    val receipts = cached.seenAhead.mapValues { (_, sequences) -> sequences.toMutableSet() }.toMutableMap()
                    queries.readReceipts(profile.server, profile.workspace).executeAsList().forEach { row ->
                        receipts.getOrPut(row.conversation_id) { mutableSetOf() }.addAll(json.decodeFromString<List<Long>>(row.payload))
                    }
                    val messages = queries.readMessages(profile.server, profile.workspace).executeAsList()
                        .map { json.decodeFromString<Message>(it) }.groupBy { it.conversationId }
                    cached.copy(messages = messages, seenAhead = receipts.mapValues { it.value.toSet() }).also { previous[profile] = it }
                }
        }
    }

    override suspend fun save(profile: Profile, chat: CachedChat) = mutex.withLock {
        withContext(Dispatchers.IO) {
            val bounded = chat.copy(messages = chat.messages.mapValues { (_, messages) -> messages.takeLast(1000) })
            val before = previous[profile]
            database.transaction {
                val queries = database.chatCacheQueries
                queries.writeCache(profile.server, profile.workspace, json.encodeToString(bounded.copy(messages = emptyMap(),
                    seenAhead = bounded.seenAhead.filterValues { it.isEmpty() })))
                if (before == null) {
                    queries.deleteMessages(profile.server, profile.workspace)
                    queries.deleteProfileReceipts(profile.server, profile.workspace)
                }
                (before?.seenAhead.orEmpty().keys + bounded.seenAhead.keys).forEach { id ->
                    if (before == null || profile in inlineReceipts || before.seenAhead[id] != bounded.seenAhead[id]) {
                        queries.deleteReceipts(profile.server, profile.workspace, id)
                        // Legacy ledgers may exceed the new admission cap. Preserve every
                        // sequence in small rows; only proven replay may compact those ledgers.
                        bounded.seenAhead[id].orEmpty().toList().chunked(1000).forEachIndexed { index, sequences ->
                            queries.writeReceipts(profile.server, profile.workspace, id, index.toLong(), json.encodeToString(sequences))
                        }
                    }
                }
                before?.messages?.forEach { (id, messages) ->
                    val keys = bounded.messages[id].orEmpty().map { it.key }.toSet()
                    messages.filter { it.key !in keys }.forEach {
                        queries.deleteMessage(profile.server, profile.workspace, id, it.key)
                    }
                }
                bounded.messages.forEach { (id, messages) ->
                    messages.forEachIndexed { index, message ->
                        if (before?.messages?.get(id)?.getOrNull(index) != message) {
                            queries.writeMessage(profile.server, profile.workspace, id, message.key, index.toLong(), json.encodeToString(message))
                        }
                    }
                }
            }
            previous[profile] = bounded
            inlineReceipts.remove(profile)
            Unit
        }
    }
}
