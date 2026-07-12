// Tests/ChatViewTests/ChatStoreV2Tests.swift
//
// P3 tests for the person-to-person (v2) store layer: the new event routing (upsert, status
// change + watermark ladder, reactions, edit, delete, member / call append, file progress,
// typing with a virtual-clock expiry, participants, history prepend) and the store-initiated
// behaviors (paging trigger, read-mark debounce, outgoing-typing throttle) plus the
// features-AND-capabilities command gating. Time-based logic runs on an injected virtual clock.
// The v1 store suites (ChatRouterTests, ChatTranscriptSeamTests) are untouched and stay green.

import XCTest
import Combine
@testable import ChatView

private final class P3Logger: ChatLogger {
    func log(_ message: String, _ level: ChatLogLevel) {}
}

// MARK: - Virtual clock

@MainActor
private final class ManualChatScheduler: ChatScheduler {
    private struct Pending {
        let fireAt: Date
        let body: @MainActor () -> Void
    }
    private var pending: [String: Pending] = [:]
    private(set) var now: Date

    init(start: Date = Date(timeIntervalSince1970: 1_000_000)) {
        self.now = start
    }

    func schedule(_ key: String, after delay: TimeInterval, _ body: @escaping @MainActor () -> Void) {
        pending[key] = Pending(fireAt: now.addingTimeInterval(delay), body: body)
    }

    func cancel(_ key: String) {
        pending[key] = nil
    }

    /// Advances virtual time, firing every due callback in fire-time order.
    func advance(by seconds: TimeInterval) {
        now = now.addingTimeInterval(seconds)
        while let key = pending.first(where: { $0.value.fireAt <= now })?.key {
            let body = pending.removeValue(forKey: key)!.body
            body()
        }
    }
}

// MARK: - Recording mock transport

private final class CommandSink: @unchecked Sendable {
    private let lock = NSLock()
    private var commands: [ChatCommand] = []
    func record(_ command: ChatCommand) { lock.withLock { commands.append(command) } }
    func all() -> [ChatCommand] { lock.withLock { commands } }
}

private final class MockP2PTransport: ChatTransport, @unchecked Sendable {
    let events: AsyncStream<ChatEvent>
    private let continuation: AsyncStream<ChatEvent>.Continuation
    let capabilities: ChatTransportCapabilities
    private let sink: CommandSink

    init(capabilities: ChatTransportCapabilities, sink: CommandSink) {
        self.capabilities = capabilities
        self.sink = sink
        var captured: AsyncStream<ChatEvent>.Continuation!
        self.events = AsyncStream { captured = $0 }
        self.continuation = captured
    }

    func start() async {}
    func send(_ command: ChatCommand) async { sink.record(command) }
    func stop() async { continuation.finish() }
}

// Full-capability set for the command / behavior tests.
private func allCaps() -> ChatTransportCapabilities {
    ChatTransportCapabilities(paging: true, typing: true, reactions: true, editing: true,
                              deletion: true, replies: true, readReceipts: true, fileTransfer: true,
                              messageIdentity: true, reportsConnectionState: true)
}

// A minimal ChatContentSource that injects a fixed states["config"] the way the engine's ViewModel
// does: a new observer receives the current value immediately (the @Published semantics the store
// relies on), so the store builds + freezes its transport synchronously during start().
@MainActor
private final class FakeConfigSource: ChatContentSource {
    private let config: Any?

    init(config: Any?) {
        self.config = config
    }

    func observeChatContent(_ handler: @escaping (Any?) -> Void) -> AnyCancellable {
        handler(nil)
        return AnyCancellable {}
    }

    func observeChatConfig(_ handler: @escaping (Any?) -> Void) -> AnyCancellable {
        handler(config)
        return AnyCancellable {}
    }
}

// MARK: - Event routing (no transport needed)

@MainActor
final class ChatStoreV2RoutingTests: XCTestCase {

    private func makeStore(scheduler: ManualChatScheduler = ManualChatScheduler()) -> ChatStore {
        let logger = P3Logger()
        return ChatStore(config: ChatConfiguration(dictionary: [:], logger: logger),
                         logger: logger, scheduler: scheduler)
    }

    private func msg(_ id: String, _ role: ChatRole, _ text: String, status: MessageStatus? = nil,
                     senderID: String? = nil) -> ChatMessage {
        ChatMessage(id: id, role: role, text: text, isStreaming: false, senderID: senderID, status: status)
    }

