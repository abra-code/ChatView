// Examples/ChatViewDemo/ChatViewDemo.swift
//
// A standalone SwiftUI demo app for the ChatView package - the Apple twin of the Kotlin
// android/demo module. It wires the ChatView component directly (no ActionUI host) across
// three screens behind a segmented picker: People (a 1:1 local-p2p session), Group (the
// four-participant local-p2p scenario with member / call events), and ReadOnly (a restored
// group transcript, history-viewer mode). People / Group inject a live transport via a
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
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}
#endif

private enum DemoScreen: String, CaseIterable, Identifiable {
    case people = "People"
    case group = "Group"
    case readOnly = "ReadOnly"

    var id: String { rawValue }
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
    @State private var screen: DemoScreen = .people

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
                case .readOnly: ReadOnlyScreen()
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

/// The bundled restored transcript, parsed from the demo target's resources.
private func loadTranscriptV2Group() -> [String: Any]? {
    guard let url = Bundle.module.url(forResource: "transcript-v2-group", withExtension: "json"),
          let data = try? Data(contentsOf: url),
          let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
        return nil
    }
    return dict
}
