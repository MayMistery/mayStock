import Foundation
import MayStockKit

extension E2EMain {

    /// The close ticket and the kernel's trading path against the real
    /// accounts. Nothing is placed.
    ///
    /// For every holding on both OKX accounts — positions and coin balances
    /// worth something — the ticket opens the way the app's does: the
    /// kernel's live book, the holding, the account's mode, the fee rates and
    /// the working orders. Then:
    ///
    /// - **The book** is watched for a few seconds: its sequence must only
    ///   move forward, it must never rebuild, and its sides must never cross.
    /// - **Every method and price source** the venue declares is planned and
    ///   reviewed, and the exact request printed.
    /// - **On the demo account only**, each planned derivative order is sent
    ///   to OKX's own order check (`order-precheck` — it places nothing; it
    ///   does not take spot orders), and a cancel
    ///   of an order that does not exist is signed and sent, to prove the
    ///   signed POST path end to end: OKX must answer with its own refusal,
    ///   not a signature or key error.
    ///
    /// `confirm` is never called.
    @MainActor
    static func closeDoctor() async -> Bool {
        let config = ConfigIO(directory: ConfigIO.defaultDirectory()).load()
        let bridge = TradeBridge(prefs: config.trading)
        let venue = OKXVenue(bridge: bridge)
        let trade = KernelTradeClient(bridge: bridge)
        var ok = true
        for mode in TradingMode.allCases {
            print("close ticket doctor — OKX \(mode.displayName)（不下单）")
            ok = await signedPaths(trade: trade, mode: mode) && ok
            var requests: [CloseTicketRequest] = []
            do {
                for position in try await venue.heldPositions(mode: mode) where position.quantity != 0 {
                    requests.append(.position(position, venue: .okx, mode: mode))
                }
                for balance in try await venue.accountSnapshot(mode: mode).balances
                where balance.available > 0 && (balance.valuationUsd ?? 0) >= 0.5 {
                    if let request = CloseTicketRequest.coin(balance.ccy, venue: .okx, mode: mode) {
                        requests.append(request)
                    }
                }
            } catch {
                fail("读取账户", String(describing: error))
                ok = false
                continue
            }
            if requests.isEmpty {
                pass("没有持仓", "跳过")
                continue
            }
            for request in requests {
                ok = await review(request, venue: venue, trade: trade) && ok
            }
        }
        return ok
    }

    /// The kernel's signed reads, and — on the demo account — a signed POST
    /// that changes nothing.
    @MainActor
    private static func signedPaths(trade: KernelTradeClient, mode: TradingMode) async -> Bool {
        var ok = true
        do {
            let listing = try await trade.workingOrders(mode: mode)
            if listing.unavailable.isEmpty {
                pass("挂单列表（内核签名读取）", "\(listing.orders.count) 笔")
            } else {
                fail("挂单列表（内核签名读取）",
                     "读到 \(listing.orders.count) 笔，未能读取：\(listing.unavailable.joined(separator: "、"))")
                ok = false
            }
        } catch {
            fail("挂单列表", String(describing: error))
            ok = false
        }
        do {
            let status = try await trade.orderStatus(
                instId: "BTC-USDT-SWAP", clientId: OrderTag.make(strategyId: "doctor"), mode: mode)
            if status == .unknown {
                pass("按 clOrdId 查单", "不存在的订单答 unknown（可安全重发的唯一答案）")
            } else {
                fail("按 clOrdId 查单", "不存在的订单答了 \(status)")
                ok = false
            }
        } catch {
            fail("按 clOrdId 查单", String(describing: error))
            ok = false
        }
        guard mode == .demo else { return ok }
        let started = Date()
        do {
            _ = try await trade.send(
                .cancel(instId: "BTC-USDT-SWAP", orderId: "1"), mode: .demo, liveUnlocked: false)
            fail("签名 POST", "撤一笔不存在的订单竟然成功了")
            ok = false
        } catch TradeError.rejected(_, let reason) {
            // OKX's own refusal for an order it does not hold: the request
            // was signed, authenticated and read.
            let code = reason.prefix(5)
            let authenticated = !["50101", "50111", "50113", "50105", "50100"].contains(String(code))
            if authenticated {
                pass("签名 POST（模拟盘撤不存在的单）",
                     "OKX 答 \(reason)（\(Int(Date().timeIntervalSince(started) * 1_000)) ms）")
            } else {
                fail("签名 POST", "认证失败：\(reason)")
                ok = false
            }
        } catch {
            fail("签名 POST", String(describing: error))
            ok = false
        }
        return ok
    }

