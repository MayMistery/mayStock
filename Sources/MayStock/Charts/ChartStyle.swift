import SwiftUI
import MayStockKit

/// Single source of truth for chart aesthetics — light/dark adaptive.
enum ChartStyle {
    static let up = Color(nsColor: .systemGreen)
    static let down = Color(nsColor: .systemRed)
    static let accent = Color(nsColor: .controlAccentColor)
    static let ma = Color(nsColor: .systemOrange)
    static let grid = Color.primary.opacity(0.06)
    static let gridStrong = Color.primary.opacity(0.11)
    static let axisLabel = Color.secondary
    static let crosshair = Color.primary.opacity(0.38)
    static let tagFill = Color.primary.opacity(0.78)
    static let tagText = Color(nsColor: .windowBackgroundColor)

    static func trend(_ isUp: Bool) -> Color { isUp ? up : down }

    static let axisFont = Font.system(size: 9, design: .monospaced)
    static let tagFont = Font.system(size: 9, weight: .semibold, design: .monospaced)
    static let readoutFont = Font.system(size: 10, design: .monospaced)
    static let legendFont = Font.system(size: 9.5, weight: .medium, design: .monospaced)

    /// Width of the right-hand price axis, and the bottom time-axis strip.
    static let priceGutter: CGFloat = 56
    static let timeAxisHeight: CGFloat = 13
    static let plotTopInset: CGFloat = 7
}

/// Pre-built, locale-stable date formatters. Charts redraw on every tick, so
/// they must never allocate a `DateFormatter` inside the draw path.
enum ChartFormatters {
    static let formats = [
        "HH:mm:ss", "HH:mm", "MM-dd", "MM-dd HH:mm", "MM-dd HH:mm:ss", "yyyy-MM", "yyyy",
    ]

    private static let cache: [String: DateFormatter] = {
        var built: [String: DateFormatter] = [:]
        for format in formats {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = format
            built[format] = formatter
        }
        return built
    }()

    private static let fallback: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "HH:mm"
        return formatter
    }()

    static func string(_ date: Date, _ format: String) -> String {
        (cache[format] ?? fallback).string(from: date)
    }
}

// MARK: - Geometry

/// Plot geometry shared by the price charts: a plot area, a right-hand price
/// gutter and a bottom time-axis strip. Everything else derives from this, so
/// gridlines, labels and crosshair tags can never drift apart.
struct PlotGeometry {
    let size: CGSize
    var gutter: CGFloat = ChartStyle.priceGutter
    var topInset: CGFloat = ChartStyle.plotTopInset
    var axisHeight: CGFloat = ChartStyle.timeAxisHeight

    var plotWidth: CGFloat { max(1, size.width - gutter) }
    var top: CGFloat { topInset }
    var bottom: CGFloat { max(topInset + 1, size.height - axisHeight) }
    var height: CGFloat { bottom - top }
    var axisBaseline: CGFloat { size.height - 2 }
}

// MARK: - Canvas helpers

extension GraphicsContext {
    func strokeLine(from start: CGPoint, to end: CGPoint, color: Color,
                    width: CGFloat = 1, dash: [CGFloat] = []) {
        var path = Path()
        path.move(to: start)
        path.addLine(to: end)
        stroke(path, with: .color(color), style: StrokeStyle(lineWidth: width, dash: dash))
    }

    func drawText(_ string: String, font: Font, color: Color,
                  at point: CGPoint, anchor: UnitPoint) {
        draw(Text(string).font(font).foregroundStyle(color), at: point, anchor: anchor)
    }

    /// A filled label pinned to the right-hand price axis — the way every
    /// trading terminal marks the last price and the crosshair price.
    func drawPriceTag(_ string: String, y: CGFloat, geometry: PlotGeometry,
                      fill: Color, text: Color = .white) {
        let rect = CGRect(x: geometry.plotWidth + 2, y: y - 8,
                          width: geometry.gutter - 4, height: 16)
        self.fill(Path(roundedRect: rect, cornerRadius: 3.5), with: .color(fill))
        drawText(string, font: ChartStyle.tagFont, color: text,
                 at: CGPoint(x: rect.midX, y: rect.midY), anchor: .center)
    }

    /// A label pinned to the bottom time axis, clamped inside the plot.
    func drawTimeTag(_ string: String, x: CGFloat, geometry: PlotGeometry,
                     fill: Color, text: Color = .white) {
        let width = max(34, CGFloat(string.count) * 5.6 + 8)
        let clamped = min(max(x, width / 2), geometry.plotWidth - width / 2)
        let rect = CGRect(x: clamped - width / 2, y: geometry.bottom + 1,
                          width: width, height: ChartStyle.timeAxisHeight - 1)
        self.fill(Path(roundedRect: rect, cornerRadius: 3.5), with: .color(fill))
        drawText(string, font: ChartStyle.tagFont, color: text,
                 at: CGPoint(x: rect.midX, y: rect.midY), anchor: .center)
    }
}

extension Path {
    /// Horizontal dashed line helper for Canvas drawing.
    static func dashedHorizontal(y: CGFloat, from x0: CGFloat, to x1: CGFloat,
                                 dash: CGFloat = 3.5, gap: CGFloat = 3) -> Path {
        var path = Path()
        var x = x0
        while x < x1 {
            path.move(to: CGPoint(x: x, y: y))
            path.addLine(to: CGPoint(x: min(x + dash, x1), y: y))
            x += dash + gap
        }
        return path
    }
}

// MARK: - Shared chrome

/// Shared empty-state for all charts.
struct ChartPlaceholder: View {
    let text: String
    var body: some View {
        VStack(spacing: 6) {
            ProgressView().controlSize(.small)
            Text(text).font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Small "loading" chip laid over a chart that is showing stale data.
struct ChartLoadingBadge: View {
    let text: String
    var body: some View {
        HStack(spacing: 4) {
            ProgressView().controlSize(.small).scaleEffect(0.6)
            Text(text).font(.system(size: 9, weight: .medium))
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(.regularMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(Color.primary.opacity(0.08)))
    }
}
