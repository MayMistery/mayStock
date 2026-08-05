import Foundation

// MARK: - Market

public enum InstrumentType: String, Codable, Sendable, CaseIterable {
    case spot = "SPOT"
    case swap = "SWAP"

    public var displayName: String {
        switch self {
        case .spot: return "现货"
        case .swap: return "永续"
        }
    }

    /// OKX taker fee in basis points, used when a manifest omits `costs`.
    public var defaultFeeBps: Double {
        switch self {
        case .spot: return 10   // 0.10%
        case .swap: return 5    // 0.05%
        }
    }

    public var allowsShorting: Bool { self == .swap }
    public var allowsLeverage: Bool { self == .swap }
}

public struct StrategyMarket: Codable, Sendable, Equatable {
    public var instId: String
    public var instType: InstrumentType
    public var bar: BarInterval

    public init(instId: String, instType: InstrumentType = .spot, bar: BarInterval = .h1) {
        self.instId = instId
        self.instType = instType
        self.bar = bar
    }
}

// MARK: - Parameters

public struct StrategyParameter: Sendable, Equatable, Identifiable {
    public var name: String
    public var value: Double
    public var minimum: Double?
    public var maximum: Double?
    public var label: String?
    public var step: Double?

    public var id: String { name }
    public var displayLabel: String { label ?? name }

    public init(
        name: String, value: Double, minimum: Double? = nil,
        maximum: Double? = nil, label: String? = nil, step: Double? = nil
    ) {
        self.name = name
        self.value = value
        self.minimum = minimum
        self.maximum = maximum
        self.label = label
        self.step = step
    }

    /// Clamp into the declared range — used when the user drags a slider.
    public func clamping(_ candidate: Double) -> Double {
        var result = candidate
        if let minimum { result = Swift.max(result, minimum) }
        if let maximum { result = Swift.min(result, maximum) }
        return result
    }
}

/// Ordered parameter list that decodes from either JSON shape:
///
/// ```json
/// "params": [ { "name": "fast", "default": 12 } ]          // ordered (canonical)
/// "params": { "fast": { "default": 12 } }                  // map, sorted by name
/// "params": { "fast": 12 }                                 // bare defaults
/// ```
public struct StrategyParameterSet: Codable, Sendable, Equatable {
    public private(set) var items: [StrategyParameter]

    public init(_ items: [StrategyParameter] = []) {
        self.items = items
    }

    public var values: [String: Double] {
        Dictionary(items.map { ($0.name, $0.value) }, uniquingKeysWith: { _, last in last })
    }

    public var names: Set<String> { Set(items.map(\.name)) }
    public var isEmpty: Bool { items.isEmpty }
    public var count: Int { items.count }

    public subscript(name: String) -> Double? {
        items.first { $0.name == name }?.value
    }

    public mutating func setValue(_ value: Double, for name: String) {
        guard let index = items.firstIndex(where: { $0.name == name }) else { return }
        items[index].value = items[index].clamping(value)
    }

    // MARK: Codable

    /// One parameter, written either as a bare number or as a full spec —
    /// both may appear in the same manifest.
    private struct Spec: Codable {
        var name: String?
        var `default`: Double?
        var value: Double?
        var min: Double?
        var max: Double?
        var label: String?
        var step: Double?

        init(
            name: String? = nil, default: Double? = nil, value: Double? = nil,
            min: Double? = nil, max: Double? = nil, label: String? = nil, step: Double? = nil
        ) {
            self.name = name
            self.default = `default`
            self.value = value
            self.min = min
            self.max = max
            self.label = label
            self.step = step
        }

        init(from decoder: Decoder) throws {
            if let bare = try? decoder.singleValueContainer().decode(Double.self) {
                self.init(default: bare)
                return
            }
            let c = try decoder.container(keyedBy: CodingKeys.self)
            self.init(
                name: try c.decodeIfPresent(String.self, forKey: .name),
                default: try c.decodeIfPresent(Double.self, forKey: .default),
                value: try c.decodeIfPresent(Double.self, forKey: .value),
                min: try c.decodeIfPresent(Double.self, forKey: .min),
                max: try c.decodeIfPresent(Double.self, forKey: .max),
                label: try c.decodeIfPresent(String.self, forKey: .label),
                step: try c.decodeIfPresent(Double.self, forKey: .step))
        }

