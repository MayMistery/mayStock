import Foundation

/// Three-way merge of two writers' edits to the same config.
///
/// `ConfigIO` uses it when the file has moved since a writer read it:
/// `base` is what the writer read, `mine` the writer's copy since, `theirs`
/// the file now. The result keeps both sides' edits, value by value — a halt
/// the review wrote and an alert's state the app recorded sit in different
/// leaves, and both survive.
///
/// Lists of `Identifiable` elements — the watchlist, the alerts, the
/// strategy budgets — merge element by element, matched by `id` and never by
/// position, so one writer removing an entry cannot slide the other's edit
/// onto its neighbour. A list keeps the file's order unless only this writer
/// reordered it. Nothing here names a field: what is a list of what, and
/// what identifies its elements, is read off the config's own `Codable`
/// conformance and the elements' `Identifiable` one, so a field added later
/// merges the same way the day it is added.
///
/// Where both changed the same value differently, the file's value stands:
/// it is the one already written, which another process has acted on and
/// reported — the review's halts arrive this way. Every such conflict is
/// reported with both values; none is resolved in silence.
public enum ConfigMerge {
    /// One value that differs between two versions, for the log.
    public struct Change: Sendable, Equatable, CustomStringConvertible {
        /// Where, as `strategy.allocations[a].running`; list elements by id.
        public let path: String
        public let before: String
        public let after: String

        public var description: String { "\(path): \(before) → \(after)" }
    }

    /// One value both writers changed, differently.
    public struct Conflict: Sendable, Equatable, CustomStringConvertible {
        public let path: String
        /// What the writer doing the merge had.
        public let mine: String
        /// What the file had — and what the result has.
        public let theirs: String

        public var description: String { "\(path): 本进程 \(mine)，文件 \(theirs)，取文件" }
    }

    public struct Outcome: Sendable, Equatable {
        /// `theirs` with `mine`'s own edits laid over it.
        public let config: AppConfig
        /// How the writer's copy changes on taking `config`: the other
        /// writer's edits, and the conflicts settled their way.
        public let adopted: [Change]
        /// How the file changes on taking `config`: this writer's own edits
        /// that survived.
        public let kept: [Change]
        /// Values both writers changed differently; `config` has the file's.
        public let conflicts: [Conflict]
    }

    /// Lay `mine`'s edits since `base` over `theirs`.
    public static func merge(base: AppConfig, mine: AppConfig, theirs: AppConfig) throws -> Outcome {
        let baseTree = try tree(of: base)
        let mineTree = try tree(of: mine)
        let theirsTree = try tree(of: theirs)
        var merger = Merger()
        let merged = merger.merge(baseTree, mineTree, theirsTree, at: ConfigPath()) ?? theirsTree
        let config = try decode(merged, fallingBackTo: theirsTree, recording: &merger)
        let result = try tree(of: config)
        return Outcome(
            config: config,
            adopted: differences(mineTree, result),
            kept: differences(theirsTree, result),
            conflicts: merger.conflicts)
    }

    /// Every value that differs between two configs, as the merge reports
    /// them — for a writer that changes the file without merging, to say
    /// what it changed.
    public static func differences(from before: AppConfig, to after: AppConfig) throws -> [Change] {
        differences(try tree(of: before), try tree(of: after))
    }

    /// The merge of three trees, before the result is read back as a config —
    /// for the test that walks every leaf of the schema, where an edit need
    /// not be a value the config could hold.
    static func merge(
        base: ConfigNode, mine: ConfigNode, theirs: ConfigNode
    ) -> (merged: ConfigNode?, conflicts: [Conflict]) {
        var merger = Merger()
        let merged = merger.merge(base, mine, theirs, at: ConfigPath())
        return (merged, merger.conflicts)
    }

    /// Every list the config encodes, by where it sits, and whether it merges
    /// element by element. A list that does not merges as one value: both
    /// writers editing it is a conflict, and one side's edit is dropped.
    static func lists(in config: AppConfig) throws -> [String: Bool] {
        let probe = ListProbe()
        try ProbeEncoder.walk(config, probe: probe, path: [], codingPath: [])
        return Dictionary(uniqueKeysWithValues: probe.lists.map { (ProbeStep.render($0.key), $0.value != nil) })
    }
}

// MARK: - The document as a tree

