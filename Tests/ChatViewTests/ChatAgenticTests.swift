// Tests/ChatViewTests/ChatAgenticTests.swift
//
// Unit tests for the M3 agentic layer: the store's router reductions (tool-call
// cards mutating in place, thoughts closing when the next item begins, the
// permission queue lifecycle, hidden-surface dropping), the `surfaces` config
// parsing / validation, and the local transport's scripted "agentic" turn -
// including the permission gate's allow, reject, and cancel paths. The scripted
// turn is the same event sequence an ACP agent produces, so these tests pin the
// contract the ACP transport (next change) maps onto.

import XCTest
@testable import ChatView

private final class TestLogger: ChatLogger {
    func log(_ message: String, _ level: ChatLogLevel) {}
}

// MARK: - Router reductions

@MainActor
final class ChatRouterTests: XCTestCase {

    private func makeStore(properties: [String: Any] = [:]) -> ChatStore {
        let logger = TestLogger()
        return ChatStore(config: ChatConfiguration(dictionary: properties, logger: logger),
                         logger: logger)
    }

    private func makeToolCall(id: String = "t1", status: ToolCallModel.Status = .pending) -> ToolCallModel {
        ToolCallModel(id: id, title: "Read a file", kind: .read, status: status,
                      contentText: "", diff: nil, rawInput: nil, rawOutput: nil)
    }

    private func makePermission(id: String = "p1") -> PermissionRequest {
        PermissionRequest(id: id, toolCallID: "t1", title: "Allow?", options: [
            PermissionRequest.Option(id: "allow-once", name: "Allow once", kind: .allowOnce),
            PermissionRequest.Option(id: "reject-once", name: "Reject", kind: .rejectOnce),
        ])
    }

    func testToolCallUpdateMutatesCardInPlace() {
        let store = makeStore()
        store.route(.toolCall(makeToolCall()))
        store.route(.toolCallUpdate(ToolCallUpdate(id: "t1", status: .completed, contentText: "done")))
        XCTAssertEqual(store.items.count, 1, "an update must not append a new item")
        guard case .toolCall(let call) = store.items[0] else {
            return XCTFail("expected a tool-call item")
        }
        XCTAssertEqual(call.status, .completed)
        XCTAssertEqual(call.contentText, "done")
        XCTAssertEqual(call.title, "Read a file", "fields absent from the update must be preserved")
        XCTAssertEqual(call.kind, .read)
    }

    func testThoughtClosesWhenNextItemBegins() {
        let store = makeStore()
        store.route(.thoughtDelta(itemID: "th1", text: "let me "))
        store.route(.thoughtDelta(itemID: "th1", text: "think"))
        store.route(.messageStart(itemID: "m1", role: .agent))
        guard case .thought(let thought) = store.items[0] else {
            return XCTFail("expected a thought item first")
        }
        XCTAssertEqual(thought.text, "let me think", "buffered deltas must be applied on close")
        XCTAssertFalse(thought.isStreaming)
        XCTAssertEqual(store.items.count, 2)
    }

    func testPermissionQueueLifecycle() {
        let store = makeStore()
        store.route(.permissionRequest(makePermission()))
        XCTAssertEqual(store.pendingPermissions.map(\.id), ["p1"])
        XCTAssertTrue(store.isStreaming, "an in-flight permission means the turn is in flight")
        store.respondToPermission("p1", optionID: "allow-once")
        XCTAssertTrue(store.pendingPermissions.isEmpty, "answering must dequeue the request")
    }

    func testTurnEndAbandonsPendingPermissions() {
        let store = makeStore()
        store.route(.permissionRequest(makePermission()))
        store.route(.messageEnd(itemID: "m1", stopReason: "cancelled"))
        XCTAssertTrue(store.pendingPermissions.isEmpty, "a cancelled turn moots its permission requests")
        XCTAssertFalse(store.isStreaming)
    }

    func testAwaitingReplyShowsThenClearsAcrossATurn() {
        let store = makeStore()
        store.send("hello")
        XCTAssertTrue(store.awaitingReply, "submitting a prompt enters the awaiting-reply state")
        XCTAssertFalse(store.isStreaming, "nothing has streamed yet, so the spinner (awaitingReply && !isStreaming) shows")

        store.route(.messageStart(itemID: "m1", role: .agent))
        XCTAssertTrue(store.isStreaming, "the first streamed event takes over; the spinner hides because isStreaming is now true")

        store.route(.messageEnd(itemID: "m1", stopReason: "end_turn"))
        XCTAssertFalse(store.awaitingReply, "the finished turn clears awaitingReply so the spinner cannot reappear when isStreaming drops")
        XCTAssertFalse(store.isStreaming)
    }

