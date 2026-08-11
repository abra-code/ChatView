// Sources/ACP/ACPConnection.swift
//
// The wire layer of the ACP transport: a newline-delimited JSON-RPC 2.0 connection to
// an agent subprocess over stdio. The client launches the agent (ACP's stdio model),
// writes one JSON-RPC message per line to the agent's stdin, and reads one message per
// line from its stdout. This file knows JSON-RPC framing and correlation only; the ACP
// method vocabulary lives in ACPChatTransport. macOS-only: spawning a subprocess
// (Foundation.Process) does not exist on iOS - the ACP remote transport (HTTP/WS) is
// still a work in progress upstream, so the framing here is kept in its own layer so a
// remote framing can swap in later.
//
// `@unchecked Sendable`: mutable state (the pending-request map, the id counter, the
// process handle, the stdout buffer, the termination flag) is guarded by `lock`; the
// stderr buffer and its retained tail have their own `stderrLock`, because reading that
// pipe and publishing what was read must be one critical section and must not queue
// behind a blocking write to the agent. Pipes and closures are immutable. Lines are
// handled in arrival order on the pipes' GCD readability callbacks; agent->client
// requests are answered from a per-request Task so a slow handler (a permission prompt
// waiting on the user) does not stall the stream.

#if os(macOS)

import Foundation
import ChatView

/// An error the agent returned for a JSON-RPC request, or a connection failure.
///
/// `package` rather than internal so the bridge target (ACPBridgeCore) can reuse this whole
/// process/stdio layer without any of it becoming public API of the ChatViewACP product.
package struct ACPConnectionError: Error, CustomStringConvertible {
    package let code: Int?
    package let message: String

    package init(code: Int?, message: String) {
        self.code = code
        self.message = message
    }

    package var description: String {
        if let code {
            return "\(message) (code \(code))"
        }
        return message
    }
}

