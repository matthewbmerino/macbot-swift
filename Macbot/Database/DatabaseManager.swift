import Foundation
import GRDB

final class DatabaseManager {
    static let shared = DatabaseManager()

    let dbPool: DatabasePool

    private init() {
        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        ).first!.appendingPathComponent("Macbot", isDirectory: true)

        try! FileManager.default.createDirectory(at: appSupport, withIntermediateDirectories: true)

        let dbPath = appSupport.appendingPathComponent("macbot.db").path
        dbPool = try! DatabasePool(path: dbPath)

        try! migrator.migrate(dbPool)
        Log.app.info("Database ready at \(dbPath)")
    }

    private var migrator: DatabaseMigrator {
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

        return migrator
    }
}
