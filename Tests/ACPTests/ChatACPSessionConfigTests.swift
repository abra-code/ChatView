// Tests/ACPTests/ChatACPSessionConfigTests.swift
//
// transport.sessionConfig: options the host asks a new session to start with (an agent
// in a box starts in the permission mode the user chose). Driven against a fake-agent
// subprocess that answers the setter in one of several ways and logs every method it
// receives, so the tests can pin both what went out on the wire and what the session
// reported. The rule under test: the session starts in the requested state or does not
// start at all.

#if os(macOS)

import XCTest
@testable import ChatViewACP
import ChatView

private final class SessionConfigTestLogger: ChatLogger {
    func log(_ message: String, _ level: ChatLogLevel) {}
}

final class ChatACPSessionConfigTests: XCTestCase {

    /// The fake agent. $1 picks how it answers session/set_config_option:
    ///   ok        - the refreshed list with the requested mode current
    ///   mismatch  - the refreshed list with the mode unchanged ("build")
    ///   empty     - success with no option list
    ///   error     - a JSON-RPC error
    ///   absent    - method not found (-32601); session/set_mode then succeeds
    ///   absent-no - method not found, and session/set_mode fails too
    /// $2 is a file that receives each request's method, one per line. session/new offers a
    /// mode option (build, plan) both as configOptions and as the spec's `modes`, and
    /// advertises an auth method, so a refusal can be checked for a misleading login hint.
    private static let fakeAgentScript = #"""
    #!/bin/sh
    behavior="$1"
    log="$2"
    while IFS= read -r line; do
      id=$(printf '%s' "$line" | /usr/bin/sed -n 's/.*"id":\([0-9]*\).*/\1/p')
      method=$(printf '%s' "$line" | /usr/bin/sed -n 's/.*"method":"\([^"]*\)".*/\1/p')
      printf '%s\n' "$method" >> "$log"
      opts='[{"id":"mode","name":"Mode","category":"mode","type":"select","currentValue":"CURRENT","options":[{"value":"build","name":"Build"},{"value":"plan","name":"Plan"}]}]'
      case "$method" in
        initialize)
          printf '%s\n' '{"jsonrpc":"2.0","id":'"$id"',"result":{"protocolVersion":1,"agentCapabilities":{},"authMethods":[{"id":"fake-login","name":"Fake login"}]}}' ;;
        session/new)
          printf '%s\n' '{"jsonrpc":"2.0","id":'"$id"',"result":{"sessionId":"s1","modes":{"currentModeId":"build","availableModes":[{"id":"build","name":"Build"},{"id":"plan","name":"Plan"}]},"configOptions":'"$(printf '%s' "$opts" | /usr/bin/sed 's/CURRENT/build/')"'}}' ;;
        session/set_config_option)
          case "$behavior" in
            ok)
              value=$(printf '%s' "$line" | /usr/bin/sed -n 's/.*"value":"\([^"]*\)".*/\1/p')
              printf '%s\n' '{"jsonrpc":"2.0","id":'"$id"',"result":{"configOptions":'"$(printf '%s' "$opts" | /usr/bin/sed "s/CURRENT/$value/")"'}}' ;;
            mismatch)
              printf '%s\n' '{"jsonrpc":"2.0","id":'"$id"',"result":{"configOptions":'"$(printf '%s' "$opts" | /usr/bin/sed 's/CURRENT/build/')"'}}' ;;
            empty)
              printf '%s\n' '{"jsonrpc":"2.0","id":'"$id"',"result":{}}' ;;
            error)
              printf '%s\n' '{"jsonrpc":"2.0","id":'"$id"',"error":{"code":-32602,"message":"Invalid params"}}' ;;
            *)
              printf '%s\n' '{"jsonrpc":"2.0","id":'"$id"',"error":{"code":-32601,"message":"Method not found"}}' ;;
          esac ;;
        session/set_mode)
          if [ "$behavior" = "absent-no" ]; then
            printf '%s\n' '{"jsonrpc":"2.0","id":'"$id"',"error":{"code":-32603,"message":"mode change refused"}}'
          else
            printf '%s\n' '{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"s1","update":{"sessionUpdate":"current_mode_update","currentModeId":"plan"}}}'
            printf '%s\n' '{"jsonrpc":"2.0","id":'"$id"',"result":{}}'
          fi ;;
      esac
    done
    """#

    private var logURL: URL!

    /// Writes the fake agent and a fresh method log into a temp directory removed at
    /// teardown, and returns the transport settings that launch it with `behavior`.
    private func settings(behavior: String, sessionConfig: Any?) throws -> [String: Any] {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("chatview-acp-sessionconfig-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: directory)
        }
        let script = directory.appendingPathComponent("fake-agent.sh")
        try Self.fakeAgentScript.write(to: script, atomically: true, encoding: .utf8)
        logURL = directory.appendingPathComponent("methods.log")
        var settings: [String: Any] = ["command": ["/bin/sh", script.path, behavior, logURL.path], "cwd": directory.path]
        if let sessionConfig {
            settings["sessionConfig"] = sessionConfig
        }
        return settings
    }

    private func methods() -> [String] {
        let text = (try? String(contentsOf: logURL, encoding: .utf8)) ?? ""
        return text.split(separator: "\n").map(String.init)
    }

    /// Starts the transport concurrently with a drain that stops at sessionReady or an
    /// error, bounded by a deadline so a regression fails rather than hangs the suite
    /// (the pattern of ChatACPLaunchTests.startAndDrain).
    private func startAndDrain(_ transport: ACPChatTransport) async -> [ChatEvent] {
        let starter = Task { await transport.start() }
        let collector = Task { () -> [ChatEvent] in
            var seen: [ChatEvent] = []
            for await event in transport.events {
                seen.append(event)
                if case .sessionReady = event { break }
                if case .error = event { break }
            }
            return seen
        }
        let watchdog = Task {
            try? await Task.sleep(nanoseconds: 10_000_000_000)
            collector.cancel()
        }
        let events = await collector.value
        watchdog.cancel()
        starter.cancel()
        await transport.stop()
        return events
    }

    private func run(behavior: String, sessionConfig: Any?) async throws -> (mode: String?, error: String?) {
        let transport = try ACPChatTransport(
            config: ChatTransportConfig(settings: settings(behavior: behavior, sessionConfig: sessionConfig)),
            logger: SessionConfigTestLogger())
        var mode: String?
        var error: String?
        for event in await startAndDrain(transport) {
            if case .sessionReady(_, let options) = event {
                mode = options.first(where: { $0.id == "mode" })?.currentValue
            }
            if case .error(let message, _) = event {
                error = message
            }
        }
        return (mode, error)
    }

    // MARK: - Applied

    func testTheSessionStartsInTheRequestedMode() async throws {
        let result = try await run(behavior: "ok", sessionConfig: ["mode": "plan"])
        XCTAssertNil(result.error)
        XCTAssertEqual(result.mode, "plan", "sessionReady must carry the mode the session actually starts in")
        XCTAssertEqual(methods(), ["initialize", "session/new", "session/set_config_option"])
    }

    func testNoSessionConfigSendsNoSetter() async throws {
        let result = try await run(behavior: "ok", sessionConfig: nil)
        XCTAssertNil(result.error)
        XCTAssertEqual(result.mode, "build")
        XCTAssertEqual(methods(), ["initialize", "session/new"])
    }

    func testTheFallbackSetterIsUsedAndRecorded() async throws {
        // The agent's current_mode_update arrives before sessionReady, which replaces the
        // option list; the list sessionReady carries must already say "plan".
        let result = try await run(behavior: "absent", sessionConfig: ["mode": "plan"])
        XCTAssertNil(result.error)
        XCTAssertEqual(result.mode, "plan")
        XCTAssertEqual(methods(), ["initialize", "session/new", "session/set_config_option", "session/set_mode"])
    }

    // MARK: - Refused: no session

    func testAValueTheAgentDoesNotOfferFailsTheStart() async throws {
        let result = try await run(behavior: "ok", sessionConfig: ["mode": "yolo"])
        XCTAssertNil(result.mode, "no session may be published")
        XCTAssertTrue(result.error?.contains("does not offer") == true, result.error ?? "no error")
        XCTAssertTrue(result.error?.contains("build, plan") == true, "the refusal names what the agent offers")
        XCTAssertFalse(methods().contains("session/set_config_option"), "nothing is sent for a value the agent did not offer")
    }

    func testARefusedSetterFailsTheStartWithoutALoginHint() async throws {
        let result = try await run(behavior: "error", sessionConfig: ["mode": "plan"])
        XCTAssertNil(result.mode)
        XCTAssertTrue(result.error?.contains("could not set mode to 'plan'") == true, result.error ?? "no error")
        XCTAssertFalse(result.error?.contains("login") == true, "a refused option is not a login problem")
    }

    func testASetterReportingAnotherValueFailsTheStart() async throws {
        let result = try await run(behavior: "mismatch", sessionConfig: ["mode": "plan"])
        XCTAssertNil(result.mode)
        XCTAssertTrue(result.error?.contains("the agent reports 'build'") == true, result.error ?? "no error")
    }

    func testASetterAnsweringWithNoListIsTakenAsConfirmed() async throws {
        // The success is the agent's answer, as for the fallback setter; the published list
        // must say "plan", not the value session/new offered.
        let result = try await run(behavior: "empty", sessionConfig: ["mode": "plan"])
        XCTAssertNil(result.error)
        XCTAssertEqual(result.mode, "plan")
    }

    func testAFailedFallbackFailsTheStart() async throws {
        let result = try await run(behavior: "absent-no", sessionConfig: ["mode": "plan"])
        XCTAssertNil(result.mode)
        XCTAssertTrue(result.error?.contains("mode change refused") == true, result.error ?? "no error")
    }

    func testAnOptionWithNoSetterFailsTheStart() async throws {
        // Not offered by the agent and not a category with a spec fallback.
        let result = try await run(behavior: "absent", sessionConfig: ["thinking": "high"])
        XCTAssertNil(result.mode)
        XCTAssertTrue(result.error?.contains("offers no way to set thinking") == true, result.error ?? "no error")
    }

    func testAMalformedSessionConfigIsRefusedAtInit() throws {
        XCTAssertNoThrow(try ACPChatTransport(
            config: ChatTransportConfig(settings: ["command": ["/bin/true"], "sessionConfig": NSNull()]),
            logger: SessionConfigTestLogger()), "a JSON null means absent")
        let malformed: [Any] = [["mode": 1], "plan", ["mode", "plan"]]
        for bad in malformed {
            XCTAssertThrowsError(try ACPChatTransport(
                config: ChatTransportConfig(settings: ["command": ["/bin/true"], "sessionConfig": bad]),
                logger: SessionConfigTestLogger()), "\(bad)")
        }
    }
}

#endif
