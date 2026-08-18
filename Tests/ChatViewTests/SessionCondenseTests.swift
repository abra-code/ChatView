// SessionCondenseTests.swift - asking for a summarized restore, and showing what came back.
//
// The feature exists so a person can READ what the model was given in place of the messages it
// no longer has. So the assertions are about two things: the request reaching the wire in the
// shape the agent documents, and the answer surviving into a transcript item a reader can open.
//
// The failure this guards hardest is the quiet one: a condense request that is dropped somewhere
// between the injected content and the prime looks exactly like an agent that chose not to
// condense - full fidelity, no error, just a slower turn nobody attributes to a bug.

import Combine
import XCTest
@testable import ChatView

/// Records what each prime was asked to do. The condense argument is the whole point: a transport
/// that only counted primes could not tell a re-prime carrying the new choice from one carrying
/// the old.
private final class CondensePrimeTransport: ChatTransport, @unchecked Sendable {
    let events: AsyncStream<ChatEvent>
    private let continuation: AsyncStream<ChatEvent>.Continuation
    private let lock = NSLock()
    private var _primes: [PrimeCondense?] = []
    var primeCount: Int { lock.withLock { _primes.count } }
    var lastCondense: PrimeCondense?? { lock.withLock { _primes.last } }
    init() {
        var captured: AsyncStream<ChatEvent>.Continuation!
        self.events = AsyncStream { captured = $0 }
        self.continuation = captured
    }
    func start() async {}
    func send(_ command: ChatCommand) async {}
    func stop() async { continuation.finish() }
    func primeHistory(_ messages: [ChatMessage]) { primeHistory(messages, condense: nil) }
    func primeHistory(_ messages: [ChatMessage], condense: PrimeCondense?) {
        lock.withLock { _primes.append(condense) }
    }
    func reserveIDs(seen ids: [String]) {}
}

private final class CondenseTransportBox: @unchecked Sendable {
    var transport: CondensePrimeTransport?
}

private final class CondenseTestLogger: ChatLogger {
    func log(_ message: String, _ level: ChatLogLevel) {}
}

/// The store holds its content source WEAKLY, so a test must keep this alive across start().
private final class CondenseConfigSource: ChatContentSource {
    var content: Any? { didSet { contentObservers.values.forEach { $0(content) } } }
    var config: Any? { didSet { configObservers.values.forEach { $0(config) } } }
    private var contentObservers: [Int: (Any?) -> Void] = [:]
    private var configObservers: [Int: (Any?) -> Void] = [:]
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
}

@MainActor
final class SessionCondenseTests: XCTestCase {

    // MARK: - The request

    func testACondenseObjectIsReadOffInjectedContent() {
        let ask = ChatStore.parseCondenseRequestForTests(
            ["version": 1, "items": [], "prime": "defer",
             "condense": ["keepRecentTurns": 8, "maxDigestTokens": 900]])
        XCTAssertEqual(ask, PrimeCondense(keepRecentTurns: 8, maxDigestTokens: 900))
    }

    /// An empty object is a real request - "summarize, your defaults" - and must not read as
    /// absent, which would silently replay everything.
    func testAnEmptyCondenseObjectStillAsksForSummarization() {
        let ask = ChatStore.parseCondenseRequestForTests(
            ["version": 1, "items": [], "condense": [:] as [String: Any]])
        XCTAssertEqual(ask, PrimeCondense())
    }

    func testNoCondenseKeyMeansReplayEverything() {
        XCTAssertNil(ChatStore.parseCondenseRequestForTests(["version": 1, "items": []]))
    }

    /// `"condense": true` is a reasonable thing for a host to write by hand; refusing it over a
    /// type mismatch would be pedantry, and refusing it SILENTLY would be a bug.
    func testABareTrueIsAcceptedAsADefaultRequest() {
        XCTAssertEqual(ChatStore.parseCondenseRequestForTests(
            ["version": 1, "items": [], "condense": true]), PrimeCondense())
        XCTAssertNil(ChatStore.parseCondenseRequestForTests(
            ["version": 1, "items": [], "condense": false]))
    }

    func testTheRequestIsReadFromAJSONStringToo() {
        let json = #"{"version":1,"items":[],"prime":"defer","condense":{"keepRecentTurns":4}}"#
        XCTAssertEqual(ChatStore.parseCondenseRequestForTests(json),
                       PrimeCondense(keepRecentTurns: 4, maxDigestTokens: nil))
    }

    // MARK: - Changing the choice after the conversation has been sent into

    /// A condense-only restore must reach the agent with the NEW request, not the one the
    /// conversation was opened with. This is the plumbing half of a fix whose other half - the
    /// re-arming itself - has no regression test here; see the note below.
    func testAPrimeAfterAChangedRestoreCarriesTheNewRequest() {
        let (store, transport, source) = Self.primedStore()
        defer { store.teardown() }

        Self.restore(source, condense: nil)
        store.send("first")
        XCTAssertEqual(transport.lastCondense ?? nil, nil, "the first restore asked for nothing")

        Self.restore(source, condense: ["keepRecentTurns": 6])
        store.send("second")
        XCTAssertEqual(transport.lastCondense??.keepRecentTurns, 6,
                       "the prime must carry the request in force at send time")

        Self.restore(source, condense: nil)
        store.send("third")
        XCTAssertNil(transport.lastCondense ?? nil,
                     "and dropping the request must reach the agent too")
    }

