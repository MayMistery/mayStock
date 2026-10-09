import Foundation
import CryptoKit

// MARK: - Reading

/// A configuration file that exists and could not be read.
public struct ConfigReadIssue: Error, Sendable, Equatable, CustomStringConvertible {
    public let reason: String
    /// Where the unreadable file was kept, when keeping it worked.
    public let keptAt: URL?

    public var description: String {
        "配置文件读不出来（\(reason)）" + (keptAt.map { "，原文件已另存为 \($0.path)" } ?? "")
    }
}

/// A file whose `schemaVersion` predates every format this build reads.
struct ConfigSchemaTooOld: Error, CustomStringConvertible {
    let found: Int

    var description: String {
        "schemaVersion \(found) 低于最低支持的 \(AppConfig.minimumSupportedSchemaVersion)"
    }
}

/// config.json as one writer last read or wrote it: what that writer's
/// unsaved edits are edits *of*.
///
/// Carries the exact bytes, because "has anyone written since?" is a
/// question about the file, not about what it decodes to.
public struct ConfigBaseline: Sendable, Equatable {
    /// What the bytes decode to — the defaults when there was no file, or
    /// one that could not be read.
    public let config: AppConfig
    /// The file's bytes; nil when there was no file.
    public let data: Data?

    public init(config: AppConfig, data: Data?) {
        self.config = config
        self.data = data
    }
}

// MARK: - Writing

public enum ConfigLockError: Error, Sendable, Equatable, CustomStringConvertible {
    /// Another process held the lock for longer than this one would wait.
    case busy(waited: TimeInterval)
    /// The lock file could not be opened or locked at all.
    case unavailable(String)

    public var description: String {
        switch self {
        case .busy(let waited):
            return "config.json 的锁被另一个进程占着，等了 \(String(format: "%.2f", waited)) 秒仍未释放"
        case .unavailable(let reason):
            return "拿不到 config.json 的锁（\(reason)）"
        }
    }
}

/// This process's standing as a follower of config.json — one that takes in
/// other writers' changes as they land. While it lives, `ConfigIO.isFollowed`
/// answers yes; it ends with the process, however the process ends.
public final class ConfigFollowing: @unchecked Sendable {
    private let descriptor: Int32

    init(descriptor: Int32) {
        self.descriptor = descriptor
    }

    deinit { close(descriptor) }
}

/// What `ConfigIO.update` found, did and left.
public struct ConfigUpdate<Result> {
    public let result: Result
    /// The file as the transform was handed it.
    public let before: ConfigBaseline
    /// The file as it was left — `before` when the transform changed nothing.
    public let after: ConfigBaseline
    /// The copy kept of `before`, when one was asked for and the file changed.
    public let keptCopy: URL?

    public var changed: Bool { after != before }
}

extension ConfigUpdate: Sendable where Result: Sendable {}

/// What `ConfigIO.commit` found and left.
public struct ConfigCommit: Sendable {
    /// The file as the commit left it: the writer's next baseline.
    public let baseline: ConfigBaseline
    /// Set when another writer had changed the file since the writer's
    /// baseline: what was laid over what. `merge.config` is what was written,
    /// and is what the writer now runs on.
    public let merge: ConfigMerge.Outcome?
    /// Set when the file had become unreadable since the baseline: it was
    /// kept beside itself (`ConfigReadIssue.keptAt`) and written over.
    public let replacedUnreadable: ConfigReadIssue?
    /// The file had been removed since the baseline and was written afresh.
    public let recreated: Bool
    /// False when the file already held exactly these bytes.
    public let wrote: Bool
}

/// What `ConfigIO.refresh` found in the file.
public enum ConfigRefresh: Sendable {
    /// The file still holds the bytes the baseline was read from.
    case unchanged
    /// Another writer changed the file. `merge.config` is the caller's copy
    /// with those changes folded in; `baseline` is the file as it is now.
    case changed(ConfigMerge.Outcome, baseline: ConfigBaseline)
    /// The file is gone. The caller's copy stands; nothing to fold in.
    case removed(baseline: ConfigBaseline)
    /// The file now holds something that cannot be read; it was kept beside
    /// itself. The caller's copy stands; nothing to fold in.
    case unreadable(ConfigReadIssue, baseline: ConfigBaseline)
}

