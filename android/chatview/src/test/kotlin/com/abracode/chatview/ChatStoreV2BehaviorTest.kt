package com.abracode.chatview

// Port of ChatStoreV2Tests.ChatStoreV2BehaviorTests: the store-initiated behaviors (paging, read-mark debounce,
// outgoing-typing throttle), the features-AND-capabilities command gating, optimistic-id reconciliation, and
// connection-state gating - plus one real end-to-end run through LocalP2PTransport. The store's `Task { transport.
// send(...) }` equivalents run on a StandardTestDispatcher(testScheduler); advanceUntilIdle() drains them (the
// analog of Swift's settle()). The v2 time-based logic runs on the separate hand-driven ManualChatScheduler.

import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.test.StandardTestDispatcher
import kotlinx.coroutines.test.TestScope
import kotlinx.coroutines.test.advanceUntilIdle
import kotlinx.coroutines.test.runTest
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put
import kotlinx.serialization.json.putJsonObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.util.UUID
import kotlin.time.Duration.Companion.seconds

@OptIn(ExperimentalCoroutinesApi::class)
class ChatStoreV2BehaviorTest {

    private fun TestScope.makeStarted(
        features: JsonObject = buildJsonObject {},
        capabilities: ChatTransportCapabilities = allCaps(),
        scheduler: ManualChatScheduler = ManualChatScheduler(),
    ): Pair<ChatStore, CommandSink> {
        val sink = CommandSink()
        val proto = "mock-p2p-" + UUID.randomUUID()
        ChatTransportRegistry.shared.register(proto) { _, _ -> MockP2PTransport(capabilities, sink) }
        val config = ChatConfiguration.fromJson(features, noopLogger())
        // The ActionUI add-on maps a configured attachActionID to attachEnabled; mirror that here.
        val attachID = (features["attachActionID"] as? JsonPrimitive)?.takeIf { it.isString }?.content
        config.attachEnabled = !attachID.isNullOrEmpty()
        val source = FakeContentSource(initialConfig = mapOf("protocol" to proto))
        val store = ChatStore(
            config = config, logger = noopLogger(), contentSource = source, scheduler = scheduler,
            scope = CoroutineScope(StandardTestDispatcher(testScheduler)),
        )
        store.start()
        return store to sink
    }

    private fun remote(id: String): ChatMessage = ChatMessage(id = id, role = ChatRole.REMOTE, text = "hi", isStreaming = false)

    @Test
    fun scrolledNearTopRequestsAPageOnce() = runTest {
        val (store, sink) = makeStarted()
        store.route(ChatEvent.MessageReceived(remote("top")))
        store.scrolledNearTop()
        advanceUntilIdle()
        assertTrue(store.isLoadingEarlier)
        assertEquals(1, sink.all().size)
        val first = sink.all().first()
        assertTrue(first is ChatCommand.LoadEarlier && first.beforeItemID == "top" && first.limit == 50)
        // A second trigger while a page is in flight does nothing.
        store.scrolledNearTop()
        advanceUntilIdle()
        assertEquals("no double request while loading", 1, sink.all().size)
    }

    @Test
    fun scrolledNearTopNoPagingCapabilityIsInert() = runTest {
        val (store, sink) = makeStarted(capabilities = ChatTransportCapabilities())
        store.route(ChatEvent.MessageReceived(remote("top")))
        store.scrolledNearTop()
        advanceUntilIdle()
        assertTrue("no paging capability -> no request", sink.all().isEmpty())
        assertFalse(store.isLoadingEarlier)
    }

    @Test
    fun readMarkDebouncedWhenPinnedAndActive() = runTest {
        val scheduler = ManualChatScheduler()
        val (store, sink) = makeStarted(scheduler = scheduler)
        store.setPinnedToBottom(true)
        store.setSceneActive(true)
        store.route(ChatEvent.MessageReceived(remote("r1")))
        assertTrue("debounced: nothing yet", sink.all().isEmpty())
        scheduler.advance(2.seconds)
        advanceUntilIdle()
        assertEquals(1, sink.all().size)
        val first = sink.all().first()
        assertTrue(first is ChatCommand.MarkRead && first.upToItemID == "r1")
    }

