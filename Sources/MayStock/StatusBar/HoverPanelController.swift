import AppKit
import SwiftUI
import MayStockKit

/// The hover panel: a borderless, *non-activating* NSPanel — it never steals
/// focus from the app you're working in (the core failure of the 1.x
/// NSPopover approach). Hovering peeks; clicking the status item pins.
@MainActor
final class HoverPanelController {
    private unowned let appState: AppState

    private var panel: NSPanel?
    private var hosting: FirstMouseHostingView<PanelRootView>?
    private var currentInstId: String?
    private(set) var isPinned = false
    private var mouseInsidePanel = false
    private var hideWorkItem: DispatchWorkItem?
    private var clickOutsideMonitor: Any?
    private var clickInsideAppMonitor: Any?
    private var activationObserver: NSObjectProtocol?
    /// The status item the panel is currently anchored under, so a content-driven
    /// resize can re-anchor rather than drift up over the menu bar.
    private weak var anchorItem: NSStatusItem?

    /// Only the width is fixed. The height follows the content, reported by the
    /// hosted view: the strip below the chart grows and shrinks with account
    /// rows and open positions, and a hard-coded height was already short of
    /// what the strip needs.
    private var panelSize = NSSize(width: PanelRootView.width, height: 512)
    private static let heightBounds: ClosedRange<CGFloat> = 360...820

    init(appState: AppState) {
        self.appState = appState
    }

    // MARK: Show / hide

