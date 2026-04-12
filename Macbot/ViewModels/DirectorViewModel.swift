import Foundation
import SwiftUI

@Observable
@MainActor
final class DirectorViewModel {
    var steps: [DirectorStep] = []
    var outputText: String = ""
    var currentAgent: String = ""
    var isRunning: Bool = false
    var elapsedTime: TimeInterval = 0
    var taskDescription: String = ""
    var interruptText: String = ""

    private var orchestrator: Orchestrator?
    private var streamTask: Task<Void, Never>?
    private var timerTask: Task<Void, Never>?
    private var startTime: Date?
    private let userId = "director"

    func configure(orchestrator: Orchestrator) {
        self.orchestrator = orchestrator
    }

    func start(task: String) {
        guard let orchestrator, !task.isEmpty else { return }
        stop()

        taskDescription = task
        outputText = ""
        steps = []
        currentAgent = ""
        isRunning = true
        elapsedTime = 0
        startTime = Date()

        startTimer()

        streamTask = Task {
            // Add an initial "thinking" step
            let thinkStep = DirectorStep(
                timestamp: Date(), type: .thinking,
                name: "Analyzing", detail: task,
                status: .running
            )
            steps.append(thinkStep)

            do {
                for try await event in orchestrator.handleMessageStream(
                    userId: userId, message: task
                ) {
                    processEvent(event)
                }
            } catch {
                addStep(type: .status, name: "Error",
                        detail: error.localizedDescription, status: .error)
            }

            // Mark any still-running steps as completed
            for i in steps.indices where steps[i].status == .running {
                steps[i].status = .completed
                if let start = startTime {
                    steps[i].duration = steps[i].timestamp.timeIntervalSince(start)
                }
            }
            isRunning = false
            timerTask?.cancel()
        }
    }

    func sendInterrupt() {
        let text = interruptText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, let orchestrator else { return }
        interruptText = ""

        addStep(type: .status, name: "Redirect",
                detail: text, status: .running)

        // Cancel current stream and start a new one with the redirect
        streamTask?.cancel()

        streamTask = Task {
            do {
                for try await event in orchestrator.handleMessageStream(
                    userId: userId, message: text
                ) {
                    processEvent(event)
                }
            } catch {
                if !Task.isCancelled {
                    addStep(type: .status, name: "Error",
                            detail: error.localizedDescription, status: .error)
                }
            }

            for i in steps.indices where steps[i].status == .running {
                steps[i].status = .completed
            }
            isRunning = false
            timerTask?.cancel()
        }
    }

    func stop() {
        streamTask?.cancel()
        timerTask?.cancel()
        isRunning = false
        for i in steps.indices where steps[i].status == .running {
            steps[i].status = .error
        }
    }

    // MARK: - Private

    private func processEvent(_ event: StreamEvent) {
        switch event {
        case .text(let chunk):
            outputText += chunk
            // Complete the thinking step on first text
            if let idx = steps.lastIndex(where: { $0.type == .thinking && $0.status == .running }) {
                steps[idx].status = .completed
                if let start = startTime {
                    steps[idx].duration = Date().timeIntervalSince(start)
                }
            }

        case .status(let status):
            // Tool calls and status updates become steps
            let isToolCall = status.lowercased().contains("tool")
                || status.lowercased().contains("calling")
                || status.lowercased().contains("searching")
                || status.lowercased().contains("reading")
                || status.lowercased().contains("running")
                || status.lowercased().contains("fetching")
                || status.lowercased().contains("generating")

            // Mark previous running status steps as completed
            for i in steps.indices where steps[i].status == .running
                && (steps[i].type == .status || steps[i].type == .toolCall) {
                steps[i].status = .completed
                if let start = startTime {
                    steps[i].duration = Date().timeIntervalSince(start)
                }
            }

            addStep(
                type: isToolCall ? .toolCall : .status,
                name: extractStepName(from: status),
                detail: status,
                status: .running
            )

        case .agentSelected(let category):
            currentAgent = category.displayName
            // Mark previous agent switch as completed
            for i in steps.indices where steps[i].type == .agentSwitch && steps[i].status == .running {
                steps[i].status = .completed
            }
            addStep(type: .agentSwitch, name: category.displayName,
                    detail: "Agent selected", status: .completed)

        case .image(_, let filename):
            addStep(type: .image, name: "Image",
                    detail: filename, status: .completed)
        }
    }

    private func addStep(type: DirectorStep.StepType, name: String,
                         detail: String, status: DirectorStep.StepStatus) {
        let step = DirectorStep(
            timestamp: Date(), type: type,
            name: name, detail: detail, status: status
        )
        steps.append(step)
    }

    private func extractStepName(from status: String) -> String {
        // Try to extract a short name from the status string
        let lower = status.lowercased()
        if lower.contains("search") { return "Search" }
        if lower.contains("fetch") { return "Fetch" }
        if lower.contains("read") { return "Read" }
        if lower.contains("exec") { return "Execute" }
        if lower.contains("generat") { return "Generate" }
        if lower.contains("calling") { return "Tool Call" }
        if lower.contains("running") { return "Running" }
        // Fallback: first two words
        let words = status.split(separator: " ").prefix(3)
        return words.joined(separator: " ")
    }

    private func startTimer() {
        timerTask = Task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(100))
                if let start = startTime {
                    elapsedTime = Date().timeIntervalSince(start)
                }
            }
        }
    }
}
