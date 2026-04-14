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
    var sceneDataJSON: String?
    var displayMode: String
    var viewportHeight: Double?
    var imagesJSON: String?
    var sourceAINodeIdsJSON: String?
    var embedding: Data?
    var createdAt: Date

    static let databaseTableName = "canvas_nodes"
}

struct CanvasEdgeRecord: Codable, FetchableRecord, PersistableRecord, Identifiable {
    var id: String
    var canvasId: String
    var fromNodeId: String
    var toNodeId: String
    var label: String?
    var style: String
    var color: String
    var direction: String
    var weight: String

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
    let embedder: CanvasEmbedder

    init(db: DatabasePool = DatabaseManager.shared.dbPool) {
        self.db = db
        self.embedder = CanvasEmbedder(db: db)
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

    // MARK: - Search

    struct SearchResult {
        let nodeId: String
        let canvasId: String
        let canvasTitle: String
        let nodeText: String
        let nodeColor: String
        /// Cosine similarity when the result came from semantic search.
        /// Nil for keyword/LIKE results.
        let similarity: Float?
    }

    func searchNodes(query: String) -> [SearchResult] {
        do {
            return try db.read { db in
                let rows = try Row.fetchAll(db, sql: """
                    SELECT n.id, n.canvasId, c.title AS canvasTitle, n.text, n.color
                    FROM canvas_nodes n
                    JOIN canvases c ON c.id = n.canvasId
                    WHERE n.text LIKE ?
                    ORDER BY c.updatedAt DESC
                    LIMIT 50
                """, arguments: ["%\(query)%"])

                return rows.map { row in
                    SearchResult(
                        nodeId: row["id"],
                        canvasId: row["canvasId"],
                        canvasTitle: row["canvasTitle"],
                        nodeText: row["text"],
                        nodeColor: row["color"],
                        similarity: nil
                    )
                }
            }
        } catch {
            Log.app.error("[canvas] searchNodes failed: \(error)")
            return []
        }
    }

    // MARK: - Save / Load Full Canvas

    /// Save all canvas state in a single transaction. Replaces existing data.
    /// Node embeddings are preserved across saves when the node's text is
    /// unchanged; otherwise they are invalidated (set to null) so the embedder
    /// will regenerate them on the next `reconcile`.
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

                // Snapshot existing embeddings keyed by id, alongside the text
                // they were generated from. Carry the embedding forward only
                // when the incoming text matches the snapshot text — any edit
                // invalidates. Keying by id (not id+text) means a rename cycle
                // A→B→A still matches on the second A, since the snapshot
                // reflects pre-save state which is still the first A.
                var preservedEmbeddings: [String: (text: String, data: Data)] = [:]
                let existingRows = try Row.fetchAll(db, sql: """
                    SELECT id, text, embedding FROM canvas_nodes WHERE canvasId = ?
                """, arguments: [canvasId])
                for row in existingRows {
                    guard let emb: Data = row["embedding"] else { continue }
                    let id: String = row["id"]
                    let text: String = row["text"]
                    preservedEmbeddings[id] = (text, emb)
                }

                // Replace nodes
                try db.execute(sql: "DELETE FROM canvas_nodes WHERE canvasId = ?", arguments: [canvasId])
                for node in nodes {
                    var record = Self.toNodeRecord(node, canvasId: canvasId)
                    if let snapshot = preservedEmbeddings[node.id.uuidString],
                       snapshot.text == node.text {
                        record.embedding = snapshot.data
                    }
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
                        label: edge.label,
                        style: edge.style.rawValue,
                        color: edge.color.rawValue,
                        direction: edge.direction.rawValue,
                        weight: edge.weight.rawValue
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

            // Backfill embeddings for any nodes whose text just changed (or
            // that were created in this save). No-op if no embedding client
            // is wired yet.
            Task { [embedder] in await embedder.reconcile(canvasId: canvasId) }
        } catch {
            Log.app.error("[canvas] saveCanvas failed: \(error)")
        }
    }

    // MARK: - Semantic search

    /// Hybrid search: semantic (vector) first, falls back to keyword LIKE
    /// when the embedder has no client or returns no hits. Mirrors the
    /// MemoryStore hybrid pattern.
    func searchNodesSemantic(query: String, limit: Int = 20) async -> [SearchResult] {
        let hits = await embedder.semanticSearch(query: query, limit: limit)
        guard !hits.isEmpty else { return searchNodes(query: query) }
        let results = resolveHits(hits)
        // If the DB fetch failed, fall back to keyword search so the user
        // still gets something.
        return results.isEmpty ? searchNodes(query: query) : results
    }

    /// Related nodes for the inspector panel. Embeds `nodeText`, drops the
    /// self-hit (`excluding`), and returns results sorted by similarity.
    func relatedNodes(
        for nodeText: String,
        excluding nodeId: UUID,
        limit: Int = 10
    ) async -> [SearchResult] {
        // Ask for one extra so we can drop the self-hit and still return `limit`.
        let hits = await embedder.semanticSearch(query: nodeText, limit: limit + 1)
        let filtered = hits.filter { $0.nodeId != nodeId }.prefix(limit)
        return resolveHits(Array(filtered))
    }

