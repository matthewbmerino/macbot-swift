import Foundation

// MARK: - Generic Chart Tools (custom matplotlib charts + file grab)

enum GenericChartTools {

    static let generateChartSpec = ToolSpec(
        name: "generate_chart",
        description: "Generate a custom chart from Python matplotlib code. Use stock_chart instead for stock/crypto charts — it's faster and more reliable. Only use this for custom/non-stock visualizations.",
        properties: [
            "code": .init(type: "string", description: "Python matplotlib code. OUTPUT_PATH is predefined. Call plt.savefig(OUTPUT_PATH) at the end."),
            "title": .init(type: "string", description: "Brief description of the chart"),
        ],
        required: ["code"]
    )

    static let grabFileSpec = ToolSpec(
        name: "grab_file",
        description: "Grab a file and include it in the response. Images display inline. Text files show content.",
        properties: ["path": .init(type: "string", description: "Path to the file")],
        required: ["path"]
    )

    static func register(on registry: ToolRegistry) async {
        await registry.register(generateChartSpec) { args in
            await generateCustomChart(code: args["code"] as? String ?? "", title: args["title"] as? String ?? "Chart")
        }
        await registry.register(grabFileSpec) { args in
            grabFile(path: args["path"] as? String ?? "")
        }
    }

    // MARK: - Custom Chart (model-written code)

    static func generateCustomChart(code: String, title: String) async -> String {
        let chartId = UUID().uuidString.prefix(8)
        let chartPath = "/tmp/macbot_chart_\(chartId).png"

        let setup = """
        import matplotlib
        matplotlib.use('Agg')
        import matplotlib.pyplot as plt
        plt.rcParams.update({
            'figure.facecolor': '#0d1117', 'axes.facecolor': '#0d1117',
            'axes.edgecolor': '#1e2937', 'axes.labelcolor': '#c9d1d9',
            'text.color': '#c9d1d9', 'xtick.color': '#6e7681', 'ytick.color': '#6e7681',
            'grid.color': '#1e2937', 'grid.alpha': 0.3, 'grid.linewidth': 0.5,
            'figure.figsize': (13, 7), 'font.size': 11,
            'font.family': ['SF Mono', 'Inter', 'Helvetica Neue', 'sans-serif'],
            'axes.grid': True, 'axes.grid.axis': 'y',
        })
        OUTPUT_PATH = '\(chartPath)'
        """

        var userCode = code
        if !userCode.contains("savefig") {
            userCode += "\nplt.tight_layout()\nplt.savefig(OUTPUT_PATH, dpi=150, bbox_inches='tight', facecolor='#0d1117')"
        }

        let fullCode = "\(setup)\n\(userCode)\nplt.close('all')\nprint('OK')"
        return await ChartShared.runPython(script: fullCode, chartPath: chartPath, label: title)
    }

    // MARK: - File Grab

    static func grabFile(path: String) -> String {
        let expanded = NSString(string: path).expandingTildeInPath
        let fm = FileManager.default

        guard fm.fileExists(atPath: expanded) else {
            return "File not found: \(path)"
        }

        let url = URL(fileURLWithPath: expanded)
        let ext = url.pathExtension.lowercased()

        let imageExts: Set = ["png", "jpg", "jpeg", "gif", "svg", "webp", "bmp", "tiff"]
        if imageExts.contains(ext) {
            return "\(url.lastPathComponent)\n[IMAGE:\(expanded)]"
        }

        let textExts: Set = [
            "txt", "md", "py", "js", "ts", "swift", "json", "yaml", "yml",
            "toml", "csv", "html", "css", "sh", "sql", "xml", "rs", "go",
            "java", "c", "cpp", "h", "rb", "php", "r", "log", "conf",
        ]

        if textExts.contains(ext) || (try? fm.attributesOfItem(atPath: expanded)[.size] as? Int ?? 0) ?? 0 < 100000 {
            if let content = try? String(contentsOfFile: expanded, encoding: .utf8) {
                let truncated = content.count > 10000 ? String(content.prefix(10000)) + "\n... (truncated)" : content
                return "File: \(url.lastPathComponent) (\(content.count) characters)\n\n\(truncated)"
            }
        }

        let size = (try? fm.attributesOfItem(atPath: expanded)[.size] as? Int) ?? 0
        return "File: \(url.lastPathComponent) (\(size) bytes) — binary format, cannot display as text."
    }
}
