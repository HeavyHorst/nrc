package dev.nrc.chat.ui

import androidx.compose.runtime.*
import androidx.compose.ui.platform.ClipboardManager
import androidx.compose.ui.platform.LocalClipboardManager
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.platform.LocalUriHandler
import androidx.compose.ui.platform.UriHandler
import androidx.compose.ui.semantics.SemanticsActions
import androidx.compose.ui.text.AnnotatedString
import androidx.compose.ui.text.TextRange
import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.unit.Density
import androidx.compose.ui.unit.dp
import dev.nrc.chat.*
import dev.nrc.chat.Retention
import org.junit.Rule
import org.junit.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertTrue

class ChatUiTest {
    @get:Rule val compose = createComposeRule()

    @OptIn(ExperimentalTestApi::class)
    @Test fun copyKeepsMarkdownAndReplyPreservesDraftUntilExplicitSend() {
        val markdown = "**Important**\nSecond line with `code`."
        var state by mutableStateOf(ChatState(profile = Profile("https://nrc.example", "studio"), selected = 2,
            username = "rene", connection = Connection.Connected, retention = mapOf(2L to Retention.Enabled),
            drafts = mapOf(2L to "Existing draft"), messages = mapOf(2L to listOf(
                Message("peer", 2, author = "maya", timestampNanos = 1000, text = markdown)))))
        var copied: AnnotatedString? = null
        var denied = false
        val sent = mutableListOf<String>()
        val clipboard = object : ClipboardManager {
            override fun setText(annotatedString: AnnotatedString) {
                if (denied) throw IllegalStateException("Clipboard unavailable")
                copied = annotatedString
            }
            override fun getText() = copied
        }
        compose.setContent {
            CompositionLocalProvider(LocalClipboardManager provides clipboard) {
                NrcApp(state, {}, { id, text -> state = state.copy(drafts = state.drafts + (id to text)) },
                    { sent.add(state.drafts[2].orEmpty()) }, {}, {}, {}, {}, {})
            }
        }
        fun openActions() = compose.onNodeWithTag("message:peer").performTouchInput { longClick() }
        fun reply() { openActions(); compose.onNodeWithText("Reply").performClick() }
        compose.onNodeWithText("Copy Markdown").assertDoesNotExist()
        compose.onNodeWithTag("message:peer").performTouchInput { click() }
        compose.onNodeWithText("Copy Markdown").assertDoesNotExist()
        openActions()
        compose.onNodeWithText("Copy Markdown").performClick()
        assertEquals(markdown, copied?.text)
        compose.onNodeWithText("Copied Markdown").assertExists()
        denied = true
        openActions()
        compose.onNodeWithText("Copy Markdown").performClick()
        compose.onNodeWithText("Could not copy message").assertExists()
        openActions()
        compose.onNodeWithText("Select text").performClick()
        compose.onNodeWithText(markdown).assertExists()
        compose.onNodeWithText("Done").performClick()
        val expected = "> maya:\n> **Important**\n> Second line with `code`.\n\nExisting draft"
        compose.onNode(hasSetTextAction()).performTextInputSelection(TextRange(3))
        reply()
        compose.onNodeWithText("Cancel reply").performClick()
        assertEquals(TextRange("Existing draft".length),
            compose.onNode(hasSetTextAction()).fetchSemanticsNode().config[androidx.compose.ui.semantics.SemanticsProperties.TextSelectionRange])
        reply()
        compose.onNode(hasSetTextAction()).assertIsFocused().assertTextEquals(expected)
        compose.onNode(hasSetTextAction()).performTextInputSelection(TextRange(3))
        reply()
        assertEquals(TextRange(expected.length),
            compose.onNode(hasSetTextAction()).fetchSemanticsNode().config[androidx.compose.ui.semantics.SemanticsProperties.TextSelectionRange])
        compose.onNode(hasSetTextAction()).performTextInput(" + edit")
        compose.onNode(hasSetTextAction()).assertTextEquals(expected + " + edit")
        assertTrue(sent.isEmpty())
        compose.onNodeWithText("Cancel reply").performClick()
        compose.onNode(hasSetTextAction()).assertTextEquals("Existing draft + edit")
        reply()
        reply()
        compose.onNode(hasSetTextAction()).assertTextEquals(expected + " + edit") // No stacked quotes on repeated taps.
        compose.onNodeWithContentDescription("Send message").performClick()
        assertEquals(listOf(expected + " + edit"), sent)
        compose.runOnIdle { state = state.copy(storageBlocked = true) }
        openActions()
        compose.onNodeWithText("Reply").assertIsNotEnabled()
        compose.onNodeWithText("Copy Markdown").assertIsEnabled()
    }

