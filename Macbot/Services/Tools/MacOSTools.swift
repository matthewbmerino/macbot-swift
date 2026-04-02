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
        name: "list_running_apps", description: "List all running visible applications.",
        properties: [:]
    )
    static let systemInfoSpec = ToolSpec(
        name: "get_system_info", description: "Get system info: battery, disk, uptime.",
        properties: [:]
    )
    static let screenshotSpec = ToolSpec(
        name: "take_screenshot", description: "Take a screenshot of the screen and display it inline in the chat. The screenshot will be shown as an image in the response automatically.",
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
        await registry.register(appsSpec) { _ in listRunningApps() }
        await registry.register(systemInfoSpec) { _ in await getSystemInfo() }
        await registry.register(screenshotSpec) { _ in await takeScreenshot() }
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

    static func listRunningApps() -> String {
        let apps = NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular }
            .compactMap { $0.localizedName }
            .sorted()
        return apps.isEmpty ? "No running apps" : apps.joined(separator: "\n")
    }

    static func getSystemInfo() async -> String {
        var info: [String] = []

        // Battery
        if let battery = runShell("pmset -g batt") {
            info.append("Battery: \(battery.trimmingCharacters(in: .whitespacesAndNewlines))")
        }

        // Disk
        if let disk = runShell("df -h / | tail -1") {
            info.append("Disk: \(disk.trimmingCharacters(in: .whitespacesAndNewlines))")
        }

        // Uptime
        if let uptime = runShell("uptime") {
            info.append(uptime.trimmingCharacters(in: .whitespacesAndNewlines))
        }

        // Memory
        if let mem = runShell("vm_stat | head -5") {
            info.append("Memory:\n\(mem.trimmingCharacters(in: .whitespacesAndNewlines))")
        }

        return info.joined(separator: "\n\n")
    }

    static func takeScreenshot() async -> String {
        let path = "/tmp/macbot_screenshot.png"
        let url = URL(fileURLWithPath: path)

        // Use native CGWindowListCreateImage — avoids repeated permission prompts
        guard let image = CGWindowListCreateImage(
            CGRect.null,  // null = entire display
            .optionOnScreenOnly,
            kCGNullWindowID,
            [.bestResolution]
        ) else {
            return "Error: screenshot failed — grant Screen Recording permission in System Settings > Privacy & Security"
        }

        let bitmap = NSBitmapImageRep(cgImage: image)
        guard let pngData = bitmap.representation(using: .png, properties: [:]) else {
            return "Error: failed to encode screenshot"
        }

        do {
            try pngData.write(to: url)
            return "Screenshot captured\n[IMAGE:\(path)]"
        } catch {
            return "Error: \(error.localizedDescription)"
        }
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
