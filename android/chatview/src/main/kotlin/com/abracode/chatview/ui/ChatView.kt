package com.abracode.chatview.ui

// A6/A7 Compose chat view - the public entry point. Owns the ChatStore lifecycle, derives the per-item layout
// (run grouping + day separators + row contexts), renders the keyed LazyColumn (paging sentinel, load-earlier
// header, item rows, typing / awaiting indicators, bottom sentinel), and runs the direct-signal scroll-pin
// sampler (plan divergence D5): a bottom-sentinel + drag-interaction detector decides pinning, pinned follow
// chases new content non-animated, prepends hold position, a generation bump resets, near-top requests paging,
// and a jump-to-latest pill + reply-jump highlight round it out. The composer (A7) sits below, unless readOnly.

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.interaction.DragInteraction
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.ArrowDownward
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.derivedStateOf
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.runtime.snapshotFlow
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.unit.dp
import com.abracode.chatview.ChatConfiguration
import com.abracode.chatview.ChatContentSource
import com.abracode.chatview.ChatHostEventSink
import com.abracode.chatview.ChatItem
import com.abracode.chatview.ChatLogger
import com.abracode.chatview.ChatStore
import com.abracode.chatview.ChatTranscriptLayout
import com.abracode.chatview.ConsoleChatLogger
import kotlinx.coroutines.launch

// The reply-excerpt ellipsis (U+2026), kept as a code point so the source stays ASCII (matches ChatView.swift).
private val ELLIPSIS = String(Character.toChars(0x2026))

/**
 * The Chat component's view. Constructs and owns a ChatStore for the given configuration, renders its transcript,
 * follows / pins the scroll like a messaging app, and (unless readOnly) hosts the composer below - input, attach,
 * and a Send button that swaps to Stop while a turn is in flight, with reply / edit banners driven by the row menu.
 */
