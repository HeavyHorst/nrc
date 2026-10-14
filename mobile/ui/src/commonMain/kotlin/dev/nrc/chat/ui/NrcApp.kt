package dev.nrc.chat.ui

import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.text.selection.SelectionContainer
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.outlined.ArrowBack
import androidx.compose.material.icons.automirrored.outlined.Send
import androidx.compose.material.icons.outlined.Add
import androidx.compose.material.icons.outlined.Close
import androidx.compose.material.icons.outlined.MoreVert
import androidx.compose.material.icons.outlined.Search
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.drawscope.scale
import androidx.compose.ui.graphics.drawscope.translate
import androidx.compose.ui.graphics.luminance
import androidx.compose.ui.graphics.vector.PathParser
import androidx.compose.ui.platform.LocalClipboardManager
import androidx.compose.ui.text.AnnotatedString
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.KeyboardCapitalization
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import dev.nrc.chat.*
import dev.nrc.chat.Retention
import kotlinx.datetime.*

private val light = lightColorScheme(primary = Color(0xFF1D5B3B), onPrimary = Color.White,
    background = Color(0xFFFAF9F5), surface = Color(0xFFFAF9F5), onSurface = Color(0xFF18221D),
    onBackground = Color(0xFF18221D), onSurfaceVariant = Color(0xFF58645E),
    surfaceVariant = Color(0xFFF0F0EA), outline = Color(0xFFB9C2BA), outlineVariant = Color(0xFFDEE2DA),
    secondaryContainer = Color(0xFFE9EEE6), onSecondaryContainer = Color(0xFF1D5B3B))
private val dark = darkColorScheme(primary = Color(0xFF9ACBA8), onPrimary = Color(0xFF112719),
    background = Color(0xFF171D19), surface = Color(0xFF171D19), onSurface = Color(0xFFE9EDE5),
    onBackground = Color(0xFFE9EDE5), onSurfaceVariant = Color(0xFFADB9AF),
    surfaceVariant = Color(0xFF232B25), outline = Color(0xFF647567), outlineVariant = Color(0xFF344337),
    secondaryContainer = Color(0xFF253C2C), onSecondaryContainer = Color(0xFF9ACBA8))
private val square = RoundedCornerShape(4.dp)

// Exact paths and translation from logo/logo.svg; no filled stripe across the open gap.
private val nrcMarkPath = PathParser().parsePathString(
    "M24 42 88 11C95 8 100 10 100 18V43C100 47 98 49 94 51L56 73 24 58.6C13 53.65 13 47.33 24 42Z " +
    "M16 61C16 65 20 65.8 24 67.6L94 99.1C98 100.9 100 104 100 109V119C100 126 96 129 90 126L24 91C19 88 16 85 16 79Z"
).toPath()

@Composable
private fun NrcMark(modifier: Modifier) {
    val color = if (MaterialTheme.colorScheme.surface.luminance() < 0.5f) Color.White else Color.Black
    Canvas(modifier) {
        val factor = minOf(size.width / 128f, size.height / 144f)
        translate((size.width - 128f * factor) / 2f + 6f * factor, (size.height - 144f * factor) / 2f) {
            scale(factor, factor, pivot = Offset.Zero) { drawPath(nrcMarkPath, color) }
        }
    }
}

