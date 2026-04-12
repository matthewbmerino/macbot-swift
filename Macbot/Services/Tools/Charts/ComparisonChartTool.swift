import Foundation

// MARK: - Comparison Chart Tool (multi-ticker % change)

enum ComparisonChartTool {

    static let spec = ToolSpec(
        name: "comparison_chart",
        description: "Compare price performance of multiple stocks/crypto on one chart. Shows percentage change from start of period. Use when comparing 2+ tickers.",
        properties: [
            "tickers": .init(type: "string", description: "Comma-separated ticker symbols (e.g., AAPL,MSFT,GOOGL or BTC-USD,ETH-USD)"),
            "period": .init(type: "string", description: "Time period: 1mo, 3mo, 6mo, ytd, 1y, 5y (default: ytd)"),
        ],
        required: ["tickers"]
    )

    static func register(on registry: ToolRegistry) async {
        await registry.register(spec) { args in
            await generateComparisonChart(
                tickers: args["tickers"] as? String ?? "",
                period: args["period"] as? String ?? "ytd"
            )
        }
    }

    static func generateComparisonChart(tickers: String, period: String) async -> String {
        let symbols = tickers.uppercased()
            .components(separatedBy: CharacterSet(charactersIn: ", "))
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard symbols.count >= 2 else {
            return "Error: comparison_chart requires at least 2 ticker symbols (comma-separated)"
        }

        let chartId = UUID().uuidString.prefix(8)
        let chartPath = "/tmp/macbot_compare_\(chartId).png"
        let normalizedPeriod = period.lowercased().trimmingCharacters(in: .whitespaces)
        let tickerList = symbols.map { "'\($0)'" }.joined(separator: ", ")

        let script = """
        import matplotlib
        matplotlib.use('Agg')
        import matplotlib.pyplot as plt
        import matplotlib.dates as mdates
        import matplotlib.ticker as mticker
        import json, urllib.request, sys
        from datetime import datetime

        BG = '#0d1117'
        GRID = '#1e2937'
        TEXT = '#c9d1d9'
        TEXT_DIM = '#6e7681'

        plt.rcParams.update({
            'figure.facecolor': BG, 'axes.facecolor': BG,
            'axes.edgecolor': GRID, 'axes.labelcolor': TEXT,
            'text.color': TEXT, 'xtick.color': TEXT_DIM, 'ytick.color': TEXT_DIM,
            'grid.color': GRID, 'grid.alpha': 0.3, 'grid.linewidth': 0.5,
            'font.size': 11,
            'font.family': ['SF Mono', 'Inter', 'Helvetica Neue', 'sans-serif'],
            'axes.grid': True, 'axes.grid.axis': 'y',
        })

        colors = ['#6366f1', '#22c55e', '#f59e0b', '#ef4444', '#8b5cf6', '#06b6d4', '#f97316', '#ec4899']
        tickers = [\(tickerList)]
        period = '\(normalizedPeriod)'

        def fetch(sym, per):
            try:
                import yfinance as yf
                data = yf.download(sym, period=per, progress=False, timeout=10)
                if not data.empty:
                    close = data['Close']
                    if hasattr(close, 'columns'):
                        close = close.iloc[:, 0]
                    return list(data.index), list(close)
            except:
                pass
            url = f'https://query1.finance.yahoo.com/v8/finance/chart/{sym}?interval=1d&range={per}'
            req = urllib.request.Request(url, headers={'User-Agent': 'Mozilla/5.0'})
            with urllib.request.urlopen(req, timeout=10) as resp:
                data = json.loads(resp.read())
            result = data['chart']['result'][0]
            timestamps = result['timestamp']
            closes = result['indicators']['quote'][0]['close']
            dates = [datetime.fromtimestamp(t) for t in timestamps]
            prices = [c for c in closes if c is not None]
            return dates[:len(prices)], prices

        fig, ax = plt.subplots(figsize=(13, 7))
        fig.subplots_adjust(left=0.08, right=0.88, top=0.90, bottom=0.12)
        plotted = []
        stats_rows = []  # source of truth for both chart and LLM text response

        for i, ticker in enumerate(tickers):
            try:
                dates, prices = fetch(ticker, period)
                if prices:
                    pct = [(p / prices[0] - 1) * 100 for p in prices]
                    color = colors[i % len(colors)]
                    ax.plot(dates, pct, color=color, linewidth=1.8, label=ticker, zorder=3)
                    # End label on right edge
                    ax.annotate(
                        f'{ticker} {pct[-1]:+.1f}%',
                        xy=(1.02, pct[-1]), xycoords=('axes fraction', 'data'),
                        fontsize=9, fontweight='bold', color=color, va='center', ha='left', zorder=5
                    )
                    plotted.append((ticker, pct[-1]))
                    stats_rows.append({
                        'ticker': ticker,
                        'start_price': round(float(prices[0]), 2),
                        'end_price': round(float(prices[-1]), 2),
                        'pct_change': round(float(pct[-1]), 2),
                        'data_points': len(prices),
                    })
            except Exception as e:
                print(f'Warning: could not fetch {ticker}: {e}', file=sys.stderr)

        if not plotted:
            print('ERROR: no data for any ticker', file=sys.stderr)
            sys.exit(1)

        ax.axhline(y=0, color=TEXT_DIM, linewidth=0.6, linestyle='--', zorder=1)
        ax.set_ylabel('% Change', fontsize=10, color=TEXT_DIM)

        # Y-axis padding
        all_pct = [p for _, p in plotted]
        ymin, ymax = min(all_pct), max(all_pct)
        # Collect all plotted data points for accurate range
        ax_lines = ax.get_lines()
        for line in ax_lines:
            yd = line.get_ydata()
            if len(yd) > 0:
                ymin = min(ymin, min(yd))
                ymax = max(ymax, max(yd))
        pad = (ymax - ymin) * 0.08 or 1
        ax.set_ylim(ymin - pad, ymax + pad)

        period_label = period.upper() if period != 'ytd' else 'YTD'
        fig.suptitle(f'{period_label} Performance Comparison', fontsize=15, fontweight='bold',
                     color=TEXT, x=0.08, ha='left', y=0.96)

        ax.legend(loc='upper left', framealpha=0.2, edgecolor='none', fontsize=10)

        if len(dates) > 200:
            ax.xaxis.set_major_locator(mdates.MonthLocator(interval=2))
        elif len(dates) > 60:
            ax.xaxis.set_major_locator(mdates.MonthLocator())
        else:
            ax.xaxis.set_major_locator(mdates.WeekdayLocator(interval=1))
        ax.xaxis.set_major_formatter(mdates.DateFormatter('%b %d'))
        fig.autofmt_xdate(rotation=30)

        ax.spines['top'].set_visible(False)
        ax.spines['right'].set_visible(False)
        ax.spines['left'].set_alpha(0.3)
        ax.spines['bottom'].set_alpha(0.3)
        ax.tick_params(axis='both', which='both', length=0)
        ax.grid(axis='y', color=GRID, alpha=0.3, linewidth=0.5)
        ax.grid(axis='x', visible=False)
        ax.yaxis.set_major_formatter(mticker.FormatStrFormatter('%+.1f%%'))

        plt.savefig('\(chartPath)', dpi=150, bbox_inches='tight', facecolor=BG)
        plt.close('all')

        # -- Stats: emitted on stdout for the LLM so its text response uses
        # the same numbers the chart was drawn with. Single source of truth. --
        import json as _json
        print('STATS:' + _json.dumps({'period': period, 'tickers': stats_rows}))
        print('OK')
        """

        let label = "\(symbols.joined(separator: " vs ")) \(normalizedPeriod.uppercased()) comparison"
        return await ChartShared.runPython(script: script, chartPath: chartPath, label: label)
    }
}
