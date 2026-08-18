// Sources/ChatView/ChatTransport.swift
//
// The transport abstraction (protocol-agnostic), its configuration slice, the
// factory type the registry stores, and the built-in `local` transport.
//
// A transport is the ONLY layer that knows a wire protocol. It emits a normalized
// `ChatEvent` stream and accepts normalized `ChatCommand`s, so the store / view above
// it are identical no matter which protocol is active. `local` is the only built-in;
// other protocols (ACP, OpenAI SSE, or a host's own) live in their own modules and
// register a factory with ChatTransportRegistry (see ActionUIChatCore.registerTransport).
//
// PUBLIC API NOTE (P0-6): ChatTransport, ChatLogger, ChatTransportConfig, and
// ChatTransportFactory are the frozen contract an out-of-module transport builds
// against. LocalChatTransport / ChatReplyContent stay internal.

import Foundation
import CoreGraphics

/// Which P2P (v2) conversation affordances a transport backs. The store consults this
/// before emitting the corresponding command (typing signals, read marks, paging, ...),
/// and the view combines it with the document's `features` config: an affordance appears
/// only when BOTH the document enables it AND the transport supports it. Every flag
/// defaults to false, so a v1 transport (which does not set `capabilities`) advertises no
/// v2 capability and behaves exactly as before.
public struct ChatTransportCapabilities: Sendable, Equatable {
    public var paging: Bool          // answers `.loadEarlier` with `.historyPage`
    public var typing: Bool          // relays `.setTyping` / emits `.typingChanged`
    public var reactions: Bool       // relays `.toggleReaction` / emits `.reactionsChanged`
    public var editing: Bool         // relays `.editMessage` / emits `.messageEdited`
    public var deletion: Bool        // relays `.deleteMessage` / emits `.messageDeleted`
    public var replies: Bool         // relays `.sendMessage(replyTo:)`
    public var readReceipts: Bool    // relays `.markRead` / emits status watermarks
    public var fileTransfer: Bool    // emits `.fileAdded` / `.fileProgress`, relays `.cancelFileTransfer`
    public var messageIdentity: Bool // assigns server-side ids to sent messages and confirms them
                                     // via `.messageIDConfirmed`; the store routes every send through
                                     // `.sendMessage` carrying a client `localID` and re-keys the
                                     // optimistic item on confirmation. Server-authoritative transports
                                     // (SimpleX, Matrix) set this; demo/agent transports leave it false.
                                     //
                                     // Ordering / failure contract a `messageIdentity` transport MUST honor:
                                     // - Emit `.messageIDConfirmed(localID:serverID:)` BEFORE any event keyed
                                     //   by that `serverID` (status ladder, reactions, edit, delete).
                                     // - Before confirmation, address the in-flight message by its `localID`
                                     //   (e.g. `.messageStatusChanged(itemID: localID, status: .failed)` on a
                                     //   send failure; the user's retry arrives as `.resendMessage(itemID: localID)`).
                                     // - A send that fails and is later retried and succeeds emits
                                     //   `.messageIDConfirmed` at the point it succeeds.
    public var reportsConnectionState: Bool  // emits `.connectionStateChanged`; the composer gates on
                                             // `connected`. A transport that never reports leaves this
                                             // false and the composer is never connection-gated.

    public init(paging: Bool = false, typing: Bool = false, reactions: Bool = false,
                editing: Bool = false, deletion: Bool = false, replies: Bool = false,
                readReceipts: Bool = false, fileTransfer: Bool = false,
                messageIdentity: Bool = false, reportsConnectionState: Bool = false) {
        self.paging = paging
        self.typing = typing
        self.reactions = reactions
        self.editing = editing
        self.deletion = deletion
        self.replies = replies
        self.readReceipts = readReceipts
        self.fileTransfer = fileTransfer
        self.messageIdentity = messageIdentity
        self.reportsConnectionState = reportsConnectionState
    }
}

