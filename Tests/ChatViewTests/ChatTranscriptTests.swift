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
    let lead: [ChatItem]?
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
    var appended: Any? {
        didSet { appendObservers.values.forEach { $0(appended) } }
    }
    var lead: Any? {
        didSet { leadObservers.values.forEach { $0(lead) } }
    }
    private var contentObservers: [Int: (Any?) -> Void] = [:]
    private var configObservers: [Int: (Any?) -> Void] = [:]
    private var appendObservers: [Int: (Any?) -> Void] = [:]
    private var leadObservers: [Int: (Any?) -> Void] = [:]
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

    func observeChatAppend(_ handler: @escaping (Any?) -> Void) -> AnyCancellable {
        nextID += 1
        let id = nextID
        appendObservers[id] = handler
        handler(appended)   // immediate current-value delivery, like the other two
        return AnyCancellable { MainActor.assumeIsolated { self.appendObservers[id] = nil } }
    }

    func observeChatLead(_ handler: @escaping (Any?) -> Void) -> AnyCancellable {
        nextID += 1
        let id = nextID
        leadObservers[id] = handler
        handler(lead)
        return AnyCancellable { MainActor.assumeIsolated { self.leadObservers[id] = nil } }
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

// MARK: - The entry a host persists must be the item it can restore

@MainActor
final class ChatSessionEventRoundTripTests: XCTestCase {

    /// A NOTICE ABOUT THE RESTORE IS NOT PART OF THE CONVERSATION. `.transientSystem` is shown
    /// like any system line and journaled by nobody: it is re-derived on every restore, so a host
    /// that persisted it would append a byte-identical copy each time and replay the whole pile
    /// on the next load. Review caught it as the "not summarized" line accumulating forever.
    func testATransientSystemLineIsShownButNeverPersisted() throws {
        let sink = EntrySink()
        let logger = HistoryTestLogger()
        var configuration = ChatConfiguration(dictionary: [:], logger: logger)
        configuration.emitsEntryEvents = true
        let store = ChatStore(config: configuration, logger: logger, hostEvents: { event in
            if case .entry(let json) = event { sink.add(json) }
        })

        store.route(.system(text: "an ordinary notice"))
        store.route(.transientSystem(text: "Not summarized - the model was idle-unloaded"))

        XCTAssertEqual(store.items.count, 2, "both are on screen")
        let entries = sink.rawJSONs()
        XCTAssertEqual(entries.count, 1, "only the ordinary one is persisted: \(entries)")
        XCTAssertTrue(entries[0].contains("an ordinary notice"), entries[0])
        XCTAssertFalse(entries[0].contains("Not summarized"), entries[0])
    }

    /// AND IT DOES NOT REPEAT ITSELF. The same restore is re-primed several times in one session -
    /// a cancelled or errored turn re-arms the context and the condense request rides in with it -
    /// so three Stops produce the same sentence three times. Once is the news; not journaling it
    /// bounds the damage to a session, and this bounds it to one line.
    func testConsecutiveIdenticalTransientLinesCollapse() throws {
        let logger = HistoryTestLogger()
        let store = ChatStore(config: ChatConfiguration(dictionary: [:], logger: logger),
                              logger: logger)
        let notice = "Not summarized - the whole conversation was sent to the model instead."

        store.route(.transientSystem(text: notice))
        store.route(.transientSystem(text: notice))
        store.route(.transientSystem(text: notice))
        XCTAssertEqual(store.items.count, 1, "three identical notices in a row are one line")

        // Only CONSECUTIVE ones collapse: the same sentence after a turn is news again, because
        // it now describes a different attempt.
        store.route(.system(text: "something else happened"))
        store.route(.transientSystem(text: notice))
        XCTAssertEqual(store.items.count, 3)
    }

    /// THE REGRESSION THIS GUARDS COST A WHOLE CONVERSATION. `.sessionEvent` was the only case that
    /// handed `fireEntry` the bare payload instead of the ChatItem, so the persisted entry had no
    /// `type` discriminator. ChatItem's decoder throws on that, ChatTranscript decodes `items` as a
    /// single array, and `ChatTranscript.decode(from:)` swallows the throw with `try?` - so the host
    /// restored nothing, silently, and the conversation could not be reopened.
    ///
    /// Asserting the entry "looks right" would not have caught it. This round-trips: persist what
    /// the element emits, restore it, and require the item back.
    func testSessionEventEntryRoundTripsThroughATranscript() throws {
        let sink = EntrySink()
        let logger = HistoryTestLogger()
        var configuration = ChatConfiguration(dictionary: [:], logger: logger)
        configuration.emitsEntryEvents = true
        let store = ChatStore(config: configuration, logger: logger, hostEvents: { event in
            if case .entry(let json) = event { sink.add(json) }
        })

        let digest = SessionDigest(summarizer: "apple-foundation-models", droppedTurns: 4,
                                   verbatimTurns: 6, unresolvedIntent: "i",
                                   establishedFacts: ["f"], decisions: ["d"], openThreads: [],
                                   userPreferences: [])
        store.route(.sessionEvent(SessionEvent(id: "c1", kind: .resumed,
                                               timestamp: "2026-08-18T21:56:33Z",
                                               model: "gemma", digest: digest)))

        let entry = try XCTUnwrap(sink.rawJSONs().last)
        let envelope = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: Data(entry.utf8)) as? [String: Any])
        let data = try XCTUnwrap(envelope["data"] as? [String: Any])

        // The half that was broken: `data` IS a ChatItem, discriminator and all.
        XCTAssertEqual(data["type"] as? String, "sessionEvent")
        XCTAssertNotNil(data["sessionEvent"], "the payload must sit under the case key")

        // The half that matters: a host that stored this can restore it.
        let restored = try XCTUnwrap(
            ChatTranscript.decode(from: ["version": 1, "items": [data]] as [String: Any]),
            "a transcript built from the emitted entry must decode - one item that does not takes "
                + "the whole conversation with it")
        XCTAssertEqual(restored.items.count, 1)
        guard let first = restored.items.first, case .sessionEvent(let event) = first else {
            return XCTFail("expected the item back as a sessionEvent")
        }
        XCTAssertEqual(event.kind, .resumed)
        XCTAssertEqual(event.model, "gemma")
        XCTAssertEqual(event.digest?.droppedTurns, 4)
    }
}

// MARK: - The append channel: one item onto a live transcript

@MainActor
final class ChatAppendChannelTests: XCTestCase {

    private func marker(_ id: String, kind: String = "resumed",
                        model: String = "Qwen3 4B") -> [String: Any] {
        ["type": "sessionEvent",
         "sessionEvent": ["id": id, "kind": kind, "model": model,
                          "timestamp": "2026-08-18T21:56:33Z"] as [String: Any]]
    }

