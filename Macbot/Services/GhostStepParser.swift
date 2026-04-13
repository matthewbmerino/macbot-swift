import Foundation

/// Heuristic parser that converts a natural-language task description into
/// a sequence of GhostSteps. For MVP this handles common patterns like
/// "open X", "type Y", "click Z", and "press Cmd+N". A future version
/// will delegate planning to the orchestrator / LLM.
enum GhostStepParser {

    static func parse(task: String) -> [GhostStep] {
        var steps: [GhostStep] = []

        // Split on "and then", "then", "and", comma, or semicolon
        let separators = try! NSRegularExpression(
            pattern: #"\b(?:and then|then|and)\b|[;,]"#,
            options: .caseInsensitive
        )
        let range = NSRange(task.startIndex..., in: task)
        var lastEnd = task.startIndex
        var fragments: [String] = []

        separators.enumerateMatches(in: task, range: range) { match, _, _ in
            guard let matchRange = match.map({ Range($0.range, in: task)! }) else { return }
            let fragment = String(task[lastEnd..<matchRange.lowerBound])
                .trimmingCharacters(in: .whitespaces)
            if !fragment.isEmpty { fragments.append(fragment) }
            lastEnd = matchRange.upperBound
        }
        let remaining = String(task[lastEnd...]).trimmingCharacters(in: .whitespaces)
        if !remaining.isEmpty { fragments.append(remaining) }

        if fragments.isEmpty { fragments = [task] }

        var currentApp = "Finder"

        for fragment in fragments {
            let fLower = fragment.lowercased().trimmingCharacters(in: .whitespaces)

            if let step = parseOpen(fLower, original: fragment, currentApp: &currentApp) {
                steps.append(step)
                // Add a wait after opening an app
                steps.append(GhostStep(
                    app: currentApp, action: .wait(seconds: 1.0),
                    description: "Waiting for \(currentApp) to launch..."
                ))
            } else if let step = parseShortcut(fLower, original: fragment, app: currentApp) {
                steps.append(step)
            } else if let step = parseClick(fLower, original: fragment, app: currentApp) {
                steps.append(step)
            } else if let step = parseType(fLower, original: fragment, app: currentApp) {
                steps.append(step)
            } else if let step = parseMenu(fLower, original: fragment, app: currentApp) {
                steps.append(step)
            } else if let step = parseWait(fLower) {
                steps.append(step)
            } else if let step = parseSearch(fLower, original: fragment, app: &currentApp) {
                // Search may prepend a Cmd+L for browsers
                steps.append(step)
            }
        }

        return steps
    }

    // MARK: - Fragment Parsers

    private static func parseOpen(_ lower: String, original: String, currentApp: inout String) -> GhostStep? {
        let pattern = try! NSRegularExpression(
            pattern: #"^(?:open|launch|start)\s+(.+)"#, options: .caseInsensitive
        )
        guard let match = pattern.firstMatch(in: original, range: nsRange(original)),
              let nameRange = Range(match.range(at: 1), in: original) else { return nil }

        let appName = String(original[nameRange]).trimmingCharacters(in: .whitespaces)
        currentApp = appName
        return GhostStep(
            app: appName,
            action: .openApp,
            description: "Opening \(appName)..."
        )
    }

    private static func parseClick(_ lower: String, original: String, app: String) -> GhostStep? {
        let pattern = try! NSRegularExpression(
            pattern: #"^(?:click|tap|hit)\s+(?:the\s+|on\s+)?(.+?)(?:\s+button)?$"#,
            options: .caseInsensitive
        )
        guard let match = pattern.firstMatch(in: original, range: nsRange(original)),
              let labelRange = Range(match.range(at: 1), in: original) else { return nil }

        let label = String(original[labelRange]).trimmingCharacters(in: .whitespaces)
        return GhostStep(
            app: app,
            action: .click(elementLabel: label),
            description: "Clicking '\(label)' in \(app)..."
        )
    }

    private static func parseType(_ lower: String, original: String, app: String) -> GhostStep? {
        let pattern = try! NSRegularExpression(
            pattern: #"^(?:type|enter|write|input)\s+(.+)"#, options: .caseInsensitive
        )
        guard let match = pattern.firstMatch(in: original, range: nsRange(original)),
              let textRange = Range(match.range(at: 1), in: original) else { return nil }

        let text = String(original[textRange]).trimmingCharacters(in: .whitespaces)
        return GhostStep(
            app: app,
            action: .type(text: text),
            description: "Typing '\(text.prefix(40))' in \(app)..."
        )
    }

    private static func parseShortcut(_ lower: String, original: String, app: String) -> GhostStep? {
        let pattern = try! NSRegularExpression(
            pattern: #"^(?:press|shortcut|keyboard)\s+((?:cmd|command|ctrl|control|alt|option|shift)\s*\+\s*\S+)"#,
            options: .caseInsensitive
        )
        guard let match = pattern.firstMatch(in: original, range: nsRange(original)),
              let keysRange = Range(match.range(at: 1), in: original) else { return nil }

        let keys = String(original[keysRange]).trimmingCharacters(in: .whitespaces)
        return GhostStep(
            app: app,
            action: .shortcut(keys: keys),
            description: "Pressing \(keys) in \(app)..."
        )
    }

    private static func parseMenu(_ lower: String, original: String, app: String) -> GhostStep? {
        let pattern = try! NSRegularExpression(
            pattern: #"^(?:menu|go to|navigate to)\s+(.+)"#, options: .caseInsensitive
        )
        guard let match = pattern.firstMatch(in: original, range: nsRange(original)),
              let pathRange = Range(match.range(at: 1), in: original) else { return nil }

        let pathStr = String(original[pathRange])
        let path = pathStr.components(separatedBy: ">").map { $0.trimmingCharacters(in: .whitespaces) }
        guard !path.isEmpty else { return nil }

        return GhostStep(
            app: app,
            action: .menu(path: path),
            description: "Navigating menu: \(path.joined(separator: " > ")) in \(app)..."
        )
    }

    private static func parseWait(_ lower: String) -> GhostStep? {
        let pattern = try! NSRegularExpression(
            pattern: #"^(?:wait|pause|sleep)\s+(?:for\s+)?(\d+(?:\.\d+)?)\s*(?:s|sec|seconds?)?"#,
            options: .caseInsensitive
        )
        guard let match = pattern.firstMatch(in: lower, range: nsRange(lower)),
              let numRange = Range(match.range(at: 1), in: lower),
              let seconds = Double(lower[numRange]) else { return nil }

        return GhostStep(
            app: "",
            action: .wait(seconds: min(seconds, 30)),
            description: "Waiting \(seconds) seconds..."
        )
    }

    private static func parseSearch(_ lower: String, original: String, app: inout String) -> GhostStep? {
        let pattern = try! NSRegularExpression(
            pattern: #"^(?:search|search for|look up|google)\s+(.+)"#,
            options: .caseInsensitive
        )
        guard let match = pattern.firstMatch(in: original, range: nsRange(original)),
              let queryRange = Range(match.range(at: 1), in: original) else { return nil }

        let query = String(original[queryRange]).trimmingCharacters(in: .whitespaces)
        // Search is a compound action — returns only the type step here,
        // but the caller should also insert a Cmd+L first for browsers.
        // We handle that by using a dedicated .search action.
        return GhostStep(
            app: app,
            action: .search(query: query),
            description: "Searching for '\(query)'..."
        )
    }

    private static func nsRange(_ s: String) -> NSRange {
        NSRange(s.startIndex..., in: s)
    }
}
