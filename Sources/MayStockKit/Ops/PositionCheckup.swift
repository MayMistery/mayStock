import Foundation

/// The numbers a live position is judged by, gathered in one place.
///
/// This exists because the same dozen readings were being pulled by hand,
/// repeatedly, in the middle of a trade: how close is liquidation, who is
/// crowded, where does the option book pull, is the macro tape helping. Every
/// one of them shaped a decision, and none of them lived in the app.
///
/// Four groups refresh on their own cadence and fail independently — a dead
/// macro feed must not blank out the liquidation buffer. Where a group cannot
/// be read, it says so; **nothing here ever shows a stale number as if it were
/// current**, because a number that is quietly fifteen minutes old is worse
/// than a blank one. It reads as fact and gets acted on.
///
/// Read-only by construction: nothing in this file places, amends or cancels
/// an order.
@Observable
@MainActor
public final class CheckupModel {

    // MARK: - What a group's data looks like

    /// A group's state. `failed` and `stale` are first-class so the view can
    /// say which, instead of rendering an old value silently.
    public enum Freshness: Sendable, Equatable {
        case never
        case loading
        case ok(Date)
        case failed(String, at: Date)

        public var asOf: Date? {
            switch self {
            case .ok(let date), .failed(_, at: let date): return date
            case .never, .loading: return nil
            }
        }
        public var errorText: String? {
            if case .failed(let message, _) = self { return message }
            return nil
        }
        public func isStale(now: Date = Date(), tolerance: TimeInterval) -> Bool {
            guard case .ok(let date) = self else { return false }
            return now.timeIntervalSince(date) > tolerance
        }
    }

    // MARK: - Risk

    public struct RiskView: Sendable, Equatable {
        public var instId: String = ""
        public var posSide: PositionSide = .net
        public var contracts: Double = 0
        public var baseQuantity: Double = 0
        public var notional: Double = 0
        public var averagePrice: Double = 0
        public var markPrice: Double = 0
        public var unrealisedPnL: Double = 0
        public var liquidationPrice: Double?
        /// Percent the mark must move before liquidation.
        public var liquidationBuffer: Double?
        public var margin: Double = 0
        /// Maintenance requirement, and the exchange's own health ratio for the
        /// position. Both come from the venue; the ratio is what it would
        /// liquidate on.
        public var maintenanceMargin: Double?
        public var marginRatio: Double?
        public var equity: Double = 0
        public var leverageSetting: Double?
        /// Notional against equity — the leverage that decides survival,
        /// which the contract's own setting routinely misstates.
        public var exposure: OptionGravity.Exposure?
        public var protectiveOrders: [VenueProtectiveOrder] = []
        /// Funding booked on this position so far, in quote currency.
        public var fundingCollected: Double = 0
        public var fundingPaymentCount: Int = 0
        /// Liquidation odds at 1, 3 and 7 days, from implied vol.
        public var liquidationOdds: [OptionGravity.LiquidationOdds] = []

        public var isShort: Bool { posSide == .short || contracts < 0 }
        public var hasPosition: Bool { contracts != 0 }
    }

    // MARK: - Perpetual structure

    public struct StructureView: Sendable, Equatable {
        public var fundingRate: Double?
        public var nextFundingTime: Date?
        /// Exchanges cap the rate; sitting at the cap means one side is paying
        /// the most it can to stay in, which is a crowding reading in itself.
        public var fundingCapPct: Double = 0.01
        public var openInterest: Double?
        public var openInterestUsd: Double?
        public var openInterestChange1h: Double?
        public var openInterestChange4h: Double?
        public var positioning: DerivativesFeed.Positioning?

        public var isFundingAtCap: Bool {
            guard let fundingRate else { return false }
            return abs(fundingRate) * 100 >= fundingCapPct * 0.95
        }
        /// Positive funding means longs pay shorts.
        public var longsPayShorts: Bool { (fundingRate ?? 0) > 0 }
    }

    // MARK: - Option gravity

    public struct ExpiryView: Sendable, Equatable, Identifiable {
        public let expiry: Date
        public let hoursRemaining: Double
        public let atmIV: Double?
        public let maxPain: OptionGravity.MaxPain?
        public let oneSigma: Double?
        /// Underlying value the open contracts represent.
        public let notionalUsd: Double
        /// What those contracts are actually worth. Shown beside the notional
        /// because the two differ by orders of magnitude on a far-dated chain,
        /// and reading the larger one as money at risk is a real trap.
        public let marketValueUsd: Double?
        public let skew: OptionGravity.Skew?
        public let contractCount: Int

        public var id: Date { expiry }
    }

