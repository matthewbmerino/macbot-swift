import SwiftUI

struct MenuBarView: View {
    @Bindable var viewModel: ChatViewModel
    @Environment(\.openWindow) private var openWindow
    @State private var monitor = SystemMonitor()

    var body: some View {
        VStack(spacing: 10) {
            // Hardware monitor
            hardwareMonitor

            Divider()

            // Last message preview
            if let last = viewModel.messages.last(where: { $0.role == .assistant }) {
                Text(String(last.content.prefix(120)))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                Text("Ready. All processing on-device.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Divider()

            // Quick input
            HStack(spacing: 8) {
                TextField("Quick message...", text: $viewModel.inputText)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { viewModel.send() }
                    .disabled(viewModel.isStreaming)

                if viewModel.isStreaming {
                    ProgressView()
                        .controlSize(.small)
                }
            }

            Divider()

            // Actions
            HStack {
                Button("Open Window") {
                    openWindow(id: "main")
                }
                .buttonStyle(.plain)
                .foregroundStyle(Color.accentColor)

                Spacer()

                Text(viewModel.activeAgent.displayName)
                    .font(.caption2)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(.quaternary)
                    .clipShape(Capsule())
            }
        }
        .padding(12)
        .frame(width: 300)
    }

    // MARK: - Hardware Monitor

    private var hardwareMonitor: some View {
        VStack(spacing: 8) {
            HStack {
                Text("SYSTEM")
                    .font(.caption2)
                    .fontWeight(.semibold)
                    .foregroundStyle(.tertiary)
                    .tracking(0.5)
                Spacer()
                Text("\(String(format: "%.1f", monitor.memoryUsedGB)) / \(Int(monitor.memoryTotalGB))GB")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }

            usageBar(label: "CPU", value: monitor.cpuUsage, color: .cyan)
            usageBar(label: "MEM", value: monitor.memoryUsage, color: memoryColor)
            usageBar(label: "GPU", value: monitor.gpuUsage, color: .purple)
        }
    }

    private var memoryColor: Color {
        if monitor.memoryUsage > 0.85 { return .red }
        if monitor.memoryUsage > 0.7 { return .orange }
        return .green
    }

    private func usageBar(label: String, value: Double, color: Color) -> some View {
        HStack(spacing: 8) {
            Text(label)
                .font(.system(size: 9, weight: .medium, design: .monospaced))
                .foregroundStyle(.tertiary)
                .frame(width: 28, alignment: .leading)

            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 3)
                        .fill(.quaternary.opacity(0.3))

                    RoundedRectangle(cornerRadius: 3)
                        .fill(color.opacity(0.8))
                        .frame(width: max(2, geo.size.width * value))
                        .animation(.easeInOut(duration: 0.8), value: value)
                }
            }
            .frame(height: 6)

            Text("\(Int(value * 100))%")
                .font(.system(size: 9, weight: .medium, design: .monospaced))
                .foregroundStyle(.tertiary)
                .frame(width: 28, alignment: .trailing)
        }
    }
}