// The store is `remember`ed with NO keys, deliberately: it owns the transport, the transcript, and the host-event
// sink for the element's whole lifetime, and re-creating it on an argument change would drop a live session. The
// consequence for a HOST is that a changed `configuration` / `contentSource` / `hostEvents` is ignored once the
// view is composed - to swap any of them, rebuild the view under `key(...)` (as the demo's Agent screen does with
// its generation counter), or inject the change through the content source's config channel, which is the seam
// built for exactly this.
@Composable
fun ChatView(
    configuration: ChatConfiguration,
    logger: ChatLogger = ConsoleChatLogger(),
    contentSource: ChatContentSource? = null,
    hostEvents: ChatHostEventSink? = null,
    modifier: Modifier = Modifier,
) {
    // A composition-scoped launcher for the view's OWN scroll animations (jump pill, reply-jump). The STORE is given
    // its own default scope (SupervisorJob + Main.immediate), NOT this one: teardown()'s `transport.stop()` launches
    // on the store scope and must survive the view leaving composition - a rememberCoroutineScope would be cancelled
    // on dispose before the stop runs, leaking the transport (connection / subprocess).
    val uiScope = rememberCoroutineScope()
    val store = remember {
        ChatStore(
            config = configuration,
            logger = logger,
            contentSource = contentSource,
            hostEvents = hostEvents,
        )
    }
    DisposableEffect(store) {
        store.start()
        onDispose { store.teardown() }
    }

    val listState = rememberLazyListState()
    val density = LocalDensity.current
    val thresholdPx = with(density) { 24.dp.toPx() }
    val nearTopPx = with(density) { 200.dp.toPx() }

    var isPinnedToBottom by remember { mutableStateOf(true) }
    // A user-initiated scroll (the drag AND the fling that follows finger-lift) may RELEASE the pin; a programmatic
    // scroll never does. A DragInteraction.Start marks the gesture user-driven and it stays marked through the fling
    // until the list fully settles (isScrollInProgress -> false). A programmatic animate/scroll issues no Start, so
    // it never counts as user intent. (DragInteraction.Stop alone would clear at finger-lift, before the fling moves
    // the content past the threshold - the common flick-to-read gesture would then never unpin.)
    var userScrollActive by remember { mutableStateOf(false) }
    var highlightedItemID by remember { mutableStateOf<String?>(null) }
    var awaitingLong by remember { mutableStateOf(false) }
    // Composer reply / edit state (view-local, dual alignment). Reply / edit put a banner above the composer; the row
    // context menu sets them, the composer's cancel / submit clear them. Mirrors ChatView.swift's replyTarget /
    // editTargetID @State.
    var replyTarget by remember { mutableStateOf<ReplyTarget?>(null) }
    var editTargetID by remember { mutableStateOf<String?>(null) }

    // The LazyColumn item count (header + sentinels + indicators + rows). Read in composition so the effects below
    // capture a fresh value; used to target the bottom sentinel and to translate an item id into a lazy index.
    val typingVisible = store.typingParticipants.isNotEmpty()
    val lazyItemCount = 1 +
        (if (store.isLoadingEarlier) 1 else 0) +
        store.items.size +
        (if (typingVisible) 1 else 0) +
        (if (awaitingLong) 1 else 0) +
        1
    val bottomIndex = maxOf(0, lazyItemCount - 1)

    fun lazyIndexOfItem(id: String): Int {
        val itemIndex = store.items.indexOfFirst { it.id == id }
        if (itemIndex < 0) return -1
        var offset = 1 // top sentinel
        if (store.isLoadingEarlier) offset += 1
        return offset + itemIndex
    }

    // --- Scroll-pin sampler (direct-signal). ---

    // A drag marks the gesture user-driven; it stays marked through the ensuing fling until the list settles.
    LaunchedEffect(listState) {
        listState.interactionSource.interactions.collect { interaction ->
            if (interaction is DragInteraction.Start) userScrollActive = true
        }
    }
    LaunchedEffect(listState) {
        snapshotFlow { listState.isScrollInProgress }.collect { inProgress ->
            if (!inProgress) userScrollActive = false
        }
    }

    // null = an unmeasured / zero-height sample: IGNORE it - never re-pin a scrolled-up reader on a transient 0,
    // matching Swift's ChatScrollPin `.ignore` on a zero container (ChatScrollPin.swift:60).
    val atBottom by remember {
        derivedStateOf {
            val info = listState.layoutInfo
            if (info.viewportEndOffset == 0) return@derivedStateOf null
            val last = info.visibleItemsInfo.lastOrNull() ?: return@derivedStateOf false
            last.index == info.totalItemsCount - 1 && (last.offset + last.size) <= info.viewportEndOffset + thresholdPx
        }
    }

    LaunchedEffect(atBottom, userScrollActive) {
        when (atBottom) {
            true -> isPinnedToBottom = true
            false -> if (userScrollActive) isPinnedToBottom = false
            null -> {}
        }
    }
    LaunchedEffect(isPinnedToBottom) { store.setPinnedToBottom(isPinnedToBottom) }

    // Awaiting-reply spinner: only after the prompt has been outstanding 2s with nothing streaming.
    LaunchedEffect(store.awaitingReply, store.isStreaming) {
        awaitingLong = false
        if (store.awaitingReply && !store.isStreaming) {
            kotlinx.coroutines.delay(2000)
            awaitingLong = true
        }
    }

    // Pinned follow / prepend: chase new content (non-animated) while pinned; a prepend holds position (keyed rows).
    LaunchedEffect(listState) {
        var prevCount = 0
        var prevFirstId: String? = null
        snapshotFlow { store.items.toList() }.collect { list ->
            val size = list.size
            val firstId = list.firstOrNull()?.id
            val prepended = prevCount > 0 && size > prevCount && firstId != prevFirstId
            if (!prepended && isPinnedToBottom) {
                val count = 1 +
                    (if (store.isLoadingEarlier) 1 else 0) +
                    size +
                    (if (store.typingParticipants.isNotEmpty()) 1 else 0) +
                    (if (awaitingLong) 1 else 0) +
                    1
                listState.scrollToItem(maxOf(0, count - 1))
            }
            prevCount = size
            prevFirstId = firstId
        }
    }
    // Indicator rows (typing / awaiting) also grow the list; keep following them while pinned.
    LaunchedEffect(awaitingLong, typingVisible) {
        if (isPinnedToBottom) listState.scrollToItem(bottomIndex)
    }

    // Generation reset: a wholesale transcript replacement re-pins to the bottom.
    LaunchedEffect(store.transcriptGeneration) {
        isPinnedToBottom = true
        listState.scrollToItem(bottomIndex)
    }

    // Near-top paging: only when scrolled back (not pinned) and hovering the very top.
    val nearTop by remember {
        derivedStateOf {
            listState.firstVisibleItemIndex == 0 &&
                listState.firstVisibleItemScrollOffset < nearTopPx &&
                !isPinnedToBottom
        }
    }
    LaunchedEffect(nearTop) { if (nearTop) store.scrolledNearTop() }

    // Reply-jump highlight fades after 1s.
    LaunchedEffect(highlightedItemID) {
        val id = highlightedItemID
        if (id != null) {
            kotlinx.coroutines.delay(1000)
            if (highlightedItemID == id) highlightedItemID = null
        }
    }

    fun jumpTo(id: String) {
        highlightedItemID = id
        isPinnedToBottom = false
        uiScope.launch {
            val idx = lazyIndexOfItem(id)
            if (idx >= 0) listState.animateScrollToItem(idx)
        }
    }

    // Composer reply / edit entry points (invoked from the row context menu). A reply quotes the message (one-line
    // excerpt, capped); an edit prefills the draft with the message text. Each clears the other, mirroring
    // ChatView.swift beginReply / beginEdit.
    fun replyExcerpt(text: String): String {
        val oneLine = text.replace("\n", " ").trim()
        return if (oneLine.length > 120) oneLine.take(120) + ELLIPSIS else oneLine
    }
    fun beginReply(id: String) {
        val message = (store.items.firstOrNull { it.id == id } as? ChatItem.Message)?.message ?: return
        editTargetID = null
        val sender = resolveName(message.senderName, message.senderID, message.role, store.participants, configuration)
        replyTarget = ReplyTarget(id = id, excerpt = replyExcerpt(message.text), sender = sender)
    }
    fun beginEdit(id: String) {
        val message = (store.items.firstOrNull { it.id == id } as? ChatItem.Message)?.message ?: return
        replyTarget = null
        editTargetID = id
        store.draft = message.text
    }

    // --- Layout Info derivation + row contexts. ---

    val itemsSnapshot = store.items.toList()
    val participantsSnapshot = store.participants.toList()
    // Key the run/day layout on the text-independent grouping signature so a streaming text delta reuses the cached
    // layout instead of re-parsing timestamps + re-grouping the whole transcript each frame.
    val signatures = itemsSnapshot.map { groupingSignature(it, participantsSnapshot) }
    val infos = remember(signatures) {
        ChatTranscriptLayout.layout(signatures.map { it.toLayoutInput() })
    }
    val contexts = remember(itemsSnapshot, participantsSnapshot, infos) {
        itemsSnapshot.mapIndexed { index, item ->
            val info = infos.getOrElse(index) { ChatTranscriptLayout.Info(true, true, false) }
            buildRowContext(item, info, participantsSnapshot, configuration)
        }
    }
    val showsSenderNames = configuration.showRoleLabels || participantsSnapshot.count { it.isSelf != true } > 1

    // --- Render. ---

    Column(modifier = modifier.fillMaxSize()) {
      Box(modifier = Modifier.weight(1f).fillMaxWidth()) {
        BoxWithConstraints(modifier = Modifier.fillMaxSize()) {
            val maxBubbleWidth = maxOf(120.dp, (maxWidth - 24.dp) * 0.75f)
            // Remembered on the gates + width so its identity is stable across streaming flushes; an unstable actions
            // bundle would force every visible row to recompose each frame even when its own ctx is unchanged.
            val actions = remember(
                configuration, showsSenderNames, maxBubbleWidth,
                store.canReact, store.canReply, store.canEditMessages, store.canDeleteMessages,
            ) {
                DualRowActions(
                    config = configuration,
                    showsSenderNames = showsSenderNames,
                    maxBubbleWidth = maxBubbleWidth,
                    canReact = store.canReact,
                    canReply = store.canReply,
                    canEdit = store.canEditMessages,
                    canDelete = store.canDeleteMessages,
                    toggleReaction = { id, emoji -> store.toggleReaction(id, emoji) },
                    reply = { id -> beginReply(id) },
                    edit = { id -> beginEdit(id) },
                    delete = { id -> store.deleteMessage(id) },
                    jumpTo = { id -> jumpTo(id) },
                    cancelTransfer = { id -> store.cancelFileTransfer(id) },
                    resend = { id -> store.resendMessage(id) },
                )
            }

            LazyColumn(
                state = listState,
                modifier = Modifier.fillMaxSize().testTag("chat.transcript"),
                contentPadding = PaddingValues(12.dp),
            ) {
                item(key = "chat.topSentinel") { Spacer(Modifier.height(1.dp)) }
                if (store.isLoadingEarlier) {
                    item(key = "chat.loadEarlier") { LoadEarlierHeader() }
                }
                items(count = contexts.size, key = { contexts[it].id }) { index ->
                    val ctx = contexts[index]
                    DualTranscriptRow(ctx, actions, highlighted = ctx.id == highlightedItemID)
                }
                if (typingVisible) {
                    item(key = "chat.typing") { TypingIndicatorRow(store.typingParticipants) }
                }
                if (awaitingLong) {
                    item(key = "chat.awaiting") { AwaitingIndicatorRow() }
                }
                item(key = "chat.bottomSentinel") { Spacer(Modifier.height(1.dp)) }
            }
        }

        if (!isPinnedToBottom) {
            Surface(
                shape = CircleShape,
                color = MaterialTheme.colorScheme.secondaryContainer,
                shadowElevation = 4.dp,
                modifier = Modifier
                    .align(Alignment.BottomEnd)
                    .padding(12.dp)
                    .clip(CircleShape)
                    .clickable {
                        uiScope.launch {
                            isPinnedToBottom = true
                            listState.animateScrollToItem(bottomIndex)
                        }
                    },
            ) {
                Icon(
                    Icons.Filled.ArrowDownward,
                    contentDescription = "Jump to latest",
                    tint = MaterialTheme.colorScheme.onSecondaryContainer,
                    modifier = Modifier.padding(12.dp),
                )
            }
        }
      }

      // The agent's blocking question sits between the transcript and the composer (ChatView.swift:90), whose
      // input pauses while it is up. Shown even in readOnly: a restored transcript never carries one, and a live
      // session that asks must be answerable - an unanswered request stalls the agent, not just this view.
      store.pendingPermissions.firstOrNull()?.let { request ->
          PermissionCard(request = request) { optionID ->
              store.respondToPermission(request.id, optionID)
          }
      }

      // readOnly is the history-viewer mode: no composer (ChatView.swift:82). Otherwise the composer sits below the
      // transcript, gating its own enablement on config / connectivity.
      if (!configuration.readOnly) {
          Composer(
              store = store,
              config = configuration,
              replyTarget = replyTarget,
              editTargetID = editTargetID,
              onCancelReply = { replyTarget = null },
              onCancelEdit = { editTargetID = null; store.draft = "" },
              onReplySubmitted = { replyTarget = null },
              onEditSubmitted = { editTargetID = null },
          )
      }
    }
}

