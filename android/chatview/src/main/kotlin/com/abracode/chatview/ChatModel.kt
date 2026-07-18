package com.abracode.chatview

// Port of Sources/ChatView/ChatModel.swift.
//
// Transport-agnostic value types shared across the Chat component:
//   - the render model:        ChatRole, ChatMessage, ChatItem
//   - the normalized inbound:  ChatEvent  (what a transport emits)
//   - the normalized outbound: ChatCommand (what the UI sends a transport)
//
// The ChatEvent / ChatCommand vocabularies are a SUPERSET shaped by the richest transport (ACP); a simpler
// transport emits only a subset. See the Swift source for the milestone history.
//
// Serialization mirrors the Swift Codable exactly (JSON contract is frozen, P0-2): kotlinx.serialization with
// explicitNulls=false / ignoreUnknownKeys=true / encodeDefaults=false, plus hand-written serializers wherever
// Swift hand-writes (ChatItem discriminator, ChatImage pixel flatten, ChatFile decode defaults, ChatTranscript
// tolerant decode + plan-only-when-nonempty). A v1 value serializes byte-identically to before; a v1 document
// still decodes with every v2 field absent.

import kotlinx.serialization.EncodeDefault
import kotlinx.serialization.ExperimentalSerializationApi
import kotlinx.serialization.KSerializer
import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable
import kotlinx.serialization.SerializationException
import kotlinx.serialization.Transient
import kotlinx.serialization.builtins.ListSerializer
import kotlinx.serialization.descriptors.SerialDescriptor
import kotlinx.serialization.descriptors.buildClassSerialDescriptor
import kotlinx.serialization.encoding.Decoder
import kotlinx.serialization.encoding.Encoder
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonDecoder
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonEncoder
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.decodeFromJsonElement
import kotlinx.serialization.json.encodeToJsonElement
import kotlinx.serialization.json.intOrNull
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.put

/**
 * The module's shared JSON codec. Mirrors the Swift JSONEncoder / JSONDecoder contract: unknown keys tolerated on
 * decode, nulls omitted on encode (explicitNulls), defaults not written (encodeDefaults) - a v1 value stays
 * byte-identical. Fields that Swift always writes (ChatImage.alt, ChatFile.kind / transferStatus) force it back
 * on with @EncodeDefault(ALWAYS).
 */
internal val chatJson: Json = Json {
    explicitNulls = false
    ignoreUnknownKeys = true
    encodeDefaults = false
}

/**
 * The party a transcript item belongs to. A transport maps its own participants onto these keys; the JSON `roles`
 * map then resolves each key to a side / label / tint.
 */
@Serializable
enum class ChatRole {
    @SerialName("local") LOCAL,
    @SerialName("agent") AGENT,
    @SerialName("remote") REMOTE,
    @SerialName("system") SYSTEM,
}

/**
 * Delivery state of an own (outgoing) message. The four ladder states advance monotonically
 * (`sending` -> `sent` -> `delivered` -> `read`); `failed` is OUTSIDE the ladder and is never overwritten by a
 * status watermark.
 */
@Serializable
enum class MessageStatus {
    @SerialName("sending") SENDING,
    @SerialName("sent") SENT,
    @SerialName("delivered") DELIVERED,
    @SerialName("read") READ,
    @SerialName("failed") FAILED;

    /** Position in the delivery ladder; `null` for `failed`, which sits outside it. */
    val watermarkRank: Int?
        get() = when (this) {
            SENDING -> 0
            SENT -> 1
            DELIVERED -> 2
            READ -> 3
            FAILED -> null
        }
}

/** One aggregated emoji reaction on a message. A transport replaces the whole reaction set per message. */
@Serializable
data class Reaction(
    val emoji: String,
    val count: Int,
    val mine: Boolean,
)

/** A reference to the message being replied to, carried on the replying message. `excerpt` is producer-truncated. */
@Serializable
data class ReplyRef(
    val itemID: String,
    val excerpt: String,
    val senderName: String? = null,
)

