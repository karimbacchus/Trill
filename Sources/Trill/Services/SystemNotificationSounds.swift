import Foundation
import TrillCore

enum SystemSoundState { case on, off, unknown }

struct SystemSoundError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

/// Reads and changes the "Play sound for notification" flag macOS keeps per app.
///
/// There is no public API. The flags live in the usernoted preferences plist: top-level key `apps`, an
/// array of dicts with `bundle-id` and an integer `flags` bitmask, where bit 2 (value 4) is "play sound".
/// Reading goes straight to the file (read-only). Writing goes through CFPreferences, so cfprefsd sees
/// the change, and then restarts `usernoted` so it reloads. Unsupported by Apple; it can stop working
/// in any macOS release, which is why every unexpected shape throws instead of guessing.
enum SystemNotificationSounds {
    static let soundBit = 4
    private static let appsKey = "apps"
    private static let bundleKey = "bundle-id"
    private static let flagsKey = "flags"

    static var candidatePaths: [String] {
        let home = NSHomeDirectory()
        return [
            home + "/Library/Group Containers/group.com.apple.usernoted/Library/Preferences/group.com.apple.usernoted.plist",
            home + "/Library/Preferences/com.apple.ncprefs.plist",
        ]
    }

    // MARK: Pure helpers (unit-checked against a copy of the plist)

    /// Returns the flags with only the sound bit changed.
    static func settingSoundBit(_ flags: Int64, enabled: Bool) -> Int64 {
        enabled ? (flags | Int64(soundBit)) : (flags & ~Int64(soundBit))
    }

    /// The integer value of a `flags` object, or nil when it is not a plain integer.
    static func integerFlags(_ value: Any?) -> Int64? {
        guard let n = value as? NSNumber,
              CFGetTypeID(n) == CFNumberGetTypeID(),
              !CFNumberIsFloatType(n) else { return nil }
        return n.int64Value
    }

    /// Returns a copy of `apps` where the entries for `bundleIDs` have only bit 2 of `flags` changed,
    /// plus the bundle IDs that matched. Every other entry and every other key is returned untouched.
    /// Throws if the shape is not what is expected or no entry matches.
    static func transform(apps: [Any], enabled: Bool, bundleIDs: [String]) throws -> (apps: [Any], matched: [String]) {
        let wanted = Set(bundleIDs.map { $0.lowercased() })
        var result: [Any] = []
        var matched: [String] = []
        for item in apps {
            guard let dict = item as? [String: Any] else {
                throw SystemSoundError("The notification settings have an unexpected layout (an app entry is not a dictionary).")
            }
            guard let id = dict[bundleKey] as? String, wanted.contains(id.lowercased()) else {
                result.append(item)
                continue
            }
            guard let flags = integerFlags(dict[flagsKey]) else {
                throw SystemSoundError("The notification settings for \(id) have an unexpected layout (flags is not an integer).")
            }
            var copy = dict
            copy[flagsKey] = NSNumber(value: settingSoundBit(flags, enabled: enabled))
            result.append(copy)
            matched.append(id)
        }
        guard !matched.isEmpty else {
            throw SystemSoundError("macOS has no notification settings for this app yet. It appears there after the app has shown its first notification.")
        }
        return (result, matched)
    }

    // MARK: Reading (file only, cached briefly)

    private static let cacheLock = NSLock()
    private static var cache: (date: Date, flags: [String: Int64]?)?

    /// Lower-cased bundle ID -> flags, or nil when no readable file with a usable `apps` array exists.
    private static func loadFlags() -> [String: Int64]? {
        for path in candidatePaths {
            guard let apps = readApps(atPath: path) else { continue }
            var map: [String: Int64] = [:]
            for case let dict as [String: Any] in apps {
                if let id = dict[bundleKey] as? String, let f = integerFlags(dict[flagsKey]) { map[id.lowercased()] = f }
            }
            return map
        }
        return nil
    }