    private func makeStore(source: FakeContentSource) -> ChatStore {
        let logger = HistoryTestLogger()
        let configuration = ChatConfiguration(dictionary: [:], logger: logger)
        let store = ChatStore(config: configuration, logger: logger, contentSource: source)
        store.start()
        return store
    }

    func testAppendAddsOneItemWithoutReplacingTheTranscript() throws {
        let source = FakeContentSource(seed: [
            "version": 1,
            "items": [["type": "message",
                       "message": ["id": "m1", "role": "local", "text": "hi"]] as [String: Any]],
        ] as [String: Any])
        let store = makeStore(source: source)
        XCTAssertEqual(store.items.count, 1)

        source.appended = marker("se-1")

        XCTAssertEqual(store.items.count, 2, "the appended item must be added, not replace")
        XCTAssertEqual(store.items.first?.id, "m1", "the conversation already shown must survive")
        guard let last = store.items.last, case .sessionEvent(let event) = last else {
            return XCTFail("expected the appended marker")
        }
        XCTAssertEqual(event.model, "Qwen3 4B")
    }

    /// The channel re-delivers its current value to a new subscriber, and a view that disappears and
    /// comes back re-subscribes. Without the dedup that is a second marker every time.
    func testReDeliveryOfTheSameItemIsIgnored() {
        let source = FakeContentSource()
        let store = makeStore(source: source)
        source.appended = marker("se-1")
        XCTAssertEqual(store.items.count, 1)
        source.appended = marker("se-1", model: "a different label")
        XCTAssertEqual(store.items.count, 1, "the same id must not append twice")
        source.appended = marker("se-2")
        XCTAssertEqual(store.items.count, 2, "a genuinely new marker still appends")
    }

    func testAppendingAnItemAlreadyInTheTranscriptIsIgnored() {
        let source = FakeContentSource(seed: [
            "version": 1,
            "items": [["type": "sessionEvent",
                       "sessionEvent": ["id": "se-1", "kind": "resumed"]] as [String: Any]],
        ] as [String: Any])
        let store = makeStore(source: source)
        XCTAssertEqual(store.items.count, 1)
        source.appended = marker("se-1")
        XCTAssertEqual(store.items.count, 1, "a restore that already carried it wins")
    }

    /// The dedup describes the items on screen. A wholesale restore replaces them, so the set stops
    /// describing anything - and left in place it outlives them forever, silently swallowing a
    /// legitimate re-announcement of the same marker into the new transcript.
    func testARestoreClearsTheDedupSoTheSameMarkerCanReturn() {
        let source = FakeContentSource()
        let store = makeStore(source: source)
        source.appended = marker("se-1")
        XCTAssertEqual(store.items.count, 1)

        source.content = [
            "version": 1,
            "items": [["type": "message",
                       "message": ["id": "m0", "role": "local", "text": "hi"]] as [String: Any]],
        ] as [String: Any]
        XCTAssertEqual(store.items.map(\.id), ["m0"], "the restore replaces what was appended")

        source.appended = marker("se-1")
        XCTAssertEqual(store.items.map(\.id), ["m0", "se-1"],
                       "the same id must be appendable again once its items are gone")
    }

    func testMalformedAppendIsIgnoredRatherThanCrashingOrClearing() {
        let source = FakeContentSource(seed: [
            "version": 1,
            "items": [["type": "message",
                       "message": ["id": "m1", "role": "local", "text": "hi"]] as [String: Any]],
        ] as [String: Any])
        let store = makeStore(source: source)
        source.appended = ["type": "notAnItemType"] as [String: Any]
        XCTAssertEqual(store.items.count, 1, "an undecodable append must leave the transcript alone")
        source.appended = "   "
        XCTAssertEqual(store.items.count, 1)
    }

}

/// The context-state half of the append channel, which needs a REAL transport: `contextState` is
/// only ever written by code paths that begin `guard let transport`. An earlier version of these
/// tests used a store with no transport and asserted the indicator was unchanged - it could not
/// have failed, because nothing in the process could write it.
@MainActor
final class ChatAppendContextStateTests: XCTestCase {

    private func primedStore() -> (ChatStore, AppendRecordingTransport, AppendConfigSource) {
        let name = "append-test-\(UUID().uuidString)"
        let box = AppendTransportBox()
        ChatTransportRegistry.shared.register(name) { _, _ in
            let t = AppendRecordingTransport()
            box.transport = t
            return t
        }
        let logger = HistoryTestLogger()
        let source = AppendConfigSource(config: ["protocol": name])
        let store = ChatStore(config: ChatConfiguration(dictionary: [:], logger: logger),
                              logger: logger, contentSource: source)
        store.start()
        return (store, box.transport!, source)
    }

    private func restoreTwoMessages(_ source: AppendConfigSource) {
        source.content = [
            "version": 1,
            "items": [["type": "message",
                       "message": ["id": "m0", "role": "local", "text": "hello"]] as [String: Any],
                      ["type": "message",
                       "message": ["id": "m1", "role": "agent", "text": "hi"]] as [String: Any]],
        ] as [String: Any]
    }

    /// The premise the whole design rests on: a marker contributes no wire entry, so the agent's
    /// context is still an accurate description of the conversation.
    func testAppendingAMarkerLeavesTheContextSynced() {
        let (store, transport, source) = primedStore()
        restoreTwoMessages(source)
        let primesBefore = transport.primeCount
        XCTAssertEqual(store.contextState, .synced)

        source.appended = ["type": "sessionEvent",
                           "sessionEvent": ["id": "se-1", "kind": "resumed",
                                            "model": "Qwen3 4B"] as [String: Any]]

        XCTAssertEqual(store.contextState, .synced,
                       "a marker adds no wire entry, so the agent still holds the conversation")
        XCTAssertEqual(transport.primeCount, primesBefore,
                       "and appending must not re-prime - that is the cost this channel avoids")
    }

    /// Appending is the fourth way an item enters the store, and the other three reserve its id.
    /// Skipping that lets an appended item collide with one the store is about to mint - and every
    /// mutation path finds items by `firstIndex`, so a collision misdirects a live turn's deltas.
    func testAppendReservesTheItemIdWithTheTransport() {
        // Bind the store: nothing else retains it (the content source holds it only through weak
        // closures), so discarding it here releases it and the append never happens.
        let (store, transport, source) = primedStore()
        restoreTwoMessages(source)
        source.appended = ["type": "sessionEvent",
                           "sessionEvent": ["id": "se-9", "kind": "resumed"] as [String: Any]]
        XCTAssertTrue(transport.reserved.contains("se-9"),
                      "the appended id must be reserved, or the transport may mint it again")
        XCTAssertEqual(store.items.count, 3)
    }

