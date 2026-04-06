import Foundation

/// Loads the canonical Soul.md prompt from the app bundle.
///
/// The soul is the shared identity prepended to every agent's system prompt
/// (see `Orchestrator.buildSystemPrompt`). Shipping it as a bundle resource
/// keeps it editable as plain markdown without recompiling logic, while the
/// in-code fallback in `Orchestrator.defaultSoul` guarantees the app never
/// boots without one.
enum SoulLoader {
    /// Returns the contents of `Resources/Soul.md`, or `nil` if the resource
    /// is missing or unreadable. Callers should fall back to the orchestrator
    /// default in that case.
    static func load() -> String? {
        guard let url = Bundle.module.url(forResource: "Soul", withExtension: "md") else {
            Log.app.warning("[soul] Soul.md not found in bundle — using built-in default")
            return nil
        }
        do {
            let text = try String(contentsOf: url, encoding: .utf8)
            Log.app.info("[soul] loaded Soul.md from bundle (\(text.count) chars)")
            return text
        } catch {
            Log.app.error("[soul] failed to read Soul.md: \(error.localizedDescription)")
            return nil
        }
    }
}
