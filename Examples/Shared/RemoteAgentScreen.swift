// Examples/Shared/RemoteAgentScreen.swift
//
// The `acp-remote` demo screen, compiled into BOTH the macOS ChatViewDemo executable and the
// iOS demo app. One source file, two apps: a screen that drifted between platforms would stop
// being evidence that the transport behaves the same on both.
//
// It is also the reference host implementation for the cold-launch checkpoint contract
// (plan section 4.2a). That contract asks the host to persist the transcript and its resume
// cursor ATOMICALLY, and the plan's own risk list calls a non-atomic host the one failure this
// design cannot close in code - so the demo has to get it right visibly, not incidentally.

import SwiftUI
import Combine
import ChatView
import ChatViewACP

// MARK: - Settings

/// Where the bridge is and how to talk to it. Persisted in UserDefaults, WHICH IS WRONG for the
/// token in a real app - it belongs in the Keychain. The demo keeps it simple and says so
/// loudly rather than implying that plist storage for a remote-code-execution credential is
/// fine (see plan 4.6).
final class RemoteAgentSettings: ObservableObject {

    @Published var url: String {
        didSet { UserDefaults.standard.set(url, forKey: "demo.acpRemote.url") }
    }
    @Published var token: String {
        didSet { UserDefaults.standard.set(token, forKey: "demo.acpRemote.token") }
    }
    @Published var sessionMode: String {
        didSet { UserDefaults.standard.set(sessionMode, forKey: "demo.acpRemote.session") }
    }

    init() {
        let defaults = UserDefaults.standard
        // 127.0.0.1 is right for the iOS Simulator (it shares this Mac's loopback) and for the
        // macOS demo. A real device needs the Mac's LAN address - run the harness with --lan.
        url = defaults.string(forKey: "demo.acpRemote.url") ?? "ws://127.0.0.1:8737/acp"
        token = defaults.string(forKey: "demo.acpRemote.token") ?? "demo-token-please-do-not-reuse"
        sessionMode = defaults.string(forKey: "demo.acpRemote.session") ?? "latest"
    }
}

// MARK: - Persistence (the 4.2a reference behavior)

/// Accumulates finalized entries and the resume checkpoint, and writes BOTH under a single
/// file write.
///
/// The timing is the whole lesson. Entries are held in memory as they arrive and committed to
/// disk only when a checkpoint arrives - which the transport emits only at turn boundaries.
/// That makes atomicity structural rather than something the host has to remember: there is no
/// moment at which a cursor exists on disk without exactly the transcript it describes.
///
/// Entries after the last checkpoint are deliberately NOT saved. Losing them is correct: the
/// bridge still has them, and the next attach replays from the cursor and re-delivers them with
/// identical ids. Saving them without a matching cursor is the failure that silently skips
/// history on the next launch.
///
/// An ObservableObject so the screen can hold it in `@StateObject`. That is not decoration: a
/// plain `let` on the View struct is re-created on every struct init, while ChatView keeps its
/// store (and therefore the FIRST hostEvents closure) in `@StateObject` forever - so the store
/// would keep recording into an accumulator the screen had already replaced.
final class RemoteAgentPersistence: ObservableObject {

    /// One saved transcript row. The id is the ENTRY envelope's id, not something dug back out
    /// of the encoded item: only `image`, `system`, and `error` carry `id` at the top level of
    /// their JSON, so recovering a tool call's id from its payload silently fails and a re-fire
    /// of that entry appends a duplicate instead of replacing the row.
    private struct StoredItem: Codable {
        var id: String
        var json: String
    }

    private struct Snapshot: Codable {
        var sessionId: String
        var afterSeq: Int
        var items: [StoredItem]
    }

    /// Entry types that are transcript ROWS. The rest of what `ChatStore.fireEntry` emits
    /// (`plan`, `usage`, `session`, `participants`, `messageIdConfirmed`) describes surfaces or
    /// bookkeeping, not items, and putting one in a transcript would fail to decode.
    private static let itemTypes: Set<String> = [
        "message", "thought", "toolCall", "image", "system", "error",
        "memberEvent", "callEvent", "file",
    ]

    private let fileURL: URL
    private let lock = NSLock()
    private var itemsByID: [String: String] = [:]
    private var order: [String] = []
    private var loaded = false
    private var restorePayload: (content: [String: Any], sessionId: String, afterSeq: Int)?