/** The source's natural pixel size (Swift CGSize), flattened to pixelWidth / pixelHeight in JSON by ChatImage. */
data class PixelSize(
    val width: Double,
    val height: Double,
)

/**
 * A single conversation message. `text` accumulates streaming deltas; `isStreaming` is true while the turn that
 * owns it is still in flight. The transient `isStreaming` flag is NOT serialized: a loaded message is always final
 * (decodes with isStreaming == false). The senderID / senderName / avatarURL / timestamp / status / reactions /
 * editedAt / replyTo / deleted fields are the ADDITIVE P2P (v2) layer: all optional, all omitted-when-null, so a
 * v1 message serializes byte-identically.
 */
@Serializable
data class ChatMessage(
    val id: String,
    val role: ChatRole,
    val text: String,
    @Transient val isStreaming: Boolean = false,
    // P2P (v2) additive fields; all optional, null for v1 messages.
    val senderID: String? = null,
    val senderName: String? = null,
    val avatarURL: String? = null,
    val timestamp: String? = null,
    val status: MessageStatus? = null,
    val reactions: List<Reaction>? = null,
    val editedAt: String? = null,
    val replyTo: ReplyRef? = null,
    val deleted: Boolean? = null,
) {
    val itemId: String get() = id
}

/**
 * A standalone image transcript element. Serializes by source reference (the URL), never pixel data; `pixelSize`
 * is flattened to explicit width / height so the JSON shape is stable and self-documenting.
 */
@OptIn(ExperimentalSerializationApi::class)
@Serializable(with = ChatImageSerializer::class)
data class ChatImage(
    val url: String,
    val alt: String = "",
    val pixelSize: PixelSize? = null,
)

@OptIn(ExperimentalSerializationApi::class)
@Serializable
private class ChatImageSurrogate(
    val url: String,
    @EncodeDefault(EncodeDefault.Mode.ALWAYS) val alt: String = "",
    val pixelWidth: Double? = null,
    val pixelHeight: Double? = null,
)

internal object ChatImageSerializer : KSerializer<ChatImage> {
    override val descriptor: SerialDescriptor = ChatImageSurrogate.serializer().descriptor

    override fun serialize(encoder: Encoder, value: ChatImage) {
        encoder.encodeSerializableValue(
            ChatImageSurrogate.serializer(),
            ChatImageSurrogate(value.url, value.alt, value.pixelSize?.width, value.pixelSize?.height),
        )
    }

    override fun deserialize(decoder: Decoder): ChatImage {
        val s = decoder.decodeSerializableValue(ChatImageSurrogate.serializer())
        val size = if (s.pixelWidth != null && s.pixelHeight != null) PixelSize(s.pixelWidth, s.pixelHeight) else null
        return ChatImage(url = s.url, alt = s.alt, pixelSize = size)
    }
}

/** A tool invocation surfaced by an agentic transport, rendered as a card. Kind / status vocabularies are ACP's. */
@Serializable
data class ToolCallModel(
    val id: String,
    val title: String,
    val kind: Kind,
    val status: Status,
    val contentText: String,
    val diff: ToolCallDiff? = null,
    val rawInput: String? = null,
    val rawOutput: String? = null,
) {
    @Serializable
    enum class Kind {
        @SerialName("read") READ,
        @SerialName("edit") EDIT,
        @SerialName("delete") DELETE,
        @SerialName("move") MOVE,
        @SerialName("search") SEARCH,
        @SerialName("execute") EXECUTE,
        @SerialName("think") THINK,
        @SerialName("fetch") FETCH,
        @SerialName("other") OTHER,
    }

    @Serializable
    enum class Status {
        @SerialName("pending") PENDING,
        @SerialName("in_progress") IN_PROGRESS,
        @SerialName("completed") COMPLETED,
        @SerialName("failed") FAILED,
    }
}

/** A proposed or applied file change carried inside a tool call's content (ACP's `diff` ToolCallContent). */
@Serializable
data class ToolCallDiff(
    val path: String,
    val oldText: String? = null,
    val newText: String,
)

