@file:OptIn(ExperimentalFoundationApi::class, ExperimentalLayoutApi::class)

package com.abracode.chatview.ui

// A6 Compose transcript view - the row composables. One dispatch entry point (DualTranscriptRow) wraps each item
// in the run-spacing / day-separator column and renders the per-kind body: message / image / file (+ voice)
// bubbles with the dual (leading / trailing) skeleton, centered captions for system / member / call / error, and
// minimal Tier-2 placeholders for thoughts / tool calls. Voice PLAYBACK is stubbed (a local toggle only, no
// MediaPlayer). No composer - this stage is transcript-only.

import androidx.compose.foundation.ExperimentalFoundationApi
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.combinedClickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ExperimentalLayoutApi
import androidx.compose.foundation.layout.FlowRow
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.text.selection.SelectionContainer
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.Reply
import androidx.compose.material.icons.filled.ArrowDownward
import androidx.compose.material.icons.filled.Call
import androidx.compose.material.icons.filled.Cancel
import androidx.compose.material.icons.filled.ContentCopy
import androidx.compose.material.icons.filled.Delete
import androidx.compose.material.icons.filled.Edit
import androidx.compose.material.icons.filled.Error
import androidx.compose.material.icons.filled.ErrorOutline
import androidx.compose.material.icons.filled.Group
import androidx.compose.material.icons.filled.InsertDriveFile
import androidx.compose.material.icons.filled.Pause
import androidx.compose.material.icons.filled.PlayArrow
import androidx.compose.material.icons.filled.Psychology
import androidx.compose.material.icons.filled.Videocam
import androidx.compose.material.icons.filled.Warning
import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.material.icons.automirrored.filled.KeyboardArrowRight
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.LinearProgressIndicator
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.rotate
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalClipboardManager
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.role
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.semantics.stateDescription
import androidx.compose.ui.text.AnnotatedString
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.abracode.asyncimagecache.CachedImage
import com.abracode.asyncimagecache.ContentMode
import com.abracode.chatview.ChatConfiguration
import com.abracode.chatview.ChatFile
import com.abracode.chatview.ChatItem
import com.abracode.chatview.ChatMessage
import com.abracode.chatview.ChatRole
import com.abracode.chatview.FileTransferStatus
import com.abracode.chatview.MessageStatus
import com.abracode.chatview.Reaction
import com.abracode.chatview.ReplyRef
import com.abracode.chatview.ToolCallModel
import com.abracode.richtext.rendering.RichText
import java.time.Instant

// --- Dispatch + run/day wrapper. ------------------------------------------------------------------------------

/**
 * Renders one transcript item: the optional day separator, then the per-kind body, inside a run-spacing column
 * (extra top gap at the start of a run). This is the single item composable the LazyColumn keys per id.
 */
@Composable
internal fun DualTranscriptRow(ctx: DualRowContext, actions: DualRowActions, highlighted: Boolean) {
    Column(
        modifier = Modifier
            .fillMaxWidth()
            .padding(top = if (ctx.info.isFirstInRun) 8.dp else 2.dp),
        verticalArrangement = Arrangement.spacedBy(4.dp),
    ) {
        val ts = ctx.timestamp
        if (ctx.info.startsNewDay && ts != null) {
            DaySeparatorRow(ts)
        }
        when (val item = ctx.item) {
            is ChatItem.Message -> DualMessageRow(ctx, actions, item.message, highlighted)
            is ChatItem.Image -> DualImageRow(ctx, actions, item)
            is ChatItem.File -> DualFileRow(ctx, actions, item.file)
            is ChatItem.MemberEventItem ->
                CenteredCaption(memberEventText(item.event), Icons.Filled.Group, MaterialTheme.colorScheme.onSurfaceVariant)
            is ChatItem.CallEventItem -> {
                val tint = if (item.event.isNegative()) MaterialTheme.colorScheme.error else MaterialTheme.colorScheme.onSurfaceVariant
                val icon = if (item.event.isVideo == true) Icons.Filled.Videocam else Icons.Filled.Call
                CenteredCaption(callEventText(item.event), icon, tint)
            }
            is ChatItem.System -> CenteredCaption(item.text, null, MaterialTheme.colorScheme.onSurfaceVariant)
            is ChatItem.Error -> CenteredCaption(item.text, Icons.Filled.Warning, MaterialTheme.colorScheme.error)
            is ChatItem.Thought -> ThoughtRow(
                thought = item.thought,
                initiallyExpanded = actions.config.surfaces.thoughts != ChatConfiguration.SurfaceMode.COLLAPSED,
            )
            is ChatItem.ToolCall -> ToolCallRow(
                call = item.call,
                compact = actions.config.surfaces.toolCalls == ChatConfiguration.SurfaceMode.COLLAPSED,
                showsDiff = actions.config.surfaces.diffs != ChatConfiguration.SurfaceMode.HIDDEN,
            )
            // DRAWS NOTHING YET, ON PURPOSE. Decoding a session marker is what stops one destroying a whole
            // transcript, and that is this change; rendering it (Swift draws a centered caption, and an expandable
            // digest in the agentic transcript) is its own piece of work. Until then the item survives a restore and
            // round-trips untouched - it is invisible, not lost.
            is ChatItem.SessionEventItem -> Unit
        }
    }
}

