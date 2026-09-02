package com.abracode.chatview.ui

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.foundation.text.KeyboardActions
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Close
import androidx.compose.material.icons.filled.KeyboardArrowDown
import androidx.compose.material.icons.filled.KeyboardArrowUp
import androidx.compose.material.icons.filled.MoreVert
import androidx.compose.material.icons.filled.Search
import androidx.compose.material3.Checkbox
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.LocalContentColor
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.text.AnnotatedString
import androidx.compose.ui.text.SpanStyle
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.buildAnnotatedString
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import com.abracode.chatview.ChatFindState
import com.abracode.chatview.ChatSearchField
import com.abracode.chatview.ChatSearchScope
import com.abracode.chatview.ChatStore
import com.abracode.richtext.rendering.RichTextHighlightStyle
import com.abracode.richtext.rendering.RichTextHighlights
import com.abracode.richtext.search.RichTextRange

// Port of Sources/ChatView/ChatFindBar.swift - the transcript find bar and the small highlight helpers the rows
// use. The bar edits the store's ChatFindState; the rows read that state through the per-row RowFind the
// transcript hands them (RichText highlights for a Markdown body, ChatHighlightedText for a plain caption, title
// or file name). Matches inside Markdown are painted by RichText's own highlight layer, so what lights up is
// exactly what ChatSearch found: the same engine, over the same rendered text.
//
// On Android the bar is opened by the search button the transcript floats at its top edge (ChatView.kt), or by
// a host's `search` state through the content source - there is no Cmd-F.

/** The one highlight style the transcript uses; the same colors RichText paints, so the transcript lights uniformly. */
internal val chatFindStyle: RichTextHighlightStyle = RichTextHighlightStyle.Default

/** The find hits of ONE row, as the row's composables need them. Equal when unchanged, so an untouched row skips. */
internal data class RowFind(
    val body: RichTextHighlights? = null,
    val caption: PlainFind? = null,
    val title: PlainFind? = null,
    val fileName: PlainFind? = null,
    /** This row holds the current hit: a folded thought / tool card opens, and the row reports its position. */
    val isCurrent: Boolean = false,
) {
    companion object {
        val None = RowFind()

        fun of(find: ChatFindState, itemID: String): RowFind {
            if (find.hits.isEmpty() || find.hitIndicesByItem[itemID] == null) return None
            return RowFind(
                body = find.highlights(itemID, ChatSearchField.BODY, chatFindStyle),
                caption = find.ranges(itemID, ChatSearchField.CAPTION)?.let { PlainFind(it.first, it.second) },
                title = find.ranges(itemID, ChatSearchField.TITLE)?.let { PlainFind(it.first, it.second) },
                fileName = find.ranges(itemID, ChatSearchField.FILE_NAME)?.let { PlainFind(it.first, it.second) },
                isCurrent = find.current?.itemID == itemID,
            )
        }
    }
}

/** Find ranges in one plain-text field, and which of them is current. */
internal data class PlainFind(val ranges: List<RichTextRange>, val current: Int?)

/** [text] with [find]'s ranges painted as background spans; a stale range past the end paints nothing. */
internal fun highlightedText(text: String, find: PlainFind?): AnnotatedString {
    if (find == null || find.ranges.isEmpty()) return AnnotatedString(text)
    return buildAnnotatedString {
        append(text)
        find.ranges.forEachIndexed { index, range ->
            val start = range.start.coerceIn(0, text.length)
            val end = range.end.coerceIn(0, text.length)
            if (end <= start) return@forEachIndexed
            val color = if (index == find.current) chatFindStyle.currentColor else chatFindStyle.color
            addStyle(SpanStyle(background = color), start, end)
        }
    }
}

/** A plain-text row (a caption, a tool title, a file name) with find ranges painted. */
@Composable
internal fun ChatHighlightedText(
    text: String,
    find: PlainFind?,
    modifier: Modifier = Modifier,
    style: TextStyle = TextStyle.Default,
    color: Color = Color.Unspecified,
    fontWeight: FontWeight? = null,
    textAlign: TextAlign? = null,
    maxLines: Int = Int.MAX_VALUE,
    overflow: TextOverflow = TextOverflow.Clip,
) {
    Text(
        text = highlightedText(text, find),
        modifier = modifier,
        style = style,
        color = color,
        fontWeight = fontWeight,
        textAlign = textAlign,
        maxLines = maxLines,
        overflow = overflow,
    )
}

