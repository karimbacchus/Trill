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
        VStack(spacing: 0) {
            statusSection
            Divider()
            logSection
            Divider()
            testSection
        }
        .frame(minWidth: 760, minHeight: 540)
    }

    // MARK: Status

    private var statusSection: some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: state.isAccessibilityTrusted ? "checkmark.shield.fill" : "exclamationmark.shield.fill")
                .font(.system(size: 28))
                .foregroundStyle(state.isAccessibilityTrusted ? Color.green : Color.orange)
            VStack(alignment: .leading, spacing: 2) {
                Text(state.isAccessibilityTrusted ? "Accessibility access granted" : "Accessibility access not granted")
                    .font(.headline)
                Text(state.watcherStatus)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
            Spacer()
            if !state.isAccessibilityTrusted {
                Button("Grant Access…") { state.requestAccessibilityPermission() }
                    .buttonStyle(.borderedProminent)
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
            .help("Copy a text dump of the notification UI's accessibility tree, for bug reports")
        }
        .padding(14)
    }

    // MARK: Log

    private var logSection: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Captured notifications").font(.headline)
                Text("(\(state.log.count))").foregroundStyle(.secondary)
                Spacer()
                Button {
                    createRule(from: selectedEntries.first)
                } label: {
                    Label("Create Rule for This", systemImage: "plus.circle")
                }
                .disabled(selectedEntries.isEmpty)
                Button {
                    state.clearLog()
                    selection.removeAll()
                } label: {
                    Label("Clear", systemImage: "trash")
                }
                .disabled(state.log.isEmpty)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)

            Table(state.log, selection: $selection) {
                TableColumn("Time") { entry in
                    Text(entry.notification.date, style: .time).monospacedDigit()
                }
                .width(min: 60, ideal: 80, max: 100)
                TableColumn("App") { entry in
                    Text(appLabel(entry.notification))
                }
                .width(min: 80, ideal: 120)
                TableColumn("Title") { entry in
                    Text(entry.notification.title)
                }
                .width(min: 100, ideal: 160)
                TableColumn("Body") { entry in
                    Text(entry.notification.body)
                }
                TableColumn("Matched rule") { entry in
                    if let name = entry.matchedRuleName {
                        Label(name, systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.primary)
                    } else {
                        Text("No match").foregroundStyle(.secondary)
                    }
                }
                .width(min: 100, ideal: 140)
            }
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

    private var testSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Send test notification").font(.headline)
            Text("Feeds a fake notification straight into the rule engine, bypassing Accessibility.")
                .font(.caption).foregroundStyle(.secondary)
            HStack(spacing: 8) {
                TextField("App", text: $testApp).frame(width: 130)
                TextField("Title", text: $testTitle)
                TextField("Subtitle", text: $testSubtitle).frame(width: 130)
                TextField("Body", text: $testBody)
            }
            .textFieldStyle(.roundedBorder)
            HStack {
                Spacer()
                Button {
                    state.sendTestNotification(
                        makeNotification(appName: testApp, bundleID: nil, title: testTitle,
                                         subtitle: testSubtitle, body: testBody))
                } label: {
                    Label("Send Test Notification", systemImage: "paperplane.fill")
                }
            }
        }
        .padding(14)
    }
}
