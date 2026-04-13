import SwiftUI
import AppKit

@main
struct MacbotApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @State private var appState = AppState()
    @Environment(\.openWindow) private var openWindow

    var body: some Scene {
        MenuBarExtra("macbot", systemImage: "cube.transparent") {
            MenuBarContent(appState: appState)
        }
        .menuBarExtraStyle(.window)

        Window("macbot", id: "main") {
            Group {
                if !appState.authService.isUnlocked {
                    LockScreen(authService: appState.authService)
                } else if appState.isReady, let vm = appState.chatViewModel {
                    ChatView(viewModel: vm)
                } else {
                    ProgressView("Connecting to Ollama...")
                        .frame(width: 300, height: 200)
                }
            }
            .onAppear {
                // Wire Director launcher to SwiftUI's openWindow action
                DirectorLauncher.shared.openWindowAction = { [openWindow] id in
                    openWindow(id: id)
                }
                // Ensure the window is visible and focused
                DispatchQueue.main.async {
                    NSApplication.shared.activate(ignoringOtherApps: true)
                    for window in NSApplication.shared.windows where window.title == "macbot" {
                        window.makeKeyAndOrderFront(nil)
                    }
                }
            }
        }
        .applyDefaultLaunchBehavior()

        Window("Director", id: "director") {
            DirectorView(orchestrator: appState.orchestrator)
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1200, height: 800)

        Settings {
            SettingsView()
        }
        .commands {
            CommandGroup(after: .toolbar) {
                Button("Toggle Overlay") { OverlayController.shared.toggle() }
                    .keyboardShortcut("o", modifiers: [.command, .shift])
                Button("Open Director") {
                    DirectorLauncher.shared.launch(task: "")
                    if let action = DirectorLauncher.shared.openWindowAction {
                        action("director")
                    }
                }
                    .keyboardShortcut("d", modifiers: [.command, .shift])
                Button("Toggle Companion") { CompanionController.shared.toggle() }
                    .keyboardShortcut("k", modifiers: [.command, .shift])
            }
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApplication.shared.setActivationPolicy(.regular)
        NSApplication.shared.activate(ignoringOtherApps: true)
        setAppIcon()
        showMainWindow()

        // Start ambient context loop — gives the assistant continuous awareness
        // of active app, idle time, battery, etc.
        Task { await AmbientMonitor.shared.start() }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { showMainWindow() }
        return true
    }

    private func setAppIcon() {
        // Set the dock icon from the bundled .icns, or fall back to the Assets
        // directory for unbundled debug runs.
        let candidates = [
            Bundle.main.url(forResource: "AppIcon", withExtension: "icns"),
            Bundle.main.resourceURL?
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("Assets/AppIcon.icns")
        ]
        for case let url? in candidates {
            if let icon = NSImage(contentsOf: url) {
                NSApplication.shared.applicationIconImage = icon
                return
            }
        }
    }

    private func showMainWindow() {
        // Retry until the SwiftUI Window scene has created the NSWindow
        func attempt(_ remaining: Int) {
            for window in NSApplication.shared.windows where window.title == "macbot" {
                window.makeKeyAndOrderFront(nil)
                NSApplication.shared.activate(ignoringOtherApps: true)
                return
            }
            if remaining > 0 {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                    attempt(remaining - 1)
                }
            }
        }
        attempt(10)
    }
}

@Observable
final class AppState {
    let orchestrator: Orchestrator = {
        let config = HardwareScanner.recommendedConfig()
        return Orchestrator(modelConfig: config, soulPrompt: SoulLoader.load())
    }()
    let authService = AuthService()
    var chatViewModel: ChatViewModel?
    var isReady = false

    init() {
        // Refresh the model tier table in the background (every 30 days).
        // This lets us update model recommendations without shipping a new binary.
        HardwareScanner.refreshTierTableInBackground()

        // Auth is triggered exclusively by LockScreen.onAppear (the main
        // window's gated content). Triggering it here as well caused two
        // Touch ID prompts on launch — one tied to the menu bar's AppState
        // init path, one tied to the main window's LockScreen appearing.
        Task.detached { [weak self] in
            guard let self else { return }

            while !self.authService.isUnlocked {
                try? await Task.sleep(for: .milliseconds(300))
            }

            // Check Ollama reachability off the main thread
            let reachable = await self.orchestrator.client.isReachable()

            // Hop to main thread only for UI state updates
            await MainActor.run {
                if reachable {
                    self.chatViewModel = ChatViewModel(orchestrator: self.orchestrator)
                    self.isReady = true

                    QuickPanelController.shared.orchestrator = self.orchestrator
                    OverlayController.shared.orchestrator = self.orchestrator
                    CompanionController.shared.orchestrator = self.orchestrator
                    HotkeyManager.shared.registerDefaults {
                        QuickPanelController.shared.toggle()
                    }
                    OverlayController.shared.registerHotkey()

                    Log.app.info("Macbot ready")
                } else {
                    // Still show the UI — Ollama might start later
                    self.chatViewModel = ChatViewModel(orchestrator: self.orchestrator)
                    self.isReady = true
                    Log.app.warning("Ollama not reachable — running in MLX-only mode")
                }
            }

            // Validate models exist, then prewarm
            await self.orchestrator.validateModels()
            await self.orchestrator.prewarm()
        }
    }
}

/// Stable wrapper for MenuBarExtra content.
/// Renders a fixed-size frame immediately so the .window popover never
/// re-animates its entrance when @Observable state changes inside.
struct MenuBarContent: View {
    let appState: AppState

    var body: some View {
        Group {
            if appState.isReady, let vm = appState.chatViewModel {
                MenuBarView(viewModel: vm)
            } else {
                VStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Connecting...").font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding()
                .frame(width: 300, height: 200)
            }
        }
        .frame(width: 300)
        .animation(nil, value: appState.isReady)
    }
}

// MARK: - Window Launch Behavior

extension Scene {
    /// On macOS 15+, tells SwiftUI to show the window on launch.
    /// On older macOS, no-op (AppDelegate handles it via retry loop).
    func applyDefaultLaunchBehavior() -> some Scene {
        if #available(macOS 15.0, *) {
            return self.defaultLaunchBehavior(.presented)
        } else {
            return self
        }
    }
}
