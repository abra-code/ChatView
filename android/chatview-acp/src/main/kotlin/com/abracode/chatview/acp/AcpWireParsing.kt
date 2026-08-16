package com.abracode.chatview.acp

// Port of Sources/ACP/ACPWireParsing.swift (`enum ACPWire`).
//
// The pure ACP payload parsers: JSON-RPC params in, ChatView model types out. Stateless, unit-tested directly, and
// shared by everything in this module that reads a session/update - exactly as the Swift file is shared by the stdio
// and the remote transports there. The Swift file is normative: where the two could differ, this one follows it.
//
// The Swift original works on Foundation's `[String: Any]` from JSONSerialization; this one works on kotlinx
// JsonObject. The type tests are matched deliberately, not loosened: `as? String` accepts ONLY a JSON string (so a
// number in a string field reads as absent), and `as? [[String: Any]]` fails for the WHOLE array if any element is
// not an object (so a malformed element drops the list rather than being skipped).

import com.abracode.chatview.PlanEntry
import com.abracode.chatview.SessionConfigOption
import com.abracode.chatview.SlashCommand
import com.abracode.chatview.ToolCallDiff
import com.abracode.chatview.ToolCallModel
import com.abracode.chatview.ToolCallUpdate
import com.abracode.chatview.UsageInfo
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.doubleOrNull

/** Namespace for the stateless ACP payload parsing. Pure functions; no transport state, no I/O. */
object AcpWireParsing {

    /**
     * Joins the text out of an ACP content value - either one ContentBlock or an array of them. Non-text blocks
     * (image / audio / resource) are noted rather than lost.
     */
    fun contentText(content: JsonElement?): String {
        if (content is JsonObject) {
            return textOfBlock(content)
        }
        val blocks = content.asObjectArray() ?: return ""
        return blocks.map { textOfBlock(it) }.filter { it.isNotEmpty() }.joinToString("\n\n")
    }

    private fun textOfBlock(block: JsonObject): String = when (block.string("type")) {
        "text" -> block.string("text") ?: ""
        "resource_link" -> "[${block.string("name") ?: block.string("uri") ?: "resource"}]"
        "resource" -> "[${(block["resource"] as? JsonObject)?.string("uri") ?: "resource"}]"
        "image" -> "[image]"
        "audio" -> "[audio]"
        else -> ""
    }

    /** Maps an ACP tool_call payload onto ToolCallModel (defaults per the spec: kind "other", status "pending"). */
    fun parseToolCall(update: JsonObject): ToolCallModel {
        val content = parseToolCallContent(update["content"])
        return ToolCallModel(
            id = update.string("toolCallId") ?: "acp-tool-unidentified",
            title = update.string("title") ?: "Tool call",
            kind = kindOf(update.string("kind")) ?: ToolCallModel.Kind.OTHER,
            status = statusOf(update.string("status")) ?: ToolCallModel.Status.PENDING,
            contentText = content.first,
            diff = content.second,
            rawInput = prettyJson(update["rawInput"]),
            rawOutput = prettyJson(update["rawOutput"]),
        )
    }

    /**
     * Maps an ACP tool_call_update payload; only the fields present on the wire are non-null, so the store mutates
     * just what changed. A `content` key that is present but empty still clears nothing - it yields "" - while an
     * ABSENT content key leaves contentText null so the card keeps the text it has.
     */
    fun parseToolCallUpdate(update: JsonObject): ToolCallUpdate {
        val hasContent = update.containsKey("content")
        val content = if (hasContent) parseToolCallContent(update["content"]) else "" to null
        return ToolCallUpdate(
            id = update.string("toolCallId") ?: "acp-tool-unidentified",
            title = update.string("title"),
            kind = kindOf(update.string("kind")),
            status = statusOf(update.string("status")),
            contentText = if (hasContent) content.first else null,
            diff = content.second,
            rawInput = prettyJson(update["rawInput"]),
            rawOutput = prettyJson(update["rawOutput"]),
        )
    }

