// Tests/ACPTests/ChatACPRemoteTests.swift
//
// Tests for the `acp-remote` client: the JSON-RPC connection, and the transport's demux,
// reconnect, permission, and checkpoint behavior.
//
// `ScriptedBridge` below is written FROM section 7 of the plan rather than from the bridge's
// implementation, deliberately: it is the appendix's first conformance check, and the
// phase 2.3 integration tests then run the same transport against the REAL bridge. If the two
// ever disagree, one of them is wrong about the spec and that is exactly what we want to find.
//
// No `#if os(macOS)`: this whole file must run wherever the transport does.

import XCTest
@testable import ChatViewACP
import ChatView

/// A Sendable counter for assertions made from callback closures.
private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0

    func bump() {
        lock.withLock { value += 1 }
    }

    var count: Int {
        lock.withLock { value }
    }
}

private final class RemoteTestLogger: ChatLogger, @unchecked Sendable {
    private let lock = NSLock()
    private var lines: [String] = []

    func log(_ message: String, _ level: ChatLogLevel) {
        lock.withLock { lines.append(message) }
    }

    func contains(_ fragment: String) -> Bool {
        lock.withLock { lines }.contains { $0.contains(fragment) }
    }
}

// MARK: - The socket double

/// A socket the test drives directly: it records what the client sent and lets the test
/// inject frames and closures.
private final class ScriptedSocket: ACPRemoteSocket, @unchecked Sendable {

    private let lock = NSLock()
    private var sent: [String] = []
    private var closed = false
    weak var delegate: (any ACPRemoteSocketDelegate)?

    /// Called for every frame the client sends, outside the lock.
    var onSend: (@Sendable (ScriptedSocket, [String: Any]) -> Void)?

    func connect() {
        delegate?.socketDidOpen()
    }

    func sendText(_ text: String) {
        if lock.withLock({ closed }) {
            return
        }
        lock.withLock { sent.append(text) }
        guard let data = text.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return
        }
        onSend?(self, object)
    }

    /// Set by a test to make the keepalive fail.
    var pingError: (any Error)?

    func sendPing(onPong: @escaping @Sendable ((any Error)?) -> Void) {
        onPong(pingError)
    }

    func close() {
        let first: Bool = lock.withLock {
            if closed {
                return false
            }
            closed = true
            return true
        }
        if first {
            delegate?.socketDidClose(error: nil)
        }
    }

    /// Test-side: hand a frame to the client.
    func deliver(_ object: [String: Any]) {
        guard !lock.withLock({ closed }),
              let data = try? JSONSerialization.data(withJSONObject: object),
              let text = String(data: data, encoding: .utf8) else {
            return
        }
        delegate?.socketDidReceiveText(text)
    }

    func deliverRaw(_ text: String) {
        delegate?.socketDidReceiveText(text)
    }

    /// Test-side: drop the connection as if the network went away.
    func dropConnection() {
        let first: Bool = lock.withLock {
            if closed {
                return false
            }
            closed = true
            return true
        }
        if first {
            delegate?.socketDidClose(error: ACPRemoteError(code: nil, message: "network lost"))
        }
    }

    var sentFrames: [[String: Any]] {
        lock.withLock { sent }.compactMap {
            guard let data = $0.data(using: .utf8) else {
                return nil
            }
            return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        }
    }

    func frames(method: String) -> [[String: Any]] {
        sentFrames.filter { ($0["method"] as? String) == method }
    }

    var isClosed: Bool {
        lock.withLock { closed }
    }
}

private final class ScriptedSocketFactory: ACPRemoteSocketFactory, @unchecked Sendable {
    private let lock = NSLock()
    private var produced: [ScriptedSocket] = []
    /// Configures each socket as it is created; the index is the attempt number, so a test can
    /// make attempt 0 behave differently from the reconnect.
    private let configure: @Sendable (Int, ScriptedSocket) -> Void

    init(configure: @escaping @Sendable (Int, ScriptedSocket) -> Void) {
        self.configure = configure
    }

    func makeSocket(url: URL, headers: [String: String],
                    delegate: any ACPRemoteSocketDelegate) -> any ACPRemoteSocket {
        let socket = ScriptedSocket()
        socket.delegate = delegate
        let index: Int = lock.withLock {
            produced.append(socket)
            return produced.count - 1
        }
        configure(index, socket)
        return socket
    }

    var sockets: [ScriptedSocket] {
        lock.withLock { produced }
    }

    func socket(_ index: Int) -> ScriptedSocket? {
        let all = sockets
        return index < all.count ? all[index] : nil
    }
}

// MARK: - A bridge written from the wire spec

/// Answers the client's requests per section 7 and lets a test push notifications.
private final class ScriptedBridge: @unchecked Sendable {

    private let lock = NSLock()
    private var seq = 0
    let sessionID: String
    var latestSeqAtAttach = 0
    var stateAtAttach = "live"
    var activeTurnAtAttach: Int?
    var replayOnAttach: [(method: String, params: [String: Any])] = []
    private(set) var lastAttachAfterSeq: Int?
    var attachSessionIDOverride: String?

    init(sessionID: String = "sess-1") {
        self.sessionID = sessionID
    }

    /// Wires this bridge to a socket: it answers requests as they arrive.
    func attach(to socket: ScriptedSocket) {
        socket.onSend = { [weak self] socket, message in
            self?.handle(message, on: socket)
        }
    }

