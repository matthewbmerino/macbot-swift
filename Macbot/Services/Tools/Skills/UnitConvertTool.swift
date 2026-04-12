import Foundation

enum UnitConvertTool {

    static let spec = ToolSpec(
        name: "unit_convert",
        description: "Convert between units. Categories: temperature (F/C/K), distance (mi/km/m/ft/in/cm), weight (lb/kg/g/oz), volume (gal/L/mL/cup/fl_oz), speed (mph/kph), data (B/KB/MB/GB/TB).",
        properties: [
            "value": .init(type: "string", description: "Numeric value to convert"),
            "from_unit": .init(type: "string", description: "Source unit (e.g., F, km, lb, GB)"),
            "to_unit": .init(type: "string", description: "Target unit (e.g., C, mi, kg, MB)"),
        ],
        required: ["value", "from_unit", "to_unit"]
    )

    static func register(on registry: ToolRegistry) async {
        await registry.register(spec) { args in
            convertUnit(
                value: args["value"] as? String ?? "",
                from: args["from_unit"] as? String ?? "",
                to: args["to_unit"] as? String ?? ""
            )
        }
    }

    // MARK: - Unit Conversion

    static func convertUnit(value: String, from: String, to: String) -> String {
        guard let num = Double(value.trimmingCharacters(in: .whitespaces)) else {
            return "Error: '\(value)' is not a valid number"
        }

        let fromUnit = from.trimmingCharacters(in: .whitespaces).lowercased()
        let toUnit = to.trimmingCharacters(in: .whitespaces).lowercased()

        // Temperature
        if let result = convertTemperature(num, from: fromUnit, to: toUnit) {
            return formatResult(result, unit: to)
        }

        // All other conversions go through a base-unit system
        let categories: [(name: String, base: String, units: [String: Double])] = [
            ("distance", "m", [
                "m": 1, "km": 1000, "mi": 1609.344, "ft": 0.3048,
                "in": 0.0254, "cm": 0.01, "mm": 0.001, "yd": 0.9144,
            ]),
            ("weight", "g", [
                "g": 1, "kg": 1000, "lb": 453.592, "oz": 28.3495,
                "mg": 0.001, "ton": 907185, "tonne": 1_000_000,
            ]),
            ("volume", "ml", [
                "ml": 1, "l": 1000, "gal": 3785.41, "cup": 236.588,
                "fl_oz": 29.5735, "pt": 473.176, "qt": 946.353, "tbsp": 14.787, "tsp": 4.929,
            ]),
            ("speed", "m_s", [
                "mph": 0.44704, "kph": 0.277778, "m_s": 1, "knot": 0.514444, "fps": 0.3048,
            ]),
            ("data", "b", [
                "b": 1, "kb": 1024, "mb": 1_048_576, "gb": 1_073_741_824,
                "tb": 1_099_511_627_776,
            ]),
            ("time", "s", [
                "s": 1, "ms": 0.001, "min": 60, "hr": 3600, "h": 3600,
                "day": 86400, "week": 604800, "month": 2_592_000, "year": 31_536_000,
            ]),
        ]

        for category in categories {
            if let fromFactor = category.units[fromUnit],
               let toFactor = category.units[toUnit] {
                let baseValue = num * fromFactor
                let result = baseValue / toFactor
                return formatResult(result, unit: to)
            }
        }

        return "Error: cannot convert from '\(from)' to '\(to)'. Supported: temperature (F/C/K), distance (m/km/mi/ft/in/cm), weight (g/kg/lb/oz), volume (mL/L/gal/cup/fl_oz), speed (mph/kph/m_s), data (B/KB/MB/GB/TB), time (s/min/hr/day)"
    }

    private static func convertTemperature(_ value: Double, from: String, to: String) -> Double? {
        let tempUnits: Set = ["f", "c", "k"]
        guard tempUnits.contains(from) && tempUnits.contains(to) else { return nil }
        if from == to { return value }

        // Convert to Celsius first
        let celsius: Double
        switch from {
        case "f": celsius = (value - 32) * 5 / 9
        case "k": celsius = value - 273.15
        default: celsius = value
        }

        // Convert from Celsius to target
        switch to {
        case "f": return celsius * 9 / 5 + 32
        case "k": return celsius + 273.15
        default: return celsius
        }
    }

    private static func formatResult(_ value: Double, unit: String) -> String {
        let formatted: String
        if value == value.rounded() && abs(value) < 1e12 {
            formatted = "\(Int(value)) \(unit)"
        } else {
            formatted = "\(String(format: "%.4g", value)) \(unit)"
        }
        return GroundedResponse.format(
            source: "unit_convert",
            timePolicy: .none,
            body: formatted
        )
    }
}
