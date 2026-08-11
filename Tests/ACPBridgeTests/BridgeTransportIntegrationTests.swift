// Tests/ACPBridgeTests/BridgeTransportIntegrationTests.swift
//
// The real client against the real server: a genuine `ACPRemoteTransport` (default
// URLSession socket) driving a genuine `ACPBridge` (real NWListener) that owns a genuine
// stdio agent subprocess. Nothing is scripted at the wire.
//
// This is the test that matters most in phase 2, because the unit tests on each side are
// written against the same document rather than against each other: `ScriptedBridge` in
// ChatACPRemoteTests is a reading of plan section 7, and the bridge is a separate reading of
// it. Two independent readings agreeing is worth far more than either one passing alone.
//
// Every wait is deadline-bounded - the failure mode here is a hang, and a hang has to fail one
// test rather than wedge the suite.

#if os(macOS)

import XCTest
@testable import ACPBridgeCore
@testable import ChatViewACP
import ChatView

private final class IntegrationLogger: ChatLogger, @unchecked Sendable {
    func log(_ message: String, _ level: ChatLogLevel) {
        if ProcessInfo.processInfo.environment["ACP_BRIDGE_TEST_LOG"] != nil {
            FileHandle.standardError.write(Data("[\(level)] \(message)\n".utf8))
        }
    }
}

private final class Events: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [ChatEvent] = []
    private var task: Task<Void, Never>?

    func start(_ transport: ACPRemoteTransport) {
        task = Task { [weak self] in
            for await event in transport.events {
                self?.lock.withLock { self?.stored.append(event) }
            }
        }
    }

    func stop() {
        task?.cancel()
    }

    var all: [ChatEvent] {
        lock.withLock { stored }
    }

    /// Message ids in the order they were opened - the thing two devices must agree on.
    var messageIDs: [String] {
        all.compactMap {
            if case .messageStart(let id, _) = $0 {
                return id
            }
            return nil
        }
    }

    var text: String {
        all.compactMap {
            if case .messageDelta(_, let text) = $0 {
                return text
            }
            return nil
        }.joined()
    }

    var checkpoints: [Int] {
        all.compactMap {
            if case .resumeCheckpoint(_, let afterSeq) = $0 {
                return afterSeq
            }
            return nil
        }
    }

    func hasTurnEnd(stopReason: String) -> Bool {
        all.contains {
            if case .messageEnd(_, let reason) = $0 {
                return reason == stopReason
            }
            return false
        }
    }

    var sessionInfo: AgentSessionInfo? {
        all.compactMap {
            if case .sessionInfo(let info) = $0 {
                return info
            }
            return nil
        }.first
    }

    var nonRecoverableErrors: [String] {
        all.compactMap {
            if case .error(let message, let recoverable) = $0, !recoverable {
                return message
            }
            return nil
        }
    }

    func wait(_ description: String, timeout: TimeInterval = 10,
              file: StaticString = #filePath, line: UInt = #line,
              until predicate: () -> Bool) {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if predicate() {
                return
            }
            usleep(5_000)
        }
        XCTFail("timed out waiting for \(description)", file: file, line: line)
    }
}

final class BridgeTransportIntegrationTests: XCTestCase {

    private var directory: URL!
    private var bridge: ACPBridge?
    private var port: UInt16 = 0
    private let token = "integration-token"

