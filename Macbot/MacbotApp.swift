import SwiftUI
import AppKit

@main
struct MacbotApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @State private var appState = AppState()

    var body: some Scene {
        MenuBarExtra("Macbot", systemImage: "brain") {
            if appState.authService.isUnlocked, let vm = appState.chatViewModel {
                MenuBarView(viewModel: vm)
            } else {
                VStack(spacing: 8) {
                    Image(systemName: "lock.shield.fill")
                        .foregroundStyle(.secondary)
                    Button("Unlock") { appState.authService.authenticate() }
                        .buttonStyle(.plain)
                        .foregroundStyle(Color.accentColor)
                }
                .padding()
            }
        }
        .menuBarExtraStyle(.window)

        Window("Macbot", id: "main") {
            Group {
                if !appState.authService.isUnlocked {
                    LockScreen(authService: appState.authService)
                } else if !appState.isReady {
                    OnboardingView(client: appState.client) { config in
                        Task { await appState.initialize(with: config) }
                    }
                } else {
                    ChatView(viewModel: appState.chatViewModel!)
                }
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
        Task {
            while !authService.isUnlocked {
                try? await Task.sleep(for: .milliseconds(200))
            }

            // If setup was done before, load saved config and skip wizard
            if let savedConfig = ModelConfig.load() {
                await initialize(with: savedConfig)
            }
            // Otherwise, OnboardingView will call initialize(with:) after setup
        }
    }

    func initialize(with config: ModelConfig) async {
        let orch = Orchestrator(modelConfig: config)

        let vm = ChatViewModel(orchestrator: orch)
        await MainActor.run {
            self.orchestrator = orch
            self.chatViewModel = vm
            self.isReady = true
        }

        // Quick panel
        QuickPanelController.shared.orchestrator = orch

        // Global hotkey
        HotkeyManager.shared.registerDefaults {
            QuickPanelController.shared.toggle()
        }

        Log.app.info("Macbot ready with config: general=\(config.general), coder=\(config.coder)")

        Task.detached(priority: .background) {
            await orch.prewarm()
        }
    }
}