    func testAwaitingReplyClearsWhenATurnErrorsBeforeStreaming() {
        let store = makeStore()
        store.send("hello")
        XCTAssertTrue(store.awaitingReply)
        store.route(.error(message: "connection failed", recoverable: true))
        XCTAssertFalse(store.awaitingReply, "an error before any content clears the awaiting state (no lingering spinner)")
    }

    func testTeardownClearsAStuckAwaitingReply() {
        // The @StateObject store outlives a view disappear/reappear. A view torn down mid-await
        // (awaitingReply true, nothing streamed yet) must not leave the flag stuck, or the
        // reappearing view shows a permanent spinner + a dead Stop button.
        let store = makeStore()
        store.send("hello")
        XCTAssertTrue(store.awaitingReply)
        store.teardown()
        XCTAssertFalse(store.awaitingReply, "teardown clears a mid-await awaitingReply so a reappearing view has no stale spinner")
        XCTAssertFalse(store.isStreaming)
    }

    func testHiddenSurfacesDropAgenticItems() {
        let store = makeStore(properties: ["surfaces": ["toolCalls": "hidden", "thoughts": "hidden"]])
        store.route(.thoughtDelta(itemID: "th1", text: "hidden"))
        store.route(.toolCall(makeToolCall()))
        store.route(.toolCallUpdate(ToolCallUpdate(id: "t1", status: .completed)))
        XCTAssertTrue(store.items.isEmpty, "hidden surfaces must drop their items entirely")
    }

    // MARK: M5 part 1 - plan / usage / session options

    func testPlanReplacesWholesale() {
        let store = makeStore()
        store.route(.plan([PlanEntry(id: 0, content: "Step 1", priority: nil, status: .inProgress),
                           PlanEntry(id: 1, content: "Step 2", priority: nil, status: .pending)]))
        store.route(.plan([PlanEntry(id: 0, content: "Step 1", priority: nil, status: .completed)]))
        XCTAssertEqual(store.plan.count, 1, "each plan event replaces the whole list, never merges")
        XCTAssertEqual(store.plan[0].status, .completed)
        XCTAssertTrue(store.items.isEmpty, "the plan is a pinned surface, not a transcript item")
    }

    func testHiddenPlanSurfaceDrops() {
        let store = makeStore(properties: ["surfaces": ["plan": "hidden"]])
        store.route(.plan([PlanEntry(id: 0, content: "Step 1", priority: nil, status: .pending)]))
        XCTAssertTrue(store.plan.isEmpty)
    }

    func testUsageLatestWins() {
        let store = makeStore()
        store.route(.usage(UsageInfo(used: 100, size: 200_000, costAmount: nil, costCurrency: nil)))
        store.route(.usage(UsageInfo(used: 250, size: 200_000, costAmount: 0.01, costCurrency: "USD")))
        XCTAssertEqual(store.usage?.used, 250)
        XCTAssertEqual(store.usage?.costAmount, 0.01)
    }

    func testConfigOptionsChangedReplacesTheDisplay() {
        let store = makeStore()
        store.route(.sessionReady(sessionID: "s1", configOptions: [
            SessionConfigOption(id: "mode", name: "Mode", category: "mode", currentValue: "build",
                                options: [.init(value: "build", name: "build", description: nil),
                                          .init(value: "plan", name: "plan", description: nil)]),
        ]))
        store.route(.configOptionsChanged([
            SessionConfigOption(id: "mode", name: "Mode", category: "mode", currentValue: "plan",
                                options: [.init(value: "build", name: "build", description: nil),
                                          .init(value: "plan", name: "plan", description: nil)]),
        ]))
        XCTAssertEqual(store.configOptions.first?.currentValue, "plan",
                       "a setter confirmation refreshes the whole option set")
    }

    func testCommandsAvailableReplacesWholesale() {
        let store = makeStore()
        store.route(.commandsAvailable([SlashCommand(name: "review", description: "Review changes"),
                                        SlashCommand(name: "test", description: "Run tests")]))
        store.route(.commandsAvailable([SlashCommand(name: "commit", description: "Draft a commit")]))
        XCTAssertEqual(store.availableCommands.map(\.name), ["commit"],
                       "each command update replaces the whole set, never merges")
        XCTAssertTrue(store.items.isEmpty, "commands feed the composer menu, not the transcript")
    }

