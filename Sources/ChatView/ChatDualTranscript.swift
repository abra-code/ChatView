// Sources/ChatView/ChatDualTranscript.swift
//
// The dual-alignment (person-to-person / group) transcript rows: the messaging-app layout
// where your own messages align trailing with the role tint and everyone else's align
// leading. Driven by `appearance.alignment: "dual"`; single alignment keeps the exact v1
// rows in ChatRootView. Run grouping, day separators, and timestamp parsing come from the
// pure ChatTranscriptLayout helpers - these views only place what those compute:
//   - a sender-name label above the FIRST message of a run (groups / showRoleLabels),
//   - an avatar (or initials disc) beside the LAST message of an incoming run,
//   - a timestamp caption (+ an "(edited)" badge) below the LAST message of a run,
//   - a delivery-status caption under the last OWN message of a run (Failed -> tap to retry),
//   - a "Message deleted" tombstone, and a quoted-excerpt block for a reply.
// Member/call/file/voice rows and the reaction chips / interactive reply-quote are later stages.

import SwiftUI
import RichText
import AsyncImageCache
import AVFoundation
#if canImport(AppKit)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif

/// One transcript item reduced to what a dual row renders: the resolved sender identity, the
/// parsed timestamp, self-authorship, and the run/day placement from ChatTranscriptLayout.
struct DualRowContext: Identifiable {
    let id: String
    let item: ChatItem
    let info: ChatTranscriptLayout.Info
    let isSelf: Bool
    let senderName: String?
    let avatarURL: String?
    let timestamp: Date?
}

/// The message affordances the transcript offers, each already gated (features AND capabilities) by
/// the caller, plus the closures that run them. Copy is always available (ungated); the gated flags
/// drive whether Reply / Edit / Delete / React appear.
struct DualRowActions {
    var canReply = false
    var canEdit = false
    var canDelete = false
    var canReact = false
    var reply: (ChatMessage) -> Void = { _ in }
    var edit: (ChatMessage) -> Void = { _ in }
    var delete: (ChatMessage) -> Void = { _ in }
    var toggleReaction: (_ itemID: String, _ emoji: String) -> Void = { _, _ in }
    var jumpTo: (String) -> Void = { _ in }
    var cancelTransfer: (String) -> Void = { _ in }

    /// The fixed quick-reaction row shown at the top of the context menu (Unicode order per the plan):
    /// thumbs up, heart, tears of joy, open mouth, crying, folded hands.
    static let quickReactions = ["\u{1F44D}", "\u{2764}\u{FE0F}", "\u{1F602}", "\u{1F62E}", "\u{1F622}", "\u{1F64F}"]
}

/// Renders one dual-alignment row (dispatch by item kind). The caller places the optional day
/// separator and the inter-run spacing; this view renders the item itself.
struct DualTranscriptRow: View {
    let ctx: DualRowContext
    let config: ChatConfiguration
    let maxBubbleWidth: CGFloat
    let showsSenderNames: Bool
    let actions: DualRowActions
    let highlighted: Bool
    @ObservedObject var audio: ChatAudioController
    let onResend: (String) -> Void

    var body: some View {
        switch ctx.item {
        case .message(let message):
            DualMessageRow(ctx: ctx, message: message, config: config, maxBubbleWidth: maxBubbleWidth,
                           showsSenderNames: showsSenderNames, actions: actions, highlighted: highlighted,
                           onResend: onResend)
        case .image(_, let role, let image):
            // An image is a leading/trailing bubble too; reuse the shared image view inside the gutter frame.
            DualImageRow(ctx: ctx, role: role, image: image, config: config, maxBubbleWidth: maxBubbleWidth)
        case .file(let file):
            DualFileRow(ctx: ctx, file: file, config: config, maxBubbleWidth: maxBubbleWidth,
                        showsSenderNames: showsSenderNames, audio: audio,
                        onCancel: { actions.cancelTransfer(file.id) },
                        onRetry: { onResend(file.id) })
        case .memberEvent(let event):
            CenteredCaption(text: MemberEventText.caption(event), systemImage: "person.2", tint: .secondary)
        case .callEvent(let event):
            CenteredCaption(text: CallEventText.caption(event),
                            systemImage: (event.isVideo ?? false) ? "video" : "phone", tint: callTint(event))
        case .system(_, let text):
            CenteredCaption(text: text, systemImage: nil, tint: .secondary)
        case .error(_, let text):
            CenteredCaption(text: text, systemImage: "exclamationmark.triangle", tint: .red)
        case .sessionEvent(let event):
            // A session boundary is as meaningful in a P2P transcript as in an agentic one, and
            // CenteredCaption is already the shape this view gives every non-bubble row.
            CenteredCaption(text: SessionEventText.caption(event), systemImage: "clock.arrow.circlepath",
                            tint: .secondary)
        case .thought, .toolCall:
            // Agentic surfaces are not part of a P2P conversation.
            EmptyView()
        }
    }

