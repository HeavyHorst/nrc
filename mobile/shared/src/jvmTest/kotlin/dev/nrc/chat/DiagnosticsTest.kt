package dev.nrc.chat

import app.cash.sqldelight.driver.jdbc.sqlite.JdbcSqliteDriver
import dev.nrc.chat.db.ChatDatabase
import io.ktor.client.HttpClient
import io.ktor.client.engine.cio.CIO
import io.ktor.client.engine.okhttp.OkHttp
import io.ktor.client.plugins.ClientRequestException
import io.ktor.client.plugins.websocket.WebSockets
import io.ktor.client.request.HttpRequestPipeline
import io.ktor.client.request.get
import kotlinx.coroutines.*
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.flow.first
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json
import okhttp3.Response
import okhttp3.WebSocket
import okhttp3.WebSocketListener
import okhttp3.mockwebserver.MockResponse
import okhttp3.mockwebserver.MockWebServer
import okhttp3.tls.HandshakeCertificates
import okhttp3.tls.HeldCertificate
import okio.ByteString
import okio.ByteString.Companion.toByteString
import java.io.ByteArrayOutputStream
import java.io.DataOutputStream
import java.io.IOException
import java.net.ConnectException
import java.net.UnknownHostException
import java.nio.file.Files
import java.security.cert.CertPathValidatorException
import java.util.Properties
import javax.net.ssl.SSLHandshakeException
import kotlin.test.*

class DiagnosticsTest {
    private val sentinels = listOf("PRIVATE_URL_SENTINEL", "PRIVATE_USER_SENTINEL", "PRIVATE_TOKEN_SENTINEL", "PRIVATE_MESSAGE_SENTINEL")
    private val profile = Profile("https://private-url-sentinel.example", "PRIVATE_WORKSPACE_SENTINEL")
    private class DiskSettings(val directory: java.io.File, private var saved: Profile) : LocalStore {
        private val log get() = directory.resolve("events.json")
        private val drafts get() = directory.resolve("drafts.properties")
        override fun profile() = saved
        override fun saveProfile(profile: Profile) { saved = profile }
        override fun diagnostics() = if (log.exists()) Json.decodeFromString<List<DiagnosticEvent>>(log.readText()) else emptyList()
        override fun saveDiagnostics(events: List<DiagnosticEvent>) { log.writeText(Json.encodeToString(events)) }
        override fun drafts(profile: Profile) = Properties().apply {
            if (drafts.exists()) drafts.inputStream().use { load(it) }
        }.let { p -> p.stringPropertyNames().associateWith { p.getProperty(it) } }
        override fun saveDraft(profile: Profile, conversationKey: String, text: String) {
            val p = Properties().apply { putAll(drafts(profile)); setProperty(conversationKey, text) }
            drafts.outputStream().use { p.store(it, null) }
        }
        override fun clearDrafts(profile: Profile) { drafts.delete() }
    }
    private fun assertSanitized(events: List<DiagnosticEvent>) {
        val report = diagnosticReport(events)
        (sentinels + "private-url-sentinel.example" + "PRIVATE_WORKSPACE_SENTINEL").forEach {
            assertFalse(report.contains(it), "Private sentinel must not appear in exported diagnostics")
        }
        assertFalse(report.contains("at dev.nrc."), "No raw stack trace")
        assertTrue(report.contains("timestamps UTC"))
    }
    private fun failingHttp(failure: Exception) = HttpClient(CIO) { install(WebSockets) }.also { http ->
        http.requestPipeline.intercept(HttpRequestPipeline.Before) { throw failure }
    }
    private suspend fun ChatClient.errorEvent() = withTimeout(5_000) {
        state.first { it.diagnostics.any { event -> event.level == DiagnosticLevel.Error } }
            .diagnostics.last { it.level == DiagnosticLevel.Error }
    }

