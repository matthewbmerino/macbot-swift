import Foundation

enum CalendarTools {

    static let calendarTodaySpec = ToolSpec(
        name: "calendar_today",
        description: "Get today's calendar events (or events for a specific date). Shows event title, time, location, and calendar name.",
        properties: [
            "date": .init(type: "string", description: "Date in YYYY-MM-DD format (default: today)"),
        ]
    )

    static let calendarCreateSpec = ToolSpec(
        name: "calendar_create",
        description: "Create a new calendar event in Calendar.app. Specify title, date, start/end time, and optional notes.",
        properties: [
            "title": .init(type: "string", description: "Event title"),
            "date": .init(type: "string", description: "Date in YYYY-MM-DD format"),
            "start_time": .init(type: "string", description: "Start time in HH:MM format (24h)"),
            "end_time": .init(type: "string", description: "End time in HH:MM format (24h)"),
            "notes": .init(type: "string", description: "Optional event notes"),
            "location": .init(type: "string", description: "Optional location"),
        ],
        required: ["title", "date", "start_time", "end_time"]
    )

    static let calendarWeekSpec = ToolSpec(
        name: "calendar_week",
        description: "Get all calendar events for the current week (or a specific week). Good for 'what's my schedule this week' questions.",
        properties: [
            "date": .init(type: "string", description: "Any date within the week in YYYY-MM-DD format (default: this week)"),
        ]
    )

    static let reminderCreateSpec = ToolSpec(
        name: "reminder_create",
        description: "Create a reminder in Reminders.app. Optionally set a due date and time.",
        properties: [
            "title": .init(type: "string", description: "Reminder text"),
            "due_date": .init(type: "string", description: "Optional due date in YYYY-MM-DD format"),
            "due_time": .init(type: "string", description: "Optional due time in HH:MM format (24h)"),
            "list": .init(type: "string", description: "Reminders list name (default: Reminders)"),
        ],
        required: ["title"]
    )

    static func register(on registry: ToolRegistry) async {
        await registry.register(calendarTodaySpec) { args in
            await calendarEvents(date: args["date"] as? String)
        }
        await registry.register(calendarCreateSpec) { args in
            await createEvent(
                title: args["title"] as? String ?? "",
                date: args["date"] as? String ?? "",
                startTime: args["start_time"] as? String ?? "",
                endTime: args["end_time"] as? String ?? "",
                notes: args["notes"] as? String,
                location: args["location"] as? String
            )
        }
        await registry.register(calendarWeekSpec) { args in
            await calendarWeek(date: args["date"] as? String)
        }
        await registry.register(reminderCreateSpec) { args in
            await createReminder(
                title: args["title"] as? String ?? "",
                dueDate: args["due_date"] as? String,
                dueTime: args["due_time"] as? String,
                list: args["list"] as? String ?? "Reminders"
            )
        }
    }

    // MARK: - Calendar Events

    static func calendarEvents(date: String?) async -> String {
        let dateStr = date ?? todayString()
        let script = """
        set targetDate to date "\(formatDateForAppleScript(dateStr))"
        set endDate to targetDate + (1 * days)
        set output to ""
        tell application "Calendar"
            repeat with cal in calendars
                set calName to name of cal
                set evts to (every event of cal whose start date >= targetDate and start date < endDate)
                repeat with e in evts
                    set t to summary of e
                    set s to start date of e
                    set en to end date of e
                    set loc to ""
                    try
                        set loc to location of e
                    end try
                    set timeStr to (time string of s) & " - " & (time string of en)
                    set output to output & t & " | " & timeStr & " | " & calName
                    if loc is not "" and loc is not missing value then
                        set output to output & " | " & loc
                    end if
                    set output to output & "\\n"
                end repeat
            end repeat
        end tell
        return output
        """

        let result = await runAppleScript(script)

        if result.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "No events found for \(dateStr)"
        }

        var lines = ["Events for \(dateStr):", String(repeating: "─", count: 30)]
        for line in result.components(separatedBy: "\n").filter({ !$0.isEmpty }) {
            let parts = line.components(separatedBy: " | ")
            if parts.count >= 3 {
                let title = parts[0]
                let time = parts[1]
                let cal = parts[2]
                let loc = parts.count > 3 ? " @ \(parts[3])" : ""
                lines.append("  \(time)  \(title) [\(cal)]\(loc)")
            } else {
                lines.append("  \(line)")
            }
        }

