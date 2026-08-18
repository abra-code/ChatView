// Tests/ChatViewTests/FixtureEmitterTests.swift
//
// A1 (Android port, cross-platform fixtures). Two responsibilities, both living here so the
// event codec, the scenario table, and the transcript-wrapping rule are defined once:
//
//   1. FixtureEmitterTests.testEmitFixtures - gated on the environment variable
//      CHAT_EMIT_FIXTURES=1. It WRITES the tracked `Fixtures/` goldens: the transcript
//      goldens (transcript-v1-minimal / transcript-v2-people / transcript-v2-group /
//      transcript-mixed-agentic) and, for each routing scenario, a `scenario-N.events.jsonl`
//      event stream paired with its `scenario-N.expected.json` final transcript. The people /
//      group goldens are produced by driving a real ChatStore through the real LocalP2PTransport
//      at stepMs 0 (deterministic), then serializing. Everything is encoded with sorted keys.
//
//   2. FixtureReplayTests - always runs (no env gate). It reads the committed `Fixtures/`
//      from disk, decodes each `scenario-N.events.jsonl` with the SAME test-only event codec,
//      routes the decoded stream through a fresh live ChatStore, and asserts the resulting
//      transcript is byte-identical (sorted-keys canonical) to `scenario-N.expected.json`. This
//      proves the emitter's expected states match a live ChatStore run (A1 acceptance) and is
//      the exact guardrail the Kotlin A5 replay mirrors. It also round-trips every transcript
//      golden (decode -> re-encode -> decode) as the Swift side of the section-8 interop gate.
//
// The event-stream envelope schema is a CONTRACT documented in Fixtures/README.md; the Kotlin
// decoder is written against that README, not against this file. Keep the two in lockstep.

import XCTest
import CoreGraphics
import Combine
@testable import ChatView

// MARK: - Shared support

private final class FixtureLogger: ChatLogger {
    func log(_ message: String, _ level: ChatLogLevel) {}
}

@MainActor
private final class FixtureScheduler: ChatScheduler {
    // A frozen clock that never fires a pending callback on its own: the fixtures are routed
    // synchronously and snapshotted immediately, so no debounce / expiry / throttle must run.
    private(set) var now = Date(timeIntervalSince1970: 1_000_000)
    func schedule(_ key: String, after delay: TimeInterval, _ body: @escaping @MainActor () -> Void) {}
    func cancel(_ key: String) {}
}

private enum FixtureError: Error { case unsupportedEvent(String), malformed(String) }

/// Absolute path to the tracked `Fixtures/` directory (repo root), derived from this file's
/// location: Tests/ChatViewTests/FixtureEmitterTests.swift -> ../../Fixtures.
private func fixturesDirectory() -> URL {
    URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()   // ChatViewTests
        .deletingLastPathComponent()   // Tests
        .deletingLastPathComponent()   // repo root
        .appendingPathComponent("Fixtures", isDirectory: true)
}

/// Compact, sorted-keys canonical JSON for a Foundation JSON value (dict / array).
private func canonicalData(_ jsonObject: Any) throws -> Data {
    try JSONSerialization.data(withJSONObject: jsonObject, options: [.sortedKeys, .withoutEscapingSlashes])
}

private func canonicalString(_ jsonObject: Any) throws -> String {
    String(decoding: try canonicalData(jsonObject), as: UTF8.self)
}

/// A Codable model -> Foundation JSON value, using the model's OWN codec so nested objects
/// carry the exact model JSON vocabulary (message keys, file keys, ...).
private func jsonValue<T: Encodable>(_ value: T) throws -> Any {
    try JSONSerialization.jsonObject(with: JSONEncoder().encode(value), options: [.fragmentsAllowed])
}

/// Foundation JSON value -> a Codable model (the inverse of `jsonValue`).
private func decodeModel<T: Decodable>(_ type: T.Type, from any: Any) throws -> T {
    try JSONDecoder().decode(type, from: JSONSerialization.data(withJSONObject: any, options: [.fragmentsAllowed]))
}

// MARK: - Test-only ChatEvent codec (the fixture envelope contract; see Fixtures/README.md)

private enum EventCodec {

