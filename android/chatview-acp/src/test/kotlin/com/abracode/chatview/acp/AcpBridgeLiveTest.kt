package com.abracode.chatview.acp

// The Kotlin twin of Tests/ACPBridgeTests/BridgeTransportIntegrationTests.swift: the real transport, over a real
// OkHttp WebSocket, against a REAL chatview-acp-bridge. The scripted-bridge suites prove the client matches the
// wire spec as written; this proves the spec as IMPLEMENTED, which is the only way a fake can be caught drifting.
//
// Opt-in, because it needs a bridge running (and the bridge is a macOS binary):
//
//   ./Scripts/run-bridge-demo.sh                  # in one terminal
//   CHATVIEW_BRIDGE_URL=ws://127.0.0.1:8737/acp \
//   CHATVIEW_BRIDGE_TOKEN=demo-token-please-do-not-reuse \
//     ./gradlew :chatview-acp:testDebugUnitTest --tests "*AcpBridgeLiveTest*"
//
// Without those variables every test here is skipped, so the ordinary suite stays hermetic.

import com.abracode.chatview.ChatCommand
import com.abracode.chatview.ChatEvent
import com.abracode.chatview.ChatTransportConfig
import kotlinx.coroutines.runBlocking
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Assume.assumeTrue
import org.junit.Test

class AcpBridgeLiveTest {

    private val url: String? = System.getenv("CHATVIEW_BRIDGE_URL")
    private val token: String = System.getenv("CHATVIEW_BRIDGE_TOKEN") ?: ""

    private fun makeTransport(session: String, resumeAfterSeq: Int? = null): Pair<AcpRemoteTransport, EventCollector> {
        val settings = buildJsonObject {
            put("url", url!!)
            put("token", token)
            put("session", session)
            if (resumeAfterSeq != null) {
                put("resumeAfterSeq", resumeAfterSeq)
            }
        }
        val transport = AcpRemoteTransport(
            config = ChatTransportConfig(protocolName = "acp-remote", settings = settings),
            logger = RecordingLogger(),
        )
        val collector = EventCollector()
        collector.start(transport)
        return transport to collector
    }

    /** Answers any permission the agent raises, so a turn that gates a tool call still completes. */
    private fun answerPermissions(transport: AcpRemoteTransport, collector: EventCollector) = runBlocking {
        for (event in collector.events()) {
            if (event is ChatEvent.PermissionRequestEvent) {
                val allow = event.request.options.firstOrNull { it.kind.allows } ?: continue
                transport.send(ChatCommand.PermissionResponse(event.request.id, allow.id))
            }
        }
    }

    @Test
    fun liveBridge_turnStreamsAndCheckpointsAtItsBoundary() = runBlocking {
        assumeTrue("set CHATVIEW_BRIDGE_URL to run the live bridge test", url != null)
        val (transport, collector) = makeTransport("new")
        try {
            transport.start()
            collector.waitFor("connected", 15_000) { collector.log().contains("state:connected") }
            assertTrue(
                "the bridge announces the agent it is fronting",
                collector.events().filterIsInstance<ChatEvent.SessionInfo>().isNotEmpty(),
            )

            transport.send(ChatCommand.Prompt("hello from the Kotlin client"))
            // The scripted agent gates a tool call on some turns; answer whatever it asks so the turn can finish.
            collector.waitFor("the turn to end", 60_000) {
                answerPermissions(transport, collector)
                collector.log().any { it.startsWith("end:") && !it.endsWith(":-") }
            }
            assertTrue(
                "a turn boundary is a checkpoint moment - that is what a cold launch resumes from",
                collector.log().any { it.startsWith("checkpoint:") },
            )
        } finally {
            transport.stop()
            collector.stop()
        }
    }

    @Test
    fun liveBridge_secondClientReplaysTheSameTranscriptWithTheSameIds() = runBlocking {
        assumeTrue("set CHATVIEW_BRIDGE_URL to run the live bridge test", url != null)
        val (first, firstEvents) = makeTransport("new")
        val sessionID: String
        try {
            first.start()
            firstEvents.waitFor("connected", 15_000) { firstEvents.log().contains("state:connected") }
            sessionID = firstEvents.events().filterIsInstance<ChatEvent.SessionReady>().first().sessionID

            first.send(ChatCommand.Prompt("a turn worth replaying"))
            firstEvents.waitFor("the turn to end", 60_000) {
                answerPermissions(first, firstEvents)
                firstEvents.log().any { it.startsWith("end:") && !it.endsWith(":-") }
            }
        } finally {
            first.stop()
        }

        // A second device attaching from zero must rebuild the SAME transcript, item id for item id: the ids are
        // pure functions of the bridge's log, which is what makes a host's id-keyed journal survive a relaunch.
        val (second, secondEvents) = makeTransport(sessionID)
        try {
            second.start()
            secondEvents.waitFor("the replay", 30_000) {
                secondEvents.log().any { it.startsWith("end:") }
            }
            val original = firstEvents.log().filter { it.startsWith("start:") || it.startsWith("thought:") }
            val replayed = secondEvents.log().filter { it.startsWith("start:") || it.startsWith("thought:") }
            assertTrue("the first client saw something to compare against", original.isNotEmpty())
            assertEquals(
                "the replay must regenerate the same ids in the same order",
                original.filter { !it.endsWith(":local") },
                replayed.filter { !it.endsWith(":local") },
            )
        } finally {
            second.stop()
            firstEvents.stop()
            secondEvents.stop()
        }
    }
}
