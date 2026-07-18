package com.abracode.chatview

// A8 instrumentation polish: the transcript affordances the earlier stages left unverified on-device - day
// separators across a date boundary, the long-press context menu gated by capabilities (only Copy when the
// transport backs nothing; the full set on a live capable transport), reaction chips, and the typing row.

import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.material3.MaterialTheme
import androidx.compose.ui.Modifier
import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.assertIsEnabled
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.test.longClick
import androidx.compose.ui.test.onAllNodesWithText
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.performImeAction
import androidx.compose.ui.test.performTextInput
import androidx.compose.ui.test.performTouchInput
import com.abracode.chatview.ui.ChatView
import kotlinx.coroutines.channels.Channel
import org.junit.Assert.assertTrue
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put
import kotlinx.serialization.json.putJsonObject
import org.junit.Rule
import org.junit.Test

class ChatAffordancesInstrumentedTest {

    @get:Rule
    val rule = createComposeRule()

    private class FixedConfigSource(private val config: JsonObject) : ChatContentSource {
        override fun observeChatContent(handler: (Any?) -> Unit): Cancellable = Cancellable { }
        override fun observeChatConfig(handler: (Any?) -> Unit): Cancellable {
            handler(config)
            return Cancellable { }
        }
    }

    // Connects (reportsConnectionState + every v2 capability) and then emits a fixed script of events, so a message
    // with a reaction and a typing signal land deterministically without any scripted-backend timing.
    private class ScriptedTransport(private val script: List<ChatEvent>) : ChatTransport {
        private val channel = Channel<ChatEvent>(Channel.UNLIMITED)
        override val events = channel
        override val capabilities = ChatTransportCapabilities(
            typing = true, reactions = true, editing = true, deletion = true, replies = true,
            readReceipts = true, messageIdentity = true, reportsConnectionState = true,
        )

        override suspend fun start() {
            channel.trySend(ChatEvent.SessionReady(sessionID = "scripted", configOptions = emptyList()))
            channel.trySend(ChatEvent.ParticipantsChanged(listOf(Participant("me", "Me", isSelf = true), Participant("alex", "Alex"))))
            channel.trySend(ChatEvent.ConnectionStateChanged(ChatConnectionState.CONNECTED))
            script.forEach { channel.trySend(it) }
        }

        override suspend fun send(command: ChatCommand) { }
        override suspend fun stop() { channel.close() }
    }

    private fun readOnlyTranscript(items: List<ChatItem>): ChatConfiguration {
        val transcript = ChatTranscript(
            version = 2,
            items = items,
            participants = listOf(Participant("me", "Me", isSelf = true), Participant("alex", "Alex")),
        )
        val props = buildJsonObject {
            putJsonObject("appearance") { put("alignment", "dual") }
            put("readOnly", true)
            put("content", chatJson.encodeToJsonElement(ChatTranscript.serializer(), transcript))
        }
        return ChatConfiguration.fromJson(props, ConsoleChatLogger())
    }

    private fun message(id: String, text: String, day: String) = ChatItem.Message(
        ChatMessage(id = id, role = ChatRole.REMOTE, text = text, senderName = "Alex", senderID = "alex", timestamp = "${day}T15:00:00Z"),
    ) as ChatItem

    private fun awaitInputEnabled() {
        rule.waitUntil(5_000) {
            runCatching { rule.onNodeWithTag("chat.composer.input").assertIsEnabled() }.isSuccess
        }
    }

    @Test
    fun daySeparatorRendersAcrossDateBoundary() {
        // Two messages on different (past) days: a day separator labels each day (a medium date carrying the year).
        val cfg = readOnlyTranscript(
            listOf(
                message("d1", "First day message", "2026-05-09"),
                message("d2", "Second day message", "2026-05-10"),
            ),
        )
        rule.setContent { MaterialTheme { Box(Modifier.fillMaxSize()) { ChatView(configuration = cfg) } } }
        rule.waitForIdle()
        rule.onNodeWithText("First day message", substring = true).assertExists()
        rule.onNodeWithText("Second day message", substring = true).assertExists()
        // The medium-date day separators carry the year; the message time captions are HH:MM only, so a "2026" node
        // is a day separator.
        assertTrue(rule.onAllNodesWithText("2026", substring = true).fetchSemanticsNodes().isNotEmpty())
    }