/** A partial mutation of an existing tool call (ACP's `tool_call_update`): only non-null fields change. */
data class ToolCallUpdate(
    val id: String,
    val title: String? = null,
    val kind: ToolCallModel.Kind? = null,
    val status: ToolCallModel.Status? = null,
    val contentText: String? = null,
    val diff: ToolCallDiff? = null,
    val rawInput: String? = null,
    val rawOutput: String? = null,
)

/** An agent's request to run a gated tool call (ACP's `session/request_permission`). */
data class PermissionRequest(
    val id: String,
    val toolCallID: String?,
    val title: String,
    val options: List<Option>,
) {
    data class Option(
        val id: String,
        val name: String,
        val kind: Kind,
    ) {
        enum class Kind(val wire: String) {
            ALLOW_ONCE("allow_once"),
            ALLOW_ALWAYS("allow_always"),
            REJECT_ONCE("reject_once"),
            REJECT_ALWAYS("reject_always");

            val allows: Boolean get() = this == ALLOW_ONCE || this == ALLOW_ALWAYS
        }
    }
}

/** One step of the agent's evolving task plan (ACP `plan`). The agent re-emits the WHOLE plan, so the store replaces. */
@Serializable
data class PlanEntry(
    val id: Int,
    val content: String,
    val priority: String? = null,
    val status: Status,
) {
    @Serializable
    enum class Status {
        @SerialName("pending") PENDING,
        @SerialName("in_progress") IN_PROGRESS,
        @SerialName("completed") COMPLETED,
    }
}

/** Token / cost usage for the session (OpenCode's `usage_update`). */
@Serializable
data class UsageInfo(
    val used: Int,
    val size: Int? = null,
    val costAmount: Double? = null,
    val costCurrency: String? = null,
)

/** One selectable session option advertised by the agent at session start. Displayed read-only in the status line. */
data class SessionConfigOption(
    val id: String,
    val name: String,
    val category: String?,
    val currentValue: String,
    val options: List<Choice>,
) {
    data class Choice(
        val value: String,
        val name: String,
        val description: String?,
    )

    val currentChoiceName: String?
        get() = options.firstOrNull { it.value == currentValue }?.name
}

/** A slash command the agent currently offers (ACP `available_commands_update`). Sent as ordinary prompt text. */
data class SlashCommand(
    val name: String,
    val description: String,
) {
    val id: String get() = name
}

/** A membership / roster change in a group conversation, rendered as a centered caption. */
@Serializable
data class MemberEvent(
    val id: String,
    val timestamp: String? = null,
    val kind: Kind,
    val actorName: String? = null,
    val subjectName: String? = null,
    val detail: String? = null,
) {
    @Serializable
    enum class Kind {
        @SerialName("joined") JOINED,
        @SerialName("left") LEFT,
        @SerialName("invited") INVITED,
        @SerialName("removed") REMOVED,
        @SerialName("roleChanged") ROLE_CHANGED,
        @SerialName("renamed") RENAMED,
    }
}

/** A call log entry, rendered as a centered caption with a phone / video glyph. */
@Serializable
data class CallEvent(
    val id: String,
    val timestamp: String? = null,
    val kind: Kind,
    val durationSeconds: Int? = null,
    val isVideo: Boolean? = null,
) {
    @Serializable
    enum class Kind {
        @SerialName("missedIncoming") MISSED_INCOMING,
        @SerialName("missedOutgoing") MISSED_OUTGOING,
        @SerialName("completed") COMPLETED,
        @SerialName("declined") DECLINED,
    }
}

/** The byte-transfer state of a file / voice message, independent of the message delivery `status`. */
@Serializable
enum class FileTransferStatus {
    @SerialName("pending") PENDING,
    @SerialName("transferring") TRANSFERRING,
    @SerialName("completed") COMPLETED,
    @SerialName("failed") FAILED,
    @SerialName("cancelled") CANCELLED,
}

