import Foundation

struct GhostStep: Identifiable {
    let id = UUID()
    let app: String           // "Xcode", "Finder", "Safari"
    let action: GhostAction
    let description: String   // Human-readable narration
    var status: StepStatus = .pending

    enum GhostAction {
        case click(elementLabel: String)
        case type(text: String)
        case menu(path: [String])      // ["File", "New", "Project..."]
        case shortcut(keys: String)    // "Cmd+N"
        case wait(seconds: Double)
    }

    enum StepStatus: String {
        case pending, running, completed, failed
    }
}
