import Foundation

/// Consistent, locale-stable price formatting across menu bar, panel and CLI.
public enum PriceFormatter {
    /// "118234.5" → "118,234.5" with a fixed number of fraction digits.
    public static func price(_ value: Double, decimals: Int) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.usesGroupingSeparator = true
        formatter.minimumFractionDigits = decimals
        formatter.maximumFractionDigits = decimals
        formatter.roundingMode = .halfUp
        return formatter.string(from: NSNumber(value: value)) ?? String(value)
    }

    /// Sensible default decimals when exchange metadata is unavailable.
    public static func autoDecimals(for value: Double) -> Int {
        switch abs(value) {
        case 10_000...: return 0
        case 1_000...: return 1
        case 10...: return 2
        case 0.1...: return 4
        default: return 6
        }
    }

    public static func auto(_ value: Double) -> String {
        price(value, decimals: autoDecimals(for: value))
    }

    /// Minimal representation without grouping: 5.0 → "5", 5.25 → "5.25".
    public static func plain(_ value: Double) -> String {
        if value == value.rounded(), abs(value) < 1e15 {
            return String(Int(value))
        }
        var s = String(format: "%.6f", value)
        while s.hasSuffix("0") { s.removeLast() }
        if s.hasSuffix(".") { s.removeLast() }
        return s
    }

    /// Signed percent: 1.234 → "+1.23%".
    public static func signedPercent(_ value: Double) -> String {
        String(format: "%@%.2f%%", value >= 0 ? "+" : "", value)
    }

    /// Compact volume: 12_400 → "12.4K".
    public static func compact(_ value: Double) -> String {
        let v = abs(value)
        switch v {
        case 1_000_000_000...: return String(format: "%.2fB", value / 1_000_000_000)
        case 1_000_000...: return String(format: "%.2fM", value / 1_000_000)
        case 10_000...: return String(format: "%.1fK", value / 1_000)
        case 1_000...: return String(format: "%.2fK", value / 1_000)
        default: return plain((value * 100).rounded() / 100)
        }
    }
}
