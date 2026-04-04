import SwiftUI

// MARK: - Obsidian Design Tokens

private enum Obsidian {
    static let bg = Color(hex: 0x111111)
    static let surface = Color(hex: 0x1A1A1A)
    static let border = Color.white.opacity(0.1)
    static let cornerRadius: CGFloat = 24
    static let innerRadius: CGFloat = 16
}

struct MenuBarView: View {
    @Bindable var viewModel: ChatViewModel
    @Environment(\.openWindow) private var openWindow
    @State private var monitor = SystemMonitor()
    @State private var livePulse = false

    var body: some View {
        VStack(spacing: 14) {
            // Header
            HStack(spacing: 8) {
                Image(systemName: "brain")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.9))

                Text("Macbot")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.9))

                Spacer()

                // Live on-device indicator
                HStack(spacing: 4) {
                    Image(systemName: "dot.radiowaves.left.and.right")
                        .font(.system(size: 8))
                        .foregroundStyle(.green)
                        .opacity(livePulse ? 1.0 : 0.4)

                    Text("On-Device")
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(.green.opacity(0.7))
                }
                .onAppear {
                    withAnimation(.easeInOut(duration: 1.5).repeatForever(autoreverses: true)) {
                        livePulse = true
                    }
                }
            }

            // Gauges
            HStack(spacing: 12) {
                circularGauge(label: "CPU", value: monitor.cpuUsage, color: .cyan)
                circularGauge(
                    label: "MEM", value: monitor.memoryUsage, color: memoryColor,
                    subLabel: "\(String(format: "%.1f", monitor.memoryUsedGB)) / \(Int(monitor.memoryTotalGB))GB"
                )
                circularGauge(label: "GPU", value: monitor.gpuUsage, color: .purple)
            }
            .padding(.vertical, 4)

            separator

            // Last message preview
            if let last = viewModel.messages.last(where: { $0.role == .assistant }) {
                Text(String(last.content.prefix(120)))
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.5))
                    .lineLimit(3)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                Text("Ready. All processing on this Mac.")
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.4))
            }

            separator

            // Quick input capsule
            HStack(spacing: 8) {
                TextField("Quick message...", text: $viewModel.inputText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 11))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)
                    .background(Obsidian.surface)
                    .clipShape(Capsule())
                    .overlay(Capsule().stroke(Obsidian.border, lineWidth: 0.5))
                    .onSubmit { viewModel.send() }
                    .disabled(viewModel.isStreaming)

                if viewModel.isStreaming {
                    ProgressView()
                        .controlSize(.small)
                        .tint(.white.opacity(0.4))
                }
            }

            separator

            // Actions
            HStack {
                Button(action: { openWindow(id: "main") }) {
                    Text("Open Window")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.white.opacity(0.7))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 5)
                        .background(.white.opacity(0.06))
                        .clipShape(Capsule())
                }
                .buttonStyle(.plain)

                Spacer()

                Text(viewModel.activeAgent.displayName)
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(.white.opacity(0.5))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(.white.opacity(0.06))
                    .clipShape(Capsule())
            }
        }
        .padding(16)
        .frame(width: 300)
        .background(Obsidian.bg)
    }

    // MARK: - Circular Gauge

    private func circularGauge(
        label: String, value: Double, color: Color, subLabel: String? = nil
    ) -> some View {
        VStack(spacing: 4) {
            ZStack {
                // Track
                Circle()
                    .stroke(color.opacity(0.1), lineWidth: 3)

                // Fill
                Circle()
                    .trim(from: 0, to: CGFloat(min(value, 1.0)))
                    .stroke(
                        AngularGradient(
                            colors: [color.opacity(0.4), color],
                            center: .center
                        ),
                        style: StrokeStyle(lineWidth: 3, lineCap: .round)
                    )
                    .rotationEffect(.degrees(-90))
                    .animation(.easeInOut(duration: 0.8), value: value)

                // Percentage
                Text("\(Int(value * 100))")
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.8))
            }
            .frame(width: 44, height: 44)

            Text(label)
                .font(.system(size: 8, weight: .semibold, design: .monospaced))
                .foregroundStyle(.white.opacity(0.35))
                .tracking(0.5)

            if let subLabel {
                Text(subLabel)
                    .font(.system(size: 7, weight: .medium, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.25))
            }
        }
        .frame(maxWidth: .infinity)
    }

    private var memoryColor: Color {
        if monitor.memoryUsage > 0.85 { return .red }
        if monitor.memoryUsage > 0.7 { return .orange }
        return .green
    }

    private var separator: some View {
        Rectangle()
            .fill(.white.opacity(0.05))
            .frame(height: 0.5)
    }
}

// MARK: - Hex Color Extension

private extension Color {
    init(hex: UInt, opacity: Double = 1.0) {
        self.init(
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            opacity: opacity
        )
    }
}
