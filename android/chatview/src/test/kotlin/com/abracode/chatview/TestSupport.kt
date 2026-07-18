package com.abracode.chatview

// Shared A5 test infrastructure: the store's test doubles (virtual-clock scheduler, recording mock transports, a
// fake content/config source), and the test-only ChatEvent codec used by the fixture-scenario replay. The codec is
// written against Fixtures/README.md (the contract), NOT against the Swift emitter's source.
//
// Coroutine model (plan section 5): the store launches its `Task { ... }` equivalents on an injected CoroutineScope.
// - Synchronous routing / restore / config tests use inertScope(): a StandardTestDispatcher that is never advanced,
//   so the queued send tasks and the 50 ms flush never run and the test asserts the store's synchronous state.
// - Async behavior / end-to-end tests wrap the body in runTest and give the store CoroutineScope(
//   StandardTestDispatcher(testScheduler)); advanceUntilIdle() then drains the send tasks (the analog of Swift's
//   settle()). The v2 time-based logic runs on the separate hand-driven ManualChatScheduler.

import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.channels.ReceiveChannel
import kotlinx.coroutines.test.StandardTestDispatcher
import kotlinx.serialization.Serializable
import kotlinx.serialization.builtins.ListSerializer
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.booleanOrNull
import kotlinx.serialization.json.doubleOrNull
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import java.time.Instant
import kotlin.time.Duration

/** A no-op logger for tests (the Swift suites all use a silent ChatLogger). */
fun noopLogger(): ChatLogger = object : ChatLogger {
    override fun log(message: String, level: ChatLogLevel) {}
}

/**
 * A store scope whose queued coroutines never run (a never-advanced StandardTestDispatcher). Use for the synchronous
 * routing / restore / config tests: the store's synchronous state is asserted directly, and the send tasks / 50 ms
 * flush must not fire.
 */
fun inertScope(): CoroutineScope = CoroutineScope(StandardTestDispatcher())

/** The full-capability set for the command / behavior tests. */
fun allCaps(): ChatTransportCapabilities = ChatTransportCapabilities(
    paging = true, typing = true, reactions = true, editing = true, deletion = true, replies = true,
    readReceipts = true, fileTransfer = true, messageIdentity = true, reportsConnectionState = true,
)

// MARK: - Virtual clock

/** A hand-driven virtual clock (mirrors the Swift ManualChatScheduler): advance() fires every due callback. */
class ManualChatScheduler(start: Instant = Instant.ofEpochSecond(1_000_000)) : ChatScheduler {
    private data class Pending(val fireAt: Instant, val body: () -> Unit)

    private val pending = mutableMapOf<String, Pending>()
    override var now: Instant = start
        private set

    override fun schedule(key: String, after: Duration, body: () -> Unit) {
        pending[key] = Pending(now.plusMillis(after.inWholeMilliseconds), body)
    }

    override fun cancel(key: String) {
        pending.remove(key)
    }

    /** Advances virtual time, firing every due callback. */
    fun advance(by: Duration) {
        now = now.plusMillis(by.inWholeMilliseconds)
        while (true) {
            val key = pending.entries.firstOrNull { !it.value.fireAt.isAfter(now) }?.key ?: break
            val body = pending.remove(key)!!.body
            body()
        }
    }
}

// MARK: - Recording mock transport

/** Records every ChatCommand the store forwards to a transport. */
class CommandSink {
    private val commands = mutableListOf<ChatCommand>()

    fun record(command: ChatCommand) {
        synchronized(commands) { commands.add(command) }
    }

    fun all(): List<ChatCommand> = synchronized(commands) { commands.toList() }
}

/**
 * A ChatTransport whose event channel is never fed (routing tests inject events via store.route directly); it only
 * records the commands the store sends. Closed by stop() so the store's drain completes.
 */
class MockP2PTransport(
    override val capabilities: ChatTransportCapabilities,
    private val sink: CommandSink,
) : ChatTransport {
    private val channel = Channel<ChatEvent>(Channel.UNLIMITED)
    override val events: ReceiveChannel<ChatEvent> = channel

    override suspend fun start() {}
    override suspend fun send(command: ChatCommand) {
        sink.record(command)
    }
    override suspend fun stop() {
        channel.close()
    }
}

/** A no-op transport that records every primeHistory / reserveIDs call, for the config-injection restore tests. */
class FakeInjectTransport : ChatTransport {
    private val channel = Channel<ChatEvent>(Channel.UNLIMITED)
    override val events: ReceiveChannel<ChatEvent> = channel