    /**
     * session/new result -> the session's selectable options. Parses OpenCode's generic `configOptions`
     * (select-typed: model, mode, ...) and falls back to the spec's `modes` sketch
     * ({ currentModeId, availableModes }).
     */
    fun parseConfigOptions(session: JsonObject): List<SessionConfigOption> {
        val raw = session["configOptions"].asObjectArray()
        if (raw != null) {
            return raw.mapNotNull { option ->
                val id = option.string("id") ?: return@mapNotNull null
                val current = option.string("currentValue") ?: return@mapNotNull null
                val type = option.string("type")
                if (type != null && type != "select") {
                    return@mapNotNull null    // only selects are displayable (and settable)
                }
                val choices = (option["options"].asObjectArray() ?: emptyList()).mapNotNull { choice ->
                    val value = choice.string("value") ?: return@mapNotNull null
                    SessionConfigOption.Choice(
                        value = value,
                        name = choice.string("name") ?: value,
                        description = choice.string("description"),
                    )
                }
                SessionConfigOption(
                    id = id,
                    name = option.string("name") ?: id,
                    category = option.string("category"),
                    currentValue = current,
                    options = choices,
                )
            }
        }
        val modes = session["modes"] as? JsonObject ?: return emptyList()
        val current = modes.string("currentModeId") ?: return emptyList()
        val choices = (modes["availableModes"].asObjectArray() ?: emptyList()).mapNotNull { mode ->
            val id = mode.string("id") ?: return@mapNotNull null
            SessionConfigOption.Choice(value = id, name = mode.string("name") ?: id, description = mode.string("description"))
        }
        return listOf(
            SessionConfigOption(id = "mode", name = "Mode", category = "mode", currentValue = current, options = choices),
        )
    }

    /**
     * `plan` update -> entries (spec shape: entries[{ content, priority, status }]). ACP plan entries carry no ids,
     * so identity is positional - and the position is the index in the RAW array, so a dropped entry does not
     * renumber the ones after it.
     */
    fun parsePlan(update: JsonObject): List<PlanEntry> {
        val raw = update["entries"].asObjectArray() ?: emptyList()
        return raw.mapIndexedNotNull { index, entry ->
            val content = entry.string("content") ?: return@mapIndexedNotNull null
            PlanEntry(
                id = index,
                content = content,
                priority = entry.string("priority"),
                status = planStatusOf(entry.string("status")) ?: PlanEntry.Status.PENDING,
            )
        }
    }

    /** `available_commands_update` -> the agent's current slash commands (availableCommands: [{ name, description }]). */
    fun parseCommands(update: JsonObject): List<SlashCommand> {
        val raw = update["availableCommands"].asObjectArray() ?: emptyList()
        return raw.mapNotNull { command ->
            val name = command.string("name")?.takeIf { it.isNotEmpty() } ?: return@mapNotNull null
            SlashCommand(name = name, description = command.string("description") ?: "")
        }
    }

    /**
     * `usage_update` -> UsageInfo (the shape OpenCode emits: used / size / cost { amount, currency }). Null without a
     * usable `used`.
     */
    fun parseUsage(update: JsonObject): UsageInfo? {
        val used = update.int("used") ?: return null
        val cost = update["cost"] as? JsonObject
        return UsageInfo(
            used = used,
            size = update.int("size"),
            costAmount = cost?.double("amount"),
            costCurrency = cost?.string("currency"),
        )
    }

    /**
     * Splits a tool call's content array into its text (regular ContentBlocks) and the FIRST diff. Terminal content
     * is noted in the text (there is no live terminal panel on either platform).
     */
    private fun parseToolCallContent(content: JsonElement?): Pair<String, ToolCallDiff?> {
        val entries = content.asObjectArray() ?: return "" to null
        val texts = mutableListOf<String>()
        var diff: ToolCallDiff? = null
        for (entry in entries) {
            when (entry.string("type")) {
                "content" -> {
                    val text = contentText(entry["content"])
                    if (text.isNotEmpty()) {
                        texts.add(text)
                    }
                }
                "diff" -> {
                    if (diff == null) {
                        val path = entry.string("path")
                        val newText = entry.string("newText")
                        if (path != null && newText != null) {
                            diff = ToolCallDiff(path = path, oldText = entry.string("oldText"), newText = newText)
                        }
                    }
                }
                "terminal" -> texts.add("[terminal output]")
                else -> Unit
            }
        }
        return texts.joinToString("\n\n") to diff
    }

    /**
     * A tool call's rawInput / rawOutput as display text: a JSON string passes through unchanged, a container is
     * pretty-printed with sorted keys.
     *
     * The layout deliberately reproduces Foundation's `JSONSerialization` with `[.prettyPrinted, .sortedKeys]`,
     * which is what the Swift transports show: two-space indent, a SPACE either side of the key colon, and forward
     * slashes escaped as `\/` (Foundation escapes them; kotlinx does not). Matching it keeps a tool card's detail
     * text identical on both platforms, including in the transcript entries a host persists.
     *
     * Numbers render as they arrived on the wire, since the parsed primitive keeps its source text.
     */
    fun prettyJson(value: JsonElement?): String? {
        if (value == null) {
            return null
        }
        if (value is JsonPrimitive && value.isString) {
            return value.content
        }
        if (value !is JsonObject && value !is JsonArray) {
            // Swift reaches `String(describing:)` here (JSONSerialization rejects a non-container at the top level),
            // which prints a JSON null as "<null>". Same text, same reason: a scalar rawInput is not a document.
            return if (value is JsonNull) "<null>" else (value as JsonPrimitive).content
        }
        return buildString { appendPretty(value, 0) }
    }

