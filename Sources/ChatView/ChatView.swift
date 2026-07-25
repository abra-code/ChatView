// Sources/ChatView/ChatView.swift
//
// The chat component's public SwiftUI surface: a transcript above a composer.
//
// Owns the @StateObject ChatStore (so the store's lifetime follows the view's
// identity), starts the session on appear, and tears it down on disappear. Renders
// the single-alignment transcript (every message leading / full-width, parties
// distinguished by tint + role label) and a composer whose submit policy is
// config-driven. Message bodies render as Markdown through the RichText component
// (M2). Agentic surfaces (M3) are transcript rows too: thoughts fold behind a
// disclosure, tool calls are status cards that mutate in place, and a pending
// permission request pins an approval card above the composer (an inline gate,
// not a window-modal sheet, so an embedded element never takes over the host
// window). Dual alignment and the M5 side panels arrive in later milestones;
// this view stays the same shape.

import SwiftUI
import RichText
import DiffView
import AsyncImageCache
#if canImport(AppKit)
import AppKit
#endif

public struct ChatView: View {

    @StateObject private var store: ChatStore
    private let config: ChatConfiguration

    private let bottomAnchor = "chat.bottom.anchor"
    // Scroll anchoring (P0-4): auto-scroll follows new content only while the user is pinned to the
    // bottom. When they scroll up to read back, auto-scroll suspends (streaming does not fight them)
    // and a "jump to latest" pill appears; returning to the bottom or tapping the pill re-pins.
    @State private var isPinnedToBottom = true
    private static let bottomThreshold: CGFloat = 24   // within this many points of the bottom counts as pinned
    // Turns each scroll / layout sample into a pin action (see ChatScrollPin.swift). A reference type in
    // @State so updating its running sample every frame does NOT redraw the view - only a pin flip does.
    @State private var pinTracker = ChatScrollPinTracker()
    // Defers + coalesces the geometry-driven chase: a .chase is decided inside the layout pass, where
    // a synchronous scrollTo can loop the display cycle into AppKit's layout-loop kill. Same
    // reference-in-@State trick as pinTracker (scheduling must not invalidate the view). See
    // ChatScrollChaser in ChatScrollPin.swift for the full crash mechanics.
    @State private var chaser = ChatScrollChaser()
    // The awaiting-reply spinner shows only if the first token has not arrived within this delay, so a
    // fast reply never flashes it. Driven by the body's .task(id:) tied to the awaiting condition.
    @State private var awaitingLongEnough = false
    private static let awaitingSpinnerDelay: Duration = .seconds(2)

    // Person-to-person (v2) interaction state (dual alignment only). Reply / edit put a banner above
    // the composer; delete confirms; a tapped reply quote scrolls to and briefly highlights the original.
    @State private var replyTarget: ReplyTarget?
    @State private var editTargetID: String?
    @State private var deleteTarget: ChatMessage?
    @State private var highlightedItemID: String?
    @State private var scrollRequest: String?
    // Paging: the id of the former top item, captured when a page is requested, so the scroll position
    // can be restored to it after older items prepend (no visual jump).
    @State private var pagingAnchorID: String?
    @StateObject private var audio = ChatAudioController()

    private struct ReplyTarget: Identifiable {
        let id: String
        let excerpt: String
        let sender: String?
    }

    public init(configuration: ChatConfiguration,
                logger: any ChatLogger = ConsoleChatLogger(),
                contentSource: (any ChatContentSource)? = nil,
                hostEvents: ChatHostEventSink? = nil) {
        self.config = configuration
        _store = StateObject(wrappedValue: ChatStore(config: configuration, logger: logger,
                                                     contentSource: contentSource,
                                                     hostEvents: hostEvents))
    }

    public var body: some View {
        VStack(spacing: 0) {
            if !store.plan.isEmpty && config.surfaces.plan != .hidden {
                PlanPanel(entries: store.plan, initiallyExpanded: config.surfaces.plan != .collapsed)
                Divider()
            }
            transcript
            if let request = store.pendingPermissions.first {
                Divider()
                PermissionCard(request: request) { optionID in
                    store.respondToPermission(request.id, optionID: optionID)
                }
            }
            // readOnly is the history-viewer mode: no composer, no slash-command menu (P0-2). The
            // status bar stays to show a restored usage total, but with no live session there are no
            // option menus.
            if !config.readOnly {
                let commandMatches = SlashCommandMenu.matches(draft: store.draft, commands: store.availableCommands)
                if !commandMatches.isEmpty {
                    Divider()
                    SlashCommandMenuView(matches: commandMatches) { command in
                        store.draft = "/\(command.name) "
                    }
                }
                Divider()
                composer
            }
            // The context indicator (an online/offline-style dot: does the model remember the
            // conversation shown?) rides on the status bar for a live, configured session; a
            // non-synced state forces the bar visible so "loads on next message" is never hidden.
            let contextState: ChatContextState? = (!config.readOnly && store.isConfigured) ? store.contextState : nil
            if store.usage != nil || !store.configOptions.isEmpty || (contextState ?? .synced) != .synced {
                Divider()
                SessionStatusBar(usage: store.usage, options: store.configOptions,
                                 contextState: contextState) { optionID, value in
                    store.setConfigOption(optionID, value: value)
                }
            }
        }
        .onAppear { store.start() }
        .onDisappear {
            store.teardown()
            audio.stop()   // a playing voice message must not outlive the view
        }
        .confirmationDialog("Delete this message?",
                            isPresented: Binding(get: { deleteTarget != nil },
                                                 set: { if !$0 { deleteTarget = nil } }),
                            presenting: deleteTarget) { message in
            Button("Delete", role: .destructive) {
                store.deleteMessage(itemID: message.id)
                deleteTarget = nil
            }
            Button("Cancel", role: .cancel) { deleteTarget = nil }
        }
        .task(id: isAwaitingReply) {
            // Delay the awaiting spinner so a fast reply never flashes it: show it only if the
            // awaiting state still holds after the delay. The id restarts this whenever the awaiting
            // condition flips, so a reply arriving within the delay cancels the pending show.
            guard isAwaitingReply else {
                awaitingLongEnough = false
                return
            }
            awaitingLongEnough = false
            try? await Task.sleep(for: Self.awaitingSpinnerDelay)
            if !Task.isCancelled {
                awaitingLongEnough = true
            }
        }
    }

    /// While an approval is pending, the composer input pauses (the Stop control stays live).
    private var permissionPending: Bool {
        !store.pendingPermissions.isEmpty
    }

    /// The awaiting-reply gap: a prompt is in flight but nothing has streamed yet. The spinner shows
    /// only once this has held for `awaitingSpinnerDelay` (gated by awaitingLongEnough in the body).
    private var isAwaitingReply: Bool {
        store.awaitingReply && !store.isStreaming
    }

    // MARK: - Transcript