    @MainActor
    private static func review(_ request: CloseTicketRequest, venue: OKXVenue, trade: KernelTradeClient) async -> Bool {
        let model = CloseTicketModel(request: request, venue: venue)
        await model.open()
        defer { model.close() }
        guard let holding = model.holding else {
            fail(request.instId, model.holdingNote ?? "读不到持仓")
            return false
        }
        var ok = await watchBook(model, instId: request.instId)
        guard let book = model.book, let spec = book.spec else {
            fail(request.instId, model.bookError ?? model.book?.specError ?? "没有盘口或合约规格")
            return false
        }
        // Give the fee read, which follows the specification, a moment.
        for _ in 0..<30 where model.fees == nil && model.feesNote == nil {
            try? await Task.sleep(for: .milliseconds(100))
        }
        print("  \(request.instId) \(holding.isLong ? "多" : "空") \(PriceFormatter.plain(holding.quantity)) \(holding.unit)"
              + " · 保证金 \(holding.marginMode ?? "—") · posSide \(holding.posSide?.rawValue ?? "—")"
              + " · 买一 \(book.bids.first?.px ?? "—") 卖一 \(book.asks.first?.px ?? "—") 最新 \(book.last?.px ?? "—")"
              + " · tick \(spec.tickSz) lot \(spec.lotSz) 组 \(spec.groupId)"
              + " · 费率 \(model.fees.map { "maker \($0.maker) taker \($0.taker)" } ?? (model.feesNote ?? "—"))"
              + " · 挂单 \(model.working.map { "\($0.orders.count)" } ?? "读不到")")

        let capabilities = model.capabilities
        for method in CloseMethod.allCases {
            let availability = capabilities.availability(of: method)
            guard availability.available else {
                print("    · \(method.displayName)：不可用（\(availability.reason ?? "")）")
                continue
            }
            model.method = method
            model.useFraction(1)
            var variants: [(String, () -> Void)] = [("", {})]
            if method == .limit {
                variants = []
                for source in capabilities.priceSources {
                    for level in source.takesLevel ? [1, 3] : [0] {
                        let label = source.displayName + (level > 0 ? "第 \(level) 档" : "")
                        variants.append((label, {
                            model.priceSource = source
                            model.level = max(level, 1)
                            model.limitKind = .limit
                        }))
                    }
                }
                for kind in capabilities.limitKinds where kind != .limit {
                    variants.append((kind.displayName + "·同向第 1 档", {
                        model.priceSource = .queue
                        model.level = 1
                        model.limitKind = kind
                    }))
                }
            }
            if method == .protect, let reference = book.lastPrice ?? book.mid {
                let levels = CloseTicketModel.illustrativeProtection(reference: reference, holding: holding)
                model.takeProfitText = capabilities.takeProfit.available ? PriceFormatter.wire(levels.takeProfit) : ""
                model.stopLossText = capabilities.stopLoss.available ? PriceFormatter.wire(levels.stopLoss) : ""
            }
            for (label, apply) in variants {
                apply()
                model.fixedPriceText = book.bids.first?.px ?? ""
                await model.review()
                let name = method.displayName + (label.isEmpty ? "" : "·" + label)
                guard case .reviewing(let plan) = model.stage else {
                    fail(name, model.problem ?? "没有生成复核")
                    ok = false
                    continue
                }
                pass(name, plan.wire.map { "\($0.path) \($0.body)" } ?? plan.review.headline)
                if let taker = plan.estimate.taker {
                    print("        预估：立即成交 \(PriceFormatter.plain(taker.size)) 均价 \(PriceFormatter.plain(taker.average)) 吃 \(taker.levels) 档"
                          + (plan.estimate.fee.map { " · 手续费 \(PriceFormatter.plain($0.amount)) \($0.ccy)" } ?? ""))
                }
                // OKX's precheck answers every spot order with "3 Operation
                // not supported" (measured 2026-09-25 on the demo account);
                // it checks derivatives only.
                if request.mode == .demo, case .place(let order) = plan.action, order.instType.isDerivative {
                    ok = await precheck(order, trade: trade) && ok
                }
                model.backToEditing()
            }
        }
        return ok
    }

