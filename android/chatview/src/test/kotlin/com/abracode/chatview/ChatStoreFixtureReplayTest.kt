package com.abracode.chatview

// The Kotlin side of the fixture-scenario replay gate (plan section 8, Fixtures/README.md). Decodes each committed
// scenario-NN.events.jsonl with the test-only event codec, routes it through a fresh ChatStore synchronously (no
// clock advance - coalesced flushes apply immediately on messageEnd, timers never fire), snapshots the resulting
// transcript, and asserts it matches the committed scenario-NN.expected.json. This proves the Kotlin store's routing
// reproduces the same final state a live Swift ChatStore does, byte-for-byte where no Double-typed field is present.

import kotlinx.serialization.json.intOrNull
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class ChatStoreFixtureReplayTest {

    // Scenarios whose final transcript carries Double-typed model fields (UsageInfo.costAmount, ChatFile.progress):
    // a Swift whole Double renders as `1` and the Kotlin re-encode as `1.0`, so these get the numeric-normalizing
    // compare only; every other scenario additionally gets strict sorted-key canonical-string equality.
    private val doubleBearing = setOf("scenario-04-plan-usage", "scenario-14-file-progress")

    @Test
    fun scenarioReplaysMatchExpected() {
        val streams = fixturesDir().listFiles { file -> file.name.endsWith(".events.jsonl") }
            ?.sortedBy { it.name }.orEmpty()
        assertTrue("no scenario fixtures found", streams.isNotEmpty())

        for (streamFile in streams) {
            val base = streamFile.name.removeSuffix(".events.jsonl")
            val events = streamFile.readText(Charsets.UTF_8).lineSequence()
                .filter { it.isNotBlank() }
                .map { FixtureEventCodec.decode(chatJson.parseToJsonElement(it).jsonObject) }
                .toList()

            val expectedText = readFixture("$base.expected.json").trim()
            val expectedElement = chatJson.parseToJsonElement(expectedText)
            val version = expectedElement.jsonObject["version"]?.jsonPrimitive?.intOrNull ?: 1

            val store = ChatStore(
                config = ChatConfiguration(),
                logger = noopLogger(),
                scheduler = ManualChatScheduler(),
                scope = inertScope(),
            )
            events.forEach { store.route(it) }

            val snapshot = ChatTranscript(
                version = version,
                items = store.items,
                usage = store.usage,
                plan = store.plan,
                title = store.title,
                participants = store.participants.ifEmpty { null },
            )
            val actualElement = chatJson.encodeToJsonElement(ChatTranscript.serializer(), snapshot)

            assertJsonSemanticallyEqual(expectedElement, actualElement, base)
            if (base !in doubleBearing) {
                assertEquals("$base: canonical bytes differ", canonicalJson(expectedElement), canonicalJson(actualElement))
            }
        }
    }
}
