// Sources/ChatView/ChatConfiguration.swift
//
// The chat component's typed configuration: appearance, role styling, the composer
// (input), the agentic surfaces routing, person-to-person features, and the read-only /
// restore seam. Hosts construct it directly (memberwise, all defaulted) or from a
// JSON-ish dictionary via init(dictionary:logger:) - the shape the ActionUI Chat
// element's `properties` block carries.
//
// Host-event enablement (attachEnabled, emitsEntryEvents) is set by the host, not parsed
// from the dictionary - in the ActionUI add-on those derive from the presence of
// attachActionID / entryActionID.
//
// The component's OPERATIONAL settings (`protocol` + `transport`) are NOT here: a host
// injects them at runtime through its ChatContentSource's config channel (see ChatStore),
// where the transport is built once the config is viable. Keeping the wire protocol and
// the (subprocess-spawning) transport command out of static UI declarations is the
// security boundary - a document is data and must not name what the host executes or
// connects to.

import Foundation

public struct ChatConfiguration {

    /// Transcript layout. `single` (default): every message leading / full-width,
    /// parties distinguished by tint + label. `dual`: incoming leading, outgoing
    /// trailing - the messaging-app layout for person-to-person / group chat.
    public enum Alignment: String, Sendable {
        case single
        case dual
    }

    /// Composer submit policy - the Cmd+Return gap, solved inside the component.
    /// `return`: single-line field, Return submits. `modifierReturn`: multiline field,
    /// Return inserts a newline, Cmd+Return submits. `shiftReturnNewline`: treated like
    /// `return` (Shift+Return newline is a later refinement).
    public enum SubmitPolicy: String, Sendable {
        case `return`
        case modifierReturn = "modifier-return"
        case shiftReturnNewline = "shift-return-newline"
    }

    /// Per-role appearance. `side` drives layout only in `dual` alignment; in `single`
    /// only `label` and `tint` are used.
    public struct RoleStyle: Sendable {
        public let side: String      // "leading" | "trailing" | "center"
        public let label: String
        public let tint: String      // a color token, e.g. "accent", "secondary"

        public init(side: String, label: String, tint: String) {
            self.side = side
            self.label = label
            self.tint = tint
        }
    }

    /// How an agentic surface presents. `inline`: in the transcript, expanded.
    /// `collapsed`: in the transcript, folded behind a disclosure. `hidden`: dropped.
    /// `panel` (a side region) is a later presentation; it parses today and renders inline.
    public enum SurfaceMode: String, Sendable {
        case inline
        case collapsed
        case hidden
        case panel
    }

    /// Routing for the agentic stream. Only transports that emit these events are
    /// affected; a plain chat transport never produces them.
    public struct Surfaces: Sendable {
        public let toolCalls: SurfaceMode    // default inline
        public let thoughts: SurfaceMode     // default collapsed
        public let plan: SurfaceMode         // default panel (a pinned region ABOVE the transcript -
                                             // the plan is a status surface, never interleaved as chat;
                                             // "inline" is coerced to panel with a note)
        public let diffs: SurfaceMode        // default inline (rendered by the DiffView component inside
                                             // the tool card's detail); hidden drops them; collapsed /
                                             // panel are coerced to inline with a note (the card's fold
                                             // already covers collapsing; a side panel is a later surface)

        public init(toolCalls: SurfaceMode = .inline, thoughts: SurfaceMode = .collapsed,
                    plan: SurfaceMode = .panel, diffs: SurfaceMode = .inline) {
            self.toolCalls = toolCalls
            self.thoughts = thoughts
            self.plan = plan
            self.diffs = diffs
        }
    }

    /// Which person-to-person / group (v2) conversation affordances the HOST enables.
    /// All default false (opt-in). Effective availability of an affordance is this AND the
    /// transport's matching `capabilities` flag - a host can request a feature the
    /// active transport does not back, and it simply does not appear.
    public struct Features: Sendable {
        public let reactions: Bool       // emoji reactions (quick-row + chips + toggle)
        public let editing: Bool         // edit own messages
        public let deletion: Bool        // delete own messages (tombstone)
        public let replies: Bool         // reply / quote a message

