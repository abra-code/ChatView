package com.abracode.chatview.ui

// A7 Compose composer - the input row below the transcript (port of ChatView.swift's `composer` group, lines
// 595-749). A connection banner and a reply / edit banner stack above an input row of: an optional attach
// paperclip, the text field, and a Send button that swaps to Stop while a turn is in flight. The whole group is
// inert until the host has injected a viable config and (for a reportsConnectionState transport) the link is up;
// a pending permission additionally pauses input while leaving Stop live.
//
// submitOn maps to Android idiom (plan divergence D3): `return` / `shift-return-newline` use a single-line field
// whose IME Send action submits (Enter cannot insert a newline, matching the Apple single-line field); modifier-
// return uses a multiline field where Enter inserts a newline and Ctrl+Enter (hardware keyboard) submits, with the
// Send button as the always-available touch submit.

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.KeyboardActions
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.Reply
import androidx.compose.material.icons.filled.AttachFile
import androidx.compose.material.icons.filled.Close
import androidx.compose.material.icons.filled.Edit
import androidx.compose.material.icons.filled.Send
import androidx.compose.material.icons.filled.Stop
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.LocalTextStyle
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.material3.TextField
import androidx.compose.material3.TextFieldDefaults
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.input.key.Key
import androidx.compose.ui.input.key.KeyEventType
import androidx.compose.ui.input.key.isCtrlPressed
import androidx.compose.ui.input.key.isMetaPressed
import androidx.compose.ui.input.key.key
import androidx.compose.ui.input.key.onPreviewKeyEvent
import androidx.compose.ui.input.key.type
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import com.abracode.chatview.ChatConfiguration
import com.abracode.chatview.ChatStore

/** The reply-quote banner target above the composer (mirrors ChatView.swift's private ReplyTarget). */
internal data class ReplyTarget(val id: String, val excerpt: String, val sender: String?)

/**
 * The composer input row. `replyTarget` and `editTargetID` drive the banner above the field; the callbacks let the
 * parent (which owns the reply / edit state and the row context menu) clear that state when a banner is cancelled or
 * a submit completes. Submit routes through the store: an active edit emits editMessage, a reply submits with
 * replyTo, and a plain submit is byte-identical to the v1 prompt path.
 */
@Composable
internal fun Composer(
    store: ChatStore,
    config: ChatConfiguration,
    replyTarget: ReplyTarget?,
    editTargetID: String?,
    onCancelReply: () -> Unit,
    onCancelEdit: () -> Unit,
    onReplySubmitted: () -> Unit,
    onEditSubmitted: () -> Unit,
    modifier: Modifier = Modifier,
) {
    // Inert until a viable config is live and (for a reportsConnectionState transport) connected; a v1 / agent
    // transport leaves isConnectionReady always true, so its composer is unchanged.
    val composerEnabled = config.inputEnabled && store.isConfigured && store.isConnectionReady
    // A pending approval pauses input (and attach / send), but Stop stays live so a hung turn is still cancellable.
    val permissionPending = store.pendingPermissions.isNotEmpty()
    val inputEnabled = composerEnabled && !permissionPending
    val inFlight = store.isStreaming || store.awaitingReply
    val draftBlank = store.draft.isBlank()

    fun submit() = submitComposer(store, replyTarget, editTargetID, onReplySubmitted, onEditSubmitted)

    Column(
        modifier = modifier
            .fillMaxWidth()
            .padding(horizontal = 12.dp, vertical = 8.dp),
        verticalArrangement = Arrangement.spacedBy(4.dp),
    ) {
        store.connectionBannerText?.let { text ->
            Text(
                text,
                style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
                modifier = Modifier.fillMaxWidth(),
            )
        }

        if (replyTarget != null) {
            ComposerBanner(
                icon = Icons.AutoMirrored.Filled.Reply,
                title = replyTarget.sender?.let { "Replying to $it" } ?: "Replying",
                detail = replyTarget.excerpt,
                // The whole composer is inert when not configured / connected (Swift gates the entire VStack), so the
                // banner's cancel follows composerEnabled - but NOT permissionPending (Swift adds that only to input).
                cancelEnabled = composerEnabled,
                onCancel = onCancelReply,
            )
        } else if (editTargetID != null) {
            ComposerBanner(
                icon = Icons.Filled.Edit,
                title = "Editing message",
                detail = null,
                cancelEnabled = composerEnabled,
                onCancel = onCancelEdit,
            )
        }

        Row(
            modifier = Modifier.fillMaxWidth(),
            verticalAlignment = Alignment.Bottom,
            horizontalArrangement = Arrangement.spacedBy(8.dp),
        ) {
            if (store.canAttach) {
                IconButton(onClick = { store.triggerAttach() }, enabled = inputEnabled) {
                    Icon(Icons.Filled.AttachFile, contentDescription = "Attach")
                }
            }

            InputField(
                store = store,
                config = config,
                enabled = inputEnabled,
                onSubmit = { submit() },
                modifier = Modifier.weight(1f),
            )

            if (inFlight) {
                // Stop is live during the awaiting gap too (a slow / hung first token stays cancellable) and is not
                // gated by a pending permission - only by the composer's own enablement.
                IconButton(onClick = { store.stop() }, enabled = composerEnabled) {
                    Icon(
                        Icons.Filled.Stop,
                        contentDescription = "Stop",
                        tint = MaterialTheme.colorScheme.error,
                    )
                }
            } else {
                IconButton(onClick = { submit() }, enabled = inputEnabled && !draftBlank) {
                    Icon(Icons.Filled.Send, contentDescription = "Send")
                }
            }
        }
    }
}

