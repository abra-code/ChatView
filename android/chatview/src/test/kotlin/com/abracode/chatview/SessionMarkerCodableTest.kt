package com.abracode.chatview

// The `sessionEvent` transcript item: the marker a host writes when a conversation is started, resumed, or handed to
// a different model. Kotlin did not know the type at all, so every conversation the current macOS app writes was
// already undecodable here - the item threw, and the whole transcript went with it.
//
// The wire shape is the Swift Codable's, and these tests pin the two halves that are easy to get subtly wrong:
// the digest's four arrays are REQUIRED on the wire (Swift declares them non-optional, so its decoder demands them
// and its encoder always writes them, empty or not), and the `kind` vocabulary is spelled started / resumed /
// modelChanged.

import kotlinx.serialization.SerializationException
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class SessionMarkerCodableTest {

    private fun fullDigest() = SessionDigest(
        summarizer = "mlx-community/Qwen3-4B",
        droppedTurns = 64,
        verbatimTurns = 6,
        unresolvedIntent = "finish the Android port",
        establishedFacts = listOf("the transcript format is frozen"),
        decisions = listOf("mirror the Swift decoder"),
        openThreads = listOf("rendering the marker"),
        userPreferences = listOf("ASCII only"),
    )

    @Test
    fun aSessionMarkerRoundTripsInsideATranscript() {
        val transcript = ChatTranscript(
            version = 1,
            items = listOf(
                ChatItem.Message(ChatMessage(id = "u1", role = ChatRole.LOCAL, text = "hi", isStreaming = false)),
                ChatItem.SessionEventItem(
                    SessionEvent(
                        id = "session-1",
                        kind = SessionEvent.Kind.RESUMED,
                        timestamp = "2026-08-18T21:56:33Z",
                        model = "Qwen3-30B",
                        digest = fullDigest(),
                    ),
                ),
            ),
        )
        val text = chatJson.encodeToString(ChatTranscript.serializer(), transcript)
        assertEquals(transcript, chatJson.decodeFromString(ChatTranscript.serializer(), text))
    }

    /** The discriminator and its payload key are the frozen contract: `type: sessionEvent` + a `sessionEvent` wrapper. */
    @Test
    fun theEncodedShapeMatchesTheSwiftCodingKeys() {
        val item: ChatItem = ChatItem.SessionEventItem(SessionEvent(id = "s1", kind = SessionEvent.Kind.STARTED))
        val obj = chatJson.encodeToJsonElement(ChatItemSerializer, item).jsonObject
        assertEquals("sessionEvent", obj["type"]?.jsonPrimitive?.content)
        val payload = obj["sessionEvent"]!!.jsonObject
        assertEquals("nothing optional is written when it is absent", setOf("id", "kind"), payload.keys)
        assertEquals("s1", payload["id"]?.jsonPrimitive?.content)
        assertEquals("started", payload["kind"]?.jsonPrimitive?.content)
    }

    @Test
    fun theKindVocabularyIsTheSwiftOne() {
        fun wire(kind: SessionEvent.Kind): String =
            chatJson.encodeToJsonElement(SessionEvent.serializer(), SessionEvent(id = "s", kind = kind))
                .jsonObject["kind"]!!.jsonPrimitive.content
        assertEquals("started", wire(SessionEvent.Kind.STARTED))
        assertEquals("resumed", wire(SessionEvent.Kind.RESUMED))
        assertEquals("modelChanged", wire(SessionEvent.Kind.MODEL_CHANGED))
    }

    /**
     * SWIFT WRITES ALL FOUR ARRAYS ALWAYS, EMPTY OR NOT, because they are non-optional there. Omitting them under
     * `encodeDefaults = false` would emit documents the Apple decoder rejects outright - and rejecting a digest
     * rejects the item, which is exactly the class of loss this whole change is about.
     */
    @Test
    fun theDigestArraysAreWrittenEvenWhenEmpty() {
        val obj = chatJson.encodeToJsonElement(SessionDigest.serializer(), SessionDigest()).jsonObject
        assertEquals(setOf("establishedFacts", "decisions", "openThreads", "userPreferences"), obj.keys)
    }

    /** And the mirror of that: they are REQUIRED on decode, as Swift's non-optional arrays are. */
    @Test
    fun aDigestMissingOneOfTheRequiredArraysIsRejected() {
        val partial = """{"establishedFacts":[],"decisions":[],"openThreads":[]}"""
        val thrown = runCatching { chatJson.decodeFromString(SessionDigest.serializer(), partial) }.exceptionOrNull()
        assertTrue("expected a decode failure, got $thrown", thrown is SerializationException)
        assertTrue("the message must name the missing field; got: ${thrown?.message}",
            thrown?.message?.contains("userPreferences") == true)
    }

    /** A marker with neither model nor digest is the commonest one, and it must not need either. */
    @Test
    fun theOptionalHalvesStayOptional() {
        val decoded = chatJson.decodeFromString(
            SessionEvent.serializer(),
            """{"id":"s1","kind":"started"}""",
        )
        assertEquals("s1", decoded.id)
        assertNull(decoded.timestamp)
        assertNull(decoded.model)
        assertNull(decoded.digest)
        assertEquals("""{"id":"s1","kind":"started"}""",
            chatJson.encodeToString(SessionEvent.serializer(), decoded))
    }

    @Test
    fun anEmptyDigestKnowsItIsEmpty() {
        assertTrue(SessionDigest().isEmpty)
        assertTrue(SessionDigest(summarizer = "a model", droppedTurns = 3).isEmpty)
        assertTrue(!SessionDigest(decisions = listOf("one")).isEmpty)
        assertNotNull(fullDigest())
        assertTrue(!fullDigest().isEmpty)
    }
}