    @Test fun nestedNetworkCausesExposeActionableHintsWithoutRawPrivateMessages() = runBlocking {
        val privateText = sentinels.joinToString(" ")
        val tls = SSLHandshakeException(privateText).apply { initCause(CertPathValidatorException(privateText)) }
        val cases = listOf(
            Triple(UnknownHostException(privateText), "DNS resolution failed", "UnknownHostException"),
            Triple(tls, "TLS verification or negotiation failed", "CertPathValidatorException"),
            Triple(ConnectException("ECONNREFUSED $privateText"), "TCP connection failed", "ECONNREFUSED")
        )
        for ((root, hint, technical) in cases) {
            val directory = Files.createTempDirectory("nrc-diagnostics-").toFile()
            val settings = DiskSettings(directory, profile)
            val job = SupervisorJob(); val scope = CoroutineScope(coroutineContext + job)
            val http = failingHttp(IOException(privateText, IOException(privateText, root)))
            val client = ChatClient(http, settings, scope)
            try {
                client.draft(2, sentinels.last()); client.connect()
                val event = client.errorEvent()
                assertEquals("Transport failed", event.summary)
                assertTrue(event.detail.contains(hint)); assertTrue(event.detail.contains(technical))
                assertTrue(event.detail.contains("IOException → IOException"))
                assertSanitized(client.state.value.diagnostics)
                client.disconnect(); job.cancelAndJoin()
                val restored = DiskSettings(directory, profile).diagnostics()
                assertTrue(restored.any { it.detail == event.detail }); assertSanitized(restored)
                assertEquals(sentinels.last(), settings.drafts(profile)["room:2"])
            } finally { client.disconnect(); job.cancelAndJoin(); http.close(); directory.deleteRecursively() }
        }
    }

    @Test fun realHttp401AndNestedHttp401RetainStatusButNeverResponseBodyOrAddress() = runBlocking {
        val server = MockWebServer()
        val cert = HeldCertificate.Builder().commonName("localhost").addSubjectAlternativeName("localhost").build()
        val serverTls = HandshakeCertificates.Builder().heldCertificate(cert).build()
        val clientTls = HandshakeCertificates.Builder().addTrustedCertificate(cert.certificate).build()
        server.useHttps(serverTls.sslSocketFactory(), false); server.start()
        val privateBody = sentinels.joinToString(" ")
        val responseHttp = HttpClient(CIO) { engine { https { trustManager = clientTls.trustManager } } }
        server.enqueue(MockResponse().setResponseCode(401).setBody(privateBody))
        val response = responseHttp.get(server.url("/PRIVATE_URL_SENTINEL").toString())
        val nested = IOException(privateBody, ClientRequestException(response, privateBody))
        try {
            for (useRealTransport in listOf(false, true)) {
                val directory = Files.createTempDirectory("nrc-401-").toFile()
                val configured = if (useRealTransport) Profile(server.url("/").toString().removeSuffix("/"), "PRIVATE_WORKSPACE_SENTINEL") else profile
                val settings = DiskSettings(directory, configured)
                val job = SupervisorJob(); val scope = CoroutineScope(coroutineContext + job)
                val http = if (useRealTransport) HttpClient(CIO) {
                    install(WebSockets); expectSuccess = true
                    engine { https { trustManager = clientTls.trustManager } }
                } else failingHttp(nested)
                if (useRealTransport) server.enqueue(MockResponse().setResponseCode(401).setBody(privateBody))
                val client = ChatClient(http, settings, scope)
                try {
                    client.connect(); val error = client.errorEvent()
                    assertTrue(error.detail.contains("HTTP 401: access rejected"), "realTransport=$useRealTransport; sanitized detail=${error.detail}")
                    assertTrue(error.detail.contains(if (useRealTransport) "WebSocketException" else "ClientRequestException"))
                    assertSanitized(client.state.value.diagnostics)
                    assertFalse(diagnosticReport(client.state.value.diagnostics).contains("localhost"))
                } finally { client.disconnect(); job.cancelAndJoin(); http.close(); directory.deleteRecursively() }
            }
        } finally { responseHttp.close(); server.shutdown() }
    }