@Composable
fun NrcApp(
    state: ChatState, onSelect: (Long?) -> Unit, onDraft: (Long, String) -> Unit,
    onSend: () -> Unit, onConfigure: (Profile) -> Unit, onStartDM: (String) -> Unit,
    onOlder: (Long) -> Unit, onReconnect: () -> Unit, onDismissNotice: () -> Unit,
    darkTheme: Boolean = false,
    onClearDiagnostics: () -> Unit = {},
    platformBackHandler: @Composable (Boolean, () -> Unit) -> Unit = { _, _ -> },
) {
    var settings by rememberSaveable { mutableStateOf(state.profile.server.isBlank()) }
    var diagnostics by rememberSaveable { mutableStateOf(false) }
    var menu by remember { mutableStateOf(false) }
    var newDM by remember { mutableStateOf(false) }
    val selected = state.conversations.firstOrNull { it.id == state.selected }
    platformBackHandler(diagnostics || (settings && state.profile.server.isNotBlank()) || selected != null) {
        when {
            diagnostics -> diagnostics = false
            settings -> settings = false
            else -> onSelect(null)
        }
    }
    MaterialTheme(colorScheme = if (darkTheme) dark else light) {
        Surface(Modifier.fillMaxSize()) {
            Column(Modifier.fillMaxSize().windowInsetsPadding(WindowInsets.safeDrawing).imePadding()) {
                if (state.preview) {
                    Text("DESIGN PREVIEW · SAMPLE DATA", Modifier.fillMaxWidth().background(MaterialTheme.colorScheme.surfaceVariant)
                        .padding(horizontal = 20.dp, vertical = 7.dp), fontFamily = FontFamily.Monospace,
                        fontSize = 10.sp, color = MaterialTheme.colorScheme.onSurfaceVariant)
                }
                if (diagnostics) {
                    SystemLog(state, onClose = { diagnostics = false }, onClear = onClearDiagnostics)
                } else if (settings) {
                    Setup(state.profile, onClose = { settings = false }, canClose = state.profile.server.isNotBlank()) {
                        onConfigure(it); settings = false
                    }
                } else {
                    Row(Modifier.fillMaxWidth().heightIn(min = 88.dp).padding(start = if (selected == null) 24.dp else 8.dp, end = 8.dp),
                        verticalAlignment = Alignment.CenterVertically) {
                        if (selected != null) IconButton(onClick = { onSelect(null) }) {
                            Icon(Icons.AutoMirrored.Outlined.ArrowBack, "Back to conversations")
                        }
                        Column(Modifier.weight(1f)) {
                            if (selected == null) {
                                Row(verticalAlignment = Alignment.CenterVertically) {
                                    NrcMark(Modifier.size(24.dp, 27.dp))
                                    Spacer(Modifier.width(10.dp))
                                    Text("NRC", fontFamily = FontFamily.Monospace, fontWeight = FontWeight.Bold, fontSize = 26.sp)
                                    Text(" / ${state.profile.workspace.uppercase()}", fontFamily = FontFamily.Monospace,
                                        fontSize = 13.sp, maxLines = 1, overflow = TextOverflow.Ellipsis,
                                        color = MaterialTheme.colorScheme.onSurfaceVariant)
                                }
                            } else {
                                Text("${if (selected.direct) "@" else "#"} ${selected.name}", fontFamily = FontFamily.Monospace,
                                    fontWeight = FontWeight.Bold, fontSize = 20.sp, maxLines = 1, overflow = TextOverflow.Ellipsis)
                            }
                            Row(Modifier.padding(top = 6.dp), verticalAlignment = Alignment.CenterVertically) {
                                val memberCount = state.members[selected?.id]?.size
                                if (selected != null && memberCount != null) Meta("$memberCount online · ")
                                ConnectionLabel(state.connection)
                            }
                        }
                        Box {
                            IconButton(onClick = { menu = true }) { Icon(Icons.Outlined.MoreVert, "Connection settings and actions") }
                            DropdownMenu(expanded = menu, onDismissRequest = { menu = false }) {
                                DropdownMenuItem(text = { Text("Connection settings") }, onClick = { menu = false; settings = true })
                                DropdownMenuItem(text = { Text("Reconnect") }, onClick = { menu = false; onReconnect() })
                                DropdownMenuItem(text = { Text("System log") }, onClick = { menu = false; diagnostics = true })
                            }
                        }
                    }
                    HorizontalDivider(color = MaterialTheme.colorScheme.outlineVariant)
                    state.notice?.let { Notice(it, onDismissNotice) }
                    if (selected == null) {
                        Conversations(state, onSelect = { onSelect(it) }, onNewDM = { newDM = true })
                    } else {
                        Transcript(state, selected, onDraft, onSend, onOlder, { onStartDM(selected.name) })
                    }
                }
            }
        }
        if (newDM) NewDM(state.connection == Connection.Connected, { newDM = false }) {
            onStartDM(it); newDM = false
        }
    }
}

