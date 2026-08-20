// Sources/ChatView/ChatModel.swift
//
// Transport-agnostic value types shared across the Chat add-on:
//   - the render model:        ChatRole, ChatMessage, ChatItem
//   - the normalized inbound:  ChatEvent  (what a transport emits)
//   - the normalized outbound: ChatCommand (what the UI sends a transport)
//
// The ChatEvent / ChatCommand vocabularies are a SUPERSET shaped by the richest
// transport (ACP); a simpler transport emits only a subset. M1 defined the plain
// message lifecycle plus system / error notices; M3 adds the agentic vocabulary -
// reasoning (thoughts), tool-call cards, and permission requests - shaped 1:1
// after ACP's session/update payloads so the ACP transport maps directly, but
// still transport-agnostic (the scripted local transport emits them too). Plans,
// terminals, and slash commands arrive with the M5 side panels
// (Private/chat-element-design.md).
//
// PUBLIC API NOTE: ChatEvent / ChatCommand and every value type they carry are the
// frozen transport-facing contract (P0-6). A transport lives in its own module
// (ActionUIChatACP, ActionUIChatOpenAI, or a host's own) and depends on
// ActionUIChatCore only for these types plus the ChatTransport protocol; so they are
// `public` with explicit `public init`s. The render model that never crosses the
// transport boundary (ChatMessage, ChatItem) stays internal.

import Foundation
import CoreGraphics

/// The party a transcript item belongs to. A transport maps its own participants
/// onto these keys; the JSON `roles` map then resolves each key to a side / label
/// / tint. In single-alignment (M1) `side` is ignored and only label / tint matter.
public enum ChatRole: String, Sendable, Hashable, Codable {
    case local      // the local user (composer input)
    case agent      // an AI agent
    case remote     // the other party in person-to-person chat
    case system     // session / system notices
}

/// Delivery state of an own (outgoing) message, rendered as a caption under the last
/// message of a run (P2P / group chat). The four ladder states advance monotonically
/// (`sending` -> `sent` -> `delivered` -> `read`); `failed` is OUTSIDE the ladder and
/// is never overwritten by a status watermark. v1 messages never carry a status, so
/// the delivery-status affordance stays invisible for them.
public enum MessageStatus: String, Sendable, Hashable, Codable {
    case sending, sent, delivered, read, failed

    /// Position in the delivery ladder (`sending` < `sent` < `delivered` < `read`);
    /// `nil` for `failed`, which sits outside the ladder. A watermark advances a
    /// message's status only when the new rank is higher, so it never regresses a
    /// message and never touches a `failed` one.
    public var watermarkRank: Int? {
        switch self {
        case .sending:   return 0
        case .sent:      return 1
        case .delivered: return 2
        case .read:      return 3
        case .failed:    return nil
        }
    }
}

/// One aggregated emoji reaction on a message: the emoji, how many participants added
/// it, and whether the local user is one of them (`mine` drives the tinted-chip
/// treatment and the toggle affordance). A transport replaces the whole reaction set
/// per message (`.reactionsChanged`), so counts are always authoritative.
public struct Reaction: Equatable, Sendable, Codable {
    public let emoji: String
    public let count: Int
    public let mine: Bool

    public init(emoji: String, count: Int, mine: Bool) {
        self.emoji = emoji
        self.count = count
        self.mine = mine
    }
}

/// A reference to the message being replied to, carried on the replying message so the
/// quoted-excerpt block renders without a second lookup. `excerpt` is pre-truncated by
/// the producer (plain text, ~200 chars max); `itemID` is the original message's id, so
/// tapping the quote can scroll to it. `senderName` labels the quote when known.
public struct ReplyRef: Equatable, Sendable, Codable {
    public let itemID: String
    public let excerpt: String
    public let senderName: String?

    public init(itemID: String, excerpt: String, senderName: String? = nil) {
        self.itemID = itemID
        self.excerpt = excerpt
        self.senderName = senderName
    }
}

/// A single conversation message. `text` accumulates streaming deltas; `isStreaming`
/// is true while the turn that owns it is still in flight (drives the streaming row
/// treatment and the Stop affordance). The `id` is stable so the transcript's
/// `LazyVStack` does not re-diff finalized rows while the last message streams.
///
/// A streaming (agentic) message enters and leaves a transport only as itemID + role +
/// text deltas (ChatEvent), never as this whole value; a P2P message, by contrast,
/// arrives complete (`.messageReceived`). Either way it IS part of the persisted
/// transcript (P0-2), so it is public and Codable. The transient `isStreaming` render
/// flag is NOT serialized: a loaded message is always final (decodes with isStreaming
/// == false).
///
/// The `senderID` / `senderName` / `avatarURL` / `timestamp` / `status` / `reactions` /
/// `editedAt` / `replyTo` / `deleted` fields are the ADDITIVE P2P (v2) layer: all
/// optional, all omitted-when-nil, so a v1 message serializes byte-identically. Sender
/// resolution order (the view / the ports follow it): message `senderName` / `avatarURL`
/// -> transcript `participants` looked up by `senderID` -> the role default from config.
public struct ChatMessage: Identifiable, Equatable, Sendable, Codable {
    public let id: String
    public let role: ChatRole
    public var text: String
    public var isStreaming: Bool

    // P2P (v2) additive fields; all optional, nil for v1 messages.
    public var senderID: String?      // participant identity (group chats)
    public var senderName: String?    // per-message sender name (rosterless transports)
    public var avatarURL: String?     // per-message avatar override
    public var timestamp: String?     // RFC 3339 with timezone; parsed to Date for display
    public var status: MessageStatus? // delivery state of an own message
    public var reactions: [Reaction]? // aggregated emoji reactions
    public var editedAt: String?      // RFC 3339; when present, the row shows an "(edited)" badge
    public var replyTo: ReplyRef?     // the message this one replies to
    public var deleted: Bool?         // tombstone; when true the view ignores `text`

    public init(id: String, role: ChatRole, text: String, isStreaming: Bool,
                senderID: String? = nil, senderName: String? = nil, avatarURL: String? = nil,
                timestamp: String? = nil, status: MessageStatus? = nil, reactions: [Reaction]? = nil,
                editedAt: String? = nil, replyTo: ReplyRef? = nil, deleted: Bool? = nil) {
        self.id = id
        self.role = role
        self.text = text
        self.isStreaming = isStreaming
        self.senderID = senderID
        self.senderName = senderName
        self.avatarURL = avatarURL
        self.timestamp = timestamp
        self.status = status
        self.reactions = reactions
        self.editedAt = editedAt
        self.replyTo = replyTo
        self.deleted = deleted
    }

