import SwiftUI
import AppKit

/// Transparent overlay that turns a **right-button drag** across a plot into a
/// horizontal zoom selection, and **Escape** into "back to full range".
///
/// Right button rather than left for two reasons: left-drag is already the
/// gate/cursor gesture on the IR plot, and SwiftUI's `DragGesture` only ever
/// tracks the left button — so the right button needs an AppKit event monitor
/// either way. Same shape as `ScrollZoomCatcher`: a local monitor rather than
/// intercepting the responder chain, and `hitTest` returns nil, so left clicks,
/// hover and pinch still reach the SwiftUI Canvas underneath untouched.
struct DragZoomCatcher: NSViewRepresentable {
    /// (startX, currentX, viewSize) on every tick while the button is held.
    var onDragChanged: (CGFloat, CGFloat, CGSize) -> Void
    /// (startX, endX, viewSize) on release.
    var onDragEnded: (CGFloat, CGFloat, CGSize) -> Void
    /// Escape pressed while this plot is on screen. Return true if it was acted
    /// on — the event is only consumed then, so Esc keeps working normally
    /// everywhere else when there's no zoom to undo.
    var onEscape: () -> Bool

    func makeNSView(context: Context) -> MonitorView {
        let v = MonitorView()
        v.apply(self)
        return v
    }

    func updateNSView(_ nsView: MonitorView, context: Context) {
        nsView.apply(self)
    }

    static func dismantleNSView(_ nsView: MonitorView, coordinator: ()) {
        nsView.removeMonitors()
    }

    final class MonitorView: NSView {
        var onDragChanged: ((CGFloat, CGFloat, CGSize) -> Void)?
        var onDragEnded: ((CGFloat, CGFloat, CGSize) -> Void)?
        var onEscape: (() -> Bool)?

        private var mouseMonitor: Any?
        private var keyMonitor: Any?
        /// Non-nil only between right-mouse-down inside the plot and its release.
        private var dragStartX: CGFloat?

        override var isFlipped: Bool { true } // top-left origin, matches SwiftUI

        func apply(_ config: DragZoomCatcher) {
            onDragChanged = config.onDragChanged
            onDragEnded = config.onDragEnded
            onEscape = config.onEscape
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            removeMonitors()
            guard window != nil else { return }

            mouseMonitor = NSEvent.addLocalMonitorForEvents(
                matching: [.rightMouseDown, .rightMouseDragged, .rightMouseUp]
            ) { [weak self] event in
                guard let self, let window = self.window, event.window === window,
                      self.bounds.width > 0
                else { return event }
                let loc = self.convert(event.locationInWindow, from: nil)

                switch event.type {
                case .rightMouseDown:
                    // Only start a selection that began inside the plot; a
                    // right-click elsewhere in the window is none of our business.
                    guard self.bounds.contains(loc) else { return event }
                    self.dragStartX = loc.x
                    return nil

                case .rightMouseDragged:
                    // Dragging past the edge is normal — clamp rather than drop it,
                    // so a selection can run right up to the axis limits.
                    guard let start = self.dragStartX else { return event }
                    self.onDragChanged?(start, self.clampedX(loc.x), self.bounds.size)
                    return nil

                case .rightMouseUp:
                    guard let start = self.dragStartX else { return event }
                    self.dragStartX = nil
                    self.onDragEnded?(start, self.clampedX(loc.x), self.bounds.size)
                    return nil

                default:
                    return event
                }
            }

            keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self, let window = self.window, event.window === window,
                      event.keyCode == 53 // Escape
                else { return event }
                return (self.onEscape?() ?? false) ? nil : event
            }
        }

        deinit { removeMonitors() }

        func removeMonitors() {
            if let m = mouseMonitor { NSEvent.removeMonitor(m); mouseMonitor = nil }
            if let m = keyMonitor { NSEvent.removeMonitor(m); keyMonitor = nil }
            dragStartX = nil
        }

        private func clampedX(_ x: CGFloat) -> CGFloat { min(max(x, 0), bounds.width) }

        // Never intercept mouse hits — left clicks/drags/hover pass to the Canvas below.
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}