    private var transcript: some View {
        GeometryReader { viewport in
            ScrollViewReader { proxy in
                ScrollView {
                    // Dual alignment (P2P / group) uses zero base spacing + per-run top padding so a
                    // run tightens; single alignment keeps the exact v1 spacing so it is pixel-identical.
                    LazyVStack(alignment: .leading, spacing: config.alignment == .dual ? 0 : 10) {
                        if config.alignment == .dual {
                            topPagingSentinel(viewport: viewport)
                            if store.isLoadingEarlier {
                                loadEarlierHeader
                            }
                            dualContent(maxBubbleWidth: max(120, (viewport.size.width - 24) * 0.75))
                            if !store.typingParticipants.isEmpty {
                                TypingIndicatorRow(names: store.typingParticipants.compactMap(\.name))
                                    .padding(.top, 6)
                            }
                        } else {
                            ForEach(store.items) { item in
                                diagnosedRow(for: item)
                            }
                        }
                        if isAwaitingReply && awaitingLongEnough {
                            awaitingIndicator
                        }
                        bottomSentinel(viewport: viewport)
                    }
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    // Scroll-invariant space the row diagnostics record their frames in (a name
                    // registration only; no layout effect when diagnostics are off).
                    .coordinateSpace(name: ChatViewDiagnostics.transcriptSpace)
                }
                .trackScrolledToBottom { distanceFromBottom, contentHeight, containerHeight in
                    updatePin(distanceFromBottom: distanceFromBottom,
                              contentHeight: contentHeight,
                              containerHeight: containerHeight,
                              proxy: proxy)
                }
                // Whether the READER is driving the scroll view, straight from the scroll view. The pin
                // otherwise has to infer that from offset algebra, which cannot tell a drag from the
                // scroll view moving its own offset under a re-measuring transcript.
                .trackScrollPhase { userDriven in
                    pinTracker.noteScrollPhase(userDriven: userDriven)
                }
                .onChange(of: store.items) { old, new in
                    // A prepended history page: restore the scroll to the anchored former-top item so the
                    // view does not jump (non-animated, same layout pass). Takes precedence over the pin.
                    if let anchor = pagingAnchorID, new.count > old.count, new.first?.id != old.first?.id {
                        pinTracker.noteProgrammaticScroll()
                        proxy.scrollTo(anchor, anchor: .top)
                        pagingAnchorID = nil
                        return
                    }
                    // Otherwise follow new content ONLY while pinned; reading back must not fight streaming.
                    // The follow is NON-animated so the geometry detector never observes the mid-animation
                    // state (content grown, offset lagging) and spuriously unpins during fast streaming.
                    // (updatePin also chases on the geometry change this triggers: a growth that arrives
                    // without an items change, e.g. an async row remeasure, is caught there.)
                    //
                    // Deferred one runloop turn through the SAME chaser as the geometry-driven chase, and
                    // for the same reason: a streaming turn mutates items once per delta, so a synchronous
                    // scrollTo here queues a scroll action on nearly every update, and SwiftUI applies
                    // those inside NSHostingView.layout - enough of them can land in one display cycle to
                    // exhaust the window's layout budget, which throws from
                    // -[NSWindow _postWindowNeedsUpdateConstraints] and kills the app. The 0.2.1 fix
                    // exempted this edge as "one-shot, cannot self-feed": true of the paging restore,
                    // onAppear and the pill, false of a stream. Coalescing to at most one scroll per turn
                    // keeps the follow immediate to the eye and bounded per cycle.
                    if isPinnedToBottom {
                        chaser.schedule {
                            // Re-checked at fire time: a geometry sample processed in between may have
                            // released the pin, and a reader must not be yanked back to the bottom.
                            if isPinnedToBottom {
                                scrollToBottom(proxy, animated: false, source: "items")
                            }
                        }
                    }
                }
                .onChange(of: isPinnedToBottom) { _, pinned in
                    store.setPinnedToBottom(pinned)
                }
                .onAppear {
                    // Loaded/restored transcripts start pinned at the latest entry.
                    scrollToBottom(proxy, animated: false, source: "appear")
                }
                .onChange(of: store.transcriptGeneration) { _, _ in
                    // A conversation was loaded in place (the transcript was replaced wholesale). The
                    // pin tracker's prior sample belongs to the old conversation, so reset it (else its
                    // stale heights net a bogus scroll-up and unpin), and start the new one pinned at
                    // the latest entry - onAppear does not refire for an in-place content swap.
                    pinTracker.reset()
                    isPinnedToBottom = true
                    scrollToBottom(proxy, animated: false, source: "generation")
                }
                .onChange(of: scrollRequest) { _, target in
                    // Jump to a tapped reply quote's original message (a brief highlight follows).
                    guard let target else { return }
                    pinTracker.noteProgrammaticScroll()
                    withAnimation(.easeInOut(duration: 0.2)) {
                        proxy.scrollTo(target, anchor: .center)
                    }
                    scrollRequest = nil
                }
                .overlay(alignment: .bottomTrailing) {
                    if !isPinnedToBottom {
                        jumpToLatestPill(proxy: proxy)
                    }
                }
                // Fade the pill in/out (the isPinnedToBottom flips happen outside withAnimation).
                .animation(.easeInOut(duration: 0.2), value: isPinnedToBottom)
            }
        }
    }

    /// The bottom-of-content marker: the scroll anchor plus, for the pre-macOS-15 fallback path, a
    /// GeometryReader that reports the transcript geometry the pin update needs - how far the bottom is
    /// below the fold, plus the content and container heights so a growth/resize can be told from a
    /// user scroll (the same three values `onScrollGeometryChange` yields directly on macOS 15+).
    private func bottomSentinel(viewport: GeometryProxy) -> some View {
        Color.clear
            .frame(height: 1)
            .id(bottomAnchor)
            .background(
                GeometryReader { marker in
                    Color.clear.preference(
                        key: SentinelMetricsKey.self,
                        value: SentinelMetrics(
                            // Points of content below the fold: marker sits at the very bottom of the
                            // content, so its global maxY beyond the viewport's is the overshoot.
                            distanceFromBottom: marker.frame(in: .global).maxY - viewport.frame(in: .global).maxY,
                            // The marker's y in the scroll-invariant content space is the total content
                            // height (it is the last element); grows as messages stream in.
                            contentHeight: marker.frame(in: .named(ChatViewDiagnostics.transcriptSpace)).maxY,
                            containerHeight: viewport.size.height))
                }
            )
    }

    /// A bottom-trailing pill that returns to (and re-pins) the latest entry.
    private func jumpToLatestPill(proxy: ScrollViewProxy) -> some View {
        Button {
            isPinnedToBottom = true
            scrollToBottom(proxy, source: "pill")
        } label: {
            Label("Jump to latest", systemImage: "arrow.down")
                .font(.callout.weight(.semibold))
                .labelStyle(.iconOnly)
                .padding(9)
                .background(.regularMaterial, in: Circle())
                .overlay(Circle().strokeBorder(.separator))
        }
        .buttonStyle(.plain)
        .help("Jump to latest")
        .padding(12)
        .transition(.opacity)
    }

