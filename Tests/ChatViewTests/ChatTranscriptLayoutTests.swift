// Tests/ChatViewTests/ChatTranscriptLayoutTests.swift
//
// P4 tests for the pure transcript-layout helpers: RFC 3339 parsing, run grouping (same sender
// within a 60 s window, broken by sender change / time gap / a non-groupable event), and
// day-separator placement between calendar days. Deterministic (a fixed UTC calendar).

import XCTest
@testable import ChatView

final class ChatTimestampTests: XCTestCase {

    func testParsesRFC3339WithAndWithoutFractionalSeconds() {
        XCTAssertNotNil(ChatTimestamp.parse("2026-07-10T12:00:00Z"))
        XCTAssertNotNil(ChatTimestamp.parse("2026-07-10T12:00:00.500Z"))
        XCTAssertNotNil(ChatTimestamp.parse("2026-07-10T12:00:00+02:00"))
    }

    func testRejectsEmptyAndGarbage() {
        XCTAssertNil(ChatTimestamp.parse(nil))
        XCTAssertNil(ChatTimestamp.parse(""))
        XCTAssertNil(ChatTimestamp.parse("not a date"))
    }
}

final class ChatTranscriptLayoutTests: XCTestCase {

    private var utc: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }

    private func at(_ iso: String) -> Date {
        ChatTimestamp.parse(iso)!
    }

    private func input(_ sender: String, _ iso: String?, groupable: Bool = true) -> ChatTranscriptLayout.Input {
        ChatTranscriptLayout.Input(senderKey: sender, groupable: groupable, timestamp: iso.map(at))
    }

    func testConsecutiveSameSenderWithinWindowIsOneRun() {
        let infos = ChatTranscriptLayout.layout([
            input("a", "2026-07-10T12:00:00Z"),
            input("a", "2026-07-10T12:00:30Z"),
            input("a", "2026-07-10T12:00:45Z"),
        ], calendar: utc)
        XCTAssertEqual(infos.map(\.isFirstInRun), [true, false, false])
        XCTAssertEqual(infos.map(\.isLastInRun), [false, false, true])
    }

    func testTimeGapBeyondWindowBreaksTheRun() {
        let infos = ChatTranscriptLayout.layout([
            input("a", "2026-07-10T12:00:00Z"),
            input("a", "2026-07-10T12:02:00Z"),   // 120s > 60s window
        ], calendar: utc)
        XCTAssertEqual(infos.map(\.isFirstInRun), [true, true])
        XCTAssertEqual(infos.map(\.isLastInRun), [true, true])
    }

    func testDifferentSenderBreaksTheRun() {
        let infos = ChatTranscriptLayout.layout([
            input("a", "2026-07-10T12:00:00Z"),
            input("b", "2026-07-10T12:00:05Z"),
            input("a", "2026-07-10T12:00:10Z"),
        ], calendar: utc)
        XCTAssertEqual(infos.map(\.isFirstInRun), [true, true, true])
        XCTAssertEqual(infos.map(\.isLastInRun), [true, true, true])
    }

    func testNonGroupableEventBreaksRunsOnBothSides() {
        let infos = ChatTranscriptLayout.layout([
            input("a", "2026-07-10T12:00:00Z"),
            input("sys", "2026-07-10T12:00:05Z", groupable: false),   // a member/call/system event
            input("a", "2026-07-10T12:00:10Z"),
        ], calendar: utc)
        // The event is its own run; the two messages do not merge across it.
        XCTAssertEqual(infos.map(\.isFirstInRun), [true, true, true])
        XCTAssertEqual(infos.map(\.isLastInRun), [true, true, true])
    }

    func testMissingTimestampsFallBackToSenderGrouping() {
        let infos = ChatTranscriptLayout.layout([
            input("a", nil),
            input("a", nil),
            input("b", nil),
        ], calendar: utc)
        XCTAssertEqual(infos.map(\.isFirstInRun), [true, false, true])
        XCTAssertEqual(infos.map(\.isLastInRun), [false, true, true])
    }

    func testDaySeparatorMarkedOnlyWhenTheCalendarDayAdvances() {
        let infos = ChatTranscriptLayout.layout([
            input("a", "2026-07-10T23:59:00Z"),
            input("a", "2026-07-11T00:01:00Z"),   // next day -> separator before this one
            input("b", "2026-07-11T09:00:00Z"),   // same day -> no separator
        ], calendar: utc)
        XCTAssertEqual(infos.map(\.startsNewDay), [false, true, false],
                       "a day separator falls between items only when the calendar day changes; never before the first")
    }

    func testItemsWithoutTimestampsGetNoDaySeparators() {
        let infos = ChatTranscriptLayout.layout([
            input("a", nil),
            input("a", nil),
        ], calendar: utc)
        XCTAssertEqual(infos.map(\.startsNewDay), [false, false])
    }

    func testEmptyAndSingleItem() {
        XCTAssertTrue(ChatTranscriptLayout.layout([], calendar: utc).isEmpty)
        let one = ChatTranscriptLayout.layout([input("a", "2026-07-10T12:00:00Z")], calendar: utc)
        XCTAssertEqual(one, [ChatTranscriptLayout.Info(isFirstInRun: true, isLastInRun: true, startsNewDay: false)])
    }
}
