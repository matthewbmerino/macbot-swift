import Foundation
import AppKit

extension MacOSTools {
    static let openAppSpec = ToolSpec(
        name: "open_app", description: "Open a macOS application by name.",
        properties: ["name": .init(type: "string", description: "App name")], required: ["name"]
    )
    static let openURLSpec = ToolSpec(
        name: "open_url", description: "Open a URL in the default browser.",
        properties: ["url": .init(type: "string", description: "URL to open")], required: ["url"]
    )
    static let quitAppSpec = ToolSpec(
        name: "quit_app", description: "Quit/close a running macOS application by name.",
        properties: ["name": .init(type: "string", description: "App name to quit")],
        required: ["name"]
    )
    static let focusAppSpec = ToolSpec(
        name: "focus_app", description: "Bring a running application to the front/focus.",
        properties: ["name": .init(type: "string", description: "App name to focus")],
        required: ["name"]
    )
    static let appsSpec = ToolSpec(
        name: "list_running_apps", description: "List all running applications with their PID, memory usage in MB, and CPU%. Shows what's actively running on the Mac.",
        properties: [:]
    )

    static func registerApps(on registry: ToolRegistry) async {
        await registry.register(openAppSpec) { args in await openApp(args["name"] as? String ?? "") }
        await registry.register(openURLSpec) { args in openURL(args["url"] as? String ?? "") }
        await registry.register(appsSpec) { _ in await listRunningApps() }
        await registry.register(quitAppSpec) { args in quitApp(args["name"] as? String ?? "") }
        await registry.register(focusAppSpec) { args in focusApp(args["name"] as? String ?? "") }
    }

    static func openApp(_ name: String) async -> String {
        let trimmed = name.trimmingCharacters(in: .whitespaces)

        // Try NSWorkspace first (most reliable)
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId(for: trimmed)) {
            let config = NSWorkspace.OpenConfiguration()
            do {
                try await NSWorkspace.shared.openApplication(at: url, configuration: config)
                return "Opened \(trimmed)"
            } catch {
                // Fall through to other methods
            }
        }

        // Try by path in /Applications
        let paths = [
            "/Applications/\(trimmed).app",
            "/Applications/Utilities/\(trimmed).app",
            "/System/Applications/\(trimmed).app",
            "/System/Applications/Utilities/\(trimmed).app",
        ]
        for path in paths {
            let url = URL(fileURLWithPath: path)
            if FileManager.default.fileExists(atPath: path) {
                do {
                    try await NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
                    return "Opened \(trimmed)"
                } catch { continue }
            }
        }

        // Try open command (catches everything else). Escape for shell
        // single-quote context so a malicious-looking app name like
        // `Safari'; rm -rf ~; echo '` can't break out.
        let shellSafe = InjectionSafety.escapeShellSingleQuote(trimmed)
        if let result = runShell("open -a '\(shellSafe)' 2>&1") {
            if !result.contains("Unable to find") {
                return "Opened \(trimmed)"
            }
        }

