import SwiftUI
import MayStockKit

// MARK: - Cards & sections

/// A titled content card. The title row is optional so the same chrome serves
/// a bare block; the trailing slot takes a control or a status chip.
struct Card<Content: View, Trailing: View>: View {
    var title: String? = nil
    var subtitle: String? = nil
    @ViewBuilder var trailing: () -> Trailing
    @ViewBuilder var content: () -> Content

    init(title: String? = nil, subtitle: String? = nil,
         @ViewBuilder trailing: @escaping () -> Trailing,
         @ViewBuilder content: @escaping () -> Content) {
        self.title = title
        self.subtitle = subtitle
        self.trailing = trailing
        self.content = content
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if title != nil || subtitle != nil {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    VStack(alignment: .leading, spacing: 2) {
                        if let title { Text(title).font(Theme.Text.heading) }
                        if let subtitle {
                            Text(subtitle).font(Theme.Text.caption).foregroundStyle(.secondary)
                        }
                    }
                    Spacer(minLength: 8)
                    trailing()
                }
            }
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardStyle()
    }
}

extension Card where Trailing == EmptyView {
    init(title: String? = nil, subtitle: String? = nil,
         @ViewBuilder content: @escaping () -> Content) {
        self.init(title: title, subtitle: subtitle, trailing: { EmptyView() }, content: content)
    }
}

/// The heading row at the top of every terminal page.
struct PageHeader<Trailing: View>: View {
    let title: String
    var subtitle: String? = nil
    @ViewBuilder var trailing: () -> Trailing

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(Theme.Text.title)
                if let subtitle {
                    Text(subtitle).font(Theme.Text.secondary).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 12)
            trailing()
        }
    }
}

extension PageHeader where Trailing == EmptyView {
    init(title: String, subtitle: String? = nil) {
        self.init(title: title, subtitle: subtitle, trailing: { EmptyView() })
    }
}

// MARK: - Figures

/// A labelled figure: the building block of every overview row.
struct StatTile: View {
    let label: String
    let value: String
    var tint: Color = .primary
    var caption: String? = nil
    var captionTint: Color = .secondary
    var help: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(Theme.Text.caption).foregroundStyle(.secondary)
            Text(value)
                .font(Theme.Text.number).numeric()
                .foregroundStyle(tint)
                .lineLimit(1).minimumScaleFactor(0.7)
                .contentTransition(.numericText())
            if let caption {
                Text(caption)
                    .font(Theme.Text.caption).foregroundStyle(captionTint)
                    .lineLimit(2)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .rowStyle(padding: 10)
        .help(help ?? "")
    }
}

/// One `label: value` line, for compact key/value blocks.
struct KeyValueRow: View {
    let label: String
    let value: String
    var tint: Color = .primary
    var mono = false

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(label).font(Theme.Text.secondary).foregroundStyle(.secondary)
            Spacer(minLength: 8)
            Text(value)
                .font(mono ? Theme.Text.mono : Theme.Text.secondaryMedium).numeric()
                .foregroundStyle(tint)
                .multilineTextAlignment(.trailing)
                .textSelection(.enabled)
        }
    }
}

// MARK: - Badges & notices

struct Badge: View {
    enum Size { case small, regular }

    let text: String
    var tint: Color = .secondary
    var icon: String? = nil
    var size: Size = .regular
    var filled = false

    var body: some View {
        HStack(spacing: 3) {
            if let icon { Image(systemName: icon).font(.system(size: size == .small ? 8 : 9, weight: .bold)) }
            Text(text)
                .font(.system(size: size == .small ? 9 : 10, weight: .bold))
        }
        .padding(.horizontal, size == .small ? 5 : 7)
        .padding(.vertical, size == .small ? 2 : 3)
        .background(filled ? tint : tint.opacity(0.16), in: Capsule())
        .foregroundStyle(filled ? Color.white : tint)
        .fixedSize()
    }
}

/// DEMO / LIVE, in the mode's colour everywhere.
struct ModeBadge: View {
    let mode: TradingMode
    var size: Badge.Size = .regular
    var filled = false

    var body: some View {
        Badge(text: mode.badge, tint: Theme.mode(mode), size: size, filled: filled)
            .help(mode.isDemo ? "当前为 OKX 模拟盘" : "当前为实盘，订单会真实成交")
    }
}

struct StatusDot: View {
    let color: Color
    var size: CGFloat = 7

    var body: some View {
        Circle().fill(color).frame(width: size, height: size)
    }
}

/// A message that changes what the reader should do next: an outage, a
/// tripped breaker, a connection that failed. Never decorative.
struct InlineNotice: View {
    enum Kind { case info, success, warning, danger }

    let kind: Kind
    var title: String? = nil
    let message: String
    var actionTitle: String? = nil
    var action: (() -> Void)? = nil

    private var tint: Color {
        switch kind {
        case .info: return .secondary
        case .success: return Theme.up
        case .warning: return Theme.warning
        case .danger: return Theme.down
        }
    }

