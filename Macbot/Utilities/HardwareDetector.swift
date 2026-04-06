import Foundation

struct HardwareProfile {
    let chipName: String       // "Apple M3 Pro", "Apple M2", etc.
    let totalRAM: Double       // GB
    let architecture: String   // "arm64" or "x86_64"
    let isAppleSilicon: Bool
    let availableForModels: Double  // GB after OS reserve
    let gpuCores: Int          // Metal GPU core count
    let neuralEngineCores: Int // ANE core count (16 on most M-series)

    var ramDescription: String {
        "\(Int(totalRAM))GB unified memory"
    }

    var summary: String {
        var parts = ["\(chipName)", ramDescription]
        if gpuCores > 0 { parts.append("\(gpuCores) GPU cores") }
        if neuralEngineCores > 0 { parts.append("\(neuralEngineCores)-core Neural Engine") }
        return parts.joined(separator: ", ")
    }

    /// Estimated peak MLX throughput based on memory bandwidth.
    /// M1: ~68 GB/s, M1 Pro/Max: ~200/400, M2: ~100, M3: ~100, M3 Pro: ~150, M3 Max: ~300+
    var estimatedBandwidthGBs: Double {
        guard isAppleSilicon else { return 25.0 }
        // Rough estimates based on chip tier
        let name = chipName.lowercased()
        if name.contains("ultra") { return 800 }
        if name.contains("max") { return 400 }
        if name.contains("pro") { return 200 }
        return 100  // Base M-series
    }

    /// Estimated tokens/second for a given model size (in billions of params, Q4).
    func estimatedTokensPerSecond(paramBillions: Double) -> Double {
        // bytes_per_token ≈ params_B * 0.5 (Q4 = 0.5 bytes per param)
        // tokens/s ≈ bandwidth / bytes_per_token
        let bytesPerToken = paramBillions * 0.5
        return estimatedBandwidthGBs / bytesPerToken
    }
}

enum HardwareDetector {
    /// Detect the current Mac's hardware profile.
    static func detect() -> HardwareProfile {
        let totalBytes = ProcessInfo.processInfo.physicalMemory
        let totalGB = Double(totalBytes) / (1024 * 1024 * 1024)

        let arch: String
        #if arch(arm64)
        arch = "arm64"
        #else
        arch = "x86_64"
        #endif

        let isAppleSilicon = arch == "arm64"
        let chipName = detectChipName() ?? (isAppleSilicon ? "Apple Silicon" : "Intel Mac")

        // Reserve 5GB for macOS on Apple Silicon, 4GB for Intel
        let osReserve: Double = isAppleSilicon ? 5.0 : 4.0
        let available = max(0, totalGB - osReserve)

        let gpuCores = detectGPUCores()
        let aneCores = isAppleSilicon ? 16 : 0  // All M-series have 16-core ANE

        return HardwareProfile(
            chipName: chipName,
            totalRAM: totalGB,
            architecture: arch,
            isAppleSilicon: isAppleSilicon,
            availableForModels: available,
            gpuCores: gpuCores,
            neuralEngineCores: aneCores
        )
    }

    /// Detect GPU core count via IOKit/system_profiler.
    private static func detectGPUCores() -> Int {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/system_profiler")
        process.arguments = ["SPDisplaysDataType", "-json"]
        let pipe = Pipe()
        process.standardOutput = pipe

        do {
            try process.run()
            process.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()

            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let items = json["SPDisplaysDataType"] as? [[String: Any]],
               let first = items.first,
               let cores = first["sppci_cores"] as? String,
               let coreCount = Int(cores) {
                return coreCount
            }
        } catch {
            Log.app.warning("[hardware] GPU core detection via system_profiler failed: \(error.localizedDescription)")
        }

        return 0
    }

    private static func detectChipName() -> String? {
        // Try sysctl first (fast)
        var size = 0
        sysctlbyname("machdep.cpu.brand_string", nil, &size, nil, 0)
        if size > 0 {
            var brand = [CChar](repeating: 0, count: size)
            sysctlbyname("machdep.cpu.brand_string", &brand, &size, nil, 0)
            let name = String(cString: brand)
            if !name.isEmpty { return name }
        }

        // Fallback to system_profiler
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/system_profiler")
        process.arguments = ["SPHardwareDataType", "-json"]
        let pipe = Pipe()
        process.standardOutput = pipe

        do {
            try process.run()
            process.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()

            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let items = json["SPHardwareDataType"] as? [[String: Any]],
               let first = items.first {
                return first["chip_type"] as? String
                    ?? first["cpu_type"] as? String
                    ?? first["machine_name"] as? String
            }
        } catch {
            Log.app.warning("[hardware] chip detection via system_profiler failed: \(error.localizedDescription)")
        }

        return nil
    }
}
