package com.abracode.chatview

import com.abracode.richtext.search.RichTextRange
import com.abracode.richtext.search.RichTextSearchOptions
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import kotlin.time.Duration.Companion.milliseconds
import kotlin.time.Duration.Companion.seconds

// Port of Tests/ChatViewTests/ChatFindTests.swift: the headless engine over items (scope, skipped items,
// rendered-text parity with what the rows highlight), the store's find state (cursor, recompute on finalized text
// only, the search channel), and the `find` configuration key.
class ChatFindTest {

    private fun message(id: String, text: String, role: ChatRole = ChatRole.AGENT, streaming: Boolean = false, deleted: Boolean? = null) =
        ChatItem.Message(ChatMessage(id = id, role = role, text = text, isStreaming = streaming, deleted = deleted))

    private val items: List<ChatItem>
        get() = listOf(
            message("m1", "The quick brown **fox** jumps.", role = ChatRole.LOCAL),
            ChatItem.Thought(ChatMessage(id = "t1", role = ChatRole.AGENT, text = "Is it a fox or a dog?")),
            ChatItem.ToolCall(
                ToolCallModel(
                    id = "c1", title = "Search for fox", kind = ToolCallModel.Kind.SEARCH,
                    status = ToolCallModel.Status.COMPLETED, contentText = "Found fox in 2 files",
                ),
            ),
            message("m2", "A fox again, and a Fox."),
            ChatItem.System(id = "s1", text = "Fox session started"),
            message("m3", "fox (deleted)", deleted = true),
            message("m4", "streaming fox", streaming = true),
            ChatItem.File(ChatFile(id = "f1", role = ChatRole.REMOTE, name = "fox.pdf")),
        )

    private fun transcriptJson(items: List<ChatItem>): String = chatJson.encodeToString(ChatTranscript.serializer(), ChatTranscript(items = items))

    // --- Engine. ---

    @Test fun defaultScopeSearchesMessagesCaptionsAndFileNames() {
        val hits = ChatSearch.matches(items, "fox")
        assertEquals(listOf("m1", "m2", "m2", "s1", "f1"), hits.map { it.itemID })
        assertEquals(
            listOf(ChatSearchField.BODY, ChatSearchField.BODY, ChatSearchField.BODY, ChatSearchField.CAPTION, ChatSearchField.FILE_NAME),
            hits.map { it.field },
        )
        assertFalse(hits.any { it.itemID in setOf("m3", "m4", "t1", "c1") })
    }

    @Test fun thoughtsAndToolCallsAreOptIn() {
        val all = ChatSearch.matches(items, "fox", scope = ChatSearchScope.All)
        assertEquals(listOf("m1", "t1", "c1", "c1", "m2", "m2", "s1", "f1"), all.map { it.itemID })
        assertEquals(listOf(ChatSearchField.TITLE, ChatSearchField.BODY), all.filter { it.itemID == "c1" }.map { it.field })
        assertEquals(listOf("t1"), ChatSearch.matches(items, "fox", scope = setOf(ChatSearchScope.THOUGHTS)).map { it.itemID })
    }

    @Test fun bodyRangesAreInTheRenderedTextTheRowsHighlight() {
        // "**fox**" renders as "fox": the range addresses the rendered text, not the Markdown.
        val hit = ChatSearch.matches(listOf(items[0]), "fox")[0]
        val rendered = ChatSearch.renderedText("The quick brown **fox** jumps.")
        assertEquals("fox", rendered.substring(hit.range.start, hit.range.end))
        assertEquals(RichTextRange(16, 19), hit.range)
        assertEquals("The quick brown fox jumps.", hit.snippet)
    }

    @Test fun optionsPassThrough() {
        val sensitive = ChatSearch.matches(items, "Fox", options = RichTextSearchOptions(caseSensitive = true))
        assertEquals(listOf("m2", "s1"), sensitive.map { it.itemID })
    }

    @Test fun searchableTextForIndexers() {
        assertEquals("The quick brown fox jumps.", items[0].searchableText())
        assertNull("a deleted message shows nothing", items[5].searchableText())
        assertNull("thoughts are out of the default scope", items[1].searchableText())
        assertEquals("Search for fox\nFound fox in 2 files", items[2].searchableText(ChatSearchScope.All))
        assertEquals("The quick brown fox jumps.\n\nFox session started", ChatTranscript(items = listOf(items[0], items[4])).searchableText())
    }