// --- Shared dual skeleton. ------------------------------------------------------------------------------------

/**
 * The leading / trailing bubble skeleton. A sender label (first of an incoming run) sits above a bottom-aligned
 * avatar + bubble row - the avatar meets the bubble's BOTTOM edge, never sinking to the reactions / caption below
 * it - and the caption (last of a run) sits underneath, indented to line up with the bubble. A reaction, when
 * present, overlays the bubble's top-OUTER corner (Apple-style), decoupled from the bottom caption stack so it
 * never collides with the time / delivery status (which live on the inner / trailing side of an own message).
 */
@Composable
private fun DualRowScaffold(
    ctx: DualRowContext,
    actions: DualRowActions,
    reactions: (@Composable () -> Unit)? = null,
    caption: (@Composable () -> Unit)? = null,
    bubble: @Composable () -> Unit,
) {
    val isSelf = ctx.isSelf
    val info = ctx.info
    val showAvatars = actions.config.showAvatars
    // The incoming avatar gutter (avatar 28 + 6 gap); the sender label and caption indent by it so they line up
    // with the bubble instead of the avatar. Own rows and no-avatar configs have no gutter.
    val contentIndent = if (showAvatars && !isSelf) 34.dp else 0.dp
    Column(
        modifier = Modifier.fillMaxWidth(),
        horizontalAlignment = if (isSelf) Alignment.End else Alignment.Start,
        verticalArrangement = Arrangement.spacedBy(2.dp),
    ) {
        if (!isSelf && info.isFirstInRun && actions.showsSenderNames && !ctx.senderName.isNullOrEmpty()) {
            Text(
                ctx.senderName,
                style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
                modifier = Modifier.padding(start = contentIndent + 4.dp, end = 4.dp),
            )
        }
        Row(
            modifier = Modifier.fillMaxWidth(),
            horizontalArrangement = if (isSelf) Arrangement.End else Arrangement.spacedBy(6.dp, Alignment.Start),
            verticalAlignment = Alignment.Bottom,
        ) {
            if (isSelf) {
                Spacer(Modifier.weight(1f, fill = false).widthIn(min = 40.dp))
            } else if (showAvatars) {
                if (info.isLastInRun) {
                    AvatarView(ctx.senderName, ctx.avatarURL, 28.dp)
                } else {
                    Spacer(Modifier.width(28.dp).height(1.dp))
                }
            }
            Box(modifier = Modifier.widthIn(max = actions.maxBubbleWidth)) {
                bubble()
                if (reactions != null) {
                    // Overlapping badge on the bubble's top-outer corner (trailing for incoming, leading for own),
                    // lifted onto a surface pill so it reads above the bubble. matchParentSize sizes this layer to the
                    // bubble WITHOUT driving the Box's own size, so a reaction pill wider than a short bubble does not
                    // grow the Box and shove the badge / bubble off-corner - TopEnd / TopStart pin to the bubble's real
                    // corner, matching SwiftUI's .overlay (which never affects the base geometry). offset() is
                    // placement-only, so the avatar still meets the bubble's bottom edge.
                    Box(modifier = Modifier.matchParentSize()) {
                        Surface(
                            shape = RoundedCornerShape(50),
                            color = MaterialTheme.colorScheme.surface,
                            shadowElevation = 3.dp,
                            modifier = Modifier
                                .align(if (isSelf) Alignment.TopStart else Alignment.TopEnd)
                                .offset(x = if (isSelf) (-8).dp else 8.dp, y = (-10).dp),
                        ) {
                            Box(modifier = Modifier.padding(horizontal = 2.dp, vertical = 1.dp)) { reactions() }
                        }
                    }
                }
            }
            if (!isSelf) {
                Spacer(Modifier.weight(1f, fill = false).widthIn(min = 40.dp))
            }
        }
        if (info.isLastInRun && caption != null) {
            Box(
                modifier = Modifier.fillMaxWidth().padding(start = contentIndent),
                contentAlignment = if (isSelf) Alignment.CenterEnd else Alignment.CenterStart,
            ) {
                caption()
            }
        }
    }
}

