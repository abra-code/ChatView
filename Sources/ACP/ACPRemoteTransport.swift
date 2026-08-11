// Sources/ACP/ACPRemoteTransport.swift
//
// The `acp-remote` transport: ChatView driving an ACP agent that runs somewhere else, over
// the bridge protocol (plan section 7). Ungated - this is the one that runs on iOS.
//
// The shape differs from the stdio transport in exactly one way, and everything else follows
// from it: the connection is not the session. A socket can drop and come back many times
// inside one conversation, and the agent keeps working the whole time. So:
//
//  - A turn is NEVER ended because the socket died (invariant I9). A dropped socket says
//    nothing about a turn that is still running bridge-side; the truth arrives with the
//    replay. The composer is gated by connection state instead.
//  - Every transcript id is derived from the bridge's sequence number (plan 4.5), so two
//    devices - and the same device after a restart - render byte-identical ids without any
//    reconciliation protocol.
//  - `lastSeq` advances only AFTER an entry is fully processed (invariant I7), so a reattach
//    asks for exactly what was missed. At-least-once delivery plus idempotent processing.
//
// The reconnect loop lives here rather than in ACPRemoteConnection: a connection object is
// single-use (I2), and this owns the policy for making new ones.

import Foundation
import ChatView

final class ACPRemoteTransport: ChatTransport, @unchecked Sendable {

    let events: AsyncStream<ChatEvent>
    private let eventSink: AsyncStream<ChatEvent>.Continuation
    private let logger: any ChatLogger

    private let url: URL
    private let token: String
    private let sessionSelector: String        // "new" | "latest" | an explicit session id
    private let requestedCwd: String?
    let handshakeTimeout: TimeInterval         // internal so tests can pin the default
    private let configuredResumeAfterSeq: Int?
    private let socketFactory: any ACPRemoteSocketFactory

    private let lock = NSLock()
    private var connection: ACPRemoteConnection?
    private var sessionID: String?
    private var sessionOptions: [SessionConfigOption] = []
    private var lastSeq = 0
    private var activeTurn: Int?
    private var stopped = false
    private var reconnectTask: Task<Void, Never>?
    private var handshakeGeneration = 0
    /// The bridge's `initialize` result, which carries the AGENT's identity verbatim. Kept so
    /// every sessionInfo reports the real agent rather than a placeholder - a phone has no
    /// other way to learn what it is talking to.
    private var agentIdentity: [String: Any] = [:]

    // Segmentation state, the same shape the stdio transport keeps, but keyed off seqs.
    private var openMessageID: String?
    private var openMessageRole: ChatRole = .agent
    private var openThoughtID: String?

    /// echoKeys this device minted. The store already appended the user's message
    /// optimistically on send, so our own `bridge/user_message` must not be rendered twice.
    /// Bounded: a set that grew forever would be a leak in a long session, and an echoKey is
    /// only interesting for the moment between sending and seeing it come back.
    private var mintedEchoKeys: [String] = []
    private static let echoKeyMemory = 64

    /// Stop pressed while the socket was down. There is no turn to cancel locally - it is
    /// running bridge-side - so the intent is latched and sent after the next attach, but only
    /// if that same turn is still live (invariant I3, re-homed for a network).
    private var pendingCancel: Int?
    /// The highest turn the bridge has told us ended. `session/prompt` learns its turn number
    /// only from the reply, so a turn that ends before that reply lands would otherwise be
    /// written back into `activeTurn` as though it were live - and a later Stop would target a
    /// turn that is already over.
    private var lastEndedTurn = 0
    /// Set when the bridge refuses us for a reason retrying cannot fix (bad token, unknown
    /// session, ended session). Without it the failure path closed the socket, which looked
    /// like a network drop, which restarted the reconnect loop - retrying a bad token forever.
    private var abandoned = false
    /// After an attach, the replay is complete once `lastSeq` reaches this. Used to emit the
    /// quiet-attach checkpoint at the right moment rather than before the replay arrives.
    private var quietCheckpointTarget: Int?

    /// Answers the user has given, keyed by requestKey, kept until the bridge confirms the
    /// resolution. This is what survives a socket that dropped between the tap and the send:
    /// the bridge re-issues unanswered requests after a reattach, and the held answer settles
    /// them without asking the user twice.
    private var permissionAnswers: [String: String?] = [:]
    /// Continuations parked on the UI, keyed by requestKey. A LIST because the bridge re-issues
    /// the same requestKey to every connection that attaches while it is unanswered, and each
    /// re-issue is its own JSON-RPC request needing its own response. Overwriting a single
    /// continuation here leaked it (a hard runtime error) and answered only the newest request.
    private var permissionWaiters: [String: [CheckedContinuation<String?, Never>]] = [:]
    /// requestKeys whose gate the store is already showing. The store appends gates without
    /// deduping, so a re-issue after a reconnect must not emit a second `.permissionRequest`
    /// for a prompt the user is already looking at.
    private var shownPermissionKeys: Set<String> = []
    private static let permissionAnswerMemory = 64

