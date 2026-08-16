package com.abracode.chatview

// Port of Sources/ChatView/ChatHostEvent.swift.
//
// The component's outbound host notifications - the generic replacement for the ActionUI action IDs. The component
// emits; the host decides what (if anything) each event maps to. In the ActionUI add-on the Chat element installs a
// sink that maps each case to its configured *ActionID and dispatches through ActionUIModel.actionHandler.

/**
 * One host-facing chat event. Cases without payload correspond to the former fire-and-forget action IDs; the
 * payload-carrying cases hand the host a JSON string. [Entry] carries the finalized-transcript-entry envelope
 * ({ sequence, type, id, data, updated? }) for incremental persistence, and [ResumeCheckpoint] carries the resume
 * cursor that goes with it.
 */
sealed interface ChatHostEvent {
    data object Send : ChatHostEvent                  // the user submitted a message
    data object Stop : ChatHostEvent                  // the user cancelled an in-flight turn
    data object Attach : ChatHostEvent                // the user tapped the composer's attach button
    data object MessageFinalized : ChatHostEvent      // a message (user or agent) reached its final form
    data object Error : ChatHostEvent                 // a transport / parse error surfaced in the transcript
    data object ToolApprovalRequested : ChatHostEvent // an agent asked for tool permission
    data class Entry(val json: String) : ChatHostEvent // one finalized transcript entry (never streaming deltas)

    /**
     * A resumable transport's cursor, as `{"afterSeq":<int>,"sessionId":"<id>"}` (sorted keys, no whitespace, the
     * same canonical encoding as [Entry]).
     *
     * ONLY DELIVERED WHEN [ChatConfiguration.emitsEntryEvents] IS TRUE. This case pairs with [Entry]: the cursor says
     * how far the entries you stored reach, so a host that is not storing entries is not offered one. If you are
     * persisting a transcript and never see a checkpoint, that flag is why.
     *
     * Emitted only at turn boundaries, never mid-stream: that is the only moment at which the transcript is
     * quiescent, so the cursor and the entries the host has stored describe the same instant. On the next launch the
     * host injects the persisted transcript through its content channel AND this cursor through the transport
     * config, and the transport resumes from it instead of replaying the session from the beginning.
     *
     * PERSIST IT ATOMICALLY WITH THE TRANSCRIPT. A cursor newer than the transcript it was stored with silently
     * loses the entries in between; an older one duplicates them. The component cannot check this - it never sees
     * what the host restored - so it is the host's invariant to keep. Storing neither half is always safe: the
     * transport then replays the whole session, which is exactly what a fresh device does.
     */
    data class ResumeCheckpoint(val json: String) : ChatHostEvent
}

/** The host's event sink. Called on the main thread, in transcript order. */
typealias ChatHostEventSink = (ChatHostEvent) -> Unit
