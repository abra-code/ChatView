// Tests/DemoSharedTests/RemoteAgentPersistenceTests.swift
//
// The demo screen is the reference host implementation of the cold-launch checkpoint contract
// (plan 4.2a), and section 9's risk 3 names a non-atomic host as the one failure the design
// cannot close in code. A reference implementation that is only checked by eye is not a
// reference - and in fact the first version of this class manufactured exactly the failure it
// was meant to demonstrate the absence of, which is what these tests exist to prevent.

import XCTest
@testable import ChatViewDemoShared
import ChatView

final class RemoteAgentPersistenceTests: XCTestCase {

    private var support: URL!

    override func setUpWithError() throws {
        // Application Support is not redirectable by environment, so the class takes a directory
        // seam. Without it every instance here would share one real file - and whatever a real
        // demo run left in it.
        support = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("cvdemo-persist-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
    }

    private func makeStore() -> RemoteAgentPersistence {
        RemoteAgentPersistence(directory: support)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: support)
    }

    private func entry(type: String, id: String, item: [String: Any]) -> String {
        let envelope: [String: Any] = ["sequence": 1, "type": type, "id": id, "data": item]
        let data = try! JSONSerialization.data(withJSONObject: envelope)
        return String(data: data, encoding: .utf8)!
    }

    private func message(_ id: String, _ text: String) -> String {
        entry(type: "message", id: id,
              data: ["type": "message", "message": ["id": id, "role": "agent", "text": text]])
    }

    private func entry(type: String, id: String, data: [String: Any]) -> String {
        entry(type: type, id: id, item: data)
    }

    private func checkpoint(_ session: String, _ seq: Int) -> String {
        #"{"afterSeq":\#(seq),"sessionId":"\#(session)"}"#
    }

    /// The defect that made the reference implementation a counter-example: reading the file
    /// again mid-session dropped everything recorded since the last checkpoint, and the next
    /// commit then wrote a NEW cursor beside the OLD transcript - losing the turn in between
    /// forever, because the next attach starts after it.
    func testRestoreDoesNotDiscardEntriesRecordedSinceTheLastCheckpoint() throws {
        let store = makeStore()
        store.record(entryJSON: message("acpr-m-2", "turn one"))
        store.commit(checkpointJSON: checkpoint("sess-1", 4))

        store.record(entryJSON: message("acpr-m-6", "turn two"))
        // Whatever the UI does - opening a sheet, a state change, anything that re-evaluates
        // body - must not cost us the in-flight turn.
        _ = store.restoreOnce()
        _ = store.restoreOnce()
        store.commit(checkpointJSON: checkpoint("sess-1", 8))

        let reloaded = makeStore()
        let restored = try XCTUnwrap(reloaded.restoreOnce())
        XCTAssertEqual(restored.afterSeq, 8)
        let items = try XCTUnwrap(restored.content["items"] as? [Any])
        XCTAssertEqual(items.count, 2,
                       "a cursor at seq 8 must be stored beside the transcript that reaches seq 8")
    }

    func testCommittedPairDecodesAsATranscript() throws {
        let store = makeStore()
        store.record(entryJSON: message("acpr-m-2", "hello"))
        store.record(entryJSON: entry(type: "system", id: "s1",
                                      data: ["type": "system", "id": "s1", "text": "note"]))
        store.commit(checkpointJSON: checkpoint("sess-1", 5))

        let restored = try XCTUnwrap(makeStore().restoreOnce())
        XCTAssertEqual(restored.sessionId, "sess-1")
        XCTAssertEqual(restored.afterSeq, 5)
        // The whole point: what the host injects must be something ChatView can decode.
        let transcript = try XCTUnwrap(ChatTranscript.decode(from: restored.content))
        XCTAssertEqual(transcript.items.count, 2)
        XCTAssertEqual(transcript.items.first?.id, "acpr-m-2")
    }