    /// The case the channel's type permits and the design must not lie about. Appending a message
    /// puts a line on screen the model was never given; if the indicator kept saying synced, the
    /// next send would not re-prime and the turn end would adopt the unsent message as held.
    func testAppendingAMessageMarksTheContextPending() {
        let (store, _, source) = primedStore()
        restoreTwoMessages(source)
        XCTAssertEqual(store.contextState, .synced)

        source.appended = ["type": "message",
                           "message": ["id": "h1", "role": "agent",
                                       "text": "never sent"] as [String: Any]]

        XCTAssertEqual(store.contextState, .pending,
                       "a message the agent was never given must not be reported as held")
    }

    /// THE CASE A HOST ACTUALLY HITS: Cadabra announces "started"/"resumed" while the FIRST turn
    /// of a conversation is streaming. `wireContext` advances only at prime, restore and turn end,
    /// so mid-turn it is stale by construction - it does not hold the message send() just
    /// appended. A whole-transcript comparison against it calls a marker a divergence, and the
    /// status line goes orange in a brand-new chat where nothing is out of sync.
    func testAppendingAMarkerDuringATurnLeavesTheContextSynced() {
        let (store, transport, source) = primedStore()
        restoreTwoMessages(source)
        XCTAssertEqual(store.contextState, .synced)

        store.send("and now?")                                   // the snapshot is stale from here
        store.route(.messageStart(itemID: "a2", role: .agent))   // the turn is streaming
        store.route(.messageDelta(itemID: "a2", text: "answering"))

        source.appended = ["type": "sessionEvent",
                           "sessionEvent": ["id": "se-1", "kind": "started",
                                            "model": "Qwen3 4B"] as [String: Any]]

        XCTAssertEqual(store.contextState, .synced,
                       "a marker moves no wire entry, whatever the mid-turn snapshot happens to hold")

        // And the cost that outlives the turn, which is the half a user notices: a pending state
        // here sends trackContextAfterTurn down its else branch, dropping the snapshot at the end
        // of the turn, so the next send re-primes the whole conversation for nothing.
        store.route(.messageEnd(itemID: "a2", stopReason: "end_turn"))
        XCTAssertEqual(store.contextState, .synced)
        let primesBefore = transport.primeCount
        store.send("still here")
        XCTAssertEqual(transport.primeCount, primesBefore,
                       "the turn grew the agent's context with the display, so nothing is re-primed")
    }

    /// The guard must not have been suppressed into uselessness: a MESSAGE the agent was never
    /// given still has to mark the context pending, mid-turn exactly as between turns.
    func testAppendingAMessageDuringATurnStillMarksTheContextPending() {
        let (store, _, source) = primedStore()
        restoreTwoMessages(source)
        store.send("and now?")
        store.route(.messageStart(itemID: "a2", role: .agent))

        source.appended = ["type": "message",
                           "message": ["id": "h1", "role": "agent",
                                       "text": "never sent"] as [String: Any]]

        XCTAssertEqual(store.contextState, .pending,
                       "a line the model never saw must not be reported as held, whenever it lands")
    }

    /// The one place a SUPPRESSED pending could in principle hide a real divergence: the turn the
    /// marker landed in never ends cleanly. It cannot, and this pins why - the suppression decides
    /// nothing about the turn, so the cancelled turn's own bookkeeping still drops the snapshot and
    /// the next send re-primes. A marker must not make a cancelled turn look clean.
    func testAMarkerDuringACancelledTurnStillLeavesTheContextPending() {
        let (store, transport, source) = primedStore()
        restoreTwoMessages(source)
        store.send("and now?")
        store.route(.messageStart(itemID: "a2", role: .agent))

        source.appended = ["type": "sessionEvent",
                           "sessionEvent": ["id": "se-2", "kind": "started"] as [String: Any]]
        XCTAssertEqual(store.contextState, .synced)

        store.route(.messageEnd(itemID: "a2", stopReason: "cancelled"))
        XCTAssertEqual(store.contextState, .pending,
                       "the agent holds a partial exchange, and no marker can make that look clean")
        let primesBefore = transport.primeCount
        store.send("again")
        XCTAssertEqual(transport.primeCount, primesBefore + 1,
                       "an unknown context must be re-primed on the next send")
    }

    /// The boundary the new question sits on. `wireEntries` admits a message only when it carries
    /// text a model would be given, so an EMPTY one is a `.message` that moves nothing - and a
    /// guard written as "is this item a message" would fire on it, marking a context stale that no
    /// transport's prime can tell apart from the one it already holds.
    func testAppendingAnEmptyMessageLeavesTheContextSynced() {
        let (store, _, source) = primedStore()
        restoreTwoMessages(source)
        XCTAssertEqual(store.contextState, .synced)

        source.appended = ["type": "message",
                           "message": ["id": "h2", "role": "agent", "text": ""] as [String: Any]]

        XCTAssertEqual(store.contextState, .synced,
                       "an empty message reaches no prime, so it cannot have moved the context")
    }

    /// The same question asked of the lead channel, where the answer matters more: this places an
    /// item DURING send(), a moment at which the whole-transcript snapshot is about to be rebuilt
    /// anyway. A marker moves no wire entry, so the agent still holds the conversation and the
    /// send must not pay a re-prime for a line the model will never see.
    func testAPlacedMarkerLeavesTheContextSynced() {
        let (store, transport, source) = primedStore()
        restoreTwoMessages(source)
        XCTAssertEqual(store.contextState, .synced)
        let primesBefore = transport.primeCount

        source.lead = ["type": "sessionEvent",
                       "sessionEvent": ["id": "se-1", "kind": "resumed",
                                        "model": "Qwen3 4B"] as [String: Any]]
        store.send("and now?")

        XCTAssertEqual(store.contextState, .synced,
                       "a marker adds no wire entry, so the agent still holds the conversation")
        XCTAssertEqual(transport.primeCount, primesBefore,
                       "and leading a message must not re-prime one that was already synced")
    }

    /// Placing is the fifth way an item enters the store, and it replays what the other four do:
    /// an id the transport does not know about is one it can mint again, and every mutation path
    /// finds items by `firstIndex`.
    func testAPlacedItemIsReservedWithTheTransport() {
        let (store, transport, source) = primedStore()
        restoreTwoMessages(source)

        source.lead = ["type": "sessionEvent",
                       "sessionEvent": ["id": "se-9", "kind": "resumed"] as [String: Any]]
        store.send("and now?")

        XCTAssertTrue(transport.reserved.contains("se-9"),
                      "the placed id must be reserved, or the transport may mint it again")
    }

