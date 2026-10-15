package dev.nrc.chat

import io.ktor.client.HttpClient
import io.ktor.client.plugins.ResponseException
import io.ktor.client.plugins.expectSuccess
import io.ktor.client.plugins.websocket.DefaultClientWebSocketSession
import io.ktor.client.plugins.websocket.webSocket
import io.ktor.http.URLProtocol
import io.ktor.http.Url
import io.ktor.http.hostWithPort
import io.ktor.websocket.Frame
import io.ktor.websocket.close
import io.ktor.websocket.readBytes
import kotlinx.coroutines.*
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.combine
import kotlinx.coroutines.flow.distinctUntilChanged
import kotlinx.coroutines.flow.update
import kotlinx.datetime.Clock
import kotlin.random.Random

/** Own on a UI/main coroutine scope. The platform host controls foreground lifetime. */
class ChatClient(private val http: HttpClient, private val store: LocalStore, private val scope: CoroutineScope,
                 private val messageStore: MessageStore? = null) {
    private val saved = store.profile()
    private val mutable = MutableStateFlow(ChatState(profile = saved,
        drafts = if (messageStore == null) restoreDrafts(saved, defaultRooms) else emptyMap(), storageBlocked = messageStore != null,
        diagnostics = try { store.diagnostics().takeLast(MAX_DIAGNOSTIC_EVENTS) } catch (_: Exception) { emptyList() }))
    val state: StateFlow<ChatState> = mutable
    private var connectionJob: Job? = null
    private var socket: DefaultClientWebSocketSession? = null
    private var generation = 0
    private var nextRequest = 1
    private val subscriptions = mutableMapOf<Int, List<Long>>()
    private val sessionSubscriptions = mutableSetOf<Long>()
    private data class History(val id: Long, val cursor: Long, val ascending: Boolean, val attempt: Int = 0)
    private val historyRequests = mutableMapOf<Int, History>()
    private val historyQueue = mutableListOf<History>()
    private val failedHistory = mutableMapOf<Long, History>()
    private val deniedHistory = mutableSetOf<Long>()
    private var historyRetry: Job? = null
    private val replayFrom = mutableMapOf<Long, Long>()
    private val loadedHistory = mutableSetOf<Long>()
    private val seenThrough = mutableMapOf<Long, Long>()
    private val seenAhead = mutableMapOf<Long, Set<Long>>()
    private val baselineEstablished = mutableSetOf<Long>()
    private val replayNeededThrough = mutableMapOf<Long, Long>()
    private var observedHighWater = 0L
    private var namespaceAtConnect = 0L
    private val cacheRevision = MutableStateFlow(0L)
    private val presenceSequences = mutableMapOf<Long, Long>()
    private var lastPong = 0L
    private var sessionKey = ""
    private var cacheJob: Job? = null
    private var cacheLoaded = CompletableDeferred<Unit>()
    private var cacheReady = false
    private var fileJob: Job? = null

    init { restoreCache() }

    private fun recordDiagnostic(level: DiagnosticLevel, summary: String, detail: String = "") {
        val event = DiagnosticEvent(Clock.System.now().toEpochMilliseconds(), level, summary, detail)
        mutable.update { it.copy(diagnostics = (it.diagnostics + event).takeLast(MAX_DIAGNOSTIC_EVENTS)) }
        saveDiagnostics()
    }

    private fun saveDiagnostics() {
        try { store.saveDiagnostics(state.value.diagnostics) }
        catch (_: Exception) {
            val event = DiagnosticEvent(Clock.System.now().toEpochMilliseconds(), DiagnosticLevel.Warning,
                "System log could not be saved", "Events are available in memory only. Check device storage.")
            mutable.update { it.copy(diagnostics = (it.diagnostics + event).takeLast(MAX_DIAGNOSTIC_EVENTS)) }
        }
    }

    fun clearDiagnostics() { mutable.update { it.copy(diagnostics = emptyList()) }; saveDiagnostics() }

    private fun recordFailure(error: Throwable, phase: String, reason: String? = null) {
        val (summary, detail) = connectionFailure(error, phase, reason)
        recordDiagnostic(DiagnosticLevel.Error, summary, detail)
    }

    private fun cachedChat(state: ChatState) = CachedChat(state.username, state.conversations,
        state.messages, state.unread, replayFrom.toMap(), loadedHistory.toSet(), state.olderCursor,
        seenThrough.toMap(), seenAhead.toMap(), observedHighWater, baselineEstablished.toSet(),
        replayNeededThrough.toMap(), state.syncPaused, receiptsAuthoritative = true)

    private fun restoreCache() {
        cacheJob?.cancel()
        cacheReady = false
        val loaded = CompletableDeferred<Unit>()
        cacheLoaded = loaded
        val profile = state.value.profile
        if (messageStore == null) { loaded.complete(Unit); return }
        cacheJob = scope.launch {
            try {
                val cached = messageStore.load(profile)
                ensureActive()
                if (cached != null) {
                    replayFrom.putAll(cached.replayFrom)
                    loadedHistory.addAll(cached.loadedHistory.filter { it in replayFrom })
                    seenThrough.putAll(cached.seenThrough.ifEmpty { cached.replayFrom })
                    seenAhead.putAll(cached.seenAhead)
                    baselineEstablished.addAll(cached.baselineEstablished + cached.replayFrom.keys)
                    replayNeededThrough.putAll(cached.replayNeededThrough)
                    val legacyHighWater = if (cached.receiptsAuthoritative) 0 else maxOf(
                        cached.messages.values.flatten().maxOfOrNull { it.sequence } ?: 0,
                        cached.seenAhead.values.maxOfOrNull { it.maxOrNull() ?: 0 } ?: 0)
                    observedHighWater = maxOf(cached.observedHighWater, cached.replayFrom.values.maxOrNull() ?: 0,
                        legacyHighWater)
                    // Old caches predate independent receipts. New caches are authoritative:
                    // an ACKed outgoing message must never manufacture a delivery receipt.
                    if (!cached.receiptsAuthoritative) cached.messages.forEach { (id, messages) ->
                        seenAhead[id] = seenAhead[id].orEmpty() + messages.filter { it.author != cached.username }
                            .map { it.sequence }.filter { it > (seenThrough[id] ?: 0) }
                    }
                    val conversations = (cached.conversations + defaultRooms).distinctBy { it.id }
                    mutable.update { it.copy(username = cached.username, conversations = conversations,
                        messages = cached.messages.mapValues { (_, messages) -> messages.takeLast(1000).map { message ->
                            // Pre-fix retention-disable/remap archives discarded sequence
                            // identity without changing the server-shaped key. Normalize once.
                            message.copy(key = if (message.sequence == 0L && LEGACY_SERVER_KEY.matches(message.key))
                                "archived:${Random.nextBytes(16).messageIdString()}" else message.key,
                                requestId = 0, delivery = if (message.delivery == Delivery.Sending) Delivery.Unconfirmed else message.delivery)
                        } }, unread = cached.unread, olderCursor = cached.olderCursor,
                        drafts = restoreDrafts(profile, conversations), syncPaused = cached.syncPaused +
                            seenAhead.filterValues { receipts -> receipts.size >= MAX_AHEAD_RECEIPTS }.keys) }
                } else mutable.update { it.copy(drafts = restoreDrafts(profile, defaultRooms)) }
                cacheReady = true
                mutable.update { it.copy(storageBlocked = false) }
            } catch (cancelled: CancellationException) { throw cancelled }
            catch (error: Exception) {
                recordFailure(error, "Local history load", "Could not open device-local history. Connection is blocked to protect saved data.")
                mutable.update { it.copy(drafts = emptyMap(), storageBlocked = true, notice = "Could not open local chat history. Connection is blocked to protect saved identity data. Existing stored data has not been overwritten.") }
            } finally { loaded.complete(Unit) }
            if (cacheReady) combine(state, cacheRevision) { _, _ -> cachedChat(state.value) }
                .distinctUntilChanged().collect { persistCache(profile) }
        }
    }

    private suspend fun persistCache(profile: Profile) {
        if (!cacheReady || state.value.profile != profile) return
        try { messageStore?.save(profile, cachedChat(state.value)) }
        catch (cancelled: CancellationException) { throw cancelled }
        catch (error: Exception) {
            recordFailure(error, "Local history save", "Could not save device-local history. Check device storage.")
            mutable.update { it.copy(notice = "Local history could not be saved. Check device storage.") }
        }
    }

    /** Flush the current copy when the platform backgrounds/closes the app. Never resend. */
    suspend fun flushCache() = withContext(NonCancellable) {
        cacheLoaded.await()
        persistCache(state.value.profile)
    }

    fun configure(profile: Profile) {
        connectionUrl(profile) // validate before changing the saved profile
        disconnect()
        store.saveProfile(profile)
        if (profile == state.value.profile) { connect(); return }
        if (cacheReady && messageStore != null) {
            val previousProfile = state.value.profile
            val previousChat = cachedChat(state.value)
            scope.launch(start = CoroutineStart.UNDISPATCHED) {
                try { messageStore.save(previousProfile, previousChat) }
                catch (cancelled: CancellationException) { throw cancelled }
                catch (_: Exception) { mutable.update { it.copy(notice = "Previous workspace history could not be saved.") } }
            }
        }
        replayFrom.clear(); loadedHistory.clear(); seenThrough.clear(); seenAhead.clear()
        baselineEstablished.clear(); replayNeededThrough.clear(); observedHighWater = 0
        mutable.value = ChatState(profile = profile,
            drafts = if (messageStore == null) restoreDrafts(profile, defaultRooms) else emptyMap(), storageBlocked = messageStore != null,
            diagnostics = state.value.diagnostics)
        recordDiagnostic(DiagnosticLevel.Info, "Connection settings changed")
        restoreCache()
        connect()
    }

    fun connect() {
        if (connectionJob?.isActive == true || state.value.profile.server.isBlank()) return
        val profile = state.value.profile
        val currentGeneration = generation
        val restore = cacheLoaded
        connectionJob = scope.launch {
            restore.await()
            if (state.value.storageBlocked || (messageStore != null && !cacheReady)) {
                recordDiagnostic(DiagnosticLevel.Warning, "Connection blocked", "Local identity/history storage is unavailable.")
                return@launch
            }
            var attempt = 0
            var fatal = false
            while (isActive && !fatal) {
                mutable.update { it.copy(connection = if (attempt == 0) Connection.Connecting else Connection.Reconnecting) }
                recordDiagnostic(DiagnosticLevel.Info, "Connecting", "Attempt ${attempt + 1}. Opening secure WebSocket transport.")
                var phase = "Transport"
                var failureReason: String? = null
                try {
                    // The WebSockets plugin requires HTTP 101. Default HTTP body validation
                    // loses body-bearing 401 statuses in OkHttp before that check can run.
                    http.webSocket(urlString = connectionUrl(profile), request = { expectSuccess = false }) {
                        ensureActive()
                        if (generation != currentGeneration) return@webSocket
                        socket = this
                        phase = "NRC handshake"
                        recordDiagnostic(DiagnosticLevel.Info, "WebSocket opened", "Waiting for authenticated NRC ServerReady.")
                        subscriptions.clear(); sessionSubscriptions.clear(); clearHistory(); presenceSequences.clear()
                        val first = withTimeout(10_000) { incoming.receive() }
                        if (first !is Frame.Binary) failureReason = "Expected a binary NRC handshake; check proxy routing and server protocol."
                        require(first is Frame.Binary) { "Expected NRC handshake" }
                        failureReason = "Invalid NRC ServerReady. Check proxy routing and server protocol."
                        val ready = Protocol.decode(first.readBytes()) as? Protocol.Ready
                            ?: error("Expected NRC ServerReady")
                        failureReason = null
                        if (ready.version != Protocol.VERSION || !ready.authenticated || ready.username.isBlank()) {
                            fatal = true
                            failureReason = if (ready.version != Protocol.VERSION) "Protocol mismatch: server ${ready.version}, app ${Protocol.VERSION}" else "Authenticated identity required"
                            error(failureReason!!)
                        }
                        attempt = 0
                        lastPong = now()
                        sessionKey = Random.nextBytes(16).messageIdString()
                        namespaceAtConnect = observedHighWater
                        if (state.value.username.isNotBlank() && state.value.username != ready.username) {
                            // Hide old drafts immediately, and do not accept the new identity unless
                            // every persisted draft (including undiscovered DMs) has been removed.
                            mutable.update { it.copy(drafts = emptyMap(), storageBlocked = true) }
                            try { store.clearDrafts(profile) }
                            catch (error: Exception) {
                                fatal = true
                                failureReason = "Could not clear previous identity's drafts. Connection stopped."
                                throw error
                            }
                            replayFrom.clear(); loadedHistory.clear(); seenThrough.clear(); seenAhead.clear()
                            baselineEstablished.clear(); replayNeededThrough.clear(); observedHighWater = 0; namespaceAtConnect = 0
                            mutable.value = ChatState(profile = profile, diagnostics = state.value.diagnostics)
                        }
                        mutable.update { it.copy(connection = Connection.Connected, username = ready.username,
                            notice = if (messageStore != null && !cacheReady) it.notice else null,
                            retention = emptyMap(), members = emptyMap(), liveDMs = emptySet()) }
                        phase = "Session"
                        recordDiagnostic(DiagnosticLevel.Info, "Connected", "Authenticated NRC handshake accepted; protocol ${ready.version}.")
                        subscribeConversations(state.value.conversations.filterNot { it.direct }.map { it.id })
                        send(Frame.Binary(true, Protocol.listDMs(request())))
                        send(Frame.Binary(true, Protocol.rooms(request())))
                        val heartbeat = launch {
                            while (isActive) {
                                delay(5_000)
                                if (now() - lastPong > 20_000_000_000L) {
                                    recordDiagnostic(DiagnosticLevel.Warning, "Heartbeat timed out", "No server pong for 20 seconds; reconnecting.")
                                    close(); break
                                }
                                send(Frame.Binary(true, Protocol.ping(now())))
                            }
                        }
                        try {
                            for (frame in incoming) {
                                if (frame is Frame.Binary) handle(Protocol.decode(frame.readBytes()))
                            }
                            if (generation == currentGeneration) {
                                val code = withTimeoutOrNull(250) { closeReason.await() }?.code
                                recordDiagnostic(DiagnosticLevel.Warning, "WebSocket closed", "Session ended${code?.let { "; close code $it" }.orEmpty()}.")
                            }
                        } finally { heartbeat.cancel() }
                    }
                } catch (timeout: TimeoutCancellationException) {
                    currentCoroutineContext().ensureActive()
                    if (generation == currentGeneration) {
                        recordFailure(timeout, phase, if (phase == "NRC handshake")
                            "No NRC ServerReady within 10 seconds. Check proxy routing and server availability." else null)
                        mutable.update { it.copy(notice = "Connection timed out. Open System log for details.") }
                    }
                } catch (cancelled: CancellationException) { throw cancelled }
                catch (error: Exception) {
                    if (error is ResponseException && error.response.status.value in listOf(401, 403)) {
                        fatal = true
                        failureReason = "HTTP ${error.response.status.value}: access rejected. Check proxy authentication and Tailscale access policy."
                    }
                    if (generation == currentGeneration) {
                        recordFailure(error, phase, failureReason)
                        mutable.update { it.copy(notice = if (fatal) failureReason ?: "Connection stopped. Open System log for details."
                            else "Unable to connect. Open System log for details.") }
                    }
                } finally {
                    if (generation == currentGeneration) {
                        cancelFileTransfer()
                        socket = null
                        clearHistory()
                        mutable.update { old -> old.copy(connection = Connection.Disconnected, loadingHistory = emptySet(), members = emptyMap(), liveDMs = emptySet(),
                        messages = old.messages.mapValues { (_, messages) -> messages.map {
                            if (it.delivery == Delivery.Sending) it.copy(delivery = Delivery.Unconfirmed) else it
                        } }) }
                    }
                }
                if (!fatal && isActive) {
                    mutable.update { it.copy(connection = Connection.Reconnecting) }
                    val retryDelay = (1_000L shl attempt.coerceAtMost(5)).coerceAtMost(30_000) + Random.nextLong(250)
                    recordDiagnostic(DiagnosticLevel.Info, "Reconnect scheduled", "Retry in ${retryDelay / 1000} seconds.")
                    delay(retryDelay)
                    attempt++
                }
            }
        }
    }

    fun disconnect() {
        cancelFileTransfer()
        if (connectionJob?.isActive == true) recordDiagnostic(DiagnosticLevel.Info, "Connection stopped", "Local disconnect or app backgrounded.")
        generation++
        connectionJob?.cancel(); connectionJob = null
        socket = null
        clearHistory()
        mutable.update { old -> old.copy(connection = Connection.Disconnected, members = emptyMap(), liveDMs = emptySet(), loadingHistory = emptySet(),
            messages = old.messages.mapValues { (_, messages) -> messages.map {
                if (it.delivery == Delivery.Sending) it.copy(delivery = Delivery.Unconfirmed) else it
            } }) }
    }

    fun select(id: Long?) {
        if (state.value.selected != id) cancelFileTransfer()
        mutable.update { it.copy(selected = id, unread = if (id == null) it.unread else it.unread - id, notice = null) }
    }
    fun dismissNotice() { mutable.update { it.copy(notice = null) } }

    fun draft(id: Long, text: String) {
        if (state.value.storageBlocked) return
        if (text.encodeToByteArray().size > Protocol.MAX_CONTENT_BYTES) {
            mutable.update { it.copy(notice = "Messages are limited to 50 KiB of UTF-8 text.") }; return
        }
        try {
            val conversation = state.value.conversations.firstOrNull { it.id == id } ?: return
            store.saveDraft(state.value.profile, conversation.draftKey(), text)
            mutable.update { it.copy(drafts = it.drafts + (id to text)) }
        } catch (error: Exception) {
            recordFailure(error, "Draft save", "Could not save a draft. Check device storage.")
            mutable.update { it.copy(notice = "Could not save the draft. Check device storage.") }
        }
    }

    fun sendSelected() {
        val current = state.value
        current.selected?.let { sendMessage(current.drafts[it].orEmpty().trim(), clearDraft = true) }
    }

    private fun sendMessage(text: String, clearDraft: Boolean): Boolean {
        val current = state.value
        if (current.storageBlocked) return false
        val id = current.selected ?: return false
        if (current.connection != Connection.Connected || text.isBlank()) return false
        val conversation = current.conversations.firstOrNull { it.id == id } ?: return false
        if (conversation.direct && id !in current.liveDMs) return false
        if (current.retention[id] !in listOf(Retention.Enabled, Retention.Ephemeral)) return false
        val target = socket ?: return false
        val currentGeneration = generation
        val request = request()
        val messageId = if (current.retention[id] == Retention.Enabled) Random.nextBytes(16) else null
        val frame = Protocol.send(id, request, text, messageId)
        val message = Message("pending:${Random.nextBytes(16).messageIdString()}", id, author = current.username, timestampNanos = now(),
            text = text, delivery = Delivery.Sending, requestId = request, clientMessageId = messageId?.messageIdString())
        if (clearDraft) {
            draft(id, "")
            if (state.value.drafts[id].orEmpty().isNotEmpty()) return false // storage failure: preserve the draft
        }
        mutable.update { it.copy(messages = it.messages + (id to (it.messages[id].orEmpty() + message).takeLast(1000))) }
        scope.launch {
            try { target.send(Frame.Binary(true, frame)) }
            catch (error: Exception) {
                if (generation != currentGeneration) return@launch
                recordFailure(error, "Message send", "Send interrupted; delivery is unknown. No automatic resend.")
                updatePending(request) { it.copy(delivery = Delivery.Unconfirmed) }
                return@launch
            }
            delay(15_000)
            if (state.value.messages[id].orEmpty().any { it.requestId == request && it.delivery == Delivery.Sending })
                recordDiagnostic(DiagnosticLevel.Warning, "Message acknowledgement timed out", "Delivery is unknown; no automatic resend.")
            updatePending(request) { if (it.delivery == Delivery.Sending) it.copy(delivery = Delivery.Unconfirmed) else it }
        }
        return true
    }

    fun attachmentTarget(): AttachmentTarget? {
        val current = state.value
        val id = current.selected ?: return null
        if (current.storageBlocked || current.connection != Connection.Connected || current.username.isBlank()) return null
        return AttachmentTarget(current.profile, current.username, id)
    }

    fun cancelFileTransfer() {
        fileJob?.cancel(); fileJob = null
        mutable.update { it.copy(fileTransfer = null) }
    }

    fun uploadAttachment(target: AttachmentTarget, file: AttachmentUpload): Job? = transfer(target, file.filename, true) { progress ->
        val session = socket
        val uploaded = AttachmentFiles(http).upload(target.profile, target.conversationId, file, progress)
        check(session != null && socket === session && attachmentTarget() == target &&
            sendMessage(uploaded.messageText(), clearDraft = false)) { "Conversation or connection changed" }
    }

    fun downloadAttachment(target: AttachmentTarget, attachment: ChatAttachment,
                           write: suspend (ByteArray, Int) -> Unit,
                           onComplete: suspend () -> Unit = {}): Job? = transfer(target, attachment.filename, false) { progress ->
        AttachmentFiles(http).download(target.profile, attachment, progress, write)
        check(attachmentTarget() == target) { "Conversation or connection changed" }
        onComplete()
    }

    private fun transfer(target: AttachmentTarget, filename: String, uploading: Boolean,
                         action: suspend (suspend (Long, Long) -> Unit) -> Unit): Job? {
        if (fileJob != null || attachmentTarget() != target) return null
        if (uploading && state.value.retention[target.conversationId] !in listOf(Retention.Enabled, Retention.Ephemeral)) return null
        if (uploading && state.value.conversations.any { it.id == target.conversationId && it.direct } &&
            target.conversationId !in state.value.liveDMs) return null
        val sessionGeneration = generation
        val job = scope.launch(start = CoroutineStart.LAZY) {
            val ownJob = currentCoroutineContext()[Job]
            try {
                action { bytes, total ->
                    if (fileJob === ownJob) mutable.update { it.copy(fileTransfer = FileTransfer(filename, uploading, bytes, total)) }
                }
            } catch (timeout: TimeoutCancellationException) {
                currentCoroutineContext().ensureActive()
                if (generation == sessionGeneration) mutable.update { it.copy(notice = "File transfer timed out. Select the file again to retry.") }
            } catch (cancelled: CancellationException) { throw cancelled }
            catch (error: Exception) {
                if (generation == sessionGeneration) {
                    recordFailure(error, "File transfer", "Upload or download failed. Check access, connectivity and device storage.")
                    mutable.update { it.copy(notice = "File transfer failed. Check access, connectivity and storage. No automatic retry.") }
                }
            } finally {
                if (fileJob === ownJob) { fileJob = null; mutable.update { it.copy(fileTransfer = null) } }
            }
        }
        fileJob = job
        mutable.update { it.copy(fileTransfer = FileTransfer(filename, uploading)) }
        job.start()
        return job
    }

    fun startDM(username: String) {
        val name = username.trim().removePrefix("@")
        if (name.isBlank() || name.encodeToByteArray().size > 255 || state.value.connection != Connection.Connected) return
        transmit(Protocol.startDM(name, request()))
    }

    fun loadOlder(id: Long) {
        if (state.value.connection != Connection.Connected || id in state.value.loadingHistory) return
        failedHistory.remove(id)?.let { fetchHistory(it.id, it.cursor, it.ascending); return }
        val cursor = state.value.olderCursor[id] ?: return
        fetchHistory(id, cursor)
    }

    private fun request() = nextRequest++
    private fun restoreDrafts(profile: Profile, conversations: List<Conversation>): Map<Long, String> {
        val drafts = store.drafts(profile)
        return conversations.mapNotNull { conversation -> drafts[conversation.draftKey()]?.let { conversation.id to it } }.toMap()
    }
    private fun now() = Clock.System.now().let { it.epochSeconds * 1_000_000_000L + it.nanosecondsOfSecond }
    private fun transmit(frame: ByteArray) {
        val target = socket ?: return
        val currentGeneration = generation
        scope.launch {
            try { target.send(Frame.Binary(true, frame)) }
            catch (error: Exception) {
                if (generation == currentGeneration) {
                    recordFailure(error, "Request send", "Protocol request could not be sent. Reconnect and try again.")
                    mutable.update { it.copy(notice = "Request could not be sent. Reconnect and try again.") }
                }
            }
        }
    }
    private fun subscribeConversations(ids: List<Long>) {
        ids.chunked(64).forEach { chunk ->
            val req = request(); subscriptions[req] = chunk
            mutable.update { it.copy(retention = it.retention + chunk.associateWith { Retention.Unknown }) }
            transmit(Protocol.subscribe(chunk, req))
        }
    }
    private fun fetchHistory(id: Long, cursor: Long, ascending: Boolean = false) {
        if (state.value.retention[id] != Retention.Enabled) return
        if (historyQueue.any { it.id == id } || historyRequests.values.any { it.id == id }) return
        failedHistory.remove(id)
        historyQueue.add(History(id, cursor, ascending))
        mutable.update { it.copy(loadingHistory = it.loadingHistory + id, failedHistory = it.failedHistory - id) }
        pumpHistory()
    }
    private fun pumpHistory() {
        if (socket == null || historyRequests.isNotEmpty() || historyRetry?.isActive == true || historyQueue.isEmpty()) return
        val next = historyQueue.removeAt(0)
        val req = request(); historyRequests[req] = next
        transmit(Protocol.history(next.id, next.cursor, req, next.ascending))
    }
    private fun clearHistory() {
        historyRetry?.cancel(); historyRetry = null
        historyRequests.clear(); historyQueue.clear(); failedHistory.clear(); deniedHistory.clear()
        mutable.update { it.copy(failedHistory = emptySet()) }
    }
    private fun requireReplay(id: Long, through: Long) {
        if (through > (replayFrom[id] ?: 0)) {
            replayNeededThrough[id] = maxOf(replayNeededThrough[id] ?: 0, through)
        }
    }
    private fun requestCatchup(id: Long) {
        if (id !in loadedHistory || id in failedHistory || id in deniedHistory || id !in replayNeededThrough) return
        fetchHistory(id, replayFrom[id] ?: 0, ascending = true)
    }
    private fun forgetRetained(id: Long) {
        replayFrom.remove(id); loadedHistory.remove(id); seenThrough.remove(id); seenAhead.remove(id)
        baselineEstablished.remove(id); replayNeededThrough.remove(id)
    }
    private fun archive(message: Message): Message = if (message.sequence == 0L) message else message.copy(
        key = "archived:${Random.nextBytes(16).messageIdString()}", sequence = 0, clientMessageId = null)

    private fun resetNamespace() {
        clearHistory()
        replayFrom.clear(); loadedHistory.clear(); seenThrough.clear(); seenAhead.clear(); replayNeededThrough.clear()
        // A restored namespace is not a newly discovered room: recover its new records
        // from zero rather than silently treating them as an initial read baseline.
        baselineEstablished.clear()
        state.value.conversations.forEach { baselineEstablished.add(it.id); replayFrom[it.id] = 0; seenThrough[it.id] = 0 }
        observedHighWater = 0; namespaceAtConnect = 0
        mutable.update { old -> old.copy(messages = old.messages.mapValues { (_, messages) -> messages.map(::archive) },
            olderCursor = emptyMap(), loadingHistory = emptySet(), syncPaused = emptySet()) }
    }
    private fun updatePending(request: Int, transform: (Message) -> Message) {
        mutable.update { state -> state.copy(messages = state.messages.mapValues { (_, messages) ->
            messages.map { if (it.requestId == request) transform(it) else it }
        }) }
    }

    private fun mergeDMs(old: ChatState, fresh: List<Conversation>): ChatState {
        var messages = old.messages
        var unread = old.unread
        var selected = old.selected
        for (conversation in fresh) {
            val previous = old.conversations.firstOrNull { it.direct && it.name == conversation.name } ?: continue
            if (previous.id == conversation.id) continue
            messages = messages - previous.id + (conversation.id to messages[previous.id].orEmpty().map {
                archive(it).copy(conversationId = conversation.id)
            })
            unread = unread - previous.id + (conversation.id to (unread[previous.id] ?: 0))
            forgetRetained(previous.id)
            if (selected == previous.id) selected = conversation.id
        }
        val conversations = old.conversations.filterNot { it.direct && fresh.any { dm -> dm.name == it.name } } + fresh
        return old.copy(conversations = conversations, messages = messages, unread = unread, selected = selected,
            olderCursor = old.olderCursor.filterKeys { id -> conversations.any { it.id == id } },
            syncPaused = old.syncPaused.filter { id -> conversations.any { it.id == id } }.toSet(),
            drafts = restoreDrafts(old.profile, conversations))
    }

    private fun handle(event: Protocol.Event) {
        try { when (event) {
            is Protocol.Incoming -> mutable.update { old ->
                val message = event.message.copy(key = "$sessionKey:${event.message.key}")
                val existing = old.messages[message.conversationId].orEmpty()
                if (existing.any { it.sequence == message.sequence && it.sequence != 0L }) old
                else old.copy(messages = old.messages + (message.conversationId to (existing + message).takeLast(1000)),
                    unread = if (old.selected == message.conversationId || message.author == old.username) old.unread
                    else old.unread + (message.conversationId to (old.unread[message.conversationId].orEmptyCount() + 1)))
            }
            is Protocol.Ack -> updatePending(event.request) {
                if (state.value.retention[it.conversationId] == Retention.Enabled) observedHighWater = maxOf(observedHighWater, event.sequence)
                it.copy(sequence = event.sequence, timestampNanos = event.nanos, delivery = Delivery.Sent)
            }
            is Protocol.Subscribed -> {
                val ids = subscriptions.remove(event.request) ?: return
                val retained = event.entries.map { it.id }.toSet()
                val firstSubscriptions = ids.filterNot { it in sessionSubscriptions }.toSet()
                sessionSubscriptions.addAll(ids)
                firstSubscriptions.filterNot { it in retained }.forEach(::forgetRetained)
                mutable.update { it.copy(retention = it.retention + ids.associateWith {
                    if (it in retained) Retention.Enabled else Retention.Ephemeral
                }, messages = it.messages.mapValues { (id, messages) ->
                    if (id in firstSubscriptions && id !in retained) messages.map(::archive) else messages
                }, olderCursor = it.olderCursor - (firstSubscriptions - retained), syncPaused = it.syncPaused - (firstSubscriptions - retained)) }
                event.entries.forEach { entry ->
                    // Compare against the previous session, not this session's concurrent
                    // live/ACK observations, which can overtake a subscription snapshot.
                    if (entry.highWater < namespaceAtConnect) resetNamespace()
                    observedHighWater = maxOf(observedHighWater, entry.highWater)
                    deniedHistory.remove(entry.id)
                    val loaded = entry.id in loadedHistory
                    if (baselineEstablished.add(entry.id)) {
                        replayFrom[entry.id] = entry.highWater
                        seenThrough[entry.id] = entry.highWater
                    }
                    requireReplay(entry.id, entry.highWater)
                    val baseline = replayFrom.getValue(entry.id)
                    // Before is exclusive. Bound initial history to the original baseline,
                    // so messages arriving during an initial read remain catch-up/unread.
                    fetchHistory(entry.id, if (loaded) baseline else baseline + 1, ascending = loaded)
                }
            }
            is Protocol.Page -> {
                // Request zero is the server's unsolicited retained-message broadcast.
                val live = event.request == 0
                val requested = if (live) null else (historyRequests.remove(event.request) ?: return)
                if (requested != null) require(requested.id == event.id && requested.ascending == event.ascending)
                require(event.messages.all { it.conversationId == event.id })
                if (state.value.retention[event.id] != Retention.Enabled) { pumpHistory(); return }
                val current = state.value
                val initial = !live && !event.ascending && event.id !in loadedHistory
                observedHighWater = maxOf(observedHighWater, event.highWater, event.messages.maxOfOrNull { it.sequence } ?: 0)
                requireReplay(event.id, maxOf(event.highWater, event.messages.maxOfOrNull { it.sequence } ?: 0))
                val through = seenThrough[event.id] ?: 0
                val ahead = seenAhead[event.id].orEmpty()
                val distinct = event.messages.distinctBy { it.sequence }
                val newPeerSequences = distinct.filter { it.author != current.username && it.sequence > through && it.sequence !in ahead }
                    .map { it.sequence }.toSet()
                val blocked = live && (event.id in current.syncPaused || ahead.size + newPeerSequences.size > MAX_AHEAD_RECEIPTS)
                val accepted = when {
                    blocked -> distinct.filterNot { it.sequence in newPeerSequences }
                    initial -> distinct.filter { it.sequence < requested!!.cursor }
                    else -> distinct
                }
                val incomingCount = if ((live || event.ascending) && current.selected != event.id) accepted.count { message ->
                    message.author != current.username && message.sequence > through && message.sequence !in ahead
                } else 0
                if (!live && event.ascending) {
                    // A completed scan proves receipt through its snapshot, even when every
                    // record expired and the continuation cursor is zero. Live/ACK maxima do not.
                    val proven = if (event.hasMore) event.cursor else maxOf(event.cursor, event.highWater)
                    if (event.hasMore) require(proven > requested!!.cursor) { "History did not advance" }
                    replayFrom[event.id] = maxOf(replayFrom[event.id] ?: 0, proven)
                    seenThrough[event.id] = maxOf(through, proven)
                    seenAhead[event.id] = seenAhead[event.id].orEmpty().filter { it > seenThrough.getValue(event.id) }.toSet()
                    if ((replayNeededThrough[event.id] ?: 0) <= replayFrom.getValue(event.id)) replayNeededThrough.remove(event.id)
                } else if (live && !blocked) {
                    seenAhead[event.id] = ahead + newPeerSequences
                }
                if (!live && !event.ascending) loadedHistory.add(event.id)
                mutable.update { old ->
                    val previous = old.messages[event.id].orEmpty()
                    val confirmedIds = accepted.mapNotNull { it.clientMessageId }.toSet()
                    val existing = previous.filterNot {
                        it.author == old.username && it.clientMessageId != null && it.clientMessageId in confirmedIds
                    }
                    val records = accepted.map { if (it.author == old.username) it.copy(delivery = Delivery.Sent) else it }
                    val merged = (existing + records).distinctBy {
                        if (it.sequence != 0L) "seq:${it.sequence}" else it.key
                    }.sortedBy { it.timestampNanos }.takeLast(1000)
                    old.copy(messages = old.messages + (event.id to merged),
                        unread = if (incomingCount == 0) old.unread else old.unread + (event.id to (old.unread[event.id].orEmptyCount() + incomingCount)),
                        loadingHistory = if (live) old.loadingHistory else old.loadingHistory - event.id,
                        syncPaused = if (blocked) old.syncPaused + event.id
                            else if (!live && event.ascending && seenAhead[event.id].orEmpty().size < REPLAY_RECEIPT_THRESHOLD) old.syncPaused - event.id
                            else old.syncPaused,
                        olderCursor = if (merged.size >= 1000) old.olderCursor - event.id
                        else if (live) old.olderCursor
                        else if (!event.ascending && event.hasMore) old.olderCursor + (event.id to event.cursor)
                        else if (!event.ascending) old.olderCursor - event.id else old.olderCursor,
                        notice = if (event.truncated) "Message history is paged; more may be available." else old.notice)
                }
                if (!live && event.ascending && event.hasMore) fetchHistory(event.id, event.cursor, true)
                else if (!live || blocked || seenAhead[event.id].orEmpty().size >= REPLAY_RECEIPT_THRESHOLD) requestCatchup(event.id)
                pumpHistory()
            }
            is Protocol.Rooms -> {
                val fresh = event.conversations.filter { room -> state.value.conversations.none { it.id == room.id } }
                val drafts = restoreDrafts(state.value.profile, fresh)
                mutable.update { it.copy(conversations = (it.conversations + event.conversations).distinctBy { it.id }, drafts = it.drafts + drafts) }
                subscribeConversations(fresh.map { it.id })
                if (event.more) transmit(Protocol.rooms(request(), event.updated, event.asset))
            }
            is Protocol.DMs -> {
                mutable.update { mergeDMs(it, event.conversations).copy(liveDMs = event.conversations.map { dm -> dm.id }.toSet()) }
                subscribeConversations(event.conversations.map { it.id })
            }
            is Protocol.DMStarted -> {
                mutable.update { mergeDMs(it, listOf(event.conversation)).copy(liveDMs = it.liveDMs + event.conversation.id) }
                subscribeConversations(listOf(event.conversation.id))
                if (event.initiator) select(event.conversation.id)
            }
            is Protocol.DMLeft -> {
                historyQueue.removeAll { it.id == event.id }; failedHistory.remove(event.id)
                historyRequests.entries.removeAll { it.value.id == event.id }
                mutable.update { it.copy(liveDMs = it.liveDMs - event.id, retention = it.retention - event.id,
                    loadingHistory = it.loadingHistory - event.id, failedHistory = it.failedHistory - event.id) }
                pumpHistory()
            }
            is Protocol.Presence -> {
                if (event.sequence <= (presenceSequences[event.id] ?: -1)) return
                presenceSequences[event.id] = event.sequence
                mutable.update { old ->
                    val users = old.members[event.id].orEmpty()
                    val next = when (event.kind) { 0 -> users + event.name; 1 -> users - event.name
                        2 -> event.users; 3 -> (users - event.oldName) + event.name; else -> users }
                    old.copy(members = old.members + (event.id to next))
                }
            }
            is Protocol.Error -> {
                recordDiagnostic(DiagnosticLevel.Warning, "Server rejected a request", "Opcode ${event.origin}; response payload omitted for privacy.")
                updatePending(event.request) { it.copy(delivery = Delivery.Failed) }
                val history = historyRequests.remove(event.request)
                val transient = event.text in setOf("retained history capacity reached", "too many retained message operations", "message storage maintenance; retry")
                if (history != null && transient && history.attempt < 4) {
                    historyQueue.add(history.copy(attempt = history.attempt + 1))
                    historyRetry = scope.launch {
                        delay(250L shl history.attempt)
                        historyRetry = null
                        pumpHistory()
                    }
                } else {
                    if (history != null) {
                        if (transient || event.text == "retained history read failed") failedHistory[history.id] = history.copy(attempt = 0)
                        else deniedHistory.add(history.id)
                    }
                    mutable.update { it.copy(notice = event.text,
                        loadingHistory = if (history == null) it.loadingHistory else it.loadingHistory - history.id,
                        failedHistory = failedHistory.keys.toSet()) }
                    pumpHistory()
                }
            }
            Protocol.Pong -> lastPong = now()
            else -> Unit
        } } finally { cacheRevision.value++ }
    }

    companion object {
        private const val REPLAY_RECEIPT_THRESHOLD = 256
        private const val MAX_AHEAD_RECEIPTS = 2048
        private val LEGACY_SERVER_KEY = Regex("-?[0-9]+:[0-9]+")

        fun connectionUrl(profile: Profile): String {
            require(Regex("[A-Za-z0-9_-]{1,128}").matches(profile.workspace)) { "Use a workspace name with letters, numbers, _ or -." }
            val url = Url(profile.server.trim())
            require(url.protocol == URLProtocol.HTTPS || url.protocol == URLProtocol.WSS) { "Use your NRC HTTPS address." }
            require(url.host.isNotBlank() && url.user == null && url.password == null && url.parameters.isEmpty() && url.fragment.isBlank())
            require(url.encodedPath == "/" || url.encodedPath.isEmpty()) { "Enter the server address without a workspace path." }
            return "wss://${url.hostWithPort}/${profile.workspace}"
        }
    }
}

private fun Int?.orEmptyCount() = this ?: 0
