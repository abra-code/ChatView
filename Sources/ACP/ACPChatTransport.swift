// Sources/ACP/ACPChatTransport.swift
//
// The ACP (Agent Client Protocol) transport: launches an ACP agent as a subprocess
// (over ACPConnection's stdio JSON-RPC) and maps the ACP session vocabulary onto the
// normalized ChatEvent / ChatCommand stream. This file is the ONLY place that knows
// ACP's method names and payload shapes (the design doc's "keep the transport's ACP
// mapping in one file"); everything above it - store, router, views - is unchanged
// from the scripted local transport.
//
// Lifecycle: start() launches the agent, runs `initialize` (advertising NO fs /
// terminal capabilities - this host is a chat surface, not an editor, so the agent
// must not assume one), opens a session with `session/new` (cwd + declared MCP
// servers), and emits sessionReady. A `.prompt` command becomes one `session/prompt`
// turn; during the turn the agent streams `session/update` notifications which demux
// onto ChatEvents per the design doc's table, and the turn ends when the prompt
// request resolves with a stopReason. `.cancel` sends the `session/cancel`
// notification (the in-flight prompt then resolves with stopReason "cancelled").
// `session/request_permission` parks the agent's request on a continuation until the
// UI answers via `.permissionResponse` (or the turn is cancelled), then resolves with
// ACP's selected / cancelled outcome. fs/* and terminal/* requests are answered
// "method not found" since the capabilities were never advertised.
//
// Message identity: ACP does not carry per-message IDs - chunks belong to the turn.
// The transport owns the segmentation: contiguous runs of agent_message_chunk /
// user_message_chunk / agent_thought_chunk become one transcript item each; a run
// closes when a different update kind (or the turn's end) arrives. A mid-turn segment
// close emits messageEnd with a nil stopReason (the turn continues); the final close
// carries the prompt's real stopReason.
//
// macOS-only, like ACPConnection (subprocesses do not exist on iOS); the factory
// falls back to the local transport elsewhere. `@unchecked Sendable`: the mutable
// segmentation / permission state is guarded by `lock`.

#if os(macOS)

import Foundation
import ChatView

final class ACPChatTransport: ChatTransport, @unchecked Sendable {

    let events: AsyncStream<ChatEvent>
    private let eventSink: AsyncStream<ChatEvent>.Continuation
    private let logger: any ChatLogger

    private let command: [String]
    private let cwd: String
    private let mcpServers: [[String: Any]]
    private let env: [String: String]
    let startupTimeout: TimeInterval                  // internal so tests can pin the "absent means none" default

    private let lock = NSLock()
    private var connection: ACPConnection?
    private var startupTimedOut = false               // the startup watchdog fired (wording for the error)
    private var startupFinished = false               // start() reached its end; the watchdog must no longer fire
    private var sessionID: String?
    private var sessionOptions: [SessionConfigOption] = []   // retained for the setter's fallback mapping
    private var promptTask: Task<Void, Never>?

    // Segmentation state (see the header): the currently-open transcript items.
    private var itemCounter = 0
    private var openMessageID: String?
    private var openMessageRole: ChatRole = .agent
    private var openThoughtID: String?

    // Permission state: synthesized request ID -> the continuation parking the agent's
    // session/request_permission until the UI answers.
    private var permissionCounter = 0
    private var pendingPermissions: [String: CheckedContinuation<String?, Never>] = [:]

    // Priming state (session/prime, an mlx-agent extension): the store seeds the wire
    // history on every content restore / New Chat clear (ChatTransport.primeHistory);
    // this transport forwards it to agents that advertise the `sessionPrime` capability.
    private var supportsPrime = false                 // initialize: agentCapabilities.sessionPrime == true
    private var pendingPrime: [ChatMessage]?          // prime requested before session/new resolved (last write wins)
    // Stashed WITH its wire payload, and cleared with it. A condense request that outlived the
    // prime it belonged to would summarize a later, unrelated restore.
    private var pendingCondense: PrimeCondense?
    private var primeTask: Task<Void, Never>?         // in-flight wire prime; prompts chain behind it
    private var hasPrimedOnce = false                 // a non-empty prime was enqueued (an empty reset is meaningful after this)
    private var hasEverPrompted = false               // a turn ran (an empty reset is meaningful after this too)
    private var turnGeneration = 0                    // guards finishTurn's promptTask clear against a newer registration
    // Stop during the PRE-DISPATCH gap. A registered turn does not reach the wire
    // immediately: startTurn's task first awaits any in-flight prime, so there is a window
    // where the turn exists to the client but the agent has never heard of it - a
    // session/cancel notify in that window cancels nothing, and the turn then dispatches
    // and runs to completion despite the user pressing Stop. These two fields close it:
    // the cancel LATCHES against the current generation, and the task CLAIMS the dispatch
    // under the lock, so exactly one of the two wins.
    private var cancelledGeneration = 0               // newest generation cancelled by the client
    private var promptDispatched = false              // the current turn's session/prompt reached the wire

