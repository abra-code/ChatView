package com.abracode.chatview

// Port of Sources/ChatView/ChatStore.swift.
//
// The main-confined source of truth for one Chat element, and the router that pre-filters the transport's event
// stream. ChatStore owns the render model (the transcript `items`, the streaming flag, the pending-permission
// queue), builds the transport from the injected config, drains its ChatEvent stream, and reduces each event into a
// store mutation (route). Outbound, it appends the user's message optimistically, emits the host-facing
// ChatHostEvents, and hands a normalized ChatCommand to the transport.
//
// Kotlin mapping (plan section 5): Swift's @MainActor confinement maps to a single-threaded injected CoroutineScope
// - every `Task { ... }` becomes `scope.launch { ... }`, so route(), the send tasks, and the 50 ms flush all
// serialize on one dispatcher. AsyncStream<ChatEvent> is drained as a kotlinx ReceiveChannel. @Published fields are
// plain read-only properties here (A5 is pure logic); A6 wraps the same surface in Compose snapshot state without
// changing this class's public shape or mutation code. The scheduler is injectable for a virtual clock.

import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.serialization.Serializable
import kotlinx.serialization.builtins.ListSerializer
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.booleanOrNull
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.intOrNull
import kotlinx.serialization.json.put
import java.time.Instant
import kotlin.time.Duration
import kotlin.time.Duration.Companion.seconds

/** A subscription handle; cancel to stop observing. Mirrors Swift's AnyCancellable at the ChatContentSource seam. */
fun interface Cancellable {
    fun cancel()
}

/**
 * The component's content + operational-config channels. In an ActionUI host these are states["content"] and
 * states["config"]. Each observer receives the current value on subscription and on every change (the @Published
 * semantics the store's dedup relies on). Cancel to stop. A protocol so any host can provide the channels and the
 * restore path is testable with a fake.
 */
interface ChatContentSource {
    fun observeChatContent(handler: (Any?) -> Unit): Cancellable
    fun observeChatConfig(handler: (Any?) -> Unit): Cancellable
}

/** How a restored transcript relates to the agent's conversational context (the transient "prime" directive). */
internal enum class ChatPrimeDirective {
    RESUME,    // "prime": true / absent - replay the transcript into the agent NOW
    FRESH,     // "prime": false - display the transcript, seed an EMPTY context NOW
    DEFERRED,  // "prime": "defer" - display only; sync the context lazily on the next send
}

/** Whether the agent's context matches the displayed transcript (the status-bar indicator + deferred prime). */
enum class ChatContextState {
    SYNCED,    // the agent remembers the conversation shown
    PENDING,   // the conversation shown reaches the agent with the next message
    FRESH,     // intentionally empty context behind a displayed transcript ("prime": false)
}

