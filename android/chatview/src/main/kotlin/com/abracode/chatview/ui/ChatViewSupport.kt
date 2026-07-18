package com.abracode.chatview.ui

// A6 Compose transcript view - shared support: pure text helpers, tint/icon resolution, the per-row context and
// action bundles the row composables consume, and the layout-metric constants. Kept UI-light (only ChatTint /
// icon lookups touch Compose) so the value logic stays easy to reason about. Everything the transcript view needs
// that is NOT a row composable lives here.

import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Build
import androidx.compose.material.icons.filled.CheckCircle
import androidx.compose.material.icons.filled.Delete
import androidx.compose.material.icons.filled.Description
import androidx.compose.material.icons.filled.Edit
import androidx.compose.material.icons.filled.Error
import androidx.compose.material.icons.filled.Folder
import androidx.compose.material.icons.filled.Psychology
import androidx.compose.material.icons.filled.Public
import androidx.compose.material.icons.filled.Schedule
import androidx.compose.material.icons.filled.Search
import androidx.compose.material.icons.filled.Terminal
import androidx.compose.material3.MaterialTheme
import androidx.compose.runtime.Composable
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import com.abracode.chatview.CallEvent
import com.abracode.chatview.ChatConfiguration
import com.abracode.chatview.ChatItem
import com.abracode.chatview.ChatRole
import com.abracode.chatview.ChatTimestamp
import com.abracode.chatview.ChatTranscriptLayout
import com.abracode.chatview.MemberEvent
import com.abracode.chatview.Participant
import com.abracode.chatview.ToolCallModel
import java.time.Instant
import java.time.LocalDate
import java.time.ZoneId
import java.time.format.DateTimeFormatter
import java.time.format.FormatStyle

// --- ASCII-safe glyphs built from code points (this source is ASCII-only). ------------------------------------

/** U+00B7 MIDDLE DOT, the caption separator. Built from its code point to keep this file ASCII-only. */
internal val MIDDLE_DOT: String = String(Character.toChars(0x00B7))

/**
 * The quick-reaction strip shown at the top of a message's context menu. Each emoji is assembled from its code
 * points so the source stays ASCII: thumbs-up, red-heart (base + VS-16), tears-of-joy, surprised, crying,
 * folded-hands.
 */
internal val quickReactions: List<String> = listOf(
    String(Character.toChars(0x1F44D)),
    buildString { append(Character.toChars(0x2764)); append(Character.toChars(0xFE0F)) },
    String(Character.toChars(0x1F602)),
    String(Character.toChars(0x1F62E)),
    String(Character.toChars(0x1F622)),
    String(Character.toChars(0x1F64F)),
)

// --- Layout metric constants (Section 9). ---------------------------------------------------------------------

/** The bubble corner radius. */
internal val BubbleShape = RoundedCornerShape(14.dp)

// --- Pure text helpers. ---------------------------------------------------------------------------------------

private val shortTimeFormatter: DateTimeFormatter =
    DateTimeFormatter.ofLocalizedTime(FormatStyle.SHORT).withZone(ZoneId.systemDefault())

private val mediumDateFormatter: DateTimeFormatter =
    DateTimeFormatter.ofLocalizedDate(FormatStyle.MEDIUM)

/** A short local clock time ("3:04 PM") for a caption, or null when the value is absent / unparseable. */
internal fun shortTime(timestamp: String?): String? {
    val instant = ChatTimestamp.parse(timestamp) ?: return null
    return shortTimeFormatter.format(instant)
}

/** A "m:ss" duration label from a whole-seconds count. */
internal fun durationText(seconds: Int): String = "%d:%02d".format(seconds / 60, seconds % 60)

/** The day-separator label for a timestamp: "Today" / "Yesterday" / a localized medium date. */
internal fun daySeparatorLabel(instant: Instant, zone: ZoneId = ZoneId.systemDefault()): String {
    val day = instant.atZone(zone).toLocalDate()
    val today = LocalDate.now(zone)
    return when (day) {
        today -> "Today"
        today.minusDays(1) -> "Yesterday"
        else -> mediumDateFormatter.format(day)
    }
}

/** The centered-caption text for a membership / roster change. */
internal fun memberEventText(event: MemberEvent): String {
    val subject = event.subjectName ?: "Someone"
    val actor = event.actorName ?: "Someone"
    return when (event.kind) {
        MemberEvent.Kind.JOINED -> "$subject joined"
        MemberEvent.Kind.LEFT -> "$subject left"
        MemberEvent.Kind.INVITED -> "$actor invited $subject"
        MemberEvent.Kind.REMOVED -> "$actor removed $subject"
        MemberEvent.Kind.ROLE_CHANGED -> "$subject is now ${event.detail ?: "updated"}"
        MemberEvent.Kind.RENAMED -> "$actor changed the name to ${event.detail ?: "a new name"}"
    }
}

