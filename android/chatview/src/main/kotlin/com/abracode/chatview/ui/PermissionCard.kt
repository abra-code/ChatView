@file:OptIn(ExperimentalLayoutApi::class)

package com.abracode.chatview.ui

// Port of the PermissionCard in Sources/ChatView/ChatView.swift (:1486). The agent's blocking question, pinned
// between the transcript and the composer: while it is up the composer's input is paused (Composer.kt gates on
// store.pendingPermissions) and Stop stays live, so a hung turn is still cancellable.
//
// This is what makes the phone a REMOTE CONTROL rather than a viewer: an agent running on a bridge host parks its
// tool call until somebody answers, and this card is the only place that answer can come from on Android.
//
// The head of the FIFO is shown, one question at a time - the same rule the Swift gate follows. Answering pops it
// (ChatStore.respondToPermission) and the next one, if any, takes its place; a bridge that resolves the request
// elsewhere (another device answered, or it timed out) clears the gate through ChatEvent.PermissionResolved
// without the user touching anything.

import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ExperimentalLayoutApi
import androidx.compose.foundation.layout.FlowRow
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Lock
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.semantics.LiveRegionMode
import androidx.compose.ui.semantics.liveRegion
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.unit.dp
import com.abracode.chatview.PermissionRequest

/**
 * The pending-approval card. [request] is the head of the store's FIFO; [respond] hands the chosen option id back
 * (null would mean "cancelled", which only the transport synthesizes - the card always names an option).
 */
@Composable
internal fun PermissionCard(
    request: PermissionRequest,
    modifier: Modifier = Modifier,
    respond: (String?) -> Unit,
) {
    Column(
        modifier = modifier
            .fillMaxWidth()
            .testTag("chat.permissionCard")
            // A blocking question that appears without the user acting must announce itself: the composer has just
            // gone inert, and a screen-reader user would otherwise find a dead input with no explanation.
            .semantics { liveRegion = LiveRegionMode.Assertive },
    ) {
        HorizontalDivider()
        Column(
            modifier = Modifier
                .fillMaxWidth()
                .background(MaterialTheme.colorScheme.onSurfaceVariant.copy(alpha = 0.08f))
                // Bounded and scrollable rather than truncated. The title below carries no line limit on purpose,
                // and a long command with the keyboard up would otherwise push the composer off the bottom of a
                // short screen. Scrolling keeps the whole question readable; eliding it would not.
                .heightIn(max = 260.dp)
                .verticalScroll(rememberScrollState())
                .padding(12.dp),
            verticalArrangement = Arrangement.spacedBy(8.dp),
        ) {
            Row(
                horizontalArrangement = Arrangement.spacedBy(6.dp),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                Icon(
                    Icons.Filled.Lock,
                    contentDescription = null,
                    tint = MaterialTheme.colorScheme.onSurface,
                    modifier = Modifier.size(18.dp),
                )
                // NO line limit, deliberately: a permission title is usually the command or the path being asked
                // for, and eliding it would mean approving something the user was not shown. This is the one place
                // in the UI where truncation is a safety problem rather than a layout one.
                Text(
                    request.title,
                    style = MaterialTheme.typography.bodyMedium,
                    color = MaterialTheme.colorScheme.onSurface,
                    modifier = Modifier.testTag("chat.permissionCard.title"),
                )
            }
            // FlowRow rather than Row: an agent is free to offer four options with long names, and a card that
            // clipped the deny button would be a safety problem, not a layout one.
            FlowRow(
                modifier = Modifier.fillMaxWidth(),
                horizontalArrangement = Arrangement.spacedBy(8.dp),
                verticalArrangement = Arrangement.spacedBy(4.dp),
            ) {
                for (option in request.options) {
                    val tag = "chat.permissionCard.option.${option.id}"
                    if (option.kind.allows) {
                        Button(onClick = { respond(option.id) }, modifier = Modifier.testTag(tag)) {
                            // Two lines, not one: "Allow always for this tool" and "Allow always for this session"
                            // are real ACP option names that collapse to the same visible string when clipped.
                            Text(option.name, maxLines = 2)
                        }
                    } else {
                        // Reject options carry the error tint on their border as well as their label, matching the
                        // destructive role the Swift gate gives them: declining must never be the button a thumb
                        // reaches for by accident.
                        OutlinedButton(
                            onClick = { respond(option.id) },
                            colors = ButtonDefaults.outlinedButtonColors(
                                contentColor = MaterialTheme.colorScheme.error,
                            ),
                            border = BorderStroke(1.dp, MaterialTheme.colorScheme.error),
                            modifier = Modifier.testTag(tag),
                        ) {
                            Text(option.name, maxLines = 2)
                        }
                    }
                }
                if (request.options.isEmpty()) {
                    // An agent should never ask a question with no answers, but a card with no buttons would leave
                    // the composer disabled with nothing to press - unrecoverable on a phone. Answering with no
                    // option is the ACP "cancelled" outcome, which is a legitimate reply.
                    OutlinedButton(
                        onClick = { respond(null) },
                        modifier = Modifier.testTag("chat.permissionCard.option.dismiss"),
                    ) {
                        Text("Dismiss")
                    }
                }
            }
        }
    }
}
