import Foundation
import MayStockKit

/// `maystock-lab review` — the unattended hourly pass.
///
/// Deliberately a command rather than a prompt. An agent that wakes every hour
/// and reads the raw JSON decides freehand: the same state yields a slightly
/// different reading each time, and "slightly different, hourly, on live
/// positions" is drift with a schedule attached. Running the checks in code
/// means the same state always produces the same findings, the thresholds are
/// on disk where they can be argued with, and the agent's job shrinks to the
/// part that actually needs judgement — deciding what an anomaly means.
extension LabMain {
    static func review(_ arguments: Arguments) async throws {
        let directory = arguments.string("dir").map { URL(fileURLWithPath: $0) }
            ?? ConfigIO.defaultDirectory()
        let policyStore = ReviewPolicyStore(directory: directory)

        if arguments.has("seed-policy") {
            try seedPolicy(directory: directory, store: policyStore, force: arguments.has("force"))
            return
        }

        let configIO = ConfigIO(directory: directory)
        let config = configIO.load()
        let mode = config.strategy.mode
        let policy = policyStore.load()

        let ledger = StrategyLedgerStore(directory: directory, mode: mode).load()
        // The one input that does not come from our own files. Read-only, and
        // a failure here degrades to "not checked" rather than to "fine" —
        // `bookDrift` says so out loud.
        // Same CLI path and profile the app trades through, so the review reads
        // the account the engine is actually acting on.
        let exchangeTotals = try? await TradeBridge(prefs: config.trading).bookTotals(mode: mode)
        let snapshot = ReviewSnapshot(
            now: Date(),
            config: config,
            lastTickAt: HeartbeatStore(directory: directory).load(),
            accountEquity: AccountEquityStore(directory: directory, mode: mode).load(),
            strategyEquity: AccountEquityStore(
                directory: directory, mode: mode, perStrategy: true).loadByStrategy(),
            positions: ledger.positions,
            fills: ledger.fills,
            appRunning: isAppRunning(),
            exchangeTotals: exchangeTotals)

        var result = PortfolioReview.run(snapshot, policy: policy)

        var outcome: ReviewActionOutcome?
        if arguments.has("apply"), !result.actions.isEmpty {
            let applied = ReviewActuator.apply(result.actions, to: config)
            if applied.didChange {
                try backupConfig(configIO.fileURL)
                try configIO.save(applied.config)
            }
            outcome = applied
            // Re-run against the config we just wrote, so the report describes
            // the state that now exists rather than the one we walked in on.
            var after = snapshot
            after.config = applied.config
            result = PortfolioReview.run(after, policy: policy)
        }

        if arguments.has("json") {
            printJSON(result, outcome: outcome, applied: arguments.has("apply"))
        } else {
            printReport(result, outcome: outcome, snapshot: snapshot, policy: policy)
        }

        if let path = arguments.string("log") {
            appendLog(result, outcome: outcome, to: URL(fileURLWithPath: path))
        }

        // Exit code carries the verdict, so a wrapper can branch without
        // parsing anything: 0 quiet, 1 warn, 2 critical.
        switch result.verdict {
        case .ok, .info: break
        case .warn: exit(1)
        case .critical: exit(2)
        }
    }

    // MARK: Report

    private static func printReport(
        _ result: ReviewResult, outcome: ReviewActionOutcome?,
        snapshot: ReviewSnapshot, policy: ReviewPolicy
    ) {
        Out.heading("组合复盘 · \(stamp(result.now))")
        Out.rule()
        let portfolio = snapshot.config.strategy
        Out.kv("模式", portfolio.mode.displayName + "（" + portfolio.mode.badge + "）")
        Out.kv("本金", money(portfolio.totalCapital) + " " + portfolio.quoteCurrency)
        Out.kv("已分配", String(
            format: "%@（%.2f×）", money(portfolio.allocatedCapital),
            portfolio.totalCapital > 0 ? portfolio.allocatedCapital / portfolio.totalCapital : 0))
        Out.kv("运行中", "\(portfolio.runningCount)/\(portfolio.allocations.count)")
        if let last = snapshot.lastTickAt {
            Out.kv("上次轮询", AccountEquityCurve.describe(result.now.timeIntervalSince(last)) + "前")
        } else {
            Out.kv("上次轮询", "从未")
        }

        Out.heading("这一小时告诉了你什么")
        Out.note(result.evidence.headline)
        Out.note("这就是为什么这个复盘不重新寻优：策略按日线思考，两次决策之间它会被看 23 次。"
            + "真正的重新验证由 evidence.stale 排期，不由钟表排期。")

        Out.heading("检查结果 · \(result.verdict.label)")
        Out.rule()
        if result.findings.isEmpty {
            Out.good("没有发现问题")
        }
        for finding in result.findings {
            let line = "[\(finding.code)] \(finding.title)"
            switch finding.severity {
            case .critical: Out.bad(line)
            case .warn: Out.warn(line)
            case .info, .ok: Out.note(line)
            }
            print("      \(finding.detail)")
            if let remedy = finding.remedy { print("      → \(remedy)") }
        }

        if let outcome {
            Out.heading("已自动执行")
            Out.rule()
            if outcome.applied.isEmpty { Out.note("无") }
            for action in outcome.applied { Out.good(action.summary + " —— " + action.reason) }
            for (action, why) in outcome.rejected {
                Out.bad("拒绝执行 \(action.summary)：\(why)")
                print("      不变式挡下了它。能触发这条的只有发出该动作的检查本身有 bug。")
            }
        } else if !result.actions.isEmpty {
            Out.heading("可自动执行（本次未加 --apply）")
            Out.rule()
            for action in result.actions { Out.note(action.summary + " —— " + action.reason) }
        }

        if !policy.mandates.isEmpty {
            Out.heading("预注册的授权额度 · \(dayStamp(policy.writtenAt))")
            Out.rule()
            print("  " + Out.pad("策略", 26) + Out.padLeft("p95 回撤", 10)
                + Out.padLeft("回测回撤", 10) + Out.padLeft("年化", 9) + Out.padLeft("新 K 线", 9))
            for mandate in policy.mandates.sorted(by: { $0.strategyId < $1.strategyId }) {
                let bars = mandate.barsSinceValidation(now: result.now)
                print("  " + Out.pad(mandate.strategyId, 26)
                    + Out.padLeft(String(format: "%.1f%%", mandate.resampleP95DrawdownPct), 10)
                    + Out.padLeft(String(format: "%.1f%%", mandate.backtestDrawdownPct), 10)
                    + Out.padLeft(String(format: "%.0f%%", mandate.expectedAnnualReturnPct), 9)
                    + Out.padLeft("\(bars)/\(policy.revalidateAfterBars)", 9))
            }
        }
        print("")
    }

