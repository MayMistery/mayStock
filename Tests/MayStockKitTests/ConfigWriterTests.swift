import Foundation
import Testing
@testable import MayStockKit

private func directory() -> URL {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("maystock-writers-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

private func at(_ seconds: TimeInterval) -> Date { Date(timeIntervalSince1970: seconds) }

/// Every optional filled and every list non-empty, so a walk over it meets
/// every part of the schema a config can hold.
private func populated() -> AppConfig {
    var config = AppConfig.default
    config.watchlist = [
        WatchItem(instId: "BTC-USDT", label: "比特币", decimals: 1),
        WatchItem(venue: .schwab, instId: "QQQ", enabled: false, style: .priceOnly,
                  sparklineMinutes: 1_440, defaultBar: .m5),
    ]
    config.alerts = [
        AlertRule(instId: "BTC-USDT", condition: .priceAbove(120_000), note: "突破", shellHook: "echo hi",
                  rearmAfterSeconds: 60, lastTriggeredAt: at(1_790_000_000)),
        AlertRule(instId: "ETH-USDT-SWAP", condition: .movePctWithin(windowMinutes: 5, pct: 0.5)),
    ]
    config.trading.cliPath = "/usr/local/bin/okx"
    config.trading.demoProfile = "demo"
    config.trading.liveProfile = "live"
    config.trading.schwabCLIPath = "/usr/local/bin/schwabctl"
    config.strategy.allocations = [
        StrategyAllocation(strategyId: "a", capital: 1_000, running: true, leverageCap: 2, addedAt: at(1_780_000_000)),
        StrategyAllocation(strategyId: "b", venue: .schwab, capital: 500, addedAt: at(1_780_000_000),
                           haltReason: "日内亏损"),
    ]
    config.strategy.maxOrderNotional = 5_000
    config.strategy.feeSchedules.okx.swapTakerOverrideBps = 4.5
    config.strategy.feeSchedules.okx.syncedAt = at(1_785_000_000)
    return config
}

/// A strategy armed with a budget, as the review finds it.
private func seedArmed(_ io: ConfigIO) throws {
    try io.update { config in
        config.strategy.capital[.okx] = 10_000
        config.strategy.allocations = [
            StrategyAllocation(strategyId: "a", capital: 1_000, running: true, addedAt: at(1_780_000_000)),
            StrategyAllocation(strategyId: "b", capital: 1_000, running: true, addedAt: at(1_780_000_000)),
        ]
    }
}

@Suite("Two writers, one config file")
struct ConfigWriterTests {
    /// The failure this suite exists for: the app loads the config at launch
    /// and keeps it in memory; the unattended review halts a strategy on
    /// disk; the app then saves its stale copy over it for an unrelated
    /// reason, and the strategy is armed again with nothing logged.
    @Test func aStaleWriterDoesNotUndoAHalt() throws {
        let dir = directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        try seedArmed(ConfigIO(directory: dir))

        let app = ConfigIO(directory: dir)
        let launch = app.readBaseline().baseline
        var inMemory = launch.config

        try ConfigIO(directory: dir).update { config in
            config = ReviewActuator.apply([.halt(strategyId: "a", reason: "超出授权额度")], to: config).config
        }

        inMemory.alerts.append(AlertRule(instId: "BTC-USDT", condition: .priceAbove(100_000)))
        let commit = try app.commit(inMemory, over: launch)

        let onDisk = ConfigIO(directory: dir).load()
        #expect(onDisk.strategy.allocation(for: "a")?.running == false)
        #expect(onDisk.strategy.allocation(for: "a")?.haltReason == "超出授权额度")
        #expect(onDisk.alerts.map(\.instId) == ["BTC-USDT"])
        // The app is handed what it now runs on, and what changed, to log.
        let merge = try #require(commit.merge)
        #expect(merge.config == onDisk)
        #expect(merge.adopted.contains {
            $0.path == "strategy.allocations[a].running" && $0.before == "true" && $0.after == "false"
        })
        #expect(merge.kept.contains { $0.path.hasPrefix("alerts[") })
        #expect(merge.conflicts.isEmpty)
    }

    /// Every action the review can take survives the app's next save. The
    /// switch is exhaustive on purpose: an action added to `ReviewAction`
    /// does not compile here until it is checked too.
    @Test(arguments: [
        ReviewAction.halt(strategyId: "a", reason: "超出授权额度"),
        .reduceCapital(strategyId: "a", to: 400, reason: "预算超额"),
        .emergencyStop(reason: "组合回撤越线"),
    ])
    func everyReviewActionSurvivesTheAppsNextSave(_ action: ReviewAction) throws {
        let dir = directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        try seedArmed(ConfigIO(directory: dir))
        let app = ConfigIO(directory: dir)
        let launch = app.readBaseline().baseline
        var inMemory = launch.config

        let review = try ConfigIO(directory: dir).update { config -> ReviewActionOutcome in
            let outcome = ReviewActuator.apply([action], to: config)
            config = outcome.config
            return outcome
        }
        #expect(review.result.applied == [action])

        inMemory.general.hoverDelayMs = 220
        _ = try app.commit(inMemory, over: launch)

        let onDisk = ConfigIO(directory: dir).load()
        switch action {
        case .halt(let id, let reason):
            #expect(onDisk.strategy.allocation(for: id)?.running == false)
            #expect(onDisk.strategy.allocation(for: id)?.haltReason == reason)
        case .reduceCapital(let id, let amount, _):
            #expect(onDisk.strategy.allocation(for: id)?.capital == amount)
        case .emergencyStop:
            #expect(onDisk.strategy.emergencyStop)
        }
        #expect(onDisk.general.hoverDelayMs == 220)
    }

    /// The app follows the file: another writer's change is folded into its
    /// copy as it lands, its own unsaved edits ride on top, and its next save
    /// is then an ordinary one.
    @Test func aRefreshFoldsInTheOtherWriterAndKeepsUnsavedEdits() throws {
        let dir = directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        try seedArmed(ConfigIO(directory: dir))
        let app = ConfigIO(directory: dir)
        let launch = app.readBaseline().baseline
        var inMemory = launch.config
        inMemory.strategy.setCapital(600, for: "b", on: .okx)

        guard case .unchanged = try app.refresh(inMemory, over: launch) else {
            Issue.record("nobody else has written")
            return
        }
        try ConfigIO(directory: dir).update { $0.strategy.setRunning(false, for: "a") }

        guard case .changed(let merge, let current) = try app.refresh(inMemory, over: launch) else {
            Issue.record("the other writer's change should be seen")
            return
        }
        #expect(merge.config.strategy.allocation(for: "a")?.running == false)
        #expect(merge.config.strategy.allocation(for: "b")?.capital == 600)
        #expect(merge.adopted.map(\.path) == ["strategy.allocations[a].running"])
        #expect(merge.kept.map(\.path) == ["strategy.allocations[b].capital"])
        #expect(current == ConfigIO(directory: dir).readBaseline().baseline)

        let commit = try app.commit(merge.config, over: current)
        #expect(commit.merge == nil, "nothing moved since the fold-in")
        #expect(commit.wrote)
        #expect(ConfigIO(directory: dir).load() == merge.config)
    }

    /// Both writers changed one value: the file's stands — it is the one
    /// already written and acted on — and the conflict is reported with both.
    @Test func bothChangingOneValueKeepsTheFilesAndSaysSo() throws {
        let dir = directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        try seedArmed(ConfigIO(directory: dir))
        let app = ConfigIO(directory: dir)
        let launch = app.readBaseline().baseline
        var inMemory = launch.config
        inMemory.strategy.setCapital(800, for: "a", on: .okx)
        try ConfigIO(directory: dir).update { $0.strategy.setCapital(500, for: "a", on: .okx) }

        let merge = try #require(try app.commit(inMemory, over: launch).merge)
        #expect(merge.config.strategy.allocation(for: "a")?.capital == 500)
        #expect(merge.conflicts == [ConfigMerge.Conflict(path: "strategy.allocations[a].capital", mine: "800", theirs: "500")])
        #expect(ConfigIO(directory: dir).load().strategy.allocation(for: "a")?.capital == 500)
    }

    /// The review's actions are applied to the file as it is when it writes,
    /// not to the copy its checks read — and its invariant is checked
    /// against that file. A budget cut lower meanwhile is not raised back to
    /// the review's figure.
    @Test func theReviewAppliesItsActionsToTheFileAsItIsNow() throws {
        let dir = directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let io = ConfigIO(directory: dir)
        try seedArmed(io)
        let checked = io.load()
        #expect(checked.strategy.allocation(for: "a")?.capital == 1_000)

        try ConfigIO(directory: dir).update { $0.strategy.setCapital(300, for: "a", on: .okx) }

        let write = try io.update(keepingCopyAs: "review") { config -> ReviewActionOutcome in
            let outcome = ReviewActuator.apply([
                .reduceCapital(strategyId: "a", to: 500, reason: "预算超额"),
                .halt(strategyId: "b", reason: "超出授权额度"),
            ], to: config)
            config = outcome.config
            return outcome
        }
        #expect(write.result.applied.map(\.strategyId) == ["b"])
        #expect(write.result.rejected.first?.why.contains("提高") == true)
        let onDisk = io.load()
        #expect(onDisk.strategy.allocation(for: "a")?.capital == 300)
        #expect(onDisk.strategy.allocation(for: "b")?.running == false)
        #expect(try ConfigMerge.differences(from: checked, to: write.before.config).map(\.path)
                == ["strategy.allocations[a].capital"])
    }

    /// An unattended change keeps the file it replaced, so it can be undone
    /// by hand — and keeps nothing when it changed nothing.
    @Test func anUnattendedChangeKeepsTheFileItReplaced() throws {
        let dir = directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let io = ConfigIO(directory: dir)
        try seedArmed(io)
        let before = try Data(contentsOf: io.fileURL)

        let write = try io.update(keepingCopyAs: "review") { $0.strategy.emergencyStop = true }
        let kept = try #require(write.keptCopy)
        #expect(kept.lastPathComponent.hasPrefix("config.json.review-"))
        #expect(try Data(contentsOf: kept) == before)
        #expect(write.changed)

        let again = try io.update(keepingCopyAs: "review") { $0.strategy.emergencyStop = true }
        #expect(again.keptCopy == nil)
        #expect(!again.changed)
    }

    /// A writer with no copy of its own refuses a file it cannot read: its
    /// change would be a change to the defaults, written over the user's file.
    @Test func aWriterWithoutACopyRefusesAFileItCannotRead() throws {
        let dir = directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let io = ConfigIO(directory: dir)
        let garbage = Data("{\"schemaVersion\": 5, \"watchlist\": [".utf8)
        try garbage.write(to: io.fileURL)

        #expect(throws: ConfigReadIssue.self) { try io.update { $0.strategy.emergencyStop = true } }
        #expect(try Data(contentsOf: io.fileURL) == garbage)
    }

    /// A long-lived writer holds a whole config, so a file that became
    /// unreadable under it is kept beside itself and written over — and the
    /// writer is told, to log it.
    @Test func aLongLivedWriterReplacesAFileThatTurnedUnreadableAndKeepsIt() throws {
        let dir = directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let app = ConfigIO(directory: dir)
        try seedArmed(app)
        let launch = app.readBaseline().baseline
        let typo = Data("{\"schemaVersion\": 5,,}".utf8)
        try typo.write(to: app.fileURL)

        guard case .unreadable(let issue, _) = try app.refresh(launch.config, over: launch) else {
            Issue.record("an unreadable file is not folded in")
            return
        }
        let commit = try app.commit(launch.config, over: launch)
        #expect(commit.replacedUnreadable?.keptAt == issue.keptAt)
        #expect(try Data(contentsOf: try #require(issue.keptAt)) == typo)
        #expect(app.load() == launch.config)
    }

    @Test func aRemovedFileIsReportedAndWrittenAfresh() throws {
        let dir = directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let app = ConfigIO(directory: dir)
        try seedArmed(app)
        let launch = app.readBaseline().baseline
        try FileManager.default.removeItem(at: app.fileURL)

        guard case .removed(let current) = try app.refresh(launch.config, over: launch) else {
            Issue.record("a removed file is reported")
            return
        }
        #expect(current.data == nil)
        let commit = try app.commit(launch.config, over: launch)
        #expect(commit.recreated)
        #expect(app.load() == launch.config)
    }

    /// While another writer holds the lock, a write waits, and gives up with
    /// a reason rather than writing around it.
    @Test func aWriterWaitsForTheLockAndGivesUpSayingWhy() throws {
        let dir = directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let io = ConfigIO(directory: dir)
        try seedArmed(io)
        let launch = io.readBaseline().baseline

        // Another open of the lock file is another holder, exactly as another
        // process would be: the lock belongs to the open file, not the process.
        let holder = open(io.lockURL.path, O_RDWR)
        #expect(holder >= 0)
        #expect(flock(holder, LOCK_EX) == 0)
        #expect(throws: ConfigLockError.busy(waited: 0.05)) {
            try io.update(waitingUpTo: 0.05) { $0.strategy.emergencyStop = true }
        }
        #expect(throws: ConfigLockError.busy(waited: 0.05)) {
            try io.commit(launch.config, over: launch, waitingUpTo: 0.05)
        }
        #expect(io.load() == launch.config)
        flock(holder, LOCK_UN)
        close(holder)

        try io.update(waitingUpTo: 0.05) { $0.strategy.emergencyStop = true }
        #expect(io.load().strategy.emergencyStop)
    }

    /// A writer can tell whether its change will be taken in: a follower
    /// holds the follow lock for as long as it lives, and stops counting the
    /// moment it is gone — its process ending is enough.
    @Test func aWriterCanTellWhetherAnyoneFollowsTheFile() throws {
        let dir = directory(), elsewhere = directory()
        defer {
            try? FileManager.default.removeItem(at: dir)
            try? FileManager.default.removeItem(at: elsewhere)
        }
        let io = ConfigIO(directory: dir)
        #expect(try io.isFollowed() == false, "nobody has ever followed it")

        var following: ConfigFollowing? = try io.follow()
        #expect(following != nil)
        #expect(try io.isFollowed())
        #expect(try ConfigIO(directory: dir).isFollowed(), "seen from any other reader of the directory")
        #expect(try ConfigIO(directory: elsewhere).isFollowed() == false, "and only for its own file")
        // Writing does not wait on followers.
        try io.update(waitingUpTo: 0.05) { $0.general.hoverDelayMs = 300 }

        following = nil
        #expect(try io.isFollowed() == false)
    }
}

