import Foundation
import Observation
import MayStockKit

/// One serial research worker for all terminal windows, with durable schedules.
@Observable
@MainActor
final class IntelligenceCenter {
    private(set) var reports: [IntelligenceReport] = []
    private(set) var events: [IntelligenceEvent] = []
    private(set) var settings = IntelligenceSettings()
    private(set) var statuses: [IntelligenceKind: IntelligenceJobStatus] = [:]
    private(set) var isRunning = false
    private(set) var activeKind: IntelligenceKind?
    private(set) var error: String?

    @ObservationIgnored private let directory: URL
    @ObservationIgnored private let snapshotMode: Bool
    @ObservationIgnored private var timer: Task<Void, Never>?
    @ObservationIgnored private var watchlist: () -> [String] = { [] }
    @ObservationIgnored private var venues: () -> [String: String] = { [:] }
    @ObservationIgnored private var liveQuote: (String) -> Ticker? = { _ in nil }
    @ObservationIgnored private var fetchQuote: @MainActor (String) async -> Ticker? = { _ in nil }
    @ObservationIgnored private var onFlash: (String) -> Void = { _ in }
    @ObservationIgnored private var canPersist = true

    private struct Archive: Codable {
        var settings: IntelligenceSettings
        var statuses: [IntelligenceKind: IntelligenceJobStatus]
        var reports: [IntelligenceReport]
        var events: [IntelligenceEvent]
    }

    init(directory: URL, snapshotMode: Bool) {
        self.directory = directory.appendingPathComponent("Intelligence")
        self.snapshotMode = snapshotMode
        let file = self.directory.appendingPathComponent("archive.json")
        if FileManager.default.fileExists(atPath: file.path) {
            do {
                let archive = try IntelligenceJSON.decoder().decode(Archive.self, from: Data(contentsOf: file))
                settings = archive.settings; statuses = archive.statuses
                reports = IntelligenceLibrary.canonicalReports(archive.reports)
                events = archive.events
            } catch {
                let backup = self.directory.appendingPathComponent("archive-unreadable-\(UUID().uuidString).json")
                do {
                    try FileManager.default.moveItem(at: file, to: backup)
                    self.error = "情报缓存无法读取；原文件已备份，等待重新生成。"
                } catch {
                    canPersist = false
                    self.error = "情报缓存无法读取且不能备份；已停止写入，原文件保留。"
                }
            }
        }
        if TimeZone(identifier: settings.timezone) == nil { settings.timezone = "Asia/Taipei" }
        settings.dailyHour = min(23, max(0, settings.dailyHour))
        settings.horizonHours = min(120, max(1, settings.horizonHours))
    }

    /// Every screen reads one projection of the archive. Reading it never
    /// changes a report's timestamps or promotes a check into a new analysis.
    func library(now: Date) -> IntelligenceLibrary {
        IntelligenceLibrary(reports: reports, events: events, now: now, timezone: settings.timezone)
    }

    func start(watchlist: @escaping () -> [String], quote: @escaping (String) -> Ticker?,
               fetchQuote: @escaping @MainActor (String) async -> Ticker?,
               venues: @escaping () -> [String: String] = { [:] },
               onFlash: @escaping (String) -> Void) {
        self.watchlist = watchlist; liveQuote = quote; self.fetchQuote = fetchQuote; self.onFlash = onFlash
        self.venues = venues
        guard !snapshotMode, timer == nil else { return }
        timer = Task { [weak self] in
            // Let launch-time market connections settle first.
            try? await Task.sleep(nanoseconds: 8_000_000_000)
            while !Task.isCancelled {
                self?.tick()
                try? await Task.sleep(nanoseconds: 15_000_000_000)
            }
        }
    }

    func setEnabled(_ enabled: Bool) {
        settings.enabled = enabled
        persist()
        if enabled { tick() }
    }