        // Last resort: AppleScript. Same hardening — escape for AS string
        // literal so quotes in the name can't terminate the string early.
        let asSafe = InjectionSafety.escapeAppleScriptString(trimmed)
        _ = runAppleScript("tell application \"\(asSafe)\" to activate")
        return "Opened \(trimmed)"
    }

    /// Map common app names to bundle identifiers.
    private static func bundleId(for name: String) -> String {
        let lower = name.lowercased()
        let bundleMap: [String: String] = [
            "safari": "com.apple.Safari",
            "terminal": "com.apple.Terminal",
            "finder": "com.apple.finder",
            "mail": "com.apple.mail",
            "messages": "com.apple.MobileSMS",
            "notes": "com.apple.Notes",
            "calendar": "com.apple.iCal",
            "music": "com.apple.Music",
            "photos": "com.apple.Photos",
            "maps": "com.apple.Maps",
            "preview": "com.apple.Preview",
            "textedit": "com.apple.TextEdit",
            "calculator": "com.apple.calculator",
            "activity monitor": "com.apple.ActivityMonitor",
            "system settings": "com.apple.systempreferences",
            "system preferences": "com.apple.systempreferences",
            "xcode": "com.apple.dt.Xcode",
            "vscode": "com.microsoft.VSCode",
            "visual studio code": "com.microsoft.VSCode",
            "chrome": "com.google.Chrome",
            "firefox": "org.mozilla.firefox",
            "slack": "com.tinyspeck.slackmacgap",
            "discord": "com.hnc.Discord",
            "spotify": "com.spotify.client",
            "iterm": "com.googlecode.iterm2",
            "iterm2": "com.googlecode.iterm2",
        ]
        return bundleMap[lower] ?? "com.apple.\(name)"
    }

    static func openURL(_ urlString: String) -> String {
        guard let url = URL(string: urlString) else { return "Error: invalid URL" }
        NSWorkspace.shared.open(url)
        return "Opened \(urlString)"
    }

    static func quitApp(_ name: String) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        let asSafe = InjectionSafety.escapeAppleScriptString(trimmed)
        let result = runAppleScript("tell application \"\(asSafe)\" to quit")
        if let err = result, err.contains("error") {
            let shellSafe = InjectionSafety.escapeShellSingleQuote(trimmed)
            _ = runShell("pkill -i '\(shellSafe)' 2>/dev/null")
        }
        return "Quit \(trimmed)"
    }

    static func focusApp(_ name: String) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        let asSafe = InjectionSafety.escapeAppleScriptString(trimmed)
        _ = runAppleScript("tell application \"\(asSafe)\" to activate")
        return "Focused \(trimmed)"
    }

    static func listRunningApps() async -> String {
        // Get per-process CPU and memory via ps
        guard let psOutput = runShell("ps -eo pid,pcpu,rss,comm -r | head -50") else {
            return fallbackAppList()
        }

        let apps = NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular }

        // Parse ps output into a lookup by PID
        var psData: [Int32: (cpu: String, memMB: String)] = [:]
        for line in psOutput.components(separatedBy: "\n").dropFirst() {
            let parts = line.trimmingCharacters(in: .whitespaces)
                .components(separatedBy: .whitespaces)
                .filter { !$0.isEmpty }
            guard parts.count >= 3, let pid = Int32(parts[0]) else { continue }
            let cpu = parts[1]
            let rssKB = Double(parts[2]) ?? 0
            let memMB = String(format: "%.0f", rssKB / 1024)
            psData[pid] = (cpu, memMB)
        }

        var lines: [String] = ["Running Applications:"]
        for app in apps.sorted(by: { ($0.localizedName ?? "") < ($1.localizedName ?? "") }) {
            let name = app.localizedName ?? "Unknown"
            let pid = app.processIdentifier
            if let data = psData[pid] {
                lines.append("  \(name) (PID \(pid)) — \(data.memMB) MB, \(data.cpu)% CPU")
            } else {
                lines.append("  \(name) (PID \(pid))")
            }
        }

        // Also show background processes using significant resources
        let heavyProcesses = runShell("ps -eo pid,pcpu,rss,comm -r | awk '$2 > 5.0 || $3 > 200000' | head -15")
        if let heavy = heavyProcesses, !heavy.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            lines.append("\nHigh-resource background processes:")
            for line in heavy.components(separatedBy: "\n") {
                let parts = line.trimmingCharacters(in: .whitespaces)
                    .components(separatedBy: .whitespaces)
                    .filter { !$0.isEmpty }
                guard parts.count >= 4 else { continue }
                let pid = parts[0]
                let cpu = parts[1]
                let rssKB = Double(parts[2]) ?? 0
                let name = parts[3...].joined(separator: " ")
                    .components(separatedBy: "/").last ?? parts[3]
                lines.append("  \(name) (PID \(pid)) — \(String(format: "%.0f", rssKB / 1024)) MB, \(cpu)% CPU")
            }
        }

        return lines.joined(separator: "\n")
    }

    private static func fallbackAppList() -> String {
        let apps = NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular }
            .compactMap { $0.localizedName }
            .sorted()
        return apps.isEmpty ? "No running apps" : apps.joined(separator: "\n")
    }
}
