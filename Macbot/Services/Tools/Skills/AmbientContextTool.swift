import Foundation

enum AmbientContextTool {

    static let spec = ToolSpec(
        name: "ambient_context",
        description: "Get a snapshot of what the user is currently doing on their Mac: active app, idle time, battery, memory, recent clipboard. Use this when you need real-time context about the user's environment.",
        properties: [:]
    )

    static func register(on registry: ToolRegistry) async {
        await registry.register(spec) { _ in
            await ambientContext()
        }
    }

    // MARK: - Ambient Context

    static func ambientContext() async -> String {
        let s = await AmbientMonitor.shared.current()
        var lines: [String] = ["Current ambient context:"]
        if !s.frontmostApp.isEmpty {
            lines.append("- Active app: \(s.frontmostApp)\(s.frontmostBundleID.isEmpty ? "" : " (\(s.frontmostBundleID))")")
        }
        if !s.windowTitle.isEmpty {
            lines.append("- Window: \(s.windowTitle)")
        }
        lines.append("- Idle: \(s.idleSeconds)s")
        if s.batteryPercent >= 0 {
            lines.append("- Battery: \(s.batteryPercent)%\(s.isCharging ? " (charging)" : "")")
        }
        if s.memoryTotalGB > 0 {
            lines.append("- Memory: \(String(format: "%.1f", s.memoryUsedGB)) / \(String(format: "%.0f", s.memoryTotalGB)) GB")
        }
        lines.append("- Network: \(s.networkOnline ? "online" : "offline")")
        if !s.clipboardPreview.isEmpty {
            lines.append("- Clipboard: \(s.clipboardPreview)")
        }
        let age = Int(Date().timeIntervalSince(s.capturedAt))
        lines.append("- Captured: \(age)s ago")
        return lines.joined(separator: "\n")
    }
}
