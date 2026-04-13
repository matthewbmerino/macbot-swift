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
        case .openApp:
            return await openApp(step.app)

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
            guard !keys.isEmpty else { return true }
            focusApp(step.app)
            try? await Task.sleep(for: .milliseconds(300))
            AccessibilityBridge.performKeyPress(keys)
            return true

        case .search(let query):
            return await executeSearch(app: step.app, query: query)

        case .wait(let seconds):
            try? await Task.sleep(for: .milliseconds(Int(seconds * 1000)))
            return true
        }
    }

    private func openApp(_ name: String) async -> Bool {
        // Try to activate if already running
        if let app = NSWorkspace.shared.runningApplications.first(where: {
            $0.localizedName?.lowercased() == name.lowercased()
        }) {
            app.activate()
            // Wait until it's actually frontmost
            let deadline = Date().addingTimeInterval(2.0)
            while Date() < deadline {
                if NSWorkspace.shared.frontmostApplication?.processIdentifier == app.processIdentifier {
                    break
                }
                Thread.sleep(forTimeInterval: 0.05)
            }
            return true
        }

        // Launch via NSWorkspace
        let config = NSWorkspace.OpenConfiguration()
        config.activates = true
        do {
            // Try the app name directly, then with .app suffix
            let appURL: URL
            if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: name.lowercased()) {
                appURL = url
            } else if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.\(name)") {
                appURL = url
            } else {
                // Fallback: try opening by name via /Applications
                let paths = [
                    "/Applications/\(name).app",
                    "/System/Applications/\(name).app",
                    "/System/Applications/Utilities/\(name).app",
                ]
                guard let path = paths.first(where: { FileManager.default.fileExists(atPath: $0) }) else {
                    narration = "Could not find app: \(name)"
                    return false
                }
                appURL = URL(fileURLWithPath: path)
            }
            try await NSWorkspace.shared.openApplication(at: appURL, configuration: config)
            try? await Task.sleep(for: .seconds(1))
            return true
        } catch {
            narration = "Failed to open \(name): \(error.localizedDescription)"
            return false
        }
    }

    private func executeSearch(app: String, query: String) async -> Bool {
        focusApp(app)
        try? await Task.sleep(for: .milliseconds(300))

        // Focus address/search bar with Cmd+L (works in Safari, Chrome, Arc, etc.)
        AccessibilityBridge.performKeyPress("Cmd+L")
        try? await Task.sleep(for: .milliseconds(300))

        // Clear any existing text, type the query, hit Enter
        AccessibilityBridge.performKeyPress("Cmd+A")
        try? await Task.sleep(for: .milliseconds(50))
        AccessibilityBridge.typeText(query)
        try? await Task.sleep(for: .milliseconds(100))
        AccessibilityBridge.performKeyPress("return")
        return true
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

    /// Focus an app and **wait** until macOS actually brings it to the front.
    /// Without this, keystrokes land on macbot's own window.
    private func focusApp(_ name: String) {
        guard let app = NSWorkspace.shared.runningApplications.first(where: {
            $0.localizedName?.lowercased() == name.lowercased()
        }) else { return }

        app.activate()

        // Poll until the app is actually frontmost (max 2 seconds).
        // activate() is asynchronous — macOS may take 100-500ms to
        // complete the app switch, especially if animations are on.
        let deadline = Date().addingTimeInterval(2.0)
        while Date() < deadline {
            if NSWorkspace.shared.frontmostApplication?.processIdentifier == app.processIdentifier {
                return
            }
            Thread.sleep(forTimeInterval: 0.05)
        }
    }
}
