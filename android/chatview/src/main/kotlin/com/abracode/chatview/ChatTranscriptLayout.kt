package com.abracode.chatview

// Port of Sources/ChatView/ChatTranscriptLayout.swift.
//
// Pure, unit-testable layout helpers for the dual-alignment (person-to-person / group) transcript: run grouping,
// day-separator placement, and RFC 3339 timestamp parsing. No Compose - the view consumes these results to place
// bubbles, sender labels, avatars, timestamp captions, and day headers. Kept pure and extracted because
// run-grouping and day-separator logic breeds off-by-ones, so it is tested directly.

import java.time.Instant
import java.time.OffsetDateTime
import java.time.ZoneId
import java.time.format.DateTimeFormatter
import kotlin.math.abs

/** RFC 3339 timestamp parsing, shared by the store and the view. The wire form is a String (cross-platform). */
object ChatTimestamp {
    // Two formatters mirroring Swift's isoFractional / isoPlain. java.time's ISO_OFFSET_DATE_TIME already accepts
    // both a fractional and a non-fractional seconds field; the plain fallback keeps the structure explicit and
    // absorbs any offset spelling the first rejects. Both are immutable and thread-safe.
    private val isoFractional: DateTimeFormatter = DateTimeFormatter.ISO_OFFSET_DATE_TIME
    private val isoPlain: DateTimeFormatter = DateTimeFormatter.ofPattern("yyyy-MM-dd'T'HH:mm:ssXXX")

    /**
     * Parses an RFC 3339 / ISO 8601 timestamp (with or without fractional seconds). Returns null for a null / empty
     * / unparseable value.
     */
    fun parse(string: String?): Instant? {
        if (string.isNullOrEmpty()) {
            return null
        }
        parseWith(isoFractional, string)?.let { return it }
        return parseWith(isoPlain, string)
    }

    private fun parseWith(formatter: DateTimeFormatter, string: String): Instant? =
        runCatching { OffsetDateTime.parse(string, formatter).toInstant() }.getOrNull()
}

object ChatTranscriptLayout {

    /** One transcript item reduced to just what layout needs. */
    data class Input(
        /** A stable per-author key. Two consecutive `groupable` items with the same key (within the time window)
         *  form a run. Non-groupable items are given any key; `groupable` gates grouping. */
        val senderKey: String,
        /** Whether this item participates in run grouping (messages and files do; member / call / system events are
         *  centered captions that break a run and never group). */
        val groupable: Boolean,
        /** The item's timestamp, when it carries one. */
        val timestamp: Instant?,
    )

    /** Per-item placement derived from the sequence. */
    data class Info(
        /** First item of its run (its sender label renders above it). */
        var isFirstInRun: Boolean,
        /** Last item of its run (its timestamp / delivery caption and avatar render at it). */
        var isLastInRun: Boolean,
        /** A day-separator caption renders immediately before this item (the calendar day advanced). */
        var startsNewDay: Boolean,
    )

    /** Default run window: consecutive same-sender items within this many seconds group. */
    const val defaultRunWindow: Double = 60.0

    /**
     * Computes run positions and day-separator flags for a transcript. `window` is the run grouping window (seconds);
     * `zone` decides day boundaries (injectable for tests; the Swift `Calendar` maps to a time zone here).
     */
    fun layout(
        inputs: List<Input>,
        window: Double = defaultRunWindow,
        zone: ZoneId = ZoneId.systemDefault(),
    ): List<Info> {
        val infos = inputs.map { Info(isFirstInRun = true, isLastInRun = true, startsNewDay = false) }
        if (inputs.size <= 1) {
            return finishDaySeparators(inputs, infos, zone)
        }
        for (index in 1 until inputs.size) {
            val previous = inputs[index - 1]
            val current = inputs[index]
            val sameRun = previous.groupable && current.groupable &&
                previous.senderKey == current.senderKey &&
                withinWindow(previous.timestamp, current.timestamp, window)
            infos[index].isFirstInRun = !sameRun
            infos[index - 1].isLastInRun = !sameRun
        }
        return finishDaySeparators(inputs, infos, zone)
    }

    /**
     * Marks each item whose timestamp falls on a later calendar day than the previous TIMESTAMPED item; the first
     * timestamped item gets no leading separator (separators go BETWEEN items).
     */
    private fun finishDaySeparators(inputs: List<Input>, infos: List<Info>, zone: ZoneId): List<Info> {
        var lastTimestamp: Instant? = null
        for (index in inputs.indices) {
            val timestamp = inputs[index].timestamp ?: continue
            val last = lastTimestamp
            if (last != null && !isSameDay(timestamp, last, zone)) {
                infos[index].startsNewDay = true
            }
            lastTimestamp = timestamp
        }
        return infos
    }

    private fun isSameDay(a: Instant, b: Instant, zone: ZoneId): Boolean =
        a.atZone(zone).toLocalDate() == b.atZone(zone).toLocalDate()

    /**
     * Two items are within the run window when both timestamps are present and close enough. When a timestamp is
     * missing (a transport that omits them), fall back to sender-only grouping.
     */
    private fun withinWindow(a: Instant?, b: Instant?, window: Double): Boolean {
        if (a == null || b == null) {
            return true
        }
        val seconds = abs(a.toEpochMilli() - b.toEpochMilli()) / 1000.0
        return seconds <= window
    }
}
