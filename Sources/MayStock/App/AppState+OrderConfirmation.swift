import AppKit
import Foundation
import MayStockKit

/// The human gate in front of an order proposed from outside the app.
///
/// Nothing here places an order on its own. A `maystock://order?…` URL only
/// gets as far as a modal that states what would happen; the order goes to the
/// exchange when — and only when — someone reads it and clicks through. The
/// live-trading lock still applies on top of that: an unlocked account is the
/// one switch that says real money may move, and a proposal arriving by URL
/// does not get to flip it.
///
/// Three things this learned the hard way, in one evening of real use:
///
/// 1. **The price cannot be written in advance.** A thin option book walked 30%
///    in three minutes; every absolute limit was stale before it could be read.
///    A relative basis is resolved here, against the book that exists now.
/// 2. **The settlement coin has to be bought first.** An ETH option is paid for
///    in ETH; an account holding only USDT is refused by the exchange with a
///    margin error naming no amount. So the dialog covers both legs and one
///    confirmation authorises the pair.
/// 3. **The dialog can die.** The app crashed with one on screen, and the
///    proposal vanished with it. Every proposal is written to disk before the
///    dialog opens and restored on the next launch.
extension AppState {

    /// Nonces already answered in this process, so a URL delivered twice — a
    /// double click, macOS replaying its launch queue — is honoured once. The
    /// on-disk record covers the same ground across restarts.
    private static var answeredNonces: Set<String> = []

    /// The venue that owns an instrument's orders.
    ///
    /// Not the account's configured venue: an ETH option belongs to OKX even
    /// when Schwab is the venue in focus, and sending it anywhere else would
    /// be a request to the wrong exchange. The app already resolves this for
    /// every other instrument-aware path; orders go through the same rule.
    private func orderVenue(for instId: String) -> any ExchangeVenue {
        exchangeVenue(for: venue(of: instId))
    }

    private var pendingOrders: PendingOrderStore {
        PendingOrderStore(directory: PendingOrderStore.defaultDirectory())
    }

    // MARK: - Entry points

    func handleOrderURL(_ url: URL) {
        let intent: PendingOrderIntent
        do {
            intent = try PendingOrderIntent.parse(url)
        } catch {
            // A malformed proposal is reported, never guessed at. Silently
            // dropping it would leave the proposer believing it is pending.
            let reason = (error as? PendingOrderIntent.ParseError)?.description
                ?? String(describing: error)
            Log.warn("order-intent: 拒绝无法解析的 URL：\(reason)（\(url.absoluteString)）")
            Task { @MainActor in
                _ = await presentAlert(
                    title: "订单链接无效", message: reason, style: .warning, buttons: ["好"])
            }
            return
        }
        Task { @MainActor in await confirmAndPlace(intent) }
    }

    /// Proposals that outlived the process that received them. Called once at
    /// launch; see `PendingOrderStore` for why they are on disk at all.
    func restorePendingOrders() {
        let store = pendingOrders
        let (items, unreadable) = store.restorable()
        for name in unreadable {
            Log.warn("order-intent: 删除无法解析的待确认记录 \(name)")
        }
        guard !items.isEmpty else { return }
        Task { @MainActor in
            for item in items {
                switch item {
                case .pending(let record):
                    Log.warn("""
                        order-intent: 恢复未答复的待确认订单 nonce=\(record.intent.nonce)\
                        （\(Int(record.age())) 秒前收到），将按当前盘口重算限价
                        """)
                    await confirmAndPlace(record.intent, restored: true)
                case .interrupted(let record):
                    // Mid-flight when the process died. Never retried: the
                    // exchange may hold the order, and a duplicate is worse
                    // than none. The person is told to go look.
                    Self.answeredNonces.insert(record.intent.nonce)
                    store.resolve(record.intent.nonce)
                    Log.warn("""
                        order-intent: nonce=\(record.intent.nonce) 在执行中被中断，不自动重试；\
                        \(record.intent.instId) 可能已在交易所成交
                        """)
                    _ = await presentAlert(
                        title: "有一笔订单执行时被中断",
                        message: """
                            \(record.intent.instId)
                            \(Self.describe(record.intent, limit: nil))

                            App 在提交这笔订单的过程中退出了，结果不明。\
                            为避免重复下单，这里不会自动重试。

                            请到交易所核对该合约的挂单与持仓，再决定要不要重新发起。
                            """,
                        style: .critical, buttons: ["好"])
                case .stale(let record):
                    store.resolve(record.intent.nonce)
                    Log.warn("""
                        order-intent: 丢弃过期的待确认订单 nonce=\(record.intent.nonce)\
                        （\(Int(record.age())) 秒前收到，超过 \(Int(PendingOrderStore.staleAfter)) 秒）
                        """)
                }
            }
        }
    }

