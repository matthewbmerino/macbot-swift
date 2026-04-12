import Foundation
import AppKit

/// Bridges the /director command to the SwiftUI Director window.
/// Stores the pending task and brings the window forward; DirectorView
/// picks up the task on appear or via notification.
@MainActor
final class DirectorLauncher {
    static let shared = DirectorLauncher()
    static let taskNotification = Notification.Name("com.macbot.directorTask")

    /// Pending task set before the window appears so DirectorView can pick it up.
    var pendingTask: String?

    /// Stored reference to SwiftUI's openWindow action, set by MacbotApp on appear.
    var openWindowAction: ((String) -> Void)?

    func launch(task: String) {
        pendingTask = task

        // Try to bring an existing Director window forward
        var found = false
        for window in NSApplication.shared.windows where window.title == "Director" {
            window.makeKeyAndOrderFront(nil)
            NSApplication.shared.activate(ignoringOtherApps: true)
            found = true
            break
        }

        // Open the window if not found
        if !found {
            openWindowAction?("director")
        }

        // Post notification so DirectorView picks up the task
        NotificationCenter.default.post(
            name: Self.taskNotification,
            object: nil,
            userInfo: ["task": task]
        )
    }
}
