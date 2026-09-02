package com.abracode.chatview

import com.abracode.chatview.ui.callEventText
import com.abracode.chatview.ui.memberEventText
import com.abracode.richtext.model.RichTextDocument
import com.abracode.richtext.rendering.RichTextRenderedText
import com.abracode.richtext.search.RichTextPlainText
import com.abracode.richtext.search.RichTextRange
import com.abracode.richtext.search.RichTextSearch
import com.abracode.richtext.search.RichTextSearchOptions

// Port of Sources/ChatView/ChatSearch.swift - headless search over the transcript model. Pure functions from
// items + query to hits, with no store and no composable, so a host can search a saved transcript it never
// renders with the SAME rules the on-screen find bar uses - and so the hit a host finds headless is the range the
// view highlights when that conversation is opened.
//
// Markdown bodies are searched through RichText's engine over the RENDERED text (the text the message's
// composables draw: RichTextRenderedText), because that is the only form in which a range is meaningful for
// highlighting. Plain fields (a tool-call title, a caption, a file name) are searched as displayed.

/** Which parts of a transcript a search looks at. Bodies and captions by default; reasoning and tools opt-in. */
enum class ChatSearchScope {
    /** Message bodies of every role, plus system / error captions, member and call captions, and file names. */
    MESSAGES,
    /** Streamed reasoning (thought items). */
    THOUGHTS,
    /** Tool-call titles and their Markdown detail text (the expanded card's body, up to the card's cap). */
    TOOL_CALLS;

    companion object {
        val Default: Set<ChatSearchScope> = setOf(MESSAGES)
        val All: Set<ChatSearchScope> = setOf(MESSAGES, THOUGHTS, TOOL_CALLS)
    }
}

/** Which displayed text of an item a hit is in. A row maps this to the element it highlights. */
enum class ChatSearchField {
    BODY,       // a Markdown body: message, thought, or tool-call detail (RichText-rendered)
    TITLE,      // a tool-call title
    CAPTION,    // a system / error / member / call caption
    FILE_NAME,  // a file item's name
}

/** One hit: the item, the field, the UTF-16 range in that field's displayed text, and a snippet. */
data class ChatSearchHit(val itemID: String, val field: ChatSearchField, val range: RichTextRange, val snippet: String)

object ChatSearch {

    /**
     * Every hit in [items], in transcript order (within an item: title before body). Deleted messages, items
     * still streaming and running tool calls are skipped (their text is not final; the store re-searches them
     * when they settle). An empty query matches nothing. `options.limit` caps the hits PER FIELD of each item.
     */
    fun matches(
        items: List<ChatItem>,
        query: String,
        options: RichTextSearchOptions = RichTextSearchOptions.Default,
        scope: Set<ChatSearchScope> = ChatSearchScope.Default,
    ): List<ChatSearchHit> = matches(items, query, options, scope, cache = null)

    /** The same over a decoded transcript (what `ChatTranscript.decode` gives a host). */
    fun matches(
        transcript: ChatTranscript,
        query: String,
        options: RichTextSearchOptions = RichTextSearchOptions.Default,
        scope: Set<ChatSearchScope> = ChatSearchScope.Default,
    ): List<ChatSearchHit> = matches(transcript.items, query, options, scope)

    /** The store's entry point: a cache of rendered Markdown bodies keyed by item, so a keystroke re-parses nothing. */
    internal fun matches(
        items: List<ChatItem>,
        query: String,
        options: RichTextSearchOptions,
        scope: Set<ChatSearchScope>,
        cache: ChatSearchTextCache?,
    ): List<ChatSearchHit> {
        if (query.isBlank()) return emptyList()
        val hits = mutableListOf<ChatSearchHit>()
        for (item in items) {
            for ((field, text) in searchableFields(item, scope)) {
                val rendered = if (field == ChatSearchField.BODY) {
                    cache?.renderedText(item.id, text) ?: renderedText(text)
                } else {
                    text
                }
                for (match in RichTextSearch.matches(rendered, query, options)) {
                    hits.add(ChatSearchHit(item.id, field, match.range, match.snippet))
                }
            }
        }
        return hits
    }

    /** The Markdown body as the message's composables draw it: the text the row's highlight ranges refer to. */
    internal fun renderedText(markdown: String): String =
        RichTextRenderedText.layout(RichTextDocument.parse(markdown)).text

