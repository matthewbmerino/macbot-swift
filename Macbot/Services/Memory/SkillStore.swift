import Accelerate
import Foundation
import GRDB

/// A distilled lesson from past interactions. The unit of learning.
/// Retrieved by embedding similarity and injected into agent prompts before
/// new turns. This is what makes macbot's *behavior* compound with use.
struct Skill: Codable, FetchableRecord, MutablePersistableRecord, Identifiable {
    var id: Int64?
    var situation: String       // "When user asks X..."
    var action: String          // "...do Y"
    var lesson: String          // "...because Z"
    var embedding: Data?
    var sourceTraceId: Int64?
    var useCount: Int
    var successCount: Int
    var createdAt: Date
    var updatedAt: Date

    static let databaseTableName = "skills"

    mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }

    var embeddingVector: [Float]? {
        guard let data = embedding, !data.isEmpty else { return nil }
        return data.withUnsafeBytes { buf in
            guard let ptr = buf.baseAddress?.assumingMemoryBound(to: Float.self) else { return nil }
            return Array(UnsafeBufferPointer(start: ptr, count: buf.count / MemoryLayout<Float>.size))
        }
    }

    /// Compact prompt-friendly form.
    var promptLine: String {
        "When \(situation.lowercased()), \(action.lowercased())."
    }
}

/// Persistent skill store + distillation pipeline. The single most important
/// piece of the learning loop: this is the difference between "macbot
/// answers your question today" and "macbot is measurably better at
/// answering your kind of questions next week."
final class SkillStore: Sendable {
    static let shared = SkillStore()

    private let dbPool: DatabasePool
    /// Cosine similarity threshold above which a new skill is considered
    /// duplicate and merged into the existing one (bump useCount).
    private let dedupeThreshold: Float = 0.85

    private init() {
        self.dbPool = DatabaseManager.shared.dbPool
    }

    // MARK: - Distillation

