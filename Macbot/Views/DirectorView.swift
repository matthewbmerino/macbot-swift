import SwiftUI
import AppKit
import MarkdownUI

struct DirectorView: View {
    @State private var viewModel = DirectorViewModel()
    @State private var taskInput = ""
    var orchestrator: Orchestrator?

    var body: some View {
        VStack(spacing: 0) {
            topBar
            Divider().background(MacbotDS.Colors.separator)

            if viewModel.isRunning || !viewModel.outputText.isEmpty {
                mainContent
            } else {
                launchScreen
            }

            Divider().background(MacbotDS.Colors.separator)
            bottomBar
        }
        .background(MacbotDS.Colors.bg)
        .background(Color.blue.opacity(0.02))
        .frame(minWidth: 900, minHeight: 600)
        .onAppear {
            if let orchestrator {
                viewModel.configure(orchestrator: orchestrator)
            }
            // Pick up pending task from /director command
            if let pending = DirectorLauncher.shared.pendingTask {
                DirectorLauncher.shared.pendingTask = nil
                viewModel.start(task: pending)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: DirectorLauncher.taskNotification)) { note in
            if let task = note.userInfo?["task"] as? String {
                DirectorLauncher.shared.pendingTask = nil
                viewModel.start(task: task)
            }
        }
    }

    // MARK: - Top Bar

