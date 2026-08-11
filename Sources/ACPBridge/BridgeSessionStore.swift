// Sources/ACPBridge/BridgeSessionStore.swift
//
// The bridge's memory: one append-only, sequence-stamped JSONL log per session, plus the
// registry of who is currently listening to each one.
//
// This is the piece that makes a phone a viable ACP client. A local stdio transport can
// assume the client is alive for the whole session - if it dies, the agent dies with it. A
// remote one cannot: the agent keeps working while the phone is in a pocket, backgrounded,
// or terminated by the OS, and when the client comes back it needs everything it missed, in
// order, exactly once. That is what the log is for. Replay is not a separate history format
// or a reconciliation protocol; it is the same notification stream, re-sent from disk.
//
// No networking in this file on purpose: subscribers are opaque sinks. That keeps the
// ordering rules (below) testable without a socket.

#if os(macOS)

import Foundation
import ChatView

/// Where a session's live traffic goes. One per attached client connection.
package typealias BridgeEventSink = @Sendable (Data) -> Void

/// A session's lifecycle state. Ended sessions stay readable (and replayable) until the
/// retention sweep removes them; they just cannot be prompted.
package enum BridgeSessionState: String, Sendable {
    case live
    case ended
}

/// What a client learns at attach time, snapshotted under the same lock acquisition that
/// registered its sink. See `attach` for why those two must not be separate steps.
package struct BridgeAttachSnapshot: Sendable {
    package let sessionID: String
    package let state: BridgeSessionState
    package let endedReason: String?
    package let latestSeq: Int
    package let activeTurn: Int?
}

/// One row of `bridge/sessions`.
package struct BridgeSessionSummary: Sendable {
    package let sessionID: String
    package let state: BridgeSessionState
    package let createdAt: Date
    package let lastActivityAt: Date
    package let latestSeq: Int
    package let title: String
}

package enum BridgeStoreError: Error, CustomStringConvertible {
    case unknownSession(String)

    package var description: String {
        switch self {
        case .unknownSession(let id):
            return "unknown session '\(id)'"
        }
    }
}

