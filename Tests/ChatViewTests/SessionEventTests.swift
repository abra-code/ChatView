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

    // MARK: - The two-line split

    /// The marker stacks the stamp under the sentence, so the break has to fall between them and
    /// nowhere else: a headline carrying the date would wrap mid-model-name again.
    func testTheStampSplitsOffTheHeadline() throws {
        let lines = SessionEventText.lines(
            SessionEvent(id: "se-1", kind: .resumed,
                         timestamp: "2026-08-17T15:42:00Z", model: "gemma-4-31B-it-UD-Q4_K_XL"))
        XCTAssertEqual(lines.headline, "Resumed with gemma-4-31B-it-UD-Q4_K_XL")
        XCTAssertFalse(lines.headline.contains("2026"), lines.headline)
        // The formatted stamp is locale-dependent, so pin what it is NOT: the wire string. A
        // `stamp` that handed back its input would otherwise satisfy every other assertion here.
        let stamp = try XCTUnwrap(lines.timestamp)
        XCTAssertFalse(stamp.contains("T15:42:00Z"), stamp)
    }

    /// No stamp means no second line at all rather than an empty one - a blank row under the
    /// sentence reads as a rendering bug.
    func testAMissingStampLeavesNoSecondLine() {
        let lines = SessionEventText.lines(SessionEvent(id: "se-1", kind: .started, model: "Qwen3 4B"))
        XCTAssertEqual(lines.headline, "Started with Qwen3 4B")
        XCTAssertNil(lines.timestamp)
        XCTAssertEqual(lines.joined, "Started with Qwen3 4B")
    }

    /// The digest branch is the one that was restructured - the stamp used to be appended
    /// inside it - so its split is the one that could regress in silence. The headline carries
    /// the size and the summarizer; the time still leaves for the second line.
    func testADigestHeadlineAlsoSplitsOffTheStamp() {
        let lines = SessionEventText.lines(
            SessionEvent(id: "c", kind: .resumed, timestamp: "2026-08-17T15:42:00Z"),
            digest: SessionDigest(summarizer: "Qwen3 4B", droppedTurns: 64))
        XCTAssertEqual(lines.headline, "Resumed - 64 earlier messages summarized by Qwen3 4B")
        XCTAssertNotNil(lines.timestamp)
    }

    /// The spoken label and the printed marker come from the same composition: VoiceOver reads
    /// `joined`, the view stacks the halves. Asserted against the literal sentence rather than
    /// against `caption`, which is DEFINED as `joined` and so could only assert an identity.
    func testTheJoinedLineIsTheWholeSentence() {
        let event = SessionEvent(id: "se-1", kind: .modelChanged, model: "Llama 3.1 8B")
        XCTAssertEqual(SessionEventText.lines(event).joined, "Switched to Llama 3.1 8B")
    }
}