    /// Reconciles the pin with the transcript geometry on every scroll / layout change, via the pure
    /// ChatScrollPinTracker. The core distinction it draws: content growing (streaming) or the view
    /// resizing both push the bottom off screen but are NOT the user reading back, so they chase the
    /// new bottom rather than unpin; only a genuine user scroll-up releases the pin. `distanceFromBottom`
    /// is points of content below the fold (<= threshold means the latest entry is on screen).
    /// Runs inside the layout pass (onScrollGeometryChange), so the chase it triggers is deferred a
    /// runloop turn through ChatScrollChaser - never a synchronous scrollTo from here.
    private func updatePin(distanceFromBottom: CGFloat, contentHeight: CGFloat,
                           containerHeight: CGFloat, proxy: ScrollViewProxy) {
        let decision = pinTracker.decide(isPinned: isPinnedToBottom, distanceFromBottom: distanceFromBottom,
                                         contentHeight: contentHeight, containerHeight: containerHeight,
                                         threshold: Self.bottomThreshold)
        ChatViewDiagnostics.pinSample(decision: "\(decision)", pinned: isPinnedToBottom,
                                      distanceFromBottom: distanceFromBottom, contentHeight: contentHeight,
                                      containerHeight: containerHeight,
                                      userScrollUp: pinTracker.lastUserScrollUp)
        switch decision {
        case .ignore, .keep:
            break
        case .unpin:
            isPinnedToBottom = false
        case .repin:
            isPinnedToBottom = true
        case .chase:
            // Deferred one runloop turn, coalesced across the burst of samples a settling layout
            // emits (see ChatScrollChaser). Never scroll synchronously here: this callback runs
            // inside the layout pass, and a scrollTo that re-dirties layout mid-pass can repeat
            // within one display cycle until AppKit's layout-loop guard kills the app.
            chaser.schedule {
                // Re-checked at fire time: a sample processed between schedule and fire may have
                // released the pin (reading back must not be yanked to the bottom).
                if isPinnedToBottom {
                    scrollToBottom(proxy, animated: false, source: "chase")
                }
            }
        }
    }

    private func scrollToBottom(_ proxy: ScrollViewProxy, animated: Bool = true, source: String = "") {
        ChatViewDiagnostics.pinScroll(source.isEmpty ? "bottom" : source)
        // Tell the tracker WE moved the viewport, so the samples the scroll view emits while it settles
        // are not mistaken for the user reading back (see ChatScrollPinTracker.noteProgrammaticScroll).
        pinTracker.noteProgrammaticScroll()
        if animated {
            withAnimation(.easeOut(duration: 0.15)) {
                proxy.scrollTo(bottomAnchor, anchor: .bottom)
            }
        } else {
            proxy.scrollTo(bottomAnchor, anchor: .bottom)
        }
    }

    /// A transcript row with the layout-shift geometry recorder attached (a no-op unless
    /// diagnostics are enabled; see ChatViewDiagnostics.swift).
    private func diagnosedRow(for item: ChatItem) -> some View {
        row(for: item)
            .chatRowDiagnostics(id: item.id, descriptor: ChatViewDiagnostics.describe(item))
            .id(item.id)
    }

