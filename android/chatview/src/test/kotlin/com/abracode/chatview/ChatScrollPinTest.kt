package com.abracode.chatview

// Port of Tests/ChatViewTests/ChatScrollPinTests.swift.
//
// Tests for the transcript auto-scroll pin state machine (ChatScrollPinTracker): staying pinned + chasing through
// streaming growth, releasing on a real user scroll-up (including one that coincides with a growth flush), never
// unpinning while a programmatic scroll carries us DOWN to the bottom, following a resize, and ignoring the
// fallback sentinel's empty default.
//
// Geometry model: a 100 px viewport (containerHeight). "distance" is px of content below the fold; distance <=
// threshold (24) counts as at-bottom. A sample where the caller has chased to the bottom reports distance 0.

import org.junit.Assert.assertEquals
import org.junit.Test

class ChatScrollPinTest {

    private val threshold = 24f
    private val container = 100f

    /** Seeds the tracker with an at-bottom sample so later samples have a prior to diff against. */
    private fun seededTracker(content: Float = 200f): ChatScrollPinTracker {
        val t = ChatScrollPinTracker()
        assertEquals("seed should be a no-op keep", ChatScrollPinDecision.KEEP, decide(t, pinned = true, distance = 0f, content = content))
        return t
    }

    private fun decide(
        t: ChatScrollPinTracker,
        pinned: Boolean,
        distance: Float,
        content: Float,
        container: Float = this.container,
    ): ChatScrollPinDecision =
        t.decide(isPinned = pinned, distanceFromBottom = distance, contentHeight = content, containerHeight = container, threshold = threshold)

    // MARK: - Streaming growth keeps the pin and chases

    @Test
    fun growthUnderPinnedViewportChasesNeverUnpins() {
        val t = seededTracker(content = 200f)
        var content = 200f
        repeat(5) {
            content += 60f
            assertEquals(
                "a growth sample that pushed the bottom off screen must chase",
                ChatScrollPinDecision.CHASE,
                decide(t, pinned = true, distance = 60f, content = content),
            )
            assertEquals(
                "after the chase settles we are at the bottom again",
                ChatScrollPinDecision.KEEP,
                decide(t, pinned = true, distance = 0f, content = content),
            )
        }
    }

    @Test
    fun smallGrowthWithinThresholdStaysPinnedWithoutChasing() {
        val t = seededTracker(content = 200f)
        assertEquals(ChatScrollPinDecision.KEEP, decide(t, pinned = true, distance = 10f, content = 210f))
    }

    // MARK: - Genuine user scroll-up releases the pin

    @Test
    fun decisiveScrollUpUnpins() {
        val t = seededTracker(content = 260f)
        assertEquals(ChatScrollPinDecision.UNPIN, decide(t, pinned = true, distance = 40f, content = 260f))
    }

    @Test
    fun slowScrollUpAccumulatesThenUnpins() {
        val t = seededTracker(content = 260f)
        assertEquals(ChatScrollPinDecision.KEEP, decide(t, pinned = true, distance = 10f, content = 260f))
        assertEquals(ChatScrollPinDecision.KEEP, decide(t, pinned = true, distance = 20f, content = 260f))
        assertEquals(ChatScrollPinDecision.UNPIN, decide(t, pinned = true, distance = 26f, content = 260f))
    }

    @Test
    fun decisiveScrollUpCoincidentWithGrowthUnpins() {
        val t = seededTracker(content = 260f)
        // content grows 40 AND the user flings up 50 in one sample: distance jumps to 90.
        // userScrollUp = gapDelta(90) - contentDelta(40) = 50 -> unpin, not chase.
        assertEquals(ChatScrollPinDecision.UNPIN, decide(t, pinned = true, distance = 90f, content = 300f))
    }

    @Test
    fun moderateScrollUpCoincidentWithGrowthUnpins() {
        val t = seededTracker(content = 260f)
        // content grows 40 AND the user scrolls up 10 in one sample: distance jumps to 50.
        // userScrollUp = gapDelta(50) - contentDelta(40) = 10 -> unpin.
        assertEquals(ChatScrollPinDecision.UNPIN, decide(t, pinned = true, distance = 50f, content = 300f))
    }

