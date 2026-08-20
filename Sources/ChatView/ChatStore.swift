// Sources/ChatView/ChatStore.swift
//
// The @MainActor source of truth for one `Chat` element, and the router that
// pre-filters the transport's event stream.
//
// ChatStore owns the render model (the transcript `items`, the streaming flag, and
// the pending-permission queue), builds the transport from the config, drains its
// `ChatEvent` stream, and reduces each event into a store mutation (`route(_:)`).
// `route` is the PRE-FILTER the design centers on: chat text lands in the
// transcript; thoughts and tool-call cards are transcript items whose presentation
// (and whether they appear at all) is driven by the `surfaces` config; permission
// requests queue for the approval card and are answered back through the transport.
// A non-agentic transport that never emits those events renders a plain
// conversation with no special cases. Outbound, it appends the user's message
// optimistically, emits the host-facing ChatHostEvents, and hands a normalized
// `ChatCommand` to the transport.

import Foundation
import SwiftUI
import Combine

/// The component's content channel. In an ActionUI host this is `states["content"]`, the same
/// place Table / List keep their content: a host RESTORES a saved session by injecting a
/// serialized transcript there at runtime, AFTER the interface is built; the store observes it
/// and loads. This is one-way (restore-in only): the store never writes it back - persistence
/// flows the other way, per finalized entry, through the host event sink's `.entry` event.
/// A protocol (rather than a concrete host type) so any host can provide the channels and the
/// restore path is testable with a fake.
@MainActor
public protocol ChatContentSource: AnyObject {
    /// Observes the session-content channel; the handler is called with the current value on
    /// subscription and on every subsequent change (matching @Published semantics). Cancel to stop.
    func observeChatContent(_ handler: @escaping (Any?) -> Void) -> AnyCancellable
    /// Observes the operational-config channel - the host-injected config (protocol + transport) -
    /// with the same current-value-on-subscription-and-on-change semantics. Cancel to stop.
    func observeChatConfig(_ handler: @escaping (Any?) -> Void) -> AnyCancellable
    /// Observes the single-item append channel: one `ChatItem` JSON at a time, added to the END of
    /// the live transcript without replacing it.
    ///
    /// This exists because the content channel is all-or-nothing. Restoring through it replaces
    /// `items` wholesale and re-primes the agent, so a host that wants to add ONE line to a
    /// conversation already on screen - a session marker saying which model is about to answer -
    /// had to choose between not showing it until the next load and re-priming the whole
    /// conversation to show it.
    ///
    /// LIKE THE CONTENT CHANNEL, THIS DOES NOT FIRE AN ENTRY. Both are the host saying "here is
    /// something you already have"; persistence flows the other way, and a host that appends an
    /// item it just wrote to its own store would otherwise get it back and write it twice.
    ///
    /// Defaulted to a channel that never delivers, so existing hosts compile unchanged.
    func observeChatAppend(_ handler: @escaping (Any?) -> Void) -> AnyCancellable
}

public extension ChatContentSource {
    func observeChatAppend(_ handler: @escaping (Any?) -> Void) -> AnyCancellable {
        AnyCancellable {}
    }
}

/// The transient restore directive riding on injected content JSON (the `"prime"` key):
/// how a restored transcript relates to the agent's conversational context.
enum ChatPrimeDirective: Equatable {
    case resume     // "prime": true / absent - replay the transcript into the agent NOW
    case fresh      // "prime": false - display the transcript, seed an EMPTY context NOW
    case deferred   // "prime": "defer" - display only; sync the context lazily on the next send
}

/// Whether the agent's conversational context matches the displayed transcript - the state
/// behind the status bar's context indicator (an online/offline-style cue) and the deferred
/// prime decision at send time. Optimistic by construction: a transport that cannot prime
/// (no capability) logs a warning instead of failing, so the indicator reflects intent.
enum ChatContextState: Equatable {
    case synced    // the agent remembers the conversation shown
    case pending   // the conversation shown reaches the agent with the next message
    case fresh     // intentionally empty context behind a displayed transcript ("prime": false)
}

@MainActor
final class ChatStore: ObservableObject {

    @Published private(set) var items: [ChatItem] = []
    @Published private(set) var transcriptGeneration = 0   // bumped when the transcript is replaced wholesale (a conversation loaded in place), so the view can reset scroll/pin state for the new conversation
    @Published private(set) var isStreaming = false       // a reply turn is in flight
    @Published private(set) var awaitingReply = false      // a prompt was submitted but no reply event has arrived yet - the "connecting / thinking" gap before the first token. The view shows a spinner while awaitingReply && !isStreaming (isStreaming only flips true on the first streamed event, not at submit).
    @Published private(set) var isConfigured = false      // a viable transport has been built from states["config"]; the composer gates on this
    @Published private(set) var pendingPermissions: [PermissionRequest] = []   // FIFO; the card shows the head
    @Published private(set) var plan: [PlanEntry] = []    // the agent's current plan (whole-list replace)
    @Published private(set) var usage: UsageInfo?         // latest token/cost status, when the agent reports it
    @Published private(set) var configOptions: [SessionConfigOption] = []   // model/mode/... advertised at session start
    @Published private(set) var sessionInfo: AgentSessionInfo?              // identity/capabilities of the live agent session (nil until one is established)
    @Published private(set) var availableCommands: [SlashCommand] = []      // the agent's slash commands (composer menu)
    @Published private(set) var contextState: ChatContextState = .synced    // does the agent context match the display (status-bar indicator)
    @Published var draft: String = ""                     // composer text

    // Person-to-person (v2) surfaces the view observes.
    @Published private(set) var participants: [Participant] = []             // group roster (sender-name / avatar resolution)
    @Published private(set) var typingParticipants: [TypingParticipant] = [] // who is currently typing (drives the typing row)
    @Published private(set) var hasEarlier: Bool = true                      // false once a history page reports no more
    @Published private(set) var isLoadingEarlier: Bool = false               // a history page is in flight
    @Published private(set) var connectionState: ChatConnectionState = .connecting  // link state; only a reportsConnectionState transport drives it (else the composer ignores it)

    /// A participant currently shown in the typing indicator. `id` is the sender key (senderID, or a
    /// stable fallback for a rosterless 1:1 chat); `name` labels the row when known.
    struct TypingParticipant: Identifiable, Equatable {
        let id: String
        let name: String?
    }

    private(set) var title: String?                       // app-owned session label, passed through the transcript

    let config: ChatConfiguration
    let logger: any ChatLogger

    // The host's event sink: outbound host-facing notifications (send / stop / attach /
    // messageFinalized / error / toolApprovalRequested / entry). Nil when the host does
    // not observe them. In the ActionUI add-on the sink maps each event to its configured
    // action ID and dispatches through ActionUIModel.actionHandler.
    private let hostEvents: ChatHostEventSink?

    private var transport: (any ChatTransport)?
    private var eventTask: Task<Void, Never>?
    private var localCounter = 0
    private var didLoadInitial = false

    // Config-injection seam (states["config"]). The operational config (protocol + transport) is NOT
    // document-declared: the store observes states["config"] and builds the transport once it first
    // resolves to a VIABLE config. `resolvedTransportConfig` holds the applied decision: an IDENTICAL
    // later injection is ignored (the observation re-delivers on every states change), a DIFFERENT
    // viable one re-configures in place (tear down + attach; the wire history re-primes from the
    // loaded items). On reappearance the torn-down transport is rebuilt from the applied decision
    // (not from a possibly-changed state).
    private var didConfigure = false
    private var resolvedTransportConfig: ChatTransportConfig?
    private var configCancellable: AnyCancellable?

    // Coalescing: streaming deltas accumulate per item here and are flushed to the published
    // transcript at most ~20 Hz, so the Markdown re-parse runs on a fixed cadence instead of once
    // per token (however fast the transport streams).
    private var streamBuffers: [String: String] = [:]
    private var flushPending = false

    // Session transcript seam (P0-2). A saved session RESTORES through the content source's
    // content channel at runtime (in an ActionUI host: states["content"] via setElementState /
    // setElementStateFromString), observed here. `lastLoadedContent` dedups so a given content
    // value loads once. Persistence flows the other way, per finalized entry, through the host
    // event sink's `.entry` event - the store never writes the content channel back.
    private weak var contentSource: (any ChatContentSource)?
    private var lastLoadedContent: ChatTranscript?
    private var contentCancellable: AnyCancellable?
    private var appendCancellable: AnyCancellable?
    // The ids appended through the append channel, so the subscription's immediate delivery of a
    // value already applied (a reappearance re-subscribes) does not double it.
    private var appendedItemIDs: Set<String> = []
    // The last value each channel rejected, so a re-delivered bad value warns once rather than
    // once per unrelated state change.
    private var lastRejectedAppend: String?
    private var lastRejectedContent: String?
    private var entrySequence = 0
    // Transient restore directive riding on the injected content JSON (not part of the
    // ChatTranscript persistence codec): "prime": false displays the transcript but seeds the
    // transport with an EMPTY wire history (fresh context); "prime": "defer" displays the
    // transcript WITHOUT touching the agent and syncs the context lazily when the user next
    // sends (the seamless-browsing restore); absent/true keeps the documented contract -
    // context follows display, immediately. Remembered so a transport rebuilt on reappearance
    // or re-configure (attach) re-applies the user's last choice, and so a re-inject that only
    // flips the flag is not swallowed by the lastLoadedContent dedup.
    private var lastPrimeDirective: ChatPrimeDirective = .resume
    // The condense request that rode in with the current content, replayed on every prime this
    // restore causes - including the DEFERRED one, which happens at send time, long after the
    // injection that asked for it.
    private var lastCondenseRequest: PrimeCondense?

