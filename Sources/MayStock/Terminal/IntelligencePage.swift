import SwiftUI
import MayStockKit

/// One current research edition, an event calendar and a dated archive.
/// All visible evidence and judgments come from validated persisted reports.
struct IntelligencePage: View {
    let appState: AppState
    @State private var section: IntelligenceSection = .current
    @State private var selectedDay = Date()
    @State private var showSettings = false
    @State private var showUpdateStatus = false
    @State private var selectedReport: IntelligenceReport?

    private var center: IntelligenceCenter { appState.intelligence }
    private var calendar: Calendar { IntelligenceCalendar.calendar(timezone: center.settings.timezone) }
    private var watchlist: [String] { Array(Set(appState.store.config.watchlist.map(\.instId))).sorted() }

    var body: some View {
        TimelineView(.periodic(from: .now, by: 60)) { context in
            let library = center.library(now: context.date)
            VStack(alignment: .leading, spacing: 0) {
                header(now: context.date)
                    .padding(.horizontal, Theme.pagePadding).padding(.top, Theme.pagePadding)
                HStack {
                    Picker("情报内容", selection: $section) {
                        ForEach(IntelligenceSection.allCases) { section in
                            Text(section.label).tag(section)
                        }
                    }
                    .pickerStyle(.segmented).labelsHidden().frame(width: 240)
                    Spacer()
                    Text(center.settings.timezone).font(Theme.Text.caption).foregroundStyle(.secondary)
                }
                .padding(.horizontal, Theme.pagePadding).padding(.vertical, 16)
                Divider()
                PageScroll {
                    VStack(alignment: .leading, spacing: Theme.sectionSpacing) {
                        notices
                        switch section {
                        case .current:
                            currentPage(library: library, now: context.date)
                        case .calendar:
                            calendarCard(library: library, now: context.date)
                            dayCard(library: library)
                        case .history:
                            historyPage(library: library, now: context.date)
                        }
                    }
                    .padding(Theme.pagePadding)
                }
            }
        }
        .sheet(isPresented: $showSettings) {
            IntelligenceSettingsSheet(center: center)
        }
        .sheet(item: $selectedReport) { report in
            IntelligenceReportReader(report: report, timezone: center.settings.timezone)
        }
    }

