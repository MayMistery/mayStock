import SwiftUI

/// One cell of the legend strip above the chart.
struct ChartLegendItem: Equatable, Hashable, Sendable, Identifiable {
    enum Tint: Equatable, Hashable, Sendable {
        case primary, secondary, up, down, accent, ma

        var color: Color {
            switch self {
            case .primary: return .primary
            case .secondary: return .secondary
            case .up: return ChartStyle.up
            case .down: return ChartStyle.down
            case .accent: return ChartStyle.accent
            case .ma: return ChartStyle.ma
            }
        }
    }

    let key: String
    var label: String? = nil
    let value: String
    var tint: Tint = .primary
    /// Higher survives when the row runs out of width. A BTC price is 9
    /// characters and an altcoin price 10, so no fixed field set fits every
    /// instrument — the row drops its least important cells instead.
    var priority: Double = 0

    var id: String { key }

    static func trend(_ key: String, label: String? = nil, value: String,
                      isUp: Bool, priority: Double = 0) -> Self {
        ChartLegendItem(key: key, label: label, value: value,
                        tint: isUp ? .up : .down, priority: priority)
    }
}

/// Charts publish their legend upward so it can live in a dedicated row
/// instead of floating over the plot and hiding the very bars being read.
///
/// The payload is optional rather than a bare array: siblings that set no
/// legend contribute `nil` and must not win the reduction, while a chart that
/// deliberately publishes *nothing* (a loading placeholder) still has to clear
/// whatever the previous chart left in the row.
struct ChartLegendPayload: Equatable, Sendable {
    var items: [ChartLegendItem]?
}

struct ChartLegendKey: PreferenceKey {
    static let defaultValue = ChartLegendPayload(items: nil)
    static func reduce(value: inout ChartLegendPayload, nextValue: () -> ChartLegendPayload) {
        if let next = nextValue().items { value.items = next }
    }
}

extension View {
    func chartLegend(_ items: [ChartLegendItem]) -> some View {
        preference(key: ChartLegendKey.self, value: ChartLegendPayload(items: items))
    }
}

/// The legend strip: one monospaced line that shows as many cells as the width
/// allows, dropping the least important ones rather than truncating or
/// clipping. Visual order is always the order the chart supplied.
struct ChartLegendRow: View {
    let items: [ChartLegendItem]

    var body: some View {
        ViewThatFits(in: .horizontal) {
            row(keeping: items.count)
            row(keeping: items.count - 1)
            row(keeping: items.count - 2)
            row(keeping: items.count - 3)
            row(keeping: 3)
            row(keeping: 2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(height: 12)
        .animation(nil, value: items) // values change every tick; never animate text
    }

    /// The `count` most important cells, back in their original order.
    private func subset(_ count: Int) -> [ChartLegendItem] {
        guard count < items.count else { return items }
        guard count > 0 else { return [] }
        let survivors = Set(
            items.enumerated()
                .sorted { ($0.element.priority, -Double($0.offset)) > ($1.element.priority, -Double($1.offset)) }
                .prefix(count)
                .map(\.offset))
        return items.enumerated().filter { survivors.contains($0.offset) }.map(\.element)
    }

    /// No `Spacer` here: `ViewThatFits` measures each candidate's ideal width,
    /// and a flexible spacer would make every candidate "fit".
    private func row(keeping count: Int) -> some View {
        HStack(spacing: 7) {
            ForEach(subset(count)) { item in
                HStack(spacing: 2.5) {
                    if let label = item.label {
                        Text(label).foregroundStyle(.tertiary)
                    }
                    Text(item.value).foregroundStyle(item.tint.color)
                }
                .fixedSize()
            }
        }
        .font(ChartStyle.legendFont)
        .monospacedDigit()
        .lineLimit(1)
    }
}