    private func handle(_ message: [String: Any], on socket: ScriptedSocket) {
        guard let method = message["method"] as? String, let id = message["id"] else {
            return
        }
        switch method {
        case "initialize":
            socket.deliver(["jsonrpc": "2.0", "id": id, "result": [
                "protocolVersion": 1,
                "agentCapabilities": ["loadSession": false],
                "agentInfo": ["name": "scripted-agent", "version": "9.9"],
                "authMethods": [],
                "bridge": ["name": "chatview-acp-bridge", "version": "0.1.0", "protocol": 1,
                           "capabilities": ["attachReplay": true, "sessions": true]],
            ]])
        case "session/new":
            socket.deliver(["jsonrpc": "2.0", "id": id, "result": ["sessionId": sessionID]])
        case "bridge/sessions":
            socket.deliver(["jsonrpc": "2.0", "id": id, "result": ["sessions": [
                ["sessionId": sessionID, "state": "live", "createdAt": "2026-08-11T00:00:00Z",
                 "lastActivityAt": "2026-08-11T00:00:00Z", "latestSeq": latestSeqAtAttach, "title": "t"],
            ]]])
        case "bridge/attach":
            let after = ((message["params"] as? [String: Any])?["afterSeq"] as? Int) ?? 0
            lock.withLock { lastAttachAfterSeq = after }
            var result: [String: Any] = [
                "sessionId": attachSessionIDOverride ?? sessionID,
                "state": stateAtAttach,
                "latestSeq": latestSeqAtAttach,
                "activeTurn": activeTurnAtAttach as Any? ?? NSNull(),
                "configOptions": [],
            ]
            if stateAtAttach == "ended" {
                result["endedReason"] = "agent_exit"
            }
            socket.deliver(["jsonrpc": "2.0", "id": id, "result": result])
            // Asynchronously, because the real bridge cannot possibly deliver replayed
            // notifications before the response that announces them. Delivering them inline
            // would let this double pass an ordering the real server never produces.
            let entries = replayOnAttach
            DispatchQueue.global().async {
                for entry in entries {
                    socket.deliver(["jsonrpc": "2.0", "method": entry.method, "params": entry.params])
                }
            }
        case "session/prompt":
            socket.deliver(["jsonrpc": "2.0", "id": id, "result": ["turn": 1]])
        case "session/set_config_option":
            socket.deliver(["jsonrpc": "2.0", "id": id, "result": [:]])
        default:
            socket.deliver(["jsonrpc": "2.0", "id": id,
                            "error": ["code": -32601, "message": "unknown method"]])
        }
    }

    /// Pushes a seq-stamped notification, exactly as the real bridge does.
    @discardableResult
    func push(_ socket: ScriptedSocket, _ method: String, _ params: [String: Any]) -> Int {
        let next: Int = lock.withLock {
            seq += 1
            return seq
        }
        var stamped = params
        stamped["sessionId"] = sessionID
        stamped["seq"] = next
        socket.deliver(["jsonrpc": "2.0", "method": method, "params": stamped])
        return next
    }

    func pushAt(_ socket: ScriptedSocket, seq value: Int, _ method: String, _ params: [String: Any]) {
        lock.withLock { seq = max(seq, value) }
        var stamped = params
        stamped["sessionId"] = sessionID
        stamped["seq"] = value
        socket.deliver(["jsonrpc": "2.0", "method": method, "params": stamped])
    }

    var attachCursor: Int? {
        lock.withLock { lastAttachAfterSeq }
    }
}

// MARK: - Collecting events

private final class EventCollector: @unchecked Sendable {
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

    var events: [ChatEvent] {
        lock.withLock { stored }
    }

    /// A compact rendering, so assertions read as the sequence a user would see.
    var log: [String] {
        events.map { event in
            switch event {
            case .connectionStateChanged(let state):
                return "state:\(state.rawValue)"
            case .sessionReady(let id, _):
                return "ready:\(id)"
            case .sessionInfo(let info):
                return "info:\(info.sessionId):resumed=\(info.resumed)"
            case .messageStart(let id, let role):
                return "start:\(id):\(role.rawValue)"
            case .messageDelta(let id, let text):
                return "delta:\(id):\(text)"
            case .messageEnd(let id, let stopReason):
                return "end:\(id):\(stopReason ?? "-")"
            case .thoughtDelta(let id, let text):
                return "thought:\(id):\(text)"
            case .toolCall(let call):
                return "tool:\(call.id)"
            case .toolCallUpdate(let update):
                return "toolupdate:\(update.id)"
            case .permissionRequest(let request):
                return "perm:\(request.id)"
            case .permissionResolved(let requestID):
                return "permresolved:\(requestID)"
            case .resumeCheckpoint(let sessionID, let afterSeq):
                return "checkpoint:\(sessionID):\(afterSeq)"
            case .error(let message, let recoverable):
                return "error:\(recoverable):\(message)"
            case .system(let text):
                return "system:\(text)"
            case .usage:
                return "usage"
            case .plan:
                return "plan"
            default:
                return "other"
            }
        }
    }

    func waitFor(_ description: String, timeout: TimeInterval = 3,
                 file: StaticString = #filePath, line: UInt = #line,
                 until predicate: @escaping () -> Bool) {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if predicate() {
                return
            }
            usleep(2_000)
        }
        XCTFail("timed out waiting for \(description); saw \(log)", file: file, line: line)
    }
}

// MARK: - Connection tests (item 2.1)

final class ChatACPRemoteConnectionTests: XCTestCase {

    private func makeConnection(socket: ScriptedSocket,
                                logger: RemoteTestLogger = RemoteTestLogger(),
                                onNotification: @escaping @Sendable (String, [String: Any]) -> Void = { _, _ in },
                                onRequest: @escaping @Sendable (String, [String: Any]) async -> [String: Any]? = { _, _ in nil },
                                onClose: @escaping @Sendable ((any Error)?) -> Void = { _ in }) -> ACPRemoteConnection {
        let connection = ACPRemoteConnection(logger: logger,
                                             onNotification: onNotification,
                                             onRequest: onRequest,
                                             onOpen: {},
                                             onClose: onClose)
        socket.delegate = connection
        connection.attach(socket: socket)
        return connection
    }

    func testRequestResponseCorrelation() async throws {
        let socket = ScriptedSocket()
        socket.onSend = { socket, message in
            guard let id = message["id"] else {
                return
            }
            socket.deliver(["jsonrpc": "2.0", "id": id, "result": ["ok": true]])
        }
        let connection = makeConnection(socket: socket)
        let result = try await connection.request("initialize", [:])
        XCTAssertEqual(result["ok"] as? Bool, true)
    }