    static func encode(_ event: ChatEvent) throws -> [String: Any] {
        switch event {
        case .messageStart(let itemID, let role):
            return ["event": "messageStart", "itemID": itemID, "role": role.rawValue]
        case .messageDelta(let itemID, let text):
            return ["event": "messageDelta", "itemID": itemID, "text": text]
        case .messageEnd(let itemID, let stopReason):
            var d: [String: Any] = ["event": "messageEnd", "itemID": itemID]
            if let stopReason { d["stopReason"] = stopReason }
            return d
        case .thoughtDelta(let itemID, let text):
            return ["event": "thoughtDelta", "itemID": itemID, "text": text]
        case .toolCall(let call):
            return ["event": "toolCall", "toolCall": try jsonValue(call)]
        case .toolCallUpdate(let u):
            var t: [String: Any] = ["id": u.id]
            if let v = u.title { t["title"] = v }
            if let v = u.kind { t["kind"] = v.rawValue }
            if let v = u.status { t["status"] = v.rawValue }
            if let v = u.contentText { t["contentText"] = v }
            if let v = u.diff { t["diff"] = try jsonValue(v) }
            if let v = u.rawInput { t["rawInput"] = v }
            if let v = u.rawOutput { t["rawOutput"] = v }
            return ["event": "toolCallUpdate", "update": t]
        case .permissionRequest(let r):
            var req: [String: Any] = [
                "id": r.id, "title": r.title,
                "options": r.options.map { ["id": $0.id, "name": $0.name, "kind": $0.kind.rawValue] },
            ]
            if let toolCallID = r.toolCallID { req["toolCallID"] = toolCallID }
            return ["event": "permissionRequest", "request": req]
        case .permissionResolved(let requestID):
            return ["event": "permissionResolved", "requestID": requestID]
        case .resumeCheckpoint(let sessionID, let afterSeq):
            return ["event": "resumeCheckpoint", "sessionID": sessionID, "afterSeq": afterSeq]
        case .plan(let entries):
            return ["event": "plan", "plan": try jsonValue(entries)]
        case .usage(let info):
            return ["event": "usage", "usage": try jsonValue(info)]
        case .error(let message, let recoverable):
            return ["event": "error", "message": message, "recoverable": recoverable]
        case .system(let text):
            return ["event": "system", "text": text]
        case .image(let itemID, let role, let image):
            return ["event": "image", "itemID": itemID, "role": role.rawValue, "image": try jsonValue(image)]

        case .messageReceived(let message):
            return ["event": "messageReceived", "message": try jsonValue(message)]
        case .messageIDConfirmed(let localID, let serverID):
            return ["event": "messageIDConfirmed", "localID": localID, "serverID": serverID]
        case .messageStatusChanged(let itemID, let status):
            return ["event": "messageStatusChanged", "itemID": itemID, "status": status.rawValue]
        case .messageStatusWatermark(let status, let upToItemID):
            return ["event": "messageStatusWatermark", "status": status.rawValue, "upToItemID": upToItemID]
        case .reactionsChanged(let itemID, let reactions):
            return ["event": "reactionsChanged", "itemID": itemID, "reactions": try jsonValue(reactions)]
        case .messageEdited(let itemID, let newText, let editedAt):
            return ["event": "messageEdited", "itemID": itemID, "newText": newText, "editedAt": editedAt]
        case .messageDeleted(let itemID):
            return ["event": "messageDeleted", "itemID": itemID]
        case .memberEvent(let e):
            return ["event": "memberEvent", "memberEvent": try jsonValue(e)]
        case .callEvent(let e):
            return ["event": "callEvent", "callEvent": try jsonValue(e)]
        case .fileAdded(let f):
            return ["event": "fileAdded", "file": try jsonValue(f)]
        case .fileProgress(let itemID, let progress, let transferStatus):
            var d: [String: Any] = ["event": "fileProgress", "itemID": itemID, "transferStatus": transferStatus.rawValue]
            if let progress { d["progress"] = progress }
            return d
        case .typingChanged(let isTyping, let senderID, let senderName):
            var d: [String: Any] = ["event": "typingChanged", "isTyping": isTyping]
            if let senderID { d["senderID"] = senderID }
            if let senderName { d["senderName"] = senderName }
            return d
        case .participantsChanged(let roster):
            return ["event": "participantsChanged", "participants": try jsonValue(roster)]
        case .historyPage(let items, let hasMore):
            return ["event": "historyPage", "items": try jsonValue(items), "hasMore": hasMore]
        case .connectionStateChanged(let state):
            return ["event": "connectionStateChanged", "state": state.rawValue]

        // Not represented in fixtures (carry option/command vocabularies or session identity,
        // none of which belong in a transcript; their transient store effects are covered by
        // the ported store unit tests). The switch stays exhaustive on purpose: every new
        // ChatEvent must be decided about here rather than swallowed by a `default:`.
        case .sessionReady, .sessionInfo, .currentModeChanged, .commandsAvailable, .configOptionsChanged,
             .sessionEvent:
            throw FixtureError.unsupportedEvent("\(event)")
        }
    }

