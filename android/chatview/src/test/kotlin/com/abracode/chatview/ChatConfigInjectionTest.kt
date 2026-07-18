package com.abracode.chatview

// Port of Tests/ChatViewTests/ChatConfigInjectionTests.swift.
//
// Tests for the host-injected operational-config seam (states["config"]). The Chat element takes its protocol +
// transport NOT from the document but from a runtime injection into states["config"] (the same channel as the
// P0-2 states["content"] restore). The store DEFERS building the transport until the config first resolves to a
// VIABLE one; after that an IDENTICAL injection is deduped while a DIFFERENT viable one re-configures in place
// (tear down + attach + re-prime from the loaded items - the host-driven model switch). Until configured the
// element is inert (isConfigured == false, no transport); readOnly never builds a transport.

import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.put
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class ChatConfigInjectionTest {

    private fun makeStore(properties: JsonObject = buildJsonObject {}, source: FakeContentSource): ChatStore =
        ChatStore(
            config = ChatConfiguration.fromJson(properties, noopLogger()),
            logger = noopLogger(),
            contentSource = source,
            scheduler = ManualChatScheduler(),
            scope = inertScope(),
        )

    // NOTE: ChatStore holds `contentSource` WEAKLY in Swift (the engine's ViewModel owns the store's lifetime, not
    // vice versa). The Kotlin port keeps a strong reference, but every test still keeps a local `source` alive
    // across start(), mirroring the Swift test shape.

    @Test
    fun testInertWithNoConfigInjected() {
        val source = FakeContentSource() // no states["config"]
        val store = makeStore(source = source)
        store.start()
        assertFalse(
            "with no states[\"config\"] injected, the element stays inert (no transport)",
            store.isConfigured,
        )
    }

    @Test
    fun testLocalConfigBuildsTransport() {
        val source = FakeContentSource(initialConfig = mapOf("protocol" to "local"))
        val store = makeStore(source = source)
        store.start()
        assertTrue("an injected local config builds the built-in transport", store.isConfigured)
        store.teardown()
    }

    @Test
    fun testMissingProtocolDefaultsToLocal() {
        val source = FakeContentSource(initialConfig = mapOf("transport" to mapOf("echo" to true)))
        val store = makeStore(source = source)
        store.start()
        assertTrue("a config object without a protocol defaults to local and is viable", store.isConfigured)
        store.teardown()
    }

    @Test
    fun testReadOnlyNeverBuildsTransportEvenWhenConfigInjected() {
        val source = FakeContentSource(initialConfig = mapOf("protocol" to "local"))
        val store = makeStore(properties = buildJsonObject { put("readOnly", true) }, source = source)
        store.start()
        assertFalse(
            "readOnly is a viewer mode: no transport even when a config is injected",
            store.isConfigured,
        )
    }

    @Test
    fun testNotYetViableConfigDefersThenBuildsOnCompleterConfig() {
        val name = "inject-test-needs-key-" + java.util.UUID.randomUUID()
        ChatTransportRegistry.shared.register(name) { config, _ ->
            if (config.settings["key"] == null) throw IllegalStateException("missing key")
            FakeInjectTransport()
        }
        val source = FakeContentSource(initialConfig = mapOf("protocol" to name)) // registered but incomplete -> not viable
        val store = makeStore(source = source)
        store.start()
        assertFalse(
            "a registered-but-incomplete config does not build or freeze; the element stays inert",
            store.isConfigured,
        )

        source.config = mapOf("protocol" to name, "transport" to mapOf("key" to "v")) // the host completes the config
        assertTrue("when a completer config arrives, the deferred transport builds", store.isConfigured)
        store.teardown()
    }

    @Test
    fun testIdenticalConfigReinjectionIsIgnored() {
        val counter = BuildCounter()
        val name = "inject-test-dedup-" + java.util.UUID.randomUUID()
        ChatTransportRegistry.shared.register(name) { _, _ ->
            counter.count += 1
            FakeInjectTransport()
        }
        val source = FakeContentSource(initialConfig = mapOf("protocol" to name, "transport" to mapOf("key" to "v")))
        val store = makeStore(source = source)
        store.start()
        assertTrue(store.isConfigured)
        assertEquals("the first viable config builds the transport once", 1, counter.count)

        // The observation re-delivers on every states change: an IDENTICAL config must not rebuild.
        source.config = mapOf("protocol" to name, "transport" to mapOf("key" to "v"))
        assertEquals("re-injecting the same resolved config is a no-op", 1, counter.count)
        store.teardown()
    }

    @Test
    fun testChangedConfigReconfiguresAndReprimesFromItems() {
        val counter = BuildCounter()
        val box = TransportBox()
        val name = "inject-test-reconfig-" + java.util.UUID.randomUUID()
        ChatTransportRegistry.shared.register(name) { _, _ ->
            counter.count += 1
            val transport = FakeInjectTransport()
            box.transport = transport
            transport
        }
        val source = FakeContentSource(initialConfig = mapOf("protocol" to name, "transport" to mapOf("model" to "A")))
        val store = makeStore(source = source)
        store.start()
        source.content = ChatTranscript(
            items = listOf(
                ChatItem.Message(ChatMessage(id = "u1", role = ChatRole.LOCAL, text = "q", isStreaming = false)),
            ),
        )
        assertEquals(1, counter.count)

        // A DIFFERENT viable config re-configures in place (the host-driven model switch): a new transport is
        // built, and attach() re-primes it from the loaded items so the conversation carries over.
        source.config = mapOf("protocol" to name, "transport" to mapOf("model" to "B"))
        assertEquals("a changed config tears down the old transport and builds the new one", 2, counter.count)
        assertEquals(
            "the re-configured transport is seeded with the loaded conversation",
            listOf("u1"),
            box.transport?.primedHistories?.last()?.map { it.id },
        )
        store.teardown()
    }

    // MARK: - Restore primes the transport wire history (P0-2 continue-in)

    private fun registerPrimingTransport(box: TransportBox): String {
        val name = "prime-test-" + java.util.UUID.randomUUID()
        ChatTransportRegistry.shared.register(name) { _, _ ->
            val transport = FakeInjectTransport()
            box.transport = transport
            transport
        }
        return name
    }

    @Test
    fun testRestorePrimesTheTransportWithLoadedMessages() {
        val box = TransportBox()
        val source = FakeContentSource(initialConfig = mapOf("protocol" to registerPrimingTransport(box)))
        val store = makeStore(source = source)
        store.start() // builds + attaches the transport (primes an empty history)
        assertTrue(store.isConfigured)

        source.content = ChatTranscript(
            items = listOf(
                ChatItem.Message(ChatMessage(id = "u1", role = ChatRole.LOCAL, text = "earlier question", isStreaming = false)),
                ChatItem.Thought(ChatMessage(id = "t1", role = ChatRole.AGENT, text = "thinking", isStreaming = false)),
                ChatItem.Message(ChatMessage(id = "a1", role = ChatRole.AGENT, text = "earlier answer", isStreaming = false)),
            ),
        )

        val primed = box.transport?.primedHistories?.last() ?: emptyList()
        assertEquals(
            "restoring a transcript primes the transport with its MESSAGE items (thoughts/tool cards omitted)",
            listOf("u1", "a1"),
            primed.map { it.id },
        )
        assertEquals(listOf(ChatRole.LOCAL, ChatRole.AGENT), primed.map { it.role })

        val reserved = box.transport?.reservedIDs?.last() ?: emptyList()
        assertEquals(
            "restore reserves EVERY loaded id (including the thought t1, which primeHistory omits) so a continued turn cannot reuse one",
            listOf("u1", "t1", "a1"),
            reserved,
        )
        store.teardown()
    }

    @Test
    fun testNewChatClearPrimesAnEmptyWire() {
        val box = TransportBox()
        val source = FakeContentSource(initialConfig = mapOf("protocol" to registerPrimingTransport(box)))
        val store = makeStore(source = source)
        store.start()
        source.content = ChatTranscript(
            items = listOf(ChatItem.Message(ChatMessage(id = "u1", role = ChatRole.LOCAL, text = "q", isStreaming = false))),
        )
        assertEquals(1, box.transport?.primedHistories?.last()?.size)
        // A New Chat injects an empty transcript -> the transport is primed with an empty wire.
        source.content = ChatTranscript(items = emptyList())
        assertEquals(
            "a cleared transcript primes an empty wire history, so the next turn starts fresh",
            0,
            box.transport?.primedHistories?.last()?.size,
        )
        store.teardown()
    }

    // MARK: - The transient "prime" directive (Read Only restore: display without context)

    /**
     * The injected transcript JSON with a "prime" key riding on it, as MLXChat's restore scripts emit it (the key
     * is transient: ChatTranscript's codec drops it, so it never reaches persistence). `prime` is true / false /
     * the string "defer" / null (key omitted).
     */
    private fun transcriptJSON(items: List<ChatItem>, prime: Any?): String {
        val encoded = chatJson.encodeToJsonElement(ChatTranscript.serializer(), ChatTranscript(items = items)).jsonObject
        val out = buildJsonObject {
            encoded.forEach { (k, v) -> put(k, v) }
            if (prime != null) {
                val primitive = when (prime) {
                    is Boolean -> JsonPrimitive(prime)
                    is String -> JsonPrimitive(prime)
                    else -> throw IllegalArgumentException("unsupported prime value: $prime")
                }
                put("prime", primitive)
            }
        }
        return chatJson.encodeToString(JsonObject.serializer(), out)
    }

    private val restoreItems: List<ChatItem> = listOf(
        ChatItem.Message(ChatMessage(id = "u1", role = ChatRole.LOCAL, text = "earlier question", isStreaming = false)),
        ChatItem.Message(ChatMessage(id = "a1", role = ChatRole.AGENT, text = "earlier answer", isStreaming = false)),
    )

    @Test
    fun testPrimeFalseRestoreDisplaysItemsButPrimesEmpty() {
        val box = TransportBox()
        val source = FakeContentSource(initialConfig = mapOf("protocol" to registerPrimingTransport(box)))
        val store = makeStore(source = source)
        store.start()

        source.content = transcriptJSON(restoreItems, false)
        assertEquals("a Read Only restore still displays the transcript", 2, store.items.size)
        assertEquals(
            "\"prime\": false seeds an EMPTY wire history (fresh context) while the transcript displays",
            0,
            box.transport?.primedHistories?.last()?.size,
        )
        assertEquals(
            "id reservation is collision safety, independent of the prime directive",
            listOf("u1", "a1"),
            box.transport?.reservedIDs?.last(),
        )
        store.teardown()
    }

    @Test
    fun testSameTranscriptWithFlippedPrimeFlagIsNotDeduped() {
        val box = TransportBox()
        val source = FakeContentSource(initialConfig = mapOf("protocol" to registerPrimingTransport(box)))
        val store = makeStore(source = source)
        store.start()

        source.content = transcriptJSON(restoreItems, false)
        assertEquals(0, box.transport?.primedHistories?.last()?.size)
        // The user reopens the SAME conversation, now choosing Resume: the identical transcript with a flipped
        // flag must re-apply, not be swallowed by the dedup.
        source.content = transcriptJSON(restoreItems, true)
        assertEquals(
            "re-injecting the same transcript with a flipped prime flag re-applies and primes the messages",
            listOf("u1", "a1"),
            box.transport?.primedHistories?.last()?.map { it.id },
        )
        store.teardown()
    }

    @Test
    fun testAbsentPrimeKeyDefaultsToPrimingMessages() {
        val box = TransportBox()
        val source = FakeContentSource(initialConfig = mapOf("protocol" to registerPrimingTransport(box)))
        val store = makeStore(source = source)
        store.start()

        source.content = transcriptJSON(restoreItems, null)
        assertEquals(
            "no prime key -> context follows display (the documented default), pinning existing behavior",
            listOf("u1", "a1"),
            box.transport?.primedHistories?.last()?.map { it.id },
        )
        store.teardown()
    }

    // MARK: - The "defer" directive (seamless browsing: display now, prime on the next send)

    @Test
    fun testDeferredRestorePrimesOnSendNotOnLoad() {
        val box = TransportBox()
        val source = FakeContentSource(initialConfig = mapOf("protocol" to registerPrimingTransport(box)))
        val store = makeStore(source = source)
        store.start()
        val attachPrimes = box.transport?.primedHistories?.size ?: 0

        source.content = transcriptJSON(restoreItems, "defer")
        assertEquals("a deferred restore still displays the transcript", 2, store.items.size)
        assertEquals(
            "\"prime\": \"defer\" must not touch the agent on load - browsing is free",
            attachPrimes,
            box.transport?.primedHistories?.size,
        )
        assertEquals(
            "id reservation still happens on a deferred restore (collision safety)",
            listOf("u1", "a1"),
            box.transport?.reservedIDs?.last(),
        )
        assertEquals(
            "the indicator reports the context loads on the next message",
            ChatContextState.PENDING,
            store.contextState,
        )

        store.send("continue")
        assertEquals(
            "the first send replays the displayed conversation before the prompt",
            listOf("u1", "a1"),
            box.transport?.primedHistories?.last()?.map { it.id },
        )
        assertEquals(ChatContextState.SYNCED, store.contextState)
        store.teardown()
    }

    @Test
    fun testBrowsingAwayAndBackSkipsTheRePrime() {
        val box = TransportBox()
        val source = FakeContentSource(initialConfig = mapOf("protocol" to registerPrimingTransport(box)))
        val store = makeStore(source = source)
        store.start()

        source.content = transcriptJSON(restoreItems, true) // conversation A, primed
        val primeCount = box.transport?.primedHistories?.size
        val otherItems: List<ChatItem> = listOf(
            ChatItem.Message(ChatMessage(id = "x1", role = ChatRole.LOCAL, text = "another conversation", isStreaming = false)),
        )
        source.content = transcriptJSON(otherItems, "defer") // browse B: agent untouched
        assertEquals(ChatContextState.PENDING, store.contextState)
        source.content = transcriptJSON(restoreItems, "defer") // back to A
        assertEquals(
            "the agent still holds A, so returning to it is already synced",
            ChatContextState.SYNCED,
            store.contextState,
        )
        store.send("go on")
        assertEquals(
            "sending into the conversation the agent already holds fires no re-prime",
            primeCount,
            box.transport?.primedHistories?.size,
        )
        store.teardown()
    }

    @Test
    fun testReconfigureAfterDeferredRestoreDefersToTheNextSend() {
        // The host-driven model switch after a deferred restore: the NEW transport (a fresh agent) is not primed
        // eagerly either - the conversation carries over on the next send.
        val counter = BuildCounter()
        val box = TransportBox()
        val name = "inject-test-reconfig-defer-" + java.util.UUID.randomUUID()
        ChatTransportRegistry.shared.register(name) { _, _ ->
            counter.count += 1
            val transport = FakeInjectTransport()
            box.transport = transport
            transport
        }
        val source = FakeContentSource(initialConfig = mapOf("protocol" to name, "transport" to mapOf("model" to "A")))
        val store = makeStore(source = source)
        store.start()
        source.content = transcriptJSON(restoreItems, "defer")

        source.config = mapOf("protocol" to name, "transport" to mapOf("model" to "B"))
        assertEquals(2, counter.count)
        assertEquals(
            "the re-configured transport is not primed eagerly under a deferred directive",
            0,
            box.transport?.primedHistories?.size,
        )
        assertEquals(ChatContextState.PENDING, store.contextState)
        store.send("carry on")
        assertEquals(
            "the switched agent inherits the conversation with the first send",
            listOf("u1", "a1"),
            box.transport?.primedHistories?.last()?.map { it.id },
        )
        store.teardown()
    }

    @Test
    fun testSupersededTurnTerminalDoesNotDowngradeARestoredContext() {
        // A restore lands while a turn is streaming: the restore path sets the truthful context state, and the
        // superseded turn's terminal messageEnd (stopReason "cancelled", always the next terminal on the ordered
        // event stream) must NOT re-run the turn-end bookkeeping - it would downgrade a correct SYNCED to PENDING
        // and force a wasted duplicate prime on the next send.
        val box = TransportBox()
        val source = FakeContentSource(initialConfig = mapOf("protocol" to registerPrimingTransport(box)))
        val store = makeStore(source = source)
        store.start()

        store.route(ChatEvent.MessageStart("turn-1", ChatRole.AGENT)) // a turn is in flight
        source.content = transcriptJSON(restoreItems, true) // restore mid-turn
        assertEquals("the resume restore primes and syncs", ChatContextState.SYNCED, store.contextState)
        val primeCount = box.transport?.primedHistories?.size

        store.route(ChatEvent.MessageEnd("turn-1", "cancelled")) // superseded turn resolves
        assertEquals(
            "the superseded turn's terminal must not downgrade the restored state",
            ChatContextState.SYNCED,
            store.contextState,
        )
        store.send("continue")
        assertEquals(
            "no duplicate prime: the send after the restore trusts the synced snapshot",
            primeCount,
            box.transport?.primedHistories?.size,
        )

        // A REAL cancellation (no restore in between) still marks the context unknown.
        store.route(ChatEvent.MessageStart("turn-2", ChatRole.AGENT))
        store.route(ChatEvent.MessageEnd("turn-2", "cancelled"))
        assertEquals(
            "a genuinely cancelled turn leaves a partial exchange agent-side; the next send re-primes",
            ChatContextState.PENDING,
            store.contextState,
        )
        store.teardown()
    }

    @Test
    fun testTransportBuiltAfterRestorePrimesFromLoadedItems() {
        // Content restored BEFORE a viable config exists: the transport does not exist yet, so the restore cannot
        // prime it. When the config later builds the transport, attach() must prime it from the already-loaded
        // items (else a continue would drop the pre-config history).
        val box = TransportBox()
        val name = registerPrimingTransport(box)
        val source = FakeContentSource() // no config yet
        source.content = ChatTranscript(
            items = listOf(
                ChatItem.Message(ChatMessage(id = "u1", role = ChatRole.LOCAL, text = "before config", isStreaming = false)),
            ),
        )
        val store = makeStore(source = source)
        store.start() // loads content; no transport built yet
        assertNull("no transport is built until a viable config arrives", box.transport)

        source.config = mapOf("protocol" to name) // now the transport builds + attaches
        val primed = box.transport?.primedHistories?.last() ?: emptyList()
        assertEquals(
            "attach() primes the freshly built transport from the transcript restored before it existed",
            listOf("u1"),
            primed.map { it.id },
        )
        store.teardown()
    }
}
