import Foundation
import CMayStockKernel

/// OKX account documents — positions, equity, balances — read by the kernel.
///
/// The live layer parses the same fields from the private socket's pushes,
/// and a second reader here drifted from it within a day (one fell back to
/// `imr` for a cross position's margin, the other did not). So there is one
/// reader, in the kernel, and the trading path calls it too.
enum KernelAccount {

    private struct Equity: Decodable {
        let totalEquity: Double?
    }

    /// Non-zero positions, short legs negative — in the live account
    /// document's shape, mapped by its one function, so a position read over
    /// REST means exactly what the same position streamed means. A REST read
    /// carries no push time: its mark is as of this machine's clock now.
    static func positions(_ json: String, readAt: Date = Date()) -> [ExchangePosition] {
        read([LiveAccount.Holding].self, "positions", json)?.map { holding in
            let position = holding.exchangePosition(offsetMs: nil)
            return position.markAt == nil ? position.marked(at: readAt) : position
        } ?? []
    }

    static func totalEquity(_ json: String) -> Double? {
        read(Equity.self, "equity", json)?.totalEquity
    }

    static func balances(_ json: String) -> [AccountBalance] {
        read([LiveAccount.Balance].self, "balances", json)?.map(\.accountBalance) ?? []
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
