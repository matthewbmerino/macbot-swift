import Foundation

// MARK: - MLX Configuration

struct MLXModelSpec {
    let huggingFaceId: String
    let contextLength: Int
    let quantization: MLXQuantization

    enum MLXQuantization: String {
        case q2 = "2bit"
        case q3 = "3bit"
        case q4 = "4bit"
        case q6 = "6bit"
        case q8 = "8bit"
        case f16 = "f16"

        var bitsPerWeight: Double {
            switch self {
            case .q2: return 2.0
            case .q3: return 3.0
            case .q4: return 4.0
            case .q6: return 6.0
            case .q8: return 8.0
            case .f16: return 16.0
            }
        }
    }
}

// MARK: - Quantization Helpers

extension MLXClient {

    /// Total parameter count for RAM estimation (not active params).
    static let totalParamOverrides: [String: Double] = [
        "gemma4:26b-a4b": 26.0,  // 26B total params, 4B active
    ]

    static func estimateMemory(for model: String) -> Double? {
        guard let spec = modelCatalog[model] else { return nil }
        // Use override for MoE models (total weight count, not active params)
        let paramB: Double
        if let override = totalParamOverrides[model] {
            paramB = override
        } else {
            let match = model.components(separatedBy: ":").last ?? ""
            paramB = Double(match.replacingOccurrences(of: "b", with: "")
                .replacingOccurrences(of: "-a4b", with: "")
                .replacingOccurrences(of: "e", with: "")) ?? 7.0
        }
        return (paramB * spec.quantization.bitsPerWeight / 8.0) + 0.5
    }

    static func availableQuantizations(ramGB: Double) -> [MLXModelSpec.MLXQuantization] {
        var options: [MLXModelSpec.MLXQuantization] = [.q4]
        if ramGB >= 16 { options.append(.q6) }
        if ramGB >= 24 { options.append(.q8) }
        if ramGB >= 48 { options.append(.f16) }
        options.insert(.q2, at: 0)
        options.insert(.q3, at: 1)
        return options
    }
}
