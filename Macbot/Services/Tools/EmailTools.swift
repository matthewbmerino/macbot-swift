import Foundation

enum EmailTools {

    static let emailDraftSpec = ToolSpec(
        name: "email_draft",
        description: "Create an email draft in Mail.app. The email is NOT sent — it's saved as a draft for the user to review and send manually. Use when the user asks to write, compose, or draft an email.",
        properties: [
            "to": .init(type: "string", description: "Recipient email address(es), comma-separated"),
            "subject": .init(type: "string", description: "Email subject line"),
            "body": .init(type: "string", description: "Email body text"),
            "cc": .init(type: "string", description: "Optional CC recipients, comma-separated"),
        ],
        required: ["to", "subject", "body"]
    )

    static let emailReadSpec = ToolSpec(
        name: "email_read",
        description: "Read the most recent emails from Mail.app. Shows sender, subject, date, and preview.",
        properties: [
            "count": .init(type: "string", description: "Number of emails to show (default: 5)"),
            "mailbox": .init(type: "string", description: "Mailbox name (default: INBOX)"),
        ]
    )

    static func register(on registry: ToolRegistry) async {
        await registry.register(emailDraftSpec) { args in
            await createDraft(
                to: args["to"] as? String ?? "",
                subject: args["subject"] as? String ?? "",
                body: args["body"] as? String ?? "",
                cc: args["cc"] as? String
            )
        }
        await registry.register(emailReadSpec) { args in
            await readEmails(
                count: args["count"] as? String ?? "5",
                mailbox: args["mailbox"] as? String ?? "INBOX"
            )
        }
    }

    // MARK: - Create Draft

    static func createDraft(to: String, subject: String, body: String, cc: String?) async -> String {
        guard !to.isEmpty else { return "Error: recipient is required" }
        guard !subject.isEmpty else { return "Error: subject is required" }

        let escapedTo = to.replacingOccurrences(of: "\"", with: "\\\"")
        let escapedSubject = subject.replacingOccurrences(of: "\"", with: "\\\"")
        let escapedBody = body.replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")

        var recipientsPart = ""
        for addr in to.components(separatedBy: ",").map({ $0.trimmingCharacters(in: .whitespaces) }) {
            if !addr.isEmpty {
                recipientsPart += """
                make new to recipient at end of to recipients with properties {address:"\(addr.replacingOccurrences(of: "\"", with: "\\\""))"}

                """
            }
        }

        var ccPart = ""
        if let cc = cc, !cc.isEmpty {
            for addr in cc.components(separatedBy: ",").map({ $0.trimmingCharacters(in: .whitespaces) }) {
                if !addr.isEmpty {
                    ccPart += """
                    make new cc recipient at end of cc recipients with properties {address:"\(addr.replacingOccurrences(of: "\"", with: "\\\""))"}

                    """
                }
            }
        }

        let script = """
        tell application "Mail"
            set newMessage to make new outgoing message with properties {subject:"\(escapedSubject)", content:"\(escapedBody)", visible:true}
            tell newMessage
                \(recipientsPart)
                \(ccPart)
            end tell
        end tell
        return "OK"
        """

        let result = await runAppleScript(script)

        if result.contains("OK") || result.isEmpty {
            var confirmation = "Email draft created (NOT sent):\nTo: \(to)\nSubject: \(subject)"
            if let cc = cc, !cc.isEmpty { confirmation += "\nCC: \(cc)" }
            confirmation += "\nBody: \(String(body.prefix(100)))\(body.count > 100 ? "..." : "")"
            confirmation += "\n\nThe draft is open in Mail.app for your review."
            return confirmation
        }

        return "Error creating draft: \(result)"
    }

    // MARK: - Read Emails

    static func readEmails(count: String, mailbox: String) async -> String {
        let n = min(Int(count) ?? 5, 20)
        let escapedMailbox = mailbox.replacingOccurrences(of: "\"", with: "\\\"")

        let script = """
        tell application "Mail"
            set output to ""
            try
                set msgs to messages of mailbox "\(escapedMailbox)" of account 1
                set msgCount to count of msgs
                set startIdx to msgCount
                set endIdx to msgCount - \(n - 1)
                if endIdx < 1 then set endIdx to 1
                repeat with i from startIdx to endIdx by -1
                    set msg to item i of msgs
                    set subj to subject of msg
                    set sndr to sender of msg
                    set dt to date received of msg
                    set rd to read status of msg
                    set preview to ""
                    try
                        set preview to text 1 thru 80 of (content of msg as text)
                    end try
                    set readMarker to ""
                    if not rd then set readMarker to "[NEW] "
                    set output to output & readMarker & subj & " | " & sndr & " | " & (dt as text) & " | " & preview & "\\n"
                end repeat
            end try
            return output
        end tell
        """

        let result = await runAppleScript(script)

        if result.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "No emails found in \(mailbox)"
        }

        var lines = ["Recent emails (\(mailbox)):", String(repeating: "─", count: 35)]
        for (i, line) in result.components(separatedBy: "\n").filter({ !$0.isEmpty }).prefix(n).enumerated() {
            let parts = line.components(separatedBy: " | ")
            if parts.count >= 3 {
                let subject = parts[0]
                let sender = parts[1]
                let date = parts[2]
                let preview = parts.count > 3 ? parts[3] : ""
                lines.append("\(i + 1). \(subject)")
                lines.append("   From: \(sender)  |  \(date)")
                if !preview.isEmpty { lines.append("   \(preview)...") }
            } else {
                lines.append("\(i + 1). \(line)")
            }
        }

        return lines.joined(separator: "\n")
    }

    // MARK: - Helper

    private static func runAppleScript(_ script: String) async -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", script]
        let pipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = pipe
        process.standardError = errPipe

        do {
            try process.run()
            let deadline = Date().addingTimeInterval(10)
            while process.isRunning && Date() < deadline {
                try await Task.sleep(for: .milliseconds(100))
            }
            if process.isRunning { process.terminate() }
            let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            return output.trimmingCharacters(in: .whitespacesAndNewlines)
        } catch {
            return "Error: \(error.localizedDescription)"
        }
    }
}
