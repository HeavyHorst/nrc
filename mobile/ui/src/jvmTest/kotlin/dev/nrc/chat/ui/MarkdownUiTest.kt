package dev.nrc.chat.ui

import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.width
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.compositeOver
import androidx.compose.ui.graphics.luminance
import androidx.compose.ui.graphics.toPixelMap
import androidx.compose.ui.platform.ClipboardManager
import androidx.compose.ui.platform.LocalClipboardManager
import androidx.compose.ui.platform.LocalUriHandler
import androidx.compose.ui.platform.UriHandler
import androidx.compose.ui.semantics.SemanticsActions
import androidx.compose.ui.semantics.SemanticsProperties
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.getOrNull
import androidx.compose.ui.state.ToggleableState
import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.text.AnnotatedString
import androidx.compose.ui.text.TextLayoutResult
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextDecoration
import androidx.compose.ui.unit.dp
import dev.nrc.chat.*
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

/** Public NrcApp rendering/actions; no calls to renderer or network implementation helpers. */
class MarkdownUiTest {
    @get:Rule val compose = createComposeRule()
    private var copied: AnnotatedString? = null
    private val opened = mutableListOf<String>()
    private lateinit var replace: (String) -> Unit
    private lateinit var replaceTheme: (Boolean) -> Unit
    private var reconnects = 0

    private fun show(source: String) {
        var markdown by mutableStateOf(source)
        var dark by mutableStateOf(false)
        replace = { markdown = it }
        replaceTheme = { dark = it }
        val clipboard = object : ClipboardManager {
            override fun setText(annotatedString: AnnotatedString) { copied = annotatedString }
            override fun getText() = copied
        }
        val uri = object : UriHandler { override fun openUri(uri: String) { opened += uri } }
        compose.setContent {
            CompositionLocalProvider(LocalClipboardManager provides clipboard, LocalUriHandler provides uri) {
                Box(Modifier.width(320.dp)) {
                    NrcApp(ChatState(profile = Profile("https://chat.invalid", "studio"), username = "rene", selected = 2,
                        connection = Connection.Connected, messages = mapOf(2L to listOf(
                            Message("markdown", 2, author = "maya", timestampNanos = 1000, text = markdown)))),
                        {}, { _, _ -> }, {}, {}, {}, {}, { reconnects++ }, {}, darkTheme = dark)
                }
            }
        }
    }

    // GFM cells retain syntax padding; compare content, not invisible leading/trailing spaces.
    private fun text(value: String) = compose.onNode(SemanticsMatcher("Rendered text is '$value'") { node ->
        node.config.getOrNull(SemanticsProperties.Text)?.any { it.text.trim() == value } == true
    }, useUnmergedTree = true)
    private fun layout(node: SemanticsNodeInteraction): TextLayoutResult {
        val results = mutableListOf<TextLayoutResult>()
        node.performSemanticsAction(SemanticsActions.GetTextLayoutResult) { it(results) }
        return results.single()
    }
    private fun layout(value: String) = layout(text(value))
    private fun change(source: String) = compose.runOnIdle { replace(source) }
    private val horizontal = SemanticsMatcher.keyIsDefined(SemanticsProperties.HorizontalScrollAxisRange)

    @Test fun inlineEmphasisProducesNativeStylesAndHtmlRemainsLiteral() {
        show("**Bold** *Italic* ~~Strike~~ `inline`")
        val result = layout(compose.onNodeWithText("Bold", substring = true, useUnmergedTree = true))
        val annotated = result.layoutInput.text
        fun styles(word: String) = annotated.spanStyles.filter {
            it.start <= annotated.text.indexOf(word) && it.end >= annotated.text.indexOf(word) + word.length
        }.map { it.item }
        assertTrue(styles("Bold").any { it.fontWeight == FontWeight.Bold })
        assertTrue(styles("Italic").any { it.fontStyle == FontStyle.Italic })
        assertTrue(styles("Strike").any { it.textDecoration?.contains(TextDecoration.LineThrough) == true })
        assertTrue(styles("inline").any { it.fontFamily == FontFamily.Monospace })
        change("<script>window.location='https://not-executed.invalid'</script>")
        text("<script>window.location='https://not-executed.invalid'</script>").assertExists()
        change("Literal <b>not bold</b> and <img src=\"https://not-requested.invalid/p.png\">.")
        text("Literal <b>not bold</b> and <img src=\"https://not-requested.invalid/p.png\">.").assertExists()
        compose.onNodeWithText("Load image", substring = true).assertDoesNotExist()
        assertTrue(opened.isEmpty())
        for ((source, expected) in listOf(
            "Tom & Jerry" to "Tom & Jerry",
            "&amp; / &#x1F680;" to "& / 🚀",
            "`&amp; & <tag>`" to "&amp; & <tag>",
            "\\*literal\\* and \\[brackets\\] and \\~tilde\\~" to "*literal* and [brackets] and ~tilde~"
        )) {
            change(source)
            text(expected).assertExists()
        }
    }

