import SwiftUI

struct MenuBarView: View {
    @Bindable var viewModel: ChatViewModel
    @Environment(\.openWindow) private var openWindow
    private var monitor: SystemMonitor { SystemMonitor.shared }

    var body: some View {
        VStack(spacing: 16) {
            // Header
            HStack(spacing: 8) {
                Image(systemName: "cube.transparent")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)

                Text("macbot")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)

                Spacer()

                // Live on-device indicator
                LiveIndicator()
            }

            // Gauges — isolated in child view so monitor updates don't re-render the full popover
            SystemGaugesView()
                .padding(.vertical, 4)

            Divider()

            // Last message preview (fixed height to prevent layout shifts)
            Text(lastMessagePreview)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(3)
                .frame(maxWidth: .infinity, minHeight: 16, alignment: .leading)

            Divider()

            // Quick input capsule
            HStack(spacing: 8) {
                TextField("Quick message...", text: $viewModel.inputText)
                    .textFieldStyle(.plain)
                    .font(.caption)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(.fill.quaternary)
                    .clipShape(Capsule())
                    .onSubmit { viewModel.send() }
                    .disabled(viewModel.isStreaming)

                ProgressView()
                    .controlSize(.small)
                    .tint(.secondary)
                    .opacity(viewModel.isStreaming ? 1 : 0)
            }

            Divider()

            // Quick actions grid
            FeatureButtonsGrid(openWindow: openWindow, viewModel: viewModel)

            Divider()

            // Footer
            HStack {
                Button(action: { openWindow(id: "main") }) {
                    HStack(spacing: 4) {
                        Image(systemName: "macwindow")
                            .font(.caption2)
                        Text("Open Chat")
                            .font(.caption2.weight(.medium))
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)

                Spacer()

                Text(viewModel.activeAgent.displayName)
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(.fill.tertiary)
                    .clipShape(Capsule())
            }
        }
        .padding(16)
        .frame(width: 300)
        .fixedSize(horizontal: false, vertical: true)
        .background(.ultraThinMaterial)
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
}

// MARK: - Feature Buttons Grid

private struct FeatureButtonsGrid: View {
    let openWindow: OpenWindowAction
    let viewModel: ChatViewModel

    var body: some View {
        HStack(spacing: 8) {
            featureButton(
                icon: "film",
                label: "Director",
                color: .cyan
            ) {
                // Small delay lets the popover dismiss before the
                // Director window appears, avoiding focus conflicts.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                    DirectorLauncher.shared.launch(task: "")
                    if let action = DirectorLauncher.shared.openWindowAction {
                        action("director")
                    }
                }
            }

            featureButton(
                icon: "rectangle.dashed",
                label: "Overlay",
                color: .purple
            ) {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                    OverlayController.shared.show()
                }
            }

            featureButton(
                icon: "sparkle",
                label: "Companion",
                color: .yellow
            ) {
                CompanionController.shared.toggle()
            }

            featureButton(
                icon: "cursorarrow.motionlines",
                label: "Ghost",
                color: .orange
            ) {
                // Ghost needs a task typed in chat, so open the main
                // window with /ghost pre-filled.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                    openWindow(id: "main")
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                        viewModel.inputText = "/ghost "
                    }
                }
            }
        }
    }

    private func featureButton(
        icon: String,
        label: String,
        color: Color,
        action: @escaping () -> Void
    ) -> some View {
        FeatureButton(icon: icon, label: label, color: color, action: action)
    }
}

private struct FeatureButton: View {
    let icon: String
    let label: String
    let color: Color
    let action: () -> Void
    @State private var isHovering = false
    @State private var isPressed = false

    var body: some View {
        Button(action: action) {
            VStack(spacing: 6) {
                ZStack {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(.fill.tertiary)
                        .frame(width: 40, height: 40)

                    Image(systemName: icon)
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(color)
                        .symbolRenderingMode(.hierarchical)
                }

                Text(label)
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.secondary)
            }
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(isHovering ? Color.primary.opacity(0.06) : .clear)
            )
            .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(.plain)
        .scaleEffect(isPressed ? 0.93 : 1.0)
        .onHover { isHovering = $0 }
        .simultaneousGesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in isPressed = true }
                .onEnded { _ in isPressed = false }
        )
        .animation(.spring(response: 0.25, dampingFraction: 0.8), value: isHovering)
        .animation(.spring(response: 0.2, dampingFraction: 0.75), value: isPressed)
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
                    .font(.caption2)
                    .foregroundStyle(.green)
                    .opacity(opacity)

                Text("On-Device")
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.green)
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
                    .stroke(color.opacity(0.15), style: StrokeStyle(lineWidth: 3, lineCap: .round))

                Circle()
                    .trim(from: 0, to: CGFloat(min(value, 1.0)))
                    .stroke(
                        color,
                        style: StrokeStyle(lineWidth: 3, lineCap: .round)
                    )
                    .rotationEffect(.degrees(-90))

                Text("\(Int(value * 100))")
                    .font(.caption.weight(.semibold).monospacedDigit())
                    .foregroundStyle(.primary)
            }
            .frame(width: 44, height: 44)

            Text(label)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)

            if let subLabel {
                Text(subLabel)
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.tertiary)
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
