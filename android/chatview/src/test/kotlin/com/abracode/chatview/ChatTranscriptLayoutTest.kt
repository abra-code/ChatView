package com.abracode.chatview

// Port of Tests/ChatViewTests/ChatTranscriptLayoutTests.swift.
//
// Tests for the pure transcript-layout helpers: RFC 3339 parsing, run grouping (same sender within a 60 s window,
// broken by sender change / time gap / a non-groupable event), and day-separator placement between calendar days.
// Deterministic (a fixed UTC zone).

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.time.Instant
import com.abracode.chatview.ui.groupingSignature
import com.abracode.chatview.ui.toLayoutInput
import java.time.ZoneId

class ChatTimestampTest {

    @Test
    fun parsesRFC3339WithAndWithoutFractionalSeconds() {
        assertNotNull(ChatTimestamp.parse("2026-07-10T12:00:00Z"))
        assertNotNull(ChatTimestamp.parse("2026-07-10T12:00:00.500Z"))
        assertNotNull(ChatTimestamp.parse("2026-07-10T12:00:00+02:00"))
    }

    @Test
    fun rejectsEmptyAndGarbage() {
        assertNull(ChatTimestamp.parse(null))
        assertNull(ChatTimestamp.parse(""))
        assertNull(ChatTimestamp.parse("not a date"))
    }
}

class ChatTranscriptLayoutTest {

    private val utc: ZoneId = ZoneId.of("UTC")

    private fun at(iso: String): Instant = ChatTimestamp.parse(iso)!!

    private fun input(sender: String, iso: String?, groupable: Boolean = true): ChatTranscriptLayout.Input =
        ChatTranscriptLayout.Input(senderKey = sender, groupable = groupable, timestamp = iso?.let { at(it) })

    private fun layout(vararg inputs: ChatTranscriptLayout.Input): List<ChatTranscriptLayout.Info> =
        ChatTranscriptLayout.layout(inputs.toList(), zone = utc)

    @Test
    fun consecutiveSameSenderWithinWindowIsOneRun() {
        val infos = layout(
            input("a", "2026-07-10T12:00:00Z"),
            input("a", "2026-07-10T12:00:30Z"),
            input("a", "2026-07-10T12:00:45Z"),
        )
        assertEquals(listOf(true, false, false), infos.map { it.isFirstInRun })
        assertEquals(listOf(false, false, true), infos.map { it.isLastInRun })
    }

    @Test
    fun timeGapBeyondWindowBreaksTheRun() {
        val infos = layout(
            input("a", "2026-07-10T12:00:00Z"),
            input("a", "2026-07-10T12:02:00Z"), // 120s > 60s window
        )
        assertEquals(listOf(true, true), infos.map { it.isFirstInRun })
        assertEquals(listOf(true, true), infos.map { it.isLastInRun })
    }

    @Test
    fun differentSenderBreaksTheRun() {
        val infos = layout(
            input("a", "2026-07-10T12:00:00Z"),
            input("b", "2026-07-10T12:00:05Z"),
            input("a", "2026-07-10T12:00:10Z"),
        )
        assertEquals(listOf(true, true, true), infos.map { it.isFirstInRun })
        assertEquals(listOf(true, true, true), infos.map { it.isLastInRun })
    }

    @Test
    fun nonGroupableEventBreaksRunsOnBothSides() {
        val infos = layout(
            input("a", "2026-07-10T12:00:00Z"),
            input("sys", "2026-07-10T12:00:05Z", groupable = false), // a member/call/system event
            input("a", "2026-07-10T12:00:10Z"),
        )
        // The event is its own run; the two messages do not merge across it.
        assertEquals(listOf(true, true, true), infos.map { it.isFirstInRun })
        assertEquals(listOf(true, true, true), infos.map { it.isLastInRun })
    }

    @Test
    fun missingTimestampsFallBackToSenderGrouping() {
        val infos = layout(
            input("a", null),
            input("a", null),
            input("b", null),
        )
        assertEquals(listOf(true, false, true), infos.map { it.isFirstInRun })
        assertEquals(listOf(false, true, true), infos.map { it.isLastInRun })
    }