    @OptIn(ExperimentalTestApi::class)
    @Test fun longTextSelectionKeepsDoneVisibleAtLargeFontWithoutChangingDraft() = runDesktopComposeUiTest(width = 320, height = 450) {
        val source = "**Original Markdown**\n" + "A long passage to select without editing the message.\n".repeat(25)
        val original = ChatState(profile = Profile("https://nrc.example", "studio"), selected = 2,
            drafts = mapOf(2L to "Unsent draft"), messages = mapOf(2L to listOf(
                Message("long", 2, author = "maya", timestampNanos = 1000, text = source))))
        var state by mutableStateOf(original)
        setContent {
            CompositionLocalProvider(LocalDensity provides Density(1f, 2f)) {
                NrcApp(state, {}, { id, text -> state = state.copy(drafts = state.drafts + (id to text)) },
                    {}, {}, {}, {}, {}, {})
            }
        }
        onNodeWithTag("message:long").performSemanticsAction(SemanticsActions.OnLongClick) { it() }
        onNodeWithText("Select text").performClick()
        onNodeWithText(source).assertExists()
        val done = onNodeWithText("Done").assertIsDisplayed()
        val bounds = done.getUnclippedBoundsInRoot()
        assertTrue(bounds.top >= 0.dp && bounds.bottom <= 450.dp && bounds.left >= 0.dp && bounds.right <= 320.dp)
        onNodeWithText("Long-press or drag to select a passage.").performScrollTo().assertIsDisplayed()
        done.performClick()
        onNode(isDialog()).assertDoesNotExist()
        runOnIdle { assertEquals(original, state) }
    }

    @Test fun messageActionsDoNotInterceptMarkdownLinkTaps() {
        val opened = mutableListOf<String>()
        compose.setContent {
            CompositionLocalProvider(LocalUriHandler provides object : UriHandler {
                override fun openUri(uri: String) { opened.add(uri) }
            }) {
                NrcApp(ChatState(profile = Profile("https://nrc.example", "studio"), selected = 2,
                    messages = mapOf(2L to listOf(Message("link", 2, author = "maya", timestampNanos = 1000,
                        text = "[Documentation](https://example.test/docs)")))),
                    {}, { _, _ -> }, {}, {}, {}, {}, {}, {})
            }
        }
        compose.onNodeWithText("Documentation", useUnmergedTree = true).performTouchInput {
            advanceEventTime(600); click(center)
        }
        assertEquals(listOf("https://example.test/docs"), opened)
        compose.onNodeWithText("Copy Markdown").assertDoesNotExist()
        compose.onNodeWithTag("message:link").performTouchInput { longClick(topLeft + androidx.compose.ui.geometry.Offset(8f, 8f)) }
        compose.onNodeWithText("Copy Markdown").assertIsDisplayed()
    }

    @Test fun consecutiveAuthorsGroupOnlyInsideFiveMinuteBoundary() {
        val base = java.time.LocalDate.now().atTime(12, 0).atZone(java.time.ZoneId.systemDefault()).toEpochSecond() * 1_000_000_000L
        var messages by mutableStateOf(listOf(0L, 299L, 599L).mapIndexed { index, seconds ->
            Message("message-$index", 2, author = "maya", timestampNanos = base + seconds * 1_000_000_000L, text = "Line $index")
        })
        compose.setContent {
            NrcApp(ChatState(profile = Profile("https://nrc.example", "studio"), selected = 2,
                connection = Connection.Connected, messages = mapOf(2L to messages)),
                {}, { _, _ -> }, {}, {}, {}, {}, {}, {})
        }
        compose.onAllNodesWithText("maya").assertCountEquals(2)
        compose.onAllNodesWithText("MA").assertCountEquals(2)
        compose.onNodeWithText("Copy Markdown").assertDoesNotExist()
        compose.onNodeWithTag("message:message-1").performTouchInput { longClick() }
        compose.onNodeWithText("Reply").performClick()
        compose.onNodeWithText("Reply").assertDoesNotExist()
        compose.runOnIdle { messages = messages.mapIndexed { index, message ->
            if (index == 1) message.copy(timestampNanos = base - 1) else message
        } }
        compose.onAllNodesWithText("maya").assertCountEquals(3)
    }

