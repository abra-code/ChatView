// Tests/ChatViewTests/ChatTranscriptScrollerTests.swift
//
// Unit tests for the AppKit half of the transcript follow (ChatTranscriptScroller.scrollToBottom).
//
// The pin state machine already had 25 tests and all of them stayed green while the transcript sat
// frozen at the very top through an entire streaming answer: ChatScrollPinTests proves the pin DECIDES
// to follow, and nothing proved the follow actually MOVED anything. That gap is what let the
// `.greatestFiniteMagnitude` proposal (see scrollToBottom) return a maxY of 0.0 on every sample,
// report success, and suppress the caller's ScrollViewProxy fallback - silently, for three releases.
//
// These run against a REAL NSScrollView with a real flipped document view. No window and no run loop
// are needed: clip-view constraining and `scroll(to:)` are pure geometry on the view tree.

#if os(macOS)

import XCTest
import AppKit
@testable import ChatView

@MainActor
final class ChatTranscriptScrollerTests: XCTestCase {

    /// SwiftUI's scroll content is flipped (origin at the top, growing down), which is the coordinate
    /// convention every offset in `scrollToBottom` assumes.
    private final class FlippedDocument: NSView {
        override var isFlipped: Bool { true }
    }

    /// A scroll view shaped like the transcript's: flipped document of `documentHeight` in a viewport
    /// of `viewportHeight`, laid out so the clip view has really taken its size.
    ///
    /// `automaticallyAdjustsContentInsets` is off to keep the expected maxima below equal to the
    /// arithmetic each test is asserting. That is representative, not a simplification: SwiftUI's own
    /// backing scroll view also has it off, and still receives `contentInsets` written from the safe
    /// area - which is why `topInset` is a parameter here rather than an exotic case.
    private func makeScrollView(documentHeight: CGFloat, viewportHeight: CGFloat,
                                bottomInset: CGFloat = 0, topInset: CGFloat = 0,
                                magnification: CGFloat = 1) -> NSScrollView {
        let scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: 400, height: viewportHeight))
        scrollView.automaticallyAdjustsContentInsets = false
        scrollView.contentInsets = NSEdgeInsets(top: topInset, left: 0, bottom: bottomInset, right: 0)
        let document = FlippedDocument(frame: NSRect(x: 0, y: 0, width: 400, height: documentHeight))
        scrollView.documentView = document
        if magnification != 1 {
            scrollView.allowsMagnification = true
            scrollView.magnification = magnification
        }
        scrollView.layoutSubtreeIfNeeded()
        return scrollView
    }

    private func makeScroller(_ scrollView: NSScrollView) -> ChatTranscriptScroller {
        let scroller = ChatTranscriptScroller()
        scroller.scrollView = scrollView
        return scroller
    }

    /// The property every successful follow must leave true, whatever the insets, the magnification or
    /// the arithmetic that computed the maximum: the end of the document is on screen. It catches the
    /// GROSS failures - a maximum of 0 under a tall document fails it on 4 of the 7 configurations here.
    ///
    /// It is deliberately paired with the exact-offset assertions rather than replacing them, because
    /// it cannot see a small one. Landing on 600 instead of the true 620 under a 20pt bottom inset
    /// still puts `documentVisibleRect.maxY` at 1080, exactly `document.frame.maxY`, so this passes and
    /// only the exact offset catches it. The two assertions fail on different mistakes; keep both.
    private func assertBottomIsVisible(_ scrollView: NSScrollView,
                                       file: StaticString = #filePath, line: UInt = #line) {
        guard let document = scrollView.documentView else { return XCTFail("no document view", file: file, line: line) }
        XCTAssertGreaterThanOrEqual(scrollView.documentVisibleRect.maxY, document.frame.maxY - 0.5,
                                    "the last line of the transcript must be on screen after a follow",
                                    file: file, line: line)
    }

    // MARK: - The follow actually moves the viewport

    /// THE regression test. With the sentinel proposal this returned true with the clip view still at
    /// 0.0 - exactly the observed failure, where the transcript never left the top of the answer.
    func testScrollToBottomMovesTheViewportToTheTrueMaximum() {
        let scrollView = makeScrollView(documentHeight: 1084, viewportHeight: 862)
        let scroller = makeScroller(scrollView)

        XCTAssertEqual(scrollView.contentView.bounds.origin.y, 0, "precondition: starts at the top")
        XCTAssertTrue(scroller.scrollToBottom(), "a flipped document in a live scroll view is scrollable")
        XCTAssertEqual(scrollView.contentView.bounds.origin.y, 222, accuracy: 0.5,
                       "must land on document height minus viewport height, not stay at 0")
        assertBottomIsVisible(scrollView)
    }

    /// The reason this asks AppKit for the maximum instead of computing `document.height -
    /// clip.height`: the naive formula lands short by the bottom inset (600 against a true 620).
    func testScrollToBottomIncludesTheBottomContentInset() {
        let scrollView = makeScrollView(documentHeight: 1080, viewportHeight: 480, bottomInset: 20)
        let scroller = makeScroller(scrollView)

        XCTAssertTrue(scroller.scrollToBottom())
        XCTAssertEqual(scrollView.contentView.bounds.origin.y, 620, accuracy: 0.5,
                       "the inset extends the scrollable range past document height minus viewport")
        assertBottomIsVisible(scrollView)
    }

    /// A transcript shorter than its viewport has nothing to scroll; the follow must be a no-op that
    /// still reports success, so a fresh conversation does not fall through to the proxy on every delta.
    func testShortDocumentStaysAtTheTopAndStillReportsSuccess() {
        let scrollView = makeScrollView(documentHeight: 120, viewportHeight: 862)
        let scroller = makeScroller(scrollView)

        XCTAssertTrue(scroller.scrollToBottom())
        XCTAssertEqual(scrollView.contentView.bounds.origin.y, 0, accuracy: 0.5)
    }

    /// A TOP content inset makes the legal maximum origin NEGATIVE, so a guard that floors its
    /// expectation at zero refuses AppKit's correct answer - for exactly as long as the transcript is
    /// shorter than the viewport, which is the opening of every conversation. SwiftUI writes
    /// `contentInsets` from the safe area, so any host that puts ChatView under a toolbar or in a
    /// full-size-content window is in this case from the first message.
    func testTopContentInsetDoesNotForceTheProxyFallback() {
        let short = makeScrollView(documentHeight: 120, viewportHeight: 862, topInset: 40)
        XCTAssertTrue(makeScroller(short).scrollToBottom(),
                      "a short transcript under a top inset is handled, not punted to the proxy")

        // Just short of the viewport: a legal range of [-40, -2], so there is real travel to make.
        let nearlyFull = makeScrollView(documentHeight: 860, viewportHeight: 862, topInset: 40)
        XCTAssertTrue(makeScroller(nearlyFull).scrollToBottom())
        assertBottomIsVisible(nearlyFull)

        let tall = makeScrollView(documentHeight: 1084, viewportHeight: 862, topInset: 40)
        XCTAssertTrue(makeScroller(tall).scrollToBottom())
        assertBottomIsVisible(tall)
    }

    /// Already at the bottom: no bounds write, because every write emits a geometry sample and the
    /// follow runs once per streaming delta.
    func testAlreadyAtBottomDoesNotTouchTheBounds() {
        let scrollView = makeScrollView(documentHeight: 1084, viewportHeight: 862)
        let scroller = makeScroller(scrollView)
        XCTAssertTrue(scroller.scrollToBottom())

        let settled = scrollView.contentView.bounds.origin.y
        XCTAssertTrue(scroller.scrollToBottom(), "a settled transcript is still 'handled'")
        XCTAssertEqual(scrollView.contentView.bounds.origin.y, settled, accuracy: 0.001)
    }

    /// Growth between follows is chased, not accumulated from a stale maximum.
    func testFollowTracksAGrowingDocument() {
        let scrollView = makeScrollView(documentHeight: 1000, viewportHeight: 400)
        let scroller = makeScroller(scrollView)
        XCTAssertTrue(scroller.scrollToBottom())
        XCTAssertEqual(scrollView.contentView.bounds.origin.y, 600, accuracy: 0.5)

        scrollView.documentView?.setFrameSize(NSSize(width: 400, height: 1600))
        scrollView.layoutSubtreeIfNeeded()
        XCTAssertTrue(scroller.scrollToBottom())
        XCTAssertEqual(scrollView.contentView.bounds.origin.y, 1200, accuracy: 0.5)
        assertBottomIsVisible(scrollView)
    }

    // MARK: - Refusing, so the caller falls back to the proxy

    /// `false` is the contract for "not handled": ChatView answers it by scrolling through
    /// ScrollViewProxy instead. Reporting success while doing nothing is the bug these guard against.
    func testNoScrollViewReportsFailure() {
        XCTAssertFalse(ChatTranscriptScroller().scrollToBottom())
    }

    func testNoDocumentViewReportsFailure() {
        let scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: 400, height: 400))
        XCTAssertFalse(makeScroller(scrollView).scrollToBottom())
    }

    /// The floor guard, tested directly: a clip view that answers every constrain request with
    /// `NSZeroRect` reproduces the shipped bug exactly (a tall document whose maximum comes back 0.0).
    /// The follow must refuse it rather than report success on a viewport it never moved.
    func testAnImplausibleMaximumIsRefusedSoTheProxyTakesOver() {
        final class ZeroRectClipView: NSClipView {
            override func constrainBoundsRect(_ proposedBounds: NSRect) -> NSRect { .zero }
        }
        let scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: 400, height: 862))
        scrollView.automaticallyAdjustsContentInsets = false
        scrollView.contentView = ZeroRectClipView(frame: NSRect(x: 0, y: 0, width: 400, height: 862))
        scrollView.documentView = FlippedDocument(frame: NSRect(x: 0, y: 0, width: 400, height: 1084))
        scrollView.layoutSubtreeIfNeeded()

        XCTAssertTrue(scrollView.contentView.isFlipped, "precondition: past the flipped-document guard")
        XCTAssertFalse(makeScroller(scrollView).scrollToBottom(),
                       "a maximum of 0 under a 1084pt document in an 862pt viewport is not a maximum")
    }

    /// Pins the OTHER half of the lower bound's shape: that it carries no content-inset term.
    ///
    /// `contentInsets` are in scroll-view points while `document.frame` and `clip.bounds` are in the
    /// clip's magnified bounds space, so a bound that adds the inset is in mixed units and lands ABOVE
    /// the true maximum under magnification - which makes it refuse AppKit's correct answer. Here the
    /// 400pt viewport is 200pt of bounds space and the true maximum is 810 (1000 + 20/2 - 200): the
    /// inset-carrying bound would be 820 and reject it, the bound in use is 800 and accepts it.
    ///
    /// SwiftUI's ScrollView does not magnify, so this is latent rather than live. It is here because
    /// the decision is otherwise untested - every inset-carrying variant passes all the other cases.
    func testMagnifiedViewportDoesNotForceTheProxyFallback() {
        let scrollView = makeScrollView(documentHeight: 1000, viewportHeight: 400,
                                        bottomInset: 20, magnification: 2)
        XCTAssertEqual(scrollView.contentView.bounds.height, 200, accuracy: 0.5,
                       "precondition: magnification halves the viewport in bounds space")

        XCTAssertTrue(makeScroller(scrollView).scrollToBottom(),
                      "a mixed-unit bound would put the expected maximum above the real one and refuse")
        XCTAssertEqual(scrollView.contentView.bounds.origin.y, 810, accuracy: 0.5,
                       "the inset is worth bottom/magnification in the clip's bounds space")
    }

    /// A non-flipped document puts the bottom at the LOW end of y, so this function's arithmetic would
    /// scroll to the top and call it success.
    func testNonFlippedDocumentReportsFailure() {
        let scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: 400, height: 400))
        scrollView.automaticallyAdjustsContentInsets = false
        scrollView.documentView = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 1200))
        scrollView.layoutSubtreeIfNeeded()

        XCTAssertFalse(scrollView.contentView.isFlipped, "precondition: an unflipped document")
        XCTAssertFalse(makeScroller(scrollView).scrollToBottom())
    }

    // MARK: - The scroller-width stabilizer

    /// Reserving the vertical scroller is what actually fixed the layout-loop kill; the `.overlay` test
    /// is load-bearing (overlay scrollers take no width and must stay auto-hiding).
    func testStabilizeReservesTheScrollerOnlyForLegacyScrollers() {
        let scrollView = makeScrollView(documentHeight: 1000, viewportHeight: 400)
        scrollView.scrollerStyle = .legacy
        makeScroller(scrollView).stabilizeScrollerWidth()

        XCTAssertTrue(scrollView.hasVerticalScroller)
        XCTAssertFalse(scrollView.autohidesScrollers, "a legacy scroller must be reserved, not autohidden")

        let overlay = makeScrollView(documentHeight: 1000, viewportHeight: 400)
        overlay.scrollerStyle = .overlay
        makeScroller(overlay).stabilizeScrollerWidth()

        XCTAssertTrue(overlay.hasVerticalScroller)
        XCTAssertTrue(overlay.autohidesScrollers, "an overlay scroller takes no width and must keep autohiding")
    }
}

#endif