    private var icon: String {
        switch kind {
        case .info: return "info.circle.fill"
        case .success: return "checkmark.circle.fill"
        case .warning: return "exclamationmark.triangle.fill"
        case .danger: return "exclamationmark.octagon.fill"
        }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: icon).font(.system(size: 12)).foregroundStyle(tint).padding(.top, 1)
            VStack(alignment: .leading, spacing: 2) {
                if let title { Text(title).font(Theme.Text.bodyMedium).foregroundStyle(tint) }
                Text(message)
                    .font(Theme.Text.secondary)
                    .foregroundStyle(kind == .info ? Color.secondary : Color.primary)
                    .textSelection(.enabled)
            }
            Spacer(minLength: 0)
            if let actionTitle, let action {
                Button(actionTitle, action: action).controlSize(.small)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(tint.opacity(kind == .info ? 0.06 : 0.10),
                    in: RoundedRectangle(cornerRadius: Theme.rowRadius, style: .continuous))
    }
}

struct EmptyState: View {
    let icon: String
    let title: String
    var message: String? = nil
    var actionTitle: String? = nil
    var action: (() -> Void)? = nil

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: icon).font(.system(size: 30)).foregroundStyle(.tertiary)
            Text(title).font(Theme.Text.heading)
            if let message {
                Text(message).font(Theme.Text.secondary).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 360)
            }
            if let actionTitle, let action {
                Button(actionTitle, action: action).controlSize(.small).padding(.top, 4)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(30)
    }
}

// MARK: - Tables

/// A column of a `DataGrid`. Sizing is decided by the cells (see `GridText`);
/// the header only names the column.
struct GridColumn {
    let title: String
    var alignment: HorizontalAlignment = .leading
}

/// Header + rows laid out with SwiftUI's `Grid`, so columns align without
/// fixed widths and without the sizing fights a `Table` picks inside a
/// scrolling page.
struct DataGrid<Row: Identifiable, Cells: View>: View {
    let columns: [GridColumn]
    let rows: [Row]
    var emptyText = "暂无数据"
    @ViewBuilder var cells: (Row) -> Cells

    var body: some View {
        if rows.isEmpty {
            Text(emptyText).font(Theme.Text.secondary).foregroundStyle(.tertiary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 6)
        } else {
            Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 0) {
                GridRow {
                    ForEach(Array(columns.enumerated()), id: \.offset) { _, column in
                        Text(column.title)
                            .font(Theme.Text.captionMedium)
                            .foregroundStyle(.secondary)
                            .fixedSize()
                            .gridColumnAlignment(column.alignment)
                    }
                }
                .padding(.vertical, 5)
                Divider()
                ForEach(rows) { row in
                    GridRow { cells(row) }
                        .padding(.vertical, 6)
                    Divider().opacity(0.4)
                }
            }
        }
    }
}

/// A grid cell with the standard table typography.
///
/// Column widths follow from the cells: a right-aligned cell is a number and
/// takes exactly the width it needs, as does a cell marked `fit` (a side, an
/// action, a currency). Everything else is free text and shares the width
/// that is left, truncating in the middle when it must. Equal shares for all
/// columns — the previous rule — spent a name's room on a two-character side.
struct GridText: View {
    let text: String
    var tint: Color = .primary
    var mono = false
    var alignment: HorizontalAlignment = .leading
    var weight: Font.Weight = .regular
    var fit = false

    init(_ text: String, tint: Color = .primary, mono: Bool = false,
         alignment: HorizontalAlignment = .leading, weight: Font.Weight = .regular, fit: Bool = false) {
        self.text = text
        self.tint = tint
        self.mono = mono
        self.alignment = alignment
        self.weight = weight
        self.fit = fit
    }

    private var fitsContent: Bool { fit || alignment == .trailing }

    var body: some View {
        let label = Text(text)
            .font(mono ? Theme.Text.mono : .system(size: 11, weight: weight)).numeric()
            .foregroundStyle(tint)
            .lineLimit(1).truncationMode(.middle)
        if fitsContent {
            label
                .fixedSize()
                .gridColumnAlignment(alignment)
        } else {
            label
                .frame(maxWidth: .infinity, alignment: Alignment(horizontal: alignment, vertical: .center))
                .gridColumnAlignment(alignment)
        }
    }
}

// MARK: - Controls

/// A compact segmented switch drawn in the app's own style, so the chart
/// filters, the mode switch and the tab strips read as one family.
struct PillSegments<Value: Hashable>: View {
    struct Segment: Identifiable {
        let value: Value
        let title: String
        var tint: Color? = nil
        var icon: String? = nil
        var help: String? = nil
        var enabled = true
        var id: Value { value }
    }

    let segments: [Segment]
    let selection: Value
    var size: CGFloat = 11
    let onSelect: (Value) -> Void

    @Namespace private var pill