// MARK: - The review's write

@Suite("The review's write says whether it will hold")
struct ReviewWriteTests {
    /// Followed is quiet; written while a MayStock runs that does not follow
    /// the file is critical; not written at all is critical — as findings, so
    /// the verdict, the exit code and the hourly log carry them.
    @Test func everyWayAWriteCanEndIsReported() throws {
        let dir = directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let io = ConfigIO(directory: dir)
        try seedArmed(io)
        let checked = io.load()

        var following: ConfigFollowing? = try io.follow()
        let followed = ReviewActuator.write(
            [.halt(strategyId: "a", reason: "超出授权额度")], checked: checked, to: io, appRunning: true)
        #expect(followed.follower == .following)
        #expect(followed.findings.isEmpty)
        #expect(followed.update?.keptCopy != nil)
        #expect(io.load().strategy.allocation(for: "a")?.running == false)
        following = nil
        #expect(following == nil)

        let unfollowed = ReviewActuator.write(
            [.halt(strategyId: "b", reason: "超出授权额度")], checked: checked, to: io, appRunning: true)
        #expect(unfollowed.follower == .nobody)
        #expect(unfollowed.findings.map(\.code) == ["config.unfollowed"])
        #expect(unfollowed.findings.first?.severity == .critical)
        // Applied to the file as it was, which the first halt had moved.
        #expect(unfollowed.movedSinceChecked.contains { $0.hasPrefix("strategy.allocations[a].running") })

        let noApp = ReviewActuator.write(
            [.emergencyStop(reason: "组合回撤越线")], checked: checked, to: io, appRunning: false)
        #expect(noApp.follower == .nobody)
        #expect(noApp.findings.isEmpty, "the next launch reads it")

        let moot = ReviewActuator.write(
            [.emergencyStop(reason: "组合回撤越线")], checked: checked, to: io, appRunning: true)
        #expect(moot.update?.changed == false)
        #expect(moot.follower == nil)
        #expect(moot.findings.isEmpty)

        let holder = open(io.lockURL.path, O_RDWR)
        #expect(flock(holder, LOCK_EX) == 0)
        defer {
            flock(holder, LOCK_UN)
            close(holder)
        }
        let before = try Data(contentsOf: io.fileURL)
        let blocked = ReviewActuator.write(
            [.reduceCapital(strategyId: "a", to: 1, reason: "预算超额")], checked: checked, to: io,
            appRunning: true, waitingUpTo: 0.05)
        #expect(blocked.update == nil)
        #expect(blocked.findings.map(\.code) == ["config.writeFailed"])
        #expect(blocked.findings.first?.severity == .critical)
        #expect(try Data(contentsOf: io.fileURL) == before)
    }
}