    var capabilities: ChatTransportCapabilities {
        ChatTransportCapabilities(reportsConnectionState: true)
    }

    // MARK: - Init and config validation

    init(config: ChatTransportConfig,
         logger: any ChatLogger,
         socketFactory: (any ACPRemoteSocketFactory)? = nil) throws {
        self.logger = logger
        self.socketFactory = socketFactory ?? URLSessionSocketFactory()

        let settings = config.settings
        guard let rawURL = settings["url"] as? String, !rawURL.isEmpty else {
            throw ACPRemoteError(code: nil, message: "the acp-remote transport requires a 'url' setting")
        }
        guard let parsed = URL(string: rawURL), let scheme = parsed.scheme?.lowercased() else {
            throw ACPRemoteError(code: nil, message: "'\(rawURL)' is not a usable URL")
        }
        guard scheme == "ws" || scheme == "wss" else {
            throw ACPRemoteError(code: nil, message: "the acp-remote url must be ws:// or wss://, got '\(scheme)://'")
        }
        let allowInsecure = (settings["allowInsecure"] as? Bool) ?? false
        if scheme == "ws", !allowInsecure, !Self.isPrivateHost(parsed.host ?? "") {
            // Cleartext to a public host would put a token that is remote code execution on
            // the wire. Refuse at construction, the way `acp` refuses a missing command.
            throw ACPRemoteError(code: nil, message: "refusing ws:// to the non-private host "
                                 + "'\(parsed.host ?? "")'; use wss:// or set allowInsecure")
        }
        self.url = parsed
        self.token = (settings["token"] as? String) ?? ""
        self.sessionSelector = (settings["session"] as? String) ?? "new"
        self.requestedCwd = settings["cwd"] as? String
        self.handshakeTimeout = Self.clampedTimeout(settings["handshakeTimeoutSeconds"], default: 15)

        // The cold-launch cursor (plan 4.2a). Only meaningful against the session id it was
        // minted for: with "new" or "latest" there is nothing for it to line up with, and a
        // cursor applied to the wrong session silently skips that session's history.
        if let raw = settings["resumeAfterSeq"] {
            let value = (raw as? NSNumber)?.intValue
            if sessionSelector == "new" || sessionSelector == "latest" {
                logger.log("acp-remote: ignoring resumeAfterSeq with session '\(sessionSelector)'; "
                           + "a checkpoint only means something against an explicit session id", .warning)
                self.configuredResumeAfterSeq = nil
            } else if let value, value >= 0 {
                self.configuredResumeAfterSeq = value
            } else {
                logger.log("acp-remote: ignoring a non-numeric or negative resumeAfterSeq", .warning)
                self.configuredResumeAfterSeq = nil
            }
        } else {
            self.configuredResumeAfterSeq = nil
        }

        var captured: AsyncStream<ChatEvent>.Continuation!
        self.events = AsyncStream(bufferingPolicy: .unbounded) { captured = $0 }
        self.eventSink = captured

        if let resume = configuredResumeAfterSeq {
            lastSeq = resume
        }
    }

    /// Loopback, `.local`, RFC 1918, link-local, CGNAT (Tailscale), and their IPv6 twins.
    /// Internal for tests.
    ///
    /// This gate decides whether a token that is remote code execution on the bridge host may
    /// travel in cleartext, so it fails CLOSED and parses strictly. An earlier version split on
    /// "." and dropped the labels that were not numbers, which made `127.0.0.1.evil.com` look
    /// like 127.0.0.1 - an attacker who registers that name gets the token over plain ws://.
    /// Every label must parse, or the host is public.
    static func isPrivateHost(_ host: String) -> Bool {
        var name = host.lowercased()
        // Strip one trailing root dot ("mac.local." is the same name as "mac.local").
        if name.hasSuffix(".") {
            name.removeLast()
        }
        if name.isEmpty {
            return false
        }
        if name == "localhost" || name.hasSuffix(".local") || name.hasSuffix(".localhost") {
            return true
        }
        if name.contains(":") {
            return isPrivateIPv6(name)
        }

        // Exactly four labels, every one a plain decimal 0...255. No octal, no hex, no
        // shorthand forms, and crucially no non-numeric labels sneaking through.
        let labels = name.split(separator: ".", omittingEmptySubsequences: false)
        guard labels.count == 4 else {
            return false
        }
        var parts: [Int] = []
        for label in labels {
            guard (1...3).contains(label.count),
                  label.allSatisfy({ $0.isASCII && $0.isNumber }),
                  label.count == 1 || label.first != "0",   // 0177 must not read as 127
                  let value = Int(label), value <= 255 else {
                return false
            }
            parts.append(value)
        }

        switch (parts[0], parts[1]) {
        case (127, _), (10, _):
            return true
        case (192, 168):
            return true
        case (169, 254):
            return true
        case (172, let second) where second >= 16 && second <= 31:
            return true
        case (100, let second) where second >= 64 && second <= 127:   // CGNAT / Tailscale
            return true
        default:
            return false
        }
    }

