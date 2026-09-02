// Sources/ChatView/ChatSearch.swift
//
// Headless search over the transcript model. Pure functions from items + query to hits, with no store
// and no view, so a host can search a saved transcript it never renders (a chat list looking for the
// conversations that mention something) with the SAME rules the on-screen find bar uses - and so the
// hit a host finds headless is the range the view highlights when that conversation is opened.
//
// Markdown bodies are searched through RichText's engine over the RENDERED text (the string the
// message's text view draws), because that is the only form in which a range is meaningful for
// highlighting: the raw Markdown of "un**believ**able" does not contain "unbelievable", the rendered
// text does. Plain fields (a tool-call title, a system caption, a file name) are searched as they are
// displayed. `ChatItem.searchableText(scope:)` is the indexer-facing form: everything the item shows,
// as plain text, for a host that wants to build its own index rather than call this per query.

import Foundation
import RichText

/// Which parts of a transcript a search looks at. Message bodies and the transcript's captions are the
/// default: what a reader would call "the conversation". Reasoning and tool activity are opt-in, being
/// long, repetitive, and usually folded away.
public struct ChatSearchScope: OptionSet, Sendable, Hashable, Codable {
    public let rawValue: Int

    public init(rawValue: Int) {
        self.rawValue = rawValue
    }

    /// Message bodies of every role, plus system / error captions, session markers, member and call
    /// captions, and file names.
    public static let messages = ChatSearchScope(rawValue: 1 << 0)
    /// Streamed reasoning (thought items).
    public static let thoughts = ChatSearchScope(rawValue: 1 << 1)
    /// Tool-call titles and their Markdown detail text (the expanded card's body). The card's raw
    /// input / output code blocks and a diff are not searched.
    public static let toolCalls = ChatSearchScope(rawValue: 1 << 2)

    public static let `default`: ChatSearchScope = [.messages]
    public static let all: ChatSearchScope = [.messages, .thoughts, .toolCalls]
}

/// Which displayed text of an item a hit is in. A view maps this to the element it highlights.
public enum ChatSearchField: String, Sendable, Codable {
    case body       // a Markdown body: message, thought, or tool-call detail (RichText-rendered)
    case title      // a tool-call title
    case caption    // a system / error / session / member / call caption
    case fileName   // a file item's name
}

/// One hit: the item, the field, the UTF-16 range in that field's displayed text, and a snippet.
public struct ChatSearchHit: Equatable, Hashable, Sendable {
    public let itemID: String
    public let field: ChatSearchField
    public let range: NSRange
    public let snippet: String

    public init(itemID: String, field: ChatSearchField, range: NSRange, snippet: String) {
        self.itemID = itemID
        self.field = field
        self.range = range
        self.snippet = snippet
    }
}

public enum ChatSearch {

    /// Every hit in `items`, in transcript order (and within an item: title before body). Deleted
    /// messages (tombstones show no text) and items still streaming (their text is not final; the
    /// store re-searches them when they end) are skipped. An empty query matches nothing.
    /// `options.limit` caps the hits PER FIELD of each item, not per transcript.
    public static func matches(in items: [ChatItem], query: String,
                               options: RichTextSearchOptions = .default,
                               scope: ChatSearchScope = .default) -> [ChatSearchHit] {
        matches(in: items, query: query, options: options, scope: scope, cache: nil)
    }

    /// The same over a decoded transcript (what `ChatTranscript.decode(from:)` gives a host).
    public static func matches(in transcript: ChatTranscript, query: String,
                               options: RichTextSearchOptions = .default,
                               scope: ChatSearchScope = .default) -> [ChatSearchHit] {
        matches(in: transcript.items, query: query, options: options, scope: scope)
    }