// MARK: - The merge

@Suite("Merging two writers' edits")
struct ConfigMergeTests {
    /// Removing an entry must not slide the other writer's edit onto its
    /// neighbour: list elements are matched by id, never by position.
    @Test func listsMergeByIdNotByPosition() throws {
        let base = populated()
        var theirs = base
        theirs.watchlist.removeFirst()
        var mine = base
        mine.watchlist[1].label = "纳指"

        let outcome = try ConfigMerge.merge(base: base, mine: mine, theirs: theirs)
        #expect(outcome.config.watchlist.map(\.instId) == ["QQQ"])
        #expect(outcome.config.watchlist.first?.label == "纳指")
        #expect(outcome.conflicts.isEmpty)
    }

    /// A list keeps the file's order unless only this writer reordered it;
    /// two different reorders are a conflict, settled the file's way.
    @Test func orderIsTheFilesUnlessOnlyThisWriterMovedIt() throws {
        var base = AppConfig.default
        base.watchlist = ["A", "B", "C"].map { WatchItem(instId: $0) }
        var mine = base
        mine.watchlist = [base.watchlist[2], base.watchlist[0], base.watchlist[1]]
        var theirs = base
        theirs.watchlist[1].enabled = false

        let moved = try ConfigMerge.merge(base: base, mine: mine, theirs: theirs)
        #expect(moved.config.watchlist.map(\.instId) == ["C", "A", "B"])
        #expect(moved.config.watchlist[2].enabled == false)
        #expect(moved.conflicts.isEmpty)

        theirs.watchlist = [base.watchlist[1], base.watchlist[0], base.watchlist[2]]
        let both = try ConfigMerge.merge(base: base, mine: mine, theirs: theirs)
        #expect(both.config.watchlist.map(\.instId) == ["B", "A", "C"])
        #expect(both.conflicts.map(\.path) == ["watchlist（顺序）"])
    }