    public struct GravityView: Sendable, Equatable {
        public var spot: Double = 0
        public var expiries: [ExpiryView] = []
        /// Strike-by-strike open interest for the nearest meaningful expiry.
        public var nearStrikes: [OptionGravity.StrikeInterest] = []
        public var nearExpiry: Date?
    }

    // MARK: - State

    public private(set) var risk = RiskView()
    public private(set) var riskState: Freshness = .never
    public private(set) var structure = StructureView()
    public private(set) var structureState: Freshness = .never
    public private(set) var gravity = GravityView()
    public private(set) var gravityState: Freshness = .never
    public private(set) var macro: [DerivativesFeed.MacroQuote] = []
    public private(set) var macroState: Freshness = .never

    /// The instrument under review. Set explicitly by callers that know it
    /// (a deep link naming one), otherwise discovered from the account — see
    /// `adoptHeldPosition`.
    public var instId: String {
        didSet { if instId != oldValue { resetForInstrument() } }
    }
    /// When true, `refreshRisk` replaces `instId` with whatever perpetual the
    /// account actually holds.
    ///
    /// Risk lives in positions, and a caller cannot know which one without
    /// asking the exchange. Assuming an instrument and reporting "flat" when
    /// the guess was wrong is the one failure mode this page must not have.
    public var followsHeldPosition: Bool
    public var mode: TradingMode

    private let venue: any ExchangeVenue
    private let feed: DerivativesFeed
    private let okx: OKXRESTClient
    private var tasks: [Task<Void, Never>] = []

    /// How often each group refreshes. Risk leads because it is the one that
    /// can end the position; macro trails because it moves slowly.
    public static let riskInterval: TimeInterval = 10
    public static let structureInterval: TimeInterval = 30
    public static let gravityInterval: TimeInterval = 60
    public static let macroInterval: TimeInterval = 60
    /// Past this, a reading is called out as stale rather than shown plainly.
    public static let staleTolerance: TimeInterval = 300

    public init(
        venue: any ExchangeVenue,
        mode: TradingMode,
        instId: String = "ETH-USDT-SWAP",
        followsHeldPosition: Bool = true,
        feed: DerivativesFeed = DerivativesFeed(),
        okx: OKXRESTClient = OKXRESTClient()
    ) {
        self.venue = venue
        self.mode = mode
        self.instId = instId
        self.followsHeldPosition = followsHeldPosition
        self.feed = feed
        self.okx = okx
    }

    private func resetForInstrument() {
        risk = RiskView()
        structure = StructureView()
        gravity = GravityView()
        riskState = .never
        structureState = .never
        gravityState = .never
    }

    // MARK: - Polling

    /// Start the four refresh loops. Safe to call again; it restarts them.
    public func start() {
        stop()
        tasks = [
            loop(Self.riskInterval) { [weak self] in await self?.refreshRisk() },
            loop(Self.structureInterval) { [weak self] in await self?.refreshStructure() },
            loop(Self.gravityInterval) { [weak self] in await self?.refreshGravity() },
            loop(Self.macroInterval) { [weak self] in await self?.refreshMacro() },
        ]
    }

    public func stop() {
        tasks.forEach { $0.cancel() }
        tasks = []
    }

    /// Refresh everything now, in parallel, without disturbing the loops.
    public func refreshAll() async {
        async let a: Void = refreshRisk()
        async let b: Void = refreshStructure()
        async let c: Void = refreshGravity()
        async let d: Void = refreshMacro()
        _ = await (a, b, c, d)
    }

    private func loop(
        _ interval: TimeInterval, _ body: @escaping @Sendable () async -> Void
    ) -> Task<Void, Never> {
        Task { @MainActor in
            while !Task.isCancelled {
                await body()
                try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
            }
        }
    }

    // MARK: - Risk