        func parameter(named fallback: String) -> StrategyParameter? {
            guard let resolved = `default` ?? value else { return nil }
            return StrategyParameter(
                name: name ?? fallback, value: resolved,
                minimum: min, maximum: max, label: label, step: step)
        }
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            items = []
            return
        }
        if let array = try? container.decode([Spec].self) {
            items = array.enumerated().compactMap { $1.parameter(named: "param\($0 + 1)") }
            return
        }
        if let map = try? container.decode([String: Spec].self) {
            items = map.keys.sorted().compactMap { map[$0]?.parameter(named: $0) }
            return
        }
        throw DecodingError.dataCorruptedError(
            in: container, debugDescription: "params 必须是参数数组或参数字典")
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(items.map {
            Spec(name: $0.name, default: $0.value, value: nil,
                 min: $0.minimum, max: $0.maximum, label: $0.label, step: $0.step)
        })
    }
}

// MARK: - Signals / sizing / risk

public struct StrategySignals: Codable, Sendable, Equatable {
    public var longEntry: String?
    public var longExit: String?
    public var shortEntry: String?
    public var shortExit: String?
    /// Continuous target exposure in −1…+1, evaluated every bar.
    ///
    /// When present it **replaces** the entry/exit signals: the strategy is no
    /// longer "in or out" but holds a scaled position. Trend following needs
    /// this — Moskowitz/Ooi/Pedersen size by past-return sign *and* by
    /// volatility, and an on/off position cannot express the second half.
    public var exposure: String?

    public init(longEntry: String? = nil, longExit: String? = nil,
                shortEntry: String? = nil, shortExit: String? = nil,
                exposure: String? = nil) {
        self.longEntry = longEntry
        self.longExit = longExit
        self.shortEntry = shortEntry
        self.shortExit = shortExit
        self.exposure = exposure
    }

    var all: [(role: String, source: String)] {
        [("longEntry", longEntry), ("longExit", longExit),
         ("shortEntry", shortEntry), ("shortExit", shortExit)]
            .compactMap { role, source in
                guard let source, !source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                else { return nil }
                return (role, source)
            }
    }
}

public struct StrategySizing: Codable, Sendable, Equatable {
    public enum Mode: String, Codable, Sendable, CaseIterable {
        /// Percent of the strategy's allocated capital committed per position.
        case equityPct
        /// Fixed notional in the quote currency (e.g. 200 USDT).
        case fixedQuote
        /// Size so that hitting the stop loses `value` percent of allocated capital.
        case riskPerTrade
        /// Scale the position so the strategy runs at a target annualised
        /// volatility: `notional = capital × targetVol / realisedVol`.
        ///
        /// This is the ingredient the trend-following literature is actually
        /// built on. Kim, Tse & Wald (2016) argue it — not the momentum signal —
        /// is what produces most of the reported returns, which is a claim this
        /// engine can now test rather than repeat.
        case volatilityTarget

        public var displayName: String {
            switch self {
            case .equityPct: return "资金百分比"
            case .fixedQuote: return "固定金额"
            case .riskPerTrade: return "单笔风险"
            case .volatilityTarget: return "波动率目标"
            }
        }
    }

    public var mode: Mode
    public var value: Double

    public init(mode: Mode = .equityPct, value: Double = 100) {
        self.mode = mode
        self.value = value
    }
}

public struct ATRStop: Codable, Sendable, Equatable {
    public var period: Int
    public var mult: Double

    public init(period: Int = 14, mult: Double = 2.5) {
        self.period = period
        self.mult = mult
    }
}

public struct StrategyRisk: Codable, Sendable, Equatable {
    /// Bars used to estimate realised volatility for `volatilityTarget`.
    public var volLookbackBars: Int
    /// Hard ceiling on |exposure| after volatility scaling, so a quiet market
    /// cannot lever the book to the moon.
    public var maxExposure: Double
    /// Only trade when the target exposure differs from the held one by at
    /// least this much. Without it, a continuous signal churns every bar.
    public var rebalanceThreshold: Double
    public var stopLossPct: Double?
    public var takeProfitPct: Double?
    public var trailingStopPct: Double?
    public var atrStop: ATRStop?
    public var leverage: Double
    /// Bars to wait after closing before a new entry is allowed.
    public var cooldownBars: Int
    /// Bars a position must be held before any exit signal is honoured.
    public var minHoldBars: Int
    /// Halt the strategy for the rest of the UTC day after this much loss.
    public var maxDailyLossPct: Double?