    /// IPv6 loopback, unique-local (fc00::/7), and link-local (fe80::/10). Foundation hands us
    /// the address without its brackets, and a zone id ("fe80::1%en0") is stripped first.
    private static func isPrivateIPv6(_ name: String) -> Bool {
        let address = name.split(separator: "%", maxSplits: 1).first.map(String.init) ?? name
        // Anything that is not hex digits and colons is not an address literal at all.
        guard address.allSatisfy({ $0 == ":" || ($0.isASCII && $0.isHexDigit) }) else {
            return false
        }
        if address == "::1" {
            return true
        }
        let head = address.split(separator: ":", omittingEmptySubsequences: false).first.map(String.init) ?? ""
        guard let leading = UInt16(head, radix: 16) else {
            return false
        }
        if leading & 0xFE00 == 0xFC00 {      // fc00::/7, unique local
            return true
        }
        if leading & 0xFFC0 == 0xFE80 {      // fe80::/10, link local
            return true
        }
        return false
    }

    private static func clampedTimeout(_ raw: Any?, default fallback: TimeInterval) -> TimeInterval {
        guard let seconds = (raw as? NSNumber)?.doubleValue else {
            return fallback
        }
        guard seconds.isFinite, seconds > 0 else {
            return 0      // 0 or a nonsense value means "no watchdog", matching acp's startupTimeout
        }
        return min(seconds, 86_400)
    }

    // MARK: - Lifecycle

    func start() async {
        eventSink.yield(.connectionStateChanged(.connecting))
        await connectOnce(isReconnect: false)
    }

    func stop() async {
        let (task, existing): (Task<Void, Never>?, ACPRemoteConnection?) = lock.withLock {
            stopped = true
            let task = reconnectTask
            reconnectTask = nil
            let connection = self.connection
            self.connection = nil
            return (task, connection)
        }
        task?.cancel()
        existing?.close()
        drainPermissionWaiters()
        eventSink.finish()
    }

    // MARK: - Connect / reconnect

    private func connectOnce(isReconnect: Bool) async {
        if lock.withLock({ stopped }) {
            return
        }
        let connection = ACPRemoteConnection(
            logger: logger,
            onNotification: { [weak self] method, params in
                self?.handleNotification(method: method, params: params)
            },
            onRequest: { [weak self] method, params in
                await self?.handleBridgeRequest(method: method, params: params)
            },
            onOpen: {},
            onClose: { [weak self] error in
                self?.handleSocketClosed(error: error)
            })
        lock.withLock { self.connection = connection }

        var headers = ["Authorization": "Bearer \(token)"]
        if token.isEmpty {
            headers.removeValue(forKey: "Authorization")
        }
        connection.attach(socket: socketFactory.makeSocket(url: url, headers: headers, delegate: connection))

        // I1: the watchdog closes the CONNECTION, it does not race the request. Racing an
        // await against a timeout in a task group deadlocks - this was proven painfully in the
        // stdio transport and the same reasoning applies verbatim to a socket.
        let generation = lock.withLock { () -> Int in
            handshakeGeneration += 1
            return handshakeGeneration
        }
        if handshakeTimeout > 0 {
            let limit = handshakeTimeout
            Task { [weak self, weak connection] in
                try? await Task.sleep(nanoseconds: UInt64(limit * 1_000_000_000))
                guard let self, self.lock.withLock({ self.handshakeGeneration == generation }) else {
                    return
                }
                self.logger.log("acp-remote: no handshake within \(Self.secondsText(limit)); closing the socket", .warning)
                connection?.close(error: ACPRemoteError(code: nil, message:
                    "The agent bridge did not respond within \(Self.secondsText(limit))"))
            }
        }

        do {
            let handshake = try await connection.request("initialize", [
                "protocolVersion": 1,
                "bridgeToken": token,
                "clientInfo": ["name": "ChatView", "title": "ChatView", "version": "0.3.0"],
            ])
            lock.withLock { agentIdentity = handshake }
            try await establishSession(on: connection, isReconnect: isReconnect)
            // Only now is the handshake done; retire the watchdog so a later slow turn is not
            // mistaken for a failed connect.
            lock.withLock { handshakeGeneration += 1 }
            eventSink.yield(.connectionStateChanged(.connected))
        } catch {
            lock.withLock { handshakeGeneration += 1 }
            let message = (error as? ACPRemoteError)?.message ?? "\(error)"
            if isReconnect {
                // A failed reconnect is not terminal: the loop keeps trying, and the composer
                // stays gated by the connection state in the meantime.
                logger.log("acp-remote: reconnect attempt failed: \(message)", .warning)
                connection.close()
                return
            }
            // Codes the bridge uses for "this will never work": a bad token, a session that
            // does not exist, a session that has ended. Latch so the close below is not mistaken
            // for a network drop and answered with a reconnect loop.
            if let code = (error as? ACPRemoteError)?.code, [-32000, -32001, -32002].contains(code) {
                lock.withLock { abandoned = true }
            }
            eventSink.yield(.error(message: message, recoverable: false))
            eventSink.yield(.connectionStateChanged(.offline))
            connection.close()
        }
    }

