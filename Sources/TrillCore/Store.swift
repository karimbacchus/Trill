import Foundation

public final class Store {
    public static var defaultDirectory: URL {
        // TRILL_DATA_DIR points the app at a separate data folder (used for demos and screenshots).
        if let override = ProcessInfo.processInfo.environment["TRILL_DATA_DIR"], !override.isEmpty {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("Trill", isDirectory: true)
    }

    public let directory: URL

    public init(directory: URL = Store.defaultDirectory) {
        self.directory = directory
    }

    public var soundsDirectory: URL {
        let url = directory.appendingPathComponent("Sounds", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    public func loadRules() -> [Rule] { load([Rule].self, "rules.json") ?? [] }
    public func saveRules(_ rules: [Rule]) { save(rules, "rules.json") }
    public func loadSettings() -> AppSettings { load(AppSettings.self, "settings.json") ?? AppSettings() }
    public func saveSettings(_ settings: AppSettings) { save(settings, "settings.json") }
    public func loadUserSounds() -> [Sound] { load([Sound].self, "sounds.json") ?? [] }
    public func saveUserSounds(_ sounds: [Sound]) { save(sounds, "sounds.json") }

    private func load<T: Decodable>(_ type: T.Type, _ file: String) -> T? {
        guard let data = try? Data(contentsOf: directory.appendingPathComponent(file)) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }

    private func save<T: Encodable>(_ value: T, _ file: String) {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let enc = JSONEncoder()
            enc.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try enc.encode(value)
            try data.write(to: directory.appendingPathComponent(file), options: .atomic)
        } catch {
            // Persistence failures never propagate to callers.
        }
    }
}
