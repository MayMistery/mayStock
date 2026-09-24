import Foundation
import CMayStockKernel

/// A live book the close ticket reads and draws. The document it publishes
/// is the one the kernel's planner prices from, so the ladder and the order
/// can never disagree about a level.
public protocol CloseBookFeed: AnyObject, Sendable {
    /// The latest document if newer than `since`; nil when nothing changed.
    func snapshot(since: UInt64) -> (seq: UInt64, json: Data)?
    func stop()
}

/// One OKX instrument's book, held in the kernel: `books` and `bbo-tbt`
/// merged by sequence number, rebuilt from a fresh snapshot whenever a frame
/// is lost.
public final class KernelBook: CloseBookFeed, @unchecked Sendable {
    private struct Config: Encodable {
        let instId: String
        let instType: String
        let mode: String
        let network: Bool
    }

    private let handle: OpaquePointer
    private let lock = NSLock()
    private var stopped = false

    /// - Parameter network: false for tests and the UI snapshotter; frames
    ///   then arrive through `ingest`.
    public init(instId: String, instType: InstrumentType, mode: TradingMode, network: Bool = true) throws {
        let json = try encodeJSON(Config(
            instId: instId, instType: instType.rawValue, mode: mode == .demo ? "demo" : "live", network: network))
        var error: UnsafeMutablePointer<CChar>?
        guard let started = ms_book_start(json, &error) else {
            throw KernelError.kernel(KernelStrategy.take(&error) ?? "盘口启动失败（未给出原因）")
        }
        handle = started
    }

    deinit { stop() }

    public func stop() {
        lock.lock()
        defer { lock.unlock() }
        guard !stopped else { return }
        stopped = true
        ms_book_stop(handle)
    }

    public func snapshot(since: UInt64) -> (seq: UInt64, json: Data)? {
        lock.lock()
        defer { lock.unlock() }
        guard !stopped else { return nil }
        var seq: UInt64 = 0
        guard let pointer = ms_book_snapshot(handle, since, &seq) else { return nil }
        defer { ms_string_free(pointer) }
        return (seq, Data(bytes: pointer, count: strlen(pointer)))
    }

    /// Feed a recorded frame to an offline book.
    public func ingest(_ frame: String) throws {
        lock.lock()
        defer { lock.unlock() }
        guard !stopped else { throw KernelError.kernel("盘口已停止") }
        var error: UnsafeMutablePointer<CChar>?
        guard ms_book_ingest(handle, frame, &error) == 1 else {
            throw KernelError.kernel(KernelStrategy.take(&error) ?? "盘口帧写入失败")
        }
    }
}

/// A venue that publishes a quote and no depth, shaped as a one-level book:
/// polled, since a quote is all there is to read.
public final class QuoteBook: CloseBookFeed, @unchecked Sendable {
    public typealias Read = @Sendable () async throws -> Ticker

    private let lock = NSLock()
    private var seq: UInt64 = 0
    private var document = Data()
    private var task: Task<Void, Never>?

    /// - Parameters:
    ///   - spec: the instrument's tick and lot, as the kernel reads them.
    ///   - interval: how often the quote is read.
    public init(instId: String, spec: BookDocument.Spec, interval: Duration = .seconds(1), read: @escaping Read) {
        publish(BookDocument.quote(instId: instId, spec: spec, ticker: nil, error: nil))
        task = Task { [weak self] in
            while !Task.isCancelled {
                let document: BookDocument
                do {
                    document = BookDocument.quote(instId: instId, spec: spec, ticker: try await read(), error: nil)
                } catch {
                    document = BookDocument.quote(instId: instId, spec: spec, ticker: nil, error: String(describing: error))
                }
                guard let self else { return }
                self.publish(document)
                try? await Task.sleep(for: interval)
            }
        }
    }

    deinit { stop() }

    private func publish(_ book: BookDocument) {
        guard let data = try? JSONEncoder().encode(book) else { return }
        lock.lock()
        defer { lock.unlock() }
        seq += 1
        document = data
    }

    public func snapshot(since: UInt64) -> (seq: UInt64, json: Data)? {
        lock.lock()
        defer { lock.unlock() }
        return seq > since ? (seq, document) : nil
    }

    public func stop() {
        task?.cancel()
        task = nil
    }
}

/// The document a book publishes (`live::book`), as the ticket draws it and
/// as `ms_close_plan` reads it.
public struct BookDocument: Codable, Sendable, Equatable {
    public struct Level: Codable, Sendable, Equatable, Hashable {
        /// The exchange's own text.
        public let px: String
        public let sz: String
        public let orders: Int

        public var price: Double { Double(px) ?? .nan }
        public var size: Double { Double(sz) ?? 0 }

        public init(px: String, sz: String, orders: Int) {
            self.px = px
            self.sz = sz
            self.orders = orders
        }
    }

    public struct Stamped: Codable, Sendable, Equatable {
        public let px: String
        public let ms: Int64
    }

    /// Tick, lot and contract terms, as OKX lists them (text, as sent).
    public struct Spec: Codable, Sendable, Equatable {
        public var instType: String
        public var tickSz: String
        public var lotSz: String
        public var minSz: String
        public var ctVal: String
        public var ctMult: String
        public var ctType: String
        public var ctValCcy: String
        public var settleCcy: String
        public var baseCcy: String
        public var quoteCcy: String
        public var groupId: String
        public var state: String

        public init(
            instType: String, tickSz: String, lotSz: String, minSz: String, ctVal: String = "", ctMult: String = "",
            ctType: String = "", ctValCcy: String = "", settleCcy: String = "", baseCcy: String = "",
            quoteCcy: String = "", groupId: String = "", state: String = "live"
        ) {
            self.instType = instType
            self.tickSz = tickSz
            self.lotSz = lotSz
            self.minSz = minSz
            self.ctVal = ctVal
            self.ctMult = ctMult
            self.ctType = ctType
            self.ctValCcy = ctValCcy
            self.settleCcy = settleCcy
            self.baseCcy = baseCcy
            self.quoteCcy = quoteCcy
            self.groupId = groupId
            self.state = state
        }

