import SwiftUI
import AppKit
import Carbon.HIToolbox

// MARK: - Overlay Controller

@MainActor
final class OverlayController {
    static let shared = OverlayController()

    private var window: NSWindow?
    private var hostingView: NSHostingView<OverlayView>?
    private var viewModel: OverlayViewModel?
    var orchestrator: Orchestrator?

    var isVisible: Bool { window?.isVisible ?? false }

    func toggle() {
        if isVisible {
            hide()
        } else {
            show()
        }
    }

    func show() {
        guard let orchestrator else {
            Log.app.warning("Overlay: no orchestrator set")
            return
        }

        if window == nil {
            createWindow(orchestrator: orchestrator)
        }

        // Capture the screen before showing the overlay
        viewModel?.captureScreen()

        guard let screen = NSScreen.main else { return }
        window?.setFrame(screen.frame, display: true)
        window?.makeKeyAndOrderFront(nil)
        window?.orderFrontRegardless()
        Log.app.info("Overlay activated")
    }

    func hide() {
        window?.orderOut(nil)
        viewModel?.dismiss()
        Log.app.info("Overlay dismissed")
    }

    /// Register the overlay hotkey (Cmd+Shift+O) with HotkeyManager.
    func registerHotkey() {
        HotkeyManager.shared.register(
            keyCode: kVK_ANSI_O,
            modifiers: [.maskCommand, .maskShift]
        ) { [weak self] in
            self?.toggle()
        }
    }

    private func createWindow(orchestrator: Orchestrator) {
        let vm = OverlayViewModel(orchestrator: orchestrator)
        vm.onDismiss = { [weak self] in self?.hide() }
        self.viewModel = vm

        let content = OverlayView(viewModel: vm)
        let hosting = NSHostingView(rootView: content)
        self.hostingView = hosting

        let screen = NSScreen.main ?? NSScreen.screens[0]
        let win = NSWindow(
            contentRect: screen.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )

        win.level = .statusBar + 1
        win.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        win.isOpaque = false
        win.backgroundColor = .clear
        win.hasShadow = false
        win.ignoresMouseEvents = false
        win.isReleasedWhenClosed = false
        win.contentView = hosting
        win.acceptsMouseMovedEvents = true

        self.window = win
    }
}
