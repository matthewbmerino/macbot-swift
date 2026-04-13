import Foundation
import GRDB

// MARK: - GRDB Records

struct CanvasRecord: Codable, FetchableRecord, PersistableRecord, Identifiable {
    var id: String
    var title: String
    var viewportOffsetX: Double
    var viewportOffsetY: Double
    var viewportScale: Double
    var createdAt: Date
    var updatedAt: Date

    static let databaseTableName = "canvases"
}

struct CanvasNodeRecord: Codable, FetchableRecord, PersistableRecord, Identifiable {
    var id: String
    var canvasId: String
    var positionX: Double
    var positionY: Double
    var width: Double
    var text: String
    var color: String
    var sourceType: String       // "manual", "chat", "ai"
    var sourceChatId: String?
    var sourceChatTitle: String?
    var sourceRole: String?
    var sourceAgentCategory: String?
    var sourceTimestamp: Date?
    var sourceAIAction: String?
    var groupId: String?
    var createdAt: Date

    static let databaseTableName = "canvas_nodes"
}

struct CanvasEdgeRecord: Codable, FetchableRecord, PersistableRecord, Identifiable {
    var id: String
    var canvasId: String
    var fromNodeId: String
    var toNodeId: String
    var label: String?

    static let databaseTableName = "canvas_edges"
}

struct CanvasGroupRecord: Codable, FetchableRecord, PersistableRecord, Identifiable {
    var id: String
    var canvasId: String
    var title: String
    var positionX: Double
    var positionY: Double
    var width: Double
    var height: Double
    var color: String?
    var isCollapsed: Bool
    var createdAt: Date

    static let databaseTableName = "canvas_groups"
}

// MARK: - Store

final class CanvasStore {
    private let db: DatabasePool

    init(db: DatabasePool = DatabaseManager.shared.dbPool) {
        self.db = db
    }

    // MARK: - Canvas CRUD

    func createCanvas(title: String = "Untitled Canvas") -> CanvasRecord {
        let now = Date()
        let record = CanvasRecord(
            id: UUID().uuidString,
            title: title,
            viewportOffsetX: 0,
            viewportOffsetY: 0,
            viewportScale: 1.0,
            createdAt: now,
            updatedAt: now
        )
        do {
            try db.write { db in try record.insert(db) }
        } catch {
            Log.app.error("[canvas] createCanvas failed: \(error)")
        }
        return record
    }

    func listCanvases() -> [CanvasRecord] {
        do {
            return try db.read { db in
                try CanvasRecord.order(Column("updatedAt").desc).fetchAll(db)
            }
        } catch {
            Log.app.error("[canvas] listCanvases failed: \(error)")
            return []
        }
    }

    func deleteCanvas(id: String) {
        do {
            try db.write { db in _ = try CanvasRecord.deleteOne(db, id: id) }
        } catch {
            Log.app.error("[canvas] deleteCanvas failed: \(error)")
        }
    }

    func renameCanvas(id: String, title: String) {
        do {
            try db.write { db in
                if var record = try CanvasRecord.fetchOne(db, id: id) {
                    record.title = title
                    record.updatedAt = Date()
                    try record.update(db)
                }
            }
        } catch {
            Log.app.error("[canvas] renameCanvas failed: \(error)")
        }
    }

    // MARK: - Save / Load Full Canvas

    /// Save all canvas state in a single transaction. Replaces existing data.
    func saveCanvas(
        canvasId: String,
        nodes: [CanvasNode],
        edges: [CanvasEdge],
        groups: [CanvasGroup],
        viewportOffset: CGSize,
        viewportScale: CGFloat
    ) {
        do {
            try db.write { db in
                // Update viewport
                if var canvas = try CanvasRecord.fetchOne(db, id: canvasId) {
                    canvas.viewportOffsetX = viewportOffset.width
                    canvas.viewportOffsetY = viewportOffset.height
                    canvas.viewportScale = viewportScale
                    canvas.updatedAt = Date()
                    try canvas.update(db)
                }

                // Replace nodes
                try db.execute(sql: "DELETE FROM canvas_nodes WHERE canvasId = ?", arguments: [canvasId])
                for node in nodes {
                    let record = Self.toNodeRecord(node, canvasId: canvasId)
                    try record.insert(db)
                }

                // Replace edges
                try db.execute(sql: "DELETE FROM canvas_edges WHERE canvasId = ?", arguments: [canvasId])
                for edge in edges {
                    let record = CanvasEdgeRecord(
                        id: edge.id.uuidString,
                        canvasId: canvasId,
                        fromNodeId: edge.fromId.uuidString,
                        toNodeId: edge.toId.uuidString,
                        label: edge.label
                    )
                    try record.insert(db)
                }

                // Replace groups
                try db.execute(sql: "DELETE FROM canvas_groups WHERE canvasId = ?", arguments: [canvasId])
                for group in groups {
                    let record = CanvasGroupRecord(
                        id: group.id.uuidString,
                        canvasId: canvasId,
                        title: group.title,
                        positionX: group.position.x,
                        positionY: group.position.y,
                        width: group.size.width,
                        height: group.size.height,
                        color: group.color.rawValue,
                        isCollapsed: group.isCollapsed,
                        createdAt: Date()
                    )
                    try record.insert(db)
                }
            }
        } catch {
            Log.app.error("[canvas] saveCanvas failed: \(error)")
        }
    }