    private func header(now: Date) -> some View {
        PageHeader(title: "情报站", subtitle: "市场分析与重要事件") {
            Button { showUpdateStatus.toggle() } label: {
                HStack(spacing: 5) {
                    StatusDot(color: center.isRunning ? Theme.accent : center.error != nil ? Theme.warning : .secondary)
                    Text("更新状态")
                }
            }
            .controlSize(.small)
            .popover(isPresented: $showUpdateStatus, arrowEdge: .bottom) {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Text("更新状态").font(Theme.Text.heading)
                        Spacer()
                        Text(center.settings.enabled ? "自动更新开启" : "自动更新暂停")
                            .font(Theme.Text.caption).foregroundStyle(.secondary)
                    }
                    ScrollView {
                        VStack(spacing: 10) {
                            ForEach(IntelligenceKind.allCases, id: \.self) { kind in
                                jobCard(kind, now: now)
                            }
                        }
                    }
                    Divider()
                    Button {
                        showUpdateStatus = false
                        showSettings = true
                    } label: {
                        Label("模型与计划", systemImage: "gearshape")
                    }
                    .controlSize(.small)
                }
                .padding(16).frame(width: 380, height: 470)
            }
            Button { showSettings = true } label: {
                Label("模型与计划", systemImage: "gearshape")
            }
            .controlSize(.small)
            Button { center.refresh(.hourly) } label: {
                Label(center.isRunning ? "更新中" : "更新分析", systemImage: "arrow.clockwise")
            }
            .buttonStyle(.borderedProminent).controlSize(.small).disabled(center.isRunning)
            Menu {
                Button("重新生成今日简报") { center.refresh(.daily) }
                Button("检查快讯") { center.refresh(.flash) }
            } label: {
                Image(systemName: "ellipsis")
            }
            .menuStyle(.borderlessButton).fixedSize().disabled(center.isRunning)
            .help("更多更新操作").accessibilityLabel("更多更新操作")
        }
    }

    @ViewBuilder
    private var notices: some View {
        if let error = center.error {
            InlineNotice(kind: .warning, title: "更新未完成，已保留已有分析", message: error)
        }
        if !center.settings.enabled {
            InlineNotice(kind: .info, title: "自动更新已暂停", message: "可通过「更新分析」手动生成，或在「更新状态」中调整生成计划。")
        }
    }

    private func jobCard(_ kind: IntelligenceKind, now: Date) -> some View {
        let status = center.statuses[kind]
        let running = center.isRunning && center.activeKind == kind
        let partial = status?.coverageComplete == false
        let unknownCoverage = status?.lastSuccessAt != nil && status?.coverageComplete == nil
        let stale = status?.lastSuccessAt.map { now.timeIntervalSince($0) > kind.staleInterval } ?? false
        return VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 5) {
                Image(systemName: kind.icon).foregroundStyle(.secondary)
                Text(kind.label).font(Theme.Text.heading)
                Spacer(minLength: 4)
                StatusDot(color: running ? Theme.accent : status?.error != nil || partial || stale ? Theme.warning :
                            status?.lastSuccessAt == nil || unknownCoverage ? .secondary : Theme.up)
                Text(running ? "检索中" : status?.error != nil ? "失败" : partial ? "覆盖不全" : stale ? "待更新" :
                        status?.lastSuccessAt == nil ? "等待首次生成" : unknownCoverage ? "覆盖未知" : "已检查")
                    .font(Theme.Text.caption).foregroundStyle(.secondary)
            }
            Text(kind == .daily ? String(format: "每日 %02d:00", center.settings.dailyHour) : kind.cadence)
                .font(Theme.Text.captionMedium).foregroundStyle(.secondary)
            Text(status?.lastSuccessAt.map { "上次检查 " + stamp($0) } ?? "尚无完成的检查")
                .font(Theme.Text.caption).foregroundStyle(.secondary)
            Text(center.settings.enabled
                 ? status?.nextRunAt.map { "下次 " + stamp($0) } ?? "等待调度"
                 : "自动更新暂停")
                .font(Theme.Text.caption).foregroundStyle(.tertiary)
            if let message = status?.error, !message.isEmpty {
                Text(message).font(Theme.Text.caption).foregroundStyle(Theme.warning)
                    .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            } else if let note = status?.note, !note.isEmpty {
                DisclosureGroup("本次检查说明") {
                    Text(note).font(Theme.Text.caption).foregroundStyle(.secondary)
                        .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                }
                .font(Theme.Text.caption)
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .cardStyle(padding: 12)
    }

    @ViewBuilder
    private func currentPage(library: IntelligenceLibrary, now: Date) -> some View {
        if let report = library.currentReport {
            VStack(alignment: .leading, spacing: 9) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(report.title).font(Theme.Text.title).textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 4)
                    if now.timeIntervalSince(report.generatedAt) > report.kind.staleInterval {
                        Badge(text: "待更新", tint: Theme.warning, size: .small)
                    }
                    if report.coverageComplete == nil {
                        Badge(text: "覆盖未知", tint: .secondary, size: .small)
                    } else if report.coverageComplete == false {
                        Badge(text: "覆盖不全", tint: Theme.warning, size: .small)
                    }
                }
                Text("研究生成 " + stamp(report.generatedAt) + " · 资料窗口 " +
                     stamp(report.windowStart) + " — " + stamp(report.windowEnd))
                    .font(Theme.Text.caption).foregroundStyle(.secondary).textSelection(.enabled)
                if let model = report.model {
                    Text("生成模型：" + model)
                        .font(Theme.Text.caption).foregroundStyle(.secondary).textSelection(.enabled)
                }
                if !report.summary.isEmpty {
                    IntelligenceSummaryView(text: report.summary).id(report.id)
                }
            }
            predictionsCard(library: library, now: now)
            if !report.findings.isEmpty || !report.coverage.isEmpty {
                Card(title: "研究分析", subtitle: "\(report.findings.count) 个章节 · 点击标题展开正文与来源") {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(report.findings.enumerated()), id: \.element.id) { index, finding in
                            IntelligenceFindingDisclosure(finding: finding, timezone: center.settings.timezone,
                                                          number: index + 1)
                                .padding(.vertical, 8)
                            if finding.id != report.findings.last?.id { Divider() }
                        }
                        if !report.coverage.isEmpty {
                            Divider().padding(.vertical, 6)
                            DisclosureGroup("检索覆盖与限制") {
                                Text(report.coverage).font(Theme.Text.secondary).foregroundStyle(.secondary)
                                    .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                                    .padding(.top, 5)
                            }
                            .font(Theme.Text.secondary)
                        }
                    }
                    .id(report.id)
                }
            }
        } else {
            EmptyState(icon: "text.magnifyingglass", title: center.isRunning ? "正在研究市场" : "等待第一份市场分析",
                       message: "生成完成后，这里会显示最新结论、全部关注标的的方向，以及支持判断的研究章节。")
                .frame(height: 180)
            if !watchlist.isEmpty { predictionsCard(library: library, now: now) }
        }
        flashSection(library: library)
        if !library.upcomingEvents.isEmpty {
            Card(title: "接下来关注") {
                Button("查看日历") { section = .calendar }.controlSize(.small)
            } content: {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(Array(library.upcomingEvents.prefix(3))) { event in
                        Button {
                            selectedDay = event.occurredAt
                            section = .calendar
                        } label: {
                            HStack(alignment: .firstTextBaseline, spacing: 10) {
                                Text(event.timePrecision == .minute ? stamp(event.occurredAt) :
                                     stamp(event.occurredAt, format: "MM/dd"))
                                    .font(Theme.Text.caption).foregroundStyle(.secondary).numeric()
                                    .frame(width: 85, alignment: .leading)
                                Text(event.title).font(Theme.Text.secondaryMedium)
                                    .fixedSize(horizontal: false, vertical: true)
                                Spacer(minLength: 4)
                                Image(systemName: "chevron.right").font(Theme.Text.caption).foregroundStyle(.secondary)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        if let daily = library.todayDaily, daily.id != library.currentReport?.id {
            Button { section = .history } label: {
                HStack(spacing: 6) {
                    Image(systemName: "newspaper")
                    Text("今日简报 · " + stamp(daily.generatedAt, format: "HH:mm") + " 更新")
                    Spacer()
                    Text("在历史中查看")
                    Image(systemName: "chevron.right")
                }
                .font(Theme.Text.secondary).foregroundStyle(.secondary).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
    }

    private func predictionsCard(library: IntelligenceLibrary, now: Date) -> some View {
        Card(title: "关注标的", subtitle: "同一份研究中的判断 · 模型置信度尚未经历史校准") {
            if watchlist.isEmpty {
                Text("在「行情」中添加关注标的，后续分析会逐一覆盖。")
                    .font(Theme.Text.secondary).foregroundStyle(.secondary)
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(watchlist, id: \.self) { instId in
                        if let context = library.currentPrediction(for: instId) {
                            IntelligencePredictionView(context: context, now: now, timezone: center.settings.timezone)
                        } else {
                            HStack {
                                Text(instId).font(Theme.Text.bodyMedium)
                                Spacer()
                                Badge(text: center.isRunning ? "分析中" : "本次暂无判断", tint: .secondary, size: .small)
                            }
                            .rowStyle(padding: 9)
                        }
                    }
                }
                .id(library.currentReport?.id)
            }
        }
    }

    @ViewBuilder
    private func flashSection(library: IntelligenceLibrary) -> some View {
        if library.recentFlashes.isEmpty {
            HStack(spacing: 6) {
                Image(systemName: "bolt").foregroundStyle(.secondary)
                Text(flashCheckText).foregroundStyle(.secondary)
            }
            .font(Theme.Text.caption)
        } else {
            Card(title: "最近快讯") {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(library.recentFlashes) { event in
                        IntelligenceEventDisclosure(event: event, timezone: center.settings.timezone)
                    }
                }
            }
        }
    }

    private var flashCheckText: String {
        let status = center.statuses[.flash]
        if center.activeKind == .flash { return "正在检查新发生的重要事件" }
        if status?.error != nil { return "快讯检查未完成，详情见「更新状态」" }
        guard let checkedAt = status?.lastSuccessAt else { return "快讯每 30 分钟检查，出现已核实的新事件时展示" }
        let result = status?.coverageComplete == false ? "已读资料中暂无已核实的新快讯，来源覆盖不全" :
            status?.coverageComplete == nil ? "暂无新快讯记录，来源覆盖未知" : "暂无已核实的新快讯"
        return "快讯检查 " + stamp(checkedAt, format: "HH:mm") + " · " + result
    }

    private func calendarCard(library: IntelligenceLibrary, now: Date) -> some View {
        let days = IntelligenceCalendar.days(around: now, timezone: center.settings.timezone)
        let leading = days.first.map { IntelligenceCalendar.leadingDays(for: $0, timezone: center.settings.timezone) } ?? 0
        return Card(title: "事件日历", subtitle: calendarRange(days)) {
            Button("今天") { selectedDay = now }.controlSize(.small)
        } content: {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 5), count: 7), spacing: 5) {
                ForEach(["周一", "周二", "周三", "周四", "周五", "周六", "周日"], id: \.self) { day in
                    Text(day).font(Theme.Text.captionMedium).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity).padding(.bottom, 3)
                }
                ForEach(0..<leading, id: \.self) { _ in
                    Color.clear.frame(height: 68).accessibilityHidden(true)
                }
                ForEach(days, id: \.self) { day in dayButton(day, library: library, today: now) }
            }
            Text("过去 7 天至未来 30 天，按事件发生或计划日期归档。")
                .font(Theme.Text.caption).foregroundStyle(.secondary)
        }
    }

    private func dayButton(_ day: Date, library: IntelligenceLibrary, today: Date) -> some View {
        let events = events(on: day, library: library)
        let confirmedCount = events.filter { $0.status != .unverified && $0.timePrecision != .unknown }.count
        let pendingCount = events.count - confirmedCount
        let selected = calendar.isDate(day, inSameDayAs: selectedDay)
        let isToday = calendar.isDate(day, inSameDayAs: today)
        let monthStart = calendar.component(.day, from: day) == 1
        return Button { selectedDay = day } label: {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 3) {
                    Text(stamp(day, format: monthStart ? "M/d" : "d"))
                        .font(Theme.Text.secondaryMedium).numeric()
                    if isToday { Text("今").font(Theme.Text.captionBold).foregroundStyle(Theme.accent) }
                    Spacer(minLength: 0)
                    if confirmedCount > 0 { Text("\(confirmedCount)").font(Theme.Text.caption).foregroundStyle(.secondary) }
                    if pendingCount > 0 { Text("?").font(Theme.Text.caption).foregroundStyle(.tertiary) }
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
                .strokeBorder(selected ? Theme.accent : isToday ? Theme.accent.opacity(0.35) : .clear, lineWidth: 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(stamp(day, format: "yyyy年M月d日") + "，\(confirmedCount) 个日期已明确事件，\(pendingCount) 个待核实事件")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func dayCard(library: IntelligenceLibrary) -> some View {
        let dayEvents = events(on: selectedDay, library: library)
        let confirmed = dayEvents.filter { $0.status != .unverified && $0.timePrecision != .unknown }
        let pending = dayEvents.filter { $0.status == .unverified || $0.timePrecision == .unknown }
        return Card(title: stamp(selectedDay, format: "M月d日 EEEE"),
                    subtitle: "\(confirmed.count) 个日期已明确事件" + (pending.isEmpty ? "" : " · \(pending.count) 个待核实")) {
            if dayEvents.isEmpty {
                EmptyState(icon: "calendar", title: library.calendarEvents.isEmpty ? "等待建立事件日历" : "当天暂无已收录事件",
                           message: library.calendarEvents.isEmpty
                           ? "今日简报完成后会补充重要事件、计划时间和来源。"
                           : "当前资料未收录这一天的事件，后续检查会继续补充。")
                    .frame(height: 150)
            } else {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(confirmed) { event in
                        IntelligenceEventDisclosure(event: event, timezone: center.settings.timezone)
                        if event.id != confirmed.last?.id { Divider() }
                    }
                    if !pending.isEmpty {
                        if !confirmed.isEmpty { Divider() }
                        Text("日期待核实").font(Theme.Text.captionMedium).foregroundStyle(.secondary)
                        Text("以下按归档日期展示，实际发生日期仍待核实。")
                            .font(Theme.Text.caption).foregroundStyle(.secondary)
                        ForEach(pending) { event in
                            IntelligenceEventDisclosure(event: event, timezone: center.settings.timezone)
                        }
                    }
                }
                .id(selectedDay)
            }
        }
    }

    @ViewBuilder
    private func historyPage(library: IntelligenceLibrary, now: Date) -> some View {
        if library.historyDays.isEmpty {
            EmptyState(icon: "clock.arrow.circlepath", title: "暂无历史报告",
                       message: "有研究内容的分析和已核实快讯会按日期保存在这里。")
                .frame(height: 180)
        } else {
            Text("按日期保留研究记录，同一天的简报重生成版本合并在一个条目中。")
                .font(Theme.Text.secondary).foregroundStyle(.secondary)
            ForEach(library.historyDays) { day in
                Card(title: calendar.isDate(day.date, inSameDayAs: now) ? "今天 · " + stamp(day.date, format: "M月d日") :
                     stamp(day.date, format: "M月d日 EEEE")) {
                    VStack(alignment: .leading, spacing: 12) {
                        ForEach(day.editions) { edition in
                            IntelligenceHistoryEditionRow(edition: edition, timezone: center.settings.timezone,
                                                          openReport: { selectedReport = $0 })
                            if edition.id != day.editions.last?.id { Divider() }
                        }
                    }
                }
            }
        }
    }

    private func events(on day: Date, library: IntelligenceLibrary) -> [IntelligenceEvent] {
        library.calendarEvents.filter { calendar.isDate($0.occurredAt, inSameDayAs: day) }.sorted {
            let leftKnown = $0.status != .unverified && $0.timePrecision != .unknown
            let rightKnown = $1.status != .unverified && $1.timePrecision != .unknown
            if leftKnown != rightKnown { return leftKnown }
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

private enum IntelligenceSection: String, CaseIterable, Identifiable {
    case current, calendar, history
    var id: Self { self }
    var label: String { self == .current ? "当前" : self == .calendar ? "日历" : "历史" }
}

private struct IntelligenceSummaryView: View {
    let text: String
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(text).font(Theme.Text.body).lineSpacing(3).lineLimit(expanded ? nil : 3)
                .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            Button(expanded ? "收起摘要" : "展开完整摘要") { expanded.toggle() }
                .buttonStyle(.plain).font(Theme.Text.caption).foregroundStyle(Theme.accent)
        }
    }
}

private struct IntelligenceFindingDisclosure: View {
    let finding: IntelligenceFinding
    let timezone: String
    var number: Int? = nil

    var body: some View {
        DisclosureGroup {
            IntelligenceFindingView(finding: finding, timezone: timezone, showHeading: false)
                .padding(.top, 8)
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                if let number {
                    Text(String(format: "%02d", number)).font(Theme.Text.caption).numeric()
                        .foregroundStyle(.tertiary).frame(width: 18, alignment: .leading)
                }
                Text(finding.title).font(Theme.Text.bodyMedium)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 4)
                Badge(text: finding.kind.label, tint: finding.kind.tint, size: .small)
            }
        }
    }
}

