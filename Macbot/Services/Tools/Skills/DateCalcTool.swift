import Foundation

enum DateCalcTool {

    static let spec = ToolSpec(
        name: "date_calc",
        description: "Date calculations. Operations: days_between (two dates), add_days (date + N days), day_of_week (what day), days_until (from today to date).",
        properties: [
            "operation": .init(type: "string", description: "One of: days_between, add_days, day_of_week, days_until"),
            "date1": .init(type: "string", description: "Date in YYYY-MM-DD format"),
            "date2": .init(type: "string", description: "Second date for days_between (YYYY-MM-DD)"),
            "days": .init(type: "string", description: "Number of days for add_days"),
        ],
        required: ["operation", "date1"]
    )

    static func register(on registry: ToolRegistry) async {
        await registry.register(spec) { args in
            dateCalculation(
                operation: args["operation"] as? String ?? "",
                date1: args["date1"] as? String ?? "",
                date2: args["date2"] as? String,
                days: args["days"] as? String
            )
        }
    }

    // MARK: - Date Calculation

    static func dateCalculation(operation: String, date1: String, date2: String?, days: String?) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.timeZone = .current

        let displayFormatter = DateFormatter()
        displayFormatter.dateFormat = "EEEE, MMMM d, yyyy"

        guard let d1 = formatter.date(from: date1.trimmingCharacters(in: .whitespaces)) else {
            return "Error: invalid date '\(date1)'. Use YYYY-MM-DD format."
        }

        let calendar = Calendar.current

        switch operation.lowercased().trimmingCharacters(in: .whitespaces) {
        case "days_between":
            guard let d2Str = date2, let d2 = formatter.date(from: d2Str.trimmingCharacters(in: .whitespaces)) else {
                return "Error: days_between requires date2 in YYYY-MM-DD format"
            }
            let components = calendar.dateComponents([.day], from: d1, to: d2)
            let count = components.day ?? 0
            return "\(abs(count)) days between \(date1) and \(d2Str)"

        case "add_days":
            guard let daysStr = days, let n = Int(daysStr.trimmingCharacters(in: .whitespaces)) else {
                return "Error: add_days requires a numeric days parameter"
            }
            guard let result = calendar.date(byAdding: .day, value: n, to: d1) else {
                return "Error: could not calculate date"
            }
            return "\(date1) + \(n) days = \(formatter.string(from: result)) (\(displayFormatter.string(from: result)))"

        case "day_of_week":
            return "\(date1) is a \(displayFormatter.string(from: d1))"

        case "days_until":
            let today = calendar.startOfDay(for: Date())
            let target = calendar.startOfDay(for: d1)
            let components = calendar.dateComponents([.day], from: today, to: target)
            let count = components.day ?? 0
            if count > 0 {
                return "\(count) days until \(date1) (\(displayFormatter.string(from: d1)))"
            } else if count == 0 {
                return "\(date1) is today!"
            } else {
                return "\(date1) was \(abs(count)) days ago (\(displayFormatter.string(from: d1)))"
            }

        default:
            return "Error: unknown operation '\(operation)'. Use: days_between, add_days, day_of_week, days_until"
        }
    }
}