    /// Load all canvas content. Returns nil if canvas not found.
    func loadCanvas(id: String) -> (
        canvas: CanvasRecord,
        nodes: [CanvasNode],
        edges: [CanvasEdge],
        groups: [CanvasGroup]
    )? {
        do {
            return try db.read { db in
                guard let canvas = try CanvasRecord.fetchOne(db, id: id) else { return nil }

                let nodeRecords = try CanvasNodeRecord
                    .filter(Column("canvasId") == id)
                    .fetchAll(db)

                let edgeRecords = try CanvasEdgeRecord
                    .filter(Column("canvasId") == id)
                    .fetchAll(db)

                let groupRecords = try CanvasGroupRecord
                    .filter(Column("canvasId") == id)
                    .fetchAll(db)

                let nodes = nodeRecords.compactMap { Self.fromNodeRecord($0) }
                let edges = edgeRecords.compactMap { Self.fromEdgeRecord($0) }
                let groups = groupRecords.map { Self.fromGroupRecord($0) }

                return (canvas, nodes, edges, groups)
            }
        } catch {
            Log.app.error("[canvas] loadCanvas failed: \(error)")
            return nil
        }
    }

    // MARK: - Record Conversion

    private static func toNodeRecord(_ node: CanvasNode, canvasId: String) -> CanvasNodeRecord {
        var sourceType = "manual"
        var sourceChatId: String?
        var sourceChatTitle: String?
        var sourceRole: String?
        var sourceAgentCategory: String?
        var sourceTimestamp: Date?
        var sourceAIAction: String?

        switch node.source {
        case .manual:
            break
        case .chat(let origin):
            sourceType = "chat"
            sourceChatId = origin.chatId
            sourceChatTitle = origin.chatTitle
            sourceRole = origin.role.rawValue
            sourceAgentCategory = origin.agentCategory?.rawValue
            sourceTimestamp = origin.timestamp
        case .ai(let origin):
            sourceType = "ai"
            sourceAIAction = origin.action
            sourceTimestamp = origin.timestamp
        }

        return CanvasNodeRecord(
            id: node.id.uuidString,
            canvasId: canvasId,
            positionX: node.position.x,
            positionY: node.position.y,
            width: node.width,
            text: node.text,
            color: node.color.rawValue,
            sourceType: sourceType,
            sourceChatId: sourceChatId,
            sourceChatTitle: sourceChatTitle,
            sourceRole: sourceRole,
            sourceAgentCategory: sourceAgentCategory,
            sourceTimestamp: sourceTimestamp,
            sourceAIAction: sourceAIAction,
            groupId: node.groupId?.uuidString,
            createdAt: Date()
        )
    }

    private static func fromNodeRecord(_ r: CanvasNodeRecord) -> CanvasNode? {
        guard let id = UUID(uuidString: r.id) else { return nil }

        let source: NodeSource
        switch r.sourceType {
        case "chat":
            source = .chat(NodeSource.ChatOrigin(
                chatId: r.sourceChatId ?? "",
                chatTitle: r.sourceChatTitle ?? "",
                role: MessageRole(rawValue: r.sourceRole ?? "user") ?? .user,
                agentCategory: r.sourceAgentCategory.flatMap { AgentCategory(rawValue: $0) },
                timestamp: r.sourceTimestamp ?? Date()
            ))
        case "ai":
            source = .ai(NodeSource.AIOrigin(
                action: r.sourceAIAction ?? "expand",
                sourceNodeIds: [],
                timestamp: r.sourceTimestamp ?? Date()
            ))
        default:
            source = .manual
        }

        return CanvasNode(
            id: id,
            position: CGPoint(x: r.positionX, y: r.positionY),
            text: r.text,
            width: r.width,
            color: CanvasNode.NodeColor(rawValue: r.color) ?? .note,
            source: source,
            groupId: r.groupId.flatMap { UUID(uuidString: $0) }
        )
    }

    private static func fromEdgeRecord(_ r: CanvasEdgeRecord) -> CanvasEdge? {
        guard let id = UUID(uuidString: r.id),
              let fromId = UUID(uuidString: r.fromNodeId),
              let toId = UUID(uuidString: r.toNodeId) else { return nil }
        return CanvasEdge(id: id, fromId: fromId, toId: toId, label: r.label)
    }

    private static func fromGroupRecord(_ r: CanvasGroupRecord) -> CanvasGroup {
        CanvasGroup(
            id: UUID(uuidString: r.id) ?? UUID(),
            title: r.title,
            position: CGPoint(x: r.positionX, y: r.positionY),
            size: CGSize(width: r.width, height: r.height),
            color: CanvasNode.NodeColor(rawValue: r.color ?? "note") ?? .note,
            isCollapsed: r.isCollapsed
        )
    }
}
