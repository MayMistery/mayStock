import SwiftUI
import MayStockKit

/// Market depth: cumulative bid/ask size around mid, inside a zoomable price
/// window.
///
/// The window is the whole point. Drawing the full 400-level book on a 300pt
/// panel compresses every interesting level into a spike at the centre, which
/// is what the previous version did — and it had no filter to escape with. Now
/// the window clips the book *and* rescales the size axis to what is visible,
/// so ±0.1% actually reveals near-touch structure.
struct DepthChartView: View {
    let book: OrderBook?
    let zoom: DepthZoom
    let decimals: Int

    @State private var hover: CGPoint? = nil

    private let gutter: CGFloat = 46

    var body: some View {
        GeometryReader { geo in
            let domain = book?.profile(withinPct: zoom.pct)
                .map { Domain(profile: $0, size: geo.size, gutter: gutter) }
            ZStack {
                if let domain {
                    Canvas(rendersAsynchronously: false) { context, size in
                        draw(context: context, size: size, domain: domain)
                    }
                    .chartLegend(legend(domain))
                } else {
                    ChartPlaceholder(text: "正在加载盘口深度…")
                        .chartLegend([])
                }
            }
            .contentShape(Rectangle())
            .onContinuousHover { phase in
                switch phase {
                case .active(let point): hover = point
                case .ended: hover = nil
                }
            }
        }
    }

    // MARK: Domain

    private struct Domain {
        let profile: DepthProfile
        let geometry: PlotGeometry
        /// Size axis top, with headroom so the tallest step is not clipped.
        let maxSize: Double

        init(profile: DepthProfile, size: CGSize, gutter: CGFloat) {
            self.profile = profile
            self.geometry = PlotGeometry(size: size, gutter: gutter)
            self.maxSize = profile.maxCumulative * 1.08
        }

        var span: Double { max(profile.hi - profile.lo, .leastNonzeroMagnitude) }

        func x(_ price: Double) -> CGFloat {
            let fraction = (price - profile.lo) / span
            return geometry.plotWidth * CGFloat(min(max(fraction, 0), 1))
        }

        func price(atX x: CGFloat) -> Double {
            let fraction = min(max(Double(x / geometry.plotWidth), 0), 1)
            return profile.lo + fraction * span
        }

        func y(_ size: Double) -> CGFloat {
            geometry.top + (1 - CGFloat(size / max(maxSize, .leastNonzeroMagnitude))) * geometry.height
        }

        /// Cumulative size resting at `price` on whichever side it falls.
        func cumulative(at price: Double) -> (size: Double, isBid: Bool) {
            if price <= profile.mid {
                return (profile.bids.last(where: { $0.price >= price })?.size ?? 0, true)
            }
            return (profile.asks.last(where: { $0.price <= price })?.size ?? 0, false)
        }
    }

    // MARK: Legend

    private func legend(_ domain: Domain) -> [ChartLegendItem] {
        let profile = domain.profile
        if let hover, hover.x < domain.geometry.plotWidth {
            let price = domain.price(atX: hover.x)
            let probe = domain.cumulative(at: price)
            let distance = abs(price - profile.mid) / profile.mid * 10_000
            return [
                ChartLegendItem(key: "p", value: PriceFormatter.price(price, decimals: decimals),
                                tint: probe.isBid ? .up : .down, priority: 10),
                ChartLegendItem(key: "d", value: String(format: "距中 %@%.1fbp",
                                                        price < profile.mid ? "−" : "+", distance),
                                tint: .secondary, priority: 8),
                ChartLegendItem(key: "c", label: "累计",
                                value: PriceFormatter.compact(probe.size), priority: 9),
                ChartLegendItem(key: "s", value: probe.isBid ? "买盘" : "卖盘",
                                tint: probe.isBid ? .up : .down, priority: 7),
            ]
        }

        var items: [ChartLegendItem] = [
            ChartLegendItem(key: "m", label: "中间价",
                            value: PriceFormatter.price(profile.mid, decimals: decimals), priority: 10),
        ]
        if let spread = book?.spread, let bps = book?.spreadBps {
            items.append(ChartLegendItem(
                key: "sp", label: "价差",
                value: "\(PriceFormatter.price(spread, decimals: decimals))/\(String(format: "%.1f", bps))bp",
                tint: .secondary, priority: 6))
        }
        items.append(ChartLegendItem(key: "b", label: "买",
                                     value: PriceFormatter.compact(profile.bidTotal),
                                     tint: .up, priority: 8))
        items.append(ChartLegendItem(key: "a", label: "卖",
                                     value: PriceFormatter.compact(profile.askTotal),
                                     tint: .down, priority: 8))
        items.append(.trend("i", label: "失衡",
                            value: PriceFormatter.signedPercent(profile.imbalance * 100),
                            isUp: profile.imbalance >= 0, priority: 9))
        if profile.clampedToBook {
            // The requested window is deeper than the snapshot reaches; say so
            // instead of pretending the flat edge is real depth.
            items.append(ChartLegendItem(key: "w",
                                         value: String(format: "±%.0fbp 已到底", profile.spanPct * 100),
                                         tint: .secondary, priority: 3))
        }
        return items
    }

