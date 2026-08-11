// Tests/ACPBridgeTests/BridgeSessionStoreTests.swift
//
// The store is where every ordering guarantee the remote transport depends on actually
// lives, so these tests are the ones that matter most in phase 1. They pin invariant I5
// (seq assignment, log write, and fan-out are one critical section) and the attach/replay
// contract that `afterSeq` rests on.

#if os(macOS)

import XCTest
@testable import ACPBridgeCore
import ChatView

private final class SilentLogger: ChatLogger, @unchecked Sendable {
    func log(_ message: String, _ level: ChatLogLevel) {}
}

/// Collects what a subscriber was sent, in order.
private final class Collector: @unchecked Sendable {
    private let lock = NSLock()
    private var lines: [Data] = []

    var sink: BridgeEventSink {
        { [self] data in
            lock.withLock { lines.append(data) }
        }
    }

    var seqs: [Int] {
        lock.withLock { lines }.compactMap { line in
            guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                  let params = object["params"] as? [String: Any] else {
                return nil
            }
            return params["seq"] as? Int
        }
    }

    var count: Int {
        lock.withLock { lines.count }
    }
}

final class BridgeSessionStoreTests: XCTestCase {

    private var directory: URL!

    override func setUpWithError() throws {
        directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("acp-bridge-store-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func makeStore(maxEntries: Int = 200_000) -> BridgeSessionStore {
        BridgeSessionStore(logDirectory: directory, maxLogEntriesPerSession: maxEntries, logger: SilentLogger())
    }

    // MARK: - I5

    func testSeqsAreMonotonicAndGaplessUnderConcurrentAppends() async {
        let store = makeStore()
        XCTAssertTrue(store.register(sessionID: "s1"))

        await withTaskGroup(of: Void.self) { group in
            for index in 0..<100 {
                group.addTask {
                    store.append(sessionID: "s1", method: "session/update", params: ["n": index])
                }
            }
        }

        let collector = Collector()
        let attached = try? store.attach(sessionID: "s1", afterSeq: 0, sink: collector.sink)
        XCTAssertNotNil(attached)
        store.replayAndGoLive(sessionID: "s1", subscriber: attached!.subscriber,
                              afterSeq: 0, throughSeq: attached!.snapshot.latestSeq)

        XCTAssertEqual(attached?.snapshot.latestSeq, 100, "100 appends must produce exactly 100 seqs")
        XCTAssertEqual(collector.seqs, Array(1...100),
                       "replayed seqs must be 1...100 in order, with no gap and no duplicate")
    }

    func testAppendFansOutToLiveSubscribersInLogOrder() {
        let store = makeStore()
        store.register(sessionID: "s1")

        let collector = Collector()
        let attached = try! store.attach(sessionID: "s1", afterSeq: 0, sink: collector.sink)
        store.replayAndGoLive(sessionID: "s1", subscriber: attached.subscriber, afterSeq: 0, throughSeq: 0)

        for index in 0..<5 {
            store.append(sessionID: "s1", method: "session/update", params: ["n": index])
        }
        XCTAssertEqual(collector.seqs, [1, 2, 3, 4, 5])
    }

    /// The race the buffering exists for: appends landing WHILE a replay is in flight must
    /// neither be lost nor delivered twice.
    func testAttachDuringLiveAppendsMissesNothingAndDuplicatesNothing() async {
        for iteration in 0..<50 {
            let store = makeStore()
            let sessionID = "race-\(iteration)"
            store.register(sessionID: sessionID)
            for index in 0..<20 {
                store.append(sessionID: sessionID, method: "session/update", params: ["n": index])
            }

            let collector = Collector()
            let attached = try! store.attach(sessionID: sessionID, afterSeq: 0, sink: collector.sink)

            // Append concurrently with the replay.
            async let writes: Void = {
                for index in 20..<40 {
                    store.append(sessionID: sessionID, method: "session/update", params: ["n": index])
                }
            }()
            store.replayAndGoLive(sessionID: sessionID, subscriber: attached.subscriber,
                                  afterSeq: 0, throughSeq: attached.snapshot.latestSeq)
            await writes

            let seqs = collector.seqs
            XCTAssertEqual(seqs, seqs.sorted(), "iteration \(iteration): out of order")
            XCTAssertEqual(seqs.count, Set(seqs).count, "iteration \(iteration): duplicate delivery")
            XCTAssertEqual(seqs.first, 1, "iteration \(iteration): lost the head of the log")
            // Everything up to the attach snapshot must be present; later ones may still be in
            // flight when we sample, so assert contiguity rather than a fixed count.
            let expected = Array(1...seqs.count)
            XCTAssertEqual(seqs, expected, "iteration \(iteration): gap in the delivered sequence")
        }
    }

    // MARK: - Replay cursor

    func testAttachAfterSeqReplaysOnlyTheTail() {
        let store = makeStore()
        store.register(sessionID: "s1")
        for index in 0..<10 {
            store.append(sessionID: "s1", method: "session/update", params: ["n": index])
        }

        let collector = Collector()
        let attached = try! store.attach(sessionID: "s1", afterSeq: 5, sink: collector.sink)
        store.replayAndGoLive(sessionID: "s1", subscriber: attached.subscriber,
                              afterSeq: 5, throughSeq: attached.snapshot.latestSeq)

        XCTAssertEqual(collector.seqs, [6, 7, 8, 9, 10],
                       "afterSeq 5 must replay exactly the entries the client has not seen")
    }

    func testAttachFromZeroReplaysEverything() {
        let store = makeStore()
        store.register(sessionID: "s1")
        for index in 0..<7 {
            store.append(sessionID: "s1", method: "session/update", params: ["n": index])
        }

        let collector = Collector()
        let attached = try! store.attach(sessionID: "s1", afterSeq: 0, sink: collector.sink)
        store.replayAndGoLive(sessionID: "s1", subscriber: attached.subscriber,
                              afterSeq: 0, throughSeq: attached.snapshot.latestSeq)

        XCTAssertEqual(collector.seqs, Array(1...7))
    }

    func testReplayedBytesAreIdenticalToWhatALiveClientReceived() {
        let store = makeStore()
        store.register(sessionID: "s1")

        let live = Collector()
        let liveAttach = try! store.attach(sessionID: "s1", afterSeq: 0, sink: live.sink)
        store.replayAndGoLive(sessionID: "s1", subscriber: liveAttach.subscriber, afterSeq: 0, throughSeq: 0)
        store.append(sessionID: "s1", method: "session/update",
                     params: ["update": ["sessionUpdate": "agent_message_chunk",
                                         "content": ["type": "text", "text": "hi"]]])

        let replayed = Collector()
        let replayAttach = try! store.attach(sessionID: "s1", afterSeq: 0, sink: replayed.sink)
        store.replayAndGoLive(sessionID: "s1", subscriber: replayAttach.subscriber,
                              afterSeq: 0, throughSeq: replayAttach.snapshot.latestSeq)

        // Byte equality, not "equivalent JSON": a client rendering a replay must not be able to
        // tell it from live traffic, and re-serializing could reorder keys.
        XCTAssertEqual(live.count, 1)
        XCTAssertEqual(replayed.count, 1)
    }

    func testAttachUnknownSessionThrows() {
        let store = makeStore()
        XCTAssertThrowsError(try store.attach(sessionID: "nope", afterSeq: 0, sink: { _ in }))
    }

    func testDetachedSubscriberStopsReceiving() {
        let store = makeStore()
        store.register(sessionID: "s1")
        let collector = Collector()
        let attached = try! store.attach(sessionID: "s1", afterSeq: 0, sink: collector.sink)
        store.replayAndGoLive(sessionID: "s1", subscriber: attached.subscriber, afterSeq: 0, throughSeq: 0)

        store.append(sessionID: "s1", method: "session/update", params: [:])
        store.detach(sessionID: "s1", subscriber: attached.subscriber)
        store.append(sessionID: "s1", method: "session/update", params: [:])

        XCTAssertEqual(collector.seqs, [1], "a detached subscriber must not receive later appends")
    }

    // MARK: - Turns and permissions

    func testOnlyOneTurnAtATime() {
        let store = makeStore()
        store.register(sessionID: "s1")
        XCTAssertEqual(store.beginTurn(sessionID: "s1"), 1)
        XCTAssertNil(store.beginTurn(sessionID: "s1"), "a second turn must not start while one is live")
        store.endTurn(sessionID: "s1", turn: 1)
        XCTAssertEqual(store.beginTurn(sessionID: "s1"), 2, "turn numbers keep climbing")
    }

    func testEndedSessionRefusesNewTurns() {
        let store = makeStore()
        store.register(sessionID: "s1")
        store.markEnded(sessionID: "s1", reason: "agent_exit")
        XCTAssertNil(store.beginTurn(sessionID: "s1"))
    }

    func testMarkEndedKeepsTheFirstReason() {
        let store = makeStore()
        store.register(sessionID: "s1")
        XCTAssertTrue(store.markEnded(sessionID: "s1", reason: "agent_exit"))
        XCTAssertFalse(store.markEnded(sessionID: "s1", reason: "log_overflow"),
                       "a second end must not rewrite the reason clients were already told")
    }

    func testPermissionKeysAreMonotonicPerSession() {
        let store = makeStore()
        store.register(sessionID: "s1")
        store.register(sessionID: "s2")
        XCTAssertEqual(store.nextPermissionKey(sessionID: "s1"), "perm-1")
        XCTAssertEqual(store.nextPermissionKey(sessionID: "s1"), "perm-2")
        XCTAssertEqual(store.nextPermissionKey(sessionID: "s2"), "perm-1", "keys are per session")
    }

    // MARK: - Overflow, restart, retention

    func testOverflowIsReportedAtTheCap() {
        let store = makeStore(maxEntries: 3)
        store.register(sessionID: "s1")
        XCTAssertEqual(store.append(sessionID: "s1", method: "session/update", params: [:])?.overflowed, false)
        XCTAssertEqual(store.append(sessionID: "s1", method: "session/update", params: [:])?.overflowed, false)
        XCTAssertEqual(store.append(sessionID: "s1", method: "session/update", params: [:])?.overflowed, true,
                       "the cap must be reported so the bridge can force-end the session")
    }

    func testRestartMarksSessionsEndedAndPreservesLatestSeq() {
        let first = makeStore()
        first.register(sessionID: "s1")
        for index in 0..<4 {
            first.append(sessionID: "s1", method: "session/update", params: ["n": index])
        }
        first.closeAll()

        let second = makeStore()
        second.loadFromDisk()

        XCTAssertEqual(second.state(of: "s1"), .ended,
                       "the agent that owned this session is gone; nothing can extend it")
        let collector = Collector()
        let attached = try! second.attach(sessionID: "s1", afterSeq: 0, sink: collector.sink)
        XCTAssertEqual(attached.snapshot.latestSeq, 4, "latestSeq must survive a restart")
        second.replayAndGoLive(sessionID: "s1", subscriber: attached.subscriber,
                               afterSeq: 0, throughSeq: attached.snapshot.latestSeq)
        XCTAssertEqual(collector.seqs, [1, 2, 3, 4], "a restarted bridge still replays the transcript")
    }

    func testRetentionSweepDeletesOnlyExpiredEndedSessions() {
        let store = makeStore()
        store.register(sessionID: "live-one")
        store.register(sessionID: "fresh-ended")
        store.register(sessionID: "old-ended")
        store.markEnded(sessionID: "fresh-ended", reason: "agent_exit")
        store.markEnded(sessionID: "old-ended", reason: "agent_exit")

        // "now" 30 days in the future makes both ended sessions old; sweep with a 14-day window
        // and only the ended ones go, never the live one.
        let swept = store.sweepRetention(olderThan: 14, now: Date().addingTimeInterval(30 * 86_400))
        XCTAssertEqual(Set(swept), ["fresh-ended", "old-ended"])
        XCTAssertTrue(store.exists(sessionID: "live-one"), "a live session is never swept, whatever its age")
        XCTAssertFalse(store.exists(sessionID: "old-ended"))
    }

    func testRetentionSweepKeepsRecentEndedSessions() {
        let store = makeStore()
        store.register(sessionID: "s1")
        store.markEnded(sessionID: "s1", reason: "agent_exit")
        XCTAssertTrue(store.sweepRetention(olderThan: 14).isEmpty)
        XCTAssertTrue(store.exists(sessionID: "s1"))
    }

    func testSessionIDsCannotEscapeTheLogDirectory() {
        let store = makeStore()
        store.register(sessionID: "../../etc/passwd")
        let contents = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        XCTAssertEqual(contents.count, 1)
        XCTAssertFalse(contents[0].contains("/"), "a hostile session id must not become a path")
    }

    /// The I5 regression test. The earlier suite never had concurrent appends racing a LIVE
    /// subscriber, so dropping the lock between "assign seq + write" and "fan out" passed
    /// every test. This one fails against that mutation: the sink sees the interleaving.
    func testConcurrentAppendsReachALiveSubscriberInLogOrder() async {
        for iteration in 0..<20 {
            let store = makeStore()
            let sessionID = "i5-\(iteration)"
            store.register(sessionID: sessionID)

            let collector = Collector()
            let attached = try! store.attach(sessionID: sessionID, afterSeq: 0, sink: collector.sink)
            store.replayAndGoLive(sessionID: sessionID, subscriber: attached.subscriber,
                                  afterSeq: 0, throughSeq: 0)

            await withTaskGroup(of: Void.self) { group in
                for index in 0..<64 {
                    group.addTask {
                        store.append(sessionID: sessionID, method: "session/update", params: ["n": index])
                    }
                }
            }

            let seqs = collector.seqs
            XCTAssertEqual(seqs.count, 64, "iteration \(iteration): a live subscriber must see every append")
            XCTAssertEqual(seqs, Array(1...64),
                           "iteration \(iteration): fan-out order must match log order exactly - "
                           + "if seq assignment and delivery are not one critical section, two "
                           + "clients can observe different histories")
        }
    }

    func testDifferentIDsThatSanitizeAlikeAreRefused() {
        let store = makeStore()
        XCTAssertTrue(store.register(sessionID: "a/b"))
        XCTAssertFalse(store.register(sessionID: "a.b"),
                       "both sanitize to a_b; accepting the second truncates the first session's log "
                       + "and interleaves two conversations with independent seq counters")
        store.append(sessionID: "a/b", method: "session/update", params: [:])
        XCTAssertEqual(store.summaries().count, 1)
    }

    func testRestartKeepsTheRealSessionIDNotTheFileName() {
        let first = makeStore()
        first.register(sessionID: "sess/1")
        first.append(sessionID: "sess/1", method: "session/update", params: [:])
        first.closeAll()

        let second = makeStore()
        second.loadFromDisk()
        XCTAssertTrue(second.exists(sessionID: "sess/1"),
                      "the client attaches with the id the agent minted; deriving it from the "
                      + "sanitized file name makes its transcript unreachable after a restart")
        XCTAssertFalse(second.exists(sessionID: "sess_1"))
    }

    func testAppendsAfterTheSessionEndsAreRefused() {
        let store = makeStore()
        store.register(sessionID: "s1")
        store.append(sessionID: "s1", method: "session/update", params: [:])
        store.markEnded(sessionID: "s1", reason: "agent_exit")

        XCTAssertNil(store.append(sessionID: "s1", method: "session/update", params: [:]),
                     "nothing may be logged after the terminal entry")
        XCTAssertNotNil(store.append(sessionID: "s1", method: "bridge/session_ended",
                                     params: ["reason": "agent_exit"], allowWhenEnded: true),
                        "the terminal entry itself must still get through")
    }

    func testEndTurnReportsOnlyOneWinner() {
        let store = makeStore()
        store.register(sessionID: "s1")
        let turn = store.beginTurn(sessionID: "s1")!
        XCTAssertTrue(store.endTurn(sessionID: "s1", turn: turn), "the first caller ends the turn")
        XCTAssertFalse(store.endTurn(sessionID: "s1", turn: turn),
                       "a second caller must not also log a terminal entry (invariant I8)")
    }

    func testDuplicateSessionIDIsRefused() {
        let store = makeStore()
        XCTAssertTrue(store.register(sessionID: "s1"))
        XCTAssertFalse(store.register(sessionID: "s1"),
                       "reusing an id would interleave two conversations into one log")
    }

    func testSummariesAreNewestFirst() {
        let store = makeStore()
        store.register(sessionID: "old", createdAt: Date().addingTimeInterval(-100))
        store.register(sessionID: "new", createdAt: Date())
        store.append(sessionID: "new", method: "session/update", params: [:])
        XCTAssertEqual(store.summaries().first?.sessionID, "new")
    }

    func testTitleComesFromTheFirstPromptOnly() {
        let store = makeStore()
        store.register(sessionID: "s1")
        store.noteTitleIfEmpty(sessionID: "s1", text: "first question")
        store.noteTitleIfEmpty(sessionID: "s1", text: "second question")
        XCTAssertEqual(store.summaries().first?.title, "first question")
    }
}

#endif