@Composable
private fun LoadEarlierHeader() {
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .padding(vertical = 8.dp),
        horizontalArrangement = Arrangement.spacedBy(8.dp, Alignment.CenterHorizontally),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        CircularProgressIndicator(modifier = Modifier.size(16.dp), strokeWidth = 2.dp)
        Text("Loading earlier...", style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
    }
}

@Composable
private fun TypingIndicatorRow(participants: List<ChatStore.TypingParticipant>) {
    val names = participants.mapNotNull { it.name?.takeIf { n -> n.isNotEmpty() } }
    val label = when {
        names.isEmpty() -> "typing..."
        names.size == 1 -> "${names.first()} is typing..."
        else -> "${names.joinToString(", ")} are typing..."
    }
    Row(modifier = Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.Start) {
        Text(
            label,
            style = MaterialTheme.typography.bodySmall,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
            modifier = Modifier
                .clip(androidx.compose.foundation.shape.RoundedCornerShape(14.dp))
                .background(MaterialTheme.colorScheme.onSurfaceVariant.copy(alpha = 0.14f))
                .padding(horizontal = 10.dp, vertical = 7.dp),
        )
    }
}

@Composable
private fun AwaitingIndicatorRow() {
    Row(modifier = Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.Start) {
        Text(
            "...",
            style = MaterialTheme.typography.bodyMedium,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
            modifier = Modifier
                .clip(androidx.compose.foundation.shape.RoundedCornerShape(14.dp))
                .background(MaterialTheme.colorScheme.onSurfaceVariant.copy(alpha = 0.14f))
                .padding(horizontal = 10.dp, vertical = 7.dp),
        )
    }
}