/**
 * A file attachment or voice message in the transcript. One case covers both: `kind` selects the rendering.
 * `kind` and `transferStatus` default (file / completed) on decode and are always written on encode, matching Swift.
 */
@OptIn(ExperimentalSerializationApi::class)
@Serializable
data class ChatFile(
    val id: String,
    val role: ChatRole,
    val senderID: String? = null,
    val senderName: String? = null,
    val timestamp: String? = null,
    val status: MessageStatus? = null,
    val name: String,
    val sizeBytes: Int? = null,
    val url: String? = null,
    @EncodeDefault(EncodeDefault.Mode.ALWAYS) val kind: Kind = Kind.FILE,
    val durationSeconds: Int? = null,
    @EncodeDefault(EncodeDefault.Mode.ALWAYS) val transferStatus: FileTransferStatus = FileTransferStatus.COMPLETED,
    val progress: Double? = null,
) {
    @Serializable
    enum class Kind {
        @SerialName("file") FILE,
        @SerialName("voice") VOICE,
    }
}

/** A conversation participant (the group roster). `isSelf` marks the local user (used to derive dual alignment). */
@Serializable
data class Participant(
    val id: String,
    val name: String,
    val avatarURL: String? = null,
    val isSelf: Boolean? = null,
)

/**
 * A heterogeneous, arrival-ordered transcript entry. Codable uses a stable `type` discriminator so the on-disk
 * format does not drift. The payload wrapper keys mirror the Swift CodingKeys exactly (`message` for both message
 * and thought, `toolCall`, `image`, `memberEvent`, `callEvent`, `file`; id / role / text inline for image / system
 * / error).
 */
@Serializable(with = ChatItemSerializer::class)
sealed class ChatItem {
    abstract val id: String

    data class Message(val message: ChatMessage) : ChatItem() {
        override val id: String get() = message.id
    }

    data class Thought(val thought: ChatMessage) : ChatItem() {
        override val id: String get() = thought.id
    }

    data class ToolCall(val call: ToolCallModel) : ChatItem() {
        override val id: String get() = call.id
    }

    data class Image(override val id: String, val role: ChatRole, val image: ChatImage) : ChatItem()

    data class System(override val id: String, val text: String) : ChatItem()

    data class Error(override val id: String, val text: String) : ChatItem()

    data class MemberEventItem(val event: MemberEvent) : ChatItem() {
        override val id: String get() = event.id
    }

    data class CallEventItem(val event: CallEvent) : ChatItem() {
        override val id: String get() = event.id
    }

    data class File(val file: ChatFile) : ChatItem() {
        override val id: String get() = file.id
    }
}

internal object ChatItemSerializer : KSerializer<ChatItem> {
    override val descriptor: SerialDescriptor = buildClassSerialDescriptor("com.abracode.chatview.ChatItem")

    override fun serialize(encoder: Encoder, value: ChatItem) {
        val json = (encoder as? JsonEncoder)?.json
            ?: throw SerializationException("ChatItem can only be serialized to JSON")
        val obj = buildJsonObject {
            when (value) {
                is ChatItem.Message -> {
                    put("type", "message")
                    put("message", json.encodeToJsonElement(value.message))
                }
                is ChatItem.Thought -> {
                    put("type", "thought")
                    put("message", json.encodeToJsonElement(value.thought))
                }
                is ChatItem.ToolCall -> {
                    put("type", "toolCall")
                    put("toolCall", json.encodeToJsonElement(value.call))
                }
                is ChatItem.Image -> {
                    put("type", "image")
                    put("id", value.id)
                    put("role", json.encodeToJsonElement(value.role))
                    put("image", json.encodeToJsonElement(value.image))
                }
                is ChatItem.System -> {
                    put("type", "system")
                    put("id", value.id)
                    put("text", value.text)
                }
                is ChatItem.Error -> {
                    put("type", "error")
                    put("id", value.id)
                    put("text", value.text)
                }
                is ChatItem.MemberEventItem -> {
                    put("type", "memberEvent")
                    put("memberEvent", json.encodeToJsonElement(value.event))
                }
                is ChatItem.CallEventItem -> {
                    put("type", "callEvent")
                    put("callEvent", json.encodeToJsonElement(value.event))
                }
                is ChatItem.File -> {
                    put("type", "file")
                    put("file", json.encodeToJsonElement(value.file))
                }
            }
        }
        (encoder as JsonEncoder).encodeJsonElement(obj)
    }

