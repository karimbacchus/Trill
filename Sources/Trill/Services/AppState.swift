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
        didSet { if !isLoading { store.saveRules(rules) } }
    }
    @Published var settings: AppSettings = AppSettings() {
        didSet { if !isLoading { store.saveSettings(settings) } }
    }
    @Published private(set) var sounds: [Sound] = []
    @Published private(set) var log: [LogEntry] = []
    @Published private(set) var isAccessibilityTrusted: Bool = AXIsProcessTrusted()
    @Published private(set) var watcherStatus: String = "Not started"

    private let store = Store()
    private lazy var library = SoundLibrary(store: store)
    private let player = SoundPlayer()
    private let speaker = Speaker()
    private let watcher = NotificationWatcher()
    private var userSounds: [Sound] = []
    private var isLoading = false
    private var started = false
    private var trustTimer: Timer?
    private var watcherRunning = false

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
        sounds = library.allSounds(userSounds: userSounds)

        let lib = library
        let me = self
        Task.detached(priority: .utility) {
            lib.generateBuiltIns()
            await MainActor.run { me.refreshSounds() }
        }

        watcher.onNotification = { [weak self] n in
            Task { @MainActor in self?.handle(n) }
        }
        watcher.onStatus = { [weak self] s in
            Task { @MainActor in self?.watcherStatus = s }
        }
        refreshTrust()
        if !isAccessibilityTrusted { startTrustPolling() }
    }

    private func refreshSounds() {
        sounds = library.allSounds(userSounds: userSounds)
    }

    // MARK: Accessibility

    private func refreshTrust() {
        let trusted = AXIsProcessTrusted()
        if trusted != isAccessibilityTrusted { isAccessibilityTrusted = trusted }
        if trusted {
            trustTimer?.invalidate(); trustTimer = nil
            if started && !watcherRunning {
                watcherRunning = true
                watcherStatus = "Starting watcher"
                watcher.start()
            }
        } else {
            if watcherRunning { watcher.stop(); watcherRunning = false }
            watcherStatus = "Waiting for Accessibility permission"
        }
    }

    private func startTrustPolling() {
        trustTimer?.invalidate()
        let t = Timer(timeInterval: 2.0, repeats: true) { [weak self] _ in
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
        if !isAccessibilityTrusted { startTrustPolling() }
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

    func deleteSound(_ sound: Sound) {
        guard sound.kind == .user else { return }
        try? FileManager.default.removeItem(at: sound.url)
        userSounds.removeAll { $0.id == sound.id }
        store.saveUserSounds(userSounds)
        refreshSounds()
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

    // MARK: Apps and shortcuts

    func installedApps() -> [AppInfo] {
        var byID: [String: AppInfo] = [:]
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser.appendingPathComponent("Applications")
        let roots = [URL(fileURLWithPath: "/Applications"), URL(fileURLWithPath: "/System/Applications"), home]

        func consider(_ url: URL) {
            guard let b = Bundle(url: url), let id = b.bundleIdentifier, byID[id] == nil else { return }
            let name = (b.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
                ?? (b.object(forInfoDictionaryKey: "CFBundleName") as? String)
                ?? url.deletingPathExtension().lastPathComponent
            byID[id] = AppInfo(name: name, bundleID: id)
        }
        func scan(_ dir: URL, depth: Int) {
            guard let items = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.isDirectoryKey],
                                                          options: [.skipsHiddenFiles]) else { return }
            for item in items {
                if item.pathExtension == "app" { consider(item) }
                else if depth > 0, (try? item.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true {
                    scan(item, depth: depth - 1)
                }
            }
        }
        for r in roots { scan(r, depth: 2) }
        for app in NSWorkspace.shared.runningApplications {
            guard let id = app.bundleIdentifier, byID[id] == nil, let name = app.localizedName, !name.isEmpty else { continue }
            byID[id] = AppInfo(name: name, bundleID: id)
        }
        return byID.values.sorted {
            let c = $0.name.localizedCaseInsensitiveCompare($1.name)
            return c == .orderedSame ? $0.bundleID < $1.bundleID : c == .orderedAscending
        }
    }

    func shortcutNames() async -> [String] {
        await ShortcutRunner.list()
    }

    // MARK: Handling notifications

    func handle(_ notification: CapturedNotification) {
        let rule = RuleEngine.firstMatch(for: notification, in: rules)
        log.insert(LogEntry(id: UUID(), notification: notification, matchedRuleID: rule?.id, matchedRuleName: rule?.name), at: 0)
        if log.count > Self.maxLog { log.removeLast(log.count - Self.maxLog) }
        guard let rule, !settings.isPaused else { return }
        perform(rule.action, volume: rule.volume, for: notification)
    }

    func sendTestNotification(_ notification: CapturedNotification) {
        handle(notification)
    }

    func clearLog() {
        log.removeAll()
    }

    private func perform(_ action: RuleAction, volume: Double, for n: CapturedNotification) {
        switch action {
        case .sound(let soundID):
            if let s = sound(withID: soundID) { player.play(url: s.url, volume: volume) }
        case .speak(let voiceID, let template):
            speaker.speak(RuleEngine.render(template: template, with: n), voiceID: voiceID, volume: volume)
        case .shortcut(let name):
            ShortcutRunner.run(name: name, input: n.searchText)
        case .silent:
            break
        }
    }
}
