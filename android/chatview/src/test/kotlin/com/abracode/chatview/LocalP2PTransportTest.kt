package com.abracode.chatview

// Port of Tests/ChatViewTests/LocalP2PTransportTests.swift.
//
// The scripted local-p2p transport: it seeds the group / people conversation with the full v2 vocabulary, answers a
// user send with a delivery ladder + a peer reply, honors reaction / edit / delete commands, and serves synthetic
// paged history that terminates. Driven at stepMs 0 so the seed is deterministic (the ambient "little life" is
// paced-mode only). Swift drains a background AsyncStream and settles with sleeps; here the transport runs on a
// StandardTestDispatcher, we advanceUntilIdle to run the scripted beats, then drain the (unbounded) event channel.

import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.channels.ReceiveChannel
import kotlinx.coroutines.test.StandardTestDispatcher
import kotlinx.coroutines.test.TestScope
import kotlinx.coroutines.test.advanceUntilIdle
import kotlinx.coroutines.test.runTest
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

@OptIn(ExperimentalCoroutinesApi::class)
class LocalP2PTransportTest {

    private val thumbsUp = String(Character.toChars(0x1F44D))

    private fun TestScope.makeTransport(scenario: String): LocalP2PTransport =
        LocalP2PTransport(
            ChatTransportConfig(
                protocolName = "local-p2p",
                settings = buildJsonObject { put("scenario", scenario); put("stepMs", 0) },
            ),
            dispatcher = StandardTestDispatcher(testScheduler),
        )

    private fun ReceiveChannel<ChatEvent>.drain(): List<ChatEvent> {
        val out = mutableListOf<ChatEvent>()
        while (true) {
            out.add(tryReceive().getOrNull() ?: break)
        }
        return out
    }

    @Test
    fun groupSeedExercisesTheFullVocabulary() = runTest {
        val transport = makeTransport("group")
        transport.start()
        advanceUntilIdle()
        val events = transport.events.drain()
        transport.stop()

        var participants: List<Participant> = emptyList()
        var memberEvents = 0
        var callEvents = 0
        var files = 0
        var voices = 0
        var messages = 0
        for (event in events) {
            when (event) {
                is ChatEvent.ParticipantsChanged -> participants = event.participants
                is ChatEvent.MemberEventReceived -> memberEvents++
                is ChatEvent.CallEventReceived -> callEvents++
                is ChatEvent.FileAdded -> if (event.file.kind == ChatFile.Kind.VOICE) voices++ else files++
                is ChatEvent.MessageReceived -> messages++
                else -> Unit
            }
        }
        assertEquals("group roster: You + Alex + Sam + Jordan", 4, participants.size)
        assertTrue("one participant is self", participants.any { it.isSelf == true })
        assertTrue("a join and a rename", memberEvents >= 2)
        assertEquals(1, callEvents)
        assertEquals(1, files)
        assertEquals(1, voices)
        assertTrue(messages >= 4)
    }

    @Test
    fun peopleScenarioHasNoGroupOnlyItems() = runTest {
        val transport = makeTransport("people")
        transport.start()
        advanceUntilIdle()
        val events = transport.events.drain()
        transport.stop()

        assertFalse("a 1:1 chat has no member events", events.any { it is ChatEvent.MemberEventReceived })
        assertFalse(events.any { it is ChatEvent.CallEventReceived })
        val roster = events.filterIsInstance<ChatEvent.ParticipantsChanged>().firstOrNull()?.participants
        assertEquals("people roster: You + Alex", 2, roster?.size)
    }

    @Test
    fun userSendGetsDeliveryLadderAndReply() = runTest {
        val transport = makeTransport("people")
        transport.start()
        advanceUntilIdle()
        transport.events.drain() // discard the seed
        transport.send(ChatCommand.Prompt("Are you around?"))
        advanceUntilIdle()
        val events = transport.events.drain()
        transport.stop()

        assertTrue(
            "the own message advances through the delivery ladder",
            events.any { it is ChatEvent.MessageStatusChanged && (it.status == MessageStatus.SENT || it.status == MessageStatus.DELIVERED) },
        )
        assertTrue(
            "the peer replies",
            events.any { it is ChatEvent.MessageReceived && it.message.role == ChatRole.REMOTE },
        )
    }