    private enum CodingKeys: String, CodingKey {
        case id, role, text
        case senderID, senderName, avatarURL, timestamp, status, reactions, editedAt, replyTo, deleted
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try container.decode(String.self, forKey: .id)
        self.role = try container.decode(ChatRole.self, forKey: .role)
        self.text = try container.decode(String.self, forKey: .text)
        self.isStreaming = false
        self.senderID = try container.decodeIfPresent(String.self, forKey: .senderID)
        self.senderName = try container.decodeIfPresent(String.self, forKey: .senderName)
        self.avatarURL = try container.decodeIfPresent(String.self, forKey: .avatarURL)
        self.timestamp = try container.decodeIfPresent(String.self, forKey: .timestamp)
        self.status = try container.decodeIfPresent(MessageStatus.self, forKey: .status)
        self.reactions = try container.decodeIfPresent([Reaction].self, forKey: .reactions)
        self.editedAt = try container.decodeIfPresent(String.self, forKey: .editedAt)
        self.replyTo = try container.decodeIfPresent(ReplyRef.self, forKey: .replyTo)
        self.deleted = try container.decodeIfPresent(Bool.self, forKey: .deleted)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(role, forKey: .role)
        try container.encode(text, forKey: .text)
        // v2 fields: omitted-when-nil, so a v1 message encodes byte-identically to before.
        try container.encodeIfPresent(senderID, forKey: .senderID)
        try container.encodeIfPresent(senderName, forKey: .senderName)
        try container.encodeIfPresent(avatarURL, forKey: .avatarURL)
        try container.encodeIfPresent(timestamp, forKey: .timestamp)
        try container.encodeIfPresent(status, forKey: .status)
        try container.encodeIfPresent(reactions, forKey: .reactions)
        try container.encodeIfPresent(editedAt, forKey: .editedAt)
        try container.encodeIfPresent(replyTo, forKey: .replyTo)
        try container.encodeIfPresent(deleted, forKey: .deleted)
    }
}

/// A standalone image transcript element. Chat splits an image and its accompanying text into SEPARATE
/// items (a person dropping a photo with a comment, an agent returning an image block), so an image is its
/// own element, not part of a message's `text`. `pixelSize` is the source's natural size when the transport
/// knows it - it lets the transcript reserve exact space so the picture hydrates without reflowing the
/// scroll position. `alt` is the accessibility / fallback description.
public struct ChatImage: Sendable, Equatable, Codable {
    public let url: URL
    public let alt: String
    public let pixelSize: CGSize?

    public init(url: URL, alt: String = "", pixelSize: CGSize? = nil) {
        self.url = url
        self.alt = alt
        self.pixelSize = pixelSize
    }

    // Serializes by source reference (the URL / path), never pixel data. `pixelSize` is
    // flattened to explicit width/height so the JSON shape is stable and self-documenting.
    private enum CodingKeys: String, CodingKey {
        case url, alt, pixelWidth, pixelHeight
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.url = try container.decode(URL.self, forKey: .url)
        self.alt = try container.decodeIfPresent(String.self, forKey: .alt) ?? ""
        if let width = try container.decodeIfPresent(Double.self, forKey: .pixelWidth),
           let height = try container.decodeIfPresent(Double.self, forKey: .pixelHeight) {
            self.pixelSize = CGSize(width: width, height: height)
        } else {
            self.pixelSize = nil
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(url, forKey: .url)
        try container.encode(alt, forKey: .alt)
        if let pixelSize {
            try container.encode(Double(pixelSize.width), forKey: .pixelWidth)
            try container.encode(Double(pixelSize.height), forKey: .pixelHeight)
        }
    }
}

/// A tool invocation surfaced by an agentic transport, rendered as a card in the
/// transcript. The shape mirrors ACP's `tool_call` payload (kind / status vocabularies
/// are ACP's) so the ACP transport maps 1:1, but nothing here is wire-specific - the
/// scripted local transport builds these too. `contentText` is the call's textual
/// content (Markdown, joined across content blocks); `diff` and the raw input / output
/// are optional detail the card can disclose.
public struct ToolCallModel: Identifiable, Equatable, Sendable, Codable {

    /// Persistence coding keys (P0-2): pinned so the on-disk format does not drift.
    private enum CodingKeys: String, CodingKey {
        case id, title, kind, status, contentText, diff, rawInput, rawOutput
    }

    /// What the call does; drives the card icon. ACP's `kind` vocabulary.
    public enum Kind: String, Sendable, Codable {
        case read, edit, delete, move, search, execute, think, fetch, other
    }

    /// Lifecycle state; drives the card's status indicator. ACP's `status` vocabulary.
    public enum Status: String, Sendable, Codable {
        case pending
        case inProgress = "in_progress"
        case completed
        case failed
    }

    public let id: String
    public var title: String
    public var kind: Kind
    public var status: Status
    public var contentText: String
    public var diff: ToolCallDiff?
    public var rawInput: String?      // pretty-printed JSON, when the transport provides it
    public var rawOutput: String?

    public init(id: String, title: String, kind: Kind, status: Status, contentText: String,
                diff: ToolCallDiff? = nil, rawInput: String? = nil, rawOutput: String? = nil) {
        self.id = id
        self.title = title
        self.kind = kind
        self.status = status
        self.contentText = contentText
        self.diff = diff
        self.rawInput = rawInput
        self.rawOutput = rawOutput
    }
}

/// A proposed or applied file change carried inside a tool call's content
/// (ACP's `diff` ToolCallContent). Rendered as a code preview in M3; a real
/// side-by-side diff viewer is an M5 surface.
public struct ToolCallDiff: Equatable, Sendable, Codable {
    private enum CodingKeys: String, CodingKey {
        case path, oldText, newText
    }

    public let path: String
    public let oldText: String?
    public let newText: String

    public init(path: String, oldText: String?, newText: String) {
        self.path = path
        self.oldText = oldText
        self.newText = newText
    }
}

/// A partial mutation of an existing tool call (ACP's `tool_call_update`):
/// only non-nil fields change on the card.
public struct ToolCallUpdate: Sendable {
    public let id: String
    public var title: String?
    public var kind: ToolCallModel.Kind?
    public var status: ToolCallModel.Status?
    public var contentText: String?
    public var diff: ToolCallDiff?
    public var rawInput: String?
    public var rawOutput: String?