    @ViewBuilder
    private func row(for item: ChatItem) -> some View {
        switch item {
        case .message(let message):
            MessageRow(message: message, config: config)
        case .thought(let thought):
            ThoughtRow(thought: thought, initiallyExpanded: config.surfaces.thoughts != .collapsed)
        case .toolCall(let call):
            ToolCallRow(call: call, compact: config.surfaces.toolCalls == .collapsed,
                        showsDiff: config.surfaces.diffs != .hidden)
        case .image(_, let role, let image):
            ImageRow(role: role, image: image, config: config)
        case .system(_, let text):
            Text(text)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .center)
        case .error(_, let text):
            Label(text, systemImage: "exclamationmark.triangle")
                .font(.caption)
                .foregroundStyle(.red)
                .frame(maxWidth: .infinity, alignment: .center)
        case .memberEvent, .callEvent, .file:
            // P2P (v2) rows (member / call captions, file / voice items) are built in P6.
            // No v1 document produces these items, so the placeholder never renders for v1.
            EmptyView()
        }
    }

    // MARK: - Dual-alignment transcript (P2P / group)

    /// The dual-alignment rows: each item placed by the pure ChatTranscriptLayout (run grouping +
    /// day separators), with a day-separator caption before an item that starts a new calendar day,
    /// and tighter spacing inside a run.
    @ViewBuilder
    private func dualContent(maxBubbleWidth: CGFloat) -> some View {
        ForEach(dualRows) { ctx in
            VStack(alignment: .leading, spacing: 4) {
                if ctx.info.startsNewDay, let date = ctx.timestamp {
                    DaySeparatorRow(date: date)
                }
                DualTranscriptRow(ctx: ctx, config: config, maxBubbleWidth: maxBubbleWidth,
                                  showsSenderNames: showsSenderNames, actions: dualActions,
                                  highlighted: highlightedItemID == ctx.id, audio: audio,
                                  onResend: { store.resendMessage(itemID: $0) })
            }
            .padding(.top, ctx.info.isFirstInRun ? 8 : 2)
            .frame(maxWidth: .infinity, alignment: .leading)
            .id(ctx.id)
        }
    }

    /// The gated message affordances handed to each dual row. Gating (feature AND capability) is read
    /// from the store; the closures set the composer's reply/edit banner, confirm a delete, toggle a
    /// reaction, or scroll to a quoted message.
    private var dualActions: DualRowActions {
        DualRowActions(
            canReply: store.canReply,
            canEdit: store.canEditMessages,
            canDelete: store.canDeleteMessages,
            canReact: store.canReact,
            reply: { beginReply($0) },
            edit: { beginEdit($0) },
            delete: { deleteTarget = $0 },
            toggleReaction: { store.toggleReaction(itemID: $0, emoji: $1) },
            jumpTo: { requestScroll(to: $0) },
            cancelTransfer: { store.cancelFileTransfer(itemID: $0) }
        )
    }

    /// The near-top detector for paging: a 1 pt marker at the very top of the transcript; when it comes
    /// within a page-trigger distance of the viewport top, request the previous history page (once).
    private func topPagingSentinel(viewport: GeometryProxy) -> some View {
        Color.clear
            .frame(height: 1)
            .background(
                GeometryReader { marker in
                    Color.clear.preference(
                        key: ScrolledNearTopKey.self,
                        value: marker.frame(in: .global).minY >= viewport.frame(in: .global).minY - 200)
                }
            )
            .onPreferenceChange(ScrolledNearTopKey.self) { nearTop in
                if nearTop {
                    requestEarlierPage()
                }
            }
    }

    private var loadEarlierHeader: some View {
        HStack {
            Spacer()
            ProgressView().controlSize(.small)
            Text("Loading earlier messages\u{2026}").font(.caption2).foregroundStyle(.secondary)
            Spacer()
        }
        .padding(.vertical, 6)
    }

    /// Requests the previous page, anchoring the current top item so the prepend does not jump the view.
    /// Gated on NOT being pinned to the bottom so a short seed (whose content fits the viewport, leaving
    /// the top sentinel near-top on first appear) does not auto-load history before the user scrolls up.
    private func requestEarlierPage() {
        guard !isPinnedToBottom, store.hasEarlier, !store.isLoadingEarlier else {
            return
        }
        pagingAnchorID = store.items.first?.id
        store.scrolledNearTop()
    }

    private func beginReply(_ message: ChatMessage) {
        editTargetID = nil
        let sender = resolvedName(role: message.role, senderID: message.senderID, explicit: message.senderName)
        replyTarget = ReplyTarget(id: message.id, excerpt: replyExcerpt(message.text), sender: sender)
    }

    private func beginEdit(_ message: ChatMessage) {
        replyTarget = nil
        editTargetID = message.id
        store.draft = message.text
    }

    private func requestScroll(to id: String) {
        // Jumping to a quoted message moves off the bottom: release the pin (and show the "jump to
        // latest" pill) so a live streaming turn does not immediately yank the reader back down.
        isPinnedToBottom = false
        scrollRequest = id
        highlightedItemID = id
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            if highlightedItemID == id {
                highlightedItemID = nil
            }
        }
    }

    private func replyExcerpt(_ text: String) -> String {
        let oneLine = text.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        return oneLine.count > 120 ? String(oneLine.prefix(120)) + "\u{2026}" : oneLine
    }

    /// Builds the per-item render contexts: run/day placement from ChatTranscriptLayout, plus resolved
    /// sender identity (message overrides -> participant roster -> role default) and self-authorship.
    private var dualRows: [DualRowContext] {
        let items = store.items
        let inputs = items.map { item -> ChatTranscriptLayout.Input in
            switch item {
            case .message(let message):
                return ChatTranscriptLayout.Input(senderKey: senderKey(role: message.role, senderID: message.senderID),
                                                  groupable: true, timestamp: ChatTimestamp.parse(message.timestamp))
            case .image(_, let role, _):
                return ChatTranscriptLayout.Input(senderKey: senderKey(role: role, senderID: nil),
                                                  groupable: true, timestamp: nil)
            case .file(let file):
                return ChatTranscriptLayout.Input(senderKey: senderKey(role: file.role, senderID: file.senderID),
                                                  groupable: true, timestamp: ChatTimestamp.parse(file.timestamp))
            default:
                // system / error / member / call / thought / toolCall: never grouped; unique key.
                return ChatTranscriptLayout.Input(senderKey: item.id, groupable: false,
                                                  timestamp: nonGroupableTimestamp(item))
            }
        }
        let layout = ChatTranscriptLayout.layout(inputs)
        return zip(items, layout).map { item, info in buildContext(item: item, info: info) }
    }

    private func buildContext(item: ChatItem, info: ChatTranscriptLayout.Info) -> DualRowContext {
        switch item {
        case .message(let message):
            return DualRowContext(id: item.id, item: item, info: info,
                                  isSelf: isSelf(role: message.role, senderID: message.senderID),
                                  senderName: resolvedName(role: message.role, senderID: message.senderID, explicit: message.senderName),
                                  avatarURL: resolvedAvatar(senderID: message.senderID, explicit: message.avatarURL),
                                  timestamp: ChatTimestamp.parse(message.timestamp))
        case .image(_, let role, _):
            return DualRowContext(id: item.id, item: item, info: info,
                                  isSelf: isSelf(role: role, senderID: nil),
                                  senderName: resolvedName(role: role, senderID: nil, explicit: nil),
                                  avatarURL: nil, timestamp: nil)
        case .file(let file):
            return DualRowContext(id: item.id, item: item, info: info,
                                  isSelf: isSelf(role: file.role, senderID: file.senderID),
                                  senderName: resolvedName(role: file.role, senderID: file.senderID, explicit: file.senderName),
                                  avatarURL: resolvedAvatar(senderID: file.senderID, explicit: nil),
                                  timestamp: ChatTimestamp.parse(file.timestamp))
        default:
            return DualRowContext(id: item.id, item: item, info: info, isSelf: false,
                                  senderName: nil, avatarURL: nil, timestamp: nonGroupableTimestamp(item))
        }
    }

    private func nonGroupableTimestamp(_ item: ChatItem) -> Date? {
        switch item {
        case .memberEvent(let event): return ChatTimestamp.parse(event.timestamp)
        case .callEvent(let event):   return ChatTimestamp.parse(event.timestamp)
        default:                      return nil
        }
    }

    // Sender resolution (mirrors the store): self is role `.local` or a senderID marked isSelf in the roster.
    private func isSelf(role: ChatRole, senderID: String?) -> Bool {
        if role == .local {
            return true
        }
        if let senderID {
            return store.participants.first(where: { $0.id == senderID })?.isSelf == true
        }
        return false
    }

    private func senderKey(role: ChatRole, senderID: String?) -> String {
        if isSelf(role: role, senderID: senderID) {
            return "self"
        }
        return senderID ?? role.rawValue
    }

    private func resolvedName(role: ChatRole, senderID: String?, explicit: String?) -> String? {
        if let explicit, !explicit.isEmpty {
            return explicit
        }
        if let senderID, let participant = store.participants.first(where: { $0.id == senderID }) {
            return participant.name
        }
        let label = config.style(for: role).label
        return label.isEmpty ? nil : label
    }

    private func resolvedAvatar(senderID: String?, explicit: String?) -> String? {
        if let explicit, !explicit.isEmpty {
            return explicit
        }
        if let senderID {
            return store.participants.first(where: { $0.id == senderID })?.avatarURL
        }
        return nil
    }

    /// Show a sender-name label above the first message of a run when role labels are on, or when the
    /// conversation has more than one non-self participant (a group).
    private var showsSenderNames: Bool {
        if config.showRoleLabels {
            return true
        }
        return store.participants.filter { $0.isSelf != true }.count > 1
    }

    // Shown in the gap between submitting a prompt and the first streamed reply event: a spinner
    // styled like a nascent assistant message (role label + tinted bubble), so the transcript
    // reflects that the model is working before the first token arrives. Once anything streams
    // (isStreaming) or the turn ends, the store clears awaitingReply and this is gone.
    private var awaitingIndicator: some View {
        VStack(alignment: .leading, spacing: 2) {
            if config.showRoleLabels {
                let label = config.style(for: .agent).label
                if !label.isEmpty {
                    Text(label).font(.caption).foregroundStyle(.secondary)
                }
            }
            ProgressView()
                .controlSize(.small)
                .padding(10)
                .background(ChatTint.color(for: config.style(for: .agent).tint).opacity(0.12),
                            in: RoundedRectangle(cornerRadius: 10))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .id("chat.awaiting.indicator")
    }

    // MARK: - Composer

    @ViewBuilder
    private var composer: some View {
        VStack(spacing: 4) {
            connectionBanner
            composerBanner
            HStack(alignment: .bottom, spacing: 8) {
                if store.canAttach {
                    Button { store.triggerAttach() } label: {
                        Image(systemName: "paperclip").imageScale(.large)
                    }
                    .help("Attach")
                    .disabled(permissionPending)
                }
                inputField
                if store.isStreaming || store.awaitingReply {
                    // Stop is live during the awaiting gap too, so a slow/hung first token is cancellable.
                    Button(role: .destructive) { store.stop() } label: {
                        Image(systemName: "stop.circle.fill").imageScale(.large)
                    }
                    .help("Stop")
                    .keyboardShortcut(".", modifiers: .command)
                } else {
                    sendButton
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .buttonStyle(.borderless)
        // Also disabled until a host has injected a viable states["config"] and the transport is
        // live (isConfigured): the element is inert until configured, so the composer never lets a
        // user type into a void. A reportsConnectionState transport additionally gates on connectivity
        // (isConnectionReady); a v1 / agent transport leaves that always true.
        .disabled(!config.inputEnabled || !store.isConfigured || !store.isConnectionReady)
    }

    // A one-line connectivity notice above the composer, shown only while a reportsConnectionState
    // transport is not connected (so the disabled composer is explained). Nothing renders - and no
    // vertical space is taken - for a v1 / agent transport or once connected, so the v1 composer is
    // unchanged.
    @ViewBuilder
    private var connectionBanner: some View {
        if let text = store.connectionBannerText {
            Text(text)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity)
        }
    }

    // The reply / edit indicator above the composer, with a cancel button. Nothing renders (and no
    // vertical space is taken) when neither is active, so the v1 composer is unchanged.
    @ViewBuilder
    private var composerBanner: some View {
        if let reply = replyTarget {
            banner(icon: "arrowshape.turn.up.left", title: reply.sender.map { "Replying to \($0)" } ?? "Replying",
                   detail: reply.excerpt) {
                replyTarget = nil
            }
        } else if editTargetID != nil {
            banner(icon: "pencil", title: "Editing message", detail: nil) {
                editTargetID = nil
                store.draft = ""
            }
        }
    }

    private func banner(icon: String, title: String, detail: String?, cancel: @escaping () -> Void) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.caption.weight(.medium))
                if let detail, !detail.isEmpty {
                    Text(detail).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer(minLength: 0)
            Button { cancel() } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
                .buttonStyle(.plain)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Color.secondary.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
    }

    /// Submits the composer, honoring an active edit (emit editMessage) or reply (send with replyTo);
    /// a plain submit is byte-identical to the v1 path.
    private func submit() {
        let text = store.draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            return
        }
        if let editID = editTargetID {
            store.editMessage(itemID: editID, newText: text)
            store.draft = ""
            editTargetID = nil
        } else {
            store.submitDraft(replyTo: replyTarget?.id)
            replyTarget = nil
        }
    }

    @ViewBuilder
    private var sendButton: some View {
        let button = Button { submit() } label: {
            Image(systemName: "arrow.up.circle.fill").imageScale(.large)
        }
        .help("Send")
        .disabled(store.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || permissionPending)

        // modifier-return: the multiline editor consumes plain Return (newline), so the Send button
        // submits on Cmd+Return. return / shift-return-newline: the growing field's onSubmit
        // already handles Return, so the button takes no Return shortcut (which would double-submit).
        if config.submitOn == .modifierReturn {
            button.keyboardShortcut(.return, modifiers: .command)
        } else {
            button
        }
    }

    @ViewBuilder
    private var inputField: some View {
        if config.submitOn == .modifierReturn {
            multilineField
                .disabled(permissionPending)
        } else {
            // Return-submits composer: a vertical-axis TextField, so a long draft wraps and grows
            // the field line-by-line (up to 8 lines, scrolling internally beyond) instead of
            // panning a single cramped line. Return still submits via onSubmit - on macOS a
            // vertical TextField's Return commits rather than inserting a newline, which is
            // exactly this policy (and why the modifier-return field cannot use it). On iOS the
            // software return key inserts a newline instead; the send button remains the submit
            // affordance there, the platform's chat idiom.
            TextField(config.placeholder, text: $store.draft, axis: .vertical)
                .textFieldStyle(.plain)
                .lineLimit(1...8)
                // Same intrinsic-width clamp as the multiline field's mirror stack: without it a
                // fitting-size host would widen with the draft's longest unbreakable run.
                .frame(idealWidth: 240, maxWidth: .infinity)
                .onSubmit { submit() }
                .disabled(permissionPending)
        }
    }

    // Multiline composer: a TextEditor, so plain Return inserts a newline (its natural behavior on
    // macOS and iOS) and Cmd+Return (the Send button's shortcut) submits. A TextField(axis: .vertical)
    // is deliberately NOT used here: on macOS its Return commits and selects the text instead of
    // inserting a newline. TextEditor has no placeholder, so an overlaid Text stands in when empty.
    //
    // A TextEditor is a scroll view with no intrinsic content height, so hidden Text mirrors size
    // the field instead: a literal three-line mirror sets the floor (agent prompts are usually
    // multi-line, so the field invites more than one line up front; a lineLimit lower bound does
    // not reserve space on a plain Text) and a mirror of the draft grows the field with its
    // content, capped at eight lines so a long prompt never swallows the transcript - past the
    // cap the editor scrolls internally, exactly as before. The clamps live in the mirrors' own
    // text metrics, NOT in a frame(maxHeight:), which would stretch to the proposal instead of
    // hugging the content.
    private var multilineField: some View {
        ZStack(alignment: .topLeading) {
            Group {
                Text(verbatim: " \n \n ")               // the three-line floor
                Text(verbatim: draftSizingMirror)       // grows the field with the draft
                    .lineLimit(...8)
            }
            .opacity(0)
            .accessibilityHidden(true)
            .allowsHitTesting(false)
            if store.draft.isEmpty {
                Text(config.placeholder)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)   // a long placeholder in a narrow column must not outgrow the floor
                    .allowsHitTesting(false)
            }
        }
        .font(.body)
        // idealWidth bounds the mirror's contribution to the view's intrinsic width: without it, a
        // host that sizes to the content's fitting size (a popover, an unconstrained Auto Layout
        // container) would widen with the draft's longest unbreakable run - a pasted paragraph
        // could report thousands of points. Real layouts propose concrete widths and are unaffected.
        .frame(idealWidth: 240, maxWidth: .infinity, alignment: .topLeading)
        .padding(.horizontal, 5)
        .padding(.trailing, Self.editorScrollerReserve)
        .padding(.vertical, Self.editorVerticalInset)
        .overlay(
            TextEditor(text: $store.draft)
                .font(.body)
                .scrollContentBackground(.hidden)
        )
    }

    // The mirror's vertical padding must equal the editor's own internal text inset, or the
    // difference shows up as a permanent blank row at the bottom of the field. UITextView insets
    // its text 8pt top and bottom; macOS's NSTextView-backed TextEditor uses no vertical inset,
    // so 8 there measured the field one line-height too tall.
    #if os(macOS)
    private static let editorVerticalInset: CGFloat = 0
    #else
    private static let editorVerticalInset: CGFloat = 8
    #endif

    // With legacy scrollers (Show scroll bars: Always, or a mouse connected) the editor's scroll
    // view reserves the scroller width even when nothing overflows, so its text wraps that much
    // narrower than the field. The mirror must measure at the same wrap width or a draft whose
    // last word falls in that band wraps one line further in the editor than was measured and
    // scrolls a line early. Overlay scrollers reserve nothing. Read per body evaluation, so a
    // style change is picked up on the next keystroke.
    #if os(macOS)
    private static var editorScrollerReserve: CGFloat {
        NSScroller.preferredScrollerStyle == .legacy
            ? NSScroller.scrollerWidth(for: .regular, scrollerStyle: .legacy)
            : 0
    }
    #else
    private static let editorScrollerReserve: CGFloat = 0
    #endif

    /// The draft as the sizing mirror measures it. The editor shows the caret on a new empty line
    /// after a trailing newline; a trailing space anchors that line in the mirror in case Text
    /// measures the bare newline as zero-height (defensive - current macOS Text already reserves
    /// it, so this is a no-op there, but that behavior is not contractual). Character.isNewline
    /// (not hasSuffix("\n")) so CRLF-terminated pastes anchor too - Swift treats "\r\n" as one
    /// grapheme, which hasSuffix("\n") misses.
    private var draftSizingMirror: String {
        store.draft.last?.isNewline == true ? store.draft + " " : store.draft
    }
}