    private var topBar: some View {
        HStack(spacing: MacbotDS.Space.md) {
            // Director icon
            Image(systemName: "film")
                .font(MacbotDS.Typo.heading)
                .foregroundStyle(MacbotDS.Colors.info)

            if !viewModel.taskDescription.isEmpty {
                Text(viewModel.taskDescription)
                    .font(MacbotDS.Typo.body)
                    .foregroundStyle(MacbotDS.Colors.textPri)
                    .lineLimit(1)
            } else {
                Text("The Director")
                    .font(MacbotDS.Typo.heading)
                    .foregroundStyle(MacbotDS.Colors.textPri)
            }

            Spacer()

            // Elapsed timer
            if viewModel.isRunning || viewModel.elapsedTime > 0 {
                HStack(spacing: MacbotDS.Space.xs) {
                    Image(systemName: "clock")
                        .font(.caption2)
                    Text(formatElapsed(viewModel.elapsedTime))
                        .font(MacbotDS.Typo.mono)
                }
                .foregroundStyle(viewModel.isRunning ? MacbotDS.Colors.warning : MacbotDS.Colors.textSec)
            }

            // Agent badge
            if !viewModel.currentAgent.isEmpty {
                Text(viewModel.currentAgent)
                    .font(MacbotDS.Typo.detail)
                    .foregroundStyle(.purple)
                    .padding(.horizontal, MacbotDS.Space.sm)
                    .padding(.vertical, MacbotDS.Space.xs)
                    .background(Color.purple.opacity(0.15))
                    .clipShape(Capsule())
            }

            // Stop button
            if viewModel.isRunning {
                Button(action: { viewModel.stop() }) {
                    HStack(spacing: MacbotDS.Space.xs) {
                        Image(systemName: "stop.fill")
                            .font(.caption2)
                        Text("Stop")
                            .font(MacbotDS.Typo.detail)
                    }
                    .foregroundStyle(MacbotDS.Colors.danger)
                    .padding(.horizontal, MacbotDS.Space.sm)
                    .padding(.vertical, MacbotDS.Space.xs)
                    .background(MacbotDS.Colors.danger.opacity(0.15))
                    .clipShape(Capsule())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, MacbotDS.Space.lg)
        .padding(.vertical, MacbotDS.Space.md)
        .background(MacbotDS.Colors.elevated)
    }

    // MARK: - Main Content (split panels)

    private var mainContent: some View {
        HSplitView {
            // Left: Output document (60%)
            outputPanel
                .frame(minWidth: 400)

            // Right: Step timeline (40%)
            timelinePanel
                .frame(minWidth: 280, idealWidth: 360)
        }
    }

    // MARK: - Output Panel

    private var outputPanel: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    if viewModel.outputText.isEmpty && viewModel.isRunning {
                        HStack(spacing: MacbotDS.Space.sm) {
                            ProgressView().controlSize(.small)
                            Text("Generating response...")
                                .font(MacbotDS.Typo.body)
                                .foregroundStyle(MacbotDS.Colors.textSec)
                        }
                        .padding(MacbotDS.Space.lg)
                    } else {
                        Markdown(viewModel.outputText)
                            .markdownTheme(.gitHub)
                            .markdownTextStyle {
                                ForegroundColor(.primary.opacity(0.88))
                                FontSize(14)
                            }
                            .textSelection(.enabled)
                            .padding(MacbotDS.Space.lg)
                    }

                    // Scroll anchor
                    Color.clear.frame(height: 1).id("output-bottom")
                }
            }
            .onChange(of: viewModel.outputText) {
                withAnimation(Motion.smooth) {
                    proxy.scrollTo("output-bottom", anchor: .bottom)
                }
            }
        }
        .background(MacbotDS.Colors.bg)
    }

    // MARK: - Timeline Panel

    private var timelinePanel: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(viewModel.steps) { step in
                        stepRow(step)
                            .id(step.id)
                            .transition(.asymmetric(
                                insertion: .opacity
                                    .combined(with: .offset(x: -8))
                                    .combined(with: .scale(scale: 0.97, anchor: .leading)),
                                removal: .opacity
                            ))
                    }
                    Color.clear.frame(height: 1).id("timeline-bottom")
                }
                .padding(.vertical, MacbotDS.Space.md)
                .padding(.horizontal, MacbotDS.Space.md)
            }
            .onChange(of: viewModel.steps.count) {
                withAnimation(Motion.smooth) {
                    proxy.scrollTo("timeline-bottom", anchor: .bottom)
                }
            }
        }
        .background(MacbotDS.Colors.surface)
    }

    @State private var expandedSteps: Set<UUID> = []
    @State private var hoveredStep: UUID?

    private func stepRow(_ step: DirectorStep) -> some View {
        let isExpanded = expandedSteps.contains(step.id)

        return VStack(alignment: .leading, spacing: MacbotDS.Space.xs) {
            HStack(spacing: MacbotDS.Space.sm) {
                // Status indicator
                statusIcon(step.status)

                // Tool type icon
                Image(systemName: step.iconName)
                    .font(.caption2)
                    .foregroundStyle(colorForStepType(step))
                    .frame(width: 16)

                // Name + detail
                VStack(alignment: .leading, spacing: 1) {
                    Text(step.name)
                        .font(MacbotDS.Typo.detail)
                        .foregroundStyle(MacbotDS.Colors.textPri)
                        .lineLimit(1)

                    Text(step.detail)
                        .font(.caption2)
                        .foregroundStyle(MacbotDS.Colors.textTer)
                        .lineLimit(isExpanded ? nil : 1)
                }

                Spacer(minLength: MacbotDS.Space.xs)

                // Relative timestamp
                if let start = viewModel.steps.first?.timestamp {
                    Text(relativeTime(from: start, to: step.timestamp))
                        .font(MacbotDS.Typo.mono)
                        .foregroundStyle(MacbotDS.Colors.textTer)
                }

                // Expand/collapse chevron
                Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(MacbotDS.Colors.textTer)
            }
            .contentShape(Rectangle())
            .onTapGesture {
                withAnimation(Motion.snappy) {
                    if expandedSteps.contains(step.id) {
                        expandedSteps.remove(step.id)
                    } else {
                        expandedSteps.insert(step.id)
                    }
                }
            }
            .onHover { hovering in
                hoveredStep = hovering ? step.id : nil
                if hovering { NSCursor.pointingHand.push() } else { NSCursor.pop() }
            }

            // Expanded result
            if isExpanded, let result = step.result, !result.isEmpty {
                Text(result)
                    .font(MacbotDS.Typo.mono)
                    .foregroundStyle(MacbotDS.Colors.textSec)
                    .padding(MacbotDS.Space.sm)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(MacbotDS.Colors.bg.opacity(0.6))
                    .clipShape(RoundedRectangle(cornerRadius: MacbotDS.Radius.sm))
                    .padding(.leading, MacbotDS.Space.xl)
            }
        }
        .padding(.horizontal, MacbotDS.Space.sm)
        .padding(.vertical, MacbotDS.Space.sm)
        .background(
            step.status == .running
                ? colorForStepType(step).opacity(0.06)
                : (hoveredStep == step.id ? Color.primary.opacity(0.04) : Color.clear)
        )
        .clipShape(RoundedRectangle(cornerRadius: MacbotDS.Radius.sm))
    }

    @ViewBuilder
    private func statusIcon(_ status: DirectorStep.StepStatus) -> some View {
        switch status {
        case .pending:
            Circle()
                .fill(MacbotDS.Colors.textTer)
                .frame(width: 7, height: 7)
        case .running:
            ProgressView()
                .controlSize(.mini)
                .frame(width: 12, height: 12)
        case .completed:
            Image(systemName: "checkmark.circle.fill")
                .font(.caption2)
                .foregroundStyle(MacbotDS.Colors.success)
        case .error:
            Image(systemName: "xmark.circle.fill")
                .font(.caption2)
                .foregroundStyle(MacbotDS.Colors.danger)
        }
    }

    private func colorForStepType(_ step: DirectorStep) -> Color {
        switch step.type {
        case .toolCall:    return MacbotDS.Colors.info
        case .status:      return MacbotDS.Colors.textSec
        case .agentSwitch: return .purple
        case .thinking:    return .blue
        case .image:       return .pink
        }
    }

    // MARK: - Launch Screen

    private var launchScreen: some View {
        VStack(spacing: MacbotDS.Space.lg) {
            Spacer()

            ZStack {
                Circle()
                    .fill(MacbotDS.Colors.info.opacity(0.08))
                    .frame(width: 100, height: 100)
                Image(systemName: "film")
                    .font(.system(size: 40, weight: .thin))
                    .foregroundStyle(MacbotDS.Colors.info.opacity(0.5))
            }

            Text("The Director")
                .font(MacbotDS.Typo.title)
                .foregroundStyle(MacbotDS.Colors.textPri)

            Text("Watch Macbot work step by step.\nEvery tool call, every decision, visualized in real time.")
                .font(MacbotDS.Typo.body)
                .foregroundStyle(MacbotDS.Colors.textSec)
                .multilineTextAlignment(.center)

            // Task input
            HStack(spacing: MacbotDS.Space.sm) {
                TextField("Describe a task...", text: $taskInput)
                    .textFieldStyle(.plain)
                    .font(.subheadline)
                    .foregroundStyle(MacbotDS.Colors.textPri)
                    .onSubmit { launchTask() }

                Button(action: { launchTask() }) {
                    HStack(spacing: MacbotDS.Space.xs) {
                        Image(systemName: "play.fill")
                            .font(.caption2)
                        Text("Direct")
                            .font(MacbotDS.Typo.detail)
                    }
                    .foregroundStyle(.white)
                    .padding(.horizontal, MacbotDS.Space.md)
                    .padding(.vertical, MacbotDS.Space.sm)
                    .background(MacbotDS.Colors.info)
                    .clipShape(Capsule())
                }
                .buttonStyle(.plain)
                .disabled(taskInput.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .padding(.horizontal, MacbotDS.Space.md)
            .padding(.vertical, MacbotDS.Space.sm)
            .background(MacbotDS.Colors.surface)
            .clipShape(RoundedRectangle(cornerRadius: MacbotDS.Radius.md))
            .overlay(RoundedRectangle(cornerRadius: MacbotDS.Radius.md).stroke(MacbotDS.Colors.separator, lineWidth: 0.5))
            .frame(maxWidth: 500)

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Bottom Bar

    private var bottomBar: some View {
        HStack(spacing: MacbotDS.Space.sm) {
            Image(systemName: "arrow.turn.right.down")
                .font(.caption2)
                .foregroundStyle(MacbotDS.Colors.textTer)

            TextField("Redirect... (\"Skip that\", \"Also check...\", \"Focus on...\")",
                      text: $viewModel.interruptText)
                .textFieldStyle(.plain)
                .font(MacbotDS.Typo.caption)
                .foregroundStyle(MacbotDS.Colors.textPri)
                .onSubmit { viewModel.sendInterrupt() }
                .disabled(!viewModel.isRunning)

            if viewModel.isRunning && !viewModel.interruptText.isEmpty {
                Button(action: { viewModel.sendInterrupt() }) {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.subheadline)
                        .foregroundStyle(MacbotDS.Colors.info)
                }
                .buttonStyle(.plain)
            }

            // Step count
            HStack(spacing: MacbotDS.Space.xs) {
                Image(systemName: "list.bullet")
                    .font(.caption2)
                Text("\(viewModel.steps.count) steps")
                    .font(MacbotDS.Typo.mono)
            }
            .foregroundStyle(MacbotDS.Colors.textTer)
        }
        .padding(.horizontal, MacbotDS.Space.lg)
        .padding(.vertical, MacbotDS.Space.sm)
        .background(MacbotDS.Colors.elevated)
    }

    // MARK: - Helpers

    private func launchTask() {
        let task = taskInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !task.isEmpty else { return }
        taskInput = ""
        viewModel.start(task: task)
    }

    private func formatElapsed(_ interval: TimeInterval) -> String {
        let mins = Int(interval) / 60
        let secs = Int(interval) % 60
        let tenths = Int((interval.truncatingRemainder(dividingBy: 1)) * 10)
        return String(format: "%d:%02d.%d", mins, secs, tenths)
    }

    private func relativeTime(from start: Date, to current: Date) -> String {
        let delta = current.timeIntervalSince(start)
        let mins = Int(delta) / 60
        let secs = Int(delta) % 60
        return String(format: "%d:%02d", mins, secs)
    }
}
