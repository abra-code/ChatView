// Sources/ChatView/ChatScrollPin.swift
//
// The transcript auto-scroll "pin" decision, factored out of ChatView as a pure state machine so it can
// be unit-tested without a SwiftUI / scroll harness. The transcript follows new content only while the
// user is pinned to the bottom; the hard part is telling content growth / a resize (which push the
// bottom off screen but must NOT unpin - the view chases them instead) apart from a genuine user
// scroll-up (which must stop the following so streaming does not fight the reader).
//
// Fed one sample per scroll / layout change: distanceFromBottom (points of content below the fold),
// contentHeight, containerHeight. On macOS 15+ these come straight from onScrollGeometryChange; on the
// older baseline from the bottom-sentinel preference. See ChatView.updatePin for the wiring.

import CoreGraphics

/// What the caller should do with the pin after one scroll / layout sample.
enum ChatScrollPinDecision: Equatable {
    case ignore   // not an actionable sample (e.g. the sentinel's empty default) - change nothing
    case keep     // actionable, but no pin change
    case unpin    // the user scrolled up: stop following the latest entry
    case repin    // the user returned to the bottom: resume following
    case chase    // content grew / the view resized under a pinned viewport: scroll to the new bottom
}

/// Defers a pinned-viewport chase to a later main-runloop turn, coalescing a burst of scroll /
/// layout samples into a single scroll. The deferral is load-bearing, not cosmetic: the geometry
/// callback that decides `.chase` fires inside AppKit's layout pass (SwiftUI dispatches pending
/// scroll actions during `NSHostingView.layout`), and a synchronous `scrollTo` there marks layout
/// dirty mid-pass. While a freshly grown transcript is still settling (lazy rows materializing,
/// text wrapping), that repeats within ONE display cycle until AppKit's layout-loop guard throws
/// from `-[NSWindow _postWindowNeedsUpdateConstraints]` and `-[NSApplication _crashOnException:]`
/// kills the app (the "typed a message, app died" crash). One runloop hop runs every chase outside
/// the display cycle, so a settle that takes N rounds becomes N cheap turns instead of N forced
/// re-layouts inside one cycle.
///
/// A reference type held in `@State` for the same reason as ChatScrollPinTracker below: scheduling
/// from a per-frame geometry sample must not invalidate the view.
@MainActor
final class ChatScrollChaser {
    private var scheduled = false

    /// Runs `chase` on a later main-runloop turn; calls made while one is pending coalesce into it
    /// (the pending action runs once). The action must re-check its own preconditions when it runs -
    /// the pin may have been released by a sample processed in between.
    func schedule(_ chase: @escaping @MainActor () -> Void) {
        guard !scheduled else { return }
        scheduled = true
        Task { @MainActor in
            // Cleared BEFORE running so a geometry change caused by this chase's own scroll can
            // schedule the next round (each round on its own turn - never within one cycle).
            self.scheduled = false
            chase()
        }
    }
}

/// A reference type so ChatView can hold it in `@State` and update its running sample on every scroll
/// event WITHOUT invalidating the view each frame - only an actual pin flip (kept in ChatView's own
/// `@State isPinnedToBottom`) redraws. Confined to the main actor; never shared, so it needs no
/// synchronization.
@MainActor
final class ChatScrollPinTracker {
    private var lastContentHeight: CGFloat = 0
    private var lastContainerHeight: CGFloat = 0
    private var lastDistanceFromBottom: CGFloat = 0
    private var seeded = false
    /// Samples remaining in the settling window (see settlingSamples). Zero means neither a
    /// re-measure nor a programmatic scroll has disturbed the viewport recently.
    private var settlingFor = 0
    /// Consecutive samples whose apparent move was upward, reset by any downward move or a return to
    /// the bottom. A user's drag sustains a run; a clamp artifact spikes once and reverses.
    private var consecutiveUpSamples = 0
    /// The `userScrollUp` the last `decide` computed - the value the unpin turns on. Exposed for the
    /// pin trace (ChatViewDiagnostics.pinSample) so a spurious unpin can be read off a log instead of
    /// inferred; the state machine itself stays pure.
    private(set) var lastUserScrollUp: CGFloat = 0