    @Test
    fun startReportsConnected() = runTest {
        val transport = makeTransport("people")
        transport.start()
        advanceUntilIdle()
        val events = transport.events.drain()
        transport.stop()

        assertTrue("local-p2p reports connection state", transport.capabilities.reportsConnectionState)
        assertTrue(
            "the link comes up on start",
            events.any { it is ChatEvent.ConnectionStateChanged && it.state == ChatConnectionState.CONNECTED },
        )
    }

    @Test
    fun sendConfirmsAServerIdThenDrivesTheLadderOnIt() = runTest {
        val transport = makeTransport("people")
        transport.start()
        advanceUntilIdle()
        transport.events.drain() // discard the seed
        transport.send(ChatCommand.SendMessage(text = "Are you around?", replyTo = null, localID = "user-1"))
        advanceUntilIdle()
        val events = transport.events.drain()
        transport.stop()

        val serverID = events.filterIsInstance<ChatEvent.MessageIDConfirmed>()
            .firstOrNull { it.localID == "user-1" }?.serverID
            ?: error("expected a messageIDConfirmed for the sent localID")
        assertTrue("the demo mints a srv-* server id", serverID.startsWith("srv-"))

        val statusIDs = events.filterIsInstance<ChatEvent.MessageStatusChanged>().map { it.itemID }
        assertFalse("the delivery ladder runs", statusIDs.isEmpty())
        assertTrue("the ladder targets the server id, not the optimistic id", statusIDs.all { it == serverID })
        assertTrue(
            "the peer's read watermark targets the server id",
            events.any { it is ChatEvent.MessageStatusWatermark && it.status == MessageStatus.READ && it.upToItemID == serverID },
        )
    }

    @Test
    fun reactionEditDeleteAreEchoed() = runTest {
        val transport = makeTransport("people")
        transport.start()
        advanceUntilIdle()
        transport.events.drain() // discard the seed
        transport.send(ChatCommand.ToggleReaction(itemID = "seed-1", emoji = thumbsUp, add = true))
        transport.send(ChatCommand.EditMessage(itemID = "seed-3", newText = "changed"))
        transport.send(ChatCommand.DeleteMessage(itemID = "seed-3"))
        advanceUntilIdle()
        val events = transport.events.drain()
        transport.stop()

        assertTrue(events.any { it is ChatEvent.ReactionsChanged && it.reactions.firstOrNull()?.mine == true })
        assertTrue(events.any { it is ChatEvent.MessageEdited && it.newText == "changed" })
        assertTrue(events.any { it is ChatEvent.MessageDeleted && it.itemID == "seed-3" })
    }

    // Not a Swift port: the A4 acceptance is "LocalP2P at stepMs 0 is byte-deterministic across runs". Two fresh
    // transports must emit an identical seed (same events, same order, same timestamps) for both scenarios.
    @Test
    fun seedIsDeterministicAcrossRuns() = runTest {
        for (scenario in listOf("people", "group")) {
            val first = makeTransport(scenario)
            first.start(); advanceUntilIdle()
            val a = first.events.drain(); first.stop()

            val second = makeTransport(scenario)
            second.start(); advanceUntilIdle()
            val b = second.events.drain(); second.stop()

            assertEquals("the $scenario seed must be identical across runs", a, b)
        }
    }

    @Test
    fun pagingServesFiftyPerPageAndTerminates() = runTest {
        val transport = makeTransport("people")
        transport.start()
        advanceUntilIdle()
        transport.events.drain() // discard the seed

        var totalItems = 0
        var pages = 0
        var lastHasMore = true
        while (lastHasMore && pages < 10) {
            transport.send(ChatCommand.LoadEarlier(beforeItemID = "seed-1", limit = 50))
            advanceUntilIdle()
            val page = transport.events.drain().filterIsInstance<ChatEvent.HistoryPage>().firstOrNull()
                ?: run { transport.stop(); error("expected a history page") }
            totalItems += page.items.size
            lastHasMore = page.hasMore
            pages++
        }
        transport.stop()

        assertEquals("the 200-item synthetic history is fully served", 200, totalItems)
        assertFalse("paging terminates (hasMore=false on the last page)", lastHasMore)
        assertEquals("200 / 50 = 4 pages", 4, pages)
    }
}