    /// Creates or attaches to the session, in the order invariant I6 requires: the session is
    /// announced BEFORE any replayed event, so the store leaves its unconfigured state first.
    private func establishSession(on connection: ACPRemoteConnection, isReconnect: Bool) async throws {
        let known = lock.withLock { sessionID }

        if let known {
            try await attach(sessionID: known, on: connection, resumed: true)
            return
        }

        switch sessionSelector {
        case "new":
            var params: [String: Any] = [:]
            if let requestedCwd {
                params["cwd"] = requestedCwd
            }
            let result = try await connection.request("session/new", params)
            guard let newID = result["sessionId"] as? String else {
                throw ACPRemoteError(code: nil, message: "the agent bridge returned no sessionId")
            }
            let options = ACPWire.parseConfigOptions(result)
            lock.withLock {
                sessionID = newID
                sessionOptions = options
            }
            eventSink.yield(.sessionReady(sessionID: newID, configOptions: options))
            eventSink.yield(.sessionInfo(makeSessionInfo(sessionID: newID, resumed: false)))

        case "latest":
            let listing = try await connection.request("bridge/sessions", [:])
            let rows = (listing["sessions"] as? [[String: Any]]) ?? []
            let preferred = rows.first { ($0["state"] as? String) == "live" } ?? rows.first
            guard let target = preferred?["sessionId"] as? String else {
                // No session to resume is not an error; it means this is a first run.
                logger.log("acp-remote: no existing session to resume; creating one", .info)
                lock.withLock { sessionID = nil }
                var params: [String: Any] = [:]
                if let requestedCwd {
                    params["cwd"] = requestedCwd
                }
                let result = try await connection.request("session/new", params)
                guard let newID = result["sessionId"] as? String else {
                    throw ACPRemoteError(code: nil, message: "the agent bridge returned no sessionId")
                }
                let options = ACPWire.parseConfigOptions(result)
                lock.withLock {
                    sessionID = newID
                    sessionOptions = options
                }
                eventSink.yield(.sessionReady(sessionID: newID, configOptions: options))
                eventSink.yield(.sessionInfo(makeSessionInfo(sessionID: newID, resumed: false)))
                return
            }
            try await attach(sessionID: target, on: connection, resumed: isReconnect)

        default:
            try await attach(sessionID: sessionSelector, on: connection, resumed: isReconnect)
        }
    }

    private func attach(sessionID target: String, on connection: ACPRemoteConnection, resumed: Bool) async throws {
        let cursor = lock.withLock { lastSeq }
        var result = try await connection.request("bridge/attach", [
            "sessionId": target,
            "afterSeq": cursor,
        ])

        // A cursor minted against a DIFFERENT session would silently skip this session's history
        // up to that number. Zeroing lastSeq is not enough - the attach that used the bad cursor
        // has already gone out - so ATTACH AGAIN from the beginning and use that result.
        if let echoed = result["sessionId"] as? String, echoed != target, cursor > 0 {
            logger.log("acp-remote: the bridge attached '\(echoed)' but '\(target)' was requested; "
                       + "re-attaching and replaying from the beginning", .warning)
            lock.withLock { lastSeq = 0 }
            result = try await connection.request("bridge/attach", [
                "sessionId": target,
                "afterSeq": 0,
            ])
        }

        let options = (result["configOptions"] as? [[String: Any]]).map { raw in
            ACPWire.parseConfigOptions(["configOptions": raw])
        } ?? []
        let turn = result["activeTurn"] as? Int
        lock.withLock {
            sessionID = target
            if !options.isEmpty {
                sessionOptions = options
            }
            activeTurn = turn
        }

        eventSink.yield(.sessionReady(sessionID: target, configOptions: options))
        eventSink.yield(.sessionInfo(makeSessionInfo(sessionID: target, resumed: resumed)))

        if (result["state"] as? String) == "ended" {
            let reason = (result["endedReason"] as? String) ?? "the session ended"
            // The transcript still replays after this; the error only says it cannot be
            // continued. Emitted after sessionReady so the store is configured first.
            eventSink.yield(.error(message: "The remote agent session has ended (\(reason))", recoverable: false))
        }

        // Stop pressed while disconnected: send it now, but only if that same turn is still
        // the live one - otherwise we would cancel somebody else's turn.
        let latched: Int? = lock.withLock {
            let value = pendingCancel
            pendingCancel = nil
            return value
        }
        if let latched, latched == turn {
            connection.notify("session/cancel", ["sessionId": target])
        }

        // A quiet attach is a checkpoint moment - but only ONCE THE REPLAY HAS ARRIVED. The
        // attach result returns before its replayed notifications, so checkpointing here would
        // hand the host a cursor describing the state before the catch-up it is about to
        // render. Arm a target instead, and fire when lastSeq reaches the tail the bridge just
        // told us about.
        let latest = (result["latestSeq"] as? Int) ?? 0
        if turn == nil {
            let reached: Bool = lock.withLock {
                if lastSeq >= latest {
                    quietCheckpointTarget = nil
                    return true
                }
                quietCheckpointTarget = latest
                return false
            }
            if reached {
                emitCheckpointIfPossible()
            }
        } else {
            lock.withLock { quietCheckpointTarget = nil }
        }
    }