    func testSessionReadyStoresOptionsAndModeChangeUpdatesThem() {
        let store = makeStore()
        store.route(.sessionReady(sessionID: "s1", configOptions: [
            SessionConfigOption(id: "model", name: "Model", category: "model", currentValue: "m1",
                                options: [.init(value: "m1", name: "Model One", description: nil)]),
            SessionConfigOption(id: "mode", name: "Mode", category: "mode", currentValue: "build",
                                options: [.init(value: "build", name: "build", description: nil),
                                          .init(value: "plan", name: "plan", description: nil)]),
        ]))
        XCTAssertEqual(store.configOptions.count, 2)
        store.route(.currentModeChanged(modeID: "plan"))
        XCTAssertEqual(store.configOptions.first(where: { $0.id == "mode" })?.currentValue, "plan",
                       "current_mode_update must retarget the mode option")
        XCTAssertEqual(store.configOptions.first(where: { $0.id == "model" })?.currentValue, "m1",
                       "other options must be untouched")
    }
}

// MARK: - Surfaces config

final class ChatSurfacesConfigTests: XCTestCase {

    func testSurfacesDefaults() {
        let config = ChatConfiguration(dictionary: [:], logger: TestLogger())
        XCTAssertEqual(config.surfaces.toolCalls, .inline)
        XCTAssertEqual(config.surfaces.thoughts, .collapsed)
    }

    func testSurfacesParse() {
        let config = ChatConfiguration(dictionary: [
            "surfaces": ["thoughts": "hidden"],
        ], logger: TestLogger())
        XCTAssertEqual(config.surfaces.thoughts, .hidden)
        XCTAssertEqual(config.surfaces.toolCalls, .inline, "an absent surface keeps its default")
    }

    func testDiffsDefaultsToInline() {
        let config = ChatConfiguration(dictionary: ["surfaces": ["toolCalls": "inline"]], logger: TestLogger())
        XCTAssertEqual(config.surfaces.diffs, .inline, "a surfaces block that omits diffs keeps the inline default")
    }

    func testDiffsHiddenParses() {
        let config = ChatConfiguration(dictionary: ["surfaces": ["diffs": "hidden"]], logger: TestLogger())
        XCTAssertEqual(config.surfaces.diffs, .hidden)
    }

    func testDiffsCollapsedCoercesToInline() {
        let config = ChatConfiguration(dictionary: ["surfaces": ["diffs": "collapsed"]], logger: TestLogger())
        XCTAssertEqual(config.surfaces.diffs, .inline, "the tool card's own fold covers collapsing; collapsed coerces to inline")
    }

    func testDiffsPanelCoercesToInline() {
        let config = ChatConfiguration(dictionary: ["surfaces": ["diffs": "panel"]], logger: TestLogger())
        XCTAssertEqual(config.surfaces.diffs, .inline, "a diff side panel is a later surface; panel coerces to inline")
    }

}

// MARK: - Slash-command menu matching

final class SlashCommandMenuTests: XCTestCase {

    private let commands = [
        SlashCommand(name: "review", description: "Review changes"),
        SlashCommand(name: "test", description: "Run tests"),
        SlashCommand(name: "revert", description: "Revert a change"),
    ]

    func testBareSlashListsEverything() {
        XCTAssertEqual(SlashCommandMenu.matches(draft: "/", commands: commands).count, 3)
    }

    func testPrefixFiltersCaseInsensitively() {
        XCTAssertEqual(SlashCommandMenu.matches(draft: "/RE", commands: commands).map(\.name),
                       ["review", "revert"])
    }

    func testMenuClosesOnceTheCommandTokenIsComplete() {
        XCTAssertTrue(SlashCommandMenu.matches(draft: "/review ", commands: commands).isEmpty,
                      "whitespace ends the command token; the user is typing arguments")
    }

    func testInactiveWithoutLeadingSlashOrCommands() {
        XCTAssertTrue(SlashCommandMenu.matches(draft: "review", commands: commands).isEmpty)
        XCTAssertTrue(SlashCommandMenu.matches(draft: "/re", commands: []).isEmpty)
    }
}

// MARK: - Tool detail rendering cap

final class ToolDetailTextTests: XCTestCase {

    func testShortTextPassesThrough() {
        XCTAssertEqual(ToolDetailText.capped("hello"), "hello")
    }

    func testBulkTextIsCappedWithANote() {
        let bulk = String(repeating: "x", count: ToolDetailText.cap + 500)
        let capped = ToolDetailText.capped(bulk)
        XCTAssertTrue(capped.count < bulk.count, "a whole-file read must not render in full")
        XCTAssertTrue(capped.hasPrefix(String(repeating: "x", count: 100)))
        XCTAssertTrue(capped.contains("truncated, 500 more characters"))
    }
}

// MARK: - Scripted agentic transport turn

final class ChatAgenticTransportTests: XCTestCase {

