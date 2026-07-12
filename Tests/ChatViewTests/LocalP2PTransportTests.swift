// Tests/ChatViewTests/LocalP2PTransportTests.swift
//
// P6 tests for the scripted local-p2p transport: it seeds the group / people conversation with the
// full v2 vocabulary, answers a user send with a delivery ladder + a peer reply, honors
// reaction / edit / delete commands, and serves synthetic paged history that terminates. Driven at
// stepMs 0 so the seed is deterministic (the ambient "little life" is paced-mode only). A background
// task drains the event stream into a locked sink; the test settles briefly and asserts (the stream
// is idle at stepMs 0 once the scripted beats have run).

import XCTest
@testable import ChatView

private final class EventSink: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [ChatEvent] = []
    func add(_ event: ChatEvent) { lock.withLock { events.append(event) } }
    func all() -> [ChatEvent] { lock.withLock { events } }
    func clear() { lock.withLock { events.removeAll() } }
}

final class LocalP2PTransportTests: XCTestCase {

    private func makeTransport(scenario: String) -> LocalP2PTransport {
        LocalP2PTransport(config: ChatTransportConfig(protocolName: "local-p2p",
                                                      settings: ["scenario": scenario, "stepMs": 0]))
    }

    private func consume(_ transport: LocalP2PTransport) -> EventSink {
        let sink = EventSink()
        Task { for await event in transport.events { sink.add(event) } }
        return sink
    }

    private func settle() async {
        for _ in 0..<4 {
            await Task.yield()
            try? await Task.sleep(nanoseconds: 12_000_000)
        }
    }

    func testGroupSeedExercisesTheFullVocabulary() async {
        let transport = makeTransport(scenario: "group")
        let sink = consume(transport)
        await transport.start()
        await settle()
        let events = sink.all()
        await transport.stop()

        var participants: [Participant] = []
        var memberEvents = 0, callEvents = 0, files = 0, voices = 0, messages = 0
        for event in events {
            switch event {
            case .participantsChanged(let roster): participants = roster
            case .memberEvent:                     memberEvents += 1
            case .callEvent:                       callEvents += 1
            case .fileAdded(let file):             file.kind == .voice ? (voices += 1) : (files += 1)
            case .messageReceived:                 messages += 1
            default:                               break
            }
        }
        XCTAssertEqual(participants.count, 4, "group roster: You + Alex + Sam + Jordan")
        XCTAssertTrue(participants.contains { $0.isSelf == true }, "one participant is self")
        XCTAssertGreaterThanOrEqual(memberEvents, 2, "a join and a rename")
        XCTAssertEqual(callEvents, 1)
        XCTAssertEqual(files, 1)
        XCTAssertEqual(voices, 1)
        XCTAssertGreaterThanOrEqual(messages, 4)
    }

    func testPeopleScenarioHasNoGroupOnlyItems() async {
        let transport = makeTransport(scenario: "people")
        let sink = consume(transport)
        await transport.start()
        await settle()
        let events = sink.all()
        await transport.stop()

        XCTAssertFalse(events.contains { if case .memberEvent = $0 { return true }; return false },
                       "a 1:1 chat has no member events")
        XCTAssertFalse(events.contains { if case .callEvent = $0 { return true }; return false })
        let roster = events.compactMap { event -> [Participant]? in
            if case .participantsChanged(let r) = event { return r }
            return nil
        }.first
        XCTAssertEqual(roster?.count, 2, "people roster: You + Alex")
    }

    func testUserSendGetsDeliveryLadderAndReply() async {
        let transport = makeTransport(scenario: "people")
        let sink = consume(transport)
        await transport.start()
        await settle()
        sink.clear()
        await transport.send(.prompt(text: "Are you around?"))
        await settle()
        let events = sink.all()
        await transport.stop()

        XCTAssertTrue(events.contains { if case .messageStatusChanged(_, let s) = $0 { return s == .sent || s == .delivered }; return false },
                      "the own message advances through the delivery ladder")
        XCTAssertTrue(events.contains { if case .messageReceived(let m) = $0 { return m.role == .remote }; return false },
                      "the peer replies")
    }

