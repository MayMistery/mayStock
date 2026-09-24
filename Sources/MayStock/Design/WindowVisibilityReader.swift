import AppKit
import SwiftUI

/// Tells its owner whether the window it sits in can be seen at all, from
/// `NSWindow.occlusionState`: not visible when the window is fully covered,
/// minimised, on another Space, or the app is hidden.
///
/// Visible is reported at once; hidden only once it has lasted `hideAfter`.
/// A window's occlusion state reads "not visible" for the instant between
/// being ordered front and the window server compositing it — measured
/// 2026-09-24, every page open paused and resumed within the same second —
/// and a swipe across Spaces passes through it too; neither is a window
/// nobody is looking at. Reported asynchronously, never from inside a view
/// update, and again whenever the owner's body runs, so an owner that
/// appears after the first report still learns the current state.
struct WindowVisibilityReader: NSViewRepresentable {
    let onChange: (Bool) -> Void

    static let hideAfter: TimeInterval = 0.5

    func makeNSView(context: Context) -> VisibilityView { VisibilityView() }

    func updateNSView(_ view: VisibilityView, context: Context) {
        view.onChange = onChange
        view.report()
    }

    final class VisibilityView: NSView {
        var onChange: ((Bool) -> Void)?
        private var observer: NSObjectProtocol?
        private var pendingHide: DispatchWorkItem?

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let observer { NotificationCenter.default.removeObserver(observer) }
            observer = nil
            pendingHide?.cancel()
            pendingHide = nil
            guard let window else { return }
            observer = NotificationCenter.default.addObserver(
                forName: NSWindow.didChangeOcclusionStateNotification, object: window, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.report() }
            }
            report()
        }

        func report() {
            guard let window else { return }
            if window.occlusionState.contains(.visible) {
                pendingHide?.cancel()
                pendingHide = nil
                DispatchQueue.main.async { [weak self] in self?.onChange?(true) }
            } else if pendingHide == nil {
                let hide = DispatchWorkItem { [weak self] in
                    MainActor.assumeIsolated {
                        guard let self else { return }
                        self.pendingHide = nil
                        guard let window = self.window, !window.occlusionState.contains(.visible) else { return }
                        self.onChange?(false)
                    }
                }
                pendingHide = hide
                DispatchQueue.main.asyncAfter(deadline: .now() + WindowVisibilityReader.hideAfter, execute: hide)
            }
        }
    }
}