    func testMessageReceivedInsertThenUpsertInPlace() {
        let store = makeStore()
        store.route(.messageReceived(msg("m1", .remote, "hi")))
        store.route(.messageReceived(msg("m2", .local, "yo")))
        XCTAssertEqual(store.items.map(\.id), ["m1", "m2"])
        // A correction with the same id replaces in place, preserving position.
        store.route(.messageReceived(msg("m1", .remote, "hi (edited by server)")))
        XCTAssertEqual(store.items.map(\.id), ["m1", "m2"], "upsert keeps position")
        guard case .message(let m) = store.items[0] else { return XCTFail() }
        XCTAssertEqual(m.text, "hi (edited by server)")
    }

    func testStatusChangedAndUnknownIsNoOp() {
        let store = makeStore()
        store.route(.messageReceived(msg("m1", .local, "hi", status: .sending)))
        store.route(.messageStatusChanged(itemID: "m1", status: .delivered))
        guard case .message(let m) = store.items[0] else { return XCTFail() }
        XCTAssertEqual(m.status, .delivered)
        // Unknown id: tolerated, no crash, no new item.
        store.route(.messageStatusChanged(itemID: "nope", status: .read))
        XCTAssertEqual(store.items.count, 1)
    }

    func testStatusWatermarkAdvancesOwnLowerMessagesUpToTarget() {
        let store = makeStore()
        store.route(.messageReceived(msg("o1", .local, "a", status: .sent)))
        store.route(.messageReceived(msg("o2", .local, "b", status: .delivered)))
        store.route(.messageReceived(msg("r1", .remote, "reply")))          // not own - never marked
        store.route(.messageReceived(msg("o3", .local, "c", status: .sent))) // AFTER target - untouched
        // Read up to o2: o1 (sent<read) and o2 (delivered<read) advance; o3 is after the target.
        store.route(.messageStatusWatermark(status: .read, upToItemID: "o2"))
        func status(_ id: String) -> MessageStatus? {
            for case .message(let m) in store.items where m.id == id { return m.status }
            return nil
        }
        XCTAssertEqual(status("o1"), .read)
        XCTAssertEqual(status("o2"), .read)
        XCTAssertEqual(status("o3"), .sent, "a message after the target is not marked")
    }

    func testStatusWatermarkNeverOverwritesFailedOrRegresses() {
        let store = makeStore()
        store.route(.messageReceived(msg("o1", .local, "a", status: .failed)))
        store.route(.messageReceived(msg("o2", .local, "b", status: .read)))
        store.route(.messageStatusWatermark(status: .delivered, upToItemID: "o2"))
        func status(_ id: String) -> MessageStatus? {
            for case .message(let m) in store.items where m.id == id { return m.status }
            return nil
        }
        XCTAssertEqual(status("o1"), .failed, "failed is never overwritten by a watermark")
        XCTAssertEqual(status("o2"), .read, "a higher status never regresses")
    }

    func testWatermarkResolvesSelfViaParticipantIsSelf() {
        let store = makeStore()
        store.route(.participantsChanged([Participant(id: "me", name: "Me", isSelf: true),
                                          Participant(id: "them", name: "Them", isSelf: false)]))
        store.route(.messageReceived(msg("mine", .remote, "hi", status: .sent, senderID: "me")))
        store.route(.messageReceived(msg("theirs", .remote, "yo", status: .sent, senderID: "them")))
        store.route(.messageStatusWatermark(status: .read, upToItemID: "theirs"))
        func status(_ id: String) -> MessageStatus? {
            for case .message(let m) in store.items where m.id == id { return m.status }
            return nil
        }
        XCTAssertEqual(status("mine"), .read, "a senderID marked isSelf counts as own")
        XCTAssertEqual(status("theirs"), .sent, "a non-self message is not marked")
    }