/** The centered-caption text for a call-log entry. */
internal fun callEventText(event: CallEvent): String {
    val kindWord = if (event.isVideo == true) "video call" else "call"
    return when (event.kind) {
        CallEvent.Kind.MISSED_INCOMING -> "Missed $kindWord"
        CallEvent.Kind.MISSED_OUTGOING -> "Unanswered $kindWord"
        CallEvent.Kind.DECLINED -> "Declined $kindWord"
        CallEvent.Kind.COMPLETED -> {
            val capitalized = if (event.isVideo == true) "Video call" else "Call"
            val seconds = event.durationSeconds
            if (seconds != null) "$capitalized $MIDDLE_DOT ${durationText(seconds)}" else capitalized
        }
    }
}

/** Whether a call event is a missed / declined one (rendered red). */
internal fun CallEvent.isNegative(): Boolean =
    kind == CallEvent.Kind.MISSED_INCOMING || kind == CallEvent.Kind.MISSED_OUTGOING || kind == CallEvent.Kind.DECLINED

// --- Tint + icon resolution. ----------------------------------------------------------------------------------

/** Resolves a role-style color token (Section 9) against the current color scheme, with fixed named colors. */
object ChatTint {
    @Composable
    fun color(token: String): Color = when (token.lowercase()) {
        "accent" -> MaterialTheme.colorScheme.primary
        "primary" -> MaterialTheme.colorScheme.onSurface
        "secondary", "tertiary" -> MaterialTheme.colorScheme.onSurfaceVariant
        "red" -> MaterialTheme.colorScheme.error
        "blue" -> Color(0xFF3B82F6)
        "green" -> Color(0xFF22C55E)
        "orange" -> Color(0xFFF97316)
        "purple" -> Color(0xFF8B5CF6)
        "pink" -> Color(0xFFEC4899)
        "teal" -> Color(0xFF14B8A6)
        "indigo" -> Color(0xFF6366F1)
        "gray", "grey" -> Color(0xFF9CA3AF)
        else -> MaterialTheme.colorScheme.onSurfaceVariant
    }
}

/** Icon lookups for the Tier-2 tool-call / thought placeholder rows. */
object ChatIcons {
    fun forToolKind(kind: ToolCallModel.Kind): ImageVector = when (kind) {
        ToolCallModel.Kind.READ -> Icons.Filled.Description
        ToolCallModel.Kind.EDIT -> Icons.Filled.Edit
        ToolCallModel.Kind.DELETE -> Icons.Filled.Delete
        ToolCallModel.Kind.MOVE -> Icons.Filled.Folder
        ToolCallModel.Kind.SEARCH -> Icons.Filled.Search
        ToolCallModel.Kind.EXECUTE -> Icons.Filled.Terminal
        ToolCallModel.Kind.THINK -> Icons.Filled.Psychology
        ToolCallModel.Kind.FETCH -> Icons.Filled.Public
        ToolCallModel.Kind.OTHER -> Icons.Filled.Build
    }

    fun forToolStatus(status: ToolCallModel.Status): ImageVector = when (status) {
        ToolCallModel.Status.PENDING, ToolCallModel.Status.IN_PROGRESS -> Icons.Filled.Schedule
        ToolCallModel.Status.COMPLETED -> Icons.Filled.CheckCircle
        ToolCallModel.Status.FAILED -> Icons.Filled.Error
    }
}

// --- Sender / self / grouping derivation (used by ChatView to build layout Input + row contexts). -------------

private fun ChatRole.wire(): String = when (this) {
    ChatRole.LOCAL -> "local"
    ChatRole.AGENT -> "agent"
    ChatRole.REMOTE -> "remote"
    ChatRole.SYSTEM -> "system"
}

/** True when the item's author is the local user (role local, or a senderID that resolves to an isSelf participant). */
internal fun isSelfAuthor(role: ChatRole, senderID: String?, participants: List<Participant>): Boolean {
    if (role == ChatRole.LOCAL) return true
    val id = senderID ?: return false
    return participants.firstOrNull { it.id == id }?.isSelf == true
}

private fun senderKey(isSelf: Boolean, senderID: String?, role: ChatRole): String =
    if (isSelf) "self" else senderID ?: role.wire()

private fun participantAvatar(senderID: String?, participants: List<Participant>): String? {
    val id = senderID ?: return null
    return participants.firstOrNull { it.id == id }?.avatarURL
}

internal fun resolveName(
    senderName: String?,
    senderID: String?,
    role: ChatRole,
    participants: List<Participant>,
    config: ChatConfiguration,
): String? {
    senderName?.takeIf { it.isNotEmpty() }?.let { return it }
    senderID?.let { id -> participants.firstOrNull { it.id == id }?.name?.takeIf { it.isNotEmpty() }?.let { return it } }
    return config.style(role).label.takeIf { it.isNotEmpty() }
}