    public init(
        stopLossPct: Double? = nil, takeProfitPct: Double? = nil,
        trailingStopPct: Double? = nil, atrStop: ATRStop? = nil,
        leverage: Double = 1, cooldownBars: Int = 0, minHoldBars: Int = 0,
        maxDailyLossPct: Double? = nil,
        volLookbackBars: Int = 60, maxExposure: Double = 1,
        rebalanceThreshold: Double = 0.1
    ) {
        self.volLookbackBars = volLookbackBars
        self.maxExposure = maxExposure
        self.rebalanceThreshold = rebalanceThreshold
        self.stopLossPct = stopLossPct
        self.takeProfitPct = takeProfitPct
        self.trailingStopPct = trailingStopPct
        self.atrStop = atrStop
        self.leverage = leverage
        self.cooldownBars = cooldownBars
        self.minHoldBars = minHoldBars
        self.maxDailyLossPct = maxDailyLossPct
    }

    public var hasStop: Bool { stopLossPct != nil || atrStop != nil || trailingStopPct != nil }

    private enum CodingKeys: String, CodingKey {
        case stopLossPct, takeProfitPct, trailingStopPct, atrStop, leverage
        case cooldownBars, minHoldBars, maxDailyLossPct
        case volLookbackBars, maxExposure, rebalanceThreshold
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        stopLossPct = try c.decodeIfPresent(Double.self, forKey: .stopLossPct)
        takeProfitPct = try c.decodeIfPresent(Double.self, forKey: .takeProfitPct)
        trailingStopPct = try c.decodeIfPresent(Double.self, forKey: .trailingStopPct)
        atrStop = try c.decodeIfPresent(ATRStop.self, forKey: .atrStop)
        leverage = try c.decodeIfPresent(Double.self, forKey: .leverage) ?? 1
        cooldownBars = try c.decodeIfPresent(Int.self, forKey: .cooldownBars) ?? 0
        minHoldBars = try c.decodeIfPresent(Int.self, forKey: .minHoldBars) ?? 0
        maxDailyLossPct = try c.decodeIfPresent(Double.self, forKey: .maxDailyLossPct)
        volLookbackBars = try c.decodeIfPresent(Int.self, forKey: .volLookbackBars) ?? 60
        maxExposure = try c.decodeIfPresent(Double.self, forKey: .maxExposure) ?? 1
        rebalanceThreshold = try c.decodeIfPresent(Double.self, forKey: .rebalanceThreshold) ?? 0.1
    }
}

public struct StrategyCosts: Codable, Sendable, Equatable {
    /// Taker fee charged on notional, once on entry and once on exit.
    public var feeBps: Double
    /// Adverse price move assumed on every fill.
    public var slippageBps: Double

    public init(feeBps: Double, slippageBps: Double = 5) {
        self.feeBps = feeBps
        self.slippageBps = slippageBps
    }

    public static func `default`(for instType: InstrumentType) -> StrategyCosts {
        StrategyCosts(feeBps: instType.defaultFeeBps, slippageBps: 5)
    }
}

// MARK: - Manifest

/// A complete, self-contained strategy definition.
///
/// A manifest is *data*, never code: importing one can add arithmetic over
/// candles and nothing else. `compile()` is the only gate into execution and it
/// rejects anything malformed before a single order can be contemplated.
public struct StrategyManifest: Codable, Sendable, Equatable, Identifiable {
    public static let currentSchema = 1

    public var schema: Int
    public var id: String
    public var name: String
    public var version: String
    public var author: String?
    public var notes: String?
    public var market: StrategyMarket
    public var params: StrategyParameterSet
    public var signals: StrategySignals
    public var sizing: StrategySizing
    public var risk: StrategyRisk
    public var costs: StrategyCosts?
    /// Named public data series beyond OHLCV — funding rate, open interest,
    /// positioning, order flow, another instrument's price. Each name becomes
    /// a variable usable in any signal expression.
    public var data: [String: AlternativeSeriesSpec]
    /// Where signals come from. Declarative by default; `script` needs an
    /// explicit unlock before anything will run it.
    public var engine: StrategyEngineSpec

