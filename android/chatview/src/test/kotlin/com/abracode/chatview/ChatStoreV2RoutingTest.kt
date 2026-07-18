package com.abracode.chatview

// Port of Tests/ChatViewTests/ChatStoreV2Tests.swift's ChatStoreV2RoutingTests: the synchronous "Event routing"
// tests (upsert, status change + watermark ladder, reactions, edit, delete, member / call append, file progress,
// typing with a virtual-clock expiry, participants, history prepend). No transport is involved; the store is built
// with an inert coroutine scope so no queued send task or debounce flush can fire out from under a synchronous
// assertion.

import kotlin.time.Duration.Companion.seconds
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class ChatStoreV2RoutingTest {

    private fun makeStore(scheduler: ManualChatScheduler = ManualChatScheduler()): ChatStore =
        ChatStore(config = ChatConfiguration(), logger = noopLogger(), scheduler = scheduler, scope = inertScope())

    private fun msg(
        id: String,
        role: ChatRole,
        text: String,
        status: MessageStatus? = null,
        senderID: String? = null,
    ): ChatMessage = ChatMessage(id = id, role = role, text = text, isStreaming = false, senderID = senderID, status = status)

    private val thumbsUp = String(Character.toChars(0x1F44D))

    @Test
    fun messageReceivedInsertThenUpsertInPlace() {
        val store = makeStore()
        store.route(ChatEvent.MessageReceived(msg("m1", ChatRole.REMOTE, "hi")))
        store.route(ChatEvent.MessageReceived(msg("m2", ChatRole.LOCAL, "yo")))
        assertEquals(listOf("m1", "m2"), store.items.map { it.id })
        // A correction with the same id replaces in place, preserving position.
        store.route(ChatEvent.MessageReceived(msg("m1", ChatRole.REMOTE, "hi (edited by server)")))
        assertEquals("upsert keeps position", listOf("m1", "m2"), store.items.map { it.id })
        val m = (store.items[0] as ChatItem.Message).message
        assertEquals("hi (edited by server)", m.text)
    }

    @Test
    fun statusChangedAndUnknownIsNoOp() {
        val store = makeStore()
        store.route(ChatEvent.MessageReceived(msg("m1", ChatRole.LOCAL, "hi", status = MessageStatus.SENDING)))
        store.route(ChatEvent.MessageStatusChanged(itemID = "m1", status = MessageStatus.DELIVERED))
        val m = (store.items[0] as ChatItem.Message).message
        assertEquals(MessageStatus.DELIVERED, m.status)
        // Unknown id: tolerated, no crash, no new item.
        store.route(ChatEvent.MessageStatusChanged(itemID = "nope", status = MessageStatus.READ))
        assertEquals(1, store.items.count())
    }

    @Test
    fun statusWatermarkAdvancesOwnLowerMessagesUpToTarget() {
        val store = makeStore()
        store.route(ChatEvent.MessageReceived(msg("o1", ChatRole.LOCAL, "a", status = MessageStatus.SENT)))
        store.route(ChatEvent.MessageReceived(msg("o2", ChatRole.LOCAL, "b", status = MessageStatus.DELIVERED)))
        store.route(ChatEvent.MessageReceived(msg("r1", ChatRole.REMOTE, "reply")))          // not own - never marked
        store.route(ChatEvent.MessageReceived(msg("o3", ChatRole.LOCAL, "c", status = MessageStatus.SENT))) // AFTER target - untouched
        // Read up to o2: o1 (sent<read) and o2 (delivered<read) advance; o3 is after the target.
        store.route(ChatEvent.MessageStatusWatermark(status = MessageStatus.READ, upToItemID = "o2"))
        fun status(id: String): MessageStatus? =
            store.items.filterIsInstance<ChatItem.Message>().firstOrNull { it.message.id == id }?.message?.status
        assertEquals(MessageStatus.READ, status("o1"))
        assertEquals(MessageStatus.READ, status("o2"))
        assertEquals("a message after the target is not marked", MessageStatus.SENT, status("o3"))
    }

    @Test
    fun statusWatermarkNeverOverwritesFailedOrRegresses() {
        val store = makeStore()
        store.route(ChatEvent.MessageReceived(msg("o1", ChatRole.LOCAL, "a", status = MessageStatus.FAILED)))
        store.route(ChatEvent.MessageReceived(msg("o2", ChatRole.LOCAL, "b", status = MessageStatus.READ)))
        store.route(ChatEvent.MessageStatusWatermark(status = MessageStatus.DELIVERED, upToItemID = "o2"))
        fun status(id: String): MessageStatus? =
            store.items.filterIsInstance<ChatItem.Message>().firstOrNull { it.message.id == id }?.message?.status
        assertEquals("failed is never overwritten by a watermark", MessageStatus.FAILED, status("o1"))
        assertEquals("a higher status never regresses", MessageStatus.READ, status("o2"))
    }

    @Test
    fun watermarkResolvesSelfViaParticipantIsSelf() {
        val store = makeStore()
        store.route(
            ChatEvent.ParticipantsChanged(
                listOf(
                    Participant(id = "me", name = "Me", isSelf = true),
                    Participant(id = "them", name = "Them", isSelf = false),
                ),
            ),
        )
        store.route(ChatEvent.MessageReceived(msg("mine", ChatRole.REMOTE, "hi", status = MessageStatus.SENT, senderID = "me")))
        store.route(ChatEvent.MessageReceived(msg("theirs", ChatRole.REMOTE, "yo", status = MessageStatus.SENT, senderID = "them")))
        store.route(ChatEvent.MessageStatusWatermark(status = MessageStatus.READ, upToItemID = "theirs"))
        fun status(id: String): MessageStatus? =
            store.items.filterIsInstance<ChatItem.Message>().firstOrNull { it.message.id == id }?.message?.status
        assertEquals("a senderID marked isSelf counts as own", MessageStatus.READ, status("mine"))
        assertEquals("a non-self message is not marked", MessageStatus.SENT, status("theirs"))
    }

    @Test
    fun reactionsEditDeleteMutateInPlace() {
        val store = makeStore()
        store.route(ChatEvent.MessageReceived(msg("m1", ChatRole.REMOTE, "original")))
        store.route(ChatEvent.ReactionsChanged(itemID = "m1", reactions = listOf(Reaction(emoji = thumbsUp, count = 1, mine = true))))
        store.route(ChatEvent.MessageEdited(itemID = "m1", newText = "edited", editedAt = "2026-07-10T12:00:00Z"))
        val edited = (store.items[0] as ChatItem.Message).message
        assertEquals(thumbsUp, edited.reactions?.first()?.emoji)
        assertEquals("edited", edited.text)
        assertEquals("2026-07-10T12:00:00Z", edited.editedAt)
        store.route(ChatEvent.MessageDeleted(itemID = "m1"))
        val deleted = (store.items[0] as ChatItem.Message).message
        assertEquals(true, deleted.deleted)
        assertEquals("a tombstone blanks the text", "", deleted.text)
    }

    @Test
    fun memberAndCallEventsAppend() {
        val store = makeStore()
        store.route(ChatEvent.MemberEventReceived(MemberEvent(id = "ev1", kind = MemberEvent.Kind.JOINED, subjectName = "Sam")))
        store.route(ChatEvent.CallEventReceived(CallEvent(id = "c1", kind = CallEvent.Kind.MISSED_INCOMING)))
        assertEquals(listOf("ev1", "c1"), store.items.map { it.id })
    }

    @Test
    fun fileAddedAndProgressAndUnknownNoOp() {
        val store = makeStore()
        store.route(
            ChatEvent.FileAdded(
                ChatFile(
                    id = "f1",
                    role = ChatRole.REMOTE,
                    name = "a.pdf",
                    transferStatus = FileTransferStatus.TRANSFERRING,
                    progress = 0.1,
                ),
            ),
        )
        store.route(ChatEvent.FileProgress(itemID = "f1", progress = 0.9, transferStatus = FileTransferStatus.TRANSFERRING))
        val file = (store.items[0] as ChatItem.File).file
        assertEquals(0.9, file.progress)
        assertEquals(FileTransferStatus.TRANSFERRING, file.transferStatus)
        store.route(ChatEvent.FileProgress(itemID = "ghost", progress = 1.0, transferStatus = FileTransferStatus.COMPLETED)) // tolerated
        assertEquals(1, store.items.count())
    }

    @Test
    fun typingIndicatorExpiresOnTheVirtualClock() {
        val scheduler = ManualChatScheduler()
        val store = makeStore(scheduler)
        store.route(ChatEvent.TypingChanged(isTyping = true, senderID = "p2", senderName = "Alex"))
        assertEquals(listOf("p2"), store.typingParticipants.map { it.id })
        assertEquals("Alex", store.typingParticipants.first().name)
        scheduler.advance(9.seconds)
        assertEquals("still typing before the 10s failsafe", 1, store.typingParticipants.count())
        scheduler.advance(2.seconds)
        assertTrue("the 10s expiry clears a lost typing signal", store.typingParticipants.isEmpty())
    }

    @Test
    fun typingRefreshResetsExpiryAndExplicitStopClears() {
        val scheduler = ManualChatScheduler()
        val store = makeStore(scheduler)
        store.route(ChatEvent.TypingChanged(isTyping = true, senderID = "p2", senderName = "Alex"))
        scheduler.advance(8.seconds)
        store.route(ChatEvent.TypingChanged(isTyping = true, senderID = "p2", senderName = "Alex")) // refresh -> expiry now at +18
        scheduler.advance(8.seconds)
        assertEquals("a refresh reset the expiry", 1, store.typingParticipants.count())
        store.route(ChatEvent.TypingChanged(isTyping = false, senderID = "p2", senderName = null))
        assertTrue("an explicit stop clears immediately", store.typingParticipants.isEmpty())
    }

    @Test
    fun participantsChangedUpdatesRoster() {
        val store = makeStore()
        store.route(ChatEvent.ParticipantsChanged(listOf(Participant(id = "me", name = "Me", isSelf = true))))
        assertEquals(listOf("me"), store.participants.map { it.id })
    }

    @Test
    fun historyPagePrependsAndSetsFlags() {
        val store = makeStore()
        store.route(ChatEvent.MessageReceived(msg("m3", ChatRole.REMOTE, "newest")))
        store.route(
            ChatEvent.HistoryPage(
                items = listOf(
                    ChatItem.Message(msg("m1", ChatRole.REMOTE, "oldest")),
                    ChatItem.Message(msg("m2", ChatRole.LOCAL, "older")),
                ),
                hasMore = false,
            ),
        )
        assertEquals("older items prepend in order", listOf("m1", "m2", "m3"), store.items.map { it.id })
        assertFalse("hasMore=false ends paging", store.hasEarlier)
        assertFalse(store.isLoadingEarlier)
    }
}
