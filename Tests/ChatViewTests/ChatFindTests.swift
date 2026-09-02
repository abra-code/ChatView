// Tests/ChatViewTests/ChatFindTests.swift
//
// Transcript search: the headless engine over items (scope, skipped items, rendered-text parity with
// what the view highlights), the store's find state (cursor, recompute on finalized text only, the
// search channel), and the `find` configuration key.

import XCTest
import Combine
import RichText
@testable import ChatView

private final class FindTestLogger: ChatLogger {
    func log(_ message: String, _ level: ChatLogLevel) {}
}

/// Virtual time for the store's debounces (the bar's typing pause) and flushes.
@MainActor
private final class ManualScheduler: ChatScheduler {
    private struct Pending {
        let fireAt: Date
        let body: @MainActor () -> Void
    }
    private var pending: [String: Pending] = [:]
    private(set) var now = Date(timeIntervalSince1970: 1_000_000)

    func schedule(_ key: String, after delay: TimeInterval, _ body: @escaping @MainActor () -> Void) {
        pending[key] = Pending(fireAt: now.addingTimeInterval(delay), body: body)
    }

    func cancel(_ key: String) {
        pending[key] = nil
    }

    var pendingKeys: [String] { Array(pending.keys) }

    func advance(by seconds: TimeInterval) {
        now = now.addingTimeInterval(seconds)
        while let key = pending.first(where: { $0.value.fireAt <= now })?.key {
            let body = pending.removeValue(forKey: key)!.body
            body()
        }
    }
}

/// A ChatContentSource with the content and search channels, delivering the current value on
/// subscription and on every change like the engine's ViewModel.
@MainActor
private final class FakeFindSource: ChatContentSource {
    var content: Any? {
        didSet { contentObservers.values.forEach { $0(content) } }
    }
    var search: Any? {
        didSet { searchObservers.values.forEach { $0(search) } }
    }
    private var contentObservers: [Int: (Any?) -> Void] = [:]
    private var searchObservers: [Int: (Any?) -> Void] = [:]
    private var nextID = 0

    func observeChatContent(_ handler: @escaping (Any?) -> Void) -> AnyCancellable {
        nextID += 1
        let id = nextID
        contentObservers[id] = handler
        handler(content)
        return AnyCancellable { MainActor.assumeIsolated { self.contentObservers[id] = nil } }
    }

    func observeChatConfig(_ handler: @escaping (Any?) -> Void) -> AnyCancellable {
        AnyCancellable {}
    }

    func observeChatSearch(_ handler: @escaping (Any?) -> Void) -> AnyCancellable {
        nextID += 1
        let id = nextID
        searchObservers[id] = handler
        handler(search)
        return AnyCancellable { MainActor.assumeIsolated { self.searchObservers[id] = nil } }
    }
}

@MainActor
final class ChatFindTests: XCTestCase {

    private func message(_ id: String, _ text: String, role: ChatRole = .agent, streaming: Bool = false,
                         deleted: Bool? = nil) -> ChatItem {
        .message(ChatMessage(id: id, role: role, text: text, isStreaming: streaming, deleted: deleted))
    }

    private var items: [ChatItem] {
        [
            message("m1", "The quick brown **fox** jumps.", role: .local),
            .thought(ChatMessage(id: "t1", role: .agent, text: "Is it a fox or a dog?", isStreaming: false)),
            .toolCall(ToolCallModel(id: "c1", title: "Search for fox", kind: .search, status: .completed,
                                    contentText: "Found fox in 2 files")),
            message("m2", "A fox again, and a Fox."),
            .system(id: "s1", text: "Fox session started"),
            message("m3", "fox (deleted)", deleted: true),
            message("m4", "streaming fox", streaming: true),
            .file(ChatFile(id: "f1", role: .remote, senderID: nil, senderName: nil, timestamp: nil, status: nil,
                           name: "fox.pdf", sizeBytes: nil, url: nil, kind: .file, durationSeconds: nil)),
        ]
    }

    private func transcriptJSON(_ items: [ChatItem]) -> String {
        let data = try! JSONEncoder().encode(ChatTranscript(items: items))
        return String(decoding: data, as: UTF8.self)
    }

