package com.abracode.chatview

// Port of Tests/ChatViewTests/ChatTranscriptLayoutTests.swift.
//
// Tests for the pure transcript-layout helpers: RFC 3339 parsing, run grouping (same sender within a 60 s window,
// broken by sender change / time gap / a non-groupable event), and day-separator placement between calendar days.
// Deterministic (a fixed UTC zone).

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.time.Instant
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