    @Test fun inlineCodeNormalizesNewlinesButPreservesLiteralEntitiesAndBackslashes() {
        show("`a\nb &amp; \\*x\\*`")
        text("a b &amp; \\*x\\*").assertExists()
        assertEquals(1, layout("a b &amp; \\*x\\*").lineCount)
        change("| Code |\n|---|\n| `a\\|b` |")
        text("a|b").assertExists()
    }

    @Test fun headingsQuotesNestedListsAndCaseInsensitiveReadOnlyTasksRender() {
        show("## Heading\n\nParagraph\n\n> Quoted text\n\n- Outer item\n  - Inner item\n\n- [X] Upper done\n- [x] Lower done\n- [ ] Still open")
        assertTrue(layout("Heading").layoutInput.style.fontSize > layout("Paragraph").layoutInput.style.fontSize)
        text("Quoted text").assertExists()
        assertTrue(text("Inner item").fetchSemanticsNode().boundsInRoot.left > text("Outer item").fetchSemanticsNode().boundsInRoot.left)
        text("Upper done").assertExists(); text("Lower done").assertExists(); text("Still open").assertExists()
        val checks = compose.onAllNodes(SemanticsMatcher.keyIsDefined(SemanticsProperties.ToggleableState), useUnmergedTree = true)
        checks.assertCountEquals(3)
        assertEquals(listOf(ToggleableState.On, ToggleableState.On, ToggleableState.Off),
            checks.fetchSemanticsNodes().map { it.config[SemanticsProperties.ToggleableState] })
        checks.fetchSemanticsNodes().forEach {
            assertEquals(Role.Checkbox, it.config[SemanticsProperties.Role])
            assertFalse(it.config.contains(SemanticsActions.OnClick))
        }
        change("3. Third\n   7. Seventh\n   8. Eighth\n4. Fourth\n\nNew list follows.\n\n7. Restarted")
        val numbers = compose.onAllNodes(SemanticsMatcher("Ordered list number") {
            it.config.getOrNull(SemanticsProperties.Text)?.any { text -> text.text.trim().matches(Regex("[0-9]+\\.")) } == true
        }, useUnmergedTree = true).fetchSemanticsNodes().sortedBy { it.boundsInRoot.top }
        assertEquals(listOf("3.", "7.", "8.", "4.", "7."),
            numbers.map { it.config[SemanticsProperties.Text].single().text.trim() })
        assertTrue(text("Seventh").fetchSemanticsNode().boundsInRoot.left > text("Third").fetchSemanticsNode().boundsInRoot.left)
    }

    @Test fun safeInlineReferenceAndBareLinksOpenButUnsafeSchemesAndCredentialsDoNot() {
        show("[Secure](https://example.test/safe)")
        val allowed = listOf(
            "[Secure](https://example.test/safe)" to ("Secure" to "https://example.test/safe"),
            "[https://shown.test](https://actual.test)" to ("https://shown.test" to "https://actual.test"),
            "[Plain](http://example.test/plain)" to ("Plain" to "http://example.test/plain"),
            "[Mail](mailto:team@example.test)" to ("Mail" to "mailto:team@example.test"),
            "[Reference][docs]\n\n[DOCS]: https://example.test/docs" to ("Reference" to "https://example.test/docs"),
            "[Docs][]\n\n[docs]: https://example.test/collapsed" to ("Docs" to "https://example.test/collapsed"),
            "[Docs]\n\n[DOCS]: https://example.test/shortcut" to ("Docs" to "https://example.test/shortcut"),
            "[Query](https://example.test/search?a=1&amp;b=2)" to ("Query" to "https://example.test/search?a=1&b=2"),
            "www.example.test" to ("www.example.test" to "https://www.example.test"),
            "<team@example.test>" to ("team@example.test" to "mailto:team@example.test"),
            "team@example.test" to ("team@example.test" to "mailto:team@example.test"),
            "https://example.test/bare" to ("https://example.test/bare" to "https://example.test/bare")
        )
        for ((source, labelAndUrl) in allowed) {
            change(source)
            text(labelAndUrl.first).performTouchInput { advanceEventTime(600); click(center) }
            assertEquals(labelAndUrl.second, opened.lastOrNull())
        }
        val before = opened.toList()
        for (url in listOf("javascript:evil", "file:///tmp/private", "content://settings/system", "intent://activity/", "https://alice:token@example.test/p", "https://example.test\\evil", "//example.test/p")) {
            change("[Blocked]($url)")
            text("Blocked").performTouchInput { click(center) }
            compose.onNodeWithText("This link cannot be opened safely.").assertExists()
            assertEquals(before, opened)
        }
    }

