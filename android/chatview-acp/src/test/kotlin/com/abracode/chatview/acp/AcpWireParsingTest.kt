package com.abracode.chatview.acp

// Port of the ACPParsingTests suite in Tests/ACPTests/ChatACPTests.swift: the same literal payloads, the same
// expected models. These are the parity tests for AcpWireParsing - if one fails here but passes in Swift, the two
// platforms would render the same agent differently.

import com.abracode.chatview.PlanEntry
import com.abracode.chatview.ToolCallDiff
import com.abracode.chatview.ToolCallModel
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.jsonObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class AcpWireParsingTest {

    private fun obj(json: String): JsonObject = Json.parseToJsonElement(json).jsonObject

    private fun element(json: String): JsonElement = Json.parseToJsonElement(json)

    @Test
    fun contentTextJoinsAndNotesNonText() {
        assertEquals("hello", AcpWireParsing.contentText(element("""{"type":"text","text":"hello"}""")))
        val joined = AcpWireParsing.contentText(
            element(
                """[{"type":"text","text":"first"},
                    {"type":"image","data":"...","mimeType":"image/png"},
                    {"type":"text","text":"second"}]""",
            ),
        )
        assertEquals("first\n\n[image]\n\nsecond", joined)
        assertEquals("", AcpWireParsing.contentText(null))
    }

    @Test
    fun contentTextNotesResourcesAndAudio() {
        assertEquals("[main.py]", AcpWireParsing.contentText(element("""{"type":"resource_link","name":"main.py"}""")))
        assertEquals(
            "the uri stands in when the link has no name",
            "[file:///tmp/a]",
            AcpWireParsing.contentText(element("""{"type":"resource_link","uri":"file:///tmp/a"}""")),
        )
        assertEquals("[resource]", AcpWireParsing.contentText(element("""{"type":"resource_link"}""")))
        assertEquals("[file:///tmp/b]", AcpWireParsing.contentText(element("""{"type":"resource","resource":{"uri":"file:///tmp/b"}}""")))
        assertEquals("[resource]", AcpWireParsing.contentText(element("""{"type":"resource"}""")))
        assertEquals("[audio]", AcpWireParsing.contentText(element("""{"type":"audio"}""")))
        assertEquals("an unknown block type contributes nothing", "", AcpWireParsing.contentText(element("""{"type":"video"}""")))
    }

    @Test
    fun parseToolCallFullPayload() {
        val call = AcpWireParsing.parseToolCall(
            obj(
                """{
                    "toolCallId": "call-1",
                    "title": "Edit main.py",
                    "kind": "edit",
                    "status": "in_progress",
                    "content": [
                        {"type":"content","content":{"type":"text","text":"editing"}},
                        {"type":"diff","path":"main.py","oldText":"a","newText":"b"},
                        {"type":"terminal","terminalId":"term-1"}
                    ],
                    "rawInput": {"path":"main.py"}
                }""",
            ),
        )
        assertEquals("call-1", call.id)
        assertEquals(ToolCallModel.Kind.EDIT, call.kind)
        assertEquals(ToolCallModel.Status.IN_PROGRESS, call.status)
        assertEquals("editing\n\n[terminal output]", call.contentText)
        assertEquals(ToolCallDiff(path = "main.py", oldText = "a", newText = "b"), call.diff)
        assertTrue(call.rawInput?.contains("main.py") == true)
        assertNull(call.rawOutput)
    }

    @Test
    fun parseToolCallDefaults() {
        val call = AcpWireParsing.parseToolCall(obj("""{"toolCallId":"call-2"}"""))
        assertEquals("spec default", ToolCallModel.Kind.OTHER, call.kind)
        assertEquals("spec default", ToolCallModel.Status.PENDING, call.status)
        assertEquals("", call.contentText)
        assertNull(call.diff)
        assertEquals("Tool call", call.title)
    }

    @Test
    fun parseToolCallUnidentifiedIdAndUnknownEnums() {
        val call = AcpWireParsing.parseToolCall(obj("""{"kind":"telepathy","status":"vibing"}"""))
        assertEquals("acp-tool-unidentified", call.id)
        assertEquals("an unknown kind falls back to other", ToolCallModel.Kind.OTHER, call.kind)
        assertEquals("an unknown status falls back to pending", ToolCallModel.Status.PENDING, call.status)
    }

    @Test
    fun parseToolCallUpdateCarriesOnlyPresentFields() {
        val update = AcpWireParsing.parseToolCallUpdate(obj("""{"toolCallId":"call-1","status":"completed"}"""))
        assertEquals("call-1", update.id)
        assertEquals(ToolCallModel.Status.COMPLETED, update.status)
        assertNull(update.title)
        assertNull(update.kind)
        assertNull("content absent on the wire must stay nil so the card keeps its text", update.contentText)
        assertNull(update.diff)
    }

    @Test
    fun parseToolCallUpdatePresentContentIsCarried() {
        val update = AcpWireParsing.parseToolCallUpdate(
            obj("""{"toolCallId":"call-1","content":[{"type":"content","content":{"type":"text","text":"done"}}]}"""),
        )
        assertEquals("done", update.contentText)
        assertEquals("an empty content array still means 'the card now has no text'", "", AcpWireParsing.parseToolCallUpdate(obj("""{"toolCallId":"c","content":[]}""")).contentText)
    }

    // MARK: - configOptions / plan / usage

    @Test
    fun parseConfigOptionsOpenCodeShape() {
        // The shape OpenCode returns from session/new (captured live).
        val options = AcpWireParsing.parseConfigOptions(
            obj(
                """{
                    "sessionId": "s1",
                    "configOptions": [
                        {"id":"model","name":"Model","category":"model","type":"select",
                         "currentValue":"opencode/big-pickle",
                         "options":[{"value":"opencode/big-pickle","name":"Big Pickle"}]},
                        {"id":"mode","name":"Session Mode","category":"mode","type":"select",
                         "currentValue":"build",
                         "options":[{"value":"build","name":"build","description":"The default agent."},
                                    {"value":"plan","name":"plan","description":"Plan mode."}]},
                        {"id":"knob","name":"Free text","type":"text","currentValue":"x"}
                    ]
                }""",
            ),
        )
        assertEquals("non-select options are dropped", listOf("model", "mode"), options.map { it.id })
        assertEquals("Big Pickle", options[0].currentChoiceName)
        assertEquals(2, options[1].options.size)
        assertEquals("Plan mode.", options[1].options[1].description)
    }

    @Test
    fun parseConfigOptionsSpecModesFallback() {
        val options = AcpWireParsing.parseConfigOptions(
            obj(
                """{"sessionId":"s1",
                    "modes":{"currentModeId":"ask",
                             "availableModes":[{"id":"ask","name":"Ask"},{"id":"auto","name":"Auto"}]}}""",
            ),
        )
        assertEquals(1, options.size)
        assertEquals("mode", options[0].id)
        assertEquals("ask", options[0].currentValue)
        assertEquals(listOf("ask", "auto"), options[0].options.map { it.value })
    }

    @Test
    fun parseConfigOptionsEmptyWithoutEitherShape() {
        assertTrue(AcpWireParsing.parseConfigOptions(obj("""{"sessionId":"s1"}""")).isEmpty())
        assertTrue(
            "a modes block with no current mode is not an option",
            AcpWireParsing.parseConfigOptions(obj("""{"modes":{"availableModes":[{"id":"ask"}]}}""")).isEmpty(),
        )
    }

    @Test
    fun parsePlanEntries() {
        val entries = AcpWireParsing.parsePlan(
            obj(
                """{"sessionUpdate":"plan",
                    "entries":[{"content":"Read the file","priority":"high","status":"completed"},
                               {"content":"Edit the file","status":"in_progress"},
                               {"content":"Later","status":"someday"}]}""",
            ),
        )
        assertEquals(3, entries.size)
        assertEquals(PlanEntry.Status.COMPLETED, entries[0].status)
        assertEquals("high", entries[0].priority)
        assertEquals(PlanEntry.Status.IN_PROGRESS, entries[1].status)
        assertEquals("an unknown status falls back to pending", PlanEntry.Status.PENDING, entries[2].status)
        assertEquals("identity is positional", listOf(0, 1, 2), entries.map { it.id })
    }

    @Test
    fun parseCommands() {
        // The shape OpenCode emits (captured live).
        val commands = AcpWireParsing.parseCommands(
            obj(
                """{"sessionUpdate":"available_commands_update",
                    "availableCommands":[{"name":"init","description":"guided AGENTS.md setup"},
                                         {"name":"review"},
                                         {"description":"nameless is dropped"}]}""",
            ),
        )
        assertEquals(listOf("init", "review"), commands.map { it.name })
        assertEquals("guided AGENTS.md setup", commands[0].description)
        assertEquals("a missing description is empty, not a drop", "", commands[1].description)
    }

    @Test
    fun parseUsage() {
        // The shape OpenCode emits (captured live).
        val usage = AcpWireParsing.parseUsage(
            obj("""{"sessionUpdate":"usage_update","used":8170,"size":200000,"cost":{"amount":0.5,"currency":"USD"}}"""),
        )
        assertEquals(8170, usage?.used)
        assertEquals(200000, usage?.size)
        assertEquals(0.5, usage?.costAmount!!, 0.0001)
        assertEquals("USD", usage.costCurrency)
        assertNull("no usable `used` -> no event", AcpWireParsing.parseUsage(obj("""{"sessionUpdate":"usage_update"}""")))
        assertNull("a string in a number field is not a number", AcpWireParsing.parseUsage(obj("""{"used":"8170"}""")))
    }

    // MARK: - prettyJson (the tool card's detail text)

    @Test
    fun prettyJsonMatchesFoundationLayout() {
        // Foundation's [.prettyPrinted, .sortedKeys]: two-space indent, a space either side of the key colon, and
        // escaped forward slashes. Pinned so a tool card's Details block reads identically on both platforms.
        val text = AcpWireParsing.prettyJson(element("""{"b":1,"a":[1,2],"path":"/Users/x/main.py"}"""))
        assertEquals(
            """
            {
              "a" : [
                1,
                2
              ],
              "b" : 1,
              "path" : "\/Users\/x\/main.py"
            }
            """.trimIndent(),
            text,
        )
    }

    @Test
    fun prettyJsonPassesStringsThroughAndDropsAbsentValues() {
        assertEquals("already text", AcpWireParsing.prettyJson(element(""""already text"""")))
        assertNull(AcpWireParsing.prettyJson(null))
        assertEquals("Foundation prints NSNull that way", "<null>", AcpWireParsing.prettyJson(element("null")))
        assertEquals("42", AcpWireParsing.prettyJson(element("42")))
    }

    @Test
    fun prettyJsonEmptyContainers() {
        // Foundation leaves a blank line inside an empty container; verified against JSONSerialization.
        assertEquals("{\n\n}", AcpWireParsing.prettyJson(element("{}")))
        assertEquals("[\n\n]", AcpWireParsing.prettyJson(element("[]")))
        assertEquals("{\n  \"a\" : {\n\n  }\n}", AcpWireParsing.prettyJson(element("""{"a":{}}""")))
    }
}
