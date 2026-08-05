import SwiftUI
import MayStockKit

/// Which chart the panel is showing.
enum ChartMode: String, CaseIterable, Identifiable, Hashable {
    case line = "折线"
    case candles = "K线"
    case depth = "深度"

    var id: String { rawValue }
    var title: String { rawValue }

    var help: String {
        switch self {
        case .line: return "逐笔价格折线"
        case .candles: return "K 线 + 成交量"
        case .depth: return "盘口深度"
        }
    }

    static var segments: [FilterSegment<ChartMode>] {
        allCases.map { FilterSegment(value: $0, title: $0.title, help: $0.help) }
    }
}

/// Chart choices that outlive a single hover: kept in `AppState` so switching
/// instruments — or re-opening the panel — does not silently reset the view
/// the user picked.
@Observable
@MainActor
final class ChartPreferences {
    var mode: ChartMode = .candles
    var lineWindow: LineWindow = .h1
    var depthZoom: DepthZoom = .bp5
}

/// One option of a `SegmentedFilter`.
struct FilterSegment<Value: Hashable>: Identifiable {
    let value: Value
    let title: String
    var help: String? = nil
    var id: Value { value }
}

/// Compact segmented control with a sliding selection pill.
///
/// Replaces the mismatched `.segmented` + `.menu` pickers the panel used to
/// mix: the chart mode and its filter now read as one control family, and the
/// selected interval is always visible rather than hidden behind a menu.
struct SegmentedFilter<Value: Hashable>: View {
    let segments: [FilterSegment<Value>]
    @Binding var selection: Value
    var minSegmentWidth: CGFloat = 0

    @Namespace private var pill

    var body: some View {
        HStack(spacing: 1) {
            ForEach(segments) { segment in
                let isSelected = segment.value == selection
                Text(segment.title)
                    .font(.system(size: 9.5, weight: isSelected ? .semibold : .medium))
                    .monospacedDigit()
                    .foregroundStyle(isSelected ? Color.primary : Color.secondary)
                    .lineLimit(1)
                    .fixedSize()
                    .frame(minWidth: minSegmentWidth)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 3)
                    .background {
                        if isSelected {
                            Capsule(style: .continuous)
                                .fill(Color.primary.opacity(0.11))
                                .matchedGeometryEffect(id: "selection", in: pill)
                        }
                    }
                    .contentShape(Capsule())
                    .onTapGesture {
                        guard segment.value != selection else { return }
                        withAnimation(.snappy(duration: 0.18)) { selection = segment.value }
                    }
                    .help(segment.help ?? segment.title)
            }
        }
        .padding(2)
        .background(Capsule(style: .continuous).fill(Color.primary.opacity(0.045)))
        .overlay(Capsule(style: .continuous).strokeBorder(Color.primary.opacity(0.05)))
    }
}

// MARK: - Domain filters

/// Trailing window of the tick-level line chart.
enum LineWindow: Int, CaseIterable, Identifiable, Hashable {
    case m5 = 5
    case m15 = 15
    case h1 = 60
    case h4 = 240
    case d1 = 1_440

    var id: Int { rawValue }
    var minutes: Int { rawValue }
    var seconds: TimeInterval { TimeInterval(rawValue) * 60 }

    var title: String {
        switch self {
        case .m5: return "5m"
        case .m15: return "15m"
        case .h1: return "1H"
        case .h4: return "4H"
        case .d1: return "1D"
        }
    }

    var help: String {
        switch self {
        case .m5: return "最近 5 分钟"
        case .m15: return "最近 15 分钟"
        case .h1: return "最近 1 小时"
        case .h4: return "最近 4 小时"
        case .d1: return "最近 24 小时"
        }
    }

    static var segments: [FilterSegment<LineWindow>] {
        allCases.map { FilterSegment(value: $0, title: $0.title, help: $0.help) }
    }
}

/// Price window of the depth chart, as a ± distance from mid in basis points.
///
/// The ladder is in bp rather than whole percent because a 400-level snapshot
/// of a liquid pair only reaches ~12bp from mid — a ±0.5%/±1% ladder would
/// clamp every rung to the same picture.
enum DepthZoom: String, CaseIterable, Identifiable, Hashable {
    case bp2, bp5, bp10, bp25, full

    var id: String { rawValue }

    /// Half-window in basis points of mid; `nil` means the whole book.
    var bps: Double? {
        switch self {
        case .bp2: return 2
        case .bp5: return 5
        case .bp10: return 10
        case .bp25: return 25
        case .full: return nil
        }
    }

    /// Half-window as a percentage of mid, the unit `OrderBook.profile` takes.
    var pct: Double? { bps.map { $0 / 100 } }

    var title: String {
        switch self {
        case .full: return "全部"
        default: return "\(Int(bps ?? 0))bp"
        }
    }

    var help: String {
        switch self {
        case .full: return "整个快照深度（约 400 档）"
        default: return "中间价 ±\(Int(bps ?? 0)) 个基点"
        }
    }

    static var segments: [FilterSegment<DepthZoom>] {
        allCases.map { FilterSegment(value: $0, title: $0.title, help: $0.help) }
    }
}

extension BarInterval {
    var title: String { rawValue }

    var help: String {
        switch self {
        case .m1: return "1 分钟 K 线"
        case .m5: return "5 分钟 K 线"
        case .m15: return "15 分钟 K 线"
        case .h1: return "1 小时 K 线"
        case .h4: return "4 小时 K 线"
        case .d1: return "日 K 线"
        case .w1: return "周 K 线"
        }
    }

    static var segments: [FilterSegment<BarInterval>] {
        allCases.map { FilterSegment(value: $0, title: $0.title, help: $0.help) }
    }
}
