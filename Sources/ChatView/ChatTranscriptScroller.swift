// Sources/ChatView/ChatTranscriptScroller.swift
//
// Owns the transcript's backing NSScrollView: keeps the vertical scroller from destabilizing the
// layout (`stabilizeScrollerWidth`, which is the fix for the crash), and moves the viewport to the
// bottom in AppKit rather than through ScrollViewProxy (`scrollToBottom`).
//
// CORRECTING THE ORIGINAL HEADER, which claimed ScrollViewProxy was the crash. It was not.
//
// The crash is `-[NSWindow _postWindowNeedsUpdateConstraints]` throwing from inside the window's
// layout pass, with `ScrollActionDispatcher.updateValue` on the stack. That framing put three releases
// (0.2.1 and 0.2.3 deferring the call, 0.2.5 bypassing the proxy) onto the question of WHO ISSUES THE
// SCROLL. A traced Cadabra crash on 2026-07-27 settled it: during the 77,994-sample storm that ends in
// the kill, ChatView issues ZERO scrolls of any kind, and the scroll offset stays at exactly 0.0 for
// 78,057 of 78,099 samples. The dispatcher is on the stack only because a ScrollViewReader exists in
// the graph and gets re-dispatched on every pass of a layout that never converges.
//
// What actually fails to converge is the scroller-toggle loop described on `stabilizeScrollerWidth`.
//
// Moving the clip view directly is still worth keeping, on its own smaller merits: it takes the
// streaming follow off the view graph entirely (74-79 pending proxy actions per session -> 0), and it
// lands on the true maximum offset, where `scrollTo(anchor: .bottom)` was settling 67pt short. The
// pin's geometry samples still arrive, because SwiftUI observes the clip view's bounds.
//
// Only the STREAMING follows switch - the geometry chase and the items follow, which fire many times a
// second while an answer arrives. Everything one-shot stays on ScrollViewProxy: the animated
// jump-to-latest, the two item-targeted scrolls (paging restore, reply-quote jump), and the two that
// run before the transcript has laid out (appear, a conversation loaded in place), where only SwiftUI
// can resolve "the bottom" because the clip view's document is still empty.

import SwiftUI
#if os(macOS)
import AppKit
#endif

#if os(macOS)

/// Holds the transcript's backing NSScrollView (captured by `ChatScrollViewFinder` from inside the
/// scroll content) and scrolls it directly. A reference type in `@State` for the same reason as
/// ChatScrollPinTracker: it is written from geometry callbacks and must never invalidate the view.
@MainActor
final class ChatTranscriptScroller {
    /// Weak: the scroll view belongs to the hosting view's AppKit tree, which outlives nothing here.
    weak var scrollView: NSScrollView?

    /// Stops the vertical scroller from changing the content's width, which is what makes the
    /// transcript's layout fail to converge and eventually kills the app.
    ///
    /// With LEGACY (non-overlay) scrollers, a shown scroller takes width from the content - 17pt at the
    /// regular control size, 13pt at `.small`. So when the transcript's height lands within a line's
    /// worth of the viewport's, AppKit oscillates:
    ///
    ///     content 465 > container 460  ->  scroller needed, shown  ->  rows rewrap at 511pt wide
    ///       ->  content 440 < container 460  ->  scroller not needed, hidden  ->  rows at 528pt
    ///       ->  content 465  ->  ...
    ///
    /// Measured in Cadabra 2026-07-27: 25,360 round trips of exactly that cycle inside a single display
    /// cycle, until `-[NSWindow _postWindowNeedsUpdateConstraints]` threw and AppKit killed the process.
    /// The row diagnostics show every row's width alternating 528 <-> 511 an equal number of times, and
    /// the pin trace shows the content height alternating 465 <-> 440 against a container fixed at 460.
    ///
    /// Reserving the scroller permanently makes the content width constant, so the height it produces is
    /// a fixed point and THIS loop cannot start. (It does not make the transcript's layout convergent in
    /// general - it removes one feedback edge.)
    ///
    /// The `== .overlay` test is load-bearing, not defensive. Overlay scrollers float above the content
    /// and take no width, so they need no reservation; forcing `autohidesScrollers = false` on them
    /// instead leaves the floating scroller permanently visible even when the content fits, which is a
    /// visible regression on the majority of Macs.
    ///
    /// Two properties of this call worth knowing before touching it:
    ///
    /// - **Writing the same values is free.** An NSScrollView only re-tiles when a value actually
    ///   changes (measured: five rounds of identical writes produce zero `tile()` calls and leave
    ///   `needsLayout` false). That is what makes it safe to call from `updateNSView` - it cannot
    ///   invalidate layout, so it cannot become the very kind of loop it exists to prevent.
    /// - **`autohidesScrollers` is scroll-view-wide**, so on a scroll view that also has a horizontal
    ///   scroller this would pin that one too and steal height. Harmless here (SwiftUI's vertical
    ///   ScrollView creates no horizontal scroller), but do not lift this onto a bidirectional one.
    ///
    /// This is why deferring the scroll (0.2.1, 0.2.3) and bypassing ScrollViewProxy (0.2.5) all failed:
    /// the loop runs with no scroll of any kind in flight - during the storm ChatView issued zero.
    func stabilizeScrollerWidth() {
        guard let scrollView else { return }
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = (scrollView.scrollerStyle == .overlay)
    }