    /// Ask a tiny model to extract a generalizable lesson from one trace.
    /// Stores it (or merges with an existing similar skill). Fire-and-forget
    /// from the orchestrator's post-turn path — never blocks the user.
    func distill(
        from trace: InteractionTrace,
        client: any InferenceProvider,
        model: String,
        embeddingModel: String
    ) async {
        // Skip trivial / failed interactions — nothing to learn from
        guard trace.error == nil,
              trace.userMessage.count >= 5,
              trace.assistantResponse.count >= 20
        else { return }

        let toolNames = trace.toolCallList.compactMap { $0["name"] as? String }.joined(separator: ", ")
        let toolLine = toolNames.isEmpty ? "(no tools used)" : "Tools used: \(toolNames)"

        let prompt = """
        Extract a generalizable behavioral lesson from this interaction. Output ONLY
        valid JSON, nothing else. Be concise — each field should be one short sentence.

        {
          "situation": "<when this kind of request comes in, in 6-10 words>",
          "action": "<what the assistant should do, in 6-12 words>",
          "lesson": "<why, in one short sentence>"
        }

        If there is no useful generalizable lesson (e.g. the interaction was trivial
        or generic), output exactly: {"situation":"","action":"","lesson":""}

        Interaction:
        User: \(trace.userMessage)
        \(toolLine)
        Assistant: \(trace.assistantResponse.prefix(800))
        """

        do {
            let resp = try await client.chat(
                model: model,
                messages: [["role": "user", "content": prompt]],
                tools: nil,
                temperature: 0.2,
                numCtx: 2048,
                timeout: 20
            )
            let cleaned = ThinkingStripper.strip(resp.content)
            guard let start = cleaned.firstIndex(of: "{"),
                  let end = cleaned.lastIndex(of: "}")
            else { return }
            let jsonStr = String(cleaned[start...end])
            guard let data = jsonStr.data(using: .utf8),
                  let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let situation = (parsed["situation"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  let action = (parsed["action"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  let lesson = (parsed["lesson"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            else { return }

            // Filter out the "nothing to learn" sentinel
            if situation.isEmpty || action.isEmpty { return }
            if situation.count < 5 || action.count < 5 { return }

            // Embed for retrieval + dedupe
            var embedding: [Float] = []
            do {
                let vecs = try await client.embed(
                    model: embeddingModel,
                    text: ["\(situation) \(action)"]
                )
                embedding = vecs.first ?? []
            } catch {
                // Continue without embedding — skill is still useful, just less retrievable
            }

            // Dedupe against existing skills
            if !embedding.isEmpty {
                let existing = recentSkills(limit: 500)
                let normNew = Self.normalize(embedding)
                for skill in existing {
                    guard let vec = skill.embeddingVector, vec.count == embedding.count else { continue }
                    let normExisting = Self.normalize(vec)
                    var dot: Float = 0
                    vDSP_dotpr(normNew, 1, normExisting, 1, &dot, vDSP_Length(normNew.count))
                    if dot > dedupeThreshold {
                        // Merge: bump useCount on the existing skill
                        bumpUseCount(skillId: skill.id ?? 0)
                        return
                    }
                }
            }

            let embeddingData: Data?
            if !embedding.isEmpty {
                embeddingData = embedding.withUnsafeBufferPointer { Data(buffer: $0) }
            } else {
                embeddingData = nil
            }

            let newSkill = Skill(
                id: nil,
                situation: situation,
                action: action,
                lesson: lesson,
                embedding: embeddingData,
                sourceTraceId: trace.id,
                useCount: 0,
                successCount: 0,
                createdAt: Date(),
                updatedAt: Date()
            )
            // Shadow inside the closure so the mutation from `didInsert`
            // doesn't cross a concurrent-closure boundary (Swift 6
            // sendable-closure-captures error otherwise).
            try await dbPool.write { db in
                var local = newSkill
                try local.insert(db)
            }
            Log.app.info("[skills] learned: \(situation)")
        } catch {
            // Distillation failures are non-fatal
        }
    }

    // MARK: - Retrieval

    /// Top-K skills most relevant to a new query, by cosine similarity.
    /// Returns nothing if there's no embedding-based match — caller should
    /// not panic, just proceed without injection.
    func retrieve(forQueryEmbedding query: [Float], topK: Int = 5) -> [Skill] {
        guard !query.isEmpty else { return [] }
        let normalized = Self.normalize(query)

        let candidates = recentSkills(limit: 1000)
        var scored: [(Skill, Float)] = []
        for skill in candidates {
            guard let vec = skill.embeddingVector, vec.count == query.count else { continue }
            let normExisting = Self.normalize(vec)
            var dot: Float = 0
            vDSP_dotpr(normalized, 1, normExisting, 1, &dot, vDSP_Length(normalized.count))
            if dot > 0.55 {  // hard relevance floor — irrelevant skills hurt
                scored.append((skill, dot))
            }
        }
        scored.sort { $0.1 > $1.1 }
        return Array(scored.prefix(topK)).map(\.0)
    }

    /// Async retrieval that handles the embedding step itself.
    func retrieve(
        forQuery text: String,
        client: any InferenceProvider,
        embeddingModel: String,
        topK: Int = 5
    ) async -> [Skill] {
        do {
            let vecs = try await client.embed(model: embeddingModel, text: [text])
            guard let vec = vecs.first else { return [] }
            return retrieve(forQueryEmbedding: vec, topK: topK)
        } catch {
            return []
        }
    }

    /// Format a list of skills for system-prompt injection. Compact, single block.
    static func formatForPrompt(_ skills: [Skill]) -> String {
        guard !skills.isEmpty else { return "" }
        let lines = skills.enumerated().map { (i, s) in "  \(i + 1). \(s.promptLine)" }
        return "RELEVANT LEARNED SKILLS (from past interactions with this user):\n" +
               lines.joined(separator: "\n")
    }

    // MARK: - Read

    func recentSkills(limit: Int = 50) -> [Skill] {
        do {
            return try dbPool.read { db in
                try Skill
                    .order(Column("updatedAt").desc)
                    .limit(limit)
                    .fetchAll(db)
            }
        } catch {
            Log.app.error("[skills] recent failed: \(error)")
            return []
        }
    }

    func count() -> Int {
        (try? dbPool.read { try Skill.fetchCount($0) }) ?? 0
    }

    func clearAll() {
        _ = try? dbPool.write { db in
            try db.execute(sql: "DELETE FROM skills")
        }
    }

    private func bumpUseCount(skillId: Int64) {
        _ = try? dbPool.write { db in
            try db.execute(
                sql: "UPDATE skills SET useCount = useCount + 1, updatedAt = ? WHERE id = ?",
                arguments: [Date(), skillId]
            )
        }
    }

    // MARK: - Helpers

    private static func normalize(_ v: [Float]) -> [Float] {
        var sumSquares: Float = 0
        vDSP_svesq(v, 1, &sumSquares, vDSP_Length(v.count))
        let norm = sqrt(sumSquares)
        guard norm > 0 else { return v }
        var divisor = norm
        var out = [Float](repeating: 0, count: v.count)
        vDSP_vsdiv(v, 1, &divisor, &out, 1, vDSP_Length(v.count))
        return out
    }
}
