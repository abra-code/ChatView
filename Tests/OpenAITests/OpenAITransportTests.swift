// Tests/OpenAITests/OpenAITransportTests.swift
//
// End-to-end tests for OpenAIChatTransport driven by the URLProtocol stub: the full SSE
// streaming path (content assembled into a transcript, usage surfaced), reasoning_content
// interleaved as thoughts, tool_calls rendered as completed cards plus a system notice,
// model "auto" resolution from /models, a non-200 JSON error body, a mid-stream disconnect,
// and cancel-mid-stream finalizing the partial reply. The pure wire parsing is covered in
// OpenAISSEParsingTests.

import XCTest
@testable import ChatViewOpenAI
import ChatView

private final class TestLogger: ChatLogger {
    func log(_ message: String, _ level: ChatLogLevel) {}
}

/// A free function (Sendable, unlike a method reference that captures the test case) used as
/// the drain terminal condition.
private func isMessageEnd(_ event: ChatEvent) -> Bool {
    if case .messageEnd = event {
        return true
    }
    return false
}

final class OpenAITransportTests: XCTestCase {

    private let chatPath = "/v1/chat/completions"
    private let modelsPath = "/v1/models"

    override func setUp() {
        super.setUp()
        StubURLProtocol.reset()
    }

    override func tearDown() {
        StubURLProtocol.reset()
        super.tearDown()
    }

    private func makeTransport(model: String = "test-model", params: [String: Any] = [:]) throws -> OpenAIChatTransport {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        let session = URLSession(configuration: configuration)
        var settings: [String: Any] = ["baseURL": "http://stub.local/v1", "model": model]
        if !params.isEmpty {
            settings["params"] = params
        }
        return try OpenAIChatTransport(config: ChatTransportConfig(settings: settings),
                                       logger: TestLogger(), session: session)
    }

    private func setChatStub(_ sse: String, terminal: StubURLProtocol.Terminal = .finish) {
        StubURLProtocol.setStub(.init(chunks: [Data(sse.utf8)], terminal: terminal), forPath: chatPath)
    }

    /// Drains events until `isTerminal`, with a safety timeout that finishes the stream so a
    /// broken test fails on assertions instead of hanging the suite.
    private func collect(from transport: OpenAIChatTransport,
                         until isTerminal: @Sendable @escaping (ChatEvent) -> Bool) async -> [ChatEvent] {
        let collector = Task { () -> [ChatEvent] in
            var collected: [ChatEvent] = []
            for await event in transport.events {
                collected.append(event)
                if isTerminal(event) {
                    break
                }
            }
            return collected
        }
        let timeout = Task {
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            await transport.stop()
        }
        let result = await collector.value
        timeout.cancel()
        return result
    }

    // MARK: - Streaming