    // MARK: - The gate

    private func confirmAndPlace(_ intent: PendingOrderIntent, restored: Bool = false) async {
        let store = pendingOrders
        // Checking and claiming have to be the same step. Between this point
        // and the order going out sit `gatherContext`'s network calls and the
        // confirmation sheet — `beginSheetModal` suspends rather than blocks —
        // and each delivery of the URL runs in its own Task. A check that only
        // read the set let a second delivery of the same nonce walk straight
        // past it, put up a second identical dialog, and send a second order.
        // Both statements run on the main actor with nothing awaited between
        // them, so together they are atomic.
        guard Self.answeredNonces.insert(intent.nonce).inserted else {
            Log.warn("order-intent: 丢弃重复的 nonce \(intent.nonce)（\(intent.instId)）")
            return
        }

        Log.warn("""
            order-intent: \(restored ? "恢复" : "收到")待确认订单 nonce=\(intent.nonce) \
            \(intent.mode.badge) \(intent.side.rawValue) \(intent.instId) \
            \(PriceFormatter.plain(intent.size)) 张 kind=\(intent.kind.rawValue) \
            价格=\(Self.describeBasis(intent))
            """)

        // On disk before the dialog opens, so a crash cannot swallow it.
        if !restored {
            do {
                try store.save(.init(intent: intent, receivedAt: Date()))
            } catch {
                // Worth saying out loud rather than proceeding as if the safety
                // net were there.
                Log.warn("order-intent: 无法持久化 nonce=\(intent.nonce)：\(error)")
            }
            // A notification outlives the process the dialog belongs to.
            notifications.post(
                title: "待确认订单（\(intent.mode.badge)）",
                body: "\(intent.side.displayName) \(intent.instId) \(PriceFormatter.plain(intent.size)) 张",
                sound: true)
        }

        func finish(_ reason: String) {
            Self.answeredNonces.insert(intent.nonce)
            store.resolve(intent.nonce)
            Log.warn("order-intent: nonce=\(intent.nonce) 结束：\(reason)")
        }

        // The live lock, checked before anything touches the network. This
        // deliberately offers no way to unlock from here: that path stays in
        // the account page, where unlocking is a decision of its own rather
        // than a step inside someone else's order.
        if intent.mode == .live && !liveTradingUnlocked {
            finish("实盘未解锁，已拒绝")
            _ = await presentAlert(
                title: "实盘未解锁",
                message: """
                    这笔订单指向实盘，但实盘尚未解锁，已拒绝。

                    \(Self.describe(intent, limit: nil))

                    要下这笔单，先到「账户与连接」页解锁实盘，再重新发起。
                    """,
                style: .critical, buttons: ["好"])
            return
        }

        if !credentialsConfigured(for: intent.mode) {
            finish("\(intent.mode.badge) 无可用 profile")
            _ = await presentAlert(
                title: "\(intent.mode.displayName)未配置",
                message: "\(intent.mode.displayName)没有可用的 profile，无法下单。先在「账户与连接」页配置。",
                style: .critical, buttons: ["好"])
            return
        }

        // Everything the decision needs, read now: the book, the contract's
        // own specification, and what the account holds.
        let context = await gatherContext(for: intent)

        // Resolve the price against that book.
        let resolved = intent.resolveLimit(
            bid: context.bid, ask: context.ask, mark: context.mark,
            tick: context.tickSize, contractValue: context.contractValue,
            indexPrice: context.indexPrice)
        var limit: Double?
        switch resolved {
        case .price(let price):
            limit = price
        case .marketOrder:
            limit = nil
        case .noQuote(let anchor):
            finish("盘口没有 \(anchor.rawValue) 报价，无法定价")
            _ = await presentAlert(
                title: "无法定价",
                message: """
                    这笔单要按盘口的 \(anchor.rawValue) 定价，但交易所此刻没有报出该侧价格\
                    \(context.failure.map { "（\($0)）" } ?? "")，已拒绝。

                    \(Self.describe(intent, limit: nil))
                    """,
                style: .critical, buttons: ["好"])
            return
        case .aboveCap(let price, let premiumUSD, let capUSD):
            // The safety valve. The book ran past what the proposal was willing
            // to pay, so nothing goes out at a price nobody agreed to.
            finish("权利金 \(PriceFormatter.money(premiumUSD)) 超过上限 \(PriceFormatter.money(capUSD))")
            _ = await presentAlert(
                title: "盘口已超出价格上限",
                message: """
                    按当前盘口，这笔单的限价会是 \(PriceFormatter.plain(price))，\
                    权利金约 \(PriceFormatter.money(premiumUSD))，\
                    超过设定的上限 \(PriceFormatter.money(capUSD))，已拒绝。

                    盘口若回落可以重新发起；也可以提高上限再发。
                    """,
                style: .critical, buttons: ["好"])
            return
        }

        // Can the account pay for it, and if not, what one spot order fixes it.
        let funding = Self.fundingOutcome(intent: intent, limit: limit, context: context)

        var message = Self.describe(intent, limit: limit)
        if let fundingText = Self.describeFunding(funding, context: context) {
            message = fundingText + "\n\n" + "第 2 步 · " + message
        }
        message += "\n\n" + Self.describeBook(context, intent: intent, limit: limit)
        if let rationale = intent.rationale {
            message += "\n\n理由：\(rationale)"
        }

        // A plan that cannot be afforded is refused here rather than half-run.
        if case .needed(let step) = funding, !step.isAffordable {
            finish("\(step.instId) 买入需 \(PriceFormatter.money(step.estimatedCostQuote))，可用不足")
            _ = await presentAlert(
                title: "资金不足",
                message: """
                    要先买入 \(PriceFormatter.plain(step.buyAmount)) \(step.coin) 支付权利金，\
                    约需 \(PriceFormatter.money(step.estimatedCostQuote))，\
                    但可用仅 \(PriceFormatter.money(step.quoteAvailable))，已拒绝。
                    """,
                style: .critical, buttons: ["好"])
            return
        }

        let stepCount = { if case .needed = funding { return 2 } else { return 1 } }()
        let response = await presentAlert(
            title: stepCount == 2
                ? "待确认订单（\(intent.mode.badge)，共 2 步）"
                : "待确认订单（\(intent.mode.badge)）",
            message: message,
            style: intent.mode == .live ? .critical : .warning,
            buttons: ["确认下单", "取消"])

        guard response == .alertFirstButtonReturn else {
            finish("用户取消")
            return
        }

        // Second look, but only for an absolute limit that the book has moved
        // past. A relative basis was priced off this very book a moment ago, so
        // there is nothing stale to warn about.
        if intent.exceedsTolerance(limit: limit, bid: context.bid, ask: context.ask),
           let drift = intent.priceDrift(limit: limit, bid: context.bid, ask: context.ask) {
            let confirmDrift = await presentAlert(
                title: "限价已偏离",
                message: """
                    盘口已经走过这笔单的容忍范围（\(PriceFormatter.plain(intent.priceTolerancePct))%）。

                    限价 \(limit.map { PriceFormatter.plain($0) } ?? "—")，\
                    当前\(intent.side == .buy ? "卖一" : "买一") \
                    \(Self.describePrice(intent.side == .buy ? context.ask : context.bid))，\
                    偏离 \(PriceFormatter.plain(drift))%。

                    按原限价下单可能不会成交。仍要下吗？
                    """,
                style: .critical, buttons: ["仍然下单", "取消"])
            guard confirmDrift == .alertFirstButtonReturn else {
                finish("用户在偏离二次确认处取消（偏离 \(PriceFormatter.plain(drift))%）")
                return
            }
        }

        // The nonce was claimed at the gate, before the dialog; what is marked
        // here is that the order is *going out*, so a process that dies now is
        // restored as interrupted and never retried automatically.
        store.markStarted(intent.nonce)

        // Step 1: buy the settlement coin, if the account is short of it.
        if case .needed(let step) = funding {
            Log.warn("""
                order-intent: 第 1 步 nonce=\(intent.nonce) 市价买入 \
                \(PriceFormatter.plain(step.buyAmount)) \(step.coin)（\(step.instId)，\
                约 \(PriceFormatter.money(step.estimatedCostQuote))）
                """)
            do {
                let result = try await orderVenue(for: step.instId).place(
                    SettlementFunding.spotOrder(for: step),
                    mode: intent.mode, liveUnlocked: liveTradingUnlocked)
                Log.warn("order-intent: 第 1 步成交 nonce=\(intent.nonce) ordId=\(result.ordId)")
            } catch {
                // The option leg is not attempted: it would be refused for the
                // very shortfall this step existed to close — and if the buy's
                // outcome is unknown, placing the next leg on a guess is worse.
                let outcome = Self.failure(error)
                store.resolve(intent.nonce)
                Log.warn("order-intent: 第 1 步\(outcome.title) nonce=\(intent.nonce)，不再下期权单：\(outcome.detail)")
                notifications.post(title: "换币\(outcome.title)，未下期权单", body: outcome.detail, sound: true)
                _ = await presentAlert(
                    title: "第 1 步\(outcome.title)，已停止",
                    message: """
                        买入 \(step.coin)\(outcome.title)，因此没有提交期权单。\(outcome.advice.map { "\n\n\($0)" } ?? "")

                        \(outcome.detail)
                        """,
                    style: .critical, buttons: ["好"])
                return
            }
            // Confirm the coin actually arrived. A market order can partially
            // fill, and proceeding on the assumption it filled whole would put
            // the option leg back into the error this step was meant to avoid.
            if let shortfall = await Self.remainingShortfall(
                venue: orderVenue(for: step.instId), mode: intent.mode, step: step, intent: intent,
                limit: limit, context: context) {
                store.resolve(intent.nonce)
                Log.warn("""
                    order-intent: 第 1 步成交后 \(step.coin) 仍缺 \
                    \(PriceFormatter.plain(shortfall))，不下期权单 nonce=\(intent.nonce)
                    """)
                _ = await presentAlert(
                    title: "换币未足额，已停止",
                    message: """
                        买入已提交，但 \(step.coin) 仍缺约 \(PriceFormatter.plain(shortfall))，\
                        因此没有提交期权单。已买入的 \(step.coin) 留在账户里。

                        可以稍后重新发起，或自行补足后再试。
                        """,
                    style: .critical, buttons: ["好"])
                return
            }
        }

        // Step 2: the order this was all for.
        //
        // `tdMode` comes from the account, never from the URL — the account's
        // margin level decides how an option is margined.
        let tradeMode = intent.instType == .option
            ? (context.accountConfig
                ?? AccountTradingConfig(positionMode: nil, accountLevel: nil)).optionTradeMode
            : nil
        let order = intent.toOrderRequest(limitPrice: limit, tradeMode: tradeMode)

        Log.warn("""
            order-intent: 第 \(stepCount) 步 nonce=\(intent.nonce) 提交 \
            \(intent.mode.badge) \(order.side.rawValue) \(order.instId) \
            \(PriceFormatter.plain(order.size)) 张 \
            @\(limit.map { PriceFormatter.plain($0) } ?? "市价") \
            tdMode=\(tradeMode ?? "默认") \
            盘口 bid=\(Self.describePrice(context.bid)) ask=\(Self.describePrice(context.ask))
            """)

        do {
            let result = try await orderVenue(for: intent.instId).place(
                order, mode: intent.mode, liveUnlocked: liveTradingUnlocked)
            store.resolve(intent.nonce)
            Log.warn("order-intent: 成交回执 nonce=\(intent.nonce) ordId=\(result.ordId)")
            notifications.post(
                title: "订单已提交（\(intent.mode.badge)）",
                body: "\(order.instId) \(order.side.displayName) \(PriceFormatter.plain(order.size)) 张",
                sound: true)
            _ = await presentAlert(
                title: "已提交",
                message: """
                    \(order.instId)
                    \(order.side.displayName) \(PriceFormatter.plain(order.size)) 张\
                    \(limit.map { " @ \(PriceFormatter.plain($0))" } ?? "")
                    ordId：\(result.ordId)
                    """,
                style: .informational, buttons: ["好"])
        } catch {
            // The exchange's own words. Not softened, not retried: a rejection
            // here is information, and a second attempt is the user's call —
            // all the more when the outcome is unknown.
            //
            // Any coin bought in step 1 stays bought. Selling it back is
            // another market order and another spread; that is a decision for
            // the person, not a cleanup this code performs silently.
            let outcome = Self.failure(error)
            store.resolve(intent.nonce)
            Log.warn("order-intent: 下单\(outcome.title) nonce=\(intent.nonce)：\(outcome.detail)")
            notifications.post(title: "订单\(outcome.title)", body: outcome.detail, sound: true)
            var text = [outcome.advice, outcome.detail, outcome.hint].compactMap { $0 }.joined(separator: "\n\n")
            if case .needed(let step) = funding {
                text += "\n\n已买入的 \(PriceFormatter.plain(step.buyAmount)) \(step.coin) 留在账户里，未自动卖回。"
            }
            _ = await presentAlert(
                title: "订单\(outcome.title)", message: text, style: .critical, buttons: ["好"])
        }
    }

