import AppKit
import SwiftUI

/// NSViewRepresentable that captures scroll wheel and magnify events for the canvas.
/// Replaces SwiftUI's DragGesture for pan — this gives us native trackpad momentum,
/// cursor-anchored zoom, and eliminates gesture conflicts with node dragging.
struct CanvasScrollHandler: NSViewRepresentable {
    var onPan: (CGFloat, CGFloat) -> Void
    /// (factor, anchor, animated) — animated is true for discrete mouse-wheel steps.
    var onZoom: (CGFloat, CGPoint, Bool) -> Void
    var onSpacebarChanged: (Bool) -> Void
    var onMouseMoved: (CGPoint) -> Void
    var isSpacebarDown: Bool = false
    var isEdgeModeActive: Bool = false

    func makeNSView(context: Context) -> CanvasScrollNSView {
        let view = CanvasScrollNSView()
        view.onPan = onPan
        view.onZoom = onZoom
        view.onSpacebarChanged = onSpacebarChanged
        view.onMouseMoved = onMouseMoved
        return view
    }

    func updateNSView(_ nsView: CanvasScrollNSView, context: Context) {
        nsView.onPan = onPan
        nsView.onZoom = onZoom
        nsView.onSpacebarChanged = onSpacebarChanged
        nsView.onMouseMoved = onMouseMoved
        nsView.updateCursor(spacebarDown: isSpacebarDown, edgeMode: isEdgeModeActive)
    }
}

/// Custom NSView that intercepts scroll wheel events.
/// - Trackpad two-finger scroll (phase-based) → pan with native momentum
/// - Mouse scroll wheel (discrete, no phase) → zoom toward cursor
/// - Cmd+scroll → zoom toward cursor (both trackpad and mouse)
final class CanvasScrollNSView: NSView {
    var onPan: ((CGFloat, CGFloat) -> Void)?
    var onZoom: ((CGFloat, CGPoint, Bool) -> Void)?
    var onSpacebarChanged: ((Bool) -> Void)?
    var onMouseMoved: ((CGPoint) -> Void)?

    private var flagsMonitor: Any?
    private var spaceDownMonitor: Any?
    private var spaceUpMonitor: Any?

    override var acceptsFirstResponder: Bool { true }
    override var isFlipped: Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil {
            installSpacebarMonitor()
        } else {
            removeSpacebarMonitor()
        }
    }

    /// Track spacebar via local event monitors. These only fire when the
    /// app is active but do NOT steal keys from focused text fields —
    /// we check the first responder before claiming the event.
    private func installSpacebarMonitor() {
        removeSpacebarMonitor()

        spaceDownMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard event.keyCode == 49, // 49 = spacebar
                  !event.isARepeat,
                  self?.isFirstResponderTextField() == false else { return event }
            self?.onSpacebarChanged?(true)
            return nil // consume the event
        }

        spaceUpMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyUp) { [weak self] event in
            guard event.keyCode == 49 else { return event }
            self?.onSpacebarChanged?(false)
            return event
        }
    }

    private func removeSpacebarMonitor() {
        if let m = spaceDownMonitor { NSEvent.removeMonitor(m); spaceDownMonitor = nil }
        if let m = spaceUpMonitor { NSEvent.removeMonitor(m); spaceUpMonitor = nil }
    }

    /// Returns true if the current first responder is a text input (NSTextView, NSTextField).
    private func isFirstResponderTextField() -> Bool {
        guard let responder = window?.firstResponder else { return false }
        return responder is NSTextView || responder is NSTextField
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas { removeTrackingArea(area) }
        addTrackingArea(NSTrackingArea(
            rect: bounds,
            options: [.mouseMoved, .activeInKeyWindow, .inVisibleRect],
            owner: self
        ))
    }

    override func mouseMoved(with event: NSEvent) {
        let location = convert(event.locationInWindow, from: nil)
        onMouseMoved?(location)
    }

    override func mouseDragged(with event: NSEvent) {
        let location = convert(event.locationInWindow, from: nil)
        onMouseMoved?(location)
    }

    deinit {
        removeSpacebarMonitor()
    }

    override func scrollWheel(with event: NSEvent) {
        let cmdHeld = event.modifierFlags.contains(.command)

        if cmdHeld {
            // Cmd+scroll = zoom toward cursor (trackpad or mouse)
            let locationInView = convert(event.locationInWindow, from: nil)
            let zoomDelta = event.scrollingDeltaY
            let factor: CGFloat
            if event.hasPreciseScrollingDeltas {
                // Trackpad with Cmd — smooth, continuous
                factor = 1.0 + zoomDelta * 0.008
            } else {
                // Mouse wheel with Cmd — discrete steps
                factor = zoomDelta > 0 ? 1.15 : 0.87
            }
            let isDiscrete = !event.hasPreciseScrollingDeltas
            onZoom?(factor, locationInView, isDiscrete)
        } else {
            // Bare scroll = always pan (trackpad or mouse wheel)
            let dx: CGFloat
            let dy: CGFloat
            if event.hasPreciseScrollingDeltas {
                // Trackpad — native deltas with momentum
                dx = event.scrollingDeltaX
                dy = event.scrollingDeltaY
            } else {
                // Mouse wheel — scale up the small discrete deltas
                dx = event.scrollingDeltaX * 8
                dy = event.scrollingDeltaY * 8
            }
            onPan?(dx, dy)
        }
    }

    override func magnify(with event: NSEvent) {
        let locationInView = convert(event.locationInWindow, from: nil)
        let factor = 1.0 + event.magnification
        onZoom?(factor, locationInView, false)
    }

    func updateCursor(spacebarDown: Bool, edgeMode: Bool) {
        if spacebarDown {
            NSCursor.openHand.set()
        } else if edgeMode {
            NSCursor.crosshair.set()
        } else {
            NSCursor.arrow.set()
        }
    }

    // Pass through mouse events so SwiftUI handles clicks/drags on nodes
    override func hitTest(_ point: NSPoint) -> NSView? {
        // Only intercept scroll and magnify — let everything else pass through
        guard let event = NSApp.currentEvent else { return nil }
        switch event.type {
        case .scrollWheel, .magnify:
            return self
        default:
            return nil
        }
    }
}