package final class ACPConnection: @unchecked Sendable {

    /// A notification from the agent (method, params).
    package typealias NotificationHandler = @Sendable (String, [String: Any]) -> Void
    /// A request from the agent (method, params) -> result. Return nil to answer with
    /// a JSON-RPC "method not found" error (the capability was not advertised).
    package typealias RequestHandler = @Sendable (String, [String: Any]) async -> [String: Any]?
    /// The agent process ended (exit status, nil when only the stream closed).
    package typealias CloseHandler = @Sendable (Int32?) -> Void

    private let logger: any ChatLogger
    private let onNotification: NotificationHandler
    private let onRequest: RequestHandler
    private let onClose: CloseHandler

    private let inPipe = Pipe()     // client -> agent stdin
    private let outPipe = Pipe()    // agent stdout -> client
    private let errPipe = Pipe()    // agent stderr -> log

    private let lock = NSLock()
    private var process: Process?
    private var nextRequestID = 1
    private var pending: [Int: CheckedContinuation<[String: Any], any Error>] = [:]
    private var closed = false
    private var stdoutBuffer = Data()
    private var stopRequested = false

    // stderr state, guarded by its OWN lock: reading the pipe and publishing what was read
    // must be one critical section (see startReading), and that section must not contend
    // with the request/response state under `lock` - `send` holds `lock` across a blocking
    // write to the agent, and a stderr reader has no business waiting behind it.
    private let stderrLock = NSLock()
    private var stderrBuffer = Data()
    private var stderrTail: [String] = []
    private static let stderrTailMax = 40           // retained lines
    private static let stderrLineMax = 1_000        // characters kept per retained line
    private static let stderrTailTextMax = 4_000    // characters of tail put in one error message
    private static let stderrBufferMax = 64_000     // bytes of unterminated line held before it is published anyway
    private static let stderrChunkSize = 8_192      // bytes per read(2)
    private static let stderrReadBudget = 8         // reads per invocation (a full pipe buffer); see readStderr

    package init(logger: any ChatLogger,
         onNotification: @escaping NotificationHandler,
         onRequest: @escaping RequestHandler,
         onClose: @escaping CloseHandler) {
        self.logger = logger
        self.onNotification = onNotification
        self.onRequest = onRequest
        self.onClose = onClose
        // Non-blocking from construction, NOT from startReading(): a launch that throws (a
        // cwd that does not exist, say) never reaches startReading, and the failure path then
        // calls drainStderr() - which on a blocking fd whose write end WE still hold would
        // block forever, taking a cooperative thread with it and yielding no error at all.
        // The child inherits the write end, a separate file description, so this does not
        // change what the agent sees.
        Self.setNonBlocking(errPipe.fileHandleForReading.fileDescriptor)
    }

    /// Puts `fd` in non-blocking mode, if it is a real descriptor.
    private static func setNonBlocking(_ fd: Int32) {
        guard fd >= 0 else {
            return
        }
        let flags = fcntl(fd, F_GETFL)
        if flags >= 0 {
            _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)
        }
    }

    /// Spawns the agent. `command` is the argv (resolved through /usr/bin/env, so a bare
    /// name found on PATH and an absolute path both work); `cwd` roots the process.
    /// `environment` entries are merged OVER the inherited environment (everything not
    /// named is still inherited). Because /usr/bin/env itself receives the merged
    /// environment, a PATH entry here governs how a bare command name resolves.
    package func launch(command: [String], cwd: String?, environment: [String: String] = [:]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = command
        if let cwd, !cwd.isEmpty {
            process.currentDirectoryURL = URL(fileURLWithPath: (cwd as NSString).expandingTildeInPath)
        }
        process.standardInput = inPipe
        process.standardOutput = outPipe
        process.standardError = errPipe
        process.terminationHandler = { [weak self] finished in
            self?.handleClose(exitStatus: finished.terminationStatus)
        }
        if !environment.isEmpty {
            process.environment = ProcessInfo.processInfo.environment
                .merging(environment) { _, override in override }
        }
        // Refuse to spawn for a connection that was already stopped, and register the spawned
        // process under the SAME lock acquisition that re-checks the flag. stop() is a latch:
        // one that fires before there is a process finds nothing to terminate and disarms
        // every later call, so without this an agent spawned across that window would outlive
        // the element with nothing left to kill it.
        if lock.withLock({ stopRequested }) {
            throw ACPConnectionError(code: nil, message: "the connection was stopped before the agent launched")
        }
        try process.run()
        let stoppedWhileLaunching = lock.withLock { () -> Bool in
            if stopRequested {
                return true
            }
            self.process = process
            return false
        }
        if stoppedWhileLaunching {
            // The same terminate-and-escalate stop() uses, not a bare SIGTERM: an agent that
            // installs a TERM trap inside this window would otherwise survive with nothing
            // left to kill it (stop() already ran and found no process to terminate).
            terminateWithEscalation(process)
            throw ACPConnectionError(code: nil, message: "the connection was stopped while the agent was launching")
        }
        startReading()
    }

    /// Starts draining stdout (one JSON-RPC message per line) and stderr (to the log).
    /// Deliberately uses `readabilityHandler` (GCD-driven) with manual line buffering,
    /// NOT `FileHandle.bytes.lines`: the AsyncBytes iterator performs a BLOCKING read()
    /// on a Swift-concurrency cooperative thread, and two such readers (stdout + stderr)
    /// can starve the fixed-width cooperative pool and deadlock the whole process.
    func startReading() {
        outPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            guard let self else {
                handle.readabilityHandler = nil
                return
            }
            let data = handle.availableData
            if data.isEmpty {   // EOF: the agent's stdout closed
                handle.readabilityHandler = nil
                self.handleClose(exitStatus: nil)
                return
            }
            let lines = self.lock.withLock { Self.splitLines(buffer: &self.stdoutBuffer, appending: data) }
            for line in lines {
                self.handleLine(line)
            }
        }
        // stderr is read with a raw read(2) on the non-blocking fd set up in init, NOT
        // FileHandle.availableData. Two reasons, both load-bearing:
        //   - availableData RAISES an uncatchable ObjC exception ("Resource temporarily
        //     unavailable") on EAGAIN, and drainStderr can empty the pipe under a handler
        //     block that is already in flight (clearing readabilityHandler does not fence
        //     one), which would abort the host process.
        //   - read-and-publish has to be ONE critical section. availableData takes the bytes
        //     out of the pipe before the lock is taken, so a drain running in that gap finds
        //     the pipe empty AND the tail empty, and the diagnosis is lost - which is what
        //     the tail exists to prevent.
        errPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            guard let self else {
                handle.readabilityHandler = nil
                return
            }
            let (lines, eof) = self.readStderr()
            if eof {   // stderr closing with the process is unremarkable
                handle.readabilityHandler = nil
            }
            for line in lines {
                self.logger.log("ACP agent stderr: \(line)", .verbose)
            }
        }
    }

    /// Reads everything stderr has buffered right now and publishes it into the tail, all
    /// under `stderrLock`, so any other reader either waits or sees the bytes already in the
    /// tail - never in flight between the two. Non-blocking: with nothing buffered it returns
    /// immediately, so draining a live, quiet agent (the startup-timeout path) is free.
    /// Returns the complete lines read (for logging) and whether the pipe hit EOF.
    private func readStderr() -> (lines: [String], eof: Bool) {
        let fd = errPipe.fileHandleForReading.fileDescriptor
        guard fd >= 0 else {
            return ([], true)
        }
        var lines: [String] = []
        var eof = false
        var chunk = [UInt8](repeating: 0, count: Self.stderrChunkSize)
        stderrLock.withLock {
            // Bounded per invocation. An agent that writes stderr as fast as we read it would
            // otherwise never let this loop reach EAGAIN, holding stderrLock indefinitely
            // (starving drainStderr and stderrTailText, both of which the failure path calls
            // synchronously) and growing `lines` without limit - a flooding agent reached a
            // gigabyte resident in seconds. The budget covers a full pipe buffer; the read
            // source is level-triggered, so it simply fires again for whatever is left.
            for _ in 0..<Self.stderrReadBudget {
                let count = chunk.withUnsafeMutableBytes { read(fd, $0.baseAddress, $0.count) }
                if count > 0 {
                    lines.append(contentsOf: appendStderrLocked(Data(chunk[0..<count])))
                    continue
                }
                if count == 0 {
                    eof = true
                    return
                }
                if errno == EINTR {
                    continue   // a signal, not an end: retrying is what keeps the tail complete
                }
                return   // EAGAIN (nothing buffered) or a real error
            }
        }
        return (lines, eof)
    }

    /// Splits `data` into lines, publishes them into the tail, and returns them. Also bounds
    /// the line buffer itself: an agent that writes without newlines (a progress bar, a
    /// binary blob) must not grow it without limit, so past the cap the partial line is
    /// published as-is. Call under `stderrLock`.
    private func appendStderrLocked(_ data: Data) -> [String] {
        var lines = Self.splitLines(buffer: &stderrBuffer, appending: data)
        appendStderrTailLocked(lines)
        if stderrBuffer.count > Self.stderrBufferMax {
            let partial = takeStderrPartialLocked()
            appendStderrTailLocked([partial])
            lines.append(partial)   // returned too, so the force-flushed line still reaches the log
        }
        return lines
    }

    /// Consumes and returns the buffered partial (unterminated) stderr line. Call under
    /// `stderrLock`.
    private func takeStderrPartialLocked() -> String {
        let partial = String(decoding: stderrBuffer, as: UTF8.self)
        stderrBuffer.removeAll(keepingCapacity: false)
        return partial
    }

    /// Adds `lines` to the retained tail, bounded in BOTH directions: at most
    /// `stderrTailMax` lines, each at most `stderrLineMax` characters. A chatty agent can
    /// write megabyte-long lines (a stack trace, a base64 blob) and the tail lives for the
    /// whole session, so the line count alone is not a bound. Call under `stderrLock`.
    private func appendStderrTailLocked(_ lines: [String]) {
        for line in lines {
            stderrTail.append(line.count > Self.stderrLineMax ? String(line.prefix(Self.stderrLineMax)) + "..." : line)
        }
        if stderrTail.count > Self.stderrTailMax {
            stderrTail.removeFirst(stderrTail.count - Self.stderrTailMax)
        }
    }

    /// The agent's most recent stderr lines (oldest first), for actionable launch-failure
    /// messages. Empty when the agent wrote nothing. NOTE: the caller puts this text in
    /// front of the user (and, for a persisting host, on disk) - it is the agent's own
    /// output verbatim, so an agent that prints credentials at startup prints them there
    /// too. Bounded so a noisy agent cannot flood the transcript.
    package func stderrTailText(maxLines: Int = 12) -> String {
        let text = stderrLock.withLock { stderrTail.suffix(maxLines).joined(separator: "\n") }
        return text.count > Self.stderrTailTextMax ? String(text.suffix(Self.stderrTailTextMax)) : text
    }

    /// Reads whatever the agent has already written to stderr but the readability handler has
    /// not published yet, so a launch failure's diagnosis is not lost to a race. The handler
    /// runs on its own dispatch source: stdout EOF (or the termination handler) can reach
    /// handleClose - and with it the transport's catch - before the stderr source ever runs,
    /// and `stop()` then removes the handler for good. The tail was measured missing in ~2%
    /// of "command not found" launches on an idle machine and over 20% under load, which is
    /// exactly the case it exists for.
    ///
    /// This is a teardown-time drain - the caller stops the connection immediately after - so
    /// it also removes the readability handler, leaving this connection's stderr fully
    /// published rather than half here and half arriving later. Safe against a handler block
    /// already in flight: both readers go through readStderr, which is non-blocking and
    /// serialized.
    package func drainStderr() {
        errPipe.fileHandleForReading.readabilityHandler = nil
        let (lines, _) = readStderr()
        for line in lines {
            logger.log("ACP agent stderr: \(line)", .verbose)
        }
        // A last partial line (no trailing newline) is common when an agent dies mid-write,
        // and it is often the whole message - keep it rather than dropping it on the floor.
        stderrLock.withLock {
            guard !stderrBuffer.isEmpty else {
                return
            }
            appendStderrTailLocked([takeStderrPartialLocked()])
        }
    }

    /// The spawned agent's pid while it runs, for host-side lifecycle registries.
    package var processID: Int32? {
        lock.withLock { process?.processIdentifier }
    }

    /// Appends `data` to `buffer` and peels off every complete (newline-terminated) line.
    /// Call under whichever lock guards `buffer` (`lock` for stdout, `stderrLock` for
    /// stderr); the trailing partial line stays buffered.
    private static func splitLines(buffer: inout Data, appending data: Data) -> [String] {
        buffer.append(data)
        var lines: [String] = []
        while let newline = buffer.firstIndex(of: 0x0A) {
            let lineData = buffer[buffer.startIndex..<newline]
            lines.append(String(decoding: lineData, as: UTF8.self))
            buffer.removeSubrange(buffer.startIndex...newline)
        }
        return lines
    }

    /// Sends a request and suspends until the agent responds. Throws the agent's
    /// JSON-RPC error, or a connection error if the agent is gone.
    package func request(_ method: String, _ params: [String: Any]) async throws -> [String: Any] {
        let id = lock.withLock { () -> Int in
            let id = nextRequestID
            nextRequestID += 1
            return id
        }
        return try await withCheckedThrowingContinuation { continuation in
            let refused = lock.withLock { () -> Bool in
                if closed {
                    return true
                }
                pending[id] = continuation
                return false
            }
            if refused {
                continuation.resume(throwing: ACPConnectionError(code: nil, message: "agent connection is closed"))
                return
            }
            send(["jsonrpc": "2.0", "id": id, "method": method, "params": params])
        }
    }

    /// Sends a notification (no response expected).
    package func notify(_ method: String, _ params: [String: Any]) {
        send(["jsonrpc": "2.0", "method": method, "params": params])
    }

    /// Terminates the agent process (if running) and fails anything in flight. ACP agents
    /// normally exit on SIGTERM / stdin EOF; a wedged or TERM-trapping agent must not
    /// outlive the element, so a SIGKILL follows after a short grace. The deliberate-stop
    /// contract is preserved: the termination handler is cleared first and handleClose
    /// runs with notify: false, so teardown never surfaces an "agent exited" error.
    ///
    /// Idempotent, and it has to be: a timed-out launch stops the connection from the
    /// watchdog, again from the transport's catch, and once more when the store tears the
    /// transport down. Without the latch each call would schedule its own escalation closure,
    /// and each closure retains the Process for the whole grace period.
    ///
    /// One pre-existing limitation this cannot promise around: `send` holds `lock` across a
    /// blocking write, so an agent that stops draining its stdin while a large prompt is
    /// being written delays this call at its first lock acquisition.
    package func stop() {
        let alreadyStopping = lock.withLock { () -> Bool in
            if stopRequested {
                return true
            }
            stopRequested = true
            return false
        }
        guard !alreadyStopping else {
            return
        }
        outPipe.fileHandleForReading.readabilityHandler = nil
        errPipe.fileHandleForReading.readabilityHandler = nil
        if let process = lock.withLock({ self.process }) {
            terminateWithEscalation(process)
        }
        handleClose(exitStatus: nil, notify: false)
        // Close our end of the agent's stdin so a well-behaved agent still sees EOF promptly.
        // Before the escalation existed this happened when the connection deallocated; the
        // escalation closure now retains the Process (and through it this pipe) for the whole
        // grace period, which would otherwise delay the graceful exit path by 5 seconds.
        // After handleClose, so `closed` already refuses further writes, and under `lock`,
        // so it cannot land inside a concurrent send().
        lock.withLock { try? inPipe.fileHandleForWriting.close() }
    }

    /// SIGTERM now, SIGKILL after a short grace if the agent is still there. Clearing the
    /// termination handler first keeps the deliberate-stop contract (no "agent exited" error
    /// for a teardown we asked for).
    private func terminateWithEscalation(_ process: Process) {
        process.terminationHandler = nil
        process.terminate()
        guard process.isRunning else {
            return
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + 5.0) {
            // Re-check isRunning and read the pid INSIDE the closure, in that order:
            // Foundation reaps the child independently of the cleared termination handler,
            // so a pid captured earlier could name a recycled process by now. 5s (not 2s)
            // because the bundled mlx-agent may be releasing tens of GB of mapped weights on
            // the way out, and that path works today.
            if process.isRunning {
                kill(process.processIdentifier, SIGKILL)
            }
        }
    }

    // MARK: - Inbound

    /// Dispatches one inbound line: a response resumes its pending request; a method
    /// with an id is an agent->client request (answered via `onRequest` on its own
    /// task); a method without an id is a notification. Internal for tests.
    func handleLine(_ line: String) {
        guard !line.isEmpty else {
            return
        }
        guard let data = line.data(using: .utf8),
              let message = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            logger.log("ACP: dropping non-JSON line from agent: \(line.prefix(200))", .warning)
            return
        }

        if let method = message["method"] as? String {
            let params = message["params"] as? [String: Any] ?? [:]
            if let id = message["id"] {
                Task { [weak self] in
                    if let result = await self?.onRequest(method, params) {
                        self?.send(["jsonrpc": "2.0", "id": id, "result": result])
                    } else {
                        self?.send(["jsonrpc": "2.0", "id": id,
                                    "error": ["code": -32601, "message": "Method not supported by this client: \(method)"]])
                    }
                }
            } else {
                onNotification(method, params)
            }
            return
        }

        // A response: correlate by id.
        guard let id = (message["id"] as? NSNumber)?.intValue,
              let continuation = lock.withLock({ pending.removeValue(forKey: id) }) else {
            logger.log("ACP: response with no matching request; dropping", .verbose)
            return
        }
        if let error = message["error"] as? [String: Any] {
            let code = (error["code"] as? NSNumber)?.intValue
            let text = (error["message"] as? String) ?? "agent error"
            continuation.resume(throwing: ACPConnectionError(code: code, message: text))
        } else {
            continuation.resume(returning: message["result"] as? [String: Any] ?? [:])
        }
    }

    // MARK: - Outbound

    /// Serializes one JSON-RPC message onto the agent's stdin as a single line.
    /// Writes are serialized by `lock` so concurrent tasks cannot interleave lines.
    /// `.withoutEscapingSlashes`: method names like "session/new" go out literally
    /// (JSONSerialization would otherwise emit "session\\/new" - valid JSON, but
    /// needlessly unlike what every other ACP implementation puts on the wire).
    private func send(_ message: [String: Any]) {
        guard var data = try? JSONSerialization.data(withJSONObject: message, options: [.withoutEscapingSlashes]) else {
            logger.log("ACP: failed to encode outbound message", .warning)
            return
        }
        data.append(0x0A)   // newline framing
        lock.withLock {
            guard !closed else {
                return
            }
            do {
                try inPipe.fileHandleForWriting.write(contentsOf: data)
            } catch {
                logger.log("ACP: writing to agent failed: \(error)", .warning)
            }
        }
    }

    // MARK: - Teardown

    /// Marks the connection closed (once), fails all pending requests, and reports the
    /// closure so the transport can surface "agent exited" to the transcript.
    private func handleClose(exitStatus: Int32?, notify: Bool = true) {
        let (continuations, first) = lock.withLock { () -> ([CheckedContinuation<[String: Any], any Error>], Bool) in
            if closed {
                return ([], false)
            }
            closed = true
            let waiting = Array(pending.values)
            pending.removeAll()
            return (waiting, true)
        }
        guard first else {
            return
        }
        for continuation in continuations {
            continuation.resume(throwing: ACPConnectionError(code: nil, message: "agent connection closed"))
        }
        if notify {
            onClose(exitStatus)
        }
    }
}

#endif