    static func decode(_ dict: [String: Any]) throws -> ChatEvent {
        guard let name = dict["event"] as? String else {
            throw FixtureError.malformed("missing 'event'")
        }
        func str(_ key: String) throws -> String {
            guard let v = dict[key] as? String else { throw FixtureError.malformed("\(name).\(key)") }
            return v
        }
        func role(_ key: String) throws -> ChatRole {
            guard let r = ChatRole(rawValue: try str(key)) else { throw FixtureError.malformed("\(name).\(key) role") }
            return r
        }
        func sub(_ key: String) throws -> Any {
            guard let v = dict[key] else { throw FixtureError.malformed("\(name).\(key)") }
            return v
        }

        switch name {
        case "messageStart":
            return .messageStart(itemID: try str("itemID"), role: try role("role"))
        case "messageDelta":
            return .messageDelta(itemID: try str("itemID"), text: try str("text"))
        case "messageEnd":
            return .messageEnd(itemID: try str("itemID"), stopReason: dict["stopReason"] as? String)
        case "thoughtDelta":
            return .thoughtDelta(itemID: try str("itemID"), text: try str("text"))
        case "toolCall":
            return .toolCall(try decodeModel(ToolCallModel.self, from: try sub("toolCall")))
        case "toolCallUpdate":
            guard let t = dict["update"] as? [String: Any], let id = t["id"] as? String else {
                throw FixtureError.malformed("toolCallUpdate.update")
            }
            return .toolCallUpdate(ToolCallUpdate(
                id: id,
                title: t["title"] as? String,
                kind: (t["kind"] as? String).flatMap(ToolCallModel.Kind.init(rawValue:)),
                status: (t["status"] as? String).flatMap(ToolCallModel.Status.init(rawValue:)),
                contentText: t["contentText"] as? String,
                diff: try (t["diff"]).map { try decodeModel(ToolCallDiff.self, from: $0) },
                rawInput: t["rawInput"] as? String,
                rawOutput: t["rawOutput"] as? String))
        case "permissionResolved":
            guard let requestID = dict["requestID"] as? String else {
                throw FixtureError.malformed("permissionResolved.requestID")
            }
            return .permissionResolved(requestID: requestID)
        case "resumeCheckpoint":
            guard let sessionID = dict["sessionID"] as? String,
                  let afterSeq = dict["afterSeq"] as? Int else {
                throw FixtureError.malformed("resumeCheckpoint")
            }
            return .resumeCheckpoint(sessionID: sessionID, afterSeq: afterSeq)
        case "permissionRequest":
            guard let r = dict["request"] as? [String: Any],
                  let id = r["id"] as? String, let title = r["title"] as? String,
                  let rawOptions = r["options"] as? [[String: Any]] else {
                throw FixtureError.malformed("permissionRequest.request")
            }
            let options = try rawOptions.map { o -> PermissionRequest.Option in
                guard let oid = o["id"] as? String, let name = o["name"] as? String,
                      let kind = (o["kind"] as? String).flatMap(PermissionRequest.Option.Kind.init(rawValue:)) else {
                    throw FixtureError.malformed("permissionRequest.option")
                }
                return PermissionRequest.Option(id: oid, name: name, kind: kind)
            }
            return .permissionRequest(PermissionRequest(id: id, toolCallID: r["toolCallID"] as? String,
                                                        title: title, options: options))
        case "plan":
            return .plan(try decodeModel([PlanEntry].self, from: try sub("plan")))
        case "usage":
            return .usage(try decodeModel(UsageInfo.self, from: try sub("usage")))
        case "error":
            return .error(message: try str("message"), recoverable: (dict["recoverable"] as? Bool) ?? false)
        case "system":
            return .system(text: try str("text"))
        case "image":
            return .image(itemID: try str("itemID"), role: try role("role"),
                          image: try decodeModel(ChatImage.self, from: try sub("image")))

        case "messageReceived":
            return .messageReceived(try decodeModel(ChatMessage.self, from: try sub("message")))
        case "messageIDConfirmed":
            return .messageIDConfirmed(localID: try str("localID"), serverID: try str("serverID"))
        case "messageStatusChanged":
            guard let s = MessageStatus(rawValue: try str("status")) else { throw FixtureError.malformed("status") }
            return .messageStatusChanged(itemID: try str("itemID"), status: s)
        case "messageStatusWatermark":
            guard let s = MessageStatus(rawValue: try str("status")) else { throw FixtureError.malformed("status") }
            return .messageStatusWatermark(status: s, upToItemID: try str("upToItemID"))
        case "reactionsChanged":
            return .reactionsChanged(itemID: try str("itemID"),
                                     reactions: try decodeModel([Reaction].self, from: try sub("reactions")))
        case "messageEdited":
            return .messageEdited(itemID: try str("itemID"), newText: try str("newText"), editedAt: try str("editedAt"))
        case "messageDeleted":
            return .messageDeleted(itemID: try str("itemID"))
        case "memberEvent":
            return .memberEvent(try decodeModel(MemberEvent.self, from: try sub("memberEvent")))
        case "callEvent":
            return .callEvent(try decodeModel(CallEvent.self, from: try sub("callEvent")))
        case "fileAdded":
            return .fileAdded(try decodeModel(ChatFile.self, from: try sub("file")))
        case "fileProgress":
            guard let ts = FileTransferStatus(rawValue: try str("transferStatus")) else {
                throw FixtureError.malformed("fileProgress.transferStatus")
            }
            return .fileProgress(itemID: try str("itemID"), progress: dict["progress"] as? Double, transferStatus: ts)
        case "typingChanged":
            return .typingChanged(isTyping: (dict["isTyping"] as? Bool) ?? false,
                                  senderID: dict["senderID"] as? String, senderName: dict["senderName"] as? String)
        case "participantsChanged":
            return .participantsChanged(try decodeModel([Participant].self, from: try sub("participants")))
        case "historyPage":
            return .historyPage(items: try decodeModel([ChatItem].self, from: try sub("items")),
                                hasMore: (dict["hasMore"] as? Bool) ?? false)
        case "connectionStateChanged":
            guard let s = ChatConnectionState(rawValue: try str("state")) else { throw FixtureError.malformed("state") }
            return .connectionStateChanged(s)
        default:
            throw FixtureError.unsupportedEvent(name)
        }
    }
}

