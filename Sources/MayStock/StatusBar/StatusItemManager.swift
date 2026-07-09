import AppKit
import MayStockKit

/// Keeps NSStatusItems in sync with the watchlist configuration.
@MainActor
final class StatusItemManager {
    private var controllers: [UUID: StatusItemController] = [:]
    private var lastOrder: [UUID] = []
    private unowned let appState: AppState

    init(appState: AppState) {
        self.appState = appState
    }

    /// Reconcile controllers with the enabled watchlist. macOS lays out
    /// status items in creation order, so when the *ordering* changes we
    /// rebuild the whole strip; otherwise we patch incrementally.
    func sync(watchlist: [WatchItem]) {
        let enabled = watchlist.filter(\.enabled)
        let order = enabled.map(\.id)
        if order != lastOrder && !controllers.isEmpty {
            removeAll()
        }
        lastOrder = order
        let enabledIDs = Set(order)

        for (id, controller) in controllers where !enabledIDs.contains(id) {
            controller.remove()
            controllers.removeValue(forKey: id)
        }

        for item in enabled {
            if let existing = controllers[item.id] {
                existing.update(watchItem: item)
            } else if let session = appState.hub.session(for: item.instId) {
                controllers[item.id] = StatusItemController(
                    watchItem: item, session: session, appState: appState)
            }
        }
    }

    func removeAll() {
        for controller in controllers.values { controller.remove() }
        controllers.removeAll()
    }
}