    public init(id: String, title: String? = nil, kind: ToolCallModel.Kind? = nil,
                status: ToolCallModel.Status? = nil, contentText: String? = nil,
                diff: ToolCallDiff? = nil, rawInput: String? = nil, rawOutput: String? = nil) {
        self.id = id
        self.title = title
        self.kind = kind
        self.status = status
        self.contentText = contentText
        self.diff = diff
        self.rawInput = rawInput
        self.rawOutput = rawOutput
    }
}

/// An agent's request to run a gated tool call (ACP's `session/request_permission`).
/// The UI blocks the call until the user picks one of the agent-offered options (or
/// the turn is cancelled); the option kinds are ACP's standard four.
public struct PermissionRequest: Identifiable, Equatable, Sendable {

    public struct Option: Identifiable, Equatable, Sendable {
        public enum Kind: String, Sendable {
            case allowOnce = "allow_once"
            case allowAlways = "allow_always"
            case rejectOnce = "reject_once"
            case rejectAlways = "reject_always"

            public var allows: Bool {
                self == .allowOnce || self == .allowAlways
            }
        }
        public let id: String        // the wire optionId, echoed back in the response
        public let name: String
        public let kind: Kind

        public init(id: String, name: String, kind: Kind) {
            self.id = id
            self.name = name
            self.kind = kind
        }
    }

    public let id: String            // the request ID, echoed back in the response
    public let toolCallID: String?   // the gated call, when the transport correlates one
    public let title: String
    public let options: [Option]

    public init(id: String, toolCallID: String?, title: String, options: [Option]) {
        self.id = id
        self.toolCallID = toolCallID
        self.title = title
        self.options = options
    }
}

/// One step of the agent's evolving task plan (ACP `plan`). The agent re-emits the
/// WHOLE plan as it progresses, so the store replaces the list rather than merging.
/// ACP plan entries carry no IDs; identity is positional, assigned by the transport.
public struct PlanEntry: Identifiable, Equatable, Sendable, Codable {
    private enum CodingKeys: String, CodingKey {
        case id, content, priority, status
    }
    public enum Status: String, Sendable, Codable {
        case pending
        case inProgress = "in_progress"
        case completed
    }
    public let id: Int               // positional (index in the emitted plan)
    public let content: String
    public let priority: String?     // "high" | "medium" | "low" when the agent sends one; display-only
    public let status: Status

    public init(id: Int, content: String, priority: String?, status: Status) {
        self.id = id
        self.content = content
        self.priority = priority
        self.status = status
    }
}

/// Token / cost usage for the session (OpenCode's `usage_update`: tokens used out of
/// the context window, plus an optional cost). Agents that do not report usage never
/// emit it; the status line simply stays empty.
public struct UsageInfo: Equatable, Sendable, Codable {
    private enum CodingKeys: String, CodingKey {
        case used, size, costAmount, costCurrency
    }

    public let used: Int
    public let size: Int?            // context window size, when reported
    public let costAmount: Double?
    public let costCurrency: String?

    public init(used: Int, size: Int?, costAmount: Double?, costCurrency: String?) {
        self.used = used
        self.size = size
        self.costAmount = costAmount
        self.costCurrency = costCurrency
    }
}

/// One selectable session option advertised by the agent at session start (OpenCode's
/// session/new `configOptions`: model, mode, ...; the ACP spec's `modes` sketch maps
/// onto the same shape). Displayed read-only in the status line (M5 part 1); the
/// interactive setter is M5 part 3.
public struct SessionConfigOption: Identifiable, Equatable, Sendable {
    public struct Choice: Equatable, Sendable {
        public let value: String
        public let name: String
        public let description: String?

        public init(value: String, name: String, description: String?) {
            self.value = value
            self.name = name
            self.description = description
        }
    }
    public let id: String            // e.g. "model", "mode"
    public let name: String          // display name, e.g. "Session Mode"
    public let category: String?     // "model" | "mode" | agent-specific
    public var currentValue: String  // a Choice.value; `current_mode_update` mutates the mode option's
    public let options: [Choice]

    public init(id: String, name: String, category: String?, currentValue: String, options: [Choice]) {
        self.id = id
        self.name = name
        self.category = category
        self.currentValue = currentValue
        self.options = options
    }

    public var currentChoiceName: String? {
        options.first(where: { $0.value == currentValue })?.name
    }
}

/// Identity and capabilities of the live agent session, emitted once the session is
/// established (ACP: after initialize + session/new or session/load). Additive to the
/// frozen transport contract: transports that do not emit it are unaffected. Codable so
/// the store can hand it to a persisting host through the entry channel.
public struct AgentSessionInfo: Equatable, Sendable, Codable {
    public let sessionId: String
    public let agentName: String?       // initialize agentInfo.name
    public let agentVersion: String?    // initialize agentInfo.version
    public let protocolVersion: Int?
    public let agentPid: Int?           // the spawned subprocess, for host-side lifecycle registries
    public let canLoadSession: Bool     // agentCapabilities.loadSession
    public let canPrime: Bool           // agentCapabilities.sessionPrime (mlx-agent extension)
    public let resumed: Bool            // true when this session came from session/load

    public init(sessionId: String, agentName: String?, agentVersion: String?, protocolVersion: Int?,
                agentPid: Int?, canLoadSession: Bool, canPrime: Bool, resumed: Bool) {
        self.sessionId = sessionId
        self.agentName = agentName
        self.agentVersion = agentVersion
        self.protocolVersion = protocolVersion
        self.agentPid = agentPid
        self.canLoadSession = canLoadSession
        self.canPrime = canPrime
        self.resumed = resumed
    }
}

/// A slash command the agent currently offers (ACP `available_commands_update`,
/// re-emitted whole as the set changes). Selecting one just fills the composer:
/// commands are SENT as ordinary prompt text ("/name args") for the agent to
/// interpret - there is no separate command channel.
public struct SlashCommand: Identifiable, Equatable, Sendable {
    public let name: String          // without the leading slash
    public let description: String

    public init(name: String, description: String) {
        self.name = name
        self.description = description
    }