    /// The case the channel's type permits and the ORDER inside send() answers. A message placed
    /// in front of the user's own is a line the agent was never given; placed before the deferred
    /// sync runs, it is part of the conversation that sync primes rather than one the model
    /// silently never sees.
    func testAPlacedMessageIsPrimedRatherThanLost() {
        let (store, transport, source) = primedStore()
        restoreTwoMessages(source)
        XCTAssertEqual(store.contextState, .synced)
        let primesBefore = transport.primeCount

        source.lead = ["type": "message",
                       "message": ["id": "h1", "role": "agent",
                                   "text": "never sent"] as [String: Any]]
        store.send("and now?")

        XCTAssertEqual(store.items.map(\.id), ["m0", "m1", "h1", "user-1"])
        XCTAssertEqual(transport.primeCount, primesBefore + 1,
                       "a line that moves the wire must reach the agent with this very send")
        XCTAssertEqual(store.contextState, .synced)
    }

    private func restoreTwoMessagesOverAnEmptyContext(_ source: AppendConfigSource) {
        source.content = [
            "version": 1,
            "prime": false,
            "items": [["type": "message",
                       "message": ["id": "m0", "role": "local", "text": "hello"]] as [String: Any],
                      ["type": "message",
                       "message": ["id": "m1", "role": "agent", "text": "hi"]] as [String: Any]],
        ] as [String: Any]
    }

    /// A "prime": false restore shows the transcript over an EMPTY context, by the user's choice,
    /// and the deferred sync never re-primes a .fresh context. A line placed from the lead channel
    /// must not turn that choice into a pending re-prime of the whole display on this very send.
    func testAPlacedMessageLeavesAFreshContextFresh() {
        let (store, transport, source) = primedStore()
        restoreTwoMessagesOverAnEmptyContext(source)
        XCTAssertEqual(store.contextState, .fresh)
        let primesBefore = transport.primeCount

        source.lead = ["type": "message",
                       "message": ["id": "h1", "role": "agent",
                                   "text": "never sent"] as [String: Any]]
        store.send("and now?")

        XCTAssertEqual(store.items.map(\.id), ["m0", "m1", "h1", "user-1"])
        XCTAssertEqual(store.contextState, .fresh, "the empty context is the user's choice")
        XCTAssertEqual(transport.primeCount, primesBefore, "and the send must not re-prime it")
    }

    /// The same rule on the append channel, which had the same hole: a line the host adds joins
    /// the displayed-but-unsent transcript rather than marking it for a prime.
    func testAnAppendedMessageLeavesAFreshContextFresh() {
        let (store, transport, source) = primedStore()
        restoreTwoMessagesOverAnEmptyContext(source)
        XCTAssertEqual(store.contextState, .fresh)
        let primesBefore = transport.primeCount

        source.appended = ["type": "message",
                           "message": ["id": "h1", "role": "agent",
                                       "text": "never sent"] as [String: Any]]

        XCTAssertEqual(store.contextState, .fresh)
        XCTAssertEqual(transport.primeCount, primesBefore)
    }
}

private final class AppendRecordingTransport: ChatTransport, @unchecked Sendable {
    let events: AsyncStream<ChatEvent>
    private let continuation: AsyncStream<ChatEvent>.Continuation
    private let lock = NSLock()
    private var _primes = 0
    private var _reserved: [String] = []
    var primeCount: Int { lock.withLock { _primes } }
    var reserved: [String] { lock.withLock { _reserved } }
    init() {
        var captured: AsyncStream<ChatEvent>.Continuation!
        self.events = AsyncStream { captured = $0 }
        self.continuation = captured
    }
    func start() async {}
    func send(_ command: ChatCommand) async {}
    func stop() async { continuation.finish() }
    func primeHistory(_ messages: [ChatMessage]) { lock.withLock { _primes += 1 } }
    func reserveIDs(seen ids: [String]) { lock.withLock { _reserved.append(contentsOf: ids) } }
}

private final class AppendTransportBox: @unchecked Sendable {
    var transport: AppendRecordingTransport?
}

/// The store holds its content source WEAKLY, so a test must keep this alive across start().
private final class AppendConfigSource: ChatContentSource {
    var content: Any? { didSet { contentObservers.values.forEach { $0(content) } } }
    var config: Any? { didSet { configObservers.values.forEach { $0(config) } } }
    var appended: Any? { didSet { appendObservers.values.forEach { $0(appended) } } }
    var lead: Any? { didSet { leadObservers.values.forEach { $0(lead) } } }
    private var contentObservers: [Int: (Any?) -> Void] = [:]
    private var configObservers: [Int: (Any?) -> Void] = [:]
    private var appendObservers: [Int: (Any?) -> Void] = [:]
    private var leadObservers: [Int: (Any?) -> Void] = [:]
    private var nextID = 0
    init(config: Any? = nil) { self.config = config }
    func observeChatContent(_ handler: @escaping (Any?) -> Void) -> AnyCancellable {
        nextID += 1; let id = nextID
        contentObservers[id] = handler; handler(content)
        return AnyCancellable { MainActor.assumeIsolated { self.contentObservers[id] = nil } }
    }
    func observeChatConfig(_ handler: @escaping (Any?) -> Void) -> AnyCancellable {
        nextID += 1; let id = nextID
        configObservers[id] = handler; handler(config)
        return AnyCancellable { MainActor.assumeIsolated { self.configObservers[id] = nil } }
    }
    func observeChatAppend(_ handler: @escaping (Any?) -> Void) -> AnyCancellable {
        nextID += 1; let id = nextID
        appendObservers[id] = handler; handler(appended)
        return AnyCancellable { MainActor.assumeIsolated { self.appendObservers[id] = nil } }
    }
    func observeChatLead(_ handler: @escaping (Any?) -> Void) -> AnyCancellable {
        nextID += 1; let id = nextID
        leadObservers[id] = handler; handler(lead)
        return AnyCancellable { MainActor.assumeIsolated { self.leadObservers[id] = nil } }
    }
}

// MARK: - The lead channel: a line held until there is a message for it to lead

@MainActor
final class ChatLeadChannelTests: XCTestCase {

    private func marker(_ id: String, kind: String = "resumed", model: String = "Qwen3 4B",
                        timestamp: String? = "2026-08-21T04:30:00Z") -> [String: Any] {
        var event: [String: Any] = ["id": id, "kind": kind, "model": model]
        if let timestamp { event["timestamp"] = timestamp }
        return ["type": "sessionEvent", "sessionEvent": event]
    }