    private fun StringBuilder.appendPretty(element: JsonElement, depth: Int) {
        val pad = "  ".repeat(depth)
        val inner = "  ".repeat(depth + 1)
        when (element) {
            is JsonObject -> {
                if (element.isEmpty()) {
                    append("{\n\n").append(pad).append("}")   // Foundation leaves a blank line inside an empty container
                    return
                }
                append("{\n")
                element.entries.sortedBy { it.key }.forEachIndexed { index, (key, child) ->
                    if (index > 0) append(",\n")
                    append(inner).append(quoted(key)).append(" : ")
                    appendPretty(child, depth + 1)
                }
                append("\n").append(pad).append("}")
            }
            is JsonArray -> {
                if (element.isEmpty()) {
                    append("[\n\n").append(pad).append("]")
                    return
                }
                append("[\n")
                element.forEachIndexed { index, child ->
                    if (index > 0) append(",\n")
                    append(inner)
                    appendPretty(child, depth + 1)
                }
                append("\n").append(pad).append("]")
            }
            is JsonPrimitive -> append(if (element.isString) quoted(element.content) else element.content)
        }
    }

    /** A JSON string literal in Foundation's dialect: standard escapes plus the `\/` that Foundation always writes. */
    private fun quoted(value: String): String = buildString {
        append('"')
        for (character in value) {
            when (character) {
                '"' -> append("\\\"")
                '\\' -> append("\\\\")
                '/' -> append("\\/")
                '\n' -> append("\\n")
                '\r' -> append("\\r")
                '\t' -> append("\\t")
                '\b' -> append("\\b")
                '\u000C' -> append("\\f")
                else -> if (character < ' ') append("\\u%04x".format(character.code)) else append(character)
            }
        }
        append('"')
    }

    // MARK: - Typed accessors mirroring Swift's `as?` casts

    /** `dict[key] as? String`: a JSON string only. A number or a bool in a string field reads as absent. */
    internal fun JsonObject.string(key: String): String? = (this[key] as? JsonPrimitive)?.takeIf { it.isString }?.content

    /** `(dict[key] as? NSNumber)?.intValue`: any JSON number, truncated toward zero like NSNumber does. */
    internal fun JsonObject.int(key: String): Int? =
        (this[key] as? JsonPrimitive)?.takeIf { !it.isString }?.doubleOrNull?.toInt()

    internal fun JsonObject.double(key: String): Double? =
        (this[key] as? JsonPrimitive)?.takeIf { !it.isString }?.doubleOrNull

    /**
     * `value as? [[String: Any]]`: an array whose elements are ALL objects, or nothing. Swift's cast is all-or-
     * nothing, so one bad element drops the whole list rather than being silently skipped - matched here on purpose.
     */
    private fun JsonElement?.asObjectArray(): List<JsonObject>? {
        val array = this as? JsonArray ?: return null
        val objects = ArrayList<JsonObject>(array.size)
        for (element in array) {
            objects.add(element as? JsonObject ?: return null)
        }
        return objects
    }

    private fun kindOf(raw: String?): ToolCallModel.Kind? = when (raw) {
        "read" -> ToolCallModel.Kind.READ
        "edit" -> ToolCallModel.Kind.EDIT
        "delete" -> ToolCallModel.Kind.DELETE
        "move" -> ToolCallModel.Kind.MOVE
        "search" -> ToolCallModel.Kind.SEARCH
        "execute" -> ToolCallModel.Kind.EXECUTE
        "think" -> ToolCallModel.Kind.THINK
        "fetch" -> ToolCallModel.Kind.FETCH
        "other" -> ToolCallModel.Kind.OTHER
        else -> null
    }

    private fun statusOf(raw: String?): ToolCallModel.Status? = when (raw) {
        "pending" -> ToolCallModel.Status.PENDING
        "in_progress" -> ToolCallModel.Status.IN_PROGRESS
        "completed" -> ToolCallModel.Status.COMPLETED
        "failed" -> ToolCallModel.Status.FAILED
        else -> null
    }

    private fun planStatusOf(raw: String?): PlanEntry.Status? = when (raw) {
        "pending" -> PlanEntry.Status.PENDING
        "in_progress" -> PlanEntry.Status.IN_PROGRESS
        "completed" -> PlanEntry.Status.COMPLETED
        else -> null
    }
}
