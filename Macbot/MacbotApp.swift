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
                    OnboardingView(client: appState.orchestrator.client) {
                        Task { await appState.initialize() }
                    }
                } else {
                    ChatView(viewModel: appState.chatViewModel!)
                        .onAppear { appState.authService.recordActivity() }
                        .onChange(of: appState.chatViewModel?.messages.count) { _, _ in
                            appState.authService.recordActivity()
                        }
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
    let orchestrator = Orchestrator()
    let authService = AuthService()
    var chatViewModel: ChatViewModel?
    var isReady = false

    init() {
        // Authenticate first, then initialize
        Task {
            // Wait for auth
            while !authService.isUnlocked {
                try? await Task.sleep(for: .milliseconds(200))
            }
            await initialize()
        }
    }

    func initialize() async {
        let reachable = await orchestrator.client.isReachable()
        if reachable {
            let vm = ChatViewModel(orchestrator: orchestrator)
            await MainActor.run {
                self.chatViewModel = vm
                self.isReady = true
            }
            Log.app.info("Macbot ready")

            Task.detached(priority: .background) { [orchestrator] in
                await orchestrator.prewarm()
            }
        }
    }
}
