// Tests/ChatViewTests/ChatScrollPinTests.swift
//
// Unit tests for the transcript auto-scroll pin state machine (ChatScrollPinTracker). These pin down
// the behaviors that were impossible to verify by eye and that a regression here would silently break:
// staying pinned + chasing through streaming growth, releasing on a real user scroll-up (including one
// that coincides with a growth flush), never unpinning while a programmatic scroll carries us DOWN to
// the bottom, following a resize, and ignoring the fallback sentinel's empty default.
//
// Geometry model used throughout: a 100 pt viewport (containerHeight). "distance" is points of content
// below the fold; distance <= threshold (24) counts as at-bottom. A sample where the caller has chased
// to the bottom reports distance 0.

import XCTest
@testable import ChatView

@MainActor
final class ChatScrollPinTests: XCTestCase {

    private let threshold: CGFloat = 24
    private let container: CGFloat = 100

    /// Seeds the tracker with an at-bottom sample so later samples have a prior to diff against.
    private func seededTracker(content: CGFloat = 200) -> ChatScrollPinTracker {
        let t = ChatScrollPinTracker()
        XCTAssertEqual(decide(t, pinned: true, distance: 0, content: content), .keep, "seed should be a no-op keep")
        return t
    }

    private func decide(_ t: ChatScrollPinTracker, pinned: Bool, distance: CGFloat,
                        content: CGFloat, container: CGFloat? = nil) -> ChatScrollPinDecision {
        t.decide(isPinned: pinned, distanceFromBottom: distance, contentHeight: content,
                 containerHeight: container ?? self.container, threshold: threshold)
    }

    // MARK: - Streaming growth keeps the pin and chases

    func testGrowthUnderPinnedViewportChasesNeverUnpins() {
        let t = seededTracker(content: 200)
        // Five streaming flushes, each grows content 60pt while the offset lags (distance jumps to 60),
        // then the caller chases (distance back to 0). Must chase on growth, keep at bottom, never unpin.
        var content: CGFloat = 200
        for _ in 0..<5 {
            content += 60
            XCTAssertEqual(decide(t, pinned: true, distance: 60, content: content), .chase,
                           "a growth sample that pushed the bottom off screen must chase")
            XCTAssertEqual(decide(t, pinned: true, distance: 0, content: content), .keep,
                           "after the chase settles we are at the bottom again")
        }
    }

    func testSmallGrowthWithinThresholdStaysPinnedWithoutChasing() {
        let t = seededTracker(content: 200)
        // A 10pt growth leaves the bottom within the 24pt threshold: still at bottom, just keep.
        XCTAssertEqual(decide(t, pinned: true, distance: 10, content: 210), .keep)
    }

    // MARK: - Genuine user scroll-up releases the pin

    func testDecisiveScrollUpUnpins() {
        let t = seededTracker(content: 260)
        // A single 40pt upward move with stable content is unambiguously the user.
        XCTAssertEqual(decide(t, pinned: true, distance: 40, content: 260), .unpin)
    }

    func testSlowScrollUpAccumulatesThenUnpins() {
        let t = seededTracker(content: 260)
        // Small per-event moves under the threshold stay pinned until the accumulated distance clears it.
        XCTAssertEqual(decide(t, pinned: true, distance: 10, content: 260), .keep)
        XCTAssertEqual(decide(t, pinned: true, distance: 20, content: 260), .keep)
        XCTAssertEqual(decide(t, pinned: true, distance: 26, content: 260), .unpin)
    }

    /// Finding 1 (decisive): a big fling that lands in the SAME sample as a streaming growth flush must
    /// unpin - the growth must not mask the scroll and yank the reader back down.
    func testDecisiveScrollUpCoincidentWithGrowthUnpins() {
        let t = seededTracker(content: 260)
        // content grows 40 AND the user flings up 50 in one sample: distance jumps to 90.
        // userScrollUp = gapDelta(90) - contentDelta(40) = 50 -> unpin, not chase.
        XCTAssertEqual(decide(t, pinned: true, distance: 90, content: 300), .unpin)
    }

    /// Finding 1 (moderate - the round-2 residual): a NORMAL trackpad/wheel scroll-up (well under the
    /// 24pt at-bottom threshold) coincident with a growth flush must also unpin. The old decisive-only
    /// (userScrollUp > threshold) rule chased here and force-snapped the reader back; the exact-cancel
    /// decomposition unpins on any real upward move regardless of the coincident growth's size.
    func testModerateScrollUpCoincidentWithGrowthUnpins() {
        let t = seededTracker(content: 260)
        // content grows 40 AND the user scrolls up 10 in one sample: distance jumps to 50.
        // userScrollUp = gapDelta(50) - contentDelta(40) = 10 -> unpin (would have been .chase before).
        XCTAssertEqual(decide(t, pinned: true, distance: 50, content: 300), .unpin)
    }

