package com.abracode.chatview

// A7 acceptance on the emulator: the composer's submit policy, Send/Stop swap, connection gating, and the reply
// banner wired from the row context menu. A host-injected config drives a live in-process transport (the built-in
// `local-p2p`, plus a scripted no-reply transport registered here so the awaiting/Stop state is deterministic).

import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.material3.MaterialTheme
import androidx.compose.ui.Modifier
import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.assertIsEnabled
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.test.longClick
import androidx.compose.ui.test.onAllNodesWithContentDescription
import androidx.compose.ui.test.onAllNodesWithText
import androidx.compose.ui.test.onNodeWithContentDescription
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.performClick
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

class ComposerInstrumentedTest {

    @get:Rule
    val rule = createComposeRule()

    // A content source that delivers `config` immediately on subscription (and nothing else) - the host-injection
    // path the store subscribes to for its transport config. No content restore.
    private class FixedConfigSource(private val config: JsonObject) : ChatContentSource {
        override fun observeChatContent(handler: (Any?) -> Unit): Cancellable = Cancellable { }
        override fun observeChatConfig(handler: (Any?) -> Unit): Cancellable {
            handler(config)
            return Cancellable { }
        }
    }

    // A scripted transport that connects and then stays silent: a submitted turn never gets a reply, so awaitingReply
    // (and therefore the Stop control) holds deterministically. Backs replies/editing so those affordances light up.
    private class NoReplyTransport : ChatTransport {
        private val channel = Channel<ChatEvent>(Channel.UNLIMITED)
        override val events = channel
        override val capabilities = ChatTransportCapabilities(
            reportsConnectionState = true, replies = true, editing = true, reactions = true, deletion = true,
        )

        override suspend fun start() {
            channel.trySend(ChatEvent.SessionReady(sessionID = "a7-test", configOptions = emptyList()))
            channel.trySend(ChatEvent.ConnectionStateChanged(ChatConnectionState.CONNECTED))
        }

        override suspend fun send(command: ChatCommand) { /* intentionally silent */ }
        override suspend fun stop() { channel.close() }
    }

    // The ChatConfiguration document (appearance / input / features) - distinct from the host-injected transport
    // config below.
    private fun config(submitOn: String? = null, replies: Boolean = false): JsonObject =
        buildJsonObject {
            putJsonObject("appearance") { put("alignment", "dual") }
            if (submitOn != null) {
                putJsonObject("input") { put("submitOn", submitOn) }
            }
            if (replies) {
                putJsonObject("features") { put("replies", true) }
            }
        }

    private fun transportConfig(protocol: String): JsonObject = buildJsonObject { put("protocol", protocol) }

    private fun awaitComposerEnabled() {
        rule.waitUntil(5_000) {
            runCatching { rule.onNodeWithTag("chat.composer.input").assertIsEnabled() }.isSuccess
        }
    }

    @Test
    fun submitOnReturnSendsAndClearsDraft() {
        val cfg = ChatConfiguration.fromJson(config(), ConsoleChatLogger())
        rule.setContent {
            MaterialTheme {
                Box(Modifier.fillMaxSize()) {
                    ChatView(configuration = cfg, contentSource = FixedConfigSource(transportConfig("local-p2p")))
                }
            }
        }
        awaitComposerEnabled()

        rule.onNodeWithTag("chat.composer.input").performTextInput("Hello from A7")
        rule.onNodeWithTag("chat.composer.input").performImeAction()

        // The optimistic outgoing message appears in the transcript, and the draft is cleared (submitDraft empties it).
        rule.waitUntil(5_000) {
            rule.onAllNodesWithText("Hello from A7", substring = true).fetchSemanticsNodes().isNotEmpty()
        }
        rule.onNodeWithText("Hello from A7", substring = true).assertIsDisplayed()
    }

    @Test
    fun stopReplacesSendWhileAwaitingReply() {
        ChatTransportRegistry.shared.register("a7-noreply") { _, _ -> NoReplyTransport() }
        val cfg = ChatConfiguration.fromJson(config(), ConsoleChatLogger())
        rule.setContent {
            MaterialTheme {
                Box(Modifier.fillMaxSize()) {
                    ChatView(configuration = cfg, contentSource = FixedConfigSource(transportConfig("a7-noreply")))
                }
            }
        }
        awaitComposerEnabled()

        // Send shows while idle; Stop is absent.
        rule.onNodeWithContentDescription("Send").assertIsDisplayed()
        rule.onNodeWithContentDescription("Stop").assertDoesNotExist()

        rule.onNodeWithTag("chat.composer.input").performTextInput("Prompt with no reply")
        rule.onNodeWithTag("chat.composer.input").performImeAction()

        // The turn is in flight and never answered: Send swaps to Stop and holds.
        rule.waitUntil(5_000) {
            rule.onAllNodesWithContentDescription("Stop").fetchSemanticsNodes().isNotEmpty()
        }
        rule.onNodeWithContentDescription("Stop").assertIsDisplayed()
        rule.onNodeWithContentDescription("Send").assertDoesNotExist()
    }

    @Test
    fun replyFromContextMenuShowsBanner() {
        ChatTransportRegistry.shared.register("a7-noreply") { _, _ -> NoReplyTransport() }
        val cfg = ChatConfiguration.fromJson(config(replies = true), ConsoleChatLogger())
        rule.setContent {
            MaterialTheme {
                Box(Modifier.fillMaxSize()) {
                    ChatView(configuration = cfg, contentSource = FixedConfigSource(transportConfig("a7-noreply")))
                }
            }
        }
        awaitComposerEnabled()

        // Post one message to reply to, then long-press it and choose Reply.
        rule.onNodeWithTag("chat.composer.input").performTextInput("Original message")
        rule.onNodeWithTag("chat.composer.input").performImeAction()
        rule.waitUntil(5_000) {
            rule.onAllNodesWithText("Original message", substring = true).fetchSemanticsNodes().isNotEmpty()
        }
        rule.onNodeWithText("Original message", substring = true).performTouchInput { longClick() }
        rule.onNodeWithText("Reply").performClick()

        // The composer's reply banner appears with the quoted excerpt, so "Original message" now shows twice (the
        // original bubble and the banner excerpt).
        rule.waitUntil(5_000) {
            rule.onAllNodesWithText("Replying", substring = true).fetchSemanticsNodes().isNotEmpty()
        }
        rule.onNodeWithText("Replying", substring = true).assertIsDisplayed()
        assertTrue(rule.onAllNodesWithText("Original message", substring = true).fetchSemanticsNodes().size >= 2)
    }

    @Test
    fun readOnlyHasNoComposer() {
        val props = buildJsonObject {
            putJsonObject("appearance") { put("alignment", "dual") }
            put("readOnly", true)
        }
        val cfg = ChatConfiguration.fromJson(props, ConsoleChatLogger())
        rule.setContent { MaterialTheme { Box(Modifier.fillMaxSize()) { ChatView(configuration = cfg) } } }
        rule.waitForIdle()
        rule.onNodeWithTag("chat.composer.input").assertDoesNotExist()
    }
}
