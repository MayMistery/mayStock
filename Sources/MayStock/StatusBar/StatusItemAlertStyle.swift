import AppKit
import QuartzCore

/// How a menu bar item looks while alerts on its instrument wait to be
/// acknowledged: a red dot before the title, the title in red, and a red line
/// along the bottom edge that pulses until a left click acknowledges them
/// (`docs/superpowers/specs/2026-07-13-alert-attention-design.md`). Whether an
/// alert is pending is the alert engine's rule (`AlertEngine.isPending`); this
/// is only how it is drawn — one definition for the live item and the
/// snapshot of it.
@MainActor
enum StatusItemAlertStyle {
    /// Turn `title` into its alerting form when anything is pending.
    static func apply(to title: NSMutableAttributedString, pending: Int, font: NSFont) {
        guard pending > 0 else { return }
        title.addAttribute(.foregroundColor, value: NSColor.systemRed, range: NSRange(location: 0, length: title.length))
        title.insert(NSAttributedString(string: "● ", attributes: [
            .font: font, .foregroundColor: NSColor.systemRed,
        ]), at: 0)
    }

    /// The first line of the item's tooltip while alerts are pending.
    static func toolTip(pending: Int) -> String? {
        pending > 0 ? "\(pending) 条告警待确认 · 点击确认并打开面板" : nil
    }

    /// Show, place or hide the line on `button`. With nothing pending and the
    /// line already hidden this returns at once — no layout, no transaction:
    /// the bar renders each item up to ten times a second, and an idle item
    /// must cost nothing (`docs/KERNEL.md` §3.18).
    static func updateLine(on button: NSButton, active: Bool, reduceMotion: Bool) {
        let existing = button.layer?.sublayers?.first { $0.name == lineName }
        guard active else {
            if let line = existing, !line.isHidden {
                line.removeAnimation(forKey: pulseKey)
                line.isHidden = true
            }
            return
        }
        button.wantsLayer = true
        // The title just changed width; the line spans the item as it lays out now.
        button.superview?.layoutSubtreeIfNeeded()
        guard let host = button.layer else { return }
        let line = existing ?? makeLine(in: host)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        // A status bar button's layer is geometry-flipped: y counts from the
        // top there, and a line placed at y = 1 would sit on the top edge.
        let y = host.isGeometryFlipped ? host.bounds.height - lineHeight - 1 : 1
        line.frame = CGRect(x: 3, y: y, width: max(0, host.bounds.width - 6), height: lineHeight)
        line.isHidden = false
        CATransaction.commit()
        if reduceMotion {
            line.removeAnimation(forKey: pulseKey)
        } else if line.animation(forKey: pulseKey) == nil {
            // Installed once; later renders move the line without restarting it.
            line.add(pulse(), forKey: pulseKey)
        }
    }

    private static let lineName = "maystock.alertLine"
    private static let pulseKey = "maystock.alertPulse"
    private static let lineHeight: CGFloat = 2

    private static func makeLine(in host: CALayer) -> CALayer {
        let line = CAGradientLayer()
        line.name = lineName
        let red = NSColor.systemRed
        line.colors = [red.withAlphaComponent(0.25).cgColor, red.cgColor, red.withAlphaComponent(0.25).cgColor]
        line.startPoint = CGPoint(x: 0, y: 0.5)
        line.endPoint = CGPoint(x: 1, y: 0.5)
        line.cornerRadius = lineHeight / 2
        line.isHidden = true
        host.addSublayer(line)
        return line
    }

    /// Wider and brighter, then back: 1.05 s each way, for as long as it shows.
    private static func pulse() -> CAAnimation {
        let width = CABasicAnimation(keyPath: "transform.scale.x")
        width.fromValue = 0.55
        width.toValue = 1.0
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 0.45
        fade.toValue = 1.0
        let group = CAAnimationGroup()
        group.animations = [width, fade]
        group.duration = 1.05
        group.autoreverses = true
        group.repeatCount = .infinity
        group.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        return group
    }
}