    @Test fun tailnetSwitchRequiresConfirmationAndKeepsChatDataWhileAwaitingNewLogin() {
        val original = ChatState(profile = Profile("https://nrc.example", "studio"), selected = 2,
            username = "rene", connection = Connection.Reconnecting, drafts = mapOf(2L to "Unsent draft"),
            messages = mapOf(2L to listOf(Message("saved", 2, author = "maya", timestampNanos = 1000, text = "Saved history"))))
        var state by mutableStateOf(original)
        var supported by mutableStateOf(false)
        var switching by mutableStateOf(false)
        var pendingLogin by mutableStateOf(false)
        var changes = 0
        var browserOpens = 0
        compose.setContent {
            NrcApp(state, { state = state.copy(selected = it) }, { id, text -> state = state.copy(drafts = state.drafts + (id to text)) },
                {}, { state = state.copy(profile = it) }, {}, {}, {}, {},
                onTailnetSignIn = if (pendingLogin) ({ browserOpens++ }) else null,
                onSwitchTailnet = if (supported) ({ changes++; switching = true; state = state.copy(connection = Connection.Disconnected) }) else null,
                switchingTailnet = switching)
        }
        compose.onNodeWithContentDescription("Connection settings and actions").performClick()
        compose.onNodeWithText("Switch Tailscale account").assertDoesNotExist()
        compose.runOnIdle { supported = true }
        compose.onNodeWithText("Switch Tailscale account").performClick()
        compose.onNodeWithText("Switch Tailscale account?").assertIsDisplayed()
        assertEquals(0, changes)
        compose.onNodeWithText("Cancel").performClick()
        compose.runOnIdle { assertEquals(original, state) }
        compose.onNodeWithContentDescription("Connection settings and actions").performClick()
        compose.onNodeWithText("Switch Tailscale account").performClick()
        compose.onNodeWithText("Sign out / sign in").performClick()
        assertEquals(1, changes)
        compose.onNodeWithText("Changing Tailscale account…").assertIsDisplayed()
        compose.onNodeWithContentDescription("Connection settings and actions").performClick()
        compose.onNodeWithText("Switch Tailscale account").assertIsNotEnabled()
        compose.onNodeWithText("Reconnect").assertIsNotEnabled()
        compose.onNodeWithText("System log").performClick()
        compose.onNodeWithContentDescription("Back from system log").performClick()
        compose.runOnIdle { switching = false; pendingLogin = true }
        compose.onNodeWithText("Continue Tailscale sign-in").performClick()
        assertEquals(1, browserOpens)
        compose.onNodeWithText("Saved history").assertExists()
        compose.onNode(hasSetTextAction()).assertTextEquals("Unsent draft")
        compose.runOnIdle { assertEquals(original.copy(connection = Connection.Disconnected), state) }
    }

    @Test fun pendingTailnetSignInCanBeRetriedAndReturnsAfterExpiry() {
        var pending by mutableStateOf(false)
        var attempts = 0
        val state = ChatState(profile = Profile("https://nrc.example", "studio"))
        compose.setContent {
            NrcApp(state, {}, { _, _ -> }, {}, {}, {}, {}, {}, {},
                onTailnetSignIn = if (pending) ({ attempts++ }) else null)
        }
        compose.onNodeWithText("Continue Tailscale sign-in").assertDoesNotExist()
        compose.runOnIdle { pending = true }
        repeat(2) { compose.onNodeWithText("Continue Tailscale sign-in").assertIsDisplayed().performClick() }
        assertEquals(2, attempts)
        compose.runOnIdle { pending = false }
        compose.onNodeWithText("Tailscale sign-in required").assertDoesNotExist()
        compose.runOnIdle { pending = true }
        compose.onNodeWithText("Continue Tailscale sign-in").assertIsDisplayed().performClick()
        assertEquals(3, attempts)
    }