    @discardableResult
    func updateSettings(dailyHour: Int, timezone: String, horizonHours: Int, model: String, enabled: Bool) -> Bool {
        guard (0...23).contains(dailyHour), TimeZone(identifier: timezone) != nil,
              (1...120).contains(horizonHours), let selectedModel = IntelligenceSettings.normalizeModel(model) else {
            error = "请填写有效模型名称、时区、0–23 点和 1–120 小时预测周期。"
            return false
        }
        var nextSettings = settings
        nextSettings.dailyHour = dailyHour; nextSettings.timezone = timezone
        nextSettings.horizonHours = horizonHours; nextSettings.model = selectedModel
        nextSettings.enabled = enabled
        var nextStatuses = statuses
        if dailyHour != settings.dailyHour || timezone != settings.timezone || horizonHours != settings.horizonHours {
            for kind in IntelligenceKind.allCases {
                var status = nextStatuses[kind] ?? IntelligenceJobStatus()
                status.nextRunAt = IntelligenceSchedule.nextRun(kind: kind, now: Date(),
                    lastSuccess: status.lastSuccessAt, settings: nextSettings)
                nextStatuses[kind] = status
            }
        }
        do {
            if !snapshotMode {
                try saveArchive(Archive(settings: nextSettings, statuses: nextStatuses, reports: reports, events: events))
            }
        } catch {
            self.error = "情报设置保存失败；请检查数据目录权限与磁盘空间。"
            return false
        }
        settings = nextSettings; statuses = nextStatuses; error = nil
        if enabled { tick() }
        return true
    }

    private func tick() {
        guard settings.enabled, !isRunning, !snapshotMode else { return }
        let now = Date()
        // Populate the full calendar first. Later, fast news checks get priority.
        let order: [IntelligenceKind] = reports.contains(where: { $0.kind == .daily })
            ? [.flash, .hourly, .daily] : [.daily, .flash, .hourly]
        for kind in order {
            let status = statuses[kind] ?? IntelligenceJobStatus()
            let next = status.nextRunAt ?? IntelligenceSchedule.nextRun(kind: kind, now: now,
                lastSuccess: status.lastSuccessAt, settings: settings)
            if next <= now { refresh(kind); return }
        }
    }

    func refresh(_ kind: IntelligenceKind) {
        guard !snapshotMode, !isRunning else { return }
        isRunning = true; activeKind = kind; error = nil
        let now = Date()
        var status = statuses[kind] ?? IntelligenceJobStatus()
        status.lastAttemptAt = now
        // A crash during research must not create a restart/cost loop.
        status.nextRunAt = now.addingTimeInterval(600)
        status.error = nil; status.note = "正在检索与核验来源"
        statuses[kind] = status
        persist()
        let capturedSettings = settings
        Task { [weak self] in
            guard let self else { return }
            defer { self.isRunning = false; self.activeKind = nil }
            do {
                let bridge = try self.resolveBridge()
                let instruments = Array(Set(self.watchlist())).sorted()
                var quotes: [IntelligenceQuote] = []
                // Hidden menu items are still watched. Read public prices for those too.
                for instId in instruments {
                    if let ticker = self.liveQuote(instId),
                       (0...300).contains(Date().timeIntervalSince(ticker.ts)) {
                        quotes.append(IntelligenceQuote(ticker: ticker))
                    } else if let ticker = await self.fetchQuote(instId) {
                        // Use the same venue source for visible and hidden instruments.
                        // The bridge preserves its market timestamp; Python rejects stale quotes.
                        quotes.append(IntelligenceQuote(ticker: ticker))
                    }
                }
                let request = IntelligenceRequest(kind: kind, now: Date(), settings: capturedSettings,
                    watchlist: instruments, quotes: quotes,
                    knownEvents: self.events.filter { $0.status == .occurred }.map(IntelligenceKnownEvent.init),
                    venues: self.venues())
                let report = try await bridge.generate(request)
                try self.accept(report, request: request)
            } catch {
                let message = (error as? LocalizedError)?.errorDescription ?? "情报生成失败，已保留上次结果。"
                self.error = message
                var status = self.statuses[kind] ?? IntelligenceJobStatus()
                status.error = message; status.note = nil
                status.nextRunAt = Date().addingTimeInterval(kind == .flash ? 1_800 : 3_600)
                self.statuses[kind] = status
                self.persist()
            }
        }
    }