internal class ChatStore(
    val config: ChatConfiguration,
    val logger: ChatLogger,
    private val contentSource: ChatContentSource? = null,
    scheduler: ChatScheduler? = null,
    private val hostEvents: ChatHostEventSink? = null,
    private val scope: CoroutineScope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate),
) {
    private val scheduler: ChatScheduler = scheduler ?: RealChatScheduler(scope)

    // --- Published render model (read-only to callers). Backed by plain fields in A5; A6 swaps to snapshot state.
    private val _items = mutableListOf<ChatItem>()
    val items: List<ChatItem> get() = _items
    var transcriptGeneration = 0; private set    // bumped when the transcript is replaced wholesale (view resets scroll/pin)
    var isStreaming = false; private set          // a reply turn is in flight
    var awaitingReply = false; private set        // a prompt was submitted but no reply event has arrived yet
    var isConfigured = false; private set         // a viable transport was built from states["config"]; the composer gates on this
    private val _pendingPermissions = mutableListOf<PermissionRequest>()
    val pendingPermissions: List<PermissionRequest> get() = _pendingPermissions   // FIFO; the card shows the head
    var plan: List<PlanEntry> = emptyList(); private set        // the agent's current plan (whole-list replace)
    var usage: UsageInfo? = null; private set                   // latest token/cost status, when reported
    var configOptions: List<SessionConfigOption> = emptyList(); private set   // model/mode/... advertised at session start
    var availableCommands: List<SlashCommand> = emptyList(); private set      // the agent's slash commands (composer menu)
    var contextState: ChatContextState = ChatContextState.SYNCED; private set // does the agent context match the display
    var draft: String = ""

    // Person-to-person (v2) surfaces the view observes.
    var participants: List<Participant> = emptyList(); private set            // group roster
    private val _typingParticipants = mutableListOf<TypingParticipant>()
    val typingParticipants: List<TypingParticipant> get() = _typingParticipants  // who is currently typing
    var hasEarlier: Boolean = true; private set                              // false once a history page reports no more
    var isLoadingEarlier: Boolean = false; private set                       // a history page is in flight
    var connectionState: ChatConnectionState = ChatConnectionState.CONNECTING; private set  // link state (reportsConnectionState transports)

    /** A participant currently shown in the typing indicator. `id` is the sender key; `name` labels the row. */
    data class TypingParticipant(val id: String, val name: String?)

    var title: String? = null; private set    // app-owned session label, passed through the transcript

    private var transport: ChatTransport? = null
    private var eventJob: Job? = null
    private var localCounter = 0
    private var didLoadInitial = false

    // Config-injection seam (states["config"]).
    private var didConfigure = false
    private var resolvedTransportConfig: ChatTransportConfig? = null
    private var configCancellable: Cancellable? = null

    // Coalescing: streaming deltas accumulate per item and flush at most ~20 Hz.
    private val streamBuffers = mutableMapOf<String, String>()
    private var flushPending = false

    // Session transcript seam: restore-in + incremental per-entry persistence.
    private var lastLoadedContent: ChatTranscript? = null
    private var contentCancellable: Cancellable? = null
    private var entrySequence = 0
    private var lastPrimeDirective: ChatPrimeDirective = ChatPrimeDirective.RESUME

    // Context-identity tracking behind `contextState` and the deferred prime. nil = unknown (a cancelled / errored
    // turn left a partial exchange agent-side), which forces a re-prime on the next send.
    private var wireContext: List<WireEntry>? = emptyList()

    // A restore that arrived while a turn was in flight supersedes that turn: swallow the superseded turn's terminal
    // messageEnd once so it does not re-run the turn-end bookkeeping. Reset on attach (a new event stream).
    private var supersededTurnPending = false

    /** One (speaker, text) pair of the agent-visible conversation - the equality unit for context matching. */
    private data class WireEntry(val local: Boolean, val text: String)

    // Person-to-person (v2) time-based behavior state.
    private var pinnedToBottom = true            // the view reports scroll pinning (drives read marks)
    private var sceneActive = true               // the view reports foreground/active (drives read marks)
    private var lastReadMarkItemID: String? = null   // the last id we emitted markRead up to (advance-only)
    private var isTypingActive = false           // we have an outstanding setTyping(true) not yet stopped
    private var lastTypingSentAt: Instant? = null    // throttle: when we last emitted setTyping(true)

    /** The active transport's advertised P2P capabilities (none before the transport is built). */
    private val capabilities: ChatTransportCapabilities
        get() = transport?.capabilities ?: ChatTransportCapabilities()

    /** The composer may accept input only when the transport is not connection-gated, or is connected. */
    val isConnectionReady: Boolean
        get() = !capabilities.reportsConnectionState || connectionState == ChatConnectionState.CONNECTED

    /** A one-line banner when a reporting transport is not yet connected; null otherwise. */
    val connectionBannerText: String?
        get() {
            if (!capabilities.reportsConnectionState || connectionState == ChatConnectionState.CONNECTED) {
                return null
            }
            return when (connectionState) {
                ChatConnectionState.CONNECTING -> "Connecting..."
                ChatConnectionState.RECONNECTING -> "Reconnecting..."
                ChatConnectionState.OFFLINE -> "Offline"
                ChatConnectionState.CONNECTED -> null
            }
        }

    /**
     * Loads any pre-populated transcript once, (re)starts observing runtime restores through the content channel,
     * and - unless readOnly - builds the transport and drains its event stream. Safe to call again after teardown
     * (which tears the transport / subscription down but preserves the transcript).
     */
    fun start() {
        // One-time pre-populated load (a preview / testing convenience, NOT the production path).
        if (!didLoadInitial) {
            didLoadInitial = true
            config.initialContentRaw?.let { raw ->
                val transcript = ChatTranscript.decode(raw)
                if (transcript != null) {
                    applyLoadedTranscript(transcript)
                    lastLoadedContent = transcript
                } else {
                    logger.log("Chat properties.content is not a decodable transcript; ignoring", ChatLogLevel.WARNING)
                }
            }
        }
        // (Re)subscribe to runtime restores through the content channel. The dedup against lastLoadedContent ignores
        // the subscription's immediate delivery of a value already loaded.
        if (contentCancellable == null) {
            contentSource?.let { source ->
                contentCancellable = source.observeChatContent { newContent -> reconcileRestoredContent(newContent) }
            }
        }

        // readOnly is the history-viewer mode: no transport, no config observation.
        if (config.readOnly) {
            return
        }

        // (Re)subscribe to the host-injected operational config. The sink delivers the current value on subscription
        // AND on every change, so init-time injection is never "too late".
        if (configCancellable == null) {
            contentSource?.let { source ->
                configCancellable = source.observeChatConfig { newConfig -> reconcileConfig(newConfig) }
            }
        }

        // Reappearance: rebuild the torn-down transport from the frozen decision (ignoring any post-freeze change).
        val resolved = resolvedTransportConfig
        if (didConfigure && transport == null && resolved != null) {
            val rebuilt = ChatTransportRegistry.shared.makeIfViable(resolved.protocolName, resolved.settings, logger)
            if (rebuilt != null) {
                attach(rebuilt)
            }
        }
    }

    // MARK: - Config injection (states["config"]) -> deferred, frozen transport

    /**
     * Handles a host-injected operational config. Builds the transport the FIRST time the config resolves to a
     * viable one; after that an IDENTICAL config is ignored while a DIFFERENT viable one RE-CONFIGURES (tear down +
     * attach + re-prime). A not-yet-viable config neither builds nor re-configures. Internal so tests can drive it.
     */
    fun reconcileConfig(raw: Any?) {
        if (config.readOnly) {
            return
        }
        val parsed = parseTransportConfig(raw) ?: return   // no config object yet - stay inert
        val (protocolName, transportSettings) = parsed
        // Dedup: the resolved config only re-applies when it actually CHANGED.
        val resolved = resolvedTransportConfig
        if (didConfigure && resolved != null &&
            resolved.protocolName == protocolName && resolved.settings == transportSettings
        ) {
            return
        }
        val built = ChatTransportRegistry.shared.makeIfViable(protocolName, transportSettings, logger)
        if (built == null) {
            logger.log(
                "Chat config for protocol '$protocolName' is not viable yet; awaiting a complete states[\"config\"]",
                ChatLogLevel.VERBOSE,
            )
            return
        }
        if (didConfigure) {
            // Re-configuration: stop the old transport cleanly and clear any in-flight turn state it can no longer
            // resolve, plus the old session's status surfaces (the new session re-emits its own at sessionReady).
            logger.log("Chat config changed; re-configuring the transport (protocol '$protocolName')", ChatLogLevel.VERBOSE)
            eventJob?.cancel()
            eventJob = null
            streamBuffers.clear()
            _pendingPermissions.clear()
            isStreaming = false
            awaitingReply = false
            plan = emptyList()
            usage = null
            configOptions = emptyList()
            availableCommands = emptyList()
            val old = transport
            transport = null
            scope.launch { old?.stop() }
        }
        didConfigure = true
        resolvedTransportConfig = ChatTransportConfig(protocolName = protocolName, settings = transportSettings)
        isConfigured = true
        attach(built)
    }

    /**
     * Parses the config channel's value into (protocolName, transport). Accepts a dict / map, a JSON string, or JSON
     * bytes. A missing `protocol` defaults to "local"; a missing `transport` is an empty object. Null when there is
     * no config object.
     */
    private fun parseTransportConfig(raw: Any?): Pair<String, JsonObject>? {
        val dict = rawToJsonObject(raw) ?: return null
        val protocolName = (dict["protocol"] as? JsonPrimitive)?.takeIf { it.isString }?.content
            ?: ChatTransportRegistry.reservedLocalName
        val transportSettings = dict["transport"] as? JsonObject ?: JsonObject(emptyMap())
        return protocolName to transportSettings
    }

    /** Installs a built transport and starts draining its event stream. */
    private fun attach(transport: ChatTransport) {
        this.transport = transport
        connectionState = ChatConnectionState.CONNECTING   // ignored unless the transport reports it; re-gates a rebuild
        // A freshly attached transport fronts a NEW agent session (context known-empty until a prime reaches it), and
        // is a new event stream (a stale supersession flag must not swallow a real turn end).
        wireContext = emptyList()
        supersededTurnPending = false
        // Seed the new transport's wire history from any already-restored items (applying the last prime directive).
        primeTransportFromItems()
        eventJob = scope.launch {
            transport.start()
            for (event in transport.events) {
                route(event)
            }
        }
    }

    /**
     * Seeds the active transport's wire history from the current transcript's message items, so a continued
     * conversation is sent with its prior turns as context. No-op when no transport exists yet. Called synchronously
     * from applyLoadedTranscript and attach, always before any subsequent prompt.
     */
    private fun primeTransportFromItems() {
        val transport = this.transport ?: return
        // Reserve every loaded item id first (ALL ids, including thoughts / tool cards), so a continued turn cannot
        // mint an id the transport already used. Id reservation is collision safety, independent of the prime choice.
        transport.reserveIDs(items.map { it.id })
        val current = wireEntries(items)
        when (lastPrimeDirective) {
            ChatPrimeDirective.RESUME -> {
                // Context follows display, immediately (the documented default).
                transport.primeHistory(messageItems())
                wireContext = current
                contextState = ChatContextState.SYNCED
            }
            ChatPrimeDirective.FRESH -> {
                // "prime": false shows the transcript but seeds an EMPTY wire history. Never re-primed at send time.
                transport.primeHistory(emptyList())
                wireContext = emptyList()
                contextState = if (current.isEmpty()) ChatContextState.SYNCED else ChatContextState.FRESH
            }
            ChatPrimeDirective.DEFERRED -> {
                // Display only: the agent is untouched. Synced if its context already matches the display, else pending.
                contextState = if (wireContext == current) ChatContextState.SYNCED else ChatContextState.PENDING
            }
        }
    }

    /** The transcript's message items (role + text) - the payload primeHistory takes. */
    private fun messageItems(): List<ChatMessage> =
        items.mapNotNull { (it as? ChatItem.Message)?.message }

    // MARK: - User intent

    /** Submits the current composer draft, if non-empty. `replyTo` quotes a message. */
    fun submitDraft(replyTo: String? = null) {
        val text = draft.trim()
        if (text.isEmpty()) {
            return
        }
        draft = ""
        stopTypingSignal()                 // sending ends the typing state
        send(text, replyTo)
    }

    /**
     * Appends the user's message optimistically, emits Send / MessageFinalized, and forwards it to the transport. A
     * plain send goes as Prompt (the v1 path); a reply goes as SendMessage when both the document's replies feature
     * and the transport's replies capability allow it. A readReceipts transport starts the message at sending.
     */
    fun send(text: String, replyTo: String? = null) {
        syncDeferredContext()
        localCounter += 1
        val itemID = "user-$localCounter"
        val repliesAllowed = replyTo != null && config.features.replies && capabilities.replies
        val replyRef = if (repliesAllowed) replyTo?.let { makeReplyRef(it) } else null
        val status: MessageStatus? = if (capabilities.readReceipts) MessageStatus.SENDING else null
        val message = ChatMessage(id = itemID, role = ChatRole.LOCAL, text = text, isStreaming = false,
            status = status, replyTo = replyRef)
        _items.add(ChatItem.Message(message))
        emit(ChatHostEvent.Send)
        emit(ChatHostEvent.MessageFinalized)
        fireEntry("message", itemID) { itemElement(ChatItem.Message(message)) }
        // Enter the awaiting-reply state until the terminal messageEnd / error (or a restore).
        awaitingReply = true
        val transport = this.transport
        // A messageIdentity transport always sends through SendMessage (carrying the optimistic itemID as localID); a
        // v1 / agent transport still uses Prompt, byte-for-byte as before.
        val useMessageSend = capabilities.messageIdentity || repliesAllowed
        if (useMessageSend) {
            val ref = if (repliesAllowed) replyTo else null
            scope.launch { transport?.send(ChatCommand.SendMessage(text = text, replyTo = ref, localID = itemID)) }
        } else {
            scope.launch { transport?.send(ChatCommand.Prompt(text = text)) }
        }
    }

    /**
     * The lazy half of a deferred restore: when the displayed conversation has not reached the agent, replay it NOW,
     * synchronously before the prompt is dispatched. Skipped when the agent's context already matches the display; a
     * fresh context is never re-primed. Called at the top of send().
     */
    private fun syncDeferredContext() {
        if (contextState != ChatContextState.PENDING) {
            return
        }
        val transport = this.transport ?: return
        val current = wireEntries(items)
        if (wireContext != current) {
            transport.primeHistory(messageItems())
        }
        wireContext = current
        contextState = ChatContextState.SYNCED
    }

    /** Requests cancellation of the in-flight turn. */
    fun stop() {
        emit(ChatHostEvent.Stop)
        val transport = this.transport
        scope.launch { transport?.send(ChatCommand.Cancel) }
    }

    /** Changes a session option from the status-line menus. Deliberately NOT optimistic. */
    fun setConfigOption(optionID: String, value: String) {
        val transport = this.transport
        scope.launch { transport?.send(ChatCommand.SetConfigOption(optionID = optionID, value = value)) }
    }

    /** Answers a pending permission request (`optionID` = a choice, or null for a dismissal). */
    fun respondToPermission(requestID: String, optionID: String?) {
        _pendingPermissions.removeAll { it.id == requestID }
        val transport = this.transport
        scope.launch { transport?.send(ChatCommand.PermissionResponse(requestID = requestID, optionID = optionID)) }
    }

    // MARK: - Person-to-person (v2) affordance availability (view display gating)

    val canReact: Boolean get() = config.features.reactions && capabilities.reactions
    val canEditMessages: Boolean get() = config.features.editing && capabilities.editing
    val canDeleteMessages: Boolean get() = config.features.deletion && capabilities.deletion
    val canReply: Boolean get() = config.features.replies && capabilities.replies
    val canAttach: Boolean get() = config.attachEnabled

    /** Emits the attach host event (the composer paperclip). No-op when the host did not enable attach. */
    fun triggerAttach() {
        emit(ChatHostEvent.Attach)
    }

    // MARK: - Person-to-person (v2) command helpers (view -> transport)

    /** Toggles the local user's reaction with `emoji` (remove when already mine, else add). */
    fun toggleReaction(itemID: String, emoji: String) {
        if (!config.features.reactions || !capabilities.reactions) {
            return
        }
        val mine = reactions(itemID)?.firstOrNull { it.emoji == emoji }?.mine ?: false
        val transport = this.transport
        scope.launch { transport?.send(ChatCommand.ToggleReaction(itemID = itemID, emoji = emoji, add = !mine)) }
    }

    /** Edits an own message. Not optimistic: the transport confirms with messageEdited. */
    fun editMessage(itemID: String, newText: String) {
        if (!config.features.editing || !capabilities.editing) {
            return
        }
        val trimmed = newText.trim()
        if (trimmed.isEmpty()) {
            return
        }
        val transport = this.transport
        scope.launch { transport?.send(ChatCommand.EditMessage(itemID = itemID, newText = trimmed)) }
    }

    /** Deletes an own message. Not optimistic: the transport confirms with messageDeleted. */
    fun deleteMessage(itemID: String) {
        if (!config.features.deletion || !capabilities.deletion) {
            return
        }
        val transport = this.transport
        scope.launch { transport?.send(ChatCommand.DeleteMessage(itemID = itemID)) }
    }

    /**
     * Retries a failed message OR a failed file / voice transfer. Not feature-gated - resend is intrinsic to sending;
     * it only reaches a P2P transport that produced the failed state. Both reuse the one ResendMessage command.
     */
    fun resendMessage(itemID: String) {
        when (val existing = item(itemID)) {
            is ChatItem.Message -> {
                if (existing.message.status != MessageStatus.FAILED) {
                    return
                }
                mutateMessage(itemID, "resend") { it.copy(status = MessageStatus.SENDING) }
            }
            is ChatItem.File -> {
                if (existing.file.transferStatus != FileTransferStatus.FAILED) {
                    return
                }
                mutateFile(itemID, fireOnTerminal = false) {
                    it.copy(transferStatus = FileTransferStatus.TRANSFERRING, progress = 0.0)
                }
            }
            else -> return
        }
        val transport = this.transport
        scope.launch { transport?.send(ChatCommand.ResendMessage(itemID = itemID)) }
    }

    /** Cancels an in-flight file / voice transfer. */
    fun cancelFileTransfer(itemID: String) {
        if (!capabilities.fileTransfer) {
            return
        }
        val transport = this.transport
        scope.launch { transport?.send(ChatCommand.CancelFileTransfer(itemID = itemID)) }
    }

    // MARK: - Person-to-person (v2) store-initiated behaviors

    /** The view reports the transcript scrolled near the top; request the previous page when appropriate. */
    fun scrolledNearTop() {
        val topID = items.firstOrNull()?.id
        if (!capabilities.paging || !hasEarlier || isLoadingEarlier || topID == null) {
            return
        }
        isLoadingEarlier = true
        val transport = this.transport
        scope.launch { transport?.send(ChatCommand.LoadEarlier(beforeItemID = topID, limit = 50)) }
    }

    /** The view reports whether the transcript is pinned to the bottom (drives read receipts). */
    fun setPinnedToBottom(pinned: Boolean) {
        pinnedToBottom = pinned
        maybeScheduleReadMark()
    }

    /** The view reports whether the scene is active / foreground (drives read receipts). */
    fun setSceneActive(active: Boolean) {
        sceneActive = active
        maybeScheduleReadMark()
    }

    /** Composer text activity: emit an outgoing typing signal, throttled to at most one per typingThrottle. */
    fun notifyComposerActivity() {
        if (!capabilities.typing) {
            return
        }
        val now = scheduler.now
        val last = lastTypingSentAt
        if (last != null && (now.toEpochMilli() - last.toEpochMilli()) < typingThrottleMillis) {
            return
        }
        lastTypingSentAt = now
        isTypingActive = true
        val transport = this.transport
        scope.launch { transport?.send(ChatCommand.SetTyping(isTyping = true)) }
    }

    /** Ends the outgoing typing state (on send, clear, or blur). A no-op when not currently typing. */
    fun stopTypingSignal() {
        if (!capabilities.typing || !isTypingActive) {
            return
        }
        isTypingActive = false
        lastTypingSentAt = null
        val transport = this.transport
        scope.launch { transport?.send(ChatCommand.SetTyping(isTyping = false)) }
    }

    /** Finishes the transport and tears down. Called from the view's onDisappear; idempotent. */
    fun teardown() {
        eventJob?.cancel()
        eventJob = null
        contentCancellable?.cancel()
        contentCancellable = null
        configCancellable?.cancel()
        configCancellable = null
        streamBuffers.clear()
        _pendingPermissions.clear()
        scheduler.cancel(readMarkKey)
        for (participant in typingParticipants) {
            scheduler.cancel(typingExpiryKey(participant.id))
        }
        // Clear the in-flight turn state too: the store outlives a disappear/reappear cycle, so a turn abandoned by
        // teardown must not leave isStreaming / awaitingReply stuck true.
        isStreaming = false
        awaitingReply = false
        connectionState = ChatConnectionState.CONNECTING   // reset for cleanliness; the composer is gated by isConfigured while torn down
        val transport = this.transport
        this.transport = null
        scope.launch { transport?.stop() }
    }

    // MARK: - Router (pre-filter): ChatEvent -> store mutation

    // Internal (not private) so tests can drive the reduction directly.
    fun route(event: ChatEvent) {
        when (event) {
            is ChatEvent.SessionReady -> {
                configOptions = event.configOptions
                logger.log("Chat session ready: ${event.sessionID}", ChatLogLevel.VERBOSE)
            }

            is ChatEvent.MessageStart -> {
                finalizeOpenThoughts()
                _items.add(ChatItem.Message(ChatMessage(id = event.itemID, role = event.role, text = "", isStreaming = true)))
                streamBuffers[event.itemID] = ""
                if (event.role != ChatRole.LOCAL) {
                    isStreaming = true
                }
            }

            is ChatEvent.MessageDelta -> {
                if (streamBuffers[event.itemID] != null) {
                    streamBuffers[event.itemID] = streamBuffers[event.itemID] + event.text
                    scheduleFlush()
                } else {
                    // A delta with no prior start: open an agent message implicitly.
                    _items.add(ChatItem.Message(ChatMessage(id = event.itemID, role = ChatRole.AGENT, text = "", isStreaming = true)))
                    streamBuffers[event.itemID] = event.text
                    isStreaming = true
                    scheduleFlush()
                }
            }

            is ChatEvent.MessageEnd -> {
                // Final flush is immediate (do not wait for the coalescing tick), then finalize.
                finalizeOpenThoughts()
                val finalText = streamBuffers[event.itemID]
                streamBuffers.remove(event.itemID)
                val index = messageIndex(event.itemID)
                if (index != null) {
                    mutateStreamingText(index) {
                        var m = it
                        if (finalText != null) {
                            m = m.copy(text = finalText)
                        }
                        m.copy(isStreaming = false)
                    }
                    (items[index] as? ChatItem.Message)?.let { finalized ->
                        fireEntry("message", event.itemID) { itemElement(ChatItem.Message(finalized.message)) }
                    }
                }
                emit(ChatHostEvent.MessageFinalized)
                // A null stopReason closes only this message (a segmented transport). A non-null stopReason ends the
                // whole turn: streaming clears and any abandoned permission is moot.
                val stopReason = event.stopReason
                if (stopReason != null) {
                    isStreaming = false
                    awaitingReply = false
                    _pendingPermissions.clear()
                    trackContextAfterTurn(stopReason)
                }
            }

            is ChatEvent.ThoughtDelta -> {
                if (config.surfaces.thoughts == ChatConfiguration.SurfaceMode.HIDDEN) {
                    return
                }
                if (streamBuffers[event.itemID] != null) {
                    streamBuffers[event.itemID] = streamBuffers[event.itemID] + event.text
                } else {
                    _items.add(ChatItem.Thought(ChatMessage(id = event.itemID, role = ChatRole.AGENT, text = "", isStreaming = true)))
                    streamBuffers[event.itemID] = event.text
                    isStreaming = true
                }
                scheduleFlush()
            }

            is ChatEvent.ToolCall -> {
                finalizeOpenThoughts()
                if (config.surfaces.toolCalls == ChatConfiguration.SurfaceMode.HIDDEN) {
                    return
                }
                _items.add(ChatItem.ToolCall(event.call))
                isStreaming = true
                fireEntryForCompletedToolCall(event.call)
            }

            is ChatEvent.ToolCallUpdateEvent -> {
                if (config.surfaces.toolCalls == ChatConfiguration.SurfaceMode.HIDDEN) {
                    return
                }
                val index = toolCallIndex(event.update.id)
                if (index == null) {
                    logger.log("Chat tool_call_update for unknown call '${event.update.id}'; ignoring", ChatLogLevel.VERBOSE)
                    return
                }
                var call = (items[index] as? ChatItem.ToolCall)?.call ?: return
                val u = event.update
                if (u.title != null) call = call.copy(title = u.title)
                if (u.kind != null) call = call.copy(kind = u.kind)
                if (u.status != null) call = call.copy(status = u.status)
                if (u.contentText != null) call = call.copy(contentText = u.contentText)
                if (u.diff != null) call = call.copy(diff = u.diff)
                if (u.rawInput != null) call = call.copy(rawInput = u.rawInput)
                if (u.rawOutput != null) call = call.copy(rawOutput = u.rawOutput)
                _items[index] = ChatItem.ToolCall(call)
                fireEntryForCompletedToolCall(call)
            }

            is ChatEvent.PermissionRequestEvent -> {
                finalizeOpenThoughts()
                _pendingPermissions.add(event.request)
                isStreaming = true
                emit(ChatHostEvent.ToolApprovalRequested)
            }

            is ChatEvent.Plan -> {
                if (config.surfaces.plan == ChatConfiguration.SurfaceMode.HIDDEN) {
                    return
                }
                // The agent re-emits its WHOLE plan as it progresses: replace, never merge.
                plan = event.entries
                fireEntry("plan", null) { chatJson.encodeToJsonElement(ListSerializer(PlanEntry.serializer()), event.entries) }
            }

            is ChatEvent.Usage -> {
                usage = event.usage
                fireEntry("usage", null) { chatJson.encodeToJsonElement(UsageInfo.serializer(), event.usage) }
            }

            is ChatEvent.CurrentModeChanged -> {
                // current_mode_update names only the new value; it targets the mode option (by category, else id "mode").
                val index = configOptions.indexOfFirst { it.category == "mode" || it.id == "mode" }
                if (index < 0) {
                    logger.log("Chat current_mode_update '${event.modeID}' with no mode option; ignoring", ChatLogLevel.VERBOSE)
                    return
                }
                configOptions = configOptions.toMutableList().also {
                    it[index] = it[index].copy(currentValue = event.modeID)
                }
            }

            is ChatEvent.CommandsAvailable -> {
                // The agent re-emits its WHOLE command set as it changes: replace, never merge.
                availableCommands = event.commands
            }

            is ChatEvent.ConfigOptionsChanged -> {
                // A setter's confirmation: the refreshed option set replaces the display.
                configOptions = event.options
            }

            is ChatEvent.Image -> {
                _items.add(ChatItem.Image(id = event.itemID, role = event.role, image = event.image))
                emit(ChatHostEvent.MessageFinalized)
                fireEntry("image", event.itemID) { itemElement(ChatItem.Image(id = event.itemID, role = event.role, image = event.image)) }
            }

            is ChatEvent.System -> {
                localCounter += 1
                val itemID = "system-$localCounter"
                _items.add(ChatItem.System(id = itemID, text = event.text))
                fireEntry("system", itemID) { itemElement(ChatItem.System(id = itemID, text = event.text)) }
            }

            is ChatEvent.Error -> {
                localCounter += 1
                val itemID = "error-$localCounter"
                _items.add(ChatItem.Error(id = itemID, text = event.message))
                awaitingReply = false   // defensive: an error without a trailing messageEnd still drops the spinner
                emit(ChatHostEvent.Error)
                fireEntry("error", itemID) { itemElement(ChatItem.Error(id = itemID, text = event.message)) }
            }

            // --- P2P (v2) events. These do NOT drive awaitingReply / isStreaming.

            is ChatEvent.MessageReceived -> {
                val existed = upsertMessage(event.message)
                emit(ChatHostEvent.MessageFinalized)
                fireEntry("message", event.message.id, updated = existed) { itemElement(ChatItem.Message(event.message.finalized())) }
                maybeScheduleReadMark()
            }

            is ChatEvent.MessageIDConfirmed -> {
                reconcileMessageID(event.localID, event.serverID)
            }

            is ChatEvent.MessageStatusChanged -> {
                mutateMessage(event.itemID, "message_status") { it.copy(status = event.status) }
            }

            is ChatEvent.MessageStatusWatermark -> {
                applyStatusWatermark(event.status, event.upToItemID)
            }

            is ChatEvent.ReactionsChanged -> {
                mutateMessage(event.itemID, "reactions") { it.copy(reactions = event.reactions) }
            }

            is ChatEvent.MessageEdited -> {
                mutateMessage(event.itemID, "edit") { it.copy(text = event.newText, editedAt = event.editedAt) }
            }

            is ChatEvent.MessageDeleted -> {
                mutateMessage(event.itemID, "delete") {
                    // a tombstone renders no text; blank it so a persisted copy carries none
                    it.copy(deleted = true, text = "")
                }
            }

            is ChatEvent.MemberEventReceived -> {
                _items.add(ChatItem.MemberEventItem(event.event))
                fireEntry("memberEvent", event.event.id) { itemElement(ChatItem.MemberEventItem(event.event)) }
                maybeScheduleReadMark()
            }

            is ChatEvent.CallEventReceived -> {
                _items.add(ChatItem.CallEventItem(event.event))
                fireEntry("callEvent", event.event.id) { itemElement(ChatItem.CallEventItem(event.event)) }
                maybeScheduleReadMark()
            }

            is ChatEvent.FileAdded -> {
                val existed = upsertFile(event.file)
                emit(ChatHostEvent.MessageFinalized)
                // Fire on add, and again (updated) once terminal - so per-tick progress does not spam the channel.
                val terminal = event.file.transferStatus == FileTransferStatus.COMPLETED ||
                    event.file.transferStatus == FileTransferStatus.FAILED ||
                    event.file.transferStatus == FileTransferStatus.CANCELLED
                if (!existed || terminal) {
                    fireEntry("file", event.file.id, updated = existed) { itemElement(ChatItem.File(event.file)) }
                }
                maybeScheduleReadMark()
            }

            is ChatEvent.FileProgress -> {
                val terminal = event.transferStatus == FileTransferStatus.COMPLETED ||
                    event.transferStatus == FileTransferStatus.FAILED ||
                    event.transferStatus == FileTransferStatus.CANCELLED
                mutateFile(event.itemID, fireOnTerminal = terminal) {
                    it.copy(progress = event.progress, transferStatus = event.transferStatus)
                }
            }

            is ChatEvent.TypingChanged -> {
                updateTypingIndicator(event.isTyping, event.senderID, event.senderName)
            }

            is ChatEvent.ParticipantsChanged -> {
                participants = event.participants
                fireEntry("participants", null) { chatJson.encodeToJsonElement(ListSerializer(Participant.serializer()), event.participants) }
            }

            is ChatEvent.HistoryPage -> {
                prependHistory(event.items, event.hasMore)
            }

            is ChatEvent.ConnectionStateChanged -> {
                connectionState = event.state
            }
        }
    }

    // MARK: - Session transcript seam: restore-in + incremental per-entry persistence

    /**
     * Handles a transcript a host restored through the content channel. Ignores content already loaded; a new
     * transcript replaces the session. Internal so tests can drive a restore directly.
     */
    fun reconcileRestoredContent(newContent: Any?) {
        val transcript = ChatTranscript.decode(newContent) ?: return
        // The transient "prime" directive rides on the raw injected JSON (the codec drops the unknown key). It
        // participates in the dedup: the same transcript re-injected with a flipped flag must re-apply.
        val prime = parsePrimeDirective(newContent)
        if (transcript == lastLoadedContent && prime == lastPrimeDirective) {
            return
        }
        lastPrimeDirective = prime
        applyLoadedTranscript(transcript)
        lastLoadedContent = transcript
    }

    /**
     * Reads the transient `prime` directive off a raw content value. true / absent / unparseable -> resume; false ->
     * fresh; "defer" -> deferred.
     */
    private fun parsePrimeDirective(raw: Any?): ChatPrimeDirective {
        val dict = rawToJsonObject(raw) ?: return ChatPrimeDirective.RESUME
        val prime = dict["prime"]
        if (prime is JsonPrimitive && !prime.isString) {
            prime.booleanOrNull?.let { return if (it) ChatPrimeDirective.RESUME else ChatPrimeDirective.FRESH }
            when (prime.intOrNull) {
                0 -> return ChatPrimeDirective.FRESH
                1 -> return ChatPrimeDirective.RESUME
            }
        }
        if (prime is JsonPrimitive && prime.isString && prime.content == "defer") {
            return ChatPrimeDirective.DEFERRED
        }
        return ChatPrimeDirective.RESUME
    }

    /**
     * Replaces the session state with a loaded transcript: items render in their final states, the streaming /
     * permission / buffer state is cleared, and the status surfaces are restored.
     */
    private fun applyLoadedTranscript(transcript: ChatTranscript) {
        val turnWasInFlight = isStreaming || awaitingReply
        _items.clear()
        _items.addAll(transcript.items)
        transcriptGeneration += 1
        usage = transcript.usage
        plan = transcript.plan
        title = transcript.title
        participants = transcript.participants ?: emptyList()
        isStreaming = false
        awaitingReply = false
        _pendingPermissions.clear()
        streamBuffers.clear()
        // A restored session supersedes any read-mark / typing state.
        lastReadMarkItemID = null
        _typingParticipants.clear()
        // Advance the id counter past any store-generated ids in the loaded transcript.
        advanceLocalCounter(transcript.items)
        // A restore mid-turn supersedes the turn: its terminal messageEnd must not re-run the turn-end bookkeeping.
        if (turnWasInFlight) {
            supersededTurnPending = true
        }
        // A deferred restore arriving mid-turn still cancels the in-flight turn - its stream has nowhere to render
        // now. The agent is left holding a partial exchange, so the context becomes unknown and the next send re-primes.
        if (lastPrimeDirective == ChatPrimeDirective.DEFERRED && turnWasInFlight) {
            wireContext = null
            val transport = this.transport
            scope.launch { transport?.send(ChatCommand.Cancel) }
        }
        // Seed the transport's wire history from the loaded transcript (P0-2 continue-in). No-op if not built yet.
        primeTransportFromItems()
    }

    /**
     * Emits Entry (when the host enabled entry events) with a sorted-keys JSON envelope for one finalized transcript
     * entry. Never called on streaming deltas. The sequence commits only when the payload encodes.
     */
    private fun fireEntry(type: String, id: String?, updated: Boolean = false, payload: () -> JsonElement) {
        if (!config.emitsEntryEvents || hostEvents == null) {
            return
        }
        // Compute the next sequence but commit it only if the payload encodes (an encode failure must not burn a number).
        val next = entrySequence + 1
        val json = runCatching {
            val obj = buildJsonObject {
                put("sequence", next)
                put("type", type)
                if (id != null) put("id", id)
                put("data", payload())
                if (updated) put("updated", true)
            }
            canonicalEntryJson(sortJsonElement(obj))
        }.getOrElse {
            logger.log("Chat: could not encode entry payload for '$type'; skipping", ChatLogLevel.WARNING)
            return
        }
        entrySequence = next
        emit(ChatHostEvent.Entry(json))
    }

    /** Fires the "toolCall" entry whenever a tool call is in (or reaches) a terminal state; re-fires on later updates. */
    private fun fireEntryForCompletedToolCall(call: ToolCallModel) {
        if (call.status != ToolCallModel.Status.COMPLETED && call.status != ToolCallModel.Status.FAILED) {
            return
        }
        fireEntry("toolCall", call.id) { itemElement(ChatItem.ToolCall(call)) }
    }

    // MARK: - Coalescing

    /** Ensures one flush is scheduled ~50 ms out. Repeated deltas within the window all land in streamBuffers. */
    private fun scheduleFlush() {
        if (flushPending) {
            return
        }
        flushPending = true
        scope.launch {
            delay(50)
            applyBufferedText()
        }
    }

    private fun applyBufferedText() {
        flushPending = false
        for ((itemID, text) in streamBuffers) {
            val index = messageIndex(itemID) ?: continue
            if (streamingText(index) != text) {
                mutateStreamingText(index) { it.copy(text = text) }
            }
        }
    }

    /** Context bookkeeping at turn end (see the Swift source for the full rationale). */
    private fun trackContextAfterTurn(stopReason: String) {
        // The terminal event of a turn a restore already superseded: the restore path set the truthful state.
        if (supersededTurnPending) {
            supersededTurnPending = false
            return
        }
        if (stopReason == "cancelled" || stopReason == "error") {
            wireContext = null
            if (contextState == ChatContextState.SYNCED) {
                contextState = ChatContextState.PENDING
            }
        } else if (contextState == ChatContextState.SYNCED) {
            wireContext = wireEntries(items)
        } else {
            wireContext = null
        }
    }

    /** Closes every still-streaming thought: applies its buffered text and clears the streaming flag. */
    private fun finalizeOpenThoughts() {
        for (index in items.indices) {
            val thoughtItem = items[index] as? ChatItem.Thought ?: continue
            if (!thoughtItem.thought.isStreaming) {
                continue
            }
            var thought = thoughtItem.thought
            val buffered = streamBuffers.remove(thought.id)
            if (buffered != null) {
                thought = thought.copy(text = buffered)
            }
            thought = thought.copy(isStreaming = false)
            _items[index] = ChatItem.Thought(thought)
            fireEntry("thought", thought.id) { itemElement(ChatItem.Thought(thought)) }
        }
    }

    // MARK: - Helpers

    /** Index of the message or thought with this id (the two item kinds that stream text). */
    private fun messageIndex(id: String): Int? {
        val index = items.indexOfFirst {
            when (it) {
                is ChatItem.Message -> it.message.id == id
                is ChatItem.Thought -> it.thought.id == id
                else -> false
            }
        }
        return if (index >= 0) index else null
    }

    private fun toolCallIndex(id: String): Int? {
        val index = items.indexOfFirst { it is ChatItem.ToolCall && it.call.id == id }
        return if (index >= 0) index else null
    }

    private fun streamingText(index: Int): String? = when (val it = items[index]) {
        is ChatItem.Message -> it.message.text
        is ChatItem.Thought -> it.thought.text
        else -> null
    }

    private fun mutateStreamingText(index: Int, transform: (ChatMessage) -> ChatMessage) {
        when (val it = items[index]) {
            is ChatItem.Message -> _items[index] = ChatItem.Message(transform(it.message))
            is ChatItem.Thought -> _items[index] = ChatItem.Thought(transform(it.thought))
            else -> {}
        }
    }

    // MARK: - Person-to-person (v2) routing helpers

    /** Inserts a complete message, or replaces one with the same id in place. Returns whether the id existed. */
    private fun upsertMessage(message: ChatMessage): Boolean {
        val index = anyItemIndex(message.id)
        if (index != null) {
            if (items[index] is ChatItem.Message) {
                _items[index] = ChatItem.Message(message.finalized())
            } else {
                logger.log("Chat messageReceived id '${message.id}' collides with a non-message item; ignoring", ChatLogLevel.VERBOSE)
            }
            return true
        }
        _items.add(ChatItem.Message(message.finalized()))
        return false
    }

    /** Inserts a file item, or replaces one with the same id in place. Returns whether it existed. */
    private fun upsertFile(file: ChatFile): Boolean {
        val index = anyItemIndex(file.id)
        if (index != null) {
            if (items[index] is ChatItem.File) {
                _items[index] = ChatItem.File(file)
            } else {
                logger.log("Chat fileAdded id '${file.id}' collides with a non-file item; ignoring", ChatLogLevel.VERBOSE)
            }
            return true
        }
        _items.add(ChatItem.File(file))
        return false
    }

    /**
     * Re-keys the optimistic message `localID` to the server-assigned `serverID` in place. Tolerant: an unknown /
     * already-reconciled localID is a logged no-op; a serverID that already names a different item drops the
     * optimistic duplicate (the confirmation entry still fires so a persisting host renames rather than orphaning it).
     */
    private fun reconcileMessageID(localID: String, serverID: String) {
        if (localID == serverID) {
            return
        }
        val index = anyItemIndex(localID)
        val message = (items.getOrNull(index ?: -1) as? ChatItem.Message)?.message
        if (index == null || message == null) {
            logger.log("Chat messageIDConfirmed for unknown/optimistic id '$localID'; ignoring", ChatLogLevel.VERBOSE)
            return
        }
        val existing = anyItemIndex(serverID)
        if (existing != null && existing != index) {
            _items.removeAt(index)   // server already delivered this as its own item; drop the optimistic duplicate
            fireEntry("messageIdConfirmed", serverID) {
                chatJson.encodeToJsonElement(MessageIDConfirmation.serializer(), MessageIDConfirmation(localID, serverID))
            }
            logger.log("Chat messageIDConfirmed serverID '$serverID' already present; dropped optimistic '$localID'", ChatLogLevel.VERBOSE)
            return
        }
        _items[index] = ChatItem.Message(message.copy(id = serverID))
        fireEntry("messageIdConfirmed", serverID) {
            chatJson.encodeToJsonElement(MessageIDConfirmation.serializer(), MessageIDConfirmation(localID, serverID))
        }
    }

    /** Mutates a message by id in place and re-fires its entry as an update. Unknown id is a logged no-op. */
    private fun mutateMessage(id: String, kind: String, transform: (ChatMessage) -> ChatMessage) {
        val index = anyItemIndex(id)
        val message = (items.getOrNull(index ?: -1) as? ChatItem.Message)?.message
        if (index == null || message == null) {
            logger.log("Chat $kind for unknown message '$id'; ignoring", ChatLogLevel.VERBOSE)
            return
        }
        val updated = transform(message)
        _items[index] = ChatItem.Message(updated)
        fireEntry("message", id, updated = true) { itemElement(ChatItem.Message(updated.finalized())) }
    }

    /** Mutates a file by id in place; re-fires its entry only when its transfer reached a terminal state. */
    private fun mutateFile(id: String, fireOnTerminal: Boolean, transform: (ChatFile) -> ChatFile) {
        val index = anyItemIndex(id)
        val file = (items.getOrNull(index ?: -1) as? ChatItem.File)?.file
        if (index == null || file == null) {
            logger.log("Chat file update for unknown file '$id'; ignoring", ChatLogLevel.VERBOSE)
            return
        }
        val updated = transform(file)
        _items[index] = ChatItem.File(updated)
        if (fireOnTerminal) {
            fireEntry("file", id, updated = true) { itemElement(ChatItem.File(updated)) }
        }
    }

    /**
     * Applies a delivery/read watermark: every OWN message at or before `upToItemID` with a LOWER ladder status
     * advances to `status`. A message with no status or a failed status is skipped. Unknown target is a logged no-op.
     */
    private fun applyStatusWatermark(status: MessageStatus, upToItemID: String) {
        val targetIndex = anyItemIndex(upToItemID)
        if (targetIndex == null) {
            logger.log("Chat status watermark for unknown item '$upToItemID'; ignoring", ChatLogLevel.VERBOSE)
            return
        }
        val newRank = status.watermarkRank ?: return   // a watermark to failed is not a ladder move
        for (index in 0..targetIndex) {
            val message = (items[index] as? ChatItem.Message)?.message ?: continue
            if (!isSelfMessage(message)) {
                continue
            }
            val currentRank = message.status?.watermarkRank
            if (currentRank == null || currentRank >= newRank) {
                continue   // no status, failed, or already at/above the watermark
            }
            val advanced = message.copy(status = status)
            _items[index] = ChatItem.Message(advanced)
            fireEntry("message", message.id, updated = true) { itemElement(ChatItem.Message(advanced.finalized())) }
        }
    }

    /** Maintains the typing indicator for one sender, with a per-sender expiry failsafe. */
    private fun updateTypingIndicator(isTyping: Boolean, senderID: String?, senderName: String?) {
        val key = senderID ?: "anon"
        if (isTyping) {
            val index = typingParticipants.indexOfFirst { it.id == key }
            if (index >= 0) {
                _typingParticipants[index] = TypingParticipant(key, senderName)
            } else {
                _typingParticipants.add(TypingParticipant(key, senderName))
            }
            scheduler.schedule(typingExpiryKey(key), typingExpiry) { removeTypingParticipant(key) }
        } else {
            removeTypingParticipant(key)
            scheduler.cancel(typingExpiryKey(key))
        }
    }

    private fun removeTypingParticipant(key: String) {
        _typingParticipants.removeAll { it.id == key }
    }

    /** Prepends an older history page to the top, updates the paging flags, advances the id counter past the page. */
    private fun prependHistory(older: List<ChatItem>, hasMore: Boolean) {
        if (older.isNotEmpty()) {
            _items.addAll(0, older)
            advanceLocalCounter(older)
        }
        hasEarlier = hasMore
        isLoadingEarlier = false
    }

    /** Schedules a debounced markRead when pinned + active and the last incoming item advanced past what was marked. */
    private fun maybeScheduleReadMark() {
        if (!capabilities.readReceipts || !pinnedToBottom || !sceneActive) {
            return
        }
        val target = lastIncomingItemID()
        if (target == null || target == lastReadMarkItemID) {
            return
        }
        scheduler.schedule(readMarkKey, readMarkDebounce) { emitReadMark(target) }
    }

    private fun emitReadMark(target: String) {
        // Re-assert the guard at FIRE time (the user may have scrolled away / backgrounded during the debounce window).
        if (!capabilities.readReceipts || !pinnedToBottom || !sceneActive) {
            return
        }
        if (anyItemIndex(target) == null || target == lastReadMarkItemID) {
            return
        }
        lastReadMarkItemID = target
        val transport = this.transport
        scope.launch { transport?.send(ChatCommand.MarkRead(upToItemID = target)) }
    }

    /** The last transcript item from someone else (a message or file not authored by the local user). */
    private fun lastIncomingItemID(): String? {
        for (item in items.asReversed()) {
            when (item) {
                is ChatItem.Message -> if (!isSelfMessage(item.message)) return item.message.id
                is ChatItem.File -> if (!isSelfFile(item.file)) return item.file.id
                else -> {}
            }
        }
        return null
    }

    /** Advances `localCounter` past any store-generated ids (user- / system- / error-N) in `items`. */
    private fun advanceLocalCounter(items: List<ChatItem>) {
        val generatedPrefixes = listOf("user-", "system-", "error-")
        val maxSuffix = items.mapNotNull { item ->
            val id = item.id
            for (prefix in generatedPrefixes) {
                if (id.startsWith(prefix)) {
                    return@mapNotNull id.removePrefix(prefix).toIntOrNull()
                }
            }
            null
        }.maxOrNull()
        if (maxSuffix != null) {
            localCounter = maxOf(localCounter, maxSuffix)
        }
    }

    // Self-authorship: role local, or a senderID that resolves to a participant marked isSelf.
    private fun isSelfMessage(message: ChatMessage): Boolean {
        if (message.role == ChatRole.LOCAL) {
            return true
        }
        val senderID = message.senderID ?: return false
        return participants.firstOrNull { it.id == senderID }?.isSelf == true
    }

    private fun isSelfFile(file: ChatFile): Boolean {
        if (file.role == ChatRole.LOCAL) {
            return true
        }
        val senderID = file.senderID ?: return false
        return participants.firstOrNull { it.id == senderID }?.isSelf == true
    }

    private fun anyItemIndex(id: String): Int? {
        val index = items.indexOfFirst { it.id == id }
        return if (index >= 0) index else null
    }

    private fun item(id: String): ChatItem? = items.firstOrNull { it.id == id }

    /** Coerces a raw content / config value (a Map, a JSON string, JSON bytes, or a JsonObject) into a JsonObject. */
    private fun rawToJsonObject(raw: Any?): JsonObject? = when (raw) {
        is JsonObject -> raw
        is Map<*, *> -> runCatching { anyToJsonElement(raw) as? JsonObject }.getOrNull()
        is String -> runCatching { chatJson.parseToJsonElement(raw) as? JsonObject }.getOrNull()
        is ByteArray -> runCatching { chatJson.parseToJsonElement(raw.toString(Charsets.UTF_8)) as? JsonObject }.getOrNull()
        else -> null
    }

    private fun reactions(id: String): List<Reaction>? = (item(id) as? ChatItem.Message)?.message?.reactions

    /** Builds the reply reference for an optimistic reply. */
    private fun makeReplyRef(itemID: String): ReplyRef? {
        return when (val existing = item(itemID)) {
            is ChatItem.Message -> ReplyRef(itemID = itemID, excerpt = replyExcerpt(existing.message.text),
                senderName = resolvedSenderName(existing.message))
            is ChatItem.File -> ReplyRef(itemID = itemID, excerpt = existing.file.name, senderName = existing.file.senderName)
            else -> null
        }
    }

    private fun replyExcerpt(text: String): String {
        val oneLine = text.replace("\n", " ").trim()
        return if (oneLine.length > 200) oneLine.take(200) else oneLine
    }

    private fun resolvedSenderName(message: ChatMessage): String? {
        message.senderName?.let { return it }
        val senderID = message.senderID ?: return null
        return participants.firstOrNull { it.id == senderID }?.name
    }

    private fun itemElement(item: ChatItem): JsonElement = chatJson.encodeToJsonElement(ChatItemSerializer, item)

    private fun emit(event: ChatHostEvent) {
        hostEvents?.invoke(event)
    }

    /** The agent-visible pairs of a transcript: message items with a conversational role and non-empty text. */
    private fun wireEntries(items: List<ChatItem>): List<WireEntry> =
        items.mapNotNull { item ->
            val message = (item as? ChatItem.Message)?.message ?: return@mapNotNull null
            if ((message.role == ChatRole.LOCAL || message.role == ChatRole.AGENT) && message.text.isNotEmpty()) {
                WireEntry(local = message.role == ChatRole.LOCAL, text = message.text)
            } else {
                null
            }
        }

    // Injectable-clock timings.
    private val typingExpiry: Duration = 10.seconds  // failsafe removal of a stuck typing indicator
    private val readMarkDebounce: Duration = 2.seconds
    private val typingThrottleMillis = 4_000L        // minimum gap between outgoing setTyping(true) signals

    companion object {
        private const val readMarkKey = "readmark"
        private fun typingExpiryKey(senderKey: String) = "typing.expire.$senderKey"
    }
}