    @Test
    fun contextMenuShowsOnlyCopyWhenCapabilitiesAbsent() {
        // readOnly has no transport, so every v2 capability is off: the menu offers only Copy.
        val cfg = readOnlyTranscript(listOf(message("m1", "A restored message", "2026-05-09")))
        rule.setContent { MaterialTheme { Box(Modifier.fillMaxSize()) { ChatView(configuration = cfg) } } }
        rule.waitForIdle()
        rule.onNodeWithText("A restored message", substring = true).performTouchInput { longClick() }
        rule.onNodeWithText("Copy").assertIsDisplayed()
        rule.onNodeWithText("Reply").assertDoesNotExist()
        rule.onNodeWithText("Edit").assertDoesNotExist()
        rule.onNodeWithText("Delete").assertDoesNotExist()
    }

    @Test
    fun liveContextMenuShowsGatedAffordances() {
        // A live, fully capable transport plus a document opting into every feature: an own message's menu offers
        // Reply, Edit, Delete, and Copy.
        val props = buildJsonObject {
            putJsonObject("appearance") { put("alignment", "dual") }
            putJsonObject("features") {
                put("reactions", true); put("editing", true); put("deletion", true); put("replies", true)
            }
        }
        val cfg = ChatConfiguration.fromJson(props, ConsoleChatLogger())
        rule.setContent {
            MaterialTheme {
                Box(Modifier.fillMaxSize()) {
                    ChatView(configuration = cfg, contentSource = FixedConfigSource(buildJsonObject { put("protocol", "local-p2p") }))
                }
            }
        }
        awaitInputEnabled()
        rule.onNodeWithTag("chat.composer.input").performTextInput("My own message")
        rule.onNodeWithTag("chat.composer.input").performImeAction()
        rule.waitUntil(5_000) {
            rule.onAllNodesWithText("My own message", substring = true).fetchSemanticsNodes().isNotEmpty()
        }
        rule.onNodeWithText("My own message", substring = true).performTouchInput { longClick() }
        rule.onNodeWithText("Reply").assertIsDisplayed()
        rule.onNodeWithText("Edit").assertIsDisplayed()
        rule.onNodeWithText("Delete").assertIsDisplayed()
        rule.onNodeWithText("Copy").assertIsDisplayed()
    }

    @Test
    fun reactionChipAndTypingRowRender() {
        ChatTransportRegistry.shared.register("a8-scripted") { _, _ ->
            ScriptedTransport(
                listOf(
                    ChatEvent.MessageReceived(
                        ChatMessage(
                            id = "r1", role = ChatRole.REMOTE, text = "Lunch spot found", senderName = "Alex", senderID = "alex",
                            reactions = listOf(Reaction(emoji = "X", count = 7, mine = false)),
                        ),
                    ),
                    ChatEvent.TypingChanged(isTyping = true, senderID = "alex", senderName = "Alex"),
                ),
            )
        }
        val props = buildJsonObject {
            putJsonObject("appearance") { put("alignment", "dual") }
            putJsonObject("features") { put("reactions", true) }
        }
        val cfg = ChatConfiguration.fromJson(props, ConsoleChatLogger())
        rule.setContent {
            MaterialTheme {
                Box(Modifier.fillMaxSize()) {
                    ChatView(configuration = cfg, contentSource = FixedConfigSource(buildJsonObject { put("protocol", "a8-scripted") }))
                }
            }
        }
        // The reaction chip (emoji + count) renders because canReact is on (feature + capability), and the typing row
        // shows while Alex is typing.
        rule.waitUntil(5_000) {
            rule.onAllNodesWithText("Lunch spot found", substring = true).fetchSemanticsNodes().isNotEmpty()
        }
        rule.onNodeWithText("7", substring = true).assertIsDisplayed()
        rule.waitUntil(5_000) {
            rule.onAllNodesWithText("typing", substring = true).fetchSemanticsNodes().isNotEmpty()
        }
        rule.onNodeWithText("typing", substring = true).assertIsDisplayed()
    }
}
