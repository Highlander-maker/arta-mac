import SwiftUI
import AppKit

/// Transparent overlay that forwards scroll-wheel events (mouse wheel or
/// trackpad) to the plot for ARTA-style zoom under the pointer. It uses a local
/// event monitor rather than intercepting the responder chain, and its
/// `hitTest` returns nil, so mouse clicks / drags / pinch still reach the
/// SwiftUI Canvas underneath untouched.
struct ScrollZoomCatcher: NSViewRepresentable {
    /// (deltaY, deltaX, precise, locationInView, viewSize, shiftDown)
    var onScroll: (CGFloat, CGFloat, Bool, CGPoint, CGSize, Bool) -> Void

    func makeNSView(context: Context) -> MonitorView {
        let v = MonitorView()
        v.onScroll = onScroll
        return v
    }

    func updateNSView(_ nsView: MonitorView, context: Context) {
        nsView.onScroll = onScroll
    }

    static func dismantleNSView(_ nsView: MonitorView, coordinator: ()) {
        nsView.removeMonitor()
    }

    final class MonitorView: NSView {
        var onScroll: ((CGFloat, CGFloat, Bool, CGPoint, CGSize, Bool) -> Void)?
        private var monitor: Any?

        override var isFlipped: Bool { true } // top-left origin, matches SwiftUI

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            removeMonitor()
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
                guard let self, let window = self.window, event.window === window else { return event }
                let locView = self.convert(event.locationInWindow, from: nil)
                guard self.bounds.contains(locView) else { return event }
                self.onScroll?(
                    event.scrollingDeltaY, event.scrollingDeltaX,
                    event.hasPreciseScrollingDeltas, locView, self.bounds.size,
                    event.modifierFlags.contains(.shift))
                return nil // consume so the window/page doesn't also scroll
            }
        }

        deinit { removeMonitor() }

        func removeMonitor() {
            if let m = monitor { NSEvent.removeMonitor(m); monitor = nil }
        }

        // Never intercept mouse hits — clicks/drags pass to the Canvas below.
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}
