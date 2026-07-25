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
//
// Two rules run the whole thing, and both exist because the offset algebra below is exact about HOW
// MUCH the viewport moved and silent about WHO moved it:
//
//   1. Where the platform can answer that directly it wins - macOS 15+ reports whether the reader is
//      driving the scroll view (noteScrollPhase), and an upward move under their finger is theirs, full
//      stop. Everything else is inference, and inference gets the second rule.
//   2. When unsure, do NOTHING. Never scroll the reader back on a guess. Following a stream is worth
//      one frame of latency; fighting someone who is actively scrolling is not worth anything, and a
//      guess enforced by scrolling also feeds its own next sample - which is how the previous version
//      of this file latched and pulled a scrolling reader back indefinitely.

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
    /// Samples remaining in which a viewport move may be the tail of a scroll WE issued (see
    /// programmaticSamples). Separate from `settlingFor` because it answers a different question: not
    /// "can this sample be trusted" but "was this the caller's own scroll landing", which must not be
    /// counted as the reader changing their mind.
    private var programmaticFor = 0
    /// Consecutive samples whose apparent move was upward, reset by any downward move or a return to
    /// the bottom. A user's drag sustains a run; a clamp artifact spikes once and reverses.
    private var consecutiveUpSamples = 0
    /// Whether the scroll view says the USER is driving it right now (finger / wheel down, or the
    /// momentum that follows). The one unambiguous answer to the question the offset algebra can only
    /// infer; nil-equivalent (false) on the pre-macOS-15 path, where the heuristics below still apply.
    private var userIsScrolling = false
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
    ///
    /// The window ALSO closes the moment a sample arrives with both heights steady, however many
    /// samples are nominally left (see `decide`): every artifact it exists to reject is a side effect
    /// of a height changing, so a steady sample proves the disturbance is over. Without that, a window
    /// opened by the last chase of an answer stayed armed for as long as the transcript sat idle -
    /// nothing was moving, so no sample arrived to count it down - and ambushed the reader's next
    /// scroll minutes later.
    private static let settlingSamples = 4

    /// How many samples after a scroll WE issued may still be that scroll landing. The caller scrolls
    /// to the bottom, so the landing arrives as one big downward move onto the bottom - which is not
    /// the reader abandoning a drag, and must not be scored as one.
    private static let programmaticSamples = 2

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
        programmaticFor = 0
        consecutiveUpSamples = 0
        userIsScrolling = false   // a gesture over the previous conversation says nothing about this one
    }

    /// Opens the settling window because the CALLER just scrolled the viewport itself. For a few
    /// samples after a programmatic scroll lands, the scroll view keeps nudging its offset (settling
    /// the animation, re-anchoring after the content it scrolled to re-measures); those nudges reach
    /// `decide` as apparent user movement, and one of them - a 19.5pt drift right after a chase - was
    /// still releasing the pin once the shrink-only window had lapsed.
    ///
    /// It deliberately does NOT clear `consecutiveUpSamples`. It used to, and that made the window a
    /// latch: the window's own answer to an unconfirmed upward move was a chase, the chase called back
    /// in here, and the run the window was waiting for was wiped every time it started - so a reader
    /// scrolling up was pulled back indefinitely and the pin never released. Our own scroll says
    /// nothing about what the reader wants; it must not erase what they have already done.
    func noteProgrammaticScroll() {
        settlingFor = Self.settlingSamples
        programmaticFor = Self.programmaticSamples
    }

    /// Reports whether the scroll view itself says the user is driving it (macOS 15+ / iOS 18+ scroll
    /// phases; see ChatView.trackScrollPhase). When it does, the guessing below is bypassed entirely:
    /// an upward move while the reader's finger or wheel is on the view IS the reader, whatever the
    /// content heights are doing. The older baseline never calls this and keeps the heuristics.
    func noteScrollPhase(userDriven: Bool) {
        userIsScrolling = userDriven
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

        // Running state the unpin rule consults. Updated on every actionable sample except the ones
        // that are demonstrably the caller's own scroll landing (below), so a run of upward samples is
        // counted across a whole gesture even while the transcript keeps following a stream.
        let shrank = contentDelta < -Self.shrinkEpsilon
        // Did either measured height move at all this sample? Only a height change can move the offset
        // without the user (the scroll view clamps to a shrunken maximum, or re-anchors as lazy rows
        // materialize), so a sample with both heights steady is trustworthy on its face - AND it proves
        // that any re-measure which opened the settling window has finished.
        let heightsMoved = abs(contentDelta) > Self.shrinkEpsilon || abs(containerDelta) > Self.shrinkEpsilon
        if programmaticFor > 0 {
            programmaticFor -= 1
        }
        if shrank {
            settlingFor = Self.settlingSamples
        } else if !heightsMoved {
            settlingFor = 0
        } else if settlingFor > 0 {
            settlingFor -= 1
        }

        let atBottom = distanceFromBottom <= threshold
        // A sample that lands at the bottom right after we scrolled there is our own scroll arriving,
        // not the reader giving up on a drag. Score nothing from it - neither the big downward move nor
        // the arrival at the bottom - or the caller's follow-the-stream scroll silently cancels the
        // reader's evidence on every delta and the confirmation below can never be reached.
        if !(programmaticFor > 0 && atBottom) {
            if shrank {
                // A shrink reads as a large upward move by construction (the offset is clamped with the
                // content), so it must not count as the first half of a confirmed drag - it would
                // confirm the very artifact this is here to reject. Start the run over instead.
                consecutiveUpSamples = 0
            } else if userScrollUp > Self.scrollEpsilon {
                consecutiveUpSamples += 1
            } else if userScrollUp < -Self.scrollEpsilon {
                consecutiveUpSamples = 0
            }
            if atBottom {
                consecutiveUpSamples = 0   // back at the bottom: whatever run was building is over
            }
        }

        let wasSeeded = seeded
        lastContentHeight = contentHeight
        lastContainerHeight = containerHeight
        lastDistanceFromBottom = distanceFromBottom
        seeded = true

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
        if shrank {
            return .chase
        }
        // The bottom is off screen without the viewport having moved up: the bottom drifted off under a
        // pinned viewport purely from growth / a resize / a downward scroll still landing. Follow it.
        // A streaming flush that grew the content in the SAME sample as a real scroll-up does not land
        // here - the growth is netted out exactly, so it can never mask the scroll and yank the reader.
        guard userScrollUp > Self.scrollEpsilon else {
            return .chase
        }
        // The viewport moved up. If the scroll view says the reader is driving it, that settles it.
        if userIsScrolling {
            return .unpin
        }
        // Otherwise this may be the rebound half of the re-measure artifact: after a shrink clamped the
        // offset, the offset does not come back when the height does, and that missing return reads as
        // an upward move on a sample whose content GREW - past the shrink guard above. While the height
        // is still re-measuring, require a second consecutive upward sample before believing it. A drag
        // sustains (the scroll view emits a stream of same-direction samples); the artifact spikes once
        // and reverses on the next sample, which resets the run. Once the heights are steady the window
        // is already closed above, so a single decisive sample unpins as it always did.
        //
        // The answer while unsure is to do NOTHING, not to chase. Chasing was a guess that the reader
        // had not moved, imposed by scrolling them back - the wrong way round, since the cost of
        // guessing wrong is fighting someone who is actively scrolling, and the cost of waiting is one
        // frame of not following a stream that the items-follow chases anyway.
        if settlingFor > 0 && consecutiveUpSamples < 2 {
            return .keep
        }
        return .unpin
    }
}