    // MARK: - Engine

    func testCaptionsOnPhotosAndFilesAreSearchedAsBodies() {
        let url = URL(string: "https://example.test/p.jpg")!
        let captioned: [ChatItem] = [
            .image(ChatImageItem(id: "p1", role: .remote, image: ChatImage(url: url), caption: "the **fox** at dusk")),
            .image(ChatImageItem(id: "p2", role: .remote, image: ChatImage(url: url, alt: "a fox"))),   // alt is not searched
            .file(ChatFile(id: "f1", role: .remote, name: "fox.pdf", caption: "fox notes")),
        ]
        let hits = ChatSearch.matches(in: captioned, query: "fox")
        XCTAssertEqual(hits.map(\.itemID), ["p1", "f1", "f1"])
        XCTAssertEqual(hits.map(\.field), [.body, .fileName, .body])
        XCTAssertEqual(hits.first?.range, NSRange(location: 4, length: 3), "a caption is searched as the rendered text")
    }

    func testDefaultScopeSearchesMessagesCaptionsAndFileNames() {
        let hits = ChatSearch.matches(in: items, query: "fox")
        XCTAssertEqual(hits.map(\.itemID), ["m1", "m2", "m2", "s1", "f1"])
        XCTAssertEqual(hits.map(\.field), [.body, .body, .body, .caption, .fileName])
        // Deleted and streaming messages are skipped; thoughts and tool calls are out of scope.
        XCTAssertFalse(hits.contains { $0.itemID == "m3" || $0.itemID == "m4" || $0.itemID == "t1" || $0.itemID == "c1" })
    }

    func testThoughtsAndToolCallsAreOptIn() {
        let all = ChatSearch.matches(in: items, query: "fox", scope: .all)
        XCTAssertEqual(all.map(\.itemID), ["m1", "t1", "c1", "c1", "m2", "m2", "s1", "f1"])
        XCTAssertEqual(all.filter { $0.itemID == "c1" }.map(\.field), [.title, .body])
        let thoughtsOnly = ChatSearch.matches(in: items, query: "fox", scope: [.thoughts])
        XCTAssertEqual(thoughtsOnly.map(\.itemID), ["t1"])
    }

    func testBodyRangesAreInTheRenderedTextTheViewHighlights() {
        // "**fox**" renders as "fox": the range must address the rendered string, not the Markdown.
        let hit = ChatSearch.matches(in: [items[0]], query: "fox")[0]
        let rendered = ChatSearch.renderedText(markdown: "The quick brown **fox** jumps.")
        XCTAssertEqual((rendered as NSString).substring(with: hit.range), "fox")
        XCTAssertEqual(hit.range, NSRange(location: 16, length: 3))
        XCTAssertEqual(hit.snippet, "The quick brown fox jumps.")
    }

    func testOptionsPassThrough() {
        let sensitive = ChatSearch.matches(in: items, query: "Fox", options: RichTextSearchOptions(caseSensitive: true))
        XCTAssertEqual(sensitive.map(\.itemID), ["m2", "s1"])
        // A regular expression, matched per field with the same case rule.
        let pattern = ChatSearch.matches(in: items, query: "F[aeiou]x", options: RichTextSearchOptions(caseSensitive: true, regularExpression: true))
        XCTAssertEqual(pattern.map(\.itemID), ["m2", "s1"])
        let anchored = ChatSearch.matches(in: items, query: "^Fox", options: RichTextSearchOptions(regularExpression: true), scope: .all)
        XCTAssertEqual(anchored.map(\.itemID), ["s1", "f1"], "anchors bound each field's own text")
        XCTAssertEqual(ChatSearch.matches(in: items, query: "F[ox", options: RichTextSearchOptions(regularExpression: true)), [])
    }

    func testSearchableTextForIndexers() {
        XCTAssertEqual(items[0].searchableText(), "The quick brown fox jumps.")
        XCTAssertNil(items[5].searchableText(), "a deleted message shows nothing")
        XCTAssertNil(items[1].searchableText(), "thoughts are out of the default scope")
        XCTAssertEqual(items[2].searchableText(scope: .all), "Search for fox\nFound fox in 2 files")
        let transcript = ChatTranscript(items: [items[0], items[4]])
        XCTAssertEqual(transcript.searchableText(), "The quick brown fox jumps.\n\nFox session started")
    }

