import SwiftUI
import TrillCore

struct RuleEditor: View {
    @Binding var rule: Rule
    @ObservedObject private var state = AppState.shared

    @State private var testText = ""
    @State private var showSyntaxHelp = false
    @State private var showSoundPicker = false
    @State private var shortcutNames: [String] = []

    var body: some View {
        Form {
            Section("Rule") {
                TextField("Name", text: $rule.name)
                LabeledContent("App") {
                    AppPickerButton(filter: $rule.appFilter)
                }
                Toggle("Enabled", isOn: $rule.isEnabled)
            }

            Section {
                queryField
                queryStatus
                TextField("Test against text", text: $testText,
                          prompt: Text("Paste a notification's text to try the query"))
                if !testText.isEmpty { testResult }
            } header: {
                Text("Match")
            } footer: {
                Text("Leave the query empty to match every notification from the chosen app.")
            }

            Section("Action") {
                Picker("Action", selection: kindBinding) {
                    ForEach(ActionKind.allCases) { kind in
                        Text(kind.title).tag(kind)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                actionEditor
            }

            if rule.action.kind != .silent {
                Section("Playback") {
                    volumeRow
                    HStack {
                        Button {
                            state.preview(action: rule.action, volume: rule.volume, sample: nil)
                        } label: {
                            Label("Preview", systemImage: "play.fill")
                        }
                        Button {
                            state.stopPreview()
                        } label: {
                            Label("Stop", systemImage: "stop.fill")
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle(rule.name.isEmpty ? "Rule" : rule.name)
    }

    // MARK: Query

    private var queryField: some View {
        HStack {
            TextField("Query", text: $rule.query,
                      prompt: Text("e.g. #prod-* OR deploy NOT failed"))
                .font(.body.monospaced())
                .autocorrectionDisabled()
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

    @ViewBuilder private var testResult: some View {
        let sample = makeNotification(appName: rule.appFilter ?? "", title: testText)
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
            LabeledContent("Sound") {
                HStack {
                    Text(state.sound(withID: soundID)?.name ?? "Missing sound")
                        .foregroundStyle(state.sound(withID: soundID) == nil ? .red : .primary)
                    Button("Choose…") { showSoundPicker = true }
                }
            }
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
                .font(.body.monospaced())
            Text("Placeholders: {app}  {title}  {subtitle}  {body}")
                .font(.caption)
                .foregroundStyle(.secondary)
        case .shortcut(let name):
            HStack {
                TextField("Shortcut name", text: shortcutBinding)
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

    // MARK: Volume

    private var volumeRow: some View {
        LabeledContent("Volume") {
            HStack(spacing: 8) {
                Slider(value: $rule.volume, in: 0...2, step: 0.01)
                    .background(alignment: .center) {
                        // Marker at 100%.
                        Capsule()
                            .fill(Color.secondary.opacity(0.6))
                            .frame(width: 2, height: 12)
                            .offset(y: 0)
                            .allowsHitTesting(false)
                    }
                    .frame(minWidth: 160)
                Text("\(Int((rule.volume * 100).rounded()))%")
                    .monospacedDigit()
                    .frame(width: 44, alignment: .trailing)
                Button("100%") { rule.volume = 1.0 }
                    .buttonStyle(.borderless)
                    .font(.caption)
                    .disabled(abs(rule.volume - 1.0) < 0.005)
                    .help("Reset to 100%")
            }
        }
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
        .task { if apps.isEmpty { apps = state.installedApps() } }
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