    public var id: String {
        name
    }
}

/// A membership / roster change in a group conversation, rendered as a centered caption
/// (the same visual family as `.system`). `actorName` is who performed the change,
/// `subjectName` who it targeted (both optional - a transport may know only one); `detail`
/// carries the free-form remainder (the new name on a rename, the new role on a role change).
public struct MemberEvent: Identifiable, Equatable, Sendable, Codable {
    public enum Kind: String, Sendable, Codable {
        case joined, left, invited, removed, roleChanged, renamed
    }
    public let id: String
    public let timestamp: String?
    public let kind: Kind
    public let actorName: String?
    public let subjectName: String?
    public let detail: String?

    public init(id: String, timestamp: String? = nil, kind: Kind,
                actorName: String? = nil, subjectName: String? = nil, detail: String? = nil) {
        self.id = id
        self.timestamp = timestamp
        self.kind = kind
        self.actorName = actorName
        self.subjectName = subjectName
        self.detail = detail
    }
}

/// A call log entry, rendered as a centered caption with a phone / video glyph. `kind`
/// distinguishes a missed incoming / outgoing call from a completed or declined one;
/// `durationSeconds` is present on a completed call, `isVideo` selects the glyph.
public struct CallEvent: Identifiable, Equatable, Sendable, Codable {
    public enum Kind: String, Sendable, Codable {
        case missedIncoming, missedOutgoing, completed, declined
    }
    public let id: String
    public let timestamp: String?
    public let kind: Kind
    public let durationSeconds: Int?
    public let isVideo: Bool?

    public init(id: String, timestamp: String? = nil, kind: Kind,
                durationSeconds: Int? = nil, isVideo: Bool? = nil) {
        self.id = id
        self.timestamp = timestamp
        self.kind = kind
        self.durationSeconds = durationSeconds
        self.isVideo = isVideo
    }
}

/// The state of a file / voice-message transfer, independent of the message delivery
/// `status`: a file can be delivered as a message while its bytes are still transferring.
public enum FileTransferStatus: String, Sendable, Hashable, Codable {
    case pending, transferring, completed, failed, cancelled
}

/// A file attachment or voice message in the transcript. One case covers both: `kind`
/// selects the rendering (a document row vs. a voice player). `url` points at the file
/// when available (local or downloaded); while it is still arriving, `transferStatus` /
/// `progress` drive the transfer UI. `durationSeconds` is the clip length for a voice
/// message. `status` is the message-level delivery state (as on `ChatMessage`), separate
/// from `transferStatus` (the byte-transfer state).
public struct ChatFile: Identifiable, Equatable, Sendable, Codable {
    public enum Kind: String, Sendable, Codable {
        case file, voice
    }
    public let id: String
    public let role: ChatRole
    public let senderID: String?
    public let senderName: String?
    public let timestamp: String?
    public let status: MessageStatus?
    public let name: String
    public let sizeBytes: Int?
    public let url: URL?
    public let kind: Kind
    public let durationSeconds: Int?
    public var transferStatus: FileTransferStatus
    public var progress: Double?      // 0...1 while transferring; nil when unknown / not applicable

    public init(id: String, role: ChatRole, senderID: String? = nil, senderName: String? = nil,
                timestamp: String? = nil, status: MessageStatus? = nil, name: String,
                sizeBytes: Int? = nil, url: URL? = nil, kind: Kind = .file,
                durationSeconds: Int? = nil, transferStatus: FileTransferStatus = .completed,
                progress: Double? = nil) {
        self.id = id
        self.role = role
        self.senderID = senderID
        self.senderName = senderName
        self.timestamp = timestamp
        self.status = status
        self.name = name
        self.sizeBytes = sizeBytes
        self.url = url
        self.kind = kind
        self.durationSeconds = durationSeconds
        self.transferStatus = transferStatus
        self.progress = progress
    }

    private enum CodingKeys: String, CodingKey {
        case id, role, senderID, senderName, timestamp, status, name, sizeBytes, url, kind, durationSeconds, transferStatus, progress
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try container.decode(String.self, forKey: .id)
        self.role = try container.decode(ChatRole.self, forKey: .role)
        self.senderID = try container.decodeIfPresent(String.self, forKey: .senderID)
        self.senderName = try container.decodeIfPresent(String.self, forKey: .senderName)
        self.timestamp = try container.decodeIfPresent(String.self, forKey: .timestamp)
        self.status = try container.decodeIfPresent(MessageStatus.self, forKey: .status)
        self.name = try container.decode(String.self, forKey: .name)
        self.sizeBytes = try container.decodeIfPresent(Int.self, forKey: .sizeBytes)
        self.url = try container.decodeIfPresent(URL.self, forKey: .url)
        self.kind = try container.decodeIfPresent(Kind.self, forKey: .kind) ?? .file
        self.durationSeconds = try container.decodeIfPresent(Int.self, forKey: .durationSeconds)
        self.transferStatus = try container.decodeIfPresent(FileTransferStatus.self, forKey: .transferStatus) ?? .completed
        self.progress = try container.decodeIfPresent(Double.self, forKey: .progress)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(role, forKey: .role)
        try container.encodeIfPresent(senderID, forKey: .senderID)
        try container.encodeIfPresent(senderName, forKey: .senderName)
        try container.encodeIfPresent(timestamp, forKey: .timestamp)
        try container.encodeIfPresent(status, forKey: .status)
        try container.encode(name, forKey: .name)
        try container.encodeIfPresent(sizeBytes, forKey: .sizeBytes)
        try container.encodeIfPresent(url, forKey: .url)
        try container.encode(kind, forKey: .kind)
        try container.encodeIfPresent(durationSeconds, forKey: .durationSeconds)
        try container.encode(transferStatus, forKey: .transferStatus)
        try container.encodeIfPresent(progress, forKey: .progress)
    }
}

/// A conversation participant (the group roster). `isSelf` marks the local user (used to
/// derive dual alignment when a message's role does not). Carried on `ChatTranscript` so
/// a message's `senderID` resolves to a name / avatar without a per-message copy.
public struct Participant: Identifiable, Equatable, Sendable, Codable {
    public let id: String
    public let name: String
    public let avatarURL: String?
    public let isSelf: Bool?