    /// An entry this writer removed and the other edited stays, edited: the
    /// file's side of a conflict stands.
    @Test func anEntryRemovedHereAndEditedThereStays() throws {
        let base = populated()
        var mine = base
        mine.strategy.remove(strategyId: "a")
        var theirs = base
        theirs.strategy.setRunning(false, for: "a")

        let outcome = try ConfigMerge.merge(base: base, mine: mine, theirs: theirs)
        #expect(outcome.config.strategy.allocation(for: "a")?.running == false)
        #expect(outcome.conflicts.map(\.path) == ["strategy.allocations[a]"])
        #expect(outcome.conflicts.first?.mine == "（无）")
    }

    /// Both writers turning one enum to different cases merges into an
    /// object with two cases, which no decoder accepts. The part the decoder
    /// names is taken from the file and reported; the rest of the edits land.
    @Test func aMergeThatWouldNotReadBackTakesTheFilesPartAndSaysSo() throws {
        var base = AppConfig.default
        let id = UUID()
        base.alerts = [AlertRule(id: id, instId: "BTC-USDT", condition: .priceAbove(100_000))]
        var mine = base
        mine.alerts[0].condition = .priceBelow(90_000)
        mine.alerts[0].note = "跌破"
        var theirs = base
        theirs.alerts[0].condition = .changePct24hAbove(5)

        let outcome = try ConfigMerge.merge(base: base, mine: mine, theirs: theirs)
        #expect(outcome.config.alerts.first?.condition == .changePct24hAbove(5))
        #expect(outcome.config.alerts.first?.note == "跌破")
        #expect(outcome.conflicts.map(\.path) == ["alerts[\(id)].condition"])
    }

