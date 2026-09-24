import AppKit
import MayStockKit

/// Closing a holding by hand.
///
/// Every door — an overview row, a balance, the checkup's risk card, the hover
/// panel — opens the same ticket on the terminal window, where the order is
/// reviewed before it goes. The hover panel only ever opens the door: it is
/// a non-activating panel that disappears on a mouse move, the wrong place to
/// put money at risk, and a modal over it crashed the process once already
/// (see `presentAlert`).
extension AppState {

    func openCloseTicket(_ request: CloseTicketRequest) {
        panel?.hide()
        if terminalWindow?.isVisible != true {
            openTerminal()
        } else {
            terminalWindow?.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        }
        Log.warn("close-ticket: 打开 \(request.mode.badge) \(request.venue.displayName) \(request.instId) \(request.holding.description)")
        closeTicketRequest = request
    }

    /// The ticket for a position the exchange reported, on the active account.
    func closeTicket(for position: ExchangePosition, on venue: Venue) -> CloseTicketRequest {
        .position(position, venue: venue, mode: tradingMode)
    }

    /// The ticket for a strategy's book entry, on the active account.
    func closeTicket(for position: StrategyPositionState) -> CloseTicketRequest {
        .held(
            instId: position.instId, isLong: position.quantity > 0,
            venue: position.venue, mode: tradingMode)
    }

    /// The ticket for a holding known by id and direction on OKX — the
    /// checkup's perpetual.
    func closeTicket(instId: String, isLong: Bool, on venue: Venue) -> CloseTicketRequest {
        .held(instId: instId, isLong: isLong, venue: venue, mode: tradingMode)
    }

    /// The ticket for a coin balance, or nil for the quote coin and for a
    /// venue whose balances are not coins.
    func closeTicket(forCoin coin: String, on venue: Venue) -> CloseTicketRequest? {
        .coin(coin, venue: venue, mode: tradingMode)
    }

    /// Why the ticket cannot send right now, or nil when it can.
    func closeTicketBlocker(_ request: CloseTicketRequest) -> String? {
        if request.mode != tradingMode {
            return "打开这张单时是\(request.mode.displayName)，现在已切到\(tradingMode.displayName)，关掉重开"
        }
        if let blocker = tradingBlocker(for: request.venue) { return blocker }
        if request.mode == .live && !liveTradingUnlocked {
            return "实盘尚未解锁。解锁在「账户与连接」页，是单独的一步，不在下单流程里。"
        }
        return nil
    }
}
