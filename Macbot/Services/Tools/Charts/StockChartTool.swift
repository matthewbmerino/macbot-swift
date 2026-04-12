import Foundation

// MARK: - Stock Chart Tool

enum StockChartTool {

    static let spec = ToolSpec(
        name: "stock_chart",
        description: "Generate a professional stock price chart for any ticker. Returns an inline image. Use this whenever the user asks to see, show, display, or chart stock/crypto price data.",
        properties: [
            "ticker": .init(type: "string", description: "Stock or crypto ticker symbol (e.g., AAPL, MSFT, BTC-USD, ETH-USD)"),
            "period": .init(type: "string", description: "Time period: 1d, 5d, 1mo, 3mo, 6mo, ytd, 1y, 5y (default: ytd)"),
            "compare": .init(type: "string", description: "Optional second ticker to compare (e.g., MSFT to compare vs AAPL)"),
            "cost_basis": .init(type: "string", description: "Optional cost basis / avg purchase price. Draws a reference line and colors the chart green above / red below."),
        ],
        required: ["ticker"]
    )

    static func register(on registry: ToolRegistry) async {
        await registry.register(spec) { args in
            await generateStockChart(
                ticker: args["ticker"] as? String ?? "",
                period: args["period"] as? String ?? "ytd",
                compare: args["compare"] as? String,
                costBasis: args["cost_basis"] as? String
            )
        }
    }

    static func generateStockChart(ticker: String, period: String, compare: String?, costBasis: String? = nil) async -> String {
        let symbol = ticker.uppercased().trimmingCharacters(in: .whitespaces)
        guard !symbol.isEmpty else { return "Error: empty ticker" }

        let chartId = UUID().uuidString.prefix(8)
        let chartPath = "/tmp/macbot_stock_\(chartId).png"

        // Normalize period
        let normalizedPeriod: String
        let lower = period.lowercased().trimmingCharacters(in: .whitespaces)
        if lower.contains("year to date") || lower.contains("year-to-date") {
            normalizedPeriod = "ytd"
        } else if lower.isEmpty {
            normalizedPeriod = "ytd"
        } else {
            normalizedPeriod = lower
        }

        let costBasisValue = costBasis.flatMap { Double($0.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "$", with: "")) }

