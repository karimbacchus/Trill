import Foundation
import AppKit
import AVFoundation
import ApplicationServices
import Combine
import TrillCore

struct LogEntry: Identifiable, Hashable {
    let id: UUID
    let notification: CapturedNotification
    let matchedRuleID: UUID?
    let matchedRuleName: String?
    /// Something went wrong playing the match (e.g. "Missing sound"), shown in Diagnostics.
    var warning: String? = nil
}

/// Inline message under an app row about its own notification sound.
enum OwnSoundNotice: Equatable {
    case working(String)
    case turnedOff(undoIDs: [String])
    case restored
    case failed(String)
}

struct AppInfo: Identifiable, Hashable {
    var id: String { bundleID }
    let name: String
    let bundleID: String
}

struct VoiceInfo: Identifiable, Hashable {
    let id: String
    let name: String
    let language: String
}

@MainActor
final class AppState: ObservableObject {
    static let shared = AppState()

    @Published var rules: [Rule] = [] {
        didSet { if !isLoading { dirtyRules = true; scheduleSave() } }
    }
    @Published var settings: AppSettings = AppSettings() {
        didSet { if !isLoading { dirtySettings = true; scheduleSave() } }
    }
    @Published private(set) var sounds: [Sound] = []
    @Published private(set) var log: [LogEntry] = []
    @Published private(set) var isAccessibilityTrusted: Bool = AXIsProcessTrusted()
    @Published private(set) var watcherStatus: String = "Not started"

    /// Bumped whenever the macOS notification-sound flags may have changed, so views re-read them.
    @Published private(set) var systemSoundRevision = 0
    /// Short inline messages per app row (keyed by `AppSoundEntry.id`).
    @Published var ownSoundNotices: [String: OwnSoundNotice] = [:]
    /// Brief note under a Preview button (e.g. that Shortcuts are not run in preview).
    @Published private(set) var previewNote: String?

    private let store = Store()
    private lazy var library = SoundLibrary(store: store)
    private let player = SoundPlayer()
    private let speaker = Speaker()
    private let watcher = NotificationWatcher()
    private var userSounds: [Sound] = []
    private var isLoading = false
    private var started = false
    private var trustTimer: Timer?
    private var trustInterval: TimeInterval = 0
    private var watcherRunning = false
    private var builtInsReady = false

    // Persistence is debounced and written off the main thread.
    private let saveQueue = DispatchQueue(label: "Trill.Persistence", qos: .utility)
    private var saveTask: Task<Void, Never>?
    private var dirtyRules = false
    private var dirtySettings = false
    /// Rules as of the last check for muted apps whose default went away.
    private var lastReconciledRules: [Rule] = []

    private static let maxLog = 200

    init() {}

    // MARK: Lifecycle

    func start() {
        guard !started else { return }
        started = true

        isLoading = true
        rules = store.loadRules()
        settings = store.loadSettings()
        userSounds = store.loadUserSounds()
        isLoading = false
        lastReconciledRules = rules
        sounds = library.allSounds(userSounds: userSounds)

        watcher.onNotification = { [weak self] n in
            Task { @MainActor in self?.handle(n) }
        }
        watcher.onStatus = { [weak self] s in
            Task { @MainActor in self?.watcherStatus = s }
        }
        let player = self.player
        watcher.onPending = { player.prewarm() }

        // The synthesized sounds must exist before the watcher can handle a notification (one at login
        // would otherwise find no sound file), so the watcher starts once they are generated.
        let lib = library
        let me = self
        Task.detached(priority: .utility) {
            lib.generateBuiltIns()
            InstalledApps.shared.warm()
            await MainActor.run {
                me.refreshSounds()
                me.builtInsReady = true
                me.refreshTrust()
            }
        }
        refreshTrust()
    }

