import Foundation
import MayStockKit

extension E2EMain {

    /// A strategy's leverage and margin mode on the DEMO account, end to end
    /// through the runner and the kernel's trading path. Never the live
    /// account: every call below names `.demo`, and the host is locked.
    ///
    /// 1. A perpetual strategy at `--leverage` (5x) ticks once: its empty leg
    ///    is set to the manifest's leverage, and its entry fills isolated at
    ///    that leverage — the margin the backtest liquidates by.
    /// 2. While the leg holds that position, a request to hold it at another
    ///    leverage is refused and the leverage stays; an opening that does
    ///    not own the contracts on the leg is refused.
    /// 3. The runner flattens it, in the position's own mode.
    /// 4. A coin is bought in the mode the account level gives — `cash` is
    ///    refused on a multi-currency account.
    /// 5. The leg's leverage is put back exactly as found.
    ///
    /// Places one small perpetual position and closes it, and buys 5 USDT of
    /// BTC that stays on the demo account. Refuses to start on a leg that
    /// holds anything, and keeps the rule it checks: the leg's leverage is put
    /// back only once the leg is empty again — never under a position.
    @MainActor
    static func leverageDemo(_ raw: [String]) async -> Bool {
        var flags: [String: String] = [:]
        var index = 0
        while index < raw.count {
            if raw[index].hasPrefix("--"), index + 1 < raw.count {
                flags[String(raw[index].dropFirst(2))] = raw[index + 1]
                index += 2
            } else {
                index += 1
            }
        }
        let instId = flags["inst"] ?? "ETH-USDT-SWAP"
        let leverage = Double(flags["leverage"] ?? "") ?? 5
        let notional = Double(flags["notional"] ?? "") ?? 300

        print("MayStock leverage demo · \(instId) · 清单 \(PriceFormatter.plain(leverage))x · 模拟盘 · \(Date())")
        let config = ConfigIO(directory: ConfigIO.defaultDirectory()).load()
        let bridge = TradeBridge(prefs: config.trading)
        let venue = OKXVenue(bridge: bridge)
        let trade = KernelTradeClient(bridge: bridge)
        var ok = true

        // What the account is, and what the leg holds before anything moves.
        let account: AccountTradingConfig
        do {
            account = try await venue.accountTradingConfig(mode: .demo)
        } catch {
            fail("账户配置", String(describing: error)); return false
        }
        pass("账户配置", "acctLv \(account.accountLevel.map(String.init) ?? "—") · \(account.positionMode?.rawValue ?? "—")")
        let leg: PositionSide = account.positionMode == .net ? .net : .long
        func legLeverage() async -> Double? {
            (try? await trade.leverage(instId: instId, marginMode: "isolated", mode: .demo))?
                .first { $0.posSide == leg }?.leverage
        }
        func heldOnLeg() async throws -> Double {
            try await venue.positions(mode: .demo, instType: .swap)
                .filter { $0.instId == instId && $0.posSide == leg && $0.marginMode == .isolated }
                .reduce(0) { $0 + $1.quantity }
        }
        guard let found = await legLeverage() else {
            fail("读杠杆", "读不到 \(instId) 逐仓 \(leg.rawValue) 的杠杆"); return false
        }
        do {
            let held = try await heldOnLeg()
            guard abs(held) < 1e-9 else {
                fail("起点", "\(instId) 逐仓 \(leg.rawValue) 上已有 \(PriceFormatter.plain(held)) 张，不在别人的仓位上做实验")
                return false
            }
        } catch {
            fail("读持仓", String(describing: error)); return false
        }
        pass("起点", "\(instId) 逐仓 \(leg.rawValue) 空仓，杠杆 \(PriceFormatter.plain(found))x")

        // --- 1. The runner opens: the empty leg is set, the entry is isolated.
        //
        // A strategy id of this run's own: the books are rebuilt from the
        // venue's last three days of fills by tag, and an earlier run's
        // entry carries the same tag as a fixed id would — a fresh ledger
        // would book a position this run never opened.
        let manifest = StrategyManifest(
            id: "e2e-leverage-\(Int(Date().timeIntervalSince1970))",
            name: "模拟盘杠杆验收",
            market: StrategyMarket(instId: instId, instType: .swap, bar: .h1),
            signals: StrategySignals(longEntry: "close > 0"),
            sizing: StrategySizing(mode: .fixedQuote, value: notional),
            risk: StrategyRisk(leverage: leverage))
        let strategy: CompiledStrategy
        do {
            strategy = try manifest.compile()
        } catch {
            fail("清单", String(describing: error)); return false
        }
        let host = DemoStrategyHost(strategy: strategy, capital: notional, venue: venue)
        let runner = StrategyRunner(host: host)
        // However the run ends: the position closed by the runner, and the
        // leg's leverage put back only once nothing is held on it.
        func finish(_ verdict: Bool) async -> Bool {
            var verdict = verdict
            if let open = host.ledger.position(for: strategy.id), !open.isFlat {
                await runner.flatten(strategyId: strategy.id, reason: "模拟盘杠杆验收收尾")
            }
            let left = (try? await heldOnLeg()) ?? .nan
            if abs(left) < 1e-9 {
                if !(await restore(instId: instId, leg: leg, to: found, trade: trade)) { verdict = false }
            } else {
                fail("杠杆恢复原样", "这条腿上还有 \(PriceFormatter.plain(left)) 张，持仓中不改杠杆，留在 "
                     + "\(await legLeverage().map { PriceFormatter.plain($0) + "x" } ?? "—")；平掉后请设回 "
                     + "\(PriceFormatter.plain(found))x")
                verdict = false
            }
            for halt in host.halts { fail("熔断", halt) }
            if !host.halts.isEmpty { verdict = false }
            print(verdict ? "\nleverage demo: PASS" : "\nleverage demo: FAIL")
            return verdict
        }
        // A fill is booked on the tick after its order, from the venue's own
        // listing: tick until the books show it.
        func settle(until booked: (StrategyPositionState?) -> Bool) async -> Int {
            for attempt in 1...6 {
                if booked(host.ledger.position(for: strategy.id)) { return attempt - 1 }
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                await runner.tick()
            }
            return booked(host.ledger.position(for: strategy.id)) ? 6 : -1
        }
        await runner.tick()
        let entry = runner.state(for: strategy.id)
        print("  · 运行器：\(entry.status.displayName) · \(entry.message ?? "—")")
        let atEntry = await legLeverage()
        let leverageHeld = atEntry.map { abs($0 - leverage) < 0.005 } ?? false
        (leverageHeld ? pass : fail)("空腿设成清单杠杆",
            "\(PriceFormatter.plain(found))x → \(atEntry.map { PriceFormatter.plain($0) + "x" } ?? "读不到")")
        if !leverageHeld { ok = false }
        let ticks = await settle { $0.map { !$0.isFlat } ?? false }
        guard ticks >= 0, let opened = host.ledger.position(for: strategy.id), !opened.isFlat else {
            fail("开仓", "台账没有仓位：\(runner.state(for: strategy.id).message ?? "无说明")")
            return await finish(false)
        }
        pass("开仓入账", "\(PriceFormatter.plain(opened.quantity)) 张 @ \(PriceFormatter.money(opened.averagePrice))"
             + (ticks > 0 ? "（成交在第 \(ticks + 1) 轮入账）" : ""))
        do {
            let positions = try await venue.positions(mode: .demo, instType: .swap)
            if let mine = positions.first(where: { $0.instId == instId && $0.posSide == leg }) {
                let notionalHeld = abs(mine.quantity) * (opened.contractSize ?? 0) * mine.averagePrice
                let expectedMargin = notionalHeld / leverage
                let isolated = mine.marginMode == .isolated
                let atLeverage = mine.leverage.map { abs($0 - leverage) < 0.005 } ?? false
                // The margin the exchange holds is the backtest's: notional
                // over the manifest's leverage, give or take the fill.
                let marginAgrees = mine.margin.map { abs($0 - expectedMargin) / expectedMargin < 0.02 } ?? false
                (isolated && atLeverage && marginAgrees ? pass : fail)("成交按清单的保证金",
                    "\(mine.marginMode?.displayName ?? "—") · \(mine.leverage.map(PriceFormatter.plain) ?? "—")x · "
                    + "\(PriceFormatter.plain(mine.quantity)) 张 · 保证金 \(mine.margin.map { PriceFormatter.money($0) } ?? "—")"
                    + "（名义 \(PriceFormatter.money(notionalHeld)) ÷ \(PriceFormatter.plain(leverage)) = "
                    + "\(PriceFormatter.money(expectedMargin))）")
                if !(isolated && atLeverage && marginAgrees) { ok = false }
            } else {
                fail("交易所持仓", "交易所没有 \(instId) \(leg.rawValue) 仓位"); ok = false
            }
        } catch {
            fail("交易所持仓", String(describing: error)); ok = false
        }

        // --- 2. A held leg is never changed; someone else's is never joined.
        let held = opened.quantity
        func prepare(_ intent: LegPreparation.Intent, held: Double) async -> Result<LegReadiness, Error> {
            do {
                return .success(try await venue.prepareLeg(LegPreparation(
                    instId: instId, instType: .swap, posSide: leg, accountLevel: account.accountLevel,
                    held: held, lot: 0.01, intent: intent), mode: .demo, liveUnlocked: false))
            } catch {
                return .failure(error)
            }
        }
        expectBlocked(await prepare(.open(leverage: leverage * 2), held: held), code: "heldAtOtherLeverage",
                      label: "持仓中不改杠杆", ok: &ok)
        let afterRefusal = await legLeverage()
        let unchanged = afterRefusal.map { abs($0 - leverage) < 0.005 } ?? false
        (unchanged ? pass : fail)("杠杆没动", afterRefusal.map { PriceFormatter.plain($0) + "x" } ?? "读不到")
        if !unchanged { ok = false }
        expectBlocked(await prepare(.open(leverage: leverage), held: 0), code: "foreignPosition",
                      label: "不并进不是自己的仓位", ok: &ok)
        switch await prepare(.reduce, held: held) {
        case .success(let ready):
            (ready.tradeMode == "isolated" ? pass : fail)("减仓按仓位自己的模式", ready.marginText ?? "—")
            if ready.tradeMode != "isolated" { ok = false }
        case .failure(let error):
            fail("减仓按仓位自己的模式", String(describing: error)); ok = false
        }

        // --- 3. The runner closes it, in the position's own mode.
        await runner.flatten(strategyId: strategy.id, reason: "模拟盘杠杆验收平仓")
        let exit = runner.state(for: strategy.id)
        print("  · 运行器：\(exit.status.displayName) · \(exit.message ?? "—")")
        _ = await settle { $0?.isFlat ?? true }
        do {
            let left = try await heldOnLeg()
            (abs(left) < 1e-9 ? pass : fail)("平仓", abs(left) < 1e-9
                ? "已无 \(instId) 逐仓 \(leg.rawValue) 仓位"
                : "仍有 \(PriceFormatter.plain(left)) 张，请到模拟盘手动处理")
            if abs(left) >= 1e-9 { ok = false }
        } catch {
            fail("平仓", String(describing: error)); ok = false
        }

        // --- 4. A coin, in the account's mode.
        switch await Result(catching: {
            try await venue.prepareLeg(LegPreparation(
                instId: "BTC-USDT", instType: .spot, posSide: nil, accountLevel: account.accountLevel,
                held: nil, lot: 0, intent: .open(leverage: nil)), mode: .demo, liveUnlocked: false)
        }) {
        case .success(let ready):
            do {
                let result = try await venue.place(OrderRequest(
                    instId: "BTC-USDT", instType: .spot, side: .buy, kind: .market, size: 5, sizeUnit: .quote,
                    clOrdId: OrderTag.make(strategyId: "e2e-spot"), tradeMode: ready.tradeMode),
                    mode: .demo, liveUnlocked: false)
                pass("现货按账户等级的模式成交", "\(ready.marginText ?? "—") · 买入 5 USDT 的 BTC · ordId \(result.ordId)（留在模拟盘）")
            } catch {
                fail("现货按账户等级的模式成交", "\(ready.marginText ?? "—")：\(error)"); ok = false
            }
        case .failure(let error):
            fail("现货的模式", String(describing: error)); ok = false
        }

        // --- 5. As found.
        return await finish(ok)
    }

