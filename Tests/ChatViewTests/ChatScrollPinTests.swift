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

    // MARK: - Re-measure artifacts (the "streaming stopped following" bug)
    //
    // Field trace (a short transcript, AppKit-backed markdown rows re-measuring as text streams in):
    // the reported contentHeight oscillates by ~100pt, and with the content near the container height
    // the scroll view clamps its own contentOffset. The clamp and its rebound are indistinguishable
    // from a user drag in the offset algebra, so the pin flapped unpin -> repin -> unpin mid-answer and
    // the transcript stopped following. Both halves are pinned down here.

    /// The clamp half, from the trace: content 1030 -> 926 while the offset falls 52 -> 0, so the
    /// algebra reports a +52 upward move on a sample where the user did nothing.
    func testContentShrinkThatMovesTheOffsetDoesNotUnpin() {
        let t = seededTracker(content: 1030)
        // Seed sample sits at the bottom; then the shrink: gap 0 -> 64 with content 1030 -> 926 gives
        // userScrollUp = gapDelta(64) - contentDelta(-104) = +168, well past the epsilon.
        XCTAssertEqual(decide(t, pinned: true, distance: 64, content: 926), .chase,
                       "an offset move caused by the content shrinking under it is not a user scroll")
    }

    /// The rebound half, from the same trace (samples 69-71): the height comes back but the clamped
    /// offset does not, so the apparent upward move lands on a sample whose content GREW - past the
    /// shrink guard. The re-measure window is what rejects it.
    func testShrinkReboundDoesNotUnpin() {
        let t = seededTracker(content: 660)
        // Shrink 660 -> 575, still above the fold (negative distance = at bottom).
        XCTAssertEqual(decide(t, pinned: true, distance: -28, content: 575), .keep, "the shrink itself")
        // Rebound 575 -> 608: gapDelta 61 - contentDelta 33 = +28 apparent upward move. Unconfirmed
        // while the height is still moving - and the answer to "unsure" is to do nothing. It is NOT to
        // chase: that is a guess that the reader did not move, imposed by scrolling them back, and when
        // the guess is wrong the transcript is fighting someone who is actively scrolling.
        XCTAssertEqual(decide(t, pinned: true, distance: 33, content: 608), .keep,
                       "the rebound's apparent scroll-up is unconfirmed while the height re-measures")
        // And the reversal that always follows: gapDelta 30 - contentDelta 58 = -28. Not an upward move
        // at all, so the transcript resumes following, and the run resets so no second sample confirms.
        XCTAssertEqual(decide(t, pinned: true, distance: 63, content: 666), .chase,
                       "the reversal resets the run, so no second sample ever confirms")
    }

    /// The window must not swallow a REAL drag: a user scrolling back through a transcript whose height
    /// is still moving unpins on the second consecutive upward sample - and is never scrolled back to
    /// the bottom in between.
    func testSustainedDragDuringReMeasureStillUnpins() {
        let t = seededTracker(content: 660)
        XCTAssertEqual(decide(t, pinned: true, distance: -28, content: 575), .keep, "a shrink opens the window")
        // The height is still moving, so the window is still open: -28 -> 30 with content 575 -> 585 is
        // gapDelta 58 - contentDelta 10 = +48 up, unconfirmed.
        XCTAssertEqual(decide(t, pinned: true, distance: 30, content: 585), .keep, "first sample: unconfirmed")
        // 30 -> 78 with content 585 -> 595: gapDelta 48 - contentDelta 10 = +38 up, same direction.
        XCTAssertEqual(decide(t, pinned: true, distance: 78, content: 595), .unpin, "second sample confirms it")
    }

    /// The window closes the moment a sample arrives with the heights steady, however many samples it
    /// nominally had left. Every artifact it exists to reject is a side effect of a height changing, so
    /// a steady sample proves the disturbance is over - and a window that only counted samples down
    /// stayed armed for as long as the transcript sat idle (nothing moving, so no samples), which is
    /// what ambushed a reader's first scroll minutes after an answer finished.
    func testWindowClosesAsSoonAsTheHeightsAreSteady() {
        let t = seededTracker(content: 660)
        XCTAssertEqual(decide(t, pinned: true, distance: -28, content: 575), .keep, "a shrink opens the window")
        XCTAssertEqual(decide(t, pinned: true, distance: 30, content: 575), .unpin,
                       "the height is steady again, so one decisive sample is believed immediately")
    }

    /// Outside the re-measure window nothing changes: one decisive sample still unpins immediately.
    func testSingleSampleUnpinSurvivesOnceTheHeightHasSettled() {
        let t = seededTracker(content: 660)
        XCTAssertEqual(decide(t, pinned: true, distance: 30, content: 575), .chase, "shrink opens the window")
        // Let the window lapse with settled samples at the bottom, then fling up once.
        for _ in 0..<3 {
            XCTAssertEqual(decide(t, pinned: true, distance: 0, content: 575), .keep)
        }
        XCTAssertEqual(decide(t, pinned: true, distance: 40, content: 575), .unpin)
    }

    // MARK: - The scroll view's own phase (macOS 15+)

    /// Where the platform can tell us the reader is driving the scroll view, none of the guessing above
    /// applies: an upward move with their finger or wheel on the view is the reader, whatever the
    /// heights are doing and whatever window is open.
    func testUserDrivenScrollPhaseUnpinsOnTheFirstSample() {
        let t = seededTracker(content: 660)
        t.noteProgrammaticScroll()            // a settling window is open...
        t.noteScrollPhase(userDriven: true)
        // ...and the height is still moving: gapDelta 58 - contentDelta 10 = +48 up.
        XCTAssertEqual(decide(t, pinned: true, distance: 58, content: 670), .unpin)
    }

    /// The identical sample without that signal (the pre-macOS-15 path) still waits for confirmation -
    /// the phase is a positive override, never a requirement, so a platform that never reports one
    /// keeps the heuristics rather than losing the ability to unpin.
    func testSameSampleWithoutThePhaseSignalWaitsForConfirmation() {
        let t = seededTracker(content: 660)
        t.noteProgrammaticScroll()
        XCTAssertEqual(decide(t, pinned: true, distance: 58, content: 670), .keep)
    }

    // MARK: - Never fight the user
    //
    // ChatView closes a loop the tracker cannot see on its own: a `.chase` becomes a scrollToBottom,
    // which calls noteProgrammaticScroll() and lands an at-bottom sample back in `decide` a moment
    // later. `drive` below plays that loop out, which is the only way these tests can catch the class
    // of bug that matters most here - a rule whose own output destroys the evidence it is waiting for,
    // so the transcript pulls a scrolling reader back indefinitely.

    /// Feeds one sample the way ChatView does, including that feedback: on `.chase` the transcript
    /// scrolls to the bottom (distance 0), tells the tracker the move was ours, and the sample that
    /// scroll produces goes back in. Mutates `pinned` / `distance` like the view's `@State`.
    private func drive(_ t: ChatScrollPinTracker, pinned: inout Bool, distance: inout CGFloat,
                       content: CGFloat, scrolls: inout Int) {
        switch decide(t, pinned: pinned, distance: distance, content: content) {
        case .unpin:
            pinned = false
        case .repin:
            pinned = true
        case .chase:
            guard pinned else { break }
            scrolls += 1
            distance = 0
            t.noteProgrammaticScroll()
            _ = decide(t, pinned: pinned, distance: 0, content: content)
        case .keep, .ignore:
            break
        }
    }

    /// The reported regression: on a transcript that is not changing at all, small wheel notches were
    /// answered by scrolling back to the bottom, over and over. The confirmation window had been left
    /// armed by the last chase of the previous answer and never lapsed (nothing was moving, so no
    /// sample arrived to count it down), and every chase it produced re-armed it and erased the run it
    /// was waiting for.
    func testSmallScrollUpOnASettledTranscriptUnpinsAndNeverScrollsBack() {
        let t = seededTracker(content: 2000)
        t.noteProgrammaticScroll()   // the previous answer's last chase; then the reader just reads
        var pinned = true
        var distance: CGFloat = 0
        var scrolls = 0
        for _ in 0..<8 where pinned {
            distance += 12           // one wheel notch, content and container dead steady
            drive(t, pinned: &pinned, distance: &distance, content: 2000, scrolls: &scrolls)
        }
        XCTAssertFalse(pinned, "a scroll-up on a transcript that is not moving must release the pin")
        XCTAssertEqual(scrolls, 0, "and the transcript must never scroll itself back under the reader")
    }

    /// Tapping a reply quote scrolls UP to the quoted message - a programmatic move, so the window was
    /// armed, and the window's answer to an unconfirmed upward move was to chase: the jump was undone
    /// and the reader landed back at the bottom.
    func testJumpToAnOlderMessageIsNotChasedBackToTheBottom() {
        let t = seededTracker(content: 2000)
        t.noteProgrammaticScroll()
        var pinned = true
        var distance: CGFloat = 900
        var scrolls = 0
        drive(t, pinned: &pinned, distance: &distance, content: 2000, scrolls: &scrolls)
        XCTAssertEqual(scrolls, 0, "the jump must not be chased back to the bottom")
        XCTAssertFalse(pinned, "and reading an older message releases the pin")
    }

    /// Mid-stream the reader drags back while the items-follow keeps scrolling to the bottom. The
    /// follow's own landing must not count against the drag, or the reader can never accumulate the
    /// confirmation the re-measure window asks for and the transcript wins forever.
    func testDragDuringStreamingUnpinsDespiteTheFollowScrollingBack() {
        let t = seededTracker(content: 1000)
        var content: CGFloat = 1000
        var pinned = true
        for round in 1...4 where pinned {
            // The stream grows the content and the items-follow scrolls to the bottom.
            content += 40
            t.noteProgrammaticScroll()
            XCTAssertEqual(decide(t, pinned: pinned, distance: 0, content: content), .keep,
                           "round \(round): the follow's landing is at the bottom")
            // Then the reader drags up 30pt while another 40pt of content arrives.
            content += 40
            if decide(t, pinned: pinned, distance: 70, content: content) == .unpin { pinned = false }
        }
        XCTAssertFalse(pinned, "a sustained drag must release the pin even while the follow fights it")
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

// MARK: - Chase deferral (ChatScrollChaser)

// The chaser's contract, pinned down because a regression is a hard crash, not a glitch: a chase
// scheduled from the layout pass must never run synchronously (running it inside the pass is the
// AppKit layout-loop kill), a burst of samples must coalesce into ONE scroll, and the chaser must
// re-arm after firing so the next settle round gets its own turn.
@MainActor
final class ChatScrollChaserTests: XCTestCase {

    func testChaseNeverRunsSynchronously() async {
        let chaser = ChatScrollChaser()
        var fired = 0
        let drained = expectation(description: "deferred chase drained")
        chaser.schedule { fired += 1; drained.fulfill() }
        XCTAssertEqual(fired, 0, "a scheduled chase must not run within the scheduling pass")
        // Drain the deferred task so it does not outlive the test.
        await fulfillment(of: [drained], timeout: 5)
    }

    func testBurstCoalescesIntoOneChase() async {
        let chaser = ChatScrollChaser()
        var fired = 0
        let first = expectation(description: "deferred chase fired")
        chaser.schedule { fired += 1; first.fulfill() }
        // The rest of the burst (further geometry samples in the same pass) must fold into the
        // pending one, not queue their own.
        for _ in 0..<4 { chaser.schedule { fired += 1 } }
        await fulfillment(of: [first], timeout: 5)
        XCTAssertEqual(fired, 1, "a burst of schedules must net exactly one chase")
    }

    func testReArmsAfterFiring() async {
        let chaser = ChatScrollChaser()
        var fired = 0
        let first = expectation(description: "first chase")
        chaser.schedule { fired += 1; first.fulfill() }
        await fulfillment(of: [first], timeout: 5)
        let second = expectation(description: "second chase")
        chaser.schedule { fired += 1; second.fulfill() }
        await fulfillment(of: [second], timeout: 5)
        XCTAssertEqual(fired, 2, "each settle round after a fire must get its own deferred chase")
    }
}
