import Foundation

struct DirectorStep: Identifiable {
    let id = UUID()
    let timestamp: Date
    let type: StepType
    let name: String
    let detail: String
    var status: StepStatus
    var result: String?
    var duration: TimeInterval?

    enum StepType: String {
        case toolCall, status, agentSwitch, thinking, image
    }

    enum StepStatus: String {
        case pending, running, completed, error
    }

    // MARK: - Icon mapping

    var iconName: String {
        switch type {
        case .toolCall:
            if name.localizedCaseInsensitiveContains("search") || name.localizedCaseInsensitiveContains("web") {
                return "globe"
            } else if name.localizedCaseInsensitiveContains("file") || name.localizedCaseInsensitiveContains("read") {
                return "doc.text"
            } else if name.localizedCaseInsensitiveContains("code") || name.localizedCaseInsensitiveContains("exec") {
                return "terminal"
            } else if name.localizedCaseInsensitiveContains("math") || name.localizedCaseInsensitiveContains("calc") {
                return "function"
            } else if name.localizedCaseInsensitiveContains("screen") {
                return "rectangle.on.rectangle"
            } else {
                return "wrench"
            }
        case .status:      return "info.circle"
        case .agentSwitch: return "person.crop.rectangle"
        case .thinking:    return "brain"
        case .image:       return "photo"
        }
    }

    var accentColor: String {
        switch type {
        case .toolCall:    return "cyan"
        case .status:      return "gray"
        case .agentSwitch: return "purple"
        case .thinking:    return "blue"
        case .image:       return "pink"
        }
    }
}