    public init(
        schema: Int = StrategyManifest.currentSchema,
        id: String,
        name: String,
        version: String = "1.0.0",
        author: String? = nil,
        notes: String? = nil,
        market: StrategyMarket,
        params: StrategyParameterSet = StrategyParameterSet(),
        signals: StrategySignals,
        sizing: StrategySizing = StrategySizing(),
        risk: StrategyRisk = StrategyRisk(),
        costs: StrategyCosts? = nil,
        data: [String: AlternativeSeriesSpec] = [:],
        engine: StrategyEngineSpec = .declarative
    ) {
        self.data = data
        self.engine = engine
        self.schema = schema
        self.id = id
        self.name = name
        self.version = version
        self.author = author
        self.notes = notes
        self.market = market
        self.params = params
        self.signals = signals
        self.sizing = sizing
        self.risk = risk
        self.costs = costs
    }

    public var effectiveCosts: StrategyCosts {
        costs ?? .default(for: market.instType)
    }

    // MARK: Codable with tolerant defaults

    private enum CodingKeys: String, CodingKey {
        case schema, id, name, version, author, notes, market, params, signals
        case sizing, risk, costs, data, engine
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        schema = try c.decodeIfPresent(Int.self, forKey: .schema) ?? StrategyManifest.currentSchema
        name = try c.decode(String.self, forKey: .name)
        id = try c.decodeIfPresent(String.self, forKey: .id) ?? StrategyManifest.slug(from: name)
        version = try c.decodeIfPresent(String.self, forKey: .version) ?? "1.0.0"
        author = try c.decodeIfPresent(String.self, forKey: .author)
        notes = try c.decodeIfPresent(String.self, forKey: .notes)
        market = try c.decode(StrategyMarket.self, forKey: .market)
        params = try c.decodeIfPresent(StrategyParameterSet.self, forKey: .params) ?? StrategyParameterSet()
        signals = try c.decode(StrategySignals.self, forKey: .signals)
        sizing = try c.decodeIfPresent(StrategySizing.self, forKey: .sizing) ?? StrategySizing()
        risk = try c.decodeIfPresent(StrategyRisk.self, forKey: .risk) ?? StrategyRisk()
        costs = try c.decodeIfPresent(StrategyCosts.self, forKey: .costs)
        data = try c.decodeIfPresent([String: AlternativeSeriesSpec].self, forKey: .data) ?? [:]
        engine = try c.decodeIfPresent(StrategyEngineSpec.self, forKey: .engine) ?? .declarative
    }

    /// "EMA 双均线趋势" → "ema-双均线趋势"; guarantees a non-empty id.
    public static func slug(from text: String) -> String {
        let mapped = text.lowercased().map { ch -> Character in
            ch.isLetter || ch.isNumber ? ch : "-"
        }
        let collapsed = String(mapped).split(separator: "-", omittingEmptySubsequences: true).joined(separator: "-")
        return collapsed.isEmpty ? "strategy-\(UUID().uuidString.prefix(8).lowercased())" : collapsed
    }

    // MARK: Files

    public static func load(from url: URL) throws -> StrategyManifest {
        let data = try Data(contentsOf: url)
        do {
            return try JSONDecoder().decode(StrategyManifest.self, from: data)
        } catch let error as DecodingError {
            throw StrategyManifestError.malformed(Self.describe(error))
        }
    }

    public func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(self)
    }

    private static func describe(_ error: DecodingError) -> String {
        switch error {
        case .keyNotFound(let key, _): return "缺少必填字段「\(key.stringValue)」"
        case .typeMismatch(_, let ctx), .valueNotFound(_, let ctx), .dataCorrupted(let ctx):
            let path = ctx.codingPath.map(\.stringValue).joined(separator: ".")
            return path.isEmpty ? ctx.debugDescription : "\(path)：\(ctx.debugDescription)"
        @unknown default: return String(describing: error)
        }
    }
}

// MARK: - Errors

public enum StrategyManifestError: Error, CustomStringConvertible, Sendable, Equatable {
    case malformed(String)
    case unsupportedSchema(Int)
    case emptyName
    case noEntrySignal
    case shortingRequiresSwap
    case leverageRequiresSwap(Double)
    case leverageOutOfRange(Double)
    case unknownIdentifier(signal: String, name: String)
    case badExpression(signal: String, reason: String)
    case invalidSizing(String)
    case invalidParameter(String)
    case riskPerTradeNeedsStop