    private func handleSocketClosed(error: (any Error)?) {
        let shouldReconnect: Bool = lock.withLock {
            connection = nil
            return !stopped && !abandoned
        }
        guard shouldReconnect else {
            return
        }
        // I9: the socket dying says NOTHING about the turn, which is still running bridge-side.
        // Never synthesize a turn end here - the composer is gated by connection state and the
        // truth arrives with the replay.
        eventSink.yield(.connectionStateChanged(.reconnecting))
        scheduleReconnect()
    }

    private func scheduleReconnect() {
        let alreadyRunning: Bool = lock.withLock {
            if stopped || reconnectTask != nil {
                return true
            }
            return false
        }
        if alreadyRunning {
            return
        }
        let task = Task { [weak self] in
            var attempt = 0
            while let self, !self.lock.withLock({ self.stopped }) {
                let base = min(pow(2.0, Double(attempt)) * 0.5, 30.0)
                let jitter = Double.random(in: 0.8...1.2)
                try? await Task.sleep(nanoseconds: UInt64(base * jitter * 1_000_000_000))
                if Task.isCancelled || self.lock.withLock({ self.stopped }) {
                    return
                }
                await self.connectOnce(isReconnect: true)
                if self.lock.withLock({ self.connection != nil }) {
                    self.lock.withLock { self.reconnectTask = nil }
                    return
                }
                attempt += 1
            }
        }
        lock.withLock { reconnectTask = task }
    }

    // MARK: - Commands

    func send(_ command: ChatCommand) async {
        switch command {
        case .prompt(let text):
            await sendPrompt(text)
        case .cancel:
            await sendCancel()
        case .permissionResponse(let requestID, let optionID):
            answerPermission(requestKey: requestID, optionID: optionID)
        case .setConfigOption(let optionID, let value):
            await setConfigOption(optionID: optionID, value: value)
        default:
            break
        }
    }

    private func sendPrompt(_ text: String) async {
        let (connection, session) = lock.withLock { (self.connection, self.sessionID) }
        guard let connection, let session, !connection.isClosed else {
            // Never queue a prompt: one firing after minutes of reconnect surprises the user,
            // and the composer is connection-gated anyway.
            eventSink.yield(.error(message: "Not connected to the agent bridge; message not sent",
                                   recoverable: true))
            return
        }
        let echoKey = UUID().uuidString
        lock.withLock {
            mintedEchoKeys.append(echoKey)
            if mintedEchoKeys.count > Self.echoKeyMemory {
                mintedEchoKeys.removeFirst(mintedEchoKeys.count - Self.echoKeyMemory)
            }
        }
        do {
            let result = try await connection.request("session/prompt", [
                "sessionId": session,
                "prompt": [["type": "text", "text": text]],
                "echoKey": echoKey,
            ])
            lock.withLock {
                guard let turn = result["turn"] as? Int, turn > lastEndedTurn else {
                    return
                }
                activeTurn = turn
            }
        } catch {
            let message = (error as? ACPRemoteError)?.message ?? "\(error)"
            eventSink.yield(.error(message: message, recoverable: true))
        }
    }

    private func sendCancel() async {
        let (connection, session, turn) = lock.withLock { (self.connection, self.sessionID, self.activeTurn) }
        guard let session else {
            return
        }
        guard let connection, !connection.isClosed else {
            // Latch it: the turn is still running bridge-side and Stop must still stop it.
            lock.withLock { pendingCancel = turn }
            return
        }
        connection.notify("session/cancel", ["sessionId": session])
    }

