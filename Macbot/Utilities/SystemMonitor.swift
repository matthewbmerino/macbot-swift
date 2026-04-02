import Foundation
import AppKit

@Observable
final class SystemMonitor {
    var cpuUsage: Double = 0       // 0.0 to 1.0
    var memoryUsage: Double = 0    // 0.0 to 1.0
    var memoryUsedGB: Double = 0
    var memoryTotalGB: Double = 0
    var gpuUsage: Double = 0       // 0.0 to 1.0 (estimated from model activity)

    private var timer: Timer?
    private var previousCPUInfo: host_cpu_load_info?

    init() {
        let totalBytes = ProcessInfo.processInfo.physicalMemory
        memoryTotalGB = Double(totalBytes) / (1024 * 1024 * 1024)
        update()
        startMonitoring()
    }

    func startMonitoring() {
        timer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            self?.update()
        }
    }

    func stopMonitoring() {
        timer?.invalidate()
        timer = nil
    }

    private func update() {
        cpuUsage = getCPUUsage()
        (memoryUsedGB, memoryUsage) = getMemoryUsage()
        gpuUsage = estimateGPUUsage()
    }

    // MARK: - CPU Usage

    private func getCPUUsage() -> Double {
        var cpuInfo = host_cpu_load_info()
        var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info>.size / MemoryLayout<integer_t>.size)

        let result = withUnsafeMutablePointer(to: &cpuInfo) { ptr in
            ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { intPtr in
                host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, intPtr, &count)
            }
        }

        guard result == KERN_SUCCESS else { return 0 }

        if let prev = previousCPUInfo {
            let userDiff = Double(cpuInfo.cpu_ticks.0 - prev.cpu_ticks.0)
            let systemDiff = Double(cpuInfo.cpu_ticks.1 - prev.cpu_ticks.1)
            let idleDiff = Double(cpuInfo.cpu_ticks.2 - prev.cpu_ticks.2)
            let niceDiff = Double(cpuInfo.cpu_ticks.3 - prev.cpu_ticks.3)
            let total = userDiff + systemDiff + idleDiff + niceDiff

            previousCPUInfo = cpuInfo
            return total > 0 ? (userDiff + systemDiff) / total : 0
        }

        previousCPUInfo = cpuInfo
        return 0
    }

    // MARK: - Memory Usage

    private func getMemoryUsage() -> (usedGB: Double, fraction: Double) {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size)

        let result = withUnsafeMutablePointer(to: &stats) { ptr in
            ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { intPtr in
                host_statistics64(mach_host_self(), HOST_VM_INFO64, intPtr, &count)
            }
        }

        guard result == KERN_SUCCESS else { return (0, 0) }

        let pageSize = Double(vm_kernel_page_size)
        let active = Double(stats.active_count) * pageSize
        let wired = Double(stats.wire_count) * pageSize
        let compressed = Double(stats.compressor_page_count) * pageSize
        let used = (active + wired + compressed) / (1024 * 1024 * 1024)
        let fraction = used / memoryTotalGB

        return (used, min(fraction, 1.0))
    }

    // MARK: - GPU Usage (estimated)

    private func estimateGPUUsage() -> Double {
        // Check if Ollama models are loaded by looking at memory pressure
        // Higher memory usage when models are loaded = GPU is being used
        // This is an approximation — true GPU utilization requires IOKit
        let pressure = memoryUsage
        if pressure > 0.7 { return min((pressure - 0.5) * 2, 1.0) }
        return 0
    }
}
