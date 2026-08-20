// Tests/ACPTests/ChatACPPrimingTests.swift
//
// Wire-level tests for the priming path (session/prime, an mlx-agent extension):
// capability gating, the pre-session stash-then-flush order, the virgin empty-prime
// suppression, role filtering, prompt-chains-behind-prime ordering, the mid-turn
// cancel-then-prime ordering, and the bounded -32003 retry.
//
// These launch a REAL subprocess: a tiny scripted python agent that answers the ACP
// handshake, journals every request it receives (one JSON line per message, in arrival
// order) to a temp file, and scripts the few behaviors the tests need (no sessionPrime
// capability, a parked prompt that resolves on cancel, a busy-once prime). Polling the
// journal asserts WHAT reached the agent and IN WHAT ORDER - the property the client's
// task chaining exists to guarantee.

#if os(macOS)

import XCTest
@testable import ChatViewACP
@testable import ChatView

private final class PrimingTestLogger: ChatLogger {
    func log(_ message: String, _ level: ChatLogLevel) {}
}

@MainActor
final class ACPPrimingTests: XCTestCase {

    private var journalURL: URL!
    private var agentScriptURL: URL!

    override func setUp() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("acp-priming-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        journalURL = dir.appendingPathComponent("journal.jsonl")
        agentScriptURL = dir.appendingPathComponent("fake_agent.py")
        try Self.fakeAgentScript.write(to: agentScriptURL, atomically: true, encoding: .utf8)
    }

    /// The scripted agent. argv: <journal-path> [behavior]. Behaviors:
    ///   default     - answer everything immediately (sessionPrime advertised)
    ///   nocap       - initialize WITHOUT the sessionPrime capability
    ///   slow-prompt - park session/prompt; resolve it (stopReason cancelled) on session/cancel
    ///   busy-once   - fail the FIRST session/prime with -32003, succeed after
    ///   slow-prime  - stall session/prime for 400ms before answering, holding a prompt that
    ///                 chains behind it inside the pre-dispatch gap for the whole window
    ///   decline-condense - answer session/prime with condensed:false and a reason, the shape an
    ///                 agent returns when it will not summarize (no summarizer available, the
    ///                 request named one it cannot run, summarization disabled)
    ///   decline-bare - condensed:false with no reason: an agent that answered the question and
    ///                 did not explain
    private static let fakeAgentScript = """
        import sys, json, time
        journal = open(sys.argv[1], "a", buffering=1)
        behavior = sys.argv[2] if len(sys.argv) > 2 else "default"
        pending_prompt = None
        primes_failed = 0
        def out(obj):
            sys.stdout.write(json.dumps(obj) + "\\n"); sys.stdout.flush()
        for line in sys.stdin:
            try:
                msg = json.loads(line)
            except ValueError:
                continue
            method = msg.get("method")
            if method:
                journal.write(json.dumps({"method": method, "params": msg.get("params", {})}) + "\\n")
            rid = msg.get("id")
            if method == "initialize":
                caps = {"promptCapabilities": {"audio": False}}
                if behavior != "nocap":
                    caps["sessionPrime"] = True
                out({"jsonrpc": "2.0", "id": rid, "result": {"protocolVersion": 1, "agentCapabilities": caps}})
            elif method == "session/new":
                out({"jsonrpc": "2.0", "id": rid, "result": {"sessionId": "s1"}})
            elif method == "session/prime":
                if behavior == "busy-once" and primes_failed == 0:
                    primes_failed = 1
                    out({"jsonrpc": "2.0", "id": rid, "error": {"code": -32003, "message": "busy"}})
                elif behavior == "slow-prime":
                    time.sleep(0.4)
                    out({"jsonrpc": "2.0", "id": rid,
                         "result": {"primed": len(msg.get("params", {}).get("messages", []))}})
                elif behavior == "decline-condense":
                    out({"jsonrpc": "2.0", "id": rid,
                         "result": {"primed": len(msg.get("params", {}).get("messages", [])),
                                    "condensed": False,
                                    "reason": "the model is idle-unloaded"}})
                elif behavior == "decline-bare":
                    out({"jsonrpc": "2.0", "id": rid,
                         "result": {"primed": len(msg.get("params", {}).get("messages", [])),
                                    "condensed": False}})
                else:
                    out({"jsonrpc": "2.0", "id": rid,
                         "result": {"primed": len(msg.get("params", {}).get("messages", []))}})
            elif method == "session/prompt":
                if behavior == "slow-prompt":
                    pending_prompt = rid
                else:
                    out({"jsonrpc": "2.0", "id": rid, "result": {"stopReason": "end_turn"}})
            elif method == "session/cancel":
                if pending_prompt is not None:
                    time.sleep(0.1)
                    out({"jsonrpc": "2.0", "id": pending_prompt, "result": {"stopReason": "cancelled"}})
                    pending_prompt = None
        """