// MARK: - Scroll-to-bottom tracking (P0-4)

/// The transcript geometry the pin update consumes on the pre-macOS-15 fallback path (the macOS 15+
/// path gets the same three values straight from `onScrollGeometryChange`). Emitted by the bottom
/// sentinel; the last (bottom-most) sentinel wins. The default encodes "the bottom is far off screen":
/// when the LazyVStack de-materializes the off-screen sentinel (the user scrolled far up, so the view
/// is already unpinned), the pin update sees a huge distance and simply stays unpinned - it never
/// re-pins and yanks the reader back on the next streaming delta.
private struct SentinelMetrics: Equatable, Sendable {
    var distanceFromBottom: CGFloat
    var contentHeight: CGFloat
    var containerHeight: CGFloat
}

private struct SentinelMetricsKey: PreferenceKey {
    static let defaultValue = SentinelMetrics(distanceFromBottom: .greatestFiniteMagnitude,
                                              contentHeight: 0, containerHeight: 0)
    static func reduce(value: inout SentinelMetrics, nextValue: () -> SentinelMetrics) {
        value = nextValue()
    }
}

/// Whether the transcript's top is within the paging-trigger distance of the viewport top. Emitted by
/// the top sentinel; drives the load-earlier request. Defaults FALSE so a de-materialized sentinel does
/// not spuriously trigger paging.
private struct ScrolledNearTopKey: PreferenceKey {
    static let defaultValue = false
    static func reduce(value: inout Bool, nextValue: () -> Bool) {
        value = nextValue()
    }
}