/// One wire protocol's adapter. `Sendable` so the store can drive it from async
/// contexts; `events` is a single-consumer stream the store drains. Construction is
/// NOT a protocol requirement - a transport is built by the factory closure registered
/// for its protocol name, so each transport is free to have whatever initializer it needs.
public protocol ChatTransport: AnyObject, Sendable {
    /// Begins the session (launch / connect / advertise options) and starts emitting events.
    func start() async
    /// Handles one normalized outbound command (a user turn, cancel, permission answer, option change).
    func send(_ command: ChatCommand) async
    /// The single-consumer event stream the store drains for the element's lifetime.
    var events: AsyncStream<ChatEvent> { get }
    /// Ends the session and finishes `events` so the store's drain completes.
    func stop() async
    /// The P2P affordances this transport backs. Defaults to none (a v1 transport is
    /// unaffected), so only a transport that supports v2 features overrides it.
    var capabilities: ChatTransportCapabilities { get }
    /// Replaces the transport's wire history with a restored transcript's messages, so a
    /// continued conversation is sent with its prior turns as context (and a cleared / new
    /// transcript resets the wire). The store calls this SYNCHRONOUSLY on a content restore
    /// (P0-2 continue-in seam), whenever a transport is (re)built while a transcript is
    /// already loaded, and - for a restore deferred by the "prime": "defer" directive -
    /// right before the first prompt that follows it; always before any subsequent prompt,
    /// so ordering holds without serializing the async command channel. `messages` are the transcript's message
    /// items in order (role + text); non-message items (thoughts, tool cards, images,
    /// notices) are omitted. A text-protocol transport maps role -> wire; a transport whose
    /// history lives server-side may ignore it. Default: no-op.
    func primeHistory(_ messages: [ChatMessage])

    /// The same, asking the agent to SUMMARIZE the older part instead of replaying all of it.
    ///
    /// Additive and opt-in on both sides: the default implementation below ignores the request,
    /// and an agent that does not know the key ignores it too. THE FALLBACK IS ALWAYS FULL
    /// FIDELITY, NEVER TRUNCATION - a transport that cannot condense must still deliver the whole
    /// conversation, because half a context that claims to be whole is worse than a slow prime.
    func primeHistory(_ messages: [ChatMessage], condense: PrimeCondense?)
    /// Reserves any id namespaces this transport MINTS, so a turn continued after a transcript
    /// restore never reuses an id already present in the loaded items. `ids` is EVERY item id in
    /// the restored transcript (messages, thoughts, tool cards, ...) - not just the messages
    /// primeHistory receives - because a transport's per-turn id counter is typically shared
    /// across item kinds. The store calls this SYNCHRONOUSLY alongside primeHistory on every
    /// restore and on a transport (re)build, before any prompt. A reused id would make the
    /// transcript's id-keyed ForEach update an existing bubble instead of appending, and the
    /// journal's last-write-wins dedup drop the older item. openai-sse and acp override this
    /// (both mint launch-reset per-turn ids); the local demo mints ids too but is not a
    /// persistence path, so it keeps the default no-op.
    func reserveIDs(seen ids: [String])
}

public extension ChatTransport {
    /// Default: no v2 capabilities. A v1 transport keeps its exact behavior without
    /// declaring anything; a P2P transport overrides this to opt into affordances.
    var capabilities: ChatTransportCapabilities { ChatTransportCapabilities() }
    /// Default: a transport with no client-owned wire history (the demo `local` transport, or
    /// an agent transport whose conversation state lives server-side) ignores a prime.
    func primeHistory(_ messages: [ChatMessage]) {}
    /// Ignoring the request and priming in full is the correct no-op: the caller still gets a
    /// complete context, just a slower first turn.
    func primeHistory(_ messages: [ChatMessage], condense: PrimeCondense?) { primeHistory(messages) }
    /// Default: no-op - only a transport that mints launch-reset per-turn ids a restore could
    /// re-alias needs to override this (openai-sse and acp do).
    func reserveIDs(seen ids: [String]) {}
}