        public init(reactions: Bool = false, editing: Bool = false,
                    deletion: Bool = false, replies: Bool = false) {
            self.reactions = reactions
            self.editing = editing
            self.deletion = deletion
            self.replies = replies
        }
    }

    public let alignment: Alignment
    public let showRoleLabels: Bool
    public let theme: String                 // "auto" | "light" | "dark"
    public let roles: [String: RoleStyle]

    // P2P (v2) appearance. Defaults keep a v1 (single-alignment) configuration pixel-identical:
    // timestamps default ON only in dual alignment, OFF in single; avatars are opt-in;
    // delivery status defaults ON but renders only on messages that carry a `status` (v1
    // messages never do). Each renders only on items that actually carry the datum.
    public let showTimestamps: Bool
    public let showAvatars: Bool
    public let showDeliveryStatus: Bool

    // P2P (v2) conversation affordances the host enables (gated further by transport capabilities).
    public let features: Features

    public let inputEnabled: Bool
    public let placeholder: String
    public let submitOn: SubmitPolicy

    public let surfaces: Surfaces

    // Session transcript seam.
    public let readOnly: Bool           // history-viewer mode: no composer / menus, no transport start
    public let initialContentRaw: Any?  // an initial transcript verbatim (a preview / testing convenience,
                                        // NOT the production restore path); the store decodes it ONCE at start

    /// The composer shows the attach (paperclip) button and the component emits
    /// ChatHostEvent.attach when it is tapped. Default false. (In the ActionUI add-on
    /// this derives from attachActionID being configured.)
    public var attachEnabled: Bool = false

    /// The component emits ChatHostEvent.entry (one JSON envelope per finalized
    /// transcript entry) for incremental persistence. Default false. (In the ActionUI
    /// add-on this derives from entryActionID being configured.)
    public var emitsEntryEvents: Bool = false

    // MARK: - Defaults

    /// Default role styling, applied when `roles` (or a given role) is absent.
    public static let defaultRoles: [String: RoleStyle] = [
        "local":  RoleStyle(side: "trailing", label: "You",   tint: "accent"),
        "agent":  RoleStyle(side: "leading",  label: "Agent", tint: "secondary"),
        "remote": RoleStyle(side: "leading",  label: "",      tint: "secondary"),
        "system": RoleStyle(side: "center",   label: "",      tint: "secondary"),
    ]

    // MARK: - Memberwise (programmatic hosts)

    /// Programmatic construction with today's defaults. `showTimestamps` nil resolves to
    /// the alignment-dependent default (ON in dual, OFF in single), matching the
    /// dictionary parse.
    public init(alignment: Alignment = .single,
                showRoleLabels: Bool = true,
                theme: String = "auto",
                roles: [String: RoleStyle] = ChatConfiguration.defaultRoles,
                showTimestamps: Bool? = nil,
                showAvatars: Bool = false,
                showDeliveryStatus: Bool = true,
                features: Features = Features(),
                inputEnabled: Bool = true,
                placeholder: String = "Message",
                submitOn: SubmitPolicy = .return,
                surfaces: Surfaces = Surfaces(),
                readOnly: Bool = false,
                initialContent: Any? = nil,
                attachEnabled: Bool = false,
                emitsEntryEvents: Bool = false) {
        self.alignment = alignment
        self.showRoleLabels = showRoleLabels
        self.theme = theme
        self.roles = roles
        self.showTimestamps = showTimestamps ?? (alignment == .dual)
        self.showAvatars = showAvatars
        self.showDeliveryStatus = showDeliveryStatus
        self.features = features
        self.inputEnabled = inputEnabled
        self.placeholder = placeholder
        self.submitOn = submitOn
        self.surfaces = surfaces
        self.readOnly = readOnly
        self.initialContentRaw = initialContent
        self.attachEnabled = attachEnabled
        self.emitsEntryEvents = emitsEntryEvents
    }

    // MARK: - Parse

