package dev.nrc.chat.ui

import androidx.compose.foundation.background
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.text.selection.DisableSelection
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.luminance
import androidx.compose.ui.platform.LocalClipboardManager
import androidx.compose.ui.platform.LocalUriHandler
import androidx.compose.ui.platform.UriHandler
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.role
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.semantics.toggleableState
import androidx.compose.ui.text.*
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextDecoration
import androidx.compose.ui.state.ToggleableState
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import coil3.ImageLoader
import coil3.annotation.ExperimentalCoilApi
import coil3.compose.AsyncImage
import coil3.compose.LocalPlatformContext
import coil3.memory.MemoryCache
import coil3.network.*
import coil3.request.ImageRequest
import coil3.size.Size
import com.mikepenz.markdown.annotator.annotatorSettings
import com.mikepenz.markdown.annotator.buildMarkdownAnnotatedString
import com.mikepenz.markdown.annotator.DefaultAnnotatorSettings
import com.mikepenz.markdown.compose.*
import com.mikepenz.markdown.compose.components.MarkdownComponentModel
import com.mikepenz.markdown.compose.components.MarkdownComponents
import com.mikepenz.markdown.compose.components.markdownComponents
import com.mikepenz.markdown.compose.elements.MarkdownHighlightedCode
import com.mikepenz.markdown.m3.markdownColor
import com.mikepenz.markdown.m3.markdownTypography
import com.mikepenz.markdown.model.*
import dev.snipme.highlights.Highlights
import dev.snipme.highlights.model.SyntaxThemes
import io.ktor.client.HttpClient
import io.ktor.client.plugins.HttpTimeout
import io.ktor.client.request.prepareGet
import io.ktor.client.statement.bodyAsChannel
import io.ktor.http.Url
import io.ktor.utils.io.readAvailable
import okio.Buffer
import org.intellij.markdown.MarkdownElementTypes
import org.intellij.markdown.MarkdownTokenTypes
import org.intellij.markdown.ast.ASTNode
import org.intellij.markdown.ast.findChildOfType
import org.intellij.markdown.ast.getTextInNode
import org.intellij.markdown.flavours.gfm.GFMElementTypes
import org.intellij.markdown.flavours.gfm.GFMFlavourDescriptor
import org.intellij.markdown.flavours.gfm.GFMTokenTypes
import org.intellij.markdown.html.entities.Entities
import org.intellij.markdown.lexer.Compat.codePointToString
import org.intellij.markdown.parser.MarkdownParser

/** One credential-free image client for the screen, never the authenticated chat transport. */
@OptIn(ExperimentalCoilApi::class)
@Composable
internal fun rememberMarkdownImageLoader(): ImageLoader {
    val context = LocalPlatformContext.current
    val http = remember { HttpClient {
        followRedirects = false
        // Check status ourselves before reading any body, including huge proxy error pages.
        expectSuccess = false
        install(HttpTimeout) { requestTimeoutMillis = 15_000; socketTimeoutMillis = 15_000 }
    } }
    val loader = remember(context, http) { ImageLoader.Builder(context)
        .components { add(NetworkFetcher.Factory(networkClient = { MarkdownImageClient(http) })) }
        .memoryCache { MemoryCache.Builder().maxSizeBytes(16L * 1024 * 1024).weakReferencesEnabled(false).build() }
        .diskCache(null)
        .build() }
    DisposableEffect(loader) { onDispose { loader.shutdown(); http.close() } }
    return loader
}

private fun allowedLink(value: String, image: Boolean = false): Boolean {
    val schemes = if (image) setOf("https") else setOf("https", "http", "mailto")
    val scheme = value.substringBefore(':').lowercase()
    if (scheme !in schemes ||
        value.any { it.isWhitespace() || it.code < 32 || it.code == 127 || it == '\\' }) return false
    // Ktor treats the recipient before @ as Url.user; that is not embedded HTTP credentials.
    if (scheme == "mailto") return value.substringAfter(':').substringBefore('?').let { '@' in it && !it.startsWith("//") }
    if (!value.startsWith("$scheme://", ignoreCase = true) ||
        value.substringAfter("://").substringBefore('/').substringBefore('?').substringBefore('#').isBlank()) return false
    val url = runCatching { Url(value) }.getOrNull() ?: return false
    return url.protocol.name in schemes &&
        url.user == null && url.password == null && url.host.isNotBlank()
}

