import Foundation
import AppKit

enum ClipboardAction: String, CaseIterable {
    case rewrite
    case summarize
    case translate
    case explain
    case fixGrammar

    var displayName: String {
        switch self {
        case .rewrite: "Rewrite"
        case .summarize: "Summarize"
        case .translate: "Translate"
        case .explain: "Explain"
        case .fixGrammar: "Fix Grammar"
        }
    }

    var systemPrompt: String {
        switch self {
        case .rewrite:
            "Rewrite the following text to be clearer and more concise. Keep the same meaning and tone. Return ONLY the rewritten text, nothing else."
        case .summarize:
            "Summarize the following text in 2-3 sentences. Return ONLY the summary, nothing else."
        case .translate:
            "Translate the following text to English. If already in English, translate to Spanish. Return ONLY the translation, nothing else."
        case .explain:
            "Explain what the following text means in simple terms. Be brief and clear."
        case .fixGrammar:
            "Fix any grammar, spelling, and punctuation errors in the following text. Keep the original meaning and style. Return ONLY the corrected text, nothing else."
        }
    }
}

final class ClipboardActionRunner {
    private let orchestrator: Orchestrator

    init(orchestrator: Orchestrator) {
        self.orchestrator = orchestrator
    }

    /// Run a clipboard action: read clipboard → process → write result to clipboard.
    func run(_ action: ClipboardAction) async -> String? {
        guard let text = NSPasteboard.general.string(forType: .string), !text.isEmpty else {
            return nil
        }

        Log.app.info("Clipboard action: \(action.rawValue) on \(text.count) chars")

        do {
            let response = try await orchestrator.client.chat(
                model: "qwen3.5:9b",
                messages: [
                    ["role": "system", "content": action.systemPrompt],
                    ["role": "user", "content": text],
                ],
                tools: nil,
                temperature: 0.3,
                numCtx: 4096,
                timeout: 30
            )

            let result = ThinkingStripper.strip(response.content)

            if !result.isEmpty {
                // Write result to clipboard
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(result, forType: .string)
            }

            return result
        } catch {
            Log.app.error("Clipboard action failed: \(error)")
            return nil
        }
    }
}