// MARK: - The file

/// config.json: reading it, and writing it without undoing anyone.
///
/// The file has more than one writer. The app keeps the config in memory
/// and saves it whenever something changes; `maystock-lab review --apply`
/// halts strategies, cuts budgets and pulls the kill switch in it,
/// unattended, while the app runs; and it gets edited by hand. A writer that
/// saved a copy read earlier put back every value another writer had
/// changed in between — the review's halt undone by the app's next save, an
/// alert firing being reason enough, with nothing logged anywhere.
///
/// So there is one rule, and it is kept here: **every write is computed from
/// the file as it is at the moment of writing.** Each write holds an
/// exclusive lock on `config.json.lock`, reads the file inside it, and
/// derives what it writes from what it read:
///
/// - `update` hands a writer that keeps no copy of its own — the review, a
///   tool — the file as it is now, to change;
/// - `commit` takes a long-lived writer's copy and the baseline it was made
///   from and, when the file has moved since, lays that writer's own edits
///   over the file's new contents (`ConfigMerge`) rather than writing the
///   copy back;
/// - `refresh` folds another writer's change into a long-lived writer's copy
///   as soon as it lands, so that writer runs on what the file says.
///
/// There is no call that writes a config blind.
///
/// Migrates MayStock 1.x configs (a bare `[MonitorItem]` array) by keeping
/// crypto items and dropping the removed CPU/MEM/NET monitors.
public struct ConfigIO: Sendable {
    public let fileURL: URL

    /// How long a writer waits for another to finish. A write holds the
    /// lock only while it reads, merges and writes a few kilobytes.
    public static let lockTimeout: TimeInterval = 5

    public init(directory: URL) {
        self.fileURL = directory.appendingPathComponent("config.json")
    }

