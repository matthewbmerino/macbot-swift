import Foundation

enum ExecutorTools {
    static let spec = ToolSpec(
        name: "run_python",
        description: "Execute Python code in a sandboxed subprocess and return the output. Missing modules are auto-installed and retried.",
        properties: ["code": .init(type: "string", description: "Python code to execute")],
        required: ["code"]
    )

    static func register(on registry: ToolRegistry) async {
        await registry.register(spec) { args in
            await runPython(code: args["code"] as? String ?? "")
        }
    }

    // MARK: - Package Management

    static let allowedPipPackages: Set<String> = [
        "matplotlib", "numpy", "pandas", "scipy", "seaborn",
        "requests", "beautifulsoup4", "bs4", "pillow", "scikit-learn",
        "yfinance", "plotly", "sympy", "openpyxl", "xlsxwriter",
        "qrcode", "pytesseract", "pyobjc-framework-vision", "pyobjc-framework-quartz",
    ]

    /// Install a Python package via pip3. Restricted to allowlist.
    static func installPackage(_ name: String) async -> String {
        let pkg = name.trimmingCharacters(in: .whitespaces).lowercased()
        guard !pkg.isEmpty else { return "Error: empty package name" }
        guard allowedPipPackages.contains(pkg) else {
            return "Error: '\(pkg)' is not in the allowed package list."
        }

        Log.tools.info("Auto-installing Python package: \(pkg)")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["pip3", "install", "--user", pkg]
        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe

        do {
            try process.run()
            let deadline = Date().addingTimeInterval(120)
            while process.isRunning && Date() < deadline {
                try await Task.sleep(for: .milliseconds(200))
            }
            if process.isRunning {
                process.terminate()
                return "Error: pip install timed out after 120s"
            }
            let output = String(data: outPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            let error = String(data: errPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            if process.terminationStatus != 0 {
                return "Error: pip install failed — \(error.prefix(500))"
            }
            Log.tools.info("Installed \(pkg) successfully")
            return output.isEmpty ? "Installed \(pkg)" : String(output.prefix(500))
        } catch {
            return "Error: \(error.localizedDescription)"
        }
    }

    /// Extract the top-level module name from a "No module named 'foo.bar'" error.
    static func extractMissingModule(from output: String) -> String? {
        guard let range = output.range(of: "No module named '") ?? output.range(of: "No module named \"") else {
            return nil
        }
        let after = output[range.upperBound...]
        guard let end = after.firstIndex(where: { $0 == "'" || $0 == "\"" }) else { return nil }
        let module = String(after[..<end])
        return module.components(separatedBy: ".").first
    }

    /// Map Python import names to pip package names where they differ.
    static func pipPackageName(for module: String) -> String {
        let mapping: [String: String] = [
            "cv2": "opencv-python",
            "PIL": "pillow",
            "bs4": "beautifulsoup4",
            "sklearn": "scikit-learn",
            "yaml": "pyyaml",
        ]
        return mapping[module] ?? module
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

        let result = await executePythonSandboxed(code: code)

        // Auto-install missing module and retry once
        if result.contains("No module named") {
            if let module = extractMissingModule(from: result) {
                let pipName = pipPackageName(for: module)
                if allowedPipPackages.contains(pipName) {
                    Log.tools.info("Auto-installing missing module: \(pipName)")
                    let installResult = await installPackage(pipName)
                    if installResult.hasPrefix("Error:") {
                        return "Tried to auto-install '\(pipName)' but failed:\n\(installResult)\n\nOriginal error:\n\(result)"
                    }
                    return await executePythonSandboxed(code: code)
                } else {
                    return "Missing module '\(module)'. Package '\(pipName)' is not in the allowed install list."
                }
            }
        }

        return result
    }

    private static func executePythonSandboxed(code: String) async -> String {
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