    override func setUpWithError() throws {
        directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("acp-bridge-integration-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        bridge?.stop()
        bridge = nil
        try? FileManager.default.removeItem(at: directory)
    }

    // MARK: - Fake agents

    /// Streams two chunks and ends the turn.
    private static let simplePrompt = """
          printf '%s\\n' '{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"sess-1","update":{"sessionUpdate":"agent_message_chunk","content":{"type":"text","text":"Hello "}}}}'
          printf '%s\\n' '{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"sess-1","update":{"sessionUpdate":"agent_message_chunk","content":{"type":"text","text":"world."}}}}'
          printf '%s\\n' "{\\"jsonrpc\\":\\"2.0\\",\\"id\\":$id,\\"result\\":{\\"stopReason\\":\\"end_turn\\"}}"
    """

    /// Asks for permission, waits for the answer, then ends the turn.
    private static let permissionPrompt = """
          printf '%s\\n' '{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"sess-1","update":{"sessionUpdate":"tool_call","toolCallId":"call-1","title":"Edit main.swift","kind":"edit","status":"pending"}}}'
          printf '%s\\n' '{"jsonrpc":"2.0","id":900,"method":"session/request_permission","params":{"sessionId":"sess-1","toolCall":{"toolCallId":"call-1","title":"Edit main.swift"},"options":[{"optionId":"allow","name":"Allow","kind":"allow_once"},{"optionId":"deny","name":"Deny","kind":"reject_once"}]}}'
          while IFS= read -r answer; do
            case "$answer" in
              *'"id":900'*) break ;;
            esac
          done
          printf '%s\\n' '{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"sess-1","update":{"sessionUpdate":"tool_call_update","toolCallId":"call-1","status":"completed"}}}'
          printf '%s\\n' "{\\"jsonrpc\\":\\"2.0\\",\\"id\\":$id,\\"result\\":{\\"stopReason\\":\\"end_turn\\"}}"
    """

    private func agentScript(promptBody: String) -> String {
        """
        #!/bin/sh
        while IFS= read -r line; do
          id=$(printf '%s' "$line" | sed -n 's/.*"id":\\([0-9]*\\).*/\\1/p')
          case "$line" in
            *'"method":"initialize"'*)
              printf '%s\\n' "{\\"jsonrpc\\":\\"2.0\\",\\"id\\":$id,\\"result\\":{\\"protocolVersion\\":1,\\"agentCapabilities\\":{},\\"agentInfo\\":{\\"name\\":\\"integration-agent\\",\\"version\\":\\"1.2\\"}}}" ;;
            *'"method":"session/new"'*)
              printf '%s\\n' "{\\"jsonrpc\\":\\"2.0\\",\\"id\\":$id,\\"result\\":{\\"sessionId\\":\\"sess-1\\"}}" ;;
            *'"method":"session/prompt"'*)
        \(promptBody) ;;
          esac
        done
        """
    }

    private func startBridge(promptBody: String = BridgeTransportIntegrationTests.simplePrompt) throws {
        let url = directory.appendingPathComponent("agent")
        try agentScript(promptBody: promptBody).write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)

        let config = BridgeConfig(listen: "127.0.0.1:0",
                                  agent: BridgeAgentConfig(command: [url.path], cwd: directory.path),
                                  token: token,
                                  permissionTimeoutSeconds: 30,
                                  logDir: directory.appendingPathComponent("sessions").path)
        let bridge = ACPBridge(config: config, token: token, logger: IntegrationLogger())
        self.bridge = bridge
        self.port = try bridge.start()
    }

    private func makeTransport(session: String = "new",
                               resumeAfterSeq: Int? = nil) throws -> (ACPRemoteTransport, Events) {
        var settings: [String: Any] = [
            "url": "ws://127.0.0.1:\(port)/acp",
            "token": token,
            "session": session,
        ]
        if let resumeAfterSeq {
            settings["resumeAfterSeq"] = resumeAfterSeq
        }
        let transport = try ACPRemoteTransport(config: ChatTransportConfig(protocolName: "acp-remote",
                                                                          settings: settings),
                                               logger: IntegrationLogger())
        let events = Events()
        events.start(transport)
        return (transport, events)
    }

    // MARK: - Tests

    func testFullTurnAgainstTheRealBridge() async throws {
        try startBridge()
        let (transport, events) = try makeTransport()
        defer { events.stop() }

        await transport.start()
        events.wait("the session to be ready") {
            events.all.contains {
                if case .sessionReady = $0 {
                    return true
                }
                return false
            }
        }

        // The agent's real identity has to survive the whole chain: agent -> bridge -> socket.
        events.wait("the identity event") { events.sessionInfo != nil }
        let info = events.sessionInfo
        XCTAssertEqual(info?.agentName, "integration-agent")
        XCTAssertEqual(info?.agentVersion, "1.2")

        await transport.send(.prompt(text: "hello"))
        events.wait("the turn to end") { events.hasTurnEnd(stopReason: "end_turn") }
        XCTAssertEqual(events.text, "Hello world.")
        // Our own message must not be echoed back into the transcript.
        XCTAssertEqual(events.messageIDs.count, 1, "only the agent's bubble; the user's is the store's")

        await transport.stop()
    }

    func testPermissionRoundTripAgainstTheRealBridge() async throws {
        try startBridge(promptBody: Self.permissionPrompt)
        let (transport, events) = try makeTransport()
        defer { events.stop() }

        await transport.start()
        events.wait("ready") {
            events.all.contains {
                if case .sessionReady = $0 {
                    return true
                }
                return false
            }
        }
        await transport.send(.prompt(text: "edit it"))

        events.wait("the permission gate") {
            events.all.contains {
                if case .permissionRequest = $0 {
                    return true
                }
                return false
            }
        }
        let request = events.all.compactMap { event -> PermissionRequest? in
            if case .permissionRequest(let request) = event {
                return request
            }
            return nil
        }.first
        XCTAssertEqual(request?.id, "perm-1", "the gate id is the bridge's stable requestKey")
        XCTAssertEqual(request?.options.count, 2)

        await transport.send(.permissionResponse(requestID: request?.id ?? "", optionID: "allow"))
        events.wait("the turn to end after the answer") { events.hasTurnEnd(stopReason: "end_turn") }
        await transport.stop()
    }

