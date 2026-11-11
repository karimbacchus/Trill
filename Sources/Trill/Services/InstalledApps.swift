import Foundation
import AppKit

/// Scans the installed applications and resolves a banner's app name to a bundle ID.
/// Thread-safe and cached: the scan runs at most once per `ttl`, and misses trigger a re-scan at most once
/// per `missRescanInterval`, so looking up a name per notification is cheap.
final class InstalledApps: @unchecked Sendable {
    static let shared = InstalledApps()

    private let lock = NSLock()
    private var apps: [AppInfo] = []
    private var byName: [String: String] = [:]   // lowercased name -> bundle ID
    private var scannedAt: Date?
    private var lastMissRescan = Date.distantPast
    private let ttl: TimeInterval = 600
    private let missRescanInterval: TimeInterval = 60

    /// All installed (and running) apps, sorted by name.
    func all() -> [AppInfo] {
        refreshIfNeeded(force: false)
        lock.lock(); defer { lock.unlock() }
        return apps
    }

    /// Warms the cache; call from a background queue.
    func warm() { refreshIfNeeded(force: false) }

    /// Bundle ID for an app name as shown on a banner (case-insensitive), or nil.
    func bundleID(forName name: String) -> String? {
        let key = Self.normalize(name)
        guard !key.isEmpty else { return nil }
        refreshIfNeeded(force: false)
        if let id = lookup(key) { return id }
        // Possibly newly installed: re-scan, but not on every miss.
        lock.lock()
        let due = Date().timeIntervalSince(lastMissRescan) > missRescanInterval
        if due { lastMissRescan = Date() }
        lock.unlock()
        if due { refreshIfNeeded(force: true); return lookup(key) }
        return nil
    }

    private func lookup(_ key: String) -> String? {
        lock.lock(); defer { lock.unlock() }
        return byName[key]
    }

    private static func normalize(_ s: String) -> String {
        s.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private func refreshIfNeeded(force: Bool) {
        lock.lock()
        let fresh = !force && scannedAt.map { Date().timeIntervalSince($0) < ttl } == true
        lock.unlock()
        if fresh { return }
        let (list, names) = Self.scan()
        lock.lock()
        apps = list; byName = names; scannedAt = Date()
        lock.unlock()
    }

    private static func scan() -> ([AppInfo], [String: String]) {
        var byID: [String: AppInfo] = [:]
        var names: [String: String] = [:]
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser.appendingPathComponent("Applications")
        let roots = [URL(fileURLWithPath: "/Applications"), URL(fileURLWithPath: "/System/Applications"), home]

        func addName(_ n: String?, _ id: String) {
            guard let n = n else { return }
            let k = normalize(n)
            if !k.isEmpty, names[k] == nil { names[k] = id }
        }
        func consider(_ url: URL) {
            guard let b = Bundle(url: url), let id = b.bundleIdentifier, byID[id] == nil else { return }
            let display = b.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
            let bundleName = b.object(forInfoDictionaryKey: "CFBundleName") as? String
            let fileName = url.deletingPathExtension().lastPathComponent
            byID[id] = AppInfo(name: display ?? bundleName ?? fileName, bundleID: id)
            addName(display, id); addName(bundleName, id); addName(fileName, id)
            if let localized = fm.displayName(atPath: url.path) as String? {
                addName(localized.hasSuffix(".app") ? String(localized.dropLast(4)) : localized, id)
            }
        }
        func scanDir(_ dir: URL, depth: Int) {
            guard let items = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.isDirectoryKey],
                                                          options: [.skipsHiddenFiles]) else { return }
            for item in items {
                if item.pathExtension == "app" { consider(item) }
                else if depth > 0, (try? item.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true {
                    scanDir(item, depth: depth - 1)
                }
            }
        }
        for r in roots { scanDir(r, depth: 2) }
        for app in NSWorkspace.shared.runningApplications {
            guard let id = app.bundleIdentifier, byID[id] == nil, let name = app.localizedName, !name.isEmpty else { continue }
            byID[id] = AppInfo(name: name, bundleID: id)
            addName(name, id)
        }
        let list = byID.values.sorted {
            let c = $0.name.localizedCaseInsensitiveCompare($1.name)
            return c == .orderedSame ? $0.bundleID < $1.bundleID : c == .orderedAscending
        }
        return (list, names)
    }
}