@Composable
private fun ColumnScope.SystemLog(state: ChatState, onClose: () -> Unit, onClear: () -> Unit) {
    val clipboard = LocalClipboardManager.current
    var copied by remember(state.diagnostics) { mutableStateOf(false) }
    Row(Modifier.fillMaxWidth().heightIn(min = 88.dp).padding(end = 20.dp), verticalAlignment = Alignment.CenterVertically) {
        IconButton(onClick = onClose) { Icon(Icons.AutoMirrored.Outlined.ArrowBack, "Back from system log") }
        Column(Modifier.weight(1f)) {
            Text("System log", fontFamily = FontFamily.Monospace, fontWeight = FontWeight.Bold, fontSize = 22.sp)
            Row(Modifier.padding(top = 6.dp)) { ConnectionLabel(state.connection) }
        }
        Meta("${state.diagnostics.size}/$MAX_DIAGNOSTIC_EVENTS")
    }
    HorizontalDivider(color = MaterialTheme.colorScheme.outlineVariant)
    Text("Recent events saved on this device. No messages, addresses, usernames or credentials are logged.",
        Modifier.padding(horizontal = 24.dp, vertical = 16.dp), fontSize = 13.sp, color = MaterialTheme.colorScheme.onSurfaceVariant)
    Row(Modifier.fillMaxWidth().padding(horizontal = 20.dp), horizontalArrangement = Arrangement.spacedBy(12.dp)) {
        OutlinedButton(onClick = { clipboard.setText(AnnotatedString(diagnosticReport(state.diagnostics))); copied = true },
            enabled = state.diagnostics.isNotEmpty(), shape = square) { Text(if (copied) "Copied" else "Copy log") }
        TextButton(onClick = { onClear(); copied = false }, enabled = state.diagnostics.isNotEmpty()) { Text("Clear log") }
    }
    if (state.diagnostics.isEmpty()) {
        Box(Modifier.weight(1f).fillMaxWidth(), contentAlignment = Alignment.Center) {
            Text("No events yet", color = MaterialTheme.colorScheme.onSurfaceVariant)
        }
    } else LazyColumn(Modifier.weight(1f), contentPadding = PaddingValues(horizontal = 24.dp, vertical = 16.dp)) {
        items(state.diagnostics.asReversed()) { event ->
            Column(Modifier.fillMaxWidth().padding(vertical = 12.dp)) {
                Meta("${Instant.fromEpochMilliseconds(event.timestampMillis).toString().replace('T', ' ').removeSuffix("Z")} UTC · ${event.level.name.uppercase()}")
                Text(event.summary, Modifier.padding(top = 6.dp), fontWeight = FontWeight.SemiBold, fontSize = 15.sp,
                    color = if (event.level == DiagnosticLevel.Error) MaterialTheme.colorScheme.error else MaterialTheme.colorScheme.onSurface)
                if (event.detail.isNotEmpty()) SelectionContainer {
                    Text(event.detail, Modifier.padding(top = 6.dp), fontFamily = FontFamily.Monospace, fontSize = 12.sp,
                        color = MaterialTheme.colorScheme.onSurfaceVariant)
                }
            }
            HorizontalDivider(color = MaterialTheme.colorScheme.outlineVariant)
        }
    }
}

@Composable
private fun ConnectionLabel(connection: Connection) {
    val colour = if (connection == Connection.Connected) MaterialTheme.colorScheme.primary else MaterialTheme.colorScheme.onSurfaceVariant
    Text("● ", color = colour, fontSize = 10.sp)
    Text(connection.name.uppercase(), color = colour, fontFamily = FontFamily.Monospace, fontSize = 11.sp,
        maxLines = 1, letterSpacing = 0.4.sp)
}