    val primedHistories = mutableListOf<List<ChatMessage>>()
    val reservedIDs = mutableListOf<List<String>>()

    override suspend fun start() {}
    override suspend fun send(command: ChatCommand) {}
    override suspend fun stop() {
        channel.close()
    }
    override fun primeHistory(messages: List<ChatMessage>) {
        primedHistories.add(messages)
    }
    override fun reserveIDs(seen: List<String>) {
        reservedIDs.add(seen)
    }
}

/** A mutable build counter shared with a test factory, to prove how many times the transport was built. */
class BuildCounter {
    var count = 0
}

/** Captures the transport instance a factory builds, so a test can inspect it afterwards. */
class TransportBox {
    var transport: FakeInjectTransport? = null
}

// MARK: - Fake content / config source

/**
 * A fake ChatContentSource mimicking states["content"] / states["config"] via @Published: assigning `content` /
 * `config` delivers it to observers, and a new observer receives the current value immediately.
 */
class FakeContentSource(seed: Any? = null, initialConfig: Any? = null) : ChatContentSource {
    private val contentObservers = mutableMapOf<Int, (Any?) -> Unit>()
    private val configObservers = mutableMapOf<Int, (Any?) -> Unit>()
    private var nextId = 0

    var content: Any? = seed
        set(value) {
            field = value
            contentObservers.values.toList().forEach { it(value) }
        }
    var config: Any? = initialConfig
        set(value) {
            field = value
            configObservers.values.toList().forEach { it(value) }
        }

    override fun observeChatContent(handler: (Any?) -> Unit): Cancellable {
        val id = nextId++
        contentObservers[id] = handler
        handler(content)
        return Cancellable { contentObservers.remove(id) }
    }

    override fun observeChatConfig(handler: (Any?) -> Unit): Cancellable {
        val id = nextId++
        configObservers[id] = handler
        handler(config)
        return Cancellable { configObservers.remove(id) }
    }
}

// MARK: - Entry-envelope capture

/** The decoded shape of a captured .entry envelope (unknown keys - data / updated - ignored). */
@Serializable
data class CapturedEntry(val sequence: Int, val type: String, val id: String? = null)

/** Collects the JSON envelopes carried by Entry host events. */
class EntrySink {
    private val jsons = mutableListOf<String>()
    private val decoder = Json { ignoreUnknownKeys = true }

    fun add(json: String) {
        synchronized(jsons) { jsons.add(json) }
    }

    fun rawJSONs(): List<String> = synchronized(jsons) { jsons.toList() }

    fun envelopes(): List<CapturedEntry> =
        rawJSONs().mapNotNull { runCatching { decoder.decodeFromString(CapturedEntry.serializer(), it) }.getOrNull() }
}

// MARK: - Test-only ChatEvent codec (the fixture envelope contract; see Fixtures/README.md)

object FixtureEventCodec {