    @Test
    fun readMarkSuppressedWhenNotPinned() = runTest {
        val scheduler = ManualChatScheduler()
        val (store, sink) = makeStarted(scheduler = scheduler)
        store.setPinnedToBottom(false)
        store.route(ChatEvent.MessageReceived(remote("r1")))
        scheduler.advance(5.seconds)
        advanceUntilIdle()
        assertTrue("not pinned to bottom -> no read mark", sink.all().isEmpty())
    }

    @Test
    fun readMarkSuppressedWhenScrolledAwayDuringDebounceWindow() = runTest {
        val scheduler = ManualChatScheduler()
        val (store, sink) = makeStarted(scheduler = scheduler)
        store.setPinnedToBottom(true)
        store.setSceneActive(true)
        store.route(ChatEvent.MessageReceived(remote("r1")))
        scheduler.advance(1.seconds)              // still within the debounce window
        store.setPinnedToBottom(false)            // user scrolls up before it fires
        scheduler.advance(2.seconds)
        advanceUntilIdle()
        assertTrue("scrolling away during the debounce window suppresses the read mark", sink.all().isEmpty())
    }

    @Test
    fun readMarkSuppressedWhenBackgroundedDuringDebounceWindow() = runTest {
        val scheduler = ManualChatScheduler()
        val (store, sink) = makeStarted(scheduler = scheduler)
        store.setPinnedToBottom(true)
        store.setSceneActive(true)
        store.route(ChatEvent.MessageReceived(remote("r1")))
        scheduler.advance(1.seconds)
        store.setSceneActive(false)               // app backgrounds before it fires
        scheduler.advance(2.seconds)
        advanceUntilIdle()
        assertTrue("backgrounding during the debounce window suppresses the read mark", sink.all().isEmpty())
    }

    @Test
    fun outgoingTypingThrottleAndStop() = runTest {
        val scheduler = ManualChatScheduler()
        val (store, sink) = makeStarted(scheduler = scheduler)
        store.notifyComposerActivity()
        store.notifyComposerActivity()   // within the 4s window -> throttled
        advanceUntilIdle()
        assertEquals("typing signal is throttled", 1, sink.all().size)
        assertTrue(sink.all().first().let { it is ChatCommand.SetTyping && it.isTyping })
        scheduler.advance(4.seconds)
        store.notifyComposerActivity()   // past the window -> allowed
        advanceUntilIdle()
        assertEquals(2, sink.all().size)
        store.stopTypingSignal()
        advanceUntilIdle()
        assertTrue(sink.all().last().let { it is ChatCommand.SetTyping && !it.isTyping })
    }

    @Test
    fun reactionGatingRequiresFeatureAndCapability() = runTest {
        // Feature on, capability off -> inert.
        val (noCap, noCapSink) = makeStarted(
            features = buildJsonObject { putJsonObject("features") { put("reactions", true) } },
            capabilities = ChatTransportCapabilities(),
        )
        noCap.route(ChatEvent.MessageReceived(remote("m1")))
        noCap.toggleReaction("m1", thumbsUp)
        advanceUntilIdle()
        assertTrue("no reactions capability -> no command", noCapSink.all().isEmpty())

        // Capability on, feature off -> inert.
        val (noFeat, noFeatSink) = makeStarted(features = buildJsonObject {}, capabilities = allCaps())
        noFeat.route(ChatEvent.MessageReceived(remote("m1")))
        noFeat.toggleReaction("m1", thumbsUp)
        advanceUntilIdle()
        assertTrue("reactions feature off -> no command", noFeatSink.all().isEmpty())

        // Both on -> emits, with add derived from the current reaction (not mine -> add).
        val (both, bothSink) = makeStarted(
            features = buildJsonObject { putJsonObject("features") { put("reactions", true) } },
            capabilities = allCaps(),
        )
        both.route(ChatEvent.MessageReceived(remote("m1")))
        both.toggleReaction("m1", thumbsUp)
        advanceUntilIdle()
        val cmd = bothSink.all().firstOrNull()
        assertTrue(cmd is ChatCommand.ToggleReaction)
        cmd as ChatCommand.ToggleReaction
        assertEquals("m1", cmd.itemID)
        assertEquals(thumbsUp, cmd.emoji)
        assertTrue("no existing reaction -> add", cmd.add)
    }