/** Routes a submit through the store, then clears the parent's reply / edit banner state. */
private fun submitComposer(
    store: ChatStore,
    replyTarget: ReplyTarget?,
    editTargetID: String?,
    onReplySubmitted: () -> Unit,
    onEditSubmitted: () -> Unit,
) {
    val text = store.draft.trim()
    if (text.isEmpty()) {
        return
    }
    if (editTargetID != null) {
        // editMessage is not optimistic (the transport confirms with messageEdited); clear the field ourselves.
        store.editMessage(itemID = editTargetID, newText = text)
        store.draft = ""
        onEditSubmitted()
    } else {
        // submitDraft trims, clears the draft, and ends the typing state before sending.
        store.submitDraft(replyTo = replyTarget?.id)
        onReplySubmitted()
    }
}

@Composable
private fun InputField(
    store: ChatStore,
    config: ChatConfiguration,
    enabled: Boolean,
    onSubmit: () -> Unit,
    modifier: Modifier = Modifier,
) {
    val multiline = config.submitOn == ChatConfiguration.SubmitPolicy.MODIFIER_RETURN
    val colors = TextFieldDefaults.colors(
        focusedContainerColor = MaterialTheme.colorScheme.surfaceVariant,
        unfocusedContainerColor = MaterialTheme.colorScheme.surfaceVariant,
        disabledContainerColor = MaterialTheme.colorScheme.surfaceVariant,
        focusedIndicatorColor = Color.Transparent,
        unfocusedIndicatorColor = Color.Transparent,
        disabledIndicatorColor = Color.Transparent,
    )
    val shape = RoundedCornerShape(20.dp)
    // modifier-return: Ctrl+Enter (or Meta+Enter) on a hardware keyboard submits; plain Enter inserts a newline.
    val keyModifier = if (multiline) {
        Modifier.onPreviewKeyEvent { event ->
            if (event.type == KeyEventType.KeyDown && event.key == Key.Enter &&
                (event.isCtrlPressed || event.isMetaPressed)
            ) {
                onSubmit()
                true
            } else {
                false
            }
        }
    } else {
        Modifier
    }

    TextField(
        value = store.draft,
        onValueChange = { store.draft = it },
        modifier = modifier
            .heightIn(max = 120.dp)
            .testTag("chat.composer.input")
            .then(keyModifier),
        enabled = enabled,
        placeholder = {
            Text(config.placeholder, maxLines = 1, overflow = TextOverflow.Ellipsis, style = LocalTextStyle.current)
        },
        singleLine = !multiline,
        maxLines = if (multiline) 6 else 1,
        keyboardOptions = KeyboardOptions(imeAction = if (multiline) ImeAction.Default else ImeAction.Send),
        keyboardActions = KeyboardActions(onSend = { onSubmit() }),
        colors = colors,
        shape = shape,
    )
}

@Composable
private fun ComposerBanner(
    icon: ImageVector,
    title: String,
    detail: String?,
    cancelEnabled: Boolean,
    onCancel: () -> Unit,
) {
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .padding(horizontal = 8.dp, vertical = 4.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(8.dp),
    ) {
        Icon(icon, contentDescription = null, tint = MaterialTheme.colorScheme.onSurfaceVariant)
        Column(modifier = Modifier.weight(1f)) {
            Text(
                title,
                style = MaterialTheme.typography.labelMedium,
                color = MaterialTheme.colorScheme.onSurface,
            )
            if (!detail.isNullOrEmpty()) {
                Text(
                    detail,
                    style = MaterialTheme.typography.labelSmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                )
            }
        }
        IconButton(onClick = onCancel, enabled = cancelEnabled, modifier = Modifier.testTag("chat.composer.cancelBanner")) {
            Icon(Icons.Filled.Close, contentDescription = "Cancel", tint = MaterialTheme.colorScheme.onSurfaceVariant)
        }
    }
}