    /// Every value in the schema merges on its own: one writer's edit to any
    /// leaf survives the other writer's edits to every other leaf, with no
    /// conflict. Walked over the config's own tree, so a field added later
    /// is covered the day it is added; edits need not be values the config
    /// could hold, because the tree merge does not read them back.
    @Test func everyValueMergesOnItsOwn() throws {
        let base = try ConfigMerge.tree(of: populated())
        let leaves = Self.leaves(of: base)
        #expect(leaves.count > 40)
        for leaf in leaves {
            let mine = Self.setting(base, at: leaf[...], to: .string("mine"))
            var theirs = base
            for other in leaves where other != leaf {
                theirs = Self.setting(theirs, at: other[...], to: .string("theirs"))
            }
            let (merged, conflicts) = ConfigMerge.merge(base: base, mine: mine, theirs: theirs)
            let result = try #require(merged)
            #expect(conflicts.isEmpty, "\(leaf)")
            #expect(Self.value(in: result, at: leaf[...]) == .string("mine"), "\(leaf)")
            let othersLanded = leaves.filter { $0 != leaf }.allSatisfy {
                Self.value(in: result, at: $0[...]) == .string("theirs")
            }
            #expect(othersLanded, "\(leaf)")
        }
    }

    /// Every list the config can hold merges element by element. One that
    /// merged as a single value would turn two writers' edits to different
    /// entries into a conflict, and drop one of them.
    @Test func everyListMergesElementByElement() throws {
        for config in [AppConfig.default, populated()] {
            let lists = try ConfigMerge.lists(in: config)
            #expect(lists.keys.contains("strategy.allocations"))
            for (path, identified) in lists.sorted(by: { $0.key < $1.key }) {
                #expect(identified, "\(path) 的元素不是 Identifiable：两个写者各改一项时，有一项会被丢掉")
            }
        }
    }

