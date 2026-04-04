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
    private var monitor: SystemMonitor { SystemMonitor.shared }

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
                LiveIndicator()
            }

            // Gauges — isolated in child view so monitor updates don't re-render the full popover
            SystemGaugesView()
                .padding(.vertical, 4)

            separator

            // Last message preview (fixed height to prevent layout shifts)
            Text(lastMessagePreview)
                .font(.system(size: 11))
                .foregroundStyle(.white.opacity(0.5))
                .lineLimit(3)
                .frame(maxWidth: .infinity, minHeight: 16, alignment: .leading)

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

                ProgressView()
                    .controlSize(.small)
                    .tint(.white.opacity(0.4))
                    .opacity(viewModel.isStreaming ? 1 : 0)
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
        .fixedSize(horizontal: false, vertical: true)
        .background(Obsidian.bg)
        .transaction { $0.animation = nil }  // Kill all implicit animations on this tree
        .onAppear {
            monitor.addObserver()
        }
        .onDisappear {
            monitor.removeObserver()
        }
    }

    private var lastMessagePreview: String {
        if let last = viewModel.messages.last(where: { $0.role == .assistant }) {
            return String(last.content.prefix(120))
        }
        return "Ready. All processing on this Mac."
    }

    private var separator: some View {
        Rectangle()
            .fill(.white.opacity(0.05))
            .frame(height: 0.5)
    }
}

// MARK: - Live Indicator (isolated animation)

/// Uses TimelineView for the pulse instead of withAnimation(.repeatForever)
/// because SwiftUI animation state changes inside MenuBarExtra(.window)
/// cause the popover to re-trigger its entrance transition.
private struct LiveIndicator: View {
    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.05)) { timeline in
            let seconds = timeline.date.timeIntervalSinceReferenceDate
            let opacity = 0.4 + 0.6 * (0.5 + 0.5 * sin(seconds * 2.0))

            HStack(spacing: 4) {
                Image(systemName: "dot.radiowaves.left.and.right")
                    .font(.system(size: 8))
                    .foregroundStyle(.green)
                    .opacity(opacity)

                Text("On-Device")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(.green.opacity(0.7))
            }
        }
    }
}

// MARK: - System Gauges (isolated to prevent popover flicker)

/// Separate view so SystemMonitor @Observable updates only re-render
/// the gauges, not the entire MenuBarExtra popover.
private struct SystemGaugesView: View {
    private var monitor: SystemMonitor { SystemMonitor.shared }

    var body: some View {
        HStack(spacing: 12) {
            circularGauge(label: "CPU", value: monitor.cpuUsage, color: .cyan)
            circularGauge(
                label: "MEM", value: monitor.memoryUsage, color: memoryColor,
                subLabel: "\(String(format: "%.1f", monitor.memoryUsedGB)) / \(Int(monitor.memoryTotalGB))GB"
            )
            circularGauge(label: "GPU", value: monitor.gpuUsage, color: .purple)
        }
    }

    private func circularGauge(
        label: String, value: Double, color: Color, subLabel: String? = nil
    ) -> some View {
        VStack(spacing: 4) {
            ZStack {
                Circle()
                    .stroke(color.opacity(0.1), lineWidth: 3)

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
}

// MARK: - Hex Color Extension

extension Color {
    init(hex: UInt, opacity: Double = 1.0) {
        self.init(
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            opacity: opacity
        )
    }
}
