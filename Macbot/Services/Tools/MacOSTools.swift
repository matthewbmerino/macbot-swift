import Foundation
import AppKit

enum MacOSTools {
    static func register(on registry: ToolRegistry) async {
        await registerApps(on: registry)
        await registerProcesses(on: registry)
        await registerScreen(on: registry)
        await registerSystem(on: registry)
    }

    // MARK: - Shared Helpers

    static func runAppleScript(_ source: String) -> String? {
        let script = NSAppleScript(source: source)
        var error: NSDictionary?
        let result = script?.executeAndReturnError(&error)
        if let error {
            return "AppleScript error: \(error)"
        }
        return result?.stringValue
    }

    static func runShell(_ command: String) -> String? {
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
