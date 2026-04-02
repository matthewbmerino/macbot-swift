import Foundation
import AppKit

enum AppContext {
    case coding      // Xcode, VS Code, Terminal, iTerm
    case writing     // Mail, Notes, Pages, TextEdit, Messages
    case browsing    // Safari, Chrome, Firefox, Arc
    case design      // Figma, Sketch, Preview
    case general     // Everything else

    var suggestedAgent: AgentCategory {
        switch self {
        case .coding: .coder
        case .writing, .browsing, .design, .general: .general
        }
    }

    var contextHint: String? {
        switch self {
        case .coding: "The user is working in a code editor. Default to technical, code-focused responses."
        case .writing: "The user is writing. Help with clarity, tone, and grammar."
        case .browsing: "The user is browsing the web. Help with research and summarization."
        case .design: "The user is working on design. Help with visual decisions and descriptions."
        case .general: nil
        }
    }
}

enum ContextDetector {
    private static let codingApps: Set<String> = [
        "Xcode", "Visual Studio Code", "Code", "Terminal", "iTerm2",
        "Cursor", "Nova", "Sublime Text", "Zed", "Warp",
    ]

    private static let writingApps: Set<String> = [
        "Mail", "Notes", "Pages", "TextEdit", "Messages",
        "Microsoft Word", "Google Docs", "Bear", "Obsidian", "Notion",
    ]

    private static let browsingApps: Set<String> = [
        "Safari", "Google Chrome", "Firefox", "Arc", "Brave Browser",
        "Microsoft Edge", "Orion",
    ]

    private static let designApps: Set<String> = [
        "Figma", "Sketch", "Preview", "Pixelmator Pro",
        "Adobe Photoshop", "Adobe Illustrator", "Affinity Designer",
    ]

    static func detect() -> AppContext {
        guard let app = NSWorkspace.shared.frontmostApplication,
              let name = app.localizedName else {
            return .general
        }

        if codingApps.contains(name) { return .coding }
        if writingApps.contains(name) { return .writing }
        if browsingApps.contains(name) { return .browsing }
        if designApps.contains(name) { return .design }
        return .general
    }
}