    func testReactionsEditDeleteMutateInPlace() {
        let store = makeStore()
        store.route(.messageReceived(msg("m1", .remote, "original")))
        store.route(.reactionsChanged(itemID: "m1", reactions: [Reaction(emoji: "👍", count: 1, mine: true)]))
        store.route(.messageEdited(itemID: "m1", newText: "edited", editedAt: "2026-07-10T12:00:00Z"))
        guard case .message(let edited) = store.items[0] else { return XCTFail() }
        XCTAssertEqual(edited.reactions?.first?.emoji, "👍")
        XCTAssertEqual(edited.text, "edited")
        XCTAssertEqual(edited.editedAt, "2026-07-10T12:00:00Z")
        store.route(.messageDeleted(itemID: "m1"))
        guard case .message(let deleted) = store.items[0] else { return XCTFail() }
        XCTAssertEqual(deleted.deleted, true)
        XCTAssertEqual(deleted.text, "", "a tombstone blanks the text")
    }

    func testMemberAndCallEventsAppend() {
        let store = makeStore()
        store.route(.memberEvent(MemberEvent(id: "ev1", kind: .joined, subjectName: "Sam")))
        store.route(.callEvent(CallEvent(id: "c1", kind: .missedIncoming)))
        XCTAssertEqual(store.items.map(\.id), ["ev1", "c1"])
    }

    func testFileAddedAndProgressAndUnknownNoOp() {
        let store = makeStore()
        store.route(.fileAdded(ChatFile(id: "f1", role: .remote, name: "a.pdf",
                                        transferStatus: .transferring, progress: 0.1)))
        store.route(.fileProgress(itemID: "f1", progress: 0.9, transferStatus: .transferring))
        guard case .file(let file) = store.items[0] else { return XCTFail() }
        XCTAssertEqual(file.progress, 0.9)
        XCTAssertEqual(file.transferStatus, .transferring)
        store.route(.fileProgress(itemID: "ghost", progress: 1, transferStatus: .completed))  // tolerated
        XCTAssertEqual(store.items.count, 1)
    }

    func testTypingIndicatorExpiresOnTheVirtualClock() {
        let scheduler = ManualChatScheduler()
        let store = makeStore(scheduler: scheduler)
        store.route(.typingChanged(isTyping: true, senderID: "p2", senderName: "Alex"))
        XCTAssertEqual(store.typingParticipants.map(\.id), ["p2"])
        XCTAssertEqual(store.typingParticipants.first?.name, "Alex")
        scheduler.advance(by: 9)
        XCTAssertEqual(store.typingParticipants.count, 1, "still typing before the 10s failsafe")
        scheduler.advance(by: 2)
        XCTAssertTrue(store.typingParticipants.isEmpty, "the 10s expiry clears a lost typing signal")
    }

    func testTypingRefreshResetsExpiryAndExplicitStopClears() {
        let scheduler = ManualChatScheduler()
        let store = makeStore(scheduler: scheduler)
        store.route(.typingChanged(isTyping: true, senderID: "p2", senderName: "Alex"))
        scheduler.advance(by: 8)
        store.route(.typingChanged(isTyping: true, senderID: "p2", senderName: "Alex"))  // refresh -> expiry now at +18
        scheduler.advance(by: 8)
        XCTAssertEqual(store.typingParticipants.count, 1, "a refresh reset the expiry")
        store.route(.typingChanged(isTyping: false, senderID: "p2", senderName: nil))
        XCTAssertTrue(store.typingParticipants.isEmpty, "an explicit stop clears immediately")
    }

    func testParticipantsChangedUpdatesRoster() {
        let store = makeStore()
        store.route(.participantsChanged([Participant(id: "me", name: "Me", isSelf: true)]))
        XCTAssertEqual(store.participants.map(\.id), ["me"])
    }

    func testHistoryPagePrependsAndSetsFlags() {
        let store = makeStore()
        store.route(.messageReceived(msg("m3", .remote, "newest")))
        store.route(.historyPage(items: [.message(msg("m1", .remote, "oldest")),
                                         .message(msg("m2", .local, "older"))], hasMore: false))
        XCTAssertEqual(store.items.map(\.id), ["m1", "m2", "m3"], "older items prepend in order")
        XCTAssertFalse(store.hasEarlier, "hasMore=false ends paging")
        XCTAssertFalse(store.isLoadingEarlier)
    }
}

// MARK: - Store-initiated behaviors + command gating (started mock transport)

@MainActor
final class ChatStoreV2BehaviorTests: XCTestCase {

