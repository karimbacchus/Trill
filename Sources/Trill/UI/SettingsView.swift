import SwiftUI
import ServiceManagement
import TrillCore

struct SettingsView: View {
    @ObservedObject private var state = AppState.shared
    @State private var launchAtLogin = false
    @State private var loginMessage: String?

    private var isAppBundle: Bool { Bundle.main.bundleURL.pathExtension == "app" }

    var body: some View {
        Form {
            Section("Appearance") {
                Picker("Theme", selection: $state.settings.appearance) {
                    Text("System").tag(Appearance.system)
                    Text("Light").tag(Appearance.light)
                    Text("Dark").tag(Appearance.dark)
                }
                .pickerStyle(.segmented)
            }

            Section {
                Toggle("Launch Trill at login", isOn: launchBinding)
                    .disabled(!isAppBundle)
                if !isAppBundle {
                    Text("Launch at login only works when Trill runs as an app bundle (build it with Scripts/build-app.sh).")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if let loginMessage {
                    Text(loginMessage).font(.caption).foregroundStyle(.red)
                }
            } header: {
                Text("Startup")
            }

            Section {
                Toggle("Pause all rules", isOn: $state.settings.isPaused)
            } header: {
                Text("Notifications")
            } footer: {
                Text("While paused, Trill still logs notifications in Diagnostics but plays nothing.")
            }

            Section("Accessibility") {
                LabeledContent("Permission") {
                    if state.isAccessibilityTrusted {
                        Label("Granted", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                    } else {
                        Button("Grant Access…") { state.requestAccessibilityPermission() }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 460, height: 440)
        .onAppear { refreshLogin() }
    }

    private var launchBinding: Binding<Bool> {
        Binding(
            get: { launchAtLogin },
            set: { newValue in
                loginMessage = nil
                do {
                    if newValue { try SMAppService.mainApp.register() }
                    else { try SMAppService.mainApp.unregister() }
                } catch {
                    loginMessage = error.localizedDescription
                }
                refreshLogin()
            }
        )
    }

    private func refreshLogin() {
        let status = SMAppService.mainApp.status
        launchAtLogin = (status == .enabled)
        if status == .requiresApproval {
            loginMessage = "Approve Trill in System Settings > General > Login Items."
        }
    }
}