    // Context-identity tracking behind `contextState` (published above with the other view
    // surfaces) and the deferred prime. `wireContext` mirrors what the agent's context is
    // believed to hold, as (speaker, text) pairs under the same filter primeHistory targets;
    // nil = unknown (a cancelled / errored turn left a partial exchange agent-side), which
    // forces a re-prime on the next send. Updated only at discrete events (prime, turn end,
    // restore) - never during streaming.
    private var wireContext: [WireEntry]? = []
    // The condense request the agent's CURRENT context was built with, tracked alongside the
    // messages for the same reason: "is the agent's context what the display asks for" is not
    // answered by the messages alone once a restore can ask for them to be summarized.
    private var wireCondense: PrimeCondense?

    // A restore that arrived while a turn was in flight supersedes that turn: the restore
    // path already set the truthful context state (and the transport chains any prime behind
    // the cancelled prompt's resolution), so the superseded turn's terminal messageEnd -
    // which is always the NEXT terminal on the ordered event stream - must not re-run the
    // turn-end bookkeeping (it would nil the snapshot and downgrade a correct .synced,
    // costing a wasted duplicate prime on the next send). Swallow-once; reset on attach
    // (a new transport is a new event stream, so a stale flag must not swallow a real end).
    private var supersededTurnPending = false

    /// One (speaker, text) pair of the agent-visible conversation - the equality unit for
    /// "does the agent's context match the display".
    private struct WireEntry: Equatable {
        let local: Bool
        let text: String
    }

    /// The agent-visible pairs of a transcript: message items with a conversational role and
    /// non-empty text (the same filter the ACP transport applies to a prime payload).
    private static func wireEntries(from items: [ChatItem]) -> [WireEntry] {
        items.compactMap { item in
            guard case .message(let message) = item,
                  message.role == .local || message.role == .agent, !message.text.isEmpty else {
                return nil
            }
            return WireEntry(local: message.role == .local, text: message.text)
        }
    }

    // Person-to-person (v2) time-based behavior state. The scheduler is injectable so the
    // typing-expiry / read-mark-debounce / typing-throttle logic is tested with a virtual clock.
    private let scheduler: any ChatScheduler
    private var pinnedToBottom = true            // the view reports scroll pinning (drives read marks)
    private var sceneActive = true               // the view reports foreground/active (drives read marks)
    private var lastReadMarkItemID: String?      // the last id we emitted markRead up to (advance-only)
    private var isTypingActive = false           // we have an outstanding setTyping(true) not yet stopped
    private var lastTypingSentAt: Date?          // throttle: when we last emitted setTyping(true)

    // Injectable-clock timings (seconds).
    private let typingExpiry: TimeInterval = 10  // failsafe removal of a typing indicator if "stopped" is lost
    private let readMarkDebounce: TimeInterval = 2
    private let typingThrottle: TimeInterval = 4 // minimum gap between outgoing setTyping(true) signals
    private static let readMarkKey = "readmark"
    private static func typingExpiryKey(_ senderKey: String) -> String { "typing.expire.\(senderKey)" }

    init(config: ChatConfiguration, logger: any ChatLogger,
         contentSource: (any ChatContentSource)? = nil, scheduler: (any ChatScheduler)? = nil,
         hostEvents: ChatHostEventSink? = nil) {
        self.config = config
        self.logger = logger
        self.contentSource = contentSource
        self.scheduler = scheduler ?? RealChatScheduler()
        self.hostEvents = hostEvents
    }

    /// The active transport's advertised P2P capabilities (none before the transport is built).
    /// Every v2 affordance is gated on this AND the document's `features` config.
    private var capabilities: ChatTransportCapabilities {
        transport?.capabilities ?? ChatTransportCapabilities()
    }

    /// The composer may accept input only when the transport is not connection-gated, or is connected.
    /// A v1 / agent transport (reportsConnectionState == false) is always ready, so its composer is
    /// never connection-gated.
    var isConnectionReady: Bool {
        !capabilities.reportsConnectionState || connectionState == .connected
    }

    /// A one-line banner string when a reporting transport is not yet connected; nil otherwise (so a
    /// v1 / agent transport, or a connected one, shows no banner).
    var connectionBannerText: String? {
        guard capabilities.reportsConnectionState, connectionState != .connected else {
            return nil
        }
        switch connectionState {
        case .connecting:   return "Connecting..."
        case .reconnecting: return "Reconnecting..."
        case .offline:      return "Offline"
        case .connected:    return nil
        }
    }

    /// Loads any pre-populated transcript (a document `properties.content`, a testing convenience) once,
    /// (re)starts observing runtime restores through `states["content"]`, and - unless `readOnly` -
    /// builds the transport and drains its event stream. Called from the view's `.onAppear`; safe to
    /// call again after `.onDisappear` (which tears the transport / subscription down but preserves the
    /// transcript): the pre-populated load runs only the first time, and the transport is rebuilt.
    func start() {
        // One-time pre-populated load. A document `properties.content` (a preview / testing convenience,
        // NOT the production path) seeds the transcript before any transport runs.
        if !didLoadInitial {
            didLoadInitial = true
            if let raw = config.initialContentRaw {
                if let transcript = ChatTranscript.decode(from: raw) {
                    applyLoadedTranscript(transcript)
                    lastLoadedContent = transcript
                } else {
                    logger.log("Chat properties.content is not a decodable transcript; ignoring", .warning)
                }
            }
        }
        // (Re)subscribe to runtime restores through the content channel (in an ActionUI host:
        // states["content"] via setElementState[FromString]).
        // The dedup against `lastLoadedContent` ignores the subscription's immediate delivery of a
        // value already loaded (e.g. the pre-populated content).
        if contentCancellable == nil, let contentSource {
            contentCancellable = contentSource.observeChatContent { [weak self] newContent in
                self?.reconcileRestoredContent(newContent)
            }
        }

        // The single-item append channel. Subscribed even in readOnly: a history viewer showing a
        // conversation is exactly where a marker naming what happened to it belongs, and appending
        // touches no transport.
        if appendCancellable == nil, let contentSource {
            appendCancellable = contentSource.observeChatAppend { [weak self] value in
                self?.reconcileAppendedItem(value)
            }
        }

        // readOnly is the history-viewer mode: no transport, no config observation (ChatRootView
        // gates the composer / menus).
        guard !config.readOnly else {
            return
        }

        // (Re)subscribe to the host-injected operational config through states["config"]. The sink
        // delivers the current value on subscription AND on every change, so INIT-time injection is
        // never "too late": whenever a viable config arrives, reconcileConfig builds the transport.
        if configCancellable == nil, let contentSource {
            configCancellable = contentSource.observeChatConfig { [weak self] newConfig in
                self?.reconcileConfig(newConfig)
            }
        }

        // Reappearance: the transport was torn down on disappear but the config decision is frozen -
        // rebuild it from the frozen decision (ignoring any post-freeze states["config"] change).
        if didConfigure, transport == nil, let resolved = resolvedTransportConfig,
           let rebuilt = ChatTransportRegistry.shared.makeIfViable(
               protocolName: resolved.protocolName, transport: resolved.settings, logger: logger) {
            attach(rebuilt)
        }
    }

    // MARK: - Config injection (states["config"]) -> deferred, frozen transport

    /// Handles a host-injected operational config from states["config"]. Builds the transport the
    /// FIRST time the config resolves to a viable one; after that an IDENTICAL config is ignored
    /// (the subscription re-delivers the current value on every states change), while a DIFFERENT
    /// viable config RE-CONFIGURES: the old transport is torn down and the new one attached, and
    /// attach() re-seeds the new transport's wire history from the loaded items - this is the
    /// host-driven in-place switch (e.g. MLXChat re-injects the transport argv with a new --model,
    /// and the conversation carries over via the prime). A config that is not yet viable (e.g.
    /// openai-sse before its baseURL, or acp before its command) neither builds nor re-configures -
    /// the element keeps its current state and waits for a completer config.
    /// Internal so tests can drive an injection directly (as the config subscription does).
    func reconcileConfig(_ raw: Any?) {
        guard !config.readOnly else {
            return
        }
        guard let (protocolName, transportSettings) = Self.parseTransportConfig(raw) else {
            return   // no config object yet (states["config"] absent / not a dict) - stay inert
        }
        // Dedup: the config observation delivers the current value on subscription and on every
        // states change; the resolved config only re-applies when it actually CHANGED.
        if didConfigure, let resolved = resolvedTransportConfig,
           resolved.protocolName == protocolName,
           NSDictionary(dictionary: resolved.settings).isEqual(to: transportSettings) {
            return
        }
        guard let built = ChatTransportRegistry.shared.makeIfViable(
                protocolName: protocolName, transport: transportSettings, logger: logger) else {
            logger.log("Chat config for protocol '\(protocolName)' is not viable yet; awaiting a complete states[\"config\"]", .verbose)
            return
        }
        if didConfigure {
            // Re-configuration: stop the old transport cleanly and clear any in-flight turn
            // state it can no longer resolve (a stuck isStreaming would show a permanent
            // spinner and a dead Stop button on the new transport), plus the old session's
            // status surfaces (plan/usage/options/commands) - the new session re-emits its
            // own at sessionReady, and stale ones would misdescribe it until then.
            logger.log("Chat config changed; re-configuring the transport (protocol '\(protocolName)')", .verbose)
            eventTask?.cancel()
            eventTask = nil
            streamBuffers.removeAll()
            pendingPermissions.removeAll()
            isStreaming = false
            awaitingReply = false
            plan = []
            usage = nil
            configOptions = []
            availableCommands = []
            let old = transport
            transport = nil
            Task { await old?.stop() }
        }
        didConfigure = true
        resolvedTransportConfig = ChatTransportConfig(protocolName: protocolName, settings: transportSettings)
        isConfigured = true
        attach(built)
    }