/** The transcript find bar: field, "n of m", previous / next, an options menu with the scope toggles, close. */
@Composable
internal fun ChatFindBar(store: ChatStore, modifier: Modifier = Modifier) {
    val find = store.find
    val focusRequester = remember { FocusRequester() }
    var menuOpen by remember { mutableStateOf(false) }
    // Focus when the reader's own gesture asked for it and no bar has honored that request yet; a bar presented by
    // the host's search channel leaves focus where the reader is typing.
    LaunchedEffect(find.focusRequests) {
        if (find.focusRequests != find.focusHonored) {
            store.markFindFocusHonored()
            focusRequester.requestFocus()
        }
    }
    Surface(color = MaterialTheme.colorScheme.surfaceContainer, modifier = modifier.fillMaxWidth().testTag("chat.findBar")) {
        Row(
            modifier = Modifier.fillMaxWidth().padding(horizontal = 10.dp, vertical = 4.dp),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(4.dp),
        ) {
            Icon(Icons.Filled.Search, contentDescription = null, tint = MaterialTheme.colorScheme.onSurfaceVariant)
            val textStyle = MaterialTheme.typography.bodyLarge.copy(color = LocalContentColor.current)
            BasicTextField(
                value = find.query,
                onValueChange = { store.setFindQuery(it, debounce = ChatStore.findTypingDebounce) },
                singleLine = true,
                textStyle = textStyle,
                cursorBrush = SolidColor(MaterialTheme.colorScheme.primary),
                keyboardOptions = KeyboardOptions(imeAction = ImeAction.Search),
                keyboardActions = KeyboardActions(onSearch = { store.findNext() }),
                modifier = Modifier.weight(1f).focusRequester(focusRequester).testTag("chat.findField"),
                decorationBox = { inner ->
                    if (find.query.isEmpty()) {
                        Text("Find in conversation", style = textStyle, color = MaterialTheme.colorScheme.onSurfaceVariant)
                    }
                    inner()
                },
            )
            Text(
                find.summary,
                style = MaterialTheme.typography.bodyMedium,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
                maxLines = 1,
                modifier = Modifier.testTag("chat.findSummary"),
            )
            IconButton(onClick = { store.findPrevious() }, enabled = find.hits.isNotEmpty()) {
                Icon(Icons.Filled.KeyboardArrowUp, contentDescription = "Previous match")
            }
            IconButton(onClick = { store.findNext() }, enabled = find.hits.isNotEmpty()) {
                Icon(Icons.Filled.KeyboardArrowDown, contentDescription = "Next match")
            }
            IconButton(onClick = { menuOpen = true }) {
                Icon(Icons.Filled.MoreVert, contentDescription = "Find options")
                DropdownMenu(expanded = menuOpen, onDismissRequest = { menuOpen = false }) {
                    FindOption("Match case", find.options.caseSensitive) {
                        store.setFindOptions(find.options.copy(caseSensitive = it))
                    }
                    FindOption("Whole words", find.options.wholeWord) {
                        store.setFindOptions(find.options.copy(wholeWord = it))
                    }
                    FindOption("Match diacritics", find.options.diacriticSensitive) {
                        store.setFindOptions(find.options.copy(diacriticSensitive = it))
                    }
                    FindOption("Regular expression", find.options.regularExpression) {
                        store.setFindOptions(find.options.copy(regularExpression = it))
                    }
                    FindOption("Include thoughts", ChatSearchScope.THOUGHTS in find.scope) {
                        store.setFindScope(if (it) find.scope + ChatSearchScope.THOUGHTS else find.scope - ChatSearchScope.THOUGHTS)
                    }
                    FindOption("Include tool calls", ChatSearchScope.TOOL_CALLS in find.scope) {
                        store.setFindScope(if (it) find.scope + ChatSearchScope.TOOL_CALLS else find.scope - ChatSearchScope.TOOL_CALLS)
                    }
                }
            }
            IconButton(onClick = { store.dismissFind() }) {
                Icon(Icons.Filled.Close, contentDescription = "Close find")
            }
        }
    }
}

@Composable
private fun FindOption(label: String, checked: Boolean, onChange: (Boolean) -> Unit) {
    DropdownMenuItem(
        text = { Text(label) },
        leadingIcon = { Checkbox(checked = checked, onCheckedChange = null) },
        onClick = { onChange(!checked) },
    )
}
