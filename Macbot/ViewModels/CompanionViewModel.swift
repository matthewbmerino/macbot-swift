import Foundation
import AppKit

// MARK: - Mood State Machine

enum CompanionMood: String {
    case idle, listening, thinking, excited, sleeping, error
}

// MARK: - Companion ViewModel

@Observable
@MainActor
final class CompanionViewModel {
    var mood: CompanionMood = .idle
    var suggestion: String?
    var position: CGPoint {
        didSet { savePosition() }
    }
    var isVisible = false

    /// When true, a text input field is shown below the companion.
    var isChatOpen = false
    var chatInput = ""
    var chatResponse: String?
    var isResponding = false

    private var chatTask: Task<Void, Never>?
    private var contextTimer: Timer?
    private var idleAccumulator: Int = 0
    private var lastFrontmostApp: String = ""
    private var lastWindowTitle: String = ""
    private var lastClipboardCount: Int = 0
    private var lastContextDigest: String = ""  // avoid repeating suggestions
    private var slowTickCounter: Int = 0        // modulo counter for heavy checks
    private var errorResetTask: Task<Void, Never>?
    private var suggestionDismissTask: Task<Void, Never>?
    private var contextAnalysisTask: Task<Void, Never>?

    /// The most recent ambient context — displayed in the chat panel
    /// so the user can see what the companion is aware of.
    var currentContext: String = ""

    private let posXKey = "companion.position.x"
    private let posYKey = "companion.position.y"
    private let autoShowKey = "companion.autoShow"

    init() {
        let x = UserDefaults.standard.double(forKey: posXKey)
        let y = UserDefaults.standard.double(forKey: posYKey)
        if x > 0 || y > 0 {
            self.position = CGPoint(x: x, y: y)
        } else {
            // Default: bottom-right of main screen
            let screen = NSScreen.main?.visibleFrame ?? .zero
            self.position = CGPoint(
                x: screen.maxX - 130,
                y: screen.minY + 130
            )
        }
        registerHooks()
    }

    // MARK: - Lifecycle

    func start() {
        isVisible = true
        startContextLoop()
    }

    func stop() {
        isVisible = false
        contextTimer?.invalidate()
        contextTimer = nil
    }

    func toggle() {
        if isVisible { stop() } else { start() }
    }

    // MARK: - User Interaction

    func interact() {
        // If sleeping, wake up
        if mood == .sleeping {
            mood = .idle
        }
        // Toggle the chat input
        if isChatOpen {
            closeChat()
        } else {
            openChat()
        }
    }

    func openChat() {
        isChatOpen = true

        // If there was an active suggestion, carry it into the chat
        // panel as the initial response so the user can still read it.
        // Don't clear it — let it become the conversation starter.
        if let activeSuggestion = suggestion {
            chatResponse = activeSuggestion
            suggestion = nil
            suggestionDismissTask?.cancel()
        } else {
            chatResponse = nil
        }
    }

    func closeChat() {
        isChatOpen = false
        chatInput = ""
        chatResponse = nil
        chatTask?.cancel()
        if isResponding {
            isResponding = false
            mood = .idle
        }
    }

    func sendChat() {
        let text = chatInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !isResponding else { return }

        chatInput = ""
        chatResponse = nil
        isResponding = true
        mood = .thinking

        chatTask = Task { @MainActor in
            do {
                guard let orchestrator = CompanionController.shared.orchestrator else {
                    chatResponse = "Not connected — try again in a moment."
                    isResponding = false
                    mood = .idle
                    return
                }

                // Inject live context so the LLM knows what the user
                // is doing right now. This is what makes the companion
                // contextually aware rather than a generic chatbot.
                let contextPrefix = currentContext.isEmpty ? "" :
                    "[Current context]\n\(currentContext)\n\n"
                let enrichedMessage = "\(contextPrefix)\(text)"

                var response = ""
                for try await event in orchestrator.handleMessageStream(
                    userId: "local", message: enrichedMessage, images: nil
                ) {
                    if Task.isCancelled { break }
                    switch event {
                    case .text(let chunk):
                        response += chunk
                        chatResponse = response
                    case .status(let status):
                        chatResponse = "⏳ \(status)"
                    default:
                        break
                    }
                }
                chatResponse = response.isEmpty ? "No response." : response
            } catch is CancellationError {
                // User closed chat mid-response
            } catch {
                chatResponse = "Error: \(error.localizedDescription)"
            }
            isResponding = false
            mood = .idle
        }
    }

