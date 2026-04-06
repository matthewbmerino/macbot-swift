import SwiftUI

struct SettingsView: View {
    @AppStorage("ollamaHost") private var ollamaHost = "http://127.0.0.1:11434"

    var body: some View {
        TabView {
            generalTab
                .tabItem { Label("General", systemImage: "gear") }

            modelsTab
                .tabItem { Label("Models", systemImage: "cpu") }

            hardwareTab
                .tabItem { Label("Hardware", systemImage: "desktopcomputer") }
        }
        .frame(width: 480, height: 350)
        .padding()
    }

    private var generalTab: some View {
        Form {
            Section("Ollama Connection") {
                TextField("Host", text: $ollamaHost)
                    .textFieldStyle(.roundedBorder)
            }
        }
    }

    private var modelsTab: some View {
        let config = ModelConfig.load() ?? ModelConfig()
        return Form {
            Section("Current Model Assignments") {
                LabeledContent("General") { Text(config.general).foregroundStyle(.secondary) }
                LabeledContent("Coder") { Text(config.coder.isEmpty ? "Disabled" : config.coder).foregroundStyle(config.coder.isEmpty ? .orange : .secondary) }
                LabeledContent("Vision") { Text(config.vision.isEmpty ? "Disabled" : config.vision).foregroundStyle(config.vision.isEmpty ? .orange : .secondary) }
                LabeledContent("Reasoner") { Text(config.reasoner.isEmpty ? "Disabled" : config.reasoner).foregroundStyle(config.reasoner.isEmpty ? .orange : .secondary) }
                LabeledContent("Router") { Text(config.router).foregroundStyle(.secondary) }
            }

            Section {
                Button("Reconfigure Models") {
                    // Clear saved config to re-trigger setup wizard on next launch
                    UserDefaults.standard.removeObject(forKey: "com.macbot.modelConfig")
                    NSApplication.shared.terminate(nil)
                }
                .foregroundStyle(.red)

                Text("This will restart the app and run the setup wizard to detect your hardware and recommend optimal models.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
    }

    private var hardwareTab: some View {
        let hw = HardwareDetector.detect()
        return Form {
            Section("Detected Hardware") {
                LabeledContent("Chip") { Text(hw.chipName) }
                LabeledContent("Memory") { Text(hw.ramDescription) }
                LabeledContent("Architecture") { Text(hw.architecture) }
                LabeledContent("Available for AI") { Text("\(String(format: "%.0f", hw.availableForModels))GB") }
            }
        }
    }
}
