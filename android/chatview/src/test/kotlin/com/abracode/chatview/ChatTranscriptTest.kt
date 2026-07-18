package com.abracode.chatview

// Port of Tests/ChatViewTests/ChatTranscriptTests.swift.
//
// Tests for the P0-2 session-transcript seam: the transcript's Codable format (round-trip + a pinned JSON shape),
// the incremental entry-event firing (once per finalized entry, correct monotonic sequence, never on deltas),
// restoring a transcript into the content source then appending a live turn, and the readOnly / properties.content
// config parsing. Combines the four Swift XCTestCase classes (ChatTranscriptCodableTests, ChatTranscriptSeamTests,
// ChatTranscriptConfigTests, ChatContentRestoreTests) into one JUnit4 class; the shared fakes (FakeContentSource,
// EntrySink, CapturedEntry) live in TestSupport.kt.

import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.addJsonObject
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put
import kotlinx.serialization.json.putJsonArray
import kotlinx.serialization.json.putJsonObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class ChatTranscriptTest {

    // MARK: - Shared store helper (mirrors both Swift `makeStore` variants: the seam tests' sourceless one and the
    // content-restore tests' one that takes a FakeContentSource).

    private fun makeStore(
        properties: JsonObject = buildJsonObject {},
        source: FakeContentSource? = null,
        entrySink: EntrySink? = null,
    ): ChatStore {
        val logger = noopLogger()
        val config = ChatConfiguration.fromJson(properties, logger)
        config.emitsEntryEvents = entrySink != null
        val hostEvents: ChatHostEventSink? = entrySink?.let { sink ->
            { event: ChatHostEvent -> if (event is ChatHostEvent.Entry) sink.add(event.json) }
        }
        return ChatStore(
            config = config,
            logger = logger,
            contentSource = source,
            scheduler = ManualChatScheduler(),
            scope = inertScope(),
            hostEvents = hostEvents,
        )
    }

    // MARK: - Codable (ChatTranscriptCodableTests)

    /** A representative transcript covering every ChatItem case, usage, plan, and title. */
    private fun sampleTranscript(): ChatTranscript = ChatTranscript(
        version = 1,
        items = listOf(
            ChatItem.Message(ChatMessage(id = "u1", role = ChatRole.LOCAL, text = "Hello", isStreaming = false)),
            ChatItem.Thought(ChatMessage(id = "t1", role = ChatRole.AGENT, text = "thinking", isStreaming = false)),
            ChatItem.ToolCall(
                ToolCallModel(
                    id = "tc1", title = "Search", kind = ToolCallModel.Kind.SEARCH, status = ToolCallModel.Status.COMPLETED,
                    contentText = "found", diff = ToolCallDiff(path = "a.swift", oldText = "old", newText = "new"),
                    rawInput = "{}", rawOutput = null,
                ),
            ),
            ChatItem.Image(
                id = "i1", role = ChatRole.AGENT,
                image = ChatImage(url = "https://example.test/i.png", alt = "pic", pixelSize = PixelSize(100.0, 50.0)),
            ),
            ChatItem.System(id = "s1", text = "system note"),
            ChatItem.Error(id = "e1", text = "boom"),
        ),
        usage = UsageInfo(used = 42, size = 1000, costAmount = 0.5, costCurrency = "USD"),
        plan = listOf(PlanEntry(id = 0, content = "step", priority = "high", status = PlanEntry.Status.COMPLETED)),
        title = "My Session",
    )

    @Test
    fun testRoundTripPreservesEverything() {
        val transcript = sampleTranscript()
        val data = chatJson.encodeToString(ChatTranscript.serializer(), transcript)
        val decoded = chatJson.decodeFromString(ChatTranscript.serializer(), data)
        assertEquals("encode -> decode must reproduce the transcript exactly", transcript, decoded)
    }

    // Pins the v1 JSON shape with a minimal fixture (sorted keys make it deterministic): the item discriminator,
    // the message keys, and the transcript keys. If any coding key drifts, this fails.
    @Test
    fun testV1JSONShapeIsPinned() {
        val transcript = ChatTranscript(items = listOf(ChatItem.Message(ChatMessage(id = "u1", role = ChatRole.LOCAL, text = "Hi"))))
        val json = canonicalJson(chatJson.encodeToJsonElement(ChatTranscript.serializer(), transcript))
        assertEquals(
            "{\"items\":[{\"message\":{\"id\":\"u1\",\"role\":\"local\",\"text\":\"Hi\"},\"type\":\"message\"}],\"version\":1}",
            json,
        )
    }

    @Test
    fun testStreamingFlagIsNotSerialized() {
        val streaming = ChatTranscript(items = listOf(ChatItem.Message(ChatMessage(id = "a", role = ChatRole.AGENT, text = "partial", isStreaming = true))))
        val decoded = chatJson.decodeFromString(
            ChatTranscript.serializer(),
            chatJson.encodeToString(ChatTranscript.serializer(), streaming),
        )
        val item = decoded.items.firstOrNull()
        assertTrue("expected a message", item is ChatItem.Message)
        val message = (item as ChatItem.Message).message
        assertFalse("a loaded message is always final; isStreaming is not persisted", message.isStreaming)
        assertEquals("the partial text IS captured in the snapshot", "partial", message.text)
    }

    @Test
    fun testImageSerializesByReferenceWithSize() {
        val image = ChatImage(url = "https://example.test/p.jpg", alt = "a", pixelSize = PixelSize(480.0, 320.0))
        val json = chatJson.encodeToString(ChatImage.serializer(), image)
        assertTrue(json.contains("\"pixelWidth\":480"))
        assertTrue(json.contains("\"pixelHeight\":320"))
        assertFalse("images serialize by URL, never pixel data", json.lowercase().contains("data:"))
    }

    @Test
    fun testDecodeToleratesMissingOptionalFields() {
        // A minimal v1 doc with only items still decodes (version defaults to 1, plan to []).
        val jsonString = "{\"items\":[{\"type\":\"system\",\"id\":\"s\",\"text\":\"hi\"}]}"
        val decoded = chatJson.decodeFromString(ChatTranscript.serializer(), jsonString)
        assertEquals(1, decoded.version)
        assertTrue(decoded.plan.isEmpty())
        assertNull(decoded.usage)
        assertEquals(1, decoded.items.size)
    }

    // MARK: - entryActionID + load (ChatTranscriptSeamTests)

    @Test
    fun seam_testEntryFiresOncePerFinalizedEntryWithMonotonicSequence() {
        val sink = EntrySink()
        val store = makeStore(entrySink = sink)
        store.route(ChatEvent.MessageStart("a1", ChatRole.AGENT))
        store.route(ChatEvent.MessageDelta("a1", "hello"))          // must NOT fire
        store.route(ChatEvent.MessageEnd("a1", null))                // fires: message
        store.route(ChatEvent.ToolCall(ToolCallModel(id = "tool1", title = "Read", kind = ToolCallModel.Kind.READ, status = ToolCallModel.Status.PENDING, contentText = "")))  // pending: no fire
        store.route(ChatEvent.ToolCallUpdateEvent(ToolCallUpdate(id = "tool1", status = ToolCallModel.Status.COMPLETED)))  // fires: toolCall
        store.route(ChatEvent.Usage(UsageInfo(used = 10, size = null, costAmount = null, costCurrency = null)))  // fires: usage

        val envelopes = sink.envelopes()
        assertEquals("only finalized items fire, in order", listOf("message", "toolCall", "usage"), envelopes.map { it.type })
        assertEquals("the sequence is monotonic", listOf(1, 2, 3), envelopes.map { it.sequence })
        assertEquals("a1", envelopes[0].id)
        assertEquals("tool1", envelopes[1].id)
    }

    @Test
    fun seam_testNoEntryActionMeansNoFiring() {
        // Without entry events enabled (no sink), driving a turn must not crash / fire anything.
        val store = makeStore()
        store.route(ChatEvent.MessageStart("a1", ChatRole.AGENT))
        store.route(ChatEvent.MessageEnd("a1", "end_turn"))
        assertEquals(1, store.items.size)
    }

    @Test
    fun seam_testLoadThenAppend() {
        val store = makeStore()
        val loaded = ChatTranscript(
            items = listOf(
                ChatItem.Message(ChatMessage(id = "old-1", role = ChatRole.LOCAL, text = "prior question", isStreaming = false)),
                ChatItem.Message(ChatMessage(id = "old-2", role = ChatRole.AGENT, text = "prior answer", isStreaming = false)),
            ),
        )
        store.reconcileRestoredContent(loaded)   // simulate setElementValue

        assertEquals("the loaded transcript replaces the session", 2, store.items.size)
        assertEquals("old-1", store.items.firstOrNull()?.id)

        // A live turn appends after the loaded items.
        store.route(ChatEvent.MessageStart("new-1", ChatRole.AGENT))
        store.route(ChatEvent.MessageEnd("new-1", "end_turn"))
        assertEquals(3, store.items.size)
        assertEquals("new-1", store.items.lastOrNull()?.id)
    }

    @Test
    fun seam_testDecodeTranscriptFromJSONObjectAndString() {
        val objectValue = mapOf("version" to 1, "items" to listOf(mapOf("type" to "system", "id" to "s1", "text" to "hi")))
        assertEquals(1, ChatTranscript.decode(objectValue)?.items?.size)
        val string = "{\"items\":[{\"type\":\"error\",\"id\":\"e1\",\"text\":\"boom\"}]}"
        assertEquals("e1", ChatTranscript.decode(string)?.items?.firstOrNull()?.id)
        assertNull("an unrelated value is not a transcript", ChatTranscript.decode(42))
    }

    // MARK: - Config parsing (readOnly / content) (ChatTranscriptConfigTests)

    @Test
    fun config_testReadOnlyParsing() {
        assertTrue(ChatConfiguration.fromJson(buildJsonObject { put("readOnly", true) }, noopLogger()).readOnly)
        assertFalse(ChatConfiguration.fromJson(buildJsonObject {}, noopLogger()).readOnly)
    }

    @Test
    fun config_testPrePopulatedContentKeptRawForOneTimeStoreDecode() {
        val transcript = buildJsonObject {
            put("version", 1)
            putJsonArray("items") {
                addJsonObject {
                    put("type", "message")
                    putJsonObject("message") {
                        put("id", "m1")
                        put("role", "agent")
                        put("text", "hi")
                    }
                }
            }
        }
        // The configuration keeps `content` RAW (the store decodes it once at start, not per view build).
        val configuration = ChatConfiguration.fromJson(buildJsonObject { put("content", transcript) }, noopLogger())
        val decoded = ChatTranscript.decode(configuration.initialContentRaw)
        assertEquals(1, decoded?.items?.size)
        assertEquals("m1", decoded?.items?.firstOrNull()?.id)
    }

    @Test
    fun config_testGarbagePrePopulatedContentDecodesToNil() {
        val configuration = ChatConfiguration.fromJson(buildJsonObject { put("content", "not a transcript") }, noopLogger())
        assertNull(ChatTranscript.decode(configuration.initialContentRaw))
    }

    // MARK: - Runtime restore through the content source (ChatContentRestoreTests)

    @Test
    fun restore_testPrePopulatedContentLoadsAtStart() {
        val source = FakeContentSource()
        val content = buildJsonObject {
            put("version", 1)
            putJsonArray("items") {
                addJsonObject {
                    put("type", "message")
                    putJsonObject("message") {
                        put("id", "seed-1")
                        put("role", "agent")
                        put("text", "seeded")
                    }
                }
            }
        }
        val properties = buildJsonObject {
            put("content", content)
            put("readOnly", true)
        }
        val store = makeStore(properties = properties, source = source)
        store.start()
        assertEquals("the document properties.content pre-populates at start()", 1, store.items.size)
        assertEquals("seed-1", store.items.firstOrNull()?.id)
    }

    @Test
    fun restore_testRestoreThroughContentReplacesSession() {
        val source = FakeContentSource()
        val store = makeStore(source = source)
        store.start()
        store.route(ChatEvent.MessageStart("a1", ChatRole.AGENT))
        store.route(ChatEvent.MessageEnd("a1", "end_turn"))
        assertEquals(1, store.items.size)

        // Simulate a runtime setElementState("content", ChatTranscript): the source notifies the store.
        val restored = ChatTranscript(items = listOf(ChatItem.Message(ChatMessage(id = "restored-1", role = ChatRole.LOCAL, text = "hi", isStreaming = false))))
        source.content = restored
        assertEquals("a runtime restore replaces the session", listOf("restored-1"), store.items.map { it.id })

        // A live turn appends after the restored items; a repeated identical restore is ignored (dedup).
        source.content = restored
        store.route(ChatEvent.MessageStart("a2", ChatRole.AGENT))
        store.route(ChatEvent.MessageEnd("a2", "end_turn"))
        assertEquals(listOf("restored-1", "a2"), store.items.map { it.id })
    }

    @Test
    fun restore_testRestoreFromJSONStringAndDict() {
        // setElementStateFromString delivers a JSON string; setElementState may deliver a dict.
        val source = FakeContentSource()
        val store = makeStore(source = source)
        store.start()
        source.content = "{\"items\":[{\"type\":\"message\",\"message\":{\"id\":\"s1\",\"role\":\"agent\",\"text\":\"from string\"}}]}"
        assertEquals("a JSON string restores", "s1", store.items.firstOrNull()?.id)
        source.content = mapOf("version" to 1, "items" to listOf(mapOf("type" to "system", "id" to "d1", "text" to "from dict")))
        assertEquals("a JSON dict restores", "d1", store.items.firstOrNull()?.id)
    }

    @Test
    fun restore_testIdCounterAdvancesPastRestoredIdsSoNoCollision() {
        val source = FakeContentSource()
        val store = makeStore(source = source)
        store.start()
        val restored = ChatTranscript(
            items = listOf(
                ChatItem.Message(ChatMessage(id = "user-2", role = ChatRole.LOCAL, text = "q1", isStreaming = false)),
                ChatItem.Message(ChatMessage(id = "agent-1", role = ChatRole.AGENT, text = "a1", isStreaming = false)),
                ChatItem.Message(ChatMessage(id = "user-3", role = ChatRole.LOCAL, text = "q2", isStreaming = false)),
            ),
        )
        source.content = restored
        store.send("new question")   // must NOT reuse user-1..user-3
        val ids = store.items.map { it.id }
        assertEquals("no duplicate ChatItem ids after restore-then-send", ids.size, ids.toSet().size)
        assertEquals("user-4", store.items.lastOrNull()?.id)
    }

    @Test
    fun restore_testReappearAfterTeardownStillObservesRestores() {
        val source = FakeContentSource()
        val store = makeStore(source = source)
        store.start()
        store.teardown()
        store.start()   // reappear: must re-subscribe and not re-run the pre-populated load

        val restored = ChatTranscript(items = listOf(ChatItem.Message(ChatMessage(id = "after-reappear", role = ChatRole.AGENT, text = "x", isStreaming = false))))
        source.content = restored
        assertEquals("the content subscription is re-established after a teardown/appear cycle", "after-reappear", store.items.firstOrNull()?.id)
    }

    @Test
    fun restore_testToolCallEntryReFiresSoTrailingOutputIsPersisted() {
        val sink = EntrySink()
        val source = FakeContentSource()
        val store = makeStore(source = source, entrySink = sink)
        store.start()
        // Some transports deliver the terminal status and the final output in SEPARATE updates.
        store.route(ChatEvent.ToolCall(ToolCallModel(id = "tool1", title = "Read", kind = ToolCallModel.Kind.READ, status = ToolCallModel.Status.PENDING, contentText = "")))
        store.route(ChatEvent.ToolCallUpdateEvent(ToolCallUpdate(id = "tool1", status = ToolCallModel.Status.COMPLETED)))         // fires (no output yet)
        store.route(ChatEvent.ToolCallUpdateEvent(ToolCallUpdate(id = "tool1", contentText = "final output")))                    // still completed: re-fires WITH output

        val toolJSONs = sink.rawJSONs().filter { it.contains("\"toolCall\"") }
        assertTrue("a terminal tool call re-fires on later updates", toolJSONs.size >= 2)
        assertTrue("the latest entry captures the final output (upsert by id)", toolJSONs.lastOrNull()?.contains("final output") == true)
        // The pending update did NOT fire an entry.
        assertEquals("only the two terminal updates fire; the pending one does not", 2, sink.rawJSONs().size)
    }
}
