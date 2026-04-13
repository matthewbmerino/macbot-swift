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
                label: "Director"
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
                label: "Overlay"
            ) {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                    OverlayController.shared.show()
                }
            }

            featureButton(
                icon: "sparkle",
                label: "Companion"
            ) {
                CompanionController.shared.toggle()
            }

            featureButton(
                icon: "cursorarrow.motionlines",
                label: "Ghost"
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
        action: @escaping () -> Void
    ) -> some View {
        FeatureButton(icon: icon, label: label, action: action)
    }
}

private struct FeatureButton: View {
    let icon: String
    let label: String
    let action: () -> Void
    @State private var isHovering = false
    @State private var isPressed = false

    var body: some View {
        Button(action: action) {
            VStack(spacing: 6) {
                ZStack {
                    RoundedRectangle(cornerRadius: MacbotDS.Radius.sm, style: .continuous)
                        .fill(.fill.tertiary)
                        .frame(width: 40, height: 40)

                    Image(systemName: icon)
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.primary.opacity(isHovering ? 0.85 : 0.5))
                        .symbolRenderingMode(.hierarchical)
                }

                Text(label)
                    .font(.system(size: 8, weight: .semibold, design: .rounded))
                    .foregroundStyle(.tertiary)
                    .tracking(0.3)
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

    /// Single accent — white at low opacity. Tints warmer only when
    /// a value enters the danger zone. No rainbow of gauge colors.
    private static let arcColor = Color.primary

    var body: some View {
        HStack(spacing: MacbotDS.Space.lg) {
            gauge(label: "CPU", value: monitor.cpuUsage)
            gauge(label: "MEM", value: monitor.memoryUsage,
                  sub: "\(String(format: "%.1f", monitor.memoryUsedGB))/\(Int(monitor.memoryTotalGB))")
            gauge(label: "GPU", value: monitor.gpuUsage)
        }
    }

    private func gauge(label: String, value: Double, sub: String? = nil) -> some View {
        let clamped = min(max(value, 0), 1)
        let hot = clamped > 0.85

        return VStack(spacing: 3) {
            ZStack {
                // Track
                Circle()
                    .stroke(Color.primary.opacity(0.08),
                            style: StrokeStyle(lineWidth: 2.5, lineCap: .round))

                // Arc — single color, opacity encodes intensity
                Circle()
                    .trim(from: 0, to: clamped)
                    .stroke(
                        hot ? Color.orange : Self.arcColor.opacity(0.35 + clamped * 0.5),
                        style: StrokeStyle(lineWidth: 2.5, lineCap: .round)
                    )
                    .rotationEffect(.degrees(-90))

                // Value
                Text("\(Int(clamped * 100))")
                    .font(.system(size: 11, weight: .medium, design: .rounded).monospacedDigit())
                    .foregroundStyle(hot ? .orange : .primary.opacity(0.7))
            }
            .frame(width: 40, height: 40)

            Text(label)
                .font(.system(size: 8, weight: .semibold, design: .rounded))
                .foregroundStyle(.tertiary)
                .tracking(0.5)

            if let sub {
                Text(sub)
                    .font(.system(size: 7, weight: .medium, design: .monospaced))
                    .foregroundStyle(.quaternary)
            }
        }
        .frame(maxWidth: .infinity)
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
