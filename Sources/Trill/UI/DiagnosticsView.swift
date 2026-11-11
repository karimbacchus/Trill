import SwiftUI
import AppKit
import TrillCore

struct DiagnosticsView: View {
    @ObservedObject private var state = AppState.shared
    @Environment(\.openWindow) private var openWindow

    @State private var selection = Set<LogEntry.ID>()
    @State private var testApp = "Test App"
    @State private var testTitle = "Hello from Trill"
    @State private var testSubtitle = ""
    @State private var testBody = "This is a test notification."
    @State private var copied = false

    var body: some View {
        VStack(spacing: 14) {
            statusCard
            logSection
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            testSection
                .padding(.horizontal, 16)
                .padding(.bottom, 14)
                .padding(.top, 6)
        }
        .frame(minWidth: 780, minHeight: 560)
        .navigationTitle("Diagnostics")
        .toolbar {
            ToolbarItemGroup {
                Button {
                    createRule(from: selectedEntries.first)
                } label: {
                    Label("Create Rule for This", systemImage: "plus.circle")
                }
                .disabled(selectedEntries.isEmpty)
                .help("Create a rule from the selected notification")
                Button {
                    state.clearLog()
                    selection.removeAll()
                } label: {
                    Label("Clear", systemImage: "trash")
                }
                .disabled(state.log.isEmpty)
                .help("Clear the list")
            }
        }
    }

    // MARK: Status

    private var statusCard: some View {
        let ok = state.isAccessibilityTrusted
        return HStack(alignment: .center, spacing: 14) {
            Image(systemName: ok ? "checkmark.shield.fill" : "exclamationmark.shield.fill")
                .font(.system(size: 30))
                .foregroundStyle(ok ? Color.green : Color.orange)
            VStack(alignment: .leading, spacing: 2) {
                Text(ok ? "Accessibility access granted" : "Accessibility access not granted")
                    .font(.headline)
                Text(state.watcherStatus)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
            Spacer()
            if !ok {
                Button("Grant Access…") { state.requestAccessibilityPermission() }
                    .glassButton(prominent: true)
            }
            Button {
                let dump = state.accessibilityDump()
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(dump, forType: .string)
                copied = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) { copied = false }
            } label: {
                Label(copied ? "Copied" : "Copy AX Dump", systemImage: copied ? "checkmark" : "doc.on.clipboard")
            }
            .glassButton()
            .help("Copy a text dump of the notification UI's accessibility tree, for bug reports")
        }
        .padding(14)
        .background((ok ? Color.green : Color.orange).opacity(0.10),
                    in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
            .strokeBorder((ok ? Color.green : Color.orange).opacity(0.25)))
    }

    // MARK: Log

    private var logSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Text("Captured notifications").font(.headline)
                Text("\(state.log.count)")
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 7).padding(.vertical, 2)
                    .background(Color.primary.opacity(0.08), in: Capsule())
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 4)

            Table(state.log, selection: $selection) {
                TableColumn("Time") { entry in
                    Text(entry.notification.date, style: .time).monospacedDigit().foregroundStyle(.secondary)
                }
                .width(min: 60, ideal: 80, max: 100)
                TableColumn("App") { entry in
                    HStack(spacing: 6) {
                        AppIconView(image: AppIcons.icon(forBundleID: entry.notification.bundleID ?? ""), size: 18)
                        Text(appLabel(entry.notification))
                    }
                }
                .width(min: 100, ideal: 140)
                TableColumn("Title") { entry in
                    Text(entry.notification.title).fontWeight(.medium)
                }
                .width(min: 100, ideal: 160)
                TableColumn("Body") { entry in
                    Text(entry.notification.body).foregroundStyle(.secondary)
                }
                TableColumn("Matched rule") { entry in
                    if let name = entry.matchedRuleName {
                        VStack(alignment: .leading, spacing: 2) {
                            Label(name, systemImage: "checkmark.circle.fill")
                                .foregroundStyle(.green)
                                .labelStyle(.titleAndIcon)
                            if let warning = entry.warning {
                                Label(warning, systemImage: "exclamationmark.triangle.fill")
                                    .font(.caption)
                                    .foregroundStyle(.orange)
                            }
                        }
                    } else {
                        Text("No match").foregroundStyle(.tertiary)
                    }
                }
                .width(min: 120, ideal: 160)
            }
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.primary.opacity(0.08)))
            .contextMenu(forSelectionType: LogEntry.ID.self) { ids in
                if let entry = state.log.first(where: { ids.contains($0.id) }) {
                    Button("Create Rule for This") { createRule(from: entry) }
                }
            }
            .overlay {
                if state.log.isEmpty {
                    VStack(spacing: 6) {
                        Image(systemName: "tray").font(.system(size: 30)).foregroundStyle(.tertiary)
                        Text("No notifications captured yet").foregroundStyle(.secondary)
                        Text("Send a test notification below, or trigger a real one.")
                            .font(.caption).foregroundStyle(.tertiary)
                    }
                    .allowsHitTesting(false)
                }
            }
        }
    }

    private var selectedEntries: [LogEntry] {
        state.log.filter { selection.contains($0.id) }
    }

    private func appLabel(_ n: CapturedNotification) -> String {
        if !n.appName.isEmpty { return n.appName }
        return n.bundleID ?? "Unknown"
    }

    private func createRule(from entry: LogEntry?) {
        guard let entry else { return }
        let n = entry.notification
        let basis = n.title.isEmpty ? String(n.body.prefix(40)) : n.title
        let cleaned = basis.replacingOccurrences(of: "\"", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let appFilter: String? = {
            if let id = n.bundleID, !id.isEmpty { return id }
            return n.appName.isEmpty ? nil : n.appName
        }()
        let rule = Rule(
            id: UUID(),
            name: cleaned.isEmpty ? (n.appName.isEmpty ? "New Rule" : n.appName) : String(cleaned.prefix(40)),
            isEnabled: true,
            appFilter: appFilter,
            query: cleaned.isEmpty ? "" : "\"\(cleaned)\"",
            action: .sound(soundID: state.soundID(preferring: ["system:Glass", "builtin:chime-up"])),
            volume: 1.0
        )
        state.rules.insert(rule, at: 0)
        UIRouter.shared.selectedRuleID = rule.id
        AppActivation.open(WindowID.rules, using: openWindow)
    }

    // MARK: Test form

    /// Floating glass panel pinned to the bottom of the window.
    private var testSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Send test notification").font(.headline)
                    Text("Feeds a fake notification straight into the rule engine, bypassing Accessibility.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    state.sendTestNotification(
                        makeNotification(appName: testApp, bundleID: nil, title: testTitle,
                                         subtitle: testSubtitle, body: testBody))
                } label: {
                    Label("Send", systemImage: "paperplane.fill")
                }
                .glassButton(prominent: true)
                .controlSize(.large)
            }
            HStack(spacing: 8) {
                TextField("App", text: $testApp).frame(width: 130)
                TextField("Title", text: $testTitle)
                TextField("Subtitle", text: $testSubtitle).frame(width: 130)
                TextField("Body", text: $testBody)
            }
            .textFieldStyle(.roundedBorder)
        }
        .padding(14)
        .glassCard(cornerRadius: 20)
    }
}