/** Stream into a bounded buffer, including responses without a Content-Length. No redirects/cookies/auth. */
private class MarkdownImageClient(private val http: HttpClient) : NetworkClient {
    override suspend fun <T> executeRequest(request: NetworkRequest, block: suspend (NetworkResponse) -> T): T {
        require(allowedLink(request.url, image = true)) { "Only credential-free HTTPS images are supported" }
        return http.prepareGet(request.url).execute { response ->
            check(response.status.value == 200) { "Image request was not successful" }
            check((response.headers["Content-Length"]?.toLongOrNull() ?: 0L) <= 8 * 1024 * 1024) { "Image exceeds 8 MiB" }
            val channel = response.bodyAsChannel()
            val bytes = Buffer()
            val chunk = ByteArray(8192)
            while (true) {
                val count = channel.readAvailable(chunk)
                if (count < 0) break
                check(bytes.size + count <= 8 * 1024 * 1024) { "Image exceeds 8 MiB" }
                bytes.write(chunk, 0, count)
            }
            val headers = NetworkHeaders.Builder()
            response.headers.entries().forEach { (name, values) -> headers[name] = values }
            val body = NetworkResponseBody(bytes)
            try { block(NetworkResponse(code = 200, headers = headers.build(), body = body)) }
            finally { body.close() }
        }
    }
}

