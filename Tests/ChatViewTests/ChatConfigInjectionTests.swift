// Tests/ChatViewTests/ChatConfigInjectionTests.swift
//
// Tests for the host-injected operational-config seam (states["config"]). The Chat
// element takes its protocol + transport NOT from the document but from a runtime
// injection into states["config"] (the same @Published states channel as the P0-2
// states["content"] restore). The store DEFERS building the transport until the config
// first resolves to a VIABLE one; after that an IDENTICAL injection is deduped while a
// DIFFERENT viable one re-configures in place (tear down + attach + re-prime from the
// loaded items - the host-driven model switch). Until configured the element is inert
// (isConfigured == false, no transport); readOnly never builds a transport.

import XCTest
import Combine
@testable import ChatView

private final class InjectionTestLogger: ChatLogger {
    func log(_ message: String, _ level: ChatLogLevel) {}
}

/// A fake ChatContentSource that drives states["config"] (and states["content"]) the way the
/// engine's ViewModel does: assigning `config` delivers it to observers, and a new observer receives
/// the current value immediately (matching the @Published semantics the store relies on).
@MainActor
private final class FakeConfigSource: ChatContentSource {
    var content: Any? {
        didSet { contentObservers.values.forEach { $0(content) } }
    }
    var config: Any? {
        didSet { configObservers.values.forEach { $0(config) } }
    }
    private var contentObservers: [Int: (Any?) -> Void] = [:]
    private var configObservers: [Int: (Any?) -> Void] = [:]
    private var nextID = 0

    init(config: Any? = nil) {
        self.config = config
    }

