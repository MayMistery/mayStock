import AppKit

/// Pure-AppKit entry point. No SwiftUI `App` scene: a menu bar utility owns
/// its own windows, and the `.accessory` activation policy never changes —
/// that's what keeps focus behaviour clean.
///
/// (`NSApplicationDelegate` is a `@MainActor` protocol, so this class — and
/// its `static main` entry point — are main-actor isolated.)
@main
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var appState: AppState?
    private var snapshotter: UISnapshotter?
    /// URLs that arrived before `applicationDidFinishLaunching` built the
    /// state — which is the normal case when the URL is what launched the app.
    private var pendingURLs: [URL] = []

    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
        withExtendedLifetime(delegate) {} // NSApp.delegate is unowned(unsafe)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let options = LaunchOptions.parse(CommandLine.arguments)
        let state = AppState(options: options)
        appState = state
        if let directory = options.snapshotDirectory {
            let snapshotter = UISnapshotter(appState: state, directory: directory)
            self.snapshotter = snapshotter
            snapshotter.run()
        } else if options.openIntelligence {
            state.openTerminal(.intelligence)
        }
        // A URL that launched the app arrives before `appState` exists, so
        // `application(_:open:)` parks it here and this drains it.
        let queued = pendingURLs
        pendingURLs = []
        for url in queued { state.handleDeepLink(url) }
        // Proposals that outlived the process that received them — the app has
        // crashed with a confirmation dialog on screen.
        if options.snapshotDirectory == nil { state.restorePendingOrders() }
    }

    /// `maystock://…` links from outside the app. `order` proposes an order a
    /// human must approve; `checkup` opens the position review. See
    /// `AppState.handleDeepLink`.
    func application(_ application: NSApplication, open urls: [URL]) {
        guard let state = appState else {
            // Launched *by* the URL: hold it until the state exists.
            pendingURLs.append(contentsOf: urls)
            return
        }
        for url in urls { state.handleDeepLink(url) }
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool { true }
}