// MARK: - Scenario table (the hand-authored routing scenarios)

private struct Scenario {
    let name: String
    let version: Int
    let events: [ChatEvent]
}

private func heart() -> String { "\u{2764}" }
private func thumbsUp() -> String { "\u{1F44D}" }

@MainActor
private func allScenarios() -> [Scenario] {
    [
        // --- v1 / agentic vocabulary ---
        Scenario(name: "scenario-01-segmented-turn", version: 1, events: [
            .messageStart(itemID: "m1", role: .agent),
            .messageDelta(itemID: "m1", text: "Let me "),
            .messageDelta(itemID: "m1", text: "look."),
            .messageEnd(itemID: "m1", stopReason: nil),                 // segment close; turn continues
            .toolCall(ToolCallModel(id: "tc1", title: "Search", kind: .search, status: .pending, contentText: "")),
            .toolCallUpdate(ToolCallUpdate(id: "tc1", status: .completed, contentText: "found 3 results")),
            .messageStart(itemID: "m2", role: .agent),
            .messageDelta(itemID: "m2", text: "Here are the results."),
            .messageEnd(itemID: "m2", stopReason: "end_turn"),          // whole turn ends
        ]),
        Scenario(name: "scenario-02-implicit-open", version: 1, events: [
            .messageDelta(itemID: "a1", text: "Implicit "),             // no prior start -> opens an agent message
            .messageDelta(itemID: "a1", text: "open."),
            .messageEnd(itemID: "a1", stopReason: "end_turn"),
        ]),
        Scenario(name: "scenario-03-thought-close", version: 1, events: [
            .thoughtDelta(itemID: "th1", text: "Thinking "),
            .thoughtDelta(itemID: "th1", text: "hard..."),
            .toolCall(ToolCallModel(id: "tc1", title: "Read", kind: .read, status: .completed, contentText: "done")),
            .messageStart(itemID: "m1", role: .agent),                  // (thought already closed by the tool call)
            .messageDelta(itemID: "m1", text: "Answer."),
            .messageEnd(itemID: "m1", stopReason: "end_turn"),
        ]),
        Scenario(name: "scenario-04-plan-usage", version: 1, events: [
            .plan([PlanEntry(id: 0, content: "first", priority: "high", status: .completed),
                   PlanEntry(id: 1, content: "second", priority: nil, status: .inProgress)]),
            .usage(UsageInfo(used: 100, size: 8000, costAmount: 0.01, costCurrency: "USD")),
            .plan([PlanEntry(id: 0, content: "first", priority: "high", status: .completed),
                   PlanEntry(id: 1, content: "second", priority: nil, status: .completed),
                   PlanEntry(id: 2, content: "third", priority: "low", status: .pending)]),   // whole-list replace
            .usage(UsageInfo(used: 250, size: 8000, costAmount: 0.03, costCurrency: "USD")),   // latest wins
        ]),
        Scenario(name: "scenario-05-error-path", version: 1, events: [
            .messageStart(itemID: "m1", role: .agent),
            .messageDelta(itemID: "m1", text: "working"),
            .messageEnd(itemID: "m1", stopReason: nil),
            .error(message: "stream failed", recoverable: true),        // appends error-1
        ]),
        Scenario(name: "scenario-06-permission", version: 1, events: [
            .toolCall(ToolCallModel(id: "tc1", title: "Delete file", kind: .delete, status: .pending, contentText: "")),
            .permissionRequest(PermissionRequest(id: "perm1", toolCallID: "tc1", title: "Allow delete?", options: [
                PermissionRequest.Option(id: "o1", name: "Allow", kind: .allowOnce),
                PermissionRequest.Option(id: "o2", name: "Reject", kind: .rejectOnce)])),
            .toolCallUpdate(ToolCallUpdate(id: "tc1", status: .completed, contentText: "deleted")),
            .messageStart(itemID: "m1", role: .agent),
            .messageDelta(itemID: "m1", text: "Done."),
            .messageEnd(itemID: "m1", stopReason: "end_turn"),          // clears the pending permission
        ]),

        // --- P2P (v2) vocabulary ---
        Scenario(name: "scenario-07-received-upsert", version: 2, events: [
            .messageReceived(ChatMessage(id: "r1", role: .remote, text: "Hello", isStreaming: false,
                                         senderID: "alex", senderName: "Alex", timestamp: "2026-07-10T15:00:00Z")),
            .messageReceived(ChatMessage(id: "r1", role: .remote, text: "Hello (edited by upsert)", isStreaming: false,
                                         senderID: "alex", senderName: "Alex", timestamp: "2026-07-10T15:00:00Z",
                                         reactions: [Reaction(emoji: thumbsUp(), count: 2, mine: false)])),   // same id -> replace
        ]),
        Scenario(name: "scenario-08-id-confirm-dedup", version: 2, events: [
            .messageReceived(ChatMessage(id: "local-1", role: .local, text: "ping", isStreaming: false,
                                         senderID: "me", status: .sending)),
            .messageIDConfirmed(localID: "local-1", serverID: "srv-1"),                       // re-key
            .messageReceived(ChatMessage(id: "local-2", role: .local, text: "pong", isStreaming: false,
                                         senderID: "me", status: .sending)),
            .messageReceived(ChatMessage(id: "srv-2", role: .local, text: "pong", isStreaming: false,
                                         senderID: "me", status: .sent)),                     // server's own copy
            .messageIDConfirmed(localID: "local-2", serverID: "srv-2"),                       // duplicate-drop
        ]),
        Scenario(name: "scenario-09-status-watermark", version: 2, events: [
            .messageReceived(ChatMessage(id: "o1", role: .local, text: "one", isStreaming: false, status: .sending)),
            .messageReceived(ChatMessage(id: "o2", role: .local, text: "two", isStreaming: false, status: .failed)),
            .messageReceived(ChatMessage(id: "o3", role: .local, text: "three", isStreaming: false, status: .sent)),
            .messageStatusChanged(itemID: "o1", status: .sent),                              // direct set
            .messageStatusWatermark(status: .delivered, upToItemID: "o3"),                   // o1,o3 advance; o2 failed skipped
            .messageStatusWatermark(status: .sent, upToItemID: "o3"),                        // regression attempt: no-op
        ]),
        Scenario(name: "scenario-10-reactions", version: 2, events: [
            .messageReceived(ChatMessage(id: "m1", role: .remote, text: "nice", isStreaming: false, senderID: "alex",
                                         reactions: [Reaction(emoji: thumbsUp(), count: 1, mine: false)])),
            .reactionsChanged(itemID: "m1", reactions: [Reaction(emoji: heart(), count: 2, mine: true),
                                                        Reaction(emoji: thumbsUp(), count: 1, mine: false)]),   // full replacement
        ]),
        Scenario(name: "scenario-11-edit", version: 2, events: [
            .messageReceived(ChatMessage(id: "m1", role: .remote, text: "typo heer", isStreaming: false, senderID: "alex")),
            .messageEdited(itemID: "m1", newText: "typo here", editedAt: "2026-07-10T15:05:00Z"),
        ]),
        Scenario(name: "scenario-12-delete", version: 2, events: [
            .messageReceived(ChatMessage(id: "m1", role: .remote, text: "oops secret", isStreaming: false, senderID: "alex")),
            .messageDeleted(itemID: "m1"),                                                    // tombstone: deleted + blank text
        ]),
        Scenario(name: "scenario-13-member-call", version: 2, events: [
            .memberEvent(MemberEvent(id: "ev1", timestamp: "2026-07-10T15:00:00Z", kind: .joined, subjectName: "Sam")),
            .callEvent(CallEvent(id: "call1", timestamp: "2026-07-10T15:01:00Z", kind: .completed,
                                 durationSeconds: 120, isVideo: false)),
        ]),
        Scenario(name: "scenario-14-file-progress", version: 2, events: [
            .fileAdded(ChatFile(id: "f1", role: .remote, senderID: "alex", senderName: "Alex",
                                timestamp: "2026-07-10T15:00:00Z", name: "doc.pdf", sizeBytes: 1024,
                                url: URL(string: "https://example.test/doc.pdf"), kind: .file,
                                transferStatus: .transferring, progress: 0.25)),
            .fileProgress(itemID: "f1", progress: 1.0, transferStatus: .completed),           // terminal (whole-Double progress)
        ]),
        Scenario(name: "scenario-15-typing", version: 2, events: [
            .messageReceived(ChatMessage(id: "m1", role: .remote, text: "hi", isStreaming: false,
                                         senderID: "alex", senderName: "Alex")),
            .typingChanged(isTyping: true, senderID: "alex", senderName: "Alex"),             // transient; not in the transcript
            .typingChanged(isTyping: false, senderID: "alex", senderName: "Alex"),
        ]),
        Scenario(name: "scenario-16-participants", version: 2, events: [
            .participantsChanged([Participant(id: "me", name: "You", isSelf: true),
                                  Participant(id: "alex", name: "Alex"),
                                  Participant(id: "sam", name: "Sam")]),
        ]),
        Scenario(name: "scenario-17-history-page", version: 2, events: [
            .messageReceived(ChatMessage(id: "cur1", role: .remote, text: "current", isStreaming: false,
                                         senderID: "alex", timestamp: "2026-07-10T15:00:00Z")),
            .historyPage(items: [
                .message(ChatMessage(id: "old1", role: .remote, text: "older 1", isStreaming: false,
                                     senderID: "alex", timestamp: "2026-07-09T15:00:00Z")),
                .message(ChatMessage(id: "old2", role: .local, text: "older 2", isStreaming: false,
                                     senderID: "me", timestamp: "2026-07-09T15:01:00Z")),
            ], hasMore: false),                                                               // prepended before cur1
        ]),
        Scenario(name: "scenario-18-connection", version: 2, events: [
            .connectionStateChanged(.connecting),
            .messageReceived(ChatMessage(id: "m1", role: .remote, text: "back online", isStreaming: false, senderID: "alex")),
            .connectionStateChanged(.connected),
        ]),
    ]
}

