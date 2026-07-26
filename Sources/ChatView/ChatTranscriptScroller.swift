// Sources/ChatView/ChatTranscriptScroller.swift
//
// Moves the transcript viewport to the bottom WITHOUT going through ScrollViewProxy, because
// ScrollViewProxy is the crash.
//
// `proxy.scrollTo` does not scroll. It records a pending scroll action, and SwiftUI applies that
// action later, from inside `NSHostingView.layout`, during the window's display cycle:
//
//     -[NSWindow layoutIfNeeded]                       (display cycle observer)
//       NSHostingView.layout
//         ViewGraphRootValueUpdater.render
//           Update.dispatchActions
//             ScrollActionDispatcher.updateValue       <- the pending scrollTo, being applied
//               ViewGraph.requestImmediateUpdate
//                 NSHostingView.setNeedsUpdate
//                   -[NSView setNeedsUpdateConstraints:]
//                     -[NSWindow _postWindowNeedsUpdateConstraints]   <- throws
//                       -[NSApplication _crashOnException:]           <- kills the app
//
// The dispatcher asks the view graph for an immediate update, which dirties constraints on a window
// that is already inside its constraint-based layout pass. Enough of that in one cycle and AppKit's
// guard throws an uncaught exception.
//
// This is why deferring the CALL never fixed it. 0.2.1 moved the geometry chase off the layout pass,
// 0.2.3 moved the items-driven follow off it too, and both crashed again: the deferral controls when
// we ASK for a scroll, never when SwiftUI APPLIES it, and the application is always inside layout. All
// a deferral buys is fewer pending actions per cycle - lower odds, same mechanism.
//
// Moving the clip view directly is a plain AppKit scroll. It changes bounds and notifies observers; it
// does not touch the view graph, request an update, or invalidate a constraint, so the stack above
// cannot form. The pin's geometry samples still arrive (SwiftUI observes the clip view's bounds), which
// is what makes this a drop-in for the follow path - verified with the demo's ScrollProbe, where a
// direct clip-view move drives `onScrollGeometryChange` exactly like a user scroll does.
//
// Only the STREAMING follows switch - the geometry chase and the items follow, which fire many times a
// second while an answer arrives. Everything one-shot stays on ScrollViewProxy: the animated
// jump-to-latest, the two item-targeted scrolls (paging restore, reply-quote jump), and the two that
// run before the transcript has laid out (appear, a conversation loaded in place), where only SwiftUI
// can resolve "the bottom" because the clip view's document is still empty. One pending action in an
// otherwise idle cycle is not what exhausts the window's layout budget; hundreds during a stream are.

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

    /// Scrolls the viewport to the bottom of the content. Returns false when there is no scroll view
    /// to move yet - before the finder has attached, or if a future SwiftUI stops backing ScrollView
    /// with NSScrollView - so the caller can fall back to ScrollViewProxy rather than silently not
    /// following.
    @discardableResult
    func scrollToBottom() -> Bool {
        guard let scrollView, let document = scrollView.documentView else { return false }
        let clip = scrollView.contentView
        let maxY = max(0, document.bounds.height - clip.bounds.height)
        // Already there: report success without touching bounds, so a settled transcript does not emit
        // a pointless bounds-change (and with it a geometry sample) on every streaming delta.
        guard abs(clip.bounds.origin.y - maxY) > 0.5 else { return true }
        clip.scroll(to: CGPoint(x: clip.bounds.origin.x, y: maxY))
        scrollView.reflectScrolledClipView(clip)
        return true
    }
}

/// A zero-size AppKit view planted in the scroll content purely to hand its `enclosingScrollView` to
/// the scroller. It lives as a background of the LazyVStack rather than as a row: the vstack is always
/// materialized, so the reference cannot be lost when the reader scrolls a lazy row off screen.
struct ChatScrollViewFinder: NSViewRepresentable {
    let scroller: ChatTranscriptScroller

    func makeNSView(context: Context) -> NSView {
        FinderView(scroller: scroller)
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        // Re-read on every update: the view can be re-parented (a window move, a split-view change)
        // and a stale reference would silently stop the transcript following.
        scroller.scrollView = nsView.enclosingScrollView
    }

    private final class FinderView: NSView {
        private let scroller: ChatTranscriptScroller

        init(scroller: ChatTranscriptScroller) {
            self.scroller = scroller
            super.init(frame: .zero)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError("not used from a nib") }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            scroller.scrollView = enclosingScrollView
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
}

#endif
