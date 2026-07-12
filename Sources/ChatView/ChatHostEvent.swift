// Sources/ChatView/ChatHostEvent.swift
//
// The component's outbound host notifications - the generic replacement for the ActionUI
// action IDs. The component emits; the host decides what (if anything) each event maps to.
// In the ActionUI add-on, the Chat element installs a sink that maps each case to its
// configured *ActionID and dispatches through ActionUIModel.actionHandler.

import Foundation

/// One host-facing chat event. Cases without payload correspond to the former fire-and-
/// forget action IDs; `.entry` carries the finalized-transcript-entry JSON envelope
/// ({ sequence, type, id, data, updated? }) for incremental persistence.
public enum ChatHostEvent: Sendable {
    case send                    // the user submitted a message
    case stop                    // the user cancelled an in-flight turn
    case attach                  // the user tapped the composer's attach button
    case messageFinalized        // a message (user or agent) reached its final form
    case error                   // a transport / parse error surfaced in the transcript
    case toolApprovalRequested   // an agent asked for tool permission
    case entry(json: String)     // one finalized transcript entry (never streaming deltas)
}

/// The host's event sink. Called on the main actor, in transcript order.
public typealias ChatHostEventSink = @MainActor (ChatHostEvent) -> Void
