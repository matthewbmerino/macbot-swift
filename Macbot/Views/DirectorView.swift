import SwiftUI
import MarkdownUI

// MARK: - Director Design Tokens

private enum DDS {
    static let bg        = Color(red: 0.102, green: 0.102, blue: 0.180) // #1a1a2e
    static let surface   = Color(red: 0.122, green: 0.122, blue: 0.200)
    static let surfaceAlt = Color(red: 0.090, green: 0.090, blue: 0.155)
    static let border    = Color.white.opacity(0.08)
    static let textPri   = Color.white.opacity(0.92)
    static let textSec   = Color.white.opacity(0.55)
    static let textDim   = Color.white.opacity(0.30)
    static let green     = Color(red: 0.30, green: 0.85, blue: 0.45)
    static let amber     = Color(red: 0.95, green: 0.75, blue: 0.20)
    static let red       = Color(red: 0.95, green: 0.35, blue: 0.35)
    static let cyan      = Color(red: 0.30, green: 0.80, blue: 0.95)
    static let purple    = Color(red: 0.65, green: 0.45, blue: 0.95)
    static let pink      = Color(red: 0.90, green: 0.45, blue: 0.65)
}

struct DirectorView: View {
    @State private var viewModel = DirectorViewModel()
    @State private var taskInput = ""
    var orchestrator: Orchestrator?