    /// Scrolls the viewport to the bottom of the content. Returns false when there is no scroll view to
    /// move, or when it is not the shape this assumes - before the finder has attached, or if a future
    /// SwiftUI stops backing ScrollView with a flipped-document NSScrollView - so the caller can fall
    /// back to ScrollViewProxy rather than silently not following.
    @discardableResult
    func scrollToBottom() -> Bool {
        guard let scrollView, scrollView.documentView != nil else { return false }
        let clip = scrollView.contentView
        // A non-flipped document puts the bottom at the LOW end of y, so the arithmetic below would
        // scroll to the top and report success - the follow would silently stop with no fallback.
        // SwiftUI's document view is flipped today; this is the same class of bet as the nil check.
        guard clip.isFlipped else { return false }
        // Ask the clip view for its own legal maximum rather than computing `document.height -
        // clip.height`: that ignores content insets and lands short by the bottom inset (measured: 600
        // vs a true 620 under a 20pt bottom inset), which is the very defect this function exists to
        // avoid in `scrollTo(anchor: .bottom)`. NSClipView.scroll(to:) does NOT clamp - it will happily
        // take an out-of-range origin - so the constraining has to happen here.
        let maxY = clip.constrainBoundsRect(
            CGRect(origin: CGPoint(x: clip.bounds.origin.x, y: .greatestFiniteMagnitude),
                   size: clip.bounds.size)).origin.y
        // Already there: report success without touching bounds, so a settled transcript does not emit
        // a pointless bounds-change (and with it a geometry sample) on every streaming delta.
        guard abs(clip.bounds.origin.y - maxY) > 0.5 else { return true }
        clip.scroll(to: CGPoint(x: clip.bounds.origin.x, y: maxY))
        scrollView.reflectScrolledClipView(clip)
        return true
    }
}

/// An invisible AppKit view planted in the scroll content purely to hand its `enclosingScrollView` to
/// the scroller. It lives as a background of the LazyVStack rather than as a row: the vstack is always
/// materialized, so the reference cannot be lost when the reader scrolls a lazy row off screen. As a
/// background it is proposed the vstack's full size, but it draws nothing and takes no hits, so it has
/// no layout or interaction effect.
struct ChatScrollViewFinder: NSViewRepresentable {
    let scroller: ChatTranscriptScroller

    func makeNSView(context: Context) -> NSView {
        FinderView(scroller: scroller)
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        // Re-read on every update: the view can be re-parented (a window move, a split-view change)
        // and a stale reference would silently stop the transcript following. Free when nothing
        // changed - see the note on stabilizeScrollerWidth.
        (nsView as? FinderView)?.adoptEnclosingScrollView()
    }

    private final class FinderView: NSView {
        private let scroller: ChatTranscriptScroller

        init(scroller: ChatTranscriptScroller) {
            self.scroller = scroller
            super.init(frame: .zero)
            // The system scroller style flips under a running app - plugging in a mouse switches every
            // app from overlay to legacy. SwiftUI does NOT re-run updateNSView for that (measured: zero
            // update calls in the 1.5s after a flip, while the content width changed by the scroller's
            // width), so without this the scroll view would sit in the stale, loop-prone configuration.
            // That matters more than a missed update usually would: the flip's own width change is
            // itself what can push the transcript across the boundary, so a heal that only arrived with
            // the next SwiftUI update would arrive after the loop had already run.
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(scrollerStyleChanged),
                name: NSScroller.preferredScrollerStyleDidChangeNotification,
                object: nil)
        }

        deinit {
            NotificationCenter.default.removeObserver(self)
            NSObject.cancelPreviousPerformRequests(withTarget: self)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError("not used from a nib") }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            adoptEnclosingScrollView()
        }

        /// Points the scroller at the transcript's scroll view and stabilizes it.
        ///
        /// The descendant check keeps this off scroll views that are not ours. `enclosingScrollView`
        /// walks superviews until it finds ANY NSScrollView, so if a future SwiftUI stops backing
        /// ScrollView with one, it would walk past and return the HOST's scroll view - AppKit hosts
        /// commonly have one - and we would force an always-visible scroller onto someone else's view.
        /// Refusing leaves `scrollToBottom` returning false, which the caller already handles by
        /// falling back to ScrollViewProxy.
        @objc func adoptEnclosingScrollView() {
            let found = enclosingScrollView
            if let found, let document = found.documentView, isDescendant(of: document) {
                scroller.scrollView = found
                scroller.stabilizeScrollerWidth()
            } else {
                scroller.scrollView = nil
            }
        }

        @objc private func scrollerStyleChanged(_ notification: Notification) {
            // Next runloop turn: NSScrollView adopts the new style from its own observer of this same
            // notification, and the order between that observer and ours is not contractual - reading
            // scrollerStyle now could read the old one. Coalesced, since the notification is per-app
            // broadcast and several views may answer it.
            NSObject.cancelPreviousPerformRequests(
                withTarget: self, selector: #selector(adoptEnclosingScrollView), object: nil)
            perform(#selector(adoptEnclosingScrollView), with: nil, afterDelay: 0)
        }

        /// Invisible to the mouse. As a background it spans the whole transcript, and it exists only to
        /// answer one question - it must never take a click, a drag or a selection off a row.
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}

#else

/// Non-macOS stub: the crash is an AppKit display-cycle exception, and UIKit's ScrollView hosting has
/// no equivalent path, so every platform but macOS keeps using ScrollViewProxy.
@MainActor
final class ChatTranscriptScroller {
    @discardableResult
    func scrollToBottom() -> Bool { false }

    /// No-op: the scroller-width loop is an AppKit legacy-scroller behavior with no UIKit equivalent.
    func stabilizeScrollerWidth() {}
}

#endif
