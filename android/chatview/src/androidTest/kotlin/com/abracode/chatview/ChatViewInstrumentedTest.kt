package com.abracode.chatview

// A6 acceptance on the emulator: the transcript renders a restored (readOnly) dual-alignment conversation, and the
// scroll-pin matrix's core loop holds - a conversation taller than the viewport starts pinned at the bottom (no
// jump pill), a user scroll up unpins and surfaces the "Jump to latest" pill, and tapping it re-pins (pill gone).

import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.material3.MaterialTheme
import androidx.compose.ui.Modifier
import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.test.onAllNodesWithContentDescription
import androidx.compose.ui.test.onNodeWithContentDescription
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.performClick
import androidx.compose.ui.test.performTouchInput
import androidx.compose.ui.test.swipeDown
import com.abracode.chatview.ui.ChatView
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put
import kotlinx.serialization.json.putJsonObject
import org.junit.Rule
import org.junit.Test

class ChatViewInstrumentedTest {

    @get:Rule
    val rule = createComposeRule()

    // A readOnly dual-alignment config carrying an inline restored transcript of `n` incoming messages, so start()
    // loads it with no transport (the transcript-only render path A6 targets).
    private fun dualReadOnlyConfig(n: Int): ChatConfiguration {
        val items = (1..n).map {
            ChatItem.Message(ChatMessage(id = "m$it", role = ChatRole.REMOTE, text = "Message $it", senderName = "Alex", senderID = "alex")) as ChatItem
        }
        val transcript = ChatTranscript(
            version = 2,
            items = items,
            participants = listOf(Participant("me", "Me", isSelf = true), Participant("alex", "Alex")),
        )
        val content = chatJson.encodeToJsonElement(ChatTranscript.serializer(), transcript)
        val props = buildJsonObject {
            putJsonObject("appearance") { put("alignment", "dual") }
            put("readOnly", true)
            put("content", content)
        }
        return ChatConfiguration.fromJson(props, ConsoleChatLogger())
    }

    @Test
    fun rendersRestoredTranscript() {
        rule.setContent { MaterialTheme { Box(Modifier.fillMaxSize()) { ChatView(configuration = dualReadOnlyConfig(3)) } } }
        rule.waitForIdle()
        rule.onNodeWithText("Message 1", substring = true).assertExists()
        rule.onNodeWithText("Message 3", substring = true).assertIsDisplayed()
        // Group mode shows the other party's sender name at the first message of a run.
        rule.onNodeWithText("Alex", substring = true).assertExists()
    }

    @Test
    fun scrollUpUnpinsAndPillRepins() {
        rule.setContent { MaterialTheme { Box(Modifier.fillMaxSize()) { ChatView(configuration = dualReadOnlyConfig(40)) } } }
        rule.waitForIdle()
        // A restored conversation opens pinned at the newest message: no jump pill.
        rule.onNodeWithContentDescription("Jump to latest").assertDoesNotExist()

        // A user scroll up (reveal earlier) unpins and surfaces the pill.
        rule.onNodeWithTag("chat.transcript").performTouchInput { swipeDown() }
        rule.waitUntil(5_000) { rule.onAllNodesWithContentDescription("Jump to latest").fetchSemanticsNodes().isNotEmpty() }
        rule.onNodeWithContentDescription("Jump to latest").assertIsDisplayed()

        // Tapping the pill re-pins to the bottom; the pill disappears.
        rule.onNodeWithContentDescription("Jump to latest").performClick()
        rule.waitUntil(5_000) { rule.onAllNodesWithContentDescription("Jump to latest").fetchSemanticsNodes().isEmpty() }
    }
}