    @Test
    fun editDeleteGating() = runTest {
        val (store, sink) = makeStarted(
            features = buildJsonObject { putJsonObject("features") { put("editing", true); put("deletion", true) } },
            capabilities = allCaps(),
        )
        store.route(ChatEvent.MessageReceived(ChatMessage(id = "m1", role = ChatRole.LOCAL, text = "hi", isStreaming = false)))
        store.editMessage("m1", "hello")
        store.deleteMessage("m1")
        advanceUntilIdle()
        // Each goes out in its own Task; assert presence, not order.
        val commands = sink.all()
        assertEquals(2, commands.size)
        assertTrue(commands.any { it is ChatCommand.EditMessage && it.itemID == "m1" && it.newText == "hello" })
        assertTrue(commands.any { it is ChatCommand.DeleteMessage && it.itemID == "m1" })
    }

    @Test
    fun resendOnlyForFailed() = runTest {
        val (store, sink) = makeStarted(capabilities = allCaps())
        store.route(ChatEvent.MessageReceived(ChatMessage(id = "ok", role = ChatRole.LOCAL, text = "hi", isStreaming = false, status = MessageStatus.SENT)))
        store.route(ChatEvent.MessageReceived(ChatMessage(id = "bad", role = ChatRole.LOCAL, text = "no", isStreaming = false, status = MessageStatus.FAILED)))
        store.resendMessage("ok")    // not failed -> ignored
        store.resendMessage("bad")   // failed -> resend + optimistic sending
        advanceUntilIdle()
        assertEquals(1, sink.all().size)
        assertTrue(sink.all().first().let { it is ChatCommand.ResendMessage && it.itemID == "bad" })
        val bad = store.items.filterIsInstance<ChatItem.Message>().first { it.message.id == "bad" }.message
        assertEquals("a resent message shows as sending again", MessageStatus.SENDING, bad.status)
    }

    @Test
    fun resendAlsoRetriesAFailedFileTransfer() = runTest {
        val (store, sink) = makeStarted(capabilities = allCaps())
        store.route(ChatEvent.FileAdded(ChatFile(id = "f1", role = ChatRole.LOCAL, name = "a.pdf", transferStatus = FileTransferStatus.FAILED)))
        store.resendMessage("f1")
        advanceUntilIdle()
        assertTrue(sink.all().first().let { it is ChatCommand.ResendMessage && it.itemID == "f1" })
        val file = store.items.filterIsInstance<ChatItem.File>().first { it.file.id == "f1" }.file
        assertEquals("a retried file transfer restarts as transferring", FileTransferStatus.TRANSFERRING, file.transferStatus)
    }

    @Test
    fun replySendRoutesThroughSendMessageWhenAllowed() = runTest {
        val (store, sink) = makeStarted(
            features = buildJsonObject { putJsonObject("features") { put("replies", true) } },
            capabilities = allCaps(),
        )
        store.route(ChatEvent.MessageReceived(remote("orig")))
        store.draft = "sure"
        store.submitDraft(replyTo = "orig")
        advanceUntilIdle()
        val first = sink.all().first()
        assertTrue("a gated reply routes through sendMessage", first is ChatCommand.SendMessage && first.text == "sure" && first.replyTo == "orig")
        val last = store.items.lastOrNull()
        assertTrue(last is ChatItem.Message)
        val m = (last as ChatItem.Message).message
        assertEquals("orig", m.replyTo?.itemID)
        assertEquals("readReceipts capability -> optimistic sending status", MessageStatus.SENDING, m.status)
    }

    @Test
    fun affordanceGatingMatrix() = runTest {
        fun caps(on: Boolean) = if (on) allCaps() else ChatTransportCapabilities()
        fun feature(name: String) = buildJsonObject { putJsonObject("features") { put(name, true) } }
        // reactions
        assertTrue(makeStarted(feature("reactions"), caps(true)).first.canReact)
        assertFalse(makeStarted(feature("reactions"), caps(false)).first.canReact)
        assertFalse(makeStarted(buildJsonObject {}, caps(true)).first.canReact)
        // editing
        assertTrue(makeStarted(feature("editing"), caps(true)).first.canEditMessages)
        assertFalse(makeStarted(buildJsonObject {}, caps(true)).first.canEditMessages)
        // deletion
        assertTrue(makeStarted(feature("deletion"), caps(true)).first.canDeleteMessages)
        assertFalse(makeStarted(feature("deletion"), caps(false)).first.canDeleteMessages)
        // replies
        assertTrue(makeStarted(feature("replies"), caps(true)).first.canReply)
        assertFalse(makeStarted(buildJsonObject {}, caps(true)).first.canReply)
        // attach is host-gated (iff attachActionID is set, which maps to attachEnabled)
        assertTrue(makeStarted(buildJsonObject { put("attachActionID", "chat.attach") }, caps(false)).first.canAttach)
        assertFalse(makeStarted(buildJsonObject {}, caps(true)).first.canAttach)
    }