    @Test func jsonValuesRoundTripExactly() throws {
        let text = #"{"a":true,"b":1,"c":1.5,"d":"x","e":null,"f":[1,"y"],"g":{"h":-2},"i":18446744073709551615}"#
        let value = try JSONDecoder().decode(JSONValue.self, from: Data(text.utf8))
        #expect(value == .object([
            "a": .bool(true), "b": .int(1), "c": .double(1.5), "d": .string("x"), "e": .null,
            "f": .array([.int(1), .string("y")]), "g": .object(["h": .int(-2)]),
            "i": .unsigned(18_446_744_073_709_551_615),
        ]))
        #expect(try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(value)) == value)
    }

    // MARK: Walking the tree

    private enum Step: Equatable, CustomStringConvertible {
        case key(String)
        case element(AnyHashable)

        var description: String {
            switch self {
            case .key(let key): return key
            case .element(let id): return "[\(id.base)]"
            }
        }
    }

    private static func leaves(of node: ConfigNode, at path: [Step] = []) -> [[Step]] {
        switch node {
        case .value, .list:
            return [path]
        case .object(let members):
            return members.keys.sorted().flatMap { leaves(of: members[$0]!, at: path + [.key($0)]) }
        case .identified(let elements):
            return elements.flatMap { leaves(of: $0.node, at: path + [.element($0.id)]) }
        }
    }

    private static func setting(_ node: ConfigNode, at path: ArraySlice<Step>, to value: JSONValue) -> ConfigNode {
        guard let step = path.first else { return .value(value) }
        switch (node, step) {
        case (.object(var members), .key(let key)):
            members[key] = setting(members[key]!, at: path.dropFirst(), to: value)
            return .object(members)
        case (.identified(var elements), .element(let id)):
            let index = elements.firstIndex { $0.id == id }!
            elements[index] = ConfigNode.Element(id: id, node: setting(elements[index].node, at: path.dropFirst(), to: value))
            return .identified(elements)
        default:
            return node
        }
    }

    private static func value(in node: ConfigNode, at path: ArraySlice<Step>) -> JSONValue? {
        guard let step = path.first else {
            if case .value(let value) = node { return value }
            return nil
        }
        switch (node, step) {
        case (.object(let members), .key(let key)):
            return members[key].flatMap { value(in: $0, at: path.dropFirst()) }
        case (.identified(let elements), .element(let id)):
            return elements.first { $0.id == id }.flatMap { value(in: $0.node, at: path.dropFirst()) }
        default:
            return nil
        }
    }
}