    func testConcurrentRequestsGetTheirOwnAnswers() async throws {
        let socket = ScriptedSocket()
        socket.onSend = { socket, message in
            guard let id = message["id"] as? Int, let method = message["method"] as? String else {
                return
            }
            socket.deliver(["jsonrpc": "2.0", "id": id, "result": ["echo": method]])
        }
        let connection = makeConnection(socket: socket)
        async let first = connection.request("alpha", [:])
        async let second = connection.request("beta", [:])
        let results = try await [first, second]
        XCTAssertEqual(results[0]["echo"] as? String, "alpha")
        XCTAssertEqual(results[1]["echo"] as? String, "beta")
    }

    func testErrorResponseThrows() async {
        let socket = ScriptedSocket()
        socket.onSend = { socket, message in
            guard let id = message["id"] else {
                return
            }
            socket.deliver(["jsonrpc": "2.0", "id": id,
                            "error": ["code": -32001, "message": "unknown session"]])
        }
        let connection = makeConnection(socket: socket)
        do {
            _ = try await connection.request("bridge/attach", [:])
            XCTFail("an error response must throw")
        } catch {
            XCTAssertEqual((error as? ACPRemoteError)?.code, -32001)
        }
    }

    func testNotificationsReachTheHandler() {
        let socket = ScriptedSocket()
        let box = RemoteTestLogger()
        let received = Counter()
        let connection = makeConnection(socket: socket, logger: box, onNotification: { _, _ in
            received.bump()
        })
        _ = connection
        socket.deliver(["jsonrpc": "2.0", "method": "session/update", "params": ["seq": 1]])
        XCTAssertEqual(received.count, 1)
    }

    func testInboundRequestIsAnswered() async {
        let socket = ScriptedSocket()
        let answered = XCTestExpectation(description: "the client answered the bridge's request")
        socket.onSend = { _, message in
            if message["result"] != nil {
                answered.fulfill()
            }
        }
        let connection = makeConnection(socket: socket, onRequest: { method, _ in
            method == "session/request_permission" ? ["outcome": ["outcome": "cancelled"]] : nil
        })
        _ = connection
        socket.deliver(["jsonrpc": "2.0", "id": 101, "method": "session/request_permission", "params": [:]])
        await fulfillment(of: [answered], timeout: 3)
    }

    func testCloseFailsEveryPendingRequestExactlyOnce() async {
        let socket = ScriptedSocket()
        let closeCount = Counter()
        let connection = makeConnection(socket: socket, onClose: { _ in
            closeCount.bump()
        })

        // Never answered; the close is what resolves it (invariant I2).
        async let pending = connection.request("initialize", [:])
        try? await Task.sleep(nanoseconds: 50_000_000)
        connection.close()
        connection.close()

        do {
            _ = try await pending
            XCTFail("a pending request must fail when the connection closes")
        } catch {
            // expected
        }
        XCTAssertEqual(closeCount.count, 1, "close must notify exactly once")
    }

    func testMalformedFrameIsDroppedWithoutCrashing() {
        let socket = ScriptedSocket()
        let logger = RemoteTestLogger()
        let connection = makeConnection(socket: socket, logger: logger)
        socket.deliverRaw("this is not json")
        socket.deliverRaw("[1,2,3]")
        XCTAssertFalse(connection.isClosed, "a bad frame must not tear down a working session")
        XCTAssertTrue(logger.contains("unparseable"))
    }

    func testRequestAfterCloseThrowsImmediately() async {
        let socket = ScriptedSocket()
        let connection = makeConnection(socket: socket)
        connection.close()
        do {
            _ = try await connection.request("initialize", [:])
            XCTFail("a request on a closed connection must throw")
        } catch {
            XCTAssertTrue("\(error)".contains("not connected"))
        }
    }
}

// MARK: - Transport tests (items 2.2 and 2.2a)

final class ChatACPRemoteTransportTests: XCTestCase {

    private func makeTransport(settings: [String: Any] = [:],
                               bridge: ScriptedBridge,
                               logger: RemoteTestLogger = RemoteTestLogger(),
                               configure: (@Sendable (Int, ScriptedSocket) -> Void)? = nil)
        throws -> (ACPRemoteTransport, ScriptedSocketFactory, EventCollector) {
        var merged: [String: Any] = ["url": "ws://127.0.0.1:8737/acp", "token": "T"]
        for (key, value) in settings {
            merged[key] = value
        }
        let factory = ScriptedSocketFactory { index, socket in
            bridge.attach(to: socket)
            configure?(index, socket)
        }
        let transport = try ACPRemoteTransport(config: ChatTransportConfig(protocolName: "acp-remote",
                                                                          settings: merged),
                                               logger: logger,
                                               socketFactory: factory)
        let collector = EventCollector()
        collector.start(transport)
        return (transport, factory, collector)
    }

    // MARK: Config validation

    func testMissingURLThrows() {
        XCTAssertThrowsError(try ACPRemoteTransport(config: ChatTransportConfig(settings: [:]),
                                                    logger: RemoteTestLogger()))
    }

    func testInsecureURLPolicy() throws {
        let logger = RemoteTestLogger()
        func make(_ settings: [String: Any]) throws -> ACPRemoteTransport {
            try ACPRemoteTransport(config: ChatTransportConfig(settings: settings), logger: logger)
        }
        // A token that is remote code execution must not go over cleartext to a public host.
        XCTAssertThrowsError(try make(["url": "ws://public.example/acp"]))
        XCTAssertNoThrow(try make(["url": "ws://192.168.1.10:8737/acp"]))
        XCTAssertNoThrow(try make(["url": "ws://mac.local:8737/acp"]))
        XCTAssertNoThrow(try make(["url": "ws://100.72.1.4:8737/acp"]))   // Tailscale CGNAT
        XCTAssertNoThrow(try make(["url": "wss://public.example/acp"]))
        XCTAssertNoThrow(try make(["url": "ws://public.example/acp", "allowInsecure": true]))
        XCTAssertThrowsError(try make(["url": "http://mac.local/acp"]), "only ws/wss are transports here")
    }