    func testStreamingAssemblesTranscriptWithUsage() async throws {
        let sse = StubURLProtocol.sseEvent(#"{"choices":[{"delta":{"role":"assistant","content":"Hello"},"finish_reason":null}]}"#)
            + StubURLProtocol.sseEvent(#"{"choices":[{"delta":{"content":" world"},"finish_reason":null}]}"#)
            + StubURLProtocol.sseEvent(#"{"choices":[{"delta":{},"finish_reason":"stop"}]}"#)
            + StubURLProtocol.sseEvent(#"{"choices":[],"usage":{"prompt_tokens":3,"completion_tokens":2,"total_tokens":5}}"#)
            + StubURLProtocol.doneEvent
        setChatStub(sse)
        let transport = try makeTransport()
        await transport.start()
        await transport.send(.prompt(text: "hi"))
        let events = await collect(from: transport, until: isMessageEnd)
        await transport.stop()

        guard case .sessionReady(let sessionID, let options)? = events.first else {
            return XCTFail("expected sessionReady first")
        }
        XCTAssertEqual(sessionID, "openai-sse")
        XCTAssertEqual(options.first?.currentValue, "test-model", "the model surfaces as a read-only option")

        let text = events.compactMap { event -> String? in
            if case .messageDelta(_, let delta) = event {
                return delta
            }
            return nil
        }.joined()
        XCTAssertEqual(text, "Hello world")
        XCTAssertTrue(events.contains { if case .messageStart = $0 { return true }; return false })
        XCTAssertTrue(events.contains { if case .usage(let usage) = $0 { return usage.used == 5 }; return false })
        guard case .messageEnd(_, let stopReason) = events.last else {
            return XCTFail("expected messageEnd last")
        }
        XCTAssertEqual(stopReason, "stop")
    }

    func testReasoningStreamsAsThoughtBeforeMessage() async throws {
        let sse = StubURLProtocol.sseEvent(#"{"choices":[{"delta":{"reasoning_content":"Let me think"}}]}"#)
            + StubURLProtocol.sseEvent(#"{"choices":[{"delta":{"content":"Answer"}}]}"#)
            + StubURLProtocol.sseEvent(#"{"choices":[{"delta":{},"finish_reason":"stop"}]}"#)
            + StubURLProtocol.doneEvent
        setChatStub(sse)
        let transport = try makeTransport()
        await transport.start()
        await transport.send(.prompt(text: "hi"))
        let events = await collect(from: transport, until: isMessageEnd)
        await transport.stop()

        let thoughtIndex = events.firstIndex { if case .thoughtDelta = $0 { return true }; return false }
        let messageStartIndex = events.firstIndex { if case .messageStart = $0 { return true }; return false }
        XCTAssertNotNil(thoughtIndex, "reasoning_content must route to a thought")
        XCTAssertNotNil(messageStartIndex)
        XCTAssertLessThan(thoughtIndex!, messageStartIndex!, "the thought streams before the message opens")
        let thoughtText = events.compactMap { event -> String? in
            if case .thoughtDelta(_, let text) = event {
                return text
            }
            return nil
        }.joined()
        XCTAssertEqual(thoughtText, "Let me think")
    }

    func testToolCallsRenderAsCompletedCardsPlusNotice() async throws {
        let sse = StubURLProtocol.sseEvent(#"{"choices":[{"delta":{"tool_calls":[{"index":0,"id":"call_1","function":{"name":"get_time","arguments":"{\"tz\":"}}]}}]}"#)
            + StubURLProtocol.sseEvent(#"{"choices":[{"delta":{"tool_calls":[{"index":0,"function":{"arguments":"\"UTC\"}"}}]}}]}"#)
            + StubURLProtocol.sseEvent(#"{"choices":[{"delta":{},"finish_reason":"tool_calls"}]}"#)
            + StubURLProtocol.doneEvent
        setChatStub(sse)
        let transport = try makeTransport()
        await transport.start()
        await transport.send(.prompt(text: "what time is it"))
        let events = await collect(from: transport, until: isMessageEnd)
        await transport.stop()

        let toolCall = events.compactMap { event -> ToolCallModel? in
            if case .toolCall(let call) = event {
                return call
            }
            return nil
        }.first
        XCTAssertEqual(toolCall?.title, "get_time")
        XCTAssertEqual(toolCall?.status, .completed)
        XCTAssertEqual(toolCall?.id, "call_1")
        XCTAssertEqual(toolCall?.rawInput, "{\n  \"tz\" : \"UTC\"\n}", "the accumulated arguments are pretty-printed")
        XCTAssertTrue(events.contains { if case .system(let text) = $0 { return text.contains("does not execute") }; return false },
                      "a system notice explains tool calls are not executed")
        guard case .messageEnd(_, let stopReason) = events.last else {
            return XCTFail("expected messageEnd last")
        }
        XCTAssertEqual(stopReason, "tool_calls")
    }

    // MARK: - Model resolution

    func testModelAutoResolvesFromModelsEndpoint() async throws {
        let models = Data(#"{"object":"list","data":[{"id":"resolved-model"},{"id":"other"}]}"#.utf8)
        StubURLProtocol.setStub(.init(statusCode: 200, headers: ["Content-Type": "application/json"],
                                      chunks: [models], terminal: .finish), forPath: modelsPath)
        let transport = try makeTransport(model: "auto")
        await transport.start()
        let events = await collect(from: transport) { event in
            if case .sessionReady = event {
                return true
            }
            return false
        }
        await transport.stop()

        guard case .sessionReady(_, let options)? = events.last else {
            return XCTFail("expected sessionReady")
        }
        XCTAssertEqual(options.first?.currentValue, "resolved-model", "model 'auto' resolves to the first /models entry")
    }

    // MARK: - Errors

    func testNon200EmitsErrorWithServerMessage() async throws {
        let body = Data(#"{"error":{"message":"context length exceeded"}}"#.utf8)
        StubURLProtocol.setStub(.init(statusCode: 400, headers: ["Content-Type": "application/json"],
                                      chunks: [body], terminal: .finish), forPath: chatPath)
        let transport = try makeTransport()
        await transport.start()
        await transport.send(.prompt(text: "hi"))
        let events = await collect(from: transport, until: isMessageEnd)
        await transport.stop()

        XCTAssertTrue(events.contains { event in
            if case .error(let message, _) = event {
                return message.contains("context length exceeded") && message.contains("400")
            }
            return false
        }, "a non-200 surfaces the server's error message")
        guard case .messageEnd(_, let stopReason) = events.last else {
            return XCTFail("expected messageEnd last")
        }
        XCTAssertEqual(stopReason, "error")
    }

    func testMidStreamDisconnectKeepsPartialAndErrors() async throws {
        let sse = StubURLProtocol.sseEvent(#"{"choices":[{"delta":{"content":"partial reply"}}]}"#)
        setChatStub(sse, terminal: .failMidStream)
        let transport = try makeTransport()
        await transport.start()
        await transport.send(.prompt(text: "hi"))
        let events = await collect(from: transport, until: isMessageEnd)
        await transport.stop()

        XCTAssertTrue(events.contains { if case .messageDelta(_, let text) = $0 { return text == "partial reply" }; return false },
                      "the partial reply that streamed before the disconnect is kept")
        XCTAssertTrue(events.contains { if case .error = $0 { return true }; return false })
        guard case .messageEnd(_, let stopReason) = events.last else {
            return XCTFail("expected messageEnd last")
        }
        XCTAssertEqual(stopReason, "error")
    }

    // MARK: - Cancel

    func testCancelMidStreamFinalizesPartial() async throws {
        let sse = StubURLProtocol.sseEvent(#"{"choices":[{"delta":{"content":"streaming"}}]}"#)
        setChatStub(sse, terminal: .hang)   // deliver the delta, then never finish
        let transport = try makeTransport()
        await transport.start()
        await transport.send(.prompt(text: "hi"))

        let collector = Task { () -> [ChatEvent] in
            var collected: [ChatEvent] = []
            for await event in transport.events {
                collected.append(event)
                if case .messageEnd = event {
                    break
                }
            }
            return collected
        }
        try await Task.sleep(nanoseconds: 250_000_000)   // let the delta stream
        await transport.send(.cancel)
        let events = await collector.value
        await transport.stop()

        XCTAssertTrue(events.contains { if case .messageDelta(_, let text) = $0 { return text == "streaming" }; return false },
                      "the partial text streamed before cancel is finalized")
        guard case .messageEnd(_, let stopReason) = events.last else {
            return XCTFail("expected messageEnd last")
        }
        XCTAssertEqual(stopReason, "cancelled")
    }

    // MARK: - Wire history

    func testSuccessfulTurnRecordsUserAndAssistantInHistory() async throws {
        let sse = StubURLProtocol.sseEvent(#"{"choices":[{"delta":{"content":"Hi there"}}]}"#)
            + StubURLProtocol.sseEvent(#"{"choices":[{"delta":{},"finish_reason":"stop"}]}"#)
            + StubURLProtocol.doneEvent
        setChatStub(sse)
        let transport = try makeTransport()
        await transport.start()
        await transport.send(.prompt(text: "hello"))
        _ = await collect(from: transport, until: isMessageEnd)
        let history = transport.conversationSnapshot
        await transport.stop()

        XCTAssertEqual(history.count, 2, "a successful turn records the user and assistant messages")
        XCTAssertEqual(history.first?["role"] as? String, "user")
        XCTAssertEqual(history.first?["content"] as? String, "hello")
        XCTAssertEqual(history.last?["role"] as? String, "assistant")
        XCTAssertEqual(history.last?["content"] as? String, "Hi there")
    }

    func testHardFailureDropsDanglingUserMessage() async throws {
        let body = Data(#"{"error":{"message":"server error"}}"#.utf8)
        StubURLProtocol.setStub(.init(statusCode: 500, headers: ["Content-Type": "application/json"],
                                      chunks: [body], terminal: .finish), forPath: chatPath)
        let transport = try makeTransport()
        await transport.start()
        await transport.send(.prompt(text: "hello"))
        _ = await collect(from: transport, until: isMessageEnd)
        let history = transport.conversationSnapshot
        await transport.stop()

        XCTAssertTrue(history.isEmpty, "a hard failure with no reply drops the user message so retries do not accumulate back-to-back user turns")
    }

    // MARK: - Prime history (P0-2 continue-in seam)

    func testPrimeHistoryReplacesWireAndMapsRoles() throws {
        let transport = try makeTransport()
        transport.primeHistory([
            ChatMessage(id: "1", role: .local, text: "earlier question", isStreaming: false),
            ChatMessage(id: "2", role: .agent, text: "earlier answer", isStreaming: false),
            ChatMessage(id: "3", role: .system, text: "a note", isStreaming: false),
            ChatMessage(id: "4", role: .remote, text: "other party", isStreaming: false),
            ChatMessage(id: "5", role: .agent, text: "", isStreaming: false),   // empty -> dropped
        ])
        let history = transport.conversationSnapshot
        XCTAssertEqual(history.map { $0["role"] as? String }, ["user", "assistant", "system", "user"],
                       "local/remote -> user, agent -> assistant, system -> system; the empty-text item is dropped")
        XCTAssertEqual(history.map { $0["content"] as? String },
                       ["earlier question", "earlier answer", "a note", "other party"])
    }

    func testEmptyPrimeResetsWire() throws {
        let transport = try makeTransport()
        transport.primeHistory([ChatMessage(id: "1", role: .local, text: "old", isStreaming: false)])
        XCTAssertEqual(transport.conversationSnapshot.count, 1)
        transport.primeHistory([])   // a New Chat clear
        XCTAssertTrue(transport.conversationSnapshot.isEmpty, "an empty prime resets the wire history")
    }

    func testPrimeThenTurnContinuesWithPriorContext() async throws {
        let sse = StubURLProtocol.sseEvent(#"{"choices":[{"delta":{"content":"following up"}}]}"#)
            + StubURLProtocol.sseEvent(#"{"choices":[{"delta":{},"finish_reason":"stop"}]}"#)
            + StubURLProtocol.doneEvent
        setChatStub(sse)
        let transport = try makeTransport()
        transport.primeHistory([
            ChatMessage(id: "1", role: .local, text: "q1", isStreaming: false),
            ChatMessage(id: "2", role: .agent, text: "a1", isStreaming: false),
        ])
        await transport.start()
        await transport.send(.prompt(text: "q2"))
        _ = await collect(from: transport, until: isMessageEnd)
        let history = transport.conversationSnapshot
        await transport.stop()

        XCTAssertEqual(history.map { $0["content"] as? String }, ["q1", "a1", "q2", "following up"],
                       "a continued turn appends AFTER the primed history, so the prior turns are sent as context")
    }

    func testPrimeDuringStreamDiscardsTheStaleReply() async throws {
        // A turn is streaming when the user switches conversations (a re-prime). The cancelled
        // stream must NOT append its reply into the freshly primed history (generation guard).
        let sse = StubURLProtocol.sseEvent(#"{"choices":[{"delta":{"content":"stale"}}]}"#)
        setChatStub(sse, terminal: .hang)   // stream a delta, then never finish
        let transport = try makeTransport()
        transport.primeHistory([ChatMessage(id: "1", role: .local, text: "A", isStreaming: false)])
        await transport.start()
        await transport.send(.prompt(text: "mid"))
        try await Task.sleep(nanoseconds: 250_000_000)   // let "stale" stream
        transport.primeHistory([ChatMessage(id: "2", role: .agent, text: "B", isStreaming: false)])
        try await Task.sleep(nanoseconds: 250_000_000)   // let the cancelled turn finalize
        let history = transport.conversationSnapshot
        await transport.stop()

        XCTAssertEqual(history.map { $0["content"] as? String }, ["B"],
                       "the re-prime replaces the wire; the cancelled turn's stale user+reply are not appended")
    }

    func testPrimeDuringStreamSilencesTheSupersededTurnsEvents() async throws {
        // The store turns a stray messageDelta after a restore into a phantom bubble in the
        // NEW conversation (and would persist it): a superseded turn must emit no terminal
        // messageEnd (and no further deltas) once a prime swaps the conversation.
        let sse = StubURLProtocol.sseEvent(#"{"choices":[{"delta":{"content":"stale"}}]}"#)
        setChatStub(sse, terminal: .hang)   // stream a delta, then never finish
        let transport = try makeTransport()
        await transport.start()

        let collector = Task { () -> [ChatEvent] in
            var collected: [ChatEvent] = []
            for await event in transport.events {
                collected.append(event)
            }
            return collected
        }
        await transport.send(.prompt(text: "mid"))
        try await Task.sleep(nanoseconds: 250_000_000)   // let messageStart + "stale" delta stream
        transport.primeHistory([ChatMessage(id: "2", role: .agent, text: "B", isStreaming: false)])
        try await Task.sleep(nanoseconds: 250_000_000)   // the superseded turn's terminal would fire here
        await transport.stop()                            // finishes the event stream so the collector ends
        let events = await collector.value

        XCTAssertFalse(events.contains { if case .messageEnd = $0 { return true }; return false },
                       "a turn superseded by a prime emits no terminal messageEnd, so nothing is finalized/persisted into the restored conversation")
    }

    // MARK: - Reserve ids (continue without reusing a loaded id)

    func testReserveIDsSeedsCounterSoContinuedTurnDoesNotReuseLoadedIds() async throws {
        // A conversation saved in a PRIOR app run (itemCounter has since reset to 0) is restored:
        // its assistant replies already carry openai-msg-1 / openai-msg-2. The store reserves every
        // loaded id before priming, so the continued turn must mint a FRESH id (openai-msg-3), NOT
        // reuse openai-msg-N - a reused id makes the store's ForEach update the loaded bubble instead
        // of appending (the reply overwrites an earlier answer) and makes the journal's
        // last-write-wins dedup drop it (data loss). Non-counter ids must be ignored: user-N (from
        // the store) and openai-tool-99 (tool cards are index-based, not from itemCounter) - if
        // openai-tool-99 were reserved the turn would mint openai-msg-100, not openai-msg-3.
        let sse = StubURLProtocol.sseEvent(#"{"choices":[{"delta":{"content":"the summary"}}]}"#)
            + StubURLProtocol.sseEvent(#"{"choices":[{"delta":{},"finish_reason":"stop"}]}"#)
            + StubURLProtocol.doneEvent
        setChatStub(sse)
        let transport = try makeTransport()
        transport.reserveIDs(seen: ["user-1", "openai-msg-1", "user-2", "openai-msg-2", "openai-tool-99"])
        await transport.start()
        await transport.send(.prompt(text: "summarize prior conversation"))
        let events = await collect(from: transport, until: isMessageEnd)
        await transport.stop()

        let ids = events.compactMap { event -> String? in
            switch event {
            case .messageStart(let itemID, _): return itemID
            case .messageDelta(let itemID, _): return itemID
            case .messageEnd(let itemID, _): return itemID
            default: return nil
            }
        }
        XCTAssertFalse(ids.isEmpty, "the continued turn emits a message")
        XCTAssertFalse(ids.contains("openai-msg-1"), "must not reuse a loaded assistant id")
        XCTAssertFalse(ids.contains("openai-msg-2"),
                       "must not reuse the LAST loaded assistant id - that is the overwrite / data-loss bug")
        XCTAssertTrue(ids.allSatisfy { $0 == "openai-msg-3" },
                      "the continued turn mints the next fresh id past the loaded max suffix")
    }

    func testReserveIDsCoversReasoningOnlyThoughtIds() async throws {
        // A reasoning-only turn (reasoning streamed, then no content: Stop before the first content
        // delta, or a content-less reasoning response) persists an "openai-thought-<n>" with NO
        // paired "openai-msg-<n>". A message-only reseed would miss it, so a continued turn could
        // reuse the thought id - duplicating a SwiftUI id and overwriting the restored thought.
        // reserveIDs sees every id, so it advances past the thought too. Here the max message suffix
        // is 1 but a reasoning-only turn left openai-thought-5, so the next turn must be turn 6.
        let sse = StubURLProtocol.sseEvent(#"{"choices":[{"delta":{"reasoning_content":"hmm"}}]}"#)
            + StubURLProtocol.sseEvent(#"{"choices":[{"delta":{"content":"ok"}}]}"#)
            + StubURLProtocol.sseEvent(#"{"choices":[{"delta":{},"finish_reason":"stop"}]}"#)
            + StubURLProtocol.doneEvent
        setChatStub(sse)
        let transport = try makeTransport()
        transport.reserveIDs(seen: ["user-1", "openai-msg-1", "openai-thought-1", "openai-thought-5"])
        await transport.start()
        await transport.send(.prompt(text: "continue"))
        let events = await collect(from: transport, until: isMessageEnd)
        await transport.stop()

        let messageIDs = events.compactMap { event -> String? in
            if case .messageStart(let itemID, _) = event { return itemID }
            return nil
        }
        let thoughtIDs = events.compactMap { event -> String? in
            if case .thoughtDelta(let itemID, _) = event { return itemID }
            return nil
        }
        XCTAssertEqual(messageIDs, ["openai-msg-6"],
                       "the continued turn is seeded past the reasoning-only thought (openai-thought-5)")
        XCTAssertFalse(thoughtIDs.contains("openai-thought-5"),
                       "the paired thought id must not reuse the restored reasoning-only thought id")
        XCTAssertTrue(thoughtIDs.allSatisfy { $0 == "openai-thought-6" },
                      "the paired thought id is also seeded past openai-thought-5")
    }

    func testReserveIDsNeverRewindsTheCounter() async throws {
        // Two reservations in a row (restore a long conversation, then switch to an OLDER/shorter
        // one) must not rewind the counter into an id already reserved this session. After reserving
        // up to 5, reserving a smaller max (2) is a no-op, so the next turn is openai-msg-6.
        let sse = StubURLProtocol.sseEvent(#"{"choices":[{"delta":{"content":"a"}}]}"#)
            + StubURLProtocol.sseEvent(#"{"choices":[{"delta":{},"finish_reason":"stop"}]}"#)
            + StubURLProtocol.doneEvent
        setChatStub(sse)
        let transport = try makeTransport()
        transport.reserveIDs(seen: ["openai-msg-5"])
        transport.reserveIDs(seen: ["openai-msg-2"])          // smaller -> must not rewind
        await transport.start()
        await transport.send(.prompt(text: "next"))
        let events = await collect(from: transport, until: isMessageEnd)
        await transport.stop()

        let ids = events.compactMap { event -> String? in
            if case .messageStart(let itemID, _) = event { return itemID }
            return nil
        }
        XCTAssertEqual(ids, ["openai-msg-6"],
                       "reserving a smaller max after a larger one must not rewind the counter into a reused id")
    }

    // MARK: - Construction

    func testMissingBaseURLThrows() {
        XCTAssertThrowsError(try OpenAIChatTransport(config: ChatTransportConfig(settings: [:]), logger: TestLogger()))
        XCTAssertThrowsError(try OpenAIChatTransport(config: ChatTransportConfig(settings: ["baseURL": ""]), logger: TestLogger()))
    }
}
