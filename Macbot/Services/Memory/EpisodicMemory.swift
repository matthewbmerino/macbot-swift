import Foundation
import GRDB

/// An auto-summarized chunk of conversation history. Episodes give macbot a
/// sense of continuity across sessions: "what happened last Tuesday" rather
/// than just key/value memory.
struct Episode: Codable, FetchableRecord, MutablePersistableRecord, Identifiable {
    var id: Int64?
    var title: String
    var summary: String
    var topics: String          // JSON array
    var messageCount: Int
    var startedAt: Date
    var endedAt: Date
    var embedding: Data?
    var createdAt: Date

    static let databaseTableName = "episodes"

    mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }

    var topicList: [String] {
        guard let data = topics.data(using: .utf8),
              let arr = try? JSONSerialization.jsonObject(with: data) as? [String]
        else { return [] }
        return arr
    }

    var embeddingVector: [Float]? {
        guard let data = embedding, !data.isEmpty else { return nil }
        return data.withUnsafeBytes { buf in
            guard let ptr = buf.baseAddress?.assumingMemoryBound(to: Float.self) else { return nil }
            return Array(UnsafeBufferPointer(start: ptr, count: buf.count / MemoryLayout<Float>.size))
        }
    }
}

/// Persists and queries episodic memory. Uses the shared DatabaseManager.
final class EpisodicMemory {
    static let shared = EpisodicMemory()

    private let dbPool = DatabaseManager.shared.dbPool
    private init() {}

    // MARK: - Save

    /// Summarize a conversation transcript using a small model and persist it.
    /// Called from session-end hook. Cheap: 1 LLM call to a tiny model.
    @discardableResult
    func recordEpisode(
        messages: [[String: Any]],
        startedAt: Date,
        endedAt: Date,
        client: any InferenceProvider,
        model: String
    ) async -> Episode? {
        // Strip system messages, build a plain transcript
        let transcript = messages.compactMap { msg -> String? in
            guard let role = msg["role"] as? String,
                  let content = msg["content"] as? String,
                  !content.isEmpty,
                  role == "user" || role == "assistant"
            else { return nil }
            return "\(role): \(content)"
        }.joined(separator: "\n").prefix(8000)  // hard cap input

        guard transcript.count > 200 else { return nil }  // skip trivial sessions

        let prompt = """
        Summarize this conversation in a structured format. Output ONLY valid JSON, no other text:
        {
          "title": "<5-8 word title>",
          "summary": "<2-3 sentence summary of what was discussed and decided>",
          "topics": ["<topic1>", "<topic2>", "<topic3>"]
        }

        Conversation:
        \(transcript)
        """

        do {
            let resp = try await client.chat(
                model: model,
                messages: [["role": "user", "content": prompt]],
                tools: nil,
                temperature: 0.2,
                numCtx: 4096,
                timeout: 30
            )

            let cleaned = ThinkingStripper.strip(resp.content)
            guard let jsonStart = cleaned.firstIndex(of: "{"),
                  let jsonEnd = cleaned.lastIndex(of: "}")
            else {
                Log.app.warning("[episodic] no JSON in summary response")
                return nil
            }
            let jsonStr = String(cleaned[jsonStart...jsonEnd])
            guard let data = jsonStr.data(using: .utf8),
                  let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let title = parsed["title"] as? String,
                  let summary = parsed["summary"] as? String
            else {
                Log.app.warning("[episodic] could not parse summary JSON")
                return nil
            }
            let topicArr = parsed["topics"] as? [String] ?? []
            let topicsJSON = (try? JSONSerialization.data(withJSONObject: topicArr))
                .flatMap { String(data: $0, encoding: .utf8) } ?? "[]"

            let newEpisode = Episode(
                id: nil,
                title: title,
                summary: summary,
                topics: topicsJSON,
                messageCount: messages.count,
                startedAt: startedAt,
                endedAt: endedAt,
                embedding: nil,
                createdAt: Date()
            )

            // Shadow the struct inside the closure so didInsert's mutation
            // doesn't cross the concurrent boundary. Return the inserted
            // copy (which now has its auto-assigned id) to the caller.
            let savedEpisode = try await dbPool.write { db -> Episode in
                var local = newEpisode
                try local.insert(db)
                return local
            }
            Log.app.info("[episodic] recorded episode: \(title)")
            return savedEpisode
        } catch {
            Log.app.warning("[episodic] failed to summarize: \(error)")
            return nil
        }
    }

    // MARK: - Query

    /// Most recent episodes, newest first.
    func recent(limit: Int = 10) -> [Episode] {
        do {
            return try dbPool.read { db in
                try Episode
                    .order(Column("startedAt").desc)
                    .limit(limit)
                    .fetchAll(db)
            }
        } catch {
            Log.app.error("[episodic] recent failed: \(error)")
            return []
        }
    }

    /// Episodes within a date range.
    func inRange(from: Date, to: Date, limit: Int = 50) -> [Episode] {
        do {
            return try dbPool.read { db in
                try Episode
                    .filter(Column("startedAt") >= from && Column("startedAt") <= to)
                    .order(Column("startedAt").desc)
                    .limit(limit)
                    .fetchAll(db)
            }
        } catch {
            Log.app.error("[episodic] range query failed: \(error)")
            return []
        }
    }

    /// Keyword search across title, summary, topics.
    func search(query: String, limit: Int = 10) -> [Episode] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !trimmed.isEmpty else { return [] }
        let pattern = "%\(trimmed)%"
        do {
            return try dbPool.read { db in
                try Episode
                    .filter(
                        Column("title").lowercased.like(pattern) ||
                        Column("summary").lowercased.like(pattern) ||
                        Column("topics").lowercased.like(pattern)
                    )
                    .order(Column("startedAt").desc)
                    .limit(limit)
                    .fetchAll(db)
            }
        } catch {
            Log.app.error("[episodic] search failed: \(error)")
            return []
        }
    }

    /// Compact text representation for prompt injection.
    static func format(_ episodes: [Episode]) -> String {
        let df = DateFormatter()
        df.dateStyle = .medium
        df.timeStyle = .short
        return episodes.map { ep in
            let when = df.string(from: ep.startedAt)
            let topics = ep.topicList.isEmpty ? "" : " [\(ep.topicList.joined(separator: ", "))]"
            return "• \(when) — \(ep.title)\(topics)\n  \(ep.summary)"
        }.joined(separator: "\n")
    }
}
