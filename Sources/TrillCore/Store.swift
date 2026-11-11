import Foundation

public final class Store: @unchecked Sendable {
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
    private let ioLock = NSLock()

    public init(directory: URL = Store.defaultDirectory) {
        self.directory = directory
    }

    public var soundsDirectory: URL {
        let url = directory.appendingPathComponent("Sounds", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    public func loadRules() -> [Rule] { loadElements(Rule.self, "rules.json") }
    public func saveRules(_ rules: [Rule]) { save(rules, "rules.json") }
    public func loadSettings() -> AppSettings { load(AppSettings.self, "settings.json") ?? AppSettings() }
    public func saveSettings(_ settings: AppSettings) { save(settings, "settings.json") }
    public func loadUserSounds() -> [Sound] { loadElements(Sound.self, "sounds.json") }
    public func saveUserSounds(_ sounds: [Sound]) { save(sounds, "sounds.json") }

    // MARK: Loading

    private func fileURL(_ file: String) -> URL { directory.appendingPathComponent(file) }

    /// Copies an unreadable file aside as `<name>.corrupt-<timestamp>` so the next save cannot destroy it.
    private func quarantine(_ file: String) {
        let src = fileURL(file)
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyyMMdd-HHmmss-SSS"
        let dest = fileURL("\(file).corrupt-\(f.string(from: Date()))")
        try? FileManager.default.copyItem(at: src, to: dest)
    }

    private func load<T: Decodable>(_ type: T.Type, _ file: String) -> T? {
        ioLock.lock(); defer { ioLock.unlock() }
        guard FileManager.default.fileExists(atPath: fileURL(file).path) else { return nil }
        guard let data = try? Data(contentsOf: fileURL(file)) else { quarantine(file); return nil }
        if let value = try? JSONDecoder().decode(type, from: data) { return value }
        quarantine(file)
        return nil
    }

    /// Decodes an array element by element: one unreadable element is skipped and the rest are kept. If
    /// anything could not be read, the original file is copied aside first.
    private func loadElements<T: Decodable>(_ type: T.Type, _ file: String) -> [T] {
        ioLock.lock(); defer { ioLock.unlock() }
        guard FileManager.default.fileExists(atPath: fileURL(file).path) else { return [] }
        guard let data = try? Data(contentsOf: fileURL(file)),
              let array = (try? JSONSerialization.jsonObject(with: data)) as? [Any] else {
            quarantine(file)
            return []
        }
        var result: [T] = []
        var skipped = false
        for element in array {
            if JSONSerialization.isValidJSONObject(element),
               let d = try? JSONSerialization.data(withJSONObject: element),
               let value = try? JSONDecoder().decode(type, from: d) {
                result.append(value)
            } else {
                skipped = true
            }
        }
        if skipped { quarantine(file) }
        return result
    }

    // MARK: Saving

    private func save<T: Encodable>(_ value: T, _ file: String) {
        ioLock.lock(); defer { ioLock.unlock() }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let enc = JSONEncoder()
            enc.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try enc.encode(value)
            let url = fileURL(file)
            if let old = try? Data(contentsOf: url) {
                if old == data { return }
                // One level of undo: the contents before this save.
                let bak = fileURL("\(file).bak")
                try? FileManager.default.removeItem(at: bak)
                try? FileManager.default.copyItem(at: url, to: bak)
            }
            try data.write(to: url, options: .atomic)
        } catch {
            // Persistence failures never propagate to callers.
        }
    }
}
