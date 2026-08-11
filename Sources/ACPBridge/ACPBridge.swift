// Sources/ACPBridge/ACPBridge.swift
//
// The bridge proper: it owns one stdio ACP agent, one session store, one WebSocket listener,
// and the routing between them.
//
// The whole design exists to break one assumption the ACP stdio transport is built on - that
// the client outlives the turn. `session/prompt` blocks until the turn ends, which is fine
// when the client is a Mac app holding the subprocess and fatal when it is a phone that gets
// suspended thirty seconds in. So the bridge notification-izes the turn (4.3): the client's
// prompt returns a turn number immediately, the bridge issues the real blocking prompt on its
// own connection, and the turn's whole life - user message, agent chunks, tool calls,
// permissions, the end - lands in the seq-ordered log. A turn runs happily with zero clients
// attached. That IS the remote-control semantic.
//
// Read section 5's invariants before editing. I5 (one critical section per append), I6
// (attach ordering), and I8 (every turn gets exactly one turn_ended) are each load-bearing
// and each easy to break with a well-meaning refactor.

#if os(macOS)

import Foundation
import ChatView
import ChatViewACP

package final class ACPBridge: @unchecked Sendable {

    package static let bridgeName = "chatview-acp-bridge"
    package static let bridgeVersion = "0.1.0"
    package static let bridgeProtocol = 1

    private let config: BridgeConfig
    private let token: String
    private let logger: any ChatLogger
    private let store: BridgeSessionStore
    private let server: BridgeWebSocketServer
    private var agent: BridgeAgentHost!

    /// Per-connection state. `attachments` maps a session id to the store subscriber id this
    /// connection holds for it, so a disconnect can unsubscribe precisely.
    private final class ClientState {
        var authenticated = false
        var attachments: [String: UUID] = [:]
    }

    /// One parked `session/request_permission` from the agent, re-issued to every attached
    /// client. First answer wins; everything else (timeout, cancel, a second client) loses.
    /// `@unchecked Sendable`: every mutable field is touched only under the bridge's `lock`,
    /// and the immutable ones are parsed JSON that nothing else retains.
    private final class PermissionBroker: @unchecked Sendable {
        let requestKey: String
        let sessionID: String
        let reissueParams: [String: Any]
        let options: [[String: Any]]
        var resolved = false
        /// What the winning resolver decided. Kept because `resolve` can win BEFORE the agent
        /// request installs its continuation (a client that answers instantly), and the
        /// install path must then return the real outcome instead of inventing a cancel.
        var settled: (outcome: String, optionID: String?)?
        var continuation: CheckedContinuation<(outcome: String, optionID: String?), Never>?

        init(requestKey: String, sessionID: String, reissueParams: [String: Any], options: [[String: Any]]) {
            self.requestKey = requestKey
            self.sessionID = sessionID
            self.reissueParams = reissueParams
            self.options = options
        }
    }

    private let lock = NSLock()
    private var clients: [UUID: (connection: BridgeClientConnection, state: ClientState)] = [:]
    private var permissions: [String: PermissionBroker] = [:]

    package init(config: BridgeConfig, token: String, logger: any ChatLogger) {
        self.config = config
        self.token = token
        self.logger = logger
        self.store = BridgeSessionStore(logDirectory: URL(fileURLWithPath: (config.logDir as NSString).expandingTildeInPath),
                                        maxLogEntriesPerSession: config.maxLogEntriesPerSession,
                                        logger: logger)
        self.server = BridgeWebSocketServer(logger: logger)

        self.agent = BridgeAgentHost(
            config: config.agent,
            logger: logger,
            onNotification: { [weak self] method, params in
                self?.handleAgentNotification(method: method, params: params)
            },
            onRequest: { [weak self] method, params in
                await self?.handleAgentRequest(method: method, params: params)
            },
            onExit: { [weak self] status, tail in
                self?.handleAgentExit(status: status, stderrTail: tail)
            })
    }

    // MARK: - Lifecycle

    @discardableResult
    package func start() throws -> UInt16 {
        store.loadFromDisk()
        store.sweepRetention(olderThan: config.retainEndedSessionsDays)

        server.onConnection = { [weak self] connection in
            self?.accept(connection)
        }
        let port = try server.start(host: config.listenHost, port: config.listenPort)
        logger.log("acp-bridge: listening on \(config.listenHost):\(port)", .info)
        return port
    }

    package func stop() {
        server.stop()
        agent.stop()
        store.closeAll()
    }

    /// Test seam: the store is where every ordering guarantee lives, so tests assert against it.
    package var sessionStore: BridgeSessionStore {
        store
    }

    /// Test seam: live client connections, for the disconnect-cleanup regression test.
    package var connectedClientCount: Int {
        server.connectionCount
    }

    /// Test seam: drop every attached client without touching the agent or the log, which is
    /// what a network failure looks like from the bridge side. The sessions stay live and the
    /// turns keep running - that is the whole property the remote transport is built around.
    package func dropAllClientsForTesting() {
        let all: [BridgeClientConnection] = lock.withLock { clients.values.map(\.connection) }
        for connection in all {
            connection.close()
        }
    }

    // MARK: - Client connections

    private func accept(_ connection: BridgeClientConnection) {
        let state = ClientState()
        lock.withLock { clients[connection.id] = (connection, state) }

        connection.onMessage = { [weak self] client, message in
            self?.handleClientMessage(client, message)
        }
        connection.onClose = { [weak self] client in
            self?.releaseClient(client)
        }

        // A connection that never says `initialize` is either a port scanner or a broken
        // client; either way it must not hold a slot forever.
        if config.handshakeDeadlineSeconds > 0 {
            let deadline = config.handshakeDeadlineSeconds
            Task { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(max(0.1, deadline) * 1_000_000_000))
                guard let self else {
                    return
                }
                let authenticated = self.lock.withLock { self.clients[connection.id]?.state.authenticated ?? true }
                if !authenticated {
                    self.logger.log("acp-bridge: dropping a client that never initialized", .warning)
                    connection.close()
                }
            }
        }
    }

    private func releaseClient(_ connection: BridgeClientConnection) {
        // The store keys subscriptions by a per-attach UUID, NOT by the connection id, so the
        // attachment map is the only way to find them. Losing this leaks a sink that writes to
        // a dead socket on every future append.
        let attachments: [String: UUID] = lock.withLock {
            let entry = clients.removeValue(forKey: connection.id)
            return entry?.state.attachments ?? [:]
        }
        for (sessionID, subscriber) in attachments {
            store.detach(sessionID: sessionID, subscriber: subscriber)
        }
    }

    private func handleClientMessage(_ connection: BridgeClientConnection, _ message: [String: Any]) {
        guard let method = message["method"] as? String else {
            return
        }
        // Boxed once here: everything below may hop onto a Task, and a raw [String: Any]
        // cannot cross that boundary under Swift 6 checking. See BridgeJSON.swift.
        let messageID = JSONRPCID(message["id"])
        let params = JSONPayload((message["params"] as? [String: Any]) ?? [:])

        if method == "initialize" {
            Task { await self.handleInitialize(connection, messageID: messageID, params: params) }
            return
        }

        let authenticated = lock.withLock { clients[connection.id]?.state.authenticated ?? false }
        guard authenticated else {
            connection.sendError(id: messageID.value, code: -32000, message: "authentication failed")
            return
        }

        switch method {
        case "session/new":
            Task { await self.handleSessionNew(connection, messageID: messageID, params: params) }
        case "bridge/attach":
            Task { await self.handleAttach(connection, messageID: messageID, params: params) }
        case "bridge/sessions":
            handleSessions(connection, messageID: messageID)
        case "session/prompt":
            handlePrompt(connection, messageID: messageID, params: params.value)
        case "session/cancel":
            handleCancel(params: params.value)
        case "session/set_config_option":
            Task { await self.handleSetConfigOption(connection, messageID: messageID, params: params) }
        default:
            if messageID.value != nil {
                connection.sendError(id: messageID.value, code: -32601, message: "unknown method '\(method)'")
            } else {
                logger.log("acp-bridge: ignoring unknown notification '\(method)'", .info)
            }
        }
    }

    // MARK: - initialize

    private func handleInitialize(_ connection: BridgeClientConnection,
                                  messageID: JSONRPCID,
                                  params: JSONPayload) async {
        let presented = (params.value["bridgeToken"] as? String) ?? ""
        guard BridgeToken.matches(presented, token) else {
            logger.log("acp-bridge: rejecting a client with a bad token", .warning)
            connection.closeAfterAuthFailure()
            return
        }

        let agentResult: [String: Any]
        do {
            agentResult = try await agent.ensureRunning()
        } catch {
            let message = (error as? ACPConnectionError)?.message ?? "\(error)"
            connection.sendError(id: messageID, code: -32003, message: message)
            return
        }

        lock.withLock { clients[connection.id]?.state.authenticated = true }

        var result = agentResult
        result["protocolVersion"] = agentResult["protocolVersion"] ?? 1
        result["bridge"] = [
            "name": Self.bridgeName,
            "version": Self.bridgeVersion,
            "protocol": Self.bridgeProtocol,
            "capabilities": ["attachReplay": true, "sessions": true],
        ]
        connection.sendResult(id: messageID, result: result)
    }

    // MARK: - Sessions

    private func handleSessionNew(_ connection: BridgeClientConnection,
                                  messageID: JSONRPCID,
                                  params: JSONPayload) async {
        do {
            _ = try await agent.ensureRunning()
            let cwd = (params.value["cwd"] as? String) ?? config.agent.cwd ?? FileManager.default.currentDirectoryPath
            let result = try await agent.request("session/new", [
                "cwd": cwd,
                "mcpServers": config.agent.mcpServers,
            ])
            guard let sessionID = result["sessionId"] as? String else {
                connection.sendError(id: messageID, code: -32003, message: "the agent returned no sessionId")
                return
            }
            guard store.register(sessionID: sessionID) else {
                connection.sendError(id: messageID, code: -32003,
                                     message: "the agent reused session id '\(sessionID)'")
                return
            }
            store.setConfigOptions(sessionID: sessionID,
                                   options: (result["configOptions"] as? [[String: Any]]) ?? [])
            subscribeForLiveTraffic(connection: connection, sessionID: sessionID)
            connection.sendResult(id: messageID, result: result)
        } catch {
            let acp = error as? ACPConnectionError
            connection.sendError(id: messageID, code: acp?.code ?? -32003,
                                 message: acp?.message ?? "\(error)")
        }
    }

    /// Subscribes a connection to a session it just created. There is nothing to replay (the
    /// log is empty), so this is the degenerate case of attach - snapshot and subscribe under
    /// one acquisition, then go live immediately.
    private func subscribeForLiveTraffic(connection: BridgeClientConnection, sessionID: String) {
        guard let attached = try? store.attach(sessionID: sessionID, afterSeq: 0, sink: { [weak connection] data in
            connection?.sendRaw(data)
        }) else {
            return
        }
        lock.withLock { clients[connection.id]?.state.attachments[sessionID] = attached.subscriber }
        store.replayAndGoLive(sessionID: sessionID, subscriber: attached.subscriber,
                              afterSeq: attached.snapshot.latestSeq, throughSeq: attached.snapshot.latestSeq)
    }

    private func handleSessions(_ connection: BridgeClientConnection, messageID: JSONRPCID) {
        let formatter = ISO8601DateFormatter()
        let rows = store.summaries().map { summary -> [String: Any] in
            [
                "sessionId": summary.sessionID,
                "state": summary.state.rawValue,
                "createdAt": formatter.string(from: summary.createdAt),
                "lastActivityAt": formatter.string(from: summary.lastActivityAt),
                "latestSeq": summary.latestSeq,
                "title": summary.title,
            ]
        }
        connection.sendResult(id: messageID, result: ["sessions": rows])
    }

    // MARK: - Attach (invariant I6)

    private func handleAttach(_ connection: BridgeClientConnection,
                              messageID: JSONRPCID,
                              params: JSONPayload) async {
        guard let sessionID = params.value["sessionId"] as? String else {
            connection.sendError(id: messageID, code: -32602, message: "bridge/attach requires sessionId")
            return
        }
        let afterSeq = max(0, (params.value["afterSeq"] as? Int) ?? 0)

        let attached: (snapshot: BridgeAttachSnapshot, subscriber: UUID)
        do {
            attached = try store.attach(sessionID: sessionID, afterSeq: afterSeq, sink: { [weak connection] data in
                connection?.sendRaw(data)
            })
        } catch {
            connection.sendError(id: messageID, code: -32001, message: "unknown session '\(sessionID)'")
            return
        }

        // Drop any previous subscription this connection held for the same session, so a
        // client that reattaches without disconnecting does not receive everything twice.
        let previous: UUID? = lock.withLock {
            let existing = clients[connection.id]?.state.attachments[sessionID]
            clients[connection.id]?.state.attachments[sessionID] = attached.subscriber
            return existing
        }
        if let previous {
            store.detach(sessionID: sessionID, subscriber: previous)
        }

        var result: [String: Any] = [
            "sessionId": sessionID,
            "state": attached.snapshot.state.rawValue,
            "latestSeq": attached.snapshot.latestSeq,
            "activeTurn": attached.snapshot.activeTurn as Any? ?? NSNull(),
            "configOptions": store.configOptions(sessionID: sessionID),
        ]
        if let reason = attached.snapshot.endedReason {
            result["endedReason"] = reason
        }
        // The result goes out BEFORE any replayed notification: the client has to leave its
        // unconfigured state before events start arriving, exactly as with the stdio transport.
        connection.sendResult(id: messageID, result: result)

        store.replayAndGoLive(sessionID: sessionID, subscriber: attached.subscriber,
                              afterSeq: afterSeq, throughSeq: attached.snapshot.latestSeq)

        // Only now, with the transcript in place, re-issue anything still waiting for an
        // answer - a permission gate must never arrive before the tool card it belongs to.
        reissuePendingPermissions(to: connection, sessionID: sessionID)
    }

    // MARK: - Turns (invariant I8)

    private func handlePrompt(_ connection: BridgeClientConnection,
                              messageID: JSONRPCID,
                              params: [String: Any]) {
        guard let sessionID = params["sessionId"] as? String else {
            connection.sendError(id: messageID, code: -32602, message: "session/prompt requires sessionId")
            return
        }
        guard store.exists(sessionID: sessionID) else {
            connection.sendError(id: messageID, code: -32001, message: "unknown session '\(sessionID)'")
            return
        }
        guard store.state(of: sessionID) == .live else {
            connection.sendError(id: messageID, code: -32002, message: "session '\(sessionID)' has ended")
            return
        }
        guard let turn = store.beginTurn(sessionID: sessionID) else {
            connection.sendError(id: messageID, code: -32002, message: "a turn is already in flight")
            return
        }

        let content = (params["prompt"] as? [[String: Any]]) ?? []
        let echoKey = (params["echoKey"] as? String) ?? ""

        // Answer FIRST: the client must not be waiting on a request that outlives its socket.
        connection.sendResult(id: messageID, result: ["turn": turn])

        store.noteTitleIfEmpty(sessionID: sessionID,
                               text: content.compactMap { $0["text"] as? String }.joined(separator: " "))
        store.append(sessionID: sessionID, method: "bridge/user_message", params: [
            "turn": turn,
            "echoKey": echoKey,
            "content": content,
        ])

        // A hung agent would otherwise leave activeTurn set forever: no turn_ended for the
        // client (which I9 forbids it from inventing) and -32002 on every later prompt, i.e. a
        // session wedged until the bridge restarts. Off by default; see plan 4.3a.
        if config.turnTimeoutSeconds > 0 {
            let limit = config.turnTimeoutSeconds
            Task { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(limit * 1_000_000_000))
                guard let self, self.store.activeTurn(sessionID: sessionID) == turn else {
                    return
                }
                self.logger.log("acp-bridge: turn \(turn) of '\(sessionID)' exceeded \(limit)s; ending it", .warning)
                // Through finishTurn, so I8's winner check makes a late real answer a no-op.
                self.finishTurn(sessionID: sessionID, turn: turn, stopReason: "error")
            }
        }

        let promptParams = JSONPayload(["sessionId": sessionID, "prompt": content])
        Task { [weak self] in
            guard let self else {
                return
            }
            var stopReason = "end_turn"
            do {
                let result = try await self.agent.request("session/prompt", promptParams.value)
                stopReason = (result["stopReason"] as? String) ?? "end_turn"
            } catch {
                stopReason = "error"
                self.logger.log("acp-bridge: turn \(turn) of '\(sessionID)' failed: \(error)", .warning)
            }
            // I8: exactly one turn_ended per accepted turn, on every path. A client whose store
            // never sees the terminal messageEnd keeps its composer disabled forever.
            self.finishTurn(sessionID: sessionID, turn: turn, stopReason: stopReason)
        }
    }

    /// Logs the one terminal entry for `turn`, if this caller is the one that ended it.
    ///
    /// I8 is "exactly one turn_ended per accepted turn", and several paths race to satisfy it:
    /// the prompt task resolving, the agent dying, a log overflow. `endTurn` returns true to
    /// exactly one of them. Before that, agent death logged a turn_ended AND the prompt task's
    /// failing request logged a second one - which arrived after session_ended.
    private func finishTurn(sessionID: String, turn: Int, stopReason: String) {
        guard store.endTurn(sessionID: sessionID, turn: turn) else {
            return
        }
        let result = store.append(sessionID: sessionID, method: "bridge/turn_ended", params: [
            "turn": turn,
            "stopReason": stopReason,
        ])
        if result?.overflowed == true {
            endSession(sessionID: sessionID, reason: "log_overflow", detail: nil)
        }
    }

    private func handleCancel(params: [String: Any]) {
        guard let sessionID = params["sessionId"] as? String, store.exists(sessionID: sessionID) else {
            return
        }
        agent.notify("session/cancel", ["sessionId": sessionID])
        resolvePermissions(forSession: sessionID, outcome: "cancelled")
    }

    private func handleSetConfigOption(_ connection: BridgeClientConnection,
                                       messageID: JSONRPCID,
                                       params: JSONPayload) async {
        guard let sessionID = params.value["sessionId"] as? String, store.exists(sessionID: sessionID) else {
            connection.sendError(id: messageID, code: -32001, message: "unknown session")
            return
        }
        guard store.state(of: sessionID) == .live else {
            connection.sendError(id: messageID, code: -32002, message: "session '\(sessionID)' has ended")
            return
        }
        do {
            let result = try await agent.request("session/set_config_option", params.value)
            connection.sendResult(id: messageID, result: result)
        } catch {
            let acp = error as? ACPConnectionError
            connection.sendError(id: messageID, code: acp?.code ?? -32003, message: acp?.message ?? "\(error)")
        }
    }

    // MARK: - Agent -> clients

    private func handleAgentNotification(method: String, params: [String: Any]) {
        guard method == "session/update", let sessionID = params["sessionId"] as? String else {
            logger.log("acp-bridge: ignoring agent notification '\(method)'", .info)
            return
        }
        var payload = params
        payload.removeValue(forKey: "sessionId")
        let result = store.append(sessionID: sessionID, method: "session/update", params: payload)
        if result?.overflowed == true {
            endSession(sessionID: sessionID, reason: "log_overflow", detail: nil)
        }
    }

    private func handleAgentRequest(method: String, params: [String: Any]) async -> [String: Any]? {
        guard method == "session/request_permission" else {
            // Anything else is a capability the bridge did not advertise (fs, terminal).
            return nil
        }
        guard let sessionID = params["sessionId"] as? String,
              let requestKey = store.nextPermissionKey(sessionID: sessionID) else {
            return ["outcome": ["outcome": "cancelled"]]
        }

        let options = (params["options"] as? [[String: Any]]) ?? []
        var reissue: [String: Any] = [
            "sessionId": sessionID,
            "requestKey": requestKey,
            "options": options,
        ]
        if let toolCall = params["toolCall"] {
            reissue["toolCall"] = toolCall
        }

        let broker = PermissionBroker(requestKey: requestKey, sessionID: sessionID,
                                      reissueParams: reissue, options: options)
        lock.withLock { _ = permissions.updateValue(broker, forKey: requestKey) }

        let connections = attachedConnections(sessionID: sessionID)
        for connection in connections {
            askForPermission(connection: connection, broker: broker)
        }
        startPermissionTimeout(broker)

        let answer = await withCheckedContinuation { (continuation: CheckedContinuation<(outcome: String, optionID: String?), Never>) in
            let already: (outcome: String, optionID: String?)? = lock.withLock {
                if broker.resolved {
                    return broker.settled ?? ("cancelled", nil)
                }
                broker.continuation = continuation
                return nil
            }
            if let already {
                continuation.resume(returning: already)
            }
        }

        lock.withLock { _ = permissions.removeValue(forKey: requestKey) }

        // A timeout is a DENIAL, not an absence of an answer: the agent is told which option
        // was picked for it. The log has to carry that same option, because a returning client
        // renders "declined" from this entry and would otherwise be told only that something
        // expired. Compute it once, here, so the wire and the log cannot disagree.
        let denial = answer.outcome == "timeout" ? Self.denialOption(from: broker.options) : nil
        let effectiveOption = answer.optionID ?? denial

        store.append(sessionID: sessionID, method: "bridge/permission_resolved", params: [
            "requestKey": requestKey,
            "outcome": answer.outcome,
            "optionId": effectiveOption as Any? ?? NSNull(),
        ])

        if answer.outcome == "selected", let optionID = answer.optionID {
            return ["outcome": ["outcome": "selected", "optionId": optionID]]
        }
        if let denial {
            // Deny by default. An unattended agent must never acquire a permission by silence.
            return ["outcome": ["outcome": "selected", "optionId": denial]]
        }
        return ["outcome": ["outcome": "cancelled"]]
    }

    private static func denialOption(from options: [[String: Any]]) -> String? {
        let rejecting = options.first { ($0["kind"] as? String) == "reject_once" }
            ?? options.first { ($0["kind"] as? String) == "reject_always" }
        return rejecting?["optionId"] as? String
    }

    private func askForPermission(connection: BridgeClientConnection, broker: PermissionBroker) {
        Task { [weak self] in
            guard let self else {
                return
            }
            do {
                let response = try await connection.request("session/request_permission", broker.reissueParams)
                let outcome = (response["outcome"] as? [String: Any]) ?? [:]
                if (outcome["outcome"] as? String) == "selected", let optionID = outcome["optionId"] as? String {
                    self.resolve(broker: broker, outcome: "selected", optionID: optionID)
                } else {
                    self.resolve(broker: broker, outcome: "cancelled", optionID: nil)
                }
            } catch {
                // This client went away or answered a key that was already settled. Neither is
                // an error worth surfacing: another client, the timeout, or a cancel will win.
                self.logger.log("acp-bridge: permission \(broker.requestKey) not answered by one client: \(error)", .info)
            }
        }
    }

    private func startPermissionTimeout(_ broker: PermissionBroker) {
        let seconds = config.permissionTimeoutSeconds
        guard seconds > 0 else {
            return
        }
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            self?.resolve(broker: broker, outcome: "timeout", optionID: nil)
        }
    }

    /// First writer wins. Every path into a resolution - a client answer, the timeout, a
    /// cancel, the session ending - comes through here, so exactly one of them can resume the
    /// agent's parked request.
    private func resolve(broker: PermissionBroker, outcome: String, optionID: String?) {
        let continuation: CheckedContinuation<(outcome: String, optionID: String?), Never>? = lock.withLock {
            if broker.resolved {
                return nil
            }
            broker.resolved = true
            broker.settled = (outcome, optionID)
            let waiter = broker.continuation
            broker.continuation = nil
            return waiter
        }
        continuation?.resume(returning: (outcome, optionID))
    }

    private func resolvePermissions(forSession sessionID: String, outcome: String) {
        let brokers: [PermissionBroker] = lock.withLock {
            permissions.values.filter { $0.sessionID == sessionID }
        }
        for broker in brokers {
            resolve(broker: broker, outcome: outcome, optionID: nil)
        }
    }

    private func reissuePendingPermissions(to connection: BridgeClientConnection, sessionID: String) {
        let brokers: [PermissionBroker] = lock.withLock {
            permissions.values.filter { $0.sessionID == sessionID && !$0.resolved }
        }
        for broker in brokers {
            askForPermission(connection: connection, broker: broker)
        }
    }

    private func attachedConnections(sessionID: String) -> [BridgeClientConnection] {
        lock.withLock {
            clients.values
                .filter { $0.state.attachments[sessionID] != nil }
                .map(\.connection)
        }
    }

    // MARK: - Agent death (invariant I8)

    private func handleAgentExit(status: Int32?, stderrTail: String) {
        let live = store.liveSessionIDs()
        let detail = stderrTail.isEmpty
            ? (status.map { "exit status \($0)" } ?? "the agent stream closed")
            : stderrTail
        logger.log("acp-bridge: the agent exited (\(detail))", .warning)

        for sessionID in live {
            // endSession ends the in-flight turn and resolves pending permissions first; see
            // its comment for why that order is invariant I8 rather than a preference.
            endSession(sessionID: sessionID, reason: "agent_exit", detail: detail)
        }
    }

    /// Ends a session, always after ending any turn it still has in flight.
    ///
    /// The ordering is invariant I8 and it is not cosmetic: a client keys its streaming state
    /// off the terminal messageEnd, so a session that ends with a turn still open leaves the
    /// composer disabled with no way back. This is also why `markEnded` comes after
    /// `finishTurn` - marking first would clear activeTurn and there would be nothing left to
    /// tell the client about.
    private func endSession(sessionID: String, reason: String, detail: String?) {
        if let turn = store.activeTurn(sessionID: sessionID) {
            finishTurn(sessionID: sessionID, turn: turn, stopReason: "error")
        }
        resolvePermissions(forSession: sessionID, outcome: "cancelled")
        guard store.markEnded(sessionID: sessionID, reason: reason) else {
            return
        }
        var params: [String: Any] = ["reason": reason]
        if let detail {
            params["detail"] = detail
        }
        // allowWhenEnded: this IS the terminal entry, written by the call that just ended the
        // session, so it is the one append the ended-session guard has to let through.
        store.append(sessionID: sessionID, method: "bridge/session_ended", params: params,
                     allowWhenEnded: true)
    }
}

#endif
