package dev.nrc.chat.ui

import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.width
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.toPixelMap
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.semantics.SemanticsProperties
import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.unit.Density
import androidx.compose.ui.unit.dp
import dev.nrc.chat.*
import dev.nrc.chat.Retention
import io.ktor.client.HttpClient
import io.ktor.client.plugins.defaultRequest
import io.ktor.client.request.get
import kotlinx.coroutines.runBlocking
import io.ktor.utils.io.ByteReadChannel
import okhttp3.mockwebserver.MockResponse
import okhttp3.mockwebserver.MockWebServer
import okhttp3.tls.HandshakeCertificates
import okhttp3.tls.HeldCertificate
import okio.Buffer
import org.junit.Rule
import org.junit.Test
import java.awt.image.BufferedImage
import java.io.ByteArrayOutputStream
import java.nio.file.Files
import java.security.KeyStore
import java.util.concurrent.TimeUnit
import javax.imageio.ImageIO
import kotlin.test.*

/** NrcApp plus its real TLS image loader; no injected production parser or transport. */
class AttachmentUiTest {
    @get:Rule val compose = createComposeRule()
    private var state by mutableStateOf(ChatState())
    private val id = "att_0123456789abcdef0123456789abcdef"
    private val filename = "Bäume + draft #1.png"
    private val draft = "Unsent draft stays editable"
    private var pending by mutableStateOf<AttachmentUpload?>(null)
    private var confirm by mutableStateOf(false)
    private var preparing by mutableStateOf(false)
    private var actionError by mutableStateOf<String?>(null)
    private val picks = mutableListOf<Boolean>()
    private val opened = mutableListOf<ChatAttachment>()
    private val saved = mutableListOf<ChatAttachment>()
    private var confirmed = 0
    private var dismissed = 0
    private var cancelled = 0

    private fun envelope(size: Long = 80, url: String = "/files/$id?filename=B%C3%A4ume+%2B+draft+%231.png") =
        """{"type":"attachment","version":1,"fileId":"$id","filename":"$filename","size":$size,"mimeType":"image/png","url":"$url"}"""

    private fun snapshot(origin: String, payload: String = envelope()) = ChatState(
        profile = Profile(origin, "studio_north"), username = "alice", selected = 2,
        connection = Connection.Connected, drafts = mapOf(2L to draft),
        messages = mapOf(2L to listOf(Message("attachment", 2, author = "peer", timestampNanos = 1, text = payload))))