private extension View {
    /// Reports the transcript geometry the pin update needs on every scroll / layout change: distance
    /// of the bottom below the fold, plus the content and container heights (so a growth / resize can
    /// be told from a user scroll). Uses the precise `onScrollGeometryChange` on macOS 15+ / iOS 18+ /
    /// visionOS 2+, and the `SentinelMetricsKey` preference (emitted by the bottom sentinel) otherwise.
    @ViewBuilder
    func trackScrolledToBottom(
        update: @escaping (_ distanceFromBottom: CGFloat, _ contentHeight: CGFloat, _ containerHeight: CGFloat) -> Void
    ) -> some View {
        if #available(macOS 15.0, iOS 18.0, visionOS 2.0, *) {
            onScrollGeometryChange(for: SentinelMetrics.self) { geometry in
                SentinelMetrics(
                    distanceFromBottom: geometry.contentSize.height
                        - (geometry.contentOffset.y + geometry.containerSize.height),
                    contentHeight: geometry.contentSize.height,
                    containerHeight: geometry.containerSize.height)
            } action: { _, metrics in
                update(metrics.distanceFromBottom, metrics.contentHeight, metrics.containerHeight)
            }
        } else {
            onPreferenceChange(SentinelMetricsKey.self) { metrics in
                update(metrics.distanceFromBottom, metrics.contentHeight, metrics.containerHeight)
            }
        }
    }

    /// Reports whether the USER is currently driving the scroll view - finger or wheel on it, or the
    /// momentum that follows. That is the one unambiguous answer to the question the pin's offset
    /// algebra can only infer, and it is what lets a genuine scroll-up be believed on its first sample
    /// even while a streaming transcript re-measures around it.
    ///
    /// `.animating` is deliberately NOT user-driven: that is the phase of the transcript's own
    /// scroll-to-bottom, whose after-effects are exactly what the pin must not mistake for the reader.
    /// macOS 15+ / iOS 18+ / visionOS 2+ only; the older baseline never reports, so the pin keeps its
    /// heuristics there rather than losing the ability to unpin at all.
    @ViewBuilder
    func trackScrollPhase(update: @escaping (_ userDriven: Bool) -> Void) -> some View {
        if #available(macOS 15.0, iOS 18.0, visionOS 2.0, *) {
            onScrollPhaseChange { _, phase in
                switch phase {
                case .tracking, .interacting, .decelerating:
                    update(true)
                case .idle, .animating:
                    update(false)
                @unknown default:
                    update(false)
                }
            }
        } else {
            self
        }
    }
}

// MARK: - Message row (single alignment)

private struct MessageRow: View {
    let message: ChatMessage
    let config: ChatConfiguration

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            if config.showRoleLabels {
                let label = config.style(for: message.role).label
                if !label.isEmpty {
                    Text(label).font(.caption).foregroundStyle(.secondary)
                }
            }
            content
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
                .background(tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // Message text is rendered as Markdown by RichText: the shared cross-platform component lays
    // the whole message out in ONE selectable, self-sizing text view (headings, code, quotes, lists,
    // GFM tables, inline styling, links, inline images). A streaming row re-renders on each coalesced
    // flush; RichText's parser is streaming-safe (an unterminated span renders as literal text and
    // an open code fence renders as a growing code block), so no pre-balancing of the buffer is needed.
    // A streaming row with no text yet shows an ellipsis so the bubble has height.
    @ViewBuilder private var content: some View {
        if message.text.isEmpty && message.isStreaming {
            Text("\u{2026}").foregroundStyle(.secondary)
        } else {
            RichText(markdown: message.text)
        }
    }

    private var tint: Color {
        ChatTint.color(for: config.style(for: message.role).tint)
    }
}

// MARK: - Thought row (agentic reasoning)

// A streamed reasoning item, visually distinct from answer text: folded behind a small
// disclosure (per surfaces.thoughts; "collapsed" is the default), secondary styling.
// The label reads "Thinking..." while the thought streams and "Thoughts" once closed.
private struct ThoughtRow: View {
    let thought: ChatMessage
    @State private var expanded: Bool

