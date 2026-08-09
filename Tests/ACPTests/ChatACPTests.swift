// Tests/ACPTests/ChatACPTests.swift
//
// Unit tests for the ACP transport, wire and demux layers, without spawning a real
// agent: the JSON-RPC framing / correlation (ACPConnection.handleLine driven with
// literal wire lines), the payload parsers (tool_call / tool_call_update / content
// blocks), the session/update demux with its message segmentation (contiguous chunk
// runs become one item; a tool call closes the open segment with a nil stopReason),
// and the session/request_permission round-trip (selected and cancelled outcomes).
// Live validation against a real ACP agent is a separate step (see the work plan).
//
// Swift 6 note: JSON payloads are [String: Any] (non-Sendable), so helper Tasks
// reduce them to Sendable digests (strings / ints / tuples) before returning, and
// cross-task signals go through the small LockedBox.

#if os(macOS)

import XCTest
@testable import ChatViewACP
import ChatView

private final class ACPTestLogger: ChatLogger {
    func log(_ message: String, _ level: ChatLogLevel) {}
}

/// A tiny lock-guarded cell for observing values set from @Sendable callbacks.
private final class LockedBox<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: T?

    var value: T? {
        get {
            lock.withLock { stored }
        }
        set {
            lock.withLock { stored = newValue }
        }
    }
}

// MARK: - JSON-RPC framing / correlation

final class ACPConnectionTests: XCTestCase {

    private func makeConnection(
        onNotification: @escaping ACPConnection.NotificationHandler = { _, _ in },
        onRequest: @escaping ACPConnection.RequestHandler = { _, _ in nil }
    ) -> ACPConnection {
        ACPConnection(logger: ACPTestLogger(), onNotification: onNotification,
                      onRequest: onRequest, onClose: { _ in })
    }

