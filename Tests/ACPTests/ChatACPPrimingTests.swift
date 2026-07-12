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
