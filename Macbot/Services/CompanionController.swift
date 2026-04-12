import SwiftUI
import AppKit

// MARK: - Key-accepting borderless window

/// Borderless NSWindow subclass that accepts keyboard input.
/// Without this, TextField inside a borderless floating window
/// silently drops all keystrokes because the window refuses
/// first-responder status.
private class KeyableWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

// MARK: - Companion Window Controller

@MainActor
final class CompanionController {
    static let shared = CompanionController()

    private var window: NSWindow?
    private var hostingView: NSHostingView<CompanionView>?
    let viewModel = CompanionViewModel()
    var orchestrator: Orchestrator?

    var isVisible: Bool { viewModel.isVisible }

    func toggle() {
        if isVisible { hide() } else { show() }
    }

    /// Tracks whether this is the first show since app launch.
    private var hasShownBefore = false

    func show() {
        if window == nil { createWindow() }

        guard let window else { return }
        guard let screen = NSScreen.main else { return }

        if hasShownBefore {
            // Return to saved position
            window.setFrameOrigin(NSPoint(
                x: viewModel.position.x - 70,
                y: viewModel.position.y - 70
            ))
            window.makeKeyAndOrderFront(nil)
            window.orderFrontRegardless()
        } else {
            // First launch: appear in screen center, then glide to corner
            hasShownBefore = true
            let screenCenter = NSPoint(
                x: screen.frame.midX - 70,
                y: screen.frame.midY - 70
            )
            window.setFrameOrigin(screenCenter)
            window.alphaValue = 0
            window.makeKeyAndOrderFront(nil)
            window.orderFrontRegardless()

            // Fade in at center
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.4
                ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
                window.animator().alphaValue = 1.0
            }

            // After a beat, glide to the bottom-right corner
            let cornerOrigin = NSPoint(
                x: screen.visibleFrame.maxX - 160,
                y: screen.visibleFrame.minY + 20
            )
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                NSAnimationContext.runAnimationGroup { ctx in
                    ctx.duration = 0.8
                    ctx.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                    window.animator().setFrameOrigin(cornerOrigin)
                }
                // Update saved position to the corner
                self?.viewModel.position = CGPoint(
                    x: cornerOrigin.x + 70,
                    y: cornerOrigin.y + 70
                )
            }
        }

        viewModel.start()
        observeChatState()
    }

    private func observeChatState() {
        // Poll-free: SwiftUI @Observable handles the view resize;
        // we just need to resize the NSWindow to match.
        Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] timer in
            guard let self else { timer.invalidate(); return }
            guard self.isVisible else { timer.invalidate(); return }
            guard let window = self.window else { return }

            let targetSize = self.viewModel.isChatOpen
                ? NSSize(width: 320, height: 440)
                : NSSize(width: 140, height: 140)

            if abs(window.frame.width - targetSize.width) > 1 {
                var frame = window.frame
                let heightDelta = targetSize.height - frame.height
                frame.size = targetSize
                frame.origin.y -= heightDelta  // grow downward
                window.setFrame(frame, display: true, animate: true)
            }
        }
    }

    func hide() {
        window?.orderOut(nil)
        viewModel.stop()
    }

    // MARK: - Window Creation

    private func createWindow() {
        let content = CompanionView(viewModel: viewModel)
        let hosting = NSHostingView(rootView: content)
        self.hostingView = hosting

        let w = KeyableWindow(
            contentRect: NSRect(x: 0, y: 0, width: 140, height: 140),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )

        w.isOpaque = false
        w.backgroundColor = .clear
        w.hasShadow = false
        w.level = .floating
        w.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        w.isMovableByWindowBackground = true
        w.isReleasedWhenClosed = false
        w.ignoresMouseEvents = false
        w.contentView = hosting

        // Track position when dragged
        NotificationCenter.default.addObserver(
            forName: NSWindow.didMoveNotification,
            object: w,
            queue: .main
        ) { [weak self] _ in
            guard let self, let frame = self.window?.frame else { return }
            self.viewModel.position = CGPoint(
                x: frame.midX,
                y: frame.midY
            )
        }

        self.window = w
    }
}