    /// Reads `apps` from the plist file directly. Never throws or crashes.
    static func readApps(atPath path: String) -> [Any]? {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
              let object = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil),
              let top = object as? [String: Any] else { return nil }
        return top[appsKey] as? [Any]
    }

    static func invalidateCache() {
        cacheLock.lock(); cache = nil; cacheLock.unlock()
    }

    static func state(forBundleID id: String) -> SystemSoundState {
        cacheLock.lock()
        if cache == nil || Date().timeIntervalSince(cache!.date) > 4 {
            cache = (Date(), loadFlags())
        }
        let flags = cache?.flags
        cacheLock.unlock()
        guard let f = flags?[id.lowercased()] else { return .unknown }
        return f & Int64(soundBit) != 0 ? .on : .off
    }

    // MARK: Writing

    private static let writeLock = NSLock()

    /// Turns the app's own notification sound on or off. Returns true when re-reading the file shows the
    /// new state for every matched app. Throws, having changed nothing, if anything looks unexpected.
    /// Blocks for a few seconds: call it off the main thread.
    static func setSoundEnabled(_ enabled: Bool, bundleIDs: [String]) throws -> Bool {
        writeLock.lock(); defer { writeLock.unlock() }
        invalidateCache()

        // 1. Find the file and read it.
        guard let path = candidatePaths.first(where: { readApps(atPath: $0) != nil }),
              let diskApps = readApps(atPath: path) else {
            throw SystemSoundError("Could not read the macOS notification settings.")
        }
        let planned = try transform(apps: diskApps, enabled: enabled, bundleIDs: bundleIDs)
        let wantedFlag = Int64(enabled ? soundBit : 0)
        let wanted = Set(planned.matched.map { $0.lowercased() })
        let alreadyDone = diskApps.allSatisfy { item in
            guard let d = item as? [String: Any], let id = d[bundleKey] as? String, wanted.contains(id.lowercased()),
                  let f = integerFlags(d[flagsKey]) else { return true }
            return f & Int64(soundBit) == wantedFlag
        }
        if alreadyDone { return true }

        // 2. What cfprefsd sees must match the file, or we would write back stale data.
        let domain = String(path.dropLast(".plist".count)) as CFString
        guard CFPreferencesAppSynchronize(domain),   // reload from disk first
              let cfApps = CFPreferencesCopyValue(appsKey as CFString, domain, kCFPreferencesCurrentUser, kCFPreferencesAnyHost) as? [Any],
              sameIdentity(cfApps, diskApps) else {
            throw SystemSoundError("The notification settings changed while Trill was reading them. Nothing was changed.")
        }
        let final = try transform(apps: cfApps, enabled: enabled, bundleIDs: bundleIDs)

        // 3. Back up the file before touching it.
        try backUp(path)

        // 4. Write through CFPreferences and flush.
        CFPreferencesSetValue(appsKey as CFString, final.apps as CFArray, domain, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
        guard CFPreferencesSynchronize(domain, kCFPreferencesCurrentUser, kCFPreferencesAnyHost) else {
            throw SystemSoundError("macOS refused to write the notification settings. Nothing was changed.")
        }

        // 5. Restart usernoted so it reloads, then verify from disk.
        try restartUsernoted()
        for _ in 0..<12 {
            Thread.sleep(forTimeInterval: 0.25)
            invalidateCache()
            if planned.matched.allSatisfy({ state(forBundleID: $0) == (enabled ? .on : .off) }) { return true }
        }
        invalidateCache()
        return false
    }

    /// Same number of entries with the same bundle IDs in the same order.
    private static func sameIdentity(_ a: [Any], _ b: [Any]) -> Bool {
        guard a.count == b.count else { return false }
        for (x, y) in zip(a, b) {
            guard let dx = x as? [String: Any], let dy = y as? [String: Any],
                  (dx[bundleKey] as? String) == (dy[bundleKey] as? String) else { return false }
        }
        return true
    }

    private static func backUp(_ path: String) throws {
        let dir = Store.defaultDirectory.appendingPathComponent("Backups", isDirectory: true)
        let fm = FileManager.default
        do {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            let f = DateFormatter()
            f.locale = Locale(identifier: "en_US_POSIX")
            f.dateFormat = "yyyyMMdd-HHmmss"
            let name = "notification-prefs-\(f.string(from: Date())).plist"
            try fm.copyItem(atPath: path, toPath: dir.appendingPathComponent(name).path)
            let old = try fm.contentsOfDirectory(atPath: dir.path)
                .filter { $0.hasPrefix("notification-prefs-") && $0.hasSuffix(".plist") }
                .sorted(by: >)
                .dropFirst(5)
            for n in old { try? fm.removeItem(at: dir.appendingPathComponent(n)) }
        } catch {
            throw SystemSoundError("Could not back up the notification settings first (\(error.localizedDescription)). Nothing was changed.")
        }
    }

    private static func restartUsernoted() throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/killall")
        p.arguments = ["usernoted"]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch {
            throw SystemSoundError("Settings were saved but the notification service could not be restarted: \(error.localizedDescription)")
        }
        p.waitUntilExit()
        // killall exits non-zero when no process matched; launchd starts usernoted on demand, so that is not fatal.
    }
}