    // NOT TESTED HERE, and worth saying rather than leaving to be discovered: that a condense-only
    // change RE-ARMS a deferred prime after the conversation has been sent into. `wireContext`
    // only takes on the full displayed transcript at TURN END (ChatStore's turn-completion path),
    // so the state where the messages match and only the request differs is unreachable from a
    // synchronous test with a stub transport - every restore in this harness differs by content
    // and re-arms for that reason instead, which would make such a test pass with or without the
    // fix. The fix (condense participating in the sync comparison) is in ChatStore; the assertion
    // that would prove it needs a harness that completes a real turn first.

    // MARK: - Harness

    private static let items: [[String: Any]] = [
        ["type": "message", "message": ["id": "m0", "role": "local", "text": "hello"]],
        ["type": "message", "message": ["id": "m1", "role": "agent", "text": "hi"]],
    ]

    private static func restore(_ source: CondenseConfigSource, condense: [String: Any]?) {
        var content: [String: Any] = ["version": 1, "items": items, "prime": "defer"]
        if let condense { content["condense"] = condense }
        source.content = content
    }

    /// A store with a recording transport attached, built the way the engine builds one: a config
    /// injected through the content source, which the registry turns into a transport.
    private static func primedStore() -> (ChatStore, CondensePrimeTransport, CondenseConfigSource) {
        let name = "condense-test-\(UUID().uuidString)"
        let box = CondenseTransportBox()
        ChatTransportRegistry.shared.register(name) { _, _ in
            let t = CondensePrimeTransport()
            box.transport = t
            return t
        }
        let logger = CondenseTestLogger()
        let source = CondenseConfigSource(config: ["protocol": name])
        let store = ChatStore(config: ChatConfiguration(dictionary: [:], logger: logger),
                              logger: logger, contentSource: source)
        store.start()
        XCTAssertNotNil(box.transport, "the registry should have built the recording transport")
        return (store, box.transport!, source)
    }

    // MARK: - The answer

    func testACondensedPrimeBecomesAReadableTranscriptItem() throws {
        let event = SessionEvent(
            id: "condense-1", kind: .resumed, timestamp: "2026-08-17T15:42:00Z", model: nil,
            digest: SessionDigest(summarizer: "apple-foundation-models", droppedTurns: 64,
                                  verbatimTurns: 6, unresolvedIntent: "Pick a vector store",
                                  establishedFacts: ["pgvector fits"], decisions: ["Use pgvector"],
                                  openThreads: [], userPreferences: []))
        let data = try JSONEncoder().encode(ChatTranscript(version: 1, items: [.sessionEvent(event)]))
        let back = try JSONDecoder().decode(ChatTranscript.self, from: data)
        guard case .sessionEvent(let decoded) = back.items[0] else {
            return XCTFail("expected a sessionEvent")
        }
        // The digest is the part that must survive: a marker that persisted without it would
        // reopen tomorrow saying a summary happened and unable to show it.
        XCTAssertEqual(decoded.digest?.summarizer, "apple-foundation-models")
        XCTAssertEqual(decoded.digest?.decisions, ["Use pgvector"])
        XCTAssertEqual(decoded.digest?.droppedTurns, 64)
    }

    /// Both facts a reader needs to judge the summary: how much it replaced, and who wrote it.
    /// A 3B on-device summary and a 32k local-model summary deserve different suspicion.
    func testTheCaptionCarriesTheSizeAndTheSummarizer() {
        let caption = SessionEventText.caption(
            SessionEvent(id: "c", kind: .resumed),
            digest: SessionDigest(summarizer: "Qwen3 4B", droppedTurns: 64))
        XCTAssertTrue(caption.contains("64 earlier messages summarized"), caption)
        XCTAssertTrue(caption.contains("by Qwen3 4B"), caption)
    }

    func testTheCaptionSaysSomethingUsefulWithoutCounts() {
        let caption = SessionEventText.caption(SessionEvent(id: "c", kind: .resumed),
                                               digest: SessionDigest())
        XCTAssertTrue(caption.contains("earlier messages summarized"), caption)
        XCTAssertFalse(caption.contains("by "), caption)
    }

    func testOneDroppedMessageIsNotPluralized() {
        let caption = SessionEventText.caption(SessionEvent(id: "c", kind: .resumed),
                                               digest: SessionDigest(droppedTurns: 1))
        XCTAssertTrue(caption.contains("1 earlier message summarized"), caption)
    }

    /// An all-empty digest renders no disclosure - an expander the user opens onto nothing is
    /// worse than a plain marker.
    func testAnEmptyDigestIsRecognizedAsEmpty() {
        XCTAssertTrue(SessionDigest().isEmpty)
        XCTAssertTrue(SessionDigest(summarizer: "x", droppedTurns: 9).isEmpty)
        XCTAssertFalse(SessionDigest(decisions: ["something"]).isEmpty)
        XCTAssertFalse(SessionDigest(unresolvedIntent: "something").isEmpty)
    }
}