@Composable
internal fun ChatMarkdown(content: String, imageLoader: ImageLoader, modifier: Modifier = Modifier) {
    val scheme = MaterialTheme.colorScheme
    val body = TextStyle(color = scheme.onSurface, fontSize = 16.sp, lineHeight = 25.sp)
    // This release's top-level renderer reparses on every recomposition. Own the document AST so
    // delivery updates, image retries and theme changes reuse the parse without altering the source.
    val document = remember(content) {
        // Must run before the parser: repeated quote prefixes cause quadratic constraint allocation.
        if (excessiveQuotePrefix(content)) return@remember null
        val tree = MarkdownParser(GFMFlavourDescriptor()).buildMarkdownTreeFromString(content)
        val nodes = mutableListOf<ASTNode>()
        val pending = ArrayDeque<Pair<ASTNode, Int>>()
        pending.addLast(tree to 0)
        while (pending.isNotEmpty()) {
            val (node, depth) = pending.removeLast()
            if (depth > 64 || nodes.size >= 4096) return@remember null
            nodes += node
            node.children.asReversed().forEach { pending.addLast(it to depth + 1) }
        }
        tree to nodes
    }
    if (document == null) {
        Column(modifier.fillMaxWidth()) {
            Text("Complex Markdown shown as plain text.", color = scheme.onSurfaceVariant, fontSize = 12.sp)
            Text(content, style = body)
        }
        return
    }
    val (tree, nodes) = document
    val references = remember(tree) { object : ReferenceLinkHandler {
        val links = mutableMapOf<String, String>()
        fun normalized(label: String) = label.removeSurrounding("[", "]").trim().replace(Regex("\\s+"), " ").lowercase()
        override fun store(label: String, destination: String?) {
            if (destination != null && normalized(label) !in links) links[normalized(label)] = destination
        }
        override fun find(label: String) = links[normalized(label)] ?: label
    }.apply {
        nodes.filter { it.type == MarkdownElementTypes.LINK_DEFINITION }.forEach { definition ->
            val label = definition.findChildOfType(MarkdownElementTypes.LINK_LABEL)?.getTextInNode(content)?.toString()?.markdownText()
            val target = definition.findChildOfType(MarkdownElementTypes.LINK_DESTINATION)?.getTextInNode(content)?.toString()?.markdownText()
            if (label != null) store(label, target?.removeSurrounding("<", ">"))
        }
    } }
    val uriHandler = LocalUriHandler.current
    var linkProblem by remember(content) { mutableStateOf(false) }
    val safeHandler = remember(uriHandler, content) { object : UriHandler {
        override fun openUri(uri: String) {
            linkProblem = !allowedLink(uri) || runCatching { uriHandler.openUri(uri) }.isFailure
        }
    } }
    // Image nodes become descriptive labels in the text, with individually consented previews below.
    // No image, DNS lookup or tracking request happens merely by scrolling through chat history.
    val images = remember(tree) { nodes.filter { it.type == MarkdownElementTypes.IMAGE }.associate { node ->
        val direct = node.descendant(MarkdownElementTypes.LINK_DESTINATION)?.getTextInNode(content)?.toString()?.markdownText()
        val label = node.descendant(MarkdownElementTypes.LINK_LABEL)?.getTextInNode(content)?.toString()?.markdownText()
            ?.takeUnless { it.removeSurrounding("[", "]").isBlank() }
            ?: node.descendant(MarkdownElementTypes.LINK_TEXT)?.getTextInNode(content)?.toString()?.markdownText().orEmpty()
        val target = direct?.removeSurrounding("<", ">") ?: references.find(label)
        val alt = (node.descendant(MarkdownElementTypes.LINK_TEXT) ?: node.descendant(MarkdownElementTypes.LINK_LABEL))
            ?.getTextInNode(content)?.toString()?.markdownText()
            ?.removeSurrounding("[", "]").orEmpty().ifBlank { "Image" }
        node.startOffset to (target to alt)
    } }
    var requested by remember(content) { mutableStateOf(setOf<String>()) }
    val linkStyle = TextLinkStyles(SpanStyle(color = scheme.primary, textDecoration = TextDecoration.Underline))
    val linkListener = LinkInteractionListener { link -> (link as? LinkAnnotation.Url)?.let { safeHandler.openUri(it.url) } }
    lateinit var annotator: MarkdownAnnotator
    annotator = markdownAnnotator { source, node ->
        when (node.type) {
            MarkdownTokenTypes.TEXT -> {
                val text = node.getTextInNode(source).toString().markdownText()
                if (generateSequence(node.parent) { it.parent }.any {
                    it.type == MarkdownElementTypes.LINK_TEXT || it.type == MarkdownElementTypes.LINK_LABEL
                }) append(text)
                else {
                    var offset = 0
                    for (email in markdownEmails.findAll(text)) {
                        append(text.substring(offset, email.range.first))
                        withLink(LinkAnnotation.Url("mailto:${email.value}", linkStyle, linkListener)) { append(email.value) }
                        offset = email.range.last + 1
                    }
                    append(text.substring(offset))
                }
                true
            }
            MarkdownElementTypes.CODE_SPAN -> {
                var code = source.substring(node.children.first().endOffset, node.children.last().startOffset)
                    .replace("\r\n", " ").replace('\n', ' ').replace('\r', ' ')
                if (code.startsWith(' ') && code.endsWith(' ') && code.any { it != ' ' }) code = code.drop(1).dropLast(1)
                if (generateSequence(node.parent) { it.parent }.any { it.type == GFMElementTypes.TABLE }) code = code.replace("\\|", "|")
                withStyle(SpanStyle(fontFamily = FontFamily.Monospace, fontSize = 14.sp, background = scheme.surfaceVariant)) { append(code) }
                true
            }
            MarkdownElementTypes.INLINE_LINK, MarkdownElementTypes.FULL_REFERENCE_LINK, MarkdownElementTypes.SHORT_REFERENCE_LINK -> {
                val label = node.findChildOfType(MarkdownElementTypes.LINK_TEXT) ?: node.findChildOfType(MarkdownElementTypes.LINK_LABEL)
                val direct = node.findChildOfType(MarkdownElementTypes.LINK_DESTINATION)?.getTextInNode(source)?.toString()
                    ?.markdownText()?.removeSurrounding("<", ">")
                val reference = node.findChildOfType(MarkdownElementTypes.LINK_LABEL)?.getTextInNode(source)?.toString()?.markdownText()
                    ?.takeUnless { it.removeSurrounding("[", "]").isBlank() }
                    ?: label?.getTextInNode(source)?.toString()?.markdownText().orEmpty()
                val target = direct ?: references.find(reference).takeIf { it != reference }
                if (label == null || target == null) append(node.getTextInNode(source).toString().markdownText())
                else withLink(LinkAnnotation.Url(target, linkStyle, linkListener)) {
                    buildMarkdownAnnotatedString(source, label.children.drop(1).dropLast(1),
                        DefaultAnnotatorSettings(linkStyle, SpanStyle(fontFamily = FontFamily.Monospace,
                            background = scheme.surfaceVariant, fontSize = 14.sp), annotator, references, linkListener, true))
                }
                true
            }
            MarkdownElementTypes.AUTOLINK, GFMTokenTypes.GFM_AUTOLINK, MarkdownTokenTypes.EMAIL_AUTOLINK -> {
                val text = node.getTextInNode(source).toString().removeSurrounding("<", ">").markdownText()
                val target = when {
                    text.startsWith("www.", ignoreCase = true) -> "https://$text"
                    ':' !in text && '@' in text -> "mailto:$text"
                    else -> text
                }
                if (generateSequence(node.parent) { it.parent }.any {
                    it.type == MarkdownElementTypes.LINK_TEXT || it.type == MarkdownElementTypes.LINK_LABEL
                }) append(text)
                else withLink(LinkAnnotation.Url(target, linkStyle, linkListener)) { append(text) }
                true
            }
            MarkdownTokenTypes.LT, MarkdownTokenTypes.GT -> {
                val siblings = node.parent?.children.orEmpty()
                val index = siblings.indexOf(node)
                if (siblings.getOrNull(index - 1)?.type == MarkdownTokenTypes.EMAIL_AUTOLINK ||
                    siblings.getOrNull(index + 1)?.type == MarkdownTokenTypes.EMAIL_AUTOLINK) true
                else { append(node.getTextInNode(source).toString()); true }
            }
            MarkdownElementTypes.IMAGE -> {
                val (target, alt) = images.getValue(node.startOffset)
                append(if (allowedLink(target, image = true)) "[Image: $alt]" else "[Image unavailable: $alt]")
                true
            }
            MarkdownTokenTypes.HTML_TAG -> { append(node.getTextInNode(source).toString()); true }
            else -> false
        }
    }
    val components = markdownComponents(
        text = { Text(it.node.getTextInNode(it.content).toString().markdownText(), style = it.typography.text) },
        paragraph = { model ->
            val settings = annotatorSettings(eolAsNewLine = true)
            Text(model.content.buildMarkdownAnnotatedString(model.node, model.typography.paragraph, settings),
                style = model.typography.paragraph)
        },
        table = { MarkdownTable(it) },
        checkbox = { model ->
            val checked = model.node.getTextInNode(model.content).contains("[x]", ignoreCase = true)
            Checkbox(checked = checked, onCheckedChange = null, modifier = Modifier.size(24.dp).padding(end = 4.dp).semantics {
                role = Role.Checkbox
                toggleableState = if (checked) ToggleableState.On else ToggleableState.Off
            })
        },
        codeFence = { model ->
            // Unlike the library's replaceIndent(), preserve intentional fence indentation when copying.
            // EOL/content tokens carry the code; WHITE_SPACE tokens carry enclosing quote/list syntax.
            val code = model.node.children.dropWhile { it.type != MarkdownTokenTypes.EOL }.drop(1)
                .takeWhile { it.type != MarkdownTokenTypes.CODE_FENCE_END }
                .filter { it.type == MarkdownTokenTypes.CODE_FENCE_CONTENT || it.type == MarkdownTokenTypes.EOL }
                .joinToString("") { it.getTextInNode(model.content).toString() }
                .let { it.removeSuffix(if (it.endsWith("\r\n")) "\r\n" else "\n") }
            val language = model.node.findChildOfType(MarkdownTokenTypes.FENCE_LANG)?.getTextInNode(model.content)?.toString()
            MarkdownCode(code, language, model.typography.code)
        },
        codeBlock = { model ->
            val code = model.node.children.filter { it.type == MarkdownTokenTypes.CODE_LINE || it.type == MarkdownTokenTypes.EOL }
                .joinToString("") { node ->
                    val raw = node.getTextInNode(model.content).toString()
                    if (node.type != MarkdownTokenTypes.CODE_LINE) raw else {
                        var columns = 0
                        var offset = 0
                        while (offset < raw.length && columns < 4) {
                            when (raw[offset]) {
                                ' ' -> columns++
                                '\t' -> columns += 4 - columns % 4
                                else -> break
                            }
                            offset++
                        }
                        raw.drop(offset)
                    }
                }.let { it.removeSuffix(if (it.endsWith("\r\n")) "\r\n" else "\n") }
            MarkdownCode(code, null, model.typography.code)
        },
        custom = { type, model -> if (type == MarkdownElementTypes.HTML_BLOCK) {
            Text(model.node.getTextInNode(model.content).toString(), style = body)
        } },
    )
    val colors = markdownColor(text = scheme.onSurface, codeText = scheme.onSurface, codeBackground = scheme.surfaceVariant,
                    inlineCodeBackground = scheme.surfaceVariant, dividerColor = scheme.outlineVariant,
                    tableBackground = scheme.surfaceVariant)
    val typography = markdownTypography(text = body, paragraph = body, bullet = body, ordered = body, list = body,
                    quote = body.copy(color = scheme.onSurfaceVariant), table = body,
                    code = body.copy(fontFamily = FontFamily.Monospace, fontSize = 14.sp, lineHeight = 22.sp),
                    inlineCode = body.copy(fontFamily = FontFamily.Monospace, fontSize = 14.sp),
                    link = body.copy(color = scheme.primary, textDecoration = TextDecoration.Underline),
                    h1 = body.copy(fontSize = 26.sp, lineHeight = 33.sp, fontWeight = FontWeight.Bold),
                    h2 = body.copy(fontSize = 23.sp, lineHeight = 30.sp, fontWeight = FontWeight.Bold),
                    h3 = body.copy(fontSize = 20.sp, lineHeight = 27.sp, fontWeight = FontWeight.Bold),
                    h4 = body.copy(fontSize = 18.sp, fontWeight = FontWeight.Bold),
                    h5 = body.copy(fontWeight = FontWeight.Bold), h6 = body.copy(fontWeight = FontWeight.Bold))
    val orderedStarts = mutableMapOf<Int, Int>()
    CompositionLocalProvider(LocalUriHandler provides safeHandler, LocalReferenceLinkHandler provides references,
        LocalOrderedListHandler provides BulletHandler { _, bullet, index, depth ->
            if (index == 0) orderedStarts[depth] = bullet?.toString()?.trim()?.trimEnd('.', ')')?.toIntOrNull() ?: 1
            "${(orderedStarts[depth] ?: 1) + index}. "
        },
        LocalMarkdownColors provides colors, LocalMarkdownTypography provides typography,
        LocalMarkdownPadding provides markdownPadding(block = 4.dp, list = 2.dp, listItemTop = 2.dp, listItemBottom = 2.dp),
        LocalMarkdownDimens provides markdownDimens(), LocalMarkdownAnnotator provides annotator,
        LocalMarkdownComponents provides components, LocalMarkdownAnimations provides markdownAnimations(),
        LocalImageTransformer provides NoOpImageTransformerImpl()) {
        Column(modifier.fillMaxWidth()) {
            tree.children.forEach { node -> MarkdownNode(MarkdownComponentModel(content, node, typography), components) }
            if (linkProblem) Text("This link cannot be opened safely.", color = scheme.onSurfaceVariant, fontSize = 12.sp)
            images.values.distinctBy { it.first }.filter { allowedLink(it.first, image = true) }.forEach { (url, alt) ->
                MarkdownImage(url, alt, url in requested, imageLoader) { requested = requested + url }
            }
        }
    }
}

