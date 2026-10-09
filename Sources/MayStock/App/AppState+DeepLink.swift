import AppKit
import Foundation
import MayStockKit

/// Where a `maystock://` link goes.
///
/// Links come from outside the app — a message, a terminal, an agent — so the
/// first thing to decide is what the link is *asking for*, before any of it is
/// treated as an order. Until this existed every link was handed to the order
/// confirmation path, which answered anything else with an error about URLs it
/// could not parse; a link to a page is not a malformed order.
extension AppState {

    /// The hosts this app answers to. Anything else is refused with the list,
    /// so a typo says what the valid options were.
    static let knownURLHosts = ["order", "checkup"]

    func handleDeepLink(_ url: URL) {
        let host = url.host?.lowercased() ?? ""
        switch host {
        case "order":
            handleOrderURL(url)
        case "checkup":
            openCheckup(from: url)
        default:
            Log.warn("deep-link: 无法识别的 host「\(host)」：\(url.absoluteString)")
            Task { @MainActor in
                _ = await presentAlert(
                    title: "无法识别的链接",
                    message: """
                        地址是 \(url.scheme ?? "")://\(host)

                        支持的链接：
                        · maystock://order?… 提交一笔待确认的订单
                        · maystock://checkup?instId=… 打开体检页
                        """,
                    style: .warning, buttons: ["好"])
            }
        }
    }

    /// `maystock://checkup`, `maystock://checkup?instId=ETH-USDT-SWAP`, or a
    /// US share with its options: `maystock://checkup?instId=MU&market=usEquity`
    /// (an id OKX could not spell — no `-` — is read as one without the
    /// `market`).
    ///
    /// Naming no instrument is the useful case: the page follows whatever is
    /// actually held, which is the question someone opening it is asking.
    private func openCheckup(from url: URL) {
        // Deliberately permissive on the query: an unknown parameter here is a
        // navigation hint gone wrong, not an order with a wrong size, so it is
        // logged and ignored rather than refused.
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        let requested = items.first { $0.name == "instId" }?.value?
            .trimmingCharacters(in: .whitespaces)
        let named = items.first { $0.name == "market" }?.value
        let unknown = Set(items.map(\.name)).subtracting(["instId", "market"])
        if !unknown.isEmpty {
            Log.warn("deep-link: checkup 忽略未知参数 \(unknown.sorted().joined(separator: "、"))")
        }
        if let requested, !requested.isEmpty {
            let request = Self.checkupRequest(instId: requested, market: named)
            Log.warn("deep-link: 打开体检页，指定 \(request.instId)（\(request.market)）")
            pendingCheckupInstId = request
        } else {
            Log.warn("deep-link: 打开体检页，跟随持仓")
            pendingCheckupInstId = nil
        }
        openTerminal(.checkup)
    }
}

extension AppState {
    /// What the checkup is asked to review, by id and, where named, market.
    /// An id OKX could not spell — no `-` — is a US share's ticker.
    static func checkupRequest(instId: String, market named: String?) -> CheckupRequest {
        let markets = [LiveSnapshot.Reviewable.crypto, LiveSnapshot.Reviewable.usEquity]
        let market = named.flatMap { markets.contains($0) ? $0 : nil }
            ?? (instId.contains("-") ? LiveSnapshot.Reviewable.crypto : LiveSnapshot.Reviewable.usEquity)
        if let named, !markets.contains(named) {
            Log.warn("checkup: market「\(named)」不认识，按 \(market) 读")
        }
        return CheckupRequest(
            instId: market == LiveSnapshot.Reviewable.usEquity ? Venue.schwab.canonicalInstId(instId) : instId,
            market: market)
    }

    /// An instrument a deep link asked the checkup page to show, consumed and
    /// cleared by the page when it opens. Nil means "follow the position".
    ///
    /// A stored request rather than a direct call because the page may not
    /// exist yet when the link arrives — the window is created lazily, and its
    /// view has no state to write to until SwiftUI builds it.
    var requestedCheckupInstId: CheckupRequest? { pendingCheckupInstId }
}

/// An instrument a deep link asked the checkup to review, and its market.
struct CheckupRequest: Equatable {
    let instId: String
    let market: String
}