/**
 * A transcript item reduced to just the run/day-grouping inputs, WITHOUT parsing the timestamp (the raw wire string
 * is kept). Grouping never depends on message text, so a list of these is the stable memo key for the layout pass -
 * a 20 Hz streaming text delta leaves every signature unchanged and reuses the cached run/day layout instead of
 * re-parsing every timestamp and re-grouping the whole transcript each frame.
 */
internal data class GroupingSignature(val senderKey: String, val groupable: Boolean, val timestampRaw: String?)

/** The grouping signature for an item. Images group like messages (Swift ChatView.swift:476-477). */
internal fun groupingSignature(item: ChatItem, participants: List<Participant>): GroupingSignature =
    when (item) {
        is ChatItem.Message -> {
            val m = item.message
            GroupingSignature(senderKey(isSelfAuthor(m.role, m.senderID, participants), m.senderID, m.role), true, m.timestamp)
        }
        is ChatItem.File -> {
            val f = item.file
            GroupingSignature(senderKey(isSelfAuthor(f.role, f.senderID, participants), f.senderID, f.role), true, f.timestamp)
        }
        is ChatItem.Image ->
            GroupingSignature(senderKey(isSelfAuthor(item.role, null, participants), null, item.role), true, null)
        is ChatItem.MemberEventItem -> GroupingSignature("system", false, item.event.timestamp)
        is ChatItem.CallEventItem -> GroupingSignature("system", false, item.event.timestamp)
        is ChatItem.System -> GroupingSignature("system", false, null)
        is ChatItem.Error -> GroupingSignature("system", false, null)
        is ChatItem.Thought -> GroupingSignature("agent", false, null)
        is ChatItem.ToolCall -> GroupingSignature("agent", false, null)
    }

/** The layout core's Input for a signature (parses the timestamp here, inside the memoized layout pass). */
internal fun GroupingSignature.toLayoutInput(): ChatTranscriptLayout.Input =
    ChatTranscriptLayout.Input(senderKey, groupable, ChatTimestamp.parse(timestampRaw))

/** Builds the per-row rendering context: self side, sender label, avatar, and parsed timestamp for day separators. */
internal fun buildRowContext(
    item: ChatItem,
    info: ChatTranscriptLayout.Info,
    participants: List<Participant>,
    config: ChatConfiguration,
): DualRowContext = when (item) {
    is ChatItem.Message -> {
        val m = item.message
        DualRowContext(
            id = item.id, item = item, info = info,
            isSelf = isSelfAuthor(m.role, m.senderID, participants),
            senderName = resolveName(m.senderName, m.senderID, m.role, participants, config),
            avatarURL = m.avatarURL ?: participantAvatar(m.senderID, participants),
            timestamp = ChatTimestamp.parse(m.timestamp),
        )
    }
    is ChatItem.File -> {
        val f = item.file
        DualRowContext(
            id = item.id, item = item, info = info,
            isSelf = isSelfAuthor(f.role, f.senderID, participants),
            senderName = resolveName(f.senderName, f.senderID, f.role, participants, config),
            avatarURL = participantAvatar(f.senderID, participants),
            timestamp = ChatTimestamp.parse(f.timestamp),
        )
    }
    is ChatItem.Image -> DualRowContext(
        id = item.id, item = item, info = info,
        isSelf = isSelfAuthor(item.role, null, participants),
        senderName = null, avatarURL = null, timestamp = null,
    )
    is ChatItem.MemberEventItem -> DualRowContext(
        id = item.id, item = item, info = info, isSelf = false,
        senderName = null, avatarURL = null, timestamp = ChatTimestamp.parse(item.event.timestamp),
    )
    is ChatItem.CallEventItem -> DualRowContext(
        id = item.id, item = item, info = info, isSelf = false,
        senderName = null, avatarURL = null, timestamp = ChatTimestamp.parse(item.event.timestamp),
    )
    else -> DualRowContext(id = item.id, item = item, info = info, isSelf = false, senderName = null, avatarURL = null, timestamp = null)
}

// --- Row context + actions bundles. ---------------------------------------------------------------------------

/** Everything a row composable needs about one item's placement and identity. */
internal data class DualRowContext(
    val id: String,
    val item: ChatItem,
    val info: ChatTranscriptLayout.Info,
    val isSelf: Boolean,
    val senderName: String?,
    val avatarURL: String?,
    val timestamp: Instant?,
)

/** The display gates, layout width, and user-intent callbacks the rows dispatch to the store. */
internal class DualRowActions(
    val config: ChatConfiguration,
    val showsSenderNames: Boolean,
    val maxBubbleWidth: Dp,
    val canReact: Boolean,
    val canReply: Boolean,
    val canEdit: Boolean,
    val canDelete: Boolean,
    val toggleReaction: (String, String) -> Unit,
    val reply: (String) -> Unit,
    val edit: (String) -> Unit,
    val delete: (String) -> Unit,
    val jumpTo: (String) -> Unit,
    val cancelTransfer: (String) -> Unit,
    val resend: (String) -> Unit,
)
