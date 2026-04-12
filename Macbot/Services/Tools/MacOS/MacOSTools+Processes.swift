import Foundation

extension MacOSTools {
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

    static func registerProcesses(on registry: ToolRegistry) async {
        await registry.register(processDetailSpec) { args in
            await getProcessDetails(query: args["query"] as? String ?? "")
        }
        await registry.register(topProcessesSpec) { args in
            await getTopProcesses(sortBy: args["sort_by"] as? String ?? "cpu")
        }
        await registry.register(portSpec) { _ in await getListeningPorts() }
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
}
