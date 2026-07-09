import AppKit
import MayStockKit

/// Renders the tiny menu bar sparkline as a crisp Retina NSImage.
@MainActor
enum SparklineRenderer {
    static let size = NSSize(width: 46, height: 15)

    /// Downsample + draw. Color follows the window trend (green/red).
    static func image(points: [SparkPoint], emphasizeLast: Bool = true) -> NSImage? {
        guard points.count >= 2 else { return nil }
        let prices = downsample(points.map(\.price), to: 60)
        guard let min = prices.min(), let max = prices.max() else { return nil }
        let isUp = (prices.last ?? 0) >= (prices.first ?? 0)
        let color: NSColor = isUp ? .systemGreen : .systemRed

        let size = Self.size
        return NSImage(size: size, flipped: false) { rect in
            let range = Swift.max(max - min, Swift.max(max.magnitude * 1e-6, .leastNonzeroMagnitude))
            let insetTop: CGFloat = 1.5, insetBottom: CGFloat = 1.5

            func point(_ i: Int) -> NSPoint {
                let x = rect.width * CGFloat(i) / CGFloat(prices.count - 1)
                let normalized = CGFloat((prices[i] - min) / range)
                let y = insetBottom + normalized * (rect.height - insetTop - insetBottom)
                return NSPoint(x: x, y: y)
            }

            // Area fill.
            let area = NSBezierPath()
            area.move(to: NSPoint(x: 0, y: 0))
            for i in 0..<prices.count { area.line(to: point(i)) }
            area.line(to: NSPoint(x: rect.width, y: 0))
            area.close()
            let gradient = NSGradient(
                starting: color.withAlphaComponent(0.30),
                ending: color.withAlphaComponent(0.03))
            gradient?.draw(in: area, angle: -90)

            // Line.
            let line = NSBezierPath()
            line.lineWidth = 1.2
            line.lineJoinStyle = .round
            line.lineCapStyle = .round
            line.move(to: point(0))
            for i in 1..<prices.count { line.line(to: point(i)) }
            color.setStroke()
            line.stroke()

            // Last-price dot.
            if emphasizeLast {
                let last = point(prices.count - 1)
                let dot = NSBezierPath(ovalIn: NSRect(x: last.x - 1.8, y: last.y - 1.8, width: 3.6, height: 3.6))
                color.setFill()
                dot.fill()
            }
            return true
        }
    }

    /// Largest-triangle-ish downsampling: keep shape with few points.
    static func downsample(_ values: [Double], to target: Int) -> [Double] {
        guard values.count > target, target > 2 else { return values }
        var result: [Double] = [values[0]]
        let bucketSize = Double(values.count - 2) / Double(target - 2)
        for bucket in 0..<(target - 2) {
            let start = Int(Double(bucket) * bucketSize) + 1
            let end = Swift.min(Int(Double(bucket + 1) * bucketSize) + 1, values.count - 1)
            guard start < end else { continue }
            let slice = values[start..<end]
            // Keep the extreme farthest from the bucket mean (preserves spikes).
            let mean = slice.reduce(0, +) / Double(slice.count)
            if let extreme = slice.max(by: { abs($0 - mean) < abs($1 - mean) }) {
                result.append(extreme)
            }
        }
        result.append(values[values.count - 1])
        return result
    }
}
