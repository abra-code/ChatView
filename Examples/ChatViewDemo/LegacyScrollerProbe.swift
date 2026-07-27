// Examples/ChatViewDemo/LegacyScrollerProbe.swift
//
// Test-only: forces LEGACY (width-taking) vertical scrollers on the demo's scroll views, so the
// scroller-toggle layout loop can be reproduced on a machine whose system preference is overlay
// scrollers - where it is invisible, because overlay scrollers float and never change the content
// width.
//
// The loop this reproduces (measured in Cadabra 2026-07-27, 25,360 round trips before AppKit's
// constraint-update guard threw and killed the app):
//
//     content 465 > container 460  ->  scroller needed, shown  ->  rows rewrap at 511pt wide
//       ->  content 440 < container 460  ->  scroller not needed, hidden  ->  rows at 528pt
//       ->  content 465  ->  ...
//
// To see it, the transcript height has to land within about a line of the viewport height, so pick
// CHATVIEW_STRESS_HEIGHT such that a streaming answer grows through that boundary.
//
// Enable with CHATVIEW_DEMO_LEGACY_SCROLLERS=1.

import AppKit

@MainActor
enum LegacyScrollerProbe {

    static func startIfRequested() {
        let env = ProcessInfo.processInfo.environment["CHATVIEW_DEMO_LEGACY_SCROLLERS"] ?? ""
        guard !env.isEmpty, env != "0" else { return }
        FileHandle.standardError.write(Data("[legacy] forcing legacy scroller style\n".utf8))
        // On a timer, not once: the transcript's scroll view may not exist yet at launch, and a screen
        // switch creates a new one.
        //
        // Ordering caveat when the machine's own preference is OVERLAY. Setting `scrollerStyle`
        // directly does not post `preferredScrollerStyleDidChangeNotification`, so the finder's
        // observer does not see it, and `stabilizeScrollerWidth` may already have run under `.overlay`
        // and left `autohidesScrollers` true. The next SwiftUI update re-applies it - frequent during
        // streaming, so it heals in milliseconds - but a very early measurement could still catch the
        // unstabilized configuration and read as the fix failing. On a legacy-preference machine the
        // forcer is a no-op and the question does not arise.
        Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { _ in
            MainActor.assumeIsolated {
                for window in NSApp.windows {
                    force(in: window.contentView)
                }
            }
        }
    }

    private static func force(in view: NSView?) {
        guard let view else { return }
        if let scrollView = view as? NSScrollView, scrollView.scrollerStyle != .legacy {
            scrollView.scrollerStyle = .legacy
        }
        for subview in view.subviews {
            force(in: subview)
        }
    }
}
