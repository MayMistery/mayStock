import Foundation

/// The numbers a live position is judged by, gathered in one place and kept
/// live.
///
/// This exists because the same dozen readings were being pulled by hand,
/// repeatedly, in the middle of a trade: how close is liquidation, where will
/// the option market let price settle, who is crowded, is the macro tape
/// helping. Every one of them shaped a decision.
///
/// All of it now streams through the kernel's live layer (`LiveKernel`): the
/// model only asks for the kernel's snapshot once a frame and publishes it
/// when it changed. Two things stay here because they are the app's, not the
/// kernel's: writing the kernel's event lines to the engine log, and — when
/// the read-only account socket is down — reading positions through the
/// `okx` CLI and handing the documents back to the kernel to parse.
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
    public private(set) var spot: LiveSnapshot.Spot?
    public private(set) var risk: LiveSnapshot.Risk?
    public private(set) var probability: LiveSnapshot.Probability?
    public private(set) var gravity: LiveSnapshot.Gravity?
    public private(set) var structure: [LiveSnapshot.VenueStructure] = []
    public private(set) var macro: LiveSnapshot.Macro?
    /// Why the live layer could not start. Shown instead of data, never
    /// alongside stale data.
    public private(set) var failure: String?
    /// The last CLI fallback read that failed, while the fallback is running.
    public private(set) var fallbackError: String?

    /// The instrument asked for. The kernel follows the held perpetual when
    /// `followsHeldPosition` is on, so the snapshot's own instrument is the
    /// one being shown.
    public var instId: String {
        didSet { if instId != oldValue { reconfigure() } }
    }
    public var followsHeldPosition: Bool {
        didSet { if followsHeldPosition != oldValue { reconfigure() } }
    }
    public var mode: TradingMode {
        didSet { if mode != oldValue { reconfigure() } }
    }
    /// Whether anyone can see the page. While not — its window covered,
    /// minimised, on another Space, or the app hidden — the pump drops to
    /// `hiddenInterval` and publishes nothing: the kernel keeps every feed
    /// live, events still reach the engine log and the CLI fallback still
    /// follows the account socket, but no card is redrawn for nobody. Shown
    /// again, the latest snapshot is published at once.
    public var isVisible = true {
        didSet {
            guard isVisible != oldValue else { return }
            Log.warn("checkup: 窗口\(isVisible ? "可见，恢复" : "不可见，暂停")界面刷新（实时层照常接收）")
            if isVisible, let snapshot { publish(snapshot) }
            if pump != nil { runPump() }
        }
    }

    private let venue: any ExchangeVenue
    private let profile: @Sendable (TradingMode) -> String?
    private let okxConfigPath: String?
    private let schwabctlPath: String?
    private let network: Bool
    private let nowOverrideMs: Int64?
    private var kernel: LiveKernel?
    private var pump: Task<Void, Never>?
    private var fallback: Task<Void, Never>?
    private var seq: UInt64 = 0
    private var loggedEventId: UInt64 = 0

    /// One display frame: the snapshot is asked for this often, and costs a
    /// lock and nothing else when unchanged.
    public static let frameInterval: TimeInterval = 1.0 / 60.0
    /// While the page cannot be seen, the snapshot is still read this often,
    /// for the engine log and the CLI fallback.
    public static let hiddenInterval: TimeInterval = 1
    /// While the account socket is down, the CLI is read this often.
    public static let fallbackInterval: TimeInterval = 10

    public init(
        venue: any ExchangeVenue,
        mode: TradingMode,
        instId: String = "ETH-USDT-SWAP",
        followsHeldPosition: Bool = true,
        okxProfile: @escaping @Sendable (TradingMode) -> String? = { _ in nil },
        okxConfigPath: String? = OKXProfileCatalog.defaultFileURL().path,
        schwabctlPath: String? = nil,
        network: Bool = true,
        nowOverrideMs: Int64? = nil
    ) {
        self.venue = venue
        self.mode = mode
        self.instId = instId
        self.followsHeldPosition = followsHeldPosition
        self.profile = okxProfile
        self.okxConfigPath = okxConfigPath
        self.schwabctlPath = schwabctlPath
        self.network = network
        self.nowOverrideMs = nowOverrideMs
    }

    private var config: LiveKernel.Config {
        LiveKernel.Config(
            instId: instId, followsHeldPosition: followsHeldPosition, mode: mode,
            okxProfile: profile(mode), okxConfigPath: okxConfigPath,
            schwabctlPath: schwabctlPath, network: network, nowOverrideMs: nowOverrideMs)
    }

    // MARK: - Lifecycle

    /// Start the live layer and the frame pump. Safe to call again; it
    /// restarts both.
    public func start() {
        stop()
        do {
            kernel = try LiveKernel(config: config)
            failure = nil
        } catch {
            failure = String(describing: error)
            Log.warn("checkup: 实时层启动失败：\(error)")
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

    public func stop() {
        pump?.cancel()
        pump = nil
        fallback?.cancel()
        fallback = nil
        kernel?.stop()
        kernel = nil
        seq = 0
    }

    /// Take the kernel's snapshot if it changed since the last one. Called
    /// every frame by the pump; exposed so tests can step it.
    @discardableResult
    public func pull() -> Bool {
        guard let kernel, let (next, json) = kernel.snapshot(since: seq) else { return false }
        do {
            let decoded = try JSONDecoder().decode(LiveSnapshot.self, from: json)
            seq = next
            snapshot = decoded
            if isVisible { publish(decoded) }
            log(decoded.events)
            followFallback(needed: decoded.risk.fallbackNeeded)
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
        update(\.spot, decoded.spot)
        update(\.risk, decoded.risk)
        update(\.probability, decoded.probability)
        update(\.gravity, decoded.gravity)
        update(\.structure, decoded.structure)
        update(\.macro, decoded.macro)
    }

    /// Hand a document to the kernel: the CLI fallback's positions and
    /// balance, and recorded frames in tests.
    public func ingest(topic: String, payload: String) throws {
        guard let kernel else { throw KernelError.kernel("实时层没有运行") }
        try kernel.ingest(topic: topic, payload: payload)
        pull()
    }

    private func reconfigure() {
        guard let kernel else { return }
        do {
            try kernel.configure(config)
        } catch {
            Log.warn("checkup: 实时层重新配置失败：\(error)")
        }
        pull()
    }

    /// The kernel's event lines — a feed lost or refused, a fallback taken, an
    /// instrument followed — go to the engine log once each, so a degraded
    /// reading can be reconstructed afterwards.
    private func log(_ events: [LiveSnapshot.Event]) {
        for event in events where event.id > loggedEventId {
            Log.warn("checkup: \(event.message)")
            loggedEventId = event.id
        }
    }

    // MARK: - CLI fallback

    private func followFallback(needed: Bool) {
        if needed, network, fallback == nil {
            Log.warn("checkup: 账户推送不可用，改由 okx CLI 读取持仓")
            let interval = UInt64(Self.fallbackInterval * 1_000_000_000)
            fallback = Task { @MainActor [weak self] in
                while !Task.isCancelled {
                    await self?.readThroughCLI()
                    try? await Task.sleep(nanoseconds: interval)
                }
            }
        } else if !needed, let task = fallback {
            task.cancel()
            fallback = nil
            fallbackError = nil
            Log.warn("checkup: 账户推送恢复，停止 CLI 读取")
        }
    }

    private func readThroughCLI() async {
        do {
            let documents = try await venue.accountDocuments(mode: mode)
            try kernel?.ingest(topic: "cli.positions", payload: documents.positions)
            try kernel?.ingest(topic: "cli.account", payload: documents.balance)
            fallbackError = nil
            pull()
        } catch {
            let message = (error as? TradeError)?.description ?? String(describing: error)
            fallbackError = message
            Log.warn("checkup: CLI 读取持仓失败：\(message)")
        }
    }
}
