package com.abracode.chatview

// Port of the LocalChatTransport + ChatReplyContent portion of Sources/ChatView/ChatTransport.swift.
//
// The `local` transport: no wire. Each submitted prompt produces a scripted agent reply streamed back
// chunk-by-chunk, which proves the element end-to-end with zero protocol risk. The `reply` style selects the
// script: "echo" repeats the prompt, "markdown" streams a Markdown showcase, and "agentic" runs a scripted agent
// turn (thoughts, tool-call cards, a permission gate, then a final answer). `echo` (config, default true) gates the
// demo reply.
//
// Swift's AsyncStream.Continuation.yield maps to Channel.trySend (unbounded, so it always succeeds); Swift's Task /
// Task.sleep / Task.isCancelled map to a coroutine on an injectable-dispatcher scope, a cancellation-swallowing
// pause (mirroring Swift's `try? await Task.sleep`), and explicit isActive checks. The permission continuation is a
// CompletableDeferred completed by the response command or failed by cancellation.

import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CoroutineDispatcher
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.cancel
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.channels.ReceiveChannel
import kotlinx.coroutines.delay
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import kotlin.coroutines.cancellation.CancellationException
import kotlin.coroutines.coroutineContext

class LocalChatTransport(
    config: ChatTransportConfig,
    @Suppress("UNUSED_PARAMETER") logger: ChatLogger,
    dispatcher: CoroutineDispatcher = Dispatchers.Default,
) : ChatTransport {

    private val channel = Channel<ChatEvent>(Channel.UNLIMITED)
    override val events: ReceiveChannel<ChatEvent> get() = channel

    private val echo: Boolean = config.bool("echo") ?: true
    private val replyStyle: String = config.string("reply") ?: "echo"     // "echo" (default) | "markdown" | "agentic"
    private val chunkMs: Int = (config.int("chunkMs") ?: 45).coerceAtLeast(0)

    private val scope = CoroutineScope(SupervisorJob() + dispatcher)
    private val lock = Any()
    private var replyCounter = 0
    private var replyJob: Job? = null
    private var pendingPermission: Pair<String, CompletableDeferred<String?>>? = null
    private var sessionOptions: List<SessionConfigOption> = emptyList()   // the agentic demo's mode/model state

    override suspend fun start() {
        // The agentic style advertises demo session options so the status bar exercises with no agent.
        val options: List<SessionConfigOption> = if (replyStyle == "agentic") {
            listOf(
                SessionConfigOption(
                    id = "model", name = "Model", category = "model", currentValue = "demo/scripted",
                    options = listOf(SessionConfigOption.Choice("demo/scripted", "Scripted Demo", null)),
                ),
                SessionConfigOption(
                    id = "mode", name = "Mode", category = "mode", currentValue = "build",
                    options = listOf(
                        SessionConfigOption.Choice("build", "build", "Executes tools based on permissions."),
                        SessionConfigOption.Choice("plan", "plan", "Read-only planning mode."),
                    ),
                ),
            )
        } else {
            emptyList()
        }
        synchronized(lock) { sessionOptions = options }
        emit(ChatEvent.SessionReady(sessionID = "local", configOptions = options))
        if (replyStyle == "agentic") {
            emit(
                ChatEvent.CommandsAvailable(
                    listOf(
                        SlashCommand("review", "Review the current changes"),
                        SlashCommand("test", "Run the test suite"),
                        SlashCommand("commit", "Draft a commit message"),
                    ),
                ),
            )
        }
    }

    override suspend fun send(command: ChatCommand) {
        when (command) {
            is ChatCommand.Prompt -> {
                if (!echo) return
                val itemID = synchronized(lock) { "agent-${++replyCounter}" }
                val agentic = replyStyle == "agentic"
                val job = scope.launch {
                    if (agentic) streamAgentic(itemID, command.text) else streamEcho(itemID, command.text)
                }
                synchronized(lock) { replyJob = job }
            }

            is ChatCommand.Cancel -> synchronized(lock) { replyJob }?.cancel()

            is ChatCommand.PermissionResponse -> {
                val resumable = synchronized(lock) {
                    val pending = pendingPermission
                    if (pending == null || pending.first != command.requestID) {
                        null
                    } else {
                        pendingPermission = null
                        pending.second
                    }
                }
                resumable?.complete(command.optionID)
            }

            is ChatCommand.SetConfigOption -> {
                // The demo round trip: accept a valid choice and confirm with the refreshed option set.
                val refreshed = synchronized(lock) {
                    val index = sessionOptions.indexOfFirst { it.id == command.optionID }
                    if (index < 0 || sessionOptions[index].options.none { it.value == command.value }) {
                        null
                    } else {
                        sessionOptions = sessionOptions.mapIndexed { i, option ->
                            if (i == index) option.copy(currentValue = command.value) else option
                        }
                        sessionOptions
                    }
                }
                if (refreshed != null) emit(ChatEvent.ConfigOptionsChanged(refreshed))
            }

            // The built-in `local` transport advertises no P2P capabilities, so the store never emits these; ignore
            // any that arrive. The scripted `local-p2p` transport handles them.
            is ChatCommand.SendMessage, is ChatCommand.ToggleReaction, is ChatCommand.EditMessage,
            is ChatCommand.DeleteMessage, is ChatCommand.ResendMessage, is ChatCommand.MarkRead,
            is ChatCommand.LoadEarlier, is ChatCommand.SetTyping, is ChatCommand.CancelFileTransfer -> Unit
        }
    }

    override suspend fun stop() {
        synchronized(lock) { replyJob }?.cancel()
        channel.close()
        // Cancel the scope too, so any turn still parked on a permission request (a superseded earlier turn the
        // replyJob no longer points at) unwinds instead of leaking.
        scope.cancel()
    }

    /**
     * Streams a canned reply chunk-by-chunk with a small per-chunk delay so streaming is visibly progressive. Chunks
     * preserve whitespace and newlines. Honors cancellation (the Stop affordance / `.cancel`).
     */
    private suspend fun streamEcho(itemID: String, prompt: String) {
        emit(ChatEvent.MessageStart(itemID = itemID, role = ChatRole.AGENT))
        val reply = ChatReplyContent.make(replyStyle, prompt)
        streamChunks(reply) { chunk -> emit(ChatEvent.MessageDelta(itemID = itemID, text = chunk)) }
        emit(ChatEvent.MessageEnd(itemID = itemID, stopReason = if (coroutineContext.isActive) "end_turn" else "cancelled"))

        // If the prompt asks for an image, follow the reply with a STANDALONE image element.
        if (coroutineContext.isActive && prompt.lowercase().contains("image")) {
            ChatReplyContent.sampleImage(itemID)?.let { image ->
                emit(ChatEvent.Image(itemID = "$itemID-image", role = ChatRole.AGENT, image = image))
            }
        }
    }

    /**
     * The scripted agent turn: a thought stream, a completed search tool call, an edit tool call gated by a
     * permission request, then a streamed Markdown summary. Mirrors what an ACP agent produces.
     */
    private suspend fun streamAgentic(itemID: String, prompt: String) {
        // 1. Reasoning streams first.
        val thoughtID = "$itemID-thought"
        streamChunks(ChatReplyContent.agenticThought(prompt)) { chunk ->
            emit(ChatEvent.ThoughtDelta(itemID = thoughtID, text = chunk))
        }

        // 1b. The agent lays out its plan; the whole list re-emits as steps progress.
        yieldPlan(listOf(PlanEntry.Status.IN_PROGRESS, PlanEntry.Status.PENDING, PlanEntry.Status.PENDING))

        // 2. A read-only tool call that runs unprompted: pending -> in_progress -> completed.
        val searchID = "$itemID-tool-search"
        emit(
            ChatEvent.ToolCall(
                ToolCallModel(
                    id = searchID, title = "Search the workspace for greetings", kind = ToolCallModel.Kind.SEARCH,
                    status = ToolCallModel.Status.PENDING, contentText = "", diff = null,
                    rawInput = "{ \"query\": \"greeting\" }", rawOutput = null,
                ),
            ),
        )
        pause()
        emit(ChatEvent.ToolCallUpdateEvent(ToolCallUpdate(id = searchID, status = ToolCallModel.Status.IN_PROGRESS)))
        pause()
        emit(
            ChatEvent.ToolCallUpdateEvent(
                ToolCallUpdate(
                    id = searchID, status = ToolCallModel.Status.COMPLETED,
                    contentText = "Found `greet(_:)` in `Sources/Greeting.swift` (2 call sites).",
                    rawOutput = "{ \"matches\": 2 }",
                ),
            ),
        )
        yieldPlan(listOf(PlanEntry.Status.COMPLETED, PlanEntry.Status.IN_PROGRESS, PlanEntry.Status.PENDING))

        // 3. A mutating tool call, gated by a permission request.
        val editID = "$itemID-tool-edit"
        emit(
            ChatEvent.ToolCall(
                ToolCallModel(
                    id = editID, title = "Edit Sources/Greeting.swift", kind = ToolCallModel.Kind.EDIT,
                    status = ToolCallModel.Status.PENDING, contentText = "",
                    diff = ChatReplyContent.agenticDiff(), rawInput = null, rawOutput = null,
                ),
            ),
        )
        val requestID = "$itemID-permission"
        emit(
            ChatEvent.PermissionRequestEvent(
                PermissionRequest(
                    id = requestID, toolCallID = editID,
                    title = "Allow the agent to edit Sources/Greeting.swift?",
                    options = listOf(
                        PermissionRequest.Option("allow-once", "Allow once", PermissionRequest.Option.Kind.ALLOW_ONCE),
                        PermissionRequest.Option("allow-always", "Always allow", PermissionRequest.Option.Kind.ALLOW_ALWAYS),
                        PermissionRequest.Option("reject-once", "Reject", PermissionRequest.Option.Kind.REJECT_ONCE),
                    ),
                ),
            ),
        )
        val optionID = awaitPermission(requestID)
        if (!coroutineContext.isActive) {
            emit(ChatEvent.ToolCallUpdateEvent(ToolCallUpdate(id = editID, status = ToolCallModel.Status.FAILED)))
            emit(ChatEvent.MessageEnd(itemID = itemID, stopReason = "cancelled"))
            return
        }
        val allowed = optionID == "allow-once" || optionID == "allow-always"
        if (allowed) {
            emit(ChatEvent.ToolCallUpdateEvent(ToolCallUpdate(id = editID, status = ToolCallModel.Status.IN_PROGRESS)))
            pause()
            emit(
                ChatEvent.ToolCallUpdateEvent(
                    ToolCallUpdate(
                        id = editID, status = ToolCallModel.Status.COMPLETED,
                        contentText = "Applied the change to `Sources/Greeting.swift`.",
                    ),
                ),
            )
        } else {
            emit(ChatEvent.ToolCallUpdateEvent(ToolCallUpdate(id = editID, status = ToolCallModel.Status.FAILED)))
        }

        yieldPlan(listOf(PlanEntry.Status.COMPLETED, PlanEntry.Status.COMPLETED, PlanEntry.Status.IN_PROGRESS))

        // 4. The final assistant answer, streamed as Markdown.
        emit(ChatEvent.MessageStart(itemID = itemID, role = ChatRole.AGENT))
        streamChunks(ChatReplyContent.agenticSummary(allowed)) { chunk ->
            emit(ChatEvent.MessageDelta(itemID = itemID, text = chunk))
        }
        yieldPlan(listOf(PlanEntry.Status.COMPLETED, PlanEntry.Status.COMPLETED, PlanEntry.Status.COMPLETED))
        // Token/cost usage the way OpenCode reports it; zero cost stays hidden.
        emit(ChatEvent.Usage(UsageInfo(used = 2350, size = 200_000, costAmount = 0.0, costCurrency = "USD")))
        emit(ChatEvent.MessageEnd(itemID = itemID, stopReason = if (coroutineContext.isActive) "end_turn" else "cancelled"))
    }

    /** The scripted turn's three-step plan, re-emitted whole as statuses change. */
    private fun yieldPlan(statuses: List<PlanEntry.Status>) {
        val steps = listOf("Find the greeting call sites", "Edit Sources/Greeting.swift", "Summarize the change")
        val entries = steps.mapIndexed { index, content ->
            PlanEntry(id = index, content = content, priority = null, status = statuses[index])
        }
        emit(ChatEvent.Plan(entries))
    }

    /**
     * Parks the scripted turn until the UI answers the permission request (via `.permissionResponse`) or the turn is
     * cancelled. Returns the chosen option ID, or null when cancelled / dismissed.
     */
    private suspend fun awaitPermission(requestID: String): String? {
        val deferred = CompletableDeferred<String?>()
        synchronized(lock) { pendingPermission = requestID to deferred }
        return try {
            deferred.await()
        } catch (_: CancellationException) {
            synchronized(lock) { if (pendingPermission?.second === deferred) pendingPermission = null }
            null
        }
    }

    /** Streams `text` chunk-by-chunk through `emit`, pacing by `chunkMs` and honoring cancellation between chunks. */
    private suspend fun streamChunks(text: String, emitChunk: (String) -> Unit) {
        for (chunk in ChatReplyContent.streamingChunks(text)) {
            if (!coroutineContext.isActive) return
            pause()
            emitChunk(chunk)
        }
    }

    /**
     * One scripted-pacing beat (`chunkMs`); a no-op at 0 so tests run instantly. Swallows cancellation like Swift's
     * `try? await Task.sleep`, so a turn cancelled mid-pace still runs its terminal events (the isActive checks then
     * mark the stopReason "cancelled").
     */
    private suspend fun pause() {
        if (chunkMs > 0) {
            try {
                delay(chunkMs.toLong())
            } catch (_: CancellationException) {
                // Swallowed: the caller's isActive checks drive the cancelled terminal path.
            }
        }
    }

    private fun emit(event: ChatEvent) {
        channel.trySend(event)
    }
}

