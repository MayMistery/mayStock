import Foundation
import Observation

@Observable
@MainActor
final class ConfigurationService {
    private let directory: URL
    private let filename = "config.json"

    var monitorItems: [MonitorItem]

    init(directory: URL? = nil) {
        let dir = directory ?? ConfigurationService.defaultDirectory()
        self.directory = dir
        self.monitorItems = Self.load(from: dir) ?? Self.defaultItems()
    }

    func save() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(monitorItems)
        let fileURL = directory.appendingPathComponent(filename)
        try data.write(to: fileURL, options: .atomic)
    }

    private static func load(from directory: URL) -> [MonitorItem]? {
        let fileURL = directory.appendingPathComponent("config.json")
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        return try? JSONDecoder().decode([MonitorItem].self, from: data)
    }

    private static func defaultItems() -> [MonitorItem] {
        [.defaultBTC(), .defaultCPU(), .defaultMemory(), .defaultNetwork()]
    }

    private static func defaultDirectory() -> URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MayStock")
    }
}