        /// Shares: a cent and one share.
        public static func shares(_ meta: InstrumentMeta) -> Spec {
            Spec(instType: InstrumentType.stock.rawValue, tickSz: PriceFormatter.wire(meta.tickSize),
                 lotSz: PriceFormatter.wire(meta.lotSize), minSz: PriceFormatter.wire(meta.minSize), quoteCcy: "USD")
        }

        public var tick: Double { Double(tickSz) ?? 0 }
        public var lot: Double { Double(lotSz) ?? 0 }
        public var minimum: Double { Double(minSz) ?? 0 }
        /// Base units per contract (`ctVal × ctMult`); nil for spot and shares.
        public var contractValue: Double? {
            guard let value = Double(ctVal), value > 0 else { return nil }
            let multiplier = Double(ctMult).flatMap { $0 > 0 ? $0 : nil } ?? 1
            return value * multiplier
        }
        /// Decimals of the tick: how a price on this instrument is written.
        public var priceDecimals: Int {
            guard let dot = tickSz.firstIndex(of: ".") else { return 0 }
            return tickSz[tickSz.index(after: dot)...].reversed().drop { $0 == "0" }.count
        }
    }

    public struct Stats: Codable, Sendable, Equatable {
        public let updates: Int
        public let tops: Int
        public let resyncs: Int
        public let lastResync: String?
    }

    public var instId: String?
    public var mode: String?
    /// `live`, `syncing`, `connecting`, `degraded`, `refused`, `off`.
    public var state: String
    public var detail: String?
    public var asks: [Level]
    public var bids: [Level]
    public var seqId: Int64?
    public var exchangeMs: Int64?
    public var receivedMs: Int64?
    public var last: Stamped?
    public var spec: Spec?
    public var specError: String?
    public var stats: Stats?
    public var topIsNewer: Bool?
    /// False for a quote: the levels carry no sizes.
    public var sizesKnown: Bool

    private enum CodingKeys: String, CodingKey {
        case instId, mode, state, detail, asks, bids, seqId, exchangeMs, receivedMs, last, spec, specError, stats
        case topIsNewer, sizesKnown
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        instId = try c.decodeIfPresent(String.self, forKey: .instId)
        mode = try c.decodeIfPresent(String.self, forKey: .mode)
        state = try c.decodeIfPresent(String.self, forKey: .state) ?? "live"
        detail = try c.decodeIfPresent(String.self, forKey: .detail)
        asks = try c.decodeIfPresent([Level].self, forKey: .asks) ?? []
        bids = try c.decodeIfPresent([Level].self, forKey: .bids) ?? []
        seqId = try c.decodeIfPresent(Int64.self, forKey: .seqId)
        exchangeMs = try c.decodeIfPresent(Int64.self, forKey: .exchangeMs)
        receivedMs = try c.decodeIfPresent(Int64.self, forKey: .receivedMs)
        last = try c.decodeIfPresent(Stamped.self, forKey: .last)
        spec = try c.decodeIfPresent(Spec.self, forKey: .spec)
        specError = try c.decodeIfPresent(String.self, forKey: .specError)
        stats = try c.decodeIfPresent(Stats.self, forKey: .stats)
        topIsNewer = try c.decodeIfPresent(Bool.self, forKey: .topIsNewer)
        sizesKnown = try c.decodeIfPresent(Bool.self, forKey: .sizesKnown) ?? true
    }

    init(
        instId: String?, state: String, detail: String?, asks: [Level], bids: [Level], receivedMs: Int64?,
        exchangeMs: Int64?, last: Stamped?, spec: Spec?, sizesKnown: Bool
    ) {
        self.instId = instId
        self.mode = nil
        self.state = state
        self.detail = detail
        self.asks = asks
        self.bids = bids
        self.seqId = nil
        self.exchangeMs = exchangeMs
        self.receivedMs = receivedMs
        self.last = last
        self.spec = spec
        self.specError = nil
        self.stats = nil
        self.topIsNewer = nil
        self.sizesKnown = sizesKnown
    }

    /// A quote as a one-level book without sizes.
    static func quote(instId: String, spec: Spec, ticker: Ticker?, error: String?) -> BookDocument {
        let text = { (price: Double?) -> [Level] in
            guard let price, price > 0 else { return [] }
            return [Level(px: PriceFormatter.wire(price), sz: "0", orders: 0)]
        }
        let now = Int64(Date().timeIntervalSince1970 * 1_000)
        return BookDocument(
            instId: instId,
            state: ticker != nil ? "live" : (error != nil ? "degraded" : "connecting"),
            detail: error,
            asks: text(ticker?.ask), bids: text(ticker?.bid),
            receivedMs: ticker != nil ? now : nil,
            exchangeMs: ticker.map { Int64($0.ts.timeIntervalSince1970 * 1_000) },
            last: ticker.flatMap { $0.last > 0 ? Stamped(px: PriceFormatter.wire($0.last), ms: Int64($0.ts.timeIntervalSince1970 * 1_000)) : nil },
            spec: spec, sizesKnown: false)
    }

    public var bestBid: Double? { bids.first?.price }
    public var bestAsk: Double? { asks.first?.price }
    public var mid: Double? {
        guard let bid = bestBid, let ask = bestAsk else { return nil }
        return (bid + ask) / 2
    }
    public var lastPrice: Double? { last.flatMap { Double($0.px) } }
    public var isLive: Bool { state == "live" }
}
