// Tests/ChatViewTests/ChatTranscriptTests.swift
//
// Tests for the P0-2 session-transcript seam: the transcript's Codable format (round-trip + a
// pinned JSON shape), the incremental entryActionID firing (once per finalized entry, correct
// monotonic sequence, never on deltas), restoring a transcript into states["content"] then
// appending a live turn, and the readOnly / properties.content config parsing.

import XCTest
import CoreGraphics
import Combine
@testable import ChatView

private final class HistoryTestLogger: ChatLogger {
    func log(_ message: String, _ level: ChatLogLevel) {}
}

// MARK: - Codable

final class ChatTranscriptCodableTests: XCTestCase {

    /// A representative transcript covering every ChatItem case, usage, plan, and title.
    private func sampleTranscript() -> ChatTranscript {
        ChatTranscript(
            version: 1,
            items: [
                .message(ChatMessage(id: "u1", role: .local, text: "Hello", isStreaming: false)),
                .thought(ChatMessage(id: "t1", role: .agent, text: "thinking", isStreaming: false)),
                .toolCall(ToolCallModel(id: "tc1", title: "Search", kind: .search, status: .completed,
                                        contentText: "found", diff: ToolCallDiff(path: "a.swift", oldText: "old", newText: "new"),
                                        rawInput: "{}", rawOutput: nil)),
                .image(id: "i1", role: .agent,
                       image: ChatImage(url: URL(string: "https://example.test/i.png")!, alt: "pic",
                                        pixelSize: CGSize(width: 100, height: 50))),
                .system(id: "s1", text: "system note"),
                .error(id: "e1", text: "boom"),
            ],
            usage: UsageInfo(used: 42, size: 1000, costAmount: 0.5, costCurrency: "USD"),
            plan: [PlanEntry(id: 0, content: "step", priority: "high", status: .completed)],
            title: "My Session")
    }

    func testRoundTripPreservesEverything() throws {
        let transcript = sampleTranscript()
        let data = try JSONEncoder().encode(transcript)
        let decoded = try JSONDecoder().decode(ChatTranscript.self, from: data)
        XCTAssertEqual(decoded, transcript, "encode -> decode must reproduce the transcript exactly")
    }