    /// `transport` config: `command` (argv array, required), `cwd` (string, defaults to
    /// the host's current directory), `mcpServers` (array of ACP server declarations,
    /// passed through verbatim), `env` (string-to-string map, merged over the inherited
    /// environment; `PATH` here governs bare-name resolution of `command[0]`),
    /// `startupTimeoutSeconds` (number; absent or <= 0 means NO timeout - the bundled
    /// local agent may legitimately take minutes to load a large model).
    init(config: ChatTransportConfig, logger: any ChatLogger) throws {
        guard let command = config.stringArray("command"), !command.isEmpty else {
            throw ACPConnectionError(code: nil, message: "transport.command (a non-empty string array) is required for protocol \"acp\"")
        }
        self.command = command
        // ACP requires the session cwd to be an ABSOLUTE path: agents resolve a relative
        // path against their own working directory (a literal "~" reached OpenCode as
        // "<cwd>/~" and failed session/new with "Invalid path"). Expand ~ and anchor
        // relative paths once here, so the launch and the wire see the same absolute path.
        self.cwd = Self.absoluteCwd(config.string("cwd"))
        self.mcpServers = config.dictionaryArray("mcpServers") ?? []
        let rawEnv = config.dictionary("env") ?? [:]
        let stringEnv = rawEnv.compactMapValues { $0 as? String }
        self.env = stringEnv
        if stringEnv.count != rawEnv.count {
            let dropped = rawEnv.keys.filter { stringEnv[$0] == nil }.sorted()
            logger.log("ACP: transport.env values must be strings; ignoring \(dropped.joined(separator: ", "))", .warning)
        }
        // Clamped and finite-checked, because this arrives as host JSON: a stray 1e12 (or an
        // Infinity or NaN from a plist-sourced number) would otherwise reach the UInt64
        // nanosecond conversion below and trap, taking the whole host down rather than
        // mistiming one launch. A day is far past any legitimate agent startup.
        let rawTimeout = config.double("startupTimeoutSeconds") ?? 0
        self.startupTimeout = rawTimeout.isFinite ? min(max(rawTimeout, 0), 86_400) : 0
        self.logger = logger
        var captured: AsyncStream<ChatEvent>.Continuation!
        self.events = AsyncStream(bufferingPolicy: .unbounded) { captured = $0 }
        self.eventSink = captured
    }

    /// The configured cwd as the absolute path ACP requires: "~" expands, a relative
    /// path anchors to the host's current directory, nil/empty falls back to the
    /// host's current directory. Internal for tests.
    static func absoluteCwd(_ raw: String?) -> String {
        guard let raw, !raw.isEmpty else {
            return FileManager.default.currentDirectoryPath
        }
        let expanded = (raw as NSString).expandingTildeInPath
        if expanded.hasPrefix("/") {
            return expanded
        }
        return URL(fileURLWithPath: expanded).path
    }

    // MARK: - ChatTransport

