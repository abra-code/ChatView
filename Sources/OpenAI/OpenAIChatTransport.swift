// Sources/OpenAI/OpenAIChatTransport.swift
//
// The OpenAI SSE transport ("openai-sse"): speaks the OpenAI-compatible
// /v1/chat/completions endpoint with server-sent-events streaming. This is the plain
// chat path that both consuming apps need - llama-server (AIChat.app) and every MLX
// server candidate expose exactly this API, and it must not require an agent process
// (ACP covers the agentic path).
//
// This file is the ONLY place that knows the OpenAI wire shape; everything above it -
// store, router, views - is unchanged from the other transports. It lives in its own
// module (ActionUIChatOpenAI) and registers through the transport registry.
//
// Design (from the wrap-up plan, P0-1):
//   - The transport owns the conversation array (role/content messages): the wire is
//     stateless, so ChatStore stays a pure event reducer. On a prompt it appends the
//     user message, POSTs stream:true, parses SSE `data:` lines, and emits the existing
//     messageStart / messageDelta / messageEnd vocabulary. The 20 Hz coalescing already
//     in ChatStore is reused; there is no second buffer layer here.
//   - model "auto" resolves once at start() via GET {baseURL}/models (first entry), and
//     surfaces through a read-only `model` configOption so the status bar shows it.
//   - reasoning_content deltas route to thoughtDelta so ThoughtRow folds local reasoning
//     models correctly. tool_calls deltas accumulate and render as COMPLETED tool cards
//     plus a system notice - there is NO client-side tool loop (that belongs to ACP).
//   - the final usage chunk (requested via stream_options.include_usage) maps to `usage`.
//   - non-200 responses and mid-stream disconnects emit `error`; cancel finalizes the
//     open message with its partial text (Stop semantics, matching the local transport).
//
// Cross-platform: URLSession works on every platform (no subprocess), so unlike ACP this
// transport is not macOS-gated. `@unchecked Sendable`: the mutable state (conversation,
// the in-flight task, the counter, the resolved model) is guarded by `lock`; `events` /
// the continuation / the immutable config are safe to touch from any context.

import Foundation
import ChatView

final class OpenAIChatTransport: ChatTransport, @unchecked Sendable {

    let events: AsyncStream<ChatEvent>
    private let eventSink: AsyncStream<ChatEvent>.Continuation
    private let logger: any ChatLogger
    private let session: URLSession
    private let ownsSession: Bool     // true when we created the session (invalidate it on stop)

    private let chatURL: URL
    private let modelsURL: URL
    private let apiKey: String
    private let systemPrompt: String
    private let params: [String: Any]     // immutable after init; merged into each request body

    private let lock = NSLock()
    private var conversation: [[String: Any]] = []   // the wire history (role/content), owned here
    private var resolvedModel: String                // "auto" until start() resolves it (if it can)
    private var itemCounter = 0
    private var promptTask: Task<Void, Never>?
    private var generation = 0                        // bumped on primeHistory; guards stale appends

    /// `transport` config: `baseURL` (the OpenAI-compatible endpoint, required, e.g.
    /// "http://127.0.0.1:8080/v1"), `model` (default "auto" -> resolved from /models),
    /// `apiKey` (default ""; empty sends no Authorization header), `systemPrompt`
    /// (default ""; empty sends no system message), and `params` (merged into the request
    /// body verbatim, e.g. temperature / max_tokens; a max_tokens of 0 is treated as
    /// "unlimited" and omitted). `session` is injectable for tests.
    init(config: ChatTransportConfig, logger: any ChatLogger, session: URLSession? = nil) throws {
        guard let base = config.string("baseURL"), !base.isEmpty else {
            throw OpenAITransportError("transport.baseURL (the OpenAI-compatible endpoint, e.g. \"http://127.0.0.1:8080/v1\") is required for protocol \"openai-sse\"")
        }
        var trimmedBase = base
        while trimmedBase.hasSuffix("/") {
            trimmedBase.removeLast()
        }
        guard let chatURL = URL(string: trimmedBase + "/chat/completions"),
              let modelsURL = URL(string: trimmedBase + "/models") else {
            throw OpenAITransportError("transport.baseURL is not a valid URL: \(base)")
        }
        self.chatURL = chatURL
        self.modelsURL = modelsURL
        let model = config.string("model") ?? "auto"
        self.resolvedModel = model.isEmpty ? "auto" : model
        self.apiKey = config.string("apiKey") ?? ""
        self.systemPrompt = config.string("systemPrompt") ?? ""
        self.params = config.dictionary("params") ?? [:]
        self.logger = logger
        if let session {
            self.session = session
            self.ownsSession = false
        } else {
            self.session = Self.defaultSession()
            self.ownsSession = true
        }
        var captured: AsyncStream<ChatEvent>.Continuation!
        self.events = AsyncStream(bufferingPolicy: .unbounded) { captured = $0 }
        self.eventSink = captured
    }