    @Test
    fun plainSendDropsReplyRefWhenRepliesNotAllowed() = runTest {
        val (store, sink) = makeStarted(features = buildJsonObject {}, capabilities = allCaps())
        store.route(ChatEvent.MessageReceived(remote("orig")))
        store.draft = "hi"
        store.submitDraft(replyTo = "orig")
        advanceUntilIdle()
        val first = sink.all().first()
        assertTrue("reply not enabled -> sendMessage with the ref dropped", first is ChatCommand.SendMessage && first.text == "hi" && first.replyTo == null)
        val m = (store.items.lastOrNull() as? ChatItem.Message)?.message
        assertNull("the dropped reply leaves no ref on the optimistic message", m?.replyTo)
    }

    @Test
    fun reKeyOnConfirmationPreservesFieldsAndLandsLaterEvents() = runTest {
        val (store, sink) = makeStarted(capabilities = allCaps())
        store.draft = "hi"
        store.submitDraft()
        advanceUntilIdle()
        val first = sink.all().first()
        assertTrue("a messageIdentity plain send routes through sendMessage with the optimistic localID",
            first is ChatCommand.SendMessage && first.text == "hi" && first.replyTo == null && first.localID == "user-1")
        assertEquals("user-1", store.items.lastOrNull()?.id)
        assertEquals(MessageStatus.SENDING, (store.items.last() as ChatItem.Message).message.status)
        // Confirmation re-keys the item in place, preserving text / status.
        store.route(ChatEvent.MessageIDConfirmed("user-1", "srv-9"))
        assertEquals("srv-9", store.items.lastOrNull()?.id)
        run {
            val m = (store.items.last() as ChatItem.Message).message
            assertEquals("hi", m.text)
            assertEquals("status is preserved across the re-key", MessageStatus.SENDING, m.status)
        }
        // A later server-keyed status change lands on the re-keyed item.
        store.route(ChatEvent.MessageStatusChanged("srv-9", MessageStatus.DELIVERED))
        assertEquals("the ladder advances on the re-keyed item", MessageStatus.DELIVERED, (store.items.last() as ChatItem.Message).message.status)
    }

    @Test
    fun preConfirmFailureAddressesTheOptimisticId() = runTest {
        val (store, sink) = makeStarted(capabilities = allCaps())
        store.draft = "hi"
        store.submitDraft()
        advanceUntilIdle()
        store.route(ChatEvent.MessageStatusChanged("user-1", MessageStatus.FAILED))
        assertEquals(MessageStatus.FAILED, (store.items.last() as ChatItem.Message).message.status)
        store.resendMessage("user-1")
        advanceUntilIdle()
        assertTrue("a pre-confirm retry resends by the optimistic id",
            sink.all().any { it is ChatCommand.ResendMessage && it.itemID == "user-1" })
    }

    @Test
    fun confirmationWithExistingServerIdDropsOptimisticDuplicate() = runTest {
        val (store, _) = makeStarted(capabilities = allCaps())
        // The server delivered the message as its own item first.
        store.route(ChatEvent.MessageReceived(ChatMessage(id = "srv-1", role = ChatRole.LOCAL, text = "hi", isStreaming = false)))
        store.draft = "hi"
        store.submitDraft()
        advanceUntilIdle()
        assertEquals("the seeded server item plus the optimistic send", 2, store.items.size)
        store.route(ChatEvent.MessageIDConfirmed("user-1", "srv-1"))
        assertEquals("the optimistic duplicate is dropped", 1, store.items.size)
        assertFalse("no optimistic item remains", store.items.any { it.id == "user-1" })
        assertTrue(store.items.any { it.id == "srv-1" })
    }