    @Test
    fun subEpsilonScrollUpIsAbsorbedAsNoise() {
        val t = seededTracker(content = 260f)
        // content grows 29.5 AND the viewport nudges up 0.5 in one sample: distance jumps to 30.
        // userScrollUp = gapDelta(30) - contentDelta(29.5) = 0.5 < epsilon(1) -> chase, not unpin.
        assertEquals(ChatScrollPinDecision.CHASE, decide(t, pinned = true, distance = 30f, content = 289.5f))
    }

    // MARK: - Programmatic scroll toward the bottom must not be misread as a user scroll

    @Test
    fun downwardProgrammaticScrollChasesNotUnpins() {
        val t = seededTracker(content = 400f)
        // The user is scrolled up and unpinned, resting at distance 90 (this seeds the prior sample).
        assertEquals(ChatScrollPinDecision.KEEP, decide(t, pinned = false, distance = 90f, content = 400f))
        // They tap "jump to latest": the caller sets the pin true and animates DOWN toward the bottom.
        assertEquals(ChatScrollPinDecision.CHASE, decide(t, pinned = true, distance = 60f, content = 400f))
        assertEquals(ChatScrollPinDecision.CHASE, decide(t, pinned = true, distance = 30f, content = 400f))
        assertEquals(ChatScrollPinDecision.KEEP, decide(t, pinned = true, distance = 0f, content = 400f))
    }

    // MARK: - Resize

    @Test
    fun containerShrinkWhilePinnedChases() {
        val t = seededTracker(content = 260f)
        // Window shrinks 100 -> 70 with the offset frozen: the bottom drifts 30 off, but it is a resize, so chase.
        assertEquals(ChatScrollPinDecision.CHASE, decide(t, pinned = true, distance = 30f, content = 260f, container = 70f))
    }

    // MARK: - Content shrink

    @Test
    fun contentShrinkWhilePinnedStaysAtBottom() {
        val t = seededTracker(content = 260f)
        // A collapsed thought shortens the content so the bottom is above the fold (negative distance): keep.
        assertEquals(ChatScrollPinDecision.KEEP, decide(t, pinned = true, distance = -40f, content = 220f))
    }

    // MARK: - Re-pin

    @Test
    fun returnToBottomRepins() {
        val t = seededTracker(content = 400f)
        assertEquals("reading back stays unpinned", ChatScrollPinDecision.KEEP, decide(t, pinned = false, distance = 200f, content = 400f))
        assertEquals("back within threshold re-pins", ChatScrollPinDecision.REPIN, decide(t, pinned = false, distance = 10f, content = 400f))
    }

    @Test
    fun unpinnedAwayFromBottomKeeps() {
        val t = seededTracker(content = 400f)
        assertEquals(ChatScrollPinDecision.KEEP, decide(t, pinned = false, distance = 300f, content = 400f))
    }

    // MARK: - Fallback sentinel default

    @Test
    fun zeroContainerHeightIsIgnored() {
        val t = seededTracker(content = 400f)
        assertEquals(ChatScrollPinDecision.IGNORE, decide(t, pinned = true, distance = Float.MAX_VALUE, content = 0f, container = 0f))
        assertEquals(ChatScrollPinDecision.IGNORE, decide(t, pinned = false, distance = Float.MAX_VALUE, content = 0f, container = 0f))
    }

    // MARK: - First sample

    @Test
    fun firstSampleNeverUnpins() {
        // A fresh tracker whose very first sample is far from the bottom: chase, never unpin.
        val t = ChatScrollPinTracker()
        assertEquals(ChatScrollPinDecision.CHASE, decide(t, pinned = true, distance = 500f, content = 800f))
    }

    @Test
    fun firstSampleAtBottomKeeps() {
        val t = ChatScrollPinTracker()
        assertEquals(ChatScrollPinDecision.KEEP, decide(t, pinned = true, distance = 0f, content = 200f))
    }
}