// --- Message. -------------------------------------------------------------------------------------------------

@Composable
private fun DualMessageRow(ctx: DualRowContext, actions: DualRowActions, msg: ChatMessage, highlighted: Boolean) {
    DualRowScaffold(
        ctx = ctx,
        actions = actions,
        reactions = if (actions.canReact && !msg.reactions.isNullOrEmpty()) {
            { ReactionChips(msg.reactions!!, msg.id, actions) }
        } else {
            null
        },
        caption = { MessageCaption(actions, msg, ctx.isSelf) },
    ) {
        MessageBubble(ctx, actions, msg, highlighted)
    }
}

@Composable
private fun MessageBubble(ctx: DualRowContext, actions: DualRowActions, msg: ChatMessage, highlighted: Boolean) {
    if (msg.deleted == true) {
        Text(
            "Message deleted",
            style = MaterialTheme.typography.bodyMedium,
            fontStyle = FontStyle.Italic,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
            modifier = Modifier.padding(horizontal = 10.dp, vertical = 7.dp),
        )
        return
    }
    val bubbleBg = if (ctx.isSelf) {
        ChatTint.color(actions.config.style(msg.role).tint).copy(alpha = 0.22f)
    } else {
        MaterialTheme.colorScheme.onSurfaceVariant.copy(alpha = 0.14f)
    }
    var menuOpen by remember { mutableStateOf(false) }
    Column(
        modifier = Modifier
            .clip(BubbleShape)
            .background(bubbleBg)
            .then(
                if (highlighted) {
                    Modifier.border(2.dp, MaterialTheme.colorScheme.primary, BubbleShape)
                } else {
                    Modifier
                },
            )
            .combinedClickable(onClick = {}, onLongClick = { menuOpen = true })
            .padding(horizontal = 10.dp, vertical = 7.dp),
        verticalArrangement = Arrangement.spacedBy(4.dp),
    ) {
        msg.replyTo?.let { ref ->
            ReplyQuote(ref, onClick = { actions.jumpTo(ref.itemID) })
        }
        if (msg.text.isEmpty() && msg.isStreaming) {
            Text("...", color = MaterialTheme.colorScheme.onSurfaceVariant)
        } else {
            RichText(markdown = msg.text)
        }
        MessageContextMenu(menuOpen, onDismiss = { menuOpen = false }, msg, ctx.isSelf, actions)
    }
}