    func testRequestResumesOnMatchingResponse() async throws {
        let connection = makeConnection()
        let task = Task { () -> Int? in
            let result = try await connection.request("initialize", ["protocolVersion": 1])
            return (result["protocolVersion"] as? NSNumber)?.intValue
        }
        try await Task.sleep(nanoseconds: 50_000_000)   // let the request register
        connection.handleLine(#"{"jsonrpc":"2.0","id":1,"result":{"protocolVersion":1}}"#)
        let version = try await task.value
        XCTAssertEqual(version, 1)
    }

    func testRequestThrowsOnErrorResponse() async throws {
        let connection = makeConnection()
        let task = Task { () -> String in
            do {
                _ = try await connection.request("session/new", [:])
                return "no error"
            } catch let error as ACPConnectionError {
                return "\(error.code ?? 0): \(error.message)"
            } catch {
                return "unexpected error: \(error)"
            }
        }
        try await Task.sleep(nanoseconds: 50_000_000)
        connection.handleLine(#"{"jsonrpc":"2.0","id":1,"error":{"code":-32000,"message":"auth required"}}"#)
        let outcome = await task.value
        XCTAssertEqual(outcome, "-32000: auth required")
    }

    func testNotificationDispatch() {
        let seen = LockedBox<(method: String, sessionID: String?)>()
        let connection = makeConnection(onNotification: { method, params in
            seen.value = (method, params["sessionId"] as? String)
        })
        // Notifications dispatch synchronously from handleLine, so assert directly.
        connection.handleLine(#"{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"s1"}}"#)
        XCTAssertEqual(seen.value?.method, "session/update")
        XCTAssertEqual(seen.value?.sessionID, "s1")
    }

    func testAgentRequestReachesHandler() async throws {
        let seen = LockedBox<(method: String, sessionID: String?)>()
        let connection = makeConnection(onRequest: { method, params in
            seen.value = (method, params["sessionId"] as? String)
            return ["outcome": ["outcome": "cancelled"]]
        })
        connection.handleLine(#"{"jsonrpc":"2.0","id":9,"method":"session/request_permission","params":{"sessionId":"s1"}}"#)
        // The handler runs on its own task (a permission prompt can take arbitrarily long);
        // poll briefly for the dispatch.
        for _ in 0..<100 where seen.value == nil {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertEqual(seen.value?.method, "session/request_permission")
        XCTAssertEqual(seen.value?.sessionID, "s1")
    }

    func testMalformedLinesAreDroppedWithoutCrashing() {
        let connection = makeConnection()
        connection.handleLine("")
        connection.handleLine("not json at all")
        connection.handleLine(#"{"jsonrpc":"2.0","id":42,"result":{}}"#)   // response with no pending request
    }
}

// MARK: - Payload parsing

final class ACPParsingTests: XCTestCase {

    func testContentTextJoinsAndNotesNonText() {
        XCTAssertEqual(ACPChatTransport.contentText(["type": "text", "text": "hello"]), "hello")
        let joined = ACPChatTransport.contentText([
            ["type": "text", "text": "first"],
            ["type": "image", "data": "...", "mimeType": "image/png"],
            ["type": "text", "text": "second"],
        ])
        XCTAssertEqual(joined, "first\n\n[image]\n\nsecond")
        XCTAssertEqual(ACPChatTransport.contentText(nil), "")
    }

    func testParseToolCallFullPayload() {
        let call = ACPChatTransport.parseToolCall([
            "toolCallId": "call-1",
            "title": "Edit main.py",
            "kind": "edit",
            "status": "in_progress",
            "content": [
                ["type": "content", "content": ["type": "text", "text": "editing"]],
                ["type": "diff", "path": "main.py", "oldText": "a", "newText": "b"],
                ["type": "terminal", "terminalId": "term-1"],
            ],
            "rawInput": ["path": "main.py"],
        ])
        XCTAssertEqual(call.id, "call-1")
        XCTAssertEqual(call.kind, .edit)
        XCTAssertEqual(call.status, .inProgress)
        XCTAssertEqual(call.contentText, "editing\n\n[terminal output]")
        XCTAssertEqual(call.diff, ToolCallDiff(path: "main.py", oldText: "a", newText: "b"))
        XCTAssertEqual(call.rawInput?.contains("main.py"), true)
        XCTAssertNil(call.rawOutput)
    }

    func testParseToolCallDefaults() {
        let call = ACPChatTransport.parseToolCall(["toolCallId": "call-2"])
        XCTAssertEqual(call.kind, .other, "spec default")
        XCTAssertEqual(call.status, .pending, "spec default")
        XCTAssertEqual(call.contentText, "")
        XCTAssertNil(call.diff)
    }

    func testParseToolCallUpdateCarriesOnlyPresentFields() {
        let update = ACPChatTransport.parseToolCallUpdate([
            "toolCallId": "call-1",
            "status": "completed",
        ])
        XCTAssertEqual(update.id, "call-1")
        XCTAssertEqual(update.status, .completed)
        XCTAssertNil(update.title)
        XCTAssertNil(update.kind)
        XCTAssertNil(update.contentText, "content absent on the wire must stay nil so the card keeps its text")
        XCTAssertNil(update.diff)
    }

    // MARK: M5 part 1 - configOptions / plan / usage

    func testParseConfigOptionsOpenCodeShape() {
        // The shape OpenCode returns from session/new (captured live).
        let options = ACPChatTransport.parseConfigOptions([
            "sessionId": "s1",
            "configOptions": [
                ["id": "model", "name": "Model", "category": "model", "type": "select",
                 "currentValue": "opencode/big-pickle",
                 "options": [["value": "opencode/big-pickle", "name": "Big Pickle"]]],
                ["id": "mode", "name": "Session Mode", "category": "mode", "type": "select",
                 "currentValue": "build",
                 "options": [["value": "build", "name": "build", "description": "The default agent."],
                             ["value": "plan", "name": "plan", "description": "Plan mode."]]],
                ["id": "knob", "name": "Free text", "type": "text", "currentValue": "x"],
            ],
        ])
        XCTAssertEqual(options.map(\.id), ["model", "mode"], "non-select options are dropped")
        XCTAssertEqual(options[0].currentChoiceName, "Big Pickle")
        XCTAssertEqual(options[1].options.count, 2)
        XCTAssertEqual(options[1].options[1].description, "Plan mode.")
    }

    func testParseConfigOptionsSpecModesFallback() {
        let options = ACPChatTransport.parseConfigOptions([
            "sessionId": "s1",
            "modes": ["currentModeId": "ask",
                      "availableModes": [["id": "ask", "name": "Ask"], ["id": "auto", "name": "Auto"]]],
        ])
        XCTAssertEqual(options.count, 1)
        XCTAssertEqual(options[0].id, "mode")
        XCTAssertEqual(options[0].currentValue, "ask")
        XCTAssertEqual(options[0].options.map(\.value), ["ask", "auto"])
    }

    func testParsePlanEntries() {
        let entries = ACPChatTransport.parsePlan([
            "sessionUpdate": "plan",
            "entries": [
                ["content": "Read the file", "priority": "high", "status": "completed"],
                ["content": "Edit the file", "status": "in_progress"],
                ["content": "Later", "status": "someday"],
            ],
        ])
        XCTAssertEqual(entries.count, 3)
        XCTAssertEqual(entries[0].status, .completed)
        XCTAssertEqual(entries[0].priority, "high")
        XCTAssertEqual(entries[1].status, .inProgress)
        XCTAssertEqual(entries[2].status, .pending, "an unknown status falls back to pending")
        XCTAssertEqual(entries.map(\.id), [0, 1, 2], "identity is positional")
    }

    func testFallbackSetterMapping() {
        let mode = SessionConfigOption(id: "session-mode", name: "Mode", category: "mode", currentValue: "b", options: [])
        XCTAssertEqual(ACPChatTransport.fallbackSetter(for: mode)?.method, "session/set_mode")
        XCTAssertEqual(ACPChatTransport.fallbackSetter(for: mode)?.paramKey, "modeId")
        let model = SessionConfigOption(id: "model", name: "Model", category: nil, currentValue: "m", options: [])
        XCTAssertEqual(ACPChatTransport.fallbackSetter(for: model)?.method, "session/set_model",
                       "the option id stands in when no category is given")
        let other = SessionConfigOption(id: "verbosity", name: "V", category: nil, currentValue: "x", options: [])
        XCTAssertNil(ACPChatTransport.fallbackSetter(for: other), "no spec fallback for agent-specific options")
        XCTAssertNil(ACPChatTransport.fallbackSetter(for: nil))
    }

    func testParseCommands() {
        // The shape OpenCode emits (captured live).
        let commands = ACPChatTransport.parseCommands([
            "sessionUpdate": "available_commands_update",
            "availableCommands": [
                ["name": "init", "description": "guided AGENTS.md setup"],
                ["name": "review"],
                ["description": "nameless is dropped"],
            ],
        ])
        XCTAssertEqual(commands.map(\.name), ["init", "review"])
        XCTAssertEqual(commands[0].description, "guided AGENTS.md setup")
        XCTAssertEqual(commands[1].description, "", "a missing description is empty, not a drop")
    }

    func testParseUsage() {
        // The shape OpenCode emits (captured live).
        let usage = ACPChatTransport.parseUsage([
            "sessionUpdate": "usage_update",
            "used": 8170, "size": 200000,
            "cost": ["amount": 0.5, "currency": "USD"],
        ])
        XCTAssertEqual(usage?.used, 8170)
        XCTAssertEqual(usage?.size, 200000)
        XCTAssertEqual(usage?.costAmount, 0.5)
        XCTAssertEqual(usage?.costCurrency, "USD")
        XCTAssertNil(ACPChatTransport.parseUsage(["sessionUpdate": "usage_update"]),
                     "no usable `used` -> no event")
    }
}

// MARK: - session/update demux and segmentation

final class ACPDemuxTests: XCTestCase {

    private func makeTransport() throws -> ACPChatTransport {
        try ACPChatTransport(config: ChatTransportConfig(settings: ["command": ["true"]]), logger: ACPTestLogger())
    }

    private func update(_ payload: [String: Any]) -> [String: Any] {
        ["sessionId": "s1", "update": payload]
    }

    private func chunk(_ kind: String, _ text: String) -> [String: Any] {
        update(["sessionUpdate": kind, "content": ["type": "text", "text": text]])
    }

    func testMessageSegmentation() async throws {
        let transport = try makeTransport()
        transport.handleNotification("session/update", chunk("agent_message_chunk", "Hello"))
        transport.handleNotification("session/update", chunk("agent_message_chunk", " world"))
        transport.handleNotification("session/update", update(["sessionUpdate": "tool_call", "toolCallId": "t1", "title": "Search"]))
        transport.handleNotification("session/update", chunk("agent_message_chunk", "Done."))
        await transport.stop()   // finish the stream so collection below terminates

        var events: [ChatEvent] = []
        for await event in transport.events {
            events.append(event)
        }

        // Expected: start(A), delta(A), delta(A), end(A, nil), toolCall, start(B), delta(B).
        guard events.count == 7,
              case .messageStart(let firstID, .agent) = events[0],
              case .messageDelta(firstID, "Hello") = events[1],
              case .messageDelta(firstID, " world") = events[2],
              case .messageEnd(firstID, nil) = events[3],
              case .toolCall(let call) = events[4],
              case .messageStart(let secondID, .agent) = events[5],
              case .messageDelta(secondID, "Done.") = events[6] else {
            return XCTFail("unexpected event sequence: \(events)")
        }
        XCTAssertEqual(call.id, "t1")
        XCTAssertNotEqual(firstID, secondID, "a tool call must split message segments")
    }

    func testWhitespaceOnlyChunkDoesNotOpenEmptyBubble() async throws {
        // Reproduces the empty-assistant-bubble bug: a model emits its reasoning, then a blank line
        // (the newline between </think> and the tool call reaches the transport as a whitespace-only
        // agent_message_chunk), then calls a tool, then answers. The blank chunk must NOT open a
        // message segment - only the thought, the tool call, and the real answer should appear.
        let transport = try makeTransport()
        transport.handleNotification("session/update", chunk("agent_thought_chunk", "reasoning"))
        transport.handleNotification("session/update", chunk("agent_message_chunk", "\n\n"))
        transport.handleNotification("session/update", update(["sessionUpdate": "tool_call", "toolCallId": "t1", "title": "get_current_time"]))
        transport.handleNotification("session/update", chunk("agent_message_chunk", "The time is 10:36 PM."))
        await transport.stop()

        var events: [ChatEvent] = []
        for await event in transport.events {
            events.append(event)
        }
        // No messageStart/messageDelta for the blank chunk: thought, tool call, then the real answer.
        guard events.count == 4,
              case .thoughtDelta(_, "reasoning") = events[0],
              case .toolCall(let call) = events[1],
              case .messageStart(let msgID, .agent) = events[2],
              case .messageDelta(msgID, "The time is 10:36 PM.") = events[3] else {
            return XCTFail("unexpected event sequence: \(events)")
        }
        XCTAssertEqual(call.id, "t1")
        XCTAssertFalse(events.contains { if case .messageDelta(_, "\n\n") = $0 { return true } else { return false } },
                       "the whitespace chunk must never reach the transcript")
    }

    func testWhitespaceWithinOpenMessageIsPreserved() async throws {
        // The guard must only suppress a whitespace chunk that would OPEN a bubble; once a message is
        // open, a blank chunk between words must still flow so spacing is not lost ("Hi" + " " + "there").
        let transport = try makeTransport()
        transport.handleNotification("session/update", chunk("agent_message_chunk", "Hi"))
        transport.handleNotification("session/update", chunk("agent_message_chunk", " "))
        transport.handleNotification("session/update", chunk("agent_message_chunk", "there"))
        await transport.stop()

        var events: [ChatEvent] = []
        for await event in transport.events {
            events.append(event)
        }
        guard events.count == 4,
              case .messageStart(let id, .agent) = events[0],
              case .messageDelta(id, "Hi") = events[1],
              case .messageDelta(id, " ") = events[2],
              case .messageDelta(id, "there") = events[3] else {
            return XCTFail("unexpected event sequence: \(events)")
        }
    }

    func testThoughtsSegmentSeparatelyFromMessages() async throws {
        let transport = try makeTransport()
        transport.handleNotification("session/update", chunk("agent_thought_chunk", "thinking"))
        transport.handleNotification("session/update", chunk("agent_message_chunk", "answer"))
        await transport.stop()

        var events: [ChatEvent] = []
        for await event in transport.events {
            events.append(event)
        }
        guard events.count == 3,
              case .thoughtDelta(let thoughtID, "thinking") = events[0],
              case .messageStart(let messageID, .agent) = events[1],
              case .messageDelta(messageID, "answer") = events[2] else {
            return XCTFail("unexpected event sequence: \(events)")
        }
        XCTAssertNotEqual(thoughtID, messageID)
    }

    func testUserMessageChunkRoutesAsLocalRole() async throws {
        let transport = try makeTransport()
        transport.handleNotification("session/update", chunk("user_message_chunk", "my prompt"))
        await transport.stop()

        var events: [ChatEvent] = []
        for await event in transport.events {
            events.append(event)
        }
        guard events.count == 2,
              case .messageStart(let id, .local) = events[0],
              case .messageDelta(id, "my prompt") = events[1] else {
            return XCTFail("unexpected event sequence: \(events)")
        }
    }

    func testReserveIDsSeedsCounterPastLoadedAcpIds() async throws {
        // Continuing an ACP transcript restored from a prior run must not reuse a loaded id. ACP
        // mints "acp-turn-/thought-/message-<n>" from a launch-reset counter, so reserving past the
        // max loaded suffix (here acp-thought-5) makes the next reply mint acp-message-6. A non-acp
        // id (user-1) is ignored.
        let transport = try makeTransport()
        transport.reserveIDs(seen: ["acp-turn-1", "acp-message-3", "acp-thought-5", "user-1"])
        transport.handleNotification("session/update", chunk("agent_message_chunk", "reply"))
        await transport.stop()

        var events: [ChatEvent] = []
        for await event in transport.events {
            events.append(event)
        }
        guard case .messageStart(let id, .agent) = events.first else {
            return XCTFail("expected a message start, got: \(events)")
        }
        XCTAssertEqual(id, "acp-message-6",
                       "a continued ACP turn mints past the max loaded acp-* suffix (5), never reusing a loaded id")
    }
}

// MARK: - Permission round-trip

/// Runs one permission request through the transport, reduced to a Sendable
/// "outcome:optionId" digest (the JSON payloads themselves are not Sendable).
private func askPermission(of transport: ACPChatTransport) async -> String {
    let params: [String: Any] = [
        "sessionId": "s1",
        "toolCall": ["toolCallId": "t1", "title": "Edit main.py"],
        "options": [
            ["optionId": "allow", "name": "Allow", "kind": "allow_once"],
            ["optionId": "reject", "name": "Reject", "kind": "reject_once"],
        ],
    ]
    let response = await transport.handleRequest("session/request_permission", params)
    let outcome = response?["outcome"] as? [String: Any]
    let kind = (outcome?["outcome"] as? String) ?? "none"
    let option = (outcome?["optionId"] as? String) ?? "-"
    return "\(kind):\(option)"
}

final class ACPPermissionTests: XCTestCase {

    /// Runs the permission request on its own task so the test can answer it mid-flight.
    private func spawnPermissionRequest(on transport: ACPChatTransport) -> Task<String, Never> {
        Task {
            await askPermission(of: transport)
        }
    }

    private func awaitPermissionEvent(from transport: ACPChatTransport) async -> PermissionRequest? {
        for await event in transport.events {
            if case .permissionRequest(let pending) = event {
                return pending
            }
        }
        return nil
    }

    func testSelectedOutcome() async throws {
        let transport = try ACPChatTransport(config: ChatTransportConfig(settings: ["command": ["true"]]), logger: ACPTestLogger())
        let responseTask = spawnPermissionRequest(on: transport)

        let observed = await awaitPermissionEvent(from: transport)
        let pending = try XCTUnwrap(observed)
        XCTAssertEqual(pending.toolCallID, "t1")
        XCTAssertEqual(pending.title, "Edit main.py")
        XCTAssertEqual(pending.options.map(\.id), ["allow", "reject"])

        await transport.send(.permissionResponse(requestID: pending.id, optionID: "allow"))
        let response = await responseTask.value
        XCTAssertEqual(response, "selected:allow")
    }

    func testDismissalBecomesCancelledOutcome() async throws {
        let transport = try ACPChatTransport(config: ChatTransportConfig(settings: ["command": ["true"]]), logger: ACPTestLogger())
        let responseTask = spawnPermissionRequest(on: transport)

        let observed = await awaitPermissionEvent(from: transport)
        let pending = try XCTUnwrap(observed)
        await transport.send(.permissionResponse(requestID: pending.id, optionID: nil))
        let response = await responseTask.value
        XCTAssertEqual(response, "cancelled:-")
    }

    func testUnsupportedAgentRequestAnswersMethodNotFound() async throws {
        let transport = try ACPChatTransport(config: ChatTransportConfig(settings: ["command": ["true"]]), logger: ACPTestLogger())
        let task = Task { () -> Bool in
            let response = await transport.handleRequest("fs/read_text_file", ["path": "/etc/hosts"])
            return response == nil
        }
        let wasRefused = await task.value
        XCTAssertTrue(wasRefused, "unadvertised capabilities must answer method-not-found")
    }

    func testMissingCommandThrows() {
        XCTAssertThrowsError(try ACPChatTransport(config: ChatTransportConfig(settings: [:]), logger: ACPTestLogger()))
        XCTAssertThrowsError(try ACPChatTransport(config: ChatTransportConfig(settings: ["command": []]), logger: ACPTestLogger()))
    }
}

// MARK: - Session cwd normalization

// ACP requires the session/new cwd to be an absolute path; a literal "~" reached
// OpenCode as "<agent cwd>/~" and failed the session. The transport must expand it.
final class ACPCwdTests: XCTestCase {

    func testTildeExpandsToHome() {
        XCTAssertEqual(ACPChatTransport.absoluteCwd("~"), NSHomeDirectory())
    }

    func testTildeSubpathExpands() {
        XCTAssertEqual(ACPChatTransport.absoluteCwd("~/Development"), NSHomeDirectory() + "/Development")
    }

    func testAbsolutePathPassesThrough() {
        XCTAssertEqual(ACPChatTransport.absoluteCwd("/usr/local"), "/usr/local")
    }

    func testNilFallsBackToCurrentDirectory() {
        XCTAssertEqual(ACPChatTransport.absoluteCwd(nil), FileManager.default.currentDirectoryPath)
    }

    func testEmptyFallsBackToCurrentDirectory() {
        XCTAssertEqual(ACPChatTransport.absoluteCwd(""), FileManager.default.currentDirectoryPath)
    }

    func testRelativePathAnchorsToCurrentDirectory() {
        XCTAssertEqual(ACPChatTransport.absoluteCwd("sub/dir"),
                       FileManager.default.currentDirectoryPath + "/sub/dir")
    }
}

// MARK: - End to end against a fake agent subprocess

// The one test that exercises the REAL wire path - launch, pipes, newline framing,
// request correlation, notification demux - by speaking to a shell-script agent that
// answers initialize / session/new / session/prompt and streams one message chunk.
final class ACPFakeAgentTests: XCTestCase {

    private static let fakeAgentScript = """
    #!/bin/sh
    while IFS= read -r line; do
      case "$line" in
        *'"method":"initialize"'*)
          printf '%s\\n' '{"jsonrpc":"2.0","id":1,"result":{"protocolVersion":1,"agentCapabilities":{},"authMethods":[]}}' ;;
        *'"method":"session/new"'*)
          case "$line" in
            *'~'*)
              printf '%s\\n' '{"jsonrpc":"2.0","id":2,"error":{"code":-32602,"message":"cwd must be an absolute path"}}' ;;
            *)
              printf '%s\\n' '{"jsonrpc":"2.0","id":2,"result":{"sessionId":"fake-session"}}' ;;
          esac ;;
        *'"method":"session/prompt"'*)
          printf '%s\\n' '{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"fake-session","update":{"sessionUpdate":"agent_message_chunk","content":{"type":"text","text":"Hi!"}}}}'
          printf '%s\\n' '{"jsonrpc":"2.0","id":3,"result":{"stopReason":"end_turn"}}' ;;
        *'"method":"session/set_config_option"'*)
          printf '%s\\n' '{"jsonrpc":"2.0","id":3,"result":{"configOptions":[{"id":"mode","name":"Mode","category":"mode","type":"select","currentValue":"plan","options":[{"value":"build","name":"build"},{"value":"plan","name":"plan"}]}]}}' ;;
      esac
    done
    """

    func testFullTurnAgainstFakeAgent() async throws {
        let scriptURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("actionui-chat-fake-acp-agent-\(UUID().uuidString).sh")
        try Self.fakeAgentScript.write(to: scriptURL, atomically: true, encoding: .utf8)
        defer {
            try? FileManager.default.removeItem(at: scriptURL)
        }

        // cwd "~" doubles as the wire-level regression test for cwd normalization: the
        // fake agent rejects session/new when a literal "~" appears in it (ACP requires
        // an absolute path; OpenCode failed exactly this way), so this test only passes
        // if the transport expanded it.
        let transport = try ACPChatTransport(
            config: ChatTransportConfig(settings: ["command": ["/bin/sh", scriptURL.path], "cwd": "~"]),
            logger: ACPTestLogger()
        )
        await transport.start()
        await transport.send(.prompt(text: "hello"))

        var log: [String] = []
        for await event in transport.events {
            switch event {
            case .sessionReady(let sessionID, _):
                log.append("ready:\(sessionID)")
            case .sessionInfo(let info):
                log.append("info:\(info.sessionId)")
            case .messageStart(_, let role):
                log.append("start:\(role.rawValue)")
            case .messageDelta(_, let text):
                log.append("delta:\(text)")
            case .messageEnd(_, let stopReason):
                log.append("end:\(stopReason ?? "nil")")
            case .error(let message, _):
                log.append("error:\(message)")
            default:
                log.append("other")
            }
            if case .messageEnd = event {
                break
            }
            if case .error = event {
                break   // a failed launch must fail the assertion below, not hang the stream
            }
        }
        await transport.stop()

        // sessionInfo (agent identity) follows sessionReady on every established session,
        // before any turn events; ChatACPLaunchTests pins its payload.
        XCTAssertEqual(log, ["ready:fake-session", "info:fake-session", "start:agent", "delta:Hi!", "end:end_turn"])
    }

    // The setter round trip through the real pipes: session/set_config_option's result
    // carries the refreshed option list (the OpenCode behavior, verified live), which
    // must surface as .configOptionsChanged. (In this sequence the setter is the third
    // request, so the fake agent's hardcoded response id 3 matches.)
    func testSetConfigOptionAgainstFakeAgent() async throws {
        let scriptURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("actionui-chat-fake-acp-agent-\(UUID().uuidString).sh")
        try Self.fakeAgentScript.write(to: scriptURL, atomically: true, encoding: .utf8)
        defer {
            try? FileManager.default.removeItem(at: scriptURL)
        }

        let transport = try ACPChatTransport(
            config: ChatTransportConfig(settings: ["command": ["/bin/sh", scriptURL.path], "cwd": "~"]),
            logger: ACPTestLogger()
        )
        await transport.start()
        await transport.send(.setConfigOption(optionID: "mode", value: "plan"))

        var confirmed: [SessionConfigOption] = []
        for await event in transport.events {
            if case .configOptionsChanged(let options) = event {
                confirmed = options
                break
            }
            if case .error(let message, _) = event {
                XCTFail("unexpected error: \(message)")
                break
            }
        }
        await transport.stop()

        XCTAssertEqual(confirmed.first(where: { $0.id == "mode" })?.currentValue, "plan")
    }
}

#endif