/// The transport-relevant slice of a `Chat` element's configuration, handed to a
/// transport factory. This is the ONLY configuration a transport sees: the element's
/// visual properties (roles, surfaces, action IDs) stay inside the element and never
/// reach a transport. `settings` is the host-injected `states["config"].transport` object verbatim,
/// as the chosen protocol interprets it; the typed accessors are conveniences over it.
///
/// Not `Sendable`: it carries the untyped `settings` dictionary and is used only at
/// construction time on the main actor (a transport reads what it needs into its own
/// Sendable state), so it never crosses an isolation boundary.
public struct ChatTransportConfig {
    /// The protocol name this transport was selected under (the host-injected
    /// `states["config"].protocol`). A transport registered under a single name can ignore it.
    public let protocolName: String
    /// The `states["config"].transport` object verbatim (protocol-specific; the chosen transport
    /// interprets it). Prefer the typed accessors below; reach for this only for shapes
    /// they do not cover.
    public let settings: [String: Any]

    public init(protocolName: String = "", settings: [String: Any] = [:]) {
        self.protocolName = protocolName
        self.settings = settings
    }

    public func string(_ key: String) -> String? {
        settings[key] as? String
    }

    public func bool(_ key: String) -> Bool? {
        settings[key] as? Bool
    }

    public func int(_ key: String) -> Int? {
        (settings[key] as? NSNumber)?.intValue ?? settings[key] as? Int
    }

    public func double(_ key: String) -> Double? {
        (settings[key] as? NSNumber)?.doubleValue ?? settings[key] as? Double
    }

    public func stringArray(_ key: String) -> [String]? {
        settings[key] as? [String]
    }

    public func dictionary(_ key: String) -> [String: Any]? {
        settings[key] as? [String: Any]
    }

    public func dictionaryArray(_ key: String) -> [[String: Any]]? {
        settings[key] as? [[String: Any]]
    }
}

/// Builds a transport from its configuration and logger. A protocol's module registers
/// one of these under its name (ActionUIChatCore.registerTransport); the element invokes
/// it on the main actor when a document selects that protocol. Throwing degrades the
/// element to the built-in `local` transport with a logged reason.
public typealias ChatTransportFactory = (ChatTransportConfig, any ChatLogger) throws -> any ChatTransport

/// The `local` transport: no wire. It is the simplest scripted demo / person-to-person
/// backend - the "Tier A" path made first-class. Each submitted prompt produces a
/// scripted agent reply streamed back chunk-by-chunk, which proves the element
/// end-to-end (append -> stream deltas -> finalize, auto-scroll, role styling) with zero
/// protocol risk. The `reply` style selects the script: "echo" repeats the prompt,
/// "markdown" streams a Markdown showcase (M2), and "agentic" runs a scripted agent
/// turn - thoughts, tool-call cards, a permission gate, then a final answer - so the
/// agentic surfaces are exercised before any wire transport exists (M3). A host that
/// wants to drive the transcript itself will get a push API in a later milestone;
/// `echo` (config, default true) gates the demo reply.
///
/// `@unchecked Sendable`: the only mutable state (the reply counter, the in-flight
/// reply task, and the pending permission continuation) is guarded by `lock`;
/// `events` / `continuation` / config values are immutable and the AsyncStream
/// continuation is itself thread-safe to yield from any context.
final class LocalChatTransport: ChatTransport, @unchecked Sendable {

    let events: AsyncStream<ChatEvent>
    private let continuation: AsyncStream<ChatEvent>.Continuation
    private let echo: Bool
    private let replyStyle: String          // "echo" (default) | "markdown" | "agentic"
    private let chunkDelay: UInt64          // nanoseconds between streamed chunks
    private let lock = NSLock()
    private var replyCounter = 0
    private var replyTask: Task<Void, Never>?
    private var pendingPermission: (requestID: String, continuation: CheckedContinuation<String?, Never>)?
    private var sessionOptions: [SessionConfigOption] = []   // the agentic demo's mode/model state