    /// A failed order in words that say what is now true, the same words
    /// every screen uses. An unknown outcome is not a failure to be retried
    /// but an order to be checked for on the exchange.
    static func failure(_ error: Error) -> (title: String, detail: String, advice: String?, hint: String?) {
        let trade = error as? TradeError
        let detail = trade?.description ?? String(describing: error)
        let standing = TradeError.standing(of: error)
        let advice: String? = switch standing {
        case .unknown: "订单可能已经成交，也可能没有。先到交易所核对挂单和成交，不要直接重下。"
        case .undelivered: TradeError.undeliveredAdvice
        case .refused: nil
        }
        return (standing.title, detail, advice, trade?.hint)
    }

    // MARK: - Reading the world

    private struct Context {
        var bid: Double?
        var ask: Double?
        var mark: Double?
        var indexPrice: Double?
        var tickSize: Double = 0.0001
        var contractValue: Double?
        var settleCurrency: String?
        var accountConfig: AccountTradingConfig?
        var snapshot: AccountSnapshot?
        var spotPrice: Double?
        var spotLotSize: Double = 0
        var spotMinSize: Double = 0
        /// The spot taker fee in bps. It is charged in the coin being bought,
        /// so the funding plan has to gross the purchase up by it.
        var spotTakerBps: Double = SettlementFunding.defaultSpotTakerBps
        var feeModel: FeeModel?
        var failure: String?
    }