    private func callTint(_ event: CallEvent) -> Color {
        switch event.kind {
        case .missedIncoming, .missedOutgoing, .declined: return .red
        case .completed:                                  return .secondary
        }
    }
}

// MARK: - Member / call event captions

/// The wording of a session boundary, in one place.
///
/// Shared by the agentic transcript's SessionEventRow and the dual transcript's centered caption
/// for the reason every other *Text enum here exists: two views phrasing the same event
/// differently is a bug nobody notices until a screenshot puts them side by side.
///
/// BOTH DETAILS ARE OPTIONAL. Agents advertise a model through session configOptions and not all
/// of them do - mlx-agent advertises none - and a host need not stamp a time. So this composes
/// from what is present rather than filling a sentence template, which would otherwise read as
/// "Resumed with  " on the commonest case of all.
enum SessionEventText {
    static func caption(_ event: SessionEvent) -> String {
        var parts: [String] = [verb(event.kind)]
        if let model = event.model, !model.isEmpty {
            parts.append(event.kind == .modelChanged ? "to \(model)" : "with \(model)")
        }
        if let stamp = event.timestamp, let date = ChatTimestamp.parse(stamp) {
            parts.append(formatter.string(from: date))
        }
        return parts.joined(separator: " ")
    }

    private static func verb(_ kind: SessionEvent.Kind) -> String {
        switch kind {
        case .started:      return "Started"
        case .resumed:      return "Resumed"
        case .modelChanged: return "Switched"
        }
    }

    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return f
    }()
}

enum MemberEventText {
    static func caption(_ event: MemberEvent) -> String {
        let subject = event.subjectName ?? "Someone"
        let actor = event.actorName ?? "Someone"
        switch event.kind {
        case .joined:      return "\(subject) joined"
        case .left:        return "\(subject) left"
        case .invited:     return "\(actor) invited \(subject)"
        case .removed:     return "\(actor) removed \(subject)"
        case .roleChanged: return "\(subject) is now \(event.detail ?? "updated")"
        case .renamed:     return "\(actor) changed the name to \(event.detail ?? "a new name")"
        }
    }
}

enum CallEventText {
    static func caption(_ event: CallEvent) -> String {
        let kind = (event.isVideo ?? false) ? "video call" : "call"
        switch event.kind {
        case .missedIncoming: return "Missed \(kind)"
        case .missedOutgoing: return "Unanswered \(kind)"
        case .declined:       return "Declined \(kind)"
        case .completed:
            if let seconds = event.durationSeconds {
                return "\(kind.capitalized(with: nil)) \u{00B7} \(durationText(seconds))"
            }
            return kind.capitalized(with: nil)
        }
    }

    static func durationText(_ seconds: Int) -> String {
        String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
}

// MARK: - Message row (dual)

private struct DualMessageRow: View {
    let ctx: DualRowContext
    let message: ChatMessage
    let config: ChatConfiguration
    let maxBubbleWidth: CGFloat
    let showsSenderNames: Bool
    let actions: DualRowActions
    let highlighted: Bool
    let onResend: (String) -> Void

    private var isSelf: Bool { ctx.isSelf }
    private var isFirstInRun: Bool { ctx.info.isFirstInRun }
    private var isLastInRun: Bool { ctx.info.isLastInRun }
    private var isTombstone: Bool { message.deleted == true }