    /// Only `image`, `system`, and `error` carry `id` at the top level of their encoded form,
    /// so recovering an id from the payload silently fails for a tool call - and a re-fire then
    /// appends a duplicate row instead of replacing the one already there.
    func testToolCallReFireReplacesRatherThanDuplicating() throws {
        let pending: [String: Any] = ["type": "toolCall",
                                      "toolCall": ["id": "call-3", "title": "Edit", "kind": "edit",
                                                   "status": "pending", "contentText": ""]]
        let done: [String: Any] = ["type": "toolCall",
                                   "toolCall": ["id": "call-3", "title": "Edit", "kind": "edit",
                                                "status": "completed", "contentText": "Edited 1 file."]]
        let store = makeStore()
        store.record(entryJSON: entry(type: "toolCall", id: "call-3", data: pending))
        store.commit(checkpointJSON: checkpoint("sess-1", 3))

        let reloaded = makeStore()
        _ = reloaded.restoreOnce()
        reloaded.record(entryJSON: entry(type: "toolCall", id: "call-3", data: done))
        reloaded.commit(checkpointJSON: checkpoint("sess-1", 6))

        let restored = try XCTUnwrap(makeStore().restoreOnce())
        let items = try XCTUnwrap(restored.content["items"] as? [[String: Any]])
        XCTAssertEqual(items.count, 1, "a re-fired entry must replace its row, not append a second")
        let status = ((items[0]["toolCall"]) as? [String: Any])?["status"] as? String
        XCTAssertEqual(status, "completed", "and the LAST payload must win")
    }

    /// `thought` is a real transcript item and the store does fire it; leaving it out of the
    /// allowlist drops every reasoning row while the cursor advances past it.
    func testThoughtsArePersisted() throws {
        let store = makeStore()
        store.record(entryJSON: entry(type: "thought", id: "acpr-t-1",
                                      data: ["type": "thought",
                                             "thought": ["id": "acpr-t-1", "role": "agent", "text": "hmm"]]))
        store.commit(checkpointJSON: checkpoint("sess-1", 2))
        let restored = try XCTUnwrap(makeStore().restoreOnce())
        XCTAssertEqual((restored.content["items"] as? [Any])?.count, 1)
    }

    func testNonItemEntryTypesAreNotStored() throws {
        let store = makeStore()
        store.record(entryJSON: message("acpr-m-1", "real"))
        for type in ["plan", "usage", "session", "participants", "messageIdConfirmed"] {
            store.record(entryJSON: entry(type: type, id: "x-\(type)", data: ["anything": true]))
        }
        store.commit(checkpointJSON: checkpoint("sess-1", 9))
        let restored = try XCTUnwrap(makeStore().restoreOnce())
        XCTAssertEqual((restored.content["items"] as? [Any])?.count, 1,
                       "surfaces and bookkeeping are not transcript rows and would fail to decode")
    }

    func testNothingIsWrittenBeforeTheFirstCheckpoint() {
        let store = makeStore()
        store.record(entryJSON: message("acpr-m-2", "in flight"))
        // Entries after the last checkpoint are deliberately not saved: the bridge still has
        // them and the next attach replays them. Saving them WITHOUT a cursor is the lossy case.
        XCTAssertNil(makeStore().restoreOnce())
    }

    func testResetForgetsBothHalves() throws {
        let store = makeStore()
        store.record(entryJSON: message("acpr-m-2", "old session"))
        store.commit(checkpointJSON: checkpoint("sess-1", 4))
        store.reset()
        XCTAssertNil(store.restoreOnce(), "a reset store must not resurrect what it just dropped")
        XCTAssertNil(makeStore().restoreOnce())
    }

    func testCorruptOrTruncatedFileStartsClean() throws {
        let store = makeStore()
        store.record(entryJSON: message("acpr-m-2", "hi"))
        store.commit(checkpointJSON: checkpoint("sess-1", 4))

        let path = support.appendingPathComponent("session.json")
        try Data("{ this is not json".utf8).write(to: path)
        XCTAssertNil(makeStore().restoreOnce(),
                     "an unreadable pair must start clean rather than restore half of it")
    }

    func testMalformedCheckpointDoesNotWrite() {
        let store = makeStore()
        store.record(entryJSON: message("acpr-m-2", "hi"))
        store.commit(checkpointJSON: "not json")
        store.commit(checkpointJSON: #"{"sessionId":"sess-1"}"#)     // no afterSeq
        XCTAssertNil(makeStore().restoreOnce())
    }
}