    private func gatherContext(for intent: PendingOrderIntent) async -> Context {
        var context = Context()
        context.accountConfig = try? await orderVenue(for: intent.instId).accountTradingConfig(mode: intent.mode)
        context.snapshot = try? await orderVenue(for: intent.instId).accountSnapshot(mode: intent.mode)

        if intent.instType == .option {
            do {
                let quote = try await orderVenue(for: intent.instId).optionQuote(instId: intent.instId, mode: intent.mode)
                context.bid = quote.bid
                context.ask = quote.ask
                context.mark = quote.mark
                context.indexPrice = quote.indexPrice
            } catch {
                let reason = (error as? TradeError)?.description ?? String(describing: error)
                Log.warn("order-intent: 无法取得 \(intent.instId) 的实时盘口：\(reason)")
                context.failure = reason
            }
            // The contract's own specification decides the tick and how much
            // underlying a contract covers. Guessing either would misprice the
            // order or misstate the premium.
            if let meta = try? await orderVenue(for: intent.instId).instrumentMeta(instId: intent.instId, mode: intent.mode) {
                if meta.tickSize > 0 { context.tickSize = meta.tickSize }
                context.contractValue = meta.contractValue
            }
            let underlying = Self.underlying(of: intent.instId)
            if let chain = try? await orderVenue(for: intent.instId).optionChain(underlying: underlying, mode: intent.mode),
               let contract = chain.first(where: { $0.instId == intent.instId }) {
                context.contractValue = contract.contractValue
                context.settleCurrency = contract.settleCurrency
                if contract.tickSize > 0 { context.tickSize = contract.tickSize }
            }
        } else {
            do {
                let last = try await orderVenue(for: intent.instId).lastPrice(instId: intent.instId, mode: intent.mode)
                context.bid = last
                context.ask = last
                context.mark = last
            } catch {
                let reason = (error as? TradeError)?.description ?? String(describing: error)
                Log.warn("order-intent: 无法取得 \(intent.instId) 的实时价格：\(reason)")
                context.failure = reason
            }
            if let meta = try? await orderVenue(for: intent.instId).instrumentMeta(instId: intent.instId, mode: intent.mode),
               meta.tickSize > 0 {
                context.tickSize = meta.tickSize
            }
        }

        // What a spot leg would need, if one turns out to be required.
        if let coin = context.settleCurrency,
           let spot = SettlementFunding.spotMarket(for: coin) {
            context.spotPrice = try? await orderVenue(for: spot).lastPrice(instId: spot, mode: intent.mode)
            if let meta = try? await orderVenue(for: spot).instrumentMeta(instId: spot, mode: intent.mode) {
                context.spotLotSize = meta.lotSize
                context.spotMinSize = meta.minSize
            }
            // The account's own schedule beats the default: the fee is taken
            // out of the coin that arrives, so getting it wrong strands the
            // purchase a few lots short of what the option leg needs.
            if let bps = store.config.strategy.feeSchedules.okx.feeBps(for: .spot) {
                context.spotTakerBps = bps
            }
        }
        context.feeModel = store.config.strategy.feeSchedules.okx.feeModel(for: .option)
        return context
    }