    public var description: String {
        switch self {
        case .malformed(let detail): return "策略文件格式错误：\(detail)"
        case .unsupportedSchema(let v): return "不支持的 schema 版本 \(v)（当前支持 \(StrategyManifest.currentSchema)）"
        case .emptyName: return "策略必须有名称"
        case .noEntrySignal: return "策略至少需要一个入场信号（longEntry 或 shortEntry）"
        case .shortingRequiresSwap: return "做空信号仅永续（instType = SWAP）可用"
        case .leverageRequiresSwap(let x): return "杠杆 \(PriceFormatter.plain(x))× 仅永续可用，现货必须为 1"
        case .leverageOutOfRange(let x): return "杠杆 \(PriceFormatter.plain(x))× 超出允许范围（1~50）"
        case .unknownIdentifier(let signal, let name):
            return "\(signal) 引用了未声明的标识符「\(name)」—— 请在 params 中声明，或改用行情变量"
        case .badExpression(let signal, let reason): return "\(signal)：\(reason)"
        case .invalidSizing(let reason): return "仓位设置无效：\(reason)"
        case .invalidParameter(let reason): return "参数无效：\(reason)"
        case .riskPerTradeNeedsStop: return "单笔风险模式必须配置止损（stopLossPct 或 atrStop）"
        }
    }
}

// MARK: - Compilation

/// A manifest that has passed every check and is ready to backtest or run.
/// Holding one is proof the strategy is executable.
/// A manifest the kernel has accepted.
///
/// The rules themselves live in the kernel, not here: this type carries the
/// manifest (for display and re-parameterisation) plus the compiled handle that
/// the backtester and the live runner both evaluate through. Swift no longer
/// holds a second parsed copy of the expressions, so there is nothing to keep
/// in step.
public struct CompiledStrategy: @unchecked Sendable {
    public let manifest: StrategyManifest
    public let parameterValues: [String: Double]
    /// Leading bars whose signals cannot be trusted (indicator warm-up), as the
    /// kernel computes it — including the volatility-target lookback.
    public let warmupBars: Int
    /// The single compiled form of this strategy's rules.
    public let kernel: KernelStrategy

    public init(manifest: StrategyManifest, kernel: KernelStrategy) {
        self.manifest = manifest
        self.parameterValues = manifest.params.values
        self.warmupBars = kernel.warmupBars
        self.kernel = kernel
    }

    /// External series this strategy needs, resolved against its market.
    public var dataSpecs: [String: AlternativeSeriesSpec] {
        manifest.data.mapValues { $0.resolved(against: manifest.market) }
    }
    public var usesAlternativeData: Bool { !manifest.data.isEmpty }
    public var isScriptEngine: Bool { manifest.engine.isScript }
    public var scriptSpec: ScriptEngineSpec? { manifest.engine.scriptSpec }

    public var id: String { manifest.id }
    public var name: String { manifest.name }
    public var market: StrategyMarket { manifest.market }
    /// Degrees of freedom, for the sample-size test in the robustness grade.
    public var freeParameterCount: Int { Swift.max(manifest.params.count, 1) }