    // The local transport never fails to construct. `logger` is accepted for a uniform
    // factory shape but unused. `chunkMs` (default 45) paces the demo streaming; tests
    // set it to 0.
    init(config: ChatTransportConfig, logger: any ChatLogger) {
        self.echo = config.bool("echo") ?? true
        self.replyStyle = config.string("reply") ?? "echo"
        let chunkMs = config.int("chunkMs") ?? 45
        self.chunkDelay = UInt64(max(0, chunkMs)) * 1_000_000
        var captured: AsyncStream<ChatEvent>.Continuation!
        self.events = AsyncStream(bufferingPolicy: .unbounded) { captured = $0 }
        self.continuation = captured
    }

    func start() async {
        // The agentic style advertises demo session options so the status bar (model /
        // mode, M5) exercises with no agent; the plain styles stay chrome-free.
        var options: [SessionConfigOption] = []
        if replyStyle == "agentic" {
            options = [
                SessionConfigOption(id: "model", name: "Model", category: "model", currentValue: "demo/scripted",
                                    options: [.init(value: "demo/scripted", name: "Scripted Demo", description: nil)]),
                SessionConfigOption(id: "mode", name: "Mode", category: "mode", currentValue: "build",
                                    options: [.init(value: "build", name: "build", description: "Executes tools based on permissions."),
                                              .init(value: "plan", name: "plan", description: "Read-only planning mode.")]),
            ]
        }
        lock.withLock { sessionOptions = options }
        continuation.yield(.sessionReady(sessionID: "local", configOptions: options))
        if replyStyle == "agentic" {
            // Demo slash commands for the composer menu (typing "/" filters them);
            // selecting one just fills the draft - commands send as ordinary prompt text.
            continuation.yield(.commandsAvailable([
                SlashCommand(name: "review", description: "Review the current changes"),
                SlashCommand(name: "test", description: "Run the test suite"),
                SlashCommand(name: "commit", description: "Draft a commit message"),
            ]))
        }
    }

    func send(_ command: ChatCommand) async {
        switch command {
        case .prompt(let text):
            guard echo else { return }
            let itemID = lock.withLock { () -> String in
                replyCounter += 1
                return "agent-\(replyCounter)"
            }
            let agentic = replyStyle == "agentic"
            let task = Task { [weak self] in
                guard let self else { return }
                if agentic {
                    await self.streamAgentic(itemID: itemID, prompt: text)
                } else {
                    await self.streamEcho(itemID: itemID, prompt: text)
                }
            }
            lock.withLock { replyTask = task }

        case .cancel:
            lock.withLock { replyTask }?.cancel()

        case .permissionResponse(let requestID, let optionID):
            let resumable = lock.withLock { () -> CheckedContinuation<String?, Never>? in
                guard let pending = pendingPermission, pending.requestID == requestID else {
                    return nil
                }
                pendingPermission = nil
                return pending.continuation
            }
            resumable?.resume(returning: optionID)

        case .setConfigOption(let optionID, let value):
            // The demo round trip: accept a valid choice and confirm with the refreshed
            // option set, exactly like an ACP agent answering set_config_option.
            let refreshed = lock.withLock { () -> [SessionConfigOption]? in
                guard let index = sessionOptions.firstIndex(where: { $0.id == optionID }),
                      sessionOptions[index].options.contains(where: { $0.value == value }) else {
                    return nil
                }
                sessionOptions[index].currentValue = value
                return sessionOptions
            }
            if let refreshed {
                continuation.yield(.configOptionsChanged(refreshed))
            }

        case .sendMessage, .toggleReaction, .editMessage, .deleteMessage, .resendMessage,
             .markRead, .loadEarlier, .setTyping, .cancelFileTransfer:
            // The built-in `local` transport advertises no P2P capabilities, so the store
            // never emits these; ignore any that arrive. The scripted `local-p2p` transport
            // (a separate protocol) handles them.
            break
        }
    }