    func start() async {
        // The store builds a fresh transport per attach, so this runs once per instance - but
        // the startup latches below are one-shot, and a future flow that re-entered start()
        // on the same transport would find the watchdog silently disarmed and a stale timeout
        // flag mislabelling the next failure. Cheap insurance, no behavior change today.
        lock.withLock {
            startupFinished = false
            startupTimedOut = false
        }
        let connection = ACPConnection(
            logger: logger,
            onNotification: { [weak self] method, params in
                self?.handleNotification(method, params)
            },
            onRequest: { [weak self] method, params in
                await self?.handleRequest(method, params)
            },
            onClose: { [weak self] exitStatus in
                self?.handleAgentClosed(exitStatus: exitStatus)
            }
        )
        lock.withLock { self.connection = connection }

        // Startup watchdog: on expiry, stop the CONNECTION. handleClose then fails every
        // pending continuation, so the awaited initialize / session/new throws and the
        // existing catch below reports it. Deliberately NOT a task group racing the request:
        // ACPConnection.request ignores cancellation, and a throwing group awaits its
        // children before rethrowing, so the group would wait forever on the very request
        // the timeout is meant to abandon.
        let watchdog: Task<Void, Never>?
        if startupTimeout > 0 {
            let seconds = startupTimeout
            watchdog = Task { [weak self, weak connection, logger] in
                try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                guard let self else { return }
                // Decide against start()'s completion under the SAME lock acquisition that
                // latches the timeout. Task.isCancelled alone is not enough: a session that
                // becomes ready between that check and connection.stop() would be torn down
                // with no error event at all, leaving a chat window that looks live and is
                // permanently dead. That window is real whenever an agent's true startup
                // time sits near the configured timeout.
                let expired = self.lock.withLock { () -> Bool in
                    if self.startupFinished { return false }
                    self.startupTimedOut = true
                    return true
                }
                guard expired else { return }
                logger.log("ACP: agent did not become ready within \(Self.secondsText(seconds))s; stopping it", .warning)
                connection?.stop()
            }
        } else {
            watchdog = nil
        }
        // Fires on every exit from start() - success, throw, and the catch. The flag is
        // published BEFORE the cancel, so a watchdog already past its sleep still sees it.
        defer {
            lock.withLock { startupFinished = true }
            watchdog?.cancel()
        }

        do {
            try connection.launch(command: command, cwd: cwd, environment: env)
            let initResult = try await connection.request("initialize", [
                "protocolVersion": 1,
                "clientCapabilities": [
                    "fs": ["readTextFile": false, "writeTextFile": false],
                    "terminal": false,
                ],
                // All three clientInfo fields: some agents (opencode) require `version`
                // to be present as a string when clientInfo is given at all.
                "clientInfo": ["name": "ActionUIChat", "title": "ActionUI Chat", "version": "1.0"],
            ])
            if let version = (initResult["protocolVersion"] as? NSNumber)?.intValue, version != 1 {
                logger.log("ACP: agent negotiated protocol version \(version) (client speaks 1); continuing", .warning)
            }
            let agentCaps = initResult["agentCapabilities"] as? [String: Any]
            let agentInfo = initResult["agentInfo"] as? [String: Any]
            let negotiatedVersion = (initResult["protocolVersion"] as? NSNumber)?.intValue
            lock.withLock { supportsPrime = (agentCaps?["sessionPrime"] as? Bool) ?? false }
            let authMethods = (initResult["authMethods"] as? [[String: Any]]) ?? []

            do {
                let session = try await connection.request("session/new", [
                    "cwd": cwd,
                    "mcpServers": mcpServers,
                ])
                guard let sessionID = session["sessionId"] as? String else {
                    throw ACPConnectionError(code: nil, message: "session/new returned no sessionId")
                }
                let options = ACPWire.parseConfigOptions(session)
                // Publish the session AND flush a prime that arrived before it existed (the
                // store primes on attach, BEFORE start() runs) in ONE lock acquisition:
                // once sessionID is visible, a live-session primeHistory registers its own
                // primeTask directly - a separate flush lock could then overwrite it with
                // the older stash and put two primes on the wire. Registered as primeTask
                // so a prompt racing in right after sessionReady chains behind it.
                // The same acquisition also settles the race with the startup watchdog, in the
                // only place it can be settled: the watchdog latches startupTimedOut under
                // this lock, so whichever side takes it first wins outright. Publishing the
                // session first and marking startup finished later (in the defer) would leave
                // a window where the watchdog stops the connection AFTER sessionReady - and
                // because that teardown runs with notify: false, the user would be left with a
                // window that looks ready over an agent that is gone.
                let lostToWatchdog = lock.withLock { () -> Bool in
                    if startupTimedOut {
                        return true
                    }
                    startupFinished = true
                    self.sessionID = sessionID
                    self.sessionOptions = options
                    if let stash = pendingPrime {
                        let stashedCondense = pendingCondense
                        pendingPrime = nil
                        pendingCondense = nil
                        if !stash.isEmpty { hasPrimedOnce = true }
                        primeTask = Task { [weak self] in
                            await self?.sendPrime(stash, condense: stashedCondense)
                        }
                    }
                    return false
                }
                if lostToWatchdog {
                    throw ACPConnectionError(code: nil, message: "the startup watchdog stopped the agent")
                }
                eventSink.yield(.sessionReady(sessionID: sessionID, configOptions: options))
                eventSink.yield(.sessionInfo(AgentSessionInfo(
                    sessionId: sessionID,
                    agentName: agentInfo?["name"] as? String,
                    agentVersion: agentInfo?["version"] as? String,
                    protocolVersion: negotiatedVersion,
                    agentPid: connection.processID.map(Int.init),
                    canLoadSession: (agentCaps?["loadSession"] as? Bool) ?? false,
                    canPrime: (agentCaps?["sessionPrime"] as? Bool) ?? false,
                    resumed: false)))
            } catch {
                // A common session/new failure is an agent that requires auth first; name
                // the advertised methods so that case is actionable (auth UX is a later
                // milestone) - but phrase it as a possibility, not a diagnosis: session/new
                // also fails for non-auth reasons (an agent-side internal error, say). A
                // timeout is never one of them: the outer catch already has the right words,
                // and blaming login for a hang would send the user off fixing the wrong thing.
                if authMethods.isEmpty || lock.withLock({ startupTimedOut }) {
                    throw error
                }
                let names = authMethods.compactMap { $0["id"] as? String ?? $0["name"] as? String }
                throw ACPConnectionError(code: nil, message: "\(error). If the agent requires login, authenticate outside the chat element first (it advertises: \(names.joined(separator: ", ")))")
            }
        } catch {
            // Name the timeout rather than the closed connection it produced, and carry the
            // agent's last stderr lines: /usr/bin/env's own "no such file or directory" and
            // an agent's fatal startup message both arrive there and are the actual diagnosis.
            let timedOut = lock.withLock { startupTimedOut }
            var message = timedOut
                // Deliberately does not say "no response to initialize or session/new": the
                // watchdog also wins narrow races against a session that had just answered,
                // and naming a request that did reply would send the user hunting a hang that
                // never happened.
                ? "The ACP agent did not become ready within \(Self.secondsText(startupTimeout))s; the startup timeout stopped it"
                : "ACP agent failed to start: \(error)"
            // Pick up stderr the readability handler has not delivered yet: the failure that
            // brought us here (stdout EOF / process exit) races that handler, and stop()
            // below removes it, so without this the diagnosis is silently lost.
            connection.drainStderr()
            let tail = connection.stderrTailText()
            if !tail.isEmpty {
                message += "\nAgent output:\n\(tail)"
            }
            eventSink.yield(.error(message: message, recoverable: false))
            // No session, no retry path: do not leave the agent subprocess running
            // until the element's teardown gets around to it.
            connection.stop()
        }
    }

