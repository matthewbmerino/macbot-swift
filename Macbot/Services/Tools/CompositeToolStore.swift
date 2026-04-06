import Foundation
import GRDB

/// A stored multi-step workflow that can be replayed as a single tool.
///
/// When a user teaches the agent a workflow (e.g., "to deploy, run X then Y then Z"),
/// we save the sequence as a composite tool that can be invoked later by name.
struct CompositeTool: Codable, FetchableRecord, MutablePersistableRecord, Identifiable {
    var id: Int64?
    var name: String              // Tool name (e.g., "deploy_app")
    var description: String       // What this workflow does
    var steps: String             // JSON-encoded array of ToolStep
    var triggerPhrase: String     // Natural language trigger (e.g., "deploy the app")
    var timesUsed: Int
    var createdAt: Date
    var updatedAt: Date

    static let databaseTableName = "composite_tools"

    mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }

    /// Decoded steps.
    var decodedSteps: [ToolStep] {
        guard let data = steps.data(using: .utf8),
              let decoded = try? JSONDecoder().decode([ToolStep].self, from: data)
        else { return [] }
        return decoded
    }
}

/// A single step in a composite tool workflow.
struct ToolStep: Codable {
    let toolName: String          // Name of the tool to call
    let arguments: [String: String]  // Argument template (may contain {{variables}})
    let description: String       // What this step does
    let captureOutput: String?    // Variable name to capture output into
}

/// Manages composite tools — learned multi-step workflows.
final class CompositeToolStore {
    private let db: DatabasePool

    init(db: DatabasePool = DatabaseManager.shared.dbPool) {
        self.db = db
    }

    // MARK: - CRUD

    @discardableResult
    func save(name: String, description: String, steps: [ToolStep], triggerPhrase: String) -> Int64 {
        let now = Date()
        let stepsJSON = (try? JSONEncoder().encode(steps)).flatMap { String(data: $0, encoding: .utf8) } ?? "[]"

        var tool = CompositeTool(
            name: name, description: description,
            steps: stepsJSON, triggerPhrase: triggerPhrase,
            timesUsed: 0, createdAt: now, updatedAt: now
        )
        do {
            try db.write { db in try tool.insert(db) }
        } catch {
            Log.app.error("[composite] save failed: \(error)")
            return 0
        }
        return tool.id ?? 0
    }

    func find(name: String) -> CompositeTool? {
        do {
            return try db.read { db in
                try CompositeTool.filter(Column("name") == name).fetchOne(db)
            }
        } catch {
            Log.app.error("[composite] find failed: \(error)")
            return nil
        }
    }

    func findByTrigger(phrase: String) -> CompositeTool? {
        let lower = phrase.lowercased()
        let all = listAll()
        return all.first { lower.contains($0.triggerPhrase.lowercased()) }
    }

    func listAll() -> [CompositeTool] {
        (try? db.read { db in
            try CompositeTool.order(Column("timesUsed").desc).fetchAll(db)
        }) ?? []
    }

    func recordUsage(id: Int64) {
        try? db.write { db in
            try db.execute(
                sql: "UPDATE composite_tools SET timesUsed = timesUsed + 1, updatedAt = ? WHERE id = ?",
                arguments: [Date(), id]
            )
        }
    }

    func delete(name: String) -> Bool {
        (try? db.write { db in
            try CompositeTool.filter(Column("name") == name).deleteAll(db) > 0
        }) ?? false
    }

    // MARK: - Execution

    /// Execute a composite tool by running each step in sequence.
    /// Variables captured from previous steps are substituted into later steps.
    func execute(
        tool: CompositeTool,
        initialVariables: [String: String] = [:],
        toolRegistry: ToolRegistry
    ) async -> String {
        let steps = tool.decodedSteps
        guard !steps.isEmpty else { return "No steps in workflow '\(tool.name)'." }

        var variables = initialVariables
        var results: [String] = []

        for (i, step) in steps.enumerated() {
            // Substitute variables into arguments
            var resolvedArgs: [String: Any] = [:]
            for (key, template) in step.arguments {
                var value = template
                for (varName, varValue) in variables {
                    value = value.replacingOccurrences(of: "{{\(varName)}}", with: varValue)
                }
                resolvedArgs[key] = value
            }

            let (_, result) = await toolRegistry.execute(name: step.toolName, arguments: resolvedArgs)

            // Capture output if specified
            if let captureName = step.captureOutput {
                variables[captureName] = result
            }

            results.append("Step \(i + 1) (\(step.description)): \(String(result.prefix(200)))")
        }

        // Record usage
        if let id = tool.id { recordUsage(id: id) }

        return results.joined(separator: "\n")
    }

    // MARK: - Registration

    /// Register all composite tools on a tool registry so agents can use them.
    func registerTools(on registry: ToolRegistry, executor: CompositeToolStore) async {
        let tools = listAll()
        for tool in tools {
            let spec = ToolSpec(
                name: tool.name,
                description: "\(tool.description) (learned workflow, \(tool.decodedSteps.count) steps)",
                properties: [:],
                required: []
            )
            let toolCopy = tool
            await registry.register(spec) { [weak executor] args in
                guard let executor else { return "Tool store unavailable" }
                return await executor.execute(
                    tool: toolCopy,
                    initialVariables: args.compactMapValues { $0 as? String },
                    toolRegistry: registry
                )
            }
        }

        if !tools.isEmpty {
            Log.tools.info("[composite] registered \(tools.count) learned workflows")
        }
    }
}
