import SwiftUI
import TrillCore

// MARK: - Known apps and default-rule logic

struct KnownApp {
    let name: String
    let bundleIDs: [String]
}

enum KnownApps {
    /// Notification-heavy apps people most often want a custom sound for.
    static let all: [KnownApp] = [
        KnownApp(name: "Slack", bundleIDs: ["com.tinyspeck.slackmacgap"]),
        KnownApp(name: "Microsoft Teams", bundleIDs: ["com.microsoft.teams2", "com.microsoft.teams"]),
        KnownApp(name: "Discord", bundleIDs: ["com.hnc.Discord"]),
        KnownApp(name: "Messages", bundleIDs: ["com.apple.MobileSMS"]),
        KnownApp(name: "Mail", bundleIDs: ["com.apple.mail"]),
        KnownApp(name: "Microsoft Outlook", bundleIDs: ["com.microsoft.Outlook"]),
        KnownApp(name: "WhatsApp", bundleIDs: ["net.whatsapp.WhatsApp", "desktop.WhatsApp"]),
        KnownApp(name: "Telegram", bundleIDs: ["ru.keepcoder.Telegram", "org.telegram.desktop"]),
        KnownApp(name: "Signal", bundleIDs: ["org.whispersystems.signal-desktop"]),
        KnownApp(name: "Zoom", bundleIDs: ["us.zoom.xos"]),
        KnownApp(name: "Webex", bundleIDs: ["Cisco-Systems.Spark", "com.cisco.webexmeetingsapp"]),
        KnownApp(name: "Google Chrome", bundleIDs: ["com.google.Chrome"]),
        KnownApp(name: "Microsoft Edge", bundleIDs: ["com.microsoft.edgemac"]),
        KnownApp(name: "Firefox", bundleIDs: ["org.mozilla.firefox"]),
        KnownApp(name: "Safari", bundleIDs: ["com.apple.Safari"]),
        KnownApp(name: "Calendar", bundleIDs: ["com.apple.iCal"]),
        KnownApp(name: "Reminders", bundleIDs: ["com.apple.reminders"]),
        KnownApp(name: "FaceTime", bundleIDs: ["com.apple.FaceTime"]),
        KnownApp(name: "Skype", bundleIDs: ["com.skype.skype"]),
        KnownApp(name: "Notion", bundleIDs: ["notion.id"]),
    ]
}

/// One row of the "App sounds" pane.
struct AppSoundEntry: Identifiable, Hashable {
    /// Bundle ID used when a new default rule is created.
    let bundleID: String
    let name: String
    /// Lower-cased bundle IDs and display name that count as "this app" for an existing rule.
    let aliases: Set<String>
    /// Every real bundle ID of the app (primary first); used for its macOS notification settings.
    let systemIDs: [String]
    var id: String { bundleID }

    init(name: String, bundleID: String, otherBundleIDs: [String] = []) {
        self.name = name
        self.bundleID = bundleID
        var ids: [String] = []
        for id in [bundleID] + otherBundleIDs where id.contains(".") || id.contains("-") {
            if !ids.contains(id) { ids.append(id) }
        }
        self.systemIDs = ids
        self.aliases = Set(([bundleID] + otherBundleIDs + [name]).map { $0.lowercased() })
    }
}

extension AppState {
    /// A rule is the app's default when its query is empty and its appFilter names the app
    /// (bundle ID or display name, case-insensitive). The first such rule wins, like the engine.
    func defaultRuleIndex(for entry: AppSoundEntry) -> Int? {
        rules.firstIndex { rule in
            guard rule.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  let f = rule.appFilter?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
                  !f.isEmpty else { return false }
            return entry.aliases.contains(f)
        }
    }