    func send(_ command: ChatCommand) async {
        switch command {
        case .prompt(let text):
            startTurn(prompt: text)

        case .cancel:
            let target = lock.withLock { () -> (connection: ACPConnection, sessionID: String, notifyAgent: Bool)? in
                guard let connection, let sessionID else { return nil }
                // Latch the Stop against the turn that is current RIGHT NOW. If that turn
                // has not claimed its dispatch yet, startTurn's task will see this and
                // suppress the request instead of racing it onto the wire.
                cancelledGeneration = turnGeneration
                // Only tell the agent about a turn it actually knows about. With a turn
                // registered but not dispatched there is nothing to cancel agent-side (the
                // suppression below ends it); with no turn at all, notify exactly as before.
                return (connection, sessionID, promptTask == nil || promptDispatched)
            }
            guard let target else {
                return
            }
            if target.notifyAgent {
                target.connection.notify("session/cancel", ["sessionId": target.sessionID])
            }
            // Per ACP, a cancelled turn must also resolve any pending permission
            // requests with the cancelled outcome; the prompt then returns
            // stopReason "cancelled", which ends the turn.
            resolveAllPermissions(with: nil)

        case .permissionResponse(let requestID, let optionID):
            let continuation = lock.withLock { pendingPermissions.removeValue(forKey: requestID) }
            continuation?.resume(returning: optionID)

        case .setConfigOption(let optionID, let value):
            await performSetConfigOption(optionID: optionID, value: value)

        case .sendMessage, .toggleReaction, .editMessage, .deleteMessage, .resendMessage,
             .markRead, .loadEarlier, .setTyping, .cancelFileTransfer:
            // ACP advertises no P2P capabilities, so the store never emits these; ignore.
            break
        }
    }

    /// Reserves the per-turn id namespaces this transport mints so a turn continued after a
    /// transcript restore does not reuse a loaded id (see ChatTransport.reserveIDs). Our ids
    /// ("acp-turn-<n>" / "acp-thought-<n>" / "acp-message-<n>") come from itemCounter, which
    /// resets to 0 for each fresh transport instance (every app launch); a reused id would make
    /// the store's ForEach overwrite an existing bubble and the journal's last-write-wins dedup
    /// drop the older item. The client mints these display/journal ids regardless of the agent's
    /// own server-side history, so this reservation is needed even though primeHistory is a no-op
    /// for ACP.
    func reserveIDs(seen ids: [String]) {
        guard let maxSuffix = ids.compactMap(Self.itemSuffix).max() else { return }
        lock.withLock {
            if maxSuffix > itemCounter { itemCounter = maxSuffix }
        }
    }

    /// The numeric suffix of one of our per-turn ids ("acp-turn-<n>" / "acp-thought-<n>" /
    /// "acp-message-<n>"), or nil for any other id. All three share itemCounter, so reserving
    /// past any of them keeps a continued turn from reusing a loaded id.
    private static func itemSuffix(_ id: String) -> Int? {
        for prefix in ["acp-turn-", "acp-thought-", "acp-message-"] where id.hasPrefix(prefix) {
            return Int(id.dropFirst(prefix.count))
        }
        return nil
    }

    // MARK: - Priming (session/prime, mlx-agent extension)

    /// Replaces the agent's conversational context with the restored transcript's messages
    /// (empty = fresh context), for agents that advertise the `sessionPrime` capability.
    /// Called synchronously by the store on every content restore and on transport attach,
    /// always before any subsequent prompt.
    ///
    /// Deadlock guard (invariant, do not weaken): the snapshot of the other side's task and
    /// the registration of our own task happen inside ONE lock acquisition, on BOTH this
    /// path and startTurn, and the Task bodies await only the snapshotted values. Separate
    /// lock acquisitions (or a fresh field read inside a Task body) admit a circular await -
    /// a prompt submitted in the same instant as a restore could make the prompt task await
    /// the new prime while the prime awaits that very prompt, wedging the composer for the
    /// life of the transport. With both snapshot-and-register pairs atomic, every task can
    /// only await tasks registered strictly before its own registration, so the wait graph
    /// is acyclic under any interleaving.
    func primeHistory(_ messages: [ChatMessage]) { primeHistory(messages, condense: nil) }