    @Test
    fun confirmationForUnknownIdIsAHarmlessNoOp() = runTest {
        val (store, _) = makeStarted(capabilities = allCaps())
        store.route(ChatEvent.MessageReceived(remote("r1")))
        val before = store.items.size
        store.route(ChatEvent.MessageIDConfirmed("nope", "x"))
        assertEquals("an unknown localID is a no-op", before, store.items.size)
        store.route(ChatEvent.MessageIDConfirmed("nope", "x"))
        assertEquals(before, store.items.size)
    }

    @Test
    fun v1TransportStillRoutesThroughPrompt() = runTest {
        val (store, sink) = makeStarted(capabilities = ChatTransportCapabilities())
        store.draft = "hi"
        store.submitDraft()
        advanceUntilIdle()
        assertTrue("a v1 transport still emits prompt", sink.all().first().let { it is ChatCommand.Prompt && it.text == "hi" })
        assertFalse("a v1 transport never sees sendMessage", sink.all().any { it is ChatCommand.SendMessage })
    }

    @Test
    fun connectionGatingOnForAReportingTransport() = runTest {
        val (store, _) = makeStarted(capabilities = allCaps())
        assertFalse("a reporting transport is not ready until connected", store.isConnectionReady)
        assertEquals("Connecting...", store.connectionBannerText)
        store.route(ChatEvent.ConnectionStateChanged(ChatConnectionState.CONNECTED))
        assertTrue("connected -> ready", store.isConnectionReady)
        assertNull("no banner when connected", store.connectionBannerText)
        store.route(ChatEvent.ConnectionStateChanged(ChatConnectionState.RECONNECTING))
        assertFalse(store.isConnectionReady)
        assertEquals("Reconnecting...", store.connectionBannerText)
        store.route(ChatEvent.ConnectionStateChanged(ChatConnectionState.OFFLINE))
        assertFalse(store.isConnectionReady)
        assertEquals("Offline", store.connectionBannerText)
    }

    @Test
    fun connectionGatingOffForAV1Transport() = runTest {
        val (store, _) = makeStarted(capabilities = ChatTransportCapabilities())
        assertTrue("no reportsConnectionState -> always ready", store.isConnectionReady)
        assertNull("no reportsConnectionState -> no banner", store.connectionBannerText)
        store.route(ChatEvent.ConnectionStateChanged(ChatConnectionState.OFFLINE))
        assertTrue("still ready: the transport does not report connection state", store.isConnectionReady)
        assertNull(store.connectionBannerText)
    }

    @Test
    fun localP2PEndToEndReKeysLaddersAndConnects() = runTest {
        val proto = "local-p2p-e2e-" + UUID.randomUUID()
        ChatTransportRegistry.shared.register(proto) { config, _ ->
            LocalP2PTransport(config = config, dispatcher = StandardTestDispatcher(testScheduler))
        }
        val source = FakeContentSource(initialConfig = mapOf(
            "protocol" to proto,
            "transport" to mapOf("scenario" to "people", "stepMs" to 0),
        ))
        val store = ChatStore(
            config = ChatConfiguration(), logger = noopLogger(), contentSource = source,
            scheduler = ManualChatScheduler(), scope = CoroutineScope(StandardTestDispatcher(testScheduler)),
        )
        store.start()
        advanceUntilIdle()
        assertEquals("the link comes up on start", ChatConnectionState.CONNECTED, store.connectionState)
        assertTrue(store.isConnectionReady)

        store.draft = "ping"
        store.submitDraft()
        advanceUntilIdle()

        val sent = store.items.filterIsInstance<ChatItem.Message>().map { it.message }.firstOrNull { it.text == "ping" }
        val reKeyedID = sent?.id
        val reKeyedStatus = sent?.status
        val hasOptimistic = store.items.any { it.id == "user-1" }

        store.teardown()
        advanceUntilIdle()

        assertTrue("the sent message is present", reKeyedID != null)
        assertTrue("the optimistic id was re-keyed to the server id", reKeyedID?.startsWith("srv-") == true)
        assertEquals("the delivery ladder reached read on the re-keyed id", MessageStatus.READ, reKeyedStatus)
        assertFalse("no optimistic id remains", hasOptimistic)
    }

    private companion object {
        // U+1F44D THUMBS UP SIGN, built from its code point to keep this source ASCII-only.
        val thumbsUp: String = String(Character.toChars(0x1F44D))
    }
}
