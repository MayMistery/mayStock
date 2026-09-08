import Foundation

/// A strategy file the library holds but cannot run, and why.
public struct BrokenStrategy: Sendable, Identifiable {
    /// The manifest's id when it decoded, else the file's stem.
    public let id: String
    public let name: String
    public let file: String
    /// Nil when the file did not even decode.
    public let manifest: StrategyManifest?
    public let reason: String

    public init(id: String, name: String, file: String, manifest: StrategyManifest?, reason: String) {
        self.id = id
        self.name = name
        self.file = file
        self.manifest = manifest
        self.reason = reason
    }
}

/// On-disk home for imported strategy manifests.
///
/// One JSON file per strategy under `Application Support/MayStock/Strategies`.
/// Importing copies the file in *after* it compiles, so the folder only ever
/// holds strategies that are known to run.
public struct StrategyStore: Sendable {
    public let directory: URL

    public init(directory: URL) {
        self.directory = directory
    }

    public static func defaultDirectory() -> URL {
        ConfigIO.defaultDirectory().appendingPathComponent("Strategies")
    }

    // MARK: Reading

    public func load() -> [StrategyManifest] {
        loadAll().manifests
    }

    /// Every JSON file in the library: the manifests that decoded, and the
    /// files that did not, each with the reason.
    ///
    /// A file that fails to decode used to be skipped without a word. That is
    /// the wrong silence for a trading app: a manifest written by a newer
    /// build — an engine kind this build has never heard of, say — simply
    /// vanished from the list, and its budget went with it.
    public func loadAll() -> (manifests: [StrategyManifest], undecodable: [BrokenStrategy]) {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil) else { return ([], []) }
        var manifests: [StrategyManifest] = []
        var undecodable: [BrokenStrategy] = []
        for url in entries where url.pathExtension.lowercased() == "json" {
            do {
                manifests.append(try StrategyManifest.load(from: url))
            } catch {
                let id = url.deletingPathExtension().lastPathComponent
                undecodable.append(BrokenStrategy(
                    id: id, name: id, file: url.lastPathComponent, manifest: nil,
                    reason: "清单无法解析：\(error)"))
            }
        }
        manifests.sort { $0.name.localizedCompare($1.name) == .orderedAscending }
        return (manifests, undecodable)
    }

    /// Compiled strategies plus the ones that failed, so the UI can show *why*
    /// a file the user imported earlier no longer runs.
    public func loadCompiled() -> (ready: [CompiledStrategy], broken: [BrokenStrategy]) {
        let loaded = loadAll()
        var ready: [CompiledStrategy] = []
        var broken = loaded.undecodable
        for manifest in loaded.manifests {
            do {
                ready.append(try manifest.compile())
            } catch {
                broken.append(BrokenStrategy(
                    id: manifest.id, name: manifest.name, file: fileURL(for: manifest.id).lastPathComponent,
                    manifest: manifest, reason: String(describing: error)))
            }
        }
        return (ready, broken.sorted { $0.name.localizedCompare($1.name) == .orderedAscending })
    }

    // MARK: Writing

    @discardableResult
    public func save(_ manifest: StrategyManifest) throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = fileURL(for: manifest.id)
        try manifest.encoded().write(to: url, options: .atomic)
        return url
    }

    /// Validate an external file and adopt it. Rejects anything that does not
    /// compile, so a broken manifest never lands in the library.
    @discardableResult
    public func importManifest(from url: URL, existing: [StrategyManifest] = []) throws -> StrategyManifest {
        var manifest = try StrategyManifest.load(from: url)
        _ = try manifest.compile()

        // Keep ids unique: a second import of the same name becomes "-2".
        let taken = Set(existing.map(\.id))
        if taken.contains(manifest.id) {
            var suffix = 2
            while taken.contains("\(manifest.id)-\(suffix)") { suffix += 1 }
            manifest.id = "\(manifest.id)-\(suffix)"
        }
        try save(manifest)
        return manifest
    }

    public func delete(id: String) throws {
        let url = fileURL(for: id)
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
    }

    /// Fill an empty library with the built-in presets — the deliberate way
    /// *back* to the examples, offered as a button on the strategies page.
    @discardableResult
    public func installPresetsIfEmpty() -> [StrategyManifest] {
        guard load().isEmpty else { return [] }
        var installed: [StrategyManifest] = []
        for preset in StrategyLibrary.presets where (try? save(preset)) != nil {
            installed.append(preset)
        }
        return installed
    }

    /// Seed the library the first time this install opens it.
    ///
    /// Seeding on every reload — which is what calling `installPresetsIfEmpty`
    /// from the reload path did — meant an emptied library refilled itself at
    /// the next launch: "remove every strategy" was a state the app would not
    /// hold, and the empty state that offers the restore button could never be
    /// reached. So seeding hangs on the library folder not existing yet, which
    /// is true exactly once per install. Emptying the folder keeps it empty;
    /// deleting the folder is how you ask for the examples back without the
    /// button.
    @discardableResult
    public func seedPresetsOnFirstRun() -> [StrategyManifest] {
        guard !FileManager.default.fileExists(atPath: directory.path) else { return [] }
        return installPresetsIfEmpty()
    }

    func fileURL(for id: String) -> URL {
        let safe = id.map { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" ? $0 : "_" }
        return directory.appendingPathComponent(String(safe) + ".json")
    }
}