    @Test fun androidOkHttpRejectedTlsUpgradesExposeOnlyStatusAndSafeCauseChain() = runBlocking {
        val server = MockWebServer()
        val cert = HeldCertificate.Builder().commonName("localhost").addSubjectAlternativeName("localhost").build()
        val serverTls = HandshakeCertificates.Builder().heldCertificate(cert).build()
        val clientTls = HandshakeCertificates.Builder().addTrustedCertificate(cert.certificate).build()
        server.useHttps(serverTls.sslSocketFactory(), false); server.start()
        try {
            for (status in listOf(401, 403, 404, 502, 200)) {
                val directory = Files.createTempDirectory("nrc-okhttp-status-").toFile()
                val configured = Profile(server.url("/").toString().removeSuffix("/"), "PRIVATE_URL_SENTINEL_PRIVATE_WORKSPACE_SENTINEL")
                val settings = DiskSettings(directory, configured)
                val job = SupervisorJob(); val scope = CoroutineScope(coroutineContext + job)
                val http = HttpClient(OkHttp) {
                    install(WebSockets); expectSuccess = true; followRedirects = false
                    engine { config { sslSocketFactory(clientTls.sslSocketFactory(), clientTls.trustManager) } }
                }
                server.enqueue(MockResponse().setStatus("HTTP/1.1 $status PRIVATE_REASON_SENTINEL")
                    .setHeader("X-Private-Token", sentinels[2]).setBody(sentinels.joinToString(" ")))
                val client = ChatClient(http, settings, scope)
                try {
                    client.draft(2, sentinels.last()); client.connect()
                    val error = client.errorEvent()
                    val expected = if (status == 401 || status == 403) "HTTP $status: access rejected" else "HTTP $status: WebSocket upgrade failed"
                    assertTrue(error.detail.contains(expected), "status=$status; sanitized detail=${error.detail}")
                    assertNotEquals(Connection.Connected, client.state.value.connection)
                    assertFalse(client.state.value.diagnostics.any { it.summary == "Connected" })
                    assertTrue(error.detail.contains("Exception"), "Technical exception class must remain in the report")
                    assertSanitized(client.state.value.diagnostics)
                    val report = diagnosticReport(client.state.value.diagnostics)
                    assertFalse(report.contains("PRIVATE_REASON_SENTINEL")); assertFalse(report.contains("localhost"))
                    assertFalse(report.contains("X-Private-Token"))
                    val request = server.takeRequest(5, java.util.concurrent.TimeUnit.SECONDS)
                    assertNotNull(request); assertEquals("websocket", request.getHeader("Upgrade"))
                    assertTrue(request.path.orEmpty().contains("PRIVATE_URL_SENTINEL"))
                    assertEquals(sentinels.last(), settings.drafts(configured)["room:2"])
                } finally { client.disconnect(); job.cancelAndJoin(); http.close(); directory.deleteRecursively() }
            }
        } finally { server.shutdown() }
    }

