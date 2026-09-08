import SwiftUI
import MayStockKit

/// The terminal's calendar and evidence trail. Nothing is seeded as live news:
/// every visible event and judgment comes from a persisted, validated report.
struct IntelligencePage: View {
    let appState: AppState
    @State private var selectedDay = Date()
    @State private var showSettings = false
    @State private var reportKind: IntelligenceKind = .daily
    @State private var analysisKind: IntelligenceKind?

    private var center: IntelligenceCenter { appState.intelligence }
    private var calendar: Calendar { IntelligenceCalendar.calendar(timezone: center.settings.timezone) }
    private var watchlist: [String] { Array(Set(appState.store.config.watchlist.map(\.instId))).sorted() }

    var body: some View {
        TimelineView(.periodic(from: .now, by: 60)) { context in
            PageScroll {
                VStack(alignment: .leading, spacing: Theme.sectionSpacing) {
                    header
                    notices
                    HStack(alignment: .top, spacing: Theme.itemSpacing) {
                        ForEach(IntelligenceKind.allCases, id: \.self) { kind in
                            jobCard(kind, now: context.date)
                        }
                    }
                    marketAnalysisCard(now: context.date)
                    predictionsCard(now: context.date)
                    calendarCard(now: context.date)
                    dayCard
                    reportsCard(now: context.date)
                }
                .padding(Theme.pagePadding)
            }
        }
        .sheet(isPresented: $showSettings) {
            IntelligenceSettingsSheet(center: center)
        }
    }

    private var header: some View {
        PageHeader(title: "情报站", subtitle: "美股 · 加密货币 · 宏观政策 · 全球局势") {
            if center.isRunning {
                ProgressView().controlSize(.small)
                Text((center.activeKind?.label ?? "情报") + "更新中")
                    .font(Theme.Text.caption).foregroundStyle(.secondary)
            }
            Button { showSettings = true } label: {
                Label("生成计划", systemImage: "clock")
            }
            .controlSize(.small)
            Menu {
                ForEach(IntelligenceKind.allCases, id: \.self) { kind in
                    Button("立即" + kind.actionLabel) { center.refresh(kind) }
                }
            } label: {
                Label("更新", systemImage: "arrow.clockwise")
            }
            .controlSize(.small)
            .fixedSize()
            .disabled(center.isRunning)
        }
    }

    @ViewBuilder
    private var notices: some View {
        if let error = center.error {
            InlineNotice(kind: .warning, title: "情报更新失败", message: error)
        }
        if !center.settings.enabled {
            InlineNotice(kind: .info, title: "自动更新已暂停", message: "已有报告继续保留，可通过右上角手动更新。")
        }
    }

