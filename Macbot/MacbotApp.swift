import SwiftUI
import AppKit

@main
struct MacbotApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @State private var appState = AppState()

    var body: some Scene {
        MenuBarExtra("Macbot", systemImage: "brain") {
            if appState.isReady, let vm = appState.chatViewModel {
                MenuBarView(viewModel: vm)
            } else {
                VStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Setting up...").font(.caption)
                }
                .padding()
            }
        }
        .menuBarExtraStyle(.window)

        Window("Macbot", id: "main") {
            mainContent
        }

        Settings {
            SettingsView()
        }
    }

    @ViewBuilder
    private var mainContent: some View {
        if !appState.authService.isUnlocked {
            LockScreen(authService: appState.authService)
        } else if !appState.isReady {
            OnboardingView(client: appState.client) { config in
                config.save()
                Task { await appState.initialize(with: config) }
            }
        } else if let vm = appState.chatViewModel {
            ChatView(viewModel: vm)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApplication.shared.setActivationPolicy(.regular)
        NSApplication.shared.activate(ignoringOtherApps: true)
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
    let client = OllamaClient()
    let authService = AuthService()
    var orchestrator: Orchestrator?
    var chatViewModel: ChatViewModel?
    var isReady = false

    init() {
        // Try auto-login
        authService.authenticate()

        // Watch for auth changes and auto-init if config exists
        Task {
            // Poll for auth (simple, reliable)
            while !authService.isUnlocked {
                try? await Task.sleep(for: .milliseconds(300))
            }

            // Auth succeeded — if we have a saved config, go straight to chat
            if let savedConfig = ModelConfig.load() {
                await initialize(with: savedConfig)
            }
            // Otherwise, SwiftUI will show OnboardingView which calls initialize when done
        }
    }

    @MainActor
    func initialize(with config: ModelConfig) async {
        let orch = Orchestrator(modelConfig: config)
        let vm = ChatViewModel(orchestrator: orch)

        self.orchestrator = orch
        self.chatViewModel = vm
        self.isReady = true

        // Quick panel
        QuickPanelController.shared.orchestrator = orch

        // Global hotkey
        HotkeyManager.shared.registerDefaults {
            QuickPanelController.shared.toggle()
        }

        Log.app.info("Macbot ready — general=\(config.general), coder=\(config.coder)")

        // Warm models in background
        Task.detached(priority: .background) {
            await orch.prewarm()
        }
    }
}
