import SwiftUI
import AppKit

// MARK: - Chart Window Controller

/// Singleton that creates a floating titled window to display financial charts.
/// Uses the same NSWindow pattern as CompanionController/OverlayController.
/// Hosts FinancialChartView (TradingView Lightweight Charts via WKWebView).
@MainActor
final class ChartWindowController {
    static let shared = ChartWindowController()

    private var window: NSWindow?

    /// Show a chart in a titled, resizable, floating window.
    /// Reuses the existing window if one is already open (updates content + title).
    func showChart(type: ChartType, title: String) {
        let ticker = extractTicker(from: title)
        let chartView = FinancialChartView(chartType: type, height: 560, ticker: ticker)
        let wrapper = ChartWindowWrapper(chartView: chartView)
        let hostingView = NSHostingView(rootView: wrapper)

        if let existing = window {
            existing.contentView = hostingView
            existing.title = title
            existing.makeKeyAndOrderFront(nil)
            NSApplication.shared.activate(ignoringOtherApps: true)
            return
        }

        let w = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )

        w.title = title
        w.contentView = hostingView
        w.isReleasedWhenClosed = false
        w.level = .floating
        w.minSize = NSSize(width: 600, height: 400)
        w.center()

        // Clean up reference when window is closed
        NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: w,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.window = nil
            }
        }

        self.window = w
        w.makeKeyAndOrderFront(nil)
        NSApplication.shared.activate(ignoringOtherApps: true)
    }

    /// Close the chart window if open.
    func close() {
        window?.close()
        window = nil
    }

    /// Extract the ticker symbol from a title like "AAPL — Candlestick (1Y)"
    private func extractTicker(from title: String) -> String? {
        let parts = title.split(separator: " ")
        return parts.first.map(String.init)
    }
}

// MARK: - Chart Window Wrapper (dark background)

/// Wraps FinancialChartView with a dark background matching the chart theme.
private struct ChartWindowWrapper: View {
    let chartView: FinancialChartView

    var body: some View {
        chartView
            .frame(minWidth: 600, minHeight: 400)
            .background(Color(nsColor: NSColor(red: 0.05, green: 0.07, blue: 0.09, alpha: 1.0)))
    }
}