    /// `directory` is a test seam. Application Support is not redirectable by environment, so
    /// without it every test instance would share one real file - and each other's leftovers.
    init(directory: URL? = nil) {
        let base = directory ?? (FileManager.default.urls(for: .applicationSupportDirectory,
                                                          in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory)
            .appendingPathComponent("ChatViewRemoteDemo", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        fileURL = base.appendingPathComponent("session.json")
    }

    /// Records one `.entry` host event.
    func record(entryJSON: String) {
        guard let data = entryJSON.data(using: .utf8),
              let envelope = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = envelope["type"] as? String,
              Self.itemTypes.contains(type),
              let id = envelope["id"] as? String,
              let payload = envelope["data"],
              let encoded = try? JSONSerialization.data(withJSONObject: payload),
              let text = String(data: encoded, encoding: .utf8) else {
            return
        }
        lock.withLock {
            if itemsByID[id] == nil {
                order.append(id)
            }
            // Last payload wins, position does not move: the store re-fires an entry when an
            // item changes, and a tool call's terminal status and its final output can arrive
            // as separate updates.
            itemsByID[id] = text
        }
    }

    /// Records a checkpoint and commits everything. This is the ONLY write.
    func commit(checkpointJSON: String) {
        guard let data = checkpointJSON.data(using: .utf8),
              let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let sessionId = payload["sessionId"] as? String,
              let afterSeq = payload["afterSeq"] as? Int else {
            return
        }
        let snapshot: Snapshot = lock.withLock {
            Snapshot(sessionId: sessionId, afterSeq: afterSeq,
                     items: order.compactMap { id in
                         itemsByID[id].map { StoredItem(id: id, json: $0) }
                     })
        }
        guard let encoded = try? JSONEncoder().encode(snapshot) else {
            return
        }
        // One atomic write for both halves. A crash either leaves the previous consistent pair
        // or the new one, never a cursor from one moment beside a transcript from another.
        try? encoded.write(to: fileURL, options: .atomic)
    }

    /// Reads the stored pair, ONCE, and seeds the in-memory accumulator from it.
    ///
    /// The once-ness is load-bearing and was a real bug: this used to run from a computed
    /// property, so every SwiftUI body evaluation reset the accumulator to the file's contents -
    /// discarding entries recorded since the last checkpoint, and then committing a NEW cursor
    /// beside the OLD transcript. That is precisely the cursor-ahead-of-transcript failure the
    /// design calls unfixable in code, manufactured by the reference implementation for it.
    func restoreOnce() -> (content: [String: Any], sessionId: String, afterSeq: Int)? {
        lock.lock()
        if loaded {
            defer { lock.unlock() }
            return restorePayload
        }
        loaded = true
        lock.unlock()

        guard let data = try? Data(contentsOf: fileURL),
              let snapshot = try? JSONDecoder().decode(Snapshot.self, from: data),
              !snapshot.items.isEmpty else {
            return nil
        }
        var items: [Any] = []
        lock.withLock {
            // MERGE, do not clobber. Seeding is a plain assignment only if nothing has been
            // recorded yet; anything already in memory was recorded after the file was written
            // and must survive, or the next commit writes a cursor past rows it just dropped.
            let recordedOrder = order
            let recorded = itemsByID
            order = []
            itemsByID = [:]
            for stored in snapshot.items {
                guard let itemData = stored.json.data(using: .utf8),
                      let object = try? JSONSerialization.jsonObject(with: itemData) else {
                    continue
                }
                order.append(stored.id)
                // A payload recorded in this run is NEWER than the one on disk.
                itemsByID[stored.id] = recorded[stored.id] ?? stored.json
                items.append(object)
            }
            for id in recordedOrder where itemsByID[id] == nil {
                order.append(id)
                itemsByID[id] = recorded[id]
            }
        }
        guard !items.isEmpty else {
            return nil
        }
        // "prime": "defer" - display the transcript without replaying it into the agent. The
        // agent on the bridge already has this conversation; re-priming it would duplicate the
        // context it is holding.
        let payload = (content: ["version": 1, "items": items, "prime": "defer"] as [String: Any],
                       sessionId: snapshot.sessionId, afterSeq: snapshot.afterSeq)
        lock.withLock { restorePayload = payload }
        return payload
    }

    /// Forgets the stored pair AND the in-memory accumulator. Used when the user deliberately
    /// starts a new conversation - a cursor kept across that would point into a session they
    /// just abandoned.
    func reset() {
        lock.withLock {
            itemsByID = [:]
            order = []
            restorePayload = nil
            loaded = true          // nothing left to load; do not re-read the file we deleted
        }
        try? FileManager.default.removeItem(at: fileURL)
    }
}

// MARK: - The content source

/// Hands ChatView its transport config and any restored transcript. Both channels are
/// host-injected at runtime, never declared in static UI data - the security boundary that
/// keeps a bridge token out of a document (plan 4.6).
final class RemoteAgentContentSource: ChatContentSource {
    private let config: Any
    private let content: Any?

    init(config: Any, content: Any?) {
        self.config = config
        self.content = content
    }

    func observeChatContent(_ handler: @escaping (Any?) -> Void) -> AnyCancellable {
        if let content {
            handler(content)
        }
        return AnyCancellable {}
    }

    func observeChatConfig(_ handler: @escaping (Any?) -> Void) -> AnyCancellable {
        handler(config)
        return AnyCancellable {}
    }
}

// MARK: - The screen

public struct RemoteAgentScreen: View {

    @StateObject private var settings = RemoteAgentSettings()
    // @StateObject, not a `let`: a View struct is re-initialized constantly, and ChatView holds
    // its store - and with it the FIRST hostEvents closure we hand over - for the screen's whole
    // lifetime. A re-created accumulator would leave the store recording into an orphan.
    @StateObject private var persistence = RemoteAgentPersistence()
    @State private var showingSettings = false
    /// Bumping this rebuilds the chat with a fresh transport - how the demo applies new
    /// settings or starts a new session.
    @State private var generation = 0
    @State private var resumeNotice: String?

    public init() {}

    public var body: some View {
        VStack(spacing: 0) {
            header
            if let resumeNotice {
                Text(resumeNotice)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 12)
                    .padding(.bottom, 6)
            }
            chat
                .id(generation)
        }
        .sheet(isPresented: $showingSettings) {
            settingsSheet
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Remote agent")
                    .font(.headline)
                Text(settings.url)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer()
            Button("New") {
                // A new conversation, and the stored pair goes with it - a cursor kept across a
                // deliberate reset would point into a session the user just abandoned.
                persistence.reset()
                settings.sessionMode = "new"
                resumeNotice = nil
                generation += 1
            }
            .help("Start a fresh session and forget the saved transcript")
            Button("Settings") {
                showingSettings = true
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var chat: some View {
        // restoreOnce(), never a fresh read: this is a computed property, so it runs on every
        // body evaluation - opening the settings sheet, typing a character, anything.
        let restored = persistence.restoreOnce()
        var transport: [String: Any] = [
            "url": settings.url,
            "token": settings.token,
            "session": settings.sessionMode,
        ]
        // Both halves or neither (plan 4.5). The transcript and the cursor it was minted with
        // are injected together, on the same launch, or the demo starts clean.
        if let restored, settings.sessionMode != "new" {
            transport["session"] = restored.sessionId
            transport["resumeAfterSeq"] = restored.afterSeq
        }

        let configuration = ChatConfiguration(dictionary: [
            "input": ["placeholder": "Message the remote agent", "submitOn": "modifier-return"],
            "surfaces": ["thoughts": "collapsed", "toolCalls": "visible",
                         "plan": "visible", "status": "visible"],
        ], logger: ConsoleChatLogger())
        var withEntries = configuration
        withEntries.emitsEntryEvents = true

        let source = RemoteAgentContentSource(
            config: ["protocol": "acp-remote", "transport": transport],
            content: settings.sessionMode == "new" ? nil : restored?.content)

        return ChatView(configuration: withEntries,
                        logger: ConsoleChatLogger(),
                        contentSource: source,
                        hostEvents: { event in
            switch event {
            case .entry(let json):
                persistence.record(entryJSON: json)
            case .resumeCheckpoint(let json):
                persistence.commit(checkpointJSON: json)
            default:
                break
            }
        })
        .onAppear {
            if let restored, settings.sessionMode != "new" {
                resumeNotice = "Resumed \(restored.sessionId) from seq \(restored.afterSeq) - "
                    + "only what you missed was fetched."
            }
        }
    }

    private var settingsSheet: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Bridge settings")
                .font(.headline)

            VStack(alignment: .leading, spacing: 4) {
                Text("URL").font(.caption).foregroundStyle(.secondary)
                TextField("ws://127.0.0.1:8737/acp", text: $settings.url)
                    .textFieldStyle(.roundedBorder)
#if os(iOS)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
#endif
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("Token").font(.caption).foregroundStyle(.secondary)
                SecureField("token", text: $settings.token)
                    .textFieldStyle(.roundedBorder)
#if os(iOS)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
#endif
            }

            Picker("Session", selection: $settings.sessionMode) {
                Text("Resume latest").tag("latest")
                Text("Always new").tag("new")
            }
            .pickerStyle(.segmented)

            Text("Run Scripts/run-bridge-demo.sh on the Mac to start a bridge; it prints this "
                 + "URL and token. Use --lan for a real device.\n\n"
                 + "The token authorizes tool execution on the bridge host, so cleartext ws:// "
                 + "is only acceptable on a network you trust.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                Spacer()
                Button("Apply") {
                    // Switching to "Always new" must drop the stored pair too. Leaving it would
                    // reseed the accumulator from the abandoned session, and the new session's
                    // first checkpoint would then write those old rows under the new id.
                    if settings.sessionMode == "new" {
                        persistence.reset()
                        resumeNotice = nil
                    }
                    showingSettings = false
                    generation += 1
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(minWidth: 320, idealWidth: 420)
    }
}
