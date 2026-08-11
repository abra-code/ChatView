// Examples/ChatViewDemo/ChatViewDemo.swift
//
// A standalone SwiftUI demo app for the ChatView package - the Apple twin of the Kotlin
// android/demo module. It wires the ChatView component directly (no ActionUI host) across
// four screens behind a segmented picker: People (a 1:1 local-p2p session), Group (the
// four-participant local-p2p scenario with member / call events), Agent (the scripted
// agentic demo turn over the built-in `local` transport, with the agentic multiline
// composer), and ReadOnly (a restored group transcript, history-viewer mode). People /
// Group inject a live transport via a
// content source that hands the store one operational config on subscription -
// { "protocol": "local-p2p", "transport": { "scenario": "people" | "group" } } - and opt
// the document into every v2 feature (reactions / editing / deletion / replies), which
// local-p2p backs. ReadOnly seeds transcript-v2-group.json (bundled from Fixtures) through
// the config's `content` preview seam, with no transport and no composer.
//
// Runs on macOS via `swift run ChatViewDemo`. The security boundary holds: the protocol /
// transport are host-injected here in code, never document-declared.

import SwiftUI
import Combine
import ChatView
import ChatViewACP
// The shared demo screens are a MODULE under SwiftPM and plain sources in the Xcode app target
// (Examples/ChatViewDemoMac compiles Examples/Shared directly), so the import only exists in
// the package build. Same discriminator as the resource lookup at the bottom of this file.
#if SWIFT_PACKAGE
import ChatViewDemoShared
#endif
#if canImport(AppKit)
import AppKit
#endif

@main
struct ChatViewDemo: App {
    // A SwiftPM executable is not an .app bundle, so on macOS it launches as a background accessory
    // (no Dock icon, no key window) unless it promotes itself. The delegate makes it a regular,
    // focusable foreground app so `swift run ChatViewDemo` shows a real window.
    #if canImport(AppKit)
    @NSApplicationDelegateAdaptor(DemoAppDelegate.self) private var delegate
    #endif

    init() {
        // Register the Stress screen's transport HERE, not in applicationDidFinishLaunching: SwiftUI
        // builds and first-renders the scene during launch, so the screen's onAppear - and with it the
        // store's config subscription - can run before the delegate callback. A protocol that is not
        // registered when its config arrives falls back to the built-in `local` transport, which waits
        // for a prompt: the symptom is a Stress screen that just sits there empty.
        registerStressTransport()
        // Same reasoning for `acp-remote`: the Remote screen's config arrives during the first
        // render, and an unregistered protocol silently degrades to `local`.
        ChatViewACP.register()
    }

    var body: some Scene {
        WindowGroup("ChatView Demo") {
            DemoRoot()
                .frame(minWidth: 420, minHeight: 520)
        }
    }
}

#if canImport(AppKit)
final class DemoAppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        // Synthetic reader scrolling, if asked for (see ScrollProbe.swift). Started here rather than
        // from a screen so it is independent of which transport is running.
        ScrollProbe.startIfRequested()
        // Legacy (width-taking) scrollers, if asked for: the scroller-toggle layout loop cannot occur
        // with the overlay scrollers most Macs default to (see LegacyScrollerProbe.swift).
        LegacyScrollerProbe.startIfRequested()
        // The layout repro needs a HOST-SIZED window: the guard trips on how much re-layout one
        // display cycle has to absorb, and a 420x520 window materializes a handful of transcript rows
        // where a real chat window materializes dozens. Only the stress run resizes, so the ordinary
        // demo screens keep their compact default.
        guard DemoScreen.initial == .stress, let window = NSApp.windows.first else { return }
        let width = Double(ProcessInfo.processInfo.environment["CHATVIEW_STRESS_WIDTH"] ?? "") ?? 1400
        let height = Double(ProcessInfo.processInfo.environment["CHATVIEW_STRESS_HEIGHT"] ?? "") ?? 1000
        if let screen = window.screen ?? NSScreen.main {
            let frame = screen.visibleFrame
            let size = NSSize(width: min(width, frame.width), height: min(height, frame.height))
            window.setFrame(NSRect(x: frame.midX - size.width / 2, y: frame.midY - size.height / 2,
                                   width: size.width, height: size.height), display: true)
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}
#endif

