package com.abracode.chatview

// Port of Sources/ChatView/ChatHostEvent.swift.
//
// The component's outbound host notifications - the generic replacement for the ActionUI action IDs. The component
// emits; the host decides what (if anything) each event maps to. In the ActionUI add-on the Chat element installs a
// sink that maps each case to its configured *ActionID and dispatches through ActionUIModel.actionHandler.

/**
 * One host-facing chat event. Cases without payload correspond to the former fire-and-forget action IDs; [Entry]
 * carries the finalized-transcript-entry JSON envelope ({ sequence, type, id, data, updated? }) for incremental
 * persistence.
 */
sealed interface ChatHostEvent {
    data object Send : ChatHostEvent                  // the user submitted a message
    data object Stop : ChatHostEvent                  // the user cancelled an in-flight turn
    data object Attach : ChatHostEvent                // the user tapped the composer's attach button
    data object MessageFinalized : ChatHostEvent      // a message (user or agent) reached its final form
    data object Error : ChatHostEvent                 // a transport / parse error surfaced in the transcript
    data object ToolApprovalRequested : ChatHostEvent // an agent asked for tool permission
    data class Entry(val json: String) : ChatHostEvent // one finalized transcript entry (never streaming deltas)
}

/** The host's event sink. Called on the main thread, in transcript order. */
typealias ChatHostEventSink = (ChatHostEvent) -> Unit