        // Build Python script — no model involvement, just data + chart
        var script = """
        import matplotlib
        matplotlib.use('Agg')
        import matplotlib.pyplot as plt
        import matplotlib.dates as mdates
        import matplotlib.ticker as mticker
        from matplotlib.colors import LinearSegmentedColormap
        import numpy as np
        import json, urllib.request, sys
        from datetime import datetime

        # -- Design system --
        BG = '#0d1117'
        CARD_BG = '#0d1117'
        GRID = '#1e2937'
        TEXT = '#c9d1d9'
        TEXT_DIM = '#6e7681'
        GREEN = '#22c55e'
        RED = '#ef4444'
        BLUE = '#6366f1'
        BLUE_FAINT = '#6366f120'

        plt.rcParams.update({
            'figure.facecolor': BG,
            'axes.facecolor': CARD_BG,
            'axes.edgecolor': GRID,
            'axes.labelcolor': TEXT,
            'text.color': TEXT,
            'xtick.color': TEXT_DIM,
            'ytick.color': TEXT_DIM,
            'grid.color': GRID,
            'grid.alpha': 0.4,
            'grid.linewidth': 0.5,
            'font.size': 11,
            'font.family': ['SF Mono', 'Inter', 'Helvetica Neue', 'sans-serif'],
            'axes.grid': True,
            'axes.grid.axis': 'y',
        })

        ticker = '\(symbol)'
        period = '\(normalizedPeriod)'
        cost_basis = \(costBasisValue.map { String($0) } ?? "None")

        def fetch_yahoo(sym, per):
            url = f'https://query1.finance.yahoo.com/v8/finance/chart/{sym}?interval=1d&range={per}'
            req = urllib.request.Request(url, headers={'User-Agent': 'Mozilla/5.0'})
            with urllib.request.urlopen(req, timeout=10) as resp:
                data = json.loads(resp.read())
            result = data['chart']['result'][0]
            ts = result['timestamp']
            quote = result['indicators']['quote'][0]
            closes = quote['close']
            volumes = quote.get('volume', [0]*len(closes))
            dates = [datetime.fromtimestamp(t) for t in ts]
            # Filter out None values while keeping dates/volumes aligned
            clean = [(d, c, v) for d, c, v in zip(dates, closes, volumes) if c is not None]
            if not clean:
                return [], [], []
            d, c, v = zip(*clean)
            return list(d), list(c), [x or 0 for x in v]

        # Fetch data — yfinance first, then direct Yahoo API
        dates, prices, volumes = None, None, None
        try:
            import yfinance as yf
            data = yf.download(ticker, period=period, progress=False, timeout=10)
            if not data.empty:
                close = data['Close']
                if hasattr(close, 'columns'):
                    close = close.iloc[:, 0]
                vol = data['Volume']
                if hasattr(vol, 'columns'):
                    vol = vol.iloc[:, 0]
                dates = list(data.index)
                prices = list(close)
                volumes = [int(v) if v == v else 0 for v in vol]
        except:
            pass

        if not dates or not prices:
            try:
                dates, prices, volumes = fetch_yahoo(ticker, period)
            except Exception as e:
                print(f'ERROR: {e}', file=sys.stderr)
                sys.exit(1)

        if not prices:
            print(f'ERROR: No data for {ticker}', file=sys.stderr)
            sys.exit(1)

        # -- Layout: price pane (80%) + volume pane (20%) --
        fig, (ax, ax_vol) = plt.subplots(
            2, 1, figsize=(13, 7), height_ratios=[4, 1],
            gridspec_kw={'hspace': 0.05}
        )
        fig.subplots_adjust(left=0.08, right=0.92, top=0.90, bottom=0.10)

        """

        // Add comparison ticker if provided
        if let comp = compare?.uppercased().trimmingCharacters(in: .whitespaces), !comp.isEmpty {
            script += """

        # -- Comparison mode --
        comp_dates, comp_prices = None, None
        try:
            import yfinance as yf
            cd = yf.download('\(comp)', period=period, progress=False, timeout=10)
            if not cd.empty:
                cc = cd['Close']
                if hasattr(cc, 'columns'):
                    cc = cc.iloc[:, 0]
                comp_dates, comp_prices = list(cd.index), list(cc)
        except:
            pass
        if not comp_dates:
            try:
                comp_dates, comp_prices, _ = fetch_yahoo('\(comp)', period)
            except:
                pass

        if comp_prices:
            pct1 = [(p / prices[0] - 1) * 100 for p in prices]
            pct2 = [(p / comp_prices[0] - 1) * 100 for p in comp_prices]
            ax.plot(dates, pct1, color=BLUE, linewidth=1.8, label=ticker, zorder=3)
            ax.plot(comp_dates, pct2, color=GREEN, linewidth=1.8, label='\(comp)', zorder=3)
            ax.axhline(y=0, color=TEXT_DIM, linewidth=0.6, linestyle='--', zorder=1)
            ax.set_ylabel('% Change', fontsize=10, color=TEXT_DIM)
            ax.legend(loc='upper left', framealpha=0.2, edgecolor='none', fontsize=10)

            # Y-axis padding
            all_pct = pct1 + pct2
            ymin, ymax = min(all_pct), max(all_pct)
            pad = (ymax - ymin) * 0.08 or 1
            ax.set_ylim(ymin - pad, ymax + pad)
        else:
            cost_basis = None  # Fall through to single-ticker mode

        if not comp_prices:

        """
        } else {
            script += """
        if True:

        """
        }