    init(thought: ChatMessage, initiallyExpanded: Bool) {
        self.thought = thought
        _expanded = State(initialValue: initiallyExpanded)
    }

    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            Group {
                if thought.text.isEmpty && thought.isStreaming {
                    Text("\u{2026}").foregroundStyle(.secondary)
                } else {
                    RichText(markdown: thought.text).opacity(0.75)
                }
            }
            .padding(.top, 4)
        } label: {
            Label(thought.isStreaming ? "Thinking\u{2026}" : "Thoughts", systemImage: "brain")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Slash-command menu (agentic, M5)

/// The composer's slash-command menu model: active while the draft is a lone, partial
/// first token beginning with "/" (no whitespace typed yet) and an advertised command
/// name has that prefix. "/" alone lists everything. Internal (not private) so tests
/// can pin the matching.
enum SlashCommandMenu {
    static func matches(draft: String, commands: [SlashCommand]) -> [SlashCommand] {
        guard !commands.isEmpty, draft.hasPrefix("/") else {
            return []
        }
        let token = draft.dropFirst()
        guard !token.contains(where: \.isWhitespace) else {
            return []
        }
        let prefix = token.lowercased()
        return commands.filter { $0.name.lowercased().hasPrefix(prefix) }
    }
}

// The menu itself: pinned between the transcript and the composer while matches exist
// (mirroring the permission card's placement). Selection fills the draft with
// "/name " - the command still sends as ordinary prompt text. Tap-driven for now;
// keyboard navigation (arrows + Tab) is a later refinement.
private struct SlashCommandMenuView: View {
    let matches: [SlashCommand]
    let select: (SlashCommand) -> Void

    /// A menu, not a browser: only the top few matches show (typing narrows them).
    private static let visibleLimit = 5

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(matches.prefix(Self.visibleLimit)) { command in
                Button {
                    select(command)
                } label: {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text("/\(command.name)")
                            .font(.system(.callout, design: .monospaced).weight(.medium))
                        Text(command.description)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                        Spacer(minLength: 0)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 12)
                .padding(.vertical, 5)
            }
            if matches.count > Self.visibleLimit {
                Text("\(matches.count - Self.visibleLimit) more\u{2026} keep typing to narrow")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 3)
            }
        }
        .padding(.vertical, 4)
    }
}

// MARK: - Plan panel (agentic, M5)

// The agent's evolving task list (ACP `plan`), pinned ABOVE the transcript as a status
// surface - never interleaved with chat (surfaces.plan: panel default, expanded /
// collapsed, folded / hidden). The agent re-emits the whole plan as it works, so rows
// update in place; the label carries a completed-count summary for the folded state.
private struct PlanPanel: View {
    let entries: [PlanEntry]
    @State private var expanded: Bool

    init(entries: [PlanEntry], initiallyExpanded: Bool) {
        self.entries = entries
        _expanded = State(initialValue: initiallyExpanded)
    }

    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(entries) { entry in
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        statusIcon(entry.status)
                        Text(entry.content)
                            .font(.caption)
                            .strikethrough(entry.status == .completed)
                            .foregroundStyle(entry.status == .completed ? Color.secondary : Color.primary)
                    }
                }
            }
            .padding(.top, 4)
            .frame(maxWidth: .infinity, alignment: .leading)
        } label: {
            Label("Plan (\(completedCount)/\(entries.count))", systemImage: "checklist")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    private var completedCount: Int {
        entries.filter { $0.status == .completed }.count
    }

    @ViewBuilder
    private func statusIcon(_ status: PlanEntry.Status) -> some View {
        switch status {
        case .pending:
            Image(systemName: "circle")
                .font(.caption)
                .foregroundStyle(.secondary)
        case .inProgress:
            ProgressView()
                .controlSize(.mini)
        case .completed:
            Image(systemName: "checkmark.circle.fill")
                .font(.caption)
                .foregroundStyle(.green)
        }
    }
}

// MARK: - Session status bar (agentic, M5)

// A thin status line under the composer: the context indicator (whether the model
// remembers the conversation shown - it may load lazily, on the next send), the
// session's model / mode (from the agent's session-start config options), and token /
// cost usage when the agent reports it. An option with several choices is a menu -
// selecting sends .setConfigOption, and the display updates when the transport
// confirms (never optimistically, so a failed change needs no revert). Single-choice
// options render as plain text.
private struct SessionStatusBar: View {
    let usage: UsageInfo?
    let options: [SessionConfigOption]
    let contextState: ChatContextState?
    let select: (String, String) -> Void