    // MARK: JSON

    private struct JSONFinding: Encodable {
        var code: String
        var severity: String
        var title: String
        var detail: String
        var remedy: String?
        var actions: [String]
    }

    private struct JSONReport: Encodable {
        var now: Date
        var verdict: String
        var evidence: String
        var hoursObserved: Double
        var hoursForSignificance: Double?
        var findings: [JSONFinding]
        var appliedActions: [String]
        var rejectedActions: [String]
        var pendingActions: [String]
        var barsSinceValidation: [String: Int]
    }

    private static func printJSON(
        _ result: ReviewResult, outcome: ReviewActionOutcome?, applied: Bool
    ) {
        let report = JSONReport(
            now: result.now,
            verdict: result.verdict.rawValue,
            evidence: result.evidence.headline,
            hoursObserved: result.evidence.hoursObserved,
            hoursForSignificance: result.evidence.hoursForSignificance,
            findings: result.findings.map {
                JSONFinding(
                    code: $0.code, severity: $0.severity.rawValue, title: $0.title,
                    detail: $0.detail, remedy: $0.remedy, actions: $0.actions.map(\.summary))
            },
            appliedActions: outcome?.applied.map { $0.summary + " —— " + $0.reason } ?? [],
            rejectedActions: outcome?.rejected.map { "\($0.action.summary)：\($0.why)" } ?? [],
            pendingActions: applied ? [] : result.actions.map { $0.summary + " —— " + $0.reason },
            barsSinceValidation: result.evidence.barsSinceValidation)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        if let data = try? encoder.encode(report), let text = String(data: data, encoding: .utf8) {
            print(text)
        }
    }

    /// One line per run, appended. Lets the next pass see whether a finding is
    /// new or has been sitting there for six hours — the difference between an
    /// incident and a condition.
    private static func appendLog(
        _ result: ReviewResult, outcome: ReviewActionOutcome?, to url: URL
    ) {
        struct Line: Encodable {
            var ts: Date
            var verdict: String
            var codes: [String]
            var applied: [String]
        }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let line = Line(
            ts: result.now, verdict: result.verdict.rawValue,
            codes: result.findings.map(\.code),
            applied: outcome?.applied.map(\.summary) ?? [])
        guard var data = try? encoder.encode(line) else { return }
        data.append(0x0A)
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        } else {
            try? data.write(to: url)
        }
    }

    // MARK: Policy seeding

    private static func seedPolicy(
        directory: URL, store: ReviewPolicyStore, force: Bool
    ) throws {
        if store.exists, !force {
            Out.bad("\(store.fileURL.path) 已存在。加 --force 覆盖。")
            Out.note("覆盖会丢掉现有的授权额度 —— 那是事先写死的风险预算，不该顺手重写。")
            exit(2)
        }
        let config = ConfigIO(directory: directory).load()
        let mandates = config.strategy.allocations.map { allocation in
            StrategyMandate(
                strategyId: allocation.strategyId,
                barSeconds: 86_400,
                resampleP95DrawdownPct: 0,
                backtestDrawdownPct: 0,
                expectedTradesPerWeek: 0,
                expectedAnnualReturnPct: 0,
                validatedAt: Date(timeIntervalSince1970: 0),
                evidence: "待填：跑 maystock-lab backtest / wf 后把真实数字写进来")
        }
        let policy = ReviewPolicy(
            writtenAt: Date(),
            note: "初始骨架。每条额度都是 0，因此自动停用规则不会触发 —— 这是有意的："
                + "没测过的数字不该拿来当风控。",
            mandates: mandates)
        try store.save(policy)
        Out.good("已写入 \(store.fileURL.path)")
        Out.warn("所有额度都是 0（占位）。在填入实测数字之前，自动停用规则不会动手。")
    }

    // MARK: Helpers

    private static func isAppRunning() -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        process.arguments = ["-x", "MayStock"]
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus == 0
        } catch {
            return false
        }
    }

    /// Keep the file we are about to overwrite. An unattended writer that
    /// cannot be undone is a worse problem than whatever it was fixing.
    private static func backupConfig(_ url: URL) throws {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let backup = url.deletingLastPathComponent()
            .appendingPathComponent("config.json.review-\(formatter.string(from: Date()))")
        try? FileManager.default.copyItem(at: url, to: backup)
    }

    private static func money(_ value: Double) -> String {
        String(format: "%.2f", value)
    }

    private static func stamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.timeZone = EquityWindow.timeZone
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter.string(from: date)
    }

    private static func dayStamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.timeZone = EquityWindow.timeZone
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }
}
