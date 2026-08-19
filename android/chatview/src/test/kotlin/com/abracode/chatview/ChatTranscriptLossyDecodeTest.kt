package com.abracode.chatview

// Port of Tests/ChatViewTests/ChatTranscriptTests.swift's ChatTranscriptLossyDecodeTests and
// ChatStoreUnreadableItemLoggingTests.
//
// One unreadable item must cost ONE LINE, not the conversation. ChatItem's decoder throws on a type it does not
// recognize, and `items` used to decode as one list, so a single bad element failed the whole transcript - which
// ChatTranscript.decode then swallowed with runCatching. The restore became a silent no-op: no items, no error, no
// log. That is how a real user lost a conversation on the Apple side, and the same structure was still here.
//
// The elements below are deliberately NOT all objects: a bad element can be a bare string, a number, a boolean, null
// or a nested array, and "does the list still advance" is a real question for each - every element must cost exactly
// one slot or the items after it shift and the conversation silently reorders.

import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.addJsonObject
import kotlinx.serialization.json.buildJsonArray
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put
import kotlinx.serialization.json.putJsonArray
import kotlinx.serialization.json.putJsonObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class ChatTranscriptLossyDecodeTest {

    private fun transcript(items: List<JsonElement>): ChatTranscript? = ChatTranscript.decode(
        buildJsonObject {
            put("version", 1)
            put("items", JsonArray(items))
        },
    )

    private fun message(id: String, role: String, text: String): JsonObject = buildJsonObject {
        put("type", "message")
        putJsonObject("message") {
            put("id", id)
            put("role", role)
            put("text", text)
        }
    }

    private val good = message("m0", "local", "hello")
    private val alsoGood = message("m1", "agent", "hi")

    /**
     * THE EXACT SHAPE THAT COST A USER A CONVERSATION: ChatView's own condense marker, written with the payload at
     * the top level and no `type` discriminator. One of these used to fail the whole transcript.
     */
    @Test
    fun theItemThatUsedToDestroyAConversationNowCostsOneLine() {
        val bare = buildJsonObject {
            put("id", "condense-1")
            put("kind", "resumed")
            put("timestamp", "2026-08-18T21:56:33Z")
        }
        val restored = transcript(listOf(good, bare, alsoGood))
        assertNotNull("the transcript must decode, not vanish", restored)
        assertEquals("the readable items must all survive", 3, restored!!.items.size)
        assertEquals(
            "in place, so the conversation still reads in order",
            listOf("m0", "unreadable-item-1", "m1"),
            restored.items.map { it.id },
        )
        assertEquals(1, restored.unreadableItemCount)
    }

    /** Visible, not silent. A dropped line the reader is never told about is the failure mode this change removes. */
    @Test
    fun theReplacementIsAVisibleErrorNamingWhatCouldNotBeRead() {
        val unknown = buildJsonObject {
            put("type", "somethingFromTheFuture")
            putJsonObject("payload") { put("a", 1) }
        }
        val restored = transcript(listOf(good, unknown))!!
        val last = restored.items.last()
        assertTrue("an unreadable item must become an error row, which renders in red", last is ChatItem.Error)
        val text = (last as ChatItem.Error).text
        assertTrue("got: $text", text.contains("could not be read"))
        assertTrue("the message must name the type that could not be read; got: $text",
            text.contains("somethingFromTheFuture"))
    }

    @Test
    fun anItemWithNoTypeAtAllStillGetsAPlaceholder() {
        val restored = transcript(listOf(buildJsonObject { put("nothing", "useful") }))!!
        val first = restored.items.first()
        assertTrue("expected a placeholder", first is ChatItem.Error)
        assertEquals("a positional id when the item carried none", "unreadable-item-0", first.id)
        val text = (first as ChatItem.Error).text
        assertTrue("got: $text", text.contains("no type given"))
    }

    /** A `type` that is present but not a string names nothing, exactly as Swift's String? probe reports nothing. */
    @Test
    fun aNonStringTypeIsReportedAsNoTypeGiven() {
        val restored = transcript(listOf(buildJsonObject { put("type", 7) }))!!
        val text = (restored.items.first() as ChatItem.Error).text
        assertEquals("This entry could not be read (no type given).", text)
    }

    /**
     * A `type` that is an object or an array is the shape that would slip past a "simplification" of the probe to
     * `.jsonPrimitive` - and it would throw INSIDE the substitution loop, outside the per-element runCatching,
     * taking the whole conversation with it. It must name nothing and cost one row, like any other unusable type.
     */
    @Test
    fun aStructuredTypeIsReportedAsNoTypeGiven() {
        val restored = transcript(listOf(
            buildJsonObject { putJsonObject("type") { put("nested", true) } },
            buildJsonObject { put("type", buildJsonArray { add(JsonPrimitive("message")) }) },
            good,
        ))!!
        assertEquals(3, restored.items.size)
        assertEquals(2, restored.unreadableItemCount)
        assertEquals("This entry could not be read (no type given).", (restored.items[0] as ChatItem.Error).text)
        assertEquals("This entry could not be read (no type given).", (restored.items[1] as ChatItem.Error).text)
        assertEquals("m0", restored.items.last().id)
    }

    /** Several bad items must not collapse into one row, and their ids must stay distinct. */
    @Test
    fun severalUnreadableItemsKeepDistinctIdentities() {
        val restored = transcript(listOf(
            buildJsonObject { put("a", 1) },
            buildJsonObject { put("b", 2) },
            good,
        ))!!
        assertEquals(3, restored.items.size)
        assertEquals(2, restored.unreadableItemCount)
        assertEquals("ids must be unique", 3, restored.items.map { it.id }.toSet().size)
    }

    /** A conversation of nothing but unreadable items is still a conversation that opens. */
    @Test
    fun aTranscriptOfOnlyUnreadableItemsStillDecodes() {
        val restored = transcript(listOf(buildJsonObject { put("a", 1) }))
        assertNotNull("decoding must not fail even when nothing is readable", restored)
        assertEquals(1, restored!!.items.size)
    }

    /**
     * Not every bad element is an object. Each must still consume exactly one slot, or the items after it shift and
     * the conversation silently reorders.
     */
    @Test
    fun nonObjectElementsEachCostExactlyOneSlot() {
        val restored = transcript(listOf(
            good,
            JsonPrimitive("a bare string"),
            JsonPrimitive(42),
            JsonPrimitive(true),
            JsonNull,
            buildJsonArray { add(JsonPrimitive(1)); add(JsonPrimitive(2)) },
            alsoGood,
        ))!!
        assertEquals("every element must occupy its own slot", 7, restored.items.size)
        assertEquals(5, restored.unreadableItemCount)
        assertEquals("m0", restored.items.first().id)
        assertEquals("the good item after them must not shift", "m1", restored.items.last().id)
        assertEquals(
            listOf("unreadable-item-1", "unreadable-item-2", "unreadable-item-3", "unreadable-item-4",
                   "unreadable-item-5"),
            restored.items.drop(1).dropLast(1).map { it.id },
        )
    }

    /** The commonest real failure: a type the reader knows, carrying a payload it cannot read. */
    @Test
    fun aKnownTypeWithAnUnreadablePayloadIsNamedByItsType() {
        val deep = buildJsonObject {
            put("type", "message")
            putJsonObject("message") { put("id", 123) }
        }
        val restored = transcript(listOf(good, deep))!!
        val last = restored.items.last() as ChatItem.Error
        assertEquals("unreadable-item-1", last.id)
        assertEquals("This entry could not be read (type \"message\").", last.text)
    }

    /**
     * THE COLLISION THAT DROPS LIVE UPDATES. An entry envelope carries `id` at the top level - the shape a host is
     * handed to persist - so a host restoring one by mistake would have given the placeholder the real message's id.
     * Every mutation path finds items by id, so the live turn's status updates would land on the placeholder.
     */
    @Test
    fun aPlaceholderNeverStealsARealItemsIdentity() {
        val envelope = buildJsonObject {
            put("sequence", 1)
            put("type", "message")
            put("id", "user-1")
            put("data", message("user-1", "local", "hi"))
        }
        val restored = transcript(listOf(envelope, message("user-1", "local", "hi")))!!
        assertEquals(2, restored.items.size)
        assertEquals("the placeholder must not take the id of the message that follows it",
            2, restored.items.map { it.id }.toSet().size)
        assertEquals("the real message keeps its own id", "user-1", restored.items.last().id)
    }

    /** And it must not take an id from a real item that happens to be named like a placeholder. */
    @Test
    fun aPlaceholderStepsAsideForARealItemNamedLikeOne() {
        val impostor = buildJsonObject {
            put("type", "system")
            put("id", "unreadable-item-0")
            put("text", "a genuine system line")
        }
        val restored = transcript(listOf(buildJsonObject { put("nothing", "useful") }, impostor))!!
        assertEquals(2, restored.items.map { it.id }.toSet().size)
        assertEquals("the real item keeps the name", "unreadable-item-0", restored.items.last().id)
        assertEquals("the bump format is part of the cross-platform contract",
            "unreadable-item-0-1", restored.items.first().id)
    }

    /**
     * EQUALITY MUST IGNORE THE DECODE DIAGNOSTICS. ChatStore dedups restores with `==`; if the counts participate, a
     * repaired transcript differs from the damaged one by the counts alone, the dedup sees a change that is not
     * there, and re-applying discards a turn that arrived in between.
     */
    @Test
    fun theDecodeDiagnosticsAreNotPartOfEquality() {
        val damaged = transcript(listOf(good, buildJsonObject { put("nothing", "useful") }))!!
        val repaired = transcript(listOf(
            good,
            buildJsonObject {
                put("type", "error")
                put("id", "unreadable-item-1")
                put("text", "This entry could not be read (no type given).")
            },
        ))!!
        assertEquals("same items", damaged.items, repaired.items)
        assertEquals(1, damaged.unreadableItemCount)
        assertEquals("different diagnostics", 0, repaired.unreadableItemCount)
        assertEquals("yet equal, or the restore dedup re-applies and wipes a turn", damaged, repaired)
        assertEquals("and hashCode must agree with equals", damaged.hashCode(), repaired.hashCode())
    }

    /**
     * BOTH diagnostics, not just the count. A restore whose `plan` could not be read, followed by the repaired
     * transcript with the bad key gone, differs ONLY in `unreadableFields` - and if that difference reaches
     * equality, ChatStore's restore dedup re-applies a transcript that has not changed and discards whatever turn
     * arrived in between.
     */
    @Test
    fun theLostFieldListIsNotPartOfEqualityEither() {
        val damaged = ChatTranscript.decode(buildJsonObject {
            put("version", 1)
            put("items", JsonArray(listOf(good)))
            put("plan", "not a plan")
        })!!
        val repaired = ChatTranscript.decode(buildJsonObject {
            put("version", 1)
            put("items", JsonArray(listOf(good)))
        })!!
        assertEquals(listOf("plan"), damaged.unreadableFields)
        assertEquals(emptyList<String>(), repaired.unreadableFields)
        assertEquals("same conversation, same surfaces", damaged.items, repaired.items)
        assertEquals("yet equal, or the restore dedup re-applies and wipes a turn", damaged, repaired)
        assertEquals("and hashCode must agree with equals", damaged.hashCode(), repaired.hashCode())
    }

    /** The diagnostics describe a decode, not a conversation, so they must never reach the wire. */
    @Test
    fun theDecodeDiagnosticsNeverRoundTrip() {
        val damaged = transcript(listOf(good, buildJsonObject { put("nothing", "useful") }))!!
        val encoded = chatJson.encodeToString(ChatTranscript.serializer(), damaged)
        assertFalse(encoded.contains("unreadableItemCount"))
        assertFalse(encoded.contains("unreadableFields"))
        assertEquals("a re-read of the rendered transcript reports nothing unreadable",
            0, chatJson.decodeFromString(ChatTranscript.serializer(), encoded).unreadableItemCount)
    }

    /** The same failure one key over: a side surface that will not decode must cost that surface, not the chat. */
    @Test
    fun aMalformedSideSurfaceDoesNotCostTheConversation() {
        val restored = ChatTranscript.decode(buildJsonObject {
            put("version", 1)
            put("items", JsonArray(listOf(good, alsoGood)))
            put("plan", buildJsonArray {
                add(buildJsonObject {
                    put("id", 1)
                    put("content", "x")
                    put("status", "fromTheFuture")
                })
            })
        })
        assertNotNull("a plan this version cannot read must not drop the conversation with it", restored)
        assertEquals(2, restored!!.items.size)
        assertEquals(emptyList<PlanEntry>(), restored.plan)
        assertEquals(listOf("plan"), restored.unreadableFields)
    }

    /** A title that is not a string is a lost surface, not a stringified number and not a lost conversation. */
    @Test
    fun aMalformedTitleCostsOnlyTheTitle() {
        val restored = ChatTranscript.decode(buildJsonObject {
            put("version", 1)
            put("items", JsonArray(listOf(good)))
            put("title", 7)
        })!!
        assertEquals(1, restored.items.size)
        assertNull(restored.title)
        assertEquals(listOf("title"), restored.unreadableFields)
    }

    @Test
    fun everyLostSideSurfaceNamesItselfInReadOrder() {
        val restored = ChatTranscript.decode(buildJsonObject {
            put("version", 1)
            put("items", JsonArray(listOf(good)))
            put("usage", "not usage")
            put("plan", "not a plan")
            put("title", 7)
            put("participants", "not participants")
        })!!
        assertEquals(listOf("usage", "plan", "title", "participants"), restored.unreadableFields)
        assertEquals("the conversation itself is untouched", 1, restored.items.size)
    }

    /** Lossiness is confined to `items`. A malformed transcript is still a malformed transcript. */
    @Test
    fun aValueThatIsNotATranscriptAtAllIsStillRejected() {
        assertNull(ChatTranscript.decode("not json"))
        assertNull(ChatTranscript.decode(buildJsonObject {
            put("version", 1)
            put("items", "not an array")
        }))
    }

    /**
     * The reason this was urgent rather than theoretical: the macOS host writes a session marker into every
     * conversation it starts, resumes, or hands to another model, and Kotlin did not know the type at all. It must
     * now decode as itself, not as a placeholder.
     */
    @Test
    fun aSessionMarkerIsReadAsItselfNotReplaced() {
        val marker = buildJsonObject {
            put("type", "sessionEvent")
            putJsonObject("sessionEvent") {
                put("id", "session-1")
                put("kind", "resumed")
                put("timestamp", "2026-08-18T21:56:33Z")
            }
        }
        val restored = transcript(listOf(good, marker, alsoGood))!!
        assertEquals(0, restored.unreadableItemCount)
        val item = restored.items[1]
        assertTrue("expected a session marker, got $item", item is ChatItem.SessionEventItem)
        assertEquals(SessionEvent.Kind.RESUMED, (item as ChatItem.SessionEventItem).event.kind)
    }
}

