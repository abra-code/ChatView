// SessionCondenseTests.swift - asking for a summarized restore, and showing what came back.
//
// The feature exists so a person can READ what the model was given in place of the messages it
// no longer has. So the assertions are about two things: the request reaching the wire in the
// shape the agent documents, and the answer surviving into a transcript item a reader can open.
//
// The failure this guards hardest is the quiet one: a condense request that is dropped somewhere
// between the injected content and the prime looks exactly like an agent that chose not to
// condense - full fidelity, no error, just a slower turn nobody attributes to a bug.

import XCTest
@testable import ChatView

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