    @Test fun offlineDraftRemainsEditableButCannotSendAndReconnectEnablesIt() {
        var state by mutableStateOf(ChatState(profile = Profile("https://nrc.example", "studio"), selected = 2,
            connection = Connection.Reconnecting, retention = mapOf(2L to Retention.Enabled), storageBlocked = true))
        var sends = 0
        compose.setContent {
            NrcApp(state, { state = state.copy(selected = it) }, { id, text -> state = state.copy(drafts = state.drafts + (id to text)) },
                { sends++ }, {}, {}, {}, {}, {})
        }
        compose.onNode(hasSetTextAction()).assertDoesNotExist()
        compose.onNodeWithText("Message #engineering").assertIsNotEnabled()
        compose.onNodeWithContentDescription("Send message").assertIsNotEnabled()
        compose.runOnIdle { state = state.copy(storageBlocked = false) }
        compose.onNodeWithText("Message #engineering").performTextInput("Draft survives reconnect")
        compose.onNodeWithText("Draft saved locally").assertExists()
        compose.onNodeWithContentDescription("Send message").assertIsNotEnabled()
        compose.runOnIdle { state = state.copy(connection = Connection.Connected) }
        compose.onNodeWithContentDescription("Send message").assertIsEnabled().performClick()
        assertEquals(1, sends)
        assertEquals("Draft survives reconnect", state.drafts[2])
        compose.onNodeWithContentDescription("Back to conversations").performClick()
        compose.onNodeWithText("ROOMS").assertExists()
        compose.onNodeWithText("engineering").performClick()
        compose.onNodeWithText("Draft survives reconnect").assertExists()
    }

    @Test fun pausedHistoryShowsExplicitRetryWithoutBlockingDeliberateSends() {
        var state by mutableStateOf(ChatState(profile = Profile("https://nrc.example", "studio"), selected = 2,
            connection = Connection.Connected, retention = mapOf(2L to Retention.Enabled),
            drafts = mapOf(2L to "Still allowed to send"), syncPaused = setOf(2L), failedHistory = setOf(2L)))
        compose.setContent { NrcApp(state, {}, { _, _ -> }, {}, {}, {}, { id ->
            state = state.copy(failedHistory = emptySet(), loadingHistory = setOf(id))
        }, {}, {}) }
        compose.onNodeWithText("Incoming messages are waiting for history recovery. Unread counts may be incomplete.").assertExists()
        compose.onNodeWithContentDescription("Send message").assertIsEnabled()
        compose.onNodeWithText("Retry message history").assertIsEnabled().performClick()
        compose.onNodeWithText("LOADING HISTORY").assertExists()
        compose.runOnIdle { state = state.copy(loadingHistory = emptySet(), syncPaused = emptySet(),
            messages = mapOf(2L to listOf(Message("recovered", 2, 1, "maya", 1000, "Recovered peer")))) }
        compose.onNodeWithText("Recovered peer").assertExists()
        compose.onNodeWithText("Incoming messages are waiting for history recovery. Unread counts may be incomplete.").assertDoesNotExist()
        compose.onNodeWithText("Retry message history").assertDoesNotExist()
    }

    @Test fun searchFiltersRoomsAndDirectMessages() {
        val state = ChatState(profile = Profile("https://nrc.example", "studio"), conversations = defaultRooms + Conversation(Long.MIN_VALUE + 1, "lena", true))
        compose.setContent { NrcApp(state, {}, { _, _ -> }, {}, {}, {}, {}, {}, {}, darkTheme = true) }
        compose.onNodeWithText("Search conversations").performTextInput("lena")
        compose.onNode(hasText("lena") and hasText("Live conversation")).assertExists()
        compose.onNodeWithText("engineering").assertDoesNotExist()
    }

    @Test fun cachedDMRequiresExplicitReopenAndNegotiatedRetentionBeforeSending() {
        val id = Long.MIN_VALUE + 9
        var state by mutableStateOf(ChatState(profile = Profile("https://nrc.example", "studio"),
            connection = Connection.Connected, selected = id, conversations = listOf(Conversation(id, "maya", true)),
            drafts = mapOf(id to "A saved draft"), retention = mapOf(id to Retention.Enabled)))
        var reopens = 0
        compose.setContent { NrcApp(state, {}, { _, _ -> }, {}, {}, { reopens++ }, {}, {}, {}) }
        compose.onNodeWithContentDescription("Send message").assertIsNotEnabled()
        assertEquals(0, reopens)
        compose.onNodeWithText("Reopen DM").performClick()
        assertEquals(1, reopens)
        compose.runOnIdle { state = state.copy(liveDMs = setOf(id), retention = mapOf(id to Retention.Unknown)) }
        compose.onNodeWithContentDescription("Send message").assertIsNotEnabled()
        compose.runOnIdle { state = state.copy(retention = mapOf(id to Retention.Ephemeral)) }
        compose.onNodeWithContentDescription("Send message").assertIsEnabled()
    }

