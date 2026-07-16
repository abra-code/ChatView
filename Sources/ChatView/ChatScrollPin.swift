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

    /// A genuine user scroll-up must move the viewport by at least this many points to release the pin.
    /// Above 0 to absorb sub-point layout jitter - especially on the pre-macOS-15 fallback, where
    /// `distanceFromBottom` and `contentHeight` come from two independently pixel-snapped GeometryReader
    /// reads that could disagree by a hair; a real scroll is many points, so nothing genuine is missed.
    private static let scrollEpsilon: CGFloat = 1

    /// Drops the running sample so the next sample is treated as a fresh seed. Call when the transcript
    /// is replaced wholesale (a conversation loaded in place): the old sample's heights belong to the
    /// previous conversation, and diffing the new conversation's first sample against them would net a
    /// huge bogus `userScrollUp` and spuriously unpin.
    func reset() {
        lastContentHeight = 0
        lastContainerHeight = 0
        lastDistanceFromBottom = 0
        seeded = false
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
        // The bottom is off screen. Release the pin only if the user themselves moved the viewport up
        // this sample - even when a streaming flush grew the content in the SAME sample (the growth is
        // already netted out, so it cannot mask the scroll and yank the reader back). Otherwise the
        // bottom drifted off under a pinned viewport purely from growth / a resize / a downward chase
        // animation (userScrollUp <= 0): follow it.
        return userScrollUp > Self.scrollEpsilon ? .unpin : .chase
    }
}