    private fun show(initial: ChatState, fileActions: Boolean = false, http: HttpClient? = null) {
        state = initial
        compose.setContent {
            Box(Modifier.width(320.dp).height(720.dp)) {
                NrcApp(state, {}, { room, value -> state = state.copy(drafts = state.drafts + (room to value)) },
                    {}, {}, {}, {}, {}, {},
                    onPickAttachment = if (fileActions) ({ image -> picks.add(image) }) else null,
                    onOpenAttachment = if (fileActions) ({ file -> opened.add(file) }) else null,
                    onSaveAttachment = if (fileActions) ({ file -> saved.add(file) }) else null,
                    onCancelFileTransfer = { cancelled++; state = state.copy(fileTransfer = null) },
                    pendingAttachment = pending, canConfirmAttachment = confirm,
                    onSendAttachment = { confirmed++; pending = null },
                    onDismissAttachment = { dismissed++; pending = null },
                    preparingAttachment = preparing, fileActionError = actionError,
                    onDismissFileError = { actionError = null }, attachmentHttp = http)
            }
        }
    }
    private fun change(value: ChatState) = compose.runOnIdle { state = value }
    private fun waitText(value: String) = compose.waitUntil(15_000) {
        compose.onAllNodesWithText(value).fetchSemanticsNodes().isNotEmpty()
    }
    private fun decoded() {
        compose.waitUntil(15_000) {
            compose.onAllNodesWithText("Loading image…").fetchSemanticsNodes().isEmpty() &&
                compose.onAllNodesWithText("Image unavailable · Retry").fetchSemanticsNodes().isEmpty() &&
                compose.onAllNodesWithContentDescription(filename).fetchSemanticsNodes().isNotEmpty()
        }
        compose.onNodeWithContentDescription(filename).assertIsDisplayed()
    }
    private fun pixels() {
        val p = compose.onNodeWithContentDescription(filename).captureToImage().toPixelMap()
        val colors = listOf(p[p.width / 4, p.height / 4], p[3 * p.width / 4, 3 * p.height / 4])
        assertTrue(colors.any { it.green > .5f && it.red < .3f && it.blue < .3f })
        assertTrue(colors.any { it.red > .5f && it.green < .3f && it.blue < .3f })
    }
    private fun png(): ByteArray = ByteArrayOutputStream().also {
        val image = BufferedImage(2, 2, BufferedImage.TYPE_INT_RGB)
        image.setRGB(0, 0, 0x00ff00); image.setRGB(1, 1, 0xff0000)
        check(ImageIO.write(image, "png", it))
    }.toByteArray()
    private fun image(bytes: ByteArray = png()) = MockResponse().setHeader("Content-Type", "image/png").setBody(Buffer().write(bytes))
    private fun request(server: MockWebServer, workspace: String = "studio_north") {
        val r = assertNotNull(server.takeRequest(5, TimeUnit.SECONDS))
        val url = assertNotNull(r.requestUrl)
        assertEquals("GET", r.method)
        assertEquals("/files/$id", url.encodedPath)
        assertEquals(setOf("workspace", "inline", "filename"), url.queryParameterNames)
        assertEquals(workspace, url.queryParameter("workspace"))
        assertEquals("true", url.queryParameter("inline")); assertEquals(filename, url.queryParameter("filename"))
        assertNull(r.getHeader("Authorization")); assertNull(r.getHeader("Cookie"))
    }

    private fun tls(block: (MockWebServer, String) -> Unit) {
        val directory = Files.createTempDirectory("nrc-attachment-trust-").toFile()
        val certificate = HeldCertificate.Builder().commonName("localhost").addSubjectAlternativeName("localhost").build()
        val trust = KeyStore.getInstance("PKCS12").apply { load(null, null); setCertificateEntry("fixture", certificate.certificate) }
        val file = directory.resolve("trust.p12")
        file.outputStream().use { trust.store(it, "fixture".toCharArray()) }
        val properties = mapOf("javax.net.ssl.trustStore" to file.absolutePath,
            "javax.net.ssl.trustStoreType" to "PKCS12", "javax.net.ssl.trustStorePassword" to "fixture")
        val previous = properties.keys.associateWith { System.getProperty(it) }
        properties.forEach { (key, value) -> System.setProperty(key, value) }
        val server = MockWebServer()
        server.useHttps(HandshakeCertificates.Builder().heldCertificate(certificate).build().sslSocketFactory(), false)
        server.start()
        try { block(server, server.url("/").toString().removeSuffix("/")) }
        finally {
            change(state.copy(messages = emptyMap())); compose.waitForIdle(); server.shutdown()
            previous.forEach { (key, value) -> if (value == null) System.clearProperty(key) else System.setProperty(key, value) }
            directory.deleteRecursively()
        }
    }

    @Test fun attachmentsBorrowChatTransportButExternalMarkdownNeverDoes() = tls { server, origin ->
        val http = HttpClient {
            followRedirects = false
            defaultRequest { headers.append("X-NRC-Test-Transport", "chat") }
        }
        try {
            server.enqueue(image()); show(snapshot(origin), http = http); decoded(); pixels()
            assertEquals("chat", assertNotNull(server.takeRequest(5, TimeUnit.SECONDS)).getHeader("X-NRC-Test-Transport"))
            change(snapshot(origin, "![Pixel]($origin/external.png)"))
            compose.onNodeWithText("Load image · Pixel").assertExists()
            server.enqueue(image()); compose.onNodeWithText("Load image · Pixel").performClick()
            compose.waitUntil(15_000) {
                compose.onAllNodesWithText("Loading image…").fetchSemanticsNodes().isEmpty() &&
                    compose.onAllNodesWithText("Image unavailable · Retry").fetchSemanticsNodes().isEmpty() &&
                    compose.onAllNodesWithContentDescription("Pixel").fetchSemanticsNodes().isNotEmpty()
            }
            val external = assertNotNull(server.takeRequest(5, TimeUnit.SECONDS))
            assertEquals("/external.png", external.path)
            assertNull(external.getHeader("X-NRC-Test-Transport"))
            // Disposing the image loaders must not close the borrowed chat client.
            change(state.copy(selected = null)); compose.waitForIdle()
            server.enqueue(MockResponse().setBody("still open"))
            assertEquals(200, runBlocking { http.get("$origin/probe").status.value })
        } finally { http.close() }
    }

