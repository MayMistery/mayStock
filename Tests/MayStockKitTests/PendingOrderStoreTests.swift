import Foundation
import Testing
@testable import MayStockKit

/// Proposals surviving the process that received them.
///
/// This exists because the app crashed with a confirmation dialog on screen and
/// the proposal vanished with it, leaving the sender believing it was pending.
@Suite("Pending order store")
struct PendingOrderStoreTests {

    private func makeStore() -> (PendingOrderStore, URL) {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("maystock-pending-\(UUID().uuidString)")
        return (PendingOrderStore(directory: dir), dir)
    }

    private func intent(nonce: String = "n1") -> PendingOrderIntent {
        PendingOrderIntent(
            instId: "ETH-USD-260919-2600-C", instType: .option, side: .buy, kind: .ioc,
            size: 73, priceBasis: .relative(anchor: .ask, slipPct: 3, capUSD: 200),
            mode: .live, rationale: "对冲空头", nonce: nonce)
    }

    @Test("a saved proposal comes back intact")
    func savesAndLoads() throws {
        let (store, dir) = makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        let record = PendingOrderStore.Record(intent: intent(), receivedAt: Date())
        try store.save(record)
        let back = store.load("n1")
        #expect(back?.intent == record.intent)
        #expect(back?.startedAt == nil)
    }

    @Test("answering it removes the record")
    func resolveRemoves() throws {
        let (store, dir) = makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        try store.save(.init(intent: intent(), receivedAt: Date()))
        store.resolve("n1")
        #expect(store.load("n1") == nil)
        #expect(store.restorable().items.isEmpty)
    }

    @Test("a fresh unanswered proposal is restorable")
    func freshIsPending() throws {
        let (store, dir) = makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        try store.save(.init(intent: intent(), receivedAt: Date()))
        guard case .pending(let record) = store.restorable().items.first else {
            Issue.record("expected pending")
            return
        }
        #expect(record.intent.nonce == "n1")
    }

    @Test("an old proposal is stale rather than shown again")
    func oldIsStale() throws {
        let (store, dir) = makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        // An option's book moves in minutes; reviving a half-hour-old proposal
        // invites confirming something whose rationale has expired.
        let old = Date().addingTimeInterval(-PendingOrderStore.staleAfter - 60)
        try store.save(.init(intent: intent(), receivedAt: old))
        guard case .stale = store.restorable().items.first else {
            Issue.record("expected stale")
            return
        }
    }

    @Test("one that was mid-flight is interrupted, never retried")
    func startedIsInterrupted() throws {
        let (store, dir) = makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        try store.save(.init(intent: intent(), receivedAt: Date()))
        store.markStarted("n1")
        // The exchange may already hold the order: a silent retry is the one
        // outcome worse than no order at all.
        guard case .interrupted(let record) = store.restorable().items.first else {
            Issue.record("expected interrupted")
            return
        }
        #expect(record.startedAt != nil)
    }

    @Test("an unreadable record is deleted and reported, not retried forever")
    func unreadableIsDeleted() throws {
        let (store, dir) = makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let bad = dir.appendingPathComponent("broken.json")
        try Data("not json".utf8).write(to: bad)
        let result = store.restorable()
        #expect(result.unreadable == ["broken.json"])
        #expect(result.items.isEmpty)
        // Left in place it would fail identically on every future launch.
        #expect(!FileManager.default.fileExists(atPath: bad.path))
    }

    @Test("a nonce cannot escape the directory it is written in")
    func nonceIsSanitised() throws {
        // The nonce arrives in a URL, so `../` in it must not write elsewhere.
        #expect(!PendingOrderStore.sanitize("../../etc/passwd").contains("/"))
        #expect(!PendingOrderStore.sanitize("a/b").contains("/"))
        #expect(PendingOrderStore.sanitize("hedge-2600_1") == "hedge-2600_1")
        #expect(PendingOrderStore.sanitize("") == "unnamed")

        let (store, dir) = makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        try store.save(.init(intent: intent(nonce: "../escape"), receivedAt: Date()))
        // Round-trips under its sanitised name, and only inside the directory.
        #expect(store.load("../escape")?.intent.nonce == "../escape")
        let names = try FileManager.default.contentsOfDirectory(atPath: dir.path)
        #expect(names.count == 1)
    }

    @Test("an empty or missing directory restores nothing")
    func emptyDirectoryIsFine() {
        let (store, dir) = makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        let result = store.restorable()
        #expect(result.items.isEmpty)
        #expect(result.unreadable.isEmpty)
    }
}