    private func jobCard(_ kind: IntelligenceKind, now: Date) -> some View {
        let status = center.statuses[kind]
        let running = center.isRunning && center.activeKind == kind
        let partial = status?.coverageComplete == false
        let stale = status?.lastSuccessAt.map { now.timeIntervalSince($0) > kind.staleInterval } ?? false
        return VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 5) {
                Image(systemName: kind.icon).foregroundStyle(.secondary)
                Text(kind.label).font(Theme.Text.heading)
                Spacer(minLength: 4)
                StatusDot(color: running ? Theme.accent : status?.error != nil ? Theme.warning :
                            partial ? Theme.warning : stale ? Theme.warning : status?.lastSuccessAt == nil ? .secondary : Theme.up)
                Text(running ? "检索中" : status?.error != nil ? "失败" : partial ? "覆盖不全" : stale ? "待更新" :
                        status?.lastSuccessAt == nil ? "待首次生成" : "已检查")
                    .font(Theme.Text.caption).foregroundStyle(.secondary)
            }
            Text(kind == .daily ? String(format: "每日 %02d:00", center.settings.dailyHour) : kind.cadence)
                .font(Theme.Text.captionMedium).foregroundStyle(.secondary)
            Text(status?.lastSuccessAt.map { "上次完成 " + stamp($0, format: "MM/dd HH:mm") } ?? "尚无完成的检查")
                .font(Theme.Text.caption).foregroundStyle(.secondary)
            Text(center.settings.enabled
                 ? status?.nextRunAt.map { "下次 " + stamp($0, format: "MM/dd HH:mm") } ?? "等待调度"
                 : "自动更新暂停")
                .font(Theme.Text.caption).foregroundStyle(.tertiary)
            if let message = status?.error, !message.isEmpty {
                Text(message).font(Theme.Text.caption).foregroundStyle(Theme.warning).lineLimit(2)
                    .help(message)
            } else if let note = status?.note, !note.isEmpty {
                Text(note).font(Theme.Text.caption).foregroundStyle(.secondary).lineLimit(2)
                    .help(note)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 80, alignment: .topLeading)
        .cardStyle(padding: 12)
    }

    private func marketAnalysisCard(now: Date) -> some View {
        let latest = center.reports.filter { $0.kind != .flash }.max { $0.generatedAt < $1.generatedAt }
        let selectedKind = analysisKind ?? latest?.kind ?? .hourly
        let report = center.reports.filter { $0.kind == selectedKind }.max { $0.generatedAt < $1.generatedAt }
        return Card(title: "市场分析", subtitle: "最近一次完成的研究 · " + center.settings.timezone) {
            Picker("分析类型", selection: Binding(get: { selectedKind }, set: { analysisKind = $0 })) {
                Text("局势更新").tag(IntelligenceKind.hourly)
                Text("日报").tag(IntelligenceKind.daily)
            }
            .pickerStyle(.segmented).labelsHidden().frame(width: 170)
        } content: {
            if let report {
                VStack(alignment: .leading, spacing: 14) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        VStack(alignment: .leading, spacing: 5) {
                            Text(report.title).font(Theme.Text.heading).textSelection(.enabled)
                                .fixedSize(horizontal: false, vertical: true)
                            Text("生成 " + stamp(report.generatedAt) + " · 本次更新 " +
                                 stamp(report.windowStart, format: "MM/dd HH:mm") + " — " +
                                 stamp(report.windowEnd, format: "MM/dd HH:mm"))
                                .font(Theme.Text.caption).foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 4)
                        if now.timeIntervalSince(report.generatedAt) > report.kind.staleInterval {
                            Badge(text: "待更新", tint: Theme.warning, size: .small)
                        }
                        if report.coverageComplete == false {
                            Badge(text: "覆盖不全", tint: Theme.warning, size: .small)
                        }
                    }
                    IntelligenceAnalysisView(report: report, timezone: center.settings.timezone)
                }
            } else {
                EmptyState(icon: "text.magnifyingglass", title: "等待市场分析",
                           message: "研究完成后，会在这里展示行情变化、驱动因素、跨市场证据和仍待核实的问题。")
                    .frame(height: 150)
            }
        }
    }

    private func calendarCard(now: Date) -> some View {
        let days = IntelligenceCalendar.days(around: now, timezone: center.settings.timezone)
        let leading = days.first.map { IntelligenceCalendar.leadingDays(for: $0, timezone: center.settings.timezone) } ?? 0
        return Card(title: "事件日历", subtitle: calendarRange(days) + " · " + center.settings.timezone) {
            HStack(spacing: 8) {
                Badge(text: "重要", tint: Theme.warning, size: .small)
                Button("今天") { selectedDay = now }.controlSize(.small)
            }
        } content: {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 5), count: 7), spacing: 5) {
                ForEach(["周一", "周二", "周三", "周四", "周五", "周六", "周日"], id: \.self) { day in
                    Text(day).font(Theme.Text.captionMedium).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity).padding(.bottom, 3)
                }
                ForEach(0..<leading, id: \.self) { _ in
                    Color.clear.frame(height: 68).accessibilityHidden(true)
                }
                ForEach(days, id: \.self) { day in dayButton(day, today: now) }
            }
            Text("按事件发生或计划日期归档；快报只收录近 30 分钟内新发生且已核实的事件。")
                .font(Theme.Text.caption).foregroundStyle(.secondary)
        }
    }

    private func dayButton(_ day: Date, today: Date) -> some View {
        let events = events(on: day)
        let selected = calendar.isDate(day, inSameDayAs: selectedDay)
        let isToday = calendar.isDate(day, inSameDayAs: today)
        let monthStart = calendar.component(.day, from: day) == 1
        return Button { selectedDay = day } label: {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 3) {
                    Text(stamp(day, format: monthStart ? "M/d" : "d"))
                        .font(Theme.Text.secondaryMedium).numeric()
                    if isToday {
                        Text("今").font(Theme.Text.captionBold).foregroundStyle(Theme.accent)
                    }
                    Spacer(minLength: 0)
                    if !events.isEmpty {
                        Text("\(events.count)").font(Theme.Text.caption).foregroundStyle(.secondary)
                    }
                }
                if let event = events.first {
                    HStack(alignment: .top, spacing: 3) {
                        Circle().fill(importanceColor(event.importance)).frame(width: 4, height: 4).padding(.top, 4)
                        Text(event.title).font(Theme.Text.caption).lineLimit(2)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    Text("—").font(Theme.Text.caption).foregroundStyle(.tertiary)
                }
                Spacer(minLength: 0)
            }
            .padding(7)
            .frame(maxWidth: .infinity, minHeight: 68, maxHeight: 68, alignment: .topLeading)
            .background(selected ? Theme.selectedFill : Theme.rowFill,
                        in: RoundedRectangle(cornerRadius: Theme.rowRadius))
            .overlay(RoundedRectangle(cornerRadius: Theme.rowRadius)
                .strokeBorder(selected ? Theme.accent : isToday ? Theme.accent.opacity(0.35) : .clear,
                              lineWidth: 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(stamp(day, format: "yyyy年M月d日") + "，\(events.count) 个事件")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private var dayCard: some View {
        let dayEvents = events(on: selectedDay)
        return Card(title: stamp(selectedDay, format: "M月d日 EEEE"),
                    subtitle: "\(dayEvents.count) 个事件 · " + center.settings.timezone) {
            if dayEvents.isEmpty {
                EmptyState(icon: "calendar", title: center.events.isEmpty ? "等待建立事件日历" : "当天暂无已收录事件",
                           message: center.events.isEmpty
                           ? "日报完成后会展示过去 7 天与未来 30 天的重要事件、计划时间和来源。"
                           : "当前资料未收录这一天的事件，后续检查会继续补充。")
                    .frame(height: 150)
            } else {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(dayEvents) { event in
                        IntelligenceEventView(event: event, timezone: center.settings.timezone)
                        if event.id != dayEvents.last?.id { Divider() }
                    }
                }
            }
        }
    }

    private func predictionsCard(now: Date) -> some View {
        Card(title: "关注标的 · 方向研判", subtitle: "覆盖全部 \(watchlist.count) 支关注标的 · \(center.settings.timezone) · 置信度为模型判断，尚未经历史校准") {
            if watchlist.isEmpty {
                EmptyState(icon: "star", title: "还没有关注标的", message: "在「行情」中添加标的，后续报告会逐一分析。")
                    .frame(height: 140)
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(watchlist, id: \.self) { instId in
                        if let context = IntelligencePredictionContext.latest(for: instId, in: center.reports) {
                            IntelligencePredictionView(context: context, now: now,
                                                       timezone: center.settings.timezone)
                        } else {
                            HStack {
                                Text(instId).font(Theme.Text.bodyMedium)
                                Spacer()
                                Badge(text: center.isRunning ? "分析中" : "等待分析", tint: .secondary)
                            }
                            .rowStyle(padding: 10)
                        }
                    }
                }
            }
        }
    }

    private func reportsCard(now: Date) -> some View {
        let reports = center.reports.filter { $0.kind == reportKind }.sorted { $0.generatedAt > $1.generatedAt }
        return Card(title: "报告记录", subtitle: "失败时保留上次成功结果；没有新事件的快报检查保持静默。") {
            Picker("报告类型", selection: $reportKind) {
                ForEach(IntelligenceKind.allCases, id: \.self) { kind in Text(kind.label).tag(kind) }
            }
            .pickerStyle(.segmented).labelsHidden().frame(width: 210)
        } content: {
            if reports.isEmpty {
                EmptyState(icon: reportKind.icon, title: reportKind == .flash ? "暂无快报" : "暂无" + reportKind.label,
                           message: reportKind == .flash
                           ? center.statuses[.flash]?.note ?? "每 30 分钟检索；确认有新发生的重要事件时生成快报。"
                           : "首次生成完成后，摘要、事件来源与当时的方向研判会保存在这里。")
                    .frame(height: 150)
            } else {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(reports) { report in
                        IntelligenceReportView(report: report, timezone: center.settings.timezone, now: now,
                                               initiallyExpanded: report.id == reports.first?.id)
                    }
                }
            }
        }
    }

    private func events(on day: Date) -> [IntelligenceEvent] {
        center.events.filter { calendar.isDate($0.occurredAt, inSameDayAs: day) }.sorted {
            if $0.importance != $1.importance { return $0.importance.rank < $1.importance.rank }
            return $0.occurredAt < $1.occurredAt
        }
    }

    private func stamp(_ date: Date, format: String = "MM/dd HH:mm") -> String {
        intelligenceStamp(date, timezone: center.settings.timezone, format: format)
    }

    private func calendarRange(_ days: [Date]) -> String {
        guard let first = days.first, let last = days.last else { return "过去 7 天 · 未来 30 天" }
        return stamp(first, format: "yyyy/M/d") + " — " + stamp(last, format: "M/d")
    }
}