    override fun deserialize(decoder: Decoder): ChatItem {
        val json = (decoder as? JsonDecoder)?.json
            ?: throw SerializationException("ChatItem can only be deserialized from JSON")
        val obj = (decoder as JsonDecoder).decodeJsonElement().jsonObject
        val type = obj["type"]?.jsonPrimitive?.content
            ?: throw SerializationException("ChatItem is missing its `type` discriminator")
        fun <T> field(key: String, deserialize: (JsonElement) -> T): T {
            val element = obj[key] ?: throw SerializationException("ChatItem `$type` is missing `$key`")
            return deserialize(element)
        }
        fun string(key: String): String = field(key) { it.jsonPrimitive.content }
        return when (type) {
            "message" -> ChatItem.Message(field("message") { json.decodeFromJsonElement(it) })
            "thought" -> ChatItem.Thought(field("message") { json.decodeFromJsonElement(it) })
            "toolCall" -> ChatItem.ToolCall(field("toolCall") { json.decodeFromJsonElement(it) })
            "image" -> ChatItem.Image(
                id = string("id"),
                role = field("role") { json.decodeFromJsonElement(it) },
                image = field("image") { json.decodeFromJsonElement(it) },
            )
            "system" -> ChatItem.System(id = string("id"), text = string("text"))
            "error" -> ChatItem.Error(id = string("id"), text = string("text"))
            "memberEvent" -> ChatItem.MemberEventItem(field("memberEvent") { json.decodeFromJsonElement(it) })
            "callEvent" -> ChatItem.CallEventItem(field("callEvent") { json.decodeFromJsonElement(it) })
            "file" -> ChatItem.File(field("file") { json.decodeFromJsonElement(it) })
            else -> throw SerializationException("Unknown ChatItem type `$type`")
        }
    }
}

/**
 * The serializable form of a whole chat session (P0-2). `version` pins the format; `items` is the transcript;
 * `usage` / `plan` are the latest status surfaces; `title` is an app-owned label; `participants` is the group
 * roster (v2). Tolerant decode (version -> 1, items -> [], plan -> []); `plan` encoded only when non-empty;
 * `participants` omitted when null so a v1 transcript stays byte-identical.
 */
@Serializable(with = ChatTranscriptSerializer::class)
data class ChatTranscript(
    val version: Int = 1,
    val items: List<ChatItem>,
    val usage: UsageInfo? = null,
    val plan: List<PlanEntry> = emptyList(),
    val title: String? = null,
    val participants: List<Participant>? = null,
) {
    companion object {
        /**
         * Decodes a restored value into a transcript: a ChatTranscript passes through; a JSON object / string /
         * bytes / map is decoded. Returns null for anything else (an unrelated value), which callers ignore.
         */
        fun decode(value: Any?): ChatTranscript? {
            return when (value) {
                is ChatTranscript -> value
                is String -> runCatching { chatJson.decodeFromString(serializer(), value) }.getOrNull()
                is ByteArray -> runCatching {
                    chatJson.decodeFromString(serializer(), value.toString(Charsets.UTF_8))
                }.getOrNull()
                is JsonElement -> runCatching { chatJson.decodeFromJsonElement(serializer(), value) }.getOrNull()
                is Map<*, *> -> runCatching {
                    chatJson.decodeFromJsonElement(serializer(), anyToJsonElement(value))
                }.getOrNull()
                else -> null
            }
        }
    }
}

internal object ChatTranscriptSerializer : KSerializer<ChatTranscript> {
    override val descriptor: SerialDescriptor = buildClassSerialDescriptor("com.abracode.chatview.ChatTranscript")

