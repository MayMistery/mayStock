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

    /// `maystock://checkup` or `maystock://checkup?instId=ETH-USDT-SWAP`.
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
        let unknown = Set(items.map(\.name)).subtracting(["instId"])
        if !unknown.isEmpty {
            Log.warn("deep-link: checkup 忽略未知参数 \(unknown.sorted().joined(separator: "、"))")
        }
        if let requested, !requested.isEmpty {
            Log.warn("deep-link: 打开体检页，指定 \(requested)")
            pendingCheckupInstId = requested
        } else {
            Log.warn("deep-link: 打开体检页，跟随持仓")
            pendingCheckupInstId = nil
        }
        openTerminal(.checkup)
    }
}

extension AppState {
    /// An instrument a deep link asked the checkup page to show, consumed and
    /// cleared by the page when it opens. Nil means "follow the position".
    ///
    /// A stored request rather than a direct call because the page may not
    /// exist yet when the link arrives — the window is created lazily, and its
    /// view has no state to write to until SwiftUI builds it.
    var requestedCheckupInstId: String? { pendingCheckupInstId }
}
