package com.abracode.chatview

// Phase 4 of the remote-agent plan on device: the surfaces a phone needs to actually OPERATE an agent session -
// the permission gate (without it a remote agent parks forever), the tool-call card, and the thought fold. The
// JVM suites cover the store routing; these cover what a thumb can reach.

import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.material3.MaterialTheme
import androidx.compose.ui.Modifier
import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.test.onAllNodesWithTag
import androidx.compose.ui.test.onAllNodesWithText
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.performClick
import com.abracode.chatview.ui.ChatView
import kotlinx.coroutines.channels.Channel
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put
import kotlinx.serialization.json.putJsonObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import java.util.UUID

class ChatAgenticRowsInstrumentedTest {

    @get:Rule
    val rule = createComposeRule()

    private class FixedConfigSource(private val config: JsonObject) : ChatContentSource {
        override fun observeChatContent(handler: (Any?) -> Unit): Cancellable = Cancellable { }
        override fun observeChatConfig(handler: (Any?) -> Unit): Cancellable {
            handler(config)
            return Cancellable { }
        }
    }

    /** Connects, then lets the test push agentic events by hand and records what the UI sent back. */
    private class AgenticTransport : ChatTransport {
        private val channel = Channel<ChatEvent>(Channel.UNLIMITED)
        override val events = channel
        override val capabilities = ChatTransportCapabilities(reportsConnectionState = true)
        private val recorded = mutableListOf<ChatCommand>()

        override suspend fun start() {
            channel.trySend(ChatEvent.SessionReady(sessionID = "agentic", configOptions = emptyList()))
            channel.trySend(ChatEvent.ConnectionStateChanged(ChatConnectionState.CONNECTED))
        }

        override suspend fun send(command: ChatCommand) {
            synchronized(recorded) { recorded.add(command) }
        }

        override suspend fun stop() {
            channel.close()
        }

        fun emit(event: ChatEvent) {
            channel.trySend(event)
        }

        fun commands(): List<ChatCommand> = synchronized(recorded) { recorded.toList() }
    }

    /** Mounts a live chat on a freshly registered transport and returns it, so the test can drive events. */
    private fun mountAgenticChat(props: JsonObject = buildJsonObject { }): AgenticTransport {
        val transport = AgenticTransport()
        val name = "agentic-rows-" + UUID.randomUUID()
        ChatTransportRegistry.shared.register(name) { _, _ -> transport }
        val cfg = ChatConfiguration.fromJson(props, ConsoleChatLogger())
        rule.setContent {
            MaterialTheme {
                Box(Modifier.fillMaxSize()) {
                    ChatView(
                        configuration = cfg,
                        contentSource = FixedConfigSource(buildJsonObject { put("protocol", name) }),
                    )
                }
            }
        }
        return transport
    }

    private fun awaitTag(tag: String) {
        rule.waitUntil(5_000) { rule.onAllNodesWithTag(tag).fetchSemanticsNodes().isNotEmpty() }
    }

    private fun permission(id: String = "p1") = PermissionRequest(
        id = id,
        toolCallID = "call-1",
        title = "Allow editing main.kt?",
        options = listOf(
            PermissionRequest.Option("allow", "Allow", PermissionRequest.Option.Kind.ALLOW_ONCE),
            PermissionRequest.Option("deny", "Deny", PermissionRequest.Option.Kind.REJECT_ONCE),
        ),
    )

    @Test
    fun permissionCardAppearsAndAnswerReachesTheTransport() {
        val transport = mountAgenticChat()
        transport.emit(ChatEvent.PermissionRequestEvent(permission()))

        awaitTag("chat.permissionCard")
        rule.onNodeWithText("Allow editing main.kt?", substring = true).assertIsDisplayed()

        rule.onNodeWithTag("chat.permissionCard.option.allow").performClick()

        // Answering pops the gate AND sends the answer: the agent is blocked until it arrives.
        rule.waitUntil(5_000) { rule.onAllNodesWithTag("chat.permissionCard").fetchSemanticsNodes().isEmpty() }
        rule.waitUntil(5_000) { transport.commands().any { it is ChatCommand.PermissionResponse } }
        val answer = transport.commands().filterIsInstance<ChatCommand.PermissionResponse>().first()
        assertEquals("p1", answer.requestID)
        assertEquals("allow", answer.optionID)
    }

