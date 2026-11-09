package dev.nrc.chat.ui

import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.width
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.asSkiaBitmap
import androidx.compose.ui.test.*
import androidx.compose.ui.unit.dp
import dev.nrc.chat.*
import org.jetbrains.skia.Image
import org.junit.Test
import org.junit.runner.RunWith
import org.junit.runners.Parameterized
import java.io.File

/** Same native screens and desktop renderer as preview; optional review artifacts. */
@OptIn(ExperimentalTestApi::class)
@RunWith(Parameterized::class)
class MemoryRenderingTest(private val dark: Boolean, private val width: Int) {
    companion object {
        @JvmStatic @Parameterized.Parameters(name = "dark={0}, width={1}")
        fun sizes() = listOf(arrayOf<Any>(false, 320), arrayOf<Any>(true, 320), arrayOf<Any>(false, 700), arrayOf<Any>(true, 700))
    }

    @Test fun privacyControlsRemainReachableAcrossThemesAndWidths() = runDesktopComposeUiTest(width = width, height = 900) {
        setContent {
            Box(Modifier.width(width.dp).height(900.dp)) {
                NrcApp(ChatState(profile = Profile("https://nrc.example", "studio"), connection = Connection.Connected),
                    {}, { _, _ -> }, {}, {}, {}, {}, {}, {}, darkTheme = dark, onVoiceStart = {},
                    memory = MemoryState(policy = MemoryPolicy(7, true)))
            }
        }
        onNodeWithText("Mit Sullivan sprechen").performClick()
        onNodeWithText("Persönliches Gedächtnis").assertDoesNotExist()
        capture("voice")
        onNodeWithText("Abbrechen").performClick()
        onNodeWithContentDescription("Connection settings and actions").performClick()
        onNodeWithText("Temporär sprechen").assertIsDisplayed()
        capture("actions")
        onNodeWithText("Connection settings").performClick()
        onNodeWithText("Alles vergessen …").performScrollTo().assertIsDisplayed()
        capture("policy")
        onNodeWithText("Alles vergessen …").performScrollTo().assertIsDisplayed().performClick()
        onNodeWithText("Endgültig vergessen").assertIsDisplayed().assertIsEnabled()
        capture("forget")
    }

    private fun ComposeUiTest.capture(name: String) {
        val directory = System.getenv("NRC_UI_SCREENSHOTS") ?: return
        val node = when (name) {
            "forget", "voice" -> onNode(isDialog())
            "actions" -> onNode(isPopup())
            else -> onRoot()
        }
        val bitmap = node.captureToImage().asSkiaBitmap()
        Image.makeFromBitmap(bitmap).use { image ->
            image.encodeToData()!!.use { data ->
                File(directory, "memory-${if (dark) "dark" else "light"}-$width-$name.png").writeBytes(data.bytes)
            }
        }
    }
}