    func testStartReportsConnected() async {
        let transport = makeTransport(scenario: "people")
        let sink = consume(transport)
        await transport.start()
        await settle()
        let events = sink.all()
        await transport.stop()

        XCTAssertTrue(transport.capabilities.reportsConnectionState, "local-p2p reports connection state")
        XCTAssertTrue(events.contains { if case .connectionStateChanged(.connected) = $0 { return true }; return false },
                      "the link comes up on start")
    }

    func testSendConfirmsAServerIdThenDrivesTheLadderOnIt() async {
        let transport = makeTransport(scenario: "people")
        let sink = consume(transport)
        await transport.start()
        await settle()
        sink.clear()
        await transport.send(.sendMessage(text: "Are you around?", replyTo: nil, localID: "user-1"))
        await settle()
        let events = sink.all()
        await transport.stop()

        // The transport confirms a server id for the optimistic localID before any server-keyed event.
        guard let serverID = events.compactMap({ event -> String? in
            if case .messageIDConfirmed(let localID, let serverID) = event, localID == "user-1" { return serverID }
            return nil
        }).first else {
            return XCTFail("expected a messageIDConfirmed for the sent localID")
        }
        XCTAssertTrue(serverID.hasPrefix("srv-"), "the demo mints a srv-* server id")
        // Every own-message status event after confirmation is keyed by the server id, never "user-1".
        let statusIDs = events.compactMap { event -> String? in
            if case .messageStatusChanged(let id, _) = event { return id }
            return nil
        }
        XCTAssertFalse(statusIDs.isEmpty, "the delivery ladder runs")
        XCTAssertTrue(statusIDs.allSatisfy { $0 == serverID }, "the ladder targets the server id, not the optimistic id")
        XCTAssertTrue(events.contains { if case .messageStatusWatermark(let s, let id) = $0 { return s == .read && id == serverID }; return false },
                      "the peer's read watermark targets the server id")
    }

    func testReactionEditDeleteAreEchoed() async {
        let transport = makeTransport(scenario: "people")
        let sink = consume(transport)
        await transport.start()
        await settle()
        sink.clear()
        await transport.send(.toggleReaction(itemID: "seed-1", emoji: "\u{1F44D}", add: true))
        await transport.send(.editMessage(itemID: "seed-3", newText: "changed"))
        await transport.send(.deleteMessage(itemID: "seed-3"))
        await settle()
        let events = sink.all()
        await transport.stop()

        XCTAssertTrue(events.contains { if case .reactionsChanged(_, let r) = $0 { return r.first?.mine == true }; return false })
        XCTAssertTrue(events.contains { if case .messageEdited(_, let text, _) = $0 { return text == "changed" }; return false })
        XCTAssertTrue(events.contains { if case .messageDeleted(let id) = $0 { return id == "seed-3" }; return false })
    }

    func testPagingServesFiftyPerPageAndTerminates() async {
        let transport = makeTransport(scenario: "people")
        let sink = consume(transport)
        await transport.start()
        await settle()

        var totalItems = 0
        var pages = 0
        var lastHasMore = true
        while lastHasMore, pages < 10 {
            sink.clear()
            await transport.send(.loadEarlier(beforeItemID: "seed-1", limit: 50))
            await settle()
            guard let page = sink.all().compactMap({ event -> (Int, Bool)? in
                if case .historyPage(let items, let hasMore) = event { return (items.count, hasMore) }
                return nil
            }).first else {
                await transport.stop()
                return XCTFail("expected a history page")
            }
            totalItems += page.0
            lastHasMore = page.1
            pages += 1
        }
        await transport.stop()

        XCTAssertEqual(totalItems, 200, "the 200-item synthetic history is fully served")
        XCTAssertFalse(lastHasMore, "paging terminates (hasMore=false on the last page)")
        XCTAssertEqual(pages, 4, "200 / 50 = 4 pages")
    }
}