    static func defaultSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 120
        configuration.waitsForConnectivity = false
        return URLSession(configuration: configuration)
    }

    // MARK: - ChatTransport

    func start() async {
        var model = lock.withLock { resolvedModel }
        if model == "auto" {
            if let resolved = await resolveAutoModel() {
                model = resolved
                lock.withLock { resolvedModel = resolved }
            } else {
                logger.log("openai-sse: could not resolve a model from \(modelsURL.absoluteString); sending 'auto' (local servers ignore the model field)", .warning)
            }
        }
        // A single-choice option renders read-only in the status bar (no menu); v1 does
        // not let the user switch models, so setConfigOption on it is a no-op.
        let option = SessionConfigOption(
            id: "model", name: "Model", category: "model", currentValue: model,
            options: [SessionConfigOption.Choice(value: model, name: model, description: nil)])
        eventSink.yield(.sessionReady(sessionID: "openai-sse", configOptions: [option]))
    }

    func send(_ command: ChatCommand) async {
        switch command {
        case .prompt(let text):
            runTurn(userText: text)

        case .cancel:
            lock.withLock { promptTask }?.cancel()

        case .setConfigOption:
            // v1 exposes the model read-only; there is nothing to set.
            logger.log("openai-sse: session options are read-only in this transport; ignoring setConfigOption", .verbose)

        case .permissionResponse:
            // openai-sse never emits permission requests (no agent tool loop); nothing to answer.
            break

        case .sendMessage, .toggleReaction, .editMessage, .deleteMessage, .resendMessage,
             .markRead, .loadEarlier, .setTyping, .cancelFileTransfer:
            // openai-sse advertises no P2P capabilities, so the store never emits these; ignore.
            break
        }
    }

    /// Replaces the wire history with a restored transcript's messages (P0-2 continue seam),
    /// mapping ChatRole -> OpenAI wire role: local/remote -> "user", agent -> "assistant",
    /// system -> "system"; empty-text items are dropped. Bumps `generation` and cancels any
    /// in-flight turn so a stream finalizing after the swap cannot append into the freshly
    /// loaded history (see appendAssistant / popLastUserMessage). Injecting an empty list (a
    /// cleared / New Chat transcript) resets the wire to nothing.
    func primeHistory(_ messages: [ChatMessage]) {
        let mapped: [[String: Any]] = messages.compactMap { message in
            guard !message.text.isEmpty else { return nil }
            let role: String
            switch message.role {
            case .local, .remote: role = "user"
            case .agent:          role = "assistant"
            case .system:         role = "system"
            }
            return ["role": role, "content": message.text]
        }
        let stale = lock.withLock { () -> Task<Void, Never>? in
            generation += 1
            let previous = promptTask
            promptTask = nil
            conversation = mapped
            return previous
        }
        stale?.cancel()
    }

    /// Advances itemCounter past every id we minted that is still in the restored transcript, so a
    /// continued turn mints FRESH ids. Our per-turn ids ("openai-msg-<n>" and the paired
    /// "openai-thought-<n>") come from itemCounter, which starts at 0 for each fresh transport
    /// instance (every app launch); without this, restoring a conversation saved in a prior run
    /// makes the next turn reuse a loaded id, which makes the store's ForEach OVERWRITE an existing
    /// bubble AND the journal's last-write-wins dedup drop the older item (data loss). The store
    /// hands us EVERY item id (including thoughts, which primeHistory omits), so this also covers a
    /// reasoning-only turn - a thought with no paired message. The `> itemCounter` guard only ever
    /// advances the counter, so switching to an older/shorter conversation mid-session never rewinds
    /// it and never re-collides.
    func reserveIDs(seen ids: [String]) {
        guard let maxSuffix = ids.compactMap(Self.itemSuffix).max() else { return }
        lock.withLock {
            if maxSuffix > itemCounter { itemCounter = maxSuffix }
        }
    }

    /// The numeric suffix of one of our per-turn ids ("openai-msg-<n>" / "openai-thought-<n>"),
    /// or nil for any other id (user-/system-/error- from the store, a "openai-tool-*" card, or a
    /// migrated/foreign id). Message and thought ids share itemCounter, so reserving past either
    /// keeps a continued turn from reusing a loaded id.
    private static func itemSuffix(_ id: String) -> Int? {
        for prefix in ["openai-msg-", "openai-thought-"] where id.hasPrefix(prefix) {
            return Int(id.dropFirst(prefix.count))
        }
        return nil
    }

    /// A snapshot of the wire history (role/content messages). Internal for tests.
    var conversationSnapshot: [[String: Any]] {
        lock.withLock { conversation }
    }

    func stop() async {
        lock.withLock { promptTask }?.cancel()
        eventSink.finish()
        // Release the session we created (cancelling any in-flight request); never touch a
        // session the host injected (a test reuses it across transports).
        if ownsSession {
            session.invalidateAndCancel()
        }
    }

    // MARK: - Outbound turn

    private func runTurn(userText: String) {
        // Only Sendable values (the item IDs) cross into the streaming Task; the messages
        // array is rebuilt inside stream() under the lock, so no [String: Any] is captured.
        // Cancel any turn still in flight first (a composer that stays live during streaming
        // can submit again): otherwise the prior task streams on, un-stoppable, and both
        // replies interleave. Cancelling it makes it finalize as `cancelled`.
        let (messageID, thoughtID, previous, gen) = lock.withLock { () -> (String, String, Task<Void, Never>?, Int) in
            conversation.append(["role": "user", "content": userText])
            itemCounter += 1
            return ("openai-msg-\(itemCounter)", "openai-thought-\(itemCounter)", promptTask, generation)
        }
        previous?.cancel()
        let task = Task { [weak self] in
            guard let self else {
                return
            }
            await self.stream(messageID: messageID, thoughtID: thoughtID, generation: gen)
        }
        lock.withLock { promptTask = task }
    }

    /// One streamed chat-completions turn: POST stream:true and demux the SSE chunks onto
    /// ChatEvents. Accumulators (content, tool-call fragments, finish reason) are locals -
    /// only the shared conversation / model / counter go through the lock.
    private func stream(messageID: String, thoughtID: String, generation gen: Int) async {
        let (messages, model) = lock.withLock { () -> ([[String: Any]], String) in
            var msgs: [[String: Any]] = []
            if !systemPrompt.isEmpty {
                msgs.append(["role": "system", "content": systemPrompt])
            }
            msgs.append(contentsOf: conversation)
            return (msgs, resolvedModel)
        }
        let body = Self.chatRequestBody(model: model, messages: messages, params: params)
        guard let request = makeRequest(url: chatURL, body: body) else {
            popLastUserMessage(generation: gen)
            eventSink.yield(.error(message: "openai-sse: could not encode the request body", recoverable: false))
            eventSink.yield(.messageEnd(itemID: messageID, stopReason: "error"))
            return
        }

        var fullContent = ""
        var messageStarted = false
        var toolFragments: [Int: ToolFragmentState] = [:]
        var finishReason: String?

        do {
            let (bytes, response) = try await session.bytes(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw OpenAITransportError("openai-sse: response was not HTTP")
            }
            if http.statusCode != 200 {
                if isSuperseded(gen) { return }   // primed away: the error is for a conversation the user left
                let message = await Self.errorBody(from: bytes, status: http.statusCode)
                popLastUserMessage(generation: gen)
                eventSink.yield(.error(message: message, recoverable: true))
                eventSink.yield(.messageEnd(itemID: messageID, stopReason: "error"))
                return
            }

            for try await line in bytes.lines {
                try Task.checkCancellation()
                if isSuperseded(gen) { return }   // primed away mid-stream: stay silent
                guard let payload = Self.ssePayload(line) else {
                    continue
                }
                if payload == "[DONE]" {
                    break
                }
                guard let data = payload.data(using: .utf8),
                      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                    continue
                }
                let chunk = Self.parseChunk(json)
                if let reasoning = chunk.reasoning, !reasoning.isEmpty {
                    eventSink.yield(.thoughtDelta(itemID: thoughtID, text: reasoning))
                }
                if let content = chunk.content, !content.isEmpty {
                    if !messageStarted {
                        eventSink.yield(.messageStart(itemID: messageID, role: .agent))
                        messageStarted = true
                    }
                    fullContent += content
                    eventSink.yield(.messageDelta(itemID: messageID, text: content))
                }
                for fragment in chunk.toolCalls {
                    var state = toolFragments[fragment.index] ?? ToolFragmentState()
                    if let id = fragment.id {
                        state.id = id
                    }
                    if let name = fragment.name {
                        state.name = name
                    }
                    if let argumentsDelta = fragment.argumentsDelta {
                        state.arguments += argumentsDelta
                    }
                    toolFragments[fragment.index] = state
                }
                if let usage = chunk.usage {
                    eventSink.yield(.usage(usage))
                }
                if let reason = chunk.finishReason {
                    finishReason = reason
                }
            }
        } catch is CancellationError {
            finalizeCancelled(messageID: messageID, partial: fullContent, messageStarted: messageStarted, generation: gen)
            return
        } catch let urlError as URLError where urlError.code == .cancelled {
            finalizeCancelled(messageID: messageID, partial: fullContent, messageStarted: messageStarted, generation: gen)
            return
        } catch {
            if isSuperseded(gen) { return }   // primed away: the error is for a conversation the user left
            // A connection failure or mid-stream disconnect: keep whatever streamed (and its
            // user turn), and surface the error (mirrors ACPChatTransport). If nothing
            // streamed, drop the dangling user message so retries do not accumulate.
            if messageStarted {
                appendAssistant(fullContent, generation: gen)
            } else {
                popLastUserMessage(generation: gen)
            }
            eventSink.yield(.error(message: "openai-sse request failed: \(error.localizedDescription)", recoverable: true))
            eventSink.yield(.messageEnd(itemID: messageID, stopReason: "error"))
            return
        }

        // Normal completion. Tool cards + notice go out BEFORE the terminal messageEnd, so
        // the store's non-nil stopReason (which clears the streaming state) is the last word.
        if isSuperseded(gen) { return }   // primed away after the stream finished: stay silent
        if !toolFragments.isEmpty {
            emitToolCards(toolFragments)
        }
        if messageStarted {
            appendAssistant(fullContent, generation: gen)
        }
        eventSink.yield(.messageEnd(itemID: messageID, stopReason: finishReason ?? "stop"))
    }

    /// Renders the accumulated tool-call fragments as completed cards, then a system notice
    /// that this transport does not execute tools (that is the agent layer's job).
    private func emitToolCards(_ fragments: [Int: ToolFragmentState]) {
        for index in fragments.keys.sorted() {
            guard let state = fragments[index] else {
                continue
            }
            let callID = state.id ?? "openai-tool-\(index)"
            let title = state.name.isEmpty ? "Tool call" : state.name
            eventSink.yield(.toolCall(ToolCallModel(
                id: callID, title: title, kind: .other, status: .completed,
                contentText: "", diff: nil, rawInput: Self.prettyArguments(state.arguments), rawOutput: nil)))
        }
        eventSink.yield(.system(text: "The model requested tool call(s); the openai-sse transport renders them but does not execute them. Use an agent transport (e.g. \"acp\") for tool execution."))
    }

    /// True once a primeHistory swapped the conversation since this turn began: the turn is
    /// superseded (its user has left this conversation) and must emit NOTHING further - not a
    /// trailing delta, not a terminal messageEnd - so no stray bubble or persisted entry lands
    /// in the newly loaded conversation. A plain Stop (.cancel) does NOT bump `generation`, so
    /// it is not superseded and still finalizes its partial normally.
    private func isSuperseded(_ gen: Int) -> Bool {
        lock.withLock { gen != generation }
    }

    /// Appends an assistant reply to the wire history only if the turn's generation is still
    /// current. A primeHistory (conversation swap / clear) since this turn began bumps
    /// `generation`, so a late finalize from a cancelled or failed stream cannot pollute the
    /// freshly loaded history.
    private func appendAssistant(_ content: String, generation gen: Int) {
        lock.withLock {
            guard gen == generation else { return }
            conversation.append(["role": "assistant", "content": content])
        }
    }

    /// Finalizes the open message with its partial text on cancel (the streamed deltas are
    /// already in the store's buffer; a non-nil stopReason ends the turn). The user message
    /// stays in the wire history - a cancel is user intent, not a failure.
    private func finalizeCancelled(messageID: String, partial: String, messageStarted: Bool, generation gen: Int) {
        guard !isSuperseded(gen) else { return }   // primed away: stay silent (no stray bubble/entry)
        if messageStarted {
            appendAssistant(partial, generation: gen)
        }
        eventSink.yield(.messageEnd(itemID: messageID, stopReason: "cancelled"))
    }

    /// Drops the trailing user message from the wire history when a turn produced no
    /// assistant reply at all (a hard failure before anything streamed), so repeated
    /// failures against a down server do not accumulate a run of back-to-back user
    /// messages that a strict server would reject on the eventual successful request. Guarded
    /// by generation so a swap since the turn began leaves the newly loaded history intact.
    private func popLastUserMessage(generation gen: Int) {
        lock.withLock {
            guard gen == generation else { return }
            if conversation.last?["role"] as? String == "user" {
                conversation.removeLast()
            }
        }
    }

    // MARK: - Requests

    private func resolveAutoModel() async -> String? {
        guard let request = makeRequest(url: modelsURL, body: nil) else {
            return nil
        }
        guard let (data, response) = try? await session.data(for: request),
              let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            return nil
        }
        return Self.parseModelsList(data).first
    }

    private func makeRequest(url: URL, body: [String: Any]?) -> URLRequest? {
        var request = URLRequest(url: url)
        if let body {
            guard JSONSerialization.isValidJSONObject(body),
                  let data = try? JSONSerialization.data(withJSONObject: body) else {
                return nil
            }
            request.httpMethod = "POST"
            request.httpBody = data
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        } else {
            request.httpMethod = "GET"
            request.setValue("application/json", forHTTPHeaderField: "Accept")
        }
        if !apiKey.isEmpty {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }
        return request
    }

    // MARK: - Pure parsing (static: unit-tested directly)

    /// The text after an SSE `data:` field, trimmed of the framing space / CR. Returns nil
    /// for any non-data line (event: / id: / comment / blank), which the loop skips.
    static func ssePayload(_ line: String) -> String? {
        guard line.hasPrefix("data:") else {
            return nil
        }
        return line.dropFirst("data:".count).trimmingCharacters(in: CharacterSet(charactersIn: " \t\r"))
    }

    /// One chat.completion.chunk -> the deltas it carries (content, reasoning, tool-call
    /// fragments, finish reason, usage). Tolerates the shape variations across servers
    /// (reasoning_content vs reasoning; usage on a choices-less final chunk).
    static func parseChunk(_ chunk: [String: Any]) -> StreamChunk {
        var result = StreamChunk()
        if let usage = chunk["usage"] as? [String: Any] {
            result.usage = parseUsage(usage)
        }
        guard let choices = chunk["choices"] as? [[String: Any]], let choice = choices.first else {
            return result
        }
        result.finishReason = choice["finish_reason"] as? String
        guard let delta = choice["delta"] as? [String: Any] else {
            return result
        }
        result.content = delta["content"] as? String
        result.reasoning = (delta["reasoning_content"] as? String) ?? (delta["reasoning"] as? String)
        if let toolCalls = delta["tool_calls"] as? [[String: Any]] {
            result.toolCalls = toolCalls.map { toolCall in
                let function = toolCall["function"] as? [String: Any]
                return ToolCallFragment(
                    index: (toolCall["index"] as? NSNumber)?.intValue ?? 0,
                    id: toolCall["id"] as? String,
                    name: function?["name"] as? String,
                    argumentsDelta: function?["arguments"] as? String)
            }
        }
        return result
    }

    /// OpenAI usage { prompt_tokens, completion_tokens, total_tokens } -> UsageInfo. Uses
    /// total_tokens when present, else prompt+completion. No context-window size / cost is
    /// reported by the wire, so `used` is the whole-turn total and size stays nil.
    static func parseUsage(_ usage: [String: Any]) -> UsageInfo? {
        let total = (usage["total_tokens"] as? NSNumber)?.intValue
        let prompt = (usage["prompt_tokens"] as? NSNumber)?.intValue
        let completion = (usage["completion_tokens"] as? NSNumber)?.intValue
        guard let used = total ?? prompt.map({ $0 + (completion ?? 0) }) else {
            return nil
        }
        return UsageInfo(used: used, size: nil, costAmount: nil, costCurrency: nil)
    }

    /// GET /models response { data: [{ id }] } -> the model ids.
    static func parseModelsList(_ data: Data) -> [String] {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let list = json["data"] as? [[String: Any]] else {
            return []
        }
        return list.compactMap { $0["id"] as? String }
    }

    /// The chat-completions request body: params merged first (so our keys win), a
    /// max_tokens of 0 dropped (our "unlimited" sentinel; servers reject 0), then model /
    /// messages / stream / stream_options set. Internal for tests.
    static func chatRequestBody(model: String, messages: [[String: Any]], params: [String: Any]) -> [String: Any] {
        var body = params
        if let maxTokens = (params["max_tokens"] as? NSNumber)?.intValue, maxTokens == 0 {
            body["max_tokens"] = nil
        }
        body["model"] = model
        body["messages"] = messages
        body["stream"] = true
        body["stream_options"] = ["include_usage": true]
        return body
    }

    /// Pretty-prints a tool call's accumulated arguments JSON; falls back to the raw string
    /// when it is not valid JSON (a partial / malformed stream). nil for empty arguments.
    static func prettyArguments(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return nil
        }
        if let data = trimmed.data(using: .utf8),
           let object = try? JSONSerialization.jsonObject(with: data),
           JSONSerialization.isValidJSONObject(object),
           let pretty = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys]),
           let text = String(data: pretty, encoding: .utf8) {
            return text
        }
        return trimmed
    }

    /// Reads a non-200 response body (capped) and extracts the OpenAI error message
    /// { error: { message } } when present, else the raw body.
    static func errorBody(from bytes: URLSession.AsyncBytes, status: Int) async -> String {
        var collected = Data()
        do {
            for try await byte in bytes {
                collected.append(byte)
                if collected.count > 8192 {
                    break
                }
            }
        } catch {
            // Use whatever was collected before the read failed.
        }
        if let json = try? JSONSerialization.jsonObject(with: collected) as? [String: Any],
           let error = json["error"] as? [String: Any],
           let message = error["message"] as? String {
            return "openai-sse HTTP \(status): \(message)"
        }
        let raw = (String(data: collected, encoding: .utf8) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return raw.isEmpty ? "openai-sse HTTP \(status)" : "openai-sse HTTP \(status): \(raw)"
    }

    // MARK: - Supporting value types

    /// The interpreted deltas of one streamed chunk.
    struct StreamChunk {
        var content: String?
        var reasoning: String?
        var toolCalls: [ToolCallFragment] = []
        var finishReason: String?
        var usage: UsageInfo?
    }

    /// One streamed tool-call fragment (fields arrive across chunks, keyed by index).
    struct ToolCallFragment {
        let index: Int
        let id: String?
        let name: String?
        let argumentsDelta: String?
    }

    /// Accumulator for a tool call being assembled across chunks.
    private struct ToolFragmentState {
        var id: String?
        var name: String = ""
        var arguments: String = ""
    }
}

struct OpenAITransportError: Error, CustomStringConvertible {
    let message: String
    init(_ message: String) {
        self.message = message
    }
    var description: String {
        message
    }
}