private fun ASTNode.descendant(type: org.intellij.markdown.IElementType): ASTNode? =
    if (this.type == type) this else children.firstNotNullOfOrNull { it.descendant(type) }

// Native Text must decode Markdown entities/escapes, not HTML-escape them like the library helper.
private val markdownEscapes = Regex("\\\\([\\p{Punct}])|&(?:#([0-9]{1,7})|#[xX]([0-9a-fA-F]{1,6})|([a-zA-Z][a-zA-Z0-9]*));")
private fun String.markdownText(): String = markdownEscapes.replace(this) { match ->
    if (match.groupValues[1].isNotEmpty()) match.groupValues[1]
    else {
        val code = match.groupValues[2].toIntOrNull() ?: match.groupValues[3].toIntOrNull(16) ?: Entities.map[match.value]
        if (code == null) match.value
        else codePointToString(if (code == 0 || code in 0xD800..0xDFFF || code > 0x10FFFF) 0xFFFD else code)
    }
}

private val markdownEmails = Regex("(?<![\\w@.])[A-Za-z0-9._%+-]+@[A-Za-z0-9](?:[A-Za-z0-9.-]*[A-Za-z0-9])?\\.[A-Za-z]{2,}(?![\\w@-])")

/** Conservative source preflight, also applied to code examples. Never invoke the parser on it. */
private fun excessiveQuotePrefix(content: String): Boolean {
    for (line in content.lineSequence()) {
        var offset = 0
        var quotes = 0
        while (offset < line.length) {
            while (offset < line.length && (line[offset] == ' ' || line[offset] == '\t')) offset++
            if (offset == line.length) break
            if (line[offset] == '>') {
                if (++quotes > 16) return true
                offset++
                continue
            }
            // Quote blocks may begin in a list item, including after nested list indentation.
            var markerEnd = offset
            if (line[offset] in "-+*") markerEnd++
            else {
                while (markerEnd < line.length && markerEnd - offset < 9 && line[markerEnd] in '0'..'9') markerEnd++
                if (markerEnd > offset && markerEnd < line.length && line[markerEnd] in ".)") markerEnd++
                else markerEnd = offset
            }
            if (markerEnd > offset && markerEnd < line.length && (line[markerEnd] == ' ' || line[markerEnd] == '\t')) offset = markerEnd + 1
            else break
        }
    }
    return false
}