    /// `BTC-USD-260919-80000-C` → `BTC-USD`.
    private static func underlying(of instId: String) -> String {
        let parts = instId.split(separator: "-")
        guard parts.count >= 2 else { return instId }
        return "\(parts[0])-\(parts[1])"
    }

    private static func fundingOutcome(
        intent: PendingOrderIntent, limit: Double?, context: Context
    ) -> SettlementFunding.Outcome {
        guard intent.instType == .option, intent.side == .buy,
              let limit, let coin = context.settleCurrency,
              let contractValue = context.contractValue,
              let config = context.accountConfig,
              let snapshot = context.snapshot,
              let fees = context.feeModel,
              let spot = SettlementFunding.spotMarket(for: coin),
              let spotPrice = context.spotPrice
        else { return .notNeeded(.sameCurrency) }

        let funding = OptionPremiumFunding(
            settleCurrency: coin, contracts: intent.size, contractValue: contractValue,
            limitPrice: limit, fees: fees,
            feeCapPctOfPremium: Self.optionFeeCapPctOfPremium,
            available: snapshot.balance(of: coin)?.available ?? 0, config: config)
        let quoteCoin = spot.split(separator: "-").last.map(String.init) ?? "USDT"
        return SettlementFunding.plan(
            funding: funding, spotInstId: spot, spotPrice: spotPrice,
            spotLotSize: context.spotLotSize, spotMinSize: context.spotMinSize,
            spotTakerBps: context.spotTakerBps,
            quoteAvailable: snapshot.balance(of: quoteCoin)?.available ?? 0)
    }