    // MARK: Drawing

    private func draw(context: GraphicsContext, size: CGSize, domain: Domain) {
        drawGrid(context: context, domain: domain)
        drawSide(context: context, domain: domain, levels: domain.profile.bids,
                 color: ChartStyle.up, edge: domain.profile.lo)
        drawSide(context: context, domain: domain, levels: domain.profile.asks,
                 color: ChartStyle.down, edge: domain.profile.hi)
        drawMid(context: context, domain: domain)
        drawSideLabels(context: context, domain: domain)
        if let hover, hover.x < domain.geometry.plotWidth {
            drawCrosshair(context: context, domain: domain, at: hover)
        }
    }

    private func drawGrid(context: GraphicsContext, domain: Domain) {
        let geometry = domain.geometry

        // Cumulative-size axis on the right — the previous version had none, so
        // the curves' heights were unreadable.
        for size in ChartMath.valueTicks(lo: 0, hi: domain.maxSize, target: 3) where size > 0 {
            let y = domain.y(size)
            context.strokeLine(from: CGPoint(x: 0, y: y),
                               to: CGPoint(x: geometry.plotWidth, y: y),
                               color: ChartStyle.grid)
            context.drawText(PriceFormatter.compact(size),
                             font: ChartStyle.axisFont, color: ChartStyle.axisLabel,
                             at: CGPoint(x: geometry.plotWidth + 5, y: y), anchor: .leading)
        }

        // Price axis along the bottom. The mid marker deliberately lives at the
        // top of the plot so it never competes with these labels for the strip.
        for price in ChartMath.valueTicks(lo: domain.profile.lo, hi: domain.profile.hi, target: 4) {
            let x = domain.x(price)
            guard x > 4, x < geometry.plotWidth - 4 else { continue }
            context.strokeLine(from: CGPoint(x: x, y: geometry.top),
                               to: CGPoint(x: x, y: geometry.bottom),
                               color: ChartStyle.grid)
            guard x > 18, x < geometry.plotWidth - 18 else { continue }
            context.drawText(PriceFormatter.price(price, decimals: decimals),
                             font: ChartStyle.axisFont, color: ChartStyle.axisLabel,
                             at: CGPoint(x: x, y: geometry.axisBaseline), anchor: .bottom)
        }
    }

