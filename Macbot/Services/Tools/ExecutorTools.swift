import Foundation

enum ExecutorTools {
    static let spec = ToolSpec(
        name: "run_python",
        description: "Execute Python code in a sandboxed subprocess and return the output.",
        properties: ["code": .init(type: "string", description: "Python code to execute")],
        required: ["code"]
    )

    static func register(on registry: ToolRegistry) async {
        await registry.register(spec) { args in
            await runPython(code: args["code"] as? String ?? "")
        }
    }

    static func runPython(code: String) async -> String {
        let tmpFile = NSTemporaryDirectory() + "macbot_exec_\(UUID().uuidString).py"

        do {
            try code.write(toFile: tmpFile, atomically: true, encoding: .utf8)
        } catch {
            return "Error writing temp file: \(error.localizedDescription)"
        }

        defer { try? FileManager.default.removeItem(atPath: tmpFile) }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["python3", tmpFile]
        process.currentDirectoryURL = URL(fileURLWithPath: NSTemporaryDirectory())

        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
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
                return "Error: execution timed out after 30s"
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