    private func markerJSON(_ id: String, kind: String = "resumed", model: String = "Qwen3 4B",
                            timestamp: String? = "2026-08-21T04:30:00Z") -> String {
        let data = try! JSONSerialization.data(withJSONObject: marker(id, kind: kind, model: model,
                                                                      timestamp: timestamp))
        return String(data: data, encoding: .utf8)!
    }

    /// The moment the tests pin the store's clock to, and its wire form.
    private let sendMoment = "2026-08-21T06:55:12Z"

    private func placedSessionEvent(_ store: ChatStore, at index: Int = 0) -> SessionEvent? {
        guard store.items.indices.contains(index),
              case .sessionEvent(let event) = store.items[index] else { return nil }
        return event
    }

    private func makeStore(source: FakeContentSource, entrySink: EntrySink? = nil) -> ChatStore {
        let logger = HistoryTestLogger()
        var configuration = ChatConfiguration(dictionary: [:], logger: logger)
        configuration.emitsEntryEvents = entrySink != nil
        var hostEvents: ChatHostEventSink?
        if let entrySink {
            hostEvents = { event in
                if case .entry(let json) = event { entrySink.add(json) }
            }
        }
        let store = ChatStore(config: configuration, logger: logger, contentSource: source,
                              hostEvents: hostEvents)
        store.start()
        return store
    }

    /// THE BUG THIS CHANNEL EXISTS FOR, first half: a conversation the user opened and read is not
    /// a conversation resumed, so nothing may appear on the strength of the display alone.
    func testAWaitingItemIsNotShownUntilAMessageIsSent() {
        let source = FakeContentSource(seed: [
            "version": 1,
            "items": [["type": "message",
                       "message": ["id": "m1", "role": "local", "text": "hi"]] as [String: Any]],
        ] as [String: Any])
        let store = makeStore(source: source)

        source.lead = markerJSON("se-1")

        XCTAssertEqual(store.items.count, 1, "holding a line must not put it on screen")
        XCTAssertEqual(store.items.first?.id, "m1")
    }

    /// The other half: when the message does arrive, the held line is IN FRONT of it - which the
    /// append channel cannot do, because by then the message is already on screen.
    func testTheWaitingItemLeadsTheMessageItOpens() {
        let source = FakeContentSource()
        let store = makeStore(source: source)
        source.lead = markerJSON("se-1")

        store.send("what changed?")

        XCTAssertEqual(store.items.map(\.id), ["se-1", "user-1"],
                       "the marker must lead the message it introduces, not follow it")
        guard case .sessionEvent(let event) = store.items[0] else {
            return XCTFail("expected the held marker first")
        }
        XCTAssertEqual(event.model, "Qwen3 4B")
    }

    /// The host is describing an item it already holds, as on the content and append channels, so
    /// placing it fires no entry OF ITS OWN - a host would write it twice. What the host cannot
    /// know from its own copy is that the line was placed at all, and that is the message's entry
    /// to say: it names what led it.
    func testPlacingAHeldItemFiresNoEntryOfItsOwnAndTheMessageReportsIt() {
        let sink = EntrySink()
        let source = FakeContentSource()
        let store = makeStore(source: source, entrySink: sink)
        source.lead = markerJSON("se-1")

        store.send("what changed?")

        let envelopes = sink.envelopes()
        XCTAssertEqual(envelopes.map(\.id), ["user-1"],
                       "only the message is a finalized entry; the marker is not")
        XCTAssertEqual(envelopes.first?.lead?.map(\.id), ["se-1"],
                       "the message's entry carries the line that led it")
    }

    /// THE TIME ON THE LINE IS THE TIME OF THE MESSAGE IT LEADS. The host hands the line over when
    /// it learns it will be needed - the conversation displayed, the engine loaded - and the user
    /// may not type for an hour; a stamp from then would put "Resumed at 2:55" over a message sent
    /// at 3:55. So a line handed over without a time is stamped here, at the send.
    func testAnItemHeldWithoutATimeIsStampedWhenItIsPlaced() {
        let source = FakeContentSource()
        let store = makeStore(source: source)
        store.now = { ChatTimestamp.parse(self.sendMoment)! }
        source.lead = markerJSON("se-1", timestamp: nil)

        store.send("what changed?")

        XCTAssertEqual(placedSessionEvent(store)?.timestamp, sendMoment,
                       "an unstamped line takes the moment it was placed")
    }

    /// The rule is about the field being empty, not about who owns it: a host that stamped its
    /// line meant that time, and the store must not overwrite it with its own.
    func testAnItemHeldWithATimeKeepsIt() {
        let source = FakeContentSource()
        let store = makeStore(source: source)
        store.now = { ChatTimestamp.parse(self.sendMoment)! }
        source.lead = markerJSON("se-1", timestamp: "2026-08-21T04:30:00Z")

        store.send("what changed?")

        XCTAssertEqual(placedSessionEvent(store)?.timestamp, "2026-08-21T04:30:00Z",
                       "a host's own stamp is not replaced")
    }

    /// The half the host persists from. The entry carries the line AS PLACED - with the stamp the
    /// store put on it - because the host's copy does not have that time and cannot reconstruct
    /// it: the whole reason the store stamps is that the host was not there when it happened.
    func testTheMessageEntryCarriesTheLineAsPlaced() {
        let sink = EntrySink()
        let source = FakeContentSource()
        let store = makeStore(source: source, entrySink: sink)
        store.now = { ChatTimestamp.parse(self.sendMoment)! }
        source.lead = markerJSON("se-1", timestamp: nil)

        store.send("what changed?")

        let envelope = sink.envelopes().first
        XCTAssertEqual(envelope?.type, "message")
        guard case .sessionEvent(let reported)? = envelope?.lead?.first else {
            return XCTFail("expected the placed marker in the message's entry: \(sink.rawJSONs())")
        }
        XCTAssertEqual(reported.id, "se-1")
        XCTAssertEqual(reported.timestamp, sendMoment, "reported as placed, stamp included")
        XCTAssertEqual(reported.model, "Qwen3 4B")
        // The raw spelling, because a host reading the envelope in a shell pre-filters on it
        // before parsing: the key is named exactly "lead", unspaced, holding an array.
        XCTAssertTrue(sink.rawJSONs()[0].contains("\"lead\":["), sink.rawJSONs()[0])
    }

