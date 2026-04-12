import Foundation
import AppKit
import SwiftUI

/// Manages the ghost cursor visual (a floating translucent window) and the
/// narration panel. Provides smooth cursor animation via Core Animation.
@MainActor
final class GhostCursorController {
    static let shared = GhostCursorController()

    private var cursorWindow: NSWindow?
    private var narrationWindow: NSWindow?
    private var narrationHosting: NSHostingView<GhostCursorView>?

    let viewModel = GhostCursorViewModel()

    private let cursorSize: CGFloat = 32

    // MARK: - Public API

    func start(steps: [GhostStep]) {
        showCursorWindow()
        showNarrationPanel()

        Task {
            await viewModel.execute(parsedSteps: steps)
            // Keep narration visible briefly after completion
            try? await Task.sleep(for: .seconds(2))
            if !viewModel.isRunning {
                dismiss()
            }
        }
    }

    func dismiss() {
        cursorWindow?.orderOut(nil)
        narrationWindow?.orderOut(nil)
        cursorWindow = nil
        narrationWindow = nil
        narrationHosting = nil
    }

    /// Animate the ghost cursor to a target point over ~400ms.
    func animateTo(_ target: CGPoint) async {
        guard let cursorWindow else { return }

        let start = cursorWindow.frame.origin
        // Convert target from screen coordinates (top-left origin used by
        // CGEvent / Accessibility) to AppKit coordinates (bottom-left origin).
        let screenHeight = NSScreen.main?.frame.height ?? 900
        let appKitTarget = CGPoint(
            x: target.x - cursorSize / 2,
            y: screenHeight - target.y - cursorSize / 2
        )

        let duration: Double = 0.4
        let frameRate: Double = 60
        let totalFrames = Int(duration * frameRate)

        for frame in 0...totalFrames {
            let t = Double(frame) / Double(totalFrames)
            // Ease-in-out cubic
            let ease = t < 0.5 ? 4 * t * t * t : 1 - pow(-2 * t + 2, 3) / 2
            let x = start.x + (appKitTarget.x - start.x) * ease
            let y = start.y + (appKitTarget.y - start.y) * ease
            cursorWindow.setFrameOrigin(NSPoint(x: x, y: y))
            try? await Task.sleep(for: .milliseconds(Int(1000 / frameRate)))
        }
    }

    // MARK: - Cursor Window

    private func showCursorWindow() {
        if cursorWindow != nil { return }

        let cursorView = NSHostingView(rootView: GhostCursorDot())
        let win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: cursorSize, height: cursorSize),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        win.level = .screenSaver
        win.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        win.isOpaque = false
        win.backgroundColor = .clear
        win.hasShadow = false
        win.ignoresMouseEvents = true
        win.isReleasedWhenClosed = false
        win.contentView = cursorView

        // Start at screen center
        if let screen = NSScreen.main {
            let center = NSPoint(
                x: screen.frame.midX - cursorSize / 2,
                y: screen.frame.midY - cursorSize / 2
            )
            win.setFrameOrigin(center)
        }

        win.makeKeyAndOrderFront(nil)
        win.orderFrontRegardless()
        cursorWindow = win
    }

    // MARK: - Narration Panel

    private func showNarrationPanel() {
        if narrationWindow != nil { return }

        let content = GhostCursorView(viewModel: viewModel)
        let hosting = NSHostingView(rootView: content)
        narrationHosting = hosting

        let win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 380, height: 110),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        win.level = .screenSaver - 1
        win.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        win.isOpaque = false
        win.backgroundColor = .clear
        win.hasShadow = true
        win.ignoresMouseEvents = false
        win.isReleasedWhenClosed = false
        win.contentView = hosting

        // Position at bottom-center of screen
        if let screen = NSScreen.main {
            let x = screen.frame.midX - 190
            let y = screen.frame.minY + 60
            win.setFrameOrigin(NSPoint(x: x, y: y))
        }

        win.makeKeyAndOrderFront(nil)
        win.orderFrontRegardless()
        narrationWindow = win
    }
}

// MARK: - Ghost Cursor Dot (the floating translucent circle)

struct GhostCursorDot: View {
    @State private var pulse = false

    var body: some View {
        Circle()
            .fill(
                RadialGradient(
                    colors: [
                        Color.purple.opacity(0.8),
                        Color.blue.opacity(0.4),
                        Color.clear,
                    ],
                    center: .center,
                    startRadius: 2,
                    endRadius: 16
                )
            )
            .frame(width: 32, height: 32)
            .scaleEffect(pulse ? 1.15 : 1.0)
            .animation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true), value: pulse)
            .onAppear { pulse = true }
    }
}