    // MARK: - Suggestion Management

    func showSuggestion(_ text: String) {
        suggestion = text
        mood = .excited
        suggestionDismissTask?.cancel()
        suggestionDismissTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(8))
            guard !Task.isCancelled else { return }
            suggestion = nil
            if mood == .excited { mood = .idle }
        }
    }

    // MARK: - Hook Integration

    private func registerHooks() {
        HookSystem.shared.on(.toolError) { [weak self] ctx in
            Task { @MainActor in
                guard let self else { return }
                self.mood = .error
                let msg = ctx.error.isEmpty ? "Something went wrong." : String(ctx.error.prefix(80))
                self.suggestion = "Error: \(msg)"
                self.errorResetTask?.cancel()
                self.errorResetTask = Task { @MainActor in
                    try? await Task.sleep(for: .seconds(3))
                    guard !Task.isCancelled else { return }
                    if self.mood == .error { self.mood = .idle }
                }
            }
        }

        HookSystem.shared.on(.responseStart) { [weak self] _ in
            Task { @MainActor in
                self?.mood = .thinking
            }
        }

        HookSystem.shared.on(.responseComplete) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                if self.mood == .thinking { self.mood = .idle }
            }
        }

        HookSystem.shared.on(.messageReceived) { [weak self] _ in
            Task { @MainActor in
                self?.mood = .listening
            }
        }
    }

    // MARK: - Context Loop

    private func startContextLoop() {
        contextTimer?.invalidate()
        // Fast loop: cursor position updates need to feel instant.
        // The timer fires every 0.25s for cursor + app context.
        // Heavier checks (clipboard, battery) run on a modulo cadence.
        contextTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.checkContext()
            }
        }
        // Fire immediately on start so there's no blank state
        checkContext()
    }

    private func checkContext() {
        guard isVisible else { return }

        // ── Fast path (every tick, ~0.25s) ──
        // Cursor + frontmost app + window title — zero await, instant.
        let cursorPos = NSEvent.mouseLocation
        let frontApp = NSWorkspace.shared.frontmostApplication?.localizedName ?? ""
        let windowTitle = Self.focusedWindowTitle() ?? ""

        // Build context string — fast fields only on most ticks
        var contextParts: [String] = []
        if !frontApp.isEmpty {
            var appLine = frontApp
            if !windowTitle.isEmpty {
                appLine += " — \(String(windowTitle.prefix(60)))"
            }
            contextParts.append(appLine)
        }
        contextParts.append("Cursor: (\(Int(cursorPos.x)), \(Int(cursorPos.y)))")

        // App switch detection (runs every tick so it's instant)
        if !frontApp.isEmpty && frontApp != lastFrontmostApp {
            let previous = lastFrontmostApp
            lastFrontmostApp = frontApp
            if !previous.isEmpty && mood == .idle {
                let appHints: [String: String] = [
                    "Xcode": "I see you opened Xcode. Want help with anything?",
                    "Terminal": "Working in Terminal? I can help with commands.",
                    "Safari": "Browsing? I can help summarize or research.",
                    "Mail": "Composing an email? I can help draft or proofread.",
                    "Notes": "Taking notes? I can help organize or expand your thoughts.",
                ]
                if let hint = appHints[frontApp] {
                    showSuggestion(hint)
                }
            }
        }

        // Window title tracking
        if !windowTitle.isEmpty && windowTitle != lastWindowTitle {
            lastWindowTitle = windowTitle
        }

        // ── Slow path (every ~5s = every 20 ticks at 0.25s) ──
        slowTickCounter += 1
        let isSlowTick = slowTickCounter % 20 == 0

        if isSlowTick {
            Task {
                let snapshot = await AmbientMonitor.shared.current()

                // Append slow-path context
                if !snapshot.clipboardPreview.isEmpty {
                    contextParts.append("Clipboard: \(String(snapshot.clipboardPreview.prefix(50)))")
                }
                if snapshot.memoryTotalGB > 0 {
                    contextParts.append("RAM: \(String(format: "%.1f", snapshot.memoryUsedGB))/\(String(format: "%.0f", snapshot.memoryTotalGB))GB")
                }
                if snapshot.batteryPercent >= 0 {
                    contextParts.append("Battery: \(snapshot.batteryPercent)%\(snapshot.isCharging ? " ⚡" : "")")
                }
                currentContext = contextParts.joined(separator: "\n")

                // Sleep / wake
                if snapshot.idleSeconds > 300 && mood != .sleeping {
                    idleAccumulator = snapshot.idleSeconds
                    mood = .sleeping
                    suggestion = nil
                    return
                }
                if mood == .sleeping && snapshot.idleSeconds < 30 {
                    mood = .idle
                    let mins = idleAccumulator / 60
                    if mins >= 5 {
                        showSuggestion("Welcome back! You were away for \(mins) minutes.")
                    }
                    idleAccumulator = 0
                    return
                }

                // Clipboard change
                if snapshot.clipboardChangeCount != lastClipboardCount && lastClipboardCount > 0 {
                    lastClipboardCount = snapshot.clipboardChangeCount
                    let clip = snapshot.clipboardPreview
                    if clip.count > 20 && mood == .idle && !isChatOpen {
                        let looksLikeCode = clip.contains("func ") || clip.contains("class ")
                            || clip.contains("import ") || clip.contains("let ") || clip.contains("var ")
                        let looksLikeError = clip.lowercased().contains("error")
                            || clip.lowercased().contains("exception") || clip.lowercased().contains("failed")
                        if looksLikeError {
                            showSuggestion("Copied an error? Click me to explain it.")
                        } else if looksLikeCode {
                            showSuggestion("Copied code — want me to explain or review it?")
                        }
                    }
                } else if lastClipboardCount == 0 {
                    lastClipboardCount = snapshot.clipboardChangeCount
                }

                // Low battery
                if snapshot.batteryPercent >= 0 && snapshot.batteryPercent <= 10
                    && !snapshot.isCharging && mood == .idle {
                    showSuggestion("Battery at \(snapshot.batteryPercent)% — plug in soon.")
                }
            }
        } else {
            // Fast ticks: just update cursor + app context (no await)
            currentContext = contextParts.joined(separator: "\n")
        }
    }

    /// Read the focused window's title via Accessibility API.
    /// Returns nil if Accessibility permission isn't granted.
    private static func focusedWindowTitle() -> String? {
        guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
        let axApp = AXUIElementCreateApplication(app.processIdentifier)

        var focusedWindow: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(
            axApp, kAXFocusedWindowAttribute as CFString, &focusedWindow
        )
        guard result == .success, let window = focusedWindow else { return nil }

        var titleValue: CFTypeRef?
        let titleResult = AXUIElementCopyAttributeValue(
            window as! AXUIElement, kAXTitleAttribute as CFString, &titleValue
        )
        guard titleResult == .success, let title = titleValue as? String else { return nil }
        return title
    }

    // MARK: - Persistence

    private func savePosition() {
        UserDefaults.standard.set(position.x, forKey: posXKey)
        UserDefaults.standard.set(position.y, forKey: posYKey)
    }
}