@Composable
private fun MessageCaption(actions: DualRowActions, msg: ChatMessage, isSelf: Boolean) {
    val onVariant = MaterialTheme.colorScheme.onSurfaceVariant
    val formatted = shortTime(msg.timestamp)
    val showTs = actions.config.showTimestamps
    val timeText: String? = if (!showTs || formatted == null) {
        if (msg.editedAt != null) "(edited)" else null
    } else {
        formatted + (if (msg.editedAt != null) " $MIDDLE_DOT (edited)" else "")
    }
    if (isSelf) {
        Row(
            modifier = Modifier.padding(horizontal = 4.dp),
            horizontalArrangement = Arrangement.spacedBy(4.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            if (timeText != null) {
                Text(timeText, style = MaterialTheme.typography.bodySmall, color = onVariant)
            }
            if (actions.config.showDeliveryStatus && msg.status != null) {
                DeliveryStatusCaption(msg.status, msg.id, actions)
            }
        }
    } else if (timeText != null) {
        Text(
            timeText,
            style = MaterialTheme.typography.bodySmall,
            color = onVariant,
            modifier = Modifier.padding(horizontal = 4.dp),
        )
    }
}

@Composable
private fun DeliveryStatusCaption(status: MessageStatus, id: String, actions: DualRowActions) {
    val caption = MaterialTheme.typography.bodySmall
    val onVariant = MaterialTheme.colorScheme.onSurfaceVariant
    when (status) {
        MessageStatus.SENDING -> Text("Sending...", style = caption, color = onVariant)
        MessageStatus.SENT -> Text("Sent", style = caption, color = onVariant)
        MessageStatus.DELIVERED -> Text("Delivered", style = caption, color = onVariant)
        MessageStatus.READ -> Text("Read", style = caption, color = MaterialTheme.colorScheme.primary)
        MessageStatus.FAILED -> Row(
            modifier = Modifier.clickable { actions.resend(id) },
            horizontalArrangement = Arrangement.spacedBy(2.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Icon(Icons.Filled.Error, contentDescription = null, tint = MaterialTheme.colorScheme.error, modifier = Modifier.size(14.dp))
            Text("Failed - tap to retry", style = caption, color = MaterialTheme.colorScheme.error)
        }
    }
}

@Composable
private fun MessageContextMenu(
    expanded: Boolean,
    onDismiss: () -> Unit,
    msg: ChatMessage,
    isSelf: Boolean,
    actions: DualRowActions,
) {
    val clipboard = LocalClipboardManager.current
    DropdownMenu(expanded = expanded, onDismissRequest = onDismiss) {
        if (actions.canReact) {
            Row(
                modifier = Modifier.padding(horizontal = 12.dp, vertical = 4.dp),
                horizontalArrangement = Arrangement.spacedBy(8.dp),
            ) {
                quickReactions.forEach { emoji ->
                    Text(
                        emoji,
                        fontSize = 20.sp,
                        modifier = Modifier.clickable { actions.toggleReaction(msg.id, emoji); onDismiss() },
                    )
                }
            }
        }
        if (actions.canReply) {
            DropdownMenuItem(
                text = { Text("Reply") },
                leadingIcon = { Icon(Icons.AutoMirrored.Filled.Reply, contentDescription = null) },
                onClick = { actions.reply(msg.id); onDismiss() },
            )
        }
        if (actions.canEdit && isSelf) {
            DropdownMenuItem(
                text = { Text("Edit") },
                leadingIcon = { Icon(Icons.Filled.Edit, contentDescription = null) },
                onClick = { actions.edit(msg.id); onDismiss() },
            )
        }
        DropdownMenuItem(
            text = { Text("Copy") },
            leadingIcon = { Icon(Icons.Filled.ContentCopy, contentDescription = null) },
            onClick = { clipboard.setText(AnnotatedString(msg.text)); onDismiss() },
        )
        if (actions.canDelete && isSelf) {
            DropdownMenuItem(
                text = { Text("Delete", color = MaterialTheme.colorScheme.error) },
                leadingIcon = { Icon(Icons.Filled.Delete, contentDescription = null, tint = MaterialTheme.colorScheme.error) },
                onClick = { actions.delete(msg.id); onDismiss() },
            )
        }
    }
}

// --- Reactions + reply quote. ---------------------------------------------------------------------------------

@Composable
private fun ReactionChips(reactions: List<Reaction>, id: String, actions: DualRowActions) {
    FlowRow(
        horizontalArrangement = Arrangement.spacedBy(4.dp),
        verticalArrangement = Arrangement.spacedBy(4.dp),
    ) {
        reactions.forEach { reaction ->
            val bg = if (reaction.mine) {
                MaterialTheme.colorScheme.primary.copy(alpha = 0.18f)
            } else {
                MaterialTheme.colorScheme.onSurfaceVariant.copy(alpha = 0.14f)
            }
            Row(
                modifier = Modifier
                    .clip(RoundedCornerShape(50))
                    .background(bg)
                    .clickable { actions.toggleReaction(id, reaction.emoji) }
                    .padding(horizontal = 7.dp, vertical = 3.dp),
                horizontalArrangement = Arrangement.spacedBy(3.dp),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                Text(reaction.emoji, style = MaterialTheme.typography.bodySmall)
                if (reaction.count > 1) {
                    Text(
                        reaction.count.toString(),
                        style = MaterialTheme.typography.bodySmall,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                    )
                }
            }
        }
    }
}

@Composable
private fun ReplyQuote(ref: ReplyRef, onClick: () -> Unit) {
    Row(
        modifier = Modifier
            .clip(RoundedCornerShape(4.dp))
            .clickable { onClick() },
        horizontalArrangement = Arrangement.spacedBy(6.dp),
    ) {
        Box(
            modifier = Modifier
                .width(3.dp)
                .height(32.dp)
                .clip(RoundedCornerShape(1.5.dp))
                .background(MaterialTheme.colorScheme.primary.copy(alpha = 0.6f)),
        )
        Column {
            ref.senderName?.takeIf { it.isNotEmpty() }?.let {
                Text(
                    it,
                    style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.primary,
                    fontWeight = FontWeight.Medium,
                )
            }
            Text(
                ref.excerpt,
                style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
                maxLines = 2,
                overflow = TextOverflow.Ellipsis,
            )
        }
    }
}

// --- Image. ---------------------------------------------------------------------------------------------------

@Composable
private fun DualImageRow(ctx: DualRowContext, actions: DualRowActions, item: ChatItem.Image) {
    DualRowScaffold(ctx = ctx, actions = actions) {
        val frameMax = minOf(actions.maxBubbleWidth, 280.dp)
        val intrinsic = item.image.pixelSize?.let { Size(it.width.toFloat(), it.height.toFloat()) }
        CachedImage(
            url = item.image.url,
            modifier = Modifier.widthIn(max = frameMax),
            intrinsicSize = intrinsic,
            cornerRadius = 12.dp,
            contentMode = ContentMode.Fill,
            maxPixelWidth = actions.maxBubbleWidth.value * 3f,
            contentDescription = item.image.alt.ifEmpty { "Image" },
        )
    }
}

// --- File + voice. --------------------------------------------------------------------------------------------

@Composable
private fun DualFileRow(ctx: DualRowContext, actions: DualRowActions, file: ChatFile) {
    // Swift's DualFileRow carries no timestamp / delivery caption (ChatDualTranscript.swift:442-447) - only the
    // sender label + bubble - so the scaffold gets no caption slot here.
    DualRowScaffold(
        ctx = ctx,
        actions = actions,
    ) {
        val bg = if (ctx.isSelf) {
            ChatTint.color(actions.config.style(ChatRole.LOCAL).tint).copy(alpha = 0.22f)
        } else {
            MaterialTheme.colorScheme.onSurfaceVariant.copy(alpha = 0.14f)
        }
        Column(
            modifier = Modifier
                .widthIn(min = 180.dp)
                .clip(BubbleShape)
                .background(bg)
                .padding(horizontal = 10.dp, vertical = 8.dp),
            verticalArrangement = Arrangement.spacedBy(4.dp),
        ) {
            if (file.kind == ChatFile.Kind.VOICE) {
                VoiceContent(file)
            } else {
                FileContent(file, actions)
            }
        }
    }
}

@Composable
private fun FileContent(file: ChatFile, actions: DualRowActions) {
    val context = LocalContext.current
    Column(verticalArrangement = Arrangement.spacedBy(4.dp)) {
        Row(horizontalArrangement = Arrangement.spacedBy(8.dp), verticalAlignment = Alignment.CenterVertically) {
            Icon(Icons.Filled.InsertDriveFile, contentDescription = null, tint = MaterialTheme.colorScheme.onSurfaceVariant)
            Column(verticalArrangement = Arrangement.spacedBy(1.dp)) {
                Text(file.name, style = MaterialTheme.typography.bodyMedium, fontWeight = FontWeight.Medium, maxLines = 1, overflow = TextOverflow.Ellipsis)
                Text(
                    transferSubtitle(context, file),
                    style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                )
            }
        }
        when (file.transferStatus) {
            FileTransferStatus.TRANSFERRING -> Row(
                horizontalArrangement = Arrangement.spacedBy(8.dp),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                LinearProgressIndicator(
                    progress = { (file.progress ?: 0.0).toFloat() },
                    modifier = Modifier.weight(1f),
                )
                IconButton(onClick = { actions.cancelTransfer(file.id) }) {
                    Icon(Icons.Filled.Cancel, contentDescription = "Cancel")
                }
            }
            FileTransferStatus.FAILED -> Row(
                modifier = Modifier.clickable { actions.resend(file.id) },
                horizontalArrangement = Arrangement.spacedBy(4.dp),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                Icon(Icons.Filled.ErrorOutline, contentDescription = null, tint = MaterialTheme.colorScheme.error, modifier = Modifier.size(16.dp))
                Text("Transfer failed - tap to retry", style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.error)
            }
            else -> {}
        }
    }
}

/** Voice message: play/pause + a progress bar + a duration label. Playback is STUBBED (a local toggle only). */
@Composable
private fun VoiceContent(file: ChatFile) {
    // TODO(A6-followup): Tier-2 stub - the toggle flips a local bool; no MediaPlayer, progress stays at 0.
    var playing by remember { mutableStateOf(false) }
    val localProgress = 0f
    Row(horizontalArrangement = Arrangement.spacedBy(10.dp), verticalAlignment = Alignment.CenterVertically) {
        IconButton(onClick = { playing = !playing }) {
            Icon(
                if (playing) Icons.Filled.Pause else Icons.Filled.PlayArrow,
                contentDescription = if (playing) "Pause" else "Play",
            )
        }
        Column(verticalArrangement = Arrangement.spacedBy(3.dp)) {
            LinearProgressIndicator(
                progress = { if (playing) localProgress else 0f },
                modifier = Modifier.width(120.dp),
            )
            val label = file.durationSeconds?.let { durationText(it) } ?: "Voice message"
            Text(label, style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
        }
    }
}

private fun transferSubtitle(context: android.content.Context, file: ChatFile): String {
    val parts = listOfNotNull(
        file.sizeBytes?.let { android.text.format.Formatter.formatShortFileSize(context, it.toLong()) },
        when (file.transferStatus) {
            FileTransferStatus.PENDING -> "Waiting..."
            FileTransferStatus.TRANSFERRING -> "${((file.progress ?: 0.0) * 100).toInt()}%"
            FileTransferStatus.CANCELLED -> "Cancelled"
            else -> null
        },
    )
    return parts.joinToString(" $MIDDLE_DOT ")
}

// --- Centered captions + day separator. -----------------------------------------------------------------------

@Composable
private fun CenteredCaption(caption: String, icon: androidx.compose.ui.graphics.vector.ImageVector?, tint: Color) {
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .padding(vertical = 2.dp),
        horizontalArrangement = Arrangement.spacedBy(4.dp, Alignment.CenterHorizontally),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        if (icon != null) {
            Icon(icon, contentDescription = null, tint = tint, modifier = Modifier.size(20.dp))
        }
        Text(caption, style = MaterialTheme.typography.bodySmall, color = tint, textAlign = TextAlign.Center)
    }
}

@Composable
private fun DaySeparatorRow(timestamp: Instant) {
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .padding(vertical = 6.dp),
        horizontalArrangement = Arrangement.Center,
    ) {
        Text(
            daySeparatorLabel(timestamp),
            style = MaterialTheme.typography.bodySmall,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
            modifier = Modifier
                .clip(RoundedCornerShape(50))
                .background(MaterialTheme.colorScheme.onSurfaceVariant.copy(alpha = 0.12f))
                .padding(horizontal = 10.dp, vertical = 3.dp),
        )
    }
}

// --- Agentic rows (thought fold / tool call card). -------------------------------------------------------------
//
// Ports of ThoughtRow (ChatView.swift:1046) and ToolCallRow (ChatView.swift:1354), replacing the Tier-2
// placeholders the porting plan left here. These are what make an agent session readable on a phone: without the
// fold a reasoning stream is a wall of text, and without the card a tool call is a title with no way to see what
// it actually did.

/** The reasoning fold. Collapsed by default unless the document asks for inline thoughts. */
@Composable
private fun ThoughtRow(thought: ChatMessage, initiallyExpanded: Boolean) {
    // rememberSaveable, not remember: a LazyColumn disposes rows outside its window, so a plain remember loses the
    // fold as soon as the reader scrolls past it - and loses every open fold on rotation. Keyed on the item id so a
    // recycled row never inherits another item's state.
    var expanded by rememberSaveable(thought.id) { mutableStateOf(initiallyExpanded) }
    Column(
        modifier = Modifier.fillMaxWidth().padding(horizontal = 4.dp),
        verticalArrangement = Arrangement.spacedBy(4.dp),
    ) {
        Row(
            modifier = Modifier
                .fillMaxWidth()
                .clip(RoundedCornerShape(6.dp))
                .clickable { expanded = !expanded }
                .padding(vertical = 2.dp)
                .semantics {
                    role = Role.Button
                    stateDescription = if (expanded) "Expanded" else "Collapsed"
                }
                .testTag("chat.thought.header"),
            horizontalArrangement = Arrangement.spacedBy(6.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Icon(
                Icons.Filled.Psychology,
                contentDescription = null,
                tint = MaterialTheme.colorScheme.onSurfaceVariant,
                modifier = Modifier.size(18.dp),
            )
            Text(
                if (thought.isStreaming) "Thinking..." else "Thoughts",
                style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
            DisclosureChevron(expanded)
        }
        if (expanded) {
            Box(modifier = Modifier.alpha(0.75f).padding(start = 24.dp).testTag("chat.thought.body")) {
                if (thought.text.isEmpty() && thought.isStreaming) {
                    Text("...", style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
                } else {
                    RichText(markdown = thought.text)
                }
            }
        }
    }
}

/**
 * One tool invocation: kind icon, title, status, and - when the call carries content, a diff, or raw input /
 * output - a fold with the detail. The card mutates in place as tool_call_update events arrive (same item id).
 *
 * The detail ALWAYS starts folded, whatever surfaces.toolCalls says: tool content is bulk material (a whole file
 * read, a long command output) and auto-expanding it floods the transcript. `compact` (surfaces.toolCalls =
 * "collapsed") additionally shrinks the card to a caption row.
 */
@Composable
private fun ToolCallRow(call: ToolCallModel, compact: Boolean, showsDiff: Boolean) {
    // rememberSaveable for the same reason as the thought fold: scrolling past an expanded card and back must not
    // re-collapse the output the reader was in the middle of.
    var expanded by rememberSaveable(call.id) { mutableStateOf(false) }
    val hasDetail = call.contentText.isNotEmpty() || (showsDiff && call.diff != null) ||
        call.rawInput != null || call.rawOutput != null

    val body: @Composable () -> Unit = {
        Column(
            modifier = Modifier.fillMaxWidth(),
            verticalArrangement = Arrangement.spacedBy(6.dp),
        ) {
            Row(
                modifier = Modifier
                    .fillMaxWidth()
                    .then(
                        if (hasDetail) {
                            Modifier
                                .clickable { expanded = !expanded }
                                .semantics {
                                    role = Role.Button
                                    stateDescription = if (expanded) "Expanded" else "Collapsed"
                                }
                        } else {
                            Modifier
                        },
                    )
                    .testTag("chat.toolCall.header"),
                horizontalArrangement = Arrangement.spacedBy(6.dp),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                Icon(
                    ChatIcons.forToolKind(call.kind),
                    contentDescription = null,
                    tint = MaterialTheme.colorScheme.onSurfaceVariant,
                    modifier = Modifier.size(18.dp),
                )
                Text(
                    call.title,
                    style = if (compact) MaterialTheme.typography.bodySmall else MaterialTheme.typography.bodyMedium,
                    color = if (compact) MaterialTheme.colorScheme.onSurfaceVariant else MaterialTheme.colorScheme.onSurface,
                    maxLines = if (compact) 1 else 2,
                    overflow = TextOverflow.Ellipsis,
                    // The one weighted child, so a long title ellipsizes instead of squeezing the status out of
                    // the row, and the status pins to the trailing edge (Swift's Spacer(minLength: 8)).
                    modifier = Modifier.weight(1f),
                )
                if (hasDetail) {
                    DisclosureChevron(expanded)
                }
                ToolStatusIndicator(call.status)
            }
            if (expanded && hasDetail) {
                ToolCallDetail(call, showsDiff)
            }
        }
    }

    if (compact) {
        Box(modifier = Modifier.fillMaxWidth().padding(horizontal = 4.dp)) { body() }
    } else {
        Box(
            modifier = Modifier
                .fillMaxWidth()
                .clip(RoundedCornerShape(10.dp))
                .background(MaterialTheme.colorScheme.onSurfaceVariant.copy(alpha = 0.08f))
                .border(1.dp, MaterialTheme.colorScheme.onSurfaceVariant.copy(alpha = 0.15f), RoundedCornerShape(10.dp))
                .padding(10.dp),
        ) {
            body()
        }
    }
}

@Composable
private fun ToolCallDetail(call: ToolCallModel, showsDiff: Boolean) {
    Column(
        modifier = Modifier.fillMaxWidth().testTag("chat.toolCall.detail"),
        verticalArrangement = Arrangement.spacedBy(6.dp),
    ) {
        if (call.contentText.isNotEmpty()) {
            RichText(markdown = cappedToolDetail(call.contentText))
        }
        val diff = call.diff
        if (showsDiff && diff != null) {
            // No DiffView on Android (it is not ported, and the remote-agent plan says not to build one here), so a
            // diff renders as its resulting text under the path - readable, and honest about what it is.
            Text(
                diff.path,
                style = MaterialTheme.typography.bodySmall.copy(fontFamily = FontFamily.Monospace),
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
            CodeBlock(cappedToolDetail(diff.newText))
        }
        call.rawInput?.let { LabeledCode("Input", cappedToolDetail(it)) }
        call.rawOutput?.let { LabeledCode("Output", cappedToolDetail(it)) }
    }
}

@Composable
private fun LabeledCode(title: String, text: String) {
    Text(
        title,
        style = MaterialTheme.typography.labelSmall,
        color = MaterialTheme.colorScheme.onSurfaceVariant,
    )
    CodeBlock(text)
}

@Composable
private fun CodeBlock(text: String) {
    // Selectable: tool output the reader cannot copy off a phone is materially less useful, and the Swift twin
    // enables text selection on the same block.
    SelectionContainer {
        Text(
            text,
            style = MaterialTheme.typography.bodySmall.copy(fontFamily = FontFamily.Monospace),
            color = MaterialTheme.colorScheme.onSurface,
            modifier = Modifier
                .fillMaxWidth()
                .clip(RoundedCornerShape(6.dp))
                .background(MaterialTheme.colorScheme.onSurfaceVariant.copy(alpha = 0.08f))
                .padding(6.dp),
        )
    }
}

@Composable
private fun DisclosureChevron(expanded: Boolean) {
    val rotation by animateFloatAsState(if (expanded) 90f else 0f, label = "disclosure")
    Icon(
        Icons.AutoMirrored.Filled.KeyboardArrowRight,
        contentDescription = null,
        tint = MaterialTheme.colorScheme.onSurfaceVariant,
        modifier = Modifier.size(16.dp).rotate(rotation),
    )
}

@Composable
private fun ToolStatusIndicator(status: ToolCallModel.Status) {
    when (status) {
        ToolCallModel.Status.IN_PROGRESS ->
            CircularProgressIndicator(modifier = Modifier.size(14.dp), strokeWidth = 2.dp)
        ToolCallModel.Status.COMPLETED -> Icon(
            ChatIcons.forToolStatus(status),
            contentDescription = "Completed",
            tint = Color(0xFF16A34A),
            modifier = Modifier.size(16.dp),
        )
        ToolCallModel.Status.FAILED -> Icon(
            ChatIcons.forToolStatus(status),
            contentDescription = "Failed",
            tint = MaterialTheme.colorScheme.error,
            modifier = Modifier.size(16.dp),
        )
        ToolCallModel.Status.PENDING -> Icon(
            ChatIcons.forToolStatus(status),
            contentDescription = "Pending",
            tint = MaterialTheme.colorScheme.onSurfaceVariant,
            modifier = Modifier.size(16.dp),
        )
    }
}

/** Port of ToolDetailText.capped: a megabyte of tool output stays a card, not a scroll marathon. */
private const val toolDetailCap = 4000

private fun cappedToolDetail(text: String): String {
    if (text.length <= toolDetailCap) {
        return text
    }
    // Back off one unit rather than splitting a surrogate pair, which would render as a replacement glyph. The
    // Swift twin counts grapheme clusters and cannot hit this at all.
    val end = if (text[toolDetailCap - 1].isHighSurrogate()) toolDetailCap - 1 else toolDetailCap
    return text.take(end) + "\n... (truncated, ${text.length - end} more characters)"
}

// --- Avatar. --------------------------------------------------------------------------------------------------

@Composable
internal fun AvatarView(name: String?, url: String?, size: androidx.compose.ui.unit.Dp) {
    if (!url.isNullOrEmpty()) {
        CachedImage(
            url = url,
            modifier = Modifier.size(size).clip(CircleShape),
            cornerRadius = size / 2,
            contentMode = ContentMode.Fill,
            contentDescription = name,
        )
        return
    }
    Box(
        modifier = Modifier
            .size(size)
            .clip(CircleShape)
            .background(discColor(name ?: "")),
        contentAlignment = Alignment.Center,
    ) {
        Text(
            initials(name),
            color = Color.White,
            style = MaterialTheme.typography.labelSmall,
        )
    }
}

private fun initials(name: String?): String {
    val parts = name?.trim()?.split(Regex("\\s+"))?.filter { it.isNotEmpty() }.orEmpty()
    if (parts.isEmpty()) return "?"
    return parts.take(2).joinToString("") { it.first().uppercaseChar().toString() }
}

private val avatarPalette = listOf(
    Color(0xFF3B82F6), Color(0xFF22C55E), Color(0xFFF97316), Color(0xFF8B5CF6),
    Color(0xFFEC4899), Color(0xFF14B8A6), Color(0xFF6366F1), Color(0xFFEF4444),
)

private fun discColor(seed: String): Color {
    var hash = 5381L
    for (c in seed) {
        hash = ((hash shl 5) + hash) + c.code
    }
    val index = (Math.floorMod(hash, avatarPalette.size.toLong())).toInt()
    return avatarPalette[index]
}