    @Test fun captionsAreSearchedAsTheRowsDrawThem() {
        val member = MemberEvent(id = "me1", kind = MemberEvent.Kind.INVITED, actorName = "Alice", subjectName = "Bob")
        val hits = ChatSearch.matches(listOf(ChatItem.MemberEventItem(member)), "alice")
        assertEquals(listOf("me1"), hits.map { it.itemID })
        val caption = com.abracode.chatview.ui.memberEventText(member)
        assertEquals("Alice", caption.substring(hits[0].range.start, hits[0].range.end))
    }

    @Test fun renderedTextCacheReusesUntilTextChanges() {
        val cache = ChatSearchTextCache()
        assertEquals("a b", cache.renderedText("x", "a **b**"))
        assertEquals(1, cache.size)
        cache.renderedText("x", "a **b**")
        assertEquals(1, cache.size)
        assertEquals("a c", cache.renderedText("x", "a **c**"))
        cache.retain(emptySet())
        assertEquals(0, cache.size)
    }

    // --- Store. ---

    private fun makeStore(source: FakeContentSource, showFindBar: Boolean = true, readOnly: Boolean = true, scheduler: ManualChatScheduler? = null): ChatStore {
        val store = ChatStore(
            config = ChatConfiguration(readOnly = readOnly, showFindBar = showFindBar),
            logger = noopLogger(),
            contentSource = source,
            scheduler = scheduler ?: ManualChatScheduler(),
            scope = inertScope(),
        )
        store.start()
        return store
    }

    @Test fun storeQueryCursorAndDismiss() {
        val source = FakeContentSource(seed = transcriptJson(items))
        val store = makeStore(source)
        assertEquals("", store.find.summary)

        // Six, not the engine's five: a restored transcript finalizes every message, so the fixture's "streaming"
        // one is searchable once it has been through the content channel.
        store.setFindQuery("fox")
        assertEquals(6, store.find.hits.size)
        assertEquals(0, store.find.currentIndex)
        assertEquals("1 of 6", store.find.summary)
        assertEquals("m1", store.find.current?.itemID)

        store.findNext()
        store.findNext()
        assertEquals("m2", store.find.current?.itemID)
        val m2 = store.find.ranges("m2", ChatSearchField.BODY)!!
        assertEquals(2, m2.first.size)
        assertEquals(1, m2.second)
        assertNull(store.find.ranges("m1", ChatSearchField.BODY)!!.second)
        assertNull(store.find.ranges("m2", ChatSearchField.CAPTION))

        store.findPrevious(); store.findPrevious(); store.findPrevious()
        assertEquals("wraps backward", 5, store.find.currentIndex)
        store.findNext()
        assertEquals("wraps forward", 0, store.find.currentIndex)

        store.setFindScope(ChatSearchScope.All)
        assertEquals(9, store.find.hits.size)
        while (!(store.find.current?.itemID == "c1" && store.find.current?.field == ChatSearchField.TITLE)) store.findNext()
        assertEquals(0, store.find.ranges("c1", ChatSearchField.TITLE)!!.second)
        assertNull(store.find.ranges("c1", ChatSearchField.BODY)!!.second)
        store.setFindOptions(RichTextSearchOptions(caseSensitive = true))
        assertEquals("the capitalized Fox in m2 and s1 drop out", 7, store.find.hits.size)

        store.presentFind()
        assertTrue(store.find.isPresented)
        store.dismissFind()
        assertFalse(store.find.isPresented)
        assertEquals("", store.find.query)
        assertTrue(store.find.hits.isEmpty())
        assertNull(store.find.current)
    }

    @Test fun typingIsDebouncedButTheQueryIsPublishedAtOnce() {
        val scheduler = ManualChatScheduler()
        val store = makeStore(FakeContentSource(seed = transcriptJson(items)), scheduler = scheduler)
        store.setFindQuery("fo", debounce = 150.milliseconds)
        store.setFindQuery("fox", debounce = 150.milliseconds)
        assertEquals("fox", store.find.query)
        assertTrue("nothing searched while typing", store.find.hits.isEmpty())
        scheduler.advance(200.milliseconds)
        assertEquals(6, store.find.hits.size)
        store.setFindQuery("fox again", debounce = 150.milliseconds)
        store.setFindQuery("quick")
        assertEquals("an immediate set cancels the pending one", 1, store.find.hits.size)
    }