    /// Drives one scripted agentic turn to completion, answering the permission request
    /// with `answer` (an option ID, or nil to cancel the whole turn at the gate).
    /// Returns the collected evidence for assertions.
    private func runTurn(answer: String?) async -> (
        sawThought: Bool, statuses: [String: ToolCallModel.Status], finalText: String, stopReason: String?,
        lastPlan: [PlanEntry], usage: UsageInfo?
    ) {
        let transport = LocalChatTransport(config: ChatTransportConfig(settings: ["reply": "agentic", "chunkMs": 0]), logger: TestLogger())
        await transport.start()
        await transport.send(.prompt(text: "please tweak the greeting"))
        var sawThought = false
        var statuses: [String: ToolCallModel.Status] = [:]
        var finalText = ""
        var stopReason: String?
        var lastPlan: [PlanEntry] = []
        var usage: UsageInfo?
        for await event in transport.events {
            switch event {
            case .thoughtDelta:
                sawThought = true
            case .plan(let entries):
                lastPlan = entries
            case .usage(let info):
                usage = info
            case .toolCall(let call):
                statuses[call.id] = call.status
            case .toolCallUpdate(let update):
                if let status = update.status {
                    statuses[update.id] = status
                }
            case .permissionRequest(let request):
                if let answer {
                    await transport.send(.permissionResponse(requestID: request.id, optionID: answer))
                } else {
                    await transport.send(.cancel)
                }
            case .messageDelta(_, let text):
                finalText += text
            case .messageEnd(_, let reason):
                stopReason = reason
            default:
                break
            }
            if stopReason != nil {
                break
            }
        }
        await transport.stop()
        return (sawThought, statuses, finalText, stopReason, lastPlan, usage)
    }

    func testAgenticTurnAllowed() async {
        let turn = await runTurn(answer: "allow-once")
        XCTAssertTrue(turn.sawThought, "the turn must stream reasoning first")
        XCTAssertEqual(turn.stopReason, "end_turn")
        XCTAssertEqual(turn.statuses.count, 2, "expected the search and edit tool calls")
        XCTAssertTrue(turn.statuses.values.allSatisfy { $0 == .completed }, "both calls complete when allowed")
        XCTAssertTrue(turn.finalText.contains("applied the approved edit"), "the summary must reflect the approval")
        XCTAssertEqual(turn.lastPlan.count, 3, "the scripted turn lays out a three-step plan")
        XCTAssertTrue(turn.lastPlan.allSatisfy { $0.status == .completed }, "the final plan re-emit completes every step")
        XCTAssertEqual(turn.usage?.used, 2350, "the turn ends with a usage report")
    }

    func testAgenticTurnRejected() async {
        let turn = await runTurn(answer: "reject-once")
        XCTAssertEqual(turn.stopReason, "end_turn", "a rejection still ends the turn normally")
        XCTAssertEqual(turn.statuses.values.filter { $0 == .failed }.count, 1, "the gated edit must fail")
        XCTAssertEqual(turn.statuses.values.filter { $0 == .completed }.count, 1, "the ungated search still completes")
        XCTAssertTrue(turn.finalText.contains("did not apply"), "the summary must reflect the rejection")
    }

    func testAgenticAdvertisesSlashCommands() async {
        let transport = LocalChatTransport(config: ChatTransportConfig(settings: ["reply": "agentic", "chunkMs": 0]), logger: TestLogger())
        await transport.start()
        var commands: [SlashCommand] = []
        for await event in transport.events {
            if case .commandsAvailable(let advertised) = event {
                commands = advertised
                break
            }
        }
        await transport.stop()
        XCTAssertEqual(commands.map(\.name), ["review", "test", "commit"],
                       "the agentic demo advertises commands right after sessionReady")
    }

    func testSetConfigOptionRoundTrip() async {
        let transport = LocalChatTransport(config: ChatTransportConfig(settings: ["reply": "agentic", "chunkMs": 0]), logger: TestLogger())
        await transport.start()
        await transport.send(.setConfigOption(optionID: "mode", value: "bogus"))   // not a choice: no confirmation
        await transport.send(.setConfigOption(optionID: "mode", value: "plan"))    // valid: confirmed
        var confirmed: [SessionConfigOption] = []
        for await event in transport.events {
            if case .configOptionsChanged(let options) = event {
                confirmed = options
                break
            }
        }
        await transport.stop()
        XCTAssertEqual(confirmed.first(where: { $0.id == "mode" })?.currentValue, "plan",
                       "only the valid choice is confirmed; the display never sees the bogus one")
    }

    func testAgenticTurnCancelledAtTheGate() async {
        let turn = await runTurn(answer: nil)
        XCTAssertEqual(turn.stopReason, "cancelled")
        XCTAssertEqual(turn.statuses.values.filter { $0 == .failed }.count, 1, "the gated edit is abandoned")
        XCTAssertTrue(turn.finalText.isEmpty, "no summary streams after a cancel at the gate")
    }
}