private struct IntelligenceAnalysisView: View {
    let report: IntelligenceReport
    let timezone: String

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if !report.summary.isEmpty {
                Text(report.summary).font(Theme.Text.body).textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            ForEach(report.findings) { finding in
                IntelligenceFindingView(finding: finding, timezone: timezone)
            }
            if !report.coverage.isEmpty {
                Text("检索覆盖：" + report.coverage).font(Theme.Text.secondary).foregroundStyle(.secondary)
                    .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct IntelligenceFindingView: View {
    let finding: IntelligenceFinding
    let timezone: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 7) {
                Badge(text: finding.kind.label, tint: finding.kind.tint, size: .small)
                Text(finding.title).font(Theme.Text.bodyMedium).textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !finding.instIds.isEmpty {
                Text(finding.instIds.joined(separator: " · "))
                    .font(Theme.Text.caption).foregroundStyle(.secondary).textSelection(.enabled)
            }
            Text(finding.body).font(Theme.Text.body).lineSpacing(4).textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            IntelligenceSourcesView(sources: finding.sources, timezone: timezone)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct IntelligenceEventView: View {
    let event: IntelligenceEvent
    let timezone: String

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .firstTextBaseline, spacing: 7) {
                Badge(text: event.category.label, tint: .secondary, size: .small)
                Text(event.title).font(Theme.Text.bodyMedium).textSelection(.enabled)
                Spacer(minLength: 4)
                Badge(text: event.status.label, tint: event.status == .unverified ? Theme.warning : .secondary, size: .small)
                if event.importance == .high { Badge(text: "重要", tint: Theme.warning, size: .small) }
            }
            Text(occurrenceText + " · " + publicationText)
                .font(Theme.Text.caption).foregroundStyle(.secondary).textSelection(.enabled)
            if !event.summary.isEmpty { Text(event.summary).font(Theme.Text.body).textSelection(.enabled) }
            if !event.impact.isEmpty {
                Text("市场影响：" + event.impact).font(Theme.Text.secondary).foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
            IntelligenceSourcesView(sources: event.sources, timezone: timezone)
        }
    }

    private var occurrenceText: String {
        let prefix = event.status == .scheduled ? "计划 " : "发生 "
        switch event.timePrecision {
        case .minute: return prefix + intelligenceStamp(event.occurredAt, timezone: timezone) + " " + timezone
        case .day:
            return "来源日期 " + intelligenceStamp(event.occurredAt, timezone: timezone, format: "yyyy/MM/dd") +
                "（时分未核实） · " + timezone
        case .unknown:
            return (event.status == .scheduled ? "计划时间待核实" : "发生时间待核实") + " · 归档 " +
                intelligenceStamp(event.occurredAt, timezone: timezone, format: "MM/dd")
        }
    }

    private var publicationText: String {
        event.publishedAt.map { "报道发布 " + intelligenceStamp($0, timezone: timezone) } ?? "报道发布时间未提供"
    }
}

private struct IntelligenceSourcesView: View {
    let sources: [IntelligenceSource]
    let timezone: String

    var body: some View {
        DisclosureGroup("来源与原始证据（\(sources.count)）") {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(Array(sources.enumerated()), id: \.offset) { _, source in
                    VStack(alignment: .leading, spacing: 3) {
                        if let url = URL(string: source.url), ["http", "https"].contains(url.scheme?.lowercased() ?? "") {
                            Link(destination: url) {
                                Label(source.title.isEmpty ? source.publisher : source.title, systemImage: "arrow.up.right.square")
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        } else {
                            Text(source.title).foregroundStyle(.secondary)
                        }
                        Text(source.publisher + " · 检索于 " + intelligenceStamp(source.retrievedAt, timezone: timezone))
                            .font(Theme.Text.caption).foregroundStyle(.secondary)
                        if !source.evidence.isEmpty {
                            Text(source.evidence).foregroundStyle(.secondary).textSelection(.enabled)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                if sources.isEmpty { Text("暂无可用来源").foregroundStyle(.secondary) }
            }
            .frame(maxWidth: .infinity, alignment: .leading).padding(.top, 6)
        }
        .font(Theme.Text.secondary)
    }
}

private struct IntelligencePredictionView: View {
    let context: IntelligencePredictionContext
    let now: Date
    let timezone: String

    private var prediction: IntelligencePrediction { context.prediction }
    private var expired: Bool { prediction.expiresAt <= now }

    var body: some View {
        DisclosureGroup {
            VStack(alignment: .leading, spacing: 7) {
                Text("生成 " + intelligenceStamp(prediction.generatedAt, timezone: timezone) + " · 有效至 " +
                     intelligenceStamp(prediction.expiresAt, timezone: timezone) + " " + timezone)
                    .font(Theme.Text.caption).foregroundStyle(.secondary)
                if let price = prediction.referencePrice {
                    Text("参考价格 " + PriceFormatter.auto(price)).font(Theme.Text.secondary).numeric()
                }
                ForEach(Array(prediction.drivers.enumerated()), id: \.offset) { _, driver in
                    Text("· " + driver).font(Theme.Text.secondary).textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if !prediction.invalidation.isEmpty {
                    Text("失效条件：" + prediction.invalidation).font(Theme.Text.secondary).textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if !context.findings.isEmpty {
                    Text("研判依据").font(Theme.Text.captionMedium).foregroundStyle(.secondary)
                    ForEach(context.findings) { finding in
                        IntelligenceFindingView(finding: finding, timezone: timezone)
                            .padding(.vertical, 4)
                    }
                }
                if !context.events.isEmpty {
                    Text("相关事件").font(Theme.Text.captionMedium).foregroundStyle(.secondary)
                    ForEach(context.events) { event in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(event.title).font(Theme.Text.secondary)
                            IntelligenceSourcesView(sources: event.sources, timezone: timezone)
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading).padding(.top, 8)
        } label: {
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(prediction.instId).font(Theme.Text.bodyMedium)
                    Text("\(prediction.horizonHours) 小时研判 · 截至 " +
                         intelligenceStamp(prediction.expiresAt, timezone: timezone, format: "MM/dd HH:mm"))
                        .font(Theme.Text.caption).foregroundStyle(.secondary)
                        .help(intelligenceStamp(prediction.expiresAt, timezone: timezone) + " " + timezone)
                }
                Spacer(minLength: 6)
                if expired { Badge(text: "已过期", tint: Theme.warning, size: .small) }
                if prediction.direction != .insufficient {
                    Text("置信度 " + prediction.confidence.label).font(Theme.Text.caption).foregroundStyle(.secondary)
                }
                Badge(text: prediction.direction.label, tint: expired ? .secondary : prediction.direction.tint)
            }
        }
        .rowStyle(padding: 10)
    }
}

private struct IntelligenceReportView: View {
    let report: IntelligenceReport
    let timezone: String
    let now: Date
    @State private var expanded: Bool

    init(report: IntelligenceReport, timezone: String, now: Date, initiallyExpanded: Bool = false) {
        self.report = report
        self.timezone = timezone
        self.now = now
        _expanded = State(initialValue: initiallyExpanded)
    }

    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            VStack(alignment: .leading, spacing: 10) {
                Text("资料窗口 " + intelligenceStamp(report.windowStart, timezone: timezone) + " — " +
                     intelligenceStamp(report.windowEnd, timezone: timezone) + " " + timezone)
                    .font(Theme.Text.caption).foregroundStyle(.secondary)
                IntelligenceAnalysisView(report: report, timezone: timezone)
                ForEach(report.events) { event in
                    IntelligenceEventView(event: event, timezone: timezone).rowStyle()
                }
                if !report.predictions.isEmpty {
                    Text("生成时的标的研判").font(Theme.Text.heading).padding(.top, 3)
                    ForEach(report.predictions) { prediction in
                        IntelligencePredictionView(context: IntelligencePredictionContext(prediction: prediction, report: report),
                                                   now: now, timezone: timezone)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading).padding(.top, 10)
        } label: {
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(report.title).font(Theme.Text.bodyMedium)
                    Text(intelligenceStamp(report.generatedAt, timezone: timezone) +
                         " · \(report.findings.count) 项分析 · \(report.events.count) 个事件")
                        .font(Theme.Text.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 4)
                if now.timeIntervalSince(report.generatedAt) > report.kind.staleInterval {
                    Badge(text: "历史报告", tint: .secondary, size: .small)
                }
            }
        }
        .rowStyle(padding: 10)
    }
}

private struct IntelligenceSettingsSheet: View {
    let center: IntelligenceCenter
    @Environment(\.dismiss) private var dismiss
    @State private var dailyHour = 8
    @State private var timezone = "Asia/Taipei"
    @State private var horizonHours = 1
    @State private var enabled = true

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("情报生成计划").font(Theme.Text.title)
            Toggle("自动更新", isOn: $enabled)
                .font(Theme.Text.body)
            Form {
                Picker("日报时间", selection: $dailyHour) {
                    ForEach(0..<24, id: \.self) { Text(String(format: "%02d:00", $0)).tag($0) }
                }
                TextField("时区", text: $timezone).textFieldStyle(.roundedBorder)
                Stepper("预测期限：\(horizonHours) 小时", value: $horizonHours, in: 1...120)
            }
            .font(Theme.Text.body)
            VStack(alignment: .leading, spacing: 6) {
                Text("局势更新：每 1 小时，回看近 60 分钟。")
                Text("新闻快报：每 30 分钟，只报告窗口内新发生且核实的事件。")
                Text("应用退出或睡眠期间暂停，恢复后只检查当前窗口。")
                Text("Claude Agent SDK · model_hub/es1_orange_o50[1m]")
                    .textSelection(.enabled)
            }
            .font(Theme.Text.secondary).foregroundStyle(.secondary)
            if TimeZone(identifier: timezone) == nil {
                Text("请输入有效 IANA 时区，例如 Asia/Taipei 或 America/New_York。")
                    .font(Theme.Text.caption).foregroundStyle(Theme.warning)
            }
            HStack {
                Button("取消") { dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                Button("保存") {
                    center.updateSettings(dailyHour: dailyHour, timezone: timezone, horizonHours: horizonHours)
                    center.setEnabled(enabled)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(TimeZone(identifier: timezone) == nil)
            }
        }
        .padding(24).frame(width: 460)
        .onAppear {
            dailyHour = center.settings.dailyHour
            timezone = center.settings.timezone
            horizonHours = center.settings.horizonHours
            enabled = center.settings.enabled
        }
    }
}

private func intelligenceStamp(_ date: Date, timezone: String, format: String = "yyyy/MM/dd HH:mm") -> String {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "zh_Hans_CN")
    formatter.timeZone = TimeZone(identifier: timezone) ?? TimeZone(secondsFromGMT: 0)
    formatter.dateFormat = format
    return formatter.string(from: date)
}

private func importanceColor(_ importance: IntelligenceImportance) -> Color {
    importance == .high ? Theme.warning : importance == .medium ? Theme.accent : .secondary
}

private extension IntelligenceKind {
    var label: String { self == .daily ? "日报" : self == .hourly ? "局势更新" : "快报" }
    var icon: String { self == .daily ? "newspaper" : self == .hourly ? "globe.asia.australia" : "bolt" }
    var cadence: String { self == .daily ? "每日" : self == .hourly ? "每 1 小时" : "每 30 分钟" }
    var actionLabel: String { self == .daily ? "生成日报" : self == .hourly ? "更新局势" : "检索快报" }
    var staleInterval: TimeInterval { self == .daily ? 86_400 : self == .hourly ? 3_600 : 1_800 }
}

private extension IntelligenceCategory {
    var label: String {
        switch self {
        case .macro: return "宏观"
        case .policy: return "政策"
        case .geopolitics: return "全球局势"
        case .crypto: return "加密"
        case .earnings: return "财报"
        }
    }
}

private extension IntelligenceEventStatus {
    var label: String { self == .scheduled ? "已排期" : self == .occurred ? "已发生" : "待核实" }
}

private extension IntelligenceImportance {
    var rank: Int { self == .high ? 0 : self == .medium ? 1 : 2 }
}

private extension IntelligenceDirection {
    var label: String {
        switch self {
        case .up: return "看涨"
        case .down: return "看跌"
        case .neutral: return "中性"
        case .insufficient: return "证据不足"
        }
    }
    var tint: Color { self == .up ? Theme.up : self == .down ? Theme.down : .secondary }
}

private extension IntelligenceConfidence {
    var label: String { self == .high ? "高" : self == .medium ? "中" : "低" }
}

private extension IntelligenceFindingKind {
    var label: String {
        switch self {
        case .observation: return "事实"
        case .inference: return "推断"
        case .unknown: return "待核实"
        }
    }
    var tint: Color {
        switch self {
        case .observation: return .secondary
        case .inference: return Theme.accent
        case .unknown: return Theme.warning
        }
    }
}