    func testRenderedTextCacheReusesUntilTextChanges() {
        let cache = ChatSearchTextCache()
        let first = cache.renderedText(for: "x", markdown: "a **b**")
        XCTAssertEqual(first, "a b")
        XCTAssertEqual(cache.count, 1)
        _ = cache.renderedText(for: "x", markdown: "a **b**")
        XCTAssertEqual(cache.count, 1)
        XCTAssertEqual(cache.renderedText(for: "x", markdown: "a **c**"), "a c")
        cache.removeAll()
        XCTAssertEqual(cache.count, 0)
    }

    // MARK: - Store

    private func makeStore(_ source: FakeFindSource, showFindBar: Bool = true, readOnly: Bool = true,
                           scheduler: ManualScheduler? = nil) -> ChatStore {
        let store = ChatStore(config: ChatConfiguration(readOnly: readOnly, showFindBar: showFindBar), logger: FindTestLogger(),
                              contentSource: source, scheduler: scheduler)
        store.start()
        return store
    }

    func testStoreQueryCursorAndDismiss() {
        let source = FakeFindSource()
        source.content = transcriptJSON(items)
        let store = makeStore(source)
        XCTAssertEqual(store.find.summary, "")

        // Six, not the engine's five: a restored transcript finalizes every message, so the fixture's
        // "streaming" one is searchable once it has been through the content channel.
        store.setFindQuery("fox")
        XCTAssertEqual(store.find.hits.count, 6)
        XCTAssertEqual(store.find.currentIndex, 0)
        XCTAssertEqual(store.find.summary, "1 of 6")
        XCTAssertEqual(store.find.current?.itemID, "m1")

        store.findNext()
        store.findNext()
        XCTAssertEqual(store.find.current?.itemID, "m2")
        XCTAssertEqual(store.find.currentIndex, 2)
        // Per-row ranges: m2 has two hits, the second is current.
        let m2 = store.find.ranges(for: "m2", field: .body)
        XCTAssertEqual(m2?.ranges.count, 2)
        XCTAssertEqual(m2?.current, 1)
        XCTAssertNil(store.find.ranges(for: "m1", field: .body)?.current)
        XCTAssertNil(store.find.ranges(for: "m2", field: .caption))
        XCTAssertEqual(store.find.highlights(for: "m2", style: .default)?.current, 1)

        store.findPrevious()
        store.findPrevious()
        store.findPrevious()
        XCTAssertEqual(store.find.currentIndex, 5, "wraps backward")
        store.findNext()
        XCTAssertEqual(store.find.currentIndex, 0, "wraps forward")

        store.setFindScope(.all)
        XCTAssertEqual(store.find.hits.count, 9)
        // The tool call has hits in two fields; each field's ranges know only their own current.
        while !(store.find.current?.itemID == "c1" && store.find.current?.field == .title) {
            store.findNext()
        }
        XCTAssertEqual(store.find.ranges(for: "c1", field: .title)?.current, 0)
        XCTAssertNil(store.find.ranges(for: "c1", field: .body)?.current)
        store.findNext()
        XCTAssertEqual(store.find.current?.field, .body)
        XCTAssertNil(store.find.ranges(for: "c1", field: .title)?.current)
        XCTAssertEqual(store.find.ranges(for: "c1", field: .body)?.current, 0)
        store.setFindOptions(RichTextSearchOptions(caseSensitive: true))
        XCTAssertEqual(store.find.hits.count, 7, "the capitalized Fox in m2 and s1 drop out")

        store.presentFind()
        XCTAssertTrue(store.find.isPresented)
        store.dismissFind()
        XCTAssertFalse(store.find.isPresented)
        XCTAssertEqual(store.find.query, "")
        XCTAssertTrue(store.find.hits.isEmpty)
        XCTAssertNil(store.find.current)
    }

