import SwiftUI
import TrillCore

struct RuleEditor: View {
    @Binding var rule: Rule
    @ObservedObject private var state = AppState.shared
    @ObservedObject private var catalog = AppCatalog.shared
    @ObservedObject private var router = UIRouter.shared

    @State private var testText = ""
    @State private var showSyntaxHelp = false
    @State private var showSoundPicker = false
    @State private var shortcutNames: [String] = []
    @FocusState private var queryFocused: Bool

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                header
                matchCard
                actionCard
            }
            .padding(24)
            .frame(maxWidth: 760, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if rule.action.kind != .silent {
                playbackBar
                    .padding(.horizontal, 24)
                    .padding(.bottom, 14)
                    .padding(.top, 6)
            }
        }
        .navigationTitle(rule.name.isEmpty ? "Rule" : rule.name)
        .task { catalog.loadIfNeeded() }
        .onAppear {
            if router.focusQueryRuleID == rule.id {
                router.focusQueryRuleID = nil
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { queryFocused = true }
            }
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(alignment: .center, spacing: 14) {
            AppIconView(image: catalog.icon(forFilter: rule.appFilter), size: 52)
                .opacity(rule.isEnabled ? 1 : 0.45)
            VStack(alignment: .leading, spacing: 4) {
                TextField("Rule name", text: $rule.name, prompt: Text("Untitled Rule"))
                    .textFieldStyle(.plain)
                    .font(.system(size: 22, weight: .semibold))
                HStack(spacing: 6) {
                    Text("For notifications from").foregroundStyle(.secondary)
                    AppPickerButton(filter: $rule.appFilter)
                }
                .font(.callout)
            }
            Spacer(minLength: 12)
            Toggle(isOn: $rule.isEnabled) { Text(rule.isEnabled ? "On" : "Off") }
                .toggleStyle(.switch)
                .help(rule.isEnabled ? "Turn this rule off" : "Turn this rule on")
        }
    }

    // MARK: Cards

    private func cardTitle(_ title: String, _ symbol: String) -> some View {
        Label(title, systemImage: symbol)
            .font(.headline)
    }

    private var matchCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            cardTitle("When the notification contains", "magnifyingglass")
            queryField
            queryStatus
            HStack(spacing: 8) {
                Image(systemName: "testtube.2").foregroundStyle(.secondary)
                TextField("Test against text", text: $testText,
                          prompt: Text("Paste a notification's text to try the query"))
                    .textFieldStyle(.plain)
                if !testText.isEmpty { testResult.font(.callout) }
            }
            .font(.callout)
            Text("Leave the query empty to match every notification from the chosen app.")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentCard()
    }

    private var actionCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            cardTitle("Then", "bolt.fill")
            Picker("Action", selection: kindBinding) {
                ForEach(ActionKind.allCases) { kind in
                    Label(kind.title, systemImage: kind.symbol).tag(kind)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .controlSize(.large)
            actionEditor
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentCard()
    }

    /// Floating control layer: volume and preview stay in reach while the form scrolls beneath.
    private var playbackBar: some View {
        GlassGroup(spacing: 12) {
            HStack(spacing: 14) {
                HStack(spacing: 10) {
                    Image(systemName: "speaker.fill").foregroundStyle(.secondary)
                    Slider(value: Binding(get: { rule.volume }, set: { rule.volume = wholePercent($0) }), in: 0...2)
                        .labelsHidden()
                        .background(alignment: .center) {
                            // 100% marker: the range is symmetric, so it sits at the exact centre; it is
                            // taller than the track so it shows above and below it.
                            Capsule()
                                .fill(Color.secondary.opacity(0.6))
                                .frame(width: 2, height: 16)
                                .allowsHitTesting(false)
                        }
                    Image(systemName: "speaker.wave.3.fill").foregroundStyle(.secondary)
                    Text("\(Int((rule.volume * 100).rounded()))%")
                        .font(.body.monospacedDigit())
                        .frame(width: 48, alignment: .trailing)
                    Button { rule.volume = 1.0 } label: { Image(systemName: "arrow.counterclockwise") }
                        .buttonStyle(.borderless)
                        .disabled(abs(rule.volume - 1.0) < 0.005)
                        .help("Reset to 100%")
                }
                .padding(.horizontal, 16).padding(.vertical, 10)
                .glassCard(cornerRadius: 22)

                HStack(spacing: 8) {
                    Button {
                        state.stopPreview()
                    } label: {
                        Image(systemName: "stop.fill")
                    }
                    .glassButton()
                    .help("Stop")
                    Button {
                        state.preview(action: rule.action, volume: rule.volume, sample: nil)
                    } label: {
                        Label("Preview", systemImage: "play.fill")
                    }
                    .glassButton(prominent: true)
                    .keyboardShortcut("p", modifiers: .command)
                    .help("Preview (⌘P)")
                }
                .controlSize(.large)
                if let note = state.previewNote {
                    Text(note).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }

    // MARK: Query

    private var queryField: some View {
        HStack(spacing: 8) {
            TextField("Query", text: $rule.query,
                      prompt: Text("e.g. #prod-* OR deploy NOT failed"))
                .textFieldStyle(.plain)
                .font(.system(size: 16, design: .monospaced))
                .autocorrectionDisabled()
                .focused($queryFocused)
            Button {
                showSyntaxHelp.toggle()
            } label: {
                Image(systemName: "questionmark.circle")
            }
            .buttonStyle(.borderless)
            .help("Query syntax")
            .popover(isPresented: $showSyntaxHelp, arrowEdge: .bottom) {
                QuerySyntaxHelp()
            }
        }
        .fieldChrome(isInvalid: QueryExpression.validate(rule.query) != nil)
    }

    @ViewBuilder private var queryStatus: some View {
        if let message = QueryExpression.validate(rule.query) {
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
                .font(.callout)
        } else if rule.query.trimmingCharacters(in: .whitespaces).isEmpty {
            Label("Matches every notification", systemImage: "infinity")
                .foregroundStyle(.secondary)
                .font(.callout)
        } else {
            Label("Query is valid", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
                .font(.callout)
        }
    }

    /// The pasted text stands in for the title and the body (so `title:`, `body:` and bare terms all see it),
    /// and the rule's own app is the sending app (so `app:` terms work).
    private var testSample: CapturedNotification {
        let filter = rule.appFilter?.trimmingCharacters(in: .whitespaces) ?? ""
        let known = catalog.info(forFilter: filter)
        let name = known?.name ?? (filter.contains(".") ? "" : filter)
        let bundle = known?.bundleID ?? (filter.contains(".") ? filter : nil)
        return makeNotification(appName: name, bundleID: bundle, title: testText, subtitle: "", body: testText)
    }

    @ViewBuilder private var testResult: some View {
        let sample = testSample
        if let expression = try? QueryExpression(parsing: rule.query) {
            if expression.matches(sample) {
                Label("Matches this text", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
            } else {
                Label("Does not match this text", systemImage: "xmark.circle.fill").foregroundStyle(.red)
            }
        } else {
            Label("Fix the query to test it", systemImage: "exclamationmark.triangle")
                .foregroundStyle(.secondary)
        }
    }

    // MARK: Action

    private var kindBinding: Binding<ActionKind> {
        Binding(
            get: { rule.action.kind },
            set: { newKind in
                guard newKind != rule.action.kind else { return }
                switch newKind {
                case .sound:
                    rule.action = .sound(soundID: state.soundID(preferring: ["system:Glass", "builtin:chime-up"]))
                case .speak:
                    rule.action = .speak(voiceID: nil, template: "{title}. {body}")
                case .shortcut:
                    rule.action = .shortcut(name: "")
                case .silent:
                    rule.action = .silent
                }
            }
        )
    }

    @ViewBuilder private var actionEditor: some View {
        switch rule.action {
        case .sound(let soundID):
            Button { showSoundPicker = true } label: {
                HStack(spacing: 10) {
                    Image(systemName: "speaker.wave.2.fill").foregroundStyle(Color.accentColor)
                    Text(state.sound(withID: soundID)?.name ?? "Missing sound")
                        .foregroundStyle(state.sound(withID: soundID) == nil ? Color.red : Color.primary)
                    Spacer()
                    Text("Choose…").foregroundStyle(.secondary)
                    Image(systemName: "chevron.up.chevron.down").font(.caption2).foregroundStyle(.secondary)
                }
                .font(.body)
                .fieldChrome()
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .sheet(isPresented: $showSoundPicker) {
                SoundPickerSheet(selection: soundIDBinding, volume: rule.volume)
            }
        case .speak(let voiceID, let template):
            let voices = state.voices
            Picker("Voice", selection: voiceBinding) {
                Text("System default").tag(String?.none)
                ForEach(voices) { voice in
                    Text("\(voice.name) (\(voice.language))").tag(String?.some(voice.id))
                }
            }
            .id(voiceID ?? "")
            TextField("Template", text: templateBinding(current: template))
                .textFieldStyle(.plain)
                .font(.body.monospaced())
                .fieldChrome()
            Text("Placeholders: {app}  {title}  {subtitle}  {body}")
                .font(.caption)
                .foregroundStyle(.secondary)
        case .shortcut(let name):
            HStack {
                TextField("Shortcut name", text: shortcutBinding)
                    .textFieldStyle(.plain)
                    .fieldChrome()
                Menu {
                    if shortcutNames.isEmpty {
                        Text("No shortcuts found")
                    }
                    ForEach(shortcutNames, id: \.self) { n in
                        Button(n) { rule.action = .shortcut(name: n) }
                    }
                } label: {
                    Image(systemName: "list.bullet")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .help("Choose from your Shortcuts")
            }
            .task { shortcutNames = await state.shortcutNames() }
            Text(name.isEmpty
                 ? "Runs a Shortcut with the notification text as input."
                 : "Runs “\(name)” with the notification text as input.")
                .font(.caption)
                .foregroundStyle(.secondary)
        case .silent:
            Text("Notifications matching this rule are recognised but make no sound. Use it to mute noisy ones before later rules can match.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }

    private var soundIDBinding: Binding<String> {
        Binding(
            get: { if case .sound(let id) = rule.action { return id } else { return "" } },
            set: { rule.action = .sound(soundID: $0) }
        )
    }

    private var voiceBinding: Binding<String?> {
        Binding(
            get: { if case .speak(let v, _) = rule.action { return v } else { return nil } },
            set: { newVoice in
                if case .speak(_, let t) = rule.action { rule.action = .speak(voiceID: newVoice, template: t) }
            }
        )
    }

    private func templateBinding(current: String) -> Binding<String> {
        Binding(
            get: { if case .speak(_, let t) = rule.action { return t } else { return current } },
            set: { newTemplate in
                if case .speak(let v, _) = rule.action { rule.action = .speak(voiceID: v, template: newTemplate) }
            }
        )
    }

    private var shortcutBinding: Binding<String> {
        Binding(
            get: { if case .shortcut(let n) = rule.action { return n } else { return "" } },
            set: { rule.action = .shortcut(name: $0) }
        )
    }
}

private struct QuerySyntaxHelp: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Query syntax").font(.headline)
            Group {
                row("deploy", "contains the word (case-insensitive)")
                row("\"build failed\"", "contains the exact phrase")
                row("#prod-*", "* matches any run of characters")
                row("a AND b", "both (also implied by a space)")
                row("a OR b", "either")
                row("NOT a", "does not contain")
                row("( a OR b ) c", "group with parentheses")
                row("title: subtitle: body: app:", "limit a term to one field, e.g. title:deploy")
            }
            Text("AND, OR and NOT must be uppercase. An empty query matches everything.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(16)
        .frame(width: 380)
    }

    private func row(_ code: String, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(code)
                .font(.system(.callout, design: .monospaced))
                .frame(width: 150, alignment: .leading)
            Text(text).font(.callout).foregroundStyle(.secondary)
            Spacer(minLength: 0)
        }
    }
}

// MARK: - App picker

private struct AppPickerButton: View {
    @Binding var filter: String?
    @ObservedObject private var state = AppState.shared
    @State private var showing = false
    @State private var apps: [AppInfo] = []
    @State private var search = ""

    var body: some View {
        Button {
            showing = true
        } label: {
            HStack(spacing: 6) {
                if let current = currentApp {
                    Image(nsImage: AppIcons.icon(forBundleID: current.bundleID))
                        .resizable().frame(width: 16, height: 16)
                    Text(current.name)
                } else if let f = filter, !f.isEmpty {
                    Image(systemName: "app.dashed")
                    Text(f)
                } else {
                    Image(systemName: "square.grid.2x2")
                    Text("Any app")
                }
                Image(systemName: "chevron.up.chevron.down").font(.caption2).foregroundStyle(.secondary)
            }
        }
        .popover(isPresented: $showing, arrowEdge: .bottom) { picker }
        .task { apps = state.installedApps() }
        .onReceive(NotificationCenter.default.publisher(for: InstalledApps.didUpdate)) { _ in
            apps = state.installedApps()
        }
    }

    private var currentApp: AppInfo? {
        guard let f = filter?.lowercased(), !f.isEmpty else { return nil }
        return apps.first { $0.bundleID.lowercased() == f || $0.name.lowercased() == f }
    }

    private var filtered: [AppInfo] {
        let q = search.trimmingCharacters(in: .whitespaces)
        if q.isEmpty { return apps }
        return apps.filter { $0.name.localizedCaseInsensitiveContains(q) || $0.bundleID.localizedCaseInsensitiveContains(q) }
    }

    private var picker: some View {
        VStack(spacing: 0) {
            TextField("Search apps", text: $search)
                .textFieldStyle(.roundedBorder)
                .padding(10)
            Divider()
            List {
                Button {
                    filter = nil
                    showing = false
                } label: {
                    HStack {
                        Image(systemName: "square.grid.2x2").frame(width: 20)
                        Text("Any app")
                        Spacer()
                        if filter == nil { Image(systemName: "checkmark") }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                ForEach(filtered) { app in
                    Button {
                        filter = app.bundleID
                        showing = false
                    } label: {
                        HStack {
                            Image(nsImage: AppIcons.icon(forBundleID: app.bundleID))
                                .resizable().frame(width: 20, height: 20)
                            VStack(alignment: .leading, spacing: 0) {
                                Text(app.name)
                                Text(app.bundleID).font(.caption2).foregroundStyle(.secondary)
                            }
                            Spacer()
                            if currentApp?.bundleID == app.bundleID { Image(systemName: "checkmark") }
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            if !search.isEmpty && filtered.isEmpty {
                Divider()
                Button("Use “\(search)” as app name") {
                    filter = search
                    showing = false
                }
                .padding(8)
            }
        }
        .frame(width: 320, height: 400)
    }
}