    private func setConfigOption(optionID: String, value: String) async {
        let (connection, session) = lock.withLock { (self.connection, self.sessionID) }
        guard let connection, let session, !connection.isClosed else {
            return
        }
        do {
            let result = try await connection.request("session/set_config_option", [
                "sessionId": session,
                "configId": optionID,
                "type": "select",
                "value": value,
            ])
            let refreshed = ACPWire.parseConfigOptions(result)
            if !refreshed.isEmpty {
                lock.withLock { sessionOptions = refreshed }
                eventSink.yield(.configOptionsChanged(refreshed))
            }
        } catch {
            logger.log("acp-remote: set_config_option failed: \(error)", .warning)
        }
    }

    private func answerPermission(requestKey: String, optionID: String?) {
        // ALWAYS record the answer, even when a waiter exists. The bad case is precisely the one
        // where it exists: the request arrived, the socket then dropped, and the user taps
        // Allow. Resuming the waiter writes the result into a dead connection, which the send
        // path silently discards - so without the record the answer is lost and the user is
        // asked again after reattach. The record is cleared when the bridge confirms the
        // resolution, which is the only authoritative "this is settled" signal there is.
        let waiters: [CheckedContinuation<String?, Never>] = lock.withLock {
            permissionAnswers[requestKey] = optionID
            if permissionAnswers.count > Self.permissionAnswerMemory, let oldest = permissionAnswers.keys.first {
                permissionAnswers.removeValue(forKey: oldest)
            }
            return permissionWaiters.removeValue(forKey: requestKey) ?? []
        }
        for waiter in waiters {
            waiter.resume(returning: optionID)
        }
    }

    /// Resumes every parked permission continuation. A continuation that is never resumed is a
    /// hard runtime error in Swift, so teardown has to drain them rather than drop them.
    private func drainPermissionWaiters() {
        let waiters: [CheckedContinuation<String?, Never>] = lock.withLock {
            let all = permissionWaiters.values.flatMap { $0 }
            permissionWaiters.removeAll()
            return all
        }
        for waiter in waiters {
            waiter.resume(returning: nil)
        }
    }

    // MARK: - Inbound

    private func handleBridgeRequest(method: String, params: [String: Any]) async -> [String: Any]? {
        guard method == "session/request_permission",
              let requestKey = params["requestKey"] as? String else {
            return nil
        }

        // Already answered - either while the socket was down, or by this same user before a
        // re-issue reached us. Settle it without asking again. The record is NOT consumed here:
        // only the bridge's permission_resolved clears it, so a second re-issue is also settled.
        let held: String?? = lock.withLock { permissionAnswers[requestKey] }
        if let held {
            return Self.permissionOutcome(optionID: held)
        }

        // Show the gate only the first time this key is seen. The bridge re-issues the same key
        // to every connection that attaches while it is unanswered, and the store appends gates
        // without deduping, so emitting again would stack a second prompt on the same question.
        let alreadyShowing: Bool = lock.withLock {
            let seen = shownPermissionKeys.contains(requestKey)
            shownPermissionKeys.insert(requestKey)
            return seen
        }
        if !alreadyShowing {
            eventSink.yield(.permissionRequest(Self.parsePermissionRequest(params, requestKey: requestKey)))
        }

        let choice: String? = await withCheckedContinuation { continuation in
            let answered: String?? = lock.withLock {
                if let value = permissionAnswers[requestKey] {
                    return value
                }
                permissionWaiters[requestKey, default: []].append(continuation)
                return nil
            }
            if let answered {
                // Raced us between the read above and here.
                continuation.resume(returning: answered)
            }
        }
        return Self.permissionOutcome(optionID: choice)
    }

    /// Builds the identity event from the bridge's cached `initialize` result. `agentPid` is
    /// deliberately nil: the agent's pid is a fact about the BRIDGE host, and a remote client
    /// has no business acting on it.
    private func makeSessionInfo(sessionID: String, resumed: Bool) -> AgentSessionInfo {
        let identity = lock.withLock { agentIdentity }
        let info = identity["agentInfo"] as? [String: Any]
        let capabilities = identity["agentCapabilities"] as? [String: Any]
        return AgentSessionInfo(sessionId: sessionID,
                                agentName: info?["name"] as? String,
                                agentVersion: info?["version"] as? String,
                                protocolVersion: identity["protocolVersion"] as? Int,
                                agentPid: nil,
                                canLoadSession: (capabilities?["loadSession"] as? Bool) ?? false,
                                canPrime: (capabilities?["sessionPrime"] as? Bool) ?? false,
                                resumed: resumed)
    }

    private static func permissionOutcome(optionID: String?) -> [String: Any] {
        if let optionID {
            return ["outcome": ["outcome": "selected", "optionId": optionID]]
        }
        return ["outcome": ["outcome": "cancelled"]]
    }

