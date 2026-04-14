import Foundation
import GRDB

// MARK: - Records

struct NotebookRecord: Codable, FetchableRecord, MutablePersistableRecord, Identifiable, Equatable {
    var id: String
    var title: String
    var parentId: String?
    var position: Double
    var createdAt: Date
    var updatedAt: Date

    static let databaseTableName = "notebooks"
}

struct PageRecord: Codable, FetchableRecord, MutablePersistableRecord, Identifiable, Equatable {
    var id: String
    var notebookId: String
    var title: String
    var content: String
    var position: Double
    var embedding: Data?
    var createdAt: Date
    var updatedAt: Date

    static let databaseTableName = "pages"
}

/// Lightweight summary used for sidebar/list rendering — skips the full
/// `content` blob so scrolling a long list doesn't pull thousands of words.
struct PageSummary: Identifiable, Equatable {
    let id: String
    let notebookId: String
    let title: String
    let preview: String
    let position: Double
    let updatedAt: Date
}

// MARK: - Store

final class NotebookStore {
    private let db: DatabasePool

    init(db: DatabasePool = DatabaseManager.shared.dbPool) {
        self.db = db
    }

    // MARK: Notebooks

    func listNotebooks() -> [NotebookRecord] {
        do {
            return try db.read { db in
                try NotebookRecord
                    .order(Column("position").asc, Column("createdAt").asc)
                    .fetchAll(db)
            }
        } catch {
            Log.app.error("[notebook] listNotebooks failed: \(error)")
            return []
        }
    }

    @discardableResult
    func createNotebook(title: String) -> NotebookRecord? {
        let now = Date()
        let pos = (try? db.read { db in
            try Double.fetchOne(db, sql: "SELECT COALESCE(MAX(position), 0) + 1 FROM notebooks")
        }) ?? 0
        let record = NotebookRecord(
            id: UUID().uuidString,
            title: title,
            parentId: nil,
            position: pos ?? 0,
            createdAt: now,
            updatedAt: now
        )
        do {
            try db.write { db in
                var r = record
                try r.insert(db)
            }
            return record
        } catch {
            Log.app.error("[notebook] createNotebook failed: \(error)")
            return nil
        }
    }

    func renameNotebook(id: String, title: String) {
        do {
            try db.write { db in
                try db.execute(
                    sql: "UPDATE notebooks SET title = ?, updatedAt = ? WHERE id = ?",
                    arguments: [title, Date(), id]
                )
            }
        } catch {
            Log.app.error("[notebook] renameNotebook failed: \(error)")
        }
    }

    func deleteNotebook(id: String) {
        do {
            try db.write { db in
                try db.execute(sql: "DELETE FROM notebooks WHERE id = ?", arguments: [id])
            }
        } catch {
            Log.app.error("[notebook] deleteNotebook failed: \(error)")
        }
    }

    // MARK: Pages

    /// Lightweight list — skips the full `content` blob.
    func listPages(notebookId: String) -> [PageSummary] {
        do {
            return try db.read { db in
                let rows = try Row.fetchAll(db, sql: """
                    SELECT id, notebookId, title, substr(content, 1, 200) AS preview,
                           position, updatedAt
                    FROM pages
                    WHERE notebookId = ?
                    ORDER BY position ASC, updatedAt DESC
                """, arguments: [notebookId])
                return rows.map { row in
                    PageSummary(
                        id: row["id"],
                        notebookId: row["notebookId"],
                        title: row["title"],
                        preview: row["preview"] ?? "",
                        position: row["position"],
                        updatedAt: row["updatedAt"]
                    )
                }
            }
        } catch {
            Log.app.error("[notebook] listPages failed: \(error)")
            return []
        }
    }

    /// All pages across every notebook, lightweight summaries. Used by the
    /// command palette so objects are reachable regardless of which notebook
    /// is currently open.
    func listAllPages() -> [PageSummary] {
        do {
            return try db.read { db in
                let rows = try Row.fetchAll(db, sql: """
                    SELECT id, notebookId, title, substr(content, 1, 140) AS preview,
                           position, updatedAt
                    FROM pages
                    ORDER BY updatedAt DESC
                    LIMIT 500
                """)
                return rows.map { row in
                    PageSummary(
                        id: row["id"],
                        notebookId: row["notebookId"],
                        title: row["title"],
                        preview: row["preview"] ?? "",
                        position: row["position"],
                        updatedAt: row["updatedAt"]
                    )
                }
            }
        } catch {
            Log.app.error("[notebook] listAllPages failed: \(error)")
            return []
        }
    }

    func getPage(id: String) -> PageRecord? {
        do {
            return try db.read { db in
                try PageRecord.fetchOne(db, key: id)
            }
        } catch {
            Log.app.error("[notebook] getPage failed: \(error)")
            return nil
        }
    }

    @discardableResult
    func createPage(notebookId: String, title: String = "Untitled") -> PageRecord? {
        let now = Date()
        let pos = (try? db.read { db in
            try Double.fetchOne(
                db,
                sql: "SELECT COALESCE(MAX(position), 0) + 1 FROM pages WHERE notebookId = ?",
                arguments: [notebookId]
            )
        }) ?? 0
        let record = PageRecord(
            id: UUID().uuidString,
            notebookId: notebookId,
            title: title,
            content: "",
            position: pos ?? 0,
            embedding: nil,
            createdAt: now,
            updatedAt: now
        )
        do {
            try db.write { db in
                var r = record
                try r.insert(db)
            }
            return record
        } catch {
            Log.app.error("[notebook] createPage failed: \(error)")
            return nil
        }
    }

    /// Update content only; callers debounce. Invalidates the embedding so
    /// it gets regenerated (Sprint 2) when embedding wiring extends here.
    func updatePageContent(id: String, content: String) {
        do {
            try db.write { db in
                try db.execute(sql: """
                    UPDATE pages
                    SET content = ?, embedding = NULL, updatedAt = ?
                    WHERE id = ?
                """, arguments: [content, Date(), id])
            }
        } catch {
            Log.app.error("[notebook] updatePageContent failed: \(error)")
        }
    }

    func updatePageTitle(id: String, title: String) {
        do {
            try db.write { db in
                try db.execute(
                    sql: "UPDATE pages SET title = ?, updatedAt = ? WHERE id = ?",
                    arguments: [title, Date(), id]
                )
            }
        } catch {
            Log.app.error("[notebook] updatePageTitle failed: \(error)")
        }
    }

    func deletePage(id: String) {
        do {
            try db.write { db in
                try db.execute(sql: "DELETE FROM pages WHERE id = ?", arguments: [id])
            }
        } catch {
            Log.app.error("[notebook] deletePage failed: \(error)")
        }
    }
}
