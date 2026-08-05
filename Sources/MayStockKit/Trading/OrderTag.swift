import Foundation

/// Encodes the owning strategy into every order's client order ID.
///
/// The exchange holds one balance for the whole account, so "which strategy
/// does this position belong to?" has no answer on the exchange side — unless
/// we put one there. Every order MayStock places carries a `clOrdId` of the
/// form:
///
/// ```
/// ms 3f2a9c41 1k7x9q2m 4b
/// │  │        │        └── nonce, disambiguates same-millisecond orders
/// │  │        └─────────── base36 milliseconds since epoch
/// │  └──────────────────── FNV-1a hash of the strategy id
/// └─────────────────────── namespace, so foreign orders are obviously not ours
/// ```
///
/// 20 characters, alphanumeric, leading letter — inside OKX's 32-character
/// limit. Attribution therefore survives app restarts, crashes and manual
/// intervention: the ledger can always be rebuilt from `okx spot fills`.
public enum OrderTag {
    public static let namespace = "ms"
    static let hashLength = 8
    static let base36 = Array("0123456789abcdefghijklmnopqrstuvwxyz")

    /// Stable 32-bit FNV-1a digest of a strategy id, as 8 lowercase hex chars.
    public static func hash(strategyId: String) -> String {
        var digest: UInt32 = 2_166_136_261
        for byte in Array(strategyId.utf8) {
            digest ^= UInt32(byte)
            digest = digest &* 16_777_619
        }
        return String(format: "%08x", digest)
    }

    /// Build a client order ID for `strategyId`.
    public static func make(
        strategyId: String, at date: Date = Date(), nonce: UInt16 = UInt16.random(in: 0..<1_296)
    ) -> String {
        let milliseconds = UInt64(Swift.max(date.timeIntervalSince1970, 0) * 1000)
        let stamp = base36String(milliseconds, width: 8)
        let suffix = base36String(UInt64(nonce % 1_296), width: 2)
        return namespace + hash(strategyId: strategyId) + stamp + suffix
    }

    /// The strategy digest inside a client order ID, or nil when the ID did not
    /// come from MayStock.
    public static func strategyHash(of clOrdId: String) -> String? {
        guard clOrdId.hasPrefix(namespace), clOrdId.count >= namespace.count + hashLength else { return nil }
        let start = clOrdId.index(clOrdId.startIndex, offsetBy: namespace.count)
        let end = clOrdId.index(start, offsetBy: hashLength)
        let digest = String(clOrdId[start..<end])
        return digest.allSatisfy(\.isHexDigit) ? digest : nil
    }

    public static func belongs(_ clOrdId: String?, to strategyId: String) -> Bool {
        guard let clOrdId, let digest = strategyHash(of: clOrdId) else { return false }
        return digest == hash(strategyId: strategyId)
    }

    /// Resolve a client order ID back to one of the strategies we know about.
    public static func resolveStrategy(_ clOrdId: String?, among strategyIds: [String]) -> String? {
        guard let clOrdId, let digest = strategyHash(of: clOrdId) else { return nil }
        return strategyIds.first { hash(strategyId: $0) == digest }
    }

    /// Strategy ids whose digests collide. Callers surface this at import time
    /// rather than silently merging two strategies' books.
    public static func collisions(among strategyIds: [String]) -> [[String]] {
        Dictionary(grouping: strategyIds, by: { hash(strategyId: $0) })
            .values.filter { $0.count > 1 }.map { $0.sorted() }
    }

    static func base36String(_ value: UInt64, width: Int) -> String {
        var digits: [Character] = []
        var remaining = value
        repeat {
            digits.append(base36[Int(remaining % 36)])
            remaining /= 36
        } while remaining > 0
        if digits.count > width {
            digits = Array(digits.prefix(width))   // keep the low-order digits
        }
        while digits.count < width {
            digits.append("0")
        }
        return String(digits.reversed())
    }
}