    /// Updates the app's default rule, or adds a new one after the app-specific rules but before the first
    /// rule with no app (which would otherwise shadow it).
    func setDefaultSound(_ soundID: String, for entry: AppSoundEntry) {
        if let i = defaultRuleIndex(for: entry) {
            rules[i].action = .sound(soundID: soundID)
            rules[i].isEnabled = true
        } else {
            rules.insert(Rule(name: "\(entry.name) — default", appFilter: entry.bundleID, query: "",
                              action: .sound(soundID: soundID), volume: 1.0),
                         at: RuleEngine.defaultInsertionIndex(in: rules))
        }
        muteOwnSoundIfNeeded(for: entry)
    }

    // MARK: The app's own notification sound

    private func notice(_ n: OwnSoundNotice, for entry: AppSoundEntry, clearAfter seconds: Double? = 8) {
        ownSoundNotices[entry.id] = n
        guard let seconds else { return }
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            if self.ownSoundNotices[entry.id] == n { self.ownSoundNotices[entry.id] = nil }
        }
    }

    /// After the user gives an app a sound (or turns its default on): turn the app's own sound off.
    func muteOwnSoundIfNeeded(for entry: AppSoundEntry) {
        guard settings.muteAppOwnSounds, !entry.systemIDs.isEmpty,
              systemSoundState(for: entry.systemIDs) == .on else { return }
        turnOffOwnSound(for: entry)
    }

    func turnOffOwnSound(for entry: AppSoundEntry) {
        let ids = entry.systemIDs
        let before = ids.filter { SystemNotificationSounds.state(forBundleID: $0) == .on }
        notice(.working("Turning off \(entry.possessiveName) own sound…"), for: entry, clearAfter: nil)
        Task { @MainActor in
            switch await setSystemSound(enabled: false, for: ids) {
            case .success: notice(.turnedOff(undoIDs: before), for: entry, clearAfter: 10)
            case .failure(let e): notice(.failed(e.localizedDescription), for: entry, clearAfter: 12)
            }
        }
    }

    func turnOnOwnSound(for entry: AppSoundEntry, ids: [String], undo: Bool) {
        notice(.working("Turning on \(entry.possessiveName) own sound…"), for: entry, clearAfter: nil)
        Task { @MainActor in
            switch await setSystemSound(enabled: true, for: ids) {
            case .success:
                if undo { ownSoundNotices[entry.id] = nil } else { notice(.restored, for: entry, clearAfter: 6) }
            case .failure(let e): notice(.failed(e.localizedDescription), for: entry, clearAfter: 12)
            }
        }
    }

    /// After the app's default is removed or switched off: give back the sound Trill took away.
    func restoreOwnSoundIfWeMuted(for entry: AppSoundEntry) {
        let ids = entry.systemIDs.filter { id in
            settings.mutedBundleIDs.contains { $0.caseInsensitiveCompare(id) == .orderedSame }
        }
        guard !ids.isEmpty else { return }
        turnOnOwnSound(for: entry, ids: ids, undo: false)
    }

    /// New rule for the app, placed just above its default (or where a new default would go if it has none yet).
    @discardableResult
    func addRule(above entry: AppSoundEntry) -> UUID {
        let index = defaultRuleIndex(for: entry) ?? RuleEngine.defaultInsertionIndex(in: rules)
        let base = defaultRuleIndex(for: entry).map { rules[$0] }
        let action = base?.action ?? .sound(soundID: soundID(preferring: ["system:Glass", "builtin:chime-up"]))
        let rule = Rule(name: "\(entry.name) — new rule", appFilter: entry.bundleID, query: "#channel-name",
                        action: action, volume: base?.volume ?? 1.0)
        rules.insert(rule, at: index)
        UIRouter.shared.focusQueryRuleID = rule.id
        UIRouter.shared.selectedRuleID = rule.id
        return rule.id
    }
}

// MARK: - Pane

struct AppSoundsView: View {
    @ObservedObject private var state = AppState.shared
    @ObservedObject private var catalog = AppCatalog.shared
    @State private var extras: [AppSoundEntry] = []
    @State private var pickingFor: AppSoundEntry?
    @State private var showAppPicker = false
    /// The sound chosen in the picker for an app that has no default yet. It is only turned into a rule on Done.
    @State private var draftSound = ""