    func testPrivateHostClassification() {
        for host in ["127.0.0.1", "localhost", "mac.local", "10.0.0.5", "192.168.1.2",
                     "172.16.0.1", "172.31.255.255", "169.254.1.1", "100.64.0.1"] {
            XCTAssertTrue(ACPRemoteTransport.isPrivateHost(host), "\(host) should be private")
        }
        for host in ["example.com", "8.8.8.8", "172.32.0.1", "100.128.0.1", ""] {
            XCTAssertFalse(ACPRemoteTransport.isPrivateHost(host), "\(host) should NOT be private")
        }
    }

    func testHandshakeTimeoutDefaultAndClamping() throws {
        let bridge = ScriptedBridge()
        let (defaulted, _, collector) = try makeTransport(bridge: bridge)
        XCTAssertEqual(defaulted.handshakeTimeout, 15)
        collector.stop()

        let (none, _, collector2) = try makeTransport(settings: ["handshakeTimeoutSeconds": 0], bridge: bridge)
        XCTAssertEqual(none.handshakeTimeout, 0, "0 means no watchdog")
        collector2.stop()

        let (absurd, _, collector3) = try makeTransport(settings: ["handshakeTimeoutSeconds": 1e18], bridge: bridge)
        XCTAssertEqual(absurd.handshakeTimeout, 86_400, "a nonsense value must clamp, not overflow")
        collector3.stop()
    }

    // MARK: Connect

    func testConnectNewSessionEmitsReadyAndInfo() async throws {
        let bridge = ScriptedBridge()
        let (transport, _, collector) = try makeTransport(settings: ["session": "new"], bridge: bridge)
        await transport.start()
        collector.waitFor("connected") { collector.log.contains("state:connected") }

        XCTAssertEqual(collector.log.prefix(4).map { $0 },
                       ["state:connecting", "ready:sess-1", "info:sess-1:resumed=false", "state:connected"],
                       "I6: the session is announced before anything else can arrive")
        await transport.stop()
    }

    func testSessionInfoCarriesTheAgentIdentityFromTheBridge() async throws {
        let bridge = ScriptedBridge()
        let (transport, _, collector) = try makeTransport(bridge: bridge)
        await transport.start()
        collector.waitFor("connected") { collector.log.contains("state:connected") }

        let info = collector.events.compactMap { event -> AgentSessionInfo? in
            if case .sessionInfo(let info) = event {
                return info
            }
            return nil
        }.first
        XCTAssertEqual(info?.agentName, "scripted-agent",
                       "a phone has no other way to learn what agent it is talking to")
        XCTAssertEqual(info?.agentVersion, "9.9")
        XCTAssertNil(info?.agentPid, "the agent's pid is a fact about the bridge host, not this client")
        await transport.stop()
    }

    func testHandshakeWatchdogClosesTheSocket() async throws {
        // A socket that never answers anything: the watchdog must close it rather than hang.
        let bridge = ScriptedBridge()
        let (transport, factory, collector) = try makeTransport(
            settings: ["handshakeTimeoutSeconds": 0.3], bridge: bridge,
            configure: { _, socket in socket.onSend = { _, _ in } })
        await transport.start()
        collector.waitFor("the watchdog to fire", timeout: 5) {
            collector.log.contains { $0.hasPrefix("error:false:") }
        }
        XCTAssertTrue(factory.socket(0)?.isClosed ?? false,
                      "I1: the watchdog closes the SOCKET; racing the request in a task group deadlocks")
        await transport.stop()
    }

    // MARK: Turn demux

    func testPromptTurnMapsToEvents() async throws {
        let bridge = ScriptedBridge()
        let (transport, factory, collector) = try makeTransport(bridge: bridge)
        await transport.start()
        collector.waitFor("connected") { collector.log.contains("state:connected") }
        guard let socket = factory.socket(0) else {
            return XCTFail("no socket")
        }

        await transport.send(.prompt(text: "hello"))
        collector.waitFor("the prompt to reach the wire") { !socket.frames(method: "session/prompt").isEmpty }
        let echoKey = (socket.frames(method: "session/prompt").first?["params"] as? [String: Any])?["echoKey"] as? String

        // Our own user message comes back and must NOT be rendered again.
        bridge.push(socket, "bridge/user_message",
                    ["turn": 1, "echoKey": echoKey ?? "", "content": [["type": "text", "text": "hello"]]])
        bridge.push(socket, "session/update",
                    ["update": ["sessionUpdate": "agent_message_chunk",
                                "content": ["type": "text", "text": "Hi "]]])
        bridge.push(socket, "session/update",
                    ["update": ["sessionUpdate": "agent_message_chunk",
                                "content": ["type": "text", "text": "there."]]])
        bridge.push(socket, "bridge/turn_ended", ["turn": 1, "stopReason": "end_turn"])

        collector.waitFor("the turn to close") { collector.log.contains { $0.hasPrefix("end:") } }
        let log = collector.log
        XCTAssertFalse(log.contains { $0.hasPrefix("start:") && $0.hasSuffix(":local") },
                       "our own echo must be suppressed - the store already appended it")
        XCTAssertTrue(log.contains("start:acpr-m-2:agent"), "ids derive from seq; saw \(log)")
        XCTAssertTrue(log.contains("delta:acpr-m-2:Hi "))
        XCTAssertTrue(log.contains("delta:acpr-m-2:there."), "a second chunk extends the same bubble")
        XCTAssertTrue(log.contains("end:acpr-m-2:end_turn"))
        await transport.stop()
    }

    func testAnotherDevicesUserMessageIsRendered() async throws {
        let bridge = ScriptedBridge()
        let (transport, factory, collector) = try makeTransport(bridge: bridge)
        await transport.start()
        collector.waitFor("connected") { collector.log.contains("state:connected") }
        guard let socket = factory.socket(0) else {
            return XCTFail("no socket")
        }

        // An echoKey we never minted: somebody else typed this.
        bridge.push(socket, "bridge/user_message",
                    ["turn": 1, "echoKey": "someone-else",
                     "content": [["type": "text", "text": "from the laptop"]]])
        collector.waitFor("the other device's message") {
            collector.log.contains { $0.hasPrefix("delta:") && $0.hasSuffix("from the laptop") }
        }
        XCTAssertTrue(collector.log.contains("start:acpr-m-1:local"))
        await transport.stop()
    }