    @Test fun gfmTableWrapsAlignsUnescapesPipesAndScrollsHorizontally() {
        show("| Left | Middle | Right |\n| :--- | :---: | ---: |\n| escaped \\| pipe | A long middle cell wraps across several words | 97 |")
        text("escaped | pipe").assertExists()
        assertEquals(TextAlign.Start, layout("Left").layoutInput.style.textAlign)
        assertEquals(TextAlign.Center, layout("Middle").layoutInput.style.textAlign)
        assertEquals(TextAlign.End, layout("Right").layoutInput.style.textAlign)
        assertTrue(layout("A long middle cell wraps across several words").lineCount >= 2)
        val scroll = compose.onNode(horizontal)
        val before = scroll.fetchSemanticsNode().config[SemanticsProperties.HorizontalScrollAxisRange].value()
        scroll.performSemanticsAction(SemanticsActions.ScrollBy) { it(200f, 0f) }
        compose.waitForIdle()
        assertTrue(scroll.fetchSemanticsNode().config[SemanticsProperties.HorizontalScrollAxisRange].value() > before)
    }

    @Test fun fencedCodeCopiesIntentionalIndentationBlankLinesAndQuoteSyntaxIsNotCopied() {
        val expected = "    val n = 3\n\n        println(n)"
        show("```kotlin\n$expected\n```")
        val syntaxColors = layout(expected.trim()).layoutInput.text.spanStyles.map { it.item.color }
            .filter { it != Color.Unspecified }.distinct()
        assertTrue(syntaxColors.size > 1, "Kotlin tokens receive distinct highlighting colors")
        val cases = listOf(
            "```kotlin\n$expected\n```",
            "> ```kotlin\n>     val n = 3\n>\n>         println(n)\n> ```",
            "> > ```kotlin\n> >     val n = 3\n> >\n> >         println(n)\n> > ```"
        )
        for ((source, output) in cases.map { it to expected } + listOf(
            "```kotlin\n\n    val n = 3\n\n        println(n)\n```" to "\n    val n = 3\n\n        println(n)",
            "```kotlin\r\n\r\n    val n = 3\r\n\r\n```" to "\r\n    val n = 3\r\n"
        )) {
            change(source)
            compose.onNodeWithText("Copy code").performClick()
            compose.onNodeWithText("Copied").assertExists()
            assertEquals(output, copied?.text)
        }
        val wide = "val message = \"${"wide ".repeat(30)}end\""
        change("```kotlin\n$wide\n```")
        val scroll = compose.onNode(horizontal)
        val before = scroll.fetchSemanticsNode().config[SemanticsProperties.HorizontalScrollAxisRange].value()
        scroll.performSemanticsAction(SemanticsActions.ScrollBy) { it(250f, 0f) }
        compose.waitForIdle()
        assertTrue(scroll.fetchSemanticsNode().config[SemanticsProperties.HorizontalScrollAxisRange].value() > before)
        compose.onNodeWithText("Copy code").performClick()
        assertEquals(wide, copied?.text?.trimEnd('\n'))

        val colorful = "@Deprecated(\"sample\")\nval enabled = true\n// comment\nval n = 3"
        val tokens = listOf("@Deprecated", "\"sample\"", "val", "true", "// comment", "=", "3")
        fun palette(): Pair<Color, Map<String, Color>> {
            val node = text(colorful)
            val input = layout(node).layoutInput
            val background = node.captureToImage().toPixelMap()[0, 0]
            val colors = tokens.associateWith { token ->
                val index = input.text.text.indexOf(token)
                assertTrue(index >= 0)
                input.text.spanStyles.filter { index in it.start until it.end && it.item.color != Color.Unspecified }
                    .lastOrNull()?.item?.color ?: input.style.color
            } + ("base" to input.style.color)
            assertTrue(colors.values.none { it == Color.Unspecified })
            return background to colors
        }
        change("```kotlin\n$colorful\n```")
        val lightColors = palette().second
        compose.runOnIdle { replaceTheme(true) }
        val (background, darkColors) = palette()
        val contrasts = darkColors.mapValues { (_, foreground) ->
            val a = foreground.compositeOver(background).luminance().toDouble()
            val b = background.luminance().toDouble()
            (maxOf(a, b) + 0.05) / (minOf(a, b) + 0.05)
        }
        // Fresh content is a control for theme changes being lost by a remembered highlighter.
        change("```kotlin\n$colorful\n\n```")
        val freshDarkColors = palette().second
        assertEquals(freshDarkColors, darkColors, "Switching theme must recolor existing code as well as fresh code")
        assertTrue(contrasts.values.all { it >= 4.5 }, "Dark rendered token/base contrast ratios: $contrasts")
        assertNotEquals(lightColors.getValue("\"sample\""), darkColors.getValue("\"sample\""))
        compose.runOnIdle { replaceTheme(false) }
        assertEquals(lightColors, palette().second, "Switching back restores light syntax colors")
    }