    var body: some View {
        HStack(spacing: 2) {
            ForEach(segments) { segment in
                let selected = segment.value == selection
                let tint = segment.tint ?? Color.primary
                HStack(spacing: 4) {
                    if let icon = segment.icon {
                        Image(systemName: icon).font(.system(size: size - 2, weight: .semibold))
                    }
                    Text(segment.title)
                        .font(.system(size: size, weight: selected ? .semibold : .medium))
                }
                .numeric()
                .foregroundStyle(selected ? (segment.tint == nil ? Color.primary : Color.white)
                                 : (segment.enabled ? Color.secondary : Color.secondary.opacity(0.5)))
                .lineLimit(1).fixedSize()
                .padding(.horizontal, 9).padding(.vertical, 4)
                .background {
                    if selected {
                        Capsule(style: .continuous)
                            .fill(segment.tint == nil ? Color.primary.opacity(0.12) : tint)
                            .matchedGeometryEffect(id: "pill", in: pill)
                    }
                }
                .contentShape(Capsule())
                .onTapGesture {
                    guard segment.enabled, !selected else { return }
                    onSelect(segment.value)
                }
                .help(segment.help ?? segment.title)
            }
        }
        .padding(2)
        .background(Capsule(style: .continuous).fill(Color.primary.opacity(0.05)))
        .overlay(Capsule(style: .continuous).strokeBorder(Color.primary.opacity(0.05)))
        .animation(.snappy(duration: 0.18), value: selection)
    }
}

/// A text field that commits on focus loss or return, showing the model value
/// while not being edited. Numbers everywhere are edited through this so the
/// half-typed text never reaches the model.
struct CommitTextField: View {
    let placeholder: String
    let value: String
    var width: CGFloat? = 90
    var mono = true
    var alignment: TextAlignment = .trailing
    let onCommit: (String) -> Void

    @State private var text = ""
    @State private var editing = false

    var body: some View {
        TextField(placeholder, text: Binding(
            get: { editing ? text : value },
            set: { text = $0 }
        ), onEditingChanged: { began in
            editing = began
            if began {
                text = value
            } else if text != value {
                onCommit(text)
            }
        })
        .textFieldStyle(.roundedBorder)
        .font(mono ? .system(size: 12).monospacedDigit() : .system(size: 12))
        .multilineTextAlignment(alignment)
        .frame(width: width)
        .onSubmit {
            if text != value { onCommit(text) }
            editing = false
        }
    }
}

/// Rounded, tinted button used for the two or three primary actions on a page.
struct ProminentButtonStyle: ButtonStyle {
    var tint: Color = Theme.accent
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(Theme.Text.bodyMedium)
            .foregroundStyle(.white)
            .padding(.horizontal, 12).padding(.vertical, 6)
            .background(tint.opacity(configuration.isPressed ? 0.75 : 1),
                        in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            .opacity(isEnabled ? 1 : 0.4)
    }
}

// MARK: - Formatting helpers shared by the views

enum Format {
    static func money(_ value: Double?, decimals: Int = 2) -> String {
        value.map { PriceFormatter.money($0, decimals: decimals) } ?? "—"
    }

    static func signedMoney(_ value: Double?, decimals: Int = 2) -> String {
        value.map { PriceFormatter.signedMoney($0, decimals: decimals) } ?? "—"
    }

    static func signedPercent(_ value: Double?) -> String {
        value.map(PriceFormatter.signedPercent) ?? "—"
    }

    static func clock(_ date: Date?) -> String {
        date?.formatted(date: .omitted, time: .standard) ?? "—"
    }

    static func shortDate(_ date: Date?) -> String {
        date?.formatted(date: .abbreviated, time: .shortened) ?? "—"
    }

    /// `09-07 21:58` — the width a table column can afford.
    static func stamp(_ date: Date) -> String {
        ChartFormatters.string(date, "MM-dd HH:mm")
    }

    static func relative(_ date: Date?, now: Date = Date()) -> String {
        guard let date else { return "从未" }
        let seconds = now.timeIntervalSince(date)
        if seconds < 60 { return "刚刚" }
        if seconds < 3_600 { return "\(Int(seconds / 60)) 分钟前" }
        if seconds < 86_400 { return "\(Int(seconds / 3_600)) 小时前" }
        return "\(Int(seconds / 86_400)) 天前"
    }

    static func duration(_ seconds: TimeInterval) -> String {
        AccountEquityCurve.describe(seconds)
    }
}


// MARK: - Scrolling

/// True while the snapshot renderer is drawing. The renderer captures a real
/// window's layers, and an `NSScrollView` whose document overflows captures
/// as black — so in this mode pages lay out at full height inside a tall
/// window instead of scrolling.
private struct SnapshotModeKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    var snapshotMode: Bool {
        get { self[SnapshotModeKey.self] }
        set { self[SnapshotModeKey.self] = newValue }
    }
}

/// The page-level scroll container. A plain stack while a snapshot is being
/// drawn; see `snapshotMode`.
struct PageScroll<Content: View>: View {
    @Environment(\.snapshotMode) private var snapshotMode
    @ViewBuilder var content: () -> Content

    var body: some View {
        if snapshotMode {
            VStack(spacing: 0) {
                content()
                Spacer(minLength: 0)
            }
        } else {
            ScrollView { content() }
        }
    }
}