    @Test fun ownServerEnvelopeAutomaticallyDecodesRetriesAndEnlargesWithoutLosingDraft() = tls { server, origin ->
        server.enqueue(MockResponse().setResponseCode(503))
        show(snapshot(origin))
        waitText("Image unavailable · Retry"); assertEquals(1, server.requestCount); request(server)
        compose.onNodeWithText("Load image", substring = true).assertDoesNotExist()
        server.enqueue(image())
        compose.onNodeWithText("Image unavailable · Retry").performClick()
        decoded(); pixels(); assertEquals(2, server.requestCount); request(server)
        compose.onNodeWithContentDescription(filename).performClick()
        compose.onNodeWithText("Close image").assertIsDisplayed()
        compose.onNodeWithContentDescription("Expanded image · $filename").assertIsDisplayed()
        compose.onNodeWithText("Close image").performClick()
        compose.onNodeWithContentDescription("Expanded image · $filename").assertDoesNotExist()
        compose.onNode(hasSetTextAction()).assertTextEquals(draft)
        assertEquals(draft, state.drafts[2]); assertEquals(2, server.requestCount)
    }

    @Test fun invalidUntrustedOrUnavailableAttachmentsNeverRequestAndConnectedControlDoes() = tls { server, origin ->
        val valid = snapshot(origin)
        show(valid.copy(connection = Connection.Disconnected))
        val blocked = listOf(
            valid.copy(connection = Connection.Disconnected), valid.copy(connection = Connection.Reconnecting),
            valid.copy(storageBlocked = true), valid.copy(username = ""),
            snapshot(origin, envelope(size = 8L * 1024 * 1024 + 1)),
            snapshot(origin, envelope(url = "$origin/files/$id?filename=B%C3%A4ume+%2B+draft+%231.png")),
            snapshot(origin, envelope().replace(id, "att_../../outside")),
            valid.copy(profile = valid.profile.copy(server = origin.replace("https:", "http:")))
        )
        for (fixture in blocked) {
            change(fixture); compose.waitForIdle()
            assertNull(server.takeRequest(500, TimeUnit.MILLISECONDS), "Unavailable/invalid attachment must not fetch")
            compose.onNodeWithContentDescription(filename).assertDoesNotExist()
        }
        server.enqueue(image()); change(valid); decoded(); pixels(); request(server)
        assertEquals(1, server.requestCount)
    }

    @Test fun identityAndProfileSwitchesDoNotReuseAnotherIdentityImageCache() = tls { server, origin ->
        server.enqueue(image()); show(snapshot(origin)); decoded(); request(server)
        server.enqueue(image()); change(state.copy(username = "bob"))
        compose.waitUntil(15_000) { server.requestCount == 2 }; decoded(); request(server)
        server.enqueue(image()); change(state.copy(profile = state.profile.copy(workspace = "other-workspace")))
        compose.waitUntil(15_000) { server.requestCount == 3 }; decoded(); request(server, "other-workspace")
        compose.onNode(hasSetTextAction()).assertTextEquals(draft)
    }

