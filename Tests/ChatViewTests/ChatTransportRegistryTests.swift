// Tests/ChatViewTests/ChatTransportRegistryTests.swift
//
// Unit tests for the transport registry (P0-6): a registered factory builds its own
// transport; the reserved `local` name cannot be overridden; the latest registration
// for a name wins. Viability (`makeIfViable`): an UNREGISTERED name degrades to the
// built-in `local` (a PERMANENT condition - registration happens at launch), while a
// REGISTERED factory that throws returns nil (NOT viable yet - the deferred-config
// element stays inert until a completer states["config"] arrives, rather than freezing
// on a `local` fallback). The registry is a main-actor singleton with no unregister API,
// so each test uses a protocol name unique to it to avoid cross-test pollution.

import XCTest
@testable import ChatView

private final class RegistryTestLogger: ChatLogger {
    func log(_ message: String, _ level: ChatLogLevel) {}
}

/// A stand-in transport a test factory returns, tagged so a test can prove which factory ran.
private final class FakeTransport: ChatTransport, @unchecked Sendable {
    let events: AsyncStream<ChatEvent>
    private let continuation: AsyncStream<ChatEvent>.Continuation
    let marker: String

    init(marker: String) {
        self.marker = marker
        var captured: AsyncStream<ChatEvent>.Continuation!
        self.events = AsyncStream { captured = $0 }
        self.continuation = captured
    }

    func start() async {}
    func send(_ command: ChatCommand) async {}
    func stop() async {
        continuation.finish()
    }
}

@MainActor
final class ChatTransportRegistryTests: XCTestCase {

    private func makeIfViable(_ protocolName: String, transport: [String: Any] = [:]) -> (any ChatTransport)? {
        ChatTransportRegistry.shared.makeIfViable(protocolName: protocolName, transport: transport, logger: RegistryTestLogger())
    }

    /// Unwraps a transport the test expects to be built (non-nil); fails otherwise.
    private func requireTransport(_ protocolName: String, transport: [String: Any] = [:],
                                  file: StaticString = #filePath, line: UInt = #line) -> any ChatTransport {
        guard let built = makeIfViable(protocolName, transport: transport) else {
            XCTFail("expected a viable transport for '\(protocolName)'", file: file, line: line)
            return LocalChatTransport(config: ChatTransportConfig(), logger: RegistryTestLogger())
        }
        return built
    }

    func testRegisteredFactoryBuildsItsTransport() {
        ChatTransportRegistry.shared.register("registry-test-basic") { config, _ in
            FakeTransport(marker: "basic:\(config.protocolName)")
        }
        XCTAssertEqual((requireTransport("registry-test-basic") as? FakeTransport)?.marker, "basic:registry-test-basic",
                       "the registered factory should build the transport, and see the resolved protocol name")
    }

    func testUnregisteredProtocolDegradesToLocal() {
        XCTAssertTrue(requireTransport("registry-test-unregistered-name") is LocalChatTransport,
                      "an unregistered protocol is a permanent condition and must degrade to the built-in local transport")
    }

    func testLocalIsBuiltInWithoutRegistration() {
        XCTAssertTrue(requireTransport("local") is LocalChatTransport)
    }

    func testLocalNameIsReservedAndNotOverridable() {
        ChatTransportRegistry.shared.register("local") { _, _ in FakeTransport(marker: "hijack") }
        XCTAssertTrue(requireTransport("local") is LocalChatTransport, "registering 'local' must be ignored; the built-in always wins")
    }

    func testLastRegistrationWins() {
        ChatTransportRegistry.shared.register("registry-test-override") { _, _ in FakeTransport(marker: "first") }
        ChatTransportRegistry.shared.register("registry-test-override") { _, _ in FakeTransport(marker: "second") }
        XCTAssertEqual((requireTransport("registry-test-override") as? FakeTransport)?.marker, "second")
    }

    func testEmptyNameIsIgnored() {
        ChatTransportRegistry.shared.register("") { _, _ in FakeTransport(marker: "empty") }
        XCTAssertFalse(ChatTransportRegistry.shared.isRegistered(""))
    }

    func testThrowingFactoryIsNotViable() {
        struct FactoryError: Error {}
        ChatTransportRegistry.shared.register("registry-test-throws") { _, _ in throw FactoryError() }
        XCTAssertNil(makeIfViable("registry-test-throws"),
                     "a registered factory that throws is not viable yet - makeIfViable returns nil so the element stays deferred (it does NOT degrade to local)")
    }

    func testIsRegistered() {
        XCTAssertTrue(ChatTransportRegistry.shared.isRegistered("local"), "the built-in local is always registered")
        XCTAssertFalse(ChatTransportRegistry.shared.isRegistered("registry-test-never-registered"))
        ChatTransportRegistry.shared.register("registry-test-present") { _, _ in FakeTransport(marker: "present") }
        XCTAssertTrue(ChatTransportRegistry.shared.isRegistered("registry-test-present"))
    }
}
