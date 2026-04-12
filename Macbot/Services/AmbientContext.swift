import Foundation
import AppKit
import IOKit.ps

/// Snapshot of the user's current environment.
/// Updated continuously by AmbientMonitor; injected into agent prompts.
struct AmbientSnapshot: Sendable {
    var frontmostApp: String = ""
    var frontmostBundleID: String = ""
    var windowTitle: String = ""
    var idleSeconds: Int = 0
    var batteryPercent: Int = -1     // -1 = not on battery
    var isCharging: Bool = false
    var networkOnline: Bool = true
    var memoryUsedGB: Double = 0
    var memoryTotalGB: Double = 0
    var clipboardPreview: String = ""
    var clipboardChangeCount: Int = 0
    var capturedAt: Date = .init()

    /// Compact human-readable summary for prompt injection.
    var promptSummary: String {
        var parts: [String] = []
        if !frontmostApp.isEmpty {
            if !windowTitle.isEmpty {
                parts.append("active: \(frontmostApp) — \(windowTitle.prefix(80))")
            } else {
                parts.append("active: \(frontmostApp)")
            }
        }
        if idleSeconds > 60 {
            let mins = idleSeconds / 60
            parts.append("idle: \(mins)m")
        }
        if batteryPercent >= 0 {
            parts.append("battery: \(batteryPercent)%\(isCharging ? "+" : "")")
        }
        if !networkOnline {
            parts.append("offline")
        }
        if memoryTotalGB > 0 {
            parts.append("ram: \(String(format: "%.1f", memoryUsedGB))/\(String(format: "%.0f", memoryTotalGB))GB")
        }
        return parts.joined(separator: " · ")
    }
}

/// Background loop that maintains the ambient snapshot.
/// Polls every `pollInterval` seconds. Cheap — no heavy work in the loop.
actor AmbientMonitor {
    static let shared = AmbientMonitor()

    private var snapshot = AmbientSnapshot()
    private var task: Task<Void, Never>?
    private let pollInterval: TimeInterval = 5
    private var lastPasteboardCount: Int = -1
    private var lastFrontmostBundle: String = ""

    func current() -> AmbientSnapshot { snapshot }

    func start() {
        guard task == nil else { return }
        Log.app.info("[ambient] starting context loop (every \(self.pollInterval)s)")
        task = Task { [weak self] in
            while !Task.isCancelled {
                await self?.tick()
                try? await Task.sleep(for: .seconds(self?.pollInterval ?? 5))
            }
        }
    }

    func stop() {
        task?.cancel()
        task = nil
    }

    private func tick() async {
        var s = AmbientSnapshot()
        s.capturedAt = Date()

        // Frontmost app — main thread
        let appInfo = await MainActor.run { () -> (String, String, String) in
            let app = NSWorkspace.shared.frontmostApplication
            let name = app?.localizedName ?? ""
            let bundle = app?.bundleIdentifier ?? ""
            // Window title via AX is heavy and needs entitlement; use app name only for now
            return (name, bundle, "")
        }
        s.frontmostApp = appInfo.0
        s.frontmostBundleID = appInfo.1
        s.windowTitle = appInfo.2

        // Idle time
        s.idleSeconds = Self.systemIdleSeconds()

        // Battery
        let (pct, charging) = Self.batteryStatus()
        s.batteryPercent = pct
        s.isCharging = charging

        // Memory
        let (memTotalGB, memUsedGB) = await MainActor.run {
            (SystemMonitor.shared.memoryTotalGB, SystemMonitor.shared.memoryUsedGB)
        }
        s.memoryTotalGB = memTotalGB
        s.memoryUsedGB = memUsedGB

        // Network — cheap heuristic via reachability of common DNS
        s.networkOnline = Self.isOnline()

        // Clipboard — only preview if it changed (don't read every tick)
        let pb = await MainActor.run { () -> (Int, String) in
            let count = NSPasteboard.general.changeCount
            let str = NSPasteboard.general.string(forType: .string) ?? ""
            return (count, str)
        }
        s.clipboardChangeCount = pb.0
        if pb.0 != lastPasteboardCount {
            lastPasteboardCount = pb.0
            s.clipboardPreview = String(pb.1.prefix(120)).replacingOccurrences(of: "\n", with: " ")
        } else {
            s.clipboardPreview = snapshot.clipboardPreview
        }

        // Fire app-switch hook if frontmost changed
        if !s.frontmostBundleID.isEmpty, s.frontmostBundleID != lastFrontmostBundle {
            let from = lastFrontmostBundle
            lastFrontmostBundle = s.frontmostBundleID
            await HookSystem.shared.fireAsync(HookContext.make(
                event: .statusUpdate,
                metadata: ["kind": "appSwitch", "from": from, "to": s.frontmostBundleID]
            ))
        }

        snapshot = s
    }

    // MARK: - Helpers

    /// Seconds since last user input (mouse/keyboard).
    private static func systemIdleSeconds() -> Int {
        var iterator: io_iterator_t = 0
        let result = IOServiceGetMatchingServices(
            kIOMainPortDefault,
            IOServiceMatching("IOHIDSystem"),
            &iterator
        )
        guard result == KERN_SUCCESS else { return 0 }
        defer { IOObjectRelease(iterator) }

        let entry = IOIteratorNext(iterator)
        guard entry != 0 else { return 0 }
        defer { IOObjectRelease(entry) }

        var unmanagedDict: Unmanaged<CFMutableDictionary>?
        let propResult = IORegistryEntryCreateCFProperties(entry, &unmanagedDict, kCFAllocatorDefault, 0)
        guard propResult == KERN_SUCCESS,
              let dict = unmanagedDict?.takeRetainedValue() as? [String: Any],
              let idleNS = dict["HIDIdleTime"] as? UInt64
        else { return 0 }

        return Int(idleNS / 1_000_000_000)
    }

    private static func batteryStatus() -> (percent: Int, charging: Bool) {
        guard let snapshot = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(snapshot)?.takeRetainedValue() as? [CFTypeRef]
        else { return (-1, false) }

        for source in sources {
            guard let info = IOPSGetPowerSourceDescription(snapshot, source)?.takeUnretainedValue() as? [String: Any] else { continue }
            if let capacity = info[kIOPSCurrentCapacityKey as String] as? Int,
               let max = info[kIOPSMaxCapacityKey as String] as? Int, max > 0 {
                let pct = (capacity * 100) / max
                let state = info[kIOPSPowerSourceStateKey as String] as? String
                let charging = state == kIOPSACPowerValue
                return (pct, charging)
            }
        }
        return (-1, false)
    }

    private static func isOnline() -> Bool {
        // Cheap stub: assume online. Real reachability requires SCNetwork or NWPathMonitor.
        // We'll wire NWPathMonitor in a follow-up if needed.
        true
    }
}

// MARK: - Prompt Injection Helper

extension AmbientMonitor {
    /// Returns a single-line context string suitable for system prompt injection,
    /// or empty string if nothing meaningful.
    func promptLine() -> String {
        let s = snapshot
        let summary = s.promptSummary
        return summary.isEmpty ? "" : "[ambient] \(summary)"
    }
}
