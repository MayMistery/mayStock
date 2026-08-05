import Foundation

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
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil) else { return [] }
        return entries
            .filter { $0.pathExtension.lowercased() == "json" }
            .compactMap { try? StrategyManifest.load(from: $0) }
            .sorted { $0.name.localizedCompare($1.name) == .orderedAscending }
    }

    /// Compiled strategies plus the ones that failed, so the UI can show *why*
    /// a file the user imported earlier no longer runs.
    public func loadCompiled() -> (ready: [CompiledStrategy], broken: [(StrategyManifest, String)]) {
        var ready: [CompiledStrategy] = []
        var broken: [(StrategyManifest, String)] = []
        for manifest in load() {
            do {
                ready.append(try manifest.compile())
            } catch {
                broken.append((manifest, String(describing: error)))
            }
        }
        return (ready, broken)
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

    /// Seed the library with the built-in presets the first time it is opened.
    @discardableResult
    public func installPresetsIfEmpty() -> [StrategyManifest] {
        guard load().isEmpty else { return [] }
        var installed: [StrategyManifest] = []
        for preset in StrategyLibrary.presets where (try? save(preset)) != nil {
            installed.append(preset)
        }
        return installed
    }

    func fileURL(for id: String) -> URL {
        let safe = id.map { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" ? $0 : "_" }
        return directory.appendingPathComponent(String(safe) + ".json")
    }
}