    fun decode(obj: JsonObject): ChatEvent {
        val name = obj.getValue("event").jsonPrimitive.content

        fun str(key: String): String = obj.getValue(key).jsonPrimitive.content
        fun optStr(key: String): String? = (obj[key] as? JsonPrimitive)?.takeIf { it.isString }?.content
        fun role(key: String): ChatRole = chatJson.decodeFromJsonElement(ChatRole.serializer(), obj.getValue(key))
        fun <T> model(key: String, serializer: kotlinx.serialization.KSerializer<T>): T =
            chatJson.decodeFromJsonElement(serializer, obj.getValue(key))

        return when (name) {
            "messageStart" -> ChatEvent.MessageStart(str("itemID"), role("role"))
            "messageDelta" -> ChatEvent.MessageDelta(str("itemID"), str("text"))
            "messageEnd" -> ChatEvent.MessageEnd(str("itemID"), optStr("stopReason"))
            "thoughtDelta" -> ChatEvent.ThoughtDelta(str("itemID"), str("text"))
            "toolCall" -> ChatEvent.ToolCall(model("toolCall", ToolCallModel.serializer()))
            "toolCallUpdate" -> {
                val u = obj.getValue("update").jsonObject
                fun uStr(key: String): String? = (u[key] as? JsonPrimitive)?.takeIf { it.isString }?.content
                ChatEvent.ToolCallUpdateEvent(
                    ToolCallUpdate(
                        id = u.getValue("id").jsonPrimitive.content,
                        title = uStr("title"),
                        kind = (u["kind"] as? JsonPrimitive)?.let { chatJson.decodeFromJsonElement(ToolCallModel.Kind.serializer(), it) },
                        status = (u["status"] as? JsonPrimitive)?.let { chatJson.decodeFromJsonElement(ToolCallModel.Status.serializer(), it) },
                        contentText = uStr("contentText"),
                        diff = u["diff"]?.let { chatJson.decodeFromJsonElement(ToolCallDiff.serializer(), it) },
                        rawInput = uStr("rawInput"),
                        rawOutput = uStr("rawOutput"),
                    ),
                )
            }
            "permissionRequest" -> {
                val r = obj.getValue("request").jsonObject
                val options = r.getValue("options").jsonArray.map {
                    val o = it.jsonObject
                    val kindWire = o.getValue("kind").jsonPrimitive.content
                    PermissionRequest.Option(
                        id = o.getValue("id").jsonPrimitive.content,
                        name = o.getValue("name").jsonPrimitive.content,
                        kind = PermissionRequest.Option.Kind.entries.first { k -> k.wire == kindWire },
                    )
                }
                ChatEvent.PermissionRequestEvent(
                    PermissionRequest(
                        id = r.getValue("id").jsonPrimitive.content,
                        toolCallID = (r["toolCallID"] as? JsonPrimitive)?.takeIf { it.isString }?.content,
                        title = r.getValue("title").jsonPrimitive.content,
                        options = options,
                    ),
                )
            }
            "plan" -> ChatEvent.Plan(model("plan", ListSerializer(PlanEntry.serializer())))
            "usage" -> ChatEvent.Usage(model("usage", UsageInfo.serializer()))
            "error" -> ChatEvent.Error(str("message"), (obj["recoverable"] as? JsonPrimitive)?.booleanOrNull ?: false)
            "system" -> ChatEvent.System(str("text"))
            "image" -> ChatEvent.Image(str("itemID"), role("role"), model("image", ChatImage.serializer()))
            "messageReceived" -> ChatEvent.MessageReceived(model("message", ChatMessage.serializer()))
            "messageIDConfirmed" -> ChatEvent.MessageIDConfirmed(str("localID"), str("serverID"))
            "messageStatusChanged" -> ChatEvent.MessageStatusChanged(
                str("itemID"),
                chatJson.decodeFromJsonElement(MessageStatus.serializer(), obj.getValue("status")),
            )
            "messageStatusWatermark" -> ChatEvent.MessageStatusWatermark(
                chatJson.decodeFromJsonElement(MessageStatus.serializer(), obj.getValue("status")),
                str("upToItemID"),
            )
            "reactionsChanged" -> ChatEvent.ReactionsChanged(str("itemID"), model("reactions", ListSerializer(Reaction.serializer())))
            "messageEdited" -> ChatEvent.MessageEdited(str("itemID"), str("newText"), str("editedAt"))
            "messageDeleted" -> ChatEvent.MessageDeleted(str("itemID"))
            "memberEvent" -> ChatEvent.MemberEventReceived(model("memberEvent", MemberEvent.serializer()))
            "callEvent" -> ChatEvent.CallEventReceived(model("callEvent", CallEvent.serializer()))
            "fileAdded" -> ChatEvent.FileAdded(model("file", ChatFile.serializer()))
            "fileProgress" -> ChatEvent.FileProgress(
                str("itemID"),
                (obj["progress"] as? JsonPrimitive)?.doubleOrNull,
                chatJson.decodeFromJsonElement(FileTransferStatus.serializer(), obj.getValue("transferStatus")),
            )
            "typingChanged" -> ChatEvent.TypingChanged(
                (obj["isTyping"] as? JsonPrimitive)?.booleanOrNull ?: false,
                optStr("senderID"),
                optStr("senderName"),
            )
            "participantsChanged" -> ChatEvent.ParticipantsChanged(model("participants", ListSerializer(Participant.serializer())))
            "historyPage" -> ChatEvent.HistoryPage(
                model("items", ListSerializer(ChatItemSerializer)),
                (obj["hasMore"] as? JsonPrimitive)?.booleanOrNull ?: false,
            )
            "connectionStateChanged" -> ChatEvent.ConnectionStateChanged(
                chatJson.decodeFromJsonElement(ChatConnectionState.serializer(), obj.getValue("state")),
            )
            else -> error("Unsupported fixture event '$name'")
        }
    }
}