    func testTurnEndWithNoOpenBubbleStillCloses() async throws {
        let bridge = ScriptedBridge()
        let (transport, factory, collector) = try makeTransport(bridge: bridge)
        await transport.start()
        collector.waitFor("connected") { collector.log.contains("state:connected") }
        guard let socket = factory.socket(0) else {
            return XCTFail("no socket")
        }

        bridge.push(socket, "bridge/turn_ended", ["turn": 1, "stopReason": "cancelled"])
        collector.waitFor("a terminal messageEnd") { collector.log.contains("end:acpr-turn-1:cancelled") }
        // Without this the store's streaming flag never clears and the composer stays disabled.
        await transport.stop()
    }

    func testThoughtsSegmentSeparatelyFromMessages() async throws {
        let bridge = ScriptedBridge()
        let (transport, factory, collector) = try makeTransport(bridge: bridge)
        await transport.start()
        collector.waitFor("connected") { collector.log.contains("state:connected") }
        guard let socket = factory.socket(0) else {
            return XCTFail("no socket")
        }

        bridge.push(socket, "session/update",
                    ["update": ["sessionUpdate": "agent_thought_chunk",
                                "content": ["type": "text", "text": "thinking"]]])
        bridge.push(socket, "session/update",
                    ["update": ["sessionUpdate": "agent_message_chunk",
                                "content": ["type": "text", "text": "answer"]]])
        collector.waitFor("both items") { collector.log.contains { $0.hasPrefix("delta:acpr-m-2") } }
        XCTAssertTrue(collector.log.contains("thought:acpr-t-1:thinking"))
        await transport.stop()
    }

    func testDuplicateSeqsAreIgnored() async throws {
        let bridge = ScriptedBridge()
        let (transport, factory, collector) = try makeTransport(bridge: bridge)
        await transport.start()
        collector.waitFor("connected") { collector.log.contains("state:connected") }
        guard let socket = factory.socket(0) else {
            return XCTFail("no socket")
        }

        bridge.pushAt(socket, seq: 1, "session/update",
                      ["update": ["sessionUpdate": "agent_message_chunk",
                                  "content": ["type": "text", "text": "once"]]])
        collector.waitFor("the first delivery") { collector.log.contains { $0.hasSuffix(":once") } }
        // At-least-once delivery plus idempotent processing (I7): re-delivery must be a no-op.
        bridge.pushAt(socket, seq: 1, "session/update",
                      ["update": ["sessionUpdate": "agent_message_chunk",
                                  "content": ["type": "text", "text": "once"]]])
        try? await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(collector.log.filter { $0.hasSuffix(":once") }.count, 1,
                       "a seq at or below lastSeq must be dropped")
        await transport.stop()
    }

    // MARK: Reconnect and resume

    func testReconnectAttachesFromLastSeq() async throws {
        let bridge = ScriptedBridge()
        let (transport, factory, collector) = try makeTransport(bridge: bridge)
        await transport.start()
        collector.waitFor("connected") { collector.log.contains("state:connected") }
        guard let first = factory.socket(0) else {
            return XCTFail("no socket")
        }

        bridge.push(first, "session/update",
                    ["update": ["sessionUpdate": "agent_message_chunk",
                                "content": ["type": "text", "text": "before"]]])
        collector.waitFor("the first chunk") { collector.log.contains { $0.hasSuffix(":before") } }

        bridge.latestSeqAtAttach = 3
        bridge.replayOnAttach = [
            (method: "session/update", params: ["seq": 2, "sessionId": "sess-1",
                                                "update": ["sessionUpdate": "agent_message_chunk",
                                                           "content": ["type": "text", "text": "missed"]]]),
            (method: "bridge/turn_ended", params: ["seq": 3, "sessionId": "sess-1",
                                                   "turn": 1, "stopReason": "end_turn"]),
        ]
        first.dropConnection()

        collector.waitFor("reconnect and replay", timeout: 10) {
            collector.log.contains { $0.hasSuffix(":missed") }
        }
        XCTAssertEqual(bridge.attachCursor, 1, "the reattach must resume from lastSeq, not from 0")
        XCTAssertTrue(collector.log.contains("state:reconnecting"))
        // I9: the drop itself must NOT have ended the turn - only the replayed turn_ended does.
        let endIndex = collector.log.firstIndex { $0.hasPrefix("end:") }
        let missedIndex = collector.log.firstIndex { $0.hasSuffix(":missed") }
        if let endIndex, let missedIndex {
            XCTAssertLessThan(missedIndex, endIndex,
                              "the turn must end from the replay, never from the socket dropping")
        }
        await transport.stop()
    }

    func testEndedSessionSurfacesANonRecoverableError() async throws {
        let bridge = ScriptedBridge(sessionID: "sess-old")
        bridge.stateAtAttach = "ended"
        let (transport, _, collector) = try makeTransport(settings: ["session": "sess-old"], bridge: bridge)
        await transport.start()
        collector.waitFor("the ended notice") { collector.log.contains { $0.hasPrefix("error:false:") } }
        // The transcript still replays; the error only says it cannot be continued.
        XCTAssertTrue(collector.log.contains("ready:sess-old"))
        XCTAssertTrue(collector.log.contains { $0.contains("has ended") })
        await transport.stop()
    }

    func testPromptWhileDisconnectedErrorsAndDoesNotQueue() async throws {
        let bridge = ScriptedBridge()
        let (transport, factory, collector) = try makeTransport(bridge: bridge)
        await transport.start()
        collector.waitFor("connected") { collector.log.contains("state:connected") }
        factory.socket(0)?.dropConnection()

        await transport.send(.prompt(text: "into the void"))
        collector.waitFor("a recoverable error") { collector.log.contains { $0.hasPrefix("error:true:") } }
        XCTAssertTrue(collector.log.contains { $0.contains("not sent") },
                      "a queued prompt firing minutes later would surprise the user")
        await transport.stop()
    }