    func stop() async {
        lock.withLock { replyTask }?.cancel()
        continuation.finish()
    }

    /// Streams a canned reply chunk-by-chunk with a small per-chunk delay so streaming is visibly
    /// progressive. Chunks preserve whitespace and newlines (so Markdown layout - blank lines, code
    /// blocks - streams faithfully). Honors cancellation (the Stop affordance / `.cancel`).
    private func streamEcho(itemID: String, prompt: String) async {
        continuation.yield(.messageStart(itemID: itemID, role: .agent))
        let reply = ChatReplyContent.make(style: replyStyle, prompt: prompt)
        await streamChunks(of: reply) { chunk in
            continuation.yield(.messageDelta(itemID: itemID, text: chunk))
        }
        continuation.yield(.messageEnd(itemID: itemID, stopReason: Task.isCancelled ? "cancelled" : "end_turn"))

        // If the prompt asks for an image, follow the reply with a STANDALONE image element, so the local
        // transport exercises the image path (ChatEvent.image -> ChatItem.image -> CachedImage) end to end.
        if !Task.isCancelled, prompt.lowercased().contains("image"),
           let image = ChatReplyContent.sampleImage(seed: itemID) {
            continuation.yield(.image(itemID: "\(itemID)-image", role: .agent, image: image))
        }
    }

    /// The scripted agent turn: a thought stream, a completed search tool call, an edit
    /// tool call gated by a permission request, then a streamed Markdown summary. It
    /// exercises every M3 event so the router / cards / approval UI run end-to-end with
    /// no wire protocol. The shape intentionally mirrors what an ACP agent produces.
    private func streamAgentic(itemID: String, prompt: String) async {
        // 1. Reasoning streams first, like an agent thinking before acting.
        let thoughtID = "\(itemID)-thought"
        await streamChunks(of: ChatReplyContent.agenticThought(prompt: prompt)) { chunk in
            continuation.yield(.thoughtDelta(itemID: thoughtID, text: chunk))
        }

        // 1b. The agent lays out its plan (ACP `plan`): the whole list re-emits as
        //     steps progress, exactly like a real agent.
        yieldPlan(statuses: [.inProgress, .pending, .pending])

        // 2. A read-only tool call that runs unprompted: pending -> in_progress -> completed.
        let searchID = "\(itemID)-tool-search"
        continuation.yield(.toolCall(ToolCallModel(
            id: searchID, title: "Search the workspace for greetings", kind: .search,
            status: .pending, contentText: "", diff: nil,
            rawInput: "{ \"query\": \"greeting\" }", rawOutput: nil)))
        await pause()
        continuation.yield(.toolCallUpdate(ToolCallUpdate(id: searchID, status: .inProgress)))
        await pause()
        continuation.yield(.toolCallUpdate(ToolCallUpdate(
            id: searchID, status: .completed,
            contentText: "Found `greet(_:)` in `Sources/Greeting.swift` (2 call sites).",
            rawOutput: "{ \"matches\": 2 }")))
        yieldPlan(statuses: [.completed, .inProgress, .pending])

        // 3. A mutating tool call, gated by a permission request (the ACP
        //    session/request_permission flow): the card appears pending, the request
        //    blocks until the user picks an option or the turn is cancelled.
        let editID = "\(itemID)-tool-edit"
        continuation.yield(.toolCall(ToolCallModel(
            id: editID, title: "Edit Sources/Greeting.swift", kind: .edit,
            status: .pending, contentText: "",
            diff: ChatReplyContent.agenticDiff(), rawInput: nil, rawOutput: nil)))
        let requestID = "\(itemID)-permission"
        continuation.yield(.permissionRequest(PermissionRequest(
            id: requestID, toolCallID: editID,
            title: "Allow the agent to edit Sources/Greeting.swift?",
            options: [
                PermissionRequest.Option(id: "allow-once", name: "Allow once", kind: .allowOnce),
                PermissionRequest.Option(id: "allow-always", name: "Always allow", kind: .allowAlways),
                PermissionRequest.Option(id: "reject-once", name: "Reject", kind: .rejectOnce),
            ])))
        let optionID = await awaitPermission(requestID: requestID)
        if Task.isCancelled {
            continuation.yield(.toolCallUpdate(ToolCallUpdate(id: editID, status: .failed)))
            continuation.yield(.messageEnd(itemID: itemID, stopReason: "cancelled"))
            return
        }
        let allowed = optionID == "allow-once" || optionID == "allow-always"
        if allowed {
            continuation.yield(.toolCallUpdate(ToolCallUpdate(id: editID, status: .inProgress)))
            await pause()
            continuation.yield(.toolCallUpdate(ToolCallUpdate(
                id: editID, status: .completed,
                contentText: "Applied the change to `Sources/Greeting.swift`.")))
        } else {
            continuation.yield(.toolCallUpdate(ToolCallUpdate(id: editID, status: .failed)))
        }

        yieldPlan(statuses: [.completed, .completed, .inProgress])

        // 4. The final assistant answer, streamed as Markdown.
        continuation.yield(.messageStart(itemID: itemID, role: .agent))
        await streamChunks(of: ChatReplyContent.agenticSummary(allowed: allowed)) { chunk in
            continuation.yield(.messageDelta(itemID: itemID, text: chunk))
        }
        yieldPlan(statuses: [.completed, .completed, .completed])
        // Token/cost usage the way OpenCode reports it (usage_update); zero cost stays hidden.
        continuation.yield(.usage(UsageInfo(used: 2350, size: 200_000, costAmount: 0, costCurrency: "USD")))
        continuation.yield(.messageEnd(itemID: itemID, stopReason: Task.isCancelled ? "cancelled" : "end_turn"))
    }

