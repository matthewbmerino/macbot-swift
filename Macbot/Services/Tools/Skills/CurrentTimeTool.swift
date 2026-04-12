import Foundation

enum CurrentTimeTool {

    static let spec = ToolSpec(
        name: "current_time",
        description: "Get the current wall-clock time on this Mac. Use this for ANY question about the current time, what time it is now, or how late it is. Never guess the time from your training data or the system prompt — always call this tool.",
        properties: [:]
    )

    static func register(on registry: ToolRegistry) async {
        await registry.register(spec) { _ in
            currentTime()
        }
    }

    // MARK: - Current Time

    /// Returns the current wall-clock time. Wrapped in GroundedResponse so the
    /// model is steered to quote the value verbatim instead of paraphrasing.
    static func currentTime() -> String {
        let now = Date()
        let formatter = DateFormatter()
        formatter.dateFormat = "EEEE, MMMM d, yyyy 'at' h:mm:ss a"
        formatter.timeZone = .current
        let local = formatter.string(from: now)
        let tz = TimeZone.current.identifier
        let body = "\(local) (\(tz))"
        return GroundedResponse.format(source: "system clock", body: body)
    }
}