package final class BridgeSessionStore: @unchecked Sendable {

    /// A subscriber is created in `.buffering` and promoted to `.live` only after its replay
    /// has been written. Live appends that land during the replay are held here rather than
    /// racing ahead of it - see `attach`.
    private enum Subscription {
        case buffering(pending: [(seq: Int, line: Data)], sink: BridgeEventSink)
        case live(sink: BridgeEventSink)

        var sink: BridgeEventSink {
            switch self {
            case .buffering(_, let sink), .live(let sink):
                return sink
            }
        }
    }

    private final class Session {
        let id: String
        let logURL: URL
        /// Opened on the FIRST append, not at registration. `loadFromDisk` indexes every log
        /// inside the retention window, and holding a write descriptor for each of them for the
        /// process lifetime is a file-descriptor leak proportional to how long the bridge has
        /// been useful. Ended sessions never append, so they never open one.
        var handle: FileHandle?
        var state: BridgeSessionState = .live
        var endedReason: String?
        var latestSeq = 0
        var activeTurn: Int?
        var nextTurn = 1
        var nextPermission = 1
        var createdAt: Date
        var lastActivityAt: Date
        var title = ""
        var configOptions: [[String: Any]] = []
        var subscribers: [UUID: Subscription] = [:]

        init(id: String, logURL: URL, createdAt: Date) {
            self.id = id
            self.logURL = logURL
            self.createdAt = createdAt
            self.lastActivityAt = createdAt
        }

        /// Opens the append handle on demand. Returns nil if the log cannot be opened, which
        /// `append` treats as "fan out but do not claim it is replayable".
        func appendHandle() -> FileHandle? {
            if let handle {
                return handle
            }
            guard let opened = try? FileHandle(forWritingTo: logURL) else {
                return nil
            }
            try? opened.seekToEnd()
            handle = opened
            return opened
        }
    }

    /// One lock for the whole registry. Sessions are few and every critical section is a
    /// handful of dictionary operations plus one buffered write, so per-session locks would
    /// buy nothing but a lock-ordering hazard between "append to session A" and "list all".
    private let lock = NSLock()
    private var sessions: [String: Session] = [:]

    private let logDirectory: URL
    private let maxLogEntriesPerSession: Int
    private let logger: any ChatLogger

    /// Force-ending a session because its log hit the cap has to happen OUTSIDE the append
    /// that discovered it (the caller has to fan the session_ended entry out too), so append
    /// reports it and ACPBridge acts on it.
    package struct AppendResult: Sendable {
        package let seq: Int
        package let line: Data
        package let overflowed: Bool
    }

    package init(logDirectory: URL,
                 maxLogEntriesPerSession: Int,
                 logger: any ChatLogger) {
        self.logDirectory = logDirectory
        self.maxLogEntriesPerSession = maxLogEntriesPerSession
        self.logger = logger
    }

    // MARK: - Session lifecycle

    /// Registers a session the agent just created. Returns false if the id is already known
    /// (an agent handing out a duplicate session id would otherwise silently interleave two
    /// conversations into one log).
    @discardableResult
    package func register(sessionID: String, createdAt: Date = Date()) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if sessions[sessionID] != nil {
            return false
        }
        // Two DIFFERENT ids can sanitize to the same file name ("a/b" and "a.b" both become
        // "a_b"), and the truncating open would then wipe the first session's log while both
        // kept writing with independent seq counters - exactly the interleaving the raw-id
        // check is meant to prevent. The file name is the real identity, so dedupe on it.
        let url = logURL(for: sessionID)
        if sessions.values.contains(where: { $0.logURL == url }) {
            logger.log("acp-bridge: refusing session '\(sessionID)'; its log name collides with a live session", .error)
            return false
        }
        guard let session = openSession(id: sessionID, url: url, createdAt: createdAt, truncate: true) else {
            return false
        }
        sessions[sessionID] = session
        return true
    }

    private func openSession(id: String, url: URL, createdAt: Date, truncate: Bool) -> Session? {
        do {
            try FileManager.default.createDirectory(at: logDirectory, withIntermediateDirectories: true)
            if truncate || !FileManager.default.fileExists(atPath: url.path) {
                FileManager.default.createFile(atPath: url.path, contents: nil,
                                               attributes: [.posixPermissions: 0o600])
            }
            return Session(id: id, logURL: url, createdAt: createdAt)
        } catch {
            logger.log("acp-bridge: could not open the log for session '\(id)': \(error)", .error)
            return nil
        }
    }

    /// The log file name is derived from the session id, so an agent that hands out an id
    /// containing a path separator must not be able to write outside the log directory.
    private func logURL(for sessionID: String) -> URL {
        let safe = sessionID.map { character -> Character in
            character.isLetter || character.isNumber || character == "-" || character == "_" ? character : "_"
        }
        return logDirectory.appendingPathComponent(String(safe) + ".jsonl")
    }

    package func exists(sessionID: String) -> Bool {
        lock.withLock { sessions[sessionID] != nil }
    }

    package func state(of sessionID: String) -> BridgeSessionState? {
        lock.withLock { sessions[sessionID]?.state }
    }

    /// Marks a session ended. Idempotent: the first reason wins, so an agent exit that races
    /// a log overflow does not rewrite the reason the clients were already told.
    @discardableResult
    package func markEnded(sessionID: String, reason: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard let session = sessions[sessionID], session.state == .live else {
            return false
        }
        session.state = .ended
        session.endedReason = reason
        session.activeTurn = nil
        session.lastActivityAt = Date()
        return true
    }

    package func liveSessionIDs() -> [String] {
        lock.withLock { sessions.values.filter { $0.state == .live }.map(\.id) }
    }

    // MARK: - Turns

    /// Claims the next turn number for a session, refusing when one is already in flight or
    /// the session has ended.
    package func beginTurn(sessionID: String) -> Int? {
        lock.lock()
        defer { lock.unlock() }
        guard let session = sessions[sessionID], session.state == .live, session.activeTurn == nil else {
            return nil
        }
        let turn = session.nextTurn
        session.nextTurn += 1
        session.activeTurn = turn
        session.lastActivityAt = Date()
        return turn
    }

    /// Clears the active turn, reporting whether THIS call is the one that ended it.
    ///
    /// The return value is what makes invariant I8 ("exactly one turn_ended per accepted
    /// turn") enforceable: several paths race to end the same turn - the prompt task
    /// resolving, the agent dying, a log overflow - and only the winner may log the terminal
    /// entry. Without this the agent-death path and the prompt-task path both logged one, and
    /// the second landed AFTER session_ended.
    @discardableResult
    package func endTurn(sessionID: String, turn: Int) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard let session = sessions[sessionID], session.activeTurn == turn else {
            return false
        }
        session.activeTurn = nil
        session.lastActivityAt = Date()
        return true
    }

    package func activeTurn(sessionID: String) -> Int? {
        lock.withLock { sessions[sessionID]?.activeTurn }
    }

    /// The session's option set, captured from `session/new` so a REATTACHING client gets it
    /// back. Without this an attach always answered with an empty list and a reconnected
    /// client silently lost its model / mode menus.
    package func setConfigOptions(sessionID: String, options: [[String: Any]]) {
        lock.lock()
        defer { lock.unlock() }
        sessions[sessionID]?.configOptions = options
    }

    package func configOptions(sessionID: String) -> [[String: Any]] {
        lock.withLock { sessions[sessionID]?.configOptions ?? [] }
    }

    package func nextPermissionKey(sessionID: String) -> String? {
        lock.lock()
        defer { lock.unlock() }
        guard let session = sessions[sessionID] else {
            return nil
        }
        let key = "perm-\(session.nextPermission)"
        session.nextPermission += 1
        return key
    }

    /// The first prompt becomes the session's title in `bridge/sessions`.
    package func noteTitleIfEmpty(sessionID: String, text: String) {
        lock.lock()
        defer { lock.unlock() }
        guard let session = sessions[sessionID], session.title.isEmpty else {
            return
        }
        let flattened = text.replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        session.title = flattened.count > 80 ? String(flattened.prefix(80)) : flattened
    }

    // MARK: - The log

    /// Assigns the next seq, stamps it into `params`, writes the JSONL line, hands the stamped
    /// line to every LIVE subscriber, and buffers it for every attaching one - all under ONE
    /// lock acquisition.
    ///
    /// That single acquisition is the invariant the whole feature rests on. If seq assignment,
    /// the disk write, and the fan-out could interleave, two concurrent appends could reach a
    /// client in the opposite order from the log, and a client that reconnected in between
    /// would see a different history than one that stayed connected. Everything that a client
    /// could ever observe about ordering is decided here, once.
    @discardableResult
    package func append(sessionID: String, method: String, params: [String: Any],
                        allowWhenEnded: Bool = false) -> AppendResult? {
        lock.lock()
        defer { lock.unlock() }
        guard let session = sessions[sessionID] else {
            return nil
        }
        // Nothing may be logged after the session's terminal entry. Without this an agent that
        // died mid-stream, or a log that hit its cap, kept accepting appends - so clients saw
        // events AFTER bridge/session_ended and the "cap" capped nothing. `allowWhenEnded` is
        // for the terminal entry itself, which is written by the call that does the ending.
        guard session.state == .live || allowWhenEnded else {
            return nil
        }

        let seq = session.latestSeq + 1
        var stamped = params
        stamped["sessionId"] = sessionID
        stamped["seq"] = seq
        let envelope: [String: Any] = ["jsonrpc": "2.0", "method": method, "params": stamped]
        guard JSONSerialization.isValidJSONObject(envelope),
              let data = try? JSONSerialization.data(withJSONObject: envelope, options: [.sortedKeys]) else {
            // Do not burn a seq on a payload we cannot serialize: a client detecting loss by a
            // sequence gap would false-positive forever after.
            logger.log("acp-bridge: dropping unserializable '\(method)' for session '\(sessionID)'", .error)
            return nil
        }

        session.latestSeq = seq
        session.lastActivityAt = Date()
        var line = data
        line.append(0x0A)
        do {
            guard let handle = session.appendHandle() else {
                throw BridgeStoreError.unknownSession(sessionID)
            }
            try handle.write(contentsOf: line)
        } catch {
            // A failed write means this entry is not replayable. Fan it out anyway - attached
            // clients are better off with the event than without it - but say so loudly,
            // because a reattach after this point will have a hole.
            logger.log("acp-bridge: log write failed for session '\(sessionID)' at seq \(seq): \(error)", .error)
        }

        for (id, subscription) in session.subscribers {
            switch subscription {
            case .live(let sink):
                sink(data)
            case .buffering(var pending, let sink):
                pending.append((seq: seq, line: data))
                session.subscribers[id] = .buffering(pending: pending, sink: sink)
            }
        }

        return AppendResult(seq: seq, line: data, overflowed: seq >= maxLogEntriesPerSession)
    }

    // MARK: - Attach and replay

    /// Registers a sink and snapshots the session in one lock acquisition, then streams the
    /// missed tail from disk, then promotes the sink to live.
    ///
    /// The three steps exist because a naive "register, then replay" delivers live events
    /// before the replay that precedes them, and "replay, then register" drops everything
    /// appended in between. Buffering across the replay is what makes the union of replayed
    /// and live events gapless AND duplicate-free, which is the property `afterSeq` depends on.
    package func attach(sessionID: String,
                        afterSeq: Int,
                        sink: @escaping BridgeEventSink) throws -> (snapshot: BridgeAttachSnapshot, subscriber: UUID) {
        let subscriber = UUID()
        let snapshot: BridgeAttachSnapshot = try lock.withLock {
            guard let session = sessions[sessionID] else {
                throw BridgeStoreError.unknownSession(sessionID)
            }
            session.subscribers[subscriber] = .buffering(pending: [], sink: sink)
            return BridgeAttachSnapshot(sessionID: sessionID,
                                        state: session.state,
                                        endedReason: session.endedReason,
                                        latestSeq: session.latestSeq,
                                        activeTurn: session.activeTurn)
        }
        return (snapshot, subscriber)
    }

    /// Streams the log entries with `afterSeq < seq <= throughSeq` to `sink`, then flushes
    /// anything that was appended while we were reading and marks the subscriber live.
    package func replayAndGoLive(sessionID: String,
                                 subscriber: UUID,
                                 afterSeq: Int,
                                 throughSeq: Int) {
        var replayedThrough = afterSeq
        if throughSeq > afterSeq, let sink = currentSink(sessionID: sessionID, subscriber: subscriber) {
            forEachLoggedLine(sessionID: sessionID) { seq, line in
                guard seq > afterSeq, seq <= throughSeq else {
                    return
                }
                sink(line)
                replayedThrough = max(replayedThrough, seq)
            }
        }

        lock.lock()
        defer { lock.unlock() }
        guard let session = sessions[sessionID],
              case .buffering(let pending, let sink) = session.subscribers[subscriber] else {
            return
        }
        for entry in pending where entry.seq > replayedThrough {
            sink(entry.line)
        }
        session.subscribers[subscriber] = .live(sink: sink)
    }

    private func currentSink(sessionID: String, subscriber: UUID) -> BridgeEventSink? {
        lock.withLock { sessions[sessionID]?.subscribers[subscriber]?.sink }
    }

    package func detach(sessionID: String, subscriber: UUID) {
        lock.lock()
        defer { lock.unlock() }
        sessions[sessionID]?.subscribers.removeValue(forKey: subscriber)
    }

    package func detachEverywhere(subscriber: UUID) {
        lock.lock()
        defer { lock.unlock() }
        for session in sessions.values {
            session.subscribers.removeValue(forKey: subscriber)
        }
    }

    /// Reads the session's log line by line, handing each parsed seq and its RAW line to
    /// `body`. The raw line is what gets re-sent: re-serializing a parsed entry could reorder
    /// keys or change number formatting, and a replayed event must be byte-identical to what
    /// the client would have received live.
    private func forEachLoggedLine(sessionID: String, _ body: (Int, Data) -> Void) {
        let url = lock.withLock { sessions[sessionID]?.logURL }
        guard let url, let handle = try? FileHandle(forReadingFrom: url) else {
            return
        }
        defer { try? handle.close() }

        var buffer = Data()
        while true {
            let chunk = (try? handle.read(upToCount: 64 * 1024)) ?? Data()
            if chunk.isEmpty {
                break
            }
            buffer.append(chunk)
            while let newline = buffer.firstIndex(of: 0x0A) {
                let line = Data(buffer[buffer.startIndex..<newline])
                buffer.removeSubrange(buffer.startIndex...newline)
                if let seq = Self.seq(ofLine: line) {
                    body(seq, line)
                }
            }
        }
        if !buffer.isEmpty, let seq = Self.seq(ofLine: buffer) {
            // A trailing line with no newline means the bridge died mid-write. It is still a
            // complete JSON object or it would not parse, so it is safe to replay.
            body(seq, buffer)
        }
    }

    /// Reads the session id out of the first well-formed entry in a log file.
    private static func sessionID(inLogAt url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else {
            return nil
        }
        defer { try? handle.close() }
        guard let head = try? handle.read(upToCount: 64 * 1024), !head.isEmpty else {
            return nil
        }
        let end = head.firstIndex(of: 0x0A) ?? head.endIndex
        let line = Data(head[head.startIndex..<end])
        guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              let params = object["params"] as? [String: Any] else {
            return nil
        }
        return params["sessionId"] as? String
    }

    private static func seq(ofLine line: Data) -> Int? {
        guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              let params = object["params"] as? [String: Any],
              let seq = params["seq"] as? Int else {
            return nil
        }
        return seq
    }

    // MARK: - Restart, listing, retention

    /// Indexes the logs left by a previous run. Every one of them is marked ENDED: the agent
    /// process that owned those sessions is gone, so nothing can add to them. They stay
    /// readable so a client that reattaches after a bridge restart gets its transcript back
    /// instead of an error.
    package func loadFromDisk() {
        let urls = (try? FileManager.default.contentsOfDirectory(at: logDirectory,
                                                                 includingPropertiesForKeys: [.contentModificationDateKey],
                                                                 options: [.skipsHiddenFiles])) ?? []
        for url in urls where url.pathExtension == "jsonl" {
            // The FILE NAME is sanitized, so it is not the session id whenever the agent used a
            // character outside [A-Za-z0-9_-]. Recovering the id from the name would rename the
            // session across a restart, and the client's bridge/attach with the real id would
            // then get "unknown session" with its transcript sitting right there on disk. Every
            // logged entry carries the true id, so read it from the content.
            let sessionID = Self.sessionID(inLogAt: url) ?? url.deletingPathExtension().lastPathComponent
            if lock.withLock({ sessions[sessionID] != nil }) {
                continue
            }
            let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
            let created = (attributes?[.creationDate] as? Date) ?? Date()
            let modified = (attributes?[.modificationDate] as? Date) ?? created
            guard let session = openSession(id: sessionID, url: url, createdAt: created, truncate: false) else {
                continue
            }
            session.state = .ended
            session.endedReason = "bridge_restart"
            session.lastActivityAt = modified
            lock.withLock { sessions[sessionID] = session }

            var latest = 0
            var title = ""
            forEachLoggedLine(sessionID: sessionID) { seq, line in
                latest = max(latest, seq)
                if title.isEmpty,
                   let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                   object["method"] as? String == "bridge/user_message",
                   let params = object["params"] as? [String: Any],
                   let content = params["content"] as? [[String: Any]] {
                    title = content.compactMap { $0["text"] as? String }.joined(separator: " ")
                }
            }
            lock.withLock {
                session.latestSeq = latest
                session.title = title.count > 80 ? String(title.prefix(80)) : title
            }
        }
    }

    package func summaries() -> [BridgeSessionSummary] {
        lock.withLock {
            sessions.values
                .map {
                    BridgeSessionSummary(sessionID: $0.id, state: $0.state, createdAt: $0.createdAt,
                                         lastActivityAt: $0.lastActivityAt, latestSeq: $0.latestSeq,
                                         title: $0.title)
                }
                .sorted { $0.lastActivityAt > $1.lastActivityAt }
        }
    }

    /// Deletes ended sessions whose last activity is older than the retention window. Live
    /// sessions are never swept regardless of age - somebody is still using them.
    @discardableResult
    package func sweepRetention(olderThan days: Int, now: Date = Date()) -> [String] {
        guard days > 0 else {
            return []
        }
        let cutoff = now.addingTimeInterval(-Double(days) * 86_400)
        let doomed: [Session] = lock.withLock {
            let expired = sessions.values.filter { $0.state == .ended && $0.lastActivityAt < cutoff }
            for session in expired {
                sessions.removeValue(forKey: session.id)
            }
            return expired
        }
        for session in doomed {
            try? session.handle?.close()
            try? FileManager.default.removeItem(at: session.logURL)
        }
        return doomed.map(\.id)
    }

    package func closeAll() {
        lock.lock()
        defer { lock.unlock() }
        for session in sessions.values {
            try? session.handle?.close()
        }
        sessions.removeAll()
    }
}

#endif
