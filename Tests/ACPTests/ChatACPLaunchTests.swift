// Tests/ACPTests/ChatACPLaunchTests.swift
//
// Launch-path tests for the ACP transport, driven against real fake-agent subprocesses
// (shell scripts written to a temp dir, one JSON line per request - the style of
// ChatACPTests.fakeAgentScript). These pin the behaviors external agents need and the
// bundled agent must keep: the environment overlay handed to the spawned process
// (including a PATH that governs bare-name resolution), the startup watchdog and its
// absence, the stderr tail carried into a launch-failure message, SIGKILL escalation for
// an agent that traps SIGTERM, and the .sessionInfo identity event.
//
// Every drain is deadline-bounded: a regression in the startup watchdog (see the plan's
// deadlock note - a task group racing connection.request never returns) must fail these
// tests, not hang the suite.

#if os(macOS)

import XCTest
import Darwin
@testable import ChatViewACP
import ChatView

private final class LaunchTestLogger: ChatLogger {
    func log(_ message: String, _ level: ChatLogLevel) {}
}

/// A lock-guarded cell for reporting a value out of a detached task that must not be
/// awaited (a stalled blocking read cannot be cancelled, so awaiting it would hang the
/// suite rather than fail one test).
private final class LaunchTestBox<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: T?

    var value: T? {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }
}

final class ChatACPLaunchTests: XCTestCase {

    // MARK: - Fake agents

    /// The `initialize` response every fake agent below returns (client request ids are
    /// sequential from 1, so the hardcoded 1 / 2 correlate).
    private static let initializeLine =
        #"'{"jsonrpc":"2.0","id":1,"result":{"protocolVersion":1,"agentCapabilities":{},"authMethods":[]}}'"#

    private static let sessionLine =
        #"'{"jsonrpc":"2.0","id":2,"result":{"sessionId":"fake-session"}}'"#

    /// A minimal fake ACP agent. `initializeLine` / `sessionLine` are the printf ARGUMENTS
    /// (quoted by the caller, so a single-quoted literal and a double-quoted line whose
    /// `$VAR` expands at agent runtime are both expressible); `prologue` runs before the
    /// read loop. After answering session/new the agent loops back to `read` and blocks -
    /// its stdin stays open, so it only ends when the client kills it.
    private static func fakeAgent(initializeLine: String = ChatACPLaunchTests.initializeLine,
                                  sessionLine: String = ChatACPLaunchTests.sessionLine,
                                  prologue: String = "") -> String {
        """
        #!/bin/sh
        \(prologue)
        while IFS= read -r line; do
          case "$line" in
            *'"method":"initialize"'*)
              printf '%s\\n' \(initializeLine) ;;
            *'"method":"session/new"'*)
              printf '%s\\n' \(sessionLine) ;;
          esac
        done
        """
    }