    /// Every other message is persisted byte-for-byte as before: a message nothing led carries no
    /// `lead` key at all, not an empty one.
    func testAMessageNothingLedCarriesNoLeadKey() {
        let sink = EntrySink()
        let source = FakeContentSource()
        let store = makeStore(source: source, entrySink: sink)

        store.send("hello")

        let raw = sink.rawJSONs()
        XCTAssertEqual(raw.count, 1)
        XCTAssertFalse(raw[0].contains("\"lead\""), "no lead key on an unled message: \(raw[0])")
    }

    /// Lines placed in front of one message share its moment - two stamps a few microseconds
    /// apart would be two different times for one event.
    func testLinesPlacedTogetherShareOneStamp() {
        let source = FakeContentSource()
        let store = makeStore(source: source)
        store.now = { ChatTimestamp.parse(self.sendMoment)! }
        source.lead = markerJSON("se-1", timestamp: nil) + "\n"
            + markerJSON("se-2", kind: "modelChanged", model: "Llama 3.1 8B", timestamp: nil)

        store.send("go on")

        XCTAssertEqual(placedSessionEvent(store, at: 0)?.timestamp, sendMoment)
        XCTAssertEqual(placedSessionEvent(store, at: 1)?.timestamp, sendMoment)
    }

    /// The stamping is not a session-marker special case: any held kind that has a timestamp to
    /// carry and arrived without one takes the moment it was placed. A message is the kind a
    /// host would most plausibly hand over next.
    func testAHeldMessageWithoutATimeIsStampedToo() {
        let source = FakeContentSource()
        let store = makeStore(source: source)
        store.now = { ChatTimestamp.parse(self.sendMoment)! }
        source.lead = "{\"type\":\"message\",\"message\":{\"id\":\"pre-1\",\"role\":\"agent\",\"text\":\"Welcome back.\"}}"

        store.send("thanks")

        guard case .message(let placed)? = store.items.first else {
            return XCTFail("expected the held message first: \(store.items.map(\.id))")
        }
        XCTAssertEqual(placed.id, "pre-1")
        XCTAssertEqual(placed.timestamp, sendMoment)
    }

    /// The value is the whole waiting list, so a host that shows a second marker before the first
    /// has been placed writes both lines - and gets both, in the order it wrote them.
    func testTheChannelCarriesTheWholeWaitingList() {
        let source = FakeContentSource()
        let store = makeStore(source: source)
        source.lead = markerJSON("se-1")
        source.lead = markerJSON("se-1") + "\n" + markerJSON("se-2", kind: "modelChanged",
                                                             model: "Llama 3.1 8B")

        store.send("go on")

        XCTAssertEqual(store.items.map(\.id), ["se-1", "se-2", "user-1"],
                       "both held lines lead the message, in the order the host showed them")
    }

    /// How a host takes a line back: the conversation it was minted for was replaced, so the line
    /// must never appear. An empty value CLEARS rather than being ignored the way an empty
    /// restore is - there is nothing else it could mean.
    func testAnEmptyValueTakesTheWaitingItemBack() {
        let source = FakeContentSource()
        let store = makeStore(source: source)
        source.lead = markerJSON("se-1")
        source.lead = ""

        store.send("hello")

        XCTAssertEqual(store.items.map(\.id), ["user-1"], "a withdrawn line must not be placed")
    }

    /// The hazard the append channel parks itself empty to avoid, which this channel cannot do -
    /// it rests holding what it is waiting to place. The host bridge republishes every channel on
    /// any state change, so the value that was just consumed comes back; placed twice, the second
    /// message would be introduced by a marker already sitting above the first.
    func testARedeliveryAfterTheSendDoesNotPlaceTheItemAgain() {
        let source = FakeContentSource()
        let store = makeStore(source: source)
        source.lead = markerJSON("se-1")
        store.send("first")

        source.lead = markerJSON("se-1")     // the host has not parked the channel yet
        store.send("second")

        XCTAssertEqual(store.items.map(\.id), ["se-1", "user-1", "user-2"],
                       "a line already placed must not lead a second message")
    }

    /// The Summarize re-inject: the display is replaced with the SAME conversation, and the
    /// marker waiting for its first message is still waiting afterwards. The store must not
    /// mistake a restore for the host withdrawing it.
    func testARestoreLeavesTheWaitingItemWaiting() {
        let source = FakeContentSource()
        let store = makeStore(source: source)
        source.lead = markerJSON("se-1")

        source.content = [
            "version": 1,
            "items": [["type": "message",
                       "message": ["id": "m1", "role": "local", "text": "hi"]] as [String: Any]],
        ] as [String: Any]
        store.send("and now?")

        XCTAssertEqual(store.items.map(\.id), ["m1", "se-1", "user-1"],
                       "the held marker still leads the first message after a re-inject")
    }

    /// A restore that carries the marker itself wins: the line is in the transcript, and placing
    /// the channel's copy would show it twice.
    func testAnItemAlreadyInTheTranscriptIsNotPlaced() {
        let source = FakeContentSource(seed: [
            "version": 1,
            "items": [["type": "sessionEvent",
                       "sessionEvent": ["id": "se-1", "kind": "resumed"]] as [String: Any]],
        ] as [String: Any])
        let store = makeStore(source: source)
        source.lead = markerJSON("se-1")

        store.send("hello")

        XCTAssertEqual(store.items.map(\.id), ["se-1", "user-1"], "no second copy of the marker")
    }

    /// A value with NOTHING readable in it is not a statement about the list, so it must not
    /// replace one. Withdrawing is what an empty value means, and a host that meant to withdraw
    /// has a way to say so - reading garbage as "withdraw" loses the line and reports nothing.
    func testAValueWithNothingReadableInItDoesNotWithdraw() {
        let source = FakeContentSource()
        let store = makeStore(source: source)
        source.lead = markerJSON("se-1")
        source.lead = "{\"type\": \"nonsense\"}"

        store.send("hello")

        XCTAssertEqual(store.items.map(\.id), ["se-1", "user-1"],
                       "the line already waiting must survive an unreadable write")
    }

    /// The withdrawal a host with a structural bridge would write. An empty ARRAY carries no
    /// items and says so - it must not be confused with a value that could not be read, which is
    /// the case above and keeps what is waiting.
    func testAnEmptyListAlsoWithdraws() {
        let source = FakeContentSource()
        let store = makeStore(source: source)
        source.lead = [marker("se-1")]
        source.lead = [] as [Any]

        store.send("hello")

        XCTAssertEqual(store.items.map(\.id), ["user-1"], "an empty list is a withdrawal")
    }