    /// OKX caps an option fee at this share of the premium.
    private static let optionFeeCapPctOfPremium: Double = 12.5

    /// Whether the coin is still short after the spot leg filled, and by how
    /// much. Nil when it is covered.
    private static func remainingShortfall(
        venue: any ExchangeVenue, mode: TradingMode, step: SettlementFunding.Step,
        intent: PendingOrderIntent, limit: Double?, context: Context
    ) async -> Double? {
        guard let limit, let contractValue = context.contractValue,
              let config = context.accountConfig,
              let fees = context.feeModel
        else { return nil }
        guard let snapshot = try? await venue.accountSnapshot(mode: mode) else {
            // Cannot tell, so do not block: the exchange will refuse the option
            // leg if the coin really is missing, and refusing here on a failed
            // balance read would stop a fundable order.
            Log.warn("order-intent: 第 1 步后读不到余额，交由交易所裁定")
            return nil
        }
        let funding = OptionPremiumFunding(
            settleCurrency: step.coin, contracts: intent.size, contractValue: contractValue,
            limitPrice: limit, fees: fees,
            feeCapPctOfPremium: optionFeeCapPctOfPremium,
            available: snapshot.balance(of: step.coin)?.available ?? 0, config: config)
        return funding.isCovered ? nil : funding.shortfall
    }

