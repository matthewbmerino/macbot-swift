import Foundation
import AppKit

extension MacOSTools {
    static let systemInfoSpec = ToolSpec(
        name: "get_system_info", description: "Get detailed system info: CPU usage, memory breakdown (used/free/wired/compressed), disk, battery, uptime, GPU, and active processes count.",
        properties: [:]
    )
    static let notifySpec = ToolSpec(
        name: "send_notification", description: "Show a macOS notification.",
        properties: [
            "title": .init(type: "string", description: "Notification title"),
            "message": .init(type: "string", description: "Notification body"),
        ], required: ["title", "message"]
    )
    static let clipboardGetSpec = ToolSpec(
        name: "get_clipboard", description: "Get the current clipboard contents.",
        properties: [:]
    )
    static let clipboardSetSpec = ToolSpec(
        name: "set_clipboard", description: "Set the clipboard contents.",
        properties: ["text": .init(type: "string", description: "Text to copy")], required: ["text"]
    )
    static let setVolumeSpec = ToolSpec(
        name: "set_volume", description: "Set the system audio volume (0-100).",
        properties: ["level": .init(type: "string", description: "Volume level 0-100")],
        required: ["level"]
    )
    static let toggleDarkModeSpec = ToolSpec(
        name: "toggle_dark_mode", description: "Toggle macOS dark mode on or off.",
        properties: [:]
    )
    static let runAppleScriptSpec = ToolSpec(
        name: "run_applescript", description: "Execute arbitrary AppleScript code. Use this for any macOS automation: controlling apps, clicking UI elements, managing windows, typing text, adjusting system settings, or anything else AppleScript can do.",
        properties: ["script": .init(type: "string", description: "AppleScript code to execute")],
        required: ["script"]
    )
    static let runShellSpec = ToolSpec(
        name: "run_command", description: "Run a shell command and return the output. Use for any system operation: file management, git, brew, network tools, etc.",
        properties: ["command": .init(type: "string", description: "Shell command to run")],
        required: ["command"]
    )

    static func registerSystem(on registry: ToolRegistry) async {
        await registry.register(notifySpec) { args in
            sendNotification(title: args["title"] as? String ?? "", message: args["message"] as? String ?? "")
        }
        await registry.register(clipboardGetSpec) { _ in getClipboard() }
        await registry.register(clipboardSetSpec) { args in setClipboard(args["text"] as? String ?? "") }
        await registry.register(systemInfoSpec) { _ in await getSystemInfo() }
        await registry.register(setVolumeSpec) { args in
            setVolume(level: args["level"] as? String ?? "50")
        }
        await registry.register(toggleDarkModeSpec) { _ in toggleDarkMode() }
        await registry.register(runAppleScriptSpec) { args in
            executeAppleScript(args["script"] as? String ?? "")
        }
        await registry.register(runShellSpec) { args in
            await executeShellCommand(args["command"] as? String ?? "")
        }
    }

    static func sendNotification(title: String, message: String) -> String {
        let safeTitle = InjectionSafety.escapeAppleScriptString(title)
        let safeMessage = InjectionSafety.escapeAppleScriptString(message)
        let script = """
        display notification "\(safeMessage)" with title "\(safeTitle)"
        """
        _ = runAppleScript(script)
        return "Notification sent: \(title)"
    }

    static func getClipboard() -> String {
        NSPasteboard.general.string(forType: .string) ?? "(clipboard empty)"
    }

    static func setClipboard(_ text: String) -> String {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        return "Copied to clipboard: \(String(text.prefix(100)))"
    }

    static func getSystemInfo() async -> String {
        var info: [String] = []

        // CPU
        if let cpu = runShell("sysctl -n machdep.cpu.brand_string") {
            info.append("CPU: \(cpu.trimmingCharacters(in: .whitespacesAndNewlines))")
        }
        if let loadAvg = runShell("sysctl -n vm.loadavg") {
            info.append("Load Average: \(loadAvg.trimmingCharacters(in: .whitespacesAndNewlines))")
        }

        // Memory — detailed breakdown
        let totalBytes = ProcessInfo.processInfo.physicalMemory
        let totalGB = Double(totalBytes) / (1024 * 1024 * 1024)

        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &stats) { ptr in
            ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { intPtr in
                host_statistics64(mach_host_self(), HOST_VM_INFO64, intPtr, &count)
            }
        }

