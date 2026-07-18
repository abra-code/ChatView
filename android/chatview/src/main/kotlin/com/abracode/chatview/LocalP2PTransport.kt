package com.abracode.chatview

// Port of Sources/ChatView/LocalP2PTransport.swift.
//
// The `local-p2p` transport: a scripted, no-wire person-to-person / group backend that exercises the entire v2
// vocabulary so the dual-alignment UI, the rows, paging, and the affordance gating all run end-to-end with no real
// transport. It is the demo content for the ChatPeople / ChatGroup examples and the behavioral fixture source.
//
// `config.transport.scenario` picks "people" (a 1:1 chat, default) or "group" (four participants with member / call
// events). It advertises ALL capabilities, seeds a short recent conversation, answers each user send with a scripted
// reply and a typing burst, honors reactions / edits / deletes / resends locally, and serves synthetic paged
// history on `.loadEarlier`. Swift's AsyncStream + Task map to a Channel + coroutines on an injectable-dispatcher
// scope; mutable state is guarded like Swift's NSLock.

import kotlinx.coroutines.CoroutineDispatcher
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.channels.ReceiveChannel
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import java.time.Instant
import java.time.format.DateTimeFormatter

class LocalP2PTransport(
    config: ChatTransportConfig,
    dispatcher: CoroutineDispatcher = Dispatchers.Default,
) : ChatTransport {

    private val channel = Channel<ChatEvent>(Channel.UNLIMITED)
    override val events: ReceiveChannel<ChatEvent> get() = channel

    override val capabilities = ChatTransportCapabilities(
        paging = true, typing = true, reactions = true, editing = true,
        deletion = true, replies = true, readReceipts = true, fileTransfer = true,
        messageIdentity = true, reportsConnectionState = true,
    )

    private val scenario: String = config.string("scenario") ?: "people"   // "people" | "group"
    private val stepMs: Int = (config.int("stepMs") ?: 700).coerceAtLeast(0)  // ms between scripted beats (0 in tests)

    private val scope = CoroutineScope(SupervisorJob() + dispatcher)
    private val lock = Any()
    private var replyCounter = 0                        // peer / generated / own server ids (peer-N, srv-N)
    private val jobs = mutableListOf<Job>()

    // Synthetic older history for paging: OLDEST first. `.loadEarlier` serves pages from the tail.
    private var history: List<ChatItem> = emptyList()
    private var historyCursor = 0                       // how many of `history` (from the end) have been served

    private val peerID = "alex"
    private val peerName = "Alex"

    // Built from code points so the source stays ASCII: U+1F44D thumbs-up, U+201C / U+201D curly double quotes.
    private val thumbsUp = String(Character.toChars(0x1F44D))
    private val leftQuote = String(Character.toChars(0x201C))
    private val rightQuote = String(Character.toChars(0x201D))

    // MARK: - Lifecycle

    override suspend fun start() {
        emit(ChatEvent.SessionReady(sessionID = "local-p2p", configOptions = emptyList()))
        emit(ChatEvent.ParticipantsChanged(roster()))
        // The link comes up: the composer starts connection-gated (the store defaults to .connecting) and enables on
        // this. At stepMs 0 (tests) it lands deterministically.
        emit(ChatEvent.ConnectionStateChanged(ChatConnectionState.CONNECTED))
        buildHistory()
        for (event in seedConversation()) {
            emit(event)
        }
        // A little life after load: the peer types, then sends one more line. Paced (interactive demo) mode only - at
        // stepMs 0 (tests / fixtures) the seed is deterministic.
        if (stepMs <= 0) {
            return
        }
        spawn {
            pause(2)
            emitPeerTyping()
            pause(1)
            val id = nextID("peer")
            emit(ChatEvent.TypingChanged(isTyping = false, senderID = peerID, senderName = peerName))
            emit(ChatEvent.MessageReceived(peerMessage(id = id, text = "Anyway - talk later!", minutesAgo = 0)))
        }
    }

    override suspend fun stop() {
        synchronized(lock) { jobs.toList() }.forEach { it.cancel() }
        channel.close()
        scope.cancel()
    }

    // MARK: - Commands

    override suspend fun send(command: ChatCommand) {
        when (command) {
            is ChatCommand.Prompt ->
                handleUserSend(text = command.text, replyTo = null, localID = nextID("user"))  // legacy path; mint a handle
            is ChatCommand.SendMessage ->
                handleUserSend(text = command.text, replyTo = command.replyTo, localID = command.localID)

            is ChatCommand.ToggleReaction -> {
                // Reflect the toggle authoritatively (the store sent optimistic intent; we echo the result).
                val reactions = if (command.add) listOf(Reaction(emoji = command.emoji, count = 1, mine = true)) else emptyList()
                emit(ChatEvent.ReactionsChanged(itemID = command.itemID, reactions = reactions))
            }

            is ChatCommand.EditMessage ->
                emit(ChatEvent.MessageEdited(itemID = command.itemID, newText = command.newText, editedAt = stamp(minutesAgo = 0)))

            is ChatCommand.DeleteMessage ->
                emit(ChatEvent.MessageDeleted(itemID = command.itemID))

            is ChatCommand.ResendMessage -> spawn {
                emit(ChatEvent.MessageStatusChanged(itemID = command.itemID, status = MessageStatus.SENDING))
                pause(1)
                emit(ChatEvent.MessageStatusWatermark(status = MessageStatus.DELIVERED, upToItemID = command.itemID))
            }

            is ChatCommand.LoadEarlier -> servePage(command.limit)

            is ChatCommand.CancelFileTransfer ->
                emit(ChatEvent.FileProgress(itemID = command.itemID, progress = null, transferStatus = FileTransferStatus.CANCELLED))

            is ChatCommand.MarkRead, is ChatCommand.SetTyping, is ChatCommand.Cancel,
            is ChatCommand.PermissionResponse, is ChatCommand.SetConfigOption -> Unit
        }
    }

    // MARK: - User send -> scripted reply

    private fun handleUserSend(text: String, replyTo: String?, localID: String) {
        // The store already appended the optimistic local message keyed by `localID`. Confirm a server id FIRST (the
        // store re-keys the item), then drive the delivery ladder on the SERVER id - exactly what a
        // server-authoritative transport does: own messages addressed only by the id the server assigned.
        val serverID = nextID("srv")
        emit(ChatEvent.MessageIDConfirmed(localID = localID, serverID = serverID))
        spawn {
            pause(1)
            emit(ChatEvent.MessageStatusChanged(itemID = serverID, status = MessageStatus.SENT))
            pause(1)
            emit(ChatEvent.MessageStatusChanged(itemID = serverID, status = MessageStatus.DELIVERED))
            emitPeerTyping()
            pause(2)
            emit(ChatEvent.TypingChanged(isTyping = false, senderID = peerID, senderName = peerName))
            val replyID = nextID("peer")
            emit(ChatEvent.MessageReceived(peerMessage(id = replyID, text = scriptedReply(text), minutesAgo = 0)))
            // The peer reads our message.
            pause(1)
            emit(ChatEvent.MessageStatusWatermark(status = MessageStatus.READ, upToItemID = serverID))
        }
    }

    private fun scriptedReply(text: String): String {
        val trimmed = text.trim()
        if (trimmed.lowercase().contains("?")) {
            return "Good question - let me check and get back to you."
        }
        return "Got it: $leftQuote${trimmed.take(80)}$rightQuote. Sounds good!"
    }

    // MARK: - Seeded conversation

    private fun seedConversation(): List<ChatEvent> {
        val events = mutableListOf<ChatEvent>()
        if (scenario == "group") {
            events.add(
                ChatEvent.MemberEventReceived(
                    MemberEvent(id = "ev-join-1", timestamp = stamp(daysAgo = 1, minute = 0), kind = MemberEvent.Kind.JOINED, subjectName = "Sam"),
                ),
            )
        }
        events.add(ChatEvent.MessageReceived(peerMessage(id = "seed-1", text = "Hey! Are we still on for tomorrow?", daysAgo = 1, minute = 1)))
        events.add(
            ChatEvent.MessageReceived(
                peerMessage(
                    id = "seed-2", text = "I found a great spot for lunch.", daysAgo = 1, minute = 1,
                    reactions = listOf(Reaction(emoji = thumbsUp, count = 1, mine = true)),
                ),
            ),
        )
        events.add(ChatEvent.MessageReceived(ownMessage(id = "seed-3", text = "Yes! Sounds perfect.", daysAgo = 0, minute = 0, status = MessageStatus.READ)))
        events.add(
            ChatEvent.MessageReceived(
                ownMessage(
                    id = "seed-4", text = "Let me double-check the time.", daysAgo = 0, minute = 1,
                    status = MessageStatus.DELIVERED, editedAt = stamp(daysAgo = 0, minute = 2),
                ),
            ),
        )
        if (scenario == "group") {
            events.add(
                ChatEvent.CallEventReceived(
                    CallEvent(id = "call-1", timestamp = stamp(daysAgo = 0, minute = 3), kind = CallEvent.Kind.MISSED_INCOMING, isVideo = true),
                ),
            )
            events.add(
                ChatEvent.MemberEventReceived(
                    MemberEvent(id = "ev-rename-1", timestamp = stamp(daysAgo = 0, minute = 4), kind = MemberEvent.Kind.RENAMED, actorName = "Alex", detail = "Weekend Trip"),
                ),
            )
        }
        // A file and a voice message from the peer.
        events.add(
            ChatEvent.FileAdded(
                ChatFile(
                    id = "file-1", role = ChatRole.REMOTE, senderID = peerID, senderName = peerName,
                    timestamp = stamp(daysAgo = 0, minute = 5), name = "itinerary.pdf",
                    sizeBytes = 284_160, url = "https://example.test/itinerary.pdf",
                    kind = ChatFile.Kind.FILE, transferStatus = FileTransferStatus.COMPLETED,
                ),
            ),
        )
        events.add(
            ChatEvent.FileAdded(
                ChatFile(
                    id = "voice-1", role = ChatRole.REMOTE, senderID = peerID, senderName = peerName,
                    timestamp = stamp(daysAgo = 0, minute = 6), name = "voice-message.m4a",
                    sizeBytes = 51_200, url = "https://example.test/voice.m4a",
                    kind = ChatFile.Kind.VOICE, durationSeconds = 14, transferStatus = FileTransferStatus.COMPLETED,
                ),
            ),
        )
        return events
    }

    // MARK: - Synthetic paging

    private fun buildHistory() {
        // 200 older messages, OLDEST first, alternating parties, a few days back.
        val items = mutableListOf<ChatItem>()
        for (index in 0 until 200) {
            val mine = index % 2 == 1
            val id = "hist-$index"
            val day = 6 - (index / 40)   // spread across several older days for day separators
            val text = "Earlier message #${index + 1}"
            if (mine) {
                items.add(ChatItem.Message(ownMessage(id = id, text = text, daysAgo = day, minute = index % 40, status = MessageStatus.READ)))
            } else {
                items.add(ChatItem.Message(peerMessage(id = id, text = text, daysAgo = day, minute = index % 40)))
            }
        }
        synchronized(lock) {
            history = items
            historyCursor = 0
        }
    }

    private fun servePage(limit: Int) {
        val page: List<ChatItem>
        val hasMore: Boolean
        synchronized(lock) {
            val remaining = history.size - historyCursor
            if (remaining <= 0) {
                page = emptyList()
                hasMore = false
            } else {
                val take = minOf(limit, remaining)
                // Serve the tail-most unseen slice, in chronological order.
                val upper = history.size - historyCursor
                val lower = upper - take
                page = history.subList(lower, upper).toList()
                historyCursor += take
                hasMore = historyCursor < history.size
            }
        }
        spawn {
            pause(1)
            emit(ChatEvent.HistoryPage(items = page, hasMore = hasMore))
        }
    }

    // MARK: - Helpers

    private fun roster(): List<Participant> {
        val people = mutableListOf(
            Participant(id = "me", name = "You", isSelf = true),
            Participant(id = peerID, name = peerName, avatarURL = null),
        )
        if (scenario == "group") {
            people.add(Participant(id = "sam", name = "Sam"))
            people.add(Participant(id = "jordan", name = "Jordan"))
        }
        return people
    }

    private fun emitPeerTyping() {
        emit(ChatEvent.TypingChanged(isTyping = true, senderID = peerID, senderName = peerName))
    }

    private fun peerMessage(
        id: String,
        text: String,
        daysAgo: Int = 0,
        minute: Int = 0,
        minutesAgo: Int? = null,
        reactions: List<Reaction>? = null,
    ): ChatMessage = ChatMessage(
        id = id, role = ChatRole.REMOTE, text = text, isStreaming = false, senderID = peerID, senderName = peerName,
        timestamp = if (minutesAgo != null) stamp(minutesAgo = minutesAgo) else stamp(daysAgo = daysAgo, minute = minute),
        reactions = reactions,
    )

    private fun ownMessage(
        id: String,
        text: String,
        daysAgo: Int = 0,
        minute: Int = 0,
        status: MessageStatus,
        editedAt: String? = null,
    ): ChatMessage = ChatMessage(
        id = id, role = ChatRole.LOCAL, text = text, isStreaming = false, senderID = "me",
        timestamp = stamp(daysAgo = daysAgo, minute = minute), status = status, editedAt = editedAt,
    )

    private fun nextID(prefix: String): String = synchronized(lock) { "$prefix-${++replyCounter}" }

    private fun spawn(body: suspend () -> Unit) {
        val job = scope.launch { body() }
        synchronized(lock) { jobs.add(job) }
    }

    private suspend fun pause(beats: Int) {
        if (stepMs > 0) {
            delay(stepMs.toLong() * beats)
        }
    }

    private fun emit(event: ChatEvent) {
        channel.trySend(event)
    }

    companion object {
        // A stable clock for the scripted timestamps: a fixed "now" so the seeded conversation is deterministic.
        private val base: Instant = Instant.parse("2026-07-10T15:00:00Z")

        private fun stamp(daysAgo: Int = 0, minute: Int = 0, minutesAgo: Int? = null): String {
            val seconds: Long = if (minutesAgo != null) {
                -minutesAgo.toLong() * 60
            } else {
                -daysAgo.toLong() * 86_400 + minute.toLong() * 60
            }
            return DateTimeFormatter.ISO_INSTANT.format(base.plusSeconds(seconds))
        }
    }
}