    /// A genuine user scroll-up must move the viewport by at least this many points to release the pin.
    /// Above 0 to absorb sub-point layout jitter - especially on the pre-macOS-15 fallback, where
    /// `distanceFromBottom` and `contentHeight` come from two independently pixel-snapped GeometryReader
    /// reads that could disagree by a hair; a real scroll is many points, so nothing genuine is missed.
    private static let scrollEpsilon: CGFloat = 1

    /// How much the content may SHRINK in one sample before the sample is disqualified from unpinning.
    /// Above 0 for the same pixel-snapping reason as scrollEpsilon; see the shrink guard in `decide`.
    private static let shrinkEpsilon: CGFloat = 1

    /// How many samples a disturbance keeps the viewport "settling". Within that window an apparent
    /// scroll-up needs a second consecutive sample to be believed; outside it a single sample still
    /// unpins immediately. Two disturbances open the window - a content shrink (the scroll view clamps
    /// its own offset, and the clamp does not come back when the height does) and a scroll WE issued
    /// (the view keeps adjusting for a few samples after it lands). Both move the offset without the
    /// user, which the offset algebra cannot tell from a drag. Four samples covered every artifact in
    /// the field trace, including the post-chase drift that a three-sample window let through, and
    /// costs a real drag at most one frame of delay.
    private static let settlingSamples = 4

    /// Drops the running sample so the next sample is treated as a fresh seed. Call when the transcript
    /// is replaced wholesale (a conversation loaded in place): the old sample's heights belong to the
    /// previous conversation, and diffing the new conversation's first sample against them would net a
    /// huge bogus `userScrollUp` and spuriously unpin.
    func reset() {
        lastContentHeight = 0
        lastContainerHeight = 0
        lastDistanceFromBottom = 0
        seeded = false
        settlingFor = 0
        consecutiveUpSamples = 0
    }

    /// Opens the settling window because the CALLER just scrolled the viewport itself. For a few
    /// samples after a programmatic scroll lands, the scroll view keeps nudging its offset (settling
    /// the animation, re-anchoring after the content it scrolled to re-measures); those nudges reach
    /// `decide` as apparent user movement, and one of them - a 19.5pt drift right after a chase - was
    /// still releasing the pin once the shrink-only window had lapsed.
    func noteProgrammaticScroll() {
        settlingFor = Self.settlingSamples
        consecutiveUpSamples = 0
    }