    /// Bytes that are not text are not a list either. Read as an empty one - which is what
    /// `String(data:encoding:)` failing used to produce - they would withdraw silently.
    func testBytesThatAreNotTextDoNotWithdraw() {
        let source = FakeContentSource()
        let store = makeStore(source: source)
        source.lead = markerJSON("se-1")
        source.lead = Data([0xFF, 0xFE, 0xFF])

        store.send("hello")

        XCTAssertEqual(store.items.map(\.id), ["se-1", "user-1"],
                       "undecodable bytes must not be obeyed as a withdrawal")
    }

    /// The view disappeared, so the store stopped listening - on this channel as on the other
    /// three. A sink left running past teardown is not a leak here, but it is the shape that
    /// becomes a duplicate subscription the first time the resubscribe guard is restructured.
    func testTeardownStopsListeningToTheChannel() {
        let source = FakeContentSource()
        let store = makeStore(source: source)
        store.teardown()

        source.lead = markerJSON("se-1")
        store.send("hello")

        XCTAssertEqual(store.items.map(\.id), ["user-1"],
                       "a torn-down store must not take anything from the channel")
    }

    /// One line that will not decode costs that line and nothing else - the same trade the
    /// transcript decoder makes item by item. The alternative is a message introduced by nothing
    /// because the value it travelled with had a stray character in it.
    func testALineThatWillNotDecodeCostsOnlyThatLine() {
        let source = FakeContentSource()
        let store = makeStore(source: source)
        source.lead = "{\"type\": \"nonsense\"}\n" + markerJSON("se-2")

        store.send("hello")

        XCTAssertEqual(store.items.map(\.id), ["se-2", "user-1"],
                       "the readable line still leads the message")
    }
}

// MARK: - One unreadable item must cost one line, not the conversation

@MainActor
final class ChatTranscriptLossyDecodeTests: XCTestCase {

    /// `[Any]`, not `[[String: Any]]`: a bad element is not always an object, and "does the array
    /// still advance" is a real question for a bare string, a number, or null.
    private func transcript(_ items: [Any]) -> ChatTranscript? {
        ChatTranscript.decode(from: ["version": 1, "items": items] as [String: Any])
    }

    private let good: [String: Any] =
        ["type": "message", "message": ["id": "m0", "role": "local", "text": "hello"]]
    private let alsoGood: [String: Any] =
        ["type": "message", "message": ["id": "m1", "role": "agent", "text": "hi"]]

    /// THE EXACT SHAPE THAT COST A USER A CONVERSATION: ChatView's own condense marker, written
    /// with the payload at the top level and no `type` discriminator. One of these used to fail the
    /// whole transcript, and `decode(from:)` swallowed the throw, so the restore did nothing at all.
    func testTheItemThatUsedToDestroyAConversationNowCostsOneLine() throws {
        let bare: [String: Any] = ["id": "condense-1", "kind": "resumed",
                                   "timestamp": "2026-08-18T21:56:33Z"]
        let restored = try XCTUnwrap(transcript([good, bare, alsoGood]),
                                     "the transcript must decode, not vanish")
        XCTAssertEqual(restored.items.count, 3, "the readable items must all survive")
        XCTAssertEqual(restored.items.map(\.id), ["m0", "unreadable-item-1", "m1"],
                       "in place, so the conversation still reads in order")
        XCTAssertEqual(restored.unreadableItemCount, 1)
    }

    /// Visible, not silent. A dropped line the reader is never told about is the failure mode this
    /// whole change exists to remove.
    func testTheReplacementIsAVisibleErrorNamingWhatCouldNotBeRead() throws {
        let unknown: [String: Any] = ["type": "somethingFromTheFuture", "payload": ["a": 1]]
        let restored = try XCTUnwrap(transcript([good, unknown]))
        guard case .error(_, let text) = try XCTUnwrap(restored.items.last) else {
            return XCTFail("an unreadable item must become an error row, which renders in red")
        }
        XCTAssertTrue(text.contains("could not be read"), "got: \(text)")
        XCTAssertTrue(text.contains("somethingFromTheFuture"),
                      "the message must name the type that could not be read; got: \(text)")
    }

    func testAnItemWithNoTypeAtAllStillGetsAPlaceholder() throws {
        let restored = try XCTUnwrap(transcript([["nothing": "useful"] as [String: Any]]))
        guard case .error(let id, let text) = try XCTUnwrap(restored.items.first) else {
            return XCTFail("expected a placeholder")
        }
        XCTAssertEqual(id, "unreadable-item-0", "a positional id when the item carried none")
        XCTAssertTrue(text.contains("no type given"), "got: \(text)")
    }

    /// Several bad items must not collapse into one row, and their ids must stay distinct - a
    /// duplicate `Identifiable.id` in a ForEach is undefined behavior in SwiftUI.
    func testSeveralUnreadableItemsKeepDistinctIdentities() throws {
        let restored = try XCTUnwrap(transcript([["a": 1] as [String: Any],
                                                 ["b": 2] as [String: Any], good]))
        XCTAssertEqual(restored.items.count, 3)
        XCTAssertEqual(restored.unreadableItemCount, 2)
        XCTAssertEqual(Set(restored.items.map(\.id)).count, 3, "ids must be unique")
    }

    /// A conversation of nothing but unreadable items is still a conversation that opens - the
    /// reader sees what happened instead of an empty window.
    func testATranscriptOfOnlyUnreadableItemsStillDecodes() throws {
        let restored = try XCTUnwrap(transcript([["a": 1] as [String: Any]]),
                                     "decoding must not fail even when nothing is readable")
        XCTAssertEqual(restored.items.count, 1)
    }

    /// Not every bad element is an object. Each must still consume exactly one array slot, or the
    /// items after it shift and the conversation silently reorders.
    func testNonObjectElementsEachCostExactlyOneSlot() throws {
        let restored = try XCTUnwrap(transcript([good, "a bare string", 42, true,
                                                 NSNull(), [1, 2], alsoGood]))
        XCTAssertEqual(restored.items.count, 7, "every element must occupy its own slot")
        XCTAssertEqual(restored.unreadableItemCount, 5)
        XCTAssertEqual(restored.items.first?.id, "m0")
        XCTAssertEqual(restored.items.last?.id, "m1", "the good item after them must not shift")
    }

    /// The commonest real failure: a type the reader knows, carrying a payload it cannot read.
    func testAKnownTypeWithAnUnreadablePayloadIsNamedByItsType() throws {
        let deep: [String: Any] = ["type": "message", "message": ["id": 123]]
        let restored = try XCTUnwrap(transcript([good, deep]))
        guard case .error(let id, let text) = try XCTUnwrap(restored.items.last) else {
            return XCTFail("expected a placeholder")
        }
        XCTAssertEqual(id, "unreadable-item-1")
        XCTAssertTrue(text.contains("\"message\""), "got: \(text)")
    }