    /// The store's entry point: a cache of rendered Markdown bodies keyed by item, so re-searching a
    /// long transcript on every keystroke does not re-parse every message.
    static func matches(in items: [ChatItem], query: String, options: RichTextSearchOptions,
                        scope: ChatSearchScope, cache: ChatSearchTextCache?) -> [ChatSearchHit] {
        guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return []
        }
        var hits: [ChatSearchHit] = []
        for item in items {
            for (field, text) in searchableFields(of: item, scope: scope) {
                let rendered: String
                if field == .body {
                    rendered = cache?.renderedText(for: item.id, markdown: text) ?? Self.renderedText(markdown: text)
                } else {
                    rendered = text
                }
                for match in RichTextSearch.matches(in: rendered, query: query, options: options) {
                    hits.append(ChatSearchHit(itemID: item.id, field: field, range: match.range, snippet: match.snippet))
                }
            }
        }
        return hits
    }

    /// The Markdown body as the message's text view renders it. The view draws with RichText's default
    /// theme and engine, and the two engines render identical text (they differ only in table drawing),
    /// so this is the string the view's highlight ranges refer to.
    static func renderedText(markdown: String) -> String {
        RichTextAttributedString.make(RichTextDocument(markdown: markdown), theme: .default, engine: .textKit1).string
    }

    /// The (field, displayed text) pairs `scope` covers for `item`, in display order. Empty text is
    /// skipped. This is the ONE place that knows which item kinds show which text, shared by the
    /// per-query search and the indexer-facing `searchableText`.
    static func searchableFields(of item: ChatItem, scope: ChatSearchScope) -> [(ChatSearchField, String)] {
        var fields: [(ChatSearchField, String)] = []
        switch item {
        case .message(let message):
            guard scope.contains(.messages), message.deleted != true, !message.isStreaming else {
                return []
            }
            fields.append((.body, message.text))
        case .thought(let thought):
            guard scope.contains(.thoughts), !thought.isStreaming else {
                return []
            }
            fields.append((.body, thought.text))
        case .toolCall(let call):
            // A running call's detail is still streaming in: like a streaming message it is searched
            // when it settles, so a delta never re-runs the whole search.
            guard scope.contains(.toolCalls), call.status != .pending, call.status != .inProgress else {
                return []
            }
            fields.append((.title, call.title))
            // The card renders the detail through the same cap the search must honor: text past the
            // cap is not on screen, so a hit there could not be highlighted.
            fields.append((.body, ToolDetailText.capped(call.contentText)))
        case .image(let item):
            // A photo's caption is a body like a message's; a photo without one shows no text.
            guard scope.contains(.messages), let caption = item.caption else {
                return []
            }
            fields.append((.body, caption))
        case .system(_, let text), .error(_, let text):
            guard scope.contains(.messages) else {
                return []
            }
            fields.append((.caption, text))
        // The captions below are searched as COMPOSED - the sentence the row draws ("Resumed with
        // gemma", "Alice invited Bob"), built by the same helpers the rows use - so a range is a
        // range into what is on screen.
        case .sessionEvent(let event):
            guard scope.contains(.messages) else {
                return []
            }
            fields.append((.caption, SessionEventText.displayedLines(event).headline))
        case .memberEvent(let event):
            guard scope.contains(.messages) else {
                return []
            }
            fields.append((.caption, MemberEventText.caption(event)))
        case .callEvent(let event):
            guard scope.contains(.messages) else {
                return []
            }
            fields.append((.caption, CallEventText.caption(event)))
        case .file(let file):
            guard scope.contains(.messages) else {
                return []
            }
            fields.append((.fileName, file.name))
            if let caption = file.caption {
                fields.append((.body, caption))
            }
        }
        return fields.filter { !$0.1.isEmpty }
    }
}

public extension ChatItem {
    /// Everything this item displays, as plain text, for a host building its own index: Markdown bodies
    /// linearized the way a reader sees them (RichTextPlainText - alt text for images, table rows as
    /// comma-separated cells, no syntax), other fields verbatim, one field per line. nil when the item
    /// shows nothing `scope` covers (a photo without a caption, a deleted message, an out-of-scope thought).
    func searchableText(scope: ChatSearchScope = .default) -> String? {
        let lines = ChatSearch.searchableFields(of: self, scope: scope).map { field, text -> String in
            field == .body ? RichTextPlainText.text(for: RichTextDocument(markdown: text)) : text
        }
        return lines.isEmpty ? nil : lines.joined(separator: "\n")
    }
}

public extension ChatTranscript {
    /// The transcript's items' `searchableText`, one item per paragraph, for an indexer.
    func searchableText(scope: ChatSearchScope = .default) -> String {
        items.compactMap { $0.searchableText(scope: scope) }.joined(separator: "\n\n")
    }
}

/// Rendered Markdown bodies by item id, invalidated when the item's source text changes. Held by the
/// store for the life of a conversation; a rendered body is a few hundred bytes, so a long transcript
/// costs little and a keystroke costs no parsing at all.
final class ChatSearchTextCache {
    private var entries: [String: (source: String, rendered: String)] = [:]

    func renderedText(for itemID: String, markdown: String) -> String {
        if let entry = entries[itemID], entry.source == markdown {
            return entry.rendered
        }
        let rendered = ChatSearch.renderedText(markdown: markdown)
        entries[itemID] = (markdown, rendered)
        return rendered
    }

    /// Drop everything (a conversation replaced wholesale).
    func removeAll() {
        entries.removeAll()
    }

    /// Drop the entries of items no longer in the transcript (one removed on its own).
    func retain(ids: Set<String>) {
        entries = entries.filter { ids.contains($0.key) }
    }

    var count: Int {
        entries.count
    }
}