    /// The scripted turn's three-step plan, re-emitted whole as statuses change.
    private func yieldPlan(statuses: [PlanEntry.Status]) {
        let steps = ["Find the greeting call sites", "Edit Sources/Greeting.swift", "Summarize the change"]
        let entries = steps.enumerated().map { index, content in
            PlanEntry(id: index, content: content, priority: nil, status: statuses[index])
        }
        continuation.yield(.plan(entries))
    }

    /// Parks the scripted turn until the UI answers the permission request (via
    /// `.permissionResponse`) or the turn is cancelled. Returns the chosen option ID,
    /// or nil when cancelled / dismissed. Registration and resumption both go through
    /// `lock`, and the cancellation handler resumes-with-nil exactly once (whichever of
    /// registration-after-cancel or cancel-after-registration happens, the continuation
    /// is taken out of `pendingPermission` before resuming).
    private func awaitPermission(requestID: String) async -> String? {
        await withTaskCancellationHandler {
            await withCheckedContinuation { (checked: CheckedContinuation<String?, Never>) in
                let alreadyCancelled = lock.withLock { () -> Bool in
                    if Task.isCancelled {
                        return true
                    }
                    pendingPermission = (requestID, checked)
                    return false
                }
                if alreadyCancelled {
                    checked.resume(returning: nil)
                }
            }
        } onCancel: {
            let resumable = lock.withLock { () -> CheckedContinuation<String?, Never>? in
                let pending = pendingPermission?.continuation
                pendingPermission = nil
                return pending
            }
            resumable?.resume(returning: nil)
        }
    }

    /// Streams `text` chunk-by-chunk through `emit`, pacing by `chunkMs` and honoring
    /// cancellation between chunks.
    private func streamChunks(of text: String, emit: (String) -> Void) async {
        for chunk in ChatReplyContent.streamingChunks(text) {
            if Task.isCancelled {
                return
            }
            await pause()
            emit(chunk)
        }
    }

    /// One scripted-pacing beat (`chunkMs`); a no-op at 0 so tests run instantly.
    private func pause() async {
        if chunkDelay > 0 {
            try? await Task.sleep(nanoseconds: chunkDelay)
        }
    }
}