    /// Two devices and a cold launch: the ids must agree without any reconciliation.
    func testSecondDeviceAndReplayProduceIdenticalItemIDs() async throws {
        try startBridge()

        let (first, firstEvents) = try makeTransport()
        defer { firstEvents.stop() }
        await first.start()
        firstEvents.wait("ready") {
            firstEvents.all.contains {
                if case .sessionReady = $0 {
                    return true
                }
                return false
            }
        }
        await first.send(.prompt(text: "one"))
        firstEvents.wait("turn one") { firstEvents.hasTurnEnd(stopReason: "end_turn") }
        let firstIDs = firstEvents.messageIDs
        let checkpoint = firstEvents.checkpoints.last
        XCTAssertNotNil(checkpoint, "a completed turn must offer the host a resume cursor")
        await first.stop()

        // "Another device" runs a second turn while the first is away.
        let (second, secondEvents) = try makeTransport(session: "latest")
        defer { secondEvents.stop() }
        await second.start()
        secondEvents.wait("the second device to attach") {
            secondEvents.all.contains {
                if case .sessionReady = $0 {
                    return true
                }
                return false
            }
        }
        // Attaching from 0 replays turn one. The second device renders one item MORE than the
        // first did - the user message. That is plan 4.5's documented asymmetry, not a defect:
        // the originating device already showed its own send through the store's optimistic
        // append (which is not a transport event at all) and suppresses the echo, while every
        // other view of that message comes off the log as acpr-m-<seq>.
        secondEvents.wait("the replay of turn one") { secondEvents.messageIDs.count >= firstIDs.count + 1 }
        XCTAssertTrue(firstIDs.allSatisfy { secondEvents.messageIDs.contains($0) },
                      "every id the first device minted must reappear identically on the second: "
                      + "ids are pure functions of the log. first=\(firstIDs) second=\(secondEvents.messageIDs)")
        XCTAssertEqual(secondEvents.messageIDs.first, "acpr-m-1",
                       "the second device additionally renders the user message the first one sent")

        let afterFirstTurn = secondEvents.messageIDs.count
        await second.send(.prompt(text: "two"))
        secondEvents.wait("turn two") { secondEvents.messageIDs.count > afterFirstTurn }
        await second.stop()

        // The first device comes back with its checkpoint: it must receive ONLY what it missed.
        let (third, thirdEvents) = try makeTransport(session: "sess-1", resumeAfterSeq: checkpoint)
        defer { thirdEvents.stop() }
        await third.start()
        thirdEvents.wait("the incremental catch-up") { thirdEvents.hasTurnEnd(stopReason: "end_turn") }
        XCTAssertFalse(thirdEvents.messageIDs.contains(firstIDs[0]),
                       "resuming from a checkpoint must not re-deliver what the host already stored")
        await third.stop()
    }

    func testAgentDeathSurfacesTurnEndThenSessionEnd() async throws {
        // Dies on the first prompt.
        try startBridge(promptBody: "      exit 3")
        let (transport, events) = try makeTransport()
        defer { events.stop() }

        await transport.start()
        events.wait("ready") {
            events.all.contains {
                if case .sessionReady = $0 {
                    return true
                }
                return false
            }
        }
        await transport.send(.prompt(text: "go"))

        events.wait("the session-ended error") { !events.nonRecoverableErrors.isEmpty }
        // I8 all the way through to the client: the turn must end BEFORE the session does, or
        // the composer never re-enables.
        XCTAssertTrue(events.hasTurnEnd(stopReason: "error"),
                      "every accepted turn ends, even when the agent dies mid-turn")
        XCTAssertTrue(events.nonRecoverableErrors.contains { $0.contains("agent_exit") },
                      "got \(events.nonRecoverableErrors)")
        await transport.stop()
    }

    func testReconnectAfterTheBridgeDropsTheClient() async throws {
        try startBridge()
        let (transport, events) = try makeTransport()
        defer { events.stop() }

        await transport.start()
        events.wait("ready") {
            events.all.contains {
                if case .sessionReady = $0 {
                    return true
                }
                return false
            }
        }
        await transport.send(.prompt(text: "one"))
        events.wait("turn one") { events.hasTurnEnd(stopReason: "end_turn") }
        let idsBefore = events.messageIDs

        // Actually drop it. The bridge keeps the session live and the log intact, so this is a
        // network failure and nothing else - which is exactly the case the transport exists for.
        bridge?.dropAllClientsForTesting()
        events.wait("the transport to notice") {
            events.all.contains {
                if case .connectionStateChanged(.reconnecting) = $0 {
                    return true
                }
                return false
            }
        }

        // It has to come back on its own and be usable again, with no duplicated history.
        events.wait("the reconnect", timeout: 30) {
            events.all.reduce(into: 0) { count, event in
                if case .connectionStateChanged(.connected) = event {
                    count += 1
                }
            } >= 2
        }
        XCTAssertEqual(events.messageIDs, idsBefore,
                       "reattaching from lastSeq must not re-deliver what was already rendered")

        await transport.send(.prompt(text: "two"))
        events.wait("a turn after the reconnect", timeout: 30) { events.messageIDs.count > idsBefore.count }
        await transport.stop()
    }
}

#endif