/// Registers the `stress` protocol (see StressTransport.swift). Idempotent - the registry keeps the
/// latest registration - so the Stress screen re-registers defensively on construction too, in case a
/// future entry point builds the screen without going through the App initializer.
@MainActor
func registerStressTransport() {
    ChatTransportRegistry.shared.register("stress") { config, _ in StressTransport(config: config) }
    if !ChatTransportRegistry.shared.isRegistered("stress") {
        FileHandle.standardError.write(Data("[stress] registration FAILED - the screen will fall back to `local`\n".utf8))
    }
}

private enum DemoScreen: String, CaseIterable, Identifiable {
    case people = "People"
    case group = "Group"
    case agent = "Agent"
    case remote = "Remote"
    case readOnly = "ReadOnly"
    case stress = "Stress"

    var id: String { rawValue }

    /// The screen the demo opens on. `CHATVIEW_DEMO_SCREEN=stress` starts the self-running layout
    /// stress repro straight away, so it can be driven from a script with no clicking.
    static var initial: DemoScreen {
        let requested = (ProcessInfo.processInfo.environment["CHATVIEW_DEMO_SCREEN"] ?? "").lowercased()
        return allCases.first { $0.rawValue.lowercased() == requested } ?? .people
    }
}

/// A ChatContentSource that hands the store one fixed value on each channel it holds, delivered
/// immediately on subscription (the host-injection seam). Either channel may be nil (yield nothing).
private final class FixedContentSource: ChatContentSource {
    private let config: Any?
    private let content: Any?

    init(config: Any? = nil, content: Any? = nil) {
        self.config = config
        self.content = content
    }

    func observeChatContent(_ handler: @escaping (Any?) -> Void) -> AnyCancellable {
        if let content { handler(content) }
        return AnyCancellable { }
    }

    func observeChatConfig(_ handler: @escaping (Any?) -> Void) -> AnyCancellable {
        if let config { handler(config) }
        return AnyCancellable { }
    }
}

private struct DemoRoot: View {
    @State private var screen: DemoScreen = .initial

