package com.abracode.chatview

// Port of ChatAgenticTests.ChatAgenticTransportTests: the scripted agentic turn through the real LocalChatTransport
// (reply "agentic"), including the permission gate's allow / reject / cancel paths, the advertised slash commands,
// and the setConfigOption round-trip. Swift's `for await event in transport.events` becomes: advanceUntilIdle() runs
// the scripted coroutine until it parks (on the permission deferred, or at the turn's end), then tryReceive drains
// the channel. The transport runs on a StandardTestDispatcher(testScheduler) so the whole turn is deterministic.

import kotlinx.coroutines.CoroutineDispatcher
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.channels.ReceiveChannel
import kotlinx.coroutines.test.StandardTestDispatcher
import kotlinx.coroutines.test.TestScope
import kotlinx.coroutines.test.advanceUntilIdle
import kotlinx.coroutines.test.runTest
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

@OptIn(ExperimentalCoroutinesApi::class)
class ChatAgenticTransportTest {

    private data class TurnResult(
        val sawThought: Boolean,
        val statuses: Map<String, ToolCallModel.Status>,
        val finalText: String,
        val stopReason: String?,
        val lastPlan: List<PlanEntry>,
        val usage: UsageInfo?,
    )

    private fun agenticTransport(dispatcher: CoroutineDispatcher): LocalChatTransport =
        LocalChatTransport(
            config = ChatTransportConfig(settings = buildJsonObject { put("reply", "agentic"); put("chunkMs", 0) }),
            logger = noopLogger(),
            dispatcher = dispatcher,
        )

    private fun ReceiveChannel<ChatEvent>.drainAvailable(): List<ChatEvent> {
        val out = mutableListOf<ChatEvent>()
        while (true) {
            val result = tryReceive()
            if (result.isSuccess) out.add(result.getOrThrow()) else break
        }
        return out
    }

    /** Drives one scripted agentic turn to completion, answering the permission with `answer` (an option id, or null to cancel). */
    private suspend fun TestScope.runTurn(answer: String?): TurnResult {
        val transport = agenticTransport(StandardTestDispatcher(testScheduler))
        transport.start()
        transport.send(ChatCommand.Prompt("please tweak the greeting"))
        advanceUntilIdle()   // runs the scripted turn up to the permission gate

        var sawThought = false
        val statuses = mutableMapOf<String, ToolCallModel.Status>()
        var finalText = ""
        var stopReason: String? = null
        var lastPlan: List<PlanEntry> = emptyList()
        var usage: UsageInfo? = null

        fun consume(events: List<ChatEvent>) {
            for (event in events) {
                when (event) {
                    is ChatEvent.ThoughtDelta -> sawThought = true
                    is ChatEvent.Plan -> lastPlan = event.entries
                    is ChatEvent.Usage -> usage = event.usage
                    is ChatEvent.ToolCall -> statuses[event.call.id] = event.call.status
                    is ChatEvent.ToolCallUpdateEvent -> event.update.status?.let { statuses[event.update.id] = it }
                    is ChatEvent.MessageDelta -> finalText += event.text
                    is ChatEvent.MessageEnd -> stopReason = event.stopReason
                    else -> {}
                }
            }
        }

        val firstBatch = transport.events.drainAvailable()
        consume(firstBatch)
        val permission = firstBatch.filterIsInstance<ChatEvent.PermissionRequestEvent>().firstOrNull()
        if (permission != null) {
            if (answer != null) {
                transport.send(ChatCommand.PermissionResponse(permission.request.id, answer))
            } else {
                transport.send(ChatCommand.Cancel)
            }
            advanceUntilIdle()
            consume(transport.events.drainAvailable())
        }
        transport.stop()
        advanceUntilIdle()
        return TurnResult(sawThought, statuses, finalText, stopReason, lastPlan, usage)
    }

    @Test
    fun agenticTurnAllowed() = runTest {
        val turn = runTurn("allow-once")
        assertTrue("the turn must stream reasoning first", turn.sawThought)
        assertEquals("end_turn", turn.stopReason)
        assertEquals("expected the search and edit tool calls", 2, turn.statuses.size)
        assertTrue("both calls complete when allowed", turn.statuses.values.all { it == ToolCallModel.Status.COMPLETED })
        assertTrue("the summary must reflect the approval", turn.finalText.contains("applied the approved edit"))
        assertEquals("the scripted turn lays out a three-step plan", 3, turn.lastPlan.size)
        assertTrue("the final plan re-emit completes every step", turn.lastPlan.all { it.status == PlanEntry.Status.COMPLETED })
        assertEquals("the turn ends with a usage report", 2350, turn.usage?.used)
    }

    @Test
    fun agenticTurnRejected() = runTest {
        val turn = runTurn("reject-once")
        assertEquals("a rejection still ends the turn normally", "end_turn", turn.stopReason)
        assertEquals("the gated edit must fail", 1, turn.statuses.values.count { it == ToolCallModel.Status.FAILED })
        assertEquals("the ungated search still completes", 1, turn.statuses.values.count { it == ToolCallModel.Status.COMPLETED })
        assertTrue("the summary must reflect the rejection", turn.finalText.contains("did not apply"))
    }

    @Test
    fun agenticAdvertisesSlashCommands() = runTest {
        val transport = agenticTransport(StandardTestDispatcher(testScheduler))
        transport.start()
        advanceUntilIdle()
        val commands = transport.events.drainAvailable().filterIsInstance<ChatEvent.CommandsAvailable>().firstOrNull()?.commands.orEmpty()
        transport.stop()
        advanceUntilIdle()
        assertEquals("the agentic demo advertises commands right after sessionReady", listOf("review", "test", "commit"), commands.map { it.name })
    }

    @Test
    fun setConfigOptionRoundTrip() = runTest {
        val transport = agenticTransport(StandardTestDispatcher(testScheduler))
        transport.start()
        advanceUntilIdle()
        transport.events.drainAvailable()   // discard the session advertisement
        transport.send(ChatCommand.SetConfigOption("mode", "bogus"))   // not a choice: no confirmation
        transport.send(ChatCommand.SetConfigOption("mode", "plan"))    // valid: confirmed
        advanceUntilIdle()
        val confirmed = transport.events.drainAvailable().filterIsInstance<ChatEvent.ConfigOptionsChanged>().lastOrNull()?.options.orEmpty()
        transport.stop()
        advanceUntilIdle()
        assertEquals("only the valid choice is confirmed; the display never sees the bogus one", "plan",
            confirmed.firstOrNull { it.id == "mode" }?.currentValue)
    }

    @Test
    fun agenticTurnCancelledAtTheGate() = runTest {
        val turn = runTurn(null)
        assertEquals("cancelled", turn.stopReason)
        assertEquals("the gated edit is abandoned", 1, turn.statuses.values.count { it == ToolCallModel.Status.FAILED })
        assertTrue("no summary streams after a cancel at the gate", turn.finalText.isEmpty())
    }
}