private struct IntelligenceEventDisclosure: View {
    let event: IntelligenceEvent
    let timezone: String

    var body: some View {
        DisclosureGroup {
            IntelligenceEventView(event: event, timezone: timezone, showHeading: false).padding(.top, 7)
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(event.title).font(Theme.Text.bodyMedium).fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 4)
                if event.importance == .high { Badge(text: "重要", tint: Theme.warning, size: .small) }
                if event.timePrecision == .unknown || event.status == .unverified {
                    Badge(text: "待核实", tint: .secondary, size: .small)
                }
                Text(intelligenceStamp(event.occurredAt, timezone: timezone,
                                       format: event.timePrecision == .minute ? "MM/dd HH:mm" : "MM/dd"))
                    .font(Theme.Text.caption).foregroundStyle(.secondary).numeric()
            }
        }
    }
}

private struct IntelligenceHistoryEditionRow: View {
    let edition: IntelligenceEdition
    let timezone: String
    let openReport: (IntelligenceReport) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            reportButton(edition.report, isPrevious: false)
            if edition.versions.count > 1 {
                DisclosureGroup("较早版本（\(edition.versions.count - 1)）") {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(Array(edition.versions.dropFirst())) { report in
                            reportButton(report, isPrevious: true)
                        }
                    }
                    .padding(.top, 6)
                }
                .font(Theme.Text.caption).foregroundStyle(.secondary)
                .padding(.leading, 26)
            }
        }
    }

    private func reportButton(_ report: IntelligenceReport, isPrevious: Bool) -> some View {
        Button { openReport(report) } label: {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Image(systemName: report.kind.icon).foregroundStyle(.secondary).frame(width: 16)
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Text(report.kind == .daily ? "当日简报" : report.kind == .hourly ? "市场分析" : "快讯")
                            .font(Theme.Text.bodyMedium)
                        if isPrevious { Badge(text: "较早版本", tint: .secondary, size: .small) }
                        Text(intelligenceStamp(report.generatedAt, timezone: timezone, format: "HH:mm"))
                            .font(Theme.Text.caption).foregroundStyle(.secondary).numeric()
                    }
                    Text(report.title).font(Theme.Text.secondary).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 4)
                Text(report.findings.isEmpty ? "\(report.events.count) 个事件" : "\(report.findings.count) 个章节")
                    .font(Theme.Text.caption).foregroundStyle(.secondary)
                Image(systemName: "chevron.right").font(Theme.Text.caption).foregroundStyle(.tertiary)
            }
            .frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
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
    var showHeading = true

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if showHeading {
                HStack(alignment: .firstTextBaseline, spacing: 7) {
                    Badge(text: finding.kind.label, tint: finding.kind.tint, size: .small)
                    Text(finding.title).font(Theme.Text.bodyMedium).textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
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
    var showHeading = true

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            if showHeading {
                HStack(alignment: .firstTextBaseline, spacing: 7) {
                    Text(event.title).font(Theme.Text.bodyMedium).textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 4)
                    if event.importance == .high { Badge(text: "重要", tint: Theme.warning, size: .small) }
                }
            }
            HStack(spacing: 7) {
                Badge(text: event.category.label, tint: .secondary, size: .small)
                Badge(text: event.status.label, tint: event.status == .unverified ? Theme.warning : .secondary, size: .small)
            }
            Text(occurrenceText + " · " + publicationText)
                .font(Theme.Text.caption).foregroundStyle(.secondary).textSelection(.enabled)
            if !event.summary.isEmpty {
                Text(event.summary).font(Theme.Text.body).textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !event.impact.isEmpty {
                Text("市场影响：" + event.impact).font(Theme.Text.secondary).foregroundStyle(.secondary)
                    .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
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
    var historical = false

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
                        IntelligenceFindingDisclosure(finding: finding, timezone: timezone)
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
                Text(prediction.instId).font(Theme.Text.bodyMedium).frame(minWidth: 80, alignment: .leading)
                Badge(text: directionLabel, tint: expired || historical ? .secondary : prediction.direction.tint,
                      size: .small)
                Text("\(prediction.horizonHours) 小时").font(Theme.Text.caption).foregroundStyle(.secondary)
                Spacer(minLength: 6)
                Text(prediction.direction == .insufficient ? "置信度 —" : "置信度 " + prediction.confidence.label)
                    .font(Theme.Text.caption).foregroundStyle(.secondary).frame(width: 62, alignment: .leading)
                if expired {
                    Badge(text: "已过期", tint: .secondary, size: .small)
                } else {
                    Text("至 " + intelligenceStamp(prediction.expiresAt, timezone: timezone, format: "HH:mm"))
                        .font(Theme.Text.caption).foregroundStyle(.secondary).numeric()
                }
            }
            .help("生成 " + intelligenceStamp(prediction.generatedAt, timezone: timezone) + " · 有效至 " +
                  intelligenceStamp(prediction.expiresAt, timezone: timezone) + " " + timezone)
        }
        .rowStyle(padding: 9)
    }

    private var directionLabel: String {
        let prefix = (expired || historical) && prediction.direction != .insufficient ? "当时" : ""
        return prefix + prediction.direction.label
    }
}