    var body: some View {
        VStack(spacing: 0) {
            Picker("Screen", selection: $screen) {
                ForEach(DemoScreen.allCases) { screen in
                    Text(screen.rawValue).tag(screen)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(8)
            Divider()
            // Rebuild the ChatView (and its store) when the screen changes, so each demo starts a
            // fresh session and the previous transport tears down first (onDisappear -> teardown).
            Group {
                switch screen {
                case .people:   LiveScreen(scenario: "people")
                case .group:    LiveScreen(scenario: "group")
                case .agent:    AgentScreen()
                case .remote:   RemoteAgentScreen()
                case .readOnly: ReadOnlyScreen()
                case .stress:   StressScreen()
                }
            }
            .id(screen)
        }
    }
}

/// People / Group: a live local-p2p session. The document opts into every v2 feature; local-p2p backs them all.
///
/// The store holds its content source WEAKLY (it observes, never owns the host's injection seam), so the
/// demo must retain the source for the screen's lifetime - `@State` does that. A bare local `let` would
/// deallocate before `start()` subscribes on appear, and no config (hence no transport) would ever arrive.
private struct LiveScreen: View {
    private let logger = ConsoleChatLogger()
    private let config: ChatConfiguration
    @State private var source: FixedContentSource

    init(scenario: String) {
        config = ChatConfiguration(dictionary: [
            "appearance": ["alignment": "dual", "showAvatars": true],
            "features": ["reactions": true, "editing": true, "deletion": true, "replies": true],
            "input": ["placeholder": "Message"],
        ], logger: logger)
        _source = State(initialValue: FixedContentSource(config: [
            "protocol": "local-p2p",
            "transport": ["scenario": scenario],
        ]))
    }

    var body: some View {
        ChatView(configuration: config, logger: logger, contentSource: source)
    }
}

/// Agent: the scripted agentic demo turn over the built-in `local` transport - thoughts, tool-call
/// cards, a permission gate, the plan panel, and the status bar. The input uses the agentic chats'
/// composer configuration (`submitOn: modifier-return`): a growing multiline field where Return
/// inserts a newline and Cmd+Return submits, matching the ActionUIChat agent examples.
private struct AgentScreen: View {
    private let logger = ConsoleChatLogger()
    private let config: ChatConfiguration
    @State private var source: FixedContentSource

    init() {
        config = ChatConfiguration(dictionary: [
            "appearance": ["alignment": "single", "showRoleLabels": true],
            "input": ["placeholder": "Ask the agent to change something", "submitOn": "modifier-return"],
        ], logger: logger)
        _source = State(initialValue: FixedContentSource(config: [
            "protocol": "local",
            "transport": ["reply": "agentic"],
        ]))
    }

    var body: some View {
        ChatView(configuration: config, logger: logger, contentSource: source)
    }
}

/// Stress: the self-running layout repro (see StressTransport.swift). Same agentic surfaces as the
/// Agent screen, but the turns fire without a prompt and stream a long markdown answer as fast as the
/// runloop drains - the "summarize this PDF" shape that trips AppKit's layout guard. The knobs are
/// read from the environment so a run can be retuned without an edit:
/// CHATVIEW_STRESS_ROUNDS / _CHUNK_MS / _BLOCKS.
private struct StressScreen: View {
    private let logger = ConsoleChatLogger()
    private let config: ChatConfiguration
    @State private var source: FixedContentSource

    init() {
        registerStressTransport()
        config = ChatConfiguration(dictionary: [
            "appearance": ["alignment": "single", "showRoleLabels": true],
            "input": ["placeholder": "The stress turns run on their own", "submitOn": "modifier-return"],
        ], logger: logger)
        func env(_ name: String, _ fallback: Int) -> Int {
            Int(ProcessInfo.processInfo.environment[name] ?? "") ?? fallback
        }
        _source = State(initialValue: FixedContentSource(config: [
            "protocol": "stress",
            "transport": [
                "rounds": env("CHATVIEW_STRESS_ROUNDS", 6),
                "chunkMs": env("CHATVIEW_STRESS_CHUNK_MS", 0),
                "blocks": env("CHATVIEW_STRESS_BLOCKS", 24),
                "turnGapMs": env("CHATVIEW_STRESS_TURN_GAP_MS", 0),
                "toolChars": env("CHATVIEW_STRESS_TOOL_CHARS", 50_000),
            ],
        ]))
    }

    var body: some View {
        ChatView(configuration: config, logger: logger, contentSource: source)
    }
}

/// ReadOnly: a restored group transcript, shown in history-viewer mode (no transport, no composer).
/// The transcript rides on the config's `content` preview seam (the same convenience the Android demo uses).
private struct ReadOnlyScreen: View {
    private let logger = ConsoleChatLogger()

    var body: some View {
        ChatView(configuration: ChatConfiguration(dictionary: readOnlyProps(), logger: logger), logger: logger)
    }

    private func readOnlyProps() -> [String: Any] {
        var props: [String: Any] = [
            "appearance": ["alignment": "dual", "showAvatars": true],
            "readOnly": true,
        ]
        if let transcript = loadTranscriptV2Group() {
            props["content"] = transcript
        }
        return props
    }
}

/// Where the demo's bundled resources live.
///
/// `Bundle.module` is synthesized by SwiftPM and does not exist in an Xcode app target, so the
/// same sources build both ways only if the lookup is conditional. `SWIFT_PACKAGE` is defined
/// by SwiftPM and by nothing else, which makes it the right discriminator: `swift run
/// ChatViewDemo` reads from the package's resource bundle, and the .app built from
/// Examples/ChatViewDemoMac reads from its own bundle, where the json is copied.
private var demoResourceBundle: Bundle {
#if SWIFT_PACKAGE
    Bundle.module
#else
    Bundle.main
#endif
}

/// The bundled restored transcript, parsed from the demo target's resources.
private func loadTranscriptV2Group() -> [String: Any]? {
    guard let url = demoResourceBundle.url(forResource: "transcript-v2-group", withExtension: "json"),
          let data = try? Data(contentsOf: url),
          let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
        return nil
    }
    return dict
}