/**
 * A logger that keeps what it was told. Every other logger in these suites discards its input, which is why the
 * store's half of the unreadable-item handling had no coverage: the warning is the only thing it does, and nothing
 * could observe it.
 */
private class CapturingLogger : ChatLogger {
    val lines = mutableListOf<String>()
    override fun log(message: String, level: ChatLogLevel) {
        lines.add("[$level] $message")
    }
}

class ChatStoreUnreadableItemLoggingTest {

    private fun store(logger: ChatLogger, source: FakeContentSource): ChatStore = ChatStore(
        config = ChatConfiguration(),
        logger = logger,
        contentSource = source,
        scheduler = ManualChatScheduler(),
        scope = inertScope(),
    )

    private fun damagedContent() = buildJsonObject {
        put("version", 1)
        putJsonArray("items") {
            addJsonObject {
                put("type", "message")
                putJsonObject("message") {
                    put("id", "m0")
                    put("role", "local")
                    put("text", "hi")
                }
            }
            addJsonObject {
                put("id", "condense-1")
                put("kind", "resumed")
            }
        }
    }

    /**
     * The placeholder rows tell the person reading the conversation. This tells whoever has to find out why - and it
     * is the reason a damaged restore is no longer indistinguishable from silence.
     */
    @Test
    fun restoringATranscriptWithUnreadableItemsIsReported() {
        val logger = CapturingLogger()
        val source = FakeContentSource()
        val chatStore = store(logger, source)
        chatStore.start()

        source.content = damagedContent()

        assertEquals("the conversation still opens", 2, chatStore.items.size)
        val warnings = logger.lines.filter { it.contains("unreadable item") }
        assertEquals("exactly one report; got: ${logger.lines}", 1, warnings.size)
        assertTrue("got: ${warnings[0]}", warnings[0].contains("WARNING"))
        assertTrue("the count belongs in it; got: ${warnings[0]}", warnings[0].contains("1 "))
    }

    @Test
    fun aCleanRestoreSaysNothing() {
        val logger = CapturingLogger()
        val source = FakeContentSource()
        val chatStore = store(logger, source)
        chatStore.start()

        source.content = ChatTranscript(
            items = listOf(ChatItem.Message(ChatMessage(id = "m0", role = ChatRole.LOCAL, text = "hi", isStreaming = false))),
        )

        assertEquals(1, chatStore.items.size)
        assertTrue("a clean restore must be quiet; got: ${logger.lines}",
            logger.lines.none { it.contains("unreadable") })
    }
}