    @Test fun realConnectRejectionsRemainDistinctFromWebSocketUpgradesWithoutLeakingProxyText() = runBlocking {
        val server = MockWebServer()
        server.start()
        try {
            for (status in listOf(403, 407, 502)) {
                val directory = Files.createTempDirectory("nrc-connect-status-").toFile()
                val settings = DiskSettings(directory, profile)
                val job = SupervisorJob(); val scope = CoroutineScope(coroutineContext + job)
                val http = HttpClient(OkHttp) {
                    install(WebSockets)
                    engine { config { proxySelector(object : java.net.ProxySelector() {
                        override fun select(uri: java.net.URI) = listOf(java.net.Proxy(java.net.Proxy.Type.HTTP,
                            java.net.InetSocketAddress("127.0.0.1", server.port)))
                        override fun connectFailed(uri: java.net.URI, address: java.net.SocketAddress, failure: IOException) = Unit
                    }) } }
                }
                server.enqueue(MockResponse().setStatus("HTTP/1.1 $status PRIVATE_REASON_SENTINEL")
                    .setHeader("X-Private-Token", sentinels[2]).setBody(sentinels.joinToString(" ")))
                val client = ChatClient(http, settings, scope)
                try {
                    client.connect()
                    val error = client.errorEvent()
                    assertTrue(error.detail.contains("HTTP $status:"), error.detail)
                    assertTrue(error.detail.contains("before TLS or NRC handshake"), error.detail)
                    assertFalse(error.detail.contains("WebSocket upgrade failed"))
                    assertFalse(client.state.value.diagnostics.any { it.summary == "WebSocket opened" || it.summary == "Connected" })
                    assertSanitized(client.state.value.diagnostics)
                    val report = diagnosticReport(client.state.value.diagnostics)
                    assertFalse(report.contains("PRIVATE_REASON_SENTINEL"))
                    assertFalse(report.contains("X-Private-Token"))
                    val request = server.takeRequest(5, java.util.concurrent.TimeUnit.SECONDS)
                    assertNotNull(request); assertEquals("CONNECT", request.method)
                } finally { client.disconnect(); job.cancelAndJoin(); http.close(); directory.deleteRecursively() }
            }
        } finally { server.shutdown() }
    }

    @Test fun androidOkHttpAcceptsVerifiedTlsAndAuthenticatedNrcReadyWithoutErrors() = runBlocking {
        val server = MockWebServer()
        val cert = HeldCertificate.Builder().commonName("localhost").addSubjectAlternativeName("localhost").build()
        val tls = HandshakeCertificates.Builder().addTrustedCertificate(cert.certificate).build()
        server.useHttps(HandshakeCertificates.Builder().heldCertificate(cert).build().sslSocketFactory(), false)
        val requests = Channel<Int>(Channel.UNLIMITED)
        server.enqueue(MockResponse().withWebSocketUpgrade(object : WebSocketListener() {
            override fun onOpen(webSocket: WebSocket, response: Response) {
                val ready = ByteArrayOutputStream().also { bytes -> DataOutputStream(bytes).use {
                    it.writeShort(100); it.writeUTF("fixture"); it.writeInt(9); it.writeUTF("test")
                    it.writeUTF(sentinels[1]); it.writeBoolean(true)
                } }.toByteArray()
                webSocket.send(ready.toByteString())
            }
            override fun onMessage(webSocket: WebSocket, bytes: ByteString) {
                requests.trySend(((bytes[0].toInt() and 255) shl 8) or (bytes[1].toInt() and 255))
            }
            override fun onClosing(webSocket: WebSocket, code: Int, reason: String) { webSocket.close(code, reason) }
        }))
        server.start()
        val directory = Files.createTempDirectory("nrc-okhttp-ready-").toFile()
        val configured = Profile(server.url("/").toString().removeSuffix("/"), "PRIVATE_WORKSPACE_SENTINEL")
        val settings = DiskSettings(directory, configured)
        val job = SupervisorJob(); val scope = CoroutineScope(coroutineContext + job)
        val http = HttpClient(OkHttp) {
            install(WebSockets); expectSuccess = true; followRedirects = false
            engine { config { sslSocketFactory(tls.sslSocketFactory(), tls.trustManager) } }
        }
        val client = ChatClient(http, settings, scope)
        try {
            client.connect()
            withTimeout(5_000) { client.state.first { it.diagnostics.any { event -> event.summary == "Connected" } } }
            val opcodes = withTimeout(5_000) { List(3) { requests.receive() }.toSet() }
            assertEquals(setOf(49, 17, 35), opcodes)
            assertEquals(Connection.Connected, client.state.value.connection)
            assertEquals(sentinels[1], client.state.value.username)
            assertTrue(client.state.value.diagnostics.any { it.summary == "WebSocket opened" })
            assertTrue(client.state.value.diagnostics.any { it.detail == "Authenticated NRC handshake accepted; protocol 8." })
            assertFalse(client.state.value.diagnostics.any { it.level == DiagnosticLevel.Error })
            assertSanitized(client.state.value.diagnostics)
            assertFalse(diagnosticReport(client.state.value.diagnostics).contains("localhost"))
        } finally { client.disconnect(); job.cancelAndJoin(); http.close(); server.shutdown(); requests.close(); directory.deleteRecursively() }
    }