    func observeChatContent(_ handler: @escaping (Any?) -> Void) -> AnyCancellable {
        nextID += 1
        let id = nextID
        contentObservers[id] = handler
        handler(content)
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

/// A mutable build counter shared with a test factory so a test can prove how many times the
/// transport was built (the freeze: a frozen element must not rebuild on a later config change).
private final class BuildCounter: @unchecked Sendable {
    var count = 0
}

/// A no-op transport a test factory returns; its event stream never emits (the store just drains it).
/// It records every primeHistory payload so a test can assert the store's restore -> prime wiring.
private final class FakeInjectTransport: ChatTransport, @unchecked Sendable {
    let events: AsyncStream<ChatEvent>
    private let continuation: AsyncStream<ChatEvent>.Continuation
    private let lock = NSLock()
    private var _primed: [[ChatMessage]] = []
    private var _reserved: [[String]] = []
    /// Every primeHistory call's payload, in order (the store primes on attach and on each restore).
    var primedHistories: [[ChatMessage]] { lock.withLock { _primed } }
    /// Every reserveIDs call's id list, in order (the store reserves alongside each prime).
    var reservedIDs: [[String]] { lock.withLock { _reserved } }
    init() {
        var captured: AsyncStream<ChatEvent>.Continuation!
        self.events = AsyncStream { captured = $0 }
        self.continuation = captured
    }
    func start() async {}
    func send(_ command: ChatCommand) async {}
    func stop() async { continuation.finish() }
    func primeHistory(_ messages: [ChatMessage]) { lock.withLock { _primed.append(messages) } }
    func reserveIDs(seen ids: [String]) { lock.withLock { _reserved.append(ids) } }
}

/// Captures the transport instance a factory builds, so a test can inspect it afterwards.
private final class TransportBox: @unchecked Sendable {
    var transport: FakeInjectTransport?
}

@MainActor
final class ChatConfigInjectionTests: XCTestCase {

    private func makeStore(properties: [String: Any] = [:], source: FakeConfigSource) -> ChatStore {
        let logger = InjectionTestLogger()
        return ChatStore(config: ChatConfiguration(dictionary: properties, logger: logger),
                         logger: logger, contentSource: source)
    }

    // NOTE: ChatStore holds `contentSource` WEAKLY (the engine's ViewModel owns the store's lifetime,
    // not vice versa - a strong ref would retain-cycle). So every test must keep a STRONG local `source`
    // alive across start(), exactly as the engine keeps the ViewModel alive; passing the fake inline
    // would let it deallocate before the subscription fires.

    func testInertWithNoConfigInjected() {
        let source = FakeConfigSource()   // no states["config"]
        let store = makeStore(source: source)
        store.start()
        XCTAssertFalse(store.isConfigured, "with no states[\"config\"] injected, the element stays inert (no transport)")
    }

    func testLocalConfigBuildsTransport() {
        let source = FakeConfigSource(config: ["protocol": "local"])
        let store = makeStore(source: source)
        store.start()
        XCTAssertTrue(store.isConfigured, "an injected local config builds the built-in transport")
        store.teardown()
    }

    func testMissingProtocolDefaultsToLocal() {
        let source = FakeConfigSource(config: ["transport": ["echo": true]])
        let store = makeStore(source: source)
        store.start()
        XCTAssertTrue(store.isConfigured, "a config object without a protocol defaults to local and is viable")
        store.teardown()
    }

    func testReadOnlyNeverBuildsTransportEvenWhenConfigInjected() {
        let source = FakeConfigSource(config: ["protocol": "local"])
        let store = makeStore(properties: ["readOnly": true], source: source)
        store.start()
        XCTAssertFalse(store.isConfigured, "readOnly is a viewer mode: no transport even when a config is injected")
    }

    func testNotYetViableConfigDefersThenBuildsOnCompleterConfig() {
        struct MissingKey: Error {}
        let name = "inject-test-needs-key-\(UUID().uuidString)"
        ChatTransportRegistry.shared.register(name) { config, _ in
            guard config.settings["key"] != nil else { throw MissingKey() }
            return FakeInjectTransport()
        }
        let source = FakeConfigSource(config: ["protocol": name])   // registered but incomplete -> not viable
        let store = makeStore(source: source)
        store.start()
        XCTAssertFalse(store.isConfigured, "a registered-but-incomplete config does not build or freeze; the element stays inert")

        source.config = ["protocol": name, "transport": ["key": "v"]]   // the host completes the config
        XCTAssertTrue(store.isConfigured, "when a completer config arrives, the deferred transport builds")
        store.teardown()
    }

    func testIdenticalConfigReinjectionIsIgnored() {
        let counter = BuildCounter()
        let name = "inject-test-dedup-\(UUID().uuidString)"
        ChatTransportRegistry.shared.register(name) { _, _ in
            counter.count += 1
            return FakeInjectTransport()
        }
        let source = FakeConfigSource(config: ["protocol": name, "transport": ["key": "v"]])
        let store = makeStore(source: source)
        store.start()
        XCTAssertTrue(store.isConfigured)
        XCTAssertEqual(counter.count, 1, "the first viable config builds the transport once")

        // The observation re-delivers on every states change: an IDENTICAL config must not rebuild.
        source.config = ["protocol": name, "transport": ["key": "v"]]
        XCTAssertEqual(counter.count, 1, "re-injecting the same resolved config is a no-op")
        store.teardown()
    }

    func testChangedConfigReconfiguresAndReprimesFromItems() {
        let counter = BuildCounter()
        let box = TransportBox()
        let name = "inject-test-reconfig-\(UUID().uuidString)"
        ChatTransportRegistry.shared.register(name) { _, _ in
            counter.count += 1
            let transport = FakeInjectTransport()
            box.transport = transport
            return transport
        }
        let source = FakeConfigSource(config: ["protocol": name, "transport": ["model": "A"]])
        let store = makeStore(source: source)
        store.start()
        source.content = ChatTranscript(items: [
            .message(ChatMessage(id: "u1", role: .local, text: "q", isStreaming: false)),
        ])
        XCTAssertEqual(counter.count, 1)

        // A DIFFERENT viable config re-configures in place (the host-driven model switch):
        // a new transport is built, and attach() re-primes it from the loaded items so the
        // conversation carries over.
        source.config = ["protocol": name, "transport": ["model": "B"]]
        XCTAssertEqual(counter.count, 2, "a changed config tears down the old transport and builds the new one")
        XCTAssertEqual(box.transport?.primedHistories.last?.map(\.id), ["u1"],
                       "the re-configured transport is seeded with the loaded conversation")
        store.teardown()
    }

    // MARK: - Restore primes the transport wire history (P0-2 continue-in)

    private func registerPrimingTransport(_ box: TransportBox) -> String {
        let name = "prime-test-\(UUID().uuidString)"
        ChatTransportRegistry.shared.register(name) { _, _ in
            let transport = FakeInjectTransport()
            box.transport = transport
            return transport
        }
        return name
    }

    func testRestorePrimesTheTransportWithLoadedMessages() {
        let box = TransportBox()
        let source = FakeConfigSource(config: ["protocol": registerPrimingTransport(box)])
        let store = makeStore(source: source)
        store.start()   // builds + attaches the transport (primes an empty history)
        XCTAssertTrue(store.isConfigured)

        source.content = ChatTranscript(items: [
            .message(ChatMessage(id: "u1", role: .local, text: "earlier question", isStreaming: false)),
            .thought(ChatMessage(id: "t1", role: .agent, text: "thinking", isStreaming: false)),
            .message(ChatMessage(id: "a1", role: .agent, text: "earlier answer", isStreaming: false)),
        ])

        let primed = box.transport?.primedHistories.last ?? []
        XCTAssertEqual(primed.map(\.id), ["u1", "a1"],
                       "restoring a transcript primes the transport with its MESSAGE items (thoughts/tool cards omitted)")
        XCTAssertEqual(primed.map(\.role), [.local, .agent])

        let reserved = box.transport?.reservedIDs.last ?? []
        XCTAssertEqual(reserved, ["u1", "t1", "a1"],
                       "restore reserves EVERY loaded id (including the thought t1, which primeHistory omits) so a continued turn cannot reuse one")
        store.teardown()
    }

    func testNewChatClearPrimesAnEmptyWire() {
        let box = TransportBox()
        let source = FakeConfigSource(config: ["protocol": registerPrimingTransport(box)])
        let store = makeStore(source: source)
        store.start()
        source.content = ChatTranscript(items: [.message(ChatMessage(id: "u1", role: .local, text: "q", isStreaming: false))])
        XCTAssertEqual(box.transport?.primedHistories.last?.count, 1)
        // A New Chat injects an empty transcript -> the transport is primed with an empty wire.
        source.content = ChatTranscript(items: [])
        XCTAssertEqual(box.transport?.primedHistories.last?.count, 0,
                       "a cleared transcript primes an empty wire history, so the next turn starts fresh")
        store.teardown()
    }

    // MARK: - The transient "prime" directive (Read Only restore: display without context)

    /// The injected transcript JSON with a "prime" key riding on it, as MLXChat's restore
    /// scripts emit it (the key is transient: ChatTranscript's codec drops it, so it never
    /// reaches persistence). `prime` is true / false / the string "defer" / nil (key omitted).
    private func transcriptJSON(items: [ChatItem], prime: Any?) throws -> String {
        let data = try JSONEncoder().encode(ChatTranscript(items: items))
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        if let prime {
            object["prime"] = prime
        }
        let out = try JSONSerialization.data(withJSONObject: object)
        return try XCTUnwrap(String(data: out, encoding: .utf8))
    }

    private let restoreItems: [ChatItem] = [
        .message(ChatMessage(id: "u1", role: .local, text: "earlier question", isStreaming: false)),
        .message(ChatMessage(id: "a1", role: .agent, text: "earlier answer", isStreaming: false)),
    ]

    func testPrimeFalseRestoreDisplaysItemsButPrimesEmpty() throws {
        let box = TransportBox()
        let source = FakeConfigSource(config: ["protocol": registerPrimingTransport(box)])
        let store = makeStore(source: source)
        store.start()

        source.content = try transcriptJSON(items: restoreItems, prime: false)
        XCTAssertEqual(store.items.count, 2, "a Read Only restore still displays the transcript")
        XCTAssertEqual(box.transport?.primedHistories.last?.count, 0,
                       "\"prime\": false seeds an EMPTY wire history (fresh context) while the transcript displays")
        XCTAssertEqual(box.transport?.reservedIDs.last, ["u1", "a1"],
                       "id reservation is collision safety, independent of the prime directive")
        store.teardown()
    }

    func testSameTranscriptWithFlippedPrimeFlagIsNotDeduped() throws {
        let box = TransportBox()
        let source = FakeConfigSource(config: ["protocol": registerPrimingTransport(box)])
        let store = makeStore(source: source)
        store.start()

        source.content = try transcriptJSON(items: restoreItems, prime: false)
        XCTAssertEqual(box.transport?.primedHistories.last?.count, 0)
        // The user reopens the SAME conversation, now choosing Resume: the identical
        // transcript with a flipped flag must re-apply, not be swallowed by the dedup.
        source.content = try transcriptJSON(items: restoreItems, prime: true)
        XCTAssertEqual(box.transport?.primedHistories.last?.map(\.id), ["u1", "a1"],
                       "re-injecting the same transcript with a flipped prime flag re-applies and primes the messages")
        store.teardown()
    }

    func testAbsentPrimeKeyDefaultsToPrimingMessages() throws {
        let box = TransportBox()
        let source = FakeConfigSource(config: ["protocol": registerPrimingTransport(box)])
        let store = makeStore(source: source)
        store.start()

        source.content = try transcriptJSON(items: restoreItems, prime: nil)
        XCTAssertEqual(box.transport?.primedHistories.last?.map(\.id), ["u1", "a1"],
                       "no prime key -> context follows display (the documented default), pinning existing behavior")
        store.teardown()
    }

    // MARK: - The "defer" directive (seamless browsing: display now, prime on the next send)

    func testDeferredRestorePrimesOnSendNotOnLoad() throws {
        let box = TransportBox()
        let source = FakeConfigSource(config: ["protocol": registerPrimingTransport(box)])
        let store = makeStore(source: source)
        store.start()
        let attachPrimes = box.transport?.primedHistories.count ?? 0

        source.content = try transcriptJSON(items: restoreItems, prime: "defer")
        XCTAssertEqual(store.items.count, 2, "a deferred restore still displays the transcript")
        XCTAssertEqual(box.transport?.primedHistories.count, attachPrimes,
                       "\"prime\": \"defer\" must not touch the agent on load - browsing is free")
        XCTAssertEqual(box.transport?.reservedIDs.last, ["u1", "a1"],
                       "id reservation still happens on a deferred restore (collision safety)")
        XCTAssertEqual(store.contextState, .pending, "the indicator reports the context loads on the next message")

        store.send("continue")
        XCTAssertEqual(box.transport?.primedHistories.last?.map(\.id), ["u1", "a1"],
                       "the first send replays the displayed conversation before the prompt")
        XCTAssertEqual(store.contextState, .synced)
        store.teardown()
    }

    func testBrowsingAwayAndBackSkipsTheRePrime() throws {
        let box = TransportBox()
        let source = FakeConfigSource(config: ["protocol": registerPrimingTransport(box)])
        let store = makeStore(source: source)
        store.start()

        source.content = try transcriptJSON(items: restoreItems, prime: true)   // conversation A, primed
        let primeCount = box.transport?.primedHistories.count
        let otherItems: [ChatItem] = [
            .message(ChatMessage(id: "x1", role: .local, text: "another conversation", isStreaming: false)),
        ]
        source.content = try transcriptJSON(items: otherItems, prime: "defer")  // browse B: agent untouched
        XCTAssertEqual(store.contextState, .pending)
        source.content = try transcriptJSON(items: restoreItems, prime: "defer") // back to A
        XCTAssertEqual(store.contextState, .synced,
                       "the agent still holds A, so returning to it is already synced")
        store.send("go on")
        XCTAssertEqual(box.transport?.primedHistories.count, primeCount,
                       "sending into the conversation the agent already holds fires no re-prime")
        store.teardown()
    }

    func testReconfigureAfterDeferredRestoreDefersToTheNextSend() throws {
        // The host-driven model switch after a deferred restore: the NEW transport (a fresh
        // agent) is not primed eagerly either - the conversation carries over on the next send.
        let counter = BuildCounter()
        let box = TransportBox()
        let name = "inject-test-reconfig-defer-\(UUID().uuidString)"
        ChatTransportRegistry.shared.register(name) { _, _ in
            counter.count += 1
            let transport = FakeInjectTransport()
            box.transport = transport
            return transport
        }
        let source = FakeConfigSource(config: ["protocol": name, "transport": ["model": "A"]])
        let store = makeStore(source: source)
        store.start()
        source.content = try transcriptJSON(items: restoreItems, prime: "defer")

        source.config = ["protocol": name, "transport": ["model": "B"]]
        XCTAssertEqual(counter.count, 2)
        XCTAssertEqual(box.transport?.primedHistories.count, 0,
                       "the re-configured transport is not primed eagerly under a deferred directive")
        XCTAssertEqual(store.contextState, .pending)
        store.send("carry on")
        XCTAssertEqual(box.transport?.primedHistories.last?.map(\.id), ["u1", "a1"],
                       "the switched agent inherits the conversation with the first send")
        store.teardown()
    }

    func testSupersededTurnTerminalDoesNotDowngradeARestoredContext() throws {
        // A restore lands while a turn is streaming: the restore path sets the truthful
        // context state, and the superseded turn's terminal messageEnd (stopReason
        // "cancelled", always the next terminal on the ordered event stream) must NOT
        // re-run the turn-end bookkeeping - it would downgrade a correct .synced to
        // .pending and force a wasted duplicate prime on the next send.
        let box = TransportBox()
        let source = FakeConfigSource(config: ["protocol": registerPrimingTransport(box)])
        let store = makeStore(source: source)
        store.start()

        store.route(.messageStart(itemID: "turn-1", role: .agent))   // a turn is in flight
        source.content = try transcriptJSON(items: restoreItems, prime: true)   // restore mid-turn
        XCTAssertEqual(store.contextState, .synced, "the resume restore primes and syncs")
        let primeCount = box.transport?.primedHistories.count

        store.route(.messageEnd(itemID: "turn-1", stopReason: "cancelled"))     // superseded turn resolves
        XCTAssertEqual(store.contextState, .synced,
                       "the superseded turn's terminal must not downgrade the restored state")
        store.send("continue")
        XCTAssertEqual(box.transport?.primedHistories.count, primeCount,
                       "no duplicate prime: the send after the restore trusts the synced snapshot")

        // A REAL cancellation (no restore in between) still marks the context unknown.
        store.route(.messageStart(itemID: "turn-2", role: .agent))
        store.route(.messageEnd(itemID: "turn-2", stopReason: "cancelled"))
        XCTAssertEqual(store.contextState, .pending,
                       "a genuinely cancelled turn leaves a partial exchange agent-side; the next send re-primes")
        store.teardown()
    }

    func testTransportBuiltAfterRestorePrimesFromLoadedItems() {
        // Content restored BEFORE a viable config exists: the transport does not exist yet, so the
        // restore cannot prime it. When the config later builds the transport, attach() must prime
        // it from the already-loaded items (else a continue would drop the pre-config history).
        let box = TransportBox()
        let name = registerPrimingTransport(box)
        let source = FakeConfigSource()                     // no config yet
        source.content = ChatTranscript(items: [
            .message(ChatMessage(id: "u1", role: .local, text: "before config", isStreaming: false)),
        ])
        let store = makeStore(source: source)
        store.start()                                       // loads content; no transport built yet
        XCTAssertNil(box.transport, "no transport is built until a viable config arrives")

        source.config = ["protocol": name]                  // now the transport builds + attaches
        let primed = box.transport?.primedHistories.last ?? []
        XCTAssertEqual(primed.map(\.id), ["u1"],
                       "attach() primes the freshly built transport from the transcript restored before it existed")
        store.teardown()
    }
}
