import Foundation
import Testing
@testable import MayStockKit

/// The close ticket through the kernel, walking the declarations rather than
/// naming today's cases: every venue, every family, every method it offers,
/// every price source and time-in-force. The planning rules themselves are
/// pinned in the kernel's tests (`trade::close`); what is pinned here is that
/// Swift asks for what the kernel declares, and that the request a review
/// shows is byte for byte the request `send` would build.
@Suite("Close ticket")
struct CloseTicketTests {

    /// A book around 2,653 on the instrument's own tick, as the kernel
    /// publishes one.
    static func book(for family: InstrumentType, sizesKnown: Bool = true) -> Data {
        let spec: BookDocument.Spec
        switch family {
        case .swap:
            spec = .init(instType: "SWAP", tickSz: "0.01", lotSz: "0.01", minSz: "0.01", ctVal: "0.1", ctMult: "1",
                         ctType: "linear", ctValCcy: "ETH", settleCcy: "USDT", groupId: "4")
        case .spot:
            spec = .init(instType: "SPOT", tickSz: "0.01", lotSz: "0.000001", minSz: "0.0001",
                         baseCcy: "ETH", quoteCcy: "USDT", groupId: "12")
        case .option:
            spec = .init(instType: "OPTION", tickSz: "0.0001", lotSz: "1", minSz: "1", ctVal: "1", ctMult: "0.1",
                         ctType: "inverse", ctValCcy: "ETH", settleCcy: "ETH", groupId: "1")
        case .stock:
            spec = .shares(SchwabMarketDataSource.equityMeta("MU"))
        }
        let prices: (asks: [String], bids: [String]) = family == .option
            ? (["0.0510", "0.0520", "0.0550", "0.0600"], ["0.0500", "0.0490", "0.0450", "0.0400"])
            : (["2653.30", "2653.35", "2653.50", "2654.00"], ["2653.20", "2653.10", "2653.00", "2652.50"])
        let level = { (px: String) in BookDocument.Level(px: px, sz: sizesKnown ? "25" : "0", orders: 2) }
        var document = BookDocument(
            instId: "X", state: "live", detail: nil,
            asks: prices.asks.map(level), bids: prices.bids.map(level),
            receivedMs: Int64(Date().timeIntervalSince1970 * 1_000), exchangeMs: nil,
            last: BookDocument.Stamped(px: family == .option ? "0.0505" : "2653.25", ms: 1),
            spec: spec, sizesKnown: sizesKnown)
        document.seqId = 7
        return (try? JSONEncoder().encode(document)) ?? Data()
    }

    static func holding(_ family: InstrumentType, isLong: Bool = true) -> CloseHolding {
        switch family {
        case .swap:
            return CloseHolding(instId: "ETH-USDT-SWAP", family: .swap, isLong: isLong, quantity: 50, unit: "张",
                                posSide: isLong ? .long : .short, marginMode: "isolated",
                                averagePrice: 2600, liquidationPrice: isLong ? 2300 : 3000)
        case .spot:
            return CloseHolding(coin: "ETH", available: 0.0408135, instId: "ETH-USDT")
        case .option:
            return CloseHolding(instId: "ETH-USD-261009-2750-P", family: .option, isLong: isLong, quantity: 5, unit: "张",
                                posSide: nil, marginMode: "cross", averagePrice: 0.045, liquidationPrice: nil)
        case .stock:
            return CloseHolding(instId: "MU", family: .stock, isLong: true, quantity: 30, unit: "股",
                                posSide: nil, marginMode: nil, averagePrice: 100, liquidationPrice: nil)
        }
    }

    static func input(
        _ venue: Venue, _ family: InstrumentType, ticket: CloseTicketInput, isLong: Bool = true
    ) -> ClosePlanInput {
        ClosePlanInput(
            venue: venue, mode: .demo, holding: holding(family, isLong: isLong), ticket: ticket,
            account: AccountTradingConfig(positionMode: .longShort, accountLevel: 2),
            fees: FeeRates(maker: 0.0002, taker: 0.0005), working: [], workingUnread: nil,
            clientId: OrderTag.make(strategyId: CloseTicketModel.manualTag))
    }