    @Test fun streamingDeltasDoNotRecomputeButTheEndDoes() {
        val scheduler = ManualChatScheduler()
        val store = makeStore(FakeContentSource(seed = transcriptJson(listOf(message("m1", "fox one")))), readOnly = false, scheduler = scheduler)
        store.setFindQuery("fox")
        assertEquals(1, store.find.hits.size)
        val before = store.find
        store.route(ChatEvent.MessageStart(itemID = "s1", role = ChatRole.AGENT))
        store.route(ChatEvent.MessageDelta(itemID = "s1", text = "a fox "))
        store.route(ChatEvent.MessageDelta(itemID = "s1", text = "and another fox"))
        scheduler.advance(1.seconds)
        assertTrue(store.items.any { it.id == "s1" })
        assertEquals("a streaming delta leaves the find untouched", before, store.find)
        store.route(ChatEvent.MessageEnd(itemID = "s1", stopReason = null))
        scheduler.advance(1.seconds)
        assertEquals("the finished message is searched", 3, store.find.hits.size)
        assertEquals("and the reader stays on the hit they were on", 0, store.find.currentIndex)
    }

    @Test fun runningToolCallIsSearchedWhenItSettles() {
        val store = makeStore(FakeContentSource(seed = transcriptJson(listOf(message("m1", "fox one")))), readOnly = false)
        store.setFindScope(ChatSearchScope.All)
        store.setFindQuery("fox")
        store.route(ChatEvent.ToolCall(ToolCallModel(id = "c1", title = "fox hunt", kind = ToolCallModel.Kind.SEARCH, status = ToolCallModel.Status.IN_PROGRESS, contentText = "")))
        store.route(ChatEvent.ToolCallUpdateEvent(ToolCallUpdate(id = "c1", status = ToolCallModel.Status.IN_PROGRESS, contentText = "found a fox")))
        assertEquals("a running call is not searched", 1, store.find.hits.size)
        store.route(ChatEvent.ToolCallUpdateEvent(ToolCallUpdate(id = "c1", status = ToolCallModel.Status.COMPLETED)))
        assertEquals("title and detail once it completes", 3, store.find.hits.size)
    }

    @Test fun storeRecomputesWhenTheTranscriptChangesAndKeepsTheCursor() {
        val source = FakeContentSource(seed = transcriptJson(listOf(message("m1", "fox one"), message("m2", "fox two"))))
        val store = makeStore(source)
        store.setFindQuery("fox")
        store.findNext()
        assertEquals("m2", store.find.current?.itemID)
        source.content = transcriptJson(listOf(message("m0", "fox zero"), message("m1", "fox one"), message("m2", "fox two")))
        assertEquals(3, store.find.hits.size)
        assertEquals("a load with the hit still present keeps the reader on it", "m2", store.find.current?.itemID)
        source.content = transcriptJson(listOf(message("m0", "fox zero"), message("m1", "fox one")))
        assertEquals(2, store.find.hits.size)
        assertEquals("the hit's message is gone: back to the first", 0, store.find.currentIndex)
        store.dismissFind()
        source.content = transcriptJson(listOf(message("m9", "fox nine")))
        assertTrue("no query: a content change finds nothing", store.find.hits.isEmpty())
    }

    @Test fun equalCountShiftedContentRecomputes() {
        val source = FakeContentSource(seed = transcriptJson(listOf(message("m1", "fox one"), message("m2", "dog"))))
        val store = makeStore(source)
        store.setFindQuery("fox")
        assertEquals(listOf("m1"), store.find.hits.map { it.itemID })
        source.content = transcriptJson(listOf(message("m0", "cat"), message("m1", "fox one")))
        assertEquals(listOf("m1"), store.find.hits.map { it.itemID })
        assertEquals(listOf(0), store.find.hitIndicesByItem["m1"])
    }

    @Test fun searchDeliveredBeforeContentAppliesOnceContentArrives() {
        val source = FakeContentSource()
        source.search = "fox"
        val store = makeStore(source)
        assertEquals("fox", store.find.query)
        assertTrue(store.find.hits.isEmpty())
        source.content = transcriptJson(items)
        assertEquals(6, store.find.hits.size)
    }