    @Test fun nestedIndentedCodeCopiesWithoutQuotePrefixesOrSyntaxIndentation() {
        show("> >     val n = 3\n> >\n> >         println(n)")
        compose.onNodeWithText("Copy code").performClick()
        assertEquals("val n = 3\n\n    println(n)", copied?.text?.removeSuffix("\n"))
    }

    @Test fun protocolMaximumDeepQuotesFallBackToExactTextAndAppRemainsResponsive() {
        val original = "> ".repeat(25599) + "xx"
        assertEquals(51200, original.toByteArray().size)
        show(original)
        compose.onNodeWithText("plain text", substring = true, ignoreCase = true).assertExists()
        compose.onNodeWithText(original, useUnmergedTree = true).assertExists()
        compose.runOnIdle { replaceTheme(true) }
        compose.onNodeWithText(original, useUnmergedTree = true).assertExists()
        compose.onNodeWithContentDescription("Connection settings and actions").performClick()
        compose.onNodeWithText("Reconnect").performClick()
        compose.runOnIdle { assertEquals(1, reconnects) }
        change("**Recovered**")
        text("Recovered").assertExists()
        compose.onNodeWithText("plain text", substring = true, ignoreCase = true).assertDoesNotExist()
    }

    /** Test-only JVM trust store; production client, verification and host-name checking stay intact. */
    private fun tls(block: (MockWebServer, String) -> Unit) {
        val directory = Files.createTempDirectory("nrc-image-trust-").toFile()
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
            compose.runOnIdle { replace("Image fixture finished") }
            compose.waitForIdle(); server.shutdown()
            previous.forEach { (key, value) -> if (value == null) System.clearProperty(key) else System.setProperty(key, value) }
            directory.deleteRecursively()
        }
    }
    private fun png(): ByteArray = ByteArrayOutputStream().also {
        val image = BufferedImage(2, 2, BufferedImage.TYPE_INT_RGB)
        image.setRGB(0, 0, 0x00ff00); image.setRGB(1, 1, 0xff0000)
        check(ImageIO.write(image, "png", it))
    }.toByteArray()
    private fun waitText(value: String) = compose.waitUntil(15_000) {
        compose.onAllNodesWithText(value).fetchSemanticsNodes().isNotEmpty()
    }
    private fun waitDecoded(alt: String) {
        compose.waitUntil(15_000) {
            compose.onAllNodesWithText("Loading image…").fetchSemanticsNodes().isEmpty() &&
                compose.onAllNodesWithText("Image unavailable · Retry").fetchSemanticsNodes().isEmpty() &&
                compose.onAllNodesWithContentDescription(alt).fetchSemanticsNodes().isNotEmpty()
        }
        compose.onNodeWithContentDescription(alt).assertIsDisplayed()
    }

    @Test fun referenceImageRequiresConsentRetriesAndDecodesWithoutCredentialHeaders() = tls { server, origin ->
        show("Before ![Pixel][PIC] after.\n\n[pic]: $origin/pixel.png?a=1&amp;b=2")
        text("Before [Image: Pixel] after.").assertExists()
        compose.onNodeWithText("Load image · Pixel").assertExists()
        compose.waitForIdle(); assertEquals(0, server.requestCount)
        server.enqueue(MockResponse().setResponseCode(503))
        compose.onNodeWithText("Load image · Pixel").performClick()
        waitText("Image unavailable · Retry")
        assertEquals(1, server.requestCount)
        server.enqueue(MockResponse().setHeader("Content-Type", "image/png").setBody(Buffer().write(png())))
        compose.onNodeWithText("Image unavailable · Retry").performClick()
        waitDecoded("Pixel"); assertEquals(2, server.requestCount)
        val pixels = compose.onNodeWithContentDescription("Pixel").captureToImage().toPixelMap()
        val colors = listOf(pixels[pixels.width / 4, pixels.height / 4], pixels[3 * pixels.width / 4, 3 * pixels.height / 4])
        assertTrue(colors.any { it.green > 0.5f && it.red < 0.3f && it.blue < 0.3f }, "Decoded green PNG pixel")
        assertTrue(colors.any { it.red > 0.5f && it.green < 0.3f && it.blue < 0.3f }, "Decoded red PNG pixel")
        repeat(2) {
            val request = server.takeRequest(5, TimeUnit.SECONDS)
            assertNotNull(request); assertEquals("/pixel.png?a=1&b=2", request.path)
            assertNull(request.getHeader("Authorization")); assertNull(request.getHeader("Cookie"))
        }
    }

    @Test fun imageRedirectAndOversizedChunkedResponseFailWithoutFetchingRedirectTarget() = tls { server, origin ->
        show("![At limit]($origin/limit.png)")
        // A valid PNG with trailing padding decodes at exactly the encoded-byte limit.
        // This positive control prevents a broken decoder from masquerading as limit enforcement.
        val atLimit = ByteArray(8 * 1024 * 1024)
        png().copyInto(atLimit)
        server.enqueue(MockResponse().setHeader("Content-Type", "image/png").setBody(Buffer().write(atLimit)))
        compose.onNodeWithText("Load image · At limit").performClick()
        waitDecoded("At limit"); assertEquals(1, server.requestCount)
        change("![Redirect]($origin/redirect.png)")
        server.enqueue(MockResponse().setResponseCode(302).setHeader("Location", "$origin/never-fetch.png"))
        compose.onNodeWithText("Load image · Redirect").performClick()
        waitText("Image unavailable · Retry"); assertEquals(2, server.requestCount)
        change("![Large]($origin/large.png)")
        val oversized = ByteArray(8 * 1024 * 1024 + 1)
        png().copyInto(oversized)
        server.enqueue(MockResponse().setHeader("Content-Type", "image/png").setChunkedBody(Buffer().write(oversized), 8192))
        compose.onNodeWithText("Load image · Large").performClick()
        waitText("Image unavailable · Retry"); assertEquals(3, server.requestCount)
        change("![Declared large]($origin/declared-large.png)")
        server.enqueue(MockResponse().setHeader("Content-Type", "image/png").setBody(Buffer().write(oversized)))
        compose.onNodeWithText("Load image · Declared large").performClick()
        waitText("Image unavailable · Retry"); assertEquals(4, server.requestCount)
        assertEquals("/limit.png", server.takeRequest(5, TimeUnit.SECONDS)?.path)
        assertEquals("/redirect.png", server.takeRequest(5, TimeUnit.SECONDS)?.path)
        assertEquals("/large.png", server.takeRequest(5, TimeUnit.SECONDS)?.path)
        assertEquals("/declared-large.png", server.takeRequest(5, TimeUnit.SECONDS)?.path)
        change("![Blocked](http://not-requested.invalid/p.png)")
        text("[Image unavailable: Blocked]").assertExists()
        compose.onNodeWithText("Load image", substring = true).assertDoesNotExist()
        assertEquals(4, server.requestCount)
    }
}
