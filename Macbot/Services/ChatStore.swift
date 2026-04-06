import Foundation
import GRDB

struct ChatRecord: Codable, FetchableRecord, PersistableRecord, Identifiable {
    var id: String
    var title: String
    var lastMessage: String
    var agentCategory: String?
    var createdAt: Date
    var updatedAt: Date

    static let databaseTableName = "chats"
}

struct ChatMessageRecord: Codable, FetchableRecord, MutablePersistableRecord, Identifiable {
    var id: Int64?
    var chatId: String
    var role: String
    var content: String
    var agentCategory: String?
    var createdAt: Date

    static let databaseTableName = "chat_messages"

    mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}

final class ChatStore {
    private let db: DatabasePool

    init(db: DatabasePool = DatabaseManager.shared.dbPool) {
        self.db = db
    }

    // MARK: - Chats

    func createChat(title: String = "New Chat") -> ChatRecord {
        let now = Date()
        var chat = ChatRecord(
            id: UUID().uuidString,
            title: title,
            lastMessage: "",
            createdAt: now,
            updatedAt: now
        )
        do {
            try db.write { db in
                try chat.insert(db)
            }
        } catch {
            Log.app.error("[chat] createChat failed: \(error)")
        }
        return chat
    }

    func listChats() -> [ChatRecord] {
        do {
            return try db.read { db in
                try ChatRecord.order(Column("updatedAt").desc).fetchAll(db)
            }
        } catch {
            Log.app.error("[chat] listChats failed: \(error)")
            return []
        }
    }

    func searchChats(query: String) -> [ChatRecord] {
        do {
            return try db.read { db in
                // Search in chat titles and message content
                let chatIds = try String.fetchAll(db, sql: """
                    SELECT DISTINCT chatId FROM chat_messages
                    WHERE content LIKE ?
                    UNION
                    SELECT id FROM chats WHERE title LIKE ?
                """, arguments: ["%\(query)%", "%\(query)%"])

                return try ChatRecord
                    .filter(chatIds.contains(Column("id")))
                    .order(Column("updatedAt").desc)
                    .fetchAll(db)
            }
        } catch {
            Log.app.error("[chat] searchChats failed: \(error)")
            return []
        }
    }

    func updateChat(id: String, title: String? = nil, lastMessage: String? = nil, agentCategory: String? = nil) {
        do {
            try db.write { db in
                if var chat = try ChatRecord.fetchOne(db, id: id) {
                    if let title { chat.title = title }
                    if let lastMessage { chat.lastMessage = lastMessage }
                    if let agentCategory { chat.agentCategory = agentCategory }
                    chat.updatedAt = Date()
                    try chat.update(db)
                }
            }
        } catch {
            Log.app.error("[chat] updateChat failed: \(error)")
        }
    }

    func deleteChat(id: String) {
        do {
            try db.write { db in
                _ = try ChatRecord.deleteOne(db, id: id)
            }
        } catch {
            Log.app.error("[chat] deleteChat failed: \(error)")
        }
    }

    // MARK: - Messages

    func saveMessage(chatId: String, role: String, content: String, agentCategory: String? = nil) {
        var msg = ChatMessageRecord(
            chatId: chatId,
            role: role,
            content: content,
            agentCategory: agentCategory,
            createdAt: Date()
        )
        do {
            try db.write { db in
                try msg.insert(db)
            }
        } catch {
            Log.app.error("[chat] saveMessage failed: \(error)")
        }

        // Update chat's last message and timestamp
        let preview = String(content.prefix(100))
        updateChat(id: chatId, lastMessage: preview, agentCategory: agentCategory)
    }

    func loadMessages(chatId: String) -> [ChatMessageRecord] {
        do {
            return try db.read { db in
                try ChatMessageRecord
                    .filter(Column("chatId") == chatId)
                    .order(Column("createdAt").asc)
                    .fetchAll(db)
            }
        } catch {
            Log.app.error("[chat] loadMessages failed: \(error)")
            return []
        }
    }

    /// Search messages across all chats.
    func searchMessages(query: String) -> [(message: ChatMessageRecord, chatTitle: String)] {
        do {
            return try db.read { db in
                let rows = try Row.fetchAll(db, sql: """
                    SELECT m.*, c.title AS chatTitle
                    FROM chat_messages m
                    JOIN chats c ON c.id = m.chatId
                    WHERE m.content LIKE ?
                    ORDER BY m.createdAt DESC
                    LIMIT 50
                """, arguments: ["%\(query)%"])

                return try rows.map { row in
                    let msg = try ChatMessageRecord(row: row)
                    let title: String = row["chatTitle"]
                    return (msg, title)
                }
            }
        } catch {
            Log.app.error("[chat] searchMessages failed: \(error)")
            return []
        }
    }

    /// Auto-generate a title from the first user message.
    func autoTitle(chatId: String, firstMessage: String) {
        let title = String(firstMessage.prefix(50)).trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanTitle = title.isEmpty ? "New Chat" : title
        updateChat(id: chatId, title: cleanTitle)
    }
}