    func show(instId: String, anchoredTo statusItem: NSStatusItem, pinned: Bool) {
        hideWorkItem?.cancel()
        if isPinned && !pinned && currentInstId != instId {
            return // don't let a hover elsewhere replace a pinned panel
        }
        isPinned = isPinned || pinned

        let panel = ensurePanel()
        if currentInstId != instId {
            if let old = currentInstId {
                appState.hub.stopDepthPolling(instId: old)
            }
            currentInstId = instId
            hosting?.rootView = makeRootView(instId: instId)
        }
        // Idempotent; also restarts polling after a hide/re-show of the same
        // instrument. Only the depth chart consumes the deep snapshot.
        if appState.charts.mode == .depth {
            appState.hub.startDepthPolling(instId: instId)
        }

        anchorItem = statusItem
        position(panel, under: statusItem)
        if !panel.isVisible {
            panel.alphaValue = 0
            panel.orderFrontRegardless()
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.16
                ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
                panel.animator().alphaValue = 1
            }
        }
        installDismissalWatchers()
    }

    func togglePinned(instId: String, anchoredTo statusItem: NSStatusItem) {
        if isPinned, currentInstId == instId, panel?.isVisible == true {
            isPinned = false
            hide()
        } else {
            isPinned = true
            show(instId: instId, anchoredTo: statusItem, pinned: true)
        }
    }

    /// Called when the pointer leaves the status item; grace period lets the
    /// user travel into the panel.
    func scheduleHide() {
        guard !isPinned else { return }
        hideWorkItem?.cancel()
        let delay = Double(appState.store.config.general.hideDelayMs) / 1000
        let work = DispatchWorkItem { [weak self] in
            guard let self, !self.mouseInsidePanel, !self.isPinned else { return }
            self.hide()
        }
        hideWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    func hide() {
        hideWorkItem?.cancel()
        removeDismissalWatchers()
        guard let panel, panel.isVisible else { return }
        if let instId = currentInstId {
            appState.hub.stopDepthPolling(instId: instId)
        }
        isPinned = false
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.14
            panel.animator().alphaValue = 0
        }, completionHandler: {
            panel.orderOut(nil)
        })
    }

    // MARK: Internals

    private func makeRootView(instId: String) -> PanelRootView {
        PanelRootView(
            appState: appState,
            instId: instId,
            onHoverChange: { [weak self] inside in
                guard let self else { return }
                self.mouseInsidePanel = inside
                if inside {
                    self.hideWorkItem?.cancel()
                } else {
                    self.scheduleHide()
                }
            },
            onHeightChange: { [weak self] height in self?.applyHeight(height) })
    }

    /// Adopt the height SwiftUI just laid out, and re-anchor: a window grows
    /// from its bottom-left origin, so a taller panel would otherwise creep up
    /// into the menu bar instead of down the screen.
    private func applyHeight(_ height: CGFloat) {
        guard height > 1 else { return }
        let clamped = min(max(height.rounded(.up), Self.heightBounds.lowerBound),
                          Self.heightBounds.upperBound)
        guard abs(clamped - panelSize.height) > 0.5 else { return }
        panelSize = NSSize(width: PanelRootView.width, height: clamped)
        hosting?.frame = NSRect(origin: .zero, size: panelSize)
        guard let panel else { return }
        panel.setContentSize(panelSize)
        if let anchorItem { position(panel, under: anchorItem) }
    }

    private func ensurePanel() -> NSPanel {
        if let panel { return panel }

        let panel = KeyablePanel(
            contentRect: NSRect(origin: .zero, size: panelSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false)
        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.isMovableByWindowBackground = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        // A hosting *view*, not a hosting controller: assigning an
        // NSHostingController to a borderless panel collapses its frame to
        // zero, and an invisible panel is a far worse failure than a slightly
        // wrong height.
        let root = makeRootView(instId: currentInstId ?? appState.store.config.watchlist.first?.instId ?? "")
        let hosting = FirstMouseHostingView(rootView: root)
        hosting.frame = NSRect(origin: .zero, size: panelSize)
        panel.contentView = hosting

        self.panel = panel
        self.hosting = hosting
        return panel
    }

    private func position(_ panel: NSPanel, under statusItem: NSStatusItem) {
        guard let button = statusItem.button, let buttonWindow = button.window,
              let screen = buttonWindow.screen ?? NSScreen.main else { return }
        let buttonFrame = buttonWindow.convertToScreen(button.convert(button.bounds, to: nil))
        var x = buttonFrame.midX - panelSize.width / 2
        x = max(screen.visibleFrame.minX + 8,
                min(x, screen.visibleFrame.maxX - panelSize.width - 8))
        let y = buttonFrame.minY - panelSize.height - 6
        panel.setFrame(NSRect(x: x, y: y, width: panelSize.width, height: panelSize.height),
                       display: true)
    }

    // MARK: Dismissal

    /// A click anywhere that is not the panel, or a switch to another app,
    /// closes the panel.
    ///
    /// Three signals feed the one rule in `dismissForClick` because no single
    /// one of them sees everything: a global monitor is only told about clicks
    /// that went to *other* applications, a local monitor only about this
    /// one's, and neither hears a ⌘-Tab or a Dock click. The panel used to
    /// rely on the global monitor alone, so a click on the terminal window —
    /// or any switch made without a click — left a pinned panel floating over
    /// everything until the status item was clicked again.
    private func installDismissalWatchers() {
        if clickOutsideMonitor == nil {
            clickOutsideMonitor = NSEvent.addGlobalMonitorForEvents(
                matching: [.leftMouseDown, .rightMouseDown]
            ) { [weak self] _ in
                // Read where the click landed *now*: by the time the hop to
                // the main actor runs, the pointer may be somewhere else.
                let location = NSEvent.mouseLocation
                Task { @MainActor [weak self] in self?.dismissForClick(at: location, windowNumber: nil) }
            }
            if clickOutsideMonitor == nil {
                // The system declined to deliver other apps' clicks. The two
                // watchers below still close the panel, but "clicks elsewhere
                // do nothing" is otherwise indistinguishable from a bug.
                Log.warn("panel: 无法监听其它应用的点击，浮窗只会在应用内点击或切换应用时关闭")
            }
        }
        if clickInsideAppMonitor == nil {
            clickInsideAppMonitor = NSEvent.addLocalMonitorForEvents(
                matching: [.leftMouseDown, .rightMouseDown]
            ) { [weak self] event in
                let location = NSEvent.mouseLocation
                let windowNumber = event.windowNumber
                Task { @MainActor [weak self] in
                    self?.dismissForClick(at: location, windowNumber: windowNumber)
                }
                return event
            }
        }
        if activationObserver == nil {
            let ownPid = ProcessInfo.processInfo.processIdentifier
            activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
                forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
            ) { [weak self] note in
                let activated = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
                guard let activated, activated.processIdentifier != ownPid else { return }
                Task { @MainActor [weak self] in self?.hide() }
            }
        }
    }

    /// The one rule: a click that did not land on the panel closes it —
    /// unless it landed on a status item, whose own click handler is about to
    /// pin, unpin or switch the panel and must not be pre-empted.
    private func dismissForClick(at location: NSPoint, windowNumber: Int?) {
        guard let panel, panel.isVisible else { return }
        if panel.frame.contains(location) { return }
        if let windowNumber, let window = NSApp.window(withWindowNumber: windowNumber) {
            if window === panel || Self.holdsStatusItem(window) { return }
        }
        hide()
    }

    /// Whether a window is the menu bar's own — the one status item buttons
    /// live in. Asked of the view tree rather than of a list of items, so a
    /// watch item added later is covered without anyone registering it.
    private static func holdsStatusItem(_ window: NSWindow) -> Bool {
        func search(_ view: NSView) -> Bool {
            view is NSStatusBarButton || view.subviews.contains(where: search)
        }
        return window.contentView.map(search) ?? false
    }

    private func removeDismissalWatchers() {
        if let monitor = clickOutsideMonitor {
            NSEvent.removeMonitor(monitor)
            clickOutsideMonitor = nil
        }
        if let monitor = clickInsideAppMonitor {
            NSEvent.removeMonitor(monitor)
            clickInsideAppMonitor = nil
        }
        if let observer = activationObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
            activationObserver = nil
        }
    }
}

/// Borderless panels refuse key status by default; the alert menu and the
/// chart filters need it. Non-activating style keeps focus with the frontmost app.
private final class KeyablePanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// The panel deliberately never activates the app, so without this the first
/// click on a chart filter would be spent merely focusing the window — every
/// interval switch would need two clicks.
private final class FirstMouseHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    required init(rootView: Content) { super.init(rootView: rootView) }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
}