    /// Parses the config channel's value into (protocolName, transport). Accepts a dict, a JSON
    /// string, or JSON Data (whatever the host's injection path delivers). A missing `protocol` defaults to
    /// "local"; a missing `transport` is an empty object. Returns nil when there is no config object.
    private static func parseTransportConfig(_ raw: Any?) -> (protocolName: String, transport: [String: Any])? {
        let dict: [String: Any]?
        switch raw {
        case let value as [String: Any]:
            dict = value
        case let string as String:
            dict = (string.data(using: .utf8).flatMap { try? JSONSerialization.jsonObject(with: $0) }) as? [String: Any]
        case let data as Data:
            dict = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        default:
            dict = nil
        }
        guard let dict else {
            return nil
        }
        let protocolName = (dict["protocol"] as? String) ?? ChatTransportRegistry.reservedLocalName
        let transportSettings = (dict["transport"] as? [String: Any]) ?? [:]
        return (protocolName, transportSettings)
    }

    /// Installs a built transport and starts draining its event stream.
    private func attach(_ transport: any ChatTransport) {
        self.transport = transport
        connectionState = .connecting   // ignored unless the transport reports connection state; a rebuilt transport re-gates until it reconnects
        // A freshly attached transport fronts a NEW agent session, so its context is
        // known-empty until a prime reaches it (immediately below, or lazily at send time
        // for a deferred directive). A new transport is also a new event stream: a stale
        // supersession flag from the old one must not swallow a real turn end.
        wireContext = []
        supersededTurnPending = false
        // A new transport is a new agent session: the old one's identity must not linger
        // (it names a pid and a session id that are both gone) until the new one reports.
        sessionInfo = nil
        // If a transcript was restored before the transport existed (content injected before a
        // viable config), seed the new transport's wire history from it so a continue carries
        // context - applying the last prime directive: an immediate directive seeds the wire
        // now; the deferred one leaves the new agent untouched until the user actually sends.
        // For a fresh session `items` is empty, so this primes an empty history.
        primeTransportFromItems()
        eventTask = Task { [weak self] in
            await transport.start()
            for await event in transport.events {
                self?.route(event)
            }
        }
    }

    /// Seeds the active transport's wire history from the current transcript's message items,
    /// so a continued conversation is sent with its prior turns as context (and an empty /
    /// cleared transcript resets the wire). No-op when no transport exists yet (attach()
    /// re-primes once one is built). Message items only (role + text); the transport maps
    /// role -> its own wire format. Called synchronously from applyLoadedTranscript and attach,
    /// always before any subsequent prompt, so no command-channel serialization is needed.
    private func primeTransportFromItems() {
        guard let transport else { return }
        // Reserve every loaded item id first, so a continued turn cannot mint an id the transport
        // already used in this transcript (ChatTransport.reserveIDs). This passes ALL ids -
        // including thoughts and tool cards, which primeHistory omits - because a transport's
        // per-turn id counter is shared across item kinds (a reasoning-only turn leaves a thought
        // id with no paired message id, invisible to a messages-only prime). Id reservation is
        // independent of the prime directive: it is collision safety, not context choice.
        transport.reserveIDs(seen: items.map(\.id))
        let current = Self.wireEntries(from: items)
        switch lastPrimeDirective {
        case .resume:
            // Context follows display, immediately (the documented default).
            transport.primeHistory(messageItems, condense: lastCondenseRequest)
            wireContext = current
            wireCondense = lastCondenseRequest
            contextState = .synced
        case .fresh:
            // "prime": false (a Read Only restore) shows the transcript but seeds an EMPTY wire
            // history, so continuing types against a fresh context instead of a misleading one.
            // Never re-primed at send time - the divergence is the user's choice.
            transport.primeHistory([])
            wireContext = []
            contextState = current.isEmpty ? .synced : .fresh
        case .deferred:
            // Display only: the agent is untouched. If its context already matches the display
            // (the user browsed away and back without sending), it is still synced and the next
            // send skips the prime entirely; otherwise the prime fires lazily in
            // syncDeferredContext() when the user next sends.
            //
            // THE REQUEST IS PART OF THE COMPARISON, not just the messages. Changing only the
            // summarize choice leaves the transcript byte-identical, so a messages-only test says
            // "already synced" and the next send skips the prime - the user picks Summarize,
            // nothing happens, and nothing reports why. It is reachable the moment a conversation
            // has been sent into once, which is when the menu is most likely to be used.
            contextState = (wireContext == current && wireCondense == lastCondenseRequest)
                ? .synced : .pending
        }
    }

    /// The transcript's message items (role + text) - the payload primeHistory takes
    /// (the transport maps role -> its own wire format and filters display-only roles).
    private var messageItems: [ChatMessage] {
        items.compactMap { item in
            if case let .message(message) = item { return message }
            return nil
        }
    }

    // MARK: - User intent

    /// Submits the current composer draft, if non-empty. `replyTo` (set by the reply flow) quotes a message.
    func submitDraft(replyTo: String? = nil) {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        draft = ""
        stopTypingSignal()                 // sending ends the typing state
        send(text, replyTo: replyTo)
    }

    /// Appends the user's message optimistically, emits `.send` / `.messageFinalized`, and
    /// forwards it to the transport. A plain send goes as `.prompt` (the v1 path, honored by every
    /// transport); a reply goes as `.sendMessage(text, replyTo:)` when both the document's `replies`
    /// feature and the transport's `replies` capability allow it (otherwise it degrades to a plain
    /// send). When the transport backs read receipts, the optimistic message starts at `.sending` so
    /// the delivery ladder shows; otherwise it carries no status (v1 / agent transports unchanged).
    func send(_ text: String, replyTo: String? = nil) {
        syncDeferredContext()
        localCounter += 1
        let itemID = "user-\(localCounter)"
        let repliesAllowed = replyTo != nil && config.features.replies && capabilities.replies
        let replyRef = repliesAllowed ? replyTo.flatMap(makeReplyRef) : nil
        let status: MessageStatus? = capabilities.readReceipts ? .sending : nil
        let message = ChatMessage(id: itemID, role: .local, text: text, isStreaming: false,
                                  status: status, replyTo: replyRef)
        items.append(.message(message))
        emit(.send)
        emit(.messageFinalized)
        fireEntry(type: "message", id: itemID, data: ChatItem.message(message))
        // Enter the awaiting-reply state: the turn is submitted but nothing has streamed back yet.
        // Cleared by the terminal messageEnd / error (or a restore); until then the view shows a
        // "thinking" spinner, because isStreaming only flips true on the first streamed event.
        awaitingReply = true
        let transport = self.transport
        // A `messageIdentity` transport always sends through `.sendMessage` (reply or not), carrying the
        // optimistic `itemID` as `localID` so the transport can address the in-flight message before it
        // has a server id (to fail it) and reconcile it (via `.messageIDConfirmed`) once it does. A v1 /
        // agent transport (messageIdentity false, replies false) still uses `.prompt`, byte-for-byte as before.
        let useMessageSend = capabilities.messageIdentity || repliesAllowed
        if useMessageSend {
            let ref = repliesAllowed ? replyTo : nil
            Task { await transport?.send(.sendMessage(text: text, replyTo: ref, localID: itemID)) }
        } else {
            Task { await transport?.send(.prompt(text: text)) }
        }
    }

    /// The lazy half of a deferred restore: when the displayed conversation has not reached
    /// the agent (contextState .pending), replay it NOW - synchronously, before the prompt is
    /// dispatched, so the transport's prime-before-prompt ordering holds (ACP chains the
    /// prompt behind the registered prime task). Skipped when the agent's context already
    /// matches the display, so browsing away and back never pays a prime; a .fresh context is
    /// never re-primed (its divergence is the user's choice). Called at the top of send(),
    /// before the optimistic user message appends (the prompt itself carries the new text).
    private func syncDeferredContext() {
        guard contextState == .pending, let transport else { return }
        let current = Self.wireEntries(from: items)
        if wireContext != current || wireCondense != lastCondenseRequest {
            // Carries the request the RESTORE arrived with, not one from now: this fires at send
            // time, and the user's choice was made when they opened the conversation.
            transport.primeHistory(messageItems, condense: lastCondenseRequest)
        }
        wireContext = current
        wireCondense = lastCondenseRequest
        contextState = .synced
    }

    /// Requests cancellation of the in-flight turn.
    func stop() {
        emit(.stop)
        let transport = self.transport
        Task { await transport?.send(.cancel) }
    }

    /// Changes a session option (mode / model / ...) from the status-line menus.
    /// Deliberately NOT optimistic: the display updates when the transport confirms
    /// (.configOptionsChanged, or the agent's own current_mode_update), so a failed
    /// change never needs a revert.
    func setConfigOption(_ optionID: String, value: String) {
        let transport = self.transport
        Task { await transport?.send(.setConfigOption(optionID: optionID, value: value)) }
    }

    /// Answers a pending permission request. `optionID` is one of the request's
    /// option IDs, or nil for a dismissal (the cancelled outcome). Dequeues the
    /// request and forwards the response to the transport, which unblocks (or
    /// abandons) the gated tool call.
    func respondToPermission(_ requestID: String, optionID: String?) {
        pendingPermissions.removeAll { $0.id == requestID }
        let transport = self.transport
        Task { await transport?.send(.permissionResponse(requestID: requestID, optionID: optionID)) }
    }

