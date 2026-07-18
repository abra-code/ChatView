package com.abracode.chatview

// Port of Sources/ChatView/ChatScrollPin.swift.
//
// The transcript auto-scroll "pin" decision, factored out as a pure state machine so it can be unit-tested without
// a scroll harness. The transcript follows new content only while the user is pinned to the bottom; the hard part
// is telling content growth / a resize (which push the bottom off screen but must NOT unpin - the view chases them)
// apart from a genuine user scroll-up (which must stop the following so streaming does not fight the reader).
//
// Fed one sample per scroll / layout change: distanceFromBottom (px of content below the fold), contentHeight,
// containerHeight. The Compose sampler feeds these from the LazyColumn geometry (see the A6 view wiring).

/** What the caller should do with the pin after one scroll / layout sample. */
enum class ChatScrollPinDecision {
    IGNORE, // not an actionable sample (e.g. the sentinel's empty default) - change nothing
    KEEP,   // actionable, but no pin change
    UNPIN,  // the user scrolled up: stop following the latest entry
    REPIN,  // the user returned to the bottom: resume following
    CHASE,  // content grew / the view resized under a pinned viewport: scroll to the new bottom
}

/**
 * Holds the running sample so the view can update it on every scroll event WITHOUT invalidating the composition
 * each frame - only an actual pin flip (kept in the view's own state) redraws. Confined to the main thread; never
 * shared, so it needs no synchronization.
 */
class ChatScrollPinTracker {
    private var lastContentHeight: Float = 0f
    private var lastContainerHeight: Float = 0f
    private var lastDistanceFromBottom: Float = 0f
    private var seeded = false

    /**
     * Drops the running sample so the next sample is treated as a fresh seed. Call when the transcript is replaced
     * wholesale (a conversation loaded in place): the old sample's heights belong to the previous conversation, and
     * diffing the new conversation's first sample against them would net a huge bogus `userScrollUp` and spuriously
     * unpin.
     */
    fun reset() {
        lastContentHeight = 0f
        lastContainerHeight = 0f
        lastDistanceFromBottom = 0f
        seeded = false
    }

    /**
     * Maps one scroll / layout sample to a pin action. `threshold` is the at-bottom tolerance (px of content below
     * the fold that still count as "following the latest entry").
     */
    fun decide(
        isPinned: Boolean,
        distanceFromBottom: Float,
        contentHeight: Float,
        containerHeight: Float,
        threshold: Float,
    ): ChatScrollPinDecision {
        // A de-materialized sentinel emits a 0-height default. A real viewport always has a positive height, so drop
        // that sample rather than reading its collapse-to-zero as a giant layout change.
        if (containerHeight <= 0f) return ChatScrollPinDecision.IGNORE

        val contentDelta = contentHeight - lastContentHeight
        val containerDelta = containerHeight - lastContainerHeight
        val gapDelta = distanceFromBottom - lastDistanceFromBottom
        // gap = contentHeight - offset - containerHeight, so gapDelta - contentDelta + containerDelta reduces to
        // exactly -offsetDelta: the user's own upward viewport move, with content growth and container resize
        // cancelled out exactly. Positive => the viewport moved toward older content, which is the ONLY thing that
        // releases the pin - a streaming flush or a resize nets ~0 here no matter its magnitude.
        val userScrollUp = gapDelta - contentDelta + containerDelta

        val wasSeeded = seeded
        lastContentHeight = contentHeight
        lastContainerHeight = containerHeight
        lastDistanceFromBottom = distanceFromBottom
        seeded = true

        val atBottom = distanceFromBottom <= threshold
        if (!isPinned) {
            return if (atBottom) ChatScrollPinDecision.REPIN else ChatScrollPinDecision.KEEP
        }
        if (atBottom) {
            return ChatScrollPinDecision.KEEP
        }
        // The first sample has no prior to diff against, so its deltas are noise; never unpin on it. Chasing an
        // off-screen bottom here is harmless (a no-op when already at the bottom).
        if (!wasSeeded) {
            return ChatScrollPinDecision.CHASE
        }
        // The bottom is off screen. Release the pin only if the user themselves moved the viewport up this sample -
        // even when a streaming flush grew the content in the SAME sample (the growth is already netted out).
        // Otherwise the bottom drifted off under a pinned viewport purely from growth / a resize / a downward chase
        // animation (userScrollUp <= 0): follow it.
        return if (userScrollUp > scrollEpsilon) ChatScrollPinDecision.UNPIN else ChatScrollPinDecision.CHASE
    }

    companion object {
        /**
         * A genuine user scroll-up must move the viewport by at least this many px to release the pin. Above 0 to
         * absorb sub-px layout jitter; a real scroll is many px, so nothing genuine is missed.
         */
        private const val scrollEpsilon: Float = 1f
    }
}
