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
        }
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool { true }
}