@Composable
private fun Meta(text: String, modifier: Modifier = Modifier) {
    Text(text, modifier, color = MaterialTheme.colorScheme.onSurfaceVariant, fontSize = 12.sp,
        fontFamily = FontFamily.Monospace)
}

@Composable
private fun Notice(text: String, onDismiss: (() -> Unit)? = null) {
    Row(Modifier.fillMaxWidth().background(MaterialTheme.colorScheme.surfaceVariant).padding(start = 20.dp, end = 8.dp),
        verticalAlignment = Alignment.CenterVertically) {
        Text(text, Modifier.weight(1f).padding(vertical = 12.dp), fontSize = 13.sp,
            color = MaterialTheme.colorScheme.onSurfaceVariant)
        if (onDismiss != null) IconButton(onClick = onDismiss) { Icon(Icons.Outlined.Close, "Dismiss notice", Modifier.size(18.dp)) }
    }
}

@Composable
private fun ColumnScope.Conversations(state: ChatState, onSelect: (Long) -> Unit, onNewDM: () -> Unit) {
    var search by rememberSaveable { mutableStateOf("") }
    OutlinedTextField(search, { search = it }, Modifier.fillMaxWidth().padding(horizontal = 20.dp, vertical = 20.dp),
        placeholder = { Text("Search conversations", fontSize = 15.sp) }, singleLine = true, shape = square,
        leadingIcon = { Icon(Icons.Outlined.Search, "Search", Modifier.size(20.dp)) })
    val filtered = state.conversations.filter { search.isBlank() || it.name.contains(search, ignoreCase = true) }
    LazyColumn(Modifier.weight(1f), contentPadding = PaddingValues(bottom = 24.dp)) {
        for (direct in listOf(false, true)) {
            item {
                Row(Modifier.fillMaxWidth().padding(start = 24.dp, end = 12.dp).height(48.dp), verticalAlignment = Alignment.CenterVertically) {
                    Text(if (direct) "DIRECT" else "ROOMS", Modifier.weight(1f), fontFamily = FontFamily.Monospace,
                        fontSize = 12.sp, letterSpacing = 2.sp)
                    if (direct) IconButton(onClick = onNewDM, enabled = state.connection == Connection.Connected) {
                        Icon(Icons.Outlined.Add, "Start direct message", Modifier.size(22.dp))
                    }
                }
            }
            items(filtered.filter { it.direct == direct }, key = { it.id }) { conversation ->
                val last = state.messages[conversation.id]?.lastOrNull()
                val unread = state.unread[conversation.id] ?: 0
                Row(Modifier.fillMaxWidth().clickable { onSelect(conversation.id) }.heightIn(min = 84.dp)
                    .padding(horizontal = 24.dp, vertical = 15.dp), verticalAlignment = Alignment.CenterVertically) {
                    Text(if (direct) "@" else "#", Modifier.width(40.dp), fontFamily = FontFamily.Monospace,
                        fontSize = 26.sp, color = if (unread > 0) MaterialTheme.colorScheme.primary else MaterialTheme.colorScheme.onSurfaceVariant)
                    Column(Modifier.weight(1f)) {
                        Text(conversation.name, fontWeight = FontWeight.SemiBold, fontSize = 16.sp,
                            maxLines = 1, overflow = TextOverflow.Ellipsis)
                        Text(last?.let { "${if (it.author == state.username) "You" else it.author}: ${it.text}" }
                            ?: if (direct) "Live conversation" else "Open conversation",
                            Modifier.padding(top = 5.dp), fontSize = 13.sp, color = MaterialTheme.colorScheme.onSurfaceVariant,
                            maxLines = 1, overflow = TextOverflow.Ellipsis)
                    }
                    Column(Modifier.padding(start = 10.dp), horizontalAlignment = Alignment.End) {
                        if (last != null) Meta(clockTime(last.timestampNanos))
                        if (unread > 0) Text("$unread new", Modifier.padding(top = 5.dp), fontFamily = FontFamily.Monospace,
                            color = MaterialTheme.colorScheme.primary, fontWeight = FontWeight.Bold, fontSize = 12.sp)
                    }
                }
                HorizontalDivider(Modifier.padding(horizontal = 24.dp), color = MaterialTheme.colorScheme.outlineVariant)
            }
            if (filtered.none { it.direct == direct }) item {
                Text(if (search.isNotBlank()) "No matches." else if (direct) "Start a conversation with a teammate." else "No rooms available.",
                    Modifier.padding(horizontal = 24.dp, vertical = 16.dp), fontSize = 14.sp, color = MaterialTheme.colorScheme.onSurfaceVariant)
            }
            item { Spacer(Modifier.height(20.dp)) }
        }
        item {
            Text("Saved history is available offline.\nMissed messages require server retention, in rooms and DMs.",
                Modifier.padding(horizontal = 24.dp), fontSize = 12.sp, lineHeight = 18.sp, color = MaterialTheme.colorScheme.onSurfaceVariant)
        }
    }
}

