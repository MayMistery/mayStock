import Foundation
import MayStockKit

extension E2EMain {

    /// The checkup of a US share against Schwab itself: the live layer with
    /// the share under review, its option chain read and fitted, and — for
    /// each contract named — the contract streamed and checked field by field
    /// against Schwab's REST quote for it, which is how the stream's field
    /// numbers (`schwab::OPTION_FIELDS`, from the Streamer Guide's numbering)
    /// are known to be the right ones.
    ///
    /// The account is the real one, read once through `schwabctl account`
    /// and handed in as the app hands it. A named contract the account does
    /// not hold is added to that reading as a one-contract **probe**, so the
    /// stream subscribes to it; the probe exists only inside this run and is
    /// said to be one. Places nothing.
    ///
    /// `fixture` names a file to write the account reading the run handed
    /// in — probes included — as `[{"topic","payload"}]`, for
    /// `MayStock --snapshot … --live-fixture` to draw the checkup holding
    /// them.
    static func liveUSDoctor(symbol: String, seconds: Int, contracts: [String], fixture: URL? = nil) async -> Bool {
        print("US checkup doctor: \(symbol) (\(seconds) s)\(contracts.isEmpty ? "" : " · probing \(contracts.joined(separator: ", "))")")
        let config = ConfigIO(directory: ConfigIO.defaultDirectory()).load()
        let schwab = SchwabBridge(prefs: config.trading)
        guard let schwabctl = schwab.resolveCLIPath() else {
            fail("schwabctl", "not found")
            return false
        }
        let rest = SchwabRESTClient(tokens: SchwabCLITokenSource(bridge: schwab))
        // What Schwab's REST quote says of each contract, to hold the stream to.
        var quotes: [String: (ticker: Ticker, terms: SchwabOptionQuoteTerms, raw: [String: Any])] = [:]
        for contract in contracts {
            do {
                let (ticker, terms) = try await rest.optionQuote(contract)
                let data = try await rest.get(SchwabAPI.quotes(symbols: [contract]))
                let raw = ((try JSONSerialization.jsonObject(with: data) as? [String: Any])?[contract] as? [String: Any])?["quote"] as? [String: Any] ?? [:]
                quotes[contract] = (ticker, terms, raw)
                pass("REST quote \(contract.trimmingCharacters(in: .whitespaces))", "bid \(ticker.bid ?? 0) ask \(ticker.ask ?? 0) last \(ticker.last)")
            } catch {
                fail("REST quote \(contract)", String(describing: error))
                return false
            }
        }

        let kernel: LiveKernel
        do {
            kernel = try LiveKernel(config: LiveKernel.Config(
                instId: symbol, followsHeldPosition: false, mode: .live,
                okxProfile: nil, okxConfigPath: nil, schwabctlPath: schwabctl,
                reviewMarket: LiveSnapshot.Reviewable.usEquity))
        } catch {
            fail("start", String(describing: error))
            return false
        }
        defer { kernel.stop() }

        // The account as the app hands it, with the probes added.
        do {
            let raw = try await schwab.accountDocument()
            var document = try JSONSerialization.jsonObject(with: raw) as? [String: Any] ?? [:]
            var account = document["securitiesAccount"] as? [String: Any] ?? [:]
            var positions = account["positions"] as? [[String: Any]] ?? []
            for (contract, quote) in quotes where !positions.contains(where: { (($0["instrument"] as? [String: Any])?["symbol"] as? String) == contract }) {
                let mark = quote.ticker.last
                positions.append([
                    "longQuantity": 1, "shortQuantity": 0, "averagePrice": mark, "marketValue": mark * quote.terms.multiplier,
                    "longOpenProfitLoss": 0,
                    "instrument": ["assetType": "OPTION", "symbol": contract, "underlyingSymbol": quote.terms.underlying,
                                   "optionMultiplier": quote.terms.multiplier] as [String: Any],
                ])
                print("  · probe: 1 张 \(contract.trimmingCharacters(in: .whitespaces)) added to this run's reading (not on the account)")
            }
            account["positions"] = positions
            document["securitiesAccount"] = account
            let read = try SchwabAccount.read(try JSONSerialization.data(withJSONObject: document))
            let payload = "{\"source\":\"schwab\",\"account\":\(read.document)}"
            try kernel.ingest(topic: SchwabVenue.accountTopic, payload: payload)
            if let fixture {
                let documents = [["topic": SchwabVenue.accountTopic, "payload": payload]]
                try JSONSerialization.data(withJSONObject: documents, options: [.prettyPrinted]).write(to: fixture)
                print("  · wrote \(fixture.path)")
            }
            pass("account handed in", "\(read.positions.count) holdings, equity \(read.equity.map { String($0) } ?? "—")")
        } catch {
            fail("account", String(describing: error))
            return false
        }

        var seq: UInt64 = 0
        var latest: LiveSnapshot?
        let started = Date()
        while Date().timeIntervalSince(started) < Double(seconds) {
            if let (next, json) = kernel.snapshot(since: seq) {
                seq = next
                do {
                    latest = try JSONDecoder().decode(LiveSnapshot.self, from: json)
                } catch {
                    fail("snapshot decode", String(describing: error))
                    return false
                }
            }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        guard let snapshot = latest else {
            fail("snapshot", "none arrived")
            return false
        }
        report(snapshot)

        var ok = true
        for id in ["schwab", "schwab.chain"] {
            if let feed = snapshot.feed(id), feed.isLive { pass(feed.label) } else {
                fail(id, snapshot.feed(id)?.detail ?? "not live")
                ok = false
            }
        }
        if snapshot.probability.columns.isEmpty { fail("价格区间概率", "no columns"); ok = false }
        else { pass("价格区间概率", "\(snapshot.probability.columns.count) 个到期") }
        if snapshot.gravity.expiries.isEmpty { fail("期权引力", "no expiries"); ok = false }
        else { pass("期权引力", "\(snapshot.gravity.expiries.count) 个到期") }

        // The close ticket on each probed contract, up to the request body
        // it would send — reviewed, never sent.
        for contract in quotes.keys.sorted() {
            ok = await rehearseClose(contract) && ok
        }

        // Each probed contract: streamed, and the stream's numbers are the
        // REST quote's numbers.
        for (contract, rest) in quotes {
            guard let leg = snapshot.risk.positions.first(where: { $0.instId == contract }), let option = leg.option,
                  let quote = option.quote else {
                fail(contract, "no leg in the risk card")
                ok = false
                continue
            }
            guard quote.source == "schwab.stream" else {
                fail(contract, "quoted from \(quote.source), not the stream")
                ok = false
                continue
            }
            func near(_ a: Double?, _ b: Double?, _ tolerance: Double) -> Bool {
                guard let a, let b else { return a == nil && b == nil }
                return abs(a - b) <= tolerance
            }
            let number = { (key: String) in (rest.raw[key] as? NSNumber)?.doubleValue }
            let checks: [(String, Double?, Double?, Double)] = [
                ("bid", quote.bid, rest.ticker.bid, 0.051),
                ("ask", quote.ask, rest.ticker.ask, 0.051),
                ("last", quote.last, rest.ticker.last, 0.051),
                ("delta", option.delta, number("delta"), 0.03),
                ("gamma", option.gamma, number("gamma"), 0.003),
                ("theta", option.theta, number("theta"), 0.2),
                ("vega", option.vega, number("vega"), 0.2),
                ("iv", option.iv, number("volatility"), 3),
                ("openInterest", quote.openInterest, number("openInterest"), 0.5),
            ]
            for (field, streamed, quoted, tolerance) in checks {
                if near(streamed, quoted, tolerance) {
                    pass("\(contract.trimmingCharacters(in: .whitespaces)) \(field)", "stream \(streamed.map { String($0) } ?? "—") · REST \(quoted.map { String($0) } ?? "—")")
                } else {
                    fail("\(contract.trimmingCharacters(in: .whitespaces)) \(field)", "stream \(streamed.map { String($0) } ?? "—") · REST \(quoted.map { String($0) } ?? "—")")
                    ok = false
                }
            }
        }
        return ok
    }

    /// The close ticket's path for one long contract, as `CloseTicketModel`
    /// runs it: Schwab's quote book on the kernel's spec, the kernel's plan
    /// for a limit at the mid and for a stop, and the body
    /// `SchwabVenue` would send for each. Nothing is sent.
    @MainActor
    private static func rehearseClose(_ contract: String) async -> Bool {
        let name = contract.trimmingCharacters(in: .whitespaces)
        let config = ConfigIO(directory: ConfigIO.defaultDirectory()).load()
        let schwab = SchwabBridge(prefs: config.trading)
        let tokens = SchwabCLITokenSource(bridge: schwab)
        let venue = SchwabVenue(
            data: SchwabMarketDataSource(schwab: SchwabRESTClient(tokens: tokens)), bridge: schwab,
            shadow: ShadowBook(venue: .schwab, fileURL: nil, startingCash: 0), tags: SchwabOrderTags(fileURL: nil),
            economics: ShadowBook.Economics(schedule: SchwabFeeSchedule()))
        let feed: any CloseBookFeed
        do {
            feed = try await venue.closeBook(instId: contract, instType: .option, mode: .live)
        } catch {
            fail("\(name) 平仓盘口", String(describing: error))
            return false
        }
        defer { feed.stop() }
        var book: (seq: UInt64, json: Data)?
        for _ in 0..<60 {
            if let next = feed.snapshot(since: 1) { book = next; break }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        guard let book, let document = try? JSONDecoder().decode(BookDocument.self, from: book.json),
              let bid = document.bestBid, document.bestAsk != nil else {
            fail("\(name) 平仓盘口", "没有报价")
            return false
        }
        pass("\(name) 平仓盘口", "买一 \(bid) 卖一 \(document.bestAsk ?? 0) · 档位 \(document.spec?.tickBands?.map { "≥\($0.from) 步长 \($0.tickSz)" }.joined(separator: "，") ?? "—")")
        let holding = CloseHolding(instId: contract, family: .option, isLong: true, quantity: 1, unit: "张",
                                   posSide: nil, marginMode: nil, averagePrice: bid, liquidationPrice: nil)
        var ok = true
        for ticket in [CloseTicketInput(method: .limit, size: .all, price: .mid),
                       CloseTicketInput(method: .protect, size: .all, stopLoss: bid * 0.8)] {
            let input = ClosePlanInput(
                venue: .schwab, mode: .live, holding: holding, ticket: ticket, account: nil, fees: nil,
                working: [], workingUnread: nil, clientId: OrderTag.make(strategyId: CloseTicketModel.manualTag))
            switch KernelClose.plan(input, book: book.json) {
            case .failure(let refusal):
                fail("\(name) \(ticket.method)", refusal.message)
                ok = false
            case .success(let plan):
                do {
                    let body: SchwabOrderSpec
                    switch plan.action {
                    case .place(let order):
                        body = try SchwabVenue.optionClose(order, held: 1)
                    case .placeAlgo(let algo):
                        guard case .protection(nil, let stop?, let trigger) = algo.kind else { throw TradeError.refused("不是止损") }
                        body = try SchwabVenue.optionStop(contract, size: algo.size, stopPrice: stop, trigger: trigger, held: 1)
                    default:
                        throw TradeError.refused("意外的动作 \(plan.action)")
                    }
                    pass("\(name) \(ticket.method) 复核", plan.review.headline)
                    for line in plan.review.lines + plan.review.warnings { print("      \(line)") }
                    print("      body " + String(decoding: body.bodyData, as: UTF8.self))
                } catch {
                    fail("\(name) \(ticket.method) 请求体", String(describing: error))
                    ok = false
                }
            }
        }
        return ok
    }

    private static func report(_ s: LiveSnapshot) {
        let age = { (ms: Int64?) -> String in
            guard let ms else { return "—" }
            let age = s.age(of: ms)
            return age < 1_000 ? "\(Int(age)) ms" : String(format: "%.1f s", age / 1_000)
        }
        print("\n— \(s.instrument.instId) (\(s.instrument.market)) · reviewable: " + s.reviewable.map(\.label).joined(separator: " | "))
        for feed in s.feeds {
            print("  \(feed.state.padding(toLength: 10, withPad: " ", startingAt: 0)) \(feed.label)  last frame \(age(feed.lastFrameMs))  \(feed.detail ?? "")")
        }
        if let spot = s.spot { print("  spot \(spot.value) (\(spot.source), \(age(spot.ms)))") }
        let p = s.probability
        print("  probability: \(p.smileVenue) surface \(age(p.surfaceMs)) · spot \(age(p.indexMs)) · anchor \(p.forwardAnchor ?? "—")")
        print("    edges " + p.edges.map { PriceFormatter.plain($0) }.joined(separator: " "))
        for column in p.columns {
            let cells = column.probabilities.map { String(format: "%.1f", $0 * 100) }.joined(separator: " ")
            print(String(format: "    %@ %.0fh fwd %.2f ATM IV %.1f%% %@ fit %.2f (%d quotes) | %@",
                         Date(timeIntervalSince1970: Double(column.expiryMs) / 1000).description, column.hours, column.forward,
                         column.atmIv ?? 0, column.curve, column.fitError, column.quotes, cells))
        }
        for note in p.notes { print("    note: \(note)") }
        for row in s.gravity.expiries.prefix(6) {
            print(String(format: "  gravity %.0fh OI %.0f 张 max pain %@ (%@) market value %@", row.hours, row.oiBase / s.gravity.oiPerUnit,
                         row.maxPain.map { PriceFormatter.plain($0.strike) } ?? "—",
                         row.maxPain.map { String(format: "%+.1f%%", $0.distancePct) } ?? "—",
                         row.marketValueUsd.map { PriceFormatter.compact($0) } ?? "—"))
        }
        let risk = s.risk
        print("  risk (\(risk.venue)): source \(risk.source) read \(risk.wasRead) equity \(risk.equity.map { String($0.value) } ?? "—")")
        if let exposure = risk.exposure {
            print(String(format: "    delta exposure net %.2f (long %.2f short %.2f) leverage %.3fx · +1%% → %.2f",
                         exposure.netNotional, exposure.longNotional, exposure.shortNotional, exposure.effectiveLeverage, exposure.pnlPerOnePercentRise))
        }
        for leg in risk.positions {
            guard let option = leg.option else {
                print("    \(leg.instId) \(leg.contracts) avg \(leg.averagePrice ?? 0) pnl \(leg.unrealisedPnl ?? 0)")
                continue
            }
            print("    \(option.label) × \(leg.contracts): mark \(option.quote.map { String($0.mark) } ?? "—") (\(option.quote?.source ?? "—"), \(age(option.quote?.ms)))"
                  + " pnl \(leg.unrealisedPnl.map { String(format: "%.2f", $0) } ?? "—")")
            print(String(format: "      Δ %@ Γ %@ Θ %@ V %@ IV %@ · breakeven %.2f · ITM %@ profit %@ touch %@ · max loss %@",
                         option.delta.map { String(format: "%.3f", $0) } ?? "—", option.gamma.map { String(format: "%.4f", $0) } ?? "—",
                         option.theta.map { String(format: "%.3f", $0) } ?? "—", option.vega.map { String(format: "%.3f", $0) } ?? "—",
                         option.iv.map { String(format: "%.1f%%", $0) } ?? "—", option.breakeven,
                         option.pItm.map { String(format: "%.1f%%", $0 * 100) } ?? "—",
                         option.pProfit.map { String(format: "%.1f%%", $0 * 100) } ?? "—",
                         option.pTouchStrike.map { String(format: "%.1f%%", $0 * 100) } ?? "—",
                         option.maxLoss.map { String(format: "%.0f", $0) } ?? "∞"))
        }
        for event in s.events.suffix(8) { print("  event: \(event.message)") }
    }
}