    @Test
    fun permissionCardShowsOneQuestionAtATimeInOrder() {
        // The store queues gates FIFO and the card shows the head. An agent can have more than one tool waiting,
        // and answering the first must reveal the second rather than dismissing both - the second request is still
        // blocking the agent.
        val transport = mountAgenticChat()
        transport.emit(ChatEvent.PermissionRequestEvent(permission("p1")))
        transport.emit(
            ChatEvent.PermissionRequestEvent(
                permission("p2").copy(title = "Allow running the tests?"),
            ),
        )

        awaitTag("chat.permissionCard")
        rule.onNodeWithText("Allow editing main.kt?", substring = true).assertIsDisplayed()
        rule.onNodeWithText("Allow running the tests?", substring = true).assertDoesNotExist()

        rule.onNodeWithTag("chat.permissionCard.option.allow").performClick()

        rule.waitUntil(5_000) {
            rule.onAllNodesWithText("Allow running the tests?", substring = true).fetchSemanticsNodes().isNotEmpty()
        }
        // The card is still up - for the SECOND question - and exactly one answer has gone out.
        rule.onNodeWithTag("chat.permissionCard").assertIsDisplayed()
        val answers = transport.commands().filterIsInstance<ChatCommand.PermissionResponse>()
        assertEquals("answering the head must not answer the queue", 1, answers.size)
        assertEquals("p1", answers.first().requestID)
    }

    @Test
    fun permissionResolvedElsewhereClearsTheCardWithoutAnswering() {
        val transport = mountAgenticChat()
        transport.emit(ChatEvent.PermissionRequestEvent(permission()))
        awaitTag("chat.permissionCard")

        // Another device answered it, or the bridge default-denied it on a timeout.
        transport.emit(ChatEvent.PermissionResolved("p1"))

        rule.waitUntil(5_000) { rule.onAllNodesWithTag("chat.permissionCard").fetchSemanticsNodes().isEmpty() }
        assertTrue(
            "the answer already happened upstream; sending one of our own would be a second vote",
            transport.commands().none { it is ChatCommand.PermissionResponse },
        )
    }

    @Test
    fun toolCardMutatesInPlaceAndFoldsOutItsDetail() {
        val transport = mountAgenticChat()
        transport.emit(
            ChatEvent.ToolCall(
                ToolCallModel(
                    id = "call-1",
                    title = "Read main.kt",
                    kind = ToolCallModel.Kind.READ,
                    status = ToolCallModel.Status.PENDING,
                    contentText = "",
                ),
            ),
        )
        awaitTag("chat.toolCall.header")
        // Nothing to fold out yet, so no detail and no chevron.
        assertTrue(rule.onAllNodesWithTag("chat.toolCall.detail").fetchSemanticsNodes().isEmpty())

        transport.emit(
            ChatEvent.ToolCallUpdateEvent(
                ToolCallUpdate(
                    id = "call-1",
                    title = "Read main.kt (34 lines)",
                    status = ToolCallModel.Status.COMPLETED,
                    contentText = "package com.abracode.demo",
                ),
            ),
        )
        rule.waitUntil(5_000) {
            rule.onAllNodesWithText("34 lines", substring = true).fetchSemanticsNodes().isNotEmpty()
        }
        // One card, mutated - not a second one appended.
        assertEquals(1, rule.onAllNodesWithTag("chat.toolCall.header").fetchSemanticsNodes().size)
        assertTrue(
            "tool content is bulk material; the card must start folded whatever the surface mode says",
            rule.onAllNodesWithTag("chat.toolCall.detail").fetchSemanticsNodes().isEmpty(),
        )

        rule.onNodeWithTag("chat.toolCall.header").performClick()
        awaitTag("chat.toolCall.detail")
        rule.onNodeWithText("package com.abracode.demo", substring = true).assertIsDisplayed()
    }

    @Test
    fun thoughtFoldStaysCollapsedUntilTapped() {
        val transport = mountAgenticChat()
        transport.emit(ChatEvent.ThoughtDelta("t1", "Checking whether the file already exists."))

        awaitTag("chat.thought.header")
        // surfaces.thoughts defaults to collapsed: reasoning is available, not imposed.
        assertTrue(rule.onAllNodesWithTag("chat.thought.body").fetchSemanticsNodes().isEmpty())

        rule.onNodeWithTag("chat.thought.header").performClick()
        awaitTag("chat.thought.body")
        rule.onNodeWithText("Checking whether the file", substring = true).assertIsDisplayed()
    }

    @Test
    fun inlineThoughtSurfaceStartsExpanded() {
        val props = buildJsonObject {
            putJsonObject("surfaces") { put("thoughts", "inline") }
        }
        val transport = mountAgenticChat(props)
        transport.emit(ChatEvent.ThoughtDelta("t1", "Reasoning out loud."))

        awaitTag("chat.thought.body")
        rule.onNodeWithText("Reasoning out loud.", substring = true).assertIsDisplayed()
    }
}