/// A JSON value, as the file holds it.
enum JSONValue: Codable, Equatable {
    case null
    case bool(Bool)
    case int(Int64)
    case unsigned(UInt64)
    case double(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Int64.self) {
            self = .int(value)
        } else if let value = try? container.decode(UInt64.self) {
            self = .unsigned(value)
        } else if let value = try? container.decode(Double.self) {
            self = .double(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([JSONValue].self) {
            self = .array(value)
        } else {
            self = .object(try container.decode([String: JSONValue].self))
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case .bool(let value): try container.encode(value)
        case .int(let value): try container.encode(value)
        case .unsigned(let value): try container.encode(value)
        case .double(let value): try container.encode(value)
        case .string(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        }
    }
}

/// The config as the merge sees it: objects by key, lists of identifiable
/// elements by id, everything else one value.
indirect enum ConfigNode: Equatable {
    case value(JSONValue)
    case object([String: ConfigNode])
    /// A list whose elements have no identity: merged as one value.
    case list([ConfigNode])
    /// A list of `Identifiable` elements, in order: merged element by element.
    case identified([Element])

    struct Element: Equatable {
        let id: AnyHashable
        let node: ConfigNode
    }

    var json: JSONValue {
        switch self {
        case .value(let value): return value
        case .object(let members): return .object(members.mapValues(\.json))
        case .list(let items): return .array(items.map(\.json))
        case .identified(let elements): return .array(elements.map(\.node.json))
        }
    }
}

extension ConfigMerge {
    /// The config's tree. The JSON is what the file would hold; which of its
    /// arrays are lists of identifiable elements, and their ids, come from
    /// walking the same `encode(to:)` calls that produced it — so they line
    /// up with the JSON's arrays by position, with nothing named.
    static func tree(of config: AppConfig) throws -> ConfigNode {
        let json = try JSONDecoder().decode(JSONValue.self, from: ConfigIO.encode(config))
        let probe = ListProbe()
        try ProbeEncoder.walk(config, probe: probe, path: [], codingPath: [])
        return node(json, at: [], lists: probe.lists)
    }

    private static func node(
        _ json: JSONValue, at path: [ProbeStep], lists: [[ProbeStep]: [AnyHashable]?]
    ) -> ConfigNode {
        switch json {
        case .object(let members):
            return .object(Dictionary(uniqueKeysWithValues: members.map { key, value in
                (key, node(value, at: path + [.key(key)], lists: lists))
            }))
        case .array(let items):
            let children = items.indices.map { node(items[$0], at: path + [.index($0)], lists: lists) }
            // Ids that do not tell every element apart cannot match them up:
            // such a list merges as one value.
            if let ids = lists[path] ?? nil, ids.count == children.count, Set(ids).count == ids.count {
                return .identified(zip(ids, children).map { ConfigNode.Element(id: $0, node: $1) })
            }
            return .list(children)
        default:
            return .value(json)
        }
    }

    /// The merged tree as a config. A merge of two documents that each
    /// decode can still produce one that does not — both writers turning the
    /// same enum to different cases leaves an object holding two. The part
    /// the decoder names is then taken from the file, reported as a conflict,
    /// and the decode tried again; if that never converges, the file's
    /// version is the result, whole, and that is reported too.
    private static func decode(
        _ merged: ConfigNode, fallingBackTo theirs: ConfigNode, recording merger: inout Merger
    ) throws -> AppConfig {
        var current = merged
        for _ in 0..<32 {
            let data = try JSONEncoder().encode(current.json)
            let failure: DecodingError
            do {
                return try ConfigIO.decode(data)
            } catch let error as DecodingError {
                failure = error
            } catch {
                break
            }
            var settled: (path: ConfigPath, mine: ConfigNode?, theirs: ConfigNode?)?
            let replaced = replacing(
                current, with: theirs, along: failure.codingPath[...], at: ConfigPath(), settled: &settled)
            guard let settled, let replaced, replaced != current else { break }
            merger.conflicts.append(Conflict(
                path: settled.path.description, mine: render(settled.mine) + "（合并后读不回来）",
                theirs: render(settled.theirs)))
            current = replaced
        }
        merger.conflicts.append(Conflict(path: ConfigPath().description, mine: "合并结果读不回来", theirs: "整份取文件"))
        return try ConfigIO.decode(JSONEncoder().encode(theirs.json))
    }

    /// `node` with the part at `codingPath` replaced by the file's — the same
    /// key, the same element by id — or removed where the file has none.
    private static func replacing(
        _ node: ConfigNode, with theirs: ConfigNode?, along codingPath: ArraySlice<CodingKey>,
        at path: ConfigPath, settled: inout (path: ConfigPath, mine: ConfigNode?, theirs: ConfigNode?)?
    ) -> ConfigNode? {
        guard let step = codingPath.first else {
            settled = (path, node, theirs)
            return theirs
        }
        switch node {
        case .object(var members):
            let key = step.stringValue
            guard let child = members[key] else {
                settled = (path, node, theirs)
                return theirs
            }
            var theirsChild: ConfigNode?
            if case .object(let theirsMembers)? = theirs { theirsChild = theirsMembers[key] }
            members[key] = replacing(
                child, with: theirsChild, along: codingPath.dropFirst(), at: path.key(key), settled: &settled)
            return .object(members)
        case .identified(var elements):
            guard let index = step.intValue, elements.indices.contains(index) else {
                settled = (path, node, theirs)
                return theirs
            }
            let id = elements[index].id
            var theirsChild: ConfigNode?
            if case .identified(let theirsElements)? = theirs {
                theirsChild = theirsElements.first { $0.id == id }?.node
            }
            if let child = replacing(
                elements[index].node, with: theirsChild, along: codingPath.dropFirst(),
                at: path.element(id), settled: &settled) {
                elements[index] = ConfigNode.Element(id: id, node: child)
            } else {
                elements.remove(at: index)
            }
            return .identified(elements)
        case .list, .value:
            settled = (path, node, theirs)
            return theirs
        }
    }
}

// MARK: - Merging

/// Where a value sits, for the reports: keys joined by dots, list elements
/// by id in brackets — `strategy.allocations[a].running`.
struct ConfigPath: CustomStringConvertible {
    private var text = ""

    func key(_ key: String) -> ConfigPath {
        var path = self
        path.text = text.isEmpty ? key : text + "." + key
        return path
    }

    func element(_ id: AnyHashable) -> ConfigPath {
        var path = self
        path.text = text + "[\(id.base)]"
        return path
    }

    func suffixed(_ suffix: String) -> ConfigPath {
        var path = self
        path.text = description + suffix
        return path
    }

    var description: String { text.isEmpty ? "（整份）" : text }
}

private struct Merger {
    var conflicts: [ConfigMerge.Conflict] = []

    /// One node of the three. Nil is absent: a key or element that one side
    /// never had, or removed.
    mutating func merge(_ base: ConfigNode?, _ mine: ConfigNode?, _ theirs: ConfigNode?, at path: ConfigPath) -> ConfigNode? {
        if mine == base { return theirs }
        if theirs == base || mine == theirs { return mine }
        switch (mine, theirs) {
        case (.object(let mineMembers)?, .object(let theirsMembers)?):
            var baseMembers: [String: ConfigNode] = [:]
            if case .object(let members)? = base { baseMembers = members }
            var result: [String: ConfigNode] = [:]
            for key in Set(mineMembers.keys).union(theirsMembers.keys).union(baseMembers.keys) {
                result[key] = merge(baseMembers[key], mineMembers[key], theirsMembers[key], at: path.key(key))
            }
            return .object(result)
        case (.identified(let mineElements)?, .identified(let theirsElements)?):
            var baseElements: [ConfigNode.Element] = []
            if case .identified(let elements)? = base { baseElements = elements }
            return .identified(merge(baseElements, mineElements, theirsElements, at: path))
        default:
            conflicts.append(ConfigMerge.Conflict(
                path: path.description, mine: ConfigMerge.render(mine), theirs: ConfigMerge.render(theirs)))
            return theirs
        }
    }

    private mutating func merge(
        _ base: [ConfigNode.Element], _ mine: [ConfigNode.Element], _ theirs: [ConfigNode.Element], at path: ConfigPath
    ) -> [ConfigNode.Element] {
        let baseNodes = ConfigMerge.byId(base), mineNodes = ConfigMerge.byId(mine), theirsNodes = ConfigMerge.byId(theirs)
        // The file's elements first, then this writer's additions, then any
        // both removed: the order an element is placed in when no side's
        // order says otherwise.
        let every = ConfigMerge.unique(theirs.map(\.id) + mine.map(\.id) + base.map(\.id))
        var merged: [AnyHashable: ConfigNode] = [:]
        for id in every {
            merged[id] = merge(baseNodes[id], mineNodes[id], theirsNodes[id], at: path.element(id))
        }
        let order = ConfigMerge.unique(
            self.order(base: base.map(\.id), mine: mine.map(\.id), theirs: theirs.map(\.id), at: path) + every)
        return order.compactMap { id in merged[id].map { ConfigNode.Element(id: id, node: $0) } }
    }

    /// The file's order, unless only this writer reordered the list.
    private mutating func order(
        base: [AnyHashable], mine: [AnyHashable], theirs: [AnyHashable], at path: ConfigPath
    ) -> [AnyHashable] {
        let mineMoved = ConfigMerge.reordered(base, mine)
        let theirsMoved = ConfigMerge.reordered(base, theirs)
        if !mineMoved || !ConfigMerge.reordered(mine, theirs) { return theirs }
        if !theirsMoved { return mine }
        conflicts.append(ConfigMerge.Conflict(
            path: path.suffixed("（顺序）").description,
            mine: ConfigMerge.render(ids: mine), theirs: ConfigMerge.render(ids: theirs)))
        return theirs
    }
}

extension ConfigMerge {
    static func byId(_ elements: [ConfigNode.Element]) -> [AnyHashable: ConfigNode] {
        Dictionary(elements.map { ($0.id, $0.node) }, uniquingKeysWith: { first, _ in first })
    }

    static func unique(_ ids: [AnyHashable]) -> [AnyHashable] {
        var seen = Set<AnyHashable>()
        return ids.filter { seen.insert($0).inserted }
    }

    /// Whether `b` puts the elements it shares with `a` in another order.
    static func reordered(_ a: [AnyHashable], _ b: [AnyHashable]) -> Bool {
        let shared = Set(a).intersection(b)
        return a.filter(shared.contains) != b.filter(shared.contains)
    }

    // MARK: Reporting

    static func differences(_ before: ConfigNode, _ after: ConfigNode) -> [Change] {
        var changes: [Change] = []
        differences(before, after, at: ConfigPath(), into: &changes)
        return changes
    }

    private static func differences(
        _ before: ConfigNode?, _ after: ConfigNode?, at path: ConfigPath, into changes: inout [Change]
    ) {
        guard before != after else { return }
        switch (before, after) {
        case (.object(let beforeMembers)?, .object(let afterMembers)?):
            for key in Set(beforeMembers.keys).union(afterMembers.keys).sorted() {
                differences(beforeMembers[key], afterMembers[key], at: path.key(key), into: &changes)
            }
        case (.identified(let beforeElements)?, .identified(let afterElements)?):
            let beforeNodes = byId(beforeElements), afterNodes = byId(afterElements)
            for id in unique(afterElements.map(\.id) + beforeElements.map(\.id)) {
                differences(beforeNodes[id], afterNodes[id], at: path.element(id), into: &changes)
            }
            if reordered(beforeElements.map(\.id), afterElements.map(\.id)) {
                changes.append(Change(
                    path: path.suffixed("（顺序）").description,
                    before: render(ids: beforeElements.map(\.id)), after: render(ids: afterElements.map(\.id))))
            }
        default:
            changes.append(Change(path: path.description, before: render(before), after: render(after)))
        }
    }

    /// A value as compact JSON, cut short past a line's worth.
    static func render(_ node: ConfigNode?) -> String {
        guard let node else { return "（无）" }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(node.json), let text = String(data: data, encoding: .utf8) else {
            return "（无法显示）"
        }
        return text.count > 160 ? String(text.prefix(159)) + "…" : text
    }

    static func render(ids: [AnyHashable]) -> String {
        "[" + ids.map { "\($0.base)" }.joined(separator: ", ") + "]"
    }
}

private extension DecodingError {
    var codingPath: [CodingKey] {
        switch self {
        case .typeMismatch(_, let context), .valueNotFound(_, let context),
             .keyNotFound(_, let context), .dataCorrupted(let context):
            return context.codingPath
        @unknown default:
            return []
        }
    }
}

// MARK: - Finding the lists

/// A list of `Identifiable` elements, seen through `Any`.
private protocol IdentifiedList {
    var identities: [AnyHashable] { get }
}

extension Array: IdentifiedList where Element: Identifiable {
    fileprivate var identities: [AnyHashable] { map { AnyHashable($0.id) } }
}

enum ProbeStep: Hashable {
    case key(String)
    case index(Int)

    static func render(_ path: [ProbeStep]) -> String {
        path.reduce(into: "") { text, step in
            switch step {
            case .key(let key): text += text.isEmpty ? key : "." + key
            case .index(let index): text += "[\(index)]"
            }
        }
    }
}

/// Every list a walk met, by where it sits: the ids of its elements when
/// they are `Identifiable`, nil when they are not.
final class ListProbe {
    var lists: [[ProbeStep]: [AnyHashable]?] = [:]
}

private struct ProbeKey: CodingKey {
    let stringValue: String
    let intValue: Int?

    init(stringValue: String) {
        self.stringValue = stringValue
        self.intValue = nil
    }

    init(intValue: Int) {
        self.stringValue = "Index \(intValue)"
        self.intValue = intValue
    }
}

/// An `Encoder` that writes nothing: it runs a value's `encode(to:)` to find
/// the lists in it. `JSONEncoder` is driven by the same calls, so the lists
/// found here sit exactly where the JSON's arrays do.
struct ProbeEncoder: Encoder {
    let probe: ListProbe
    let path: [ProbeStep]
    let codingPath: [CodingKey]
    /// The ids of the list this encoder is handed, when its elements are
    /// `Identifiable` — known to whoever handed it over, before the list
    /// opens its container.
    let identities: [AnyHashable]?

    var userInfo: [CodingUserInfoKey: Any] { [:] }

    static func walk<T: Encodable>(
        _ value: T, probe: ListProbe, path: [ProbeStep], codingPath: [CodingKey]
    ) throws {
        // `JSONEncoder` writes these as single values; their own
        // `encode(to:)` would show lists the JSON does not have — `Data` is a
        // list of bytes to any other encoder.
        if value is Date || value is Data || value is URL || value is Decimal { return }
        try value.encode(to: ProbeEncoder(
            probe: probe, path: path, codingPath: codingPath,
            identities: (value as? any IdentifiedList)?.identities))
    }

    func container<Key: CodingKey>(keyedBy type: Key.Type) -> KeyedEncodingContainer<Key> {
        KeyedEncodingContainer(ProbeKeyedContainer<Key>(probe: probe, path: path, codingPath: codingPath))
    }

    func unkeyedContainer() -> UnkeyedEncodingContainer {
        probe.lists[path] = .some(identities)
        return ProbeUnkeyedContainer(probe: probe, path: path, codingPath: codingPath)
    }

    func singleValueContainer() -> SingleValueEncodingContainer {
        ProbeSingleValueContainer(probe: probe, path: path, codingPath: codingPath)
    }
}

private struct ProbeKeyedContainer<Key: CodingKey>: KeyedEncodingContainerProtocol {
    let probe: ListProbe
    let path: [ProbeStep]
    let codingPath: [CodingKey]

    private func child(_ key: Key) -> (path: [ProbeStep], codingPath: [CodingKey]) {
        (path + [.key(key.stringValue)], codingPath + [key])
    }

    mutating func encodeNil(forKey key: Key) throws {}
    mutating func encode(_ value: Bool, forKey key: Key) throws {}
    mutating func encode(_ value: String, forKey key: Key) throws {}
    mutating func encode(_ value: Double, forKey key: Key) throws {}
    mutating func encode(_ value: Float, forKey key: Key) throws {}
    mutating func encode(_ value: Int, forKey key: Key) throws {}
    mutating func encode(_ value: Int8, forKey key: Key) throws {}
    mutating func encode(_ value: Int16, forKey key: Key) throws {}
    mutating func encode(_ value: Int32, forKey key: Key) throws {}
    mutating func encode(_ value: Int64, forKey key: Key) throws {}
    mutating func encode(_ value: UInt, forKey key: Key) throws {}
    mutating func encode(_ value: UInt8, forKey key: Key) throws {}
    mutating func encode(_ value: UInt16, forKey key: Key) throws {}
    mutating func encode(_ value: UInt32, forKey key: Key) throws {}
    mutating func encode(_ value: UInt64, forKey key: Key) throws {}

    mutating func encode<T: Encodable>(_ value: T, forKey key: Key) throws {
        let child = child(key)
        try ProbeEncoder.walk(value, probe: probe, path: child.path, codingPath: child.codingPath)
    }

    mutating func nestedContainer<NestedKey: CodingKey>(
        keyedBy keyType: NestedKey.Type, forKey key: Key
    ) -> KeyedEncodingContainer<NestedKey> {
        let child = child(key)
        return KeyedEncodingContainer(ProbeKeyedContainer<NestedKey>(
            probe: probe, path: child.path, codingPath: child.codingPath))
    }

    mutating func nestedUnkeyedContainer(forKey key: Key) -> UnkeyedEncodingContainer {
        let child = child(key)
        probe.lists[child.path] = .some(nil)
        return ProbeUnkeyedContainer(probe: probe, path: child.path, codingPath: child.codingPath)
    }

    mutating func superEncoder() -> Encoder {
        ProbeEncoder(
            probe: probe, path: path + [.key("super")],
            codingPath: codingPath + [ProbeKey(stringValue: "super")], identities: nil)
    }

    mutating func superEncoder(forKey key: Key) -> Encoder {
        let child = child(key)
        return ProbeEncoder(probe: probe, path: child.path, codingPath: child.codingPath, identities: nil)
    }
}

private struct ProbeUnkeyedContainer: UnkeyedEncodingContainer {
    let probe: ListProbe
    let path: [ProbeStep]
    let codingPath: [CodingKey]
    private(set) var count = 0

    init(probe: ListProbe, path: [ProbeStep], codingPath: [CodingKey]) {
        self.probe = probe
        self.path = path
        self.codingPath = codingPath
    }

    private mutating func next() -> (path: [ProbeStep], codingPath: [CodingKey]) {
        defer { count += 1 }
        return (path + [.index(count)], codingPath + [ProbeKey(intValue: count)])
    }

    mutating func encodeNil() throws { count += 1 }
    mutating func encode(_ value: Bool) throws { count += 1 }
    mutating func encode(_ value: String) throws { count += 1 }
    mutating func encode(_ value: Double) throws { count += 1 }
    mutating func encode(_ value: Float) throws { count += 1 }
    mutating func encode(_ value: Int) throws { count += 1 }
    mutating func encode(_ value: Int8) throws { count += 1 }
    mutating func encode(_ value: Int16) throws { count += 1 }
    mutating func encode(_ value: Int32) throws { count += 1 }
    mutating func encode(_ value: Int64) throws { count += 1 }
    mutating func encode(_ value: UInt) throws { count += 1 }
    mutating func encode(_ value: UInt8) throws { count += 1 }
    mutating func encode(_ value: UInt16) throws { count += 1 }
    mutating func encode(_ value: UInt32) throws { count += 1 }
    mutating func encode(_ value: UInt64) throws { count += 1 }

    mutating func encode<T: Encodable>(_ value: T) throws {
        let child = next()
        try ProbeEncoder.walk(value, probe: probe, path: child.path, codingPath: child.codingPath)
    }

    mutating func nestedContainer<NestedKey: CodingKey>(keyedBy keyType: NestedKey.Type) -> KeyedEncodingContainer<NestedKey> {
        let child = next()
        return KeyedEncodingContainer(ProbeKeyedContainer<NestedKey>(
            probe: probe, path: child.path, codingPath: child.codingPath))
    }

    mutating func nestedUnkeyedContainer() -> UnkeyedEncodingContainer {
        let child = next()
        probe.lists[child.path] = .some(nil)
        return ProbeUnkeyedContainer(probe: probe, path: child.path, codingPath: child.codingPath)
    }

    mutating func superEncoder() -> Encoder {
        let child = next()
        return ProbeEncoder(probe: probe, path: child.path, codingPath: child.codingPath, identities: nil)
    }
}

private struct ProbeSingleValueContainer: SingleValueEncodingContainer {
    let probe: ListProbe
    let path: [ProbeStep]
    let codingPath: [CodingKey]

    mutating func encodeNil() throws {}
    mutating func encode(_ value: Bool) throws {}
    mutating func encode(_ value: String) throws {}
    mutating func encode(_ value: Double) throws {}
    mutating func encode(_ value: Float) throws {}
    mutating func encode(_ value: Int) throws {}
    mutating func encode(_ value: Int8) throws {}
    mutating func encode(_ value: Int16) throws {}
    mutating func encode(_ value: Int32) throws {}
    mutating func encode(_ value: Int64) throws {}
    mutating func encode(_ value: UInt) throws {}
    mutating func encode(_ value: UInt8) throws {}
    mutating func encode(_ value: UInt16) throws {}
    mutating func encode(_ value: UInt32) throws {}
    mutating func encode(_ value: UInt64) throws {}

    mutating func encode<T: Encodable>(_ value: T) throws {
        try ProbeEncoder.walk(value, probe: probe, path: path, codingPath: codingPath)
    }
}
