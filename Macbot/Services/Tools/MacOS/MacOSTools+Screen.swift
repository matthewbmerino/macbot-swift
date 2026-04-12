import Foundation

extension MacOSTools {
    static let screenshotSpec = ToolSpec(
        name: "take_screenshot", description: "Take a screenshot of the screen and display it inline in the chat. The screenshot will be shown as an image in the response automatically.",
        properties: [:]
    )

    static func registerScreen(on registry: ToolRegistry) async {
        await registry.register(screenshotSpec) { _ in await takeScreenshot() }
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
}
