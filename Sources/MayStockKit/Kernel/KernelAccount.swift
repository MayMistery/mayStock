import Foundation
import CMayStockKernel

/// OKX account documents — positions, equity, balances — read by the kernel.
///
/// The live layer parses the same fields from the private socket's pushes,
/// and a second reader here drifted from it within a day (one fell back to
/// `imr` for a cross position's margin, the other did not). So there is one
/// reader, in the kernel, and the trading path calls it too.
enum KernelAccount {

    private struct PositionRow: Decodable {
        let instId: String
        let instType: String
        let posSide: String
        let contracts: Double
        let averagePrice: Double?
        let markPrice: Double?
        let unrealisedPnl: Double?
        let leverage: Double?
        let liquidationPrice: Double?
        let notionalUsd: Double?
        let margin: Double?
        let maintenanceMargin: Double?
        let marginRatio: Double?
        let settlementCurrency: String?
        let usdRate: Double?
        let marginMode: String?
    }

    private struct Equity: Decodable {
        let totalEquity: Double?
    }

    private struct BalanceRow: Decodable {
        let ccy: String
        let available: Double
        let total: Double
        let valuationUsd: Double?
    }

    /// Non-zero positions, short legs negative.
    static func positions(_ json: String) -> [ExchangePosition] {
        read([PositionRow].self, "positions", json)?.map { row in
            ExchangePosition(
                instId: row.instId,
                posSide: PositionSide(rawValue: row.posSide) ?? .net,
                quantity: row.contracts,
                averagePrice: row.averagePrice ?? 0,
                markPrice: row.markPrice,
                unrealisedPnL: row.unrealisedPnl ?? 0,
                leverage: row.leverage,
                liquidationPrice: row.liquidationPrice,
                notionalUsd: row.notionalUsd,
                instType: row.instType,
                margin: row.margin,
                maintenanceMargin: row.maintenanceMargin,
                marginRatio: row.marginRatio,
                settlementCurrency: row.settlementCurrency,
                usdRate: row.usdRate,
                marginMode: row.marginMode.flatMap(MarginMode.init(rawValue:)))
        } ?? []
    }

    static func totalEquity(_ json: String) -> Double? {
        read(Equity.self, "equity", json)?.totalEquity
    }

    static func balances(_ json: String) -> [AccountBalance] {
        read([BalanceRow].self, "balances", json)?.map {
            AccountBalance(ccy: $0.ccy, available: $0.available, total: $0.total, valuationUsd: $0.valuationUsd)
        } ?? []
    }

    /// A kernel refusal here is a programming error (an unknown kind), never
    /// a market condition — logged, not swallowed.
    private static func read<T: Decodable>(_ type: T.Type, _ kind: String, _ json: String) -> T? {
        do {
            let text = try callReturningString { error in ms_okx_account_document(kind, json, error) }
            return try JSONDecoder().decode(type, from: Data(text.utf8))
        } catch {
            Log.warn("kernel: 读取 OKX 账户文档（\(kind)）失败：\(error)")
            return nil
        }
    }
}