    public static func defaultDirectory() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config")
        return base.appendingPathComponent("MayStock")
    }

    /// Held exclusively for the length of every write. A file of its own:
    /// an atomic save replaces config.json, so a lock taken on config.json
    /// itself would be a lock on the copy just replaced.
    public var lockURL: URL { fileURL.appendingPathExtension("lock") }

    /// Held shared, for as long as it runs, by every process that follows the
    /// file (`follow`), so a writer can tell whether its change will be taken
    /// in — and, with a MayStock process running that holds none, that the
    /// process is a build that will save its own copy back over it.
    public var followURL: URL { fileURL.appendingPathExtension("follow") }

    // MARK: Reading

    /// The configuration on disk, or the defaults when there is none.
    public func load() -> AppConfig { read().config }

    /// The configuration on disk, and — when a file exists but cannot be
    /// read — why, and where it was kept.
    ///
    /// An unreadable file used to come back as the defaults in silence, and
    /// the next save wrote the defaults over it: one field a newer build
    /// added, or one hand-edited typo, and the watchlist, alerts and
    /// strategy budgets were gone with nothing in the log. Now the file is
    /// copied beside itself first (`config.json.unreadable-<digest>`, one copy
    /// per distinct content), the reason is logged, and the caller is told —
    /// the app says so on launch, and `review --apply` refuses to write.
    public func read() -> (config: AppConfig, issue: ConfigReadIssue?) {
        let reading = readBaseline()
        return (reading.baseline.config, reading.issue)
    }

    /// `read`, with the bytes the config came from: what a writer needs to
    /// tell, later, whether anyone else has written since.
    public func readBaseline() -> (baseline: ConfigBaseline, issue: ConfigReadIssue?) {
        interpret(readRaw())
    }

    private enum Raw {
        case absent
        case unopenable(String)
        case bytes(Data)

        var data: Data? {
            if case .bytes(let data) = self { return data }
            return nil
        }
    }

    private func readRaw() -> Raw {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return .absent }
        do {
            return .bytes(try Data(contentsOf: fileURL))
        } catch {
            return .unopenable(String(describing: error))
        }
    }

    private func interpret(_ raw: Raw) -> (baseline: ConfigBaseline, issue: ConfigReadIssue?) {
        switch raw {
        case .absent:
            return (ConfigBaseline(config: .default, data: nil), nil)
        case .unopenable(let reason):
            Log.warn("config: config.json 打不开（\(reason)），这次用默认配置")
            return (ConfigBaseline(config: .default, data: nil), ConfigReadIssue(reason: reason, keptAt: nil))
        case .bytes(let data):
            do {
                return (ConfigBaseline(config: try Self.decode(data), data: data), nil)
            } catch {
                let reason = String(describing: error)
                let kept = keepUnreadable(data)
                Log.warn("config: config.json 读不出来（\(reason)），"
                         + (kept.map { "原文件另存为 \($0.lastPathComponent)，" } ?? "另存也失败，")
                         + "这次用默认配置")
                return (ConfigBaseline(config: .default, data: data), ConfigReadIssue(reason: reason, keptAt: kept))
            }
        }
    }

    /// Bytes to config: the one way every reader, every writer and every
    /// merge result goes. Throws the decoder's own error, so a caller can
    /// find where in the document it failed.
    static func decode(_ data: Data) throws -> AppConfig {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let failure: Error
        do {
            var config = try decoder.decode(AppConfig.self, from: data)
            if config.schemaVersion >= AppConfig.minimumSupportedSchemaVersion {
                config.schemaVersion = AppConfig.currentSchemaVersion
                // The menu bar is the app's only way in, so it never starts
                // empty — but an empty watchlist is no reason to drop every
                // other setting, which is what this used to do.
                if config.watchlist.isEmpty {
                    Log.warn("config: 自选为空，恢复默认自选，其余设置照旧")
                    config.watchlist = AppConfig.default.watchlist
                }
                return config
            }
            failure = ConfigSchemaTooOld(found: config.schemaVersion)
        } catch {
            failure = error
        }
        if let migrated = migrateV1(data: data) { return migrated }
        throw failure
    }

    /// Config to bytes: the one way every writer goes.
    static func encode(_ config: AppConfig) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(config)
    }

    /// Copy an unreadable file beside itself, named by its content so the
    /// same file read twice is kept once.
    private func keepUnreadable(_ data: Data) -> URL? {
        let digest = SHA256.hash(data: data).prefix(4).map { String(format: "%02x", $0) }.joined()
        let copy = fileURL.deletingLastPathComponent()
            .appendingPathComponent("\(fileURL.lastPathComponent).unreadable-\(digest)")
        if FileManager.default.fileExists(atPath: copy.path) { return copy }
        return (try? data.write(to: copy, options: .atomic)) != nil ? copy : nil
    }

    // MARK: Writing

    /// Change the file as it is now: `transform` is handed what the file
    /// holds at this moment, under the write lock, and what it leaves is
    /// written back.
    ///
    /// For a writer that keeps no copy of its own — the review, a tool, a
    /// test. Read the file first and hand back a copy edited since, and the
    /// window this closes is open again: work out the change inside
    /// `transform`, from what it is given.
    ///
    /// Refuses a file that cannot be read, throwing its `ConfigReadIssue`: a
    /// change made to the defaults and written over it would replace the
    /// user's config with them. Writes nothing when the transform leaves the
    /// config as it was. `keepingCopyAs` keeps the file being replaced beside
    /// it as `config.json.<tag>-<yyyyMMdd-HHmmss>`, so an unattended change
    /// can be undone by hand.
    @discardableResult
    public func update<Result>(
        keepingCopyAs tag: String? = nil,
        waitingUpTo timeout: TimeInterval = ConfigIO.lockTimeout,
        _ transform: (inout AppConfig) throws -> Result
    ) throws -> ConfigUpdate<Result> {
        try withWriteLock(waitingUpTo: timeout) {
            let (before, issue) = readBaseline()
            if let issue { throw issue }
            var config = before.config
            let result = try transform(&config)
            guard config != before.config else {
                return ConfigUpdate(result: result, before: before, after: before, keptCopy: nil)
            }
            let data = try Self.encode(config)
            let kept = try tag.flatMap { tag in try before.data.map { try keepCopy(of: $0, as: tag) } }
            try data.write(to: fileURL, options: .atomic)
            return ConfigUpdate(
                result: result, before: before,
                after: ConfigBaseline(config: try Self.decode(data), data: data), keptCopy: kept)
        }
    }

    /// Write a long-lived writer's copy without undoing anyone. `mine` is
    /// the config as that writer holds it: `base` — the file as it last read
    /// or wrote it — plus its own edits since.
    ///
    /// Under the write lock the file is read again. When it still holds
    /// `base`'s bytes, `mine` is written as it is. When another writer has
    /// changed it since, `mine`'s own edits are laid over the file's new
    /// contents instead (`ConfigMerge` — where both changed one value, the
    /// file's value stands), the result is written, and the caller is to
    /// adopt it (`ConfigCommit.merge`). A file that has since become
    /// unreadable has been kept beside itself by the read and is written
    /// over: this writer holds a whole config, where any reader of that file
    /// would get the defaults. A file that is gone is written afresh.
    public func commit(
        _ mine: AppConfig, over base: ConfigBaseline,
        waitingUpTo timeout: TimeInterval = ConfigIO.lockTimeout
    ) throws -> ConfigCommit {
        try withWriteLock(waitingUpTo: timeout) {
            let raw = readRaw()
            var result = mine
            var merge: ConfigMerge.Outcome?
            var replacedUnreadable: ConfigReadIssue?
            var recreated = false
            if raw.data != base.data {
                let (current, issue) = interpret(raw)
                if let issue {
                    replacedUnreadable = issue
                } else if current.data == nil {
                    recreated = true
                } else {
                    let outcome = try ConfigMerge.merge(base: base.config, mine: mine, theirs: current.config)
                    merge = outcome
                    result = outcome.config
                }
            }
            let data = try Self.encode(result)
            let wrote = data != raw.data
            if wrote { try data.write(to: fileURL, options: .atomic) }
            return ConfigCommit(
                baseline: ConfigBaseline(config: try Self.decode(data), data: data),
                merge: merge, replacedUnreadable: replacedUnreadable, recreated: recreated, wrote: wrote)
        }
    }

    /// Fold whatever another writer has put in the file since `base` into
    /// `mine` — the caller's copy, `base` plus its own edits — writing
    /// nothing.
    ///
    /// For a long-lived writer to call whenever the file may have changed, so
    /// that it runs on what the file says rather than on what it read at
    /// launch. A file that cannot be read, or is gone, folds nothing in: the
    /// caller's copy stands, and is what its next `commit` restores.
    public func refresh(_ mine: AppConfig, over base: ConfigBaseline) throws -> ConfigRefresh {
        let raw = readRaw()
        guard raw.data != base.data else { return .unchanged }
        let (current, issue) = interpret(raw)
        if let issue {
            return .unreadable(issue, baseline: ConfigBaseline(config: base.config, data: raw.data))
        }
        guard current.data != nil else {
            return .removed(baseline: ConfigBaseline(config: base.config, data: nil))
        }
        return .changed(
            try ConfigMerge.merge(base: base.config, mine: mine, theirs: current.config), baseline: current)
    }

    // MARK: Following

    /// Declare that this process follows the file — takes in other writers'
    /// changes as they land (`refresh`) — for as long as the returned value
    /// lives.
    public func follow(waitingUpTo timeout: TimeInterval = 1) throws -> ConfigFollowing {
        let descriptor = try openLockFile(followURL)
        do {
            // A writer asking `isFollowed` holds it exclusively for an instant.
            try Self.acquire(descriptor, LOCK_SH, waitingUpTo: timeout)
        } catch {
            close(descriptor)
            throw error
        }
        return ConfigFollowing(descriptor: descriptor)
    }

    /// Whether a live process follows the file. Read off the lock itself, so
    /// a follower that has died does not count — the kernel lets go of a
    /// dead process's locks — and nor does one following another directory.
    public func isFollowed() throws -> Bool {
        let descriptor = open(followURL.path, O_RDONLY | O_CLOEXEC)
        if descriptor < 0 {
            let code = errno
            // No process has ever followed this file.
            if code == ENOENT { return false }
            throw ConfigLockError.unavailable(String(cString: strerror(code)))
        }
        defer { close(descriptor) }
        // Taken means nobody holds it; closing the descriptor gives it back.
        if flock(descriptor, LOCK_EX | LOCK_NB) == 0 { return false }
        let code = errno
        guard code == EWOULDBLOCK else { throw ConfigLockError.unavailable(String(cString: strerror(code))) }
        return true
    }

    // MARK: Locks

    /// Run `body` holding the exclusive write lock. Every writer that goes
    /// through `ConfigIO`, in this process or another, waits here for the
    /// one before it, so a writer's read, decision and write are one step.
    private func withWriteLock<T>(waitingUpTo timeout: TimeInterval, _ body: () throws -> T) throws -> T {
        let descriptor = try openLockFile(lockURL)
        // Closing the descriptor releases the lock — on every way out of
        // here, a thrown error and a dying process included.
        defer { close(descriptor) }
        try Self.acquire(descriptor, LOCK_EX, waitingUpTo: timeout)
        return try body()
    }

    private func openLockFile(_ url: URL) throws -> Int32 {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let descriptor = open(url.path, O_RDONLY | O_CREAT | O_CLOEXEC, 0o644)
        guard descriptor >= 0 else { throw ConfigLockError.unavailable(String(cString: strerror(errno))) }
        return descriptor
    }

    /// Take `operation` (`LOCK_EX` or `LOCK_SH`) on an open lock file,
    /// waiting up to `timeout` for whoever holds it. The lock belongs to the
    /// open file, so two opens in one process exclude each other exactly as
    /// two processes do.
    private static func acquire(_ descriptor: Int32, _ operation: Int32, waitingUpTo timeout: TimeInterval) throws {
        let deadline = Date().addingTimeInterval(timeout)
        while flock(descriptor, operation | LOCK_NB) != 0 {
            let code = errno
            guard code == EWOULDBLOCK || code == EINTR else {
                throw ConfigLockError.unavailable(String(cString: strerror(code)))
            }
            guard Date() < deadline else { throw ConfigLockError.busy(waited: timeout) }
            usleep(2_000)
        }
    }

    /// Keep `data` beside the file as `config.json.<tag>-<yyyyMMdd-HHmmss>`,
    /// stamped on the display clock May reads it by.
    private func keepCopy(of data: Data, as tag: String) throws -> URL {
        let copy = fileURL.deletingLastPathComponent()
            .appendingPathComponent("\(fileURL.lastPathComponent).\(tag)-\(DisplayTime.string(Date(), "yyyyMMdd-HHmmss"))")
        try data.write(to: copy, options: .atomic)
        return copy
    }

    /// Best-effort v1 migration via loose JSON inspection (the old schema was
    /// an array of enum-encoded `MonitorItem`s).
    static func migrateV1(data: Data) -> AppConfig? {
        guard let array = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] else {
            return nil
        }
        var items: [WatchItem] = []
        for entry in array where (entry["type"] as? String) == "crypto" {
            var instId = "BTC-USDT"
            if let source = entry["source"] as? [String: Any],
               let okx = source["okx"] as? [String: Any],
               let v = okx["instId"] as? String, !v.isEmpty {
                instId = v
            }
            if !items.contains(where: { $0.instId == instId }) {
                items.append(WatchItem(instId: instId))
            }
        }
        guard !items.isEmpty else { return nil }
        var config = AppConfig.default
        config.watchlist = items
        return config
    }
}
