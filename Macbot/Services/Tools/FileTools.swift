import Foundation

enum FileTools {
    static let readSpec = ToolSpec(
        name: "read_file",
        description: "Read the contents of a file.",
        properties: ["path": .init(type: "string", description: "File path to read")],
        required: ["path"]
    )

    static let writeSpec = ToolSpec(
        name: "write_file",
        description: "Write content to a file. Creates the file if it doesn't exist.",
        properties: [
            "path": .init(type: "string", description: "File path to write"),
            "content": .init(type: "string", description: "Content to write"),
        ],
        required: ["path", "content"]
    )

    static let listSpec = ToolSpec(
        name: "list_directory",
        description: "List the contents of a directory.",
        properties: ["path": .init(type: "string", description: "Directory path")],
        required: ["path"]
    )

    static let searchSpec = ToolSpec(
        name: "search_files",
        description: "Search for files matching a pattern in a directory.",
        properties: [
            "directory": .init(type: "string", description: "Directory to search"),
            "pattern": .init(type: "string", description: "Search pattern (glob)"),
        ],
        required: ["directory", "pattern"]
    )

    static let commandSpec = ToolSpec(
        name: "run_command",
        description: "Run a shell command and return the output. Dangerous commands are blocked.",
        properties: ["command": .init(type: "string", description: "Shell command to run")],
        required: ["command"]
    )

    private static let dangerousPatterns = [
        "rm -rf /", "rm -rf ~", "mkfs", "dd if=", "format",
        "> /dev/sd", "chmod -R 777 /", ":(){ :|:& };:",
    ]

    static func register(on registry: ToolRegistry) async {
        await registry.register(readSpec) { args in
            readFile(path: args["path"] as? String ?? "")
        }
        await registry.register(writeSpec) { args in
            writeFile(path: args["path"] as? String ?? "", content: args["content"] as? String ?? "")
        }
        await registry.register(listSpec) { args in
            listDirectory(path: args["path"] as? String ?? "")
        }
        await registry.register(searchSpec) { args in
            searchFiles(directory: args["directory"] as? String ?? "", pattern: args["pattern"] as? String ?? "")
        }
        await registry.register(commandSpec) { args in
            await runCommand(command: args["command"] as? String ?? "")
        }
    }

    static func readFile(path: String) -> String {
        let expanded = NSString(string: path).expandingTildeInPath
        guard FileManager.default.fileExists(atPath: expanded) else {
            return "Error: file not found: \(path)"
        }
        do {
            let content = try String(contentsOfFile: expanded, encoding: .utf8)
            if content.count > 10000 {
                return String(content.prefix(10000)) + "\n... (truncated)"
            }
            return content
        } catch {
            return "Error reading file: \(error.localizedDescription)"
        }
    }

    static func writeFile(path: String, content: String) -> String {
        let expanded = NSString(string: path).expandingTildeInPath
        do {
            try content.write(toFile: expanded, atomically: true, encoding: .utf8)
            return "Written \(content.count) characters to \(path)"
        } catch {
            return "Error writing file: \(error.localizedDescription)"
        }
    }

    static func listDirectory(path: String) -> String {
        let expanded = NSString(string: path).expandingTildeInPath
        do {
            let items = try FileManager.default.contentsOfDirectory(atPath: expanded)
            if items.isEmpty { return "(empty directory)" }
            return items.sorted().joined(separator: "\n")
        } catch {
            return "Error: \(error.localizedDescription)"
        }
    }

    static func searchFiles(directory: String, pattern: String) -> String {
        let expanded = NSString(string: directory).expandingTildeInPath
        let fm = FileManager.default

        guard let enumerator = fm.enumerator(atPath: expanded) else {
            return "Error: cannot access \(directory)"
        }

        var matches: [String] = []
        while let file = enumerator.nextObject() as? String {
            if file.lowercased().contains(pattern.lowercased()) {
                matches.append(file)
                if matches.count >= 50 { break }
            }
        }

        return matches.isEmpty ? "No files matching '\(pattern)'" : matches.joined(separator: "\n")
    }

    static func runCommand(command: String) async -> String {
        // Block dangerous commands
        for pattern in dangerousPatterns {
            if command.contains(pattern) {
                return "Error: this command is blocked for safety."
            }
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-c", command]

        let pipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = pipe
        process.standardError = errPipe

        do {
            try process.run()

            // Timeout after 30 seconds
            let deadline = Date().addingTimeInterval(30)
            while process.isRunning && Date() < deadline {
                try await Task.sleep(for: .milliseconds(100))
            }
            if process.isRunning {
                process.terminate()
                return "Error: command timed out after 30s"
            }

            let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            let error = String(data: errPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""

            var result = output
            if !error.isEmpty { result += "\nSTDERR: \(error)" }
            if result.count > 5000 { result = String(result.prefix(5000)) + "\n... (truncated)" }
            return result.isEmpty ? "(no output)" : result
        } catch {
            return "Error: \(error.localizedDescription)"
        }
    }
}
