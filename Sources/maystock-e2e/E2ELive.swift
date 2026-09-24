import Foundation
import MayStockKit

extension E2EMain {

    /// The live layer against the real venues, through exactly what the app
    /// uses: the kernel's C interface, `LiveSnapshot` decoding, and ages
    /// corrected by the measured clock offset. Reads the app's own config for
    /// the trading mode, the CLI profile and `schwabctl`, so it sees what the
    /// checkup page would.
    ///
    /// Passes when the feeds everything else depends on are live and the
    /// probability table has columns; the rest is reported, not required.
    static func liveDoctor(seconds: Int) async -> Bool {
        print("live layer doctor (\(seconds) s)")
        let config = ConfigIO(directory: ConfigIO.defaultDirectory()).load()
        let mode = config.strategy.mode
        let bridge = TradeBridge(prefs: config.trading)
        let kernel: LiveKernel
        do {
            kernel = try LiveKernel(config: LiveKernel.Config(
                instId: "ETH-USDT-SWAP", followsHeldPosition: true, mode: mode,
                okxProfile: bridge.profile(for: mode),
                okxConfigPath: OKXProfileCatalog.defaultFileURL().path,
                schwabctlPath: SchwabBridge(prefs: config.trading).resolveCLIPath()))
        } catch {
            fail("start", String(describing: error))
            return false
        }
        defer { kernel.stop() }

        var seq: UInt64 = 0
        var latest: LiveSnapshot?
        var snapshots = 0
        let started = Date()
        var nextReport = started.addingTimeInterval(10)
        while Date().timeIntervalSince(started) < Double(seconds) {
            if let (next, json) = kernel.snapshot(since: seq) {
                seq = next
                snapshots += 1
                do {
                    latest = try JSONDecoder().decode(LiveSnapshot.self, from: json)
                } catch {
                    fail("snapshot decode", String(describing: error))
                    return false
                }
            }
            if Date() >= nextReport, let snapshot = latest {
                report(snapshot, snapshots: snapshots, elapsed: Date().timeIntervalSince(started))
                nextReport = nextReport.addingTimeInterval(10)
            }
            try? await Task.sleep(nanoseconds: 16_000_000)
        }
        guard let snapshot = latest else {
            fail("snapshot", "none arrived")
            return false
        }
        report(snapshot, snapshots: snapshots, elapsed: Date().timeIntervalSince(started))

        var ok = true
        for id in ["okx.public", "deribit", "options.book", "clock"] {
            if let feed = snapshot.feed(id), feed.isLive {
                pass(feed.label)
            } else {
                fail(id, snapshot.feed(id)?.detail ?? "not live")
                ok = false
            }
        }
        if snapshot.probability.columns.isEmpty {
            fail("价格区间概率", "no columns")
            ok = false
        } else {
            pass("价格区间概率", "\(snapshot.probability.columns.count) 个到期")
        }
        return ok
    }

    private static func age(_ snapshot: LiveSnapshot, _ ms: Int64?) -> String {
        guard let ms else { return "—" }
        let age = snapshot.age(of: ms)
        return age < 1_000 ? "\(Int(age)) ms" : String(format: "%.1f s", age / 1_000)
    }

    private static func report(_ s: LiveSnapshot, snapshots: Int, elapsed: TimeInterval) {
        print(String(format: "\n— t+%.0f s · %d snapshots · clock %@", elapsed, snapshots,
                     s.clock.map { String(format: "%+.0f ms ±%.0f", $0.offsetMs, $0.roundTripMs / 2) } ?? "unmeasured"))
        for feed in s.feeds {
            print("  \(feed.state.padding(toLength: 10, withPad: " ", startingAt: 0)) \(feed.label)  last frame \(age(s, feed.lastFrameMs))  \(feed.detail ?? "")")
        }
        if let spot = s.spot { print("  spot \(spot.value) (\(spot.source), \(age(s, spot.ms)))") }
        let p = s.probability
        print("  probability: surface \(age(s, p.surfaceMs)) · index \(age(s, p.indexMs)) · anchor \(p.forwardAnchor ?? "—")")
        print("    edges " + p.edges.map { String(Int($0)) }.joined(separator: " "))
        for column in p.columns {
            let cells = column.probabilities.map { String(format: "%.1f", $0 * 100) }.joined(separator: " ")
            print(String(format: "    %.1fh %@ fit %.2f clamped %@ | %@", column.hours, column.curve, column.fitError, column.clamped.description, cells))
        }
        for row in s.gravity.expiries.prefix(4) {
            print(String(format: "  gravity %.1fh max pain %@ weak %@ beyond %@", row.hours,
                         row.maxPain.map { String($0.strike) } ?? "—", row.maxPain.map { String($0.weak) } ?? "—",
                         row.pBeyondMaxPain.map { String(format: "%.2f%%", $0 * 100) } ?? "—"))
        }
        let risk = s.risk
        print("  risk: source \(risk.source) read \(risk.wasRead) held \(risk.held) stops \(age(s, risk.stopsMs))")
        if let position = risk.position {
            print(String(format: "    %@ %.2f liq %@ buffer %@ mark %@ (%@)", position.instId, position.contracts,
                         position.liquidationPrice.map { String($0) } ?? "—",
                         position.liquidationBufferPct.map { String(format: "%.2f%%", $0) } ?? "—",
                         position.markPrice.map { String($0) } ?? "—", age(s, position.markMs)))
            print("    protective \(position.protective.count)" + position.protective.map { order in
                " · \(order.kind) sl \(order.stopPrice.map { String($0) } ?? "—") tp \(order.takeProfitPrice.map { String($0) } ?? "—")"
            }.joined() + (risk.stopsError.map { " · stops error: \($0)" } ?? ""))
            for odds in risk.liquidationOdds {
                print(String(format: "    %3.0fh touch %.2f%% at %.2f%% iv %.0f%% (%@)", odds.hours, odds.touching * 100, odds.atHorizon * 100, odds.iv, odds.placement))
            }
        }
        for venue in s.structure {
            print("  \(venue.venue): price \(venue.price.map { String($0.value) } ?? "—") (\(age(s, venue.price?.ms))) funding \(venue.fundingRate.map { String($0.value) } ?? "—") OI 1h \(venue.oiChange1h.map { String(format: "%+.2f%%", $0.pct) } ?? "—")")
        }
        print("  macro (\(s.macro.source)): " + s.macro.rows.map { "\($0.id) \($0.price.map { String(format: "%.2f", $0) } ?? "—") (\(age(s, $0.ms)))" }.joined(separator: " · "))
    }
}
