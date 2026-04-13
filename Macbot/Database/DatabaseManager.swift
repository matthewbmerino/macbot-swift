import Foundation
import GRDB

final class DatabaseManager: Sendable {
    static let shared = DatabaseManager()

    let dbPool: DatabasePool

    private init() {
        guard let appSupportBase = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        ).first else {
            fatalError("[database] could not locate Application Support directory")
        }
        let appSupport = appSupportBase.appendingPathComponent("Macbot", isDirectory: true)

        do {
            try FileManager.default.createDirectory(at: appSupport, withIntermediateDirectories: true)
        } catch {
            Log.app.error("[database] failed to create app support directory: \(error)")
            fatalError("[database] failed to create app support directory: \(error)")
        }

        let dbPath = appSupport.appendingPathComponent("macbot.db").path
        do {
            dbPool = try DatabasePool(path: dbPath)
        } catch {
            Log.app.error("[database] failed to open database at \(dbPath): \(error)")
            fatalError("[database] failed to open database: \(error)")
        }

        do {
            try migrator.migrate(dbPool)
        } catch {
            Log.app.error("[database] migration failed: \(error)")
            fatalError("[database] migration failed: \(error)")
        }
        Log.app.info("Database ready at \(dbPath)")
    }

    private var migrator: DatabaseMigrator { Self.buildMigrator() }

    /// Schema migrator. Static so tests can apply it to an in-memory pool
    /// without triggering the singleton (which opens the real on-disk DB).
    static func buildMigrator() -> DatabaseMigrator {
        var migrator = DatabaseMigrator()

        migrator.registerMigration("v1") { db in
            try db.create(table: "memories") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("category", .text).notNull()
                t.column("content", .text).notNull()
                t.column("metadata", .text).defaults(to: "{}")
                t.column("createdAt", .datetime).notNull()
                t.column("updatedAt", .datetime).notNull()
            }
            try db.create(index: "idx_memories_category", on: "memories", columns: ["category"])

            try db.create(table: "conversations") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("userId", .text).notNull()
                t.column("summary", .text).notNull()
                t.column("messageCount", .integer).defaults(to: 0)
                t.column("createdAt", .datetime).notNull()
            }
            try db.create(index: "idx_conversations_user", on: "conversations", columns: ["userId"])
        }

        migrator.registerMigration("v2_chat_history") { db in
            try db.create(table: "chats") { t in
                t.column("id", .text).primaryKey()
                t.column("title", .text).notNull()
                t.column("lastMessage", .text).notNull().defaults(to: "")
                t.column("agentCategory", .text)
                t.column("createdAt", .datetime).notNull()
                t.column("updatedAt", .datetime).notNull()
            }

            try db.create(table: "chat_messages") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("chatId", .text).notNull().references("chats", onDelete: .cascade)
                t.column("role", .text).notNull()
                t.column("content", .text).notNull()
                t.column("agentCategory", .text)
                t.column("createdAt", .datetime).notNull()
            }
            try db.create(index: "idx_chat_messages_chatId", on: "chat_messages", columns: ["chatId"])
        }

        // RAG document chunks and ingestion tracking
        migrator.registerMigration("v3_rag") { db in
            try db.create(table: "document_chunks") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("sourceFile", .text).notNull()
                t.column("chunkIndex", .integer).notNull()
                t.column("content", .text).notNull()
                t.column("embedding", .blob).notNull()
                t.column("tokenCount", .integer).defaults(to: 0)
                t.column("metadata", .text).defaults(to: "{}")
                t.column("createdAt", .datetime).notNull()
                t.column("updatedAt", .datetime).notNull()
            }
            try db.create(index: "idx_chunks_source", on: "document_chunks", columns: ["sourceFile"])

            try db.create(table: "ingested_files") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("filePath", .text).notNull().unique()
                t.column("fileHash", .text).notNull()
                t.column("chunkCount", .integer).defaults(to: 0)
                t.column("totalTokens", .integer).defaults(to: 0)
                t.column("ingestedAt", .datetime).notNull()
                t.column("modifiedAt", .datetime).notNull()
            }
        }

        // Vector embeddings for semantic memory search
        migrator.registerMigration("v4_memory_embeddings") { db in
            try db.alter(table: "memories") { t in
                t.add(column: "embedding", .blob)
            }
        }

        // Composite tools (learned workflows)
        migrator.registerMigration("v5_composite_tools") { db in
            try db.create(table: "composite_tools") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("name", .text).notNull().unique()
                t.column("description", .text).notNull()
                t.column("steps", .text).notNull()
                t.column("triggerPhrase", .text).notNull()
                t.column("timesUsed", .integer).defaults(to: 0)
                t.column("createdAt", .datetime).notNull()
                t.column("updatedAt", .datetime).notNull()
            }
        }

        // Skill acquisition — distilled (situation, action, lesson) tuples
        // extracted from successful interactions. Retrieved by embedding
        // similarity and injected into future agent prompts.
        migrator.registerMigration("v8_skills") { db in
            try db.create(table: "skills") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("situation", .text).notNull()
                t.column("action", .text).notNull()
                t.column("lesson", .text).notNull()
                t.column("embedding", .blob)
                t.column("sourceTraceId", .integer)
                t.column("useCount", .integer).defaults(to: 0)
                t.column("successCount", .integer).defaults(to: 0)
                t.column("createdAt", .datetime).notNull()
                t.column("updatedAt", .datetime).notNull()
            }
            try db.create(index: "idx_skills_useCount", on: "skills", columns: ["useCount"])
        }

        // Trace layer — structured log of every user→assistant turn.
        // Foundation for: replay, eval harness, learned routing, skill
        // distillation, regression detection, on-device personalization.
        migrator.registerMigration("v7_traces") { db in
            try db.create(table: "interaction_traces") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("sessionId", .text).notNull()
                t.column("userId", .text).notNull().defaults(to: "local")
                t.column("turnIndex", .integer).notNull().defaults(to: 0)
                t.column("userMessage", .text).notNull()
                t.column("userMessageEmbedding", .blob)
                t.column("routedAgent", .text).notNull()
                t.column("routeReason", .text).defaults(to: "")
                t.column("modelUsed", .text).notNull()
                t.column("toolCalls", .text).defaults(to: "[]")     // JSON array
                t.column("assistantResponse", .text).notNull()
                t.column("responseTokens", .integer).defaults(to: 0)
                t.column("latencyMs", .integer).defaults(to: 0)
                t.column("error", .text)
                t.column("ambientSnapshot", .text).defaults(to: "{}")
                t.column("metadata", .text).defaults(to: "{}")
                t.column("createdAt", .datetime).notNull()
            }
            try db.create(index: "idx_traces_session", on: "interaction_traces", columns: ["sessionId"])
            try db.create(index: "idx_traces_createdAt", on: "interaction_traces", columns: ["createdAt"])
            try db.create(index: "idx_traces_agent", on: "interaction_traces", columns: ["routedAgent"])
        }

        // Episodic memory — auto-summarized conversation episodes
        migrator.registerMigration("v6_episodes") { db in
            try db.create(table: "episodes") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("title", .text).notNull()
                t.column("summary", .text).notNull()
                t.column("topics", .text).defaults(to: "[]")  // JSON array of strings
                t.column("messageCount", .integer).defaults(to: 0)
                t.column("startedAt", .datetime).notNull()
                t.column("endedAt", .datetime).notNull()
                t.column("embedding", .blob)
                t.column("createdAt", .datetime).notNull()
            }
            try db.create(index: "idx_episodes_startedAt", on: "episodes", columns: ["startedAt"])
        }

        // Canvas workspace — infinite canvas for visual note-taking and knowledge mapping
        migrator.registerMigration("v9_canvas") { db in
            try db.create(table: "canvases") { t in
                t.column("id", .text).primaryKey()
                t.column("title", .text).notNull().defaults(to: "Untitled Canvas")
                t.column("viewportOffsetX", .double).defaults(to: 0)
                t.column("viewportOffsetY", .double).defaults(to: 0)
                t.column("viewportScale", .double).defaults(to: 1.0)
                t.column("createdAt", .datetime).notNull()
                t.column("updatedAt", .datetime).notNull()
            }

            try db.create(table: "canvas_nodes") { t in
                t.column("id", .text).primaryKey()
                t.column("canvasId", .text).notNull().references("canvases", onDelete: .cascade)
                t.column("positionX", .double).notNull()
                t.column("positionY", .double).notNull()
                t.column("width", .double).notNull().defaults(to: 200)
                t.column("text", .text).notNull().defaults(to: "")
                t.column("color", .text).notNull().defaults(to: "note")
                t.column("sourceType", .text).notNull().defaults(to: "manual")
                t.column("sourceChatId", .text)
                t.column("sourceChatTitle", .text)
                t.column("sourceRole", .text)
                t.column("sourceAgentCategory", .text)
                t.column("sourceTimestamp", .datetime)
                t.column("sourceAIAction", .text)
                t.column("groupId", .text)
                t.column("createdAt", .datetime).notNull()
            }
            try db.create(index: "idx_canvas_nodes_canvasId", on: "canvas_nodes", columns: ["canvasId"])

            try db.create(table: "canvas_edges") { t in
                t.column("id", .text).primaryKey()
                t.column("canvasId", .text).notNull().references("canvases", onDelete: .cascade)
                t.column("fromNodeId", .text).notNull()
                t.column("toNodeId", .text).notNull()
                t.column("label", .text)
            }
            try db.create(index: "idx_canvas_edges_canvasId", on: "canvas_edges", columns: ["canvasId"])

            try db.create(table: "canvas_groups") { t in
                t.column("id", .text).primaryKey()
                t.column("canvasId", .text).notNull().references("canvases", onDelete: .cascade)
                t.column("title", .text).notNull().defaults(to: "Group")
                t.column("positionX", .double).notNull()
                t.column("positionY", .double).notNull()
                t.column("width", .double).notNull().defaults(to: 400)
                t.column("height", .double).notNull().defaults(to: 300)
                t.column("color", .text).defaults(to: "note")
                t.column("isCollapsed", .boolean).defaults(to: false)
                t.column("createdAt", .datetime).notNull()
            }
            try db.create(index: "idx_canvas_groups_canvasId", on: "canvas_groups", columns: ["canvasId"])
        }

        // Edge styling — line style, color, direction, weight
        migrator.registerMigration("v10_edge_styles") { db in
            try db.alter(table: "canvas_edges") { t in
                t.add(column: "style", .text).defaults(to: "solid")
                t.add(column: "color", .text).defaults(to: "neutral")
                t.add(column: "direction", .text).defaults(to: "forward")
                t.add(column: "weight", .text).defaults(to: "normal")
            }
        }

        // Persist sceneData, images, displayMode, viewportHeight on canvas nodes
        migrator.registerMigration("v11_canvas_scene_images") { db in
            try db.alter(table: "canvas_nodes") { t in
                t.add(column: "sceneDataJSON", .text)
                t.add(column: "displayMode", .text).defaults(to: "card")
                t.add(column: "viewportHeight", .double)
                t.add(column: "imagesJSON", .text)    // JSON array of base64 strings
            }
        }

        return migrator
    }

    /// Create a fresh database pool backed by a unique temp file, with all
    /// migrations applied. For test use only — DatabasePool requires a real
    /// file (it uses WAL), so we use a temp path instead of `:memory:`.
    /// Caller is responsible for cleanup.
    static func makeTestPool() throws -> (pool: DatabasePool, path: String) {
        let path = NSTemporaryDirectory() + "macbot-test-\(UUID().uuidString).sqlite"
        let pool = try DatabasePool(path: path)
        try buildMigrator().migrate(pool)
        return (pool, path)
    }
}