    /// Watch the book for a few seconds: forward only, never rebuilt, never
    /// crossed.
    @MainActor
    private static func watchBook(_ model: CloseTicketModel, instId: String) async -> Bool {
        for _ in 0..<100 where model.book?.isLive != true || model.book?.spec == nil {
            try? await Task.sleep(for: .milliseconds(100))
        }
        guard let first = model.book, first.isLive else {
            fail("盘口 \(instId)", model.bookError ?? model.book?.detail ?? "10 秒内没有进入实时状态")
            return false
        }
        var lastSeq = first.seqId ?? 0
        var steps = 0
        var ok = true
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            try? await Task.sleep(for: .milliseconds(100))
            guard let book = model.book, let seq = book.seqId else { continue }
            if seq < lastSeq {
                fail("盘口 \(instId)", "序号倒退：\(lastSeq) → \(seq)")
                ok = false
            }
            if seq != lastSeq { steps += 1 }
            lastSeq = seq
            if let bid = book.bestBid, let ask = book.bestAsk, bid >= ask {
                fail("盘口 \(instId)", "买一 \(bid) ≥ 卖一 \(ask)")
                ok = false
            }
        }
        let stats = model.book?.stats
        if (stats?.resyncs ?? 0) > 0 {
            fail("盘口 \(instId)", "5 秒内重建 \(stats?.resyncs ?? 0) 次：\(stats?.lastResync ?? "")")
            ok = false
        }
        if ok {
            pass("盘口 \(instId)", "5 秒 \(steps) 次更新，序号只进不退，重建 0 次；增量 \(stats?.updates ?? 0) · 最优报价 \(stats?.tops ?? 0)")
        }
        return ok
    }

    /// OKX's own check of an order, which places nothing. OKX offers it on
    /// multi-currency and portfolio margin accounts only — the demo account.
    @MainActor
    private static func precheck(_ order: TradeOrderSpec, trade: KernelTradeClient) async -> Bool {
        do {
            let receipt = try await trade.send(.precheck(order), mode: .demo, liveUnlocked: false)
            print("        ✓ 交易所预检通过（\(receipt.elapsedMs) ms）")
            return true
        } catch TradeError.rejected(_, let reason) {
            // A request OKX cannot read is a bug here; a refusal of an order
            // it read — margin, balance, price limits — is the exchange
            // judging the order as written, which is what the check is for.
            let code = String(reason.prefix(5))
            if Self.malformedRequestCodes.contains(code) {
                fail("交易所预检", "请求本身有问题：\(reason)")
                return false
            }
            print("        ⚠︎ 交易所预检：\(reason)")
            return true
        } catch {
            fail("交易所预检", String(describing: error))
            return false
        }
    }

    /// OKX's codes for a request it could not read as an order: a missing
    /// or malformed parameter, an instrument it does not list, a flag it does
    /// not accept here.
    static let malformedRequestCodes: Set<String> = ["50014", "51000", "51001", "51205"]
}