    var body: some View {
        // The incoming avatar gutter (avatar 28 + 6 spacing); the sender label and caption indent by it so they
        // line up with the bubble instead of the avatar. Own rows and no-avatar configs have no gutter.
        let contentIndent: CGFloat = (config.showAvatars && !isSelf) ? 34 : 0
        VStack(alignment: isSelf ? .trailing : .leading, spacing: 2) {
            if !isSelf, isFirstInRun, showsSenderNames, let name = ctx.senderName, !name.isEmpty {
                Text(name)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.leading, contentIndent)
                    .padding(.horizontal, 4)
            }
            // Avatar + bubble in a bottom-aligned row so the incoming avatar meets the bubble's BOTTOM edge (not
            // the caption below). The reaction overlays the bubble's top-OUTER corner (Apple-style), decoupled
            // from the bottom caption so it never collides with the time / delivery status.
            HStack(alignment: .bottom, spacing: 6) {
                if isSelf {
                    Spacer(minLength: 40)
                } else if config.showAvatars {
                    avatarGutter
                }
                bubble
                    // Chips are an affordance, so they are gated on canReact (features AND capabilities), never on
                    // data presence alone - a seeded / inbound message can carry reaction data even when the
                    // document/transport does not enable reactions. The overlay is applied to the hugging bubble
                    // BEFORE the maxWidth frame, so the badge pins to the bubble's real corner (not the frame edge).
                    .overlay(alignment: isSelf ? .topLeading : .topTrailing) {
                        if actions.canReact, let reactions = message.reactions, !reactions.isEmpty {
                            ReactionChips(reactions: reactions) { emoji in
                                actions.toggleReaction(message.id, emoji)
                            }
                            .padding(2)
                            .background(.background, in: Capsule())
                            .shadow(radius: 1.5, y: 1)
                            .offset(x: isSelf ? -8 : 8, y: -10)
                        }
                    }
                    .frame(maxWidth: maxBubbleWidth, alignment: isSelf ? .trailing : .leading)
                if !isSelf {
                    Spacer(minLength: 40)
                }
            }
            if isLastInRun {
                captionRow
                    .padding(.leading, contentIndent)
            }
        }
        .frame(maxWidth: .infinity, alignment: isSelf ? .trailing : .leading)
    }

    @ViewBuilder
    private var bubble: some View {
        Group {
            if isTombstone {
                Text("Message deleted")
                    .italic()
                    .foregroundStyle(.secondary)
            } else {
                // The bubble hugs its content (the messaging idiom), rather than filling the column like a
                // v1 full-width row. No .frame(maxWidth:) here: a maxWidth frame FILLS up to its cap, which
                // would stretch the bubble. Instead the content hugs itself - RichText via .widthBehavior(.hug)
                // (see `content`) and the reply quote by not filling - each capped by the column-width proposal
                // that DualTranscriptRow already applies (.frame(maxWidth: maxBubbleWidth) at the row level).
                VStack(alignment: .leading, spacing: 4) {
                    if let reply = message.replyTo {
                        Button { actions.jumpTo(reply.itemID) } label: { ReplyQuote(reply: reply) }
                            .buttonStyle(.plain)
                    }
                    content
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(bubbleBackground, in: RoundedRectangle(cornerRadius: 14))
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .strokeBorder(Color.accentColor, lineWidth: highlighted ? 2 : 0)
        )
        .contextMenu { if !isTombstone { bubbleMenu } }
    }

    // The message context menu: a quick-reaction row on top (when reactions are enabled), then the
    // gated actions and the always-available Copy. Edit / Delete are own-message only (the caller's
    // gate already accounts for that via canEdit / canDelete plus isSelf).
    @ViewBuilder
    private var bubbleMenu: some View {
        if actions.canReact {
            ControlGroup {
                ForEach(DualRowActions.quickReactions, id: \.self) { emoji in
                    Button(emoji) { actions.toggleReaction(message.id, emoji) }
                }
            }
        }
        if actions.canReply {
            Button { actions.reply(message) } label: { Label("Reply", systemImage: "arrowshape.turn.up.left") }
        }
        if actions.canEdit, isSelf {
            Button { actions.edit(message) } label: { Label("Edit", systemImage: "pencil") }
        }
        Button { copyText() } label: { Label("Copy", systemImage: "doc.on.doc") }
        if actions.canDelete, isSelf {
            Button(role: .destructive) { actions.delete(message) } label: { Label("Delete", systemImage: "trash") }
        }
    }

    private func copyText() {
        #if os(macOS)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(message.text, forType: .string)
        #else
        UIPasteboard.general.string = message.text
        #endif
    }

    @ViewBuilder
    private var content: some View {
        if message.text.isEmpty && message.isStreaming {
            Text("\u{2026}").foregroundStyle(.secondary)
        } else {
            // .hug so a dual bubble sizes to its text (up to the column width) instead of filling the
            // column like a v1 full-width row. The enclosing bubble's .frame(maxWidth:) is the cap.
            RichText(markdown: message.text).widthBehavior(.hug)
        }
    }

    private var bubbleBackground: Color {
        if isSelf {
            return ChatTint.color(for: config.style(for: message.role).tint).opacity(0.22)
        }
        return Color.secondary.opacity(0.14)
    }

    // The avatar renders beside the LAST message of an incoming run; earlier rows reserve the gutter
    // (a clear spacer) so the bubbles stay aligned.
    @ViewBuilder
    private var avatarGutter: some View {
        if isLastInRun {
            AvatarView(url: ctx.avatarURL, name: ctx.senderName, size: 28)
        } else {
            Color.clear.frame(width: 28, height: 1)
        }
    }

    // Below the last message of a run: a timestamp (+ "(edited)"), and for an own run the delivery status.
    @ViewBuilder
    private var captionRow: some View {
        let timeText = timestampCaption
        if isSelf {
            HStack(spacing: 4) {
                if let timeText {
                    Text(timeText).font(.caption2).foregroundStyle(.secondary)
                }
                if config.showDeliveryStatus, let status = message.status {
                    DeliveryStatusCaption(status: status) { onResend(message.id) }
                }
            }
            .padding(.horizontal, 4)
        } else if let timeText {
            Text(timeText)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 4)
        }
    }

    private var timestampCaption: String? {
        guard config.showTimestamps, let date = ctx.timestamp else {
            // An edited message with no timestamp still shows the edited badge.
            return message.editedAt != nil ? "(edited)" : nil
        }
        var text = ChatDateFormat.shortTime(date)
        if message.editedAt != nil {
            text += " \u{00B7} (edited)"
        }
        return text
    }
}

// MARK: - Image row (dual)

private struct DualImageRow: View {
    let ctx: DualRowContext
    let role: ChatRole
    let image: ChatImage
    let config: ChatConfiguration
    let maxBubbleWidth: CGFloat

