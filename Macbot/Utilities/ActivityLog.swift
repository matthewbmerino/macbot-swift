import Foundation
import SwiftUI

/// A single activity log entry.
struct ActivityEntry: Identifiable {
    let id = UUID()
    let timestamp: Date
    let category: Category
    let message: String

    enum Category: String {
        case routing    // Agent selection
        case inference  // Model calls
        case tool       // Tool execution
        case memory     // Memory/RAG operations
        case system     // App lifecycle

        var color: Color {
            switch self {
            case .routing: .cyan
            case .inference: .purple
            case .tool: .orange
            case .memory: .green
            case .system: .gray
            }
        }

        var icon: String {
            switch self {
            case .routing: "arrow.triangle.branch"
            case .inference: "cube.transparent"
            case .tool: "wrench.and.screwdriver"
            case .memory: "memorychip"
            case .system: "gearshape"
            }
        }
    }

    var timeString: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        return formatter.string(from: timestamp)
    }
}

/// Observable activity log that captures real-time system events.
/// Views subscribe to this to show a live terminal feed.
@Observable
final class ActivityLog {
    static let shared = ActivityLog()

    private(set) var entries: [ActivityEntry] = []
    private let maxEntries = 200

    func log(_ category: ActivityEntry.Category, _ message: String) {
        let entry = ActivityEntry(timestamp: Date(), category: category, message: message)
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.entries.append(entry)
            if self.entries.count > self.maxEntries {
                self.entries.removeFirst(self.entries.count - self.maxEntries)
            }
        }
    }

    func clear() {
        entries.removeAll()
    }
}
