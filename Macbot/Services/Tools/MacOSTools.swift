import Foundation
import AppKit

enum MacOSTools {
    static let openAppSpec = ToolSpec(
        name: "open_app", description: "Open a macOS application by name.",
        properties: ["name": .init(type: "string", description: "App name")], required: ["name"]
    )
    static let openURLSpec = ToolSpec(
        name: "open_url", description: "Open a URL in the default browser.",
        properties: ["url": .init(type: "string", description: "URL to open")], required: ["url"]
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
    static let appsSpec = ToolSpec(
        name: "list_running_apps", description: "List all running applications with their PID, memory usage in MB, and CPU%. Shows what's actively running on the Mac.",
        properties: [:]
    )
    static let systemInfoSpec = ToolSpec(
        name: "get_system_info", description: "Get detailed system info: CPU usage, memory breakdown (used/free/wired/compressed), disk, battery, uptime, GPU, and active processes count.",
        properties: [:]
    )
    static let screenshotSpec = ToolSpec(
        name: "take_screenshot", description: "Take a screenshot of the screen and display it inline in the chat. The screenshot will be shown as an image in the response automatically.",
        properties: [:]
    )
    static let processDetailSpec = ToolSpec(
        name: "get_process_details", description: "Get detailed info about a specific running process by name or PID: memory usage, CPU%, threads, open files, ports, and runtime.",
        properties: ["query": .init(type: "string", description: "Process name or PID to inspect")],
        required: ["query"]
    )
    static let topProcessesSpec = ToolSpec(
        name: "get_top_processes", description: "Get the top processes by CPU or memory usage. Shows what's consuming the most resources right now.",
        properties: ["sort_by": .init(type: "string", description: "'cpu' or 'memory' (default: cpu)")],
        required: []
    )
    static let portSpec = ToolSpec(
        name: "get_listening_ports", description: "List all processes listening on network ports. Useful for finding what servers/services are running (web servers, databases, dev servers, etc.).",
        properties: [:]
    )

    static func register(on registry: ToolRegistry) async {
        await registry.register(openAppSpec) { args in openApp(args["name"] as? String ?? "") }
        await registry.register(openURLSpec) { args in openURL(args["url"] as? String ?? "") }
        await registry.register(notifySpec) { args in
            sendNotification(title: args["title"] as? String ?? "", message: args["message"] as? String ?? "")
        }
        await registry.register(clipboardGetSpec) { _ in getClipboard() }
        await registry.register(clipboardSetSpec) { args in setClipboard(args["text"] as? String ?? "") }
        await registry.register(appsSpec) { _ in await listRunningApps() }
        await registry.register(systemInfoSpec) { _ in await getSystemInfo() }
        await registry.register(screenshotSpec) { _ in await takeScreenshot() }
        await registry.register(processDetailSpec) { args in
            await getProcessDetails(query: args["query"] as? String ?? "")
        }
        await registry.register(topProcessesSpec) { args in
            await getTopProcesses(sortBy: args["sort_by"] as? String ?? "cpu")
        }
        await registry.register(portSpec) { _ in await getListeningPorts() }
    }

    static func openApp(_ name: String) -> String {
        let result = runAppleScript("tell application \"\(name)\" to activate")
        return result ?? "Opened \(name)"
    }

    static func openURL(_ urlString: String) -> String {
        guard let url = URL(string: urlString) else { return "Error: invalid URL" }
        NSWorkspace.shared.open(url)
        return "Opened \(urlString)"
    }

    static func sendNotification(title: String, message: String) -> String {
        let script = """
        display notification "\(message)" with title "\(title)"
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
            let pageSize = Double(vm_kernel_page_size)
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

    // MARK: - Process Details

    static func getProcessDetails(query: String) async -> String {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return "Error: provide a process name or PID" }

        // Try as PID first
        let isPID = Int(trimmed) != nil
        let pidStr: String

        if isPID {
            pidStr = trimmed
        } else {
            // Find PID by name
            guard let result = runShell("pgrep -i -x '\(trimmed)' 2>/dev/null || pgrep -i '\(trimmed)' 2>/dev/null | head -1") else {
                return "No process found matching '\(trimmed)'"
            }
            pidStr = result.trimmingCharacters(in: .whitespacesAndNewlines).components(separatedBy: "\n").first ?? ""
            if pidStr.isEmpty {
                return "No process found matching '\(trimmed)'"
            }
        }

        guard let pid = Int(pidStr) else { return "No process found matching '\(trimmed)'" }

        var lines: [String] = []

        // Basic info: name, CPU, memory, threads, user
        if let psInfo = runShell("ps -p \(pid) -o pid,pcpu,rss,vsz,user,started,etime,command") {
            let psLines = psInfo.components(separatedBy: "\n").filter { !$0.isEmpty }
            if psLines.count >= 2 {
                let parts = psLines[1].trimmingCharacters(in: .whitespaces)
                    .components(separatedBy: .whitespaces)
                    .filter { !$0.isEmpty }
                if parts.count >= 7 {
                    let rssKB = Double(parts[2]) ?? 0
                    let vszKB = Double(parts[3]) ?? 0
                    let user = parts[4]
                    let started = parts[5]
                    let elapsed = parts[6]
                    let command = parts[7...].joined(separator: " ")

                    lines.append("Process: \(command.components(separatedBy: "/").last ?? command)")
                    lines.append("PID: \(pid)")
                    lines.append("User: \(user)")
                    lines.append("CPU: \(parts[1])%")
                    lines.append("Memory (RSS): \(String(format: "%.1f", rssKB / 1024)) MB")
                    lines.append("Virtual Memory: \(String(format: "%.1f", vszKB / 1024)) MB")
                    lines.append("Started: \(started)")
                    lines.append("Elapsed: \(elapsed)")
                }
            }
        }

        // Thread count
        if let threads = runShell("ps -M -p \(pid) 2>/dev/null | wc -l") {
            let count = (Int(threads.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 1) - 1
            lines.append("Threads: \(count)")
        }

        // Open files count
        if let fileCount = runShell("lsof -p \(pid) 2>/dev/null | wc -l") {
            let count = fileCount.trimmingCharacters(in: .whitespacesAndNewlines)
            lines.append("Open Files: \(count)")
        }

        // Network connections
        if let netInfo = runShell("lsof -i -p \(pid) 2>/dev/null | grep -v '^COMMAND' | head -10") {
            let net = netInfo.trimmingCharacters(in: .whitespacesAndNewlines)
            if !net.isEmpty {
                lines.append("Network:\n\(net)")
            }
        }

        return lines.isEmpty ? "No info found for PID \(pid)" : lines.joined(separator: "\n")
    }

    // MARK: - Top Processes

    static func getTopProcesses(sortBy: String) async -> String {
        let flag = sortBy.lowercased() == "memory" ? "-m" : "-r"
        guard let output = runShell("ps -eo pid,pcpu,rss,comm \(flag) | head -16") else {
            return "Error: could not get process list"
        }

        let psLines = output.components(separatedBy: "\n").filter { !$0.isEmpty }
        guard psLines.count > 1 else { return "No processes found" }

        let sortLabel = sortBy.lowercased() == "memory" ? "memory" : "CPU"
        var lines = ["Top processes by \(sortLabel):"]

        for line in psLines.dropFirst() {
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

        return lines.joined(separator: "\n")
    }

    // MARK: - Listening Ports

    static func getListeningPorts() async -> String {
        guard let output = runShell("lsof -iTCP -sTCP:LISTEN -P -n 2>/dev/null | grep -v '^COMMAND'") else {
            return "No listening ports found (or insufficient permissions)"
        }

        let portLines = output.trimmingCharacters(in: .whitespacesAndNewlines)
            .components(separatedBy: "\n")
            .filter { !$0.isEmpty }

        guard !portLines.isEmpty else { return "No listening ports found" }

        var lines = ["Listening ports:"]
        var seen = Set<String>()

        for line in portLines {
            let parts = line.components(separatedBy: .whitespaces).filter { !$0.isEmpty }
            guard parts.count >= 9 else { continue }
            let name = parts[0]
            let pid = parts[1]
            let address = parts[8]

            let key = "\(name):\(address)"
            guard !seen.contains(key) else { continue }
            seen.insert(key)

            lines.append("  \(name) (PID \(pid)) — \(address)")
        }

        return lines.joined(separator: "\n")
    }

    static func takeScreenshot() async -> String {
        let path = "/tmp/macbot_screenshot.png"

        // Use screencapture — permission prompt is unavoidable in debug builds
        // (each Xcode build is a new binary signature; goes away with signed distribution)
        _ = runShell("screencapture -x \(path)")

        // Verify the file was created and has content
        let fm = FileManager.default
        if fm.fileExists(atPath: path),
           let attrs = try? fm.attributesOfItem(atPath: path),
           let size = attrs[.size] as? Int, size > 0 {
            return "Screenshot captured\n[IMAGE:\(path)]"
        }

        return "Error: screenshot failed — grant Screen Recording permission in System Settings > Privacy & Security > Screen Recording"
    }

    // MARK: - Helpers

    private static func runAppleScript(_ source: String) -> String? {
        let script = NSAppleScript(source: source)
        var error: NSDictionary?
        let result = script?.executeAndReturnError(&error)
        if let error {
            return "AppleScript error: \(error)"
        }
        return result?.stringValue
    }

    private static func runShell(_ command: String) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-c", command]
        let pipe = Pipe()
        process.standardOutput = pipe
        try? process.run()
        process.waitUntilExit()
        return String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)
    }
}
