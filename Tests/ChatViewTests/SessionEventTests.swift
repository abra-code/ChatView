// SessionEventTests.swift - the transcript's record of the session changing under it.
//
// A session event is the only item a READER of an old conversation needs that no message can
// supply: which model wrote which part, and when the conversation was picked back up. The status
// line cannot answer it - it only ever shows the last state - so these assertions are about the
// item surviving a round trip and reading correctly with pieces missing, which is the normal case
// rather than the edge one.

import XCTest
@testable import ChatView

final class SessionEventTests: XCTestCase {

    // MARK: - Persistence

    func testSessionEventSurvivesATranscriptRoundTrip() throws {
        let event = SessionEvent(id: "se-1", kind: .resumed,
                                 timestamp: "2026-08-17T15:42:00Z", model: "Qwen3 4B")
        let transcript = ChatTranscript(version: 1, items: [.sessionEvent(event)])

        let data = try JSONEncoder().encode(transcript)
        let back = try JSONDecoder().decode(ChatTranscript.self, from: data)

        XCTAssertEqual(back.items.count, 1)
        guard case .sessionEvent(let decoded) = back.items[0] else {
            return XCTFail("expected a sessionEvent, got \(back.items[0])")
        }
        XCTAssertEqual(decoded, event)
    }

    /// The discriminator is the on-disk contract - a host's own store keys off it (Cadabra's
    /// history_store.py keeps an explicit set of item types and drops anything else), so a rename
    /// here silently costs every saved conversation its markers.
    func testTheEncodedTypeDiscriminatorIsStable() throws {
        let event = SessionEvent(id: "se-1", kind: .started)
        let data = try JSONEncoder().encode(ChatItem.sessionEvent(event))
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(json["type"] as? String, "sessionEvent")
    }

    func testKindsEncodeAsTheirNames() throws {
        for (kind, expected) in [(SessionEvent.Kind.started, "started"),
                                 (.resumed, "resumed"),
                                 (.modelChanged, "modelChanged")] {
            let data = try JSONEncoder().encode(SessionEvent(id: "x", kind: kind))
            let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
            XCTAssertEqual(json["kind"] as? String, expected)
        }
    }

    // MARK: - Wording

    func testCaptionNamesTheModelAndTheTime() {
        let caption = SessionEventText.caption(
            SessionEvent(id: "se-1", kind: .resumed,
                         timestamp: "2026-08-17T15:42:00Z", model: "Qwen3 4B"))
        XCTAssertTrue(caption.hasPrefix("Resumed with Qwen3 4B"), caption)
        // The formatted time is locale-dependent, so assert it is PRESENT rather than its shape -
        // an assertion on "3:42 PM" would pass here and fail on a 24-hour machine.
        XCTAssertGreaterThan(caption.count, "Resumed with Qwen3 4B".count, caption)
    }

    /// The commonest case in this app: mlx-agent advertises no model at all, so the marker has a
    /// verb and a time and nothing else. It must not read as "Resumed with  ".
    func testCaptionOmitsAMissingModelRatherThanLeavingAGap() {
        let caption = SessionEventText.caption(
            SessionEvent(id: "se-1", kind: .resumed, timestamp: "2026-08-17T15:42:00Z", model: nil))
        XCTAssertTrue(caption.hasPrefix("Resumed "), caption)
        XCTAssertFalse(caption.contains("with"), caption)
        XCTAssertFalse(caption.contains("  "), caption)
    }

    func testCaptionSurvivesWithNothingButAKind() {
        XCTAssertEqual(SessionEventText.caption(SessionEvent(id: "se-1", kind: .started)), "Started")
    }

    /// An empty string is not the same as absent when it arrives from JSON, and it would produce
    /// the same trailing-preposition sentence a nil does.
    func testAnEmptyModelIsTreatedAsAbsent() {
        XCTAssertEqual(SessionEventText.caption(SessionEvent(id: "se-1", kind: .started, model: "")),
                       "Started")
    }

    /// A switch reads "to X", not "with X" - the preposition is the difference between naming the
    /// model that took over and naming the one that was already there.
    func testAModelChangeReadsAsAHandover() {
        let caption = SessionEventText.caption(
            SessionEvent(id: "se-1", kind: .modelChanged, model: "Llama 3.1 8B"))
        XCTAssertEqual(caption, "Switched to Llama 3.1 8B")
    }

    /// An unparseable stamp is dropped rather than printed raw: a marker reading
    /// "Resumed with X not-a-date" is worse than one that simply does not say when.
    func testAnUnparseableTimestampIsDropped() {
        let caption = SessionEventText.caption(
            SessionEvent(id: "se-1", kind: .resumed, timestamp: "not-a-date", model: "Qwen3 4B"))
        XCTAssertEqual(caption, "Resumed with Qwen3 4B")
    }
}
