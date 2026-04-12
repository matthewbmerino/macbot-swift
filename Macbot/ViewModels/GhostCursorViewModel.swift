import Foundation
import AppKit

@MainActor
@Observable
final class GhostCursorViewModel {
    var steps: [GhostStep] = []
    var currentStepIndex: Int = 0
    var isRunning: Bool = false
    var narration: String = ""
    var isCancelled: Bool = false

    var progress: Double {
        guard !steps.isEmpty else { return 0 }
        return Double(currentStepIndex) / Double(steps.count)
    }

    var currentStepLabel: String {
        guard !steps.isEmpty, currentStepIndex < steps.count else { return "" }
        return "Step \(currentStepIndex + 1)/\(steps.count): \(steps[currentStepIndex].description)"
    }

    func cancel() {
        isCancelled = true
        isRunning = false
        narration = "Cancelled by user."
    }

    /// Execute a task described in natural language. For MVP, we parse a simple
    /// JSON-like format from the orchestrator. The caller provides steps directly
    /// so this layer stays orchestrator-agnostic.
    func execute(parsedSteps: [GhostStep]) async {
        guard AccessibilityBridge.checkAccessibilityPermission() else {
            narration = "Accessibility permission required. Opening System Settings..."
            AccessibilityBridge.requestAccessibilityPermission()
            return
        }

        steps = parsedSteps
        currentStepIndex = 0
        isRunning = true
        isCancelled = false

        for (index, step) in steps.enumerated() {
            guard !isCancelled else { break }
            currentStepIndex = index
            steps[index].status = .running
            narration = step.description

            let success = await executeStep(step)
            steps[index].status = success ? .completed : .failed

            if !success {
                narration = "Step failed: \(step.description)"
                break
            }

            // Brief pause between steps for visual clarity
            try? await Task.sleep(for: .milliseconds(200))
        }

        if !isCancelled && steps.allSatisfy({ $0.status == .completed }) {
            narration = "All steps completed."
        }
        isRunning = false
    }

    // MARK: - Step Execution

    private func executeStep(_ step: GhostStep) async -> Bool {
        switch step.action {
        case .click(let elementLabel):
            return await executeClick(app: step.app, label: elementLabel)

        case .type(let text):
            await animateToCurrentField(app: step.app)
            try? await Task.sleep(for: .milliseconds(100))
            AccessibilityBridge.typeText(text)
            return true

        case .menu(let path):
            return AccessibilityBridge.navigateMenu(app: step.app, path: path)

        case .shortcut(let keys):
            // Focus the app first
            focusApp(step.app)
            try? await Task.sleep(for: .milliseconds(300))
            AccessibilityBridge.performKeyPress(keys)
            return true

        case .wait(let seconds):
            try? await Task.sleep(for: .milliseconds(Int(seconds * 1000)))
            return true
        }
    }

    private func executeClick(app: String, label: String) async -> Bool {
        focusApp(app)
        try? await Task.sleep(for: .milliseconds(300))

        guard let element = AccessibilityBridge.findElement(app: app, label: label),
              let center = AccessibilityBridge.elementCenter(element) else {
            // Fallback: element not found
            narration = "Could not find '\(label)' in \(app)"
            return false
        }

        // Animate the ghost cursor to the target, then click
        await GhostCursorController.shared.animateTo(center)
        AccessibilityBridge.performClick(at: center)
        return true
    }

    private func animateToCurrentField(app: String) async {
        // Try to find the focused element to animate toward
        focusApp(app)
        try? await Task.sleep(for: .milliseconds(200))
    }

    private func focusApp(_ name: String) {
        if let app = NSWorkspace.shared.runningApplications.first(where: {
            $0.localizedName?.lowercased() == name.lowercased()
        }) {
            app.activate()
        }
    }
}