    /// Maps one scroll / layout sample to a pin action. `threshold` is the at-bottom tolerance (points
    /// of content below the fold that still count as "following the latest entry").
    func decide(isPinned: Bool, distanceFromBottom: CGFloat, contentHeight: CGFloat,
                containerHeight: CGFloat, threshold: CGFloat) -> ChatScrollPinDecision {
        // The pre-macOS-15 bottom sentinel emits a 0-height default when the LazyVStack de-materializes
        // it (the user scrolled far up). A real viewport always has a positive height, so drop that
        // sample rather than reading its collapse-to-zero as a giant layout change (which would else
        // snap a still-pinned reader back to the bottom on the fallback path).
        guard containerHeight > 0 else { return .ignore }

        let contentDelta = contentHeight - lastContentHeight
        let containerDelta = containerHeight - lastContainerHeight
        let gapDelta = distanceFromBottom - lastDistanceFromBottom
        // gap = contentHeight - offset - containerHeight, so gapDelta - contentDelta + containerDelta
        // reduces to exactly -offsetDelta: the user's own upward viewport move, with content growth and
        // container resize cancelled out exactly (not merely thresholded). Positive => the viewport
        // moved toward older content, which is the ONLY thing that releases the pin - a streaming flush
        // or a resize nets ~0 here no matter its magnitude.
        let userScrollUp = gapDelta - contentDelta + containerDelta
        lastUserScrollUp = userScrollUp

        // Running state the unpin rule consults. Updated on EVERY actionable sample, including the
        // at-bottom ones below, so a run of upward samples is counted across the whole gesture.
        let shrank = contentDelta < -Self.shrinkEpsilon
        if shrank {
            settlingFor = Self.settlingSamples
        } else if settlingFor > 0 {
            settlingFor -= 1
        }
        if shrank {
            // A shrink reads as a large upward move by construction (the offset is clamped with the
            // content), so it must not count as the first half of a confirmed drag - it would confirm
            // the very artifact this is here to reject. Start the run over instead.
            consecutiveUpSamples = 0
        } else if userScrollUp > Self.scrollEpsilon {
            consecutiveUpSamples += 1
        } else if userScrollUp < -Self.scrollEpsilon {
            consecutiveUpSamples = 0
        }
        if distanceFromBottom <= threshold {
            consecutiveUpSamples = 0   // back at the bottom: whatever run was building is over
        }

        let wasSeeded = seeded
        lastContentHeight = contentHeight
        lastContainerHeight = containerHeight
        lastDistanceFromBottom = distanceFromBottom
        seeded = true

        let atBottom = distanceFromBottom <= threshold
        guard isPinned else {
            return atBottom ? .repin : .keep
        }
        if atBottom {
            return .keep
        }
        // The first sample has no prior to diff against, so its deltas are noise; never unpin on it.
        // Chasing an off-screen bottom here is harmless (a no-op when already at the bottom).
        guard wasSeeded else {
            return .chase
        }
        // A sample whose content SHRANK cannot be read as a user scroll, however large the apparent
        // move. `userScrollUp` reduces to -offsetDelta, and the scroll view moves its own offset when
        // the content shrinks under it: with the content near the container height (a SHORT transcript
        // - a fresh conversation, the first turns of a session) a row re-measuring smaller drops the
        // maximum offset, so AppKit clamps the current one, and that involuntary move is
        // indistinguishable in the algebra from the user dragging up. Streaming re-measures constantly
        // (the AppKit-backed markdown rows settle a beat after their text changes), so this fired
        // repeatedly: unpin -> the reader is at the bottom -> repin -> unpin, and the transcript
        // visibly stopped following mid-answer. Every flip also writes @State, invalidating the view
        // inside the layout pass that produced the sample - the feedback edge behind the
        // _postWindowNeedsUpdateConstraints crash.
        //
        // A genuine user scroll-up never shrinks the content, so nothing real is lost: growth still
        // unpins normally (the growth is netted out and cannot mask a scroll), and a shrink that
        // coincides with a real drag simply defers the unpin to the next sample.
        if contentDelta < -Self.shrinkEpsilon {
            return .chase
        }
        // The rebound half of the same artifact: after a shrink clamped the offset, the offset does not
        // come back when the height does, and that missing return reads as an upward move on a sample
        // whose content GREW - so the shrink guard alone does not cover it. While the height is still
        // re-measuring, require a second consecutive upward sample before believing it. A drag sustains
        // (the scroll view emits a stream of same-direction samples); the artifact spikes once and
        // reverses on the next sample, which resets the run. Outside the window a single sample still
        // unpins immediately, so a decisive fling mid-stream keeps its current behavior.
        if settlingFor > 0 && consecutiveUpSamples < 2 {
            return .chase
        }
        // The bottom is off screen. Release the pin only if the user themselves moved the viewport up
        // this sample - even when a streaming flush grew the content in the SAME sample (the growth is
        // already netted out, so it cannot mask the scroll and yank the reader back). Otherwise the
        // bottom drifted off under a pinned viewport purely from growth / a resize / a downward chase
        // animation (userScrollUp <= 0): follow it.
        return userScrollUp > Self.scrollEpsilon ? .unpin : .chase
    }
}
