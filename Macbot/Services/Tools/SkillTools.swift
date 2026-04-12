import Foundation

enum SkillTools {

    // MARK: - Registration

    static func register(on registry: ToolRegistry) async {
        await WeatherTool.register(on: registry)
        await CalculatorTool.register(on: registry)
        await UnitConvertTool.register(on: registry)
        await DateCalcTool.register(on: registry)
        await DefineWordTool.register(on: registry)
        await SystemDashboardTool.register(on: registry)
        await AmbientContextTool.register(on: registry)
        await RecallEpisodesTool.register(on: registry)
        await CurrentTimeTool.register(on: registry)
    }

    // MARK: - Backward Compatibility

    /// Forwarded so existing tests continue to compile against `SkillTools.weatherQueryCandidates`.
    static func weatherQueryCandidates(_ raw: String) -> [String] {
        WeatherTool.weatherQueryCandidates(raw)
    }
}
