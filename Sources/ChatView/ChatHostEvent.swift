// Sources/ChatView/ChatHostEvent.swift
//
// The component's outbound host notifications - the generic replacement for the ActionUI
// action IDs. The component emits; the host decides what (if anything) each event maps to.
// In the ActionUI add-on, the Chat element installs a sink that maps each case to its
// configured *ActionID and dispatches through ActionUIModel.actionHandler.

import Foundation

/// One host-facing chat event. Cases without payload correspond to the former fire-and-
/// forget action IDs; the payload-carrying cases hand the host a JSON string. `.entry`
/// carries the finalized-transcript-entry envelope ({ sequence, type, id, data, updated? })
/// for incremental persistence, and `.resumeCheckpoint` carries the resume cursor that goes
/// with it.
public enum ChatHostEvent: Sendable {
    case send                    // the user submitted a message
    case stop                    // the user cancelled an in-flight turn
    case attach                  // the user tapped the composer's attach button
    case messageFinalized        // a message (user or agent) reached its final form
    case error                   // a transport / parse error surfaced in the transcript
    case toolApprovalRequested   // an agent asked for tool permission
    case entry(json: String)     // one finalized transcript entry (never streaming deltas)

    /// A resumable transport's cursor, as `{"afterSeq":<int>,"sessionId":"<id>"}` (sorted keys,
    /// no whitespace, same encoder settings as `.entry`).
    ///
    /// ONLY DELIVERED WHEN `ChatConfiguration.emitsEntryEvents` IS TRUE. This case pairs with
    /// `.entry`: the cursor says how far the entries you stored reach, so a host that is not
    /// storing entries is not offered one. If you are persisting a transcript and never see a
    /// checkpoint, that flag is why.
    ///
    /// Emitted only at turn boundaries, never mid-stream: that is the only moment at which the
    /// transcript is quiescent, so the cursor and the entries the host has stored describe the
    /// same instant. On the next launch the host injects the persisted transcript through its
    /// content channel AND this cursor through the transport config, and the transport resumes
    /// from it instead of replaying the session from the beginning.
    ///
    /// PERSIST IT ATOMICALLY WITH THE TRANSCRIPT. A cursor newer than the transcript it was
    /// stored with silently loses the entries in between; an older one duplicates them. The
    /// component cannot check this - it never sees what the host restored - so it is the host's
    /// invariant to keep. Storing neither half is always safe: the transport then replays the
    /// whole session, which is exactly what a fresh device does.
    case resumeCheckpoint(json: String)
}

/// The host's event sink. Called on the main actor, in transcript order.
public typealias ChatHostEventSink = @MainActor (ChatHostEvent) -> Void
