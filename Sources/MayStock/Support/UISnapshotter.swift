import AppKit
import SwiftUI
import MayStockKit

/// Renders every surface of the app to PNG and exits.
///
/// A menu bar accessory cannot be screenshotted by the usual tools — there is
/// no window to find — so this is how a layout change gets *looked at* before
/// it ships. It runs against a copy of the state directory and without the
/// trading loop (see `LaunchOptions`), waits for live market data to arrive,
/// then hosts each surface in a real, off-screen window and caches its display.
///
/// A real window rather than `ImageRenderer`, because most of what the
/// terminal is made of — lists, scroll views, buttons, pickers, the split
/// view — is AppKit underneath, and `ImageRenderer` draws AppKit-backed views
/// as a placeholder. Only the real view hierarchy draws the real thing. The
/// one thing a real window will not draw into a cache is a scroll view whose
/// document overflows, so pages are told (`snapshotMode`) to lay out at full
/// height instead, in a window tall enough to hold them.
///
///     MayStock --data-dir <copy-of-state-dir> --snapshot <out-dir>
@MainActor
final class UISnapshotter {
    private let appState: AppState
    private let directory: URL
    /// How long to let the feeds and the CLI fill in before drawing.
    private let settle: TimeInterval = 9
    /// Pixels per point in the output.
    private let scale: CGFloat = 2

    init(appState: AppState, directory: URL) {
        self.appState = appState
        self.directory = directory
    }

    func run() {
        Task { @MainActor in
            do {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                await appState.refreshAccount()
                try await Task.sleep(nanoseconds: UInt64(settle * 1_000_000_000))
                try await render()
                Log.warn("snapshot: wrote \(directory.path)")
                exit(0)
            } catch {
                FileHandle.standardError.write(Data("snapshot failed: \(error)\n".utf8))
                exit(1)
            }
        }
    }

    private func render() async throws {
        let instId = appState.store.config.watchlist.first(where: \.enabled)?.instId
            ?? appState.store.config.watchlist.first?.instId ?? "BTC-USDT"

        // The hover panel, at the height it lays out to.
        let panel = NSHostingView(rootView: PanelRootView(appState: appState, instId: instId))
        let panelWindow = OffscreenWindow(size: panel.fittingSize, chrome: false)
        panelWindow.contentView = panel
        panelWindow.orderFrontRegardless()
        try await pause()
        try await pause()
        try capture(panel, name: "panel")
        panelWindow.orderOut(nil)

        // The terminal, tall enough that a scrolling page shows all of itself.
        let selection = TerminalSelection()
        selection.strategyId = appState.strategies.first?.id
        selection.instId = instId
        let terminal = NSHostingView(
            rootView: TerminalView(appState: appState, selection: selection)
                .environment(\.snapshotMode, true))
        let terminalWindow = OffscreenWindow(size: CGSize(width: 1_180, height: 2_400), chrome: true)
        terminalWindow.contentView = terminal
        terminalWindow.orderFrontRegardless()
        // The first draw of a freshly ordered window lags a beat behind its
        // layout; capturing on the same cycle produced a black detail column.
        try await pause()
        try await pause()
        for page in TerminalPage.allCases {
            selection.page = page
            try await pause()
            Log.warn("snapshot: \(page.rawValue) fitting \(terminal.fittingSize) bounds \(terminal.bounds.size)")
            try capture(terminal, name: "terminal-\(page.rawValue)")
        }
        for tab in StrategyDetailTab.allCases where tab != .backtest {
            selection.page = .strategies
            selection.detailTab = tab
            try await pause()
            try capture(terminal, name: "terminal-strategies-\(tab.rawValue)")
        }
        terminalWindow.orderOut(nil)
    }

    /// A run-loop breath for SwiftUI to lay out and draw a state change.
    private func pause() async throws {
        try await Task.sleep(nanoseconds: 400_000_000)
    }

    private func capture(_ view: NSView, name: String) throws {
        view.layoutSubtreeIfNeeded()
        view.displayIfNeeded()
        let bounds = view.bounds
        guard bounds.width > 0, bounds.height > 0,
              let rep = NSBitmapImageRep(
                bitmapDataPlanes: nil,
                pixelsWide: Int(bounds.width * scale), pixelsHigh: Int(bounds.height * scale),
                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)
        else { throw SnapshotError.renderFailed(name) }
        // Points stay points; the rep's pixel grid is what makes it Retina.
        rep.size = bounds.size
        view.cacheDisplay(in: bounds, to: rep)
        guard let png = rep.representation(using: .png, properties: [:]) else {
            throw SnapshotError.renderFailed(name)
        }
        try png.write(to: directory.appendingPathComponent("\(name).png"), options: .atomic)
    }

    enum SnapshotError: Error { case renderFailed(String) }
}

/// A window that is allowed to sit entirely off every screen. AppKit
/// otherwise drags any window back onto a display, which for a render
/// target would mean flashing it in front of whatever the user is doing.
private final class OffscreenWindow: NSWindow {
    init(size: CGSize, chrome: Bool) {
        super.init(
            contentRect: NSRect(x: -30_000, y: -30_000, width: size.width, height: size.height),
            styleMask: chrome ? [.titled, .fullSizeContentView] : [.borderless],
            backing: .buffered, defer: false)
        isReleasedWhenClosed = false
        if chrome {
            titlebarAppearsTransparent = true
            toolbarStyle = .unifiedCompact
        } else {
            isOpaque = false
            backgroundColor = .clear
        }
    }

    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
}
