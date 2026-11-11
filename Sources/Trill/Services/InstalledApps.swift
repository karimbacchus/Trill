import Foundation
import AppKit
import TrillCore

/// Scans the installed applications and resolves a banner's app name to a bundle ID.
/// Thread-safe and cached: the scan runs at most once per `ttl`, and misses trigger a re-scan at most once
/// per `missRescanInterval`, so looking up a name per notification is cheap.
final class InstalledApps: @unchecked Sendable {
    static let shared = InstalledApps()

    /// Posted on the main queue after a background scan finished and the cache changed.
    static let didUpdate = Notification.Name("Trill.InstalledApps.didUpdate")

    private let lock = NSLock()
    private var apps: [AppInfo] = []
    private var byName: [String: String] = [:]   // normalized name -> bundle ID
    private var scannedAt: Date?
    private var lastMissRescan = Date.distantPast
    private var scanning = false                  // in-flight guard: at most one scan at a time
    private let ttl: TimeInterval = 600
    private let missRescanInterval: TimeInterval = 60

    /// Cached apps, sorted by name; returns immediately (possibly empty before the first scan finishes).
    /// A missing or stale cache triggers a background refresh, announced by `didUpdate`.
    func all() -> [AppInfo] {
        lock.lock()
        let stale = scannedAt.map { Date().timeIntervalSince($0) >= ttl } ?? true
        let result = apps
        lock.unlock()
        if stale { refreshInBackground() }
        return result
    }

    /// Warms the cache synchronously; call from a background queue.
    func warm() { scan(force: false) }

    func refreshInBackground() {
        DispatchQueue.global(qos: .utility).async { [self] in scan(force: false) }
    }

    /// Bundle ID for an app name as shown on a banner, or nil. Exact (case-insensitive), then without a
    /// trailing "(...)", then the longest known app name that prefixes it at a word boundary.
    /// May scan synchronously on a miss: call from a background thread only.
    func bundleID(forName name: String) -> String? {
        guard !AppIdentity.normalize(name).isEmpty else { return nil }
        scan(force: false)
        if let id = lookup(name) { return id }
        // Possibly newly installed: re-scan, but not on every miss.
        if missRescanDue() { scan(force: true); return lookup(name) }
        return nil
    }

    /// Like `bundleID(forName:)` but never blocks: cache only; a miss schedules a background re-scan.
    func cachedBundleID(forName name: String) -> String? {
        guard !AppIdentity.normalize(name).isEmpty else { return nil }
        if let id = lookup(name) { return id }
        if missRescanDue() { DispatchQueue.global(qos: .utility).async { [self] in scan(force: true) } }
        return nil
    }

    /// Display names and bundle IDs that denote the same app as `identifier` (a bundle ID or a name).
    func aliases(for identifier: String) -> [String] {
        let key = AppIdentity.normalize(identifier)
        guard !key.isEmpty else { return [] }
        lock.lock(); defer { lock.unlock() }
        var out: [String] = []
        for app in apps where app.bundleID.lowercased() == key || AppIdentity.normalize(app.name) == key {
            out.append(app.bundleID); out.append(app.name)
        }
        if out.isEmpty, let id = AppIdentity.resolve(name: identifier, in: byName) {
            out.append(id)
            if let app = apps.first(where: { $0.bundleID == id }) { out.append(app.name) }
        }
        return out
    }

    private func missRescanDue() -> Bool {
        lock.lock(); defer { lock.unlock() }
        let due = Date().timeIntervalSince(lastMissRescan) > missRescanInterval
        if due { lastMissRescan = Date() }
        return due
    }

    private func lookup(_ name: String) -> String? {
        lock.lock(); defer { lock.unlock() }
        return AppIdentity.resolve(name: name, in: byName)
    }

    private func scan(force: Bool) {
        lock.lock()
        let fresh = !force && scannedAt.map { Date().timeIntervalSince($0) < ttl } == true
        if fresh || scanning { lock.unlock(); return }
        scanning = true
        lock.unlock()
        let (list, names) = Self.scan()
        lock.lock()
        apps = list; byName = names; scannedAt = Date(); scanning = false
        lock.unlock()
        DispatchQueue.main.async { NotificationCenter.default.post(name: Self.didUpdate, object: nil) }
    }

    private static func normalize(_ s: String) -> String { AppIdentity.normalize(s) }

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