    public init(id: String, name: String, avatarURL: String? = nil, isSelf: Bool? = nil) {
        self.id = id
        self.name = name
        self.avatarURL = avatarURL
        self.isSelf = isSelf
    }
}

/// A heterogeneous, arrival-ordered transcript entry. M1 carries messages plus
/// system / error notices; M3 adds thoughts (reasoning, `ChatMessage`-shaped but
/// visually folded) and tool-call cards; the P2P (v2) layer adds member events, call
/// events, and file / voice items. Plan / terminal panels are M5 side surfaces and
/// live outside the transcript.
///
/// The store's render model - transports emit ChatEvents and the store builds ChatItems
/// from them - and, since P0-2, the unit of the persisted transcript, so it is public and
/// Codable. Codable uses a stable `type` discriminator ("message" / "thought" / "toolCall"
/// / "image" / "system" / "error") so the on-disk format does not drift.
/// A record, in the transcript, of something changing about the SESSION rather than about the
/// conversation - it started, it was resumed, the model answering it changed.
///
/// WHY THIS IS A TRANSCRIPT ITEM AND NOT A STATUS SURFACE. A status line answers "what is true
/// now"; this answers "what was true then", which is the question a reader of an old conversation
/// actually has. A conversation resumed three times with three different models is one transcript
/// whose parts were written by different authors, and without a record in the flow there is
/// nothing to attribute them to - the status line only ever shows the last one.
///
/// APPENDED, NEVER INSERTED. The store is append-only, and appending is also the honest
/// placement: the event happened at that point in time, so it belongs after everything that
/// preceded it and before everything that follows.
///
/// `model` is a DISPLAY name and may be absent. Agents advertise a model through session
/// `configOptions`, but not all of them do - mlx-agent advertises none at all - so a host that
/// knows better can supply one through its configuration, and neither source is guaranteed.
/// What an agent did to a restored conversation when it summarized instead of replaying it.
///
/// THE POINT OF CARRYING THIS AT ALL IS THAT THE USER CAN READ IT. A summary the model holds and
/// the person cannot see is a context loss they can only infer from degraded answers - they have
/// to guess what was dropped from the way it starts getting things wrong. Shown, they can simply
/// restate whatever the digest missed.
///
/// Structured rather than prose because the parts answer different questions: `decisions` is what
/// was settled, `openThreads` is what was not, and a reader scanning for what is MISSING needs
/// them apart. `summarizer` matters for the same reason - "the summary is thin" and "the summary
/// was written by a 3B on-device model" are the same observation from the reader's side.
public struct SessionDigest: Equatable, Sendable, Codable {
    /// The model that wrote the summary, as the agent names it.
    public let summarizer: String?
    /// How many messages were replaced, and how many are still verbatim after it.
    public let droppedTurns: Int?
    public let verbatimTurns: Int?

    public let unresolvedIntent: String?
    public let establishedFacts: [String]
    public let decisions: [String]
    public let openThreads: [String]
    public let userPreferences: [String]

    public init(summarizer: String? = nil, droppedTurns: Int? = nil, verbatimTurns: Int? = nil,
                unresolvedIntent: String? = nil, establishedFacts: [String] = [],
                decisions: [String] = [], openThreads: [String] = [],
                userPreferences: [String] = []) {
        self.summarizer = summarizer
        self.droppedTurns = droppedTurns
        self.verbatimTurns = verbatimTurns
        self.unresolvedIntent = unresolvedIntent
        self.establishedFacts = establishedFacts
        self.decisions = decisions
        self.openThreads = openThreads
        self.userPreferences = userPreferences
    }

    /// Every section is optional on the wire, so a digest with nothing in it is possible and must
    /// not render as an empty disclosure the user opens for nothing.
    public var isEmpty: Bool {
        (unresolvedIntent?.isEmpty ?? true) && establishedFacts.isEmpty && decisions.isEmpty
            && openThreads.isEmpty && userPreferences.isEmpty
    }
}

/// What a host asks for when it wants a restore summarized rather than replayed. The bounds are
/// the agent's to clamp; nil means "your default".
public struct PrimeCondense: Equatable, Sendable, Codable {
    public let keepRecentTurns: Int?
    public let maxDigestTokens: Int?
    /// Which model should summarize THIS restore, in the agent's own vocabulary, or nil to leave
    /// the choice to however the agent was configured.
    ///
    /// A STRING, deliberately, and never interpreted here. The set of summarizers is the agent's
    /// (mlx-agent takes `auto`, `foundation`, `session`, `none`), it differs between agents, and a
    /// closed enum in this library would mean a new summarizer needs a ChatView release before a
    /// host could name it. So the value is carried through to `session/prime` untouched and the
    /// agent decides - including whether it can honor it, which it reports back through the
    /// condensation marker's summarizer name.
    ///
    /// It matters that this is per RESTORE rather than per agent process: a host offering the
    /// choice to a person has to be able to honor it in the conversation in front of them, and an
    /// agent outlives any one restore.
    public let backend: String?

    public init(keepRecentTurns: Int? = nil, maxDigestTokens: Int? = nil, backend: String? = nil) {
        self.keepRecentTurns = keepRecentTurns
        self.maxDigestTokens = maxDigestTokens
        self.backend = backend
    }
}

public struct SessionEvent: Identifiable, Equatable, Sendable, Codable {
    public enum Kind: String, Codable, Sendable {
        case started        // a fresh conversation
        case resumed        // a saved conversation loaded back into a session
        case modelChanged   // the model answering changed mid-conversation
    }

    public let id: String
    public let kind: Kind
    /// ISO 8601, same format ChatMessage uses. Optional because a host that does not stamp its
    /// items should not be forced to start.
    public let timestamp: String?
    /// The model answering from this point on, as a person would read it.
    public let model: String?
    /// Present when the conversation was summarized to get here, so the reader can see what the
    /// model was actually given in place of the messages above.
    public let digest: SessionDigest?

    public init(id: String, kind: Kind, timestamp: String? = nil, model: String? = nil,
                digest: SessionDigest? = nil) {
        self.id = id
        self.kind = kind
        self.timestamp = timestamp
        self.model = model
        self.digest = digest
    }
}

public enum ChatItem: Identifiable, Equatable, Sendable, Codable {
    case message(ChatMessage)
    case thought(ChatMessage)
    case toolCall(ToolCallModel)
    case image(id: String, role: ChatRole, image: ChatImage)
    case system(id: String, text: String)
    case error(id: String, text: String)
    case memberEvent(MemberEvent)
    case callEvent(CallEvent)
    case file(ChatFile)
    case sessionEvent(SessionEvent)