// MARK: - Transcript wrapping (identical on the emit and replay sides)

@MainActor
private func snapshotTranscript(_ store: ChatStore, version: Int) -> ChatTranscript {
    ChatTranscript(version: version, items: store.items, usage: store.usage, plan: store.plan,
                   title: store.title, participants: store.participants.isEmpty ? nil : store.participants)
}

@MainActor
private func routeScenario(_ scenario: Scenario) -> ChatStore {
    let logger = FixtureLogger()
    let store = ChatStore(config: ChatConfiguration(dictionary: [:], logger: logger),
                          logger: logger, scheduler: FixtureScheduler())
    for event in scenario.events {
        store.route(event)
    }
    return store
}

private func encoderSortedKeys() -> JSONEncoder {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    return encoder
}

// MARK: - Emitter (gated on CHAT_EMIT_FIXTURES=1)

@MainActor
final class FixtureEmitterTests: XCTestCase {

    func testEmitFixtures() async throws {
        guard ProcessInfo.processInfo.environment["CHAT_EMIT_FIXTURES"] == "1" else {
            throw XCTSkip("Set CHAT_EMIT_FIXTURES=1 to (re)write Fixtures/ goldens.")
        }
        let dir = fixturesDirectory()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let encoder = encoderSortedKeys()

        func write(_ text: String, _ name: String) throws {
            try (text + "\n").write(to: dir.appendingPathComponent(name), atomically: true, encoding: .utf8)
        }
        func writeTranscript(_ transcript: ChatTranscript, _ name: String) throws {
            try write(String(decoding: try encoder.encode(transcript), as: UTF8.self), name)
        }

        // (a) Transcript goldens.
        try writeTranscript(minimalV1Transcript(), "transcript-v1-minimal.json")
        try writeTranscript(mixedAgenticTranscript(), "transcript-mixed-agentic.json")
        try writeTranscript(try await p2pTranscript(scenario: "people"), "transcript-v2-people.json")
        try writeTranscript(try await p2pTranscript(scenario: "group"), "transcript-v2-group.json")

        // (b) Routing scenarios: a JSONL event stream + its final transcript.
        for scenario in allScenarios() {
            let lines = try scenario.events.map { try canonicalString(try EventCodec.encode($0)) }
            try write(lines.joined(separator: "\n"), "\(scenario.name).events.jsonl")
            let transcript = snapshotTranscript(routeScenario(scenario), version: scenario.version)
            try writeTranscript(transcript, "\(scenario.name).expected.json")
        }
    }

