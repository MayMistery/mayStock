import Foundation
import Testing
@testable import MayStockKit

/// The kernel spells a trade's exit reason as a string and the app decodes it
/// into its own enum, for the labels. Held to the kernel's own list
/// (`ms_exit_reasons`), not to a list written out here a third time.
@Suite("Exit reasons")
struct ExitReasonParityTests {

    /// One the app lacks would fail a whole backtest's decode; one the kernel
    /// lacks is a label for something that never happens.
    @Test func theAppNamesExactlyTheKernelsReasons() throws {
        #expect(Set(TradeExitReason.allCases.map(\.rawValue)) == Set(try TradingKernel.exitReasons()))
    }

    @Test func everyReasonHasALabelOfItsOwn() {
        let labels = TradeExitReason.allCases.map(\.displayName)
        #expect(Set(labels).count == labels.count, "two reasons share a label")
        #expect(labels.allSatisfy { !$0.isEmpty })
    }

    /// A reversal comes back from a real run as one, through the decode the
    /// app uses, and reads as such.
    @Test func aReversalComesBackAsOne() throws {
        let json = KernelGoldenTests.manifest(
            instType: "SWAP",
            signals: #"{"longEntry": "close > sma(close, 20)", "shortEntry": "close < sma(close, 20)"}"#)
        let result = try KernelStrategy(manifestJSON: json).backtest(
            candles: KernelGoldenTests.candles(600, seed: 21), config: KernelBacktestConfig(initialCapital: 30_000))
        let reversal = try #require(result.trades.first { $0.exitReason == .reversal })
        #expect(reversal.exitReason.displayName == "反手")
    }
}