    func testStoreRecomputesWhenFinalizedTextChangesAndKeepsTheCursor() {
        let source = FakeFindSource()
        source.content = transcriptJSON([message("m1", "fox one"), message("m2", "fox two")])
        let store = makeStore(source)
        store.setFindQuery("fox")
        store.findNext()
        XCTAssertEqual(store.find.current?.itemID, "m2")

        // A new conversation load with the same hit still present keeps the reader on it.
        source.content = transcriptJSON([message("m0", "fox zero"), message("m1", "fox one"), message("m2", "fox two")])
        XCTAssertEqual(store.find.hits.count, 3)
        XCTAssertEqual(store.find.current?.itemID, "m2")
        XCTAssertEqual(store.find.currentIndex, 2)

        // The hit's message is gone: back to the first hit.
        source.content = transcriptJSON([message("m0", "fox zero"), message("m1", "fox one")])
        XCTAssertEqual(store.find.hits.count, 2)
        XCTAssertEqual(store.find.currentIndex, 0)

        // No query: a content change costs nothing and finds nothing.
        store.dismissFind()
        source.content = transcriptJSON([message("m9", "fox nine")])
        XCTAssertTrue(store.find.hits.isEmpty)
    }

    func testRegularExpressionOptionAndInvalidPattern() {
        let source = FakeFindSource()
        source.content = transcriptJSON(items)
        let store = makeStore(source)
        store.setFindOptions(RichTextSearchOptions(regularExpression: true))
        store.setFindQuery("f(ox")
        XCTAssertEqual(store.find.summary, "Invalid expression")
        XCTAssertTrue(store.find.hits.isEmpty)
        store.setFindQuery("f[o]x")
        XCTAssertEqual(store.find.summary, "1 of 6")
        // Off again: the same characters are a literal that the conversation does not contain.
        store.setFindOptions(RichTextSearchOptions())
        XCTAssertEqual(store.find.summary, "No matches")
    }

    func testStepOnNothingIsANoOp() {
        let source = FakeFindSource()
        source.content = transcriptJSON(items)
        let store = makeStore(source)
        store.setFindQuery("zebra")
        XCTAssertEqual(store.find.summary, "No matches")
        store.findNext()
        store.findPrevious()
        XCTAssertNil(store.find.currentIndex)
        store.setFindQuery("   ")
        XCTAssertEqual(store.find.summary, "", "a blank query is not a search")
    }

    func testTypingIsDebouncedButTheQueryIsPublishedAtOnce() {
        let source = FakeFindSource()
        source.content = transcriptJSON(items)
        let scheduler = ManualScheduler()
        let store = makeStore(source, scheduler: scheduler)
        store.setFindQuery("fo", debounce: 0.15)
        store.setFindQuery("fox", debounce: 0.15)
        XCTAssertEqual(store.find.query, "fox")
        XCTAssertTrue(store.find.hits.isEmpty, "nothing searched while typing")
        scheduler.advance(by: 0.2)
        XCTAssertEqual(store.find.hits.count, 6)
        // An immediate set cancels a pending debounce and searches now.
        store.setFindQuery("fox again", debounce: 0.15)
        store.setFindQuery("quick")
        XCTAssertEqual(store.find.hits.count, 1)
        XCTAssertFalse(scheduler.pendingKeys.contains("find.query"))
    }

    func testStreamingDeltasDoNotRecomputeButTheEndDoes() {
        let source = FakeFindSource()
        source.content = transcriptJSON([message("m1", "fox one")])
        let scheduler = ManualScheduler()
        let store = makeStore(source, readOnly: false, scheduler: scheduler)
        store.setFindQuery("fox")
        XCTAssertEqual(store.find.hits.count, 1)
        let before = store.find

        store.route(.messageStart(itemID: "s1", role: .agent))
        store.route(.messageDelta(itemID: "s1", text: "a fox "))
        store.route(.messageDelta(itemID: "s1", text: "and another fox"))
        scheduler.advance(by: 1)
        // The streaming message is on screen with its text, but not searched yet.
        XCTAssertTrue(store.items.contains { $0.id == "s1" })
        XCTAssertEqual(store.find, before, "a streaming delta leaves the find untouched")

        store.route(.messageEnd(itemID: "s1", stopReason: nil))
        scheduler.advance(by: 1)
        XCTAssertEqual(store.find.hits.count, 3, "the finished message is searched")
        XCTAssertEqual(store.find.currentIndex, 0, "and the reader stays on the hit they were on")
    }