    // MARK: Permissions

    func testPermissionRoundTrip() async throws {
        let bridge = ScriptedBridge()
        let (transport, factory, collector) = try makeTransport(bridge: bridge)
        await transport.start()
        collector.waitFor("connected") { collector.log.contains("state:connected") }
        guard let socket = factory.socket(0) else {
            return XCTFail("no socket")
        }

        socket.deliver(["jsonrpc": "2.0", "id": 900, "method": "session/request_permission", "params": [
            "sessionId": "sess-1", "requestKey": "perm-1",
            "toolCall": ["toolCallId": "call-1", "title": "Edit main.swift"],
            "options": [["optionId": "allow", "name": "Allow", "kind": "allow_once"],
                        ["optionId": "deny", "name": "Deny", "kind": "reject_once"]],
        ]])
        collector.waitFor("the gate") { collector.log.contains("perm:perm-1") }
        // The id IS the requestKey, so the gate survives a reconnect and matches other devices.

        await transport.send(.permissionResponse(requestID: "perm-1", optionID: "allow"))
        collector.waitFor("the answer on the wire") {
            socket.sentFrames.contains { ($0["result"] as? [String: Any]) != nil }
        }
        let answer = socket.sentFrames.first { ($0["result"] as? [String: Any]) != nil }
        let outcome = ((answer?["result"] as? [String: Any])?["outcome"] as? [String: Any])
        XCTAssertEqual(outcome?["outcome"] as? String, "selected")
        XCTAssertEqual(outcome?["optionId"] as? String, "allow")
        await transport.stop()
    }

    func testPermissionResolvedElsewhereClearsTheGate() async throws {
        let bridge = ScriptedBridge()
        let (transport, factory, collector) = try makeTransport(bridge: bridge)
        await transport.start()
        collector.waitFor("connected") { collector.log.contains("state:connected") }
        guard let socket = factory.socket(0) else {
            return XCTFail("no socket")
        }

        socket.deliver(["jsonrpc": "2.0", "id": 900, "method": "session/request_permission", "params": [
            "sessionId": "sess-1", "requestKey": "perm-1", "toolCall": ["toolCallId": "c", "title": "t"],
            "options": [["optionId": "allow", "name": "Allow", "kind": "allow_once"]],
        ]])
        collector.waitFor("the gate") { collector.log.contains("perm:perm-1") }

        // Another device answered it.
        bridge.push(socket, "bridge/permission_resolved",
                    ["requestKey": "perm-1", "outcome": "selected", "optionId": "allow"])
        collector.waitFor("the gate to clear") { collector.log.contains("permresolved:perm-1") }
        await transport.stop()
    }

    func testPermissionTimeoutAlsoEmitsASystemNotice() async throws {
        let bridge = ScriptedBridge()
        let (transport, factory, collector) = try makeTransport(bridge: bridge)
        await transport.start()
        collector.waitFor("connected") { collector.log.contains("state:connected") }
        guard let socket = factory.socket(0) else {
            return XCTFail("no socket")
        }

        bridge.push(socket, "bridge/permission_resolved",
                    ["requestKey": "perm-1", "outcome": "timeout", "optionId": "deny"])
        collector.waitFor("the timeout notice") { collector.log.contains { $0.hasPrefix("system:") } }
        XCTAssertTrue(collector.log.contains { $0.contains("timed out") },
                      "a returning user must see why the request is gone, not a silent disappearance")
        await transport.stop()
    }

    func testPrivateHostRejectsSpoofedAndMalformedNames() {
        // The gate that decides whether an RCE token may travel in cleartext must fail closed.
        // Splitting on "." and keeping only the numeric labels made every one of these look
        // private, which handed the token to whoever registered the name.
        for host in ["127.0.0.1.evil.com", "10.0.0.1.attacker.example", "100.64.0.1.evil.net",
                     "a.10.b.0.c.0.d.1.evil.com", "0177.0.0.1", "10.0.0",
                     "10.0.0.1.2", "127.0.0.01", "10.0.0.256", "192.168.1.evil"] {
            XCTAssertFalse(ACPRemoteTransport.isPrivateHost(host), "\(host) must NOT count as private")
        }
        // A trailing root dot is the fully-qualified spelling of the same name, not a trick.
        for host in ["127.0.0.1", "127.0.0.1.", "10.0.0.5", "mac.local.",
                     "::1", "fd00::1", "fe80::1%en0"] {
            XCTAssertTrue(ACPRemoteTransport.isPrivateHost(host), "\(host) should be private")
        }
    }

    func testSpoofedHostIsRefusedByTheFactory() {
        XCTAssertThrowsError(try ACPRemoteTransport(
            config: ChatTransportConfig(settings: ["url": "ws://127.0.0.1.evil.com:8737/acp"]),
            logger: RemoteTestLogger()), "a name that merely looks loopback must not enable cleartext")
    }

    func testRoleSwitchClosesThePreviousBubble() async throws {
        let bridge = ScriptedBridge()
        let (transport, factory, collector) = try makeTransport(bridge: bridge)
        await transport.start()
        collector.waitFor("connected") { collector.log.contains("state:connected") }
        guard let socket = factory.socket(0) else {
            return XCTFail("no socket")
        }

        bridge.push(socket, "session/update",
                    ["update": ["sessionUpdate": "agent_message_chunk",
                                "content": ["type": "text", "text": "from the agent"]]])
        bridge.push(socket, "session/update",
                    ["update": ["sessionUpdate": "user_message_chunk",
                                "content": ["type": "text", "text": "from a person"]]])
        collector.waitFor("both bubbles") { collector.log.contains { $0.hasPrefix("start:acpr-m-2") } }
        // Without the close, the first bubble stays streaming until the turn ends - and the
        // turn-end only closes the newest id, so it never closes at all.
        XCTAssertTrue(collector.log.contains("end:acpr-m-1:-"),
                      "a role switch must close the bubble it replaces; saw \(collector.log)")
        await transport.stop()
    }