    func primeHistory(_ messages: [ChatMessage], condense: PrimeCondense?) {
        // Model context is user/assistant text only: session notices (.system) and P2P
        // (.remote) are display items, not conversation the model produced or saw.
        let wire = messages.filter { ($0.role == .local || $0.role == .agent) && !$0.text.isEmpty }
        let cancelTurn: (connection: ACPConnection, sessionID: String)? = lock.withLock {
            // An empty prime is a context RESET; it only means something once the agent-side
            // context could be non-empty (a prior prime or a completed turn). Suppressing the
            // virgin case avoids a useless session/prime [] on every window open.
            if wire.isEmpty && !hasPrimedOnce && !hasEverPrompted {
                return nil
            }
            guard let sessionID else {
                // Session not up yet (attach primes before start()): stash, last write wins;
                // start() flushes it right after session/new. The capability is unknown
                // until initialize resolves, so the stash is unconditional.
                pendingPrime = wire
                pendingCondense = condense
                return nil
            }
            guard supportsPrime else {
                // Full no-op for agents without the capability - including the mid-turn
                // cancel below, so a foreign ACP agent keeps today's behavior exactly.
                logger.log("ACP: agent does not advertise sessionPrime; the restored context will not reach the model", .warning)
                return nil
            }
            if !wire.isEmpty { hasPrimedOnce = true }
            let previousPrime = primeTask
            let inFlightTurn = promptTask
            primeTask = Task { [weak self] in
                await previousPrime?.value   // last prime wins; never two on the wire at once
                await inFlightTurn?.value    // the agent's busy flag clears when the turn RESOLVES
                await self?.sendPrime(wire, condense: condense)
            }
            // A restore during a streaming turn: the turn must be cancelled for inFlightTurn
            // to resolve (the store has already cleared its streaming UI state). The notify
            // goes out after this lock releases; ordering is safe because the prime is sent
            // only after the cancelled prompt's RESPONSE arrives.
            if inFlightTurn != nil {
                // Same latch as send(.cancel): a turn still inside the pre-dispatch gap must
                // be suppressed, not merely notified about - otherwise the abandoned
                // conversation's prompt would still reach the agent, and the prime behind it
                // would wait out a turn the user already navigated away from.
                cancelledGeneration = turnGeneration
                if !promptDispatched { return nil }
                if let connection { return (connection, sessionID) }
            }
            return nil
        }
        if let cancelTurn {
            cancelTurn.connection.notify("session/cancel", ["sessionId": cancelTurn.sessionID])
            resolveAllPermissions(with: nil)
        }
    }

    /// Sends one session/prime request. A first -32003 is an expected transient (the agent
    /// clears its busy flag a hair after responding to a cancelled prompt), so one bounded
    /// retry; anything else surfaces as a system line - a failed prime must not kill the
    /// session, but the user must know Resume did not take.
    private func sendPrime(_ messages: [ChatMessage], condense: PrimeCondense?) async {
        let (connection, sessionID, supported) = lock.withLock { (self.connection, self.sessionID, self.supportsPrime) }
        guard let connection, let sessionID else {
            return
        }
        guard supported else {
            logger.log("ACP: agent does not advertise sessionPrime; the restored context will not reach the model", .warning)
            return
        }
        let wire: [[String: Any]] = messages.map {
            ["role": $0.role == .local ? "user" : "assistant", "content": $0.text]
        }
        var lastError: Error?
        for attempt in 0..<2 {
            if attempt > 0 {
                try? await Task.sleep(nanoseconds: 300_000_000)
            }
            do {
                var params: [String: Any] = [
                    "sessionId": sessionID,
                    "messages": wire,
                ]
                if let condense {
                    var ask: [String: Any] = [:]
                    if let keep = condense.keepRecentTurns { ask["keepRecentTurns"] = keep }
                    if let maxTokens = condense.maxDigestTokens { ask["maxDigestTokens"] = maxTokens }
                    // Sent even when empty: the KEY is the request. Omitting it because both
                    // bounds are nil would silently turn "summarize with your defaults" into
                    // "replay everything", which is the opposite of what the caller asked.
                    params["condense"] = ask
                }
                let result = try await connection.request("session/prime", params)
                let count = (result["primed"] as? NSNumber)?.intValue ?? wire.count
                logger.log("ACP: primed \(count) messages (\(wire.count) sent)", .verbose)
                emitCondensationEvent(from: result, requested: condense != nil)
                return
            } catch let error as ACPConnectionError where error.code == -32003 {
                lastError = error   // transient: the cancelled turn had not fully resolved agent-side
            } catch {
                lastError = error
                break
            }
        }
        eventSink.yield(.system(text: "Could not restore the conversation context to the agent: \(lastError.map { "\($0)" } ?? "unknown error")"))
    }

    /// The marker's own clock. Stamped HERE rather than taken from the agent because the agent
    /// does not send one, and a marker whose time came from the reader's machine is the honest
    /// reading anyway: it records when this session picked the conversation back up.
    ///
    /// ISO8601DateFormatter is not Sendable, but a configured instance's string(from:) is
    /// read-only and safe to share - the same reasoning ChatTimestamp documents for parsing.
    nonisolated(unsafe) private static let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    private static func isoNow() -> String { iso.string(from: Date()) }