/** Use the library's native block components over our memoized GFM document. */
@Composable
private fun ColumnScope.MarkdownNode(model: MarkdownComponentModel, components: MarkdownComponents) {
    val component: com.mikepenz.markdown.compose.components.MarkdownComponent? = when (model.node.type) {
        MarkdownTokenTypes.TEXT -> components.text
        MarkdownElementTypes.PARAGRAPH -> components.paragraph
        MarkdownElementTypes.ATX_1 -> components.heading1
        MarkdownElementTypes.ATX_2 -> components.heading2
        MarkdownElementTypes.ATX_3 -> components.heading3
        MarkdownElementTypes.ATX_4 -> components.heading4
        MarkdownElementTypes.ATX_5 -> components.heading5
        MarkdownElementTypes.ATX_6 -> components.heading6
        MarkdownElementTypes.SETEXT_1 -> components.setextHeading1
        MarkdownElementTypes.SETEXT_2 -> components.setextHeading2
        MarkdownElementTypes.BLOCK_QUOTE -> components.blockQuote
        MarkdownElementTypes.ORDERED_LIST -> components.orderedList
        MarkdownElementTypes.UNORDERED_LIST -> components.unorderedList
        MarkdownElementTypes.CODE_FENCE -> components.codeFence
        MarkdownElementTypes.CODE_BLOCK -> components.codeBlock
        GFMElementTypes.TABLE -> components.table
        MarkdownTokenTypes.HORIZONTAL_RULE -> components.horizontalRule
        MarkdownElementTypes.LINK_DEFINITION, MarkdownTokenTypes.EOL -> null
        else -> components.custom?.let { custom -> { current -> custom(current.node.type, current) } }
    }
    if (component != null) {
        Spacer(Modifier.height(4.dp))
        component(model)
    }
}

