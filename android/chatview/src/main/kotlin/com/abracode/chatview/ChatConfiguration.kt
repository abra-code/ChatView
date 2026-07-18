package com.abracode.chatview

// Port of Sources/ChatView/ChatConfiguration.swift.
//
// The chat component's typed configuration: appearance, role styling, the composer (input), the agentic surfaces
// routing, person-to-person features, and the read-only / restore seam. Hosts construct it directly (memberwise,
// all defaulted) or from a JSON object via fromJson() - the shape the ActionUI Chat element's `properties` block
// carries.
//
// Host-event enablement (attachEnabled, emitsEntryEvents) is set by the host, not parsed from the JSON - in the
// ActionUI add-on those derive from the presence of attachActionID / entryActionID.
//
// The component's OPERATIONAL settings (`protocol` + `transport`) are NOT here: a host injects them at runtime
// through its ChatContentSource's config channel (the security boundary - a document is data and must not name what
// the host executes or connects to).

import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.booleanOrNull
import kotlinx.serialization.json.intOrNull

class ChatConfiguration(
    val alignment: Alignment = Alignment.SINGLE,
    val showRoleLabels: Boolean = true,
    val theme: String = "auto",
    val roles: Map<String, RoleStyle> = defaultRoles,
    showTimestamps: Boolean? = null,
    val showAvatars: Boolean = false,
    val showDeliveryStatus: Boolean = true,
    val features: Features = Features(),
    val inputEnabled: Boolean = true,
    val placeholder: String = "Message",
    val submitOn: SubmitPolicy = SubmitPolicy.RETURN,
    val surfaces: Surfaces = Surfaces(),
    val readOnly: Boolean = false,
    val initialContentRaw: Any? = null,
    // Host-set fields (not parsed from the dictionary).
    var attachEnabled: Boolean = false,
    var emitsEntryEvents: Boolean = false,
) {
    /**
     * Transcript layout. `single` (default): every message leading / full-width, parties distinguished by tint +
     * label. `dual`: incoming leading, outgoing trailing - the messaging-app layout.
     */
    enum class Alignment(val wire: String) {
        SINGLE("single"),
        DUAL("dual");

        companion object {
            fun fromWire(value: String?): Alignment? = entries.firstOrNull { it.wire == value }
        }
    }

    /**
     * Composer submit policy. `return`: Return submits. `modifierReturn`: Return inserts a newline, modifier+Return
     * submits. `shiftReturnNewline`: treated like `return`.
     */
    enum class SubmitPolicy(val wire: String) {
        RETURN("return"),
        MODIFIER_RETURN("modifier-return"),
        SHIFT_RETURN_NEWLINE("shift-return-newline");

        companion object {
            fun fromWire(value: String?): SubmitPolicy? = entries.firstOrNull { it.wire == value }
        }
    }

    /** Per-role appearance. `side` drives layout only in `dual` alignment; in `single` only `label` and `tint` matter. */
    data class RoleStyle(
        val side: String,   // "leading" | "trailing" | "center"
        val label: String,
        val tint: String,   // a color token, e.g. "accent", "secondary"
    )

    /**
     * How an agentic surface presents. `inline`: expanded. `collapsed`: folded. `hidden`: dropped. `panel`: a side
     * region (parses today, renders inline).
     */
    enum class SurfaceMode(val wire: String) {
        INLINE("inline"),
        COLLAPSED("collapsed"),
        HIDDEN("hidden"),
        PANEL("panel");

        companion object {
            fun fromWire(value: String?): SurfaceMode? = entries.firstOrNull { it.wire == value }
        }
    }

    /** Routing for the agentic stream. Only transports that emit these events are affected. */
    data class Surfaces(
        val toolCalls: SurfaceMode = SurfaceMode.INLINE,
        val thoughts: SurfaceMode = SurfaceMode.COLLAPSED,
        val plan: SurfaceMode = SurfaceMode.PANEL,
        val diffs: SurfaceMode = SurfaceMode.INLINE,
    )

    /**
     * Which person-to-person / group (v2) conversation affordances the HOST enables. All default false (opt-in).
     * Effective availability is this AND the transport's matching `capabilities` flag.
     */
    data class Features(
        val reactions: Boolean = false,
        val editing: Boolean = false,
        val deletion: Boolean = false,
        val replies: Boolean = false,
    )

    // P2P (v2) appearance. Timestamps default ON only in dual alignment, OFF in single, so a v1 (single)
    // configuration is pixel-identical while a P2P (dual) one reads like a messaging app without opting in.
    val showTimestamps: Boolean = showTimestamps ?: (alignment == Alignment.DUAL)

    /** Role styling resolved with the defaults, matching Swift's `style(for:)`. */
    fun style(role: ChatRole): RoleStyle =
        roles[role.wire] ?: defaultRoles[role.wire] ?: RoleStyle(side = "leading", label = "", tint = "secondary")

    companion object {
        /** Default role styling, applied when `roles` (or a given role) is absent. */
        val defaultRoles: Map<String, RoleStyle> = mapOf(
            "local" to RoleStyle(side = "trailing", label = "You", tint = "accent"),
            "agent" to RoleStyle(side = "leading", label = "Agent", tint = "secondary"),
            "remote" to RoleStyle(side = "leading", label = "", tint = "secondary"),
            "system" to RoleStyle(side = "center", label = "", tint = "secondary"),
        )

        /** Parses the ActionUI `properties` block (kotlinx JsonObject), mirroring the Swift init(dictionary:logger:). */
        fun fromJson(dictionary: JsonObject, logger: ChatLogger): ChatConfiguration {
            val appearance = dictionary.objectOrNull("appearance")
            val parsedAlignment = Alignment.fromWire(appearance.stringOrNull("alignment")) ?: Alignment.SINGLE
            val showRoleLabels = appearance.boolOrNull("showRoleLabels") ?: true
            val theme = appearance.stringOrNull("theme") ?: "auto"
            // Timestamps default ON in dual alignment, OFF in single.
            val showTimestamps = appearance.boolOrNull("showTimestamps") ?: (parsedAlignment == Alignment.DUAL)
            val showAvatars = appearance.boolOrNull("showAvatars") ?: false
            val showDeliveryStatus = appearance.boolOrNull("showDeliveryStatus") ?: true

            val roles = parseRoles(dictionary.objectOrNull("roles"))

            val featuresRaw = dictionary.objectOrNull("features")
            val features = Features(
                reactions = featuresRaw.boolOrNull("reactions") ?: false,
                editing = featuresRaw.boolOrNull("editing") ?: false,
                deletion = featuresRaw.boolOrNull("deletion") ?: false,
                replies = featuresRaw.boolOrNull("replies") ?: false,
            )

            val input = dictionary.objectOrNull("input")
            val inputEnabled = input.boolOrNull("enabled") ?: true
            val placeholder = input.stringOrNull("placeholder") ?: "Message"
            val submitOn = SubmitPolicy.fromWire(input.stringOrNull("submitOn")) ?: SubmitPolicy.RETURN

            val surfacesRaw = dictionary.objectOrNull("surfaces")
            var planMode = SurfaceMode.fromWire(surfacesRaw.stringOrNull("plan")) ?: SurfaceMode.PANEL
            if (planMode == SurfaceMode.INLINE) {
                logger.log(
                    "Chat surfaces.plan 'inline' is not a plan presentation (the plan is a pinned status surface); rendering as panel",
                    ChatLogLevel.VERBOSE,
                )
                planMode = SurfaceMode.PANEL
            }
            var diffsMode = SurfaceMode.fromWire(surfacesRaw.stringOrNull("diffs")) ?: SurfaceMode.INLINE
            if (diffsMode == SurfaceMode.COLLAPSED || diffsMode == SurfaceMode.PANEL) {
                logger.log(
                    "Chat surfaces.diffs '${diffsMode.wire}' renders inline (the tool card's fold covers collapsing; a diff panel is a later surface)",
                    ChatLogLevel.VERBOSE,
                )
                diffsMode = SurfaceMode.INLINE
            }
            val surfaces = Surfaces(
                toolCalls = SurfaceMode.fromWire(surfacesRaw.stringOrNull("toolCalls")) ?: SurfaceMode.INLINE,
                thoughts = SurfaceMode.fromWire(surfacesRaw.stringOrNull("thoughts")) ?: SurfaceMode.COLLAPSED,
                plan = planMode,
                diffs = diffsMode,
            )

            val readOnly = dictionary.boolOrNull("readOnly") ?: false
            // A pre-populated transcript in `content` - a preview / testing convenience only. Kept RAW so it is not
            // re-decoded on every view build; the store decodes it once at start.
            val initialContentRaw: Any? = dictionary["content"]

            return ChatConfiguration(
                alignment = parsedAlignment,
                showRoleLabels = showRoleLabels,
                theme = theme,
                roles = roles,
                showTimestamps = showTimestamps,
                showAvatars = showAvatars,
                showDeliveryStatus = showDeliveryStatus,
                features = features,
                inputEnabled = inputEnabled,
                placeholder = placeholder,
                submitOn = submitOn,
                surfaces = surfaces,
                readOnly = readOnly,
                initialContentRaw = initialContentRaw,
            )
        }

        private fun parseRoles(raw: JsonObject?): Map<String, RoleStyle> {
            val resolved = defaultRoles.toMutableMap()
            if (raw == null) {
                return resolved
            }
            for ((key, value) in raw) {
                val entry = value as? JsonObject ?: continue
                val base = resolved[key] ?: RoleStyle(side = "leading", label = "", tint = "secondary")
                resolved[key] = RoleStyle(
                    side = entry.stringOrNull("side") ?: base.side,
                    label = entry.stringOrNull("label") ?: base.label,
                    tint = entry.stringOrNull("tint") ?: base.tint,
                )
            }
            return resolved
        }

        // JSON extraction helpers mirroring the Swift `as? String` / `as? Bool` casts on a JSONSerialization value.
        private fun JsonObject?.objectOrNull(key: String): JsonObject? = this?.get(key) as? JsonObject

        // A number in a string slot yields null (matches `as? String`, which rejects an NSNumber).
        private fun JsonObject?.stringOrNull(key: String): String? =
            (this?.get(key) as? JsonPrimitive)?.takeIf { it.isString }?.content

        // A JSON string "true" is NOT a boolean (Swift's `as? Bool` rejects it), so guard on !isString. But Swift
        // parses JSON via JSONSerialization, where `NSNumber as? Bool` succeeds for exactly 0 / 1 (the Foundation
        // bridging quirk): a JSON number 0 / 1 in a bool slot casts to false / true. Match that so a host that spells
        // a flag as 0 / 1 resolves identically on both platforms.
        private fun JsonObject?.boolOrNull(key: String): Boolean? {
            val primitive = this?.get(key) as? JsonPrimitive ?: return null
            if (primitive.isString) return null
            primitive.booleanOrNull?.let { return it }
            return when (primitive.intOrNull) {
                0 -> false
                1 -> true
                else -> null
            }
        }
    }
}

private val ChatRole.wire: String
    get() = when (this) {
        ChatRole.LOCAL -> "local"
        ChatRole.AGENT -> "agent"
        ChatRole.REMOTE -> "remote"
        ChatRole.SYSTEM -> "system"
    }