    private var entries: [AppSoundEntry] {
        var result: [AppSoundEntry] = []
        var claimed = Set<String>()
        func add(_ e: AppSoundEntry) {
            guard claimed.isDisjoint(with: e.aliases) else { return }
            claimed.formUnion(e.aliases)
            result.append(e)
        }
        let installed = Set(catalog.apps.map { $0.bundleID.lowercased() })
        for known in KnownApps.all {
            let present = known.bundleIDs.filter { installed.contains($0.lowercased()) }
            guard let primary = present.first else { continue }
            add(AppSoundEntry(name: known.name, bundleID: primary, otherBundleIDs: known.bundleIDs))
        }
        // Apps that already have a default rule but are not in the well-known list, plus ones just added.
        for rule in state.rules where rule.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            guard let f = rule.appFilter?.trimmingCharacters(in: .whitespaces), !f.isEmpty else { continue }
            if let info = catalog.info(forFilter: f) {
                add(AppSoundEntry(name: info.name, bundleID: info.bundleID))
            } else {
                add(AppSoundEntry(name: f, bundleID: f))
            }
        }
        extras.forEach(add)
        return result
    }

    /// Apps with an active default whose own sound is on or can't be read.
    private var attentionNames: [String] {
        entries.compactMap { e in
            guard let i = state.defaultRuleIndex(for: e), state.rules[i].isEnabled,
                  state.ownSoundNotices[e.id] == nil else { return nil }
            return state.systemSoundState(for: e.systemIDs) == .off ? nil : e.name
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header
                notificationNote
                LazyVStack(spacing: 10) {
                    ForEach(entries) { entry in
                        AppSoundRow(entry: entry, choose: { pickingFor = entry })
                    }
                }
                Button {
                    showAppPicker = true
                } label: {
                    Label("Add another app…", systemImage: "plus.app")
                }
                .glassButton()
                .controlSize(.large)
                .popover(isPresented: $showAppPicker, arrowEdge: .bottom) {
                    AppChooserPopover { app in
                        let entry = AppSoundEntry(name: app.name, bundleID: app.bundleID)
                        if !extras.contains(entry) { extras.append(entry) }
                        showAppPicker = false
                        pickingFor = entry
                    }
                }
            }
            .padding(24)
            .frame(maxWidth: 760, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .navigationTitle("App sounds")
        .task { catalog.loadIfNeeded() }
        .onAppear { state.refreshSystemSounds() }   // read-only
        .onReceive(UIRouter.shared.$demoOpenPicker) { open in
            guard open else { return }
            UIRouter.shared.demoOpenPicker = false
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { pickingFor = entries.first }
        }
        .sheet(item: $pickingFor, onDismiss: { draftSound = "" }) { entry in
            SoundPickerSheet(selection: soundBinding(for: entry),
                             volume: volume(for: entry),
                             onDone: { commitDraft(for: entry) })
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("App sounds").font(.largeTitle.weight(.bold))
            Text("Pick the sound each app plays for its notifications. For anything more specific, such as one channel, a person or a keyword, add a rule.")
                .font(.title3)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var notificationNote: some View {
        VStack(alignment: .leading, spacing: 10) {
            let names = attentionNames
            if !names.isEmpty {
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.title3)
                        .foregroundStyle(.orange)
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Still playing their own sound: \(names.joined(separator: ", "))")
                            .font(.headline)
                        Text("Trill couldn't turn these off, or can't see their setting. To hear only Trill's sound, turn off \"Play sound for notification\" for each in System Settings → Notifications.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        Button("Open Notification Settings…") { SystemLinks.openNotificationSettings() }
                            .controlSize(.small)
                            .padding(.top, 2)
                    }
                    Spacer(minLength: 0)
                }
                .contentCard()
            }
            Text("Some apps, such as Slack and Discord, play their notification sound themselves. Turn that off in the app's own preferences.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func soundBinding(for entry: AppSoundEntry) -> Binding<String> {
        Binding(
            get: {
                if let i = state.defaultRuleIndex(for: entry) {
                    if case .sound(let id) = state.rules[i].action { return id }
                    return ""
                }
                return draftSound
            },
            set: { new in
                // An app that already has a default changes it live; otherwise nothing is created until Done.
                if state.defaultRuleIndex(for: entry) != nil { state.setDefaultSound(new, for: entry) }
                else { draftSound = new }
            }
        )
    }

    private func commitDraft(for entry: AppSoundEntry) {
        defer { draftSound = "" }
        guard !draftSound.isEmpty, state.defaultRuleIndex(for: entry) == nil,
              state.sound(withID: draftSound) != nil else { return }
        state.setDefaultSound(draftSound, for: entry)
    }

    private func volume(for entry: AppSoundEntry) -> Double {
        state.defaultRuleIndex(for: entry).map { state.rules[$0].volume } ?? 1.0
    }
}

// MARK: - Row

private struct AppSoundRow: View {
    let entry: AppSoundEntry
    let choose: () -> Void
    @ObservedObject private var state = AppState.shared
    @ObservedObject private var router = UIRouter.shared

    private var index: Int? { state.defaultRuleIndex(for: entry) }
    private var rule: Rule? { index.map { state.rules[$0] } }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .center, spacing: 14) {
                AppIconView(image: AppIcons.icon(forBundleID: entry.bundleID), size: 44)
                    .opacity(rule?.isEnabled == false ? 0.5 : 1)
                VStack(alignment: .leading, spacing: 5) {
                    Text(entry.name).font(.headline)
                    soundButton
                }
                Spacer(minLength: 8)
                if let rule {
                    controls(rule)
                }
            }
            ownSoundLine
            if let note = state.previewNote, rule?.action.kind == .shortcut {
                Text(note).font(.caption).foregroundStyle(.secondary)
            }
            HStack {
                Button {
                    router.selectedRuleID = state.addRule(above: entry)
                } label: {
                    Label("Add a rule for a channel, person or keyword…", systemImage: "plus.circle")
                        .font(.callout)
                }
                .buttonStyle(.link)
                Spacer()
                if let i = index {
                    Menu {
                        Button("Open default rule") { router.selectedRuleID = state.rules[i].id }
                        Divider()
                        Button("Remove default sound", role: .destructive) {
                            state.rules.remove(at: i)   // AppState gives back a muted own sound
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()
                    .help("More")
                }
            }
        }
        .contentCard()
    }

    // MARK: The app's own sound

    @ViewBuilder private var ownSoundLine: some View {
        let name = entry.possessiveName
        HStack(spacing: 6) {
            if let notice = state.ownSoundNotices[entry.id] {
                switch notice {
                case .working(let text):
                    ProgressView().controlSize(.small)
                    Text(text)
                case .turnedOff(let ids):
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                    Text("\(name) own sound turned off")
                    Button("Undo") { state.turnOnOwnSound(for: entry, ids: ids, undo: true) }
                        .buttonStyle(.link)
                case .restored:
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                    Text("\(name) own sound turned back on")
                case .failed(let message):
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    Text(message).lineLimit(2).fixedSize(horizontal: false, vertical: true)
                    Button("Open Notification Settings…") { SystemLinks.openNotificationSettings() }
                        .buttonStyle(.link)
                }
            } else {
                switch state.systemSoundState(for: entry.systemIDs) {
                case .on:
                    Image(systemName: "speaker.wave.2").foregroundStyle(.secondary)
                    Text("\(name) own sound: On ·")
                    Button("Turn off") { state.turnOffOwnSound(for: entry) }
                        .buttonStyle(.link)
                case .off:
                    Image(systemName: "speaker.slash").foregroundStyle(.secondary)
                    Text("Own sound off")
                case .unknown:
                    if rule != nil {
                        Image(systemName: "questionmark.circle").foregroundStyle(.secondary)
                        Text("\(name) own sound: unknown ·")
                        Button("Open Notification Settings…") { SystemLinks.openNotificationSettings() }
                            .buttonStyle(.link)
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .font(.callout)
        .foregroundStyle(.secondary)
    }

    // MARK: Sound and controls

    private var soundButton: some View {
        Button(action: choose) {
            HStack(spacing: 6) {
                Image(systemName: rule == nil ? "plus" : "speaker.wave.2.fill")
                    .font(.callout)
                Text(soundTitle)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .foregroundStyle(rule == nil ? Color.accentColor : Color.primary)
            .padding(.horizontal, 10).padding(.vertical, 5)
            .background(Color.primary.opacity(0.07), in: Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help(rule == nil ? "Choose a sound for \(entry.name)" : "Change sound")
    }

    private var soundTitle: String {
        guard let rule else { return "Choose a sound…" }
        switch rule.action {
        case .sound(let id): return state.sound(withID: id)?.name ?? "Missing sound"
        default: return state.summary(of: rule.action)
        }
    }

    /// Play button, volume (icon, slider, percent) and switch share one centred line and fixed widths.
    @ViewBuilder private func controls(_ rule: Rule) -> some View {
        HStack(alignment: .center, spacing: 14) {
            Button {
                state.preview(action: rule.action, volume: rule.volume, sample: nil)
            } label: {
                Image(systemName: "play.fill")
                    .frame(width: 18, height: 18)
            }
            .glassButton()
            .help("Preview")
            .disabled(rule.action.kind == .silent)

            HStack(alignment: .center, spacing: 8) {
                Image(systemName: "speaker.fill")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(width: 16)
                Slider(value: volumeBinding, in: 0...2)
                    .frame(width: 120)
                    .labelsHidden()
                Text("\(Int((rule.volume * 100).rounded()))%")
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(width: 44, alignment: .trailing)
            }
            .help("Volume (up to 200%)")

            Toggle("Enabled", isOn: enabledBinding)
                .labelsHidden()
                .toggleStyle(.switch)
                .help(rule.isEnabled ? "Turn this default off" : "Turn this default on")
        }
    }

    private var volumeBinding: Binding<Double> {
        Binding(get: { rule?.volume ?? 1 },
                set: { v in if let i = index { state.rules[i].volume = wholePercent(v) } })
    }

    private var enabledBinding: Binding<Bool> {
        Binding(get: { rule?.isEnabled ?? false },
                set: { v in
                    guard let i = index else { return }
                    state.rules[i].isEnabled = v
                    if v { state.muteOwnSoundIfNeeded(for: entry) }   // turning it off is handled centrally by AppState
                })
    }
}

extension AppSoundEntry {
    /// "Teams'" / "Mail's", for "Mail's own sound".
    var possessiveName: String { name.hasSuffix("s") ? "\(name)'" : "\(name)'s" }
}

/// Rounds a slider value to a whole percent (the slider itself has no `step`, which would draw 200 ticks).
func wholePercent(_ v: Double) -> Double { (v * 100).rounded() / 100 }

// MARK: - App chooser

struct AppChooserPopover: View {
    let onPick: (AppInfo) -> Void
    @ObservedObject private var catalog = AppCatalog.shared
    @State private var search = ""

    private var filtered: [AppInfo] {
        let q = search.trimmingCharacters(in: .whitespaces)
        if q.isEmpty { return catalog.apps }
        return catalog.apps.filter { $0.name.localizedCaseInsensitiveContains(q) || $0.bundleID.localizedCaseInsensitiveContains(q) }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search apps", text: $search).textFieldStyle(.plain)
            }
            .fieldChrome()
            .padding(10)
            List(filtered) { app in
                Button { onPick(app) } label: {
                    HStack(spacing: 10) {
                        AppIconView(image: AppIcons.icon(forBundleID: app.bundleID), size: 24)
                        Text(app.name)
                        Spacer()
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            .listStyle(.plain)
        }
        .frame(width: 320, height: 400)
        .task { catalog.loadIfNeeded() }
    }
}
