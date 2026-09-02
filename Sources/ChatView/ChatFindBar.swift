// Sources/ChatView/ChatFindBar.swift
//
// The transcript find bar and the small highlight helpers the rows use. The bar edits the store's
// ChatFindState; the rows read that state through the store (`find.highlights(for:)` for a Markdown
// body, `ChatHighlightedText` for a plain caption or title). Matches inside Markdown are painted by
// RichText's own highlight layer, so what lights up is exactly what `ChatSearch` found: the same
// engine, over the same rendered text.
//
// This is deliberately NOT RichText's find bar. That bar owns one document's cursor; a transcript is
// many documents with one cursor walking across them, so the store keeps the cursor and each message
// only receives its own ranges.

import SwiftUI
import RichText

#if canImport(AppKit)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif

struct ChatFindBar: View {
    @ObservedObject var store: ChatStore
    @FocusState private var fieldFocused: Bool

    var body: some View {
        let find = store.find
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField("Find in conversation", text: Binding(
                get: { store.find.query },
                set: { store.setFindQuery($0, debounce: ChatFindBar.typingDebounce) }))
                .textFieldStyle(.plain)
                .focused($fieldFocused)
                .onSubmit {
                    store.findNext()
                }
                #if os(iOS)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                #endif
            Text(find.summary)
                .font(.callout.monospacedDigit())
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .fixedSize()
            Button {
                store.findPrevious()
            } label: {
                Image(systemName: "chevron.up")
            }
            .keyboardShortcut("g", modifiers: [.command, .shift])
            .disabled(find.hits.isEmpty)
            .accessibilityLabel("Previous match")
            Button {
                store.findNext()
            } label: {
                Image(systemName: "chevron.down")
            }
            .keyboardShortcut("g", modifiers: .command)
            .disabled(find.hits.isEmpty)
            .accessibilityLabel("Next match")
            Menu {
                Toggle("Match Case", isOn: optionBinding(\.caseSensitive))
                Toggle("Whole Words", isOn: optionBinding(\.wholeWord))
                Toggle("Match Diacritics", isOn: optionBinding(\.diacriticSensitive))
                Divider()
                Toggle("Include Thoughts", isOn: scopeBinding(.thoughts))
                Toggle("Include Tool Calls", isOn: scopeBinding(.toolCalls))
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuIndicator(.hidden)
            .fixedSize()
            .accessibilityLabel("Find options")
            Button {
                store.dismissFind()
            } label: {
                Image(systemName: "xmark.circle.fill")
            }
            .keyboardShortcut(.escape, modifiers: [])
            .accessibilityLabel("Close find")
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(.bar)
        // Focus when a Cmd-F asked for it and no bar has honored that request yet: a repeat Cmd-F while
        // the bar is open puts the reader back in the field, a bar presented by the host's search channel
        // leaves focus in the host's field. `initial: true` covers the request that presented this bar;
        // the Task (not onAppear) waits for the field to be in the responder chain.
        .onChange(of: store.find.focusRequests, initial: true) { _, _ in
            guard store.find.focusRequests != store.find.focusHonored else {
                return
            }
            store.markFindFocusHonored()
            Task { @MainActor in
                fieldFocused = true
            }
        }
    }

    /// How long typing pauses before the transcript is searched: long enough to skip the keystrokes
    /// inside a word, short enough to feel live.
    static let typingDebounce: TimeInterval = 0.15

    private func optionBinding(_ keyPath: WritableKeyPath<RichTextSearchOptions, Bool>) -> Binding<Bool> {
        Binding(
            get: { store.find.options[keyPath: keyPath] },
            set: { value in
                var options = store.find.options
                options[keyPath: keyPath] = value
                store.setFindOptions(options)
            })
    }

    private func scopeBinding(_ member: ChatSearchScope) -> Binding<Bool> {
        Binding(
            get: { store.find.scope.contains(member) },
            set: { value in
                var scope = store.find.scope
                if value {
                    scope.insert(member)
                } else {
                    scope.remove(member)
                }
                store.setFindScope(scope)
            })
    }
}

/// A plain-text row (a system caption, a tool title, an error line) with find ranges painted, in the
/// same colors RichText uses for Markdown bodies so the transcript lights up uniformly.
struct ChatHighlightedText: View {
    let text: String
    let ranges: [NSRange]
    let current: Int?

    init(_ text: String, ranges: [NSRange], current: Int?) {
        self.text = text
        self.ranges = ranges
        self.current = current
    }

    /// The row's text when the find has nothing in it (the common case: no attributed work at all).
    init(_ text: String, find: (ranges: [NSRange], current: Int?)?) {
        self.init(text, ranges: find?.ranges ?? [], current: find?.current)
    }

    var body: some View {
        if ranges.isEmpty {
            Text(text)
        } else {
            Text(attributed)
        }
    }

    /// Built as a SwiftUI AttributedString directly (no AppKit / UIKit bridge), so the background
    /// color lands in the scope `Text` renders. A stale range past the end of the text paints nothing.
    var attributed: AttributedString {
        var attributed = AttributedString(text)
        for (index, nsRange) in ranges.enumerated() {
            guard let range = Range(nsRange, in: attributed) else {
                continue
            }
            attributed[range].backgroundColor = Color(index == current ? chatFindStyle.currentColor : chatFindStyle.color)
        }
        return attributed
    }
}

/// The one highlight style the transcript uses. Hoisted because `RichTextHighlightStyle.default`
/// allocates two platform colors each time it is read, and a row asks for its highlights on every
/// body pass; the same colors also let SwiftUI see an unchanged row as unchanged.
@MainActor let chatFindStyle = RichTextHighlightStyle.default

/// The two frames the transcript needs to bring the current hit into view, as anchors: the row that
/// holds it (published by the row) and the match inside it (RichText's own anchor, republished by that
/// row under this key). Resolved in the transcript's overlay in the same layout pass, never stored.
struct ChatFindAnchors: Equatable {
    var row: Anchor<CGRect>?
    var match: Anchor<CGRect>?
}

/// See ChatView.alignFindHit: the item scrolls to center first, then, if the match inside a long
/// message is still off screen, the row is re-aligned so the match's position within the row lands
/// at the same position within the viewport.
struct ChatFindAnchorsKey: PreferenceKey {
    static var defaultValue: ChatFindAnchors {
        ChatFindAnchors()
    }

    static func reduce(value: inout ChatFindAnchors, nextValue: () -> ChatFindAnchors) {
        let next = nextValue()
        if let row = next.row {
            value.row = row
        }
        if let match = next.match {
            value.match = match
        }
    }
}

extension View {
    /// Publish this transcript row's frame and its RichText's current-match frame under
    /// ChatFindAnchorsKey while it holds the current hit; publish nothing otherwise (which also drops a
    /// match anchor a previous hit's RichText may still be reporting).
    func chatFindAnchors(isCurrent: Bool) -> some View {
        self
            .overlayPreferenceValue(RichTextCurrentMatchAnchorKey.self) { match in
                Color.clear
                    .preference(key: ChatFindAnchorsKey.self, value: ChatFindAnchors(row: nil, match: isCurrent ? match : nil))
                    .allowsHitTesting(false)
            }
            .transformAnchorPreference(key: ChatFindAnchorsKey.self, value: .bounds) { value, anchor in
                if isCurrent {
                    value.row = anchor
                } else {
                    value = ChatFindAnchors()
                }
            }
    }
}