    private static func parsePermissionRequest(_ params: [String: Any], requestKey: String) -> PermissionRequest {
        let toolCall = params["toolCall"] as? [String: Any]
        let options = (params["options"] as? [[String: Any]] ?? []).compactMap { option -> PermissionRequest.Option? in
            guard let id = option["optionId"] as? String else {
                return nil
            }
            return PermissionRequest.Option(id: id,
                                            name: (option["name"] as? String) ?? id,
                                            kind: (option["kind"] as? String)
                                                .flatMap(PermissionRequest.Option.Kind.init(rawValue:)) ?? .allowOnce)
        }
        // The id IS the requestKey, so the gate keeps its identity across reconnects and across
        // devices - that is what lets the bridge re-issue the same request after a reattach.
        return PermissionRequest(id: requestKey,
                                 toolCallID: toolCall?["toolCallId"] as? String,
                                 title: (toolCall?["title"] as? String) ?? "Allow this action?",
                                 options: options)
    }

    private func handleNotification(method: String, params: [String: Any]) {
        guard let seq = params["seq"] as? Int else {
            logger.log("acp-remote: dropping '\(method)' with no seq", .warning)
            return
        }
        // I7: process first, advance lastSeq after. A cursor ahead of what was processed loses
        // content on the next attach.
        let alreadySeen: Bool = lock.withLock { seq <= lastSeq }
        if alreadySeen {
            return
        }

        switch method {
        case "session/update":
            routeSessionUpdate((params["update"] as? [String: Any]) ?? [:], seq: seq)
        case "bridge/user_message":
            routeUserMessage(params, seq: seq)
        case "bridge/turn_ended":
            routeTurnEnded(params, seq: seq)
        case "bridge/permission_resolved":
            routePermissionResolved(params)
        case "bridge/session_ended":
            routeSessionEnded(params)
        default:
            logger.log("acp-remote: ignoring unknown notification '\(method)'", .info)
        }

        let quietTargetReached: Bool = lock.withLock {
            lastSeq = max(lastSeq, seq)
            guard let target = quietCheckpointTarget, lastSeq >= target, activeTurn == nil else {
                return false
            }
            quietCheckpointTarget = nil
            return true
        }
        if quietTargetReached {
            emitCheckpointIfPossible()
        }

        if method == "bridge/turn_ended" {
            // A turn boundary is the only moment the transcript is quiescent, which is what
            // makes the cursor and the host's stored entries describe the same instant.
            emitCheckpointIfPossible()
        }
    }

    private func routeSessionUpdate(_ update: [String: Any], seq: Int) {
        switch update["sessionUpdate"] as? String {
        case "agent_message_chunk":
            appendMessageChunk(ACPWire.contentText(update["content"]), role: .agent, seq: seq)
        case "user_message_chunk":
            appendMessageChunk(ACPWire.contentText(update["content"]), role: .local, seq: seq)
        case "agent_thought_chunk":
            appendThoughtChunk(ACPWire.contentText(update["content"]), seq: seq)
        case "tool_call":
            finalizeOpenItems()
            eventSink.yield(.toolCall(ACPWire.parseToolCall(update)))
        case "tool_call_update":
            eventSink.yield(.toolCallUpdate(ACPWire.parseToolCallUpdate(update)))
        case "plan":
            eventSink.yield(.plan(ACPWire.parsePlan(update)))
        case "usage_update":
            if let usage = ACPWire.parseUsage(update) {
                eventSink.yield(.usage(usage))
            }
        case "current_mode_update":
            if let mode = update["currentModeId"] as? String {
                eventSink.yield(.currentModeChanged(modeID: mode))
            }
        case "available_commands_update":
            eventSink.yield(.commandsAvailable(ACPWire.parseCommands(update)))
        default:
            logger.log("acp-remote: ignoring unknown session/update kind", .info)
        }
    }

    private func routeUserMessage(_ params: [String: Any], seq: Int) {
        let echoKey = (params["echoKey"] as? String) ?? ""
        let isOurs: Bool = lock.withLock {
            guard let index = mintedEchoKeys.firstIndex(of: echoKey) else {
                return false
            }
            mintedEchoKeys.remove(at: index)
            return true
        }
        if isOurs {
            // Our own send; the store already appended it optimistically.
            return
        }
        let text = (params["content"] as? [[String: Any]] ?? []).compactMap { $0["text"] as? String }
            .joined(separator: "\n\n")
        guard !text.isEmpty else {
            return
        }
        finalizeOpenItems()
        let id = "acpr-m-\(seq)"
        eventSink.yield(.messageStart(itemID: id, role: .local))
        eventSink.yield(.messageDelta(itemID: id, text: text))
        eventSink.yield(.messageEnd(itemID: id, stopReason: nil))
    }