    private func makeTransport(behavior: String = "default") throws -> ACPChatTransport {
        try ACPChatTransport(
            config: ChatTransportConfig(settings: [
                "command": ["python3", agentScriptURL.path, journalURL.path, behavior]
            ]),
            logger: PrimingTestLogger())
    }

    /// The journal so far: one (method, params) per request the agent received, in order.
    private func journal() -> [(method: String, params: [String: Any])] {
        guard let text = try? String(contentsOf: journalURL, encoding: .utf8) else { return [] }
        return text.split(separator: "\n").compactMap { line in
            guard let obj = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any],
                  let method = obj["method"] as? String else {
                return nil
            }
            return (method, (obj["params"] as? [String: Any]) ?? [:])
        }
    }

    /// Polls until the journal's method list satisfies `condition` (or ~2s passes).
    private func waitForJournal(_ condition: @escaping ([String]) -> Bool) async {
        for _ in 0..<200 {
            if condition(journal().map(\.method)) { return }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    private func message(_ id: String, role: ChatRole, _ text: String) -> ChatMessage {
        ChatMessage(id: id, role: role, text: text, isStreaming: false)
    }

    // MARK: - Stash-then-flush, capability gate, suppression

    func testPrimeBeforeStartFlushesOnceAfterSessionNew() async throws {
        let transport = try makeTransport()
        // The store primes on attach, BEFORE start() - the transport must stash and flush.
        transport.primeHistory([
            message("u1", role: .local, "earlier question"),
            message("a1", role: .agent, "earlier answer"),
        ])
        await transport.start()
        await waitForJournal { $0.contains("session/prime") }

        let methods = journal().map(\.method)
        XCTAssertEqual(methods, ["initialize", "session/new", "session/prime"],
                       "a pre-session prime flushes exactly once, after session/new")
        let primeParams = journal().last { $0.method == "session/prime" }?.params
        let wire = (primeParams?["messages"] as? [[String: Any]]) ?? []
        XCTAssertEqual(wire.map { $0["role"] as? String }, ["user", "assistant"])
        XCTAssertEqual(wire.map { $0["content"] as? String }, ["earlier question", "earlier answer"])
        XCTAssertEqual(primeParams?["sessionId"] as? String, "s1")
        await transport.stop()
    }

    /// The summarizer the user chose has to arrive in the object the agent documents. A choice
    /// that stops at the transport is invisible: the restore still succeeds, the model is still
    /// primed, and the only trace is a summarizer name in the marker afterwards that does not
    /// match what was picked - which reads as the app ignoring them.
    func testTheCondenseRequestCarriesTheChosenSummarizer() async throws {
        let transport = try makeTransport()
        transport.primeHistory([message("u1", role: .local, "earlier question")],
                               condense: PrimeCondense(keepRecentTurns: 6, backend: "session"))
        await transport.start()
        await waitForJournal { $0.contains("session/prime") }

        let ask = journal().last { $0.method == "session/prime" }?.params["condense"] as? [String: Any]
        XCTAssertEqual(ask?["keepRecentTurns"] as? Int, 6)
        XCTAssertEqual(ask?["backend"] as? String, "session")
        await transport.stop()
    }

    /// No stored choice means "your default", which is the absence of the key - not a summarizer
    /// named "". An agent may refuse that, and a refusal replays the whole conversation.
    func testAnEmptySummarizerIsLeftOffTheWire() async throws {
        let transport = try makeTransport()
        transport.primeHistory([message("u1", role: .local, "earlier question")],
                               condense: PrimeCondense(keepRecentTurns: 6, backend: ""))
        await transport.start()
        await waitForJournal { $0.contains("session/prime") }

        let ask = journal().last { $0.method == "session/prime" }?.params["condense"] as? [String: Any]
        XCTAssertNotNil(ask, "the condense key itself is still the request to summarize")
        XCTAssertNil(ask?["backend"], "an empty choice must not reach the agent as a name")
        await transport.stop()
    }

    /// Whitespace is not a choice either. A host can build `PrimeCondense` directly, without
    /// going through the content parser that trims, so the transport trims too - an agent reading
    /// "   " as a value it does not recognize would refuse and replay the whole conversation.
    func testAWhitespaceSummarizerIsLeftOffTheWire() async throws {
        let transport = try makeTransport()
        transport.primeHistory([message("u1", role: .local, "earlier question")],
                               condense: PrimeCondense(keepRecentTurns: 6, backend: "  \n "))
        await transport.start()
        await waitForJournal { $0.contains("session/prime") }

        let ask = journal().last { $0.method == "session/prime" }?.params["condense"] as? [String: Any]
        XCTAssertNotNil(ask, "the condense key itself is still the request to summarize")
        XCTAssertNil(ask?["backend"])
        await transport.stop()
    }

    /// A REQUESTED condensation that did not happen has to say so. The user picked a summarizer
    /// and sent a message; without this the only difference from success is a slower turn, which
    /// reads as the app ignoring them - the same failure the marker on the success path prevents.
    func testADeclinedCondensationIsVisibleRatherThanSilent() async throws {
        let transport = try makeTransport(behavior: "decline-condense")
        transport.primeHistory([message("u1", role: .local, "earlier question")],
                               condense: PrimeCondense(keepRecentTurns: 6, backend: "session"))
        await transport.start()
        await waitForJournal { $0.contains("session/prime") }
        try await Task.sleep(nanoseconds: 300_000_000)   // let the response be handled
        await transport.stop()

        var notices: [String] = []
        for await event in transport.events {
            // TRANSIENT, not `.system`: the store shows it without journaling it, so a restore
            // that declines does not leave a permanent line in the conversation - and does not
            // leave a byte-identical pile of them after a few of them.
            if case .transientSystem(let text) = event { notices.append(text) }
        }
        XCTAssertTrue(notices.contains { $0.contains("Not summarized") }, "\(notices)")
        XCTAssertTrue(notices.contains { $0.contains("the model is idle-unloaded") },
                      "the agent's reason is the whole value of the notice: \(notices)")
    }

    /// An agent that does not implement `condense` answers a plain `{"primed": n}` - no
    /// `condensed` key at all. Saying "not summarized" on every restore of every conversation in
    /// that window would be noise about a capability the agent never claimed, so the KEY's
    /// presence is the gate rather than the reason's.
    func testAnAgentWithoutCondenseSupportSaysNothing() async throws {
        let transport = try makeTransport()   // the default agent answers `primed` only
        transport.primeHistory([message("u1", role: .local, "earlier question")],
                               condense: PrimeCondense(keepRecentTurns: 6, backend: "session"))
        await transport.start()
        await waitForJournal { $0.contains("session/prime") }
        try await Task.sleep(nanoseconds: 300_000_000)
        await transport.stop()

        var notices: [String] = []
        for await event in transport.events {
            if case .transientSystem(let text) = event { notices.append(text) }
            if case .system(let text) = event { notices.append(text) }
        }
        XCTAssertFalse(notices.contains { $0.contains("Not summarized") }, "\(notices)")
    }

    /// And a prime nobody asked to condense stays silent: "nothing was summarized" on every
    /// ordinary restore would be noise.
    func testAnUnrequestedPrimeSaysNothingAboutSummarizing() async throws {
        let transport = try makeTransport(behavior: "decline-condense")
        transport.primeHistory([message("u1", role: .local, "earlier question")])
        await transport.start()
        await waitForJournal { $0.contains("session/prime") }
        try await Task.sleep(nanoseconds: 300_000_000)
        await transport.stop()

        var notices: [String] = []
        for await event in transport.events {
            if case .transientSystem(let text) = event { notices.append(text) }
        }
        XCTAssertFalse(notices.contains { $0.contains("Not summarized") }, "\(notices)")
    }

    /// But an agent that DID answer and declined without explaining still has to say so: "the
    /// whole conversation went to the model" is the part the user can act on, reason or no reason.
    func testADeclineWithoutAReasonStillSaysWhatHappened() async throws {
        let transport = try makeTransport(behavior: "decline-bare")
        transport.primeHistory([message("u1", role: .local, "earlier question")],
                               condense: PrimeCondense(keepRecentTurns: 6))
        await transport.start()
        await waitForJournal { $0.contains("session/prime") }
        try await Task.sleep(nanoseconds: 300_000_000)
        await transport.stop()

        var notices: [String] = []
        for await event in transport.events {
            if case .transientSystem(let text) = event { notices.append(text) }
        }
        XCTAssertTrue(notices.contains { $0.contains("Not summarized") }, "\(notices)")
        XCTAssertFalse(notices.contains { $0.hasSuffix(":") }, "no dangling colon: \(notices)")
    }

    func testPrimeIsGatedOnTheSessionPrimeCapability() async throws {
        let transport = try makeTransport(behavior: "nocap")
        transport.primeHistory([message("u1", role: .local, "q")])
        await transport.start()
        // Give a would-be prime ample time to appear, then require its absence.
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertFalse(journal().map(\.method).contains("session/prime"),
                       "an agent that does not advertise sessionPrime must never receive session/prime")
        await transport.stop()
    }

    func testVirginEmptyPrimeIsSuppressed() async throws {
        let transport = try makeTransport()
        transport.primeHistory([])   // attach on a fresh window: nothing to reset
        await transport.start()
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertFalse(journal().map(\.method).contains("session/prime"),
                       "an empty prime on a virgin session (no prior prime, no turn) is a pointless reset and is suppressed")
        await transport.stop()
    }

    func testSystemAndRemoteRolesAreFilteredFromTheWire() async throws {
        let transport = try makeTransport()
        transport.primeHistory([
            message("s1", role: .system, "model switched"),
            message("u1", role: .local, "q"),
            message("r1", role: .remote, "peer text"),
            message("a1", role: .agent, "a"),
        ])
        await transport.start()
        await waitForJournal { $0.contains("session/prime") }
        let wire = (journal().last { $0.method == "session/prime" }?.params["messages"] as? [[String: Any]]) ?? []
        XCTAssertEqual(wire.map { $0["role"] as? String }, ["user", "assistant"],
                       "session notices and P2P roles are display items, not model context")
        await transport.stop()
    }

    // MARK: - Ordering: prompts chain behind primes; mid-turn restores cancel first

    func testPromptWaitsForThePrimeOnTheWire() async throws {
        let transport = try makeTransport()
        await transport.start()
        await waitForJournal { $0.contains("session/new") }

        transport.primeHistory([message("u1", role: .local, "resumed context")])
        await transport.send(.prompt(text: "continue"))
        await waitForJournal { $0.contains("session/prompt") }

        let methods = journal().map(\.method)
        let primeIndex = try XCTUnwrap(methods.firstIndex(of: "session/prime"))
        let promptIndex = try XCTUnwrap(methods.firstIndex(of: "session/prompt"))
        XCTAssertLessThan(primeIndex, promptIndex,
                          "a prompt submitted right after a restore reaches the agent AFTER the prime")
        await transport.stop()
    }

    func testMidTurnRestoreCancelsThenPrimesAfterTheTurnResolves() async throws {
        let transport = try makeTransport(behavior: "slow-prompt")
        await transport.start()
        await waitForJournal { $0.contains("session/new") }

        await transport.send(.prompt(text: "long generation"))
        await waitForJournal { $0.contains("session/prompt") }
        // Restore while the turn is streaming: the transport must cancel the turn and
        // send the prime only after the cancelled prompt RESOLVES agent-side.
        transport.primeHistory([message("u1", role: .local, "other conversation")])
        await waitForJournal { $0.contains("session/prime") }

        let methods = journal().map(\.method)
        let promptIndex = try XCTUnwrap(methods.firstIndex(of: "session/prompt"))
        let cancelIndex = try XCTUnwrap(methods.firstIndex(of: "session/cancel"))
        let primeIndex = try XCTUnwrap(methods.firstIndex(of: "session/prime"))
        XCTAssertLessThan(promptIndex, cancelIndex)
        XCTAssertLessThan(cancelIndex, primeIndex,
                          "the prime goes out only after session/cancel (and the turn's resolution)")
        await transport.stop()
    }

    // MARK: - Stop inside the pre-dispatch gap

    /// A turn does not reach the wire the instant it is submitted: startTurn's task first
    /// awaits any in-flight prime. Stop pressed inside that window used to notify
    /// session/cancel for a turn the agent had never heard of (a no-op), after which the
    /// prompt dispatched anyway and ran to completion - the user's Stop did nothing and the
    /// composer stayed streaming out a full answer. The suppressed turn must never reach
    /// the wire at all.
    func testCancelBeforeDispatchSuppressesThePrompt() async throws {
        let transport = try makeTransport(behavior: "slow-prime")
        await transport.start()
        await waitForJournal { $0.contains("session/new") }

        // The prime parks agent-side for 400ms; a prompt submitted now chains behind it and
        // sits in the pre-dispatch gap for that whole window.
        transport.primeHistory([message("u1", role: .local, "resumed context")])
        await transport.send(.prompt(text: "a question the user immediately regrets"))
        await transport.send(.cancel)

        // Well past the prime's release: if the prompt were going to dispatch, it would have.
        try await Task.sleep(nanoseconds: 900_000_000)
        let methods = journal().map(\.method)
        XCTAssertFalse(methods.contains("session/prompt"),
                       "a turn cancelled before it reached the wire must never be dispatched")
        XCTAssertFalse(methods.contains("session/cancel"),
                       "there is nothing to cancel agent-side for a turn it never received")
        await transport.stop()
    }

    /// The other half of the latch: once the turn IS on the wire, Stop must still reach the
    /// agent as session/cancel. Guards against "fixing" the gap by suppressing every cancel.
    func testCancelAfterDispatchStillNotifiesTheAgent() async throws {
        let transport = try makeTransport(behavior: "slow-prompt")
        await transport.start()
        await waitForJournal { $0.contains("session/new") }

        await transport.send(.prompt(text: "long generation"))
        await waitForJournal { $0.contains("session/prompt") }   // provably dispatched
        await transport.send(.cancel)
        await waitForJournal { $0.contains("session/cancel") }

        XCTAssertTrue(journal().map(\.method).contains("session/cancel"),
                      "a dispatched turn is cancelled agent-side, as before")
        await transport.stop()
    }

    /// A cancelled turn must not wedge the transport: the NEXT prompt dispatches normally.
    /// The latch is per-generation, so it can never leak onto a later turn.
    func testPromptAfterASuppressedTurnStillDispatches() async throws {
        let transport = try makeTransport(behavior: "slow-prime")
        await transport.start()
        await waitForJournal { $0.contains("session/new") }

        transport.primeHistory([message("u1", role: .local, "resumed context")])
        await transport.send(.prompt(text: "regretted"))
        await transport.send(.cancel)
        await waitForJournal { $0.contains("session/prime") }

        await transport.send(.prompt(text: "actually asked"))
        await waitForJournal { $0.contains("session/prompt") }

        let prompts = journal().filter { $0.method == "session/prompt" }
        XCTAssertEqual(prompts.count, 1, "exactly the second prompt reaches the agent")
        let blocks = (prompts.first?.params["prompt"] as? [[String: Any]]) ?? []
        XCTAssertEqual(blocks.first?["text"] as? String, "actually asked",
                       "the suppressed turn's text must not be what got sent")
        await transport.stop()
    }

    func testBusyPrimeRetriesOnceAndSucceeds() async throws {
        let transport = try makeTransport(behavior: "busy-once")
        await transport.start()
        await waitForJournal { $0.contains("session/new") }

        transport.primeHistory([message("u1", role: .local, "q")])
        await waitForJournal { methods in methods.filter { $0 == "session/prime" }.count == 2 }

        let primes = journal().map(\.method).filter { $0 == "session/prime" }
        XCTAssertEqual(primes.count, 2, "a first -32003 is an expected transient; exactly one bounded retry")
        await transport.stop()
    }
}

#endif