    private var isSelf: Bool { ctx.isSelf }

    var body: some View {
        HStack(alignment: .bottom, spacing: 6) {
            if isSelf {
                Spacer(minLength: 40)
            } else if config.showAvatars {
                if ctx.info.isLastInRun {
                    AvatarView(url: ctx.avatarURL, name: ctx.senderName, size: 28)
                } else {
                    Color.clear.frame(width: 28, height: 1)
                }
            }
            CachedImage(url: image.url, intrinsicSize: image.pixelSize, cornerRadius: 12,
                        maxPixelWidth: maxBubbleWidth * 3)
                .frame(maxWidth: min(maxBubbleWidth, 280), alignment: isSelf ? .trailing : .leading)
                .accessibilityLabel(image.alt.isEmpty ? Text("Image") : Text(image.alt))
            if !isSelf {
                Spacer(minLength: 40)
            }
        }
        .frame(maxWidth: .infinity, alignment: isSelf ? .trailing : .leading)
    }
}

// MARK: - File / voice row

/// One shared audio slot per chat: starting one voice message stops any other. Only local (or already
/// downloaded) file URLs play directly; a remote URL that has not been fetched simply does not start.
@MainActor
final class ChatAudioController: ObservableObject {
    @Published private(set) var playingID: String?
    @Published private(set) var progress: Double = 0     // 0...1

    private var player: AVAudioPlayer?
    private var delegate: PlayerDelegate?
    private var ticker: Timer?

    func toggle(id: String, url: URL?) {
        if playingID == id {
            stop()
            return
        }
        stop()
        guard let url, url.isFileURL, let player = try? AVAudioPlayer(contentsOf: url) else {
            return
        }
        let delegate = PlayerDelegate()
        delegate.controller = self
        player.delegate = delegate
        self.player = player
        self.delegate = delegate
        playingID = id
        player.play()
        let ticker = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let player = self.player, player.duration > 0 else { return }
                self.progress = player.currentTime / player.duration
            }
        }
        self.ticker = ticker
    }

    func stop() {
        ticker?.invalidate()
        ticker = nil
        player?.stop()
        player = nil
        delegate = nil
        playingID = nil
        progress = 0
    }

    private final class PlayerDelegate: NSObject, AVAudioPlayerDelegate {
        weak var controller: ChatAudioController?
        func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
            Task { @MainActor [weak controller] in controller?.stop() }
        }
    }
}

