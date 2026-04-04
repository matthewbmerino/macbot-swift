import SwiftUI
import AppKit

@main
struct MacbotApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @State private var appState = AppState()

    var body: some Scene {
        MenuBarExtra("Macbot", systemImage: "brain") {
            MenuBarContent(appState: appState)
        }
        .menuBarExtraStyle(.window)

        Window("Macbot", id: "main") {
            if !appState.authService.isUnlocked {
                LockScreen(authService: appState.authService)
            } else if appState.isReady, let vm = appState.chatViewModel {
                ChatView(viewModel: vm)
            } else {
                ProgressView("Connecting to Ollama...")
                    .frame(width: 300, height: 200)
            }
        }

        Settings {
            SettingsView()
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApplication.shared.setActivationPolicy(.regular)
        NSApplication.shared.activate(ignoringOtherApps: true)

        // Open the main window on launch
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            for window in NSApplication.shared.windows where window.title == "Macbot" {
                window.makeKeyAndOrderFront(nil)
                return
            }
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag {
            for window in sender.windows where window.title == "Macbot" {
                window.makeKeyAndOrderFront(nil)
                return true
            }
        }
        return true
    }
}

@Observable
final class AppState {
    let orchestrator = Orchestrator()
    let authService = AuthService()
    var chatViewModel: ChatViewModel?
    var isReady = false

    init() {
        authService.authenticate()

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
                    HotkeyManager.shared.registerDefaults {
                        QuickPanelController.shared.toggle()
                    }

                    Log.app.info("Macbot ready")
                } else {
                    // Still show the UI — Ollama might start later
                    self.chatViewModel = ChatViewModel(orchestrator: self.orchestrator)
                    self.isReady = true
                    Log.app.warning("Ollama not reachable — running in MLX-only mode")
                }
            }

            // Prewarm models in background (never blocks UI)
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