        script += """
            # -- Single ticker mode --
            np_prices = np.array(prices, dtype=float)
            np_dates = np.array(dates)

            if cost_basis is not None:
                # Color segments: green above cost basis, red below
                above = np.where(np_prices >= cost_basis, np_prices, cost_basis)
                below = np.where(np_prices < cost_basis, np_prices, cost_basis)

                ax.plot(dates, prices, color=TEXT_DIM, linewidth=0.3, zorder=2)

                # Green fill + line above cost basis
                ax.fill_between(dates, cost_basis, above, alpha=0.15, color=GREEN, zorder=1)
                ax.plot(dates, above, color=GREEN, linewidth=1.6, zorder=3)

                # Red fill + line below cost basis
                ax.fill_between(dates, cost_basis, below, alpha=0.15, color=RED, zorder=1)
                ax.plot(dates, below, color=RED, linewidth=1.6, zorder=3)

                # Cost basis reference line
                ax.axhline(y=cost_basis, color='#f59e0b', linewidth=1.0, linestyle='--', zorder=4, alpha=0.8)
                ax.text(dates[-1], cost_basis, f'  Avg Cost ${cost_basis:.2f}',
                        va='center', ha='left', fontsize=9, color='#f59e0b', fontweight='bold',
                        bbox=dict(boxstyle='round,pad=0.3', facecolor=BG, edgecolor='#f59e0b', alpha=0.9),
                        zorder=5)
            else:
                # Default: blue gradient fill
                ax.plot(dates, prices, color=BLUE, linewidth=1.8, zorder=3)

                # Gradient fill — fades from blue at top to transparent at bottom
                ymin_data = min(prices)
                n_steps = 80
                alpha_max = 0.25
                for i in range(n_steps):
                    frac = i / n_steps
                    y_lo = ymin_data + (min(prices) - ymin_data) * (1 - frac) if False else ymin_data
                    alpha = alpha_max * (1 - frac * 0.9)
                    ax.fill_between(dates, ymin_data, prices, alpha=alpha / n_steps * 3, color=BLUE, zorder=1)
                # Simpler approach: single fill with moderate alpha
                ax.fill_between(dates, min(prices) * 0.998, prices, alpha=0.12, color=BLUE, zorder=1)

            # -- Y-axis: zoom to data range with 5% padding --
            price_min, price_max = min(prices), max(prices)
            price_range = price_max - price_min or price_max * 0.01
            y_pad = price_range * 0.05
            ax.set_ylim(price_min - y_pad, price_max + y_pad)

            # -- Current price label on right edge --
            end_price = prices[-1]
            price_color = GREEN if end_price >= prices[0] else RED
            ax.annotate(
                f'${end_price:.2f}',
                xy=(1.01, end_price), xycoords=('axes fraction', 'data'),
                fontsize=10, fontweight='bold', color=BG,
                bbox=dict(boxstyle='round,pad=0.4', facecolor=price_color, edgecolor='none', alpha=0.95),
                va='center', ha='left', zorder=6
            )

            # -- Key point annotations: period high, period low --
            max_idx = prices.index(price_max)
            min_idx = prices.index(price_min)

            # Only annotate if they're not at the edges (to avoid clutter)
            if 2 < max_idx < len(prices) - 3:
                ax.annotate(f'${price_max:.2f}', xy=(dates[max_idx], price_max),
                           xytext=(0, 12), textcoords='offset points',
                           fontsize=8, color=GREEN, ha='center', va='bottom',
                           arrowprops=dict(arrowstyle='-', color=GREEN, lw=0.5))
            if 2 < min_idx < len(prices) - 3:
                ax.annotate(f'${price_min:.2f}', xy=(dates[min_idx], price_min),
                           xytext=(0, -12), textcoords='offset points',
                           fontsize=8, color=RED, ha='center', va='top',
                           arrowprops=dict(arrowstyle='-', color=RED, lw=0.5))

        # -- Volume bars --
        if volumes and len(volumes) == len(dates):
            vol_colors = []
            for i in range(len(prices)):
                if i == 0:
                    vol_colors.append(TEXT_DIM)
                elif prices[i] >= prices[i-1]:
                    vol_colors.append('#22c55e40')
                else:
                    vol_colors.append('#ef444440')
            ax_vol.bar(dates, volumes, width=0.8, color=vol_colors, edgecolor='none', zorder=2)
            ax_vol.set_ylim(0, max(volumes) * 1.15 if max(volumes) > 0 else 1)
            ax_vol.set_ylabel('Vol', fontsize=9, color=TEXT_DIM)
            ax_vol.yaxis.set_major_formatter(mticker.FuncFormatter(
                lambda x, p: f'{x/1e6:.0f}M' if x >= 1e6 else f'{x/1e3:.0f}K' if x >= 1e3 else f'{x:.0f}'
            ))
            ax_vol.tick_params(axis='y', labelsize=8)
        else:
            ax_vol.set_visible(False)

        # -- Title --
        start_price = prices[0]
        end_price = prices[-1]
        change = end_price - start_price
        pct_change = (change / start_price) * 100
        title_color = GREEN if change >= 0 else RED
        arrow = '+' if change >= 0 else ''

        period_label = period.upper() if period != 'ytd' else 'YTD'
        title = f'{ticker}  {period_label}    ${end_price:.2f}  ({arrow}{pct_change:.1f}%)'
        fig.suptitle(title, fontsize=15, fontweight='bold', color=title_color, x=0.08, ha='left', y=0.96)

        # -- X-axis formatting (only on volume axis) --
        ax.set_xticklabels([])
        if len(prices) > 200:
            ax_vol.xaxis.set_major_locator(mdates.MonthLocator(interval=2))
        elif len(prices) > 60:
            ax_vol.xaxis.set_major_locator(mdates.MonthLocator())
        else:
            ax_vol.xaxis.set_major_locator(mdates.WeekdayLocator(interval=1))
        ax_vol.xaxis.set_major_formatter(mdates.DateFormatter('%b %d'))
        fig.autofmt_xdate(rotation=30)

        # -- Cleanup --
        for a in [ax, ax_vol]:
            a.spines['top'].set_visible(False)
            a.spines['right'].set_visible(False)
            a.spines['left'].set_alpha(0.3)
            a.spines['bottom'].set_alpha(0.3)
            a.tick_params(axis='both', which='both', length=0)
        ax.yaxis.set_major_formatter(mticker.FormatStrFormatter('$%.2f'))

        # Y grid only on price axis, subtle
        ax.grid(axis='y', color=GRID, alpha=0.3, linewidth=0.5)
        ax.grid(axis='x', visible=False)
        ax_vol.grid(axis='y', color=GRID, alpha=0.2, linewidth=0.5)
        ax_vol.grid(axis='x', visible=False)

        plt.savefig('\(chartPath)', dpi=150, bbox_inches='tight', facecolor=BG)
        plt.close('all')

        # -- Stats: emitted on stdout for the LLM so its text response uses
        # the same numbers the chart was drawn with. Single source of truth. --
        import json as _json
        _stats = {
            'ticker': ticker,
            'period': period,
            'start_price': round(float(prices[0]), 2),
            'end_price': round(float(prices[-1]), 2),
            'pct_change': round(float((prices[-1] / prices[0] - 1) * 100), 2),
            'period_high': round(float(max(prices)), 2),
            'period_low': round(float(min(prices)), 2),
            'data_points': len(prices),
        }
        print('STATS:' + _json.dumps(_stats))
        print('OK')
        """

        return await ChartShared.runPython(script: script, chartPath: chartPath, label: "\(symbol) \(normalizedPeriod.uppercased()) chart")
    }
}