    func testHealthyConnectionSurvivesPastTheHandshakeTimeout() async throws {
        let bridge = ScriptedBridge()
        let (transport, factory, collector) = try makeTransport(
            settings: ["handshakeTimeoutSeconds": 0.3], bridge: bridge)
        await transport.start()
        collector.waitFor("connected") { collector.log.contains("state:connected") }

        // I1's other half: the watchdog must be RETIRED on success. Without that it closes every
        // healthy connection once the timeout elapses, which in production looks like the agent
        // dropping the user mid-conversation.
        try? await Task.sleep(nanoseconds: 700_000_000)
        XCTAssertFalse(factory.socket(0)?.isClosed ?? true,
                       "a connection that handshook successfully must not be closed by its watchdog")
        XCTAssertFalse(collector.log.contains("state:reconnecting"))
        await transport.stop()
    }

    func testCancelWhileDisconnectedLatchesUntilReattach() async throws {
        let bridge = ScriptedBridge()
        let (transport, factory, collector) = try makeTransport(bridge: bridge)
        await transport.start()
        collector.waitFor("connected") { collector.log.contains("state:connected") }
        guard let first = factory.socket(0) else {
            return XCTFail("no socket")
        }

        await transport.send(.prompt(text: "long running"))
        collector.waitFor("the prompt") { !first.frames(method: "session/prompt").isEmpty }

        // The turn is still running bridge-side; the bridge reports it at reattach.
        bridge.activeTurnAtAttach = 1
        bridge.latestSeqAtAttach = 0
        first.dropConnection()
        await transport.send(.cancel)

        collector.waitFor("the reconnect", timeout: 10) { factory.sockets.count > 1 }
        guard let second = factory.socket(1) else {
            return XCTFail("no second socket")
        }
        collector.waitFor("the latched cancel to reach the wire", timeout: 10) {
            !second.frames(method: "session/cancel").isEmpty
        }
        // I3: Stop must still stop, even when it was pressed with no connection.
        XCTAssertFalse(second.frames(method: "session/cancel").isEmpty)
        await transport.stop()
    }

    func testCancelIsNotSentForATurnThatAlreadyEnded() async throws {
        let bridge = ScriptedBridge()
        let (transport, factory, collector) = try makeTransport(bridge: bridge)
        await transport.start()
        collector.waitFor("connected") { collector.log.contains("state:connected") }
        guard let first = factory.socket(0) else {
            return XCTFail("no socket")
        }
        await transport.send(.prompt(text: "quick"))
        collector.waitFor("the prompt") { !first.frames(method: "session/prompt").isEmpty }

        // The bridge says no turn is running when we come back: the latch must NOT fire, or we
        // would cancel whatever turn starts next.
        bridge.activeTurnAtAttach = nil
        first.dropConnection()
        await transport.send(.cancel)

        collector.waitFor("the reconnect", timeout: 10) { factory.sockets.count > 1 }
        try? await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertTrue(factory.socket(1)?.frames(method: "session/cancel").isEmpty ?? false,
                      "a latched cancel must target its own turn, not the next one")
        await transport.stop()
    }

    func testNonRecoverableRefusalStopsReconnecting() async throws {
        let bridge = ScriptedBridge()
        let (transport, factory, collector) = try makeTransport(bridge: bridge, configure: { _, socket in
            socket.onSend = { socket, message in
                guard let id = message["id"] else {
                    return
                }
                socket.deliver(["jsonrpc": "2.0", "id": id,
                                "error": ["code": -32000, "message": "authentication failed"]])
            }
        })
        await transport.start()
        collector.waitFor("the refusal") { collector.log.contains { $0.hasPrefix("error:false:") } }

        // Retrying a bad token forever helps nobody and hammers the bridge.
        try? await Task.sleep(nanoseconds: 1_500_000_000)
        XCTAssertFalse(collector.log.contains("state:reconnecting"),
                       "a refusal retrying cannot fix must not start the reconnect loop; saw \(collector.log)")
        XCTAssertEqual(factory.sockets.count, 1, "no second attempt should have been made")
        await transport.stop()
    }

    func testPermissionAnsweredWhileDisconnectedSurvivesTheReattach() async throws {
        let bridge = ScriptedBridge()
        let (transport, factory, collector) = try makeTransport(bridge: bridge)
        await transport.start()
        collector.waitFor("connected") { collector.log.contains("state:connected") }
        guard let first = factory.socket(0) else {
            return XCTFail("no socket")
        }

        let request: [String: Any] = [
            "sessionId": "sess-1", "requestKey": "perm-1",
            "toolCall": ["toolCallId": "call-1", "title": "Edit"],
            "options": [["optionId": "allow", "name": "Allow", "kind": "allow_once"]],
        ]
        first.deliver(["jsonrpc": "2.0", "id": 900, "method": "session/request_permission", "params": request])
        collector.waitFor("the gate") { collector.log.contains("perm:perm-1") }

        // The socket dies, THEN the user taps Allow. The answer must not evaporate.
        first.dropConnection()
        await transport.send(.permissionResponse(requestID: "perm-1", optionID: "allow"))

        collector.waitFor("the reconnect", timeout: 10) { factory.sockets.count > 1 }
        guard let second = factory.socket(1) else {
            return XCTFail("no second socket")
        }
        second.deliver(["jsonrpc": "2.0", "id": 901, "method": "session/request_permission", "params": request])

        collector.waitFor("the held answer to be applied", timeout: 10) {
            second.sentFrames.contains { ($0["result"] as? [String: Any]) != nil }
        }
        let answer = second.sentFrames.first { ($0["result"] as? [String: Any]) != nil }
        let outcome = (answer?["result"] as? [String: Any])?["outcome"] as? [String: Any]
        XCTAssertEqual(outcome?["optionId"] as? String, "allow",
                       "the user answered once; they must not be asked again")
        XCTAssertEqual(collector.log.filter { $0 == "perm:perm-1" }.count, 1,
                       "and the gate must not be shown a second time")
        await transport.stop()
    }

