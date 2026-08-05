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

    private let panelSize = NSSize(width: PanelRootView.panelSize.width,
                                   height: PanelRootView.panelSize.height)

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
        installClickOutsideMonitor()
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
        removeClickOutsideMonitor()
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
            })
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

        let root = makeRootView(instId: currentInstId ?? "BTC-USDT")
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

    private func installClickOutsideMonitor() {
        guard clickOutsideMonitor == nil else { return }
        clickOutsideMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown]
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, let panel = self.panel, panel.isVisible else { return }
                if !panel.frame.contains(NSEvent.mouseLocation) {
                    self.hide()
                }
            }
        }
    }

    private func removeClickOutsideMonitor() {
        if let monitor = clickOutsideMonitor {
            NSEvent.removeMonitor(monitor)
            clickOutsideMonitor = nil
        }
    }
}

/// Borderless panels refuse key status by default; text fields in the trade
/// ticket need it. Non-activating style keeps focus with the frontmost app.
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