    // The v1 minimal golden matches ChatTranscriptTests.testV1JSONShapeIsPinned exactly.
    private func minimalV1Transcript() -> ChatTranscript {
        ChatTranscript(items: [.message(ChatMessage(id: "u1", role: .local, text: "Hi", isStreaming: false))])
    }

    // Every ChatItem case (incl. thought / toolCall with diff + rawInput + rawOutput), plus usage,
    // plan, participants, and title - a mixed restored transcript for the Tier-2 pass-through gate.
    private func mixedAgenticTranscript() -> ChatTranscript {
        ChatTranscript(
            version: 2,
            items: [
                .message(ChatMessage(id: "u1", role: .local, text: "Port ChatView", isStreaming: false,
                                     senderID: "me", timestamp: "2026-07-10T15:00:00Z", status: .read)),
                .thought(ChatMessage(id: "t1", role: .agent, text: "Planning the port...", isStreaming: false)),
                .toolCall(ToolCallModel(id: "tc1", title: "Edit ChatModel.kt", kind: .edit, status: .completed,
                                        contentText: "applied",
                                        diff: ToolCallDiff(path: "ChatModel.kt", oldText: "struct", newText: "data class"),
                                        rawInput: "{\"path\":\"ChatModel.kt\"}", rawOutput: "1 file changed")),
                .image(id: "i1", role: .agent,
                       image: ChatImage(url: URL(string: "https://example.test/diagram.png")!, alt: "architecture",
                                        pixelSize: CGSize(width: 800, height: 600))),
                .system(id: "s1", text: "Session started"),
                .error(id: "e1", text: "transient hiccup"),
                .memberEvent(MemberEvent(id: "mv1", timestamp: "2026-07-10T15:01:00Z", kind: .joined, subjectName: "Sam")),
                .callEvent(CallEvent(id: "cv1", timestamp: "2026-07-10T15:02:00Z", kind: .missedIncoming, isVideo: true)),
                .file(ChatFile(id: "fv1", role: .remote, senderID: "alex", senderName: "Alex",
                               timestamp: "2026-07-10T15:03:00Z", name: "notes.pdf", sizeBytes: 4096,
                               url: URL(string: "https://example.test/notes.pdf"), kind: .file,
                               transferStatus: .completed)),
            ],
            usage: UsageInfo(used: 42, size: 1000, costAmount: 0.5, costCurrency: "USD"),
            plan: [PlanEntry(id: 0, content: "step", priority: "high", status: .completed)],
            title: "Mixed Session",
            participants: [Participant(id: "me", name: "You", isSelf: true),
                           Participant(id: "alex", name: "Alex")])
    }