    private func accept(_ input: IntelligenceReport, request: IntelligenceRequest) throws {
        var report = input
        let now = Date()
        let known = Set(events.map(\.id))
        if report.kind == .flash {
            // Defense in depth: backend validation is required; UI never trusts raw LLM timing.
            report.events = report.events.filter {
                $0.status == .occurred && $0.timePrecision == .minute && !$0.sources.isEmpty
                && $0.occurredAt > now.addingTimeInterval(-1_800)
                && $0.occurredAt <= now && !known.contains($0.id)
            }
            let acceptedIDs = Set(report.events.map(\.id))
            report.predictions = report.predictions.filter { Set($0.eventIds).isSubset(of: acceptedIDs) }
            report.windowStart = max(report.windowStart, now.addingTimeInterval(-1_800))
            if report.events.isEmpty { report.predictions = [] }
        }
        var nextReports = reports
        if IntelligenceLibrary.hasContent(report) {
            nextReports.insert(report, at: 0)
            // Preserve enough history for the complete seven-day calendar.
            nextReports = Array(IntelligenceLibrary.canonicalReports(nextReports)
                .filter { now.timeIntervalSince($0.generatedAt) < 8 * 86_400 }.prefix(600))
        }
        var merged = Dictionary(events.map { ($0.id, $0) }, uniquingKeysWith: { _, newer in newer })
        for event in report.events { merged[event.id] = event }
        let dates = IntelligenceSchedule.days(now: now, timezone: settings.timezone)
        let lower = dates.first ?? now.addingTimeInterval(-7 * 86_400)
        let upper = IntelligenceSchedule.calendar(timezone: settings.timezone)
            .date(byAdding: .day, value: 1, to: dates.last ?? now) ?? now.addingTimeInterval(31 * 86_400)
        let nextEvents = merged.values.filter { $0.occurredAt >= lower && $0.occurredAt < upper }
            .sorted { $0.occurredAt < $1.occurredAt }
        var status = statuses[report.kind] ?? IntelligenceJobStatus()
        status.lastSuccessAt = now; status.error = nil
        status.coverageComplete = report.coverageComplete
        status.nextRunAt = IntelligenceSchedule.nextRun(kind: report.kind, now: now,
            lastSuccess: report.kind == .daily ? now : request.now, settings: settings)
        if report.kind == .flash && report.events.isEmpty {
            status.note = (report.coverageComplete == false
                ? "来源覆盖不完整；已读取资料中未核验到窗口内新事件，本次静默。"
                : "未发现符合发生时间要求的新事件，本次静默。") + report.coverage
        } else if !IntelligenceLibrary.hasContent(report) {
            status.note = "本次检查未形成新的有效研究，继续保留上次分析。" + report.coverage
        } else {
            status.note = report.coverage
        }
        var nextStatuses = statuses
        nextStatuses[report.kind] = status
        // Persist as a transaction before exposing new results or delivering a notification.
        try saveArchive(Archive(settings: settings, statuses: nextStatuses, reports: nextReports, events: nextEvents))
        reports = nextReports; events = nextEvents; statuses = nextStatuses
        if report.kind == .flash, !report.events.isEmpty, settings.enabled {
            onFlash(report.events.prefix(3).map(\.title).joined(separator: "；")
                .replacingOccurrences(of: "\\", with: "").replacingOccurrences(of: "\n", with: " "))
        }
    }

    private func resolveBridge() throws -> IntelligenceBridge {
        let env = ProcessInfo.processInfo.environment
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let pythonCandidates = [env["MAYSTOCK_INTELLIGENCE_PYTHON"].map { URL(fileURLWithPath: $0) },
            ConfigIO.defaultDirectory().appendingPathComponent("IntelligenceRuntime/bin/python3"),
            root.appendingPathComponent(".build/intelligence-venv/bin/python3")].compactMap { $0 }
        let scriptCandidates = [Bundle.main.resourceURL?.appendingPathComponent("Intelligence/runner.py"),
            root.appendingPathComponent("Intelligence/runner.py")].compactMap { $0 }
        guard let python = pythonCandidates.first(where: { FileManager.default.isExecutableFile(atPath: $0.path) }),
              let script = scriptCandidates.first(where: { FileManager.default.fileExists(atPath: $0.path) }) else {
            throw IntelligenceBridgeError.failed("情报 SDK 尚未安装。请在源码目录运行 ./Scripts/setup-intelligence.sh，然后重试。")
        }
        return IntelligenceBridge(python: python, script: script)
    }

    private func save() throws {
        try saveArchive(Archive(settings: settings, statuses: statuses, reports: reports, events: events))
    }

    private func saveArchive(_ archive: Archive) throws {
        guard canPersist else {
            throw IntelligenceBridgeError.failed("情报缓存尚未安全备份，已停止写入。")
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try IntelligenceJSON.encoder().encode(archive).write(to: directory.appendingPathComponent("archive.json"), options: .atomic)
    }

    private func persist() {
        guard !snapshotMode else { return }
        do { try save() } catch { self.error = "情报缓存写入失败；请检查数据目录权限与磁盘空间。" }
    }
}