/** A copy guaranteed non-streaming, for persistence / upsert. */
private fun ChatMessage.finalized(): ChatMessage = if (isStreaming) copy(isStreaming = false) else this

/** The messageIdConfirmed entry payload: lets a persisting host rename its optimistic localID row to serverID. */
@Serializable
private data class MessageIDConfirmation(val localID: String, val serverID: String)

// --- Canonical (sorted-keys, compact) JSON for the entry envelope, mirroring Swift's JSONEncoder [.sortedKeys].

private fun sortJsonElement(element: JsonElement): JsonElement = when (element) {
    is JsonObject -> JsonObject(element.toSortedMap().mapValues { sortJsonElement(it.value) })
    is kotlinx.serialization.json.JsonArray -> kotlinx.serialization.json.JsonArray(element.map { sortJsonElement(it) })
    else -> element
}

// Matches Swift fireEntry's `JSONEncoder` with `outputFormatting = [.sortedKeys]` (ChatStore.swift:1045) byte-for-
// byte for the host entry channel. That encoder does NOT set `.withoutEscapingSlashes` (unlike the fixture emitter),
// so Foundation escapes every `/` as `\/`; kotlinx never escapes slashes, so we do it here. Every `/` in compact
// JSON output lives inside a string value (no structural slashes), so a blanket replace is safe. A whole-value
// Double still renders as `1.0` here vs Swift's `1` - the documented cross-language number-format divergence.
private fun canonicalEntryJson(element: JsonElement): String =
    Json.Default.encodeToString(JsonElement.serializer(), element).replace("/", "\\/")