/// Canned reply content for the local transport. `echo` repeats the prompt; `markdown` returns a
/// showcase that exercises the M2 Markdown renderer (headings, emphasis, code, lists, a quote, a
/// table, a rule) and embeds the prompt as a quote. The `agentic` pieces script the M3 demo turn
/// (a thought, a diff, a summary); the turn's structure lives in the transport.
enum ChatReplyContent {

    /// The scripted reasoning stream for the agentic demo.
    static func agenticThought(prompt: String) -> String {
        let oneLine = prompt.replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return """
        The user asked: "\(oneLine)". I should search the workspace first to see what \
        is there, then propose a small edit. The edit needs approval before it runs.
        """
    }

    /// The scripted file change the gated edit tool call proposes.
    static func agenticDiff() -> ToolCallDiff {
        ToolCallDiff(
            path: "Sources/Greeting.swift",
            oldText: "func greet(_ name: String) -> String {\n    return \"Hello, \\(name)!\"\n}",
            newText: "func greet(_ name: String) -> String {\n    return \"Hello, \\(name)! Welcome back.\"\n}"
        )
    }

    /// The final streamed answer for the agentic demo turn.
    static func agenticSummary(allowed: Bool) -> String {
        if allowed {
            return """
            Done. I searched the workspace, found `greet(_:)` in `Sources/Greeting.swift`, \
            and applied the approved edit:

            ```swift
            func greet(_ name: String) -> String {
                return "Hello, \\(name)! Welcome back."
            }
            ```

            Both call sites pick the new greeting up unchanged.
            """
        }
        return """
        Understood - I did not apply the edit. The search results are still in the \
        tool card above if you want to revisit; nothing in the workspace was changed.
        """
    }

    static func make(style: String, prompt: String) -> String {
        switch style {
        case "markdown":
            return markdownShowcase(prompt: prompt)
        default:
            return "You said: \(prompt)"
        }
    }

    /// A deterministic sample image for the demo image path (seeded so it is stable per reply). Its size is
    /// declared, so the transcript reserves the right box and the picture hydrates without reflow.
    static func sampleImage(seed: String) -> ChatImage? {
        let cleaned = seed.replacingOccurrences(of: "/", with: "-")
        guard let url = URL(string: "https://picsum.photos/seed/\(cleaned)/480/320") else {
            return nil
        }
        return ChatImage(url: url, alt: "A sample image", pixelSize: CGSize(width: 480, height: 320))
    }

    private static func markdownShowcase(prompt: String) -> String {
        let oneLine = prompt.replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let quoted = escapeInline(oneLine.isEmpty ? "(empty message)" : oneLine)
        return """
        ## Streaming Markdown

        > \(quoted)

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
            return "Hello, \\(name)!"
        }
        ```

        | Feature  | Status |
        | -------- | :----: |
        | Headings | ok     |
        | Code     | ok     |
        | Tables   | ok     |

        That is all.
        """
    }

    private static func escapeInline(_ s: String) -> String {
        var out = ""
        for c in s {
            if "\\`*_[]()#~|".contains(c) {
                out.append("\\")
            }
            out.append(c)
        }
        return out
    }

    /// Splits text into chunks that each preserve their trailing whitespace, so streaming the chunks
    /// one at a time reproduces the source exactly (blank lines, indentation, code layout included).
    /// A boundary falls where a non-space character follows whitespace - i.e. each chunk is a word
    /// plus the whitespace that trails it.
    static func streamingChunks(_ text: String) -> [String] {
        var chunks: [String] = []
        var current = ""
        for ch in text {
            let isSpace = ch == " " || ch == "\n" || ch == "\t"
            if !isSpace, let last = current.last, last == " " || last == "\n" || last == "\t" {
                chunks.append(current)
                current = ""
            }
            current.append(ch)
        }
        if !current.isEmpty {
            chunks.append(current)
        }
        return chunks
    }
}

