import Foundation

enum GitTools {

    static let gitStatusSpec = ToolSpec(
        name: "git_status",
        description: "Get a structured overview of a git repository: current branch, status, recent commits, and staged changes. Use when the user asks about a repo's state.",
        properties: [
            "path": .init(type: "string", description: "Path to the git repository (default: current directory)"),
        ]
    )

    static let gitLogSpec = ToolSpec(
        name: "git_log",
        description: "Show recent git commit history with optional filtering.",
        properties: [
            "path": .init(type: "string", description: "Path to the git repository"),
            "count": .init(type: "string", description: "Number of commits to show (default: 10)"),
            "author": .init(type: "string", description: "Filter by author name"),
        ]
    )

    static let gitDiffSpec = ToolSpec(
        name: "git_diff",
        description: "Show git diff — unstaged changes by default, or staged changes, or diff between branches/commits.",
        properties: [
            "path": .init(type: "string", description: "Path to the git repository"),
            "target": .init(type: "string", description: "What to diff: 'staged', 'unstaged' (default), a branch name, or a commit hash"),
        ]
    )

    static func register(on registry: ToolRegistry) async {
        await registry.register(gitStatusSpec) { args in
            await gitStatus(path: args["path"] as? String)
        }
        await registry.register(gitLogSpec) { args in
            await gitLog(
                path: args["path"] as? String,
                count: args["count"] as? String ?? "10",
                author: args["author"] as? String
            )
        }
        await registry.register(gitDiffSpec) { args in
            await gitDiff(
                path: args["path"] as? String,
                target: args["target"] as? String ?? "unstaged"
            )
        }
    }

    // MARK: - Status

    static func gitStatus(path: String?) async -> String {
        let dir = resolvePath(path)

        var sections: [String] = []

        // Branch
        let branch = await git("rev-parse --abbrev-ref HEAD", in: dir)
        sections.append("Branch: \(branch)")

        // Status
        let status = await git("status --short", in: dir)
        if status.isEmpty {
            sections.append("Working tree clean")
        } else {
            let lines = status.components(separatedBy: "\n").filter { !$0.isEmpty }
            let staged = lines.filter { $0.hasPrefix("A ") || $0.hasPrefix("M ") || $0.hasPrefix("D ") || $0.hasPrefix("R ") }
            let modified = lines.filter { $0.hasPrefix(" M") || $0.hasPrefix(" D") }
            let untracked = lines.filter { $0.hasPrefix("??") }

            if !staged.isEmpty { sections.append("Staged (\(staged.count)):\n\(indent(staged))") }
            if !modified.isEmpty { sections.append("Modified (\(modified.count)):\n\(indent(modified))") }
            if !untracked.isEmpty { sections.append("Untracked (\(untracked.count)):\n\(indent(untracked.prefix(15).map { String($0) }))") }
        }

        // Recent commits
        let log = await git("log --oneline -5 --no-decorate", in: dir)
        if !log.isEmpty {
            sections.append("Recent commits:\n\(indent(log.components(separatedBy: "\n")))")
        }

        // Remote tracking
        let tracking = await git("rev-parse --abbrev-ref @{upstream} 2>/dev/null", in: dir)
        if !tracking.isEmpty {
            let ahead = await git("rev-list --count @{upstream}..HEAD 2>/dev/null", in: dir)
            let behind = await git("rev-list --count HEAD..@{upstream} 2>/dev/null", in: dir)
            let aheadN = Int(ahead) ?? 0
            let behindN = Int(behind) ?? 0
            if aheadN > 0 || behindN > 0 {
                sections.append("Tracking: \(tracking) (ahead \(aheadN), behind \(behindN))")
            } else {
                sections.append("Tracking: \(tracking) (up to date)")
            }
        }

        return sections.joined(separator: "\n\n")
    }

    // MARK: - Log

    static func gitLog(path: String?, count: String, author: String?) async -> String {
        let dir = resolvePath(path)
        let n = Int(count) ?? 10
        var cmd = "log --oneline --no-decorate -\(min(n, 50))"
        if let author = author, !author.isEmpty {
            cmd += " --author='\(author.replacingOccurrences(of: "'", with: ""))'"
        }
        let result = await git(cmd, in: dir)
        return result.isEmpty ? "No commits found." : result
    }

    // MARK: - Diff

    static func gitDiff(path: String?, target: String) async -> String {
        let dir = resolvePath(path)
        let cmd: String

        switch target.lowercased().trimmingCharacters(in: .whitespaces) {
        case "staged":
            cmd = "diff --cached --stat"
        case "unstaged", "":
            cmd = "diff --stat"
        default:
            // Branch or commit comparison
            cmd = "diff --stat \(target.replacingOccurrences(of: "'", with: ""))"
        }

        let stat = await git(cmd, in: dir)
        if stat.isEmpty { return "No differences found." }

        // Also get the actual diff (truncated)
        let detailCmd = cmd.replacingOccurrences(of: "--stat", with: "")
        let detail = await git(detailCmd, in: dir)
        let truncated = detail.count > 4000 ? String(detail.prefix(4000)) + "\n... (truncated)" : detail

        return "Summary:\n\(stat)\n\nDiff:\n\(truncated)"
    }

    // MARK: - Helpers

    private static func resolvePath(_ path: String?) -> String {
        let p = path?.trimmingCharacters(in: .whitespaces) ?? "."
        return NSString(string: p).expandingTildeInPath
    }

    private static func git(_ command: String, in directory: String) async -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["-C", directory] + command.components(separatedBy: " ")
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()

        do {
            try process.run()
            let deadline = Date().addingTimeInterval(10)
            while process.isRunning && Date() < deadline {
                try await Task.sleep(for: .milliseconds(50))
            }
            if process.isRunning { process.terminate() }
            let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            return output.trimmingCharacters(in: .whitespacesAndNewlines)
        } catch {
            return ""
        }
    }

    private static func indent(_ lines: [String]) -> String {
        lines.filter { !$0.isEmpty }.map { "  \($0)" }.joined(separator: "\n")
    }

    private static func indent(_ text: String) -> String {
        indent(text.components(separatedBy: "\n"))
    }
}