    func testRunningToolCallIsSearchedWhenItSettles() {
        let source = FakeFindSource()
        source.content = transcriptJSON([message("m1", "fox one")])
        let store = makeStore(source, readOnly: false)
        store.setFindScope(.all)
        store.setFindQuery("fox")
        XCTAssertEqual(store.find.hits.count, 1)
        store.route(.toolCall(ToolCallModel(id: "c1", title: "fox hunt", kind: .search, status: .inProgress, contentText: "")))
        store.route(.toolCallUpdate(ToolCallUpdate(id: "c1", status: .inProgress, contentText: "found a fox")))
        XCTAssertEqual(store.find.hits.count, 1, "a running call is not searched")
        store.route(.toolCallUpdate(ToolCallUpdate(id: "c1", status: .completed)))
        XCTAssertEqual(store.find.hits.count, 3, "title and detail once it completes")
    }

    func testReKeyedMessageKeepsItsHits() {
        let source = FakeFindSource()
        source.content = transcriptJSON([message("m1", "fox one")])
        let store = makeStore(source, readOnly: false)
        store.setFindQuery("fox")
        store.route(.messageReceived(ChatMessage(id: "local-1", role: .local, text: "a fox", isStreaming: false)))
        XCTAssertEqual(store.find.hits.map(\.itemID), ["m1", "local-1"])
        store.findNext()
        XCTAssertEqual(store.find.current?.itemID, "local-1")
        store.route(.messageIDConfirmed(localID: "local-1", serverID: "srv-9"))
        XCTAssertEqual(store.find.hits.map(\.itemID), ["m1", "srv-9"], "hits follow the new id")
        XCTAssertEqual(store.find.current?.itemID, "srv-9", "and so does the cursor")
    }

    func testEqualCountShiftedContentRecomputes() {
        let source = FakeFindSource()
        source.content = transcriptJSON([message("m1", "fox one"), message("m2", "dog")])
        let store = makeStore(source)
        store.setFindQuery("fox")
        XCTAssertEqual(store.find.hits.map(\.itemID), ["m1"])
        source.content = transcriptJSON([message("m0", "cat"), message("m1", "fox one")])
        XCTAssertEqual(store.find.hits.map(\.itemID), ["m1"])
        XCTAssertEqual(store.find.hitIndicesByItem["m1"], [0])
    }

    func testHighlightedTextMapsUTF16RangesOntoNonASCIIText() {
        let text = "h\u{e9}llo w\u{f6}rld"
        let view = ChatHighlightedText(text, ranges: [NSRange(location: 6, length: 5), NSRange(location: 900, length: 2)], current: 0)
        let attributed = view.attributed
        let painted = attributed.runs.filter { $0.backgroundColor != nil }
        XCTAssertEqual(painted.count, 1)
        XCTAssertEqual(String(attributed[painted[0].range].characters), "w\u{f6}rld")
    }

    func testSessionEventWithADigestIsSearchedAsDrawn() {
        let digest = SessionDigest(droppedTurns: 64)
        let event = SessionEvent(id: "se2", kind: .resumed, model: "Gemma 4", digest: digest)
        let drawn = SessionEventText.displayedLines(event).headline
        XCTAssertEqual(drawn, SessionEventText.lines(event).headline, "an empty digest is not drawn")
        let hits = ChatSearch.matches(in: [.sessionEvent(event)], query: "gemma")
        XCTAssertEqual(hits.count, 1)
        XCTAssertEqual((drawn as NSString).substring(with: hits[0].range).lowercased(), "gemma")
    }