/**
 * Canned reply content for the local transport. `echo` repeats the prompt; `markdown` returns a showcase that
 * exercises the Markdown renderer (headings, emphasis, code, lists, a quote, a table, a rule) and embeds the prompt
 * as a quote. The `agentic` pieces script the demo turn (a thought, a diff, a summary).
 */
object ChatReplyContent {

    /** The scripted reasoning stream for the agentic demo. */
    fun agenticThought(prompt: String): String {
        val oneLine = prompt.replace("\n", " ").trim()
        return "The user asked: \"$oneLine\". I should search the workspace first to see what " +
            "is there, then propose a small edit. The edit needs approval before it runs."
    }

    /** The scripted file change the gated edit tool call proposes. */
    fun agenticDiff(): ToolCallDiff = ToolCallDiff(
        path = "Sources/Greeting.swift",
        oldText = "func greet(_ name: String) -> String {\n    return \"Hello, \\(name)!\"\n}",
        newText = "func greet(_ name: String) -> String {\n    return \"Hello, \\(name)! Welcome back.\"\n}",
    )

    /** The final streamed answer for the agentic demo turn. */
    fun agenticSummary(allowed: Boolean): String {
        if (allowed) {
            return """
                Done. I searched the workspace, found `greet(_:)` in `Sources/Greeting.swift`, and applied the approved edit:

                ```swift
                func greet(_ name: String) -> String {
                    return "Hello, \(name)! Welcome back."
                }
                ```

                Both call sites pick the new greeting up unchanged.
            """.trimIndent()
        }
        return """
            Understood - I did not apply the edit. The search results are still in the tool card above if you want to revisit; nothing in the workspace was changed.
        """.trimIndent()
    }