    // Drive a real ChatStore through the real LocalP2PTransport at stepMs 0 (deterministic seed),
    // then snapshot its transcript. Mirrors ChatStoreV2Tests' end-to-end wiring.
    private func p2pTranscript(scenario: String) async throws -> ChatTranscript {
        let proto = "local-p2p-fixture-\(scenario)"
        ChatTransportRegistry.shared.register(proto) { config, _ in LocalP2PTransport(config: config) }
        let logger = FixtureLogger()
        // The store holds contentSource weakly; keep it alive across start()+settle().
        let source = EmitterConfigSource(config: ["protocol": proto,
                                                  "transport": ["scenario": scenario, "stepMs": 0]])
        let store = ChatStore(config: ChatConfiguration(dictionary: [:], logger: logger),
                              logger: logger, contentSource: source, scheduler: FixtureScheduler())
        store.start()
        for _ in 0..<5 { await Task.yield(); try? await Task.sleep(nanoseconds: 10_000_000) }
        let transcript = snapshotTranscript(store, version: 2)
        store.teardown()
        for _ in 0..<3 { await Task.yield(); try? await Task.sleep(nanoseconds: 10_000_000) }
        withExtendedLifetime(source) {}
        return transcript
    }
}

@MainActor
private final class EmitterConfigSource: ChatContentSource {
    private let config: Any?
    init(config: Any?) { self.config = config }
    func observeChatContent(_ handler: @escaping (Any?) -> Void) -> AnyCancellable {
        handler(nil); return AnyCancellable {}
    }
    func observeChatConfig(_ handler: @escaping (Any?) -> Void) -> AnyCancellable {
        handler(config); return AnyCancellable {}
    }
}

