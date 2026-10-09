import Foundation
import CMayStockKernel

/// A US-listed option, as the kernel reads its OCC symbol
/// (`us_options::UsOption`): `MU    261120C01040000` is the Micron 1,040
/// call expiring 2026-11-20. The one reader of that spelling — the account
/// document, the order path and the checkup all ask here.
public struct USOptionContract: Sendable, Equatable, Decodable {
    public let underlying: String
    public let call: Bool
    public let strike: Double
    /// `2026-11-20`.
    public let expiryDay: String
    /// When it stops trading, epoch milliseconds.
    public let expiryMs: Int64

    /// Nil for a symbol that is not an option's.
    public init?(_ symbol: String) {
        guard let pointer = ms_us_option(symbol) else { return nil }
        defer { ms_string_free(pointer) }
        guard let read = try? JSONDecoder().decode(USOptionContract.self, from: Data(bytes: pointer, count: strlen(pointer))) else {
            return nil
        }
        self = read
    }

    public var kind: OptionKind { call ? .call : .put }
}