// MARK: - Rules every change obeys

@Suite("Rules every config change obeys")
struct ConfigTransitionRuleTests {
    private func armed(_ mode: TradingMode, unlocked: Bool) -> AppConfig {
        var config = AppConfig.default
        config.strategy.mode = mode
        config.trading.liveTradingUnlocked = unlocked
        config.strategy.allocations = [
            StrategyAllocation(strategyId: "a", capital: 1_000, running: true),
            StrategyAllocation(strategyId: "b", capital: 1_000, running: false),
        ]
        return config
    }

    @Test func crossingBetweenDemoAndLiveDisarmsEveryStrategy() {
        let before = armed(.demo, unlocked: true)
        var after = before
        after.strategy.mode = .live
        let enforced = after.enforceTransitionRules(from: before)
        #expect(after.strategy.allocations.allSatisfy { !$0.running })
        #expect(after.strategy.mode == .live)
        #expect(enforced == ["交易模式 demo → live，停用 a"])
    }

    @Test func lockingLiveWhileOnItMovesToDemoAndDisarms() {
        let before = armed(.live, unlocked: true)
        var after = before
        after.trading.liveTradingUnlocked = false
        let enforced = after.enforceTransitionRules(from: before)
        #expect(after.strategy.mode == .demo)
        #expect(after.strategy.allocations.allSatisfy { !$0.running })
        #expect(enforced.count == 2)
    }

    @Test func lockingLiveOnDemoAndUnrelatedChangesEnforceNothing() {
        let before = armed(.demo, unlocked: true)
        var locked = before
        locked.trading.liveTradingUnlocked = false
        #expect(locked.enforceTransitionRules(from: before).isEmpty)
        #expect(locked.strategy.allocation(for: "a")?.running == true)

        var edited = before
        edited.strategy.setCapital(500, for: "a", on: .okx)
        edited.alerts = [AlertRule(instId: "BTC-USDT", condition: .priceAbove(1))]
        let untouched = edited
        #expect(edited.enforceTransitionRules(from: before).isEmpty)
        #expect(edited == untouched)
    }
}

// MARK: - Following the file

#if canImport(Darwin)
@Suite("Following a file")
struct FileWatcherTests {
    private final class Calls: @unchecked Sendable {
        var count = 0
    }

    @MainActor
    private func wait(_ calls: Calls, toPass count: Int) async -> Bool {
        for _ in 0..<300 {
            if calls.count > count { return true }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        return false
    }

    private func append(_ text: String, to url: URL) throws {
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(text.utf8))
    }

    /// An atomic save puts a new file under the name; a watch on the file
    /// alone would hear the first and never another. Every kind of save is
    /// heard, repeatedly, including writes in place after the name moved.
    @Test @MainActor func hearsEveryKindOfSaveAgainAndAgain() async throws {
        let dir = directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("config.json")
        try Data("0".utf8).write(to: file)
        let calls = Calls()
        let watcher = FileWatcher(url: file, coalescingFor: 0.01) { calls.count += 1 }
        defer { watcher.cancel() }

        for round in 1...3 {
            let before = calls.count
            try Data("\(round)".utf8).write(to: file, options: .atomic)
            #expect(await wait(calls, toPass: before), "atomic save \(round)")
        }
        var before = calls.count
        try append("x", to: file)
        #expect(await wait(calls, toPass: before), "write in place after atomic saves")

        before = calls.count
        try FileManager.default.removeItem(at: file)
        #expect(await wait(calls, toPass: before), "removed")
        before = calls.count
        try Data("back".utf8).write(to: file)
        #expect(await wait(calls, toPass: before), "created again")
        before = calls.count
        try append("y", to: file)
        #expect(await wait(calls, toPass: before), "write in place after it came back")
    }
}
#endif