    /// Turn a condensed prime into something the user can read.
    ///
    /// A digest the model holds and the person cannot see is a context loss they can only infer
    /// from the answers getting worse - they end up guessing what was dropped. So the moment the
    /// agent says it summarized, the transcript gets a marker carrying the summary itself.
    ///
    /// SILENT WHEN NOTHING WAS CONDENSED. `condensed: false` is the ordinary, healthy answer -
    /// the agent primed the full history and said why - and a marker announcing "nothing was
    /// summarized" on every restore would be noise for the common case. The `reason` is logged
    /// instead, because it explains a slow first turn to whoever is reading the log.
    private func emitCondensationEvent(from result: [String: Any], requested: Bool) {
        let condensed = (result["condensed"] as? NSNumber)?.boolValue ?? false
        guard condensed else {
            if requested, let reason = result["reason"] as? String {
                logger.log("ACP: prime was not condensed - \(reason)", .verbose)
            }
            return
        }

        let summarizer = result["summarizer"] as? String
        let dropped = result["dropped"] as? [String: Any]
        let droppedTurns = (dropped?["turns"] as? NSNumber)?.intValue
        let primed = (result["primed"] as? NSNumber)?.intValue
        let body = result["digest"] as? [String: Any] ?? [:]

        // The verbatim tail is what the reader most wants bounded ("how much of this is exact?").
        // `primed` counts the REPLACEMENT history, which includes the preamble and, usually, an
        // acknowledgment turn - so the tail is primed minus those. The agent documents `injected`
        // as 1 or 2 and does not send it, so this is the one number here that is an estimate; it
        // is reported only when it comes out sane.
        let verbatim = primed.map { max(0, $0 - 2) }

        let digest = SessionDigest(
            summarizer: summarizer,
            droppedTurns: droppedTurns,
            verbatimTurns: verbatim,
            unresolvedIntent: body["unresolvedIntent"] as? String,
            establishedFacts: body["establishedFacts"] as? [String] ?? [],
            decisions: body["decisions"] as? [String] ?? [],
            openThreads: body["openThreads"] as? [String] ?? [],
            userPreferences: body["userPreferences"] as? [String] ?? [])

        eventSink.yield(.sessionEvent(SessionEvent(
            id: "condense-\(UUID().uuidString)",
            kind: .resumed,
            timestamp: Self.isoNow(),
            model: nil,
            digest: digest)))
    }

    /// Changes a session option. The primary method is the generic
    /// session/set_config_option { sessionId, configId, type: "select", value }, whose
    /// result carries the REFRESHED configOptions list (verified live against
    /// OpenCode); an agent that lacks it (-32601) gets the spec-sketched per-category
    /// fallbacks (session/set_mode / session/set_model), whose confirmation is the
    /// agent's own current_mode_update notification - no synthetic events, so the
    /// display never claims a change the agent did not confirm.
    private func performSetConfigOption(optionID: String, value: String) async {
        let (connection, sessionID) = lock.withLock { (self.connection, self.sessionID) }
        guard let connection, let sessionID else {
            return
        }
        do {
            let result = try await connection.request("session/set_config_option", [
                "sessionId": sessionID,
                "configId": optionID,
                "type": "select",
                "value": value,
            ])
            let refreshed = ACPWire.parseConfigOptions(result)
            if !refreshed.isEmpty {
                lock.withLock { sessionOptions = refreshed }
                eventSink.yield(.configOptionsChanged(refreshed))
            }
        } catch let error as ACPConnectionError where error.code == -32601 {
            let option = lock.withLock { sessionOptions.first(where: { $0.id == optionID }) }
            guard let fallback = Self.fallbackSetter(for: option) else {
                logger.log("ACP: agent offers no setter for option '\(optionID)'", .warning)
                return
            }
            do {
                _ = try await connection.request(fallback.method, ["sessionId": sessionID, fallback.paramKey: value])
            } catch {
                eventSink.yield(.system(text: "Could not change \(optionID): \(error)"))
            }
        } catch {
            eventSink.yield(.system(text: "Could not change \(optionID): \(error)"))
        }
    }

    /// The spec-sketched per-category setters, used when the generic method is absent.
    /// Internal for tests.
    static func fallbackSetter(for option: SessionConfigOption?) -> (method: String, paramKey: String)? {
        switch option?.category ?? option?.id {
        case "mode":
            return (method: "session/set_mode", paramKey: "modeId")
        case "model":
            return (method: "session/set_model", paramKey: "modelId")
        default:
            return nil
        }
    }

    /// A timeout rendered for a human: whole seconds stay whole ("30"), a sub-second timeout
    /// keeps its fraction rather than reading as "0".
    static func secondsText(_ seconds: TimeInterval) -> String {
        String(format: "%g", seconds)
    }