    public var id: String {
        switch self {
        case .message(let message):  return message.id
        case .thought(let thought):  return thought.id
        case .toolCall(let call):    return call.id
        case .image(let id, _, _):   return id
        case .system(let id, _):     return id
        case .error(let id, _):      return id
        case .memberEvent(let event): return event.id
        case .callEvent(let event):  return event.id
        case .file(let file):        return file.id
        case .sessionEvent(let event): return event.id
        }
    }

    private enum CodingKeys: String, CodingKey {
        case type, message, toolCall, id, role, image, text, memberEvent, callEvent, file, sessionEvent
    }

    private enum ItemType: String, Codable {
        case message, thought, toolCall, image, system, error, memberEvent, callEvent, file, sessionEvent
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(ItemType.self, forKey: .type)
        switch type {
        case .message:
            self = .message(try container.decode(ChatMessage.self, forKey: .message))
        case .thought:
            self = .thought(try container.decode(ChatMessage.self, forKey: .message))
        case .toolCall:
            self = .toolCall(try container.decode(ToolCallModel.self, forKey: .toolCall))
        case .image:
            self = .image(id: try container.decode(String.self, forKey: .id),
                          role: try container.decode(ChatRole.self, forKey: .role),
                          image: try container.decode(ChatImage.self, forKey: .image))
        case .system:
            self = .system(id: try container.decode(String.self, forKey: .id),
                           text: try container.decode(String.self, forKey: .text))
        case .error:
            self = .error(id: try container.decode(String.self, forKey: .id),
                          text: try container.decode(String.self, forKey: .text))
        case .memberEvent:
            self = .memberEvent(try container.decode(MemberEvent.self, forKey: .memberEvent))
        case .callEvent:
            self = .callEvent(try container.decode(CallEvent.self, forKey: .callEvent))
        case .file:
            self = .file(try container.decode(ChatFile.self, forKey: .file))
        case .sessionEvent:
            self = .sessionEvent(try container.decode(SessionEvent.self, forKey: .sessionEvent))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .message(let message):
            try container.encode(ItemType.message, forKey: .type)
            try container.encode(message, forKey: .message)
        case .thought(let thought):
            try container.encode(ItemType.thought, forKey: .type)
            try container.encode(thought, forKey: .message)
        case .toolCall(let call):
            try container.encode(ItemType.toolCall, forKey: .type)
            try container.encode(call, forKey: .toolCall)
        case .image(let id, let role, let image):
            try container.encode(ItemType.image, forKey: .type)
            try container.encode(id, forKey: .id)
            try container.encode(role, forKey: .role)
            try container.encode(image, forKey: .image)
        case .system(let id, let text):
            try container.encode(ItemType.system, forKey: .type)
            try container.encode(id, forKey: .id)
            try container.encode(text, forKey: .text)
        case .error(let id, let text):
            try container.encode(ItemType.error, forKey: .type)
            try container.encode(id, forKey: .id)
            try container.encode(text, forKey: .text)
        case .memberEvent(let event):
            try container.encode(ItemType.memberEvent, forKey: .type)
            try container.encode(event, forKey: .memberEvent)
        case .callEvent(let event):
            try container.encode(ItemType.callEvent, forKey: .type)
            try container.encode(event, forKey: .callEvent)
        case .file(let file):
            try container.encode(ItemType.file, forKey: .type)
            try container.encode(file, forKey: .file)
        case .sessionEvent(let event):
            try container.encode(ItemType.sessionEvent, forKey: .type)
            try container.encode(event, forKey: .sessionEvent)
        }
    }
}

/// The serializable form of a whole chat session (P0-2). The chat has no scalar value: a host
/// RESTORES a saved session at runtime by injecting this (as JSON / a dict / a string) through
/// its ChatContentSource's content channel (in an ActionUI host: states["content"] via
/// setElementState / setElementStateFromString), and persists incrementally the other way, per
/// finalized entry, through the host event sink's `.entry` event. `version` pins the format;
/// `items` is the transcript; `usage` / `plan` are the latest status surfaces; `title` is an
/// optional app-owned label passed through untouched (the component never interprets it).
public struct ChatTranscript: Equatable, Sendable, Codable {
    public let version: Int
    public let items: [ChatItem]
    public let usage: UsageInfo?
    public let plan: [PlanEntry]
    public let title: String?
    public let participants: [Participant]?   // group roster (v2); nil / omitted for v1

    /// `version` defaults to 1 so a transcript with no v2 content serializes byte-identically
    /// to a v1 transcript; a producer that includes P2P content (participants, v2 items /
    /// fields) passes `version: 2`. The decoder accepts either (v1 = v2 fields absent).
    public init(version: Int = 1, items: [ChatItem], usage: UsageInfo? = nil,
                plan: [PlanEntry] = [], title: String? = nil, participants: [Participant]? = nil) {
        self.version = version
        self.items = items
        self.usage = usage
        self.plan = plan
        self.title = title
        self.participants = participants
    }

    private enum CodingKeys: String, CodingKey {
        case version, items, usage, plan, title, participants
    }

    /// One element of `items`, decoded so that a single unreadable entry cannot destroy the rest.
    ///
    /// `ChatItem.init(from:)` throws on an item whose `type` it does not recognize, and an array
    /// decode propagates that: ONE bad element used to fail the whole `ChatTranscript`, which
    /// `decode(from:)` then swallowed with `try?`. A conversation with a single malformed entry
    /// became a conversation that would not open, silently. That really happened, to a real user,
    /// because of one item written with its payload at the top level.
    ///
    /// This never throws, so the array decode always advances cleanly and the surviving items are
    /// kept. What was lost is reported in place rather than omitted: losing one line of a
    /// conversation is a nuisance, losing the conversation is not, and losing either without being
    /// told is the worst of the three.
    ///
    /// A HOST MUST NOT PERSIST A DECODED TRANSCRIPT BACK OVER ITS SOURCE. The placeholder encodes
    /// as an ordinary `.error` row, so writing a rendered transcript back replaces the bytes that
    /// could not be read with a sentence about them - permanently, and after that second read
    /// reports nothing unreadable at all. Persist what the element emits per entry, and rebuild the
    /// transcript from that.
    private struct LossyChatItem: Decodable {
        let item: ChatItem?
        let probedType: String?

        /// The one field worth recovering from an item that would not decode: enough to name what
        /// was unreadable. Its `id` is deliberately NOT recovered - see the placeholder ids below.
        private struct Probe: Decodable {
            let type: String?
        }