@Composable
private fun ColumnScope.Transcript(state: ChatState, conversation: Conversation, onDraft: (Long, String) -> Unit,
                                   onSend: () -> Unit, onOlder: (Long) -> Unit, onReopenDM: () -> Unit) {
    val id = conversation.id
    val markdownImages = rememberMarkdownImageLoader()
    val messages = state.messages[id].orEmpty()
    val draft = state.drafts[id].orEmpty()
    val list = rememberLazyListState()
    var lastKey by remember(id) { mutableStateOf<String?>(null) }
    LaunchedEffect(id, messages.lastOrNull()?.key) {
        val newKey = messages.lastOrNull()?.key
        val nearBottom = list.layoutInfo.visibleItemsInfo.lastOrNull()?.index?.let { it >= list.layoutInfo.totalItemsCount - 3 } ?: true
        if (newKey != lastKey && (lastKey == null || nearBottom || messages.lastOrNull()?.delivery == Delivery.Sending)) {
            if (messages.isNotEmpty()) list.scrollToItem(messages.size)
        }
        lastKey = newKey
    }
    if (state.storageBlocked) Notice("Local storage is unavailable. Draft editing is locked to protect saved data.")
    else if (state.connection != Connection.Connected) Notice("Offline. Saved messages and drafts are available on this device.")
    else if (conversation.direct && id !in state.liveDMs) {
        Notice("Saved conversation. Reopen this DM to resume chatting.")
        TextButton(onClick = onReopenDM, modifier = Modifier.fillMaxWidth()) { Text("Reopen DM") }
    } else if (state.retention[id] == Retention.Ephemeral) Notice("Saved on this device. Messages missed while offline cannot be recovered.")
    if (id in state.syncPaused) Notice("Incoming messages are waiting for history recovery. Unread counts may be incomplete.")
    LazyColumn(Modifier.weight(1f), state = list, contentPadding = PaddingValues(top = 18.dp, bottom = 16.dp)) {
        item {
            if (id in state.failedHistory) TextButton(onClick = { onOlder(id) },
                enabled = state.connection == Connection.Connected, modifier = Modifier.fillMaxWidth()) { Text("Retry message history") }
            else if (id in state.olderCursor) TextButton(onClick = { onOlder(id) }, enabled = id !in state.loadingHistory && state.connection == Connection.Connected,
                modifier = Modifier.fillMaxWidth()) { Text(if (id in state.loadingHistory) "Loading…" else "Load earlier messages") }
            else if (id in state.loadingHistory) Meta("LOADING HISTORY", Modifier.padding(horizontal = 24.dp, vertical = 12.dp))
        }
        if (messages.isEmpty()) item {
            Column(Modifier.padding(24.dp)) {
                Text("A quiet room.", fontFamily = FontFamily.Monospace, fontSize = 18.sp)
                Text("Write the first message, or wait for the conversation to begin.", Modifier.padding(top = 12.dp),
                    color = MaterialTheme.colorScheme.onSurfaceVariant, fontSize = 15.sp, lineHeight = 23.sp)
            }
        }
        items(messages, key = { it.key }) { message ->
            val previous = messages.getOrNull(messages.indexOf(message) - 1)
            if (previous == null || localDate(previous.timestampNanos) != localDate(message.timestampNanos)) {
                Row(Modifier.padding(horizontal = 24.dp, vertical = 16.dp), verticalAlignment = Alignment.CenterVertically) {
                    HorizontalDivider(Modifier.weight(1f), color = MaterialTheme.colorScheme.outlineVariant)
                    Meta(localDate(message.timestampNanos), Modifier.padding(horizontal = 12.dp))
                    HorizontalDivider(Modifier.weight(1f), color = MaterialTheme.colorScheme.outlineVariant)
                }
            }
            val own = message.author == state.username
            Column(Modifier.fillMaxWidth().padding(horizontal = 24.dp, vertical = 12.dp)) {
                Row {
                    Text(if (own) "you" else message.author, Modifier.weight(1f, fill = false).alignByBaseline(),
                        fontWeight = FontWeight.SemiBold, fontSize = 15.sp, maxLines = 1, overflow = TextOverflow.Ellipsis)
                    Meta(" · ${clockTime(message.timestampNanos)}", Modifier.padding(start = 6.dp).alignByBaseline())
                }
                SelectionContainer {
                    ChatMarkdown(message.text, markdownImages, Modifier.padding(top = 8.dp))
                }
                if (own && message.delivery != Delivery.Received && message.delivery != Delivery.Sent) Meta(when (message.delivery) {
                    Delivery.Sending -> "sending…"
                    Delivery.Unconfirmed -> "delivery unknown · check before resending"
                    Delivery.Failed -> "not sent"; else -> ""
                }, Modifier.padding(top = 7.dp))
            }
        }
    }
    HorizontalDivider(color = MaterialTheme.colorScheme.outlineVariant)
    Row(Modifier.fillMaxWidth().padding(start = 20.dp, end = 20.dp, top = 14.dp, bottom = 6.dp),
        verticalAlignment = Alignment.Bottom) {
        OutlinedTextField(draft, { onDraft(id, it) }, Modifier.weight(1f).heightIn(min = 56.dp, max = 160.dp),
            enabled = !state.storageBlocked,
            placeholder = { Text("Message ${if (conversation.direct) "@" else "#"}${conversation.name}", fontSize = 15.sp) },
            shape = square, maxLines = 5, keyboardOptions = KeyboardOptions(capitalization = KeyboardCapitalization.Sentences))
        Spacer(Modifier.width(10.dp))
        val canSend = !state.storageBlocked && state.connection == Connection.Connected && draft.isNotBlank() &&
            (!conversation.direct || id in state.liveDMs) &&
            (state.retention[id] == Retention.Enabled || state.retention[id] == Retention.Ephemeral)
        Button(onClick = onSend, enabled = canSend, modifier = Modifier.size(56.dp), shape = square,
            contentPadding = PaddingValues(0.dp)) { Icon(Icons.AutoMirrored.Outlined.Send, "Send message", Modifier.size(22.dp)) }
    }
    Meta(if (draft.isNotBlank()) "Draft saved locally" else if (state.username.isNotBlank()) "SIGNED IN · ${state.username}" else "",
        Modifier.padding(start = 22.dp, end = 20.dp, top = 3.dp, bottom = 12.dp))
}

@Composable
private fun Setup(profile: Profile, onClose: () -> Unit, canClose: Boolean, onSave: (Profile) -> Unit) {
    var server by rememberSaveable(profile) { mutableStateOf(profile.server) }
    var workspace by rememberSaveable(profile) { mutableStateOf(profile.workspace) }
    var error by remember { mutableStateOf<String?>(null) }
    LazyColumn(Modifier.fillMaxSize(), contentPadding = PaddingValues(24.dp)) {
        item {
            Row(verticalAlignment = Alignment.CenterVertically) {
                NrcMark(Modifier.size(32.dp, 36.dp))
                Spacer(Modifier.width(12.dp))
                Text("NRC", Modifier.weight(1f), fontFamily = FontFamily.Monospace, fontSize = 32.sp, fontWeight = FontWeight.Bold)
                if (canClose) IconButton(onClick = onClose) { Icon(Icons.Outlined.Close, "Close settings") }
            }
            Meta("QUIET, PRECISE, HUMAN.", Modifier.padding(top = 12.dp, bottom = 40.dp))
            Text("Connect to your workspace", fontSize = 23.sp, fontWeight = FontWeight.SemiBold)
            Text("Use your existing NRC address. Tailscale must be connected on this phone; your identity comes from the trusted NRC proxy.",
                Modifier.padding(top = 14.dp, bottom = 24.dp), fontSize = 15.sp, lineHeight = 24.sp, color = MaterialTheme.colorScheme.onSurfaceVariant)
            OutlinedTextField(server, { server = it; error = null }, Modifier.fillMaxWidth(),
                label = { Text("Server address") }, placeholder = { Text("https://nrc.example.ts.net") }, singleLine = true,
                shape = square, keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Uri))
            Spacer(Modifier.height(16.dp))
            OutlinedTextField(workspace, { workspace = it; error = null }, Modifier.fillMaxWidth(),
                label = { Text("Workspace") }, singleLine = true, shape = square)
            if (error != null) Text(error!!, Modifier.padding(top = 16.dp), color = MaterialTheme.colorScheme.error, fontSize = 14.sp)
            Button(onClick = {
                try { onSave(Profile(server.trim(), workspace.trim())) }
                catch (failure: Exception) { error = failure.message ?: "Could not save connection settings." }
            }, enabled = server.isNotBlank() && workspace.isNotBlank(), modifier = Modifier.fillMaxWidth().padding(top = 24.dp).height(52.dp), shape = square) {
                Text("Connect", fontFamily = FontFamily.Monospace)
            }
            HorizontalDivider(Modifier.padding(vertical = 28.dp), color = MaterialTheme.colorScheme.outlineVariant)
            Text("Chat history is saved on this device. Background push is not configured. Recovering missed room messages and DMs requires server retention.",
                fontSize = 13.sp, lineHeight = 21.sp, color = MaterialTheme.colorScheme.onSurfaceVariant)
        }
    }
}

@Composable
private fun NewDM(connected: Boolean, onClose: () -> Unit, onStart: (String) -> Unit) {
    var name by remember { mutableStateOf("") }
    AlertDialog(onDismissRequest = onClose, shape = square,
        title = { Text("Direct message", fontFamily = FontFamily.Monospace) },
        text = { OutlinedTextField(name, { name = it }, label = { Text("Exact NRC username") }, singleLine = true, shape = square) },
        confirmButton = { TextButton(onClick = { onStart(name) }, enabled = connected && name.isNotBlank()) { Text("Start") } },
        dismissButton = { TextButton(onClick = onClose) { Text("Cancel") } })
}

private fun localTime(nanos: Long) = Instant.fromEpochSeconds(nanos / 1_000_000_000, nanos % 1_000_000_000)
    .toLocalDateTime(TimeZone.currentSystemDefault())
private fun clockTime(nanos: Long): String = localTime(nanos).let { "${it.hour.toString().padStart(2, '0')}:${it.minute.toString().padStart(2, '0')}" }
private fun localDate(nanos: Long): String = localTime(nanos).date.toString()
