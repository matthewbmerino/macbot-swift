import Darwin
import Foundation

enum SystemDashboardTool {

    static let spec = ToolSpec(
        name: "system_dashboard",
        description: "Show a system health dashboard: CPU, memory, disk, battery, top processes, network, and Ollama model status.",
        properties: [:]
    )

    static func register(on registry: ToolRegistry) async {
        await registry.register(spec) { _ in
            await systemDashboard()
        }
    }

    // MARK: - System Dashboard

    static func systemDashboard() async -> String {
        var sections: [String] = ["System Dashboard", String(repeating: "─", count: 40)]

        // CPU
        if let cpu = shell("sysctl -n machdep.cpu.brand_string") {
            sections.append("CPU: \(cpu.trimmingCharacters(in: .whitespacesAndNewlines))")
        }
        if let load = shell("sysctl -n vm.loadavg") {
            sections.append("Load: \(load.trimmingCharacters(in: .whitespacesAndNewlines))")
        }

        // Memory
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
            let wired = Double(stats.wire_count) * pageSize / (1024 * 1024 * 1024)
            let compressed = Double(stats.compressor_page_count) * pageSize / (1024 * 1024 * 1024)
            let free = Double(stats.free_count) * pageSize / (1024 * 1024 * 1024)
            let used = active + wired + compressed
            let pressure = used / totalGB > 0.85 ? "HIGH" : used / totalGB > 0.7 ? "moderate" : "normal"

            sections.append("""
            Memory: \(String(format: "%.1f", used))GB / \(String(format: "%.1f", totalGB))GB (\(String(format: "%.0f", (used / totalGB) * 100))%) — pressure: \(pressure)
              Active: \(String(format: "%.1f", active))GB  Wired: \(String(format: "%.1f", wired))GB  Compressed: \(String(format: "%.1f", compressed))GB  Free: \(String(format: "%.1f", free))GB
            """)
        }

        // Disk
        if let disk = shell("df -h / | tail -1 | awk '{print $3 \" used / \" $2 \" total (\" $5 \" full)\"}'") {
            sections.append("Disk: \(disk.trimmingCharacters(in: .whitespacesAndNewlines))")
        }

        // Battery
        if let battery = shell("pmset -g batt | grep -E 'InternalBattery|AC Power'") {
            sections.append("Power: \(battery.trimmingCharacters(in: .whitespacesAndNewlines))")
        }

        // Uptime
        if let uptime = shell("uptime | sed 's/.*up //' | sed 's/,.*//'") {
            sections.append("Uptime: \(uptime.trimmingCharacters(in: .whitespacesAndNewlines))")
        }

        // Top 5 processes
        if let top = shell("ps -eo pcpu,rss,comm -r | head -6") {
            let lines = top.components(separatedBy: "\n").filter { !$0.isEmpty }
            if lines.count > 1 {
                sections.append("\nTop Processes (by CPU):")
                for line in lines.dropFirst().prefix(5) {
                    let parts = line.trimmingCharacters(in: .whitespaces)
                        .components(separatedBy: .whitespaces)
                        .filter { !$0.isEmpty }
                    guard parts.count >= 3 else { continue }
                    let cpu = parts[0]
                    let rssKB = Double(parts[1]) ?? 0
                    let name = parts[2...].joined(separator: " ").components(separatedBy: "/").last ?? parts[2]
                    sections.append("  \(name) — \(cpu)% CPU, \(String(format: "%.0f", rssKB / 1024)) MB")
                }
            }
        }

        // Network
        if let netCount = shell("netstat -an 2>/dev/null | grep ESTABLISHED | wc -l") {
            sections.append("\nNetwork: \(netCount.trimmingCharacters(in: .whitespacesAndNewlines)) established connections")
        }

        // Ollama status
        if let ollamaModels = shell("curl -s http://127.0.0.1:11434/api/tags 2>/dev/null") {
            if let data = ollamaModels.data(using: .utf8),
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let models = json["models"] as? [[String: Any]] {
                let names = models.compactMap { $0["name"] as? String }
                sections.append("Ollama: \(names.count) models installed (\(names.joined(separator: ", ")))")
            }
        } else {
            sections.append("Ollama: not reachable")
        }

        return sections.joined(separator: "\n")
    }

    // MARK: - Helpers

    static func shell(_ command: String) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-c", command]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        try? process.run()
        process.waitUntilExit()
        return String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)
    }
}