    @Test fun boundedLogPersistsRecreatesAndClearsWithoutLosingSqliteHistoryOrDrafts() = runBlocking {
        val directory = Files.createTempDirectory("nrc-diagnostic-cache-").toFile()
        val settings = DiskSettings(directory, profile)
        var driver = JdbcSqliteDriver("jdbc:sqlite:${directory.resolve("history.db")}")
        ChatDatabase.Schema.create(driver)
        var cache = SqliteMessageStore(driver)
        val original = Message("2:1", 2, 1, sentinels[1], 1000, sentinels.last())
        cache.save(profile, CachedChat(username = sentinels[1], messages = mapOf(2L to listOf(original))))
        val http = failingHttp(IOException(sentinels.joinToString(), UnknownHostException(sentinels.first())))
        var job = SupervisorJob(); var scope = CoroutineScope(coroutineContext + job)
        var client = ChatClient(http, settings, scope, cache)
        try {
            withTimeout(5_000) { client.state.first { it.messages.isNotEmpty() } }
            client.draft(2, "PRIVATE_DRAFT_SENTINEL")
            repeat(60) {
                client.connect()
                withTimeout(5_000) { client.state.first { it.diagnostics.lastOrNull()?.summary == "Reconnect scheduled" } }
                client.disconnect()
            }
            assertEquals(200, client.state.value.diagnostics.size)
            assertEquals(200, settings.diagnostics().size)
            assertSanitized(client.state.value.diagnostics)
            assertFalse(diagnosticReport(client.state.value.diagnostics).contains("PRIVATE_DRAFT_SENTINEL"))
            val before = client.state.value.diagnostics
            client.flushCache(); job.cancelAndJoin(); driver.close()
            driver = JdbcSqliteDriver("jdbc:sqlite:${directory.resolve("history.db")}"); cache = SqliteMessageStore(driver)
            job = SupervisorJob(); scope = CoroutineScope(coroutineContext + job)
            client = ChatClient(http, DiskSettings(directory, profile), scope, cache)
            val restored = withTimeout(5_000) { client.state.first { it.messages.isNotEmpty() } }
            assertEquals(before, restored.diagnostics); assertEquals(listOf(original), restored.messages[2])
            assertEquals("PRIVATE_DRAFT_SENTINEL", restored.drafts[2])
            client.clearDiagnostics(); assertTrue(client.state.value.diagnostics.isEmpty())
            assertTrue(DiskSettings(directory, profile).diagnostics().isEmpty())
            assertEquals(listOf(original), client.state.value.messages[2]); assertEquals("PRIVATE_DRAFT_SENTINEL", client.state.value.drafts[2])
            client.flushCache(); job.cancelAndJoin()
            job = SupervisorJob(); scope = CoroutineScope(coroutineContext + job)
            client = ChatClient(http, DiskSettings(directory, profile), scope, cache)
            val afterClear = withTimeout(5_000) { client.state.first { it.messages.isNotEmpty() } }
            assertTrue(afterClear.diagnostics.isEmpty()); assertEquals(listOf(original), afterClear.messages[2])
            assertEquals("PRIVATE_DRAFT_SENTINEL", afterClear.drafts[2])
        } finally { client.disconnect(); job.cancelAndJoin(); http.close(); driver.close(); directory.deleteRecursively() }
    }
}