    /// A tiny sub-epsilon upward move (layout jitter, not a real scroll) coincident with growth must be
    /// absorbed as noise and chased, never unpinned - this pins the one branch the epsilon guards.
    func testSubEpsilonScrollUpIsAbsorbedAsNoise() {
        let t = seededTracker(content: 260)
        // content grows 29.5 AND the viewport nudges up 0.5 in one sample: distance jumps to 30.
        // userScrollUp = gapDelta(30) - contentDelta(29.5) = 0.5 < epsilon(1) -> chase, not unpin.
        XCTAssertEqual(decide(t, pinned: true, distance: 30, content: 289.5), .chase)
    }

    // MARK: - Programmatic scroll toward the bottom must not be misread as a user scroll

    /// Finding 3: while an animated "jump to latest" carries the viewport DOWN toward the bottom, the
    /// bottom is transiently off screen but the move is downward (userScrollUp <= 0); that must chase to
    /// completion, never unpin (which would flicker the pill and stall following).
    func testDownwardProgrammaticScrollChasesNotUnpins() {
        let t = seededTracker(content: 400)
        // The user is scrolled up and unpinned, resting at distance 90 (this seeds the prior sample).
        XCTAssertEqual(decide(t, pinned: false, distance: 90, content: 400), .keep)
        // They tap "jump to latest": the caller sets the pin true and animates DOWN toward the bottom.
        // The mid-animation frames (distance shrinking 90 -> 60 -> 30) are a downward move, not a user
        // scroll-up, so they chase to completion and never flip the pin back off.
        XCTAssertEqual(decide(t, pinned: true, distance: 60, content: 400), .chase)
        XCTAssertEqual(decide(t, pinned: true, distance: 30, content: 400), .chase)
        XCTAssertEqual(decide(t, pinned: true, distance: 0, content: 400), .keep)
    }

    // MARK: - Resize

    func testContainerShrinkWhilePinnedChases() {
        let t = seededTracker(content: 260)
        // Window shrinks 100 -> 70 with the offset frozen: the bottom drifts 30pt off, but it is a
        // resize (not a user scroll), so chase to stay pinned.
        XCTAssertEqual(decide(t, pinned: true, distance: 30, content: 260, container: 70), .chase)
    }

    // MARK: - Content shrink

    func testContentShrinkWhilePinnedStaysAtBottom() {
        let t = seededTracker(content: 260)
        // A collapsed thought shortens the content so the bottom is above the fold (negative distance):
        // still at bottom, keep.
        XCTAssertEqual(decide(t, pinned: true, distance: -40, content: 220), .keep)
    }

    // MARK: - Re-pin

    func testReturnToBottomRepins() {
        let t = seededTracker(content: 400)
        XCTAssertEqual(decide(t, pinned: false, distance: 200, content: 400), .keep, "reading back stays unpinned")
        XCTAssertEqual(decide(t, pinned: false, distance: 10, content: 400), .repin, "back within threshold re-pins")
    }

    func testUnpinnedAwayFromBottomKeeps() {
        let t = seededTracker(content: 400)
        XCTAssertEqual(decide(t, pinned: false, distance: 300, content: 400), .keep)
    }

    // MARK: - Fallback sentinel default

    /// Finding 2: the pre-macOS-15 sentinel emits containerHeight 0 when it de-materializes. That sample
    /// must be ignored, not read as a huge layout change that snaps a still-pinned reader to the bottom.
    func testZeroContainerHeightIsIgnored() {
        let t = seededTracker(content: 400)
        XCTAssertEqual(decide(t, pinned: true, distance: .greatestFiniteMagnitude, content: 0, container: 0), .ignore)
        XCTAssertEqual(decide(t, pinned: false, distance: .greatestFiniteMagnitude, content: 0, container: 0), .ignore)
    }

    // MARK: - First sample

    func testFirstSampleNeverUnpins() {
        // A fresh tracker whose very first sample is far from the bottom (e.g. a restored transcript
        // before onAppear scrolls): chase, never unpin (its deltas are meaningless with no prior).
        let t = ChatScrollPinTracker()
        XCTAssertEqual(decide(t, pinned: true, distance: 500, content: 800), .chase)
    }

    func testFirstSampleAtBottomKeeps() {
        let t = ChatScrollPinTracker()
        XCTAssertEqual(decide(t, pinned: true, distance: 0, content: 200), .keep)
    }
}
