import SwiftUI

struct OnboardingView: View {
    let client: OllamaClient
    let onComplete: (ModelConfig) -> Void

    @State private var step = 0
    @State private var hardware: HardwareProfile?
    @State private var ollamaConnected = false
    @State private var installedModels: [String] = []
    @State private var recommendation: ModelRecommendation?
    @State private var pullingModel: String?
    @State private var pullProgress: Double = 0
    @State private var isChecking = false
    @State private var error: String?

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack(spacing: 12) {
                Image(systemName: "cube.transparent")
                    .font(.title)
                    .foregroundStyle(Color.accentColor)
                VStack(alignment: .leading) {
                    Text("Macbot Setup")
                        .font(.title2)
                        .fontWeight(.semibold)
                    Text("Step \(step + 1) of 4")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(24)

            Divider()

            // Content
            Group {
                switch step {
                case 0: hardwareStep
                case 1: ollamaStep
                case 2: modelsStep
                case 3: readyStep
                default: readyStep
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(24)
        }
        .frame(width: 520, height: 480)
        .task { detectHardware() }
    }

    // MARK: - Step 1: Hardware Detection

    private var hardwareStep: some View {
        VStack(spacing: 20) {
            if let hw = hardware {
                VStack(spacing: 16) {
                    Image(systemName: "desktopcomputer")
                        .font(.system(size: 36))
                        .foregroundStyle(.secondary)

                    Text("Your Mac")
                        .font(.headline)

                    VStack(spacing: 8) {
                        infoRow("Chip", hw.chipName)
                        infoRow("Memory", hw.ramDescription)
                        infoRow("Architecture", hw.architecture)
                        infoRow("Available for AI", "\(String(format: "%.0f", hw.availableForModels))GB (after OS reserve)")
                    }
                    .padding()
                    .background(.quaternary.opacity(0.3))
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                }

                Spacer()

                Button("Continue") { step = 1 }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
            } else {
                ProgressView("Detecting hardware...")
            }
        }
    }

    // MARK: - Step 2: Ollama Check

    private var ollamaStep: some View {
        VStack(spacing: 20) {
            if isChecking {
                ProgressView("Checking Ollama...")
            } else if ollamaConnected {
                VStack(spacing: 12) {
                    Label("Ollama connected", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                        .font(.headline)

                    Text("\(installedModels.count) models installed")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Button("Continue") {
                    generateRecommendation()
                    step = 2
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
            } else {
                VStack(spacing: 12) {
                    Label("Ollama not found", systemImage: "xmark.circle.fill")
                        .foregroundStyle(.red)
                        .font(.headline)

                    Text("Install Ollama from ollama.com, start it, then click Retry.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)

                    if let error {
                        Text(error)
                            .font(.caption2)
                            .foregroundStyle(.red)
                    }
                }

                Spacer()

                HStack(spacing: 12) {
                    Button("Open ollama.com") {
                        NSWorkspace.shared.open(URL(string: "https://ollama.com")!)
                    }
                    .buttonStyle(.bordered)

                    Button("Retry") { Task { await checkOllama() } }
                        .buttonStyle(.borderedProminent)
                }
            }
        }
        .task { await checkOllama() }
    }

    // MARK: - Step 3: Model Recommendations

    private var modelsStep: some View {
        VStack(spacing: 16) {
            if let rec = recommendation, let hw = hardware {
                Text("Recommended for your \(Int(hw.totalRAM))GB Mac")
                    .font(.headline)

                ScrollView {
                    VStack(spacing: 8) {
                        // Always included
                        modelRow("Router", rec.config.router, ModelRecommender.routerModel.estimatedRAM, installed: true)
                        modelRow("Embedding", rec.config.embedding, ModelRecommender.embeddingModel.estimatedRAM, installed: true)

                        // Recommended models
                        ForEach(Array(rec.selectedModels.enumerated()), id: \.offset) { _, item in
                            let isInstalled = installedModels.contains(where: { $0 == item.1 || $0.hasPrefix(item.1) })
                            modelRow(item.0.displayName, item.1, item.2, installed: isInstalled)
                        }

                        // Skipped roles
                        ForEach(Array(rec.skippedRoles.enumerated()), id: \.offset) { _, item in
                            HStack {
                                Text(item.0.displayName)
                                    .font(.caption)
                                    .fontWeight(.medium)
                                Spacer()
                                Text("Skipped")
                                    .font(.caption2)
                                    .foregroundStyle(.orange)
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                        }

                        Divider()

                        HStack {
                            Text("Estimated total")
                                .font(.caption)
                                .fontWeight(.medium)
                            Spacer()
                            Text("\(String(format: "%.1f", rec.totalEstimatedRAM))GB of \(String(format: "%.0f", hw.availableForModels))GB available")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .padding(.horizontal, 12)
                    }
                }

                // Pull status
                if let pulling = pullingModel {
                    VStack(spacing: 6) {
                        Text("Downloading \(pulling)...")
                            .font(.caption)
                        ProgressView(value: pullProgress)
                            .progressViewStyle(.linear)
                    }
                    .padding(.top, 8)
                }

                Spacer()

                HStack(spacing: 12) {
                    Button("Pull Missing Models") {
                        Task { await pullMissingModels() }
                    }
                    .buttonStyle(.bordered)
                    .disabled(pullingModel != nil)

                    Button("Continue") {
                        rec.config.save()
                        step = 3
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                }
            }
        }
    }

    // MARK: - Step 4: Ready

    private var readyStep: some View {
        VStack(spacing: 20) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 48))
                .foregroundStyle(.green)

            Text("Setup Complete")
                .font(.title2)
                .fontWeight(.semibold)

            if let hw = hardware {
                Text("Macbot is configured for your \(hw.chipName) with \(Int(hw.totalRAM))GB memory.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }

            Text("All processing happens on this machine. Nothing leaves your network.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)

            Spacer()

            Button("Start Chatting") {
                if let config = recommendation?.config {
                    onComplete(config)
                } else {
                    onComplete(ModelConfig())
                }
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
        }
    }

    // MARK: - Helpers

    private func infoRow(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 120, alignment: .trailing)
            Text(value)
                .font(.caption)
                .fontWeight(.medium)
            Spacer()
        }
    }

    private func modelRow(_ role: String, _ name: String, _ ram: Double, installed: Bool) -> some View {
        HStack {
            Text(role)
                .font(.caption)
                .fontWeight(.medium)
                .frame(width: 80, alignment: .leading)
            Text(name)
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            Text("\(String(format: "%.1f", ram))GB")
                .font(.caption2)
                .foregroundStyle(.tertiary)
            Image(systemName: installed ? "checkmark.circle.fill" : "arrow.down.circle")
                .font(.caption)
                .foregroundStyle(installed ? .green : .orange)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
    }

    // MARK: - Actions

    private func detectHardware() {
        hardware = HardwareDetector.detect()
    }

    private func checkOllama() async {
        isChecking = true
        error = nil
        ollamaConnected = await client.isReachable()
        if ollamaConnected {
            do {
                let models = try await client.listModels()
                installedModels = models.map(\.name)
            } catch {
                self.error = error.localizedDescription
            }
        }
        isChecking = false
    }

    private func generateRecommendation() {
        guard let hw = hardware else { return }
        recommendation = ModelRecommender.recommend(for: hw)
    }

    private func pullMissingModels() async {
        guard let rec = recommendation else { return }

        let allNeeded = rec.config.allModels
        for model in allNeeded {
            let installed = installedModels.contains { $0 == model || $0.hasPrefix(model) }
            if !installed {
                pullingModel = model
                pullProgress = 0

                do {
                    for try await progress in client.pullModel(model) {
                        await MainActor.run { pullProgress = progress }
                    }
                    installedModels.append(model)
                } catch {
                    Log.app.error("Failed to pull \(model): \(error)")
                }
            }
        }
        pullingModel = nil
    }
}