private struct IntelligenceReportReader: View {
    let report: IntelligenceReport
    let timezone: String
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        TimelineView(.periodic(from: .now, by: 60)) { context in
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .top, spacing: 12) {
                    VStack(alignment: .leading, spacing: 7) {
                        HStack(spacing: 7) {
                            Badge(text: "历史报告", tint: .secondary, size: .small)
                            Text(intelligenceStamp(report.generatedAt, timezone: timezone) + " · " + timezone)
                                .font(Theme.Text.caption).foregroundStyle(.secondary).textSelection(.enabled)
                            if report.coverageComplete == nil {
                                Badge(text: "旧版记录 · 覆盖未知", tint: .secondary, size: .small)
                            } else if report.coverageComplete == false {
                                Badge(text: "覆盖不全", tint: Theme.warning, size: .small)
                            }
                        }
                        Text(report.title).font(Theme.Text.title).textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 4)
                    Button("完成") { dismiss() }.keyboardShortcut(.cancelAction)
                }
                .padding(22)
                Divider()
                ScrollView {
                    VStack(alignment: .leading, spacing: Theme.sectionSpacing) {
                        Text("资料窗口 " + intelligenceStamp(report.windowStart, timezone: timezone) + " — " +
                             intelligenceStamp(report.windowEnd, timezone: timezone) + " " + timezone)
                            .font(Theme.Text.caption).foregroundStyle(.secondary).textSelection(.enabled)
                        if let model = report.model {
                            Text("生成模型：" + model)
                                .font(Theme.Text.caption).foregroundStyle(.secondary).textSelection(.enabled)
                        }
                        IntelligenceAnalysisView(report: report, timezone: timezone)
                        if !report.predictions.isEmpty {
                            Card(title: "当时的标的判断", subtitle: "仅反映本报告生成时的研究，过期判断不代表当前方向") {
                                VStack(alignment: .leading, spacing: 6) {
                                    ForEach(report.predictions) { prediction in
                                        IntelligencePredictionView(
                                            context: IntelligencePredictionContext(prediction: prediction, report: report),
                                            now: context.date, timezone: timezone, historical: true)
                                    }
                                }
                            }
                        }
                        if !report.events.isEmpty {
                            Card(title: "本报告收录的事件") {
                                VStack(alignment: .leading, spacing: 12) {
                                    ForEach(report.events) { event in
                                        IntelligenceEventDisclosure(event: event, timezone: timezone)
                                        if event.id != report.events.last?.id { Divider() }
                                    }
                                }
                            }
                        }
                    }
                    .padding(22)
                }
            }
        }
        .frame(width: 820, height: 740)
    }
}

