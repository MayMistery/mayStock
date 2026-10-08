import Foundation

/// The numbers a live position is judged by, gathered in one place and kept
/// live.
///
/// This exists because the same dozen readings were being pulled by hand,
/// repeatedly, in the middle of a trade: how close is liquidation, where will
/// the option market let price settle, who is crowded, is the macro tape
/// helping. Every one of them shaped a decision.
///
/// All of it streams through the kernel's live layer (`LiveKernel`), which
/// the app runs for its whole life because the account part of it is what
/// every screen values the account with (`LiveAccountFeed`). This model
/// borrows that layer: opening the page switches the market analytics on,
/// closing it switches them off, and in between it asks for the snapshot
/// once a frame and publishes it when it changed. The account's own duties —
/// the engine log, the CLI fallback while the private socket is down — are
/// the account feed's, so they keep running whether or not this page is open.
///
/// Read-only by construction: nothing here, or in the live layer, places,
/// amends or cancels an order.
@Observable
@MainActor
public final class CheckupModel {

    /// The latest snapshot, whole; nil until the first one arrives.
    ///
    /// Not observed: the screen reads the sections below instead, each
    /// assigned only when its content changed, so a card is re-evaluated only
    /// when its own section moved.
    @ObservationIgnored public private(set) var snapshot: LiveSnapshot?

    public private(set) var clock: LiveSnapshot.Clock?
    public private(set) var instrument: LiveSnapshot.Instrument?
    public private(set) var feeds: [LiveSnapshot.Feed] = []
    /// Several venues unreachable at once; see `LiveSnapshot.network`.
    public private(set) var outage: LiveSnapshot.Network?
    public private(set) var spot: LiveSnapshot.Spot?
    public private(set) var risk: LiveSnapshot.Risk?
    public private(set) var probability: LiveSnapshot.Probability?
    public private(set) var gravity: LiveSnapshot.Gravity?
    public private(set) var structure: [LiveSnapshot.VenueStructure] = []
    public private(set) var macro: LiveSnapshot.Macro?
    public private(set) var predictions: LiveSnapshot.Predictions?
    /// Why the analytics could not be switched on. Shown instead of data,
    /// never alongside stale data.
    public private(set) var failure: String?

    /// The instrument asked for. The kernel follows the held perpetual when
    /// `followsHeldPosition` is on, so the snapshot's own instrument is the
    /// one being shown.
    public var instId: String {
        didSet { if instId != oldValue { reconfigure() } }
    }
    public var followsHeldPosition: Bool {
        didSet { if followsHeldPosition != oldValue { reconfigure() } }
    }
    /// How finely the probability table cuts its automatic step; see
    /// `LiveKernel.Config.gridDivisor`.
    public var gridDivisor: Int {
        didSet { if gridDivisor != oldValue { reconfigure() } }
    }
    /// Whether anyone can see the page. While not — its window covered,
    /// minimised, on another Space, or the app hidden — the pump drops to
    /// `hiddenInterval` and publishes nothing: the kernel keeps every feed
    /// live, but no card is redrawn for nobody. Shown again, the latest
    /// snapshot is published at once.
    public var isVisible = true {
        didSet {
            guard isVisible != oldValue else { return }
            Log.warn("checkup: 窗口\(isVisible ? "可见，恢复" : "不可见，暂停")界面刷新（实时层照常接收）")
            if isVisible, let snapshot { publish(snapshot) }
            if pump != nil { runPump() }
        }
    }

    private let kernel: LiveKernel
    private var pump: Task<Void, Never>?
    private var seq: UInt64 = 0

    /// One display frame: the snapshot is asked for this often, and costs a
    /// lock and nothing else when unchanged.
    public static let frameInterval: TimeInterval = 1.0 / 60.0
    /// While the page cannot be seen, the snapshot is still read this often.
    public static let hiddenInterval: TimeInterval = 1

    public init(
        kernel: LiveKernel,
        instId: String = "ETH-USDT-SWAP",
        followsHeldPosition: Bool = true,
        gridDivisor: Int = 1
    ) {
        self.kernel = kernel
        self.instId = instId
        self.followsHeldPosition = followsHeldPosition
        self.gridDivisor = gridDivisor
    }

    // MARK: - Lifecycle

    /// Switch the analytics on for this page's instrument and start the
    /// frame pump. Safe to call again.
    public func start() {
        pump?.cancel()
        seq = 0
        do {
            try kernel.update { config in
                config.instId = instId
                config.followsHeldPosition = followsHeldPosition
                config.gridDivisor = gridDivisor
                config.analytics = true
            }
            failure = nil
        } catch {
            failure = String(describing: error)
            Log.warn("checkup: 打开实时分析失败：\(error)")
            return
        }
        pull()
        runPump()
    }

    /// Every display frame while the page can be seen; `hiddenInterval`
    /// while it cannot.
    private func runPump() {
        pump?.cancel()
        let interval = UInt64((isVisible ? Self.frameInterval : Self.hiddenInterval) * 1_000_000_000)
        pump = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                self?.pull()
                try? await Task.sleep(nanoseconds: interval)
            }
        }
    }

    /// Stop the pump and switch the analytics off. The account part of the
    /// layer runs on: the rest of the app reads it.
    public func stop() {
        pump?.cancel()
        pump = nil
        seq = 0
        do {
            try kernel.update { $0.analytics = false }
        } catch {
            Log.warn("checkup: 关闭实时分析失败：\(error)")
        }
    }

    /// Take the kernel's snapshot if it changed since the last one. Called
    /// every frame by the pump; exposed so tests can step it.
    @discardableResult
    public func pull() -> Bool {
        guard let (next, json) = kernel.snapshot(since: seq) else { return false }
        do {
            let decoded = try JSONDecoder().decode(LiveSnapshot.self, from: json)
            seq = next
            snapshot = decoded
            if isVisible { publish(decoded) }
            return true
        } catch {
            // The kernel and the app disagree about the snapshot's shape — a
            // build defect, not a market condition. Shown, never skipped.
            seq = next
            failure = "实时层快照无法解码：\(error)"
            Log.warn("checkup: \(failure ?? "")")
            return false
        }
    }

    /// Assign each section only when it changed, so only the cards reading
    /// it redraw.
    private func publish(_ decoded: LiveSnapshot) {
        func update<T: Equatable>(_ keyPath: ReferenceWritableKeyPath<CheckupModel, T>, _ value: T) {
            if self[keyPath: keyPath] != value { self[keyPath: keyPath] = value }
        }
        update(\.clock, decoded.clock)
        update(\.instrument, decoded.instrument)
        update(\.feeds, decoded.feeds)
        update(\.outage, decoded.network)
        update(\.spot, decoded.spot)
        update(\.risk, decoded.risk)
        update(\.probability, decoded.probability)
        update(\.gravity, decoded.gravity)
        update(\.structure, decoded.structure)
        update(\.macro, decoded.macro)
        update(\.predictions, decoded.predictions)
    }

    /// Hand a recorded frame or document to the kernel (tests).
    public func ingest(topic: String, payload: String) throws {
        try kernel.ingest(topic: topic, payload: payload)
        pull()
    }

    private func reconfigure() {
        guard pump != nil else { return }
        do {
            try kernel.update { config in
                config.instId = instId
                config.followsHeldPosition = followsHeldPosition
                config.gridDivisor = gridDivisor
            }
        } catch {
            Log.warn("checkup: 实时层重新配置失败：\(error)")
        }
        pull()
    }
}