    // MARK: - Person-to-person (v2) affordance availability (view display gating)

    // An affordance shows only when the document enables the feature AND the transport backs it. The
    // command helpers below re-check the same gate defensively. `canAttach` is host-action-gated
    // (attach is a host concern, not a transport capability).
    var canReact: Bool { config.features.reactions && capabilities.reactions }
    var canEditMessages: Bool { config.features.editing && capabilities.editing }
    var canDeleteMessages: Bool { config.features.deletion && capabilities.deletion }
    var canReply: Bool { config.features.replies && capabilities.replies }
    var canAttach: Bool { config.attachEnabled }

    /// Emits the attach host event (the composer paperclip). The host mediates the picker
    /// and hands the file to its transport out of band. No-op when the host did not enable attach.
    func triggerAttach() {
        emit(.attach)
    }

    // MARK: - Person-to-person (v2) command helpers (view -> transport)

    // Each affordance is gated on the document's `features` AND the transport's `capabilities`;
    // the view gates the same way for display, so a command only reaches here when both allow it,
    // but the guard is repeated defensively (a stale view, a programmatic call).

    /// Toggles the local user's reaction with `emoji` on a message. The add / remove direction is
    /// derived from the current reaction set (remove when already `mine`, else add).
    func toggleReaction(itemID: String, emoji: String) {
        guard config.features.reactions, capabilities.reactions else {
            return
        }
        let mine = reactions(of: itemID)?.first(where: { $0.emoji == emoji })?.mine ?? false
        let transport = self.transport
        Task { await transport?.send(.toggleReaction(itemID: itemID, emoji: emoji, add: !mine)) }
    }