    /**
     * The (field, displayed text) pairs [scope] covers for [item], in display order; empty text skipped. The ONE
     * place that knows which item kinds show which text, shared by the per-query search and [searchableText].
     */
    internal fun searchableFields(item: ChatItem, scope: Set<ChatSearchScope>): List<Pair<ChatSearchField, String>> {
        val fields = mutableListOf<Pair<ChatSearchField, String>>()
        when (item) {
            is ChatItem.Message -> {
                val message = item.message
                if (ChatSearchScope.MESSAGES !in scope || message.deleted == true || message.isStreaming) return emptyList()
                fields.add(ChatSearchField.BODY to message.text)
            }
            is ChatItem.Thought -> {
                if (ChatSearchScope.THOUGHTS !in scope || item.thought.isStreaming) return emptyList()
                fields.add(ChatSearchField.BODY to item.thought.text)
            }
            is ChatItem.ToolCall -> {
                // A running call's detail is still streaming in: searched when it settles, like a message.
                val call = item.call
                val running = call.status == ToolCallModel.Status.PENDING || call.status == ToolCallModel.Status.IN_PROGRESS
                if (ChatSearchScope.TOOL_CALLS !in scope || running) return emptyList()
                fields.add(ChatSearchField.TITLE to call.title)
                // The card renders the detail through the same cap the search must honor.
                fields.add(ChatSearchField.BODY to ToolDetailText.capped(call.contentText))
            }
            is ChatItem.Image -> return emptyList()
            is ChatItem.System -> {
                if (ChatSearchScope.MESSAGES !in scope) return emptyList()
                fields.add(ChatSearchField.CAPTION to item.text)
            }
            is ChatItem.Error -> {
                if (ChatSearchScope.MESSAGES !in scope) return emptyList()
                fields.add(ChatSearchField.CAPTION to item.text)
            }
            // The captions are searched as COMPOSED - the sentence the row draws - so a range is a range into
            // what is on screen. A session marker draws nothing on Android yet, so it is not searched here
            // (Swift searches its headline); when the row lands, search what it draws.
            is ChatItem.MemberEventItem -> {
                if (ChatSearchScope.MESSAGES !in scope) return emptyList()
                fields.add(ChatSearchField.CAPTION to memberEventText(item.event))
            }
            is ChatItem.CallEventItem -> {
                if (ChatSearchScope.MESSAGES !in scope) return emptyList()
                fields.add(ChatSearchField.CAPTION to callEventText(item.event))
            }
            is ChatItem.File -> {
                if (ChatSearchScope.MESSAGES !in scope) return emptyList()
                fields.add(ChatSearchField.FILE_NAME to item.file.name)
            }
            is ChatItem.SessionEventItem -> return emptyList()
        }
        return fields.filter { it.second.isNotEmpty() }
    }
}

/**
 * Everything this item displays, as plain text, for a host building its own index: Markdown bodies linearized
 * the way a reader sees them (RichTextPlainText), other fields verbatim, one field per line. null when the item
 * shows nothing [scope] covers.
 */
fun ChatItem.searchableText(scope: Set<ChatSearchScope> = ChatSearchScope.Default): String? {
    val lines = ChatSearch.searchableFields(this, scope).map { (field, text) ->
        if (field == ChatSearchField.BODY) RichTextPlainText.text(RichTextDocument.parse(text)) else text
    }
    return if (lines.isEmpty()) null else lines.joinToString("\n")
}

/** The transcript's items' [searchableText], one item per paragraph, for an indexer. */
fun ChatTranscript.searchableText(scope: Set<ChatSearchScope> = ChatSearchScope.Default): String =
    items.mapNotNull { it.searchableText(scope) }.joinToString("\n\n")

/**
 * Rendered Markdown bodies by item id, invalidated when the item's source text changes. Held by the store for
 * the life of a conversation, so a keystroke costs no parsing at all.
 */
internal class ChatSearchTextCache {
    private val entries = HashMap<String, Pair<String, String>>()   // id -> (source, rendered)

    fun renderedText(itemID: String, markdown: String): String {
        entries[itemID]?.let { (source, rendered) -> if (source == markdown) return rendered }
        val rendered = ChatSearch.renderedText(markdown)
        entries[itemID] = markdown to rendered
        return rendered
    }

    fun removeAll() = entries.clear()

    /** Drop the entries of items no longer in the transcript. */
    fun retain(ids: Set<String>) {
        entries.keys.retainAll(ids)
    }

    val size: Int get() = entries.size
}
