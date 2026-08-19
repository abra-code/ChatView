package com.abracode.chatview

// A3 fixture (a) interop gate (plan section 8). Every Fixtures/transcript-*.json emitted by the Swift side must
// decode in Kotlin and re-encode to a SEMANTICALLY identical document, and the decode must be round-trip stable.
//
// - PRIMARY: assertJsonSemanticallyEqual (numeric-normalizing tree compare) against the Swift golden - applies to
//   all four goldens. This tolerates the Swift-whole-Double vs Kotlin-800.0 rendering difference by design.
// - SECONDARY: round-trip stability (decode -> encode -> decode == first decode).
// - STRICT (Double-free goldens only): canonical sorted-keys string equality, to catch key-spelling drift with byte
//   precision. transcript-mixed-agentic carries Double-typed model fields (ChatImage pixels, UsageInfo cost), which
//   Swift renders as `800` and Kotlin as `800.0`, so the strict check is applied to the other three goldens only
//   (judged by model types per section 8; their ChatFile.progress / image pixels are absent, so no Double renders).

import kotlinx.serialization.json.JsonElement
import org.junit.Assert.assertEquals
import org.junit.Test

class FixtureTranscriptInteropTest {

    private val doubleFreeGoldens = listOf(
        "transcript-v1-minimal.json",
        "transcript-v2-people.json",
        "transcript-v2-group.json",
        // The session-marker golden. Kotlin did not know `sessionEvent` at all, so every conversation the current
        // macOS host writes failed to decode here - and no other golden carries one, which is why the gate could not
        // see it. Double-free by construction, so it gets the strict canonical-string check.
        "transcript-session-event.json",
    )
    private val doubleBearingGoldens = listOf(
        "transcript-mixed-agentic.json",
    )

    private fun decode(text: String): ChatTranscript = chatJson.decodeFromString(ChatTranscript.serializer(), text)
    private fun reencode(transcript: ChatTranscript): JsonElement =
        chatJson.encodeToJsonElement(ChatTranscript.serializer(), transcript)

    private fun assertInteropGate(name: String, strictString: Boolean) {
        val goldenText = readFixture(name)
        val golden = chatJson.parseToJsonElement(goldenText)

        // PRIMARY: decode + re-encode is semantically identical to the golden.
        val decoded = decode(goldenText)
        val reencoded = reencode(decoded)
        assertJsonSemanticallyEqual(golden, reencoded, "$name:$")

        // SECONDARY: round-trip stability.
        val decodedAgain = decode(chatJson.encodeToString(ChatTranscript.serializer(), decoded))
        assertEquals("$name: round-trip is not stable", decoded, decodedAgain)

        // STRICT: byte-level canonical equality where the golden carries no Double-typed model field.
        if (strictString) {
            assertEquals(
                "$name: canonical sorted-keys re-encode drifted from the golden",
                canonicalJson(golden),
                canonicalJson(reencoded),
            )
        }
    }

    @Test
    fun doubleFreeGoldensPassStrictInteropGate() {
        for (name in doubleFreeGoldens) {
            assertInteropGate(name, strictString = true)
        }
    }

    @Test
    fun doubleBearingGoldensPassSemanticInteropGate() {
        for (name in doubleBearingGoldens) {
            assertInteropGate(name, strictString = false)
        }
    }

    /**
     * The lossy-decode parity gate. `lossy-unreadable-items.json` is the one fixture whose input is deliberately
     * unreadable: an item with no `type` (the exact shape that cost a real user a conversation), a type from the
     * future, a known type over an unreadable payload, a `type` that is not a string at all, elements that are not
     * objects at all, and a real item named like a placeholder. Both platforms must make the SAME transcript of it - same number of items, same order,
     * same placeholder ids, same wording - or a conversation reads differently on the two, or opens on one and not
     * the other. `.expected.json` is the Apple decoder's own output (emitted by FixtureEmitterTests).
     *
     * It is deliberately NOT named `transcript-*`: goldens under that prefix must re-encode to their own bytes, and
     * this one cannot - a placeholder encodes as an ordinary error row, which is exactly why a host must never
     * persist a decoded transcript back over its source.
     */
    @Test
    fun unreadableItemsDecodeToTheCommittedPlaceholders() {
        val decoded = decode(readFixture("lossy-unreadable-items.json"))
        assertEquals("every element must cost exactly one slot", 12, decoded.items.size)
        assertEquals(9, decoded.unreadableItemCount)
        val expected = chatJson.parseToJsonElement(readFixture("lossy-unreadable-items.expected.json"))
        assertEquals(
            "the placeholders drifted from the committed cross-platform expectation",
            canonicalJson(expected),
            canonicalJson(reencode(decoded)),
        )
    }
}