@Composable
private fun MarkdownTable(model: MarkdownComponentModel) {
    val header = model.node.findChildOfType(GFMElementTypes.HEADER) ?: return
    val rows = listOf(header) + model.node.children.filter { it.type == GFMElementTypes.ROW }
    val cells = rows.map { row -> row.children.filter { it.type == GFMTokenTypes.CELL } }
    val count = cells.first().size
    val separators = model.node.findChildOfType(GFMTokenTypes.TABLE_SEPARATOR)?.getTextInNode(model.content)
        ?.toString()?.trim()?.removePrefix("|")?.removeSuffix("|")?.split('|').orEmpty()
    val settings = annotatorSettings(eolAsNewLine = true)
    val widths = (0 until count).map { column ->
        if (cells.any { row -> row.getOrNull(column)?.getTextInNode(model.content)?.length?.let { it > 24 } == true }) 220.dp else 120.dp
    }
    Column(Modifier.fillMaxWidth().padding(vertical = 6.dp)) {
        Text("TABLE · swipe horizontally", fontSize = 10.sp, color = MaterialTheme.colorScheme.onSurfaceVariant)
        Column(Modifier.horizontalScroll(rememberScrollState()).padding(top = 6.dp)
            .background(MaterialTheme.colorScheme.surfaceVariant)) {
            cells.forEachIndexed { index, row ->
                Row {
                    repeat(count) { column ->
                        val delimiter = separators.getOrNull(column)?.trim().orEmpty()
                        val alignment = when {
                            delimiter.startsWith(':') && delimiter.endsWith(':') -> TextAlign.Center
                            delimiter.endsWith(':') -> TextAlign.End
                            else -> TextAlign.Start
                        }
                        val style = model.typography.table.copy(textAlign = alignment,
                            fontWeight = if (index == 0) FontWeight.SemiBold else FontWeight.Normal)
                        val text = row.getOrNull(column)?.let { model.content.buildMarkdownAnnotatedString(it, style, settings) }
                            ?: AnnotatedString("")
                        Text(text, Modifier.width(widths[column]).padding(horizontal = 12.dp, vertical = 10.dp), style = style)
                    }
                }
                HorizontalDivider(Modifier.width(widths.fold(0.dp) { total, width -> total + width }),
                    color = MaterialTheme.colorScheme.outlineVariant)
            }
        }
    }
}