    /// THE COLLISION THAT DROPS LIVE UPDATES. An entry envelope carries `id` at the top level -
    /// the shape fireEntry hands hosts - so a host restoring one by mistake used to give the
    /// placeholder the real message's id. Every mutation path finds items with `firstIndex`, so
    /// the live turn's status updates landed on the placeholder and were silently discarded.
    func testAPlaceholderNeverStealsARealItemsIdentity() throws {
        let envelope: [String: Any] = ["sequence": 1, "type": "message", "id": "user-1",
                                       "data": ["type": "message",
                                                "message": ["id": "user-1", "role": "local",
                                                            "text": "hi"]] as [String: Any]]
        let real: [String: Any] = ["type": "message",
                                   "message": ["id": "user-1", "role": "local", "text": "hi"]]
        let restored = try XCTUnwrap(transcript([envelope, real]))
        XCTAssertEqual(restored.items.count, 2)
        XCTAssertEqual(Set(restored.items.map(\.id)).count, 2,
                       "the placeholder must not take the id of the message that follows it")
        XCTAssertEqual(restored.items.last?.id, "user-1", "the real message keeps its own id")
    }

    /// And it must not take an id from a real item that happens to be named like a placeholder.
    func testAPlaceholderStepsAsideForARealItemNamedLikeOne() throws {
        let impostor: [String: Any] = ["type": "system", "id": "unreadable-item-0",
                                       "text": "a genuine system line"]
        let restored = try XCTUnwrap(transcript([["nothing": "useful"] as [String: Any], impostor]))
        XCTAssertEqual(Set(restored.items.map(\.id)).count, 2)
        XCTAssertEqual(restored.items.last?.id, "unreadable-item-0", "the real item keeps the name")
    }

    /// EQUALITY MUST IGNORE THE DECODE DIAGNOSTICS. `ChatStore` dedups restores with `!=`; if the
    /// counts participate, a repaired transcript differs from the damaged one by the counts alone,
    /// the dedup sees a change that is not there, and re-applying discards a turn that arrived in
    /// between.
    func testTheDecodeDiagnosticsAreNotPartOfEquality() throws {
        let damaged = try XCTUnwrap(transcript([good, ["nothing": "useful"] as [String: Any]]))
        let repaired = try XCTUnwrap(transcript([
            good,
            ["type": "error", "id": "unreadable-item-1",
             "text": "This entry could not be read (no type given)."] as [String: Any],
        ]))
        XCTAssertEqual(damaged.items, repaired.items, "same items")
        XCTAssertEqual(damaged.unreadableItemCount, 1)
        XCTAssertEqual(repaired.unreadableItemCount, 0, "different diagnostics")
        XCTAssertEqual(damaged, repaired, "yet equal, or the restore dedup re-applies and wipes a turn")
    }

    /// The same failure one key over. A side surface that will not decode must cost that surface,
    /// not the conversation.
    func testAMalformedSideSurfaceDoesNotCostTheConversation() throws {
        let restored = try XCTUnwrap(
            ChatTranscript.decode(from: ["version": 1, "items": [good, alsoGood],
                                         "plan": [["id": 1, "content": "x",
                                                   "status": "fromTheFuture"]]] as [String: Any]),
            "a plan this version cannot read must not drop the conversation with it")
        XCTAssertEqual(restored.items.count, 2)
        XCTAssertEqual(restored.plan, [])
        XCTAssertEqual(restored.unreadableFields, ["plan"])
    }

    /// Lossiness is confined to `items`. A malformed transcript is still a malformed transcript.
    func testAValueThatIsNotATranscriptAtAllIsStillRejected() {
        XCTAssertNil(ChatTranscript.decode(from: "not json"))
        XCTAssertNil(ChatTranscript.decode(from: ["version": 1, "items": "not an array"]
                                                 as [String: Any]))
    }

    /// The single-item append channel stays STRICT: appending a bad item must be refused, not
    /// turned into an error row the host never asked for.
    func testTheAppendChannelDoesNotSubstitutePlaceholders() {
        XCTAssertNil(ChatItem.decode(from: ["id": "condense-1", "kind": "resumed"]
                                     as [String: Any]))
    }
}

/// A logger that keeps what it was told. Every other logger in this package's tests discards its
/// input, which is why the store's own half of the unreadable-item handling had no coverage: the
/// warning is the only thing it does, and nothing could observe it.
private final class CapturingLogger: ChatLogger, @unchecked Sendable {
    private let lock = NSLock()
    private var lines: [String] = []
    func log(_ message: String, _ level: ChatLogLevel) {
        lock.withLock { lines.append("[\(level)] \(message)") }
    }
    var captured: [String] { lock.withLock { lines } }
}

@MainActor
final class ChatStoreUnreadableItemLoggingTests: XCTestCase {

    /// The placeholder rows tell the person reading the conversation. This tells whoever has to
    /// find out why - and it is the reason a restore is no longer indistinguishable from silence.
    func testRestoringATranscriptWithUnreadableItemsIsReported() {
        let logger = CapturingLogger()
        let source = FakeContentSource()
        let store = ChatStore(config: ChatConfiguration(dictionary: [:], logger: logger),
                              logger: logger, contentSource: source)
        store.start()

        source.content = [
            "version": 1,
            "items": [["type": "message",
                       "message": ["id": "m0", "role": "local", "text": "hi"]] as [String: Any],
                      ["id": "condense-1", "kind": "resumed"] as [String: Any]],
        ] as [String: Any]

        XCTAssertEqual(store.items.count, 2, "the conversation still opens")
        let warnings = logger.captured.filter { $0.contains("unreadable item") }
        XCTAssertEqual(warnings.count, 1, "exactly one report; got: \(logger.captured)")
        XCTAssertTrue(warnings[0].contains("warning"), "got: \(warnings[0])")
        XCTAssertTrue(warnings[0].contains("1 "), "the count belongs in it; got: \(warnings[0])")
    }

    func testACleanRestoreSaysNothing() {
        let logger = CapturingLogger()
        let source = FakeContentSource()
        let store = ChatStore(config: ChatConfiguration(dictionary: [:], logger: logger),
                              logger: logger, contentSource: source)
        store.start()
        source.content = [
            "version": 1,
            "items": [["type": "message",
                       "message": ["id": "m0", "role": "local", "text": "hi"]] as [String: Any]],
        ] as [String: Any]
        XCTAssertEqual(store.items.count, 1)
        XCTAssertTrue(logger.captured.filter { $0.contains("unreadable") }.isEmpty,
                      "a clean restore must not warn; got: \(logger.captured)")
    }
}
