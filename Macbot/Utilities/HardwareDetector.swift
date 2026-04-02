import Foundation

struct HardwareProfile {
    let chipName: String       // "Apple M3 Pro", "Apple M2", etc.
    let totalRAM: Double       // GB
    let architecture: String   // "arm64" or "x86_64"
    let isAppleSilicon: Bool
    let availableForModels: Double  // GB after OS reserve

    var ramDescription: String {
        "\(Int(totalRAM))GB unified memory"
    }

    var summary: String {
        "\(chipName), \(ramDescription)"
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

        return HardwareProfile(
            chipName: chipName,
            totalRAM: totalGB,
            architecture: arch,
            isAppleSilicon: isAppleSilicon,
            availableForModels: available
        )
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
        } catch {}

        return nil
    }
}