/// A file attachment or voice message, aligned like a message bubble. A document file shows an icon +
/// name + size + transfer state (a progress bar with a cancel button while transferring, a retry on
/// failure); a voice message shows a play/pause button + a progress bar + the elapsed/total time.
private struct DualFileRow: View {
    let ctx: DualRowContext
    let file: ChatFile
    let config: ChatConfiguration
    let maxBubbleWidth: CGFloat
    let showsSenderNames: Bool
    @ObservedObject var audio: ChatAudioController
    let onCancel: () -> Void
    let onRetry: () -> Void

    private var isSelf: Bool { ctx.isSelf }

    var body: some View {
        HStack(alignment: .bottom, spacing: 6) {
            if isSelf {
                Spacer(minLength: 40)
            } else if config.showAvatars {
                if ctx.info.isLastInRun {
                    AvatarView(url: ctx.avatarURL, name: ctx.senderName, size: 28)
                } else {
                    Color.clear.frame(width: 28, height: 1)
                }
            }
            VStack(alignment: isSelf ? .trailing : .leading, spacing: 2) {
                if !isSelf, ctx.info.isFirstInRun, showsSenderNames, let name = ctx.senderName, !name.isEmpty {
                    Text(name).font(.caption).foregroundStyle(.secondary).padding(.horizontal, 4)
                }
                bubble
            }
            .frame(maxWidth: maxBubbleWidth, alignment: isSelf ? .trailing : .leading)
            if !isSelf {
                Spacer(minLength: 40)
            }
        }
        .frame(maxWidth: .infinity, alignment: isSelf ? .trailing : .leading)
    }