    @Test
    fun daySeparatorMarkedOnlyWhenTheCalendarDayAdvances() {
        val infos = layout(
            input("a", "2026-07-10T23:59:00Z"),
            input("a", "2026-07-11T00:01:00Z"), // next day -> separator before this one
            input("b", "2026-07-11T09:00:00Z"), // same day -> no separator
        )
        assertEquals(
            "a day separator falls between items only when the calendar day changes; never before the first",
            listOf(false, true, false),
            infos.map { it.startsNewDay },
        )
    }

    @Test
    fun itemsWithoutTimestampsGetNoDaySeparators() {
        val infos = layout(
            input("a", null),
            input("a", null),
        )
        assertEquals(listOf(false, false), infos.map { it.startsNewDay })
    }

    @Test
    fun emptyAndSingleItem() {
        assertTrue(ChatTranscriptLayout.layout(emptyList(), zone = utc).isEmpty())
        val one = layout(input("a", "2026-07-10T12:00:00Z"))
        assertEquals(
            listOf(ChatTranscriptLayout.Info(isFirstInRun = true, isLastInRun = true, startsNewDay = false)),
            one,
        )
    }
}

/**
 * The layout inputs the transcript actually builds from its items ([groupingSignature]), as opposed to the pure
 * layout core above. One item type gets this wrong in a way the core cannot see: a row that reports a timestamp but
 * draws nothing takes the day separator with it.
 */
class ChatGroupingSignatureTest {

    private val utc: ZoneId = ZoneId.of("UTC")

    private fun message(id: String, iso: String) = ChatItem.Message(
        ChatMessage(id = id, role = ChatRole.REMOTE, text = id, isStreaming = false, senderID = "alex", timestamp = iso),
    )

    private fun layoutOf(items: List<ChatItem>): List<ChatTranscriptLayout.Info> =
        ChatTranscriptLayout.layout(items.map { groupingSignature(it, emptyList()).toLayoutInput() }, zone = utc)

    /**
     * A SESSION MARKER CARRIES NO LAYOUT TIMESTAMP, mirroring Swift's nonGroupableTimestamp. The day separator is
     * placed on the first TIMESTAMPED item of a new day; hand the marker a timestamp and the separator lands on a row
     * that draws nothing (its row context has no timestamp either), so the day header vanishes from the conversation
     * instead of appearing on the message below it.
     */
    @Test
    fun aSessionMarkerDoesNotSwallowTheDaySeparator() {
        val infos = layoutOf(listOf(
            message("m0", "2026-07-10T23:50:00Z"),
            ChatItem.SessionEventItem(
                SessionEvent(id = "sess-1", kind = SessionEvent.Kind.RESUMED, timestamp = "2026-07-11T09:00:00Z"),
            ),
            message("m1", "2026-07-11T09:01:00Z"),
        ))
        assertEquals(
            "the day header must land on the row that can draw it, not on the marker",
            listOf(false, false, true),
            infos.map { it.startsNewDay },
        )
    }

    /**
     * And it still breaks a run, like every other centered marker. The `groupable` flag is asserted DIRECTLY as
     * well as through the layout: the marker's sender key is `system`, which matches no message's key, so the two
     * messages could not merge across it even if the flag were wrong - the layout assertion alone would pass with
     * the flag flipped and pin nothing.
     */
    @Test
    fun aSessionMarkerBreaksTheRunAroundIt() {
        val marker = ChatItem.SessionEventItem(SessionEvent(id = "sess-1", kind = SessionEvent.Kind.MODEL_CHANGED))
        assertFalse("a marker is never groupable", groupingSignature(marker, emptyList()).groupable)
        val infos = layoutOf(listOf(
            message("m0", "2026-07-11T09:00:00Z"),
            marker,
            message("m1", "2026-07-11T09:00:30Z"),
        ))
        assertEquals(listOf(true, true, true), infos.map { it.isFirstInRun })
        assertEquals(listOf(true, true, true), infos.map { it.isLastInRun })
    }
}