    /// Edits an own message. Not optimistic: the transport confirms with `.messageEdited`.
    func editMessage(itemID: String, newText: String) {
        guard config.features.editing, capabilities.editing else {
            return
        }
        let trimmed = newText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return
        }
        let transport = self.transport
        Task { await transport?.send(.editMessage(itemID: itemID, newText: trimmed)) }
    }

    /// Deletes an own message. Not optimistic: the transport confirms with `.messageDeleted`.
    func deleteMessage(itemID: String) {
        guard config.features.deletion, capabilities.deletion else {
            return
        }
        let transport = self.transport
        Task { await transport?.send(.deleteMessage(itemID: itemID)) }
    }

    /// Retries a `failed` message OR a `failed` file / voice transfer (the "tap to retry" affordance).
    /// Not feature-gated - resend is intrinsic to sending; it only reaches a P2P transport that produced
    /// the failed state. Both reuse the one `.resendMessage(itemID:)` command (no separate file case).
    func resendMessage(itemID: String) {
        switch item(itemID) {
        case .message(let message) where message.status == .failed:
            mutateMessage(itemID, kind: "resend") { $0.status = .sending }
        case .file(let file) where file.transferStatus == .failed:
            mutateFile(itemID, fireEntry: false) {
                $0.transferStatus = .transferring
                $0.progress = 0
            }
        default:
            return
        }
        let transport = self.transport
        Task { await transport?.send(.resendMessage(itemID: itemID)) }
    }

    /// Cancels an in-flight file / voice transfer.
    func cancelFileTransfer(itemID: String) {
        guard capabilities.fileTransfer else {
            return
        }
        let transport = self.transport
        Task { await transport?.send(.cancelFileTransfer(itemID: itemID)) }
    }

    // MARK: - Person-to-person (v2) store-initiated behaviors

    /// The view reports the transcript scrolled near the top. When the transport pages and there is
    /// (or may be) earlier history not already loading, request the previous page.
    func scrolledNearTop() {
        guard capabilities.paging, hasEarlier, !isLoadingEarlier, let topID = items.first?.id else {
            return
        }
        isLoadingEarlier = true
        let transport = self.transport
        Task { await transport?.send(.loadEarlier(beforeItemID: topID, limit: 50)) }
    }

    /// The view reports whether the transcript is pinned to the bottom (drives read receipts).
    func setPinnedToBottom(_ pinned: Bool) {
        pinnedToBottom = pinned
        maybeScheduleReadMark()
    }

    /// The view reports whether the scene is active / foreground (drives read receipts).
    func setSceneActive(_ active: Bool) {
        sceneActive = active
        maybeScheduleReadMark()
    }

    /// Composer text activity: emit an outgoing typing signal, throttled to at most one per
    /// `typingThrottle` seconds. Called on each keystroke by the view when the draft is non-empty.
    func notifyComposerActivity() {
        guard capabilities.typing else {
            return
        }
        let now = scheduler.now
        if let last = lastTypingSentAt, now.timeIntervalSince(last) < typingThrottle {
            return
        }
        lastTypingSentAt = now
        isTypingActive = true
        let transport = self.transport
        Task { await transport?.send(.setTyping(isTyping: true)) }
    }

    /// Ends the outgoing typing state (on send, clear, or blur). A no-op when not currently typing.
    func stopTypingSignal() {
        guard capabilities.typing, isTypingActive else {
            return
        }
        isTypingActive = false
        lastTypingSentAt = nil
        let transport = self.transport
        Task { await transport?.send(.setTyping(isTyping: false)) }
    }

    /// Finishes the transport (ending its event stream so the drain task completes)
    /// and tears down. Called from the view's `.onDisappear`; idempotent.
    func teardown() {
        eventTask?.cancel()
        eventTask = nil
        contentCancellable?.cancel()
        contentCancellable = nil
        appendCancellable?.cancel()
        appendCancellable = nil
        configCancellable?.cancel()
        configCancellable = nil
        streamBuffers.removeAll()
        pendingPermissions.removeAll()
        scheduler.cancel(Self.readMarkKey)
        for participant in typingParticipants {
            scheduler.cancel(Self.typingExpiryKey(participant.id))
        }
        // Clear the in-flight turn state too: the @StateObject store outlives a disappear/reappear
        // cycle, so a turn abandoned by teardown must not leave isStreaming / awaitingReply stuck
        // true - which would show a permanent spinner and a dead Stop button on reappearance.
        isStreaming = false
        awaitingReply = false
        connectionState = .connecting   // reset for cleanliness; the composer is already gated by isConfigured while torn down
        sessionInfo = nil               // the agent is being stopped; its session id and pid name nothing after this
        let transport = self.transport
        self.transport = nil
        Task { await transport?.stop() }
    }

    // MARK: - Router (pre-filter): ChatEvent -> store mutation

    // Internal (not private) so tests can drive the reduction directly.
    func route(_ event: ChatEvent) {
        switch event {
        case .sessionReady(let sessionID, let options):
            configOptions = options
            logger.log("Chat session ready: \(sessionID)", .verbose)

        case .sessionEvent(let event):
            // Appended like any other item, and journaled like one: a host that persists the
            // transcript keeps the record of what its model was actually given, so reopening the
            // conversation tomorrow still answers "what was summarized away here".
            items.append(.sessionEvent(event))
            // ChatItem.sessionEvent(event), NOT the bare event. `data` is the persisted ChatItem,
            // and every other case here wraps; this one did not, so the entry went out with the
            // payload at the top level and no `type` discriminator. A host that stored it verbatim
            // and restored it later handed ChatItem's decoder an object with no `type`: it throws,
            // ChatTranscript decodes `items` as one array, and the WHOLE conversation fails to
            // decode. What this element wrote, it could not read back.
            fireEntry(type: "sessionEvent", id: event.id, data: ChatItem.sessionEvent(event))

        case .sessionInfo(let info):
            sessionInfo = info
            fireEntry(type: "session", id: info.sessionId, data: info)

        case .messageStart(let itemID, let role):
            finalizeOpenThoughts()
            items.append(.message(ChatMessage(id: itemID, role: role, text: "", isStreaming: true)))
            streamBuffers[itemID] = ""
            if role != .local {
                isStreaming = true
            }

        case .messageDelta(let itemID, let text):
            if streamBuffers[itemID] != nil {
                streamBuffers[itemID]? += text
                scheduleFlush()
            } else {
                // A delta with no prior start: open an agent message implicitly.
                items.append(.message(ChatMessage(id: itemID, role: .agent, text: "", isStreaming: true)))
                streamBuffers[itemID] = text
                isStreaming = true
                scheduleFlush()
            }

        case .messageEnd(let itemID, let stopReason):
            // Final flush is immediate (do not wait for the coalescing tick), then finalize.
            finalizeOpenThoughts()
            let finalText = streamBuffers[itemID]
            streamBuffers[itemID] = nil
            if let index = messageIndex(itemID) {
                mutateStreamingText(at: index) {
                    if let finalText {
                        $0.text = finalText
                    }
                    $0.isStreaming = false
                }
                if case .message(let finalized) = items[index] {
                    fireEntry(type: "message", id: itemID, data: ChatItem.message(finalized))
                }
            }
            emit(.messageFinalized)
            // A nil stopReason closes only this message (a segmented transport - ACP -
            // interleaves tool calls mid-turn). A non-nil stopReason ends the whole turn:
            // streaming state clears, and a permission request the turn abandoned (e.g.
            // on cancel) is moot.
            if let stopReason {
                isStreaming = false
                awaitingReply = false
                pendingPermissions.removeAll()
                trackContextAfterTurn(stopReason: stopReason)
            }

        case .thoughtDelta(let itemID, let text):
            if config.surfaces.thoughts == .hidden {
                return
            }
            if streamBuffers[itemID] != nil {
                streamBuffers[itemID]? += text
            } else {
                items.append(.thought(ChatMessage(id: itemID, role: .agent, text: "", isStreaming: true)))
                streamBuffers[itemID] = text
                isStreaming = true
            }
            scheduleFlush()

        case .toolCall(let call):
            finalizeOpenThoughts()
            if config.surfaces.toolCalls == .hidden {
                return
            }
            items.append(.toolCall(call))
            isStreaming = true
            fireEntryForCompletedToolCall(call)

        case .toolCallUpdate(let update):
            if config.surfaces.toolCalls == .hidden {
                return
            }
            guard let index = toolCallIndex(update.id) else {
                logger.log("Chat tool_call_update for unknown call '\(update.id)'; ignoring", .verbose)
                return
            }
            guard case .toolCall(var call) = items[index] else { return }
            if let title = update.title {
                call.title = title
            }
            if let kind = update.kind {
                call.kind = kind
            }
            if let status = update.status {
                call.status = status
            }
            if let contentText = update.contentText {
                call.contentText = contentText
            }
            if let diff = update.diff {
                call.diff = diff
            }
            if let rawInput = update.rawInput {
                call.rawInput = rawInput
            }
            if let rawOutput = update.rawOutput {
                call.rawOutput = rawOutput
            }
            items[index] = .toolCall(call)
            fireEntryForCompletedToolCall(call)

        case .permissionRequest(let request):
            finalizeOpenThoughts()
            pendingPermissions.append(request)
            isStreaming = true
            emit(.toolApprovalRequested)

        case .permissionResolved(let requestID):
            // Somebody else settled this one: a second device attached to the same remote session
            // answered it, or the bridge default-denied it on a timeout. Drop the gate without
            // sending an answer of our own - the answer already happened upstream. An id we never
            // saw is normal (we may have attached after the request was issued), so this is a
            // no-op rather than a warning.
            pendingPermissions.removeAll { $0.id == requestID }

        case .resumeCheckpoint(let sessionID, let afterSeq):
            fireResumeCheckpoint(sessionID: sessionID, afterSeq: afterSeq)

        case .plan(let entries):
            if config.surfaces.plan == .hidden {
                return
            }
            // The agent re-emits its WHOLE plan as it progresses: replace, never merge.
            plan = entries
            fireEntry(type: "plan", id: nil, data: entries)

        case .usage(let info):
            usage = info
            fireEntry(type: "usage", id: nil, data: info)

        case .currentModeChanged(let modeID):
            // The spec's current_mode_update names only the new value; it targets the
            // mode option (matched by category, falling back to the "mode" id).
            guard let index = configOptions.firstIndex(where: { $0.category == "mode" || $0.id == "mode" }) else {
                logger.log("Chat current_mode_update '\(modeID)' with no mode option; ignoring", .verbose)
                return
            }
            configOptions[index].currentValue = modeID

        case .commandsAvailable(let commands):
            // The agent re-emits its WHOLE command set as it changes: replace, never merge.
            availableCommands = commands

        case .configOptionsChanged(let options):
            // A setter's confirmation: the refreshed option set replaces the display.
            configOptions = options

        case .image(let itemID, let role, let image):
            items.append(.image(id: itemID, role: role, image: image))
            emit(.messageFinalized)
            fireEntry(type: "image", id: itemID, data: ChatItem.image(id: itemID, role: role, image: image))

        case .system(let text):
            localCounter += 1
            let itemID = "system-\(localCounter)"
            items.append(.system(id: itemID, text: text))
            fireEntry(type: "system", id: itemID, data: ChatItem.system(id: itemID, text: text))

        case .transientSystem(let text):
            // Shown, not journaled. No `fireEntry`, deliberately - see the case's documentation:
            // this describes the restore that just happened, and a host that stored it would
            // accumulate one identical copy per restore and replay all of them next time.
            //
            // Not repeated back to back either. The same restore can be re-primed several times
            // in one session - a cancelled or errored turn re-arms the context, and the request
            // that rode in with the content is replayed with it - so the same sentence can arrive
            // three times for three Stops. Once is the news; the rest is noise.
            if case .system(_, let previous) = items.last, previous == text { return }
            localCounter += 1
            items.append(.system(id: "system-\(localCounter)", text: text))

        case .error(let message, _):
            localCounter += 1
            let itemID = "error-\(localCounter)"
            items.append(.error(id: itemID, text: message))
            awaitingReply = false   // defensive: a transport that errors without a trailing messageEnd still drops the spinner
            emit(.error)
            fireEntry(type: "error", id: itemID, data: ChatItem.error(id: itemID, text: message))

        // --- P2P (v2) events. Only the `local-p2p` and real P2P transports emit these; a v1
        //     transport never does, so v1 behavior is untouched. These do NOT drive
        //     awaitingReply / isStreaming (that is agentic-turn state, kept separate).

        case .messageReceived(let message):
            let existed = upsertMessage(message)
            emit(.messageFinalized)
            fireEntry(type: "message", id: message.id, data: ChatItem.message(message.finalized), updated: existed)
            maybeScheduleReadMark()

        case .messageIDConfirmed(let localID, let serverID):
            reconcileMessageID(localID: localID, serverID: serverID)

        case .messageStatusChanged(let itemID, let status):
            mutateMessage(itemID, kind: "message_status") { $0.status = status }

        case .messageStatusWatermark(let status, let upToItemID):
            applyStatusWatermark(status: status, upTo: upToItemID)

        case .reactionsChanged(let itemID, let reactions):
            mutateMessage(itemID, kind: "reactions") { $0.reactions = reactions }

        case .messageEdited(let itemID, let newText, let editedAt):
            mutateMessage(itemID, kind: "edit") {
                $0.text = newText
                $0.editedAt = editedAt
            }

        case .messageDeleted(let itemID):
            mutateMessage(itemID, kind: "delete") {
                $0.deleted = true
                $0.text = ""     // a tombstone renders no text; blank it so a persisted copy carries none
            }

        case .memberEvent(let event):
            items.append(.memberEvent(event))
            fireEntry(type: "memberEvent", id: event.id, data: ChatItem.memberEvent(event))
            maybeScheduleReadMark()

        case .callEvent(let event):
            items.append(.callEvent(event))
            fireEntry(type: "callEvent", id: event.id, data: ChatItem.callEvent(event))
            maybeScheduleReadMark()

        case .fileAdded(let file):
            let existed = upsertFile(file)
            emit(.messageFinalized)
            // Fire the file entry on add, and again (updated) once its transfer is terminal - like a
            // tool call - so per-tick progress does not spam the entry channel.
            let terminal = file.transferStatus == .completed || file.transferStatus == .failed || file.transferStatus == .cancelled
            if !existed || terminal {
                fireEntry(type: "file", id: file.id, data: ChatItem.file(file), updated: existed)
            }
            maybeScheduleReadMark()

        case .fileProgress(let itemID, let progress, let transferStatus):
            let terminal = transferStatus == .completed || transferStatus == .failed || transferStatus == .cancelled
            mutateFile(itemID, fireEntry: terminal) {
                $0.progress = progress
                $0.transferStatus = transferStatus
            }

        case .typingChanged(let isTyping, let senderID, let senderName):
            updateTypingIndicator(isTyping: isTyping, senderID: senderID, senderName: senderName)

        case .participantsChanged(let roster):
            participants = roster
            fireEntry(type: "participants", id: nil, data: roster)

        case .historyPage(let older, let hasMore):
            prependHistory(older, hasMore: hasMore)

        case .connectionStateChanged(let state):
            connectionState = state
        }
    }

    /// True for the values the content channel uses to mean "nothing here" - worth distinguishing
    /// from a malformed transcript, which is worth a warning.
    private static func isEmptyContent(_ value: Any?) -> Bool {
        guard let value else { return true }
        if value is NSNull { return true }
        if let string = value as? String {
            return string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        if let data = value as? Data { return data.isEmpty }
        return false
    }

    /// Appends ONE host-supplied item to the live transcript. Internal so tests can drive it
    /// directly, exactly as the append subscription does.
    ///
    /// It fires no entry (the host already has this item - see `observeChatAppend`) and does not
    /// re-prime. It is NOT otherwise a shortcut: it replays the same id and read-mark bookkeeping
    /// the other three ways into `items` perform.
    ///
    /// An item that adds no wire entry leaves the context indicator alone - a session marker, and
    /// equally a message the prime would drop anyway (empty text, or a display-only role). A
    /// message carrying conversational text does not: it moves `wireEntries` ahead of what the
    /// agent was told, so the context is marked pending and the next send re-primes.
    func reconcileAppendedItem(_ value: Any?) {
        guard let item = ChatItem.decode(from: value) else {
            // Warn ONCE per distinct bad value. The host bridge re-delivers this channel on every
            // change to the whole state dictionary, so an unchanged rejected value would otherwise
            // log once per keystroke and bury the diagnostic it exists to provide.
            let description = String(describing: value)
            if !Self.isEmptyContent(value), description != lastRejectedAppend {
                lastRejectedAppend = description
                logger.log("Chat append channel delivered a value that is not a decodable item; "
                           + "it was ignored", .warning)
            }
            return
        }
        lastRejectedAppend = nil
        // The channel delivers its current value on subscription, so a reappearance re-delivers the
        // last item appended. Dedup on id rather than on the item, so a host that re-sends a
        // corrected version of the same marker is also a no-op rather than a duplicate line.
        guard !appendedItemIDs.contains(item.id), !items.contains(where: { $0.id == item.id }) else {
            return
        }
        appendedItemIDs.insert(item.id)
        items.append(item)
        // This is the fourth way items enter the store, and the other three replay these invariants.
        // Skipping them is how an appended item collides with one the store is about to mint: the
        // ids handed to a host by fireEntry are the store's own (`user-N`), so a host replaying one
        // of its saved items through this channel reuses that shape by construction, and every
        // mutation path looks items up with `firstIndex`.
        advanceLocalCounter(past: [item])
        transport?.reserveIDs(seen: [item.id])
        maybeScheduleReadMark()
        // AND THE CONTEXT MAY NOW BE STALE - but only if THIS item is one the agent was never
        // told about, which is a question about the item's OWN wire contribution (asked through
        // `wireEntries`, so the two stay in step if that filter ever changes). It cannot be asked
        // of the whole transcript against `wireContext`: that snapshot advances only at prime,
        // restore and turn end, so mid-turn it is stale by construction - it does not yet hold the
        // optimistic message send() appended. Measured against it, a session marker that moves no
        // wire entry at all reads as a divergence: the indicator goes orange in a brand-new chat,
        // and trackContextAfterTurn then nils the snapshot at that turn's end, so the next send
        // re-primes the whole conversation for nothing.
        // The limit of asking it this way, worth knowing rather than discovering: `wireEntries` is
        // the ACP prime's filter exactly (role local/agent, non-empty text), but the OpenAI
        // transport maps `.remote` and `.system` to real wire roles too - so a host appending one
        // of those DOES change what the next prime sends there, and neither this test nor the
        // snapshot it compares against can represent it. That blindness is older than this line:
        // the whole-transcript comparison could not see those items either.
        //
        // A MESSAGE CARRYING TEXT is the case this really guards: left unsaid, the model answers
        // without ever seeing a line the user is reading, the indicator keeps claiming synced, and
        // trackContextAfterTurn adopts the unsent message as held at the end of the next turn -
        // after which nothing can tell it was ever wrong. Saying `pending` costs one re-prime on
        // the next send, which is exactly what the deferred path already does.
        if transport != nil, !Self.wireEntries(from: [item]).isEmpty,
           Self.wireEntries(from: items) != wireContext {
            contextState = .pending
        }
    }

    // MARK: - Session transcript seam: restore-in + incremental per-entry persistence

    /// Handles a transcript a host restored through the content channel (in an ActionUI host:
    /// states["content"]). Ignores content already loaded (the subscription's immediate
    /// current-value delivery, or a repeated identical restore); a new transcript replaces the
    /// session. Internal so tests can drive a restore directly (as the content subscription does).
    func reconcileRestoredContent(_ newContent: Any?) {
        guard let transcript = ChatTranscript.decode(from: newContent) else {
            // A restore that will not decode is indistinguishable from no restore at all without
            // this line, and that silence is expensive: ChatItem's decoder throws on an item whose
            // `type` it does not recognize, ChatTranscript decodes `items` as a single array, and
            // `decode(from:)` swallows the throw with `try?`. ONE bad item therefore drops a whole
            // conversation, and the window just keeps showing whatever it had - no error, no
            // change, nothing to search for. Nil is the ordinary empty channel and stays quiet.
            let description = String(describing: newContent)
            if !Self.isEmptyContent(newContent), description != lastRejectedContent {
                lastRejectedContent = description
                logger.log("Chat content channel delivered a value that is not a decodable "
                           + "transcript; the restore was ignored", .warning)
            }
            return
        }
        // The transient "prime" directive rides on the raw injected JSON (Codable drops the
        // unknown key from ChatTranscript, so it never reaches persistence). It participates
        // in the dedup: the same transcript re-injected with a flipped flag must re-apply
        // (e.g. the user reopens a conversation Read Only after having resumed it).
        let prime = Self.parsePrimeDirective(newContent)
        // Same reasoning as `prime`: a re-injection that only changes how the context should be
        // built still has to re-apply, or asking to summarize a conversation already on screen
        // would be silently ignored.
        let condense = Self.parseCondenseRequest(newContent)
        guard transcript != lastLoadedContent || prime != lastPrimeDirective
                || condense != lastCondenseRequest else {
            return
        }
        lastPrimeDirective = prime
        lastCondenseRequest = condense
        applyLoadedTranscript(transcript)
        lastLoadedContent = transcript
    }

    /// Reads the transient `condense` object off the same raw content value.
    ///
    /// Absent means "replay everything", which is the documented default and the safe one. An
    /// EMPTY object is a real request - "summarize, your defaults" - so presence of the key, not
    /// its contents, is what decides.
    /// Test seam for the parser above. Internal, and named for what it is, so nobody mistakes it
    /// for API: the parser is private because hosts never call it, but it decides whether a
    /// user's choice reaches the agent at all, which is worth asserting directly.
    static func parseCondenseRequestForTests(_ raw: Any?) -> PrimeCondense? {
        parseCondenseRequest(raw)
    }

    private static func parseCondenseRequest(_ raw: Any?) -> PrimeCondense? {
        guard let dict = Self.contentDictionary(raw), let ask = dict["condense"] else {
            return nil
        }
        guard let body = ask as? [String: Any] else {
            // `"condense": true` is a reasonable thing for a host to write, and refusing it over
            // a type mismatch would be pedantry: it means the same as an empty object.
            return (ask as? Bool) == true ? PrimeCondense() : nil
        }
        // Trimmed, and empty means ABSENT rather than a request for a summarizer named "". A host
        // that stores the user's choice as a string has an empty one before they have chosen, and
        // forwarding that would ask the agent for a summarizer nobody named - which agents are
        // entitled to refuse, turning "no preference" into a conversation that primes whole.
        var backend = (body["backend"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if backend?.isEmpty == true { backend = nil }
        return PrimeCondense(keepRecentTurns: (body["keepRecentTurns"] as? NSNumber)?.intValue,
                             maxDigestTokens: (body["maxDigestTokens"] as? NSNumber)?.intValue,
                             backend: backend)
    }

    /// Reads the transient `prime` directive off a raw states["content"] value, accepting the
    /// same three shapes ChatTranscript.decode does (dict / JSON string / Data). true / absent /
    /// unparseable -> resume (context follows display, the documented default); false -> fresh;
    /// "defer" -> deferred (display now, prime lazily on the next send).
    /// The three shapes a host can inject content as, reduced to a dictionary. Shared by both
    /// transient-directive readers so they cannot come to disagree about what counts as content.
    private static func contentDictionary(_ raw: Any?) -> [String: Any]? {
        switch raw {
        case let value as [String: Any]:
            return value
        case let string as String:
            return (string.data(using: .utf8).flatMap { try? JSONSerialization.jsonObject(with: $0) }) as? [String: Any]
        case let data as Data:
            return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        default:
            return nil
        }
    }

    private static func parsePrimeDirective(_ raw: Any?) -> ChatPrimeDirective {
        let dict = Self.contentDictionary(raw)
        switch dict?["prime"] {
        case let flag as Bool:
            return flag ? .resume : .fresh
        case let mode as String where mode == "defer":
            return .deferred
        default:
            return .resume
        }
    }

    /// Replaces the session state with a loaded transcript: items render in their final states
    /// (no live continuations), the streaming / permission / buffer state is cleared, and the
    /// status surfaces are restored. Appended turns (if a transport runs) land after the loaded items.
    private func applyLoadedTranscript(_ transcript: ChatTranscript) {
        // Both restore paths funnel through here, so this is the one place that sees every decode.
        // The placeholder rows make the loss visible to the READER of the conversation; this makes
        // it searchable for whoever has to work out why an entry is unreadable.
        if transcript.unreadableItemCount > 0 {
            logger.log("Chat restored a transcript with \(transcript.unreadableItemCount) "
                       + "unreadable item(s); each is shown in place as an error row", .warning)
        }
        let turnWasInFlight = isStreaming || awaitingReply
        items = transcript.items
        transcriptGeneration &+= 1
        usage = transcript.usage
        plan = transcript.plan
        title = transcript.title
        participants = transcript.participants ?? []
        isStreaming = false
        awaitingReply = false
        pendingPermissions.removeAll()
        streamBuffers.removeAll()
        // A restored session supersedes any read-mark / typing state.
        lastReadMarkItemID = nil
        typingParticipants.removeAll()
        // The append dedup describes the items that were just replaced, so it stops describing
        // anything. Left in place it outlives them forever and silently swallows a legitimate
        // re-append of the same id into the new transcript.
        appendedItemIDs.removeAll()
        // Advance the id counter past any store-generated ids in the loaded transcript, so a
        // subsequent user/system/error item cannot collide with a loaded one.
        advanceLocalCounter(past: transcript.items)
        // A restore mid-turn supersedes the turn: its terminal messageEnd must not re-run
        // the turn-end context bookkeeping (see supersededTurnPending).
        if turnWasInFlight {
            supersededTurnPending = true
        }
        // A deferred restore arriving mid-turn still cancels the in-flight turn - its stream
        // has nowhere to render now that the items were replaced. (The immediate directives
        // cancel inside the transport's primeHistory.) The agent is left holding a partial
        // exchange, so the context becomes unknown and the next send re-primes.
        if lastPrimeDirective == .deferred, turnWasInFlight {
            wireContext = nil
            let transport = self.transport
            Task { await transport?.send(.cancel) }
        }
        // Seed the transport's wire history from the loaded transcript so typing continues the
        // conversation WITH its prior turns as context (P0-2 continue-in). An empty transcript
        // (New Chat clear) resets the wire; a deferred directive only marks the context pending.
        // No-op if the transport is not built yet.
        primeTransportFromItems()
    }

    /// The envelope carried by the `.entry` host event: a monotonic sequence, the finalized entry's type
    /// and id (for idempotent upsert on the app side), and the entry's JSON. `updated` is set
    /// only on a POST-finalization re-fire of an already-seen id (a status change, reaction,
    /// edit, delete, or terminal file transfer); it is omitted otherwise, so a v1 entry's
    /// envelope is byte-identical to before.
    private struct EntryEnvelope<Payload: Encodable>: Encodable {
        let sequence: Int
        let type: String
        let id: String?
        let data: Payload
        let updated: Bool?
    }

    /// Emits `.entry` (when the host enabled entry events) with a JSON envelope for one finalized
    /// transcript entry, so the host can persist incrementally without polling. Never called on streaming deltas.
    /// `updated` marks a re-fire for an id the host already has (upsert-and-mark-updated).
    private func fireEntry<Payload: Encodable>(type: String, id: String?, data: Payload, updated: Bool = false) {
        guard config.emitsEntryEvents, hostEvents != nil else {
            return
        }
        // Compute the next sequence but commit it only if the payload encodes, so an encode failure
        // does not burn a number (a host detecting dropped events by a sequence gap would false-positive).
        let next = entrySequence + 1
        let envelope = EntryEnvelope(sequence: next, type: type, id: id, data: data, updated: updated ? true : nil)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let jsonData = try? encoder.encode(envelope), let json = String(data: jsonData, encoding: .utf8) else {
            logger.log("Chat: could not encode entry payload for '\(type)'; skipping", .warning)
            return
        }
        entrySequence = next
        emit(.entry(json: json))
    }

    /// The `{"afterSeq":N,"sessionId":"..."}` payload of a `.resumeCheckpoint` host event.
    /// `sessionId` (lowercase d) matches the wire spelling the bridge uses, not Swift's `sessionID`.
    private struct ResumeCheckpoint: Encodable {
        let sessionId: String
        let afterSeq: Int
    }

    /// Hands the host the resume cursor for the transcript it has stored so far.
    ///
    /// Gated on `emitsEntryEvents` deliberately: a host that is not persisting entries has no
    /// transcript for this cursor to pair with, and a cursor stored WITHOUT its transcript is the
    /// worse of the two failure modes - it silently skips the history before it on the next
    /// attach. No entries out, no cursor out.
    private func fireResumeCheckpoint(sessionID: String, afterSeq: Int) {
        guard config.emitsEntryEvents, hostEvents != nil else {
            // Say so once rather than dropping silently: a host that wired a checkpoint store
            // but left emitsEntryEvents false would otherwise see cold-launch replay from zero
            // forever with nothing to explain it.
            logger.log("Chat: dropping a resume checkpoint; the host is not persisting entries "
                       + "(set emitsEntryEvents to receive it)", .verbose)
            return
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let payload = ResumeCheckpoint(sessionId: sessionID, afterSeq: afterSeq)
        guard let jsonData = try? encoder.encode(payload), let json = String(data: jsonData, encoding: .utf8) else {
            logger.log("Chat: could not encode resume checkpoint for session '\(sessionID)'; skipping", .warning)
            return
        }
        emit(.resumeCheckpoint(json: json))
    }

    /// Fires the "toolCall" entry whenever a tool call is in (or reaches) a terminal (completed /
    /// failed) state. It re-fires if a terminal call receives further updates - some transports deliver
    /// the terminal status and the final output/diff in SEPARATE updates - so the LAST entry always
    /// carries the final content. The host upserts by type+id, so the re-fires collapse to the latest.
    private func fireEntryForCompletedToolCall(_ call: ToolCallModel) {
        guard call.status == .completed || call.status == .failed else {
            return
        }
        fireEntry(type: "toolCall", id: call.id, data: ChatItem.toolCall(call))
    }

    // MARK: - Coalescing

    /// Ensures one flush is scheduled ~50 ms out (≈20 Hz). Repeated deltas within the window do not
    /// stack up - they all land in `streamBuffers` and are applied by the single pending flush.
    private func scheduleFlush() {
        if flushPending {
            return
        }
        flushPending = true
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 50_000_000)
            self?.applyBufferedText()
        }
    }

    private func applyBufferedText() {
        flushPending = false
        for (itemID, text) in streamBuffers {
            guard let index = messageIndex(itemID) else {
                continue
            }
            if streamingText(at: index) != text {
                mutateStreamingText(at: index) { $0.text = text }
            }
        }
    }

    /// Context bookkeeping at turn end. A cleanly ended turn grew the agent's context and the
    /// display together, so a synced context stays synced and the tracked snapshot advances.
    /// A cancelled / errored turn leaves the agent holding a partial exchange the display may
    /// not mirror: the context becomes unknown, and a synced state drops to pending so the
    /// next send re-primes from the display (a wasted re-prime is safe; a silently divergent
    /// context is not). A .fresh context diverges further with every turn, so its snapshot
    /// goes unknown too (a later deferred restore of that conversation then re-primes).
    private func trackContextAfterTurn(stopReason: String) {
        // The terminal event of a turn a restore already superseded: the restore path set
        // the truthful state; running the bookkeeping below would wrongly discard it.
        if supersededTurnPending {
            supersededTurnPending = false
            return
        }
        if stopReason == "cancelled" || stopReason == "error" {
            wireContext = nil
            if contextState == .synced {
                contextState = .pending
            }
        } else if contextState == .synced {
            wireContext = Self.wireEntries(from: items)
        } else {
            wireContext = nil
        }
    }

    /// Closes every still-streaming thought: applies its buffered text and clears the
    /// streaming flag. A thought has no explicit end event - it ends when the next
    /// item (message, tool call, permission request) begins, or when the turn does.
    private func finalizeOpenThoughts() {
        for index in items.indices {
            guard case .thought(var thought) = items[index], thought.isStreaming else {
                continue
            }
            if let buffered = streamBuffers.removeValue(forKey: thought.id) {
                thought.text = buffered
            }
            thought.isStreaming = false
            items[index] = .thought(thought)
            fireEntry(type: "thought", id: thought.id, data: ChatItem.thought(thought))
        }
    }

    // MARK: - Helpers

    /// Index of the message or thought with this id (the two item kinds that stream text).
    private func messageIndex(_ id: String) -> Int? {
        items.firstIndex {
            switch $0 {
            case .message(let message):  return message.id == id
            case .thought(let thought):  return thought.id == id
            default:                     return false
            }
        }
    }

    private func toolCallIndex(_ id: String) -> Int? {
        items.firstIndex {
            if case .toolCall(let call) = $0 {
                return call.id == id
            }
            return false
        }
    }

    private func streamingText(at index: Int) -> String? {
        switch items[index] {
        case .message(let message):  return message.text
        case .thought(let thought):  return thought.text
        default:                     return nil
        }
    }

    private func mutateStreamingText(at index: Int, _ transform: (inout ChatMessage) -> Void) {
        switch items[index] {
        case .message(var message):
            transform(&message)
            items[index] = .message(message)
        case .thought(var thought):
            transform(&thought)
            items[index] = .thought(thought)
        default:
            break
        }
    }

    // MARK: - Person-to-person (v2) routing helpers

    /// Inserts a complete message, or replaces one with the same id in place (server echo /
    /// out-of-order correction), preserving position. Returns whether the id already existed.
    @discardableResult
    private func upsertMessage(_ message: ChatMessage) -> Bool {
        if let index = anyItemIndex(message.id) {
            // Replace in place ONLY when the existing item is a message; a collision with a
            // different-typed item sharing an id is logged and left alone (never clobbered),
            // matching the tolerant posture of the in-place mutators.
            if case .message = items[index] {
                items[index] = .message(message.finalized)
            } else {
                logger.log("Chat messageReceived id '\(message.id)' collides with a non-message item; ignoring", .verbose)
            }
            return true
        }
        items.append(.message(message.finalized))
        return false
    }

    /// Inserts a file item, or replaces one with the same id in place. Returns whether it existed.
    @discardableResult
    private func upsertFile(_ file: ChatFile) -> Bool {
        if let index = anyItemIndex(file.id) {
            if case .file = items[index] {
                items[index] = .file(file)
            } else {
                logger.log("Chat fileAdded id '\(file.id)' collides with a non-file item; ignoring", .verbose)
            }
            return true
        }
        items.append(.file(file))
        return false
    }

    /// Re-keys the optimistic message `localID` to the server-assigned `serverID` in place, so every
    /// later server-keyed event (status, reactions, edit, delete) targets the right item. The transport
    /// MUST emit `.messageIDConfirmed` BEFORE any event keyed by `serverID`. Tolerant: an unknown /
    /// already-reconciled `localID` is a logged no-op; a `serverID` that already names a different item
    /// means the server also delivered the message as its own item, so the optimistic duplicate is dropped
    /// (the confirmation entry still fires, so a persisting host renames the localID row rather than orphaning it).
    ///
    /// The optimistic entry was already emitted as an `.entry` event under `localID` and the confirmed row is
    /// now `serverID`; the `messageIdConfirmed` entry lets a persisting host reconcile the two as a rename.
    private func reconcileMessageID(localID: String, serverID: String) {
        guard localID != serverID else { return }
        guard let index = anyItemIndex(localID), case .message(let message) = items[index] else {
            logger.log("Chat messageIDConfirmed for unknown/optimistic id '\(localID)'; ignoring", .verbose)
            return
        }
        if let existing = anyItemIndex(serverID), existing != index {
            items.remove(at: index)   // server already delivered this as its own item; drop the optimistic duplicate
            // Still fire the confirmation so a persisting host renames its optimistic `localID` row onto the
            // server one (idempotent upsert by id) rather than orphaning it - same signal as the re-key path.
            fireEntry(type: "messageIdConfirmed", id: serverID, data: MessageIDConfirmation(localID: localID, serverID: serverID))
            logger.log("Chat messageIDConfirmed serverID '\(serverID)' already present; dropped optimistic '\(localID)'", .verbose)
            return
        }
        items[index] = .message(message.reidentified(serverID))
        fireEntry(type: "messageIdConfirmed", id: serverID, data: MessageIDConfirmation(localID: localID, serverID: serverID))
    }

    /// Mutates a message by id in place and re-fires its entry as an update. Unknown id is a logged
    /// no-op (the v1 tolerant posture).
    private func mutateMessage(_ id: String, kind: String, _ transform: (inout ChatMessage) -> Void) {
        guard let index = anyItemIndex(id), case .message(var message) = items[index] else {
            logger.log("Chat \(kind) for unknown message '\(id)'; ignoring", .verbose)
            return
        }
        transform(&message)
        items[index] = .message(message)
        fireEntry(type: "message", id: id, data: ChatItem.message(message.finalized), updated: true)
    }

    /// Mutates a file by id in place; re-fires its entry only when its transfer reached a terminal
    /// state (`fireOnTerminal`), so per-tick progress does not spam the entry channel.
    private func mutateFile(_ id: String, fireEntry fireOnTerminal: Bool, _ transform: (inout ChatFile) -> Void) {
        guard let index = anyItemIndex(id), case .file(var file) = items[index] else {
            logger.log("Chat file update for unknown file '\(id)'; ignoring", .verbose)
            return
        }
        transform(&file)
        items[index] = .file(file)
        if fireOnTerminal {
            fireEntry(type: "file", id: id, data: ChatItem.file(file), updated: true)
        }
    }

    /// Applies a delivery/read watermark: every OWN message at or before `upToItemID` that carries a
    /// LOWER ladder status advances to `status`. A message with no status or a `failed` status is
    /// skipped (both have a nil watermarkRank), so the watermark never overwrites a failure and never
    /// invents a status. Unknown target id is a logged no-op.
    private func applyStatusWatermark(status: MessageStatus, upTo upToItemID: String) {
        guard let targetIndex = anyItemIndex(upToItemID) else {
            logger.log("Chat status watermark for unknown item '\(upToItemID)'; ignoring", .verbose)
            return
        }
        guard let newRank = status.watermarkRank else {
            return   // a watermark to `failed` is not a ladder move
        }
        for index in 0...targetIndex {
            guard case .message(var message) = items[index], isSelfMessage(message) else {
                continue
            }
            guard let currentRank = message.status?.watermarkRank, currentRank < newRank else {
                continue   // no status, failed, or already at/above the watermark
            }
            message.status = status
            items[index] = .message(message)
            fireEntry(type: "message", id: message.id, data: ChatItem.message(message.finalized), updated: true)
        }
    }

    /// Maintains the typing indicator for one sender, with a per-sender expiry failsafe so a lost
    /// "stopped typing" signal cannot pin the indicator forever.
    private func updateTypingIndicator(isTyping: Bool, senderID: String?, senderName: String?) {
        let key = senderID ?? "anon"
        if isTyping {
            if let index = typingParticipants.firstIndex(where: { $0.id == key }) {
                typingParticipants[index] = TypingParticipant(id: key, name: senderName)
            } else {
                typingParticipants.append(TypingParticipant(id: key, name: senderName))
            }
            scheduler.schedule(Self.typingExpiryKey(key), after: typingExpiry) { [weak self] in
                self?.removeTypingParticipant(key)
            }
        } else {
            removeTypingParticipant(key)
            scheduler.cancel(Self.typingExpiryKey(key))
        }
    }

    private func removeTypingParticipant(_ key: String) {
        typingParticipants.removeAll { $0.id == key }
    }

    /// Prepends an older history page (chronological order) to the top, updates the paging flags,
    /// and advances the id counter past any generated ids in the page (collision safety).
    private func prependHistory(_ older: [ChatItem], hasMore: Bool) {
        if !older.isEmpty {
            items.insert(contentsOf: older, at: 0)
            advanceLocalCounter(past: older)
        }
        hasEarlier = hasMore
        isLoadingEarlier = false
    }

    /// Schedules a debounced markRead when pinned to the bottom and active and the last incoming item
    /// advanced past what was last marked. Only when the transport backs read receipts.
    private func maybeScheduleReadMark() {
        guard capabilities.readReceipts, pinnedToBottom, sceneActive else {
            return
        }
        guard let target = lastIncomingItemID(), target != lastReadMarkItemID else {
            return
        }
        scheduler.schedule(Self.readMarkKey, after: readMarkDebounce) { [weak self] in
            self?.emitReadMark(upTo: target)
        }
    }

    private func emitReadMark(upTo target: String) {
        // Re-assert the guard at FIRE time, not just at schedule time: during the debounce window the
        // user may have scrolled away or the scene may have backgrounded, in which case the message
        // must NOT be marked read (a receipt-privacy bug otherwise).
        guard capabilities.readReceipts, pinnedToBottom, sceneActive else {
            return
        }
        guard anyItemIndex(target) != nil, target != lastReadMarkItemID else {
            return
        }
        lastReadMarkItemID = target
        let transport = self.transport
        Task { await transport?.send(.markRead(upToItemID: target)) }
    }

    /// The last transcript item from someone else (a message or file not authored by the local user);
    /// the target a read mark advances up to. Member / call events are not "read" targets.
    private func lastIncomingItemID() -> String? {
        for item in items.reversed() {
            switch item {
            case .message(let message) where !isSelfMessage(message): return message.id
            case .file(let file) where !isSelfFile(file):             return file.id
            default:                                                  continue
            }
        }
        return nil
    }

    /// Advances `localCounter` past any store-generated ids (user- / system- / error-N) in `items`,
    /// so a later generated item cannot collide with one already present (which would break
    /// ForEach identity and index lookups).
    private func advanceLocalCounter(past items: [ChatItem]) {
        let generatedPrefixes = ["user-", "system-", "error-"]
        let maxSuffix = items.compactMap { item -> Int? in
            let id = item.id
            for prefix in generatedPrefixes where id.hasPrefix(prefix) {
                return Int(id.dropFirst(prefix.count))
            }
            return nil
        }.max()
        if let maxSuffix {
            localCounter = max(localCounter, maxSuffix)
        }
    }

    // Self-authorship: role `.local`, or a senderID that resolves to a participant marked isSelf.
    private func isSelfMessage(_ message: ChatMessage) -> Bool {
        if message.role == .local {
            return true
        }
        if let senderID = message.senderID {
            return participants.first(where: { $0.id == senderID })?.isSelf == true
        }
        return false
    }

    private func isSelfFile(_ file: ChatFile) -> Bool {
        if file.role == .local {
            return true
        }
        if let senderID = file.senderID {
            return participants.first(where: { $0.id == senderID })?.isSelf == true
        }
        return false
    }

    private func anyItemIndex(_ id: String) -> Int? {
        items.firstIndex { $0.id == id }
    }

    private func item(_ id: String) -> ChatItem? {
        items.first { $0.id == id }
    }

    private func reactions(of id: String) -> [Reaction]? {
        if case .message(let message)? = item(id) {
            return message.reactions
        }
        return nil
    }

    /// Builds the reply reference for an optimistic reply: the original's id, a pre-truncated plain
    /// excerpt, and the resolved sender name.
    private func makeReplyRef(_ itemID: String) -> ReplyRef? {
        switch item(itemID) {
        case .message(let message):
            return ReplyRef(itemID: itemID, excerpt: replyExcerpt(message.text), senderName: resolvedSenderName(message))
        case .file(let file):
            return ReplyRef(itemID: itemID, excerpt: file.name, senderName: file.senderName)
        default:
            return nil
        }
    }

    private func replyExcerpt(_ text: String) -> String {
        let oneLine = text.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        return oneLine.count > 200 ? String(oneLine.prefix(200)) : oneLine
    }

    private func resolvedSenderName(_ message: ChatMessage) -> String? {
        if let name = message.senderName {
            return name
        }
        if let senderID = message.senderID {
            return participants.first(where: { $0.id == senderID })?.name
        }
        return nil
    }

    private func emit(_ event: ChatHostEvent) {
        hostEvents?(event)
    }

    deinit {
        eventTask?.cancel()
    }
}

private extension ChatMessage {
    /// A copy guaranteed non-streaming, for persistence / upsert (a P2P message arrives complete,
    /// but normalize defensively so a stored message is never marked streaming).
    var finalized: ChatMessage {
        guard isStreaming else {
            return self
        }
        var copy = self
        copy.isStreaming = false
        return copy
    }

    /// A copy with a new id (ChatMessage.id is a let). Used to re-key an optimistic message to its
    /// server-assigned id on `.messageIDConfirmed`.
    func reidentified(_ newID: String) -> ChatMessage {
        ChatMessage(id: newID, role: role, text: text, isStreaming: isStreaming,
                    senderID: senderID, senderName: senderName, avatarURL: avatarURL,
                    timestamp: timestamp, status: status, reactions: reactions,
                    editedAt: editedAt, replyTo: replyTo, deleted: deleted)
    }
}

/// The `messageIdConfirmed` entry payload: lets a persisting host (the `.entry` events) rename its stored
/// row from the optimistic `localID` to the server-assigned `serverID`.
private struct MessageIDConfirmation: Encodable {
    let localID: String
    let serverID: String
}