    var body: some View {
        VStack(spacing: 0) {
            topBar
            Divider().background(DDS.border)

            if viewModel.isRunning || !viewModel.outputText.isEmpty {
                mainContent
            } else {
                launchScreen
            }

            Divider().background(DDS.border)
            bottomBar
        }
        .background(DDS.bg)
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
        HStack(spacing: 12) {
            // Director icon
            Image(systemName: "film")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(DDS.cyan)

            if !viewModel.taskDescription.isEmpty {
                Text(viewModel.taskDescription)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(DDS.textPri)
                    .lineLimit(1)
            } else {
                Text("The Director")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(DDS.textPri)
            }

            Spacer()

            // Elapsed timer
            if viewModel.isRunning || viewModel.elapsedTime > 0 {
                HStack(spacing: 4) {
                    Image(systemName: "clock")
                        .font(.system(size: 10))
                    Text(formatElapsed(viewModel.elapsedTime))
                        .font(.system(size: 12, design: .monospaced))
                }
                .foregroundStyle(viewModel.isRunning ? DDS.amber : DDS.textSec)
            }

            // Agent badge
            if !viewModel.currentAgent.isEmpty {
                Text(viewModel.currentAgent)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(DDS.purple)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(DDS.purple.opacity(0.15))
                    .clipShape(Capsule())
            }

            // Stop button
            if viewModel.isRunning {
                Button(action: { viewModel.stop() }) {
                    HStack(spacing: 4) {
                        Image(systemName: "stop.fill")
                            .font(.system(size: 8))
                        Text("Stop")
                            .font(.system(size: 11, weight: .medium))
                    }
                    .foregroundStyle(DDS.red)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(DDS.red.opacity(0.15))
                    .clipShape(Capsule())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .background(DDS.surfaceAlt)
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
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Text("Generating response...")
                                .font(.system(size: 13))
                                .foregroundStyle(DDS.textSec)
                        }
                        .padding(24)
                    } else {
                        Markdown(viewModel.outputText)
                            .markdownTheme(.gitHub)
                            .markdownTextStyle {
                                ForegroundColor(Color.white.opacity(0.88))
                                FontSize(14)
                            }
                            .textSelection(.enabled)
                            .padding(24)
                    }

                    // Scroll anchor
                    Color.clear.frame(height: 1).id("output-bottom")
                }
            }
            .onChange(of: viewModel.outputText) {
                withAnimation(.easeOut(duration: 0.15)) {
                    proxy.scrollTo("output-bottom", anchor: .bottom)
                }
            }
        }
        .background(DDS.bg)
    }

    // MARK: - Timeline Panel

    private var timelinePanel: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(viewModel.steps) { step in
                        stepRow(step)
                            .id(step.id)
                    }
                    Color.clear.frame(height: 1).id("timeline-bottom")
                }
                .padding(.vertical, 12)
                .padding(.horizontal, 12)
            }
            .onChange(of: viewModel.steps.count) {
                withAnimation(.easeOut(duration: 0.15)) {
                    proxy.scrollTo("timeline-bottom", anchor: .bottom)
                }
            }
        }
        .background(DDS.surface)
    }

    @State private var expandedSteps: Set<UUID> = []

    private func stepRow(_ step: DirectorStep) -> some View {
        let isExpanded = expandedSteps.contains(step.id)

        return VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                // Status indicator
                statusIcon(step.status)

                // Tool type icon
                Image(systemName: step.iconName)
                    .font(.system(size: 11))
                    .foregroundStyle(colorForStepType(step))
                    .frame(width: 16)

                // Name + detail
                VStack(alignment: .leading, spacing: 1) {
                    Text(step.name)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(DDS.textPri)
                        .lineLimit(1)

                    Text(step.detail)
                        .font(.system(size: 10))
                        .foregroundStyle(DDS.textDim)
                        .lineLimit(isExpanded ? nil : 1)
                }

                Spacer(minLength: 4)

                // Relative timestamp
                if let start = viewModel.steps.first?.timestamp {
                    Text(relativeTime(from: start, to: step.timestamp))
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(DDS.textDim)
                }
            }
            .contentShape(Rectangle())
            .onTapGesture {
                withAnimation(.easeInOut(duration: 0.15)) {
                    if expandedSteps.contains(step.id) {
                        expandedSteps.remove(step.id)
                    } else {
                        expandedSteps.insert(step.id)
                    }
                }
            }

            // Expanded result
            if isExpanded, let result = step.result, !result.isEmpty {
                Text(result)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(DDS.textSec)
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(DDS.bg.opacity(0.6))
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .padding(.leading, 32)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(
            step.status == .running
                ? colorForStepType(step).opacity(0.06)
                : Color.clear
        )
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    @ViewBuilder
    private func statusIcon(_ status: DirectorStep.StepStatus) -> some View {
        switch status {
        case .pending:
            Circle()
                .fill(DDS.textDim)
                .frame(width: 7, height: 7)
        case .running:
            ProgressView()
                .controlSize(.mini)
                .frame(width: 12, height: 12)
        case .completed:
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 11))
                .foregroundStyle(DDS.green)
        case .error:
            Image(systemName: "xmark.circle.fill")
                .font(.system(size: 11))
                .foregroundStyle(DDS.red)
        }
    }

    private func colorForStepType(_ step: DirectorStep) -> Color {
        switch step.type {
        case .toolCall:    return DDS.cyan
        case .status:      return DDS.textSec
        case .agentSwitch: return DDS.purple
        case .thinking:    return Color.blue
        case .image:       return DDS.pink
        }
    }

    // MARK: - Launch Screen

    private var launchScreen: some View {
        VStack(spacing: 24) {
            Spacer()

            ZStack {
                Circle()
                    .fill(DDS.cyan.opacity(0.08))
                    .frame(width: 100, height: 100)
                Image(systemName: "film")
                    .font(.system(size: 40, weight: .thin))
                    .foregroundStyle(DDS.cyan.opacity(0.5))
            }

            Text("The Director")
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(DDS.textPri)

            Text("Watch Macbot work step by step.\nEvery tool call, every decision, visualized in real time.")
                .font(.system(size: 13))
                .foregroundStyle(DDS.textSec)
                .multilineTextAlignment(.center)

            // Task input
            HStack(spacing: 10) {
                TextField("Describe a task...", text: $taskInput)
                    .textFieldStyle(.plain)
                    .font(.system(size: 14))
                    .foregroundStyle(DDS.textPri)
                    .onSubmit { launchTask() }

                Button(action: { launchTask() }) {
                    HStack(spacing: 4) {
                        Image(systemName: "play.fill")
                            .font(.system(size: 10))
                        Text("Direct")
                            .font(.system(size: 12, weight: .semibold))
                    }
                    .foregroundStyle(.white)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 7)
                    .background(DDS.cyan)
                    .clipShape(Capsule())
                }
                .buttonStyle(.plain)
                .disabled(taskInput.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(DDS.surface)
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(DDS.border, lineWidth: 0.5))
            .frame(maxWidth: 500)

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Bottom Bar

    private var bottomBar: some View {
        HStack(spacing: 10) {
            Image(systemName: "arrow.turn.right.down")
                .font(.system(size: 11))
                .foregroundStyle(DDS.textDim)

            TextField("Redirect... (\"Skip that\", \"Also check...\", \"Focus on...\")",
                      text: $viewModel.interruptText)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .foregroundStyle(DDS.textPri)
                .onSubmit { viewModel.sendInterrupt() }
                .disabled(!viewModel.isRunning)

            if viewModel.isRunning && !viewModel.interruptText.isEmpty {
                Button(action: { viewModel.sendInterrupt() }) {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.system(size: 16))
                        .foregroundStyle(DDS.cyan)
                }
                .buttonStyle(.plain)
            }

            // Step count
            HStack(spacing: 4) {
                Image(systemName: "list.bullet")
                    .font(.system(size: 9))
                Text("\(viewModel.steps.count) steps")
                    .font(.system(size: 10, design: .monospaced))
            }
            .foregroundStyle(DDS.textDim)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
        .background(DDS.surfaceAlt)
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
