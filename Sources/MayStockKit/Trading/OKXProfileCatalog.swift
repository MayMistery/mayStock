import Foundation

/// One named credential set in the official CLI's `~/.okx/config.toml`.
///
/// Only the *shape* of the profile is read — its name and whether the CLI has
/// it marked as a demo-environment key. The key material itself is never
/// parsed, held or shown: MayStock's whole credential model is that the CLI
/// owns the secrets and this app only ever asks the CLI to act.
public struct OKXProfile: Sendable, Equatable, Identifiable, Hashable {
    public let name: String
    /// `demo = true` in the profile. Nil when the profile does not say.
    ///
    /// Worth surfacing because OKX issues *separate* API keys for the demo
    /// environment and the live one, and a key from either is rejected by
    /// the other with "APIKey does not match current environment". A profile
    /// flagged demo assigned to the live account is a mistake the UI can catch
    /// before the exchange does.
    public let isDemo: Bool?

    public var id: String { name }

    public init(name: String, isDemo: Bool?) {
        self.name = name
        self.isDemo = isDemo
    }
}

/// The profiles the CLI knows about, read from its own config file.
public struct OKXProfileCatalog: Sendable, Equatable {
    public var profiles: [OKXProfile]
    /// `default_profile` at the top of the file — what the CLI uses when no
    /// `--profile` is passed.
    public var defaultProfile: String?
    /// False when the config file does not exist at all: the CLI has never
    /// been configured, which is a different message from "no profiles".
    public var fileExists: Bool
    /// When the file this catalogue was read from was last written; nil when
    /// it did not exist. The catalogue is a snapshot of the file, and this is
    /// what says whether the snapshot is still the file.
    public var fileModifiedAt: Date?

    public init(
        profiles: [OKXProfile] = [], defaultProfile: String? = nil, fileExists: Bool = false,
        fileModifiedAt: Date? = nil
    ) {
        self.profiles = profiles
        self.defaultProfile = defaultProfile
        self.fileExists = fileExists
        self.fileModifiedAt = fileModifiedAt
    }

    public static let empty = OKXProfileCatalog()

    public static func defaultFileURL() -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".okx/config.toml")
    }

    public func profile(named name: String) -> OKXProfile? {
        profiles.first { $0.name == name }
    }

    /// The profile a mode resolves to: the named one, else the CLI default.
    public func resolved(_ name: String?) -> OKXProfile? {
        if let name, !name.isEmpty { return profile(named: name) }
        return defaultProfile.flatMap(profile(named:))
    }

    // MARK: Loading

    public static func load(from url: URL = defaultFileURL()) -> OKXProfileCatalog {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else {
            return OKXProfileCatalog(fileExists: false)
        }
        var catalog = parse(text)
        catalog.fileExists = true
        catalog.fileModifiedAt = modificationDate(of: url)
        return catalog
    }

    /// The file's last-write time, nil when it is not there.
    public static func modificationDate(of url: URL) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
    }

    /// True when the file has been created, removed or rewritten since this
    /// catalogue was read from it.
    ///
    /// The app used to read the file once at launch and then only again when
    /// the read had found no file at all. A profile added with `okx config
    /// init` while the app was open therefore never appeared — the account
    /// page kept offering the launch-time snapshot as if it were the file —
    /// until a restart. Whether the snapshot is current is a question about
    /// the file, so it is answered from the file.
    public func isStale(against url: URL = defaultFileURL()) -> Bool {
        switch (Self.modificationDate(of: url), fileExists) {
        case (nil, false): return false
        case (nil, true), (.some, false): return true
        case (let onDisk?, true): return onDisk != fileModifiedAt
        }
    }

    /// A deliberately narrow TOML reader.
    ///
    /// The file has one flat table per profile and a handful of scalar keys;
    /// a full TOML parser would be more code than the rest of this type and
    /// would still have to be told to ignore `api_key`, `secret_key` and
    /// `passphrase`. This reads section headers and the two keys it needs,
    /// and skips every other line unread.
    public static func parse(_ toml: String) -> OKXProfileCatalog {
        var profiles: [OKXProfile] = []
        var defaultProfile: String?
        var currentName: String?
        var currentDemo: Bool?

        func flush() {
            if let currentName {
                profiles.append(OKXProfile(name: currentName, isDemo: currentDemo))
            }
            currentName = nil
            currentDemo = nil
        }

        for rawLine in toml.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = stripComment(String(rawLine)).trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }

            if line.hasPrefix("[") {
                flush()
                if let name = profileName(fromHeader: line) { currentName = name }
                continue
            }
            guard let (key, value) = keyValue(line) else { continue }
            if currentName != nil {
                if key == "demo" { currentDemo = bool(value) }
            } else if key == "default_profile" {
                defaultProfile = unquote(value)
            }
        }
        flush()
        return OKXProfileCatalog(profiles: profiles, defaultProfile: defaultProfile, fileExists: true)
    }

    // MARK: Line helpers

    /// `[profiles.name]`, `[profiles."name"]` and `[profiles.'name']`.
    static func profileName(fromHeader header: String) -> String? {
        guard header.hasPrefix("["), header.hasSuffix("]") else { return nil }
        let inner = header.dropFirst().dropLast().trimmingCharacters(in: .whitespaces)
        guard inner.hasPrefix("profiles.") else { return nil }
        let name = unquote(String(inner.dropFirst("profiles.".count)))
        return name.isEmpty ? nil : name
    }

    static func keyValue(_ line: String) -> (String, String)? {
        guard let equals = line.firstIndex(of: "=") else { return nil }
        let key = line[..<equals].trimmingCharacters(in: .whitespaces)
        let value = line[line.index(after: equals)...].trimmingCharacters(in: .whitespaces)
        guard !key.isEmpty else { return nil }
        return (key, value)
    }

    static func bool(_ value: String) -> Bool? {
        switch unquote(value).lowercased() {
        case "true": return true
        case "false": return false
        default: return nil
        }
    }

    static func unquote(_ value: String) -> String {
        var text = value.trimmingCharacters(in: .whitespaces)
        for quote in ["'''", "\"\"\"", "\"", "'"] {
            if text.hasPrefix(quote), text.hasSuffix(quote), text.count >= quote.count * 2 {
                text = String(text.dropFirst(quote.count).dropLast(quote.count))
                break
            }
        }
        return text
    }

    /// Drop a trailing `# comment`, but not a `#` inside a quoted value.
    static func stripComment(_ line: String) -> String {
        var inSingle = false
        var inDouble = false
        var result = ""
        for character in line {
            switch character {
            case "'" where !inDouble: inSingle.toggle()
            case "\"" where !inSingle: inDouble.toggle()
            case "#" where !inSingle && !inDouble: return result
            default: break
            }
            result.append(character)
        }
        return result
    }
}
