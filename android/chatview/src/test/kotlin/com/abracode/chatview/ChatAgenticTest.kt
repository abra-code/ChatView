package com.abracode.chatview

// Port of Tests/ChatViewTests/ChatAgenticTests.swift's synchronous suites: ChatRouterTests, ChatSurfacesConfigTests,
// SlashCommandMenuTests, ToolDetailTextTests. The store's router reductions (tool-call cards mutating in place,
// thoughts closing when the next item begins, the permission queue lifecycle, hidden-surface dropping), the
// `surfaces` config parsing / validation, the slash-command menu matcher, and the tool-detail text cap.
//
// ChatAgenticTransportTests (the scripted local-transport turn) is async and is ported separately.

import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put
import kotlinx.serialization.json.putJsonObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class ChatAgenticTest {

    // MARK: - Router reductions

    private fun makeStore(config: ChatConfiguration = ChatConfiguration()): ChatStore =
        ChatStore(config = config, logger = noopLogger(), scheduler = ManualChatScheduler(), scope = inertScope())

    private fun makeToolCall(id: String = "t1", status: ToolCallModel.Status = ToolCallModel.Status.PENDING): ToolCallModel =
        ToolCallModel(
            id = id, title = "Read a file", kind = ToolCallModel.Kind.READ, status = status,
            contentText = "", diff = null, rawInput = null, rawOutput = null,
        )

    private fun makePermission(id: String = "p1"): PermissionRequest =
        PermissionRequest(
            id = id, toolCallID = "t1", title = "Allow?",
            options = listOf(
                PermissionRequest.Option(id = "allow-once", name = "Allow once", kind = PermissionRequest.Option.Kind.ALLOW_ONCE),
                PermissionRequest.Option(id = "reject-once", name = "Reject", kind = PermissionRequest.Option.Kind.REJECT_ONCE),
            ),
        )

    @Test
    fun router_toolCallUpdateMutatesCardInPlace() {
        val store = makeStore()
        store.route(ChatEvent.ToolCall(makeToolCall()))
        store.route(ChatEvent.ToolCallUpdateEvent(ToolCallUpdate(id = "t1", status = ToolCallModel.Status.COMPLETED, contentText = "done")))
        assertEquals("an update must not append a new item", 1, store.items.size)
        val call = (store.items[0] as ChatItem.ToolCall).call
        assertEquals(ToolCallModel.Status.COMPLETED, call.status)
        assertEquals("done", call.contentText)
        assertEquals("fields absent from the update must be preserved", "Read a file", call.title)
        assertEquals(ToolCallModel.Kind.READ, call.kind)
    }

    @Test
    fun router_thoughtClosesWhenNextItemBegins() {
        val store = makeStore()
        store.route(ChatEvent.ThoughtDelta(itemID = "th1", text = "let me "))
        store.route(ChatEvent.ThoughtDelta(itemID = "th1", text = "think"))
        store.route(ChatEvent.MessageStart(itemID = "m1", role = ChatRole.AGENT))
        val thought = (store.items[0] as ChatItem.Thought).thought
        assertEquals("buffered deltas must be applied on close", "let me think", thought.text)
        assertFalse(thought.isStreaming)
        assertEquals(2, store.items.size)
    }

    @Test
    fun router_permissionQueueLifecycle() {
        val store = makeStore()
        store.route(ChatEvent.PermissionRequestEvent(makePermission()))
        assertEquals(listOf("p1"), store.pendingPermissions.map { it.id })
        assertTrue("an in-flight permission means the turn is in flight", store.isStreaming)
        store.respondToPermission("p1", "allow-once")
        assertTrue("answering must dequeue the request", store.pendingPermissions.isEmpty())
    }

    @Test
    fun router_turnEndAbandonsPendingPermissions() {
        val store = makeStore()
        store.route(ChatEvent.PermissionRequestEvent(makePermission()))
        store.route(ChatEvent.MessageEnd(itemID = "m1", stopReason = "cancelled"))
        assertTrue("a cancelled turn moots its permission requests", store.pendingPermissions.isEmpty())
        assertFalse(store.isStreaming)
    }

    @Test
    fun router_awaitingReplyShowsThenClearsAcrossATurn() {
        val store = makeStore()
        store.send("hello")
        assertTrue("submitting a prompt enters the awaiting-reply state", store.awaitingReply)
        assertFalse(
            "nothing has streamed yet, so the spinner (awaitingReply && !isStreaming) shows",
            store.isStreaming,
        )

        store.route(ChatEvent.MessageStart(itemID = "m1", role = ChatRole.AGENT))
        assertTrue("the first streamed event takes over; the spinner hides because isStreaming is now true", store.isStreaming)

        store.route(ChatEvent.MessageEnd(itemID = "m1", stopReason = "end_turn"))
        assertFalse(
            "the finished turn clears awaitingReply so the spinner cannot reappear when isStreaming drops",
            store.awaitingReply,
        )
        assertFalse(store.isStreaming)
    }

    @Test
    fun router_awaitingReplyClearsWhenATurnErrorsBeforeStreaming() {
        val store = makeStore()
        store.send("hello")
        assertTrue(store.awaitingReply)
        store.route(ChatEvent.Error(message = "connection failed", recoverable = true))
        assertFalse(
            "an error before any content clears the awaiting state (no lingering spinner)",
            store.awaitingReply,
        )
    }

    @Test
    fun router_teardownClearsAStuckAwaitingReply() {
        // The store outlives a view disappear/reappear. A view torn down mid-await (awaitingReply true,
        // nothing streamed yet) must not leave the flag stuck, or the reappearing view shows a permanent
        // spinner + a dead Stop button.
        val store = makeStore()
        store.send("hello")
        assertTrue(store.awaitingReply)
        store.teardown()
        assertFalse("teardown clears a mid-await awaitingReply so a reappearing view has no stale spinner", store.awaitingReply)
        assertFalse(store.isStreaming)
    }

    @Test
    fun router_hiddenSurfacesDropAgenticItems() {
        val store = makeStore(
            ChatConfiguration.fromJson(
                buildJsonObject {
                    putJsonObject("surfaces") {
                        put("toolCalls", "hidden")
                        put("thoughts", "hidden")
                    }
                },
                noopLogger(),
            ),
        )
        store.route(ChatEvent.ThoughtDelta(itemID = "th1", text = "hidden"))
        store.route(ChatEvent.ToolCall(makeToolCall()))
        store.route(ChatEvent.ToolCallUpdateEvent(ToolCallUpdate(id = "t1", status = ToolCallModel.Status.COMPLETED)))
        assertTrue("hidden surfaces must drop their items entirely", store.items.isEmpty())
    }

    // MARK: M5 part 1 - plan / usage / session options

    @Test
    fun router_planReplacesWholesale() {
        val store = makeStore()
        store.route(
            ChatEvent.Plan(
                listOf(
                    PlanEntry(id = 0, content = "Step 1", priority = null, status = PlanEntry.Status.IN_PROGRESS),
                    PlanEntry(id = 1, content = "Step 2", priority = null, status = PlanEntry.Status.PENDING),
                ),
            ),
        )
        store.route(ChatEvent.Plan(listOf(PlanEntry(id = 0, content = "Step 1", priority = null, status = PlanEntry.Status.COMPLETED))))
        assertEquals("each plan event replaces the whole list, never merges", 1, store.plan.size)
        assertEquals(PlanEntry.Status.COMPLETED, store.plan[0].status)
        assertTrue("the plan is a pinned surface, not a transcript item", store.items.isEmpty())
    }

    @Test
    fun router_hiddenPlanSurfaceDrops() {
        val store = makeStore(
            ChatConfiguration.fromJson(
                buildJsonObject { putJsonObject("surfaces") { put("plan", "hidden") } },
                noopLogger(),
            ),
        )
        store.route(ChatEvent.Plan(listOf(PlanEntry(id = 0, content = "Step 1", priority = null, status = PlanEntry.Status.PENDING))))
        assertTrue(store.plan.isEmpty())
    }

    @Test
    fun router_usageLatestWins() {
        val store = makeStore()
        store.route(ChatEvent.Usage(UsageInfo(used = 100, size = 200_000, costAmount = null, costCurrency = null)))
        store.route(ChatEvent.Usage(UsageInfo(used = 250, size = 200_000, costAmount = 0.01, costCurrency = "USD")))
        assertEquals(250, store.usage?.used)
        assertEquals(0.01, store.usage?.costAmount)
    }

    @Test
    fun router_configOptionsChangedReplacesTheDisplay() {
        val store = makeStore()
        store.route(
            ChatEvent.SessionReady(
                sessionID = "s1",
                configOptions = listOf(
                    SessionConfigOption(
                        id = "mode", name = "Mode", category = "mode", currentValue = "build",
                        options = listOf(
                            SessionConfigOption.Choice(value = "build", name = "build", description = null),
                            SessionConfigOption.Choice(value = "plan", name = "plan", description = null),
                        ),
                    ),
                ),
            ),
        )
        store.route(
            ChatEvent.ConfigOptionsChanged(
                listOf(
                    SessionConfigOption(
                        id = "mode", name = "Mode", category = "mode", currentValue = "plan",
                        options = listOf(
                            SessionConfigOption.Choice(value = "build", name = "build", description = null),
                            SessionConfigOption.Choice(value = "plan", name = "plan", description = null),
                        ),
                    ),
                ),
            ),
        )
        assertEquals(
            "a setter confirmation refreshes the whole option set",
            "plan",
            store.configOptions.firstOrNull()?.currentValue,
        )
    }

    @Test
    fun router_commandsAvailableReplacesWholesale() {
        val store = makeStore()
        store.route(
            ChatEvent.CommandsAvailable(
                listOf(
                    SlashCommand(name = "review", description = "Review changes"),
                    SlashCommand(name = "test", description = "Run tests"),
                ),
            ),
        )
        store.route(ChatEvent.CommandsAvailable(listOf(SlashCommand(name = "commit", description = "Draft a commit"))))
        assertEquals(
            "each command update replaces the whole set, never merges",
            listOf("commit"),
            store.availableCommands.map { it.name },
        )
        assertTrue("commands feed the composer menu, not the transcript", store.items.isEmpty())
    }

    @Test
    fun router_sessionReadyStoresOptionsAndModeChangeUpdatesThem() {
        val store = makeStore()
        store.route(
            ChatEvent.SessionReady(
                sessionID = "s1",
                configOptions = listOf(
                    SessionConfigOption(
                        id = "model", name = "Model", category = "model", currentValue = "m1",
                        options = listOf(SessionConfigOption.Choice(value = "m1", name = "Model One", description = null)),
                    ),
                    SessionConfigOption(
                        id = "mode", name = "Mode", category = "mode", currentValue = "build",
                        options = listOf(
                            SessionConfigOption.Choice(value = "build", name = "build", description = null),
                            SessionConfigOption.Choice(value = "plan", name = "plan", description = null),
                        ),
                    ),
                ),
            ),
        )
        assertEquals(2, store.configOptions.size)
        store.route(ChatEvent.CurrentModeChanged("plan"))
        assertEquals(
            "current_mode_update must retarget the mode option",
            "plan",
            store.configOptions.firstOrNull { it.id == "mode" }?.currentValue,
        )
        assertEquals(
            "other options must be untouched",
            "m1",
            store.configOptions.firstOrNull { it.id == "model" }?.currentValue,
        )
    }

    // MARK: - Surfaces config

    @Test
    fun surfaces_defaults() {
        val config = ChatConfiguration.fromJson(buildJsonObject {}, noopLogger())
        assertEquals(ChatConfiguration.SurfaceMode.INLINE, config.surfaces.toolCalls)
        assertEquals(ChatConfiguration.SurfaceMode.COLLAPSED, config.surfaces.thoughts)
    }

    @Test
    fun surfaces_parse() {
        val config = ChatConfiguration.fromJson(
            buildJsonObject { putJsonObject("surfaces") { put("thoughts", "hidden") } },
            noopLogger(),
        )
        assertEquals(ChatConfiguration.SurfaceMode.HIDDEN, config.surfaces.thoughts)
        assertEquals("an absent surface keeps its default", ChatConfiguration.SurfaceMode.INLINE, config.surfaces.toolCalls)
    }

    @Test
    fun surfaces_diffsDefaultsToInline() {
        val config = ChatConfiguration.fromJson(
            buildJsonObject { putJsonObject("surfaces") { put("toolCalls", "inline") } },
            noopLogger(),
        )
        assertEquals(
            "a surfaces block that omits diffs keeps the inline default",
            ChatConfiguration.SurfaceMode.INLINE,
            config.surfaces.diffs,
        )
    }

    @Test
    fun surfaces_diffsHiddenParses() {
        val config = ChatConfiguration.fromJson(
            buildJsonObject { putJsonObject("surfaces") { put("diffs", "hidden") } },
            noopLogger(),
        )
        assertEquals(ChatConfiguration.SurfaceMode.HIDDEN, config.surfaces.diffs)
    }

    @Test
    fun surfaces_diffsCollapsedCoercesToInline() {
        val config = ChatConfiguration.fromJson(
            buildJsonObject { putJsonObject("surfaces") { put("diffs", "collapsed") } },
            noopLogger(),
        )
        assertEquals(
            "the tool card's own fold covers collapsing; collapsed coerces to inline",
            ChatConfiguration.SurfaceMode.INLINE,
            config.surfaces.diffs,
        )
    }

    @Test
    fun surfaces_diffsPanelCoercesToInline() {
        val config = ChatConfiguration.fromJson(
            buildJsonObject { putJsonObject("surfaces") { put("diffs", "panel") } },
            noopLogger(),
        )
        assertEquals(
            "a diff side panel is a later surface; panel coerces to inline",
            ChatConfiguration.SurfaceMode.INLINE,
            config.surfaces.diffs,
        )
    }

    // MARK: - Slash-command menu matching

    private val commands = listOf(
        SlashCommand(name = "review", description = "Review changes"),
        SlashCommand(name = "test", description = "Run tests"),
        SlashCommand(name = "revert", description = "Revert a change"),
    )

    @Test
    fun slash_bareSlashListsEverything() {
        assertEquals(3, SlashCommandMenu.matches(draft = "/", commands = commands).size)
    }

    @Test
    fun slash_prefixFiltersCaseInsensitively() {
        assertEquals(
            listOf("review", "revert"),
            SlashCommandMenu.matches(draft = "/RE", commands = commands).map { it.name },
        )
    }

    @Test
    fun slash_menuClosesOnceTheCommandTokenIsComplete() {
        assertTrue(
            "whitespace ends the command token; the user is typing arguments",
            SlashCommandMenu.matches(draft = "/review ", commands = commands).isEmpty(),
        )
    }

    @Test
    fun slash_inactiveWithoutLeadingSlashOrCommands() {
        assertTrue(SlashCommandMenu.matches(draft = "review", commands = commands).isEmpty())
        assertTrue(SlashCommandMenu.matches(draft = "/re", commands = emptyList()).isEmpty())
    }

    // MARK: - Tool detail rendering cap

    @Test
    fun detail_shortTextPassesThrough() {
        assertEquals("hello", ToolDetailText.capped("hello"))
    }

    @Test
    fun detail_bulkTextIsCappedWithANote() {
        val bulk = "x".repeat(ToolDetailText.cap + 500)
        val capped = ToolDetailText.capped(bulk)
        assertTrue("a whole-file read must not render in full", capped.length < bulk.length)
        assertTrue(capped.startsWith("x".repeat(100)))
        assertTrue(capped.contains("truncated, 500 more characters"))
    }
}