    private func routeTurnEnded(_ params: [String: Any], seq: Int) {
        let stopReason = (params["stopReason"] as? String) ?? "end_turn"
        lock.withLock {
            if let turn = params["turn"] as? Int {
                lastEndedTurn = max(lastEndedTurn, turn)
            }
            activeTurn = nil
        }
        let open: String? = lock.withLock {
            let id = openMessageID
            openMessageID = nil
            openThoughtID = nil
            return id
        }
        // The terminal messageEnd is what clears the store's streaming flag and its pending
        // permissions, so it must be emitted for every turn - with an open bubble if there is
        // one, and against a synthetic id if the turn produced nothing.
        eventSink.yield(.messageEnd(itemID: open ?? "acpr-turn-\(seq)", stopReason: stopReason))
    }

    private func routePermissionResolved(_ params: [String: Any]) {
        guard let requestKey = params["requestKey"] as? String else {
            return
        }
        let waiters: [CheckedContinuation<String?, Never>] = lock.withLock {
            permissionAnswers.removeValue(forKey: requestKey)
            shownPermissionKeys.remove(requestKey)
            return permissionWaiters.removeValue(forKey: requestKey) ?? []
        }
        // Somebody else settled it (another device, or the bridge's timeout). Unpark every
        // request handler still waiting on this key, and clear the gate in the store.
        for waiter in waiters {
            waiter.resume(returning: nil)
        }
        eventSink.yield(.permissionResolved(requestID: requestKey))
        if (params["outcome"] as? String) == "timeout" {
            eventSink.yield(.system(text: "The permission request timed out and was declined"))
        }
    }

    private func routeSessionEnded(_ params: [String: Any]) {
        finalizeOpenItems()
        let reason = (params["reason"] as? String) ?? "unknown"
        eventSink.yield(.error(message: "The remote agent session has ended (\(reason))", recoverable: false))
    }

    // MARK: - Segmentation (ids derived from seq, per plan 4.5)

    private func appendMessageChunk(_ text: String, role: ChatRole, seq: Int) {
        guard !text.isEmpty else {
            return
        }
        // A whitespace-only chunk never OPENS a bubble (it may extend one) - carried over from
        // the stdio transport, where agents emit leading whitespace before real content.
        let existing: String? = lock.withLock { openMessageID }
        if existing == nil, text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return
        }
        if lock.withLock({ openThoughtID != nil }) {
            lock.withLock { openThoughtID = nil }
        }
        let (id, replaced): (String, String?) = lock.withLock {
            if let openMessageID, openMessageRole == role {
                return (openMessageID, nil)
            }
            let previous = openMessageID
            let minted = "acpr-m-\(seq)"
            openMessageID = minted
            openMessageRole = role
            return (minted, previous)
        }
        // A role switch mid-turn (agent chunk then user chunk) must CLOSE the bubble it
        // replaces. Leaving it open keeps the store streaming that item until the turn ends,
        // and the turn-end only closes the newest id. The stdio transport does the same.
        if let replaced {
            eventSink.yield(.messageEnd(itemID: replaced, stopReason: nil))
        }
        if replaced != nil || id == "acpr-m-\(seq)" {
            eventSink.yield(.messageStart(itemID: id, role: role))
        }
        eventSink.yield(.messageDelta(itemID: id, text: text))
    }

    private func appendThoughtChunk(_ text: String, seq: Int) {
        guard !text.isEmpty else {
            return
        }
        let openMessage: String? = lock.withLock {
            let id = openMessageID
            openMessageID = nil
            return id
        }
        if let openMessage {
            eventSink.yield(.messageEnd(itemID: openMessage, stopReason: nil))
        }
        let id: String = lock.withLock {
            if let openThoughtID {
                return openThoughtID
            }
            let minted = "acpr-t-\(seq)"
            openThoughtID = minted
            return minted
        }
        eventSink.yield(.thoughtDelta(itemID: id, text: text))
    }

    private func finalizeOpenItems() {
        let open: String? = lock.withLock {
            let id = openMessageID
            openMessageID = nil
            openThoughtID = nil
            return id
        }
        if let open {
            eventSink.yield(.messageEnd(itemID: open, stopReason: nil))
        }
    }

    // MARK: - Cold-launch checkpoint (plan 4.2a)

    private func emitCheckpointIfPossible() {
        let (session, seq) = lock.withLock { (self.sessionID, self.lastSeq) }
        guard let session, seq > 0 else {
            return
        }
        eventSink.yield(.resumeCheckpoint(sessionID: session, afterSeq: seq))
    }

    private static func secondsText(_ seconds: TimeInterval) -> String {
        seconds == seconds.rounded() ? "\(Int(seconds))s" : String(format: "%.1fs", seconds)
    }
}
