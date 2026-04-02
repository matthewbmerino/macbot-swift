import SwiftUI

struct OnboardingView: View {
    let client: OllamaClient
    let onComplete: () -> Void

    @State private var isChecking = true
    @State private var isConnected = false
    @State private var models: [ModelInfo] = []
    @State private var errorMessage: String?

    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "brain")
                .font(.system(size: 48))
                .foregroundStyle(Color.accentColor)

            Text("Macbot")
                .font(.largeTitle)
                .fontWeight(.bold)

            Text("Local AI agent — all processing on-device")
                .foregroundStyle(.secondary)

            Divider().padding(.horizontal, 40)

            if isChecking {
                HStack(spacing: 10) {
                    ProgressView().controlSize(.small)
                    Text("Checking Ollama connection...")
                        .foregroundStyle(.secondary)
                }
            } else if isConnected {
                VStack(spacing: 12) {
                    Label("Ollama connected", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)

                    Text("\(models.count) models available")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Button("Get Started") { onComplete() }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                }
            } else {
                VStack(spacing: 12) {
                    Label("Ollama not found", systemImage: "xmark.circle.fill")
                        .foregroundStyle(.red)

                    if let error = errorMessage {
                        Text(error)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    Text("Install Ollama from ollama.com, start it, then relaunch Macbot.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)

                    Button("Retry") { Task { await check() } }
                        .buttonStyle(.bordered)
                }
            }
        }
        .padding(40)
        .frame(width: 400, height: 350)
        .task { await check() }
    }

    private func check() async {
        isChecking = true
        errorMessage = nil

        let reachable = await client.isReachable()
        if reachable {
            do {
                models = try await client.listModels()
                isConnected = true
            } catch {
                errorMessage = error.localizedDescription
                isConnected = false
            }
        } else {
            isConnected = false
            errorMessage = "Cannot reach Ollama at \(client.host)"
        }
        isChecking = false
    }
}
