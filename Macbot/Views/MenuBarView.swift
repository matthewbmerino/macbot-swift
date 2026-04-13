import SwiftUI

struct MenuBarView: View {
    @Bindable var viewModel: ChatViewModel
    @Environment(\.openWindow) private var openWindow
    private var monitor: SystemMonitor { SystemMonitor.shared }

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack(spacing: MacbotDS.Space.sm) {
                Image(systemName: "cube.transparent")
                    .font(MacbotDS.Typo.heading)
                    .foregroundStyle(.primary)

                Text("macbot")
                    .font(MacbotDS.Typo.heading)
                    .foregroundStyle(.primary)

                Spacer()

                // Live on-device indicator
                LiveIndicator()
            }
            .padding(.bottom, MacbotDS.Space.md)

            // Gauges — isolated in child view so monitor updates don't re-render the full popover
            SystemGaugesView()
                .padding(.vertical, MacbotDS.Space.xs)

            Divider()
                .padding(.vertical, MacbotDS.Space.sm)

            // Last message preview (fixed height to prevent layout shifts)
            Text(lastMessagePreview)
                .font(MacbotDS.Typo.caption)
                .foregroundStyle(.secondary)
                .lineLimit(3)
                .frame(maxWidth: .infinity, minHeight: 16, alignment: .leading)

            Divider()
                .padding(.vertical, MacbotDS.Space.sm)

            // Quick input capsule
            HStack(spacing: MacbotDS.Space.sm) {
                TextField("Quick message...", text: $viewModel.inputText)
                    .textFieldStyle(.plain)
                    .font(MacbotDS.Typo.caption)
                    .padding(.horizontal, MacbotDS.Space.md)
                    .padding(.vertical, MacbotDS.Space.sm)
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
                .padding(.vertical, MacbotDS.Space.sm)

            // Quick actions grid
            FeatureButtonsGrid(openWindow: openWindow, viewModel: viewModel)

            Divider()
                .padding(.vertical, MacbotDS.Space.sm)

            // Footer
            HStack {
                Button(action: { openWindow(id: "main") }) {
                    HStack(spacing: MacbotDS.Space.xs) {
                        Image(systemName: "macwindow")
                            .font(.caption2)
                        Text("Open Chat")
                            .font(MacbotDS.Typo.detail)
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)

                Spacer()

                Text(viewModel.activeAgent.displayName)
                    .font(MacbotDS.Typo.detail)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, MacbotDS.Space.sm)
                    .padding(.vertical, MacbotDS.Space.xs)
                    .background(.fill.tertiary)
                    .clipShape(Capsule())
            }
        }
        .padding(MacbotDS.Space.md)
        .frame(width: 300)
        .fixedSize(horizontal: false, vertical: true)
        .background(MacbotDS.Mat.float)
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
        HStack(spacing: MacbotDS.Space.sm) {
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
            .help("Automate your desktop — type a task after /ghost")
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
            VStack(spacing: MacbotDS.Space.sm) {
                ZStack {
                    RoundedRectangle(cornerRadius: MacbotDS.Radius.sm, style: .continuous)
                        .fill(.fill.tertiary)
                        .frame(width: 40, height: 40)

                    Image(systemName: icon)
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(color)
                        .symbolRenderingMode(.hierarchical)
                }

                Text(label)
                    .font(MacbotDS.Typo.detail)
                    .foregroundStyle(.secondary)
            }
            .padding(.vertical, MacbotDS.Space.sm)
            .frame(maxWidth: .infinity)
            .background(
                RoundedRectangle(cornerRadius: MacbotDS.Radius.sm, style: .continuous)
                    .fill(isHovering ? Color.primary.opacity(0.06) : .clear)
            )
            .contentShape(RoundedRectangle(cornerRadius: MacbotDS.Radius.sm, style: .continuous))
        }
        .buttonStyle(.plain)
        .scaleEffect(isPressed ? 0.93 : 1.0)
        .onHover { isHovering = $0 }
        .simultaneousGesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in isPressed = true }
                .onEnded { _ in isPressed = false }
        )
        .animation(Motion.snappy, value: isHovering)
        .animation(Motion.snappy, value: isPressed)
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

            HStack(spacing: MacbotDS.Space.xs) {
                Image(systemName: "dot.radiowaves.left.and.right")
                    .font(.caption2)
                    .foregroundStyle(MacbotDS.Colors.success)
                    .opacity(opacity)

                Text("On-Device")
                    .font(MacbotDS.Typo.detail)
                    .foregroundStyle(MacbotDS.Colors.success)
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
        HStack(spacing: MacbotDS.Space.md) {
            circularGauge(label: "CPU", value: monitor.cpuUsage, color: MacbotDS.Colors.info)
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
        VStack(spacing: MacbotDS.Space.xs) {
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
                    .font(MacbotDS.Typo.mono)
                    .foregroundStyle(.tertiary)
            }
        }
        .frame(maxWidth: .infinity)
    }

    private var memoryColor: Color {
        if monitor.memoryUsage > 0.85 { return MacbotDS.Colors.danger }
        if monitor.memoryUsage > 0.7 { return MacbotDS.Colors.warning }
        return MacbotDS.Colors.success
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