    override fun serialize(encoder: Encoder, value: ChatTranscript) {
        val json = (encoder as? JsonEncoder)?.json
            ?: throw SerializationException("ChatTranscript can only be serialized to JSON")
        val obj = buildJsonObject {
            put("version", value.version)
            put("items", json.encodeToJsonElement(ListSerializer(ChatItemSerializer), value.items))
            value.usage?.let { put("usage", json.encodeToJsonElement(it)) }
            if (value.plan.isNotEmpty()) {
                put("plan", json.encodeToJsonElement(ListSerializer(PlanEntry.serializer()), value.plan))
            }
            value.title?.let { put("title", it) }
            value.participants?.let { put("participants", json.encodeToJsonElement(ListSerializer(Participant.serializer()), it)) }
        }
        (encoder as JsonEncoder).encodeJsonElement(obj)
    }

    override fun deserialize(decoder: Decoder): ChatTranscript {
        val json = (decoder as? JsonDecoder)?.json
            ?: throw SerializationException("ChatTranscript can only be deserialized from JSON")
        val obj = (decoder as JsonDecoder).decodeJsonElement().jsonObject
        // An explicit JSON null is treated as absent, mirroring Swift's decodeIfPresent (which returns nil / the
        // default for both a missing key and a null value); decoding JsonNull into a non-null serializer would throw.
        fun present(key: String): JsonElement? = obj[key]?.takeUnless { it is kotlinx.serialization.json.JsonNull }
        val version = present("version")?.jsonPrimitive?.intOrNull ?: 1
        val items = present("items")?.let { json.decodeFromJsonElement(ListSerializer(ChatItemSerializer), it) } ?: emptyList()
        val usage = present("usage")?.let { json.decodeFromJsonElement(UsageInfo.serializer(), it) }
        val plan = present("plan")?.let { json.decodeFromJsonElement(ListSerializer(PlanEntry.serializer()), it) } ?: emptyList()
        val title = present("title")?.jsonPrimitive?.contentOrNull
        val participants = present("participants")?.let {
            json.decodeFromJsonElement(ListSerializer(Participant.serializer()), it)
        }
        return ChatTranscript(version, items, usage, plan, title, participants)
    }
}

/**
 * Best-effort conversion of a decoded-JSON value graph (Map / List / String / Number / Boolean / null, as a host
 * hands through its content channel) into a kotlinx JsonElement, so it can flow through the model serializers.
 * Mirrors the Swift `JSONSerialization.data(withJSONObject:)` leg of `ChatTranscript.decode(from:)`.
 */
internal fun anyToJsonElement(value: Any?): JsonElement = when (value) {
    null -> kotlinx.serialization.json.JsonNull
    is JsonElement -> value
    is String -> kotlinx.serialization.json.JsonPrimitive(value)
    is Boolean -> kotlinx.serialization.json.JsonPrimitive(value)
    is Int -> kotlinx.serialization.json.JsonPrimitive(value)
    is Long -> kotlinx.serialization.json.JsonPrimitive(value)
    is Double -> kotlinx.serialization.json.JsonPrimitive(value)
    is Float -> kotlinx.serialization.json.JsonPrimitive(value)
    is Number -> kotlinx.serialization.json.JsonPrimitive(value)
    is Map<*, *> -> JsonObject(value.entries.associate { (k, v) -> k.toString() to anyToJsonElement(v) })
    is List<*> -> kotlinx.serialization.json.JsonArray(value.map { anyToJsonElement(it) })
    else -> throw SerializationException("Cannot convert value of type ${value::class} to JSON")
}

/** A `reportsConnectionState` transport's link state, emitted via `.connectionStateChanged`. */
@Serializable
enum class ChatConnectionState {
    @SerialName("connecting") CONNECTING,
    @SerialName("connected") CONNECTED,
    @SerialName("reconnecting") RECONNECTING,
    @SerialName("offline") OFFLINE,
}

/**
 * Normalized inbound event a transport emits. Transport-agnostic. NOT serializable (runtime contract only; fixture
 * replay uses a test-only codec). Mirrors the Swift `ChatEvent` enum case-for-case.
 */