    /// Resolve vector-index hits into SearchResults, preserving similarity and
    /// the input order (which is similarity-sorted from the VectorIndex).
    private func resolveHits(_ hits: [(nodeId: UUID, similarity: Float)]) -> [SearchResult] {
        guard !hits.isEmpty else { return [] }

        let idStrings = hits.map { $0.nodeId.uuidString }
        let similarityById: [String: Float] = Dictionary(
            uniqueKeysWithValues: hits.map { ($0.nodeId.uuidString, $0.similarity) }
        )

        do {
            let rows = try db.read { db in
                try Row.fetchAll(db, sql: """
                    SELECT n.id, n.canvasId, c.title AS canvasTitle, n.text, n.color
                    FROM canvas_nodes n
                    JOIN canvases c ON c.id = n.canvasId
                    WHERE n.id IN (\(idStrings.map { _ in "?" }.joined(separator: ",")))
                """, arguments: StatementArguments(idStrings))
            }

            let byId: [String: SearchResult] = Dictionary(uniqueKeysWithValues: rows.map { row in
                let id: String = row["id"]
                let r = SearchResult(
                    nodeId: id,
                    canvasId: row["canvasId"],
                    canvasTitle: row["canvasTitle"],
                    nodeText: row["text"],
                    nodeColor: row["color"],
                    similarity: similarityById[id]
                )
                return (r.nodeId, r)
            })
            return idStrings.compactMap { byId[$0] }
        } catch {
            Log.app.error("[canvas] resolveHits failed: \(error)")
            return []
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
        var sourceAINodeIdsJSON: String?

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
            if !origin.sourceNodeIds.isEmpty {
                let ids = origin.sourceNodeIds.map { $0.uuidString }
                if let data = try? JSONEncoder().encode(ids) {
                    sourceAINodeIdsJSON = String(data: data, encoding: .utf8)
                }
            }
        }

        // Serialize sceneData as JSON
        var sceneJSON: String?
        if let scene = node.sceneData, let data = try? JSONEncoder().encode(scene) {
            sceneJSON = String(data: data, encoding: .utf8)
        }

        // Serialize images as JSON array of base64 strings
        var imagesJSON: String?
        if let images = node.images, !images.isEmpty {
            let b64 = images.map { $0.base64EncodedString() }
            if let data = try? JSONEncoder().encode(b64) {
                imagesJSON = String(data: data, encoding: .utf8)
            }
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
            sceneDataJSON: sceneJSON,
            displayMode: node.displayMode.rawValue,
            viewportHeight: node.viewportHeight.map { Double($0) },
            imagesJSON: imagesJSON,
            sourceAINodeIdsJSON: sourceAINodeIdsJSON,
            embedding: nil,
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
            var sourceNodeIds: [UUID] = []
            if let json = r.sourceAINodeIdsJSON, let data = json.data(using: .utf8),
               let strings = try? JSONDecoder().decode([String].self, from: data) {
                sourceNodeIds = strings.compactMap { UUID(uuidString: $0) }
            }
            source = .ai(NodeSource.AIOrigin(
                action: r.sourceAIAction ?? "expand",
                sourceNodeIds: sourceNodeIds,
                timestamp: r.sourceTimestamp ?? Date()
            ))
        default:
            source = .manual
        }

        // Deserialize sceneData
        var sceneData: SceneDescription?
        if let json = r.sceneDataJSON, let data = json.data(using: .utf8) {
            sceneData = try? JSONDecoder().decode(SceneDescription.self, from: data)
        }

        // Deserialize images
        var images: [Data]?
        if let json = r.imagesJSON, let data = json.data(using: .utf8),
           let b64Array = try? JSONDecoder().decode([String].self, from: data) {
            let decoded = b64Array.compactMap { Data(base64Encoded: $0) }
            if !decoded.isEmpty { images = decoded }
        }

        var node = CanvasNode(
            id: id,
            position: CGPoint(x: r.positionX, y: r.positionY),
            text: r.text,
            width: r.width,
            color: CanvasNode.NodeColor(rawValue: r.color) ?? .note,
            source: source,
            groupId: r.groupId.flatMap { UUID(uuidString: $0) },
            images: images,
            sceneData: sceneData
        )
        node.displayMode = CanvasNode.DisplayMode(rawValue: r.displayMode) ?? .card
        node.viewportHeight = r.viewportHeight.map { CGFloat($0) }
        return node
    }

    private static func fromEdgeRecord(_ r: CanvasEdgeRecord) -> CanvasEdge? {
        guard let id = UUID(uuidString: r.id),
              let fromId = UUID(uuidString: r.fromNodeId),
              let toId = UUID(uuidString: r.toNodeId) else { return nil }
        return CanvasEdge(
            id: id, fromId: fromId, toId: toId,
            label: r.label,
            style: CanvasEdge.EdgeStyle(rawValue: r.style) ?? .solid,
            color: CanvasEdge.EdgeColor(rawValue: r.color) ?? .neutral,
            direction: CanvasEdge.EdgeDirection(rawValue: r.direction) ?? .forward,
            weight: CanvasEdge.EdgeWeight(rawValue: r.weight) ?? .normal
        )
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
