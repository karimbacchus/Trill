import SwiftUI
import ServiceManagement
import ObjectiveC
import TrillCore

struct SettingsView: View {
    @ObservedObject private var state = AppState.shared
    @State private var launchAtLogin = false
    @State private var loginMessage: String?

    private var isAppBundle: Bool { Bundle.main.bundleURL.pathExtension == "app" }

    var body: some View {
        // The window itself is the glass (see `GlassWindowStyle`); the sections are quiet, non-glass cards on
        // top of it so text stays legible in light and dark and glass is never stacked on glass.
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                hero
                appearanceSection
                startupSection
                notificationsSection
                accessibilitySection
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 24)
            // Clears the traffic lights, which float over the content.
            .padding(.top, 38)
        }
        .scrollContentBackground(.hidden)
        .ignoresSafeArea(.container, edges: .top)
        .frame(width: 480, height: 720)
        .background(WindowAccessor { GlassWindowStyle.apply(to: $0) })
        .onAppear { refreshLogin() }
    }

    private var hero: some View {
        HStack(spacing: 14) {
            Image(systemName: "waveform")
                .font(.system(size: 24, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 52, height: 52)
                .background(LinearGradient(colors: [.pink, .orange], startPoint: .topLeading, endPoint: .bottomTrailing),
                            in: RoundedRectangle(cornerRadius: 13, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                Text("Trill Settings").font(.title2.weight(.semibold))
                Text("Give every notification its own sound.").foregroundStyle(.secondary)
            }
            Spacer()
            if state.settings.isPaused {
                Label("Paused", systemImage: "pause.fill")
                    .font(.callout.weight(.medium))
                    .padding(.horizontal, 10).padding(.vertical, 5)
                    .background(Color.orange.opacity(0.18), in: Capsule())
                    .foregroundStyle(.orange)
            }
        }
    }

    private var appearanceSection: some View {
        SettingsSection("Appearance") {
            Picker("Theme", selection: $state.settings.appearance) {
                Text("System").tag(Appearance.system)
                Text("Light").tag(Appearance.light)
                Text("Dark").tag(Appearance.dark)
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            if WindowRouter.canHideMenuBarIcon {
                Divider()
                SettingsToggle("Show Trill in the menu bar", isOn: $state.settings.showMenuBarIcon)
                SettingsNote("If you hide the icon, open Trill again (from Finder, Spotlight or Launchpad) to show its window. From there you can reach Diagnostics, Settings and Quit.")
            }
        }
    }

    private var startupSection: some View {
        SettingsSection("Startup") {
            SettingsToggle("Launch Trill at login", isOn: launchBinding)
                .disabled(!isAppBundle)
            if !isAppBundle {
                SettingsNote("Launch at login only works when Trill runs as an app bundle (build it with Scripts/build-app.sh).")
            }
            if let loginMessage {
                Text(loginMessage).font(.caption).foregroundStyle(.red)
            }
        }
    }

    private var notificationsSection: some View {
        SettingsSection("Notifications") {
            SettingsToggle("Pause all rules", isOn: $state.settings.isPaused)
            SettingsNote("While paused, Trill still logs notifications in Diagnostics but plays nothing.")
            Divider()
            SettingsToggle("Turn off apps' own sounds", isOn: $state.settings.muteAppOwnSounds)
            SettingsNote("When you give an app a sound, Trill switches off that app's \"Play sound for notification\" setting so you only hear Trill's, and switches it back on if you remove the sound. This edits macOS's notification preferences and briefly restarts the notification service, which Apple does not officially support, so it may stop working in a future macOS.")
            HStack {
                Text("Apps' own sounds")
                Spacer()
                Button("Open Notification Settings…") { SystemLinks.openNotificationSettings() }
            }
        }
    }

    private var accessibilitySection: some View {
        SettingsSection("Accessibility") {
            HStack {
                Text("Permission")
                Spacer()
                if state.isAccessibilityTrusted {
                    Label("Granted", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                } else {
                    Button("Grant Access…") { state.requestAccessibilityPermission() }
                }
            }
        }
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

private struct SettingsSection<Content: View>: View {
    let title: String
    @ViewBuilder var content: () -> Content

    init(_ title: String, @ViewBuilder content: @escaping () -> Content) {
        self.title = title
        self.content = content
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.leading, 4)
            VStack(alignment: .leading, spacing: 10) {
                content()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
            // A solid-ish surface rather than glass (the window is the glass), so text keeps its contrast
            // whatever is behind the window.
            .background(Color(nsColor: .windowBackgroundColor).opacity(0.6),
                        in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08)))
        }
    }
}

private struct SettingsToggle: View {
    let title: String
    @Binding var isOn: Bool
    init(_ title: String, isOn: Binding<Bool>) { self.title = title; _isOn = isOn }
    var body: some View {
        HStack {
            Text(title)
            Spacer()
            Toggle(title, isOn: $isOn).labelsHidden().toggleStyle(.switch)
        }
    }
}

private struct SettingsNote: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// Turns the Settings window into a floating glass pane with no solid title bar: the title bar is transparent,
/// content runs under it with the traffic lights floating on top, and the window background is Liquid Glass
/// (`NSGlassEffectView`) on macOS 26+, or a behind-window blur (`NSVisualEffectView`) on 13-25.
/// SwiftUI's `Settings` scene has no API for this, so it goes through the hosting `NSWindow`.
@MainActor
enum GlassWindowStyle {
    private static var observerKey = 0
    private static let backdropID = NSUserInterfaceItemIdentifier("TrillGlassBackdrop")

    static func apply(to window: NSWindow) {
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.styleMask.insert(.fullSizeContentView)
        window.isMovableByWindowBackground = true
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = true
        // SwiftUI puts the title bar back after the window is shown (and when the scene updates), so keep it off.
        if objc_getAssociatedObject(window, &observerKey) == nil {
            let observer = window.observe(\.titlebarAppearsTransparent, options: [.new]) { window, _ in
                if !window.titlebarAppearsTransparent { window.titlebarAppearsTransparent = true }
            }
            objc_setAssociatedObject(window, &observerKey, observer, .OBJC_ASSOCIATION_RETAIN)
        }

        guard let content = window.contentView, let frame = content.superview,
              !frame.subviews.contains(where: { $0.identifier == backdropID }) else { return }
        let backdrop: NSView
        if #available(macOS 26.0, *) {
            let glass = NSGlassEffectView()
            glass.style = .regular
            glass.cornerRadius = 0
            backdrop = glass
        } else {
            let blur = NSVisualEffectView()
            blur.material = .underWindowBackground
            blur.blendingMode = .behindWindow
            blur.state = .active
            backdrop = blur
        }
        backdrop.identifier = backdropID
        backdrop.frame = frame.bounds
        backdrop.autoresizingMask = [.width, .height]
        frame.addSubview(backdrop, positioned: .below, relativeTo: content)
    }
}
