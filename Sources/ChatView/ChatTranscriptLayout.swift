// Sources/ChatView/ChatTranscriptLayout.swift
//
// Pure, unit-testable layout helpers for the dual-alignment (person-to-person / group)
// transcript: run grouping, day-separator placement, and RFC 3339 timestamp parsing. No
// SwiftUI - the view consumes these results to place bubbles, sender labels, avatars,
// timestamp captions, and day headers. Kept pure and extracted because run-grouping and
// day-separator logic breeds off-by-ones (plan risk 3), so it is tested directly.

import Foundation

/// RFC 3339 timestamp parsing, shared by the store and the view. The wire form is a String
/// (cross-platform stability); this parses it to a Date for display grouping / formatting.
enum ChatTimestamp {
    /// Parses an RFC 3339 / ISO 8601 timestamp (with or without fractional seconds). Returns nil for
    /// a nil / empty / unparseable value.
    static func parse(_ string: String?) -> Date? {
        guard let string, !string.isEmpty else {
            return nil
        }
        if let date = isoFractional.date(from: string) {
            return date
        }
        return isoPlain.date(from: string)
    }

    /// The wire form of a moment: RFC 3339 in UTC to the second ("2026-08-21T06:55:12Z") - the
    /// form `parse` reads back, and the form a host's own stamps take, so a line the store stamps
    /// and a line the host stamps are told apart by nothing.
    static func format(_ date: Date) -> String {
        isoPlain.string(from: date)
    }

    // ISO8601DateFormatter is not Sendable, but once configured its date(from:) parsing and
    // string(from:) formatting are thread-safe (read-only use), so a shared instance is safe to
    // reuse across contexts.
    nonisolated(unsafe) private static let isoFractional: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    nonisolated(unsafe) private static let isoPlain: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()
}

enum ChatTranscriptLayout {

    /// One transcript item reduced to just what layout needs.
    struct Input: Equatable {
        /// A stable per-author key. Two consecutive `groupable` items with the same key (within the
        /// time window) form a run. Non-groupable items are given any key; `groupable` gates grouping.
        let senderKey: String
        /// Whether this item participates in run grouping (messages and files do; member / call /
        /// system events are centered captions that break a run and never group).
        let groupable: Bool
        /// The item's timestamp, when it carries one.
        let timestamp: Date?

        init(senderKey: String, groupable: Bool, timestamp: Date?) {
            self.senderKey = senderKey
            self.groupable = groupable
            self.timestamp = timestamp
        }
    }

    /// Per-item placement derived from the sequence.
    struct Info: Equatable {
        /// First item of its run (its sender label renders above it).
        var isFirstInRun: Bool
        /// Last item of its run (its timestamp / delivery caption and avatar render at it).
        var isLastInRun: Bool
        /// A day-separator caption renders immediately before this item (the calendar day advanced).
        var startsNewDay: Bool
    }

    /// Default run window: consecutive same-sender items within this many seconds group.
    static let defaultRunWindow: TimeInterval = 60

    /// Computes run positions and day-separator flags for a transcript. `window` is the run
    /// grouping window; `calendar` decides day boundaries (injectable for tests).
    static func layout(_ inputs: [Input],
                       window: TimeInterval = defaultRunWindow,
                       calendar: Calendar = .current) -> [Info] {
        var infos = inputs.map { _ in Info(isFirstInRun: true, isLastInRun: true, startsNewDay: false) }
        guard inputs.count > 1 else {
            return finishDaySeparators(inputs, &infos, calendar: calendar)
        }
        for index in 1..<inputs.count {
            let previous = inputs[index - 1]
            let current = inputs[index]
            let sameRun = previous.groupable && current.groupable
                && previous.senderKey == current.senderKey
                && withinWindow(previous.timestamp, current.timestamp, window)
            infos[index].isFirstInRun = !sameRun
            infos[index - 1].isLastInRun = !sameRun
        }
        return finishDaySeparators(inputs, &infos, calendar: calendar)
    }

    /// Marks each item whose timestamp falls on a later calendar day than the previous TIMESTAMPED
    /// item; the first timestamped item gets no leading separator (separators go BETWEEN items).
    private static func finishDaySeparators(_ inputs: [Input], _ infos: inout [Info], calendar: Calendar) -> [Info] {
        var lastTimestamp: Date?
        for index in inputs.indices {
            guard let timestamp = inputs[index].timestamp else {
                continue
            }
            if let last = lastTimestamp, !calendar.isDate(timestamp, inSameDayAs: last) {
                infos[index].startsNewDay = true
            }
            lastTimestamp = timestamp
        }
        return infos
    }

    /// Two items are within the run window when both timestamps are present and close enough. When a
    /// timestamp is missing (a transport that omits them), fall back to sender-only grouping.
    private static func withinWindow(_ a: Date?, _ b: Date?, _ window: TimeInterval) -> Bool {
        guard let a, let b else {
            return true
        }
        return abs(a.timeIntervalSince(b)) <= window
    }
}