sealed interface ChatEvent {
    data class SessionReady(val sessionID: String, val configOptions: List<SessionConfigOption>) : ChatEvent
    data class MessageStart(val itemID: String, val role: ChatRole) : ChatEvent
    data class MessageDelta(val itemID: String, val text: String) : ChatEvent
    data class MessageEnd(val itemID: String, val stopReason: String?) : ChatEvent
    data class ThoughtDelta(val itemID: String, val text: String) : ChatEvent
    data class ToolCall(val call: ToolCallModel) : ChatEvent
    data class ToolCallUpdateEvent(val update: ToolCallUpdate) : ChatEvent
    data class PermissionRequestEvent(val request: PermissionRequest) : ChatEvent
    data class Plan(val entries: List<PlanEntry>) : ChatEvent
    data class Usage(val usage: UsageInfo) : ChatEvent
    data class CurrentModeChanged(val modeID: String) : ChatEvent
    data class CommandsAvailable(val commands: List<SlashCommand>) : ChatEvent
    data class ConfigOptionsChanged(val options: List<SessionConfigOption>) : ChatEvent
    data class Image(val itemID: String, val role: ChatRole, val image: ChatImage) : ChatEvent
    data class System(val text: String) : ChatEvent
    data class Error(val message: String, val recoverable: Boolean) : ChatEvent

    // --- P2P (v2) additive vocabulary. All are transport -> store.
    data class MessageReceived(val message: ChatMessage) : ChatEvent
    data class MessageIDConfirmed(val localID: String, val serverID: String) : ChatEvent
    data class MessageStatusChanged(val itemID: String, val status: MessageStatus) : ChatEvent
    data class MessageStatusWatermark(val status: MessageStatus, val upToItemID: String) : ChatEvent
    data class ReactionsChanged(val itemID: String, val reactions: List<Reaction>) : ChatEvent
    data class MessageEdited(val itemID: String, val newText: String, val editedAt: String) : ChatEvent
    data class MessageDeleted(val itemID: String) : ChatEvent
    data class MemberEventReceived(val event: MemberEvent) : ChatEvent
    data class CallEventReceived(val event: CallEvent) : ChatEvent
    data class FileAdded(val file: ChatFile) : ChatEvent
    data class FileProgress(val itemID: String, val progress: Double?, val transferStatus: FileTransferStatus) : ChatEvent
    data class TypingChanged(val isTyping: Boolean, val senderID: String?, val senderName: String?) : ChatEvent
    data class ParticipantsChanged(val participants: List<Participant>) : ChatEvent
    data class HistoryPage(val items: List<ChatItem>, val hasMore: Boolean) : ChatEvent
    data class ConnectionStateChanged(val state: ChatConnectionState) : ChatEvent
}

/**
 * Normalized outbound command the UI hands a transport. NOT serializable (runtime contract only). Mirrors the Swift
 * `ChatCommand` enum case-for-case.
 */
sealed interface ChatCommand {
    data class Prompt(val text: String) : ChatCommand
    data object Cancel : ChatCommand
    data class PermissionResponse(val requestID: String, val optionID: String?) : ChatCommand
    data class SetConfigOption(val optionID: String, val value: String) : ChatCommand

    // --- P2P (v2) additive vocabulary. All are store -> transport.
    data class SendMessage(val text: String, val replyTo: String?, val localID: String) : ChatCommand
    data class ToggleReaction(val itemID: String, val emoji: String, val add: Boolean) : ChatCommand
    data class EditMessage(val itemID: String, val newText: String) : ChatCommand
    data class DeleteMessage(val itemID: String) : ChatCommand
    data class ResendMessage(val itemID: String) : ChatCommand
    data class MarkRead(val upToItemID: String) : ChatCommand
    data class LoadEarlier(val beforeItemID: String, val limit: Int) : ChatCommand
    data class SetTyping(val isTyping: Boolean) : ChatCommand
    data class CancelFileTransfer(val itemID: String) : ChatCommand
}