    /// Read positions and the account, and adopt whichever perpetual is held.
    ///
    /// Exposed rather than private so the risk group can be driven on its own —
    /// it is the group whose failure mode is a confident lie about whether a
    /// position exists, and that deserves a test.
    public func refreshRisk() async {
        if case .never = riskState { riskState = .loading }
        do {
            async let positionsTask = venue.allPositions(mode: mode)
            async let snapshotTask = venue.accountSnapshot(mode: mode)
            let (positions, snapshot) = try await (positionsTask, snapshotTask)

            // Which position is "the" position? Ask the account, not a guess.
            // A perpetual is where the risk is; the instrument the page was
            // constructed with is only a default for when nothing is open.
            if followsHeldPosition,
               let held = positions.first(where: { $0.instId.hasSuffix("-SWAP") }),
               held.instId != instId {
                Log.warn("checkup: 跟随持仓切换到 \(held.instId)（原 \(instId)）")
                instId = held.instId
            }

            var view = RiskView()
            view.instId = instId
            view.equity = snapshot.totalEquity ?? 0

            if let position = positions.first(where: { $0.instId == instId }) {
                view.posSide = position.posSide
                view.contracts = position.quantity
                view.averagePrice = position.averagePrice
                view.markPrice = position.markPrice ?? position.averagePrice
                view.unrealisedPnL = position.unrealisedPnL
                view.liquidationPrice = position.liquidationPrice
                view.leverageSetting = position.leverage
                view.notional = position.notionalUsd ?? 0
                view.margin = position.margin ?? 0
                view.maintenanceMargin = position.maintenanceMargin
                view.marginRatio = position.marginRatio
                if view.markPrice > 0, view.notional > 0 {
                    view.baseQuantity = view.notional / view.markPrice
                }
                if let liq = position.liquidationPrice, view.markPrice > 0 {
                    view.liquidationBuffer = OptionGravity.liquidationBuffer(
                        mark: view.markPrice, liquidationPrice: liq, isShort: view.isShort)
                }
                view.exposure = OptionGravity.Exposure(
                    notional: view.notional, equity: view.equity, margin: view.margin)

                // Liquidation odds need a vol; the option chain is the source
                // already being polled for gravity.
                if let liq = position.liquidationPrice, view.markPrice > 0,
                   let iv = gravity.expiries.compactMap(\.atmIV).first {
                    view.liquidationOdds = [24.0, 72.0, 168.0].compactMap {
                        OptionGravity.liquidationOdds(
                            spot: view.markPrice, liquidationPrice: liq,
                            iv: iv / 100, hours: $0, isShort: view.isShort)
                    }
                }
            }

            // Protective orders and funding are useful but not essential; a
            // failure there must not blank the risk panel.
            if let orders = try? await venue.protectiveOrders(
                instId: instId, instType: .swap, mode: mode) {
                view.protectiveOrders = orders
            }
            if let payments = try? await venue.fundingPayments(instId: instId, mode: mode) {
                view.fundingCollected = payments.reduce(0) { $0 + $1.amount }
                view.fundingPaymentCount = payments.count
            }

            risk = view
            riskState = .ok(Date())
            // Recorded because this panel's failure mode is silence: an empty
            // card and a failed read look the same on screen, and the only way
            // to tell them apart afterwards is a line saying what was found.
            Log.warn("""
                checkup: \(instId) \(view.hasPosition ? "持有" : "无持仓") \
                张数=\(PriceFormatter.plain(view.contracts)) \
                缓冲=\(view.liquidationBuffer.map { PriceFormatter.plain($0) } ?? "—")% \
                保证金=\(PriceFormatter.plain(view.margin)) \
                保证金率=\(view.marginRatio.map { PriceFormatter.plain($0) } ?? "—") \
                条件单=\(view.protectiveOrders.count)
                """)
        } catch {
            riskState = .failed(describe(error), at: Date())
            Log.warn("checkup: 读取持仓失败：\(describe(error))")
        }
    }

    // MARK: - Structure

    private func refreshStructure() async {
        if case .never = structureState { structureState = .loading }
        var view = structure
        var anySucceeded = false
        var failures: [String] = []

        struct FundingRow: Decodable { let fundingRate: String?; let nextFundingTime: String? }
        if let rows = try? await okx.getRaw(
            FundingRow.self, path: "api/v5/public/funding-rate",
            query: ["instId": instId]), let row = rows.first {
            view.fundingRate = row.fundingRate.flatMap(Double.init)
            view.nextFundingTime = row.nextFundingTime.flatMap(Double.init)
                .map { Date(timeIntervalSince1970: $0 / 1000) }
            anySucceeded = true
        } else {
            failures.append("资金费率")
        }

        struct OIRow: Decodable { let oi: String?; let oiUsd: String? }
        if let rows = try? await okx.getRaw(
            OIRow.self, path: "api/v5/public/open-interest",
            query: ["instType": "SWAP", "instId": instId]), let row = rows.first {
            view.openInterest = row.oi.flatMap(Double.init)
            view.openInterestUsd = row.oiUsd.flatMap(Double.init)
            anySucceeded = true
        } else {
            failures.append("未平仓量")
        }

        // Trend matters more than level: rising OI into a move is new money,
        // falling OI is an unwind.
        if let history = try? await feed.openInterestHistory(
            symbol: binanceSymbol, period: "1h", limit: 5), history.count >= 2 {
            let latest = history.last!.contracts
            if let prior = history.dropLast().last?.contracts, prior > 0 {
                view.openInterestChange1h = (latest / prior - 1) * 100
            }
            if let oldest = history.first?.contracts, oldest > 0, history.count >= 5 {
                view.openInterestChange4h = (latest / oldest - 1) * 100
            }
            anySucceeded = true
        } else {
            failures.append("OI 变化")
        }

        if let positioning = try? await feed.positioning(symbol: binanceSymbol) {
            view.positioning = positioning
            anySucceeded = true
        } else {
            failures.append("多空比")
        }

        structure = view
        structureState = anySucceeded
            ? (failures.isEmpty ? .ok(Date()) : .failed("部分取数失败：\(failures.joined(separator: "、"))", at: Date()))
            : .failed("全部取数失败", at: Date())
    }

