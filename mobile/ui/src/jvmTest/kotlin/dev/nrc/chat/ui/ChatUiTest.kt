package dev.nrc.chat.ui

import androidx.compose.runtime.*
import androidx.compose.ui.platform.ClipboardManager
import androidx.compose.ui.platform.LocalClipboardManager
import androidx.compose.ui.text.AnnotatedString
import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.createComposeRule
import dev.nrc.chat.*
import dev.nrc.chat.Retention
import org.junit.Rule
import org.junit.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertTrue

class ChatUiTest {
    @get:Rule val compose = createComposeRule()

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
}