    @Test fun validEightMiBImageDecodesButOversizeAndRedirectCannotBypassTransportLimit() = tls { server, origin ->
        val atLimit = ByteArray(8 * 1024 * 1024).also { png().copyInto(it) }
        server.enqueue(image(atLimit)); show(snapshot(origin, envelope(size = atLimit.size.toLong())))
        decoded(); pixels(); request(server)
        server.enqueue(MockResponse().setResponseCode(302).setHeader("Location", "$origin/never-fetch.png"))
        // Changing identity must create a fresh loader even for the same download URL.
        change(snapshot(origin).copy(username = "redirect-user")); waitText("Image unavailable · Retry"); request(server)
        val large = atLimit.copyOf(atLimit.size + 1)
        server.enqueue(image(large)); change(state.copy(username = "declared-user"))
        waitText("Image unavailable · Retry"); request(server)
        server.enqueue(MockResponse().setHeader("Content-Type", "image/png").setChunkedBody(Buffer().write(large), 8192))
        change(state.copy(username = "chunked-user")); waitText("Image unavailable · Retry"); request(server)
        assertEquals(4, server.requestCount)
        assertNull(server.takeRequest(300, TimeUnit.MILLISECONDS), "Redirect target must not be requested")
    }

    @Test fun filePickerChoicesNeedExplicitConfirmationAndCancellationNeverSends() {
        show(snapshot("https://chat.invalid", "Ordinary message").copy(retention = mapOf(2L to Retention.Enabled)), fileActions = true)
        compose.onNodeWithContentDescription("Attach photo or file").assertIsEnabled().performClick()
        compose.onNodeWithText("Photo or image").performClick()
        compose.onNodeWithContentDescription("Attach photo or file").performClick()
        compose.onNodeWithText("File").performClick()
        assertEquals(listOf(true, false), picks); assertEquals(0, confirmed)
        var readers = 0
        val staged = AttachmentUpload("Plan #2.pdf", "application/pdf", 4096) { readers++; ByteReadChannel(byteArrayOf(1)) }
        compose.runOnIdle { pending = staged }
        compose.onNodeWithText("To #engineering").assertExists()
        val send = compose.onNode(hasText("Send") and hasClickAction())
        send.assertIsNotEnabled(); assertEquals(0, readers); assertEquals(0, confirmed)
        compose.onNodeWithText("Cancel").performClick()
        assertEquals(1, dismissed); assertEquals(0, confirmed)
        compose.runOnIdle { pending = staged; confirm = true }
        send.assertIsEnabled().performClick()
        assertEquals(1, confirmed); assertEquals(0, readers)
        compose.onNode(hasSetTextAction()).assertTextEquals(draft)
    }

    @OptIn(ExperimentalTestApi::class)
    @Test fun largeFontShortImageConfirmationKeepsActionsAndScrollsDetails() = runDesktopComposeUiTest(width = 320, height = 450) {
        val directory = Files.createTempDirectory("nrc-selected-preview-").toFile()
        val localImage = directory.resolve("selected.png").apply { writeBytes(png()) }
        var staged by mutableStateOf<AttachmentUpload?>(AttachmentUpload("selected-sample.png", "image/png", localImage.length()) { ByteReadChannel(png()) })
        var sent = 0
        var cancelled = 0
        val dm = "long-destination-".repeat(15)
        val chat = snapshot("https://chat.invalid", "Ordinary message").copy(
            conversations = listOf(Conversation(2, dm, direct = true)), liveDMs = setOf(2),
            retention = mapOf(2L to Retention.Enabled))
        try {
            setContent {
                CompositionLocalProvider(LocalDensity provides Density(1f, 2f)) {
                    NrcApp(chat, {}, { _, _ -> }, {}, {}, {}, {}, {}, {}, pendingAttachment = staged,
                        attachmentPreview = localImage, canConfirmAttachment = true,
                        onSendAttachment = { sent++; staged = null }, onDismissAttachment = { cancelled++; staged = null })
                }
            }
            val dialog = onNode(isDialog()).getUnclippedBoundsInRoot()
            for (label in listOf("Send", "Cancel")) {
                val button = onNode((hasText(label) or hasText("$label attachment")) and hasClickAction()).assertIsDisplayed().assertIsEnabled()
                val bounds = button.getUnclippedBoundsInRoot()
                assertTrue(bounds.left >= dialog.left && bounds.right <= dialog.right && bounds.top >= dialog.top && bounds.bottom <= dialog.bottom,
                    "$label must fit entirely within dialog: $bounds vs $dialog")
                assertTrue(bounds.left >= 0.dp && bounds.right <= 320.dp && bounds.top >= 0.dp && bounds.bottom <= 450.dp,
                    "$label must fit entirely within viewport: $bounds")
            }
            onNodeWithText("To @$dm").assertExists()
            onNodeWithContentDescription("Selected image").performScrollTo().assertIsDisplayed()
            onNodeWithContentDescription("Selected image").captureToImage().toPixelMap().let { pixels ->
                assertTrue((0 until pixels.width).any { x -> pixels[x, pixels.height / 4].let { it.green > .8f && it.red < .2f && it.blue < .2f } }, "Decoded local PNG must be visible")
            }
            onNode(hasText("Cancel") and hasClickAction()).performClick()
            assertEquals(1, cancelled); assertEquals(0, sent)
            onNode(hasSetTextAction()).assertTextEquals(draft)
            runOnIdle { staged = AttachmentUpload("selected-sample.png", "image/png", localImage.length()) { ByteReadChannel(png()) } }
            onNode(hasText("Send") and hasClickAction()).performClick()
            assertEquals(1, sent); assertEquals(1, cancelled)
            onNode(hasSetTextAction()).assertTextEquals(draft)
        } finally { runOnIdle { staged = null }; waitForIdle(); directory.deleteRecursively() }
    }

