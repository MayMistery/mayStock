import SwiftUI

/// Single source of truth for chart aesthetics — light/dark adaptive.
enum ChartStyle {
    static let up = Color(nsColor: .systemGreen)
    static let down = Color(nsColor: .systemRed)
    static let accent = Color(nsColor: .controlAccentColor)
    static let ma = Color(nsColor: .systemOrange)
    static let grid = Color.primary.opacity(0.07)
    static let axisLabel = Color.secondary
    static let crosshair = Color.primary.opacity(0.35)

    static func trend(_ isUp: Bool) -> Color { isUp ? up : down }

    static let axisFont = Font.system(size: 9, design: .monospaced)
    static let readoutFont = Font.system(size: 10, design: .monospaced)

    /// Nice-looking axis step so gridlines land on round prices.
    static func niceStep(range: Double, target: Int = 4) -> Double {
        guard range > 0, target > 0 else { return 1 }
        let rough = range / Double(target)
        let magnitude = pow(10, floor(log10(rough)))
        let normalized = rough / magnitude
        let nice: Double = normalized < 1.5 ? 1 : normalized < 3.5 ? 2 : normalized < 7.5 ? 5 : 10
        return nice * magnitude
    }
}

extension Path {
    /// Horizontal dashed line helper for Canvas drawing.
    static func dashedHorizontal(y: CGFloat, from x0: CGFloat, to x1: CGFloat, dash: CGFloat = 3.5, gap: CGFloat = 3) -> Path {
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
