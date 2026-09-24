import AppKit
import SwiftUI
import MayStockKit

/// How old a venue timestamp is, ticking on its own so a feed that goes quiet
/// visibly ages even though no new data arrives. Corrected for this machine's
/// measured clock offset from the venue (`offsetMs`, local minus venue).
///
/// Drawn by AppKit rather than as a SwiftUI `Text`, on purpose. The checkup
/// page carries about forty-five of these, and nearly all of them change on
/// every tick: under a second they count milliseconds, under a minute tenths
/// of a second. As `Text`, every tick took each label through SwiftUI's whole
/// update — resolve, measure, place, redraw — plus the window's layout pass,
/// and measured on 2026-09-24 at about 12 ms of main thread per tick, ten
/// times a second: the largest single cost of the page. Here SwiftUI hands
/// over a timestamp only when a new one arrives; the ticking is `AgeClock`
/// redrawing the small views whose text changed, and nothing else.
struct AgeLabel: NSViewRepresentable {
    let ms: Int64
    let offsetMs: Double
    /// Past this many milliseconds the age turns amber.
    var staleAfterMs: Double

    func makeNSView(context: Context) -> AgeView { AgeView() }

    func updateNSView(_ view: AgeView, context: Context) {
        view.show(ms: ms, offsetMs: offsetMs, staleAfterMs: staleAfterMs)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: AgeView, context: Context) -> CGSize? {
        AgeView.size
    }

    /// The one age format: milliseconds under a second, then tenths of a
    /// second, whole minutes, tenths of an hour, whole days.
    static func format(_ milliseconds: Double) -> String {
        let ms = max(0, milliseconds)
        if ms < 1_000 { return "\(Int(ms)) ms" }
        if ms < 60_000 { return String(format: "%.1f 秒", ms / 1_000) }
        if ms < 3_600_000 { return "\(Int(ms / 60_000)) 分钟" }
        if ms < 100 * 3_600_000 { return String(format: "%.1f 小时", ms / 3_600_000) }
        return "\(Int(ms / 86_400_000)) 天"
    }

    /// The longest text each band of `format` can produce, which is what the
    /// label's fixed width is measured from.
    static let widestTexts = [999, 59_949, 3_599_999, 359_999_999, 999 * 86_400_000].map { format(Double($0)) }
}

/// The view behind `AgeLabel`: a fixed-size box that redraws itself when its
/// text changes and never asks anything around it to move.
final class AgeView: NSView {
    static let font = NSFont.monospacedDigitSystemFont(ofSize: Theme.Text.captionSize, weight: .regular)

    /// As wide as the widest text the format can produce and one line tall,
    /// so a changing age never re-lays out its row.
    static let size: CGSize = {
        let widest = AgeLabel.widestTexts
            .map { ($0 as NSString).size(withAttributes: [.font: font]).width }
            .max() ?? 0
        return CGSize(width: ceil(widest) + 1, height: ceil(font.ascender - font.descender + font.leading))
    }()

    private var ms: Int64 = 0
    private var offsetMs = 0.0
    private var staleAfterMs = Double.infinity
    private var text = ""
    private var isStale = false

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
    }

    required init?(coder: NSCoder) {
        fatalError("AgeView is only made in code")
    }

    override var isFlipped: Bool { true }
    override var intrinsicContentSize: NSSize { Self.size }
    override var firstBaselineOffsetFromTop: CGFloat { ceil(Self.font.ascender) }
    override var lastBaselineOffsetFromBottom: CGFloat { Self.size.height - ceil(Self.font.ascender) }

    /// Clicks and tooltips belong to whatever the age sits in.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func show(ms: Int64, offsetMs: Double, staleAfterMs: Double) {
        self.ms = ms
        self.offsetMs = offsetMs
        self.staleAfterMs = staleAfterMs
        refresh(now: Date())
    }

    /// Recompute the age and redraw only if what it shows changed.
    func refresh(now: Date) {
        let age = LiveSnapshot.age(of: ms, offsetMs: offsetMs, now: now)
        let text = AgeLabel.format(age)
        let isStale = age > staleAfterMs
        guard text != self.text || isStale != self.isStale else { return }
        self.text = text
        self.isStale = isStale
        setAccessibilityValue(text)
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        let style = NSMutableParagraphStyle()
        style.alignment = .right
        style.lineBreakMode = .byClipping
        (text as NSString).draw(in: bounds, withAttributes: [
            .font: Self.font,
            .foregroundColor: isStale ? NSColor(Theme.warning) : NSColor.secondaryLabelColor,
            .paragraphStyle: style,
        ])
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil {
            AgeClock.shared.remove(self)
        } else {
            AgeClock.shared.add(self)
            refresh(now: Date())
        }
    }
}

/// One clock for every age on screen, ten times a second. A tick redraws only
/// the ages whose text changed, and skips windows nobody can see: a covered or
/// minimised window costs nothing until it is shown, and its ages are brought
/// current on the first tick after.
@MainActor
final class AgeClock {
    static let shared = AgeClock()
    static let interval: TimeInterval = 0.1

    private let views = NSHashTable<AgeView>.weakObjects()
    private var timer: Timer?

    func add(_ view: AgeView) {
        views.add(view)
        guard timer == nil else { return }
        let timer = Timer(timeInterval: Self.interval, repeats: true) { _ in
            MainActor.assumeIsolated { AgeClock.shared.tick() }
        }
        timer.tolerance = Self.interval / 10
        // `.common`, so ages keep counting while a scroll is being tracked.
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func remove(_ view: AgeView) {
        views.remove(view)
        if views.allObjects.isEmpty {
            timer?.invalidate()
            timer = nil
        }
    }

    private func tick() {
        let now = Date()
        for view in views.allObjects where view.window?.occlusionState.contains(.visible) == true {
            view.refresh(now: now)
        }
    }
}