    // MARK: Persistence

    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 300_000_000)
            guard !Task.isCancelled, let self else { return }
            self.flushSaves()
            self.reconcileMutedOwnSounds()
        }
    }

    /// Writes any pending rules/settings now. `wait: true` (quit) blocks until they are on disk.
    func flushSaves(wait: Bool = false) {
        saveTask?.cancel(); saveTask = nil
        let r: [Rule]? = dirtyRules ? rules : nil
        let s: AppSettings? = dirtySettings ? settings : nil
        dirtyRules = false; dirtySettings = false
        guard r != nil || s != nil else { return }
        let store = self.store
        let work: @Sendable () -> Void = {
            if let r { store.saveRules(r) }
            if let s { store.saveSettings(s) }
        }
        if wait { saveQueue.sync(execute: work) } else { saveQueue.async(execute: work) }
    }

    private func refreshSounds() {
        sounds = library.allSounds(userSounds: userSounds)
    }

    // MARK: Accessibility

    private func refreshTrust() {
        let trusted = AXIsProcessTrusted()
        if trusted != isAccessibilityTrusted { isAccessibilityTrusted = trusted }
        // Keep polling (slowly once trusted) so a later revoke is noticed.
        startTrustPolling(interval: trusted ? 5.0 : 2.0)
        if trusted {
            if started && builtInsReady && !watcherRunning {
                watcherRunning = true
                watcherStatus = "Starting watcher"
                watcher.start()
            }
        } else {
            if watcherRunning { watcher.stop(); watcherRunning = false }
            watcherStatus = "Waiting for Accessibility permission"
        }
    }

    private func startTrustPolling(interval: TimeInterval = 2.0) {
        guard trustTimer == nil || trustInterval != interval else { return }
        trustInterval = interval
        trustTimer?.invalidate()
        let t = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshTrust() }
        }
        RunLoop.main.add(t, forMode: .common)
        trustTimer = t
    }

    func requestAccessibilityPermission() {
        let opts = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(opts)
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
        refreshTrust()
    }

    func accessibilityDump() -> String {
        NotificationWatcher.dumpAccessibilityTree()
    }

    // MARK: Sounds

    func sound(withID id: String) -> Sound? {
        sounds.first { $0.id == id }
    }

    func preview(sound: Sound, volume: Double) {
        stopPreview()
        player.play(url: sound.url, volume: volume)
    }

    func preview(action: RuleAction, volume: Double, sample: CapturedNotification?) {
        stopPreview()
        if case .shortcut = action {
            // Never run a real Shortcut from a preview.
            previewNote = "Shortcuts aren't run in preview"
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                if self.previewNote == "Shortcuts aren't run in preview" { self.previewNote = nil }
            }
            return
        }
        previewNote = nil
        let n = sample ?? CapturedNotification(
            appName: "Mail", bundleID: "com.apple.mail", title: "Quarterly report",
            subtitle: "Alex Morgan", body: "The numbers are in. Take a look when you can.")
        perform(action, volume: volume, for: n)
    }

    func stopPreview() {
        player.stopAll()
        speaker.stop()
    }

    func importSounds(from urls: [URL]) throws -> [Sound] {
        let new = try library.importFiles(urls)
        userSounds.append(contentsOf: new)
        store.saveUserSounds(userSounds)
        refreshSounds()
        return new
    }

    /// Rules whose action plays `sound`.
    func rules(using sound: Sound) -> [Rule] {
        rules.filter { if case .sound(let id) = $0.action { return id == sound.id } else { return false } }
    }

    /// The sound rules fall back to when theirs is deleted.
    func fallbackSound(excluding id: String? = nil) -> Sound? {
        for pref in ["system:Glass", "builtin:chime-up"] {
            if pref != id, let s = sound(withID: pref) { return s }
        }
        return sounds.first { $0.id != id }
    }

    /// Deletes a user sound and repoints every rule that used it to the fallback sound. Returns how many rules changed.
    @discardableResult
    func deleteSound(_ sound: Sound) -> Int {
        guard sound.kind == .user else { return 0 }
        try? FileManager.default.removeItem(at: sound.url)
        userSounds.removeAll { $0.id == sound.id }
        store.saveUserSounds(userSounds)
        let fallback = fallbackSound(excluding: sound.id)
        var changed = 0
        var updated = rules
        for i in updated.indices {
            if case .sound(let id) = updated[i].action, id == sound.id {
                updated[i].action = .sound(soundID: fallback?.id ?? "system:Glass")
                changed += 1
            }
        }
        if changed > 0 { rules = updated }
        refreshSounds()
        return changed
    }

    func generateSpokenSound(text: String, voiceID: String?, name: String) async throws -> Sound {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw ServicesError.synthesisFailed("the text is empty") }
        let uuid = UUID()
        let dir = store.soundsDirectory
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("\(uuid.uuidString).caf")
        try await speaker.render(text: trimmed, voiceID: voiceID, to: url)
        let cleanName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let sound = Sound(id: "user:\(uuid.uuidString)", name: cleanName.isEmpty ? String(trimmed.prefix(40)) : cleanName,
                          kind: .user, url: url)
        userSounds.append(sound)
        store.saveUserSounds(userSounds)
        refreshSounds()
        return sound
    }

    var voices: [VoiceInfo] {
        AVSpeechSynthesisVoice.speechVoices()
            .map { VoiceInfo(id: $0.identifier, name: $0.name, language: $0.language) }
            .sorted {
                if $0.language != $1.language { return $0.language < $1.language }
                return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
            }
    }

    // MARK: Apps' own notification sounds

    /// Combined state for one app's bundle IDs: on if any is on, else off if any is off, else unknown.
    func systemSoundState(for bundleIDs: [String]) -> SystemSoundState {
        _ = systemSoundRevision
        let states = bundleIDs.map { SystemNotificationSounds.state(forBundleID: $0) }
        if states.contains(.on) { return .on }
        if states.contains(.off) { return .off }
        return .unknown
    }

    /// Re-reads the flags from disk (read-only).
    func refreshSystemSounds() {
        SystemNotificationSounds.invalidateCache()
        systemSoundRevision &+= 1
    }

    func setSystemSound(enabled: Bool, for bundleIDs: [String]) async -> Result<Void, Error> {
        let wasOn = Set(bundleIDs.filter { SystemNotificationSounds.state(forBundleID: $0) == .on }.map { $0.lowercased() })
        let outcome: Result<Bool, Error> = await Task.detached(priority: .userInitiated) {
            Result { try SystemNotificationSounds.setSoundEnabled(enabled, bundleIDs: bundleIDs) }
        }.value
        refreshSystemSounds()
        switch outcome {
        case .failure(let error):
            return .failure(error)
        case .success(let verified):
            var muted = settings.mutedBundleIDs
            if enabled {
                muted.removeAll { id in bundleIDs.contains { $0.caseInsensitiveCompare(id) == .orderedSame } }
            } else {
                for id in bundleIDs where wasOn.contains(id.lowercased()) && !muted.contains(id) { muted.append(id) }
            }
            if muted != settings.mutedBundleIDs { settings.mutedBundleIDs = muted }
            return verified ? .success(())
                : .failure(SystemSoundError("macOS did not confirm the change. It may take effect after the app is restarted."))
        }
    }

    // MARK: Apps and shortcuts

    func installedApps() -> [AppInfo] {
        InstalledApps.shared.all()
    }

    func shortcutNames() async -> [String] {
        await ShortcutRunner.list()
    }

    // MARK: Handling notifications

    /// Other identifiers of the same app (display names, alternate bundle IDs) for matching an app filter.
    func appAliases(for filter: String) -> [String] {
        let f = AppIdentity.normalize(filter)
        var out: [String] = []
        if let k = KnownApps.all.first(where: { app in
            app.bundleIDs.contains { $0.lowercased() == f } || AppIdentity.normalize(app.name) == f }) {
            out += k.bundleIDs + [k.name]
        }
        out += InstalledApps.shared.aliases(for: f)
        return out
    }

    /// Fills in what the banner lacked: the bundle ID from the app name, or the name from the bundle ID.
    private func enriched(_ n: CapturedNotification) -> CapturedNotification {
        var n = n
        if n.bundleID == nil, !n.appName.isEmpty {
            n.bundleID = InstalledApps.shared.cachedBundleID(forName: n.appName)
        }
        if n.appName.isEmpty, let id = n.bundleID, !id.isEmpty {
            let lower = id.lowercased()
            if let app = InstalledApps.shared.all().first(where: { $0.bundleID.lowercased() == lower }) {
                n.appName = app.name
            } else if let k = KnownApps.all.first(where: { $0.bundleIDs.contains { $0.lowercased() == lower } }) {
                n.appName = k.name
            }
        }
        return n
    }

    func handle(_ raw: CapturedNotification) {
        let notification = enriched(raw)
        let rule = RuleEngine.firstMatch(for: notification, in: rules, aliases: { [unowned self] in self.appAliases(for: $0) })
        log.insert(LogEntry(id: UUID(), notification: notification, matchedRuleID: rule?.id, matchedRuleName: rule?.name), at: 0)
        if log.count > Self.maxLog { log.removeLast(log.count - Self.maxLog) }
        guard let rule, !settings.isPaused else { return }
        if let warning = perform(rule.action, volume: rule.volume, for: notification),
           let i = log.firstIndex(where: { $0.notification.id == notification.id }) {
            log[i].warning = warning
        }
    }

    func sendTestNotification(_ notification: CapturedNotification) {
        handle(notification)
    }

    func clearLog() {
        log.removeAll()
    }

    /// Runs an action. Returns a warning to show in Diagnostics when something was wrong (a missing sound).
    @discardableResult
    private func perform(_ action: RuleAction, volume: Double, for n: CapturedNotification) -> String? {
        switch action {
        case .sound(let soundID):
            if let s = sound(withID: soundID) {
                player.play(url: s.url, volume: volume)
            } else {
                // The sound was deleted or never existed: still make a noise, and say so.
                let fallback = fallbackSound()?.url ?? URL(fileURLWithPath: "/System/Library/Sounds/Glass.aiff")
                player.play(url: fallback, volume: volume)
                return "Missing sound (played a fallback)"
            }
        case .speak(let voiceID, let template):
            speaker.speak(RuleEngine.render(template: template, with: n), voiceID: voiceID, volume: volume)
        case .shortcut(let name):
            ShortcutRunner.run(name: name, input: n.searchText)
        case .silent:
            break
        }
        return nil
    }

    // MARK: Restoring muted apps' own sounds

    /// The "App sounds" entry for a bundle ID Trill muted.
    private func ownSoundEntry(forBundleID id: String) -> AppSoundEntry {
        let lower = id.lowercased()
        if let k = KnownApps.all.first(where: { $0.bundleIDs.contains { $0.lowercased() == lower } }) {
            let primary = k.bundleIDs.first { $0.lowercased() == lower } ?? id
            return AppSoundEntry(name: k.name, bundleID: primary, otherBundleIDs: k.bundleIDs)
        }
        let name = InstalledApps.shared.all().first { $0.bundleID.lowercased() == lower }?.name ?? id
        return AppSoundEntry(name: name, bundleID: id)
    }

    private func hasActiveDefault(_ entry: AppSoundEntry, in rules: [Rule]) -> Bool {
        rules.contains { rule in
            guard rule.isEnabled, rule.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  let f = rule.appFilter?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(), !f.isEmpty
            else { return false }
            return entry.aliases.contains(f)
        }
    }

    /// When an app's default rule is removed, disabled or retargeted, give back the macOS notification sound
    /// Trill had turned off for it. Runs from the debounced rules save, wherever the change came from.
    private func reconcileMutedOwnSounds() {
        let before = lastReconciledRules
        lastReconciledRules = rules
        guard !settings.mutedBundleIDs.isEmpty else { return }
        var seen = Set<String>()
        for id in settings.mutedBundleIDs {
            let entry = ownSoundEntry(forBundleID: id)
            guard seen.insert(entry.id.lowercased()).inserted else { continue }
            if hasActiveDefault(entry, in: before), !hasActiveDefault(entry, in: rules) {
                restoreOwnSoundIfWeMuted(for: entry)
            }
        }
    }
}