private struct IntelligenceSettingsSheet: View {
    let center: IntelligenceCenter
    @Environment(\.dismiss) private var dismiss
    @State private var dailyHour = 8
    @State private var timezone = "Asia/Taipei"
    @State private var horizonHours = 1
    @State private var enabled = true
    @State private var model = IntelligenceSettings.defaultModel
    @State private var saveError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("情报模型与计划").font(Theme.Text.title)
            Toggle("自动更新", isOn: $enabled)
                .font(Theme.Text.body)
            Form {
                TextField("模型名称", text: $model)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12, design: .monospaced))
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
                Text("日报、局势更新、快报及复核共用此模型，保存后从下一轮开始生效。")
                if center.isRunning { Text("当前研究会继续使用启动时的模型。") }
            }
            .font(Theme.Text.secondary).foregroundStyle(.secondary)
            if TimeZone(identifier: timezone) == nil {
                Text("请输入有效 IANA 时区，例如 Asia/Taipei 或 America/New_York。")
                    .font(Theme.Text.caption).foregroundStyle(Theme.warning)
            }
            if IntelligenceSettings.normalizeModel(model) == nil {
                Text("请输入 1–200 位模型名称，可包含字母、数字、下划线、点、冒号、斜线、短横线和方括号。")
                    .font(Theme.Text.caption).foregroundStyle(Theme.warning)
            }
            if let saveError {
                Text(saveError).font(Theme.Text.caption).foregroundStyle(Theme.warning)
            }
            HStack {
                Button("取消") { dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                Button("保存") {
                    if center.updateSettings(dailyHour: dailyHour, timezone: timezone, horizonHours: horizonHours,
                                             model: model, enabled: enabled) {
                        dismiss()
                    } else {
                        saveError = center.error
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(TimeZone(identifier: timezone) == nil || IntelligenceSettings.normalizeModel(model) == nil)
            }
        }
        .padding(24).frame(width: 560)
        .onAppear {
            dailyHour = center.settings.dailyHour
            timezone = center.settings.timezone
            horizonHours = center.settings.horizonHours
            enabled = center.settings.enabled
            model = center.settings.model
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