    public init(dictionary: [String: Any], logger: any ChatLogger) {
        let appearance = dictionary["appearance"] as? [String: Any] ?? [:]
        let parsedAlignment = (appearance["alignment"] as? String).flatMap(Alignment.init(rawValue:)) ?? .single
        alignment = parsedAlignment
        showRoleLabels = (appearance["showRoleLabels"] as? Bool) ?? true
        theme = (appearance["theme"] as? String) ?? "auto"
        // Timestamps default ON in dual alignment, OFF in single - so a v1 (single) configuration is
        // pixel-identical while a P2P (dual) one reads like a messaging app without opting in.
        showTimestamps = (appearance["showTimestamps"] as? Bool) ?? (parsedAlignment == .dual)
        showAvatars = (appearance["showAvatars"] as? Bool) ?? false
        showDeliveryStatus = (appearance["showDeliveryStatus"] as? Bool) ?? true

        roles = Self.parseRoles(dictionary["roles"] as? [String: Any])

        let featuresRaw = dictionary["features"] as? [String: Any] ?? [:]
        features = Features(
            reactions: (featuresRaw["reactions"] as? Bool) ?? false,
            editing: (featuresRaw["editing"] as? Bool) ?? false,
            deletion: (featuresRaw["deletion"] as? Bool) ?? false,
            replies: (featuresRaw["replies"] as? Bool) ?? false
        )

        let input = dictionary["input"] as? [String: Any] ?? [:]
        inputEnabled = (input["enabled"] as? Bool) ?? true
        placeholder = (input["placeholder"] as? String) ?? "Message"
        submitOn = (input["submitOn"] as? String).flatMap(SubmitPolicy.init(rawValue:)) ?? .return

        let surfacesRaw = dictionary["surfaces"] as? [String: Any] ?? [:]
        var planMode = (surfacesRaw["plan"] as? String).flatMap(SurfaceMode.init(rawValue:)) ?? .panel
        if planMode == .inline {
            logger.log("Chat surfaces.plan 'inline' is not a plan presentation (the plan is a pinned status surface); rendering as panel", .verbose)
            planMode = .panel
        }
        var diffsMode = (surfacesRaw["diffs"] as? String).flatMap(SurfaceMode.init(rawValue:)) ?? .inline
        if diffsMode == .collapsed || diffsMode == .panel {
            logger.log("Chat surfaces.diffs '\(diffsMode.rawValue)' renders inline (the tool card's fold covers collapsing; a diff panel is a later surface)", .verbose)
            diffsMode = .inline
        }
        surfaces = Surfaces(
            toolCalls: (surfacesRaw["toolCalls"] as? String).flatMap(SurfaceMode.init(rawValue:)) ?? .inline,
            thoughts: (surfacesRaw["thoughts"] as? String).flatMap(SurfaceMode.init(rawValue:)) ?? .collapsed,
            plan: planMode,
            diffs: diffsMode
        )

        readOnly = (dictionary["readOnly"] as? Bool) ?? false
        // A pre-populated transcript in `content` - a preview / testing convenience only.
        // The production restore path is the runtime content channel (ChatContentSource),
        // which the store observes separately; a static UI declaration should not carry
        // session data. Kept RAW here so it is not re-decoded on every view build; the
        // store decodes it once at start.
        initialContentRaw = dictionary["content"]
    }

    private static func parseRoles(_ raw: [String: Any]?) -> [String: RoleStyle] {
        var resolved = defaultRoles
        guard let raw else {
            return resolved
        }
        for (key, value) in raw {
            guard let entry = value as? [String: Any] else {
                continue
            }
            let base = resolved[key] ?? RoleStyle(side: "leading", label: "", tint: "secondary")
            resolved[key] = RoleStyle(
                side: entry["side"] as? String ?? base.side,
                label: entry["label"] as? String ?? base.label,
                tint: entry["tint"] as? String ?? base.tint
            )
        }
        return resolved
    }

    // MARK: - Lookups used by the view

    public func style(for role: ChatRole) -> RoleStyle {
        roles[role.rawValue] ?? Self.defaultRoles[role.rawValue]
            ?? RoleStyle(side: "leading", label: "", tint: "secondary")
    }
}