    /// One side of the book as a staircase: cumulative size is constant between
    /// levels and jumps at each one — a smooth slope would be a fiction.
    private func drawSide(context: GraphicsContext, domain: Domain,
                          levels: [BookLevel], color: Color, edge: Double) {
        guard let first = levels.first else { return }
        let geometry = domain.geometry
        let innerX = domain.x(first.price)

        var line = Path()
        line.move(to: CGPoint(x: innerX, y: domain.y(first.size)))
        var lastY = domain.y(first.size)
        for level in levels.dropFirst() {
            let x = domain.x(level.price)
            line.addLine(to: CGPoint(x: x, y: lastY))
            lastY = domain.y(level.size)
            line.addLine(to: CGPoint(x: x, y: lastY))
        }
        // Reach the window edge so the area never stops in mid-air.
        let outerX = domain.x(edge)
        line.addLine(to: CGPoint(x: outerX, y: lastY))

        var area = line
        area.addLine(to: CGPoint(x: outerX, y: geometry.bottom))
        area.addLine(to: CGPoint(x: innerX, y: geometry.bottom))
        area.closeSubpath()

        context.fill(area, with: .linearGradient(
            Gradient(colors: [color.opacity(0.30), color.opacity(0.04)]),
            startPoint: CGPoint(x: 0, y: geometry.top),
            endPoint: CGPoint(x: 0, y: geometry.bottom)))
        context.stroke(line, with: .color(color),
                       style: StrokeStyle(lineWidth: 1.4, lineJoin: .round))
    }

    private func drawMid(context: GraphicsContext, domain: Domain) {
        let geometry = domain.geometry
        let profile = domain.profile

        // Shade the spread itself, so a wide book is visible at a glance.
        if let bestBid = book?.bestBid, let bestAsk = book?.bestAsk, bestAsk > bestBid {
            let rect = CGRect(x: domain.x(bestBid), y: geometry.top,
                              width: max(1, domain.x(bestAsk) - domain.x(bestBid)),
                              height: geometry.height)
            context.fill(Path(rect), with: .color(Color.primary.opacity(0.05)))
        }

        let x = domain.x(profile.mid)
        context.strokeLine(from: CGPoint(x: x, y: geometry.top),
                           to: CGPoint(x: x, y: geometry.bottom),
                           color: ChartStyle.crosshair, dash: [3, 3])

        // Mid price pill riding the top of the line, clear of the price axis.
        let label = PriceFormatter.price(profile.mid, decimals: decimals)
        let width = max(34, CGFloat(label.count) * 5.6 + 10)
        let clamped = min(max(x, width / 2), geometry.plotWidth - width / 2)
        let rect = CGRect(x: clamped - width / 2, y: geometry.top, width: width, height: 13)
        context.fill(Path(roundedRect: rect, cornerRadius: 3.5), with: .color(ChartStyle.tagFill))
        context.drawText(label, font: ChartStyle.tagFont, color: ChartStyle.tagText,
                         at: CGPoint(x: rect.midX, y: rect.midY), anchor: .center)
    }

    private func drawSideLabels(context: GraphicsContext, domain: Domain) {
        let geometry = domain.geometry
        context.drawText("买盘", font: ChartStyle.axisFont, color: ChartStyle.up.opacity(0.65),
                         at: CGPoint(x: 4, y: geometry.top + 1), anchor: .topLeading)
        context.drawText("卖盘", font: ChartStyle.axisFont, color: ChartStyle.down.opacity(0.65),
                         at: CGPoint(x: geometry.plotWidth - 4, y: geometry.top + 1), anchor: .topTrailing)
    }

    private func drawCrosshair(context: GraphicsContext, domain: Domain, at point: CGPoint) {
        let geometry = domain.geometry
        let price = domain.price(atX: point.x)
        let probe = domain.cumulative(at: price)
        let color = probe.isBid ? ChartStyle.up : ChartStyle.down
        let y = domain.y(probe.size)

        context.strokeLine(from: CGPoint(x: point.x, y: geometry.top),
                           to: CGPoint(x: point.x, y: geometry.bottom),
                           color: ChartStyle.crosshair, dash: [2, 2])
        context.strokeLine(from: CGPoint(x: 0, y: y),
                           to: CGPoint(x: geometry.plotWidth, y: y),
                           color: ChartStyle.crosshair, dash: [2, 2])
        context.fill(Path(ellipseIn: CGRect(x: point.x - 3, y: y - 3, width: 6, height: 6)),
                     with: .color(color))

        context.drawPriceTag(PriceFormatter.compact(probe.size), y: y, geometry: geometry,
                             fill: ChartStyle.tagFill, text: ChartStyle.tagText)
        context.drawTimeTag(PriceFormatter.price(price, decimals: decimals),
                            x: point.x, geometry: geometry, fill: color, text: .white)
    }
}