    /// Every ticket worth asking a venue for, given what it declares.
    static func tickets(for capabilities: CloseCapabilities, family: InstrumentType) -> [CloseTicketInput] {
        var tickets: [CloseTicketInput] = []
        for method in CloseMethod.allCases where capabilities.availability(of: method).available {
            switch method {
            case .limit:
                for source in capabilities.priceSources {
                    let prices: [ClosePriceSource]
                    switch source {
                    case .counterparty: prices = (1...min(capabilities.bookDepth, 4)).map { .counterparty(level: $0) }
                    case .queue: prices = (1...min(capabilities.bookDepth, 4)).map { .queue(level: $0) }
                    case .mid: prices = [.mid]
                    case .last: prices = [.last]
                    case .fixed: prices = [.fixed(family == .option ? 0.0555 : 2660.004)]
                    }
                    for price in prices {
                        for kind in capabilities.limitKinds {
                            tickets.append(CloseTicketInput(method: .limit, size: .all, price: price, limitKind: kind))
                        }
                    }
                }
            case .chase, .market:
                tickets.append(CloseTicketInput(method: method, size: .all))
            case .protect:
                tickets.append(CloseTicketInput(
                    method: .protect, size: .all,
                    takeProfit: capabilities.takeProfit.available ? 2800 : nil,
                    stopLoss: capabilities.stopLoss.available ? 2500 : nil))
            }
        }
        return tickets
    }

    @Test("every venue declares every family: what it trades, and why not for the rest")
    func everyFamilyIsDeclared() {
        for venue in Venue.allCases {
            for family in InstrumentType.allCases {
                let capabilities = KernelClose.capabilities(venue: venue, family: family)
                let offered = CloseMethod.allCases.filter { capabilities.availability(of: $0).available }
                #expect(offered.isEmpty != venue.trades(family), "\(venue) \(family): offers \(offered)")
                for method in CloseMethod.allCases where !capabilities.availability(of: method).available {
                    #expect(capabilities.availability(of: method).reason?.isEmpty == false, "\(venue) \(family) \(method) says why")
                }
                if capabilities.limit.available {
                    #expect(capabilities.limitKinds.contains(.limit), "\(venue) \(family): GTC is always a limit close")
                    #expect(!capabilities.limitKinds.contains(.market))
                    #expect(capabilities.bookDepth >= 1)
                }
            }
        }
    }

