import Foundation

/// Thin facade — delegates to per-chart-type modules in Charts/.
/// Keeps `ChartTools.register(on:)` as the single entry point and
/// preserves `ChartTools.formatStatsBlock` for existing callers/tests.
enum ChartTools {

    static func register(on registry: ToolRegistry) async {
        await StockChartTool.register(on: registry)
        await ComparisonChartTool.register(on: registry)
        await GenericChartTools.register(on: registry)
    }

    // MARK: - Public re-exports (used by tests)

    static func formatStatsBlock(stdout: String) -> String {
        ChartShared.formatStatsBlock(stdout: stdout)
    }
}
