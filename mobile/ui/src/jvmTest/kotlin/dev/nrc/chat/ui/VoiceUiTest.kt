package dev.nrc.chat.ui

import androidx.compose.foundation.layout.*
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.unit.Density
import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.unit.dp
import dev.nrc.chat.*
import org.junit.Rule
import org.junit.Test
import kotlin.test.assertEquals

class VoiceUiTest {
    @get:Rule val compose = createComposeRule()

    @Test fun startNeedsConsentAndProposalNeedsSelectionWhileMuteAndEndRemainAvailable() {
        var state by mutableStateOf(ChatState(profile = Profile("https://nrc.example", "studio"),
            connection = Connection.Connected))
        var voice by mutableStateOf(VoiceState())
        var approvals = 0
        compose.setContent {
            CompositionLocalProvider(LocalDensity provides Density(1f, 2f)) {
            Box(Modifier.width(320.dp).height(640.dp)) {
                NrcApp(state, {}, { _, _ -> }, {}, {}, {}, {}, {}, {}, voice = voice,
                    onVoiceStart = { voice = VoiceState(visible = true, active = true, ready = true, workspace = "studio", status = "Verbunden") },
                    onVoiceMute = { voice = voice.copy(muted = !voice.muted) },
                    onVoiceEnd = { voice = voice.copy(active = false, ready = false, canApprove = false) },
                    onVoiceSelect = { id, checked -> voice = voice.copy(selected = if (checked) voice.selected + id else voice.selected - id) },
                    onVoiceApprove = { approvals++; voice = voice.copy(canApprove = false, resolving = true, submitted = true, selected = emptySet()) })
            }
            }
        }
        compose.onNodeWithText("Mit Sullivan sprechen").assertIsDisplayed().performClick()
        compose.onNodeWithText("Gespräch starten").assertIsEnabled()
        assertEquals(false, voice.active)
        compose.onNodeWithText("Gespräch starten").performClick()
        compose.onNodeWithText("Mikrofon aktiv").assertExists()
        compose.onNodeWithText("Stummschalten").performClick()
        compose.onNodeWithText("Mikrofon stumm").assertExists()
        compose.onNodeWithText("Aktivieren").assertIsEnabled()
        compose.runOnIdle { voice = voice.copy(canApprove = true, actions = listOf(
            VoiceAction("a", "Rollout prüfen", """{"type":"create_task","title":"Rollout prüfen","priority":0,"description":"","unknown":"false"}"""))) }
        compose.onNodeWithText("Bestätigen").assertIsNotEnabled()
        compose.onNodeWithText("Aufgabe anlegen").assertExists()
        compose.onNodeWithText("Niedrig (0)").assertExists()
        compose.onNodeWithText("Leer").assertExists()
        compose.onNodeWithText("false").assertExists()
        for ((priority, label) in listOf(127 to "Niedrig (127)", 128 to "Mittel (128)",
            199 to "Mittel (199)", 200 to "Hoch (200)", 254 to "Hoch (254)", 255 to "255")) {
            compose.runOnIdle { voice = voice.copy(actions = listOf(VoiceAction("a", "Rollout prüfen",
                """{"type":"create_task","title":"Rollout prüfen","priority":$priority}"""))) }
            compose.onNodeWithText(label).assertExists()
        }
        compose.onNode(isToggleable()).performScrollTo().assertIsOff().performClick()
        compose.onNode(hasText("Aktivieren") and hasAnyAncestor(isDialog())).assertIsDisplayed()
        compose.onNode(hasText("Ende") and hasAnyAncestor(isDialog())).assertIsDisplayed()
        compose.onNodeWithText("Bestätigen").assertIsDisplayed().assertIsEnabled().performClick()
        assertEquals(1, approvals)
        compose.onNodeWithText("Bestätigen").assertIsNotEnabled()
        compose.onNodeWithText("Noch nicht ausgeführt.").assertDoesNotExist()
        compose.onNodeWithText("Bereits bestätigt. Ausführung kann erfolgt sein; nicht erneut ausführen.").assertExists()
        compose.runOnIdle { voice = voice.copy(resolving = false) }
        compose.onNodeWithText("Noch nicht ausgeführt.").assertDoesNotExist()
        compose.onNodeWithText("Bereits bestätigt. Ausführung kann erfolgt sein; nicht erneut ausführen.").assertExists()
        compose.runOnIdle { voice = voice.copy(resolving = true) }
        compose.onNodeWithText("Zurück").performClick()
        compose.onNodeWithText("Ende").assertIsEnabled().performClick()
        assertEquals(false, voice.active)
        assertEquals(true, voice.resolving)
        compose.onNodeWithContentDescription("Connection settings and actions").performClick()
        compose.onNodeWithText("Sullivan Sprache").assertIsNotEnabled()
    }
}