    @Test("everything a venue offers plans, and the reviewed request is exactly what send builds")
    func everyOfferedTicketPlans() throws {
        for venue in Venue.allCases {
            for family in InstrumentType.allCases where venue.trades(family) {
                let capabilities = KernelClose.capabilities(venue: venue, family: family)
                let book = Self.book(for: family, sizesKnown: venue == .okx)
                let tickets = Self.tickets(for: capabilities, family: family)
                #expect(!tickets.isEmpty, "\(venue) \(family)")
                for ticket in tickets {
                    let plan: ClosePlan
                    switch KernelClose.plan(Self.input(venue, family, ticket: ticket), book: book) {
                    case .success(let planned):
                        #expect(!(ticket.limitKind == .postOnly && ticket.price.kind == .counterparty),
                                "\(venue) \(family): a maker-only sale at a bid would take, and must be refused")
                        plan = planned
                    case .failure(let refusal):
                        // A maker-only order at a price that takes is refused
                        // by design — in this book, a sale at any bid level
                        // and nothing else. Everything else offered must plan.
                        let takes = ticket.limitKind == .postOnly && ticket.price.kind == .counterparty
                        #expect(takes, "\(venue) \(family) \(ticket): \(refusal)")
                        continue
                    }
                    #expect(plan.side == .sell, "a long is closed by selling")
                    // What Swift hands back to be sent is the action planned.
                    let data = try JSONEncoder().encode(plan.action)
                    #expect(try JSONDecoder().decode(TradeAction.self, from: data) == plan.action)
                    if venue == .okx {
                        let wire = try #require(plan.wire, "\(family) \(ticket)")
                        #expect(try KernelTradeClient.describe(plan.action) == wire, "\(family) \(ticket)")
                    } else {
                        #expect(plan.wire == nil)
                    }
                }
            }
        }
    }

    @Test("what a venue refuses is refused with the reason it declared")
    func refusalsCarryTheDeclaredReason() {
        for venue in Venue.allCases {
            for family in InstrumentType.allCases where venue.trades(family) {
                let capabilities = KernelClose.capabilities(venue: venue, family: family)
                for method in CloseMethod.allCases where !capabilities.availability(of: method).available {
                    let ticket = CloseTicketInput(method: method, size: .all, takeProfit: 2800, stopLoss: 2500)
                    guard case .failure(let refusal) = KernelClose.plan(
                        Self.input(venue, family, ticket: ticket), book: Self.book(for: family)) else {
                        Issue.record("\(venue) \(family) \(method) planned although declared unavailable")
                        continue
                    }
                    let reason = capabilities.availability(of: method).reason ?? ""
                    #expect(refusal.message.contains(reason), "\(refusal.message) / \(reason)")
                }
            }
        }
    }

    @Test("a short is bought back, on its own leg")
    func aShortIsBoughtBack() throws {
        let ticket = CloseTicketInput(method: .limit, size: .all, price: .counterparty(level: 2))
        guard case .success(let plan) = KernelClose.plan(Self.input(.okx, .swap, ticket: ticket, isLong: false), book: Self.book(for: .swap)) else {
            Issue.record("no plan")
            return
        }
        #expect(plan.side == .buy)
        #expect(plan.price?.value == 2653.35, "a buy-back's counterparty is the offer")
        let body = try #require(plan.wire?.body)
        #expect(body.contains(#""posSide":"short""#))
        #expect(body.contains(#""tdMode":"isolated""#), "the position's own margin mode, never a default")
    }

    @Test("a family the app does not trade gets nothing, and says so")
    func unsupportedFamilyIsNamed() {
        for venue in Venue.allCases {
            let capabilities = CloseCapabilities.unsupportedFamily("FUTURES", venue: venue)
            for method in CloseMethod.allCases {
                #expect(capabilities.availability(of: method).reason?.contains("FUTURES") == true)
            }
        }
        // Filed as a delivery future, never mistaken for spot by its id.
        #expect(Venue.okx.family(ofPositionFiledAs: "FUTURES") == nil)
        #expect(Venue.okx.instrumentType(of: "BTC-USD-250926") == .spot, "why the id is not trusted")
        #expect(Venue.okx.family(ofPositionFiledAs: "SWAP") == .swap)
        #expect(Venue.schwab.family(ofPositionFiledAs: "EQUITY") == .stock)
    }

    @Test("a coin's ticket sells into its USDT market; the quote coin has none")
    func coinTickets() {
        let request = CloseTicketRequest.coin("eth", venue: .okx, mode: .live)
        #expect(request?.instId == "ETH-USDT")
        #expect(request?.holding == .coin("ETH"))
        #expect(CloseTicketRequest.coin("USDT", venue: .okx, mode: .live) == nil)
        #expect(CloseTicketRequest.coin("ETH", venue: .schwab, mode: .live) == nil)
        let held = CloseTicketRequest.held(instId: "ETH-USDT", isLong: true, venue: .okx, mode: .demo)
        #expect(held.holding == .coin("ETH"), "a spot book entry is a coin")
    }

    @Test("an order on a leg reads by its side and leg, not by reduceOnly")
    func directionLabels() {
        let cases: [(OrderSide, PositionSide, String)] = [
            (.buy, .long, "买入开多"), (.sell, .long, "卖出平多"),
            (.sell, .short, "卖出开空"), (.buy, .short, "买入平空"),
        ]
        for (side, leg, expected) in cases {
            for reduceOnly in [true, false] {
                let order = ExchangeOpenOrder(
                    id: "1", book: .order, instId: "ETH-USDT-SWAP", ordType: "limit", side: side, posSide: leg,
                    price: 2700, triggerPrice: nil, stopTriggerPrice: nil, takeProfitTriggerPrice: nil,
                    size: 1, closeFraction: nil, filledSize: 0, state: "live", reduceOnly: reduceOnly,
                    clOrdId: nil, createdAt: nil)
                #expect(OrderLabels.direction(order) == expected, "\(side) \(leg) reduceOnly=\(reduceOnly)")
            }
        }
    }
}