    /// The spawned agent's pid while the connection is live - the same value `.sessionInfo`
    /// publishes. Internal so tests can watch the subprocess directly.
    var agentProcessID: Int32? {
        lock.withLock { connection }?.processID
    }

    func stop() async {
        let (connection, task, prime) = lock.withLock { (self.connection, self.promptTask, self.primeTask) }
        task?.cancel()
        prime?.cancel()
        resolveAllPermissions(with: nil)
        connection?.stop()
        eventSink.finish()
    }

    // MARK: - Outbound turn

    private func startTurn(prompt: String) {
        let (connection, sessionID) = lock.withLock { (self.connection, self.sessionID) }
        guard let connection, let sessionID else {
            eventSink.yield(.error(message: "ACP session is not ready; message not sent", recoverable: true))
            return
        }
        // Snapshot the in-flight prime and register the prompt task under ONE lock
        // acquisition, and await only the snapshot - see the deadlock guard on
        // primeHistory. A prime on the wire strictly precedes this prompt.
        lock.withLock {
            let inFlightPrime = primeTask
            hasEverPrompted = true
            turnGeneration += 1
            let generation = turnGeneration
            promptDispatched = false
            promptTask = Task { [weak self] in
                await inFlightPrime?.value
                // Claim the dispatch, or lose to a Stop that landed during the prime await
                // (or before this task was even scheduled). self stays weakly held across
                // the request below, as before.
                guard let claimed = self?.claimDispatch(generation: generation) else { return }
                guard claimed else {
                    self?.finishTurn(stopReason: "cancelled", generation: generation)
                    return
                }
                do {
                    let result = try await connection.request("session/prompt", [
                        "sessionId": sessionID,
                        "prompt": [["type": "text", "text": prompt]],
                    ])
                    let stopReason = (result["stopReason"] as? String) ?? "end_turn"
                    self?.finishTurn(stopReason: stopReason, generation: generation)
                } catch {
                    self?.eventSink.yield(.error(message: "ACP turn failed: \(error)", recoverable: true))
                    self?.finishTurn(stopReason: "error", generation: generation)
                }
            }
        }
    }

    /// Claims the wire for this turn, or concedes it to a Stop that already landed. The
    /// latch check and the claim are ONE lock acquisition (the invariant that makes the
    /// pre-dispatch gap safe): a concurrent `.cancel` therefore either sees an unclaimed
    /// turn and lets this suppress it, or sees `promptDispatched` and notifies the agent -
    /// the interleaving where both conclude "the other side will handle it", leaving a Stop
    /// that stops nothing, cannot occur. Returns false when this turn must not dispatch.
    private func claimDispatch(generation: Int) -> Bool {
        lock.withLock {
            if cancelledGeneration >= generation { return false }
            promptDispatched = true
            return true
        }
    }

    /// Ends the turn: closes whatever item is still open, emits the terminal
    /// messageEnd carrying the turn's real stopReason (a non-nil stopReason is what
    /// flips the store out of its streaming state), and clears `promptTask` so
    /// "a turn is in flight" stays a truthful test (primeHistory's cancel path keys
    /// on it). Generation-guarded: only the turn that registered the current task
    /// clears it, so a stale finish can never unregister a newer turn.
    private func finishTurn(stopReason: String, generation: Int) {
        let itemID = lock.withLock { () -> String in
            if turnGeneration == generation {
                promptTask = nil
            }
            openThoughtID = nil
            if let open = openMessageID {
                openMessageID = nil
                return open
            }
            itemCounter += 1
            return "acp-turn-\(itemCounter)"
        }
        eventSink.yield(.messageEnd(itemID: itemID, stopReason: stopReason))
    }

    // MARK: - Inbound: notifications (the session/update demux)

    // Internal (not private) so tests can drive the demux without a subprocess.
    func handleNotification(_ method: String, _ params: [String: Any]) {
        guard method == "session/update" else {
            logger.log("ACP: unhandled notification \(method)", .verbose)
            return
        }
        guard let update = params["update"] as? [String: Any],
              let kind = update["sessionUpdate"] as? String else {
            logger.log("ACP: session/update with no update payload; dropping", .warning)
            return
        }

        switch kind {
        case "agent_message_chunk":
            appendMessageChunk(update, role: .agent)

        case "user_message_chunk":
            appendMessageChunk(update, role: .local)

        case "agent_thought_chunk":
            let text = ACPWire.contentText(update["content"])
            guard !text.isEmpty else {
                return
            }
            closeOpenMessage()
            let itemID = lock.withLock { () -> String in
                if let open = openThoughtID {
                    return open
                }
                itemCounter += 1
                let id = "acp-thought-\(itemCounter)"
                openThoughtID = id
                return id
            }
            eventSink.yield(.thoughtDelta(itemID: itemID, text: text))

        case "tool_call":
            closeOpenMessage()
            lock.withLock { openThoughtID = nil }
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
            if let modeID = update["currentModeId"] as? String {
                eventSink.yield(.currentModeChanged(modeID: modeID))
            }

        case "available_commands_update":
            eventSink.yield(.commandsAvailable(ACPWire.parseCommands(update)))

        default:
            logger.log("ACP: unknown session update '\(kind)'; dropping", .verbose)
        }
    }