        init(from decoder: Decoder) throws {
            if let decoded = try? ChatItem(from: decoder) {
                item = decoded
                probedType = nil
                return
            }
            item = nil
            probedType = (try? Probe(from: decoder))?.type
        }
    }

    /// How many items in the decoded transcript were replaced by a placeholder. Not part of the
    /// wire shape - it describes this decode, not the conversation - so it is absent from
    /// `CodingKeys` and never round-trips.
    public private(set) var unreadableItemCount: Int = 0

    /// The names of the transcript's SIDE surfaces that would not decode and fell back to their
    /// defaults. Like `unreadableItemCount`, absent from `CodingKeys` - it describes this decode.
    public private(set) var unreadableFields: [String] = []

    /// `unreadableItemCount` and `unreadableFields` describe a DECODE, not a conversation, so they
    /// stay out of equality. In it, `decode(from:)` stops being idempotent: re-injecting a repaired
    /// version of a transcript already on screen would differ from the damaged one by the counts
    /// alone, `ChatStore`'s restore dedup would see a change that is not there, and re-applying the
    /// transcript discards a turn that arrived in between.
    public static func == (lhs: ChatTranscript, rhs: ChatTranscript) -> Bool {
        lhs.version == rhs.version && lhs.items == rhs.items && lhs.usage == rhs.usage
            && lhs.plan == rhs.plan && lhs.title == rhs.title
            && lhs.participants == rhs.participants
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.version = try container.decodeIfPresent(Int.self, forKey: .version) ?? 1
        let lossy = try container.decodeIfPresent([LossyChatItem].self, forKey: .items) ?? []
        // A PLACEHOLDER'S ID MUST COLLIDE WITH NOTHING. Adopting the id probed off the unreadable
        // element is the tempting branch and the dangerous one: only `.image`, `.system` and
        // `.error` carry `id` at the top level of an item, so in practice a probed id means the
        // element was an ENVELOPE - exactly the shape `fireEntry` hands hosts, `id` and all. A host
        // that stores envelopes and restores one by mistake would give the placeholder the real
        // message's id, and since every mutation path finds items with `firstIndex`, the live
        // turn's status updates would land on the placeholder and be dropped. Positional instead,
        // then disambiguated against every id in the transcript - including a real item that
        // happens to be called `unreadable-item-0`.
        var taken = Set(lossy.compactMap { $0.item?.id })
        var decoded: [ChatItem] = []
        decoded.reserveCapacity(lossy.count)
        var unreadable = 0
        for (index, element) in lossy.enumerated() {
            if let item = element.item {
                decoded.append(item)
                continue
            }
            unreadable += 1
            var id = "unreadable-item-\(index)"
            var bump = 0
            while taken.contains(id) {
                bump += 1
                id = "unreadable-item-\(index)-\(bump)"
            }
            taken.insert(id)
            let text: String
            if let type = element.probedType {
                text = "This entry could not be read (type \"\(type)\")."
            } else {
                text = "This entry could not be read (no type given)."
            }
            decoded.append(.error(id: id, text: text))
        }
        self.items = decoded
        self.unreadableItemCount = unreadable
        // The same failure one key over. `usage`, `plan`, `participants` and `title` all threw out
        // of this initializer, and `decode(from:)` swallowed it identically - so a future
        // `PlanEntry.Status` case would drop a whole conversation exactly the way a future
        // `ChatItem` case used to. None of them is the conversation, so each degrades to its
        // default and says which one was lost.
        var lost: [String] = []
        do { self.usage = try container.decodeIfPresent(UsageInfo.self, forKey: .usage) }
        catch { self.usage = nil; lost.append("usage") }
        do { self.plan = try container.decodeIfPresent([PlanEntry].self, forKey: .plan) ?? [] }
        catch { self.plan = []; lost.append("plan") }
        do { self.title = try container.decodeIfPresent(String.self, forKey: .title) }
        catch { self.title = nil; lost.append("title") }
        do {
            self.participants = try container.decodeIfPresent([Participant].self,
                                                              forKey: .participants)
        } catch { self.participants = nil; lost.append("participants") }
        self.unreadableFields = lost
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(version, forKey: .version)
        try container.encode(items, forKey: .items)
        try container.encodeIfPresent(usage, forKey: .usage)
        if !plan.isEmpty {
            try container.encode(plan, forKey: .plan)
        }
        try container.encodeIfPresent(title, forKey: .title)
        try container.encodeIfPresent(participants, forKey: .participants)   // omitted when nil: v1 shape unchanged
    }

