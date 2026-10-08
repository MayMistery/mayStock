import Foundation
import MayStockKit

extension E2EMain {

    /// The live account against the exchange itself: the kernel's account
    /// document — what every screen of the app shows — next to a REST read of
    /// the same account taken at the same moment, every few seconds.
    ///
    /// The two are valued at marks a moment apart, so each comparison is
    /// made at the REST read's own mark: the live document's floating profit
    /// for the leg is re-derived at that mark from the live document's own
    /// rule-of-three (profit per point × points), and must land within a
    /// cent per contract-point of the venue's `upl`. The live figure's age is
    /// reported on its own.
    ///
    /// Read-only, both ways. Runs the account part of the layer alone, as the
    /// app does with the checkup page closed.
    static func accountDoctor(seconds: Int) async -> Bool {
        print("live account doctor (\(seconds) s)")
        let config = ConfigIO(directory: ConfigIO.defaultDirectory()).load()
        let mode = config.strategy.mode
        let bridge = TradeBridge(prefs: config.trading)
        let kernel: LiveKernel
        do {
            kernel = try LiveKernel(config: LiveKernel.Config(
                instId: "ETH-USDT-SWAP", followsHeldPosition: true, mode: mode,
                okxProfile: bridge.profile(for: mode),
                okxConfigPath: OKXProfileCatalog.defaultFileURL().path,
                schwabctlPath: nil, analytics: false))
        } catch {
            fail("start", String(describing: error))
            return false
        }
        defer { kernel.stop() }
        let trade = KernelTradeClient(bridge: bridge)

        var seq: UInt64 = 0
        var latest: LiveAccount?
        var documents = 0
        var markAges: [Double] = []
        var gaps: [Double] = []
        var equityGaps: [Double] = []
        let started = Date()
        var nextCheck = started.addingTimeInterval(8)
        while Date().timeIntervalSince(started) < Double(seconds) {
            if let (next, json) = kernel.account(since: seq) {
                seq = next
                documents += 1
                do {
                    let account = try JSONDecoder().decode(LiveAccount.self, from: json)
                    latest = account
                    if let ms = account.equity?.markedMs {
                        markAges.append(Date().timeIntervalSince(account.date(ms: ms)) * 1000)
                    }
                } catch {
                    fail("account decode", String(describing: error))
                    return false
                }
            }
            if Date() >= nextCheck, let account = latest {
                nextCheck = nextCheck.addingTimeInterval(6)
                await compare(account, with: trade, mode: mode, gaps: &gaps, equityGaps: &equityGaps)
            }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        guard let account = latest else {
            fail("account", "no document arrived")
            return false
        }
        print("\n— \(documents) documents in \(seconds) s")
        for feed in account.feeds {
            let age = feed.lastFrameMs.map { Date().timeIntervalSince(account.date(ms: $0)) * 1000 }
            print("  \(feed.state.padding(toLength: 10, withPad: " ", startingAt: 0)) \(feed.label)  last frame \(age.map { String(format: "%.0f ms", $0) } ?? "—")  \(feed.detail ?? "")")
        }
        if !markAges.isEmpty {
            let sorted = markAges.sorted()
            print(String(format: "  valuation mark age: p50 %.0f ms · p90 %.0f ms · max %.0f ms (%d documents)",
                         sorted[sorted.count / 2], sorted[sorted.count * 9 / 10], sorted.last ?? 0, sorted.count))
        }
        print("  orders: \(account.orders.listing.map { "\($0.orders.count) working" } ?? "not read")"
              + (account.orders.unavailable.isEmpty ? "" : " · unavailable \(account.orders.unavailable)")
              + (account.orders.error.map { " · error \($0)" } ?? ""))
        print("  transfers this week: \(account.transfers.items.count)" + (account.transfers.error.map { " · error \($0)" } ?? ""))
        let byCurrency = Dictionary(grouping: account.transfers.items, by: \.ccy).mapValues { $0.reduce(0) { $0 + $1.amount } }
        let bySubType = Dictionary(grouping: account.transfers.items, by: { $0.subType ?? "—" })
        print("    by subType: " + bySubType.map { "\($0.key) ×\($0.value.count) \(String(format: "%+.4f", $0.value.reduce(0) { $0 + $1.amount }))" }.sorted().joined(separator: " · "))
        print("    net by currency: " + byCurrency.map { "\($0.key) \(String(format: "%+.4f", $0.value))" }.sorted().joined(separator: " · "))
        let formatter = DateFormatter()
        formatter.dateFormat = "MM-dd HH:mm:ss"
        for transfer in account.transfers.items where transfer.kind != .income {
            print("    left out: \(formatter.string(from: account.date(ms: transfer.ms))) \(transfer.ccy) \(String(format: "%+.6f", transfer.amount)) subType \(transfer.subType ?? "—") \(transfer.kind)")
        }
        for transfer in account.transfers.items.prefix(3) {
            print("    \(formatter.string(from: account.date(ms: transfer.ms))) \(transfer.ccy) \(String(format: "%+.6f", transfer.amount)) subType \(transfer.subType ?? "—") (bill \(transfer.id))")
        }

        var ok = true
        for id in ["okx.private", "okx.marks", "okx.orders", "okx.order-events", "okx.transfers"] {
            let feed = account.feeds.first { $0.id == id }
            // A quiet account pushes nothing on the order-events socket; up is
            // what it has to be.
            let healthy = feed?.isLive == true
            if healthy || (id == "okx.marks" && account.positions.isEmpty) {
                pass(feed?.label ?? id)
            } else {
                fail(feed?.label ?? id, feed?.detail ?? "not live")
                ok = false
            }
        }
        if !account.wasRead {
            fail("positions", account.note ?? "not read")
            ok = false
        } else if account.positions.contains(where: { !$0.remarked }) {
            fail("valuation", account.positions.compactMap(\.note).joined(separator: "；"))
            ok = false
        } else {
            pass("valuation", "\(account.positions.count) 个持仓按实时标记价重估")
        }
        if let worst = gaps.map(abs).max() {
            if worst < 0.05 {
                pass("floating profit vs REST at the same mark", String(format: "max |Δ| %.4f over %d checks", worst, gaps.count))
            } else {
                fail("floating profit vs REST at the same mark", String(format: "max |Δ| %.4f", worst))
                ok = false
            }
        }
        if let worst = equityGaps.map(abs).max() {
            print(String(format: "  equity vs REST totalEq (each at its own moment): max |Δ| %.2f USD over %d checks", worst, equityGaps.count))
        }
        return ok
    }

    /// One comparison: the REST positions and the live document's legs,
    /// brought to the REST read's mark.
    private static func compare(
        _ account: LiveAccount, with trade: KernelTradeClient, mode: TradingMode,
        gaps: inout [Double], equityGaps: inout [Double]
    ) async {
        guard let rest = try? await trade.positions(mode: mode) else {
            print("  (REST positions read failed; skipped)")
            return
        }
        let snapshot = try? await trade.accountSnapshot(mode: mode)
        for leg in account.positions {
            guard let truth = rest.first(where: { $0.instId == leg.instId && $0.posSide.rawValue == leg.posSide }),
                  let restMark = truth.markPrice, let liveMark = leg.mark?.price,
                  let liveUpl = leg.unrealisedPnl, let average = leg.averagePrice, liveMark != average
            else { continue }
            // The live rule is linear in the mark for a linear contract: its
            // profit per point is liveUpl / (liveMark − average).
            let perPoint = liveUpl / (liveMark - average)
            let atRestMark = perPoint * (restMark - average)
            let gap = atRestMark - truth.unrealisedPnL
            gaps.append(gap)
            let age = leg.mark?.ms.map { Date().timeIntervalSince(account.date(ms: $0)) * 1000 } ?? .nan
            print(String(format: "  %@ %@ live mark %.2f (%.0f ms) upl %.2f · REST mark %.2f upl %.4f · live rule at REST mark %.4f · Δ %.4f",
                         leg.instId, leg.posSide, liveMark, age, liveUpl, restMark, truth.unrealisedPnL, atRestMark, gap))
        }
        if let live = account.equity?.usd, let restEquity = snapshot?.totalEquity {
            equityGaps.append(live - restEquity)
            print(String(format: "  equity live %.2f USD · REST totalEq %.2f USD · Δ %.2f (marks a moment apart)", live, restEquity, live - restEquity))
        }
    }
}
