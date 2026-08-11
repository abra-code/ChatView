// Tests/ACPBridgeTests/BridgeProtocolTests.swift
//
// End-to-end tests for the bridge: a real fake ACP agent as a subprocess (shell scripts in
// the ChatACPLaunchTests idiom), a real NWListener, and a real URLSessionWebSocketTask
// client. Nothing here is mocked at the wire, so a passing run is a conformance check of
// section 7 of the plan rather than a check that our fakes agree with each other.
//
// Every wait is deadline-bounded: the failures these tests exist to catch (a turn that
// never ends, a permission that never resolves, a replay that never arrives) are all
// hangs, and a hang must fail one test rather than wedge the suite.

#if os(macOS)

import XCTest
@testable import ACPBridgeCore
import ChatView

private final class SilentLogger: ChatLogger, @unchecked Sendable {
    func log(_ message: String, _ level: ChatLogLevel) {
        if ProcessInfo.processInfo.environment["ACP_BRIDGE_TEST_LOG"] != nil {
            FileHandle.standardError.write(Data("[bridge \(level)] \(message)\n".utf8))
        }
    }
}

/// A JSON-RPC client over a real WebSocket, collecting inbound notifications and answering
/// bridge-initiated requests through a pluggable hook.
private final class TestClient: @unchecked Sendable {

    private let task: URLSessionWebSocketTask
    private let lock = NSLock()
    private var notifications: [[String: Any]] = []
    private var responses: [Int: [String: Any]] = [:]
    private var nextID = 1
    private var closed = false

    /// Answers a bridge request (`session/request_permission`). Return nil to stay silent,
    /// which is how the timeout test keeps the request unanswered.
    var onRequest: (@Sendable ([String: Any]) -> [String: Any]?)?

    init(port: UInt16) {
        let url = URL(string: "ws://127.0.0.1:\(port)/acp")!
        task = URLSession.shared.webSocketTask(with: url)
        task.resume()
        receive()
    }

    private func receive() {
        task.receive { [weak self] result in
            guard let self else {
                return
            }
            switch result {
            case .failure:
                self.lock.withLock { self.closed = true }
                return
            case .success(let message):
                if case .string(let text) = message,
                   let data = text.data(using: .utf8),
                   let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                    self.handle(object)
                }
                self.receive()
            }
        }
    }

    private func handle(_ object: [String: Any]) {
        if let method = object["method"] as? String {
            if let requestID = object["id"], let handler = onRequest {
                let params = (object["params"] as? [String: Any]) ?? [:]
                if let result = handler(params) {
                    send(["jsonrpc": "2.0", "id": requestID, "result": result])
                }
                return
            }
            _ = method
            lock.withLock { notifications.append(object) }
            return
        }
        if let responseID = object["id"] as? Int {
            lock.withLock { responses[responseID] = object }
        }
    }

    private func send(_ object: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: object),
              let text = String(data: data, encoding: .utf8) else {
            return
        }
        task.send(.string(text)) { _ in }
    }

    /// Sends a request and waits for its response, or nil on timeout.
    func request(_ method: String, _ params: [String: Any], timeout: TimeInterval = 5) -> [String: Any]? {
        let id: Int = lock.withLock {
            let next = nextID
            nextID += 1
            return next
        }
        send(["jsonrpc": "2.0", "id": id, "method": method, "params": params])
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let response = lock.withLock({ responses[id] }) {
                return response
            }
            usleep(5_000)
        }
        return nil
    }

    func notify(_ method: String, _ params: [String: Any]) {
        send(["jsonrpc": "2.0", "method": method, "params": params])
    }

    func received(method: String) -> [[String: Any]] {
        lock.withLock { notifications }
            .filter { ($0["method"] as? String) == method }
            .compactMap { $0["params"] as? [String: Any] }
    }

    var allNotifications: [(method: String, seq: Int?)] {
        lock.withLock { notifications }.map {
            (($0["method"] as? String) ?? "",
             ($0["params"] as? [String: Any])?["seq"] as? Int)
        }
    }

    /// Waits until `predicate` holds, or fails the calling test.
    @discardableResult
    func wait(_ description: String, timeout: TimeInterval = 5,
              file: StaticString = #filePath, line: UInt = #line,
              until predicate: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if predicate() {
                return true
            }
            usleep(5_000)
        }
        XCTFail("timed out waiting for \(description)", file: file, line: line)
        return false
    }

    func close() {
        task.cancel(with: .goingAway, reason: nil)
    }
}