    private static func expectBlocked(_ result: Result<LegReadiness, Error>, code: String, label: String, ok: inout Bool) {
        switch result {
        case .failure(let blocked as LegBlocked) where blocked.code == code:
            pass(label, blocked.reason)
        case .failure(let error):
            fail(label, "拦下了，但原因不对：\(error)"); ok = false
        case .success(let ready):
            fail(label, "没有拦下：\(ready)"); ok = false
        }
    }

    /// Put the leg back at the leverage it was found at, and read it back.
    @discardableResult
    private static func restore(instId: String, leg: PositionSide, to leverage: Double, trade: KernelTradeClient) async -> Bool {
        do {
            _ = try await trade.send(.setLeverage(
                instId: instId, instType: .swap, marginMode: "isolated",
                posSide: leg == .net ? nil : leg, leverage: leverage), mode: .demo, liveUnlocked: false)
            let now = try await trade.leverage(instId: instId, marginMode: "isolated", mode: .demo)
                .first { $0.posSide == leg }?.leverage
            let restored = now.map { abs($0 - leverage) < 0.005 } ?? false
            (restored ? pass : fail)("杠杆恢复原样", now.map { PriceFormatter.plain($0) + "x" } ?? "读不到")
            return restored
        } catch {
            fail("杠杆恢复原样", "\(error)；请到模拟盘把 \(instId) 逐仓 \(leg.rawValue) 设回 \(PriceFormatter.plain(leverage))x")
            return false
        }
    }
}

extension Result where Failure == Error {
    init(catching body: () async throws -> Success) async {
        do { self = .success(try await body()) } catch { self = .failure(error) }
    }
}