    // Lets the store's `Task { await transport?.send(...) }` command emissions drain on the MainActor.
    // Real sleeps interleaved with yields keep this robust when the whole suite runs together (a fixed
    // yield count alone occasionally raced a lazily-initialized first run).
    private func settle() async {
        for _ in 0..<3 {
            await Task.yield()
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        await Task.yield()
    }

    private func makeStarted(features: [String: Any] = [:],
                             capabilities: ChatTransportCapabilities = allCaps(),
                             scheduler: ManualChatScheduler = ManualChatScheduler())
        -> (ChatStore, CommandSink) {
        let sink = CommandSink()
        let proto = "mock-p2p-\(UUID().uuidString)"
        ChatTransportRegistry.shared.register(proto) { _, _ in MockP2PTransport(capabilities: capabilities, sink: sink) }
        let logger = P3Logger()
        var config = ChatConfiguration(dictionary: features, logger: logger)
        // The ActionUI add-on maps a configured attachActionID to attachEnabled; mirror that here.
        config.attachEnabled = !((features["attachActionID"] as? String)?.isEmpty ?? true)
        // The protocol is injected through states["config"] (not the document): the source delivers it
        // synchronously on subscribe, so start() builds + freezes the mock transport before returning.
        let source = FakeConfigSource(config: ["protocol": proto])
        let store = ChatStore(config: config, logger: logger,
                              contentSource: source, scheduler: scheduler)
        store.start()
        return (store, sink)
    }

    private func remote(_ id: String) -> ChatMessage {
        ChatMessage(id: id, role: .remote, text: "hi", isStreaming: false)
    }

    func testScrolledNearTopRequestsAPageOnce() async {
        let (store, sink) = makeStarted()
        store.route(.messageReceived(remote("top")))
        store.scrolledNearTop()
        await settle()
        XCTAssertTrue(store.isLoadingEarlier)
        XCTAssertEqual(sink.all().count, 1)
        if case .loadEarlier(let before, let limit) = sink.all().first {
            XCTAssertEqual(before, "top")
            XCTAssertEqual(limit, 50)
        } else {
            XCTFail("expected loadEarlier")
        }
        // A second trigger while a page is in flight does nothing.
        store.scrolledNearTop()
        await settle()
        XCTAssertEqual(sink.all().count, 1, "no double request while loading")
    }

    func testScrolledNearTopNoPagingCapabilityIsInert() async {
        let (store, sink) = makeStarted(capabilities: ChatTransportCapabilities())
        store.route(.messageReceived(remote("top")))
        store.scrolledNearTop()
        await settle()
        XCTAssertTrue(sink.all().isEmpty, "no paging capability -> no request")
        XCTAssertFalse(store.isLoadingEarlier)
    }

    func testReadMarkDebouncedWhenPinnedAndActive() async {
        let scheduler = ManualChatScheduler()
        let (store, sink) = makeStarted(scheduler: scheduler)
        store.setPinnedToBottom(true)
        store.setSceneActive(true)
        store.route(.messageReceived(remote("r1")))
        XCTAssertTrue(sink.all().isEmpty, "debounced: nothing yet")
        scheduler.advance(by: 2)
        await settle()
        XCTAssertEqual(sink.all().count, 1)
        if case .markRead(let upTo) = sink.all().first {
            XCTAssertEqual(upTo, "r1")
        } else {
            XCTFail("expected markRead")
        }
    }

    func testReadMarkSuppressedWhenNotPinned() async {
        let scheduler = ManualChatScheduler()
        let (store, sink) = makeStarted(scheduler: scheduler)
        store.setPinnedToBottom(false)
        store.route(.messageReceived(remote("r1")))
        scheduler.advance(by: 5)
        await settle()
        XCTAssertTrue(sink.all().isEmpty, "not pinned to bottom -> no read mark")
    }

    func testReadMarkSuppressedWhenScrolledAwayDuringDebounceWindow() async {
        // Pinned + active when the message arrives (schedules a read mark), then the user scrolls away
        // BEFORE the 2s debounce fires: the mark must be suppressed (a receipt-privacy guarantee).
        let scheduler = ManualChatScheduler()
        let (store, sink) = makeStarted(scheduler: scheduler)
        store.setPinnedToBottom(true)
        store.setSceneActive(true)
        store.route(.messageReceived(remote("r1")))
        scheduler.advance(by: 1)              // still within the debounce window
        store.setPinnedToBottom(false)        // user scrolls up before it fires
        scheduler.advance(by: 2)
        await settle()
        XCTAssertTrue(sink.all().isEmpty, "scrolling away during the debounce window suppresses the read mark")
    }

    func testReadMarkSuppressedWhenBackgroundedDuringDebounceWindow() async {
        let scheduler = ManualChatScheduler()
        let (store, sink) = makeStarted(scheduler: scheduler)
        store.setPinnedToBottom(true)
        store.setSceneActive(true)
        store.route(.messageReceived(remote("r1")))
        scheduler.advance(by: 1)
        store.setSceneActive(false)           // app backgrounds before it fires
        scheduler.advance(by: 2)
        await settle()
        XCTAssertTrue(sink.all().isEmpty, "backgrounding during the debounce window suppresses the read mark")
    }

    func testOutgoingTypingThrottleAndStop() async {
        let scheduler = ManualChatScheduler()
        let (store, sink) = makeStarted(scheduler: scheduler)
        store.notifyComposerActivity()
        store.notifyComposerActivity()   // within the 4s window -> throttled
        await settle()
        XCTAssertEqual(sink.all().count, 1, "typing signal is throttled")
        XCTAssertTrue({ if case .setTyping(true) = sink.all().first { return true }; return false }())
        scheduler.advance(by: 4)
        store.notifyComposerActivity()   // past the window -> allowed
        await settle()
        XCTAssertEqual(sink.all().count, 2)
        store.stopTypingSignal()
        await settle()
        XCTAssertTrue({ if case .setTyping(false) = sink.all().last { return true }; return false }())
    }

    func testReactionGatingRequiresFeatureAndCapability() async {
        // Feature on, capability off -> inert.
        let (noCap, noCapSink) = makeStarted(features: ["features": ["reactions": true]],
                                             capabilities: ChatTransportCapabilities())
        noCap.route(.messageReceived(remote("m1")))
        noCap.toggleReaction(itemID: "m1", emoji: "👍")
        await settle()
        XCTAssertTrue(noCapSink.all().isEmpty, "no reactions capability -> no command")

        // Capability on, feature off -> inert.
        let (noFeat, noFeatSink) = makeStarted(features: [:], capabilities: allCaps())
        noFeat.route(.messageReceived(remote("m1")))
        noFeat.toggleReaction(itemID: "m1", emoji: "👍")
        await settle()
        XCTAssertTrue(noFeatSink.all().isEmpty, "reactions feature off -> no command")

        // Both on -> emits, with add derived from the current reaction (not mine -> add).
        let (both, bothSink) = makeStarted(features: ["features": ["reactions": true]], capabilities: allCaps())
        both.route(.messageReceived(remote("m1")))
        both.toggleReaction(itemID: "m1", emoji: "👍")
        await settle()
        guard case .toggleReaction(let id, let emoji, let add)? = bothSink.all().first else {
            return XCTFail("expected toggleReaction")
        }
        XCTAssertEqual(id, "m1")
        XCTAssertEqual(emoji, "👍")
        XCTAssertTrue(add, "no existing reaction -> add")
    }

    func testEditDeleteGating() async {
        let (store, sink) = makeStarted(features: ["features": ["editing": true, "deletion": true]],
                                        capabilities: allCaps())
        store.route(.messageReceived(ChatMessage(id: "m1", role: .local, text: "hi", isStreaming: false)))
        store.editMessage(itemID: "m1", newText: "hello")
        store.deleteMessage(itemID: "m1")
        await settle()
        // Both commands are emitted; each goes out in its own Task, so the store does not guarantee their
        // relative order on the wire - assert presence, not position.
        let commands = sink.all()
        XCTAssertEqual(commands.count, 2)
        XCTAssertTrue(commands.contains { if case .editMessage("m1", "hello") = $0 { return true }; return false })
        XCTAssertTrue(commands.contains { if case .deleteMessage("m1") = $0 { return true }; return false })
    }

    func testResendOnlyForFailed() async {
        let (store, sink) = makeStarted(capabilities: allCaps())
        store.route(.messageReceived(ChatMessage(id: "ok", role: .local, text: "hi", isStreaming: false, status: .sent)))
        store.route(.messageReceived(ChatMessage(id: "bad", role: .local, text: "no", isStreaming: false, status: .failed)))
        store.resendMessage(itemID: "ok")   // not failed -> ignored
        store.resendMessage(itemID: "bad")  // failed -> resend + optimistic .sending
        await settle()
        XCTAssertEqual(sink.all().count, 1)
        XCTAssertTrue({ if case .resendMessage("bad") = sink.all().first { return true }; return false }())
        for case .message(let m) in store.items where m.id == "bad" {
            XCTAssertEqual(m.status, .sending, "a resent message shows as sending again")
        }
    }

    func testResendAlsoRetriesAFailedFileTransfer() async {
        let (store, sink) = makeStarted(capabilities: allCaps())
        store.route(.fileAdded(ChatFile(id: "f1", role: .local, name: "a.pdf", transferStatus: .failed)))
        store.resendMessage(itemID: "f1")
        await settle()
        XCTAssertTrue({ if case .resendMessage("f1") = sink.all().first { return true }; return false }())
        for case .file(let file) in store.items where file.id == "f1" {
            XCTAssertEqual(file.transferStatus, .transferring, "a retried file transfer restarts as transferring")
        }
    }

    func testReplySendRoutesThroughSendMessageWhenAllowed() async {
        let (store, sink) = makeStarted(features: ["features": ["replies": true]], capabilities: allCaps())
        store.route(.messageReceived(remote("orig")))
        store.draft = "sure"
        store.submitDraft(replyTo: "orig")
        await settle()
        // The optimistic local message carries the reply ref; the transport gets sendMessage with the
        // optimistic id as its localID handle.
        XCTAssertTrue({ if case .sendMessage("sure", "orig", _) = sink.all().first { return true }; return false }(),
                      "a gated reply routes through sendMessage")
        let last = store.items.last
        if case .message(let m)? = last {
            XCTAssertEqual(m.replyTo?.itemID, "orig")
            XCTAssertEqual(m.status, .sending, "readReceipts capability -> optimistic sending status")
        } else {
            XCTFail("expected an optimistic local message")
        }
    }

    // The affordance-availability matrix the view reads to show/hide each menu item: an affordance is
    // available only when the document's feature AND the transport's capability are both on.
    func testAffordanceGatingMatrix() {
        func caps(_ on: Bool) -> ChatTransportCapabilities {
            on ? allCaps() : ChatTransportCapabilities()
        }
        // reactions
        XCTAssertTrue(makeStarted(features: ["features": ["reactions": true]], capabilities: caps(true)).0.canReact)
        XCTAssertFalse(makeStarted(features: ["features": ["reactions": true]], capabilities: caps(false)).0.canReact)
        XCTAssertFalse(makeStarted(features: [:], capabilities: caps(true)).0.canReact)
        // editing
        XCTAssertTrue(makeStarted(features: ["features": ["editing": true]], capabilities: caps(true)).0.canEditMessages)
        XCTAssertFalse(makeStarted(features: [:], capabilities: caps(true)).0.canEditMessages)
        // deletion
        XCTAssertTrue(makeStarted(features: ["features": ["deletion": true]], capabilities: caps(true)).0.canDeleteMessages)
        XCTAssertFalse(makeStarted(features: ["features": ["deletion": true]], capabilities: caps(false)).0.canDeleteMessages)
        // replies
        XCTAssertTrue(makeStarted(features: ["features": ["replies": true]], capabilities: caps(true)).0.canReply)
        XCTAssertFalse(makeStarted(features: [:], capabilities: caps(true)).0.canReply)
        // attach is host-gated (not a capability): present iff the host enabled it (in the
        // ActionUI add-on: iff attachActionID is set, which ChatConfig maps to attachEnabled).
        XCTAssertTrue(makeStarted(features: ["attachActionID": "chat.attach"], capabilities: caps(false)).0.canAttach)
        XCTAssertFalse(makeStarted(features: [:], capabilities: caps(true)).0.canAttach)
    }

    func testPlainSendDropsReplyRefWhenRepliesNotAllowed() async {
        // replies feature off: even with replyTo, the reply degrades. Under a messageIdentity transport
        // a plain send still routes through sendMessage (carrying the localID handle), but with a nil ref.
        let (store, sink) = makeStarted(features: [:], capabilities: allCaps())
        store.route(.messageReceived(remote("orig")))
        store.draft = "hi"
        store.submitDraft(replyTo: "orig")
        await settle()
        XCTAssertTrue({ if case .sendMessage("hi", nil, _) = sink.all().first { return true }; return false }(),
                      "reply not enabled -> sendMessage with the ref dropped")
        if case .message(let m)? = store.items.last {
            XCTAssertNil(m.replyTo, "the dropped reply leaves no ref on the optimistic message")
        }
    }

    // MARK: - Optimistic-id reconciliation (messageIdentity)

    func testReKeyOnConfirmationPreservesFieldsAndLandsLaterEvents() async {
        let (store, sink) = makeStarted(capabilities: allCaps())
        store.draft = "hi"
        store.submitDraft()
        await settle()
        // A messageIdentity send routes through sendMessage carrying the optimistic id as its localID.
        XCTAssertTrue({ if case .sendMessage("hi", nil, "user-1") = sink.all().first { return true }; return false }(),
                      "a messageIdentity plain send routes through sendMessage with the optimistic localID")
        XCTAssertEqual(store.items.last?.id, "user-1")
        if case .message(let m)? = store.items.last {
            XCTAssertEqual(m.status, .sending, "readReceipts capability -> optimistic sending status")
        } else {
            XCTFail("expected an optimistic local message")
        }
        // Confirmation re-keys the item in place, preserving text / status.
        store.route(.messageIDConfirmed(localID: "user-1", serverID: "srv-9"))
        XCTAssertEqual(store.items.last?.id, "srv-9", "the optimistic item is re-keyed to its server id")
        if case .message(let m)? = store.items.last {
            XCTAssertEqual(m.text, "hi")
            XCTAssertEqual(m.status, .sending, "status is preserved across the re-key")
        }
        // A later server-keyed status change lands on the re-keyed item.
        store.route(.messageStatusChanged(itemID: "srv-9", status: .delivered))
        if case .message(let m)? = store.items.last {
            XCTAssertEqual(m.status, .delivered, "the ladder advances on the re-keyed item")
        }
    }

    func testPreConfirmFailureAddressesTheOptimisticId() async {
        let (store, sink) = makeStarted(capabilities: allCaps())
        store.draft = "hi"
        store.submitDraft()
        await settle()
        // Before any server id exists, a send failure is addressed by the optimistic localID.
        store.route(.messageStatusChanged(itemID: "user-1", status: .failed))
        if case .message(let m)? = store.items.last {
            XCTAssertEqual(m.status, .failed)
        } else {
            XCTFail("expected the optimistic message")
        }
        // The retry emits resendMessage keyed by the same optimistic id.
        store.resendMessage(itemID: "user-1")
        await settle()
        XCTAssertTrue(sink.all().contains { if case .resendMessage("user-1") = $0 { return true }; return false },
                      "a pre-confirm retry resends by the optimistic id")
    }

    func testConfirmationWithExistingServerIdDropsOptimisticDuplicate() async {
        let (store, _) = makeStarted(capabilities: allCaps())
        // The server delivered the message as its own item first.
        store.route(.messageReceived(ChatMessage(id: "srv-1", role: .local, text: "hi", isStreaming: false)))
        store.draft = "hi"
        store.submitDraft()
        await settle()
        XCTAssertEqual(store.items.count, 2, "the seeded server item plus the optimistic send")
        store.route(.messageIDConfirmed(localID: "user-1", serverID: "srv-1"))
        XCTAssertEqual(store.items.count, 1, "the optimistic duplicate is dropped")
        XCTAssertFalse(store.items.contains { $0.id == "user-1" }, "no optimistic item remains")
        XCTAssertTrue(store.items.contains { $0.id == "srv-1" })
    }

    func testConfirmationForUnknownIdIsAHarmlessNoOp() async {
        let (store, _) = makeStarted(capabilities: allCaps())
        store.route(.messageReceived(remote("r1")))
        let before = store.items.count
        store.route(.messageIDConfirmed(localID: "nope", serverID: "x"))
        XCTAssertEqual(store.items.count, before, "an unknown localID is a no-op")
        // Idempotent: a second confirmation for an already-reconciled/unknown id is also a no-op.
        store.route(.messageIDConfirmed(localID: "nope", serverID: "x"))
        XCTAssertEqual(store.items.count, before)
    }

    func testV1TransportStillRoutesThroughPrompt() async {
        // No messageIdentity, no replies: the send is byte-identical to the v1 prompt path.
        let (store, sink) = makeStarted(capabilities: ChatTransportCapabilities())
        store.draft = "hi"
        store.submitDraft()
        await settle()
        XCTAssertTrue({ if case .prompt("hi") = sink.all().first { return true }; return false }(),
                      "a v1 transport still emits .prompt")
        XCTAssertFalse(sink.all().contains { if case .sendMessage = $0 { return true }; return false },
                       "a v1 transport never sees sendMessage")
    }

    // MARK: - Connection-state gating (reportsConnectionState)

    func testConnectionGatingOnForAReportingTransport() {
        let (store, _) = makeStarted(capabilities: allCaps())
        // A reporting transport starts connection-gated (state .connecting).
        XCTAssertFalse(store.isConnectionReady, "a reporting transport is not ready until connected")
        XCTAssertEqual(store.connectionBannerText, "Connecting...")

        store.route(.connectionStateChanged(.connected))
        XCTAssertTrue(store.isConnectionReady, "connected -> ready")
        XCTAssertNil(store.connectionBannerText, "no banner when connected")

        store.route(.connectionStateChanged(.reconnecting))
        XCTAssertFalse(store.isConnectionReady)
        XCTAssertEqual(store.connectionBannerText, "Reconnecting...")

        store.route(.connectionStateChanged(.offline))
        XCTAssertFalse(store.isConnectionReady)
        XCTAssertEqual(store.connectionBannerText, "Offline")
    }

    func testConnectionGatingOffForAV1Transport() {
        // A transport that does not report connection state never gates the composer, whatever the
        // store's connectionState happens to be.
        let (store, _) = makeStarted(capabilities: ChatTransportCapabilities())
        XCTAssertTrue(store.isConnectionReady, "no reportsConnectionState -> always ready")
        XCTAssertNil(store.connectionBannerText, "no reportsConnectionState -> no banner")
        store.route(.connectionStateChanged(.offline))
        XCTAssertTrue(store.isConnectionReady, "still ready: the transport does not report connection state")
        XCTAssertNil(store.connectionBannerText)
    }

    // End-to-end through the REAL local-p2p transport wired to a real store (not a mock + hand-routed
    // events): a send is re-keyed to the server id and laddered to .read, and the link reports connected.
    func testLocalP2PEndToEndReKeysLaddersAndConnects() async {
        let proto = "local-p2p-e2e-\(UUID().uuidString)"
        ChatTransportRegistry.shared.register(proto) { config, _ in LocalP2PTransport(config: config) }
        let logger = P3Logger()
        // The store holds `contentSource` weakly (the engine's ViewModel owns it), so the source must
        // stay alive for the whole test or the config subscription is torn down before it delivers.
        let source = FakeConfigSource(config: ["protocol": proto,
                                               "transport": ["scenario": "people", "stepMs": 0]])
        let store = ChatStore(config: ChatConfiguration(dictionary: [:], logger: logger),
                              logger: logger,
                              contentSource: source, scheduler: ManualChatScheduler())
        store.start()
        await settle()
        XCTAssertEqual(store.connectionState, .connected, "the link comes up on start")
        XCTAssertTrue(store.isConnectionReady)

        store.draft = "ping"
        store.submitDraft()
        await settle()

        // The message we sent ("ping") was optimistically "user-1" and is now re-keyed to a srv-* id,
        // laddered to .read by the peer's watermark - all addressed by the server id, never "user-1".
        let sent = store.items.compactMap { item -> ChatMessage? in
            if case .message(let m) = item, m.text == "ping" { return m }
            return nil
        }.first
        let reKeyedID = sent?.id
        let reKeyedStatus = sent?.status
        let hasOptimistic = store.items.contains { $0.id == "user-1" }

        // Tear the transport down and settle BEFORE asserting/returning, so this real-transport test
        // leaves no drain / ladder tasks outliving it to perturb the rest of the suite's timing.
        store.teardown()
        await settle()

        XCTAssertNotNil(reKeyedID, "the sent message is present")
        XCTAssertEqual(reKeyedID?.hasPrefix("srv-"), true, "the optimistic id was re-keyed to the server id")
        XCTAssertEqual(reKeyedStatus, .read, "the delivery ladder reached .read on the re-keyed id")
        XCTAssertFalse(hasOptimistic, "no optimistic id remains")
    }
}
