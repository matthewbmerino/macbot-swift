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
                    Text("Connecting...").font(.caption)
                }
                .padding()
            }
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

        Task {
            while !authService.isUnlocked {
                try? await Task.sleep(for: .milliseconds(300))
            }
            await initialize()
        }
    }

    @MainActor
    func initialize() async {
        let reachable = await orchestrator.client.isReachable()
        if reachable {
            self.chatViewModel = ChatViewModel(orchestrator: orchestrator)
            self.isReady = true

            QuickPanelController.shared.orchestrator = orchestrator
            HotkeyManager.shared.registerDefaults {
                QuickPanelController.shared.toggle()
            }

            Log.app.info("Macbot ready")

            Task.detached(priority: .background) { [orchestrator = self.orchestrator] in
                await orchestrator.prewarm()
            }
        }
    }
}
