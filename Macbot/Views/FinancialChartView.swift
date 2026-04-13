import SwiftUI
import WebKit

// MARK: - Chart data types

enum ChartType {
    case candlestickVolume(ohlcv: [OHLCV], smas: [(period: Int, values: [Double?])]?)
    case stbrDualAxis(prices: [PricePoint], stbrBars: [StbrBar])
    case riskMomentum(items: [RiskMomentumItem])
    case pnlBars(items: [PnlBarItem])
}

struct OHLCV {
    let date: String
    let open: Double
    let high: Double
    let low: Double
    let close: Double
    let volume: Double
}

struct PricePoint {
    let date: String
    let value: Double
}

struct StbrBar {
    let date: String
    let value: Double
    let color: String
}

struct RiskMomentumItem {
    let symbol: String
    let score: Double
    let rsi: Double
    let stbr: Double
    let riskLevel: String
    let riskColor: String
}

struct PnlBarItem {
    let symbol: String
    let value: Double
    let percentage: Double
}

// MARK: - SwiftUI wrapper

struct FinancialChartView: NSViewRepresentable {
    let chartType: ChartType
    let height: CGFloat
    var ticker: String?

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.preferences.setValue(true, forKey: "developerExtrasEnabled")
        let wv = WKWebView(frame: .zero, configuration: config)
        wv.setValue(false, forKey: "drawsBackground")
        return wv
    }

    func updateNSView(_ wv: WKWebView, context: Context) {
        let html = buildHTML()
        wv.loadHTMLString(html, baseURL: nil)
    }

    // MARK: - HTML builders

    private func buildHTML() -> String {
        switch chartType {
        case .candlestickVolume(let ohlcv, let smas):
            return candlestickHTML(ohlcv: ohlcv, smas: smas)
        case .stbrDualAxis(let prices, let stbrBars):
            return stbrHTML(prices: prices, stbrBars: stbrBars)
        case .riskMomentum(let items):
            return riskMomentumHTML(items: items)
        case .pnlBars(let items):
            return pnlBarsHTML(items: items)
        }
    }

    // MARK: Candlestick + Volume

    private func candlestickHTML(ohlcv: [OHLCV], smas: [(period: Int, values: [Double?])]?) -> String {
        let ohlcJSON = ohlcv.map {
            """
            {time:"\($0.date)",open:\($0.open),high:\($0.high),low:\($0.low),close:\($0.close)}
            """
        }.joined(separator: ",")

        let volJSON = ohlcv.map {
            let c = $0.close >= $0.open ? "rgba(38,166,154,0.4)" : "rgba(239,83,80,0.4)"
            return "{time:\"\($0.date)\",value:\($0.volume),color:\"\(c)\"}"
        }.joined(separator: ",")

        var smaBlocks = ""
        if let smas = smas {
            let palette = ["#2962FF", "#FF6D00", "#AB47BC", "#00BFA5"]
            for (idx, sma) in smas.enumerated() {
                let color = palette[idx % palette.count]
                let vals = sma.values.enumerated().compactMap { (i, v) -> String? in
                    guard let v = v, i < ohlcv.count else { return nil }
                    return "{time:\"\(ohlcv[i].date)\",value:\(v)}"
                }.joined(separator: ",")
                smaBlocks += """
                {
                    const s=chart.addLineSeries({color:"\(color)",lineWidth:1,
                        title:"SMA \(sma.period)",priceScaleId:"right"});
                    s.setData([\(vals)]);
                }
                """
            }
        }

        let watermark = ticker.map {
            "watermark:{visible:true,text:\"\($0)\",fontSize:48,color:\"rgba(255,255,255,0.04)\"},"
        } ?? ""

        return page(body: """
        <div id="chart" style="width:100%;height:\(Int(height))px"></div>
        <script>
        const chart=LightweightCharts.createChart(document.getElementById("chart"),{
            width:document.getElementById("chart").clientWidth,
            height:\(Int(height)),
            \(watermark)
            layout:{background:{type:"solid",color:"#09090B"},textColor:"#A1A1AA",
                    fontFamily:"-apple-system,BlinkMacSystemFont,sans-serif"},
            grid:{vertLines:{color:"#1a1a1a"},horzLines:{color:"#1a1a1a"}},
            crosshair:{mode:0},
            rightPriceScale:{borderColor:"#1a1a1a"},
            timeScale:{borderColor:"#1a1a1a",timeVisible:false}
        });
        const cs=chart.addCandlestickSeries({
            upColor:"#26a69a",downColor:"#ef5350",borderVisible:false,
            wickUpColor:"#26a69a",wickDownColor:"#ef5350"});
        cs.setData([\(ohlcJSON)]);
        const vs=chart.addHistogramSeries({
            priceFormat:{type:"volume"},priceScaleId:"volume",
            color:"rgba(38,166,154,0.4)"});
        vs.priceScale().applyOptions({scaleMargins:{top:0.8,bottom:0}});
        vs.setData([\(volJSON)]);
        \(smaBlocks)
        chart.timeScale().fitContent();
        new ResizeObserver(()=>{
            chart.applyOptions({width:document.getElementById("chart").clientWidth});
        }).observe(document.getElementById("chart"));
        </script>
        """)
    }

    // MARK: STBR Dual-Axis

    private func stbrHTML(prices: [PricePoint], stbrBars: [StbrBar]) -> String {
        let priceJSON = prices.map {
            "{time:\"\($0.date)\",value:\($0.value)}"
        }.joined(separator: ",")

        // Simple 140-day SMA computed inline
        let window = 140
        var smaJSON = [String]()
        for i in 0..<prices.count {
            if i < window - 1 { continue }
            let slice = prices[(i - window + 1)...i]
            let avg = slice.reduce(0.0) { $0 + $1.value } / Double(window)
            smaJSON.append("{time:\"\(prices[i].date)\",value:\(avg)}")
        }

        let stbrJSON = stbrBars.map {
            "{time:\"\($0.date)\",value:\($0.value),color:\"\($0.color)\"}"
        }.joined(separator: ",")

        return page(body: """
        <div id="chart" style="width:100%;height:\(Int(height))px"></div>
        <script>
        const chart=LightweightCharts.createChart(document.getElementById("chart"),{
            width:document.getElementById("chart").clientWidth,
            height:\(Int(height)),
            layout:{background:{type:"solid",color:"#09090B"},textColor:"#A1A1AA",
                    fontFamily:"-apple-system,BlinkMacSystemFont,sans-serif"},
            grid:{vertLines:{color:"#1a1a1a"},horzLines:{color:"#1a1a1a"}},
            crosshair:{mode:0},
            rightPriceScale:{borderColor:"#1a1a1a",scaleMargins:{top:0.05,bottom:0.4},
                             mode:1},
            leftPriceScale:{visible:true,borderColor:"#1a1a1a",
                            scaleMargins:{top:0.65,bottom:0.05}},
            timeScale:{borderColor:"#1a1a1a"}
        });
        const ps=chart.addLineSeries({color:"#FAFAFA",lineWidth:2,
            priceScaleId:"right",title:"Price"});
        ps.setData([\(priceJSON)]);
        const sma=chart.addLineSeries({color:"#FF6D00",lineWidth:1,
            lineStyle:2,priceScaleId:"right",title:"140D SMA"});
        sma.setData([\(smaJSON.joined(separator: ","))]);
        const hb=chart.addHistogramSeries({priceScaleId:"left",title:"STBR",
            priceFormat:{type:"price",precision:3,minMove:0.001}});
        hb.setData([\(stbrJSON)]);
        chart.timeScale().fitContent();
        new ResizeObserver(()=>{
            chart.applyOptions({width:document.getElementById("chart").clientWidth});
        }).observe(document.getElementById("chart"));
        </script>
        """)
    }

    // MARK: Risk x Momentum (pure HTML)

    private func riskMomentumHTML(items: [RiskMomentumItem]) -> String {
        let sorted = items.sorted { $0.score > $1.score }
        let rows = sorted.map { item in
            """
            <div class="row">
              <span class="sym">\(item.symbol)</span>
              <div class="bar-track">
                <div class="bar-fill" style="width:\(item.score)%;background:\(item.riskColor)"></div>
                <span class="bar-label">\(String(format: "%.0f", item.score))</span>
              </div>
              <span class="badge" style="background:\(item.riskColor)22;color:\(item.riskColor);
                  border:1px solid \(item.riskColor)44">\(item.riskLevel)</span>
              <div class="tooltip">RSI \(String(format: "%.1f", item.rsi)) &middot;
                  STBR \(String(format: "%.3f", item.stbr))</div>
            </div>
            """
        }.joined(separator: "\n")

        return htmlShell("""
        <style>
        .row{display:flex;align-items:center;gap:10px;padding:6px 12px;position:relative}
        .row:hover{background:#ffffff08}
        .row:hover .tooltip{opacity:1;transform:translateY(0)}
        .sym{width:60px;font-weight:600;color:#FAFAFA;font-size:13px}
        .bar-track{flex:1;height:20px;background:#1a1a1a;border-radius:4px;position:relative;overflow:hidden}
        .bar-fill{height:100%;border-radius:4px;transition:width .4s ease}
        .bar-label{position:absolute;right:6px;top:50%;transform:translateY(-50%);
            font-size:11px;color:#FAFAFA;font-weight:500}
        .badge{font-size:10px;padding:2px 8px;border-radius:4px;font-weight:600;
            text-transform:uppercase;white-space:nowrap}
        .tooltip{position:absolute;right:0;top:-22px;font-size:10px;color:#A1A1AA;
            background:#18181B;padding:2px 8px;border-radius:4px;opacity:0;
            transform:translateY(4px);transition:all .2s ease;pointer-events:none;
            white-space:nowrap}
        </style>
        <div style="display:flex;flex-direction:column;gap:2px;padding:8px 0">
        \(rows)
        </div>
        """)
    }

    // MARK: P&L Bars (pure HTML)

    private func pnlBarsHTML(items: [PnlBarItem]) -> String {
        let maxAbs = items.map { abs($0.value) }.max() ?? 1.0
        let rows = items.map { item in
            let pct = abs(item.value) / maxAbs * 100.0
            let color = item.value >= 0 ? "#26a69a" : "#ef5350"
            let sign = item.value >= 0 ? "+" : ""
            return """
            <div class="row">
              <span class="sym">\(item.symbol)</span>
              <div class="bar-track">
                <div class="bar-fill" style="width:\(String(format: "%.1f", pct))%;background:\(color)"></div>
              </div>
              <span class="val" style="color:\(color)">\(sign)\(String(format: "%.2f", item.value))</span>
              <span class="pct" style="color:\(color)">(\(sign)\(String(format: "%.1f", item.percentage))%)</span>
            </div>
            """
        }.joined(separator: "\n")

        return htmlShell("""
        <style>
        .row{display:flex;align-items:center;gap:10px;padding:6px 12px}
        .row:hover{background:#ffffff08}
        .sym{width:60px;font-weight:600;color:#FAFAFA;font-size:13px}
        .bar-track{flex:1;height:18px;background:#1a1a1a;border-radius:4px;overflow:hidden}
        .bar-fill{height:100%;border-radius:4px;transition:width .4s ease}
        .val{font-size:12px;font-weight:600;width:70px;text-align:right;font-variant-numeric:tabular-nums}
        .pct{font-size:11px;width:60px;text-align:right;font-variant-numeric:tabular-nums}
        </style>
        <div style="display:flex;flex-direction:column;gap:2px;padding:8px 0">
        \(rows)
        </div>
        """)
    }

    // MARK: - Template helpers

    /// Full page with TradingView CDN script loaded.
    private func page(body: String) -> String {
        """
        <!DOCTYPE html>
        <html><head><meta charset="utf-8">
        <meta name="viewport" content="width=device-width,initial-scale=1">
        <script src="https://unpkg.com/lightweight-charts@4/dist/lightweight-charts.standalone.production.js"></script>
        <style>
        *{margin:0;padding:0;box-sizing:border-box}
        html,body{background:#09090B;overflow:hidden;font-family:-apple-system,BlinkMacSystemFont,sans-serif}
        </style>
        </head><body>\(body)</body></html>
        """
    }

    /// Minimal HTML shell for non-TradingView chart types.
    private func htmlShell(_ body: String) -> String {
        """
        <!DOCTYPE html>
        <html><head><meta charset="utf-8">
        <style>
        *{margin:0;padding:0;box-sizing:border-box}
        html,body{background:#09090B;color:#FAFAFA;overflow-x:hidden;
            font-family:-apple-system,BlinkMacSystemFont,sans-serif}
        </style>
        </head><body>\(body)</body></html>
        """
    }
}
