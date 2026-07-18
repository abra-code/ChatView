package com.abracode.chatview

// Ports of the two pure text helpers from Sources/ChatView/ChatView.swift (SlashCommandMenu :891, ToolDetailText
// :1142). Their consumers (the composer slash menu, the tool-call card detail) are Compose UI landing in later
// stages, but the logic is pure and is pinned by the A5 ChatAgenticTests port, so it lives here as UI-free helpers.

/**
 * The slash-command menu's matcher: while the draft starts with "/" and the token after it has no whitespace, list
 * every command whose name has that prefix (case-insensitive). "/" alone lists everything; a trailing space closes
 * the menu (the user is typing arguments).
 */
object SlashCommandMenu {
    fun matches(draft: String, commands: List<SlashCommand>): List<SlashCommand> {
        if (commands.isEmpty() || !draft.startsWith("/")) {
            return emptyList()
        }
        val token = draft.drop(1)
        if (token.any { it.isWhitespace() }) {
            return emptyList()
        }
        val prefix = token.lowercase()
        return commands.filter { it.name.lowercase().startsWith(prefix) }
    }
}

/**
 * Caps bulk tool-detail text so a whole-file read or a long command output does not render in full (which would make
 * the transcript layout crawl). Short text passes through; over the cap, it is truncated with a note.
 */
object ToolDetailText {
    const val cap = 4000

    fun capped(text: String): String {
        if (text.length <= cap) {
            return text
        }
        // U+2026 (horizontal ellipsis), built from its code point to keep this source ASCII-only.
        val ellipsis = String(Character.toChars(0x2026))
        return text.take(cap) + "\n$ellipsis (truncated, ${text.length - cap} more characters)"
    }
}