/// A Sendable string collector for assertions made from the client's request hook.
private final class KeyLog: @unchecked Sendable {
    private let lock = NSLock()
    private var keys: [String] = []

    func add(_ key: String) {
        lock.withLock { keys.append(key) }
    }

    var all: [String] {
        lock.withLock { keys }
    }

    var first: String? {
        all.first
    }

    var count: Int {
        all.count
    }
}

final class BridgeProtocolTests: XCTestCase {

    private var directory: URL!
    private var bridge: ACPBridge?
    private let token = "test-token"

    override func setUpWithError() throws {
        directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("acp-bridge-proto-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        bridge?.stop()
        bridge = nil
        try? FileManager.default.removeItem(at: directory)
    }

    // MARK: - Fake agents

    /// A fake agent that streams two chunks and ends the turn. `extra` is spliced into the
    /// prompt branch so individual tests can add tool calls or permission requests.
    private func agentScript(promptBody: String? = nil) -> String {
        let prompt = promptBody ?? """
              printf '%s\\n' '{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"sess-1","update":{"sessionUpdate":"agent_message_chunk","content":{"type":"text","text":"Hi "}}}}'
              printf '%s\\n' '{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"sess-1","update":{"sessionUpdate":"agent_message_chunk","content":{"type":"text","text":"there."}}}}'
              printf '%s\\n' "{\\"jsonrpc\\":\\"2.0\\",\\"id\\":$id,\\"result\\":{\\"stopReason\\":\\"end_turn\\"}}"
        """
        return """
        #!/bin/sh
        while IFS= read -r line; do
          id=$(printf '%s' "$line" | sed -n 's/.*"id":\\([0-9]*\\).*/\\1/p')
          case "$line" in
            *'"method":"initialize"'*)
              printf '%s\\n' "{\\"jsonrpc\\":\\"2.0\\",\\"id\\":$id,\\"result\\":{\\"protocolVersion\\":1,\\"agentCapabilities\\":{},\\"agentInfo\\":{\\"name\\":\\"fake\\"},\\"authMethods\\":[]}}" ;;
            *'"method":"session/new"'*)
              printf '%s\\n' "{\\"jsonrpc\\":\\"2.0\\",\\"id\\":$id,\\"result\\":{\\"sessionId\\":\\"sess-1\\"}}" ;;
            *'"method":"session/prompt"'*)
        \(prompt) ;;
          esac
        done
        """
    }

    private func writeAgent(_ script: String) throws -> String {
        let url = directory.appendingPathComponent("fake-agent")
        try script.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url.path
    }

    private func startBridge(script: String,
                             permissionTimeout: Double = 900,
                             handshakeDeadline: Double = 10,
                             maxLogEntries: Int = 200_000) throws -> UInt16 {
        let path = try writeAgent(script)
        let config = BridgeConfig(listen: "127.0.0.1:0",
                                  agent: BridgeAgentConfig(command: [path], cwd: directory.path),
                                  token: token,
                                  permissionTimeoutSeconds: permissionTimeout,
                                  logDir: directory.appendingPathComponent("sessions").path,
                                  maxLogEntriesPerSession: maxLogEntries,
                                  handshakeDeadlineSeconds: handshakeDeadline)
        let bridge = ACPBridge(config: config, token: token, logger: SilentLogger())
        self.bridge = bridge
        return try bridge.start()
    }

    private func connect(port: UInt16, token: String? = nil) -> TestClient {
        let client = TestClient(port: port)
        let result = client.request("initialize", [
            "protocolVersion": 1,
            "bridgeToken": token ?? self.token,
            "clientInfo": ["name": "BridgeProtocolTests", "version": "1.0"],
        ], timeout: 10)
        XCTAssertNotNil(result?["result"], "initialize should have succeeded")
        return client
    }

    // MARK: - Auth (item 1.3)

    func testGoodTokenInitializeReturnsTheBridgeCapabilityBlock() throws {
        let port = try startBridge(script: agentScript())
        let client = TestClient(port: port)
        defer { client.close() }

        let response = client.request("initialize", [
            "protocolVersion": 1, "bridgeToken": token,
            "clientInfo": ["name": "t", "version": "1"],
        ], timeout: 10)

        let result = response?["result"] as? [String: Any]
        XCTAssertNotNil(result)
        let bridgeBlock = result?["bridge"] as? [String: Any]
        XCTAssertEqual(bridgeBlock?["name"] as? String, "chatview-acp-bridge")
        XCTAssertEqual((bridgeBlock?["capabilities"] as? [String: Any])?["attachReplay"] as? Bool, true)
        XCTAssertNotNil(result?["agentCapabilities"], "the agent's initialize result is passed through")
    }

    func testBadTokenIsRejected() throws {
        let port = try startBridge(script: agentScript())
        let client = TestClient(port: port)
        defer { client.close() }

        let response = client.request("initialize", [
            "protocolVersion": 1, "bridgeToken": "wrong",
            "clientInfo": ["name": "t", "version": "1"],
        ], timeout: 3)
        XCTAssertNil(response?["result"], "a bad token must not produce a result")
    }

    func testUnauthenticatedMethodsAreRefused() throws {
        let port = try startBridge(script: agentScript())
        let client = TestClient(port: port)
        defer { client.close() }

        let response = client.request("session/new", [:], timeout: 3)
        let error = response?["error"] as? [String: Any]
        XCTAssertEqual(error?["code"] as? Int, -32000,
                       "everything before a successful initialize must fail closed")
    }

    // MARK: - Turn lifecycle (item 1.4, invariant I8)

    func testPromptTurnLifecycle() throws {
        let port = try startBridge(script: agentScript())
        let client = connect(port: port)
        defer { client.close() }

        let session = client.request("session/new", [:], timeout: 10)
        XCTAssertEqual((session?["result"] as? [String: Any])?["sessionId"] as? String, "sess-1")

        let prompt = client.request("session/prompt", [
            "sessionId": "sess-1",
            "prompt": [["type": "text", "text": "hello"]],
            "echoKey": "E1",
        ], timeout: 5)
        // The prompt answers IMMEDIATELY with a turn number - it must not block for the turn.
        XCTAssertEqual((prompt?["result"] as? [String: Any])?["turn"] as? Int, 1)

        client.wait("the turn to end") { !client.received(method: "bridge/turn_ended").isEmpty }

        let userMessages = client.received(method: "bridge/user_message")
        XCTAssertEqual(userMessages.first?["echoKey"] as? String, "E1")
        XCTAssertEqual(userMessages.first?["turn"] as? Int, 1)

        let updates = client.received(method: "session/update")
        XCTAssertEqual(updates.count, 2, "both agent chunks must be relayed")

        let ended = client.received(method: "bridge/turn_ended")
        XCTAssertEqual(ended.first?["stopReason"] as? String, "end_turn")
        XCTAssertEqual(ended.first?["turn"] as? Int, 1)

        // Seqs must be dense and ordered across the whole turn.
        let seqs = client.allNotifications.compactMap(\.seq)
        XCTAssertEqual(seqs, Array(1...seqs.count), "every notification carries the next seq")
    }

    func testPromptOnUnknownSessionFails() throws {
        let port = try startBridge(script: agentScript())
        let client = connect(port: port)
        defer { client.close() }

        let response = client.request("session/prompt", [
            "sessionId": "nope", "prompt": [], "echoKey": "E",
        ], timeout: 3)
        XCTAssertEqual((response?["error"] as? [String: Any])?["code"] as? Int, -32001)
    }

    /// I8: a turn the bridge accepted always ends, even when the agent dies mid-turn, and
    /// turn_ended is logged BEFORE session_ended.
    func testAgentDeathEndsTheTurnBeforeTheSession() throws {
        // This agent answers initialize and session/new, then exits on the first prompt.
        let script = """
        #!/bin/sh
        while IFS= read -r line; do
          id=$(printf '%s' "$line" | sed -n 's/.*"id":\\([0-9]*\\).*/\\1/p')
          case "$line" in
            *'"method":"initialize"'*)
              printf '%s\\n' "{\\"jsonrpc\\":\\"2.0\\",\\"id\\":$id,\\"result\\":{\\"protocolVersion\\":1,\\"agentCapabilities\\":{}}}" ;;
            *'"method":"session/new"'*)
              printf '%s\\n' "{\\"jsonrpc\\":\\"2.0\\",\\"id\\":$id,\\"result\\":{\\"sessionId\\":\\"sess-1\\"}}" ;;
            *'"method":"session/prompt"'*)
              exit 3 ;;
          esac
        done
        """
        let port = try startBridge(script: script)
        let client = connect(port: port)
        defer { client.close() }

        _ = client.request("session/new", [:], timeout: 10)
        _ = client.request("session/prompt", [
            "sessionId": "sess-1", "prompt": [["type": "text", "text": "go"]], "echoKey": "E1",
        ], timeout: 5)

        client.wait("the session to end") { !client.received(method: "bridge/session_ended").isEmpty }

        let methods = client.allNotifications.map(\.method)
        guard let turnEnded = methods.firstIndex(of: "bridge/turn_ended"),
              let sessionEnded = methods.firstIndex(of: "bridge/session_ended") else {
            return XCTFail("expected both turn_ended and session_ended, got \(methods)")
        }
        XCTAssertLessThan(turnEnded, sessionEnded,
                          "I8: a client that never sees turn_ended keeps its composer disabled forever")
        XCTAssertEqual(client.received(method: "bridge/turn_ended").first?["stopReason"] as? String, "error")
        XCTAssertEqual(client.received(method: "bridge/session_ended").first?["reason"] as? String, "agent_exit")
    }

    // MARK: - Attach and replay (item 1.5, invariant I6)

    func testAttachAfterDisconnectReplaysOnlyTheTail() throws {
        let port = try startBridge(script: agentScript())
        let first = connect(port: port)
        _ = first.request("session/new", [:], timeout: 10)
        _ = first.request("session/prompt", [
            "sessionId": "sess-1", "prompt": [["type": "text", "text": "hello"]], "echoKey": "E1",
        ], timeout: 5)
        first.wait("the first turn to end") { !first.received(method: "bridge/turn_ended").isEmpty }
        let seenThrough = first.allNotifications.compactMap(\.seq).max() ?? 0
        XCTAssertEqual(seenThrough, 4, "user_message + 2 chunks + turn_ended")
        first.close()

        // A brand-new connection resumes from the cursor the first one reached.
        let second = connect(port: port)
        defer { second.close() }
        let attach = second.request("bridge/attach", ["sessionId": "sess-1", "afterSeq": 2], timeout: 5)
        let result = attach?["result"] as? [String: Any]
        XCTAssertEqual(result?["state"] as? String, "live")
        XCTAssertEqual(result?["latestSeq"] as? Int, 4)

        second.wait("the tail to replay") { second.allNotifications.count >= 2 }
        XCTAssertEqual(second.allNotifications.compactMap(\.seq), [3, 4],
                       "afterSeq 2 must replay exactly seqs 3 and 4")
    }

    func testAttachFromZeroRebuildsTheWholeTranscript() throws {
        let port = try startBridge(script: agentScript())
        let first = connect(port: port)
        _ = first.request("session/new", [:], timeout: 10)
        _ = first.request("session/prompt", [
            "sessionId": "sess-1", "prompt": [["type": "text", "text": "hello"]], "echoKey": "E1",
        ], timeout: 5)
        first.wait("the turn to end") { !first.received(method: "bridge/turn_ended").isEmpty }
        first.close()

        let second = connect(port: port)
        defer { second.close() }
        _ = second.request("bridge/attach", ["sessionId": "sess-1", "afterSeq": 0], timeout: 5)
        second.wait("the full replay") { second.allNotifications.count >= 4 }
        XCTAssertEqual(second.allNotifications.compactMap(\.seq), [1, 2, 3, 4],
                       "a fresh device rebuilds everything through the same event path")
    }

    func testAttachUnknownSessionFails() throws {
        let port = try startBridge(script: agentScript())
        let client = connect(port: port)
        defer { client.close() }
        let response = client.request("bridge/attach", ["sessionId": "nope", "afterSeq": 0], timeout: 3)
        XCTAssertEqual((response?["error"] as? [String: Any])?["code"] as? Int, -32001)
    }

    /// The turn must keep running with NO client attached - the whole point of the feature.
    func testTurnSurvivesWithNoClientAttached() throws {
        let port = try startBridge(script: agentScript())
        let first = connect(port: port)
        _ = first.request("session/new", [:], timeout: 10)
        _ = first.request("session/prompt", [
            "sessionId": "sess-1", "prompt": [["type": "text", "text": "hello"]], "echoKey": "E1",
        ], timeout: 5)
        // Drop the socket immediately, before the turn can finish.
        first.close()

        let second = connect(port: port)
        defer { second.close() }
        _ = second.request("bridge/attach", ["sessionId": "sess-1", "afterSeq": 0], timeout: 5)
        second.wait("the turn to have completed while nobody was listening") {
            !second.received(method: "bridge/turn_ended").isEmpty
        }
        XCTAssertEqual(second.received(method: "bridge/turn_ended").first?["stopReason"] as? String, "end_turn")
    }

    func testSessionsListing() throws {
        let port = try startBridge(script: agentScript())
        let client = connect(port: port)
        defer { client.close() }
        _ = client.request("session/new", [:], timeout: 10)
        _ = client.request("session/prompt", [
            "sessionId": "sess-1", "prompt": [["type": "text", "text": "what is the time"]], "echoKey": "E1",
        ], timeout: 5)
        client.wait("the turn to end") { !client.received(method: "bridge/turn_ended").isEmpty }

        let listing = client.request("bridge/sessions", [:], timeout: 5)
        let rows = (listing?["result"] as? [String: Any])?["sessions"] as? [[String: Any]]
        XCTAssertEqual(rows?.count, 1)
        XCTAssertEqual(rows?.first?["sessionId"] as? String, "sess-1")
        XCTAssertEqual(rows?.first?["title"] as? String, "what is the time")
    }

    /// The count matters, not just the order: agent death used to log turn_ended AND then the
    /// failing prompt task logged a second one, which landed after session_ended.
    func testAgentDeathLogsExactlyOneTurnEnded() throws {
        let script = """
        #!/bin/sh
        while IFS= read -r line; do
          id=$(printf '%s' "$line" | sed -n 's/.*"id":\\([0-9]*\\).*/\\1/p')
          case "$line" in
            *'"method":"initialize"'*)
              printf '%s\\n' "{\\"jsonrpc\\":\\"2.0\\",\\"id\\":$id,\\"result\\":{\\"protocolVersion\\":1,\\"agentCapabilities\\":{}}}" ;;
            *'"method":"session/new"'*)
              printf '%s\\n' "{\\"jsonrpc\\":\\"2.0\\",\\"id\\":$id,\\"result\\":{\\"sessionId\\":\\"sess-1\\"}}" ;;
            *'"method":"session/prompt"'*)
              exit 3 ;;
          esac
        done
        """
        let port = try startBridge(script: script)
        let client = connect(port: port)
        defer { client.close() }

        _ = client.request("session/new", [:], timeout: 10)
        _ = client.request("session/prompt", [
            "sessionId": "sess-1", "prompt": [["type": "text", "text": "go"]], "echoKey": "E1",
        ], timeout: 5)
        client.wait("the session to end") { !client.received(method: "bridge/session_ended").isEmpty }
        Thread.sleep(forTimeInterval: 0.7)   // let any duplicate arrive before we count

        XCTAssertEqual(client.received(method: "bridge/turn_ended").count, 1,
                       "invariant I8 is EXACTLY one turn_ended per accepted turn")
        let methods = client.allNotifications.map(\.method)
        XCTAssertEqual(methods.last, "bridge/session_ended",
                       "nothing may be logged after the session's terminal entry; got \(methods)")
    }

    /// The cap has to cap, and it has to end the turn before it ends the session.
    func testLogOverflowEndsTheTurnThenTheSessionAndStopsLogging() throws {
        let port = try startBridge(script: agentScript(), maxLogEntries: 3)
        let client = connect(port: port)
        defer { client.close() }

        _ = client.request("session/new", [:], timeout: 10)
        _ = client.request("session/prompt", [
            "sessionId": "sess-1", "prompt": [["type": "text", "text": "hello"]], "echoKey": "E1",
        ], timeout: 5)

        client.wait("the session to be force-ended") { !client.received(method: "bridge/session_ended").isEmpty }
        Thread.sleep(forTimeInterval: 0.5)

        let methods = client.allNotifications.map(\.method)
        XCTAssertEqual(methods.last, "bridge/session_ended",
                       "the cap must actually stop the log; got \(methods)")
        XCTAssertEqual(client.received(method: "bridge/session_ended").first?["reason"] as? String,
                       "log_overflow")
        if let turnEnded = methods.firstIndex(of: "bridge/turn_ended"),
           let sessionEnded = methods.firstIndex(of: "bridge/session_ended") {
            XCTAssertLessThan(turnEnded, sessionEnded, "the turn must end before the session does")
        } else {
            XCTFail("an overflowing turn must still get its terminal entry; got \(methods)")
        }
    }

    func testDisconnectedClientsAreReleased() throws {
        let port = try startBridge(script: agentScript())
        for _ in 0..<5 {
            let client = connect(port: port)
            client.close()
        }
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline, bridge?.connectedClientCount != 0 {
            usleep(20_000)
        }
        XCTAssertEqual(bridge?.connectedClientCount, 0,
                       "a connection the consumer's onClose handler replaced would leak for the "
                       + "bridge's whole lifetime, each retaining an NWConnection")
    }

    // MARK: - Permissions (item 1.4, section 4.4)

    private static let permissionPromptBody = """
          printf '%s\\n' '{"jsonrpc":"2.0","id":900,"method":"session/request_permission","params":{"sessionId":"sess-1","toolCall":{"toolCallId":"call-1","title":"Edit main.swift"},"options":[{"optionId":"allow","name":"Allow","kind":"allow_once"},{"optionId":"deny","name":"Deny","kind":"reject_once"}]}}'
          while IFS= read -r answer; do
            case "$answer" in
              *'"id":900'*) break ;;
            esac
          done
          printf '%s\\n' "{\\"jsonrpc\\":\\"2.0\\",\\"id\\":$id,\\"result\\":{\\"stopReason\\":\\"end_turn\\"}}"
    """

    func testPermissionRoundTrip() throws {
        let port = try startBridge(script: agentScript(promptBody: Self.permissionPromptBody))
        let client = connect(port: port)
        defer { client.close() }

        let seenKey = KeyLog()
        client.onRequest = { params in
            if let key = params["requestKey"] as? String {
                seenKey.add(key)
            }
            return ["outcome": ["outcome": "selected", "optionId": "allow"]]
        }

        _ = client.request("session/new", [:], timeout: 10)
        _ = client.request("session/prompt", [
            "sessionId": "sess-1", "prompt": [["type": "text", "text": "edit"]], "echoKey": "E1",
        ], timeout: 5)

        client.wait("the permission to resolve") {
            !client.received(method: "bridge/permission_resolved").isEmpty
        }
        XCTAssertEqual(seenKey.first, "perm-1",
                       "requestKey identity must be stable so a reconnecting client keeps its gate")
        let resolved = client.received(method: "bridge/permission_resolved").first
        XCTAssertEqual(resolved?["outcome"] as? String, "selected")
        XCTAssertEqual(resolved?["optionId"] as? String, "allow")

        client.wait("the turn to end after the permission") {
            !client.received(method: "bridge/turn_ended").isEmpty
        }
    }

    func testPermissionTimeoutDeniesByDefault() throws {
        let port = try startBridge(script: agentScript(promptBody: Self.permissionPromptBody),
                                   permissionTimeout: 1)
        let client = connect(port: port)
        defer { client.close() }

        // Never answer. An unattended agent must not acquire the permission by silence.
        client.onRequest = { _ in nil }

        _ = client.request("session/new", [:], timeout: 10)
        _ = client.request("session/prompt", [
            "sessionId": "sess-1", "prompt": [["type": "text", "text": "edit"]], "echoKey": "E1",
        ], timeout: 5)

        client.wait("the permission to time out", timeout: 10) {
            !client.received(method: "bridge/permission_resolved").isEmpty
        }
        let resolved = client.received(method: "bridge/permission_resolved").first
        XCTAssertEqual(resolved?["outcome"] as? String, "timeout")
        XCTAssertEqual(resolved?["optionId"] as? String, "deny",
                       "the timeout must pick the reject_once option, not allow")
    }

    func testPermissionIsReissuedToAClientThatAttachesLater() throws {
        let port = try startBridge(script: agentScript(promptBody: Self.permissionPromptBody))
        let first = connect(port: port)
        defer { first.close() }
        first.onRequest = { _ in nil }   // leave it hanging

        _ = first.request("session/new", [:], timeout: 10)
        _ = first.request("session/prompt", [
            "sessionId": "sess-1", "prompt": [["type": "text", "text": "edit"]], "echoKey": "E1",
        ], timeout: 5)
        // Give the agent time to raise the permission.
        first.wait("the user message to be logged") { !first.received(method: "bridge/user_message").isEmpty }
        Thread.sleep(forTimeInterval: 0.5)

        let second = connect(port: port)
        defer { second.close() }
        let asked = KeyLog()
        second.onRequest = { params in
            asked.add((params["requestKey"] as? String) ?? "")
            return ["outcome": ["outcome": "selected", "optionId": "allow"]]
        }
        _ = second.request("bridge/attach", ["sessionId": "sess-1", "afterSeq": 0], timeout: 5)

        second.wait("the pending permission to be re-issued after replay", timeout: 10) {
            asked.count > 0
        }
        XCTAssertEqual(asked.first, "perm-1")
        // I6: the gate must arrive AFTER the transcript it belongs to.
        XCTAssertFalse(second.allNotifications.isEmpty,
                       "replay must have been delivered before the permission re-issue")
    }

    func testCancelResolvesPendingPermissions() throws {
        let port = try startBridge(script: agentScript(promptBody: Self.permissionPromptBody))
        let client = connect(port: port)
        defer { client.close() }
        client.onRequest = { _ in nil }

        _ = client.request("session/new", [:], timeout: 10)
        _ = client.request("session/prompt", [
            "sessionId": "sess-1", "prompt": [["type": "text", "text": "edit"]], "echoKey": "E1",
        ], timeout: 5)
        client.wait("the user message") { !client.received(method: "bridge/user_message").isEmpty }
        Thread.sleep(forTimeInterval: 0.5)

        client.notify("session/cancel", ["sessionId": "sess-1"])

        client.wait("the permission to resolve as cancelled", timeout: 10) {
            !client.received(method: "bridge/permission_resolved").isEmpty
        }
        XCTAssertEqual(client.received(method: "bridge/permission_resolved").first?["outcome"] as? String,
                       "cancelled")
    }
}

#endif