    @Test fun systemLogMenuCopiesClearsAndBothBackPathsPreserveSelectedDraft() {
        var state by mutableStateOf(ChatState(profile = Profile("https://nrc.example", "studio"), selected = 2,
            connection = Connection.Reconnecting, drafts = mapOf(2L to "Draft before opening system log"),
            diagnostics = listOf(DiagnosticEvent(1791875701000, DiagnosticLevel.Error, "Transport failed",
                "DNS resolution failed. Check the server hostname and Tailscale DNS connection.\nIOException → UnknownHostException"))))
        var copied: AnnotatedString? = null
        val clipboard = object : ClipboardManager {
            override fun setText(annotatedString: AnnotatedString) { copied = annotatedString }
            override fun getText() = copied
        }
        var hostBack: () -> Unit = {}
        var backEnabled = false
        compose.setContent {
            CompositionLocalProvider(LocalClipboardManager provides clipboard) {
                NrcApp(state, { state = state.copy(selected = it) }, { _, _ -> }, {}, {}, {}, {}, {}, {},
                    onClearDiagnostics = { state = state.copy(diagnostics = emptyList()) },
                    platformBackHandler = { enabled, handler -> SideEffect { backEnabled = enabled; hostBack = handler } })
            }
        }
        fun openLog() {
            compose.onNodeWithContentDescription("Connection settings and actions").performClick()
            compose.onNodeWithText("System log").performClick()
        }
        openLog()
        compose.onNodeWithText("1/200").assertExists()
        compose.onNodeWithText("Transport failed").assertExists()
        compose.onNodeWithText("Copy log").assertIsEnabled().performClick()
        compose.onNodeWithText("Copied").assertExists()
        assertTrue(copied!!.text.contains("NRC chat · system log · timestamps UTC"))
        assertTrue(copied!!.text.contains("IOException → UnknownHostException"))
        assertFalse(copied!!.text.contains("Draft before opening system log"))
        compose.runOnIdle { assertTrue(backEnabled); hostBack() }
        compose.onNodeWithText("Draft before opening system log").assertExists()
        assertEquals(2L, state.selected)
        openLog()
        compose.onNodeWithText("Clear log").assertIsEnabled().performClick()
        compose.onNodeWithText("No events yet").assertExists()
        compose.onNodeWithText("0/200").assertExists()
        compose.onNodeWithText("Copy log").assertIsNotEnabled()
        compose.onNodeWithText("Clear log").assertIsNotEnabled()
        compose.onNodeWithContentDescription("Back from system log").performClick()
        compose.onNodeWithText("Draft before opening system log").assertExists()
        assertEquals(2L, state.selected)
        compose.runOnIdle { hostBack() }
        compose.onNodeWithText("ROOMS").assertExists()
        compose.runOnIdle { assertFalse(backEnabled) }
        assertEquals("Draft before opening system log", state.drafts[2])
    }

    @Test fun messageHeadersFollowWebAndOnlyPendingOrProblemStatesShowStatus() {
        var message by mutableStateOf(Message("outgoing", 2, author = "rene", timestampNanos = 1000,
            text = "A normal message", delivery = Delivery.Sending))
        compose.setContent {
            NrcApp(ChatState(profile = Profile("https://nrc.example", "studio"), username = "rene", selected = 2,
                connection = Connection.Connected, messages = mapOf(2L to listOf(message))),
                {}, { _, _ -> }, {}, {}, {}, {}, {}, {})
        }
        compose.onNodeWithText("sending…").assertExists()
        val timestamp = java.text.SimpleDateFormat("HH:mm", java.util.Locale.ROOT).format(java.util.Date(0))
        val authorBounds = compose.onNodeWithText("you", useUnmergedTree = true).fetchSemanticsNode().boundsInRoot
        val timeBounds = compose.onNodeWithText(timestamp, useUnmergedTree = true).fetchSemanticsNode().boundsInRoot
        assertTrue(authorBounds.right <= timeBounds.left, "Sender must precede the timestamp without overlap")
        compose.runOnIdle { message = message.copy(delivery = Delivery.Sent) }
        compose.onNodeWithText("A normal message").assertExists()
        compose.onNodeWithText("sent").assertDoesNotExist()
        compose.onNodeWithText("sending…").assertDoesNotExist()
        compose.runOnIdle { message = message.copy(delivery = Delivery.Unconfirmed) }
        compose.onNodeWithText("delivery unknown · check before resending").assertExists()
        compose.runOnIdle { message = message.copy(delivery = Delivery.Failed) }
        compose.onNodeWithText("not sent").assertExists()
        compose.onNodeWithText("delivery unknown · check before resending").assertDoesNotExist()
    }
}