    /// OKX perpetual ids map onto Binance's symbol for the positioning feeds.
    private var binanceSymbol: String {
        instId.replacingOccurrences(of: "-SWAP", with: "")
            .replacingOccurrences(of: "-", with: "")
    }

    // MARK: - Gravity

    /// One row of OKX's option summary: the whole chain, IV and greeks
    /// included, arrives in a single call.
    private struct OptSummaryRow: Decodable {
        let instId: String
        let markVol: String?
        let ts: String?
    }
    /// Open interest per contract. **This is where option OI lives** —
    /// `market/tickers` carries none, which silently produced an empty chain
    /// until the endpoint was actually inspected.
    private struct OptOIRow: Decodable {
        let instId: String
        let oi: String?
        let oiUsd: String?
    }
    private struct OptMarkRow: Decodable {
        let instId: String
        let markPx: String?
    }

    private func refreshGravity() async {
        if case .never = gravityState { gravityState = .loading }
        let underlying = optionUnderlying
        do {
            async let summaryTask = okx.getRaw(
                OptSummaryRow.self, path: "api/v5/public/opt-summary",
                query: ["uly": underlying])
            async let oiTask = okx.getRaw(
                OptOIRow.self, path: "api/v5/public/open-interest",
                query: ["instType": "OPTION", "uly": underlying])
            async let markTask = okx.getRaw(
                OptMarkRow.self, path: "api/v5/public/mark-price",
                query: ["instType": "OPTION", "uly": underlying])
            async let spotTask = venue.indexPrice(underlying: underlying, mode: mode)
            let (summary, openInterest, marks, spot) =
                try await (summaryTask, oiTask, markTask, spotTask)
            guard spot > 0 else { throw DerivativesFeed.FeedError.empty("index \(underlying)") }

            let ivByInst = Dictionary(
                summary.compactMap { row -> (String, Double)? in
                    // markVol is a fraction (0.2749); show it as a percentage.
                    guard let vol = row.markVol.flatMap(Double.init), vol > 0 else { return nil }
                    return (row.instId, vol * 100)
                }, uniquingKeysWith: { first, _ in first })
            let markByInst = Dictionary(
                marks.compactMap { row -> (String, Double)? in
                    guard let px = row.markPx.flatMap(Double.init), px > 0 else { return nil }
                    return (row.instId, px)
                }, uniquingKeysWith: { first, _ in first })

            struct Leg {
                let strike: Double
                let kind: OptionKind
                let oi: Double
                let oiUsd: Double?
                let mark: Double?
                let iv: Double?
            }
            var byExpiry: [Date: [Leg]] = [:]
            for row in openInterest {
                // The same underlying lists a USDT-margined family
                // (`ETH-USD_UM-…`) alongside the coin-margined one. Mixing the
                // two would double-count the book and misprice max pain.
                guard row.instId.hasPrefix("\(underlying)-"),
                      let parsed = Self.parseOptionId(row.instId),
                      let oi = row.oi.flatMap(Double.init), oi > 0
                else { continue }
                byExpiry[parsed.expiry, default: []].append(
                    Leg(strike: parsed.strike, kind: parsed.kind, oi: oi,
                        oiUsd: row.oiUsd.flatMap(Double.init),
                        mark: markByInst[row.instId],
                        iv: ivByInst[row.instId]))
            }

            let contractValue = Self.contractValue(for: underlying)
            let now = Date()
            var views: [ExpiryView] = []
            for (expiry, legs) in byExpiry where expiry > now {
                let hours = expiry.timeIntervalSince(now) / 3600
                var byStrike: [Double: (call: Leg?, put: Leg?)] = [:]
                for leg in legs {
                    var entry = byStrike[leg.strike] ?? (nil, nil)
                    if leg.kind == .call { entry.call = leg } else { entry.put = leg }
                    byStrike[leg.strike] = entry
                }
                let interests = byStrike.map { strike, pair in
                    OptionGravity.StrikeInterest(
                        strike: strike,
                        callOI: pair.call?.oi ?? 0, putOI: pair.put?.oi ?? 0,
                        callMark: pair.call?.mark, putMark: pair.put?.mark)
                }
                // The exchange states the notional itself (`oiUsd`); premiums
                // have to be valued. Both are kept: on a far-dated chain they
                // differ by a factor of twenty-five, and reading the notional
                // as money at risk turns cheap tail insurance into a thesis.
                let notional = legs.compactMap(\.oiUsd).reduce(0, +)
                let marketValues = interests.compactMap {
                    $0.marketValue(spot: spot, contractValue: contractValue)
                }
                let iv = OptionGravity.atmIV(
                    legs.map { ($0.strike, $0.iv) }, spot: spot)
                views.append(ExpiryView(
                    expiry: expiry,
                    hoursRemaining: hours,
                    atmIV: iv,
                    maxPain: OptionGravity.maxPain(interests, spot: spot),
                    oneSigma: iv.flatMap {
                        OptionGravity.oneSigma(spot: spot, iv: $0 / 100, hours: hours)
                    },
                    notionalUsd: notional,
                    marketValueUsd: marketValues.isEmpty ? nil : marketValues.reduce(0, +),
                    skew: OptionGravity.skew25d(
                        legs.map { ($0.strike, $0.kind, $0.iv) },
                        spot: spot, hoursToExpiry: hours),
                    contractCount: legs.count))
            }
            views.sort { $0.expiry < $1.expiry }

            var view = GravityView()
            view.spot = spot
            view.expiries = Array(views.prefix(8))
            // Strike detail for the nearest expiry that is not minutes from
            // settling — the one whose hedging flow still has time to act.
            if let near = views.first(where: { $0.hoursRemaining > 1 }) ?? views.first,
               let legs = byExpiry[near.expiry] {
                var byStrike: [Double: (call: Double, put: Double)] = [:]
                for leg in legs {
                    var entry = byStrike[leg.strike] ?? (0, 0)
                    if leg.kind == .call { entry.call += leg.oi } else { entry.put += leg.oi }
                    byStrike[leg.strike] = entry
                }
                view.nearExpiry = near.expiry
                view.nearStrikes = byStrike
                    .map { OptionGravity.StrikeInterest(
                        strike: $0.key, callOI: $0.value.call, putOI: $0.value.put) }
                    .filter { abs($0.strike - spot) / spot < 0.06 && $0.totalOI > 0 }
                    .sorted { $0.strike < $1.strike }
            }
            gravity = view
            gravityState = .ok(Date())
        } catch {
            gravityState = .failed(describe(error), at: Date())
        }
    }

