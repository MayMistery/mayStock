import Foundation

/// Where a proposed order waits while a human decides.
///
/// The confirmation is a modal dialog, so it dies with the process — and the
/// app did crash while one was on screen (a SwiftUI hover-tracking fault in the
/// macOS 27 SDK, unrelated to this feature), taking the proposal with it and
/// leaving the person who sent it believing it was still pending. A proposal
/// that only exists inside a window is a proposal that can vanish silently.
///
/// So the intent is written here *before* the dialog opens, and the record is
/// removed only once it has actually been answered. On the next launch anything
/// still unanswered comes back — repriced against the book that exists then,
/// which is safe precisely because a relative basis carries no stale price.
public struct PendingOrderStore: Sendable {

    /// A proposal on disk, with the bookkeeping that decides whether it is
    /// still worth showing.
    public struct Record: Sendable, Equatable, Codable {
        public var intent: PendingOrderIntent
        public var receivedAt: Date
        /// Set when execution begins. A record that carries this and is found
        /// again at launch crashed *mid-flight*, which is a different and worse
        /// situation than one that was never answered: an order may be live at
        /// the exchange. It is never silently retried.
        public var startedAt: Date?

        public init(intent: PendingOrderIntent, receivedAt: Date, startedAt: Date? = nil) {
            self.intent = intent
            self.receivedAt = receivedAt
            self.startedAt = startedAt
        }

        public func age(now: Date = Date()) -> TimeInterval {
            now.timeIntervalSince(receivedAt)
        }
    }

    /// How long an unanswered proposal stays worth restoring. Past this it is
    /// discarded rather than shown: an option's book moves in minutes, and
    /// reviving a half-hour-old proposal invites confirming something whose
    /// rationale has expired.
    public static let staleAfter: TimeInterval = 15 * 60

    private let directory: URL
    /// `FileManager.default` is documented thread-safe for the operations used
    /// here; it is simply not annotated `Sendable`. Held unchecked rather than
    /// dropping the injection point the tests need.
    private nonisolated(unsafe) let fileManager: FileManager

    public init(directory: URL, fileManager: FileManager = .default) {
        self.directory = directory
        self.fileManager = fileManager
    }

    /// The canonical location, beside the rest of the app's state.
    public static func defaultDirectory() -> URL {
        ConfigIO.defaultDirectory().appendingPathComponent("pending-orders")
    }

    private func url(for nonce: String) -> URL {
        // The nonce reaches us from a URL, so it cannot be trusted as a file
        // name: `../` in it would write outside the directory.
        directory.appendingPathComponent("\(Self.sanitize(nonce)).json")
    }

    static func sanitize(_ nonce: String) -> String {
        let allowed = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_")
        let cleaned = String(nonce.map { allowed.contains($0) ? $0 : "_" })
        return cleaned.isEmpty ? "unnamed" : String(cleaned.prefix(120))
    }

    private static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    private static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    // MARK: - Writing

    /// Record a proposal before showing it. Throwing here is deliberate: the
    /// caller decides whether to proceed without a safety net, and doing so
    /// silently would recreate the bug this type exists to fix.
    public func save(_ record: Record) throws {
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        try Self.encoder().encode(record).write(to: url(for: record.intent.nonce), options: .atomic)
    }

    /// Mark a proposal as being executed, so a crash during the round trip is
    /// distinguishable from one before it.
    public func markStarted(_ nonce: String, at date: Date = Date()) {
        guard var record = load(nonce) else { return }
        record.startedAt = date
        try? save(record)
    }

    public func load(_ nonce: String) -> Record? {
        guard let data = try? Data(contentsOf: url(for: nonce)) else { return nil }
        return try? Self.decoder().decode(Record.self, from: data)
    }

    /// Answered, one way or another. Cancelled, placed, refused — all the same
    /// to this type: the decision has been made and must not be revisited.
    public func resolve(_ nonce: String) {
        try? fileManager.removeItem(at: url(for: nonce))
    }

    // MARK: - Reading back

    public enum Restorable: Sendable, Equatable {
        /// Never answered and still fresh: show it again.
        case pending(Record)
        /// Execution had begun. Not retried — the exchange may already hold the
        /// order, and a silent retry is the one outcome worse than no order.
        case interrupted(Record)
        /// Too old to act on.
        case stale(Record)
    }

    /// Everything on disk, classified. Unreadable files are deleted and
    /// reported: a record we cannot parse is a record we cannot honour, and
    /// leaving it would make every future launch retry the same failure.
    public func restorable(
        now: Date = Date(), staleAfter: TimeInterval = PendingOrderStore.staleAfter
    ) -> (items: [Restorable], unreadable: [String]) {
        guard let names = try? fileManager.contentsOfDirectory(atPath: directory.path) else {
            return ([], [])
        }
        var items: [Restorable] = []
        var unreadable: [String] = []
        for name in names.sorted() where name.hasSuffix(".json") {
            let fileURL = directory.appendingPathComponent(name)
            guard let data = try? Data(contentsOf: fileURL),
                  let record = try? Self.decoder().decode(Record.self, from: data)
            else {
                unreadable.append(name)
                try? fileManager.removeItem(at: fileURL)
                continue
            }
            if record.startedAt != nil {
                items.append(.interrupted(record))
            } else if record.age(now: now) > staleAfter {
                items.append(.stale(record))
            } else {
                items.append(.pending(record))
            }
        }
        return (items, unreadable)
    }
}