    /// Decodes a restored value into a transcript: a ChatTranscript passes through; a JSON object /
    /// string / data is decoded. Returns nil for anything else (an unrelated value), which callers
    /// ignore. Used by both the store's `states["content"]` restore observation and the
    /// `properties.content` pre-populated load.
    public static func decode(from value: Any?) -> ChatTranscript? {
        if let transcript = value as? ChatTranscript {
            return transcript
        }
        let data: Data?
        switch value {
        case let string as String:
            data = string.data(using: .utf8)
        case let raw as Data:
            data = raw
        case let object as [String: Any]:
            data = try? JSONSerialization.data(withJSONObject: object)
        default:
            data = nil
        }
        guard let data else {
            return nil
        }
        return try? JSONDecoder().decode(ChatTranscript.self, from: data)
    }
}

public extension ChatItem {
    /// Decodes ONE item from a host-supplied value, for the append channel. Accepts the same
    /// shapes as `ChatTranscript.decode(from:)` so a host can hand over a JSON string, Data, or a
    /// dictionary without knowing which the bridge it crossed produced.
    static func decode(from value: Any?) -> ChatItem? {
        if let item = value as? ChatItem {
            return item
        }
        let data: Data?
        switch value {
        case let string as String:
            data = string.data(using: .utf8)
        case let raw as Data:
            data = raw
        case let object as [String: Any]:
            data = try? JSONSerialization.data(withJSONObject: object)
        default:
            data = nil
        }
        guard let data else {
            return nil
        }
        return try? JSONDecoder().decode(ChatItem.self, from: data)
    }
}

/// A `reportsConnectionState` transport's link state, emitted via `.connectionStateChanged`.
/// The composer gates on `connected`; every other state disables it (with a one-line banner).
/// A transport that never reports leaves the composer un-gated.
public enum ChatConnectionState: String, Sendable, Equatable, Codable {
    case connecting, connected, reconnecting, offline
}

/// Normalized inbound event a transport emits. Transport-agnostic: the `local`
/// transport emits the message lifecycle (plus the agentic cases in its scripted
/// "agentic" demo style); the ACP transport emits the full vocabulary.
public enum ChatEvent: Sendable {
    case sessionReady(sessionID: String, configOptions: [SessionConfigOption])
    /// A boundary the TRANSPORT noticed rather than the host: today, a prime that came back
    /// condensed, where the digest and the summarizing model are known only to the agent.
    case sessionEvent(SessionEvent)
    case sessionInfo(AgentSessionInfo)                     // agent identity + capabilities, once per established session
    case messageStart(itemID: String, role: ChatRole)
    case messageDelta(itemID: String, text: String)        // streaming token(s)
    case messageEnd(itemID: String, stopReason: String?)   // nil stopReason: the message closed but the
                                                           // turn continues (e.g. a tool call interleaves,
                                                           // ACP); non-nil: the whole turn ended
    case thoughtDelta(itemID: String, text: String)        // streaming reasoning; no explicit start/end,
                                                           // a thought closes when another item begins
    case toolCall(ToolCallModel)                           // a new tool invocation
    case toolCallUpdate(ToolCallUpdate)                    // mutate that card in place
    case permissionRequest(PermissionRequest)              // blocks the gated call until answered
    case permissionResolved(requestID: String)             // an out-of-band resolution of a pending request:
                                                           // another device answered it, or a remote bridge
                                                           // timed it out. The store clears the matching gate;
                                                           // an unknown id is a no-op, never an error - a
                                                           // reattaching client can legitimately hear about a
                                                           // resolution for a request it never saw.
    case plan([PlanEntry])                                 // the agent's WHOLE current plan (replace, not merge)
    case usage(UsageInfo)                                  // token / cost status (latest wins)
    case currentModeChanged(modeID: String)                // ACP current_mode_update; updates the mode option
    case commandsAvailable([SlashCommand])                 // the agent's WHOLE current command set (replace)
    case configOptionsChanged([SessionConfigOption])       // the refreshed option set (a setter's confirmation)
    case image(itemID: String, role: ChatRole, image: ChatImage)   // a standalone image element
    case system(text: String)
    /// A system line for THIS session only: shown like `.system`, never journaled.
    ///
    /// For a notice that describes what just happened rather than what the conversation
    /// contains - "the restore was not summarized, so the model got all of it". Re-derived on
    /// every restore, so persisting it would append a byte-identical line each time and replay
    /// the whole pile on the next load. A host that stores `.entry` events sees nothing here,
    /// which is the point: its journal stays the record of the conversation.
    case transientSystem(text: String)
    case error(message: String, recoverable: Bool)

    /// A resumable transport reporting how far the host's persisted transcript now reaches.
    /// The store forwards it as one `.resumeCheckpoint` host event; it is not a transcript
    /// item and never appears in `items`. Emitted only at turn boundaries, where the
    /// transcript is quiescent, so that "what the host has stored" and "this cursor" describe
    /// the same instant; see the acp-remote plan's section 4.2a.
    ///
    /// REQUIRES `ChatConfiguration.emitsEntryEvents`. A cursor is only meaningful next to the
    /// transcript it was minted against, and `.entry` is how that transcript reaches the host,
    /// so a store that is not emitting entries drops checkpoints instead of handing out a
    /// cursor with nothing to pair it with.
    case resumeCheckpoint(sessionID: String, afterSeq: Int)

    // --- P2P (v2) additive vocabulary. Existing (streaming / agentic) transports never
    //     emit these; the store routes them in P3. All are transport -> store.
    case messageReceived(ChatMessage)                              // insert/UPSERT a complete message by id
    case messageIDConfirmed(localID: String, serverID: String)     // re-key the optimistic item to its server id
    case messageStatusChanged(itemID: String, status: MessageStatus)
    case messageStatusWatermark(status: MessageStatus, upToItemID: String)  // apply to own msgs up to id (ladder rule)
    case reactionsChanged(itemID: String, reactions: [Reaction])  // full replacement
    case messageEdited(itemID: String, newText: String, editedAt: String)
    case messageDeleted(itemID: String)                           // sets tombstone
    case memberEvent(MemberEvent)                                 // append a roster-change item
    case callEvent(CallEvent)                                     // append a call-log item
    case fileAdded(ChatFile)                                      // insert/upsert a file item by id
    case fileProgress(itemID: String, progress: Double?, transferStatus: FileTransferStatus)
    case typingChanged(isTyping: Bool, senderID: String?, senderName: String?)
    case participantsChanged([Participant])                       // update the roster
    case historyPage(items: [ChatItem], hasMore: Bool)           // OLDER items (chronological), prepended
    case connectionStateChanged(ChatConnectionState)             // link state; the composer gates on `connected`
}

/// Normalized outbound command the UI hands a transport. A plain-text user turn,
/// a cancel, the answer to a pending permission request (`optionID` nil means
/// the request was dismissed / the turn cancelled - ACP's `cancelled` outcome),
/// and a session-option change from the status-line menus (mode / model / ...).
/// Attachments (ContentBlock[]) arrive with later milestones.
public enum ChatCommand: Sendable {
    case prompt(text: String)
    case cancel
    case permissionResponse(requestID: String, optionID: String?)
    case setConfigOption(optionID: String, value: String)

    // --- P2P (v2) additive vocabulary. `.prompt` cannot gain an optional associated value
    //     source-compatibly (it would break every `case .prompt(let text)` site), so the
    //     reply-carrying send is a NEW case; a transport that does not support a capability
    //     ignores the corresponding command (the store gates emission on `capabilities`).
    //     All are store -> transport.
    case sendMessage(text: String, replyTo: String?, localID: String)   // a P2P send, optionally quoting a
                                                       // message. `localID` is the store's optimistic id
                                                       // (always present) - the stable handle a
                                                       // `messageIdentity` transport addresses the in-flight
                                                       // message by until it emits `.messageIDConfirmed`; a
                                                       // transport that does no reconciliation ignores it.
    case toggleReaction(itemID: String, emoji: String, add: Bool)
    case editMessage(itemID: String, newText: String)
    case deleteMessage(itemID: String)
    case resendMessage(itemID: String)                 // retry a `failed` message
    case markRead(upToItemID: String)
    case loadEarlier(beforeItemID: String, limit: Int)
    case setTyping(isTyping: Bool)
    case cancelFileTransfer(itemID: String)
}