@Composable
private fun MarkdownCode(code: String, language: String?, style: TextStyle) {
    val clipboard = LocalClipboardManager.current
    var copied by remember(code) { mutableStateOf(false) }
    val dark = MaterialTheme.colorScheme.surface.luminance() < 0.5f
    // The bundled Darcula strings/comments are too dim on our forest-dark surface.
    val syntax = SyntaxThemes.default(darkMode = dark).let { theme ->
        if (!dark) theme else theme.copy(
            keyword = 0xFFB86C, string = 0xB5CEA8, literal = 0x9CDCFE,
            comment = 0xA7B0A8, multilineComment = 0xA7B0A8, metadata = 0xDCDCAA,
            punctuation = 0xD8E3D9, mark = 0xD8E3D9,
        )
    }
    Column(Modifier.fillMaxWidth().padding(vertical = 6.dp).background(MaterialTheme.colorScheme.surfaceVariant)) {
        DisableSelection {
            Row(Modifier.fillMaxWidth().padding(start = 12.dp), horizontalArrangement = Arrangement.SpaceBetween) {
                Text(language?.substringBefore(' ')?.ifBlank { null } ?: "Code", Modifier.padding(top = 13.dp),
                    fontFamily = FontFamily.Monospace, fontSize = 12.sp, color = MaterialTheme.colorScheme.onSurfaceVariant)
                TextButton(onClick = { clipboard.setText(AnnotatedString(code)); copied = true }) { Text(if (copied) "Copied" else "Copy code") }
            }
        }
        // Upstream remembers the highlighter by code alone, so recreate it on theme/language changes.
        key(dark, language) {
            MarkdownHighlightedCode(code = code, language = language?.substringBefore(' '), style = style,
                highlights = Highlights.Builder(theme = syntax))
        }
    }
}

@Composable
private fun MarkdownImage(url: String, alt: String, requested: Boolean, loader: ImageLoader, onLoad: () -> Unit) {
    val context = LocalPlatformContext.current
    var attempt by remember(url) { mutableStateOf(0) }
    var failed by remember(url, attempt) { mutableStateOf(false) }
    var loading by remember(url, attempt) { mutableStateOf(true) }
    val request = remember(context, url, attempt) { ImageRequest.Builder(context).data(url)
        .size(Size(1024, 1024)).memoryCacheKey("$url:$attempt").build() }
    Column(Modifier.fillMaxWidth().padding(top = 8.dp)) {
        DisableSelection {
            if (!requested) TextButton(onClick = onLoad) { Text("Load image · $alt") }
            else if (failed) TextButton(onClick = { attempt++ }) { Text("Image unavailable · Retry") }
            else if (loading) Text("Loading image…", fontSize = 12.sp, color = MaterialTheme.colorScheme.onSurfaceVariant)
        }
        if (requested && !failed) AsyncImage(model = request, imageLoader = loader, contentDescription = alt,
            modifier = Modifier.fillMaxWidth().heightIn(max = 280.dp),
            onSuccess = { loading = false }, onError = { failed = true; loading = false })
        if (!requested) Text("External HTTPS content; loading shares your IP with its host.",
            fontSize = 11.sp, lineHeight = 16.sp, color = MaterialTheme.colorScheme.onSurfaceVariant)
    }
}