    private static func declared(_ source: String?) -> Bool {
        guard let source else { return false }
        return !source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    public var canGoLong: Bool {
        Self.declared(manifest.signals.longEntry) || isContinuous
    }
    public var canGoShort: Bool {
        Self.declared(manifest.signals.shortEntry) || isContinuous
    }
    /// True when the strategy sizes continuously rather than switching on/off.
    public var isContinuous: Bool { Self.declared(manifest.signals.exposure) }

    /// Same rules, different parameter values. The kernel recompiles — parsing
    /// is cheap next to a backtest, and sharing one handle across a grid search
    /// would mean every point saw the last point's parameters.
    public func with(parameterValues newValues: [String: Double]) throws -> CompiledStrategy {
        var manifest = self.manifest
        for (name, value) in newValues { manifest.params.setValue(value, for: name) }
        return try manifest.compile()
    }
}

extension StrategyManifest {
    /// Parse and validate every rule. Throws on the first real problem, with a
    /// message aimed at whoever wrote the file.
    public func compile() throws -> CompiledStrategy {
        guard schema == Self.currentSchema else { throw StrategyManifestError.unsupportedSchema(schema) }
        guard !name.trimmingCharacters(in: .whitespaces).isEmpty else { throw StrategyManifestError.emptyName }

        for parameter in params.items {
            if let lower = parameter.minimum, let upper = parameter.maximum, lower > upper {
                throw StrategyManifestError.invalidParameter("\(parameter.name) 的 min > max")
            }
            if parameter.value != parameter.clamping(parameter.value) {
                throw StrategyManifestError.invalidParameter("\(parameter.name) 的默认值超出 min/max 范围")
            }
        }

        let values = params.values
        let seriesNames = Set(data.keys)
        if let clash = seriesNames.intersection(StrategyManifest.marketSeriesNames).sorted().first {
            throw StrategyManifestError.invalidParameter(
                "data 中的「\(clash)」与内置行情变量重名，请改名")
        }
        if let clash = seriesNames.intersection(values.keys).sorted().first {
            throw StrategyManifestError.invalidParameter("data 中的「\(clash)」与参数重名，请改名")
        }
        var allowed = values.keys.reduce(into: StrategyManifest.marketSeriesNames) { $0.insert($1) }
        allowed.formUnion(seriesNames)

        let hasExposure = Self.isDeclared(signals.exposure)
        let hasLongEntry = Self.isDeclared(signals.longEntry)
        let hasShortEntry = Self.isDeclared(signals.shortEntry)

        // Market-policy checks run *before* the kernel compiles the rules, so a
        // spot manifest declaring a short leg reports the precise reason rather
        // than the kernel's generic refusal.
        if hasShortEntry, !market.instType.allowsShorting {
            throw StrategyManifestError.shortingRequiresSwap
        }

        // Expression validation belongs to the kernel: it owns the grammar, the
        // function table and the period rules, so a second Swift validator here
        // could only ever disagree with what actually runs.
        let kernel: KernelStrategy
        do {
            kernel = try KernelStrategy(
                manifest: try JSONEncoder().encode(self),
                knownSeries: Array(seriesNames))
        } catch let error as KernelError {
            throw StrategyManifestError.badExpression(
                signal: "signals", reason: error.description)
        }

        // A script decides its own direction, and a continuous-exposure
        // strategy expresses direction *and* size in one expression. Both need
        // no entry signal; everything else (risk, sizing, budget) still applies.
        if !engine.isScript, !hasExposure {
            guard hasLongEntry || hasShortEntry else {
                throw StrategyManifestError.noEntrySignal
            }
        }
        // Continuous exposure can go short by construction, so the same
        // spot-market restriction has to apply to it.
        if hasExposure, !market.instType.allowsShorting {
            // Long-only spot is still fine — the engine clamps exposure at 0.
            // Nothing to reject here, but the clamp is what makes it safe.
        }
        if risk.leverage != 1 {
            guard market.instType.allowsLeverage else {
                throw StrategyManifestError.leverageRequiresSwap(risk.leverage)
            }
            guard risk.leverage >= 1, risk.leverage <= 50 else {
                throw StrategyManifestError.leverageOutOfRange(risk.leverage)
            }
        }

        guard sizing.value > 0 else { throw StrategyManifestError.invalidSizing("数值必须大于 0") }
        switch sizing.mode {
        case .equityPct:
            guard sizing.value <= 100 else {
                throw StrategyManifestError.invalidSizing("资金百分比不能超过 100")
            }
        case .riskPerTrade:
            guard sizing.value <= 100 else {
                throw StrategyManifestError.invalidSizing("单笔风险不能超过 100%")
            }
            guard risk.hasStop else { throw StrategyManifestError.riskPerTradeNeedsStop }
        case .fixedQuote:
            break
        case .volatilityTarget:
            guard sizing.value > 0, sizing.value <= 500 else {
                throw StrategyManifestError.invalidSizing("目标年化波动率应在 0~500% 之间")
            }
            guard risk.volLookbackBars >= 5 else {
                throw StrategyManifestError.invalidSizing("波动率回看窗口至少 5 根")
            }
        }
        guard risk.maxExposure > 0, risk.maxExposure <= 50 else {
            throw StrategyManifestError.invalidSizing("maxExposure 应在 0~50 之间")
        }

        // Warm-up (including the volatility-target lookback) is the kernel's
        // number — the runner fetches history against it, so a second opinion
        // here would make live and backtest disagree about the first tradeable
        // bar.
        return CompiledStrategy(manifest: self, kernel: kernel)
    }

    /// The built-in market variables the DSL exposes. Mirrors
    /// `kernel/src/expr/mod.rs::MARKET_SERIES`; a `data` block may not shadow
    /// one of these, which is the only reason Swift needs the list at all.
    static let marketSeriesNames: Set<String> = [
        "open", "high", "low", "close", "volume", "hl2", "hlc3", "ohlc4", "bar_index",
    ]

    static func isDeclared(_ source: String?) -> Bool {
        guard let source else { return false }
        return !source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}