    /// Streams one message chunk into the open message segment for `role`, opening a
    /// new segment (messageStart) if none is open or the speaker changed.
    private func appendMessageChunk(_ update: [String: Any], role: ChatRole) {
        let text = ACPWire.contentText(update["content"])
        guard !text.isEmpty else {
            return
        }
        // Whitespace-only text must not OPEN a new bubble - it would render as an empty assistant
        // message. Models routinely emit blank text at a segment boundary (the newline between
        // </think> and a tool call, or leading whitespace before a <think> block), which arrives here
        // as a whitespace-only chunk with no message open. Drop those. Once a bubble IS open, blank
        // text flows through normally so inter-word spacing inside a message is never lost.
        let hasOpenSegment = lock.withLock { openMessageID != nil && openMessageRole == role }
        if !hasOpenSegment, text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return
        }
        lock.withLock { openThoughtID = nil }
        let (itemID, isNew) = lock.withLock { () -> (String, Bool) in
            if let open = openMessageID, openMessageRole == role {
                return (open, false)
            }
            itemCounter += 1
            let id = "acp-message-\(itemCounter)"
            return (id, true)
        }
        if isNew {
            closeOpenMessage()
            lock.withLock {
                openMessageID = itemID
                openMessageRole = role
            }
            eventSink.yield(.messageStart(itemID: itemID, role: role))
        }
        eventSink.yield(.messageDelta(itemID: itemID, text: text))
    }

    /// Closes the open message segment mid-turn (nil stopReason: the turn continues).
    private func closeOpenMessage() {
        let open = lock.withLock { () -> String? in
            let open = openMessageID
            openMessageID = nil
            return open
        }
        if let open {
            eventSink.yield(.messageEnd(itemID: open, stopReason: nil))
        }
    }

    // MARK: - Inbound: agent -> client requests

    // Internal (not private) so tests can drive the permission round-trip without a subprocess.
    // The result is `sending` (always freshly built here) so callers on other tasks can consume it.
    func handleRequest(_ method: String, _ params: [String: Any]) async -> sending [String: Any]? {
        guard method == "session/request_permission" else {
            // fs/* and terminal/* land here: the capabilities were not advertised, so a
            // conforming agent should not call them; answer method-not-found either way.
            logger.log("ACP: agent requested unsupported method \(method)", .verbose)
            return nil
        }

        let toolCall = params["toolCall"] as? [String: Any]
        let options = ((params["options"] as? [[String: Any]]) ?? []).compactMap { raw -> PermissionRequest.Option? in
            guard let id = raw["optionId"] as? String,
                  let kind = (raw["kind"] as? String).flatMap(PermissionRequest.Option.Kind.init(rawValue:)) else {
                return nil
            }
            return PermissionRequest.Option(id: id, name: (raw["name"] as? String) ?? id, kind: kind)
        }
        guard !options.isEmpty else {
            logger.log("ACP: permission request carried no usable options; answering cancelled", .warning)
            return ["outcome": ["outcome": "cancelled"]]
        }

        let requestID = lock.withLock { () -> String in
            permissionCounter += 1
            return "acp-permission-\(permissionCounter)"
        }
        let request = PermissionRequest(
            id: requestID,
            toolCallID: toolCall?["toolCallId"] as? String,
            title: (toolCall?["title"] as? String) ?? "Allow this tool call?",
            options: options
        )
        eventSink.yield(.permissionRequest(request))

        let chosen = await withCheckedContinuation { (continuation: CheckedContinuation<String?, Never>) in
            lock.withLock { pendingPermissions[requestID] = continuation }
        }
        if let chosen {
            return ["outcome": ["outcome": "selected", "optionId": chosen]]
        }
        return ["outcome": ["outcome": "cancelled"]]
    }

    private func resolveAllPermissions(with optionID: String?) {
        let continuations = lock.withLock { () -> [CheckedContinuation<String?, Never>] in
            let waiting = Array(pendingPermissions.values)
            pendingPermissions.removeAll()
            return waiting
        }
        for continuation in continuations {
            continuation.resume(returning: optionID)
        }
    }

    private func handleAgentClosed(exitStatus: Int32?) {
        resolveAllPermissions(with: nil)
        let hadSession = lock.withLock { sessionID != nil }
        if hadSession {
            let status = exitStatus.map { " (exit status \($0))" } ?? ""
            eventSink.yield(.error(message: "The ACP agent exited\(status)", recoverable: false))
        }
    }

    // MARK: - Payload parsing
    //
    // The pure parsers moved to ACPWire (Sources/ACP/ACPWireParsing.swift) so the network
    // transport can share them: this file is macOS-only (it owns a subprocess), that one is
    // not. Call sites below read `ACPWire.parseX`. Behavior is unchanged - the move was
    // verbatim and ACPParsingTests pins it.

}

#endif