    fun make(style: String, prompt: String): String = when (style) {
        "markdown" -> markdownShowcase(prompt)
        else -> "You said: $prompt"
    }

    /** A deterministic sample image for the demo image path (seeded so it is stable per reply), with a declared size. */
    fun sampleImage(seed: String): ChatImage? {
        val cleaned = seed.replace("/", "-")
        return ChatImage(
            url = "https://picsum.photos/seed/$cleaned/480/320",
            alt = "A sample image",
            pixelSize = PixelSize(480.0, 320.0),
        )
    }

    private fun markdownShowcase(prompt: String): String {
        val oneLine = prompt.replace("\n", " ").trim()
        val quoted = escapeInline(oneLine.ifEmpty { "(empty message)" })
        return """
            ## Streaming Markdown

            > $quoted

            Here are the basics, **streamed** chunk by chunk:

            - **bold**, *italic*, ~~strike~~, and `inline code`
            - a [link](https://www.swift.org)
            - a nested list:
              - sub item one
              - sub item two

            > A short blockquote, to show quoting.

            ---

            Code and tables render too:

            ```swift
            func greet(_ name: String) -> String {
                return "Hello, \(name)!"
            }
            ```

            | Feature  | Status |
            | -------- | :----: |
            | Headings | ok     |
            | Code     | ok     |
            | Tables   | ok     |

            That is all.
        """.trimIndent()
    }

    private fun escapeInline(s: String): String {
        val out = StringBuilder()
        for (c in s) {
            if (c in "\\`*_[]()#~|") {
                out.append('\\')
            }
            out.append(c)
        }
        return out.toString()
    }

    /**
     * Splits text into chunks that each preserve their trailing whitespace, so streaming the chunks one at a time
     * reproduces the source exactly (blank lines, indentation, code layout included). A boundary falls where a
     * non-space character follows whitespace - i.e. each chunk is a word plus the whitespace that trails it.
     */
    fun streamingChunks(text: String): List<String> {
        val chunks = mutableListOf<String>()
        val current = StringBuilder()
        for (ch in text) {
            val isSpace = ch == ' ' || ch == '\n' || ch == '\t'
            if (!isSpace && current.isNotEmpty()) {
                val last = current.last()
                if (last == ' ' || last == '\n' || last == '\t') {
                    chunks.add(current.toString())
                    current.clear()
                }
            }
            current.append(ch)
        }
        if (current.isNotEmpty()) {
            chunks.add(current.toString())
        }
        return chunks
    }
}