    @Test fun nativeFileActionsProgressErrorsAndOfflineBusyGatesPreserveDraft() {
        val attachment = ChatAttachment(id, "Plan #2.pdf", 4096, "application/pdf")
        val valid = snapshot("https://chat.invalid", attachment.messageText()).copy(retention = mapOf(2L to Retention.Ephemeral))
        show(valid, fileActions = true)
        compose.onNodeWithText("Open").assertIsEnabled().performClick()
        compose.onNodeWithText("Save").assertIsEnabled().performClick()
        assertEquals(listOf(attachment), opened); assertEquals(listOf(attachment), saved)
        for (blocked in listOf(valid.copy(connection = Connection.Disconnected), valid.copy(storageBlocked = true),
            valid.copy(fileTransfer = FileTransfer("Plan #2.pdf", true, 2048, 4096)))) {
            change(blocked)
            compose.onNodeWithContentDescription("Attach photo or file").assertIsNotEnabled()
            compose.onNodeWithText("Open").assertIsNotEnabled(); compose.onNodeWithText("Save").assertIsNotEnabled()
        }
        compose.onNodeWithText("Uploading · Plan #2.pdf").assertExists()
        val progress = compose.onNode(SemanticsMatcher.keyIsDefined(SemanticsProperties.ProgressBarRangeInfo))
            .fetchSemanticsNode().config[SemanticsProperties.ProgressBarRangeInfo]
        assertEquals(.5f, progress.current)
        compose.onNodeWithText("Cancel transfer").performClick(); assertEquals(1, cancelled)
        compose.onNodeWithText("Cancel transfer").assertDoesNotExist()
        change(valid.copy(retention = mapOf(2L to Retention.Unknown)))
        compose.onNodeWithContentDescription("Attach photo or file").assertIsNotEnabled()
        change(valid); compose.runOnIdle { preparing = true }
        compose.onNodeWithText("Preparing file on this device…").assertExists()
        compose.onNodeWithContentDescription("Attach photo or file").assertIsNotEnabled()
        compose.onNodeWithText("Open").assertIsNotEnabled(); compose.onNodeWithText("Save").assertIsNotEnabled()
        compose.runOnIdle { preparing = false; actionError = "Sample storage failure" }
        compose.onNodeWithText("File error").assertExists()
        compose.onNodeWithText("Sample storage failure").assertExists()
        compose.onNodeWithText("OK").performClick()
        compose.onNodeWithText("File error").assertDoesNotExist()
        compose.onNode(hasSetTextAction()).assertTextEquals(draft)
    }
}
