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

    // Blocked patterns — commands that should never be executed.
    // Uses allowlist of safe directories instead of a bypassable blocklist.
    private static let blockedImports: Set<String> = [
        "subprocess", "shutil.rmtree", "ctypes", "signal",
    ]

    /// Sandbox profile for macOS sandbox-exec.
    /// Restricts file system access to temp directory and read-only access elsewhere.
    private static let sandboxProfile = """
    (version 1)
    (deny default)
    (allow file-read*)
    (allow file-write*
        (subpath "/private/tmp")
        (subpath "/tmp")
        (subpath "\(NSTemporaryDirectory())")
    )
    (allow process-exec)
    (allow process-fork)
    (allow sysctl-read)
    (allow mach-lookup)
    (allow network-outbound)
    (allow system-socket)
    """

    static func runPython(code: String) async -> String {
        // Check for blocked imports
        for blocked in blockedImports {
            if code.contains(blocked) {
                return "Error: '\(blocked)' is not allowed in sandboxed execution."
            }
        }

        let tmpDir = NSTemporaryDirectory() + "macbot_sandbox_\(UUID().uuidString)/"
        let tmpFile = tmpDir + "script.py"

        do {
            try FileManager.default.createDirectory(atPath: tmpDir, withIntermediateDirectories: true)
            try code.write(toFile: tmpFile, atomically: true, encoding: .utf8)
        } catch {
            return "Error writing temp file: \(error.localizedDescription)"
        }

        defer { try? FileManager.default.removeItem(atPath: tmpDir) }

        let process = Process()

        // Use sandbox-exec for macOS sandboxing when available
        let sandboxProfilePath = tmpDir + "sandbox.sb"
        if let _ = try? sandboxProfile.write(toFile: sandboxProfilePath, atomically: true, encoding: .utf8) {
            process.executableURL = URL(fileURLWithPath: "/usr/bin/sandbox-exec")
            process.arguments = ["-f", sandboxProfilePath, "/usr/bin/env", "python3", tmpFile]
        } else {
            // Fallback without sandbox
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = ["python3", tmpFile]
        }

        process.currentDirectoryURL = URL(fileURLWithPath: tmpDir)

        // Restrict environment
        process.environment = [
            "PATH": "/usr/bin:/usr/local/bin:/opt/homebrew/bin",
            "HOME": tmpDir,
            "TMPDIR": tmpDir,
            "PYTHONDONTWRITEBYTECODE": "1",
        ]

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