// MARK: - Replay + interop gate (always runs)

@MainActor
final class FixtureReplayTests: XCTestCase {

    // Proves the committed scenario streams, decoded with the test codec and routed through a live
    // ChatStore, reproduce the committed expected transcripts byte-for-byte (sorted-keys canonical).
    func testScenarioReplaysMatchExpected() throws {
        let dir = fixturesDirectory()
        let streams = try FileManager.default
            .contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasSuffix(".events.jsonl") }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        XCTAssertFalse(streams.isEmpty, "no scenario fixtures found; run CHAT_EMIT_FIXTURES=1 emitter first")

        let logger = FixtureLogger()
        for streamURL in streams {
            let base = streamURL.lastPathComponent.replacingOccurrences(of: ".events.jsonl", with: "")
            let expectedURL = dir.appendingPathComponent("\(base).expected.json")

            let lines = try String(contentsOf: streamURL, encoding: .utf8)
                .split(separator: "\n", omittingEmptySubsequences: true)
            let events = try lines.map { line -> ChatEvent in
                guard let object = try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any] else {
                    throw FixtureError.malformed("not a JSON object: \(line)")
                }
                return try EventCodec.decode(object)
            }

            let expectedText = try String(contentsOf: expectedURL, encoding: .utf8)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let version = try decodeModel(ChatTranscript.self, from:
                JSONSerialization.jsonObject(with: Data(expectedText.utf8))).version

            let store = ChatStore(config: ChatConfiguration(dictionary: [:], logger: logger),
                                  logger: logger, scheduler: FixtureScheduler())
            for event in events { store.route(event) }
            let actual = String(decoding: try encoderSortedKeys().encode(snapshotTranscript(store, version: version)),
                                as: UTF8.self)

            XCTAssertEqual(actual, expectedText, "replay of \(base) diverged from its expected transcript")
        }
    }

    // The Swift side of the section-8 interop gate: every transcript golden decodes, re-encodes to the
    // SAME canonical bytes (key-spelling / omission stability), and round-trips (decode -> encode -> decode).
    func testTranscriptGoldensRoundTrip() throws {
        let dir = fixturesDirectory()
        let goldens = try FileManager.default
            .contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix("transcript-") && $0.pathExtension == "json" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        XCTAssertFalse(goldens.isEmpty, "no transcript goldens found; run CHAT_EMIT_FIXTURES=1 emitter first")

        let encoder = encoderSortedKeys()
        for goldenURL in goldens {
            let text = try String(contentsOf: goldenURL, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
            let data = Data(text.utf8)
            let decoded = try JSONDecoder().decode(ChatTranscript.self, from: data)
            let reencoded = String(decoding: try encoder.encode(decoded), as: UTF8.self)
            XCTAssertEqual(reencoded, text, "\(goldenURL.lastPathComponent) is not canonical-stable")
            let redecoded = try JSONDecoder().decode(ChatTranscript.self, from: Data(reencoded.utf8))
            XCTAssertEqual(redecoded, decoded, "\(goldenURL.lastPathComponent) round-trip changed the value")
        }
    }
}
