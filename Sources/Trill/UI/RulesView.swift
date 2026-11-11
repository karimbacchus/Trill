import SwiftUI
import TrillCore

struct RulesView: View {
    @ObservedObject private var state = AppState.shared
    @ObservedObject private var router = UIRouter.shared

    var body: some View {
        VStack(spacing: 0) {
            if !state.isAccessibilityTrusted {
                OnboardingCard()
                Divider()
            }
            NavigationSplitView {
                sidebar
                    .navigationSplitViewColumnWidth(min: 240, ideal: 290, max: 380)
            } detail: {
                detail
            }
        }
        .frame(minWidth: 820, minHeight: 520)
        .toolbar {
            ToolbarItemGroup {
                Button(action: addRule) { Label("New Rule", systemImage: "plus") }
                    .keyboardShortcut("n", modifiers: .command)
                    .help("New rule (⌘N)")
                Button(action: duplicateSelected) { Label("Duplicate", systemImage: "plus.square.on.square") }
                    .disabled(selectedIndex == nil)
                    .help("Duplicate rule")
                Button(action: deleteSelected) { Label("Delete", systemImage: "trash") }
                    .disabled(selectedIndex == nil)
                    .help("Delete rule")
            }
        }
    }

    // MARK: Sidebar

    private var sidebar: some View {
        List(selection: $router.selectedRuleID) {
            ForEach($state.rules) { $rule in
                RuleRow(rule: $rule)
                    .contextMenu {
                        Button("Duplicate") { duplicate(id: rule.id) }
                        Button(rule.isEnabled ? "Disable" : "Enable") { rule.isEnabled.toggle() }
                        Divider()
                        Button("Delete", role: .destructive) { delete(id: rule.id) }
                    }
            }
            .onMove { state.rules.move(fromOffsets: $0, toOffset: $1) }
            .onDelete { state.rules.remove(atOffsets: $0) }
        }
        .onDeleteCommand(perform: deleteSelected)
        .overlay {
            if state.rules.isEmpty {
                Text("No rules yet")
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: Detail

    @ViewBuilder private var detail: some View {
        if let id = router.selectedRuleID, state.rules.contains(where: { $0.id == id }) {
            RuleEditor(rule: binding(for: id))
                .id(id)
        } else if state.rules.isEmpty {
            EmptyRulesView(addRule: addRule, addExamples: addExamples)
        } else {
            VStack(spacing: 8) {
                Image(systemName: "list.bullet.rectangle")
                    .font(.system(size: 36))
                    .foregroundStyle(.tertiary)
                Text("Select a rule to edit it")
                    .foregroundStyle(.secondary)
                Text("Rules are checked from top to bottom; the first match wins.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    // MARK: Helpers

    private var selectedIndex: Int? {
        guard let id = router.selectedRuleID else { return nil }
        return state.rules.firstIndex { $0.id == id }
    }

    private func binding(for id: UUID) -> Binding<Rule> {
        Binding(
            get: { state.rules.first { $0.id == id } ?? Rule.placeholder },
            set: { newValue in
                if let i = state.rules.firstIndex(where: { $0.id == id }) { state.rules[i] = newValue }
            }
        )
    }

    private func addRule() {
        let rule = Rule(id: UUID(), name: "New Rule", isEnabled: true, appFilter: nil, query: "",
                        action: .sound(soundID: state.soundID(preferring: ["system:Glass", "builtin:chime-up"])),
                        volume: 1.0)
        state.rules.append(rule)
        router.selectedRuleID = rule.id
    }

    private func duplicateSelected() {
        if let id = router.selectedRuleID { duplicate(id: id) }
    }

    private func duplicate(id: UUID) {
        guard let i = state.rules.firstIndex(where: { $0.id == id }) else { return }
        var copy = state.rules[i]
        copy.id = UUID()
        copy.name += " Copy"
        state.rules.insert(copy, at: i + 1)
        router.selectedRuleID = copy.id
    }

    private func deleteSelected() {
        if let id = router.selectedRuleID { delete(id: id) }
    }

    private func delete(id: UUID) {
        guard let i = state.rules.firstIndex(where: { $0.id == id }) else { return }
        state.rules.remove(at: i)
        if router.selectedRuleID == id {
            router.selectedRuleID = state.rules.isEmpty ? nil : state.rules[min(i, state.rules.count - 1)].id
        }
    }

    private func addExamples() {
        let examples: [Rule] = [
            Rule(id: UUID(), name: "Slack incidents", isEnabled: true,
                 appFilter: "com.tinyspeck.slackmacgap", query: "#incident-* OR #prod-*",
                 action: .sound(soundID: state.soundID(preferring: ["builtin:alarm", "system:Sosumi"])),
                 volume: 1.5),
            Rule(id: UUID(), name: "Urgent keywords", isEnabled: true, appFilter: nil,
                 query: "urgent OR outage OR \"on fire\"",
                 action: .speak(voiceID: nil, template: "{app}: {title}. {body}"), volume: 1.0),
            Rule(id: UUID(), name: "Messages", isEnabled: true, appFilter: "com.apple.MobileSMS", query: "",
                 action: .sound(soundID: state.soundID(preferring: ["system:Pop", "builtin:chime-up"])),
                 volume: 1.0),
            Rule(id: UUID(), name: "Silence marketing mail", isEnabled: true, appFilter: "com.apple.mail",
                 query: "unsubscribe OR \"% off\" OR newsletter", action: .silent, volume: 1.0),
        ]
        state.rules.append(contentsOf: examples)
        router.selectedRuleID = examples.first?.id
    }
}

extension Rule {
    static let placeholder = Rule(id: UUID(), name: "", isEnabled: false, appFilter: nil, query: "",
                                  action: .silent, volume: 1.0)
}

private struct RuleRow: View {
    @Binding var rule: Rule
    @ObservedObject private var state = AppState.shared

    var body: some View {
        HStack(spacing: 8) {
            Toggle("Enabled", isOn: $rule.isEnabled)
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.mini)
            VStack(alignment: .leading, spacing: 2) {
                Text(rule.name.isEmpty ? "Untitled Rule" : rule.name)
                    .lineLimit(1)
                Label(state.summary(of: rule.action), systemImage: rule.action.kind.symbol)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .opacity(rule.isEnabled ? 1 : 0.5)
        }
        .padding(.vertical, 2)
    }
}

private struct EmptyRulesView: View {
    let addRule: () -> Void
    let addExamples: () -> Void

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "waveform.circle")
                .font(.system(size: 48))
                .foregroundStyle(.tertiary)
            Text("No rules yet").font(.title2)
            Text("A rule picks a sound (or speech, or a Shortcut) for notifications that match an app and a query.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .frame(maxWidth: 360)
            HStack {
                Button("New Rule", action: addRule)
                Button("Add Example Rules", action: addExamples)
            }
            .padding(.top, 4)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct OnboardingCard: View {
    @ObservedObject private var state = AppState.shared

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: "hand.raised.fill")
                .font(.system(size: 26))
                .foregroundStyle(Color.accentColor)
            VStack(alignment: .leading, spacing: 6) {
                Text("Trill needs Accessibility access")
                    .font(.headline)
                Text("To notice notification banners, Trill reads the on-screen text of the notification UI through the macOS Accessibility API. Everything is processed locally on this Mac; nothing is sent anywhere.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Text("After enabling Trill in System Settings, this banner disappears on its own.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            Spacer(minLength: 12)
            Button("Grant Access…") { state.requestAccessibilityPermission() }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
        }
        .padding(14)
        .background(Color.accentColor.opacity(0.10))
    }
}