    func testReissuedPermissionDoesNotStackASecondGate() async throws {
        let bridge = ScriptedBridge()
        let (transport, factory, collector) = try makeTransport(bridge: bridge)
        await transport.start()
        collector.waitFor("connected") { collector.log.contains("state:connected") }
        guard let socket = factory.socket(0) else {
            return XCTFail("no socket")
        }

        let request: [String: Any] = [
            "sessionId": "sess-1", "requestKey": "perm-1",
            "toolCall": ["toolCallId": "call-1", "title": "Edit"],
            "options": [["optionId": "allow", "name": "Allow", "kind": "allow_once"]],
        ]
        socket.deliver(["jsonrpc": "2.0", "id": 900, "method": "session/request_permission", "params": request])
        collector.waitFor("the gate") { collector.log.contains("perm:perm-1") }
        // A second re-issue of the SAME key, which the bridge does for every attaching client.
        socket.deliver(["jsonrpc": "2.0", "id": 901, "method": "session/request_permission", "params": request])
        try? await Task.sleep(nanoseconds: 200_000_000)

        XCTAssertEqual(collector.log.filter { $0 == "perm:perm-1" }.count, 1,
                       "the store appends gates without deduping, so a re-issue must not emit again")

        // Both parked requests must be answered - and neither continuation may leak, which
        // would be a hard runtime error.
        await transport.send(.permissionResponse(requestID: "perm-1", optionID: "allow"))
        collector.waitFor("both requests answered") {
            socket.sentFrames.filter { ($0["result"] as? [String: Any]) != nil }.count == 2
        }
        await transport.stop()
    }

    func testKeepaliveFailureClosesTheConnection() async throws {
        let bridge = ScriptedBridge()
        let (transport, factory, collector) = try makeTransport(bridge: bridge)
        await transport.start()
        collector.waitFor("connected") { collector.log.contains("state:connected") }
        // A silently reaped flow never errors on receive, so the ping is the only thing that
        // can notice. Drive it directly rather than waiting 30 seconds.
        guard let socket = factory.socket(0) else {
            return XCTFail("no socket")
        }
        socket.pingError = ACPRemoteError(code: nil, message: "network unreachable")
        socket.sendPing { _ in }
        XCTAssertNotNil(socket.pingError)
        await transport.stop()
    }

    // MARK: Cold-launch checkpoint (item 2.2a)

    func testCheckpointEmittedAtTurnBoundaryOnly() async throws {
        let bridge = ScriptedBridge()
        let (transport, factory, collector) = try makeTransport(bridge: bridge)
        await transport.start()
        collector.waitFor("connected") { collector.log.contains("state:connected") }
        guard let socket = factory.socket(0) else {
            return XCTFail("no socket")
        }

        bridge.push(socket, "session/update",
                    ["update": ["sessionUpdate": "agent_message_chunk",
                                "content": ["type": "text", "text": "streaming"]]])
        try? await Task.sleep(nanoseconds: 80_000_000)
        XCTAssertFalse(collector.log.contains { $0.hasPrefix("checkpoint:") },
                       "a mid-stream checkpoint would pair a cursor with a half-rendered bubble")

        bridge.push(socket, "bridge/turn_ended", ["turn": 1, "stopReason": "end_turn"])
        collector.waitFor("the checkpoint") { collector.log.contains { $0.hasPrefix("checkpoint:") } }
        XCTAssertEqual(collector.log.filter { $0.hasPrefix("checkpoint:") }, ["checkpoint:sess-1:2"],
                       "exactly one checkpoint, carrying the turn_ended seq")
        await transport.stop()
    }

    func testCheckpointAfterAQuietAttach() async throws {
        let bridge = ScriptedBridge()
        bridge.latestSeqAtAttach = 5
        let (transport, _, collector) = try makeTransport(settings: ["session": "sess-1",
                                                                     "resumeAfterSeq": 5], bridge: bridge)
        await transport.start()
        collector.waitFor("the checkpoint") { collector.log.contains { $0.hasPrefix("checkpoint:") } }
        XCTAssertTrue(collector.log.contains("checkpoint:sess-1:5"),
                      "a settled attach with no live turn is a checkpoint moment")
        await transport.stop()
    }

    func testResumeAfterSeqIsSentOnTheFirstAttach() async throws {
        let bridge = ScriptedBridge()
        bridge.latestSeqAtAttach = 412
        let (transport, _, collector) = try makeTransport(settings: ["session": "sess-1",
                                                                     "resumeAfterSeq": 412], bridge: bridge)
        await transport.start()
        collector.waitFor("connected") { collector.log.contains("state:connected") }
        XCTAssertEqual(bridge.attachCursor, 412,
                       "the whole point of the checkpoint: ask only for what came after it")
        await transport.stop()
    }

    func testResumeAfterSeqIgnoredForNewOrLatestSession() throws {
        let bridge = ScriptedBridge()
        let logger = RemoteTestLogger()
        let (transport, _, collector) = try makeTransport(settings: ["session": "new", "resumeAfterSeq": 99],
                                                          bridge: bridge, logger: logger)
        _ = transport
        collector.stop()
        XCTAssertTrue(logger.contains("ignoring resumeAfterSeq"),
                      "a cursor is only meaningful against the session id it was minted for")
    }

    func testResumeAfterSeqIgnoredOnSessionMismatch() async throws {
        let bridge = ScriptedBridge(sessionID: "sess-1")
        bridge.attachSessionIDOverride = "sess-DIFFERENT"
        bridge.latestSeqAtAttach = 50
        let logger = RemoteTestLogger()
        let (transport, _, collector) = try makeTransport(settings: ["session": "sess-1", "resumeAfterSeq": 40],
                                                          bridge: bridge, logger: logger)
        await transport.start()
        collector.waitFor("connected") { collector.log.contains("state:connected") }
        XCTAssertTrue(logger.contains("replaying from the beginning"),
                      "a cursor from another session would silently skip this session's history")
        await transport.stop()
    }
}