        if result == KERN_SUCCESS {
            let pageSize = Double(kernelPageSize)
            let active = Double(stats.active_count) * pageSize / (1024 * 1024 * 1024)
            let inactive = Double(stats.inactive_count) * pageSize / (1024 * 1024 * 1024)
            let wired = Double(stats.wire_count) * pageSize / (1024 * 1024 * 1024)
            let compressed = Double(stats.compressor_page_count) * pageSize / (1024 * 1024 * 1024)
            let free = Double(stats.free_count) * pageSize / (1024 * 1024 * 1024)
            let used = active + wired + compressed
            let swapUsed = Double(stats.swapouts) > 0

            info.append("""
            Memory: \(String(format: "%.1f", used))GB used / \(String(format: "%.1f", totalGB))GB total (\(String(format: "%.0f", (used / totalGB) * 100))%)
              Active: \(String(format: "%.1f", active))GB
              Wired: \(String(format: "%.1f", wired))GB
              Compressed: \(String(format: "%.1f", compressed))GB
              Inactive: \(String(format: "%.1f", inactive))GB
              Free: \(String(format: "%.1f", free))GB
              Memory Pressure: \(used / totalGB > 0.85 ? "HIGH" : used / totalGB > 0.7 ? "moderate" : "normal")\(swapUsed ? " (swap active)" : "")
            """)
        }

        // GPU
        if let gpuInfo = runShell("system_profiler SPDisplaysDataType 2>/dev/null | grep -E 'Chipset|VRAM|Metal|Cores'") {
            let lines = gpuInfo.trimmingCharacters(in: .whitespacesAndNewlines)
            if !lines.isEmpty {
                info.append("GPU:\n\(lines)")
            }
        }

        // Battery
        if let battery = runShell("pmset -g batt | grep -E 'InternalBattery|AC Power'") {
            info.append("Power: \(battery.trimmingCharacters(in: .whitespacesAndNewlines))")
        }

        // Disk
        if let disk = runShell("df -h / | tail -1 | awk '{print \"Disk: \" $3 \" used / \" $2 \" total (\" $5 \" full)\"}'") {
            info.append(disk.trimmingCharacters(in: .whitespacesAndNewlines))
        }

        // Uptime
        if let uptime = runShell("uptime | sed 's/.*up /Uptime: /' | sed 's/,.*//'") {
            info.append(uptime.trimmingCharacters(in: .whitespacesAndNewlines))
        }

        // Process count
        if let procCount = runShell("ps -e | wc -l") {
            let count = procCount.trimmingCharacters(in: .whitespacesAndNewlines)
            info.append("Active Processes: \(count)")
        }

        // Network connections
        if let netCount = runShell("netstat -an 2>/dev/null | grep ESTABLISHED | wc -l") {
            let count = netCount.trimmingCharacters(in: .whitespacesAndNewlines)
            info.append("Network Connections: \(count) established")
        }

        return info.joined(separator: "\n")
    }

    static func setVolume(level: String) -> String {
        let vol = Int(level) ?? 50
        let clamped = max(0, min(100, vol))
        _ = runAppleScript("set volume output volume \(clamped)")
        return "Volume set to \(clamped)%"
    }

    static func toggleDarkMode() -> String {
        let result = runAppleScript("""
        tell application "System Events"
            tell appearance preferences
                set dark mode to not dark mode
                return dark mode as string
            end tell
        end tell
        """)
        let mode = result == "true" ? "dark" : "light"
        return "Switched to \(mode) mode"
    }

    // MARK: - General Execution

    static func executeAppleScript(_ script: String) -> String {
        let result = runAppleScript(script)
        return result ?? "(no output)"
    }

    static func executeShellCommand(_ command: String) async -> String {
        let trimmed = command.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return "Error: empty command" }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-c", trimmed]
        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe

        do {
            try process.run()

            let deadline = Date().addingTimeInterval(30)
            while process.isRunning && Date() < deadline {
                try await Task.sleep(for: .milliseconds(100))
            }
            if process.isRunning {
                process.terminate()
                return "Error: command timed out after 30s"
            }

            let output = String(data: outPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            let error = String(data: errPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""

            var result = ""
            if !output.isEmpty { result += output }
            if !error.isEmpty { result += (result.isEmpty ? "" : "\n") + "STDERR: \(error)" }
            if result.count > 5000 { result = String(result.prefix(5000)) + "\n... (truncated)" }
            return result.isEmpty ? "(no output)" : result
        } catch {
            return "Error: \(error.localizedDescription)"
        }
    }
}