    func testCaptionsAreSearchedAsTheRowsDrawThem() {
        let event = SessionEvent(id: "se1", kind: .resumed, model: "Gemma 4")
        let member = MemberEvent(id: "me1", timestamp: nil, kind: .invited, actorName: "Alice", subjectName: "Bob", detail: nil)
        let items: [ChatItem] = [.sessionEvent(event), .memberEvent(member)]
        let resumed = ChatSearch.matches(in: items, query: "resumed")
        XCTAssertEqual(resumed.map(\.itemID), ["se1"])
        let headline = SessionEventText.lines(event, digest: nil).headline
        XCTAssertEqual((headline as NSString).substring(with: resumed[0].range).lowercased(), "resumed")
        let caption = MemberEventText.caption(member)
        let alice = ChatSearch.matches(in: items, query: "alice")
        XCTAssertEqual(alice.map(\.itemID), ["me1"])
        XCTAssertEqual((caption as NSString).substring(with: alice[0].range), "Alice")
    }

    func testSearchChannelPresentsWithQueryAndDismissesOnEmpty() {
        let source = FakeFindSource()
        source.content = transcriptJSON(items)
        let store = makeStore(source)

        source.search = "fox"
        XCTAssertTrue(store.find.isPresented)
        XCTAssertEqual(store.find.query, "fox")
        XCTAssertEqual(store.find.hits.count, 6)
        XCTAssertEqual(store.find.focusRequests, 0, "a host's term does not take the reader's focus")
        store.presentFind()
        XCTAssertEqual(store.find.focusRequests, 1, "the reader's Cmd-F does")
        store.markFindFocusHonored()
        XCTAssertEqual(store.find.focusHonored, 1)

        source.search = ""
        XCTAssertFalse(store.find.isPresented)
        XCTAssertEqual(store.find.query, "")
        XCTAssertTrue(store.find.hits.isEmpty)

        // nil is no opinion: the key going away does not touch a bar the reader may be using.
        source.search = "fox"
        source.search = nil
        XCTAssertTrue(store.find.isPresented)
        XCTAssertEqual(store.find.query, "fox")

        // A non-String value is ignored, not applied.
        source.search = 42
        XCTAssertEqual(store.find.query, "fox")
        XCTAssertTrue(store.find.isPresented)
    }

    func testSearchChannelRedeliveryDoesNotReopenAClosedBar() {
        let source = FakeFindSource()
        source.content = transcriptJSON(items)
        let store = makeStore(source)
        source.search = "fox"
        XCTAssertTrue(store.find.isPresented)
        // The reader closes the bar; an unrelated states change re-delivers the same value.
        store.dismissFind()
        source.content = transcriptJSON(items)
        source.search = "fox"
        XCTAssertFalse(store.find.isPresented)
        XCTAssertEqual(store.find.query, "")
        // Setting "" and then the term again re-opens it.
        source.search = ""
        source.search = "fox"
        XCTAssertTrue(store.find.isPresented)
        XCTAssertEqual(store.find.hits.count, 6)
    }

    func testSearchChannelHighlightsWithoutPresentingWhenFindIsOff() {
        let source = FakeFindSource()
        source.content = transcriptJSON(items)
        let store = makeStore(source, showFindBar: false)
        source.search = "fox"
        XCTAssertFalse(store.find.isPresented)
        XCTAssertEqual(store.find.hits.count, 6)
    }

    func testSearchDeliveredBeforeContentAppliesOnceContentArrives() {
        let source = FakeFindSource()
        source.search = "fox"
        let store = makeStore(source)
        XCTAssertEqual(store.find.query, "fox")
        XCTAssertTrue(store.find.hits.isEmpty)
        source.content = transcriptJSON(items)
        XCTAssertEqual(store.find.hits.count, 6)
    }

    // MARK: - Configuration

    func testFindConfigurationKeyDefaultsOn() {
        XCTAssertTrue(ChatConfiguration(dictionary: [:], logger: FindTestLogger()).showFindBar)
        XCTAssertFalse(ChatConfiguration(dictionary: ["showFindBar": false], logger: FindTestLogger()).showFindBar)
        XCTAssertTrue(ChatConfiguration(dictionary: ["showFindBar": "no"], logger: FindTestLogger()).showFindBar, "a non-Bool is ignored")
        XCTAssertTrue(ChatConfiguration().showFindBar)
    }
}