    /// Writes `script` into a fresh temp directory as an executable file and returns its
    /// URL; the directory is removed at teardown. The file is chmod 0755 with a shebang, so
    /// /usr/bin/env can exec it by absolute path or by bare name found on the injected PATH.
    private func writeAgentScript(_ script: String, named name: String = "fake-acp-agent") throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("chatview-acp-launch-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent(name)
        try script.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: directory)
        }
        return url
    }

    private func makeTransport(_ settings: [String: Any]) throws -> ACPChatTransport {
        try ACPChatTransport(config: ChatTransportConfig(settings: settings), logger: LaunchTestLogger())
    }

    /// Starts the transport CONCURRENTLY with the drain, and returns the events that arrive
    /// until `isDone` matches (that event included) or `deadline` elapses.
    ///
    /// Starting concurrently is what makes the deadline load-bearing. The deadlock the plan
    /// warns about - a throwing task group racing ACPConnection.request, which ignores
    /// cancellation - hangs INSIDE start(), so `await transport.start()` before the drain
    /// would hang the whole suite no matter how the drain is bounded (SwiftPM applies no
    /// per-test timeout). The event stream is unbounded-buffered, so nothing yielded during
    /// start() is missed, and the race itself is on the stream, which is cancellation-safe.
    private func startAndDrain(_ transport: ACPChatTransport,
                               deadline: TimeInterval = 10,
                               until isDone: @escaping @Sendable (ChatEvent) -> Bool) async -> [ChatEvent] {
        let starter = Task { await transport.start() }
        let collector = Task { () -> [ChatEvent] in
            var seen: [ChatEvent] = []
            for await event in transport.events {
                seen.append(event)
                if isDone(event) {
                    break
                }
            }
            return seen
        }
        let watchdog = Task {
            try? await Task.sleep(nanoseconds: UInt64(deadline * 1_000_000_000))
            collector.cancel()
        }
        let events = await collector.value
        watchdog.cancel()
        // Deliberately NOT awaited: a healthy start() has long since returned, and a wedged
        // one must be abandoned rather than joined, or the hang comes back through this line.
        starter.cancel()
        return events
    }

    /// True when `pid` is gone as far as these tests care: no such process, or a zombie its
    /// parent has not reaped yet. `kill(pid, 0)` alone cannot tell a live process from a
    /// killed-but-unreaped one, so a bare kill check would silently be asserting "SIGKILL
    /// delivered AND Foundation reaped in time" instead of "the agent is dead".
    private static func processIsGone(_ pid: pid_t) -> Bool {
        if kill(pid, 0) != 0 {
            return true
        }
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0, size > 0 else {
            return true
        }
        return info.kp_proc.p_stat == Int8(SZOMB)
    }

    private func sessionID(in events: [ChatEvent]) -> String? {
        for event in events {
            if case .sessionReady(let sessionID, _) = event {
                return sessionID
            }
        }
        return nil
    }

    private func errorMessage(in events: [ChatEvent]) -> String? {
        for event in events {
            if case .error(let message, _) = event {
                return message
            }
        }
        return nil
    }

    /// Static so it converts to the drain's `@Sendable` predicate (an instance method
    /// reference would carry `self`, which XCTestCase is not Sendable for).
    private static func isReady(_ event: ChatEvent) -> Bool {
        if case .sessionReady = event {
            return true
        }
        if case .error = event {
            return true   // a failed launch must fail the assertion, not sit out the deadline
        }
        return false
    }

    // MARK: - Environment injection (0.1)

    func testLaunchEnvironmentReachesTheAgent() async throws {
        // The agent interpolates the injected variable into the sessionId it reports, so a
        // sessionReady of "env-marker-123" is proof the overlay reached the subprocess.
        let script = try writeAgentScript(Self.fakeAgent(
            sessionLine: #""{\"jsonrpc\":\"2.0\",\"id\":2,\"result\":{\"sessionId\":\"env-$ACP_PROBE_ENV\"}}""#))
        let transport = try makeTransport([
            "command": [script.path],
            "env": ["ACP_PROBE_ENV": "marker-123"],
        ])
        let events = await startAndDrain(transport, until: Self.isReady)
        await transport.stop()

        XCTAssertEqual(sessionID(in: events), "env-marker-123",
                       "transport.env must be merged over the agent's inherited environment")
    }

    func testAbsentEnvKeyLeavesTheInheritedEnvironmentIntact() async throws {
        // The overlay must ADD to the inherited environment, never replace it - and with no
        // env key at all the child's environment must be untouched, which is what keeps the
        // bundled agent's launch byte-for-byte what it was.
        setenv("ACP_INHERIT_PROBE", "inherited-ok", 1)
        addTeardownBlock {
            unsetenv("ACP_INHERIT_PROBE")
        }
        let script = try writeAgentScript(Self.fakeAgent(
            sessionLine: #""{\"jsonrpc\":\"2.0\",\"id\":2,\"result\":{\"sessionId\":\"env-$ACP_INHERIT_PROBE\"}}""#))
        let transport = try makeTransport(["command": [script.path]])   // no "env" key
        let events = await startAndDrain(transport, until: Self.isReady)
        await transport.stop()

        XCTAssertEqual(sessionID(in: events), "env-inherited-ok",
                       "the agent must inherit the host's environment when no overlay is configured")
    }

    func testBareCommandResolvesThroughInjectedPATH() async throws {
        // command[0] is a bare name; only the injected PATH can resolve it, because
        // /usr/bin/env itself is spawned with the merged environment.
        let script = try writeAgentScript(Self.fakeAgent())
        let directory = script.deletingLastPathComponent().path
        let transport = try makeTransport([
            "command": ["fake-acp-agent"],
            "env": ["PATH": directory + ":" + (ProcessInfo.processInfo.environment["PATH"] ?? "")],
        ])
        let events = await startAndDrain(transport, until: Self.isReady)
        await transport.stop()

        XCTAssertEqual(sessionID(in: events), "fake-session",
                       "a bare command name must resolve through the injected PATH")
    }

    // MARK: - Startup timeout (0.2)

    func testStartupTimeoutFailsTheSessionAndStopsTheAgent() async throws {
        // The agent takes the initialize request and never answers.
        let script = try writeAgentScript("""
        #!/bin/sh
        read line
        sleep 60
        """)
        let transport = try makeTransport([
            "command": [script.path],
            "startupTimeoutSeconds": 0.5,
        ])
        let events = await startAndDrain(transport, deadline: 5, until: Self.isReady)
        await transport.stop()

        guard let message = errorMessage(in: events) else {
            return XCTFail("startup timeout did not fire (no error event within the test deadline)")
        }
        XCTAssertTrue(message.contains("did not become ready within"),
                      "the error must name the timeout, not the connection it closed: \(message)")
    }

    func testNoTimeoutKeyPreservesTodayBehavior() async throws {
        // No startupTimeoutSeconds means no watchdog at all - the bundled local agent may
        // legitimately spend minutes loading a model before it answers initialize.
        let script = try writeAgentScript(Self.fakeAgent(prologue: "sleep 1"))
        let transport = try makeTransport(["command": [script.path]])
        // Pin the resolved value too: a slow agent coming up would also pass against a
        // sneaked-in default timeout, so the property the plan actually fixes ("absent means
        // NO timeout") has to be asserted directly.
        XCTAssertEqual(transport.startupTimeout, 0, "an absent startupTimeoutSeconds must arm no watchdog")
        let events = await startAndDrain(transport, until: Self.isReady)
        await transport.stop()

        XCTAssertEqual(sessionID(in: events), "fake-session",
                       "a slow but healthy agent must still come up when no timeout is configured")
    }

    func testNonPositiveTimeoutArmsNoWatchdog() async throws {
        // The host writes 0 (or a negative) to mean "no timeout" as explicitly as omitting it.
        let script = try writeAgentScript(Self.fakeAgent(prologue: "sleep 1"))
        let transport = try makeTransport(["command": [script.path], "startupTimeoutSeconds": -5])
        XCTAssertEqual(transport.startupTimeout, 0)
        let events = await startAndDrain(transport, until: Self.isReady)
        await transport.stop()

        XCTAssertEqual(sessionID(in: events), "fake-session")
    }

    func testAbsurdTimeoutIsClampedRatherThanTrapping() throws {
        // startupTimeoutSeconds is host JSON: an unclamped 1e12 traps in the UInt64 nanosecond
        // conversion and takes the host down, so a typo must degrade to a long timeout.
        let transport = try makeTransport(["command": ["/bin/sh"], "startupTimeoutSeconds": 1e12])
        XCTAssertEqual(transport.startupTimeout, 86_400)
        // Execute the conversion the clamp protects, rather than only asserting the bound.
        XCTAssertEqual(UInt64(transport.startupTimeout * 1_000_000_000), 86_400_000_000_000)

        for hostile in [Double.infinity, -Double.infinity, Double.nan, -1e12] {
            let transport = try makeTransport(["command": ["/bin/sh"], "startupTimeoutSeconds": hostile])
            XCTAssertTrue(transport.startupTimeout.isFinite, "\(hostile) must not survive as a non-finite timeout")
            XCTAssertLessThanOrEqual(transport.startupTimeout, 86_400)
            XCTAssertGreaterThanOrEqual(transport.startupTimeout, 0)
            _ = UInt64(transport.startupTimeout * 1_000_000_000)
        }
    }

    // MARK: - Stderr tail (0.3)

    func testLaunchFailureCarriesTheStderrTail() async throws {
        let script = try writeAgentScript("""
        #!/bin/sh
        echo "FATAL: credential store locked" 1>&2
        exit 3
        """)
        let transport = try makeTransport(["command": [script.path]])
        let events = await startAndDrain(transport, until: Self.isReady)
        await transport.stop()

        guard let message = errorMessage(in: events) else {
            return XCTFail("expected a launch failure, got: \(events)")
        }
        XCTAssertTrue(message.contains("FATAL: credential store locked"),
                      "the agent's own stderr is the actionable diagnosis: \(message)")
    }

    func testMissingAgentBinaryIsDiagnosedFromStderr() async throws {
        // The flagship case: the agent is not installed, so /usr/bin/env fails the exec and
        // writes its own message to stderr microseconds before exiting. That exec-failure /
        // exit pair is the tightest version of the stderr-vs-EOF race, which is why the
        // transport drains stderr explicitly before composing the error.
        let transport = try makeTransport(["command": ["chatview-not-installed-\(UUID().uuidString)"]])
        let events = await startAndDrain(transport, until: Self.isReady)
        await transport.stop()

        guard let message = errorMessage(in: events) else {
            return XCTFail("expected a launch failure, got: \(events)")
        }
        XCTAssertTrue(message.contains("No such file or directory"),
                      "a missing agent must be diagnosable from the message alone: \(message)")
    }

    func testDrainStderrPicksUpWhatTheHandlerNeverSaw() async throws {
        // Pins drainStderr's own read path, which the two tests above cannot: they pass
        // whichever reader got there first. Here the handler is removed before the agent
        // writes anything, so the drain is the ONLY way the line can reach the tail.
        let connection = ACPConnection(logger: LaunchTestLogger(), onNotification: { _, _ in },
                                       onRequest: { _, _ in nil }, onClose: { _ in })
        try connection.launch(command: ["/bin/sh", "-c", "sleep 0.3; echo 'FATAL: late line' 1>&2; sleep 60"],
                              cwd: nil)
        defer { connection.stop() }
        connection.drainStderr()   // nothing written yet; this also removes the handler for good
        XCTAssertEqual(connection.stderrTailText(), "", "nothing has been written yet")

        try await Task.sleep(nanoseconds: 900_000_000)
        XCTAssertEqual(connection.stderrTailText(), "", "with the handler gone, only a drain can publish")
        connection.drainStderr()
        XCTAssertTrue(connection.stderrTailText().contains("FATAL: late line"),
                      "drainStderr must pick up stderr the handler never delivered")
    }

    func testUnlaunchableAgentReportsAnErrorInsteadOfHanging() async throws {
        // A cwd that does not exist makes Process.run() throw, so the connection never starts
        // reading. The failure path still drains stderr, which must not block on a pipe whose
        // write end this process holds - it did, until the fd was made non-blocking at
        // construction rather than at startReading(). A hang here is the whole point of the
        // deadline: it shows up as "no error event", not as a stuck suite.
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("chatview-acp-missing-\(UUID().uuidString)").path
        let transport = try makeTransport(["command": ["/bin/sh"], "cwd": missing])
        let events = await startAndDrain(transport, deadline: 5, until: Self.isReady)
        await transport.stop()

        guard let message = errorMessage(in: events) else {
            return XCTFail("an unlaunchable agent must report an error, not hang: \(events)")
        }
        XCTAssertTrue(message.contains("failed to start"), message)
    }

    func testStopBeforeLaunchRefusesToSpawnTheAgent() throws {
        // stop() is a latch, so one that fires before there is a process disarms every later
        // call. Launching across that window would leave an agent with nothing left to kill
        // it, so launch() refuses instead.
        let connection = ACPConnection(logger: LaunchTestLogger(), onNotification: { _, _ in },
                                       onRequest: { _, _ in nil }, onClose: { _ in })
        connection.stop()
        XCTAssertThrowsError(try connection.launch(command: ["/bin/sh", "-c", "sleep 60"], cwd: nil),
                             "a stopped connection must not spawn an agent")
        XCTAssertNil(connection.processID, "no process may be registered after a refused launch")
    }

    func testFloodingStderrDoesNotStallTheDrain() async throws {
        // An agent that writes stderr as fast as it is read must not be able to hold the
        // stderr lock indefinitely: drainStderr and stderrTailText are called synchronously
        // from the failure path, so an unbounded read loop there stalls the error report and
        // grows without limit. Each read pass is budgeted instead; the level-triggered source
        // picks up the rest.
        let connection = ACPConnection(logger: LaunchTestLogger(), onNotification: { _, _ in },
                                       onRequest: { _, _ in nil }, onClose: { _ in })
        // `yes` and not a shell `echo` loop: echo writes ~17 bytes per iteration, which an
        // 8 KB read outruns, so even an unbounded loop reaches EAGAIN at once and the test
        // would pass against the very bug it guards. `yes` writes in large buffered blocks
        // and keeps the pipe full.
        try connection.launch(command: ["/bin/sh", "-c", "yes flooding-stderr-line 1>&2"], cwd: nil)
        defer { connection.stop() }
        try await Task.sleep(nanoseconds: 300_000_000)

        // The work runs on its own thread and reports through a box rather than being awaited:
        // a stalled read cannot be cancelled, so awaiting it would hang the suite instead of
        // failing this test.
        let reported = LaunchTestBox<(tailLength: Int, seconds: Double)>()
        Task.detached {
            let started = Date()
            connection.drainStderr()
            let length = connection.stderrTailText().count
            reported.value = (length, Date().timeIntervalSince(started))
        }
        var outcome: (tailLength: Int, seconds: Double)?
        for _ in 0..<50 where outcome == nil {
            try await Task.sleep(nanoseconds: 100_000_000)
            outcome = reported.value
        }
        guard let outcome else {
            return XCTFail("drainStderr / stderrTailText did not return within 5s: the stderr read loop is unbounded")
        }
        XCTAssertLessThan(outcome.seconds, 2.0,
                          "a budgeted read pass returns in milliseconds; \(outcome.seconds)s means it drained to EAGAIN")
        XCTAssertGreaterThan(outcome.tailLength, 0, "the flood must actually reach the tail")
    }

    // MARK: - SIGKILL escalation (0.4)

    func testStopEscalatesToSigkillForATermTrappingAgent() async throws {
        // The agent answers the handshake, then leaves the read loop and parks, ignoring
        // SIGTERM. Neither of stop()'s gentler exits can end it: it never reads stdin again,
        // so the stdin EOF stop() produces is invisible, and TERM is trapped. Only the
        // SIGKILL escalation can. (Parking inside the read loop instead would let the EOF
        // take the credit and the test would pass without exercising the escalation at all -
        // it did exactly that until the stdin close was added.)
        let script = try writeAgentScript("""
        #!/bin/sh
        trap "" TERM
        while IFS= read -r line; do
          case "$line" in
            *'"method":"initialize"'*)
              printf '%s\\n' \(Self.initializeLine) ;;
            *'"method":"session/new"'*)
              printf '%s\\n' \(Self.sessionLine)
              break ;;
          esac
        done
        while :; do
          sleep 1
        done
        """)
        let transport = try makeTransport(["command": [script.path]])
        let events = await startAndDrain(transport, until: Self.isReady)
        XCTAssertEqual(sessionID(in: events), "fake-session")

        guard let pid = transport.agentProcessID else {
            return XCTFail("no agent pid after sessionReady")
        }
        XCTAssertFalse(Self.processIsGone(pid), "the fake agent should still be running before stop()")

        await transport.stop()
        // stop() TERMs (ignored here) and escalates after a 5s grace; allow a margin. The
        // transport is kept alive across the poll on purpose: the escalation closure is what
        // holds the Process (and its stdin pipe), so releasing the transport early would let
        // a plain stdin-EOF exit take the credit for this kill.
        var gone = false
        for _ in 0..<80 where !gone {
            try await Task.sleep(nanoseconds: 100_000_000)
            gone = Self.processIsGone(pid)
        }
        withExtendedLifetime(transport) {}
        XCTAssertTrue(gone, "an agent that traps SIGTERM must still be killed by stop()")
    }

    func testStopClosesTheAgentsStdinSoTheGracefulExitStillWorks() async throws {
        // The inverse of the test above, and the reason stop() closes its end of the agent's
        // stdin explicitly: the escalation closure retains the Process (and with it the pipe)
        // for the whole 5s grace, so without the close a well-behaved agent's stdin-EOF exit
        // would be delayed by 5 seconds on every teardown. This agent traps SIGTERM but still
        // reads stdin, so only the EOF can end it - and it must, well inside the grace.
        let script = try writeAgentScript(Self.fakeAgent(prologue: #"trap "" TERM"#))
        let transport = try makeTransport(["command": [script.path]])
        let events = await startAndDrain(transport, until: Self.isReady)
        XCTAssertEqual(sessionID(in: events), "fake-session")
        guard let pid = transport.agentProcessID else {
            return XCTFail("no agent pid after sessionReady")
        }

        await transport.stop()
        var gone = false
        for _ in 0..<30 where !gone {
            try await Task.sleep(nanoseconds: 100_000_000)
            gone = Self.processIsGone(pid)
        }
        withExtendedLifetime(transport) {}
        XCTAssertTrue(gone, "the agent must see stdin EOF and exit well before the SIGKILL grace")
    }

    // MARK: - Session identity (0.5)

    func testSessionInfoCarriesAgentIdentityAndPid() async throws {
        let script = try writeAgentScript(Self.fakeAgent(
            initializeLine: #"'{"jsonrpc":"2.0","id":1,"result":{"protocolVersion":1,"agentInfo":{"name":"FakeAgent","version":"9.9"},"agentCapabilities":{"loadSession":true}}}'"#,
            sessionLine: #"'{"jsonrpc":"2.0","id":2,"result":{"sessionId":"info-session"}}'"#))
        let transport = try makeTransport(["command": [script.path]])
        let events = await startAndDrain(transport, until: { event in
            if case .sessionInfo = event {
                return true
            }
            if case .error = event {
                return true
            }
            return false
        })
        let livePID = transport.agentProcessID   // read before stop(), while it is unambiguously live
        await transport.stop()

        let kinds = events.map { event -> String in
            switch event {
            case .sessionReady: return "ready"
            case .sessionInfo: return "info"
            case .error(let message, _): return "error:\(message)"
            default: return "other"
            }
        }
        XCTAssertEqual(kinds, ["ready", "info"], "sessionInfo follows sessionReady, once")

        var info: AgentSessionInfo?
        for event in events {
            if case .sessionInfo(let payload) = event {
                info = payload
            }
        }
        guard let info else {
            return XCTFail("no sessionInfo event")
        }
        XCTAssertEqual(info.sessionId, "info-session")
        XCTAssertEqual(info.agentName, "FakeAgent")
        XCTAssertEqual(info.agentVersion, "9.9")
        XCTAssertEqual(info.protocolVersion, 1)
        XCTAssertTrue(info.canLoadSession, "agentCapabilities.loadSession must surface")
        XCTAssertFalse(info.canPrime, "sessionPrime was not advertised")
        XCTAssertFalse(info.resumed, "session/new is not a resume")
        XCTAssertNotNil(info.agentPid)
        XCTAssertEqual(info.agentPid.map(Int32.init), livePID,
                       "the reported pid is the spawned subprocess")
    }
}

#endif