    var body: some View {
        HStack(spacing: 12) {
            ForEach(options) { option in
                if option.options.count > 1 {
                    Menu {
                        ForEach(option.options, id: \.value) { choice in
                            Button {
                                select(option.id, choice.value)
                            } label: {
                                if choice.value == option.currentValue {
                                    Label(choice.name, systemImage: "checkmark")
                                } else {
                                    Text(choice.name)
                                }
                            }
                        }
                    } label: {
                        Text("\(option.name): \(option.currentChoiceName ?? option.currentValue)")
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    .menuStyle(.button)
                    .buttonStyle(.borderless)
                    .fixedSize()
                } else {
                    Text("\(option.name): \(option.currentChoiceName ?? option.currentValue)")
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            Spacer()
            if let usage {
                Text(usageText(usage))
                    .monospacedDigit()
                    .lineLimit(1)
            }
            // Right-aligned, under the message field: the trailing edge of the status line.
            if let contextState {
                contextIndicator(contextState)
            }
        }
        .font(.caption2)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
    }

    /// The context dot + caption. Green = the model remembers the conversation shown; orange =
    /// it loads with the next message (a deferred restore, or a re-sync after a cancelled turn);
    /// gray = an intentionally fresh context behind a displayed transcript (Read Only).
    private func contextIndicator(_ state: ChatContextState) -> some View {
        HStack(spacing: 4) {
            Circle()
                .fill(indicatorColor(state))
                .frame(width: 7, height: 7)
            Text(indicatorLabel(state))
                .lineLimit(1)
        }
        .help(indicatorHelp(state))
        .accessibilityElement(children: .combine)
    }

    private func indicatorColor(_ state: ChatContextState) -> Color {
        switch state {
        case .synced:  return .green
        case .pending: return .orange
        case .fresh:   return .secondary
        }
    }

    private func indicatorLabel(_ state: ChatContextState) -> String {
        switch state {
        case .synced:  return "Context loaded"
        case .pending: return "Context on next message"
        case .fresh:   return "Fresh context"
        }
    }

    private func indicatorHelp(_ state: ChatContextState) -> String {
        switch state {
        case .synced:  return "The model remembers the conversation shown."
        case .pending: return "The conversation shown will load into the model with your next message."
        case .fresh:   return "The transcript is shown for reference; the model starts with a fresh context."
        }
    }

    private func usageText(_ usage: UsageInfo) -> String {
        var parts: [String] = []
        if let size = usage.size, size > 0 {
            parts.append("\(Self.compact(usage.used)) / \(Self.compact(size)) tokens")
        } else {
            parts.append("\(Self.compact(usage.used)) tokens")
        }
        if let amount = usage.costAmount, amount > 0 {
            let currency = usage.costCurrency ?? ""
            if currency == "USD" {
                parts.append(String(format: "$%.4f", amount))
            } else {
                parts.append(String(format: "%.4f %@", amount, currency))
            }
        }
        return parts.joined(separator: " \u{00B7} ")
    }

    private static func compact(_ value: Int) -> String {
        if value >= 1000 {
            return String(format: "%.1fk", Double(value) / 1000)
        }
        return "\(value)"
    }
}

/// Caps bulk tool detail for rendering: a tool call's content is often a whole file or
/// a long command output, and the card is a preview of the call, not a file viewer -
/// uncapped text would also make the transcript's attributed-string layout crawl.
/// Internal (not private) so tests can pin the behavior.
enum ToolDetailText {
    static let cap = 4000

    static func capped(_ text: String) -> String {
        guard text.count > cap else {
            return text
        }
        return text.prefix(cap) + "\n\u{2026} (truncated, \(text.count - cap) more characters)"
    }
}

// MARK: - Tool-call card (agentic)

// One tool invocation: a kind icon, the title, a status indicator, and - when the call
// carries content, a diff, or raw input / output - a disclosure with the detail. The
// card mutates in place as tool_call_update events arrive (same item id). The detail
// ALWAYS starts folded, whatever surfaces.toolCalls says: tool content is bulk material
// (a whole file read, a long command output), and auto-expanding it floods the
// transcript - the mainstream agentic UX shows the fact of the call, not its payload.
// "collapsed" additionally shrinks the card to a compact caption row (Thoughts-style).
// Expanded detail renders through ToolDetailText.capped so a megabyte read stays a
// preview. Diffs render through the standalone DiffView component (a line diff with hunks
// and old / new line-number gutters); surfaces.diffs "hidden" drops them from the card.
private struct ToolCallRow: View {
    let call: ToolCallModel
    let compact: Bool     // surfaces.toolCalls == .collapsed
    let showsDiff: Bool   // surfaces.diffs != .hidden
    @State private var expanded = false

    var body: some View {
        let column = VStack(alignment: .leading, spacing: 6) {
            header
            if expanded && hasDetail {
                detail
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)

        return Group {
            if compact {
                column
            } else {
                column
                    .padding(10)
                    .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
                    .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.secondary.opacity(0.15)))
            }
        }
    }

    private var header: some View {
        HStack(spacing: 6) {
            Image(systemName: kindIcon)
                .foregroundStyle(.secondary)
            Text(call.title)
                .font(compact ? .caption : .callout.weight(.medium))
                .foregroundStyle(compact ? Color.secondary : Color.primary)
                .lineLimit(compact ? 1 : 2)
            if hasDetail {
                Image(systemName: "chevron.right")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .rotationEffect(expanded ? .degrees(90) : .zero)
            }
            Spacer(minLength: 8)
            status
        }
        .contentShape(Rectangle())
        .onTapGesture {
            if hasDetail {
                withAnimation(.easeOut(duration: 0.15)) { expanded.toggle() }
            }
        }
    }

    @ViewBuilder
    private var detail: some View {
        if !call.contentText.isEmpty {
            RichText(markdown: ToolDetailText.capped(call.contentText))
        }
        if showsDiff, let diff = call.diff {
            Text(diff.path)
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
            DiffView(oldText: diff.oldText ?? "", newText: diff.newText)
        }
        if let rawInput = call.rawInput {
            labeledCode("Input", ToolDetailText.capped(rawInput))
        }
        if let rawOutput = call.rawOutput {
            labeledCode("Output", ToolDetailText.capped(rawOutput))
        }
    }

    private var hasDetail: Bool {
        !call.contentText.isEmpty || (showsDiff && call.diff != nil) || call.rawInput != nil || call.rawOutput != nil
    }

    @ViewBuilder
    private func labeledCode(_ title: String, _ text: String) -> some View {
        Text(title)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.secondary)
        codeBlock(text)
    }

    private func codeBlock(_ text: String) -> some View {
        Text(text)
            .font(.system(.caption, design: .monospaced))
            .textSelection(.enabled)
            .padding(6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
    }

    private var kindIcon: String {
        switch call.kind {
        case .read:     return "doc.text"
        case .edit:     return "pencil"
        case .delete:   return "trash"
        case .move:     return "folder"
        case .search:   return "magnifyingglass"
        case .execute:  return "terminal"
        case .think:    return "brain"
        case .fetch:    return "network"
        case .other:    return "wrench.and.screwdriver"
        }
    }

    @ViewBuilder
    private var status: some View {
        switch call.status {
        case .pending:
            Image(systemName: "clock")
                .foregroundStyle(.secondary)
        case .inProgress:
            ProgressView()
                .controlSize(.small)
        case .completed:
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
        case .failed:
            Image(systemName: "xmark.circle.fill")
                .foregroundStyle(.red)
        }
    }
}

// MARK: - Permission card (agentic approval gate)

// The head of the pending-permission queue, pinned between the transcript and the
// composer: the agent's question plus one button per agent-offered option (allow
// variants prominent, reject variants bordered). An inline gate rather than a
// window-modal sheet so an embedded Chat element never takes over the host window;
// the composer input pauses while a request is pending.
private struct PermissionCard: View {
    let request: PermissionRequest
    let respond: (String?) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(request.title, systemImage: "lock.shield")
                .font(.callout.weight(.medium))
            HStack(spacing: 8) {
                ForEach(request.options) { option in
                    if option.kind.allows {
                        Button(option.name) { respond(option.id) }
                            .buttonStyle(.borderedProminent)
                    } else {
                        Button(option.name, role: .destructive) { respond(option.id) }
                            .buttonStyle(.bordered)
                    }
                }
            }
            .controlSize(.small)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(Color.secondary.opacity(0.08))
    }
}

// MARK: - Image row (single alignment)

// A standalone image element. Rendered with CachedImage (the AsyncImageCache view): bytes come from the
// shared memory + disk cache, decoded/scaled off the main thread; the box reserves the image's aspect up
// front (from the transport-provided pixelSize when known) so hydration does not reflow the transcript.
// The image is capped to a readable bubble width; maxPixelWidth bounds the decoded resolution to ~3x that.
private struct ImageRow: View {
    let role: ChatRole
    let image: ChatImage
    let config: ChatConfiguration

    private static let maxDisplayWidth: CGFloat = 280

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            if config.showRoleLabels {
                let label = config.style(for: role).label
                if !label.isEmpty {
                    Text(label).font(.caption).foregroundStyle(.secondary)
                }
            }
            CachedImage(url: image.url,
                        intrinsicSize: image.pixelSize,
                        cornerRadius: 10,
                        maxPixelWidth: Self.maxDisplayWidth * 3)
                .frame(maxWidth: Self.maxDisplayWidth, alignment: .leading)
                .accessibilityLabel(image.alt.isEmpty ? Text("Image") : Text(image.alt))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Tint token resolver

// ActionUI's ColorHelper is internal, so the add-on resolves the common color
// tokens locally for M1 (the same token vocabulary). Promoting a public color
// resolver in core would let this defer to the framework; tracked as a later
// refinement. Internal (not private) so the dual-alignment rows share it.
enum ChatTint {
    static func color(for token: String) -> Color {
        switch token.lowercased() {
        case "accent":              return .accentColor
        case "primary":             return .primary
        case "secondary", "tertiary": return .secondary
        case "red":                 return .red
        case "orange":              return .orange
        case "yellow":              return .yellow
        case "green":               return .green
        case "mint":                return .mint
        case "teal":                return .teal
        case "blue":                return .blue
        case "indigo":              return .indigo
        case "purple":              return .purple
        case "pink":                return .pink
        case "gray", "grey":        return .gray
        default:                    return .secondary
        }
    }
}
