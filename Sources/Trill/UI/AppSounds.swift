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
    var id: String { bundleID }

    init(name: String, bundleID: String, otherBundleIDs: [String] = []) {
        self.name = name
        self.bundleID = bundleID
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

    /// Updates the app's default rule, or appends a new one at the END so specific rules above win.
    func setDefaultSound(_ soundID: String, for entry: AppSoundEntry) {
        if let i = defaultRuleIndex(for: entry) {
            rules[i].action = .sound(soundID: soundID)
            rules[i].isEnabled = true
        } else {
            rules.append(Rule(name: "\(entry.name) — default", appFilter: entry.bundleID, query: "",
                              action: .sound(soundID: soundID), volume: 1.0))
        }
    }

    /// New rule for the app, placed just above its default (or at the end if it has none yet).
    @discardableResult
    func addRule(above entry: AppSoundEntry) -> UUID {
        let index = defaultRuleIndex(for: entry) ?? rules.count
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
        .onReceive(UIRouter.shared.$demoOpenPicker) { open in
            guard open else { return }
            UIRouter.shared.demoOpenPicker = false
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { pickingFor = entries.first }
        }
        .sheet(item: $pickingFor) { entry in
            SoundPickerSheet(selection: soundBinding(for: entry),
                             volume: volume(for: entry))
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
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "info.circle.fill")
                .font(.title3)
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 6) {
                Text("The app's own sound keeps playing")
                    .font(.headline)
                Text("Trill adds its sound on top. To hear only Trill's, turn the app's notification sound off in System Settings → Notifications.")
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

    private func soundBinding(for entry: AppSoundEntry) -> Binding<String> {
        Binding(
            get: {
                if let i = state.defaultRuleIndex(for: entry), case .sound(let id) = state.rules[i].action { return id }
                return ""
            },
            set: { state.setDefaultSound($0, for: entry) }
        )
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
            HStack(spacing: 14) {
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
                        Button("Remove default sound", role: .destructive) { state.rules.remove(at: i) }
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

    @ViewBuilder private func controls(_ rule: Rule) -> some View {
        HStack(spacing: 12) {
            Button {
                state.preview(action: rule.action, volume: rule.volume, sample: nil)
            } label: {
                Image(systemName: "play.fill")
            }
            .glassButton()
            .help("Preview")
            .disabled(rule.action.kind == .silent)

            HStack(spacing: 6) {
                Image(systemName: "speaker.fill").font(.caption).foregroundStyle(.secondary)
                Slider(value: volumeBinding, in: 0...2, step: 0.01)
                    .frame(width: 110)
                Text("\(Int((rule.volume * 100).rounded()))%")
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(width: 42, alignment: .trailing)
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
                set: { v in if let i = index { state.rules[i].volume = v } })
    }

    private var enabledBinding: Binding<Bool> {
        Binding(get: { rule?.isEnabled ?? false },
                set: { v in if let i = index { state.rules[i].isEnabled = v } })
    }
}

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