    @ViewBuilder
    private var bubble: some View {
        Group {
            if file.kind == .voice {
                voiceContent
            } else {
                fileContent
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(minWidth: 180, alignment: .leading)
        .background(isSelf ? ChatTint.color(for: config.style(for: .local).tint).opacity(0.22)
                           : Color.secondary.opacity(0.14),
                    in: RoundedRectangle(cornerRadius: 14))
    }

    private var isPlaying: Bool { audio.playingID == file.id }

    private var voiceContent: some View {
        HStack(spacing: 10) {
            Button {
                audio.toggle(id: file.id, url: file.url)
            } label: {
                Image(systemName: isPlaying ? "pause.circle.fill" : "play.circle.fill")
                    .font(.title2)
                    .foregroundStyle(.tint)
            }
            .buttonStyle(.plain)
            VStack(alignment: .leading, spacing: 3) {
                ProgressView(value: isPlaying ? audio.progress : 0)
                    .frame(width: 120)
                Text(durationLabel).font(.caption2).foregroundStyle(.secondary)
            }
        }
    }

    private var fileContent: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Image(systemName: "doc.fill").font(.title3).foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 1) {
                    Text(file.name).font(.callout.weight(.medium)).lineLimit(1)
                    Text(transferSubtitle).font(.caption2).foregroundStyle(.secondary)
                }
            }
            if file.transferStatus == .transferring {
                HStack(spacing: 8) {
                    ProgressView(value: file.progress ?? 0).frame(maxWidth: .infinity)
                    Button(action: onCancel) {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            } else if file.transferStatus == .failed {
                Button(action: onRetry) {
                    Label("Transfer failed \u{2013} tap to retry", systemImage: "exclamationmark.circle")
                        .font(.caption2)
                        .foregroundStyle(.red)
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var durationLabel: String {
        guard let seconds = file.durationSeconds else {
            return "Voice message"
        }
        if isPlaying, audio.progress > 0 {
            let elapsed = Int(audio.progress * Double(seconds))
            return "\(CallEventText.durationText(elapsed)) / \(CallEventText.durationText(seconds))"
        }
        return CallEventText.durationText(seconds)
    }

    private var transferSubtitle: String {
        var parts: [String] = []
        if let size = file.sizeBytes {
            parts.append(Self.formatSize(size))
        }
        switch file.transferStatus {
        case .pending:      parts.append("Waiting\u{2026}")
        case .transferring: parts.append("\(Int((file.progress ?? 0) * 100))%")
        case .cancelled:    parts.append("Cancelled")
        case .completed, .failed: break
        }
        return parts.joined(separator: " \u{00B7} ")
    }

    static func formatSize(_ bytes: Int) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: Int64(bytes))
    }
}

// MARK: - Typing indicator

/// An animated three-dot bubble at the transcript bottom, shown while participants are typing. Distinct
/// from the agentic awaiting indicator; driven by the store's `typingParticipants`.
struct TypingIndicatorRow: View {
    let names: [String]
    @State private var phase = 0

    private let timer = Timer.publish(every: 0.35, on: .main, in: .common).autoconnect()

    var body: some View {
        HStack(alignment: .bottom, spacing: 6) {
            HStack(spacing: 4) {
                ForEach(0..<3, id: \.self) { index in
                    Circle()
                        .fill(Color.secondary)
                        .frame(width: 6, height: 6)
                        .opacity(phase == index ? 1 : 0.3)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .background(Color.secondary.opacity(0.14), in: RoundedRectangle(cornerRadius: 14))
            if let label = typingLabel {
                Text(label).font(.caption2).foregroundStyle(.secondary)
            }
            Spacer(minLength: 40)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onReceive(timer) { _ in
            phase = (phase + 1) % 3
        }
        .transition(.opacity)
    }

    private var typingLabel: String? {
        let known = names.filter { !$0.isEmpty }
        switch known.count {
        case 0:  return nil
        case 1:  return "\(known[0]) is typing\u{2026}"
        case 2:  return "\(known[0]) and \(known[1]) are typing\u{2026}"
        default: return "Several people are typing\u{2026}"
        }
    }
}

// MARK: - Reply quote (display; the tap-to-scroll + compose banner are P5)

private struct ReplyQuote: View {
    let reply: ReplyRef

    var body: some View {
        HStack(spacing: 6) {
            RoundedRectangle(cornerRadius: 1.5)
                .fill(Color.accentColor.opacity(0.6))
                .frame(width: 3)
            VStack(alignment: .leading, spacing: 1) {
                if let sender = reply.senderName, !sender.isEmpty {
                    Text(sender).font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                }
                Text(reply.excerpt).font(.caption2).foregroundStyle(.secondary).lineLimit(2)
            }
        }
        // fixedSize(vertical): the accent bar is a RoundedRectangle, which is greedy vertically; without this
        // it expands to whatever height the bubble is proposed. Hug the row to its text height instead (the
        // bar then matches that height). No maxWidth:.infinity, so the quote hugs its excerpt and the bubble
        // can hug too - the bubble's column-width proposal caps how wide a long quote may grow.
        .fixedSize(horizontal: false, vertical: true)
        .padding(.vertical, 2)
    }
}

// MARK: - Reaction chips

/// A wrapping row of reaction chips under a bubble: emoji + count, `mine` tinted; tap toggles.
private struct ReactionChips: View {
    let reactions: [Reaction]
    let toggle: (String) -> Void

    var body: some View {
        // The chips hug their content: this renders as an overlay badge on the bubble corner, and the
        // overlay proposes the bubble's full width, so a greedy maxWidth frame here would stretch the
        // capsule background across the whole bubble. ReactionFlow returns its content width, so the
        // badge stays a snug pill (and still wraps to a second line if a long reaction run exceeds the
        // bubble width). Matches the Kotlin FlowRow, which hugs its content too.
        ReactionFlow(spacing: 4) {
            ForEach(reactions, id: \.emoji) { reaction in
                Button { toggle(reaction.emoji) } label: {
                    HStack(spacing: 3) {
                        Text(reaction.emoji)
                        if reaction.count > 1 {
                            Text("\(reaction.count)").font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(reaction.mine ? Color.accentColor.opacity(0.22) : Color.secondary.opacity(0.14),
                                in: Capsule())
                    .overlay(Capsule().strokeBorder(reaction.mine ? Color.accentColor.opacity(0.5) : Color.clear))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 2)
    }
}

/// A minimal wrapping (flow) layout: lays subviews left to right, wrapping to a new line when the
/// proposed width is exceeded. Used for the reaction chip row.
private struct ReactionFlow: Layout {
    var spacing: CGFloat = 4

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var rowWidth: CGFloat = 0
        var rowHeight: CGFloat = 0
        var totalHeight: CGFloat = 0
        var widest: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if rowWidth > 0, rowWidth + spacing + size.width > maxWidth {
                totalHeight += rowHeight + spacing
                widest = max(widest, rowWidth)
                rowWidth = 0
                rowHeight = 0
            }
            rowWidth += (rowWidth > 0 ? spacing : 0) + size.width
            rowHeight = max(rowHeight, size.height)
        }
        totalHeight += rowHeight
        widest = max(widest, rowWidth)
        return CGSize(width: min(maxWidth, widest), height: totalHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX
        var y = bounds.minY
        var rowHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > bounds.minX, x + size.width > bounds.maxX {
                x = bounds.minX
                y += rowHeight + spacing
                rowHeight = 0
            }
            subview.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}

// MARK: - Delivery status caption

private struct DeliveryStatusCaption: View {
    let status: MessageStatus
    let onRetry: () -> Void

    var body: some View {
        switch status {
        case .sending:
            Text("Sending\u{2026}").font(.caption2).foregroundStyle(.secondary)
        case .sent:
            Text("Sent").font(.caption2).foregroundStyle(.secondary)
        case .delivered:
            Text("Delivered").font(.caption2).foregroundStyle(.secondary)
        case .read:
            Text("Read").font(.caption2).foregroundStyle(.tint)
        case .failed:
            Button(action: onRetry) {
                Label("Failed \u{2013} tap to retry", systemImage: "exclamationmark.circle.fill")
                    .font(.caption2)
                    .foregroundStyle(.red)
            }
            .buttonStyle(.plain)
        }
    }
}

// MARK: - Avatar

/// A sender avatar: the resolved image, or a colored initials disc when no avatar resolves.
struct AvatarView: View {
    let url: String?
    let name: String?
    let size: CGFloat

    var body: some View {
        if let url, let parsed = URL(string: url) {
            CachedImage(url: parsed, intrinsicSize: nil, cornerRadius: size / 2, maxPixelWidth: size * 3)
                .frame(width: size, height: size)
                .clipShape(Circle())
        } else {
            Circle()
                .fill(discColor.opacity(0.25))
                .frame(width: size, height: size)
                .overlay(
                    Text(initials)
                        .font(.system(size: size * 0.4, weight: .semibold))
                        .foregroundStyle(discColor)
                )
        }
    }

    private var initials: String {
        let words = (name ?? "").split(separator: " ").prefix(2)
        let letters = words.compactMap { $0.first }.map(String.init).joined()
        return letters.isEmpty ? "?" : letters.uppercased()
    }

    // A stable per-name hue so a participant keeps the same disc color across the transcript.
    private var discColor: Color {
        let palette: [Color] = [.blue, .green, .orange, .purple, .pink, .teal, .indigo, .red]
        let key = name ?? ""
        var hash = 5381
        for byte in key.utf8 {
            hash = ((hash << 5) &+ hash) &+ Int(byte)
        }
        return palette[abs(hash) % palette.count]
    }
}

// MARK: - Centered caption + day separator

/// A centered caption row (system notice, and the visual family member / call events will reuse in P6).
struct CenteredCaption: View {
    let text: String
    let systemImage: String?
    let tint: Color

    var body: some View {
        Group {
            if let systemImage {
                Label(text, systemImage: systemImage)
            } else {
                Text(text)
            }
        }
        .font(.caption)
        .foregroundStyle(tint)
        .frame(maxWidth: .infinity, alignment: .center)
        .padding(.vertical, 2)
    }
}

/// A centered date caption inserted between items when the calendar day changes.
struct DaySeparatorRow: View {
    let date: Date

    var body: some View {
        Text(ChatDateFormat.daySeparator(date))
            .font(.caption2.weight(.medium))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 10)
            .padding(.vertical, 3)
            .background(Color.secondary.opacity(0.12), in: Capsule())
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.vertical, 6)
    }
}

// MARK: - Date formatting

enum ChatDateFormat {
    static func shortTime(_ date: Date) -> String {
        timeFormatter.string(from: date)
    }

    /// "Today" / "Yesterday" / a medium date for the day separator.
    static func daySeparator(_ date: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(date) {
            return "Today"
        }
        if calendar.isDateInYesterday(date) {
            return "Yesterday"
        }
        return dayFormatter.string(from: date)
    }

    nonisolated(unsafe) private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        formatter.dateStyle = .none
        return formatter
    }()

    nonisolated(unsafe) private static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        return formatter
    }()
}