    // Pins the v1 JSON shape with a minimal fixture (sortedKeys makes it deterministic): the item
    // discriminator, the message keys, and the transcript keys. If any coding key drifts, this fails.
    func testV1JSONShapeIsPinned() throws {
        let transcript = ChatTranscript(items: [
            .message(ChatMessage(id: "u1", role: .local, text: "Hi", isStreaming: false)),
        ])
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let json = String(data: try encoder.encode(transcript), encoding: .utf8)
        XCTAssertEqual(json, #"{"items":[{"message":{"id":"u1","role":"local","text":"Hi"},"type":"message"}],"version":1}"#)
    }

    func testStreamingFlagIsNotSerialized() throws {
        let streaming = ChatTranscript(items: [.message(ChatMessage(id: "a", role: .agent, text: "partial", isStreaming: true))])
        let decoded = try JSONDecoder().decode(ChatTranscript.self, from: try JSONEncoder().encode(streaming))
        guard case .message(let message)? = decoded.items.first else {
            return XCTFail("expected a message")
        }
        XCTAssertFalse(message.isStreaming, "a loaded message is always final; isStreaming is not persisted")
        XCTAssertEqual(message.text, "partial", "the partial text IS captured in the snapshot")
    }

    func testImageSerializesByReferenceWithSize() throws {
        let image = ChatImage(url: URL(string: "https://example.test/p.jpg")!, alt: "a", pixelSize: CGSize(width: 480, height: 320))
        let json = String(data: try JSONEncoder().encode(image), encoding: .utf8) ?? ""
        XCTAssertTrue(json.contains("\"pixelWidth\":480"))
        XCTAssertTrue(json.contains("\"pixelHeight\":320"))
        XCTAssertFalse(json.lowercased().contains("data:"), "images serialize by URL, never pixel data")
    }

    func testDecodeToleratesMissingOptionalFields() throws {
        // A minimal v1 doc with only items still decodes (version defaults to 1, plan to []).
        let data = Data(#"{"items":[{"type":"system","id":"s","text":"hi"}]}"#.utf8)
        let decoded = try JSONDecoder().decode(ChatTranscript.self, from: data)
        XCTAssertEqual(decoded.version, 1)
        XCTAssertTrue(decoded.plan.isEmpty)
        XCTAssertNil(decoded.usage)
        XCTAssertEqual(decoded.items.count, 1)
    }
}

// MARK: - entryActionID + load

private struct CapturedEntry: Decodable {
    let sequence: Int
    let type: String
    let id: String?
}

/// Collects the JSON envelopes carried by `.entry` host events.
private final class EntrySink: @unchecked Sendable {
    private let lock = NSLock()
    private var jsons: [String] = []

    func add(_ json: String) {
        lock.withLock { jsons.append(json) }
    }

    func rawJSONs() -> [String] {
        lock.withLock { jsons }
    }

    func envelopes() -> [CapturedEntry] {
        lock.withLock { jsons }.compactMap { json in
            try? JSONDecoder().decode(CapturedEntry.self, from: Data(json.utf8))
        }
    }
}

@MainActor
final class ChatTranscriptSeamTests: XCTestCase {

    private func makeStore(properties: [String: Any] = [:], entrySink: EntrySink? = nil) -> ChatStore {
        let logger = HistoryTestLogger()
        var configuration = ChatConfiguration(dictionary: properties, logger: logger)
        configuration.emitsEntryEvents = entrySink != nil
        var hostEvents: ChatHostEventSink?
        if let entrySink {
            hostEvents = { event in
                if case .entry(let json) = event {
                    entrySink.add(json)
                }
            }
        }
        return ChatStore(config: configuration, logger: logger, hostEvents: hostEvents)
    }

    func testEntryFiresOncePerFinalizedEntryWithMonotonicSequence() {
        let sink = EntrySink()
        let store = makeStore(entrySink: sink)
        store.route(.messageStart(itemID: "a1", role: .agent))
        store.route(.messageDelta(itemID: "a1", text: "hello"))       // must NOT fire
        store.route(.messageEnd(itemID: "a1", stopReason: nil))       // fires: message
        store.route(.toolCall(ToolCallModel(id: "tool1", title: "Read", kind: .read, status: .pending, contentText: "")))  // pending: no fire
        store.route(.toolCallUpdate(ToolCallUpdate(id: "tool1", status: .completed)))  // fires: toolCall
        store.route(.usage(UsageInfo(used: 10, size: nil, costAmount: nil, costCurrency: nil)))  // fires: usage

        let envelopes = sink.envelopes()
        XCTAssertEqual(envelopes.map(\.type), ["message", "toolCall", "usage"], "only finalized items fire, in order")
        XCTAssertEqual(envelopes.map(\.sequence), [1, 2, 3], "the sequence is monotonic")
        XCTAssertEqual(envelopes[0].id, "a1")
        XCTAssertEqual(envelopes[1].id, "tool1")
    }

    func testSessionEntryEnvelopeFires() {
        // Session identity is not a transcript item: it reaches a persisting host only
        // through the entry channel (type "session"), and it publishes on the store for the
        // status surfaces. One event, one envelope.
        let sink = EntrySink()
        let store = makeStore(entrySink: sink)
        store.route(.sessionInfo(AgentSessionInfo(sessionId: "ses-42", agentName: "FakeAgent",
                                                  agentVersion: "9.9", protocolVersion: 1,
                                                  agentPid: 4242, canLoadSession: true,
                                                  canPrime: false, resumed: false)))

        XCTAssertEqual(store.sessionInfo?.sessionId, "ses-42", "the store publishes the live session identity")
        XCTAssertEqual(store.sessionInfo?.agentName, "FakeAgent")
        XCTAssertEqual(store.items.count, 0, "session identity must not append a transcript item")

        let envelopes = sink.envelopes()
        XCTAssertEqual(envelopes.map(\.type), ["session"], "exactly one session envelope fires")
        XCTAssertEqual(envelopes.first?.id, "ses-42")
        let json = sink.rawJSONs().first ?? ""
        XCTAssertTrue(json.contains("\"type\":\"session\""), "the envelope names the entry type: \(json)")
        XCTAssertTrue(json.contains("\"sessionId\":\"ses-42\""), "the payload carries the agent's session id: \(json)")
        XCTAssertTrue(json.contains("\"agentPid\":4242"), "the payload carries the agent pid for host lifecycle registries: \(json)")
    }

    func testNoEntryActionMeansNoFiring() {
        // Without entry events enabled (no sink), driving a turn must not crash / fire anything.
        let store = makeStore()
        store.route(.messageStart(itemID: "a1", role: .agent))
        store.route(.messageEnd(itemID: "a1", stopReason: "end_turn"))
        XCTAssertEqual(store.items.count, 1)
    }

    func testLoadThenAppend() {
        let store = makeStore()
        let loaded = ChatTranscript(items: [
            .message(ChatMessage(id: "old-1", role: .local, text: "prior question", isStreaming: false)),
            .message(ChatMessage(id: "old-2", role: .agent, text: "prior answer", isStreaming: false)),
        ])
        store.reconcileRestoredContent(loaded)   // simulate setElementValue

        XCTAssertEqual(store.items.count, 2, "the loaded transcript replaces the session")
        XCTAssertEqual(store.items.first?.id, "old-1")

        // A live turn appends after the loaded items.
        store.route(.messageStart(itemID: "new-1", role: .agent))
        store.route(.messageEnd(itemID: "new-1", stopReason: "end_turn"))
        XCTAssertEqual(store.items.count, 3)
        XCTAssertEqual(store.items.last?.id, "new-1")
    }

    func testDecodeTranscriptFromJSONObjectAndString() {
        let object: [String: Any] = ["version": 1, "items": [["type": "system", "id": "s1", "text": "hi"]]]
        XCTAssertEqual(ChatTranscript.decode(from: object)?.items.count, 1)
        let string = #"{"items":[{"type":"error","id":"e1","text":"boom"}]}"#
        XCTAssertEqual(ChatTranscript.decode(from: string)?.items.first?.id, "e1")
        XCTAssertNil(ChatTranscript.decode(from: 42), "an unrelated value is not a transcript")
    }
}

// MARK: - Config parsing (readOnly / content)

final class ChatTranscriptConfigTests: XCTestCase {

    func testReadOnlyParsing() {
        XCTAssertTrue(ChatConfiguration(dictionary: ["readOnly": true], logger: HistoryTestLogger()).readOnly)
        XCTAssertFalse(ChatConfiguration(dictionary: [:], logger: HistoryTestLogger()).readOnly)
    }

    func testPrePopulatedContentKeptRawForOneTimeStoreDecode() {
        let transcript: [String: Any] = [
            "version": 1,
            "items": [["type": "message", "message": ["id": "m1", "role": "agent", "text": "hi"]]],
        ]
        // The configuration keeps `content` RAW (the store decodes it once at start, not per view build).
        let configuration = ChatConfiguration(dictionary: ["content": transcript], logger: HistoryTestLogger())
        let decoded = ChatTranscript.decode(from: configuration.initialContentRaw)
        XCTAssertEqual(decoded?.items.count, 1)
        XCTAssertEqual(decoded?.items.first?.id, "m1")
    }

    func testGarbagePrePopulatedContentDecodesToNil() {
        let configuration = ChatConfiguration(dictionary: ["content": "not a transcript"], logger: HistoryTestLogger())
        XCTAssertNil(ChatTranscript.decode(from: configuration.initialContentRaw))
    }
}

// MARK: - Runtime restore through states["content"] (tested via a fake content source)

/// A fake ChatContentSource mimicking states["content"] via @Published: setting `content` delivers
/// it to observers, and a new observer receives the current value immediately (as @Published does).
@MainActor
private final class FakeContentSource: ChatContentSource {
    var content: Any? {
        didSet { contentObservers.values.forEach { $0(content) } }
    }
    var config: Any? {
        didSet { configObservers.values.forEach { $0(config) } }
    }
    private var contentObservers: [Int: (Any?) -> Void] = [:]
    private var configObservers: [Int: (Any?) -> Void] = [:]
    private var nextID = 0

    init(seed: Any? = nil, config: Any? = nil) {
        self.content = seed
        self.config = config
    }

    func observeChatContent(_ handler: @escaping (Any?) -> Void) -> AnyCancellable {
        nextID += 1
        let id = nextID
        contentObservers[id] = handler
        handler(content)   // immediate current-value delivery, like @Published
        return AnyCancellable { MainActor.assumeIsolated { self.contentObservers[id] = nil } }
    }

    func observeChatConfig(_ handler: @escaping (Any?) -> Void) -> AnyCancellable {
        nextID += 1
        let id = nextID
        configObservers[id] = handler
        handler(config)
        return AnyCancellable { MainActor.assumeIsolated { self.configObservers[id] = nil } }
    }
}

@MainActor
final class ChatContentRestoreTests: XCTestCase {

    private func makeStore(properties: [String: Any] = [:], source: FakeContentSource,
                           entrySink: EntrySink? = nil) -> ChatStore {
        let logger = HistoryTestLogger()
        var configuration = ChatConfiguration(dictionary: properties, logger: logger)
        configuration.emitsEntryEvents = entrySink != nil
        var hostEvents: ChatHostEventSink?
        if let entrySink {
            hostEvents = { event in
                if case .entry(let json) = event {
                    entrySink.add(json)
                }
            }
        }
        return ChatStore(config: configuration, logger: logger, contentSource: source,
                         hostEvents: hostEvents)
    }

    func testPrePopulatedContentLoadsAtStart() {
        let source = FakeContentSource()
        let content: [String: Any] = [
            "version": 1,
            "items": [["type": "message", "message": ["id": "seed-1", "role": "agent", "text": "seeded"]]],
        ]
        let store = makeStore(properties: ["content": content, "readOnly": true], source: source)
        store.start()
        XCTAssertEqual(store.items.count, 1, "the document properties.content pre-populates at start()")
        XCTAssertEqual(store.items.first?.id, "seed-1")
    }

    func testRestoreThroughContentReplacesSession() {
        let source = FakeContentSource()
        let store = makeStore(source: source)
        store.start()
        store.route(.messageStart(itemID: "a1", role: .agent))
        store.route(.messageEnd(itemID: "a1", stopReason: "end_turn"))
        XCTAssertEqual(store.items.count, 1)

        // Simulate a runtime setElementState("content", ChatTranscript): the source notifies the store.
        let restored = ChatTranscript(items: [.message(ChatMessage(id: "restored-1", role: .local, text: "hi", isStreaming: false))])
        source.content = restored
        XCTAssertEqual(store.items.map(\.id), ["restored-1"], "a runtime restore replaces the session")

        // A live turn appends after the restored items; a repeated identical restore is ignored (dedup).
        source.content = restored
        store.route(.messageStart(itemID: "a2", role: .agent))
        store.route(.messageEnd(itemID: "a2", stopReason: "end_turn"))
        XCTAssertEqual(store.items.map(\.id), ["restored-1", "a2"])
    }

    func testRestoreFromJSONStringAndDict() {
        // setElementStateFromString delivers a JSON string; setElementState may deliver a dict.
        let source = FakeContentSource()
        let store = makeStore(source: source)
        store.start()
        source.content = #"{"items":[{"type":"message","message":{"id":"s1","role":"agent","text":"from string"}}]}"#
        XCTAssertEqual(store.items.first?.id, "s1", "a JSON string restores")
        source.content = ["version": 1, "items": [["type": "system", "id": "d1", "text": "from dict"]]] as [String: Any]
        XCTAssertEqual(store.items.first?.id, "d1", "a JSON dict restores")
    }

    func testIdCounterAdvancesPastRestoredIdsSoNoCollision() {
        let source = FakeContentSource()
        let store = makeStore(source: source)
        store.start()
        let restored = ChatTranscript(items: [
            .message(ChatMessage(id: "user-2", role: .local, text: "q1", isStreaming: false)),
            .message(ChatMessage(id: "agent-1", role: .agent, text: "a1", isStreaming: false)),
            .message(ChatMessage(id: "user-3", role: .local, text: "q2", isStreaming: false)),
        ])
        source.content = restored
        store.send("new question")   // must NOT reuse user-1..user-3
        let ids = store.items.map(\.id)
        XCTAssertEqual(Set(ids).count, ids.count, "no duplicate ChatItem ids after restore-then-send")
        XCTAssertEqual(store.items.last?.id, "user-4")
    }

    func testReappearAfterTeardownStillObservesRestores() {
        let source = FakeContentSource()
        let store = makeStore(source: source)
        store.start()
        store.teardown()
        store.start()   // reappear: must re-subscribe and not re-run the pre-populated load

        let restored = ChatTranscript(items: [.message(ChatMessage(id: "after-reappear", role: .agent, text: "x", isStreaming: false))])
        source.content = restored
        XCTAssertEqual(store.items.first?.id, "after-reappear", "the content subscription is re-established after a teardown/appear cycle")
    }

    func testToolCallEntryReFiresSoTrailingOutputIsPersisted() {
        let sink = EntrySink()
        let source = FakeContentSource()
        let store = makeStore(source: source, entrySink: sink)
        store.start()
        // Some transports deliver the terminal status and the final output in SEPARATE updates.
        store.route(.toolCall(ToolCallModel(id: "tool1", title: "Read", kind: .read, status: .pending, contentText: "")))
        store.route(.toolCallUpdate(ToolCallUpdate(id: "tool1", status: .completed)))        // fires (no output yet)
        store.route(.toolCallUpdate(ToolCallUpdate(id: "tool1", contentText: "final output"))) // still completed: re-fires WITH output

        let toolJSONs = sink.rawJSONs().filter { $0.contains("\"toolCall\"") }
        XCTAssertGreaterThanOrEqual(toolJSONs.count, 2, "a terminal tool call re-fires on later updates")
        XCTAssertTrue(toolJSONs.last?.contains("final output") == true, "the latest entry captures the final output (upsert by id)")
        // The pending update did NOT fire an entry.
        XCTAssertEqual(sink.rawJSONs().count, 2, "only the two terminal updates fire; the pending one does not")
    }
}
