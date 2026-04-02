import SwiftUI

@main
struct MacbotApp: App {
    @State private var appState = AppState()

    var body: some Scene {
        MenuBarExtra("Macbot", systemImage: "brain") {
            if appState.isReady {
                MenuBarView(viewModel: appState.chatViewModel!)
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
            Group {
                if !appState.isReady {
                    OnboardingView(client: appState.orchestrator.client) {
                        Task { await appState.initialize() }
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

@Observable
final class AppState {
    let orchestrator = Orchestrator()
    var chatViewModel: ChatViewModel?
    var isReady = false

    init() {
        Task { await initialize() }
    }

    func initialize() async {
        let reachable = await orchestrator.client.isReachable()
        if reachable {
            await orchestrator.prewarm()
            let vm = ChatViewModel(orchestrator: orchestrator)
            await MainActor.run {
                self.chatViewModel = vm
                self.isReady = true
            }
            Log.app.info("Macbot ready")
        }
    }
}