    /// `ETH-USDT-SWAP` → `ETH-USD`, the index its options settle against.
    private var optionUnderlying: String {
        let base = instId.split(separator: "-").first.map(String.init) ?? "ETH"
        return "\(base)-USD"
    }

    /// Underlying units per contract: 0.1 ETH, 0.01 BTC.
    static func contractValue(for underlying: String) -> Double {
        underlying.hasPrefix("BTC") ? 0.01 : 0.1
    }

    /// `ETH-USD-260925-2600-C` → expiry, strike, kind.
    static func parseOptionId(_ instId: String) -> (expiry: Date, strike: Double, kind: OptionKind)? {
        let parts = instId.split(separator: "-")
        guard parts.count == 5, let strike = Double(parts[3]) else { return nil }
        let kind: OptionKind = parts[4] == "C" ? .call : .put
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let formatter = DateFormatter()
        formatter.dateFormat = "yyMMdd"
        formatter.timeZone = calendar.timeZone
        guard let day = formatter.date(from: String(parts[2])) else { return nil }
        // OKX settles options at 08:00 UTC.
        guard let expiry = calendar.date(byAdding: .hour, value: 8, to: day) else { return nil }
        return (expiry, strike, kind)
    }

    // MARK: - Macro

    private func refreshMacro() async {
        if case .never = macroState { macroState = .loading }
        let quotes = await feed.macroSnapshot()
        if quotes.isEmpty {
            macroState = .failed("宏观取数全部失败", at: Date())
        } else {
            macro = quotes
            let missing = DerivativesFeed.macroSymbols.count - quotes.count
            macroState = missing > 0
                ? .failed("\(missing) 个标的取数失败", at: Date())
                : .ok(Date())
        }
    }

    private func describe(_ error: any Error) -> String {
        (error as? TradeError)?.description
            ?? (error as? DerivativesFeed.FeedError)?.description
            ?? String(describing: error)
    }
}