        return lines.joined(separator: "\n")
    }

    // MARK: - Calendar Week

    static func calendarWeek(date: String?) async -> String {
        let calendar = Calendar.current
        let baseDate: Date

        if let dateStr = date,
           let parsed = parseDate(dateStr) {
            baseDate = parsed
        } else {
            baseDate = Date()
        }

        let weekStart = calendar.dateInterval(of: .weekOfYear, for: baseDate)?.start ?? baseDate
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"

        var allResults: [String] = []

        for dayOffset in 0..<7 {
            guard let day = calendar.date(byAdding: .day, value: dayOffset, to: weekStart) else { continue }
            let dayStr = formatter.string(from: day)
            let events = await calendarEvents(date: dayStr)
            if !events.contains("No events found") {
                allResults.append(events)
            }
        }

        if allResults.isEmpty {
            let weekEndDate = calendar.date(byAdding: .day, value: 6, to: weekStart) ?? weekStart
            return "No events this week (\(formatter.string(from: weekStart)) to \(formatter.string(from: weekEndDate)))"
        }

        return allResults.joined(separator: "\n\n")
    }

    // MARK: - Create Event

    static func createEvent(title: String, date: String, startTime: String, endTime: String, notes: String?, location: String?) async -> String {
        guard !title.isEmpty else { return "Error: empty title" }

        let escapedTitle = title.replacingOccurrences(of: "\"", with: "\\\"")
        let escapedNotes = (notes ?? "").replacingOccurrences(of: "\"", with: "\\\"")
        let escapedLoc = (location ?? "").replacingOccurrences(of: "\"", with: "\\\"")

        let script = """
        tell application "Calendar"
            tell calendar "Calendar"
                set startDate to date "\(formatDateForAppleScript(date)) \(startTime)"
                set endDate to date "\(formatDateForAppleScript(date)) \(endTime)"
                set newEvent to make new event with properties {summary:"\(escapedTitle)", start date:startDate, end date:endDate}
                \(notes != nil ? "set description of newEvent to \"\(escapedNotes)\"" : "")
                \(location != nil ? "set location of newEvent to \"\(escapedLoc)\"" : "")
            end tell
        end tell
        return "OK"
        """

        let result = await runAppleScript(script)

        if result.contains("OK") || result.isEmpty {
            var confirmation = "Created event: \(title)\nDate: \(date)\nTime: \(startTime) - \(endTime)"
            if let loc = location, !loc.isEmpty { confirmation += "\nLocation: \(loc)" }
            if let note = notes, !note.isEmpty { confirmation += "\nNotes: \(note)" }
            return confirmation
        }

        return "Error creating event: \(result)"
    }

    // MARK: - Create Reminder

    static func createReminder(title: String, dueDate: String?, dueTime: String?, list: String) async -> String {
        guard !title.isEmpty else { return "Error: empty reminder title" }

        let escapedTitle = title.replacingOccurrences(of: "\"", with: "\\\"")
        let escapedList = list.replacingOccurrences(of: "\"", with: "\\\"")

        var duePart = ""
        if let date = dueDate, !date.isEmpty {
            let timeStr = dueTime ?? "09:00"
            duePart = ", due date:(date \"\(formatDateForAppleScript(date)) \(timeStr)\")"
        }

        let script = """
        tell application "Reminders"
            tell list "\(escapedList)"
                make new reminder with properties {name:"\(escapedTitle)"\(duePart)}
            end tell
        end tell
        return "OK"
        """

        let result = await runAppleScript(script)

        if result.contains("OK") || result.isEmpty {
            var confirmation = "Created reminder: \(title)"
            if let date = dueDate { confirmation += "\nDue: \(date)" }
            if let time = dueTime { confirmation += " at \(time)" }
            confirmation += "\nList: \(list)"
            return confirmation
        }

        return "Error creating reminder: \(result)"
    }

    // MARK: - Helpers

    private static func todayString() -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: Date())
    }

    private static func parseDate(_ str: String) -> Date? {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return f.date(from: str.trimmingCharacters(in: .whitespaces))
    }

    /// Convert YYYY-MM-DD to AppleScript-friendly date string
    private static func formatDateForAppleScript(_ dateStr: String) -> String {
        guard let date = parseDate(dateStr) else { return dateStr }
        let f = DateFormatter()
        f.dateFormat = "MMMM d, yyyy"
        return f.string(from: date)
    }

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
            let error = String(data: errPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            if !error.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && output.isEmpty {
                return "Error: \(error.trimmingCharacters(in: .whitespacesAndNewlines))"
            }
            return output.trimmingCharacters(in: .whitespacesAndNewlines)
        } catch {
            return "Error: \(error.localizedDescription)"
        }
    }
}