    // MARK: - Wording

    private static func describePrice(_ value: Double?) -> String {
        value.map { PriceFormatter.plain($0) } ?? "—"
    }

    private static func describeBasis(_ intent: PendingOrderIntent) -> String {
        switch intent.priceBasis {
        case .none: return "市价"
        case .absolute(let price): return "限价 \(PriceFormatter.plain(price))"
        case .relative(let anchor, let slip, let cap):
            var text = "跟\(anchor.rawValue) +\(PriceFormatter.plain(slip))%"
            if let cap { text += "，上限 \(PriceFormatter.money(cap))" }
            return text
        }
    }

    private static func describe(_ intent: PendingOrderIntent, limit: Double?) -> String {
        var lines: [String] = []
        lines.append("\(intent.side.displayName) \(intent.instId)")
        lines.append("类型：\(intent.instType.displayName) · \(intent.kind.rawValue.uppercased())")
        lines.append("数量：\(PriceFormatter.plain(intent.size)) 张")
        if let limit {
            var text = "限价：\(PriceFormatter.plain(limit))"
            if case .relative(let anchor, let slip, _) = intent.priceBasis {
                text += "（按\(anchor.rawValue) +\(PriceFormatter.plain(slip))% 实时算出）"
            }
            lines.append(text)
        } else {
            lines.append("限价：市价单")
        }
        if let posSide = intent.posSide {
            lines.append("持仓方向：\(posSide.rawValue)")
        }
        if intent.reduceOnly { lines.append("仅减仓") }
        if let maxLoss = intent.maxLossUSD {
            lines.append("最大亏损：\(PriceFormatter.money(maxLoss))")
        }
        if let note = intent.expiryNote {
            lines.append("到期：\(note)")
        }
        return lines.joined(separator: "\n")
    }

    /// The spot leg, spelled out so the amount can be checked rather than
    /// trusted. Nil when there is no leg.
    private static func describeFunding(
        _ outcome: SettlementFunding.Outcome, context: Context
    ) -> String? {
        switch outcome {
        case .notNeeded:
            return nil
        case .belowMinimum(let shortfall, let minimum):
            return """
                ⚠️ 结算币缺 \(PriceFormatter.plain(shortfall))，\
                但低于现货最小下单量 \(PriceFormatter.plain(minimum))，无法自动换币。
                """
        case .needed(let step):
            return """
                第 1 步 · 买入结算币
                市价买入 \(PriceFormatter.plain(step.buyAmount)) \(step.coin)（\(step.instId)）
                约需 \(PriceFormatter.money(step.estimatedCostQuote))，\
                可用 \(PriceFormatter.money(step.quoteAvailable))
                """
        }
    }

    private static func describeBook(
        _ context: Context, intent: PendingOrderIntent, limit: Double?
    ) -> String {
        if let failure = context.failure {
            return "⚠️ 取不到实时盘口（\(failure)）——无法校验限价是否仍然有效。"
        }
        var text: String
        if intent.instType == .option {
            text = "当前盘口：买一 \(describePrice(context.bid))，卖一 \(describePrice(context.ask))"
            if let index = context.indexPrice {
                text += "，指数 \(PriceFormatter.plain(index))"
            }
        } else {
            text = "当前价：\(describePrice(context.ask))"
        }
        if let drift = intent.priceDrift(limit: limit, bid: context.bid, ask: context.ask) {
            let label = drift > 0 ? "不利" : "有利"
            text += "\n限价偏离：\(PriceFormatter.plain(drift))%（\(label)）"
            if case .absolute = intent.priceBasis, drift > intent.priceTolerancePct {
                text += " ⚠️ 已超出容忍 \(PriceFormatter.plain(intent.priceTolerancePct))%"
            }
        }
        return text
    }
}