    @Test fun theSentMessageIsSearchedAtOnce() {
        val store = makeStore(FakeContentSource(seed = transcriptJson(listOf(message("m1", "fox one")))), readOnly = false)
        store.setFindQuery("fox")
        store.send("another fox")
        assertEquals(2, store.find.hits.size)
    }

    @Test fun stepOnNothingIsANoOp() {
        val store = makeStore(FakeContentSource(seed = transcriptJson(items)))
        store.setFindQuery("zebra")
        assertEquals("No matches", store.find.summary)
        store.findNext(); store.findPrevious()
        assertNull(store.find.currentIndex)
        store.setFindQuery("   ")
        assertEquals("a blank query is not a search", "", store.find.summary)
    }

    @Test fun highlightedTextMapsUTF16RangesOntoNonASCIIText() {
        val text = "h\u00e9llo w\u00f6rld"
        val painted = com.abracode.chatview.ui.highlightedText(
            text, com.abracode.chatview.ui.PlainFind(listOf(RichTextRange(6, 11), RichTextRange(900, 902)), current = 0),
        )
        val spans = painted.spanStyles.filter { it.item.background != androidx.compose.ui.graphics.Color.Unspecified }
        assertEquals(1, spans.size)
        assertEquals("w\u00f6rld", painted.text.substring(spans[0].start, spans[0].end))
    }

    @Test fun reKeyedMessageKeepsItsHits() {
        val store = makeStore(FakeContentSource(seed = transcriptJson(listOf(message("m1", "fox one")))), readOnly = false)
        store.setFindQuery("fox")
        store.route(ChatEvent.MessageReceived(ChatMessage(id = "local-1", role = ChatRole.LOCAL, text = "a fox")))
        assertEquals(listOf("m1", "local-1"), store.find.hits.map { it.itemID })
        store.findNext()
        store.route(ChatEvent.MessageIDConfirmed(localID = "local-1", serverID = "srv-9"))
        assertEquals(listOf("m1", "srv-9"), store.find.hits.map { it.itemID })
        assertEquals("srv-9", store.find.current?.itemID)
    }

    @Test fun searchChannelPresentsWithoutFocusAndDismissesOnEmpty() {
        val source = FakeContentSource(seed = transcriptJson(items))
        val store = makeStore(source)
        source.search = "fox"
        assertTrue(store.find.isPresented)
        assertEquals("fox", store.find.query)
        assertEquals(6, store.find.hits.size)
        assertEquals("a host's term does not take the reader's focus", 0, store.find.focusRequests)
        store.presentFind()
        assertEquals("the reader's own gesture does", 1, store.find.focusRequests)
        store.markFindFocusHonored()
        assertEquals(1, store.find.focusHonored)

        source.search = ""
        assertFalse(store.find.isPresented)
        assertTrue(store.find.hits.isEmpty())

        // nil is no opinion; a non-String is ignored.
        source.search = "fox"
        source.search = null
        assertTrue(store.find.isPresented)
        source.search = 42
        assertEquals("fox", store.find.query)
    }

    @Test fun searchChannelRedeliveryDoesNotReopenAClosedBar() {
        val source = FakeContentSource(seed = transcriptJson(items))
        val store = makeStore(source)
        source.search = "fox"
        store.dismissFind()
        source.content = transcriptJson(items)
        source.search = "fox"
        assertFalse(store.find.isPresented)
        assertEquals("", store.find.query)
        source.search = ""
        source.search = "fox"
        assertTrue(store.find.isPresented)
        assertEquals(6, store.find.hits.size)
    }

    @Test fun searchChannelHighlightsWithoutPresentingWhenFindIsOff() {
        val source = FakeContentSource(seed = transcriptJson(items))
        val store = makeStore(source, showFindBar = false)
        source.search = "fox"
        assertFalse(store.find.isPresented)
        assertEquals(6, store.find.hits.size)
    }

    // --- Configuration. ---

    @Test fun findConfigurationKeyDefaultsOn() {
        assertTrue(ChatConfiguration.fromJson(buildJsonObject {}, noopLogger()).showFindBar)
        assertFalse(ChatConfiguration.fromJson(buildJsonObject { put("showFindBar", false) }, noopLogger()).showFindBar)
        assertTrue("a non-Bool is ignored", ChatConfiguration.fromJson(buildJsonObject { put("showFindBar", "no") }, noopLogger()).showFindBar)
        assertTrue(ChatConfiguration().showFindBar)
    }
}
