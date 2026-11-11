import SwiftUI
import TrillCore

private enum SidebarItem: Hashable {
    case appSounds
    case rule(UUID)
}

struct RulesView: View {
    @ObservedObject private var state = AppState.shared
    @ObservedObject private var router = UIRouter.shared
    @ObservedObject private var catalog = AppCatalog.shared

    var body: some View {
        NavigationSplitView {
            sidebar
                .navigationSplitViewColumnWidth(min: 250, ideal: 300, max: 400)
        } detail: {
            detail
                .safeAreaInset(edge: .top, spacing: 0) {
                    if !state.isAccessibilityTrusted {
                        OnboardingCard()
                            .padding([.horizontal, .top], 16)
                            .padding(.bottom, 4)
                    }
                }
        }
        .frame(minWidth: 860, minHeight: 540)
        .task { catalog.loadIfNeeded() }
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

    private var selection: Binding<SidebarItem?> {
        Binding(
            get: {
                if router.showAppSounds { return .appSounds }
                return router.selectedRuleID.map { .rule($0) }
            },
            set: { new in
                switch new {
                case .appSounds?: router.selectedRuleID = nil; router.showAppSounds = true
                case .rule(let id)?: router.selectedRuleID = id
                case nil: break
                }
            }
        )
    }

    private var sidebar: some View {
        List(selection: selection) {
            Section {
                HStack(spacing: 10) {
                    Image(systemName: "bell.badge.waveform.fill")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 30, height: 30)
                        .background(LinearGradient(colors: [.pink, .orange], startPoint: .topLeading, endPoint: .bottomTrailing),
                                    in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    VStack(alignment: .leading, spacing: 1) {
                        Text("App sounds").fontWeight(.semibold)
                        Text("One sound per app").font(.caption).foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 3)
                .tag(SidebarItem.appSounds)
            }

            Section("Rules") {
                ForEach($state.rules) { $rule in
                    RuleRow(rule: $rule)
                        .tag(SidebarItem.rule(rule.id))
                        .contextMenu {
                            Button("Duplicate") { duplicate(id: rule.id) }
                            Button(rule.isEnabled ? "Disable" : "Enable") { rule.isEnabled.toggle() }
                            Divider()
                            Button("Delete", role: .destructive) { delete(id: rule.id) }
                        }
                }
                .onMove { state.rules.move(fromOffsets: $0, toOffset: $1) }
                .onDelete { state.rules.remove(atOffsets: $0) }

                if state.rules.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("No rules yet").foregroundStyle(.secondary)
                        Button("Add Example Rules", action: addExamples).controlSize(.small)
                    }
                    .padding(.vertical, 4)
                }
            }
        }
        .onDeleteCommand(perform: deleteSelected)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            Button(action: addRule) {
                Label("New Rule", systemImage: "plus")
                    .frame(maxWidth: .infinity)
            }
            .glassButton()
            .controlSize(.large)
            .padding(12)
        }
    }

    // MARK: Detail

    @ViewBuilder private var detail: some View {
        if router.showAppSounds || router.selectedRuleID == nil {
            AppSoundsView()
        } else if let id = router.selectedRuleID, state.rules.contains(where: { $0.id == id }) {
            RuleEditor(rule: binding(for: id))
                .id(id)
        } else {
            AppSoundsView()
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
    @ObservedObject private var catalog = AppCatalog.shared

    private var matchSummary: String {
        let query = rule.query.trimmingCharacters(in: .whitespacesAndNewlines)
        let app = rule.appFilter.map { $0.trimmingCharacters(in: .whitespaces) }.flatMap { $0.isEmpty ? nil : $0 }
        switch (app, query.isEmpty) {
        case (let a?, true): return "\(catalog.displayName(forFilter: a)) · everything"
        case (let a?, false): return "\(catalog.displayName(forFilter: a)) · \(query)"
        case (nil, true): return "Any app · everything"
        case (nil, false): return "Any app · \(query)"
        }
    }

    var body: some View {
        HStack(spacing: 10) {
            AppIconView(image: catalog.icon(forFilter: rule.appFilter), size: 30)
                .opacity(rule.isEnabled ? 1 : 0.4)
            VStack(alignment: .leading, spacing: 1) {
                Text(rule.name.isEmpty ? "Untitled Rule" : rule.name)
                    .fontWeight(.medium)
                    .lineLimit(1)
                Text(matchSummary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Label(state.summary(of: rule.action), systemImage: rule.action.kind.symbol)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
            .opacity(rule.isEnabled ? 1 : 0.5)
            Spacer(minLength: 0)
            if !rule.isEnabled {
                Image(systemName: "pause.circle").foregroundStyle(.tertiary).help("Disabled")
            }
        }
        .padding(.vertical, 3)
    }
}

struct OnboardingCard: View {
    @ObservedObject private var state = AppState.shared

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            Image(systemName: "hand.raised.fill")
                .font(.system(size: 24))
                .foregroundStyle(Color.accentColor)
            VStack(alignment: .leading, spacing: 4) {
                Text("Trill needs Accessibility access")
                    .font(.headline)
                Text("Trill reads the on-screen text of notification banners through the Accessibility API. Everything stays on this Mac. This banner disappears once access is granted.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            Button("Grant Access…") { state.requestAccessibilityPermission() }
                .glassButton(prominent: true)
                .controlSize(.large)
        }
        .padding(14)
        .glassCard(cornerRadius: 18, tint: Color.accentColor.opacity(0.12))
    }
}
