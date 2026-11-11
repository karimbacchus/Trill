import SwiftUI
import AppKit
import Combine
import TrillCore

struct TrillApp: App {
    @NSApplicationDelegateAdaptor(TrillAppDelegate.self) private var delegate
    @ObservedObject private var state = AppState.shared

    var body: some Scene {
        MenuBarExtra {
            MenuBarContent()
        } label: {
            Image(systemName: state.settings.isPaused ? "pause.circle" : "waveform.circle")
                .modifier(LaunchWindows())
        }

        Window("Rules", id: WindowID.rules) {
            RulesView()
        }
        .defaultSize(width: 920, height: 600)

        Window("Diagnostics", id: WindowID.diagnostics) {
            DiagnosticsView()
        }
        .defaultSize(width: 860, height: 620)

        Settings {
            SettingsView()
        }
    }
}

enum WindowID {
    static let rules = "rules"
    static let diagnostics = "diagnostics"
}

@MainActor
final class TrillAppDelegate: NSObject, NSApplicationDelegate {
    private var cancellables = Set<AnyCancellable>()

    func applicationDidFinishLaunching(_ notification: Notification) {
        AppState.shared.start()
        AppState.shared.$settings
            .map(\.appearance)
            .removeDuplicates()
            .sink { Self.apply(appearance: $0) }
            .store(in: &cancellables)
    }

    static func apply(appearance: Appearance) {
        switch appearance {
        case .system: NSApp.appearance = nil
        case .light: NSApp.appearance = NSAppearance(named: .aqua)
        case .dark: NSApp.appearance = NSAppearance(named: .darkAqua)
        }
    }
}

enum AppActivation {
    @MainActor
    static func activate() {
        if #available(macOS 14.0, *) {
            NSApp.activate()
        } else {
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    @MainActor
    static func open(_ id: String, using openWindow: OpenWindowAction) {
        activate()
        openWindow(id: id)
        DispatchQueue.main.async { activate() }
    }

    @MainActor
    static func openSettings() {
        activate()
        let name = ProcessInfo.processInfo.operatingSystemVersion.majorVersion >= 14
            ? "showSettingsWindow:" : "showPreferencesWindow:"
        NSApp.sendAction(Selector(name), to: nil, from: nil)
        DispatchQueue.main.async { activate() }
    }
}

struct MenuBarContent: View {
    @ObservedObject private var state = AppState.shared
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button(state.settings.isPaused ? "Resume Trill" : "Pause Trill") {
            state.settings.isPaused.toggle()
        }
        if !state.isAccessibilityTrusted {
            Button("Grant Accessibility Access…") {
                state.requestAccessibilityPermission()
            }
        }
        Divider()
        Button("Rules…") { AppActivation.open(WindowID.rules, using: openWindow) }
        Button("Diagnostics…") { AppActivation.open(WindowID.diagnostics, using: openWindow) }
        if #available(macOS 14.0, *) {
            SettingsMenuButton()
        } else {
            Button("Settings…") { AppActivation.openSettings() }
                .keyboardShortcut(",")
        }
        Divider()
        Button("Quit Trill") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }
}

/// Attached to the menu bar icon, which is the only view that exists at launch.
/// Opens the Rules window on first run (no rules yet, or no Accessibility access), so a new user sees
/// something. `Trill --demo` also opens the other windows and feeds sample notifications through the
/// rules, for regenerating the README screenshots; combine with TRILL_DATA_DIR to keep real data untouched.
private struct LaunchWindows: ViewModifier {
    @Environment(\.openWindow) private var openWindow
    private static var didRun = false
    private static var demoSettingsWindow: NSWindow?

    func body(content: Content) -> some View {
        content.onAppear {
            guard !Self.didRun else { return }
            Self.didRun = true
            let demo = CommandLine.arguments.contains("--demo")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                let state = AppState.shared
                if demo || state.rules.isEmpty || !state.isAccessibilityTrusted {
                    AppActivation.open(WindowID.rules, using: openWindow)
                }
                if demo { runDemo() }
            }
        }
    }

    /// `--demo` options (all optional, for README screenshots):
    ///   --pane=app-sounds (default) | rule   which pane the Rules window shows
    ///   --picker                             open the sound picker on the first app
    ///   --settings                           also open Settings
    ///   --no-diagnostics                     do not open the Diagnostics window
    private func runDemo() {
        let args = CommandLine.arguments
        if args.contains("--pane=rule") {
            UIRouter.shared.selectedRuleID = AppState.shared.rules.first?.id
        } else {
            UIRouter.shared.showAppSounds = true
        }
        if args.contains("--picker") { UIRouter.shared.demoOpenPicker = true }
        if args.contains("--settings") {
            // Hosted in a plain window so it can be captured reliably.
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                let window = NSWindow(contentViewController: NSHostingController(rootView: SettingsView()))
                window.title = "Settings"
                window.styleMask = [.titled, .closable]
                window.center()
                window.makeKeyAndOrderFront(nil)
                Self.demoSettingsWindow = window
            }
        }
        if !args.contains("--no-diagnostics") { openWindow(id: WindowID.diagnostics) }
        let samples: [(String, String, String, String)] = [
            ("Slack", "#incident-142", "Checkout latency is above 2s in eu-west", "com.tinyspeck.slackmacgap"),
            ("Messages", "Sam", "Running five minutes late", "com.apple.MobileSMS"),
            ("Slack", "#deploys", "deploy of api@4f2c1 finished", "com.tinyspeck.slackmacgap"),
            ("Mail", "Weekly newsletter", "Ten things we shipped this month", "com.apple.mail"),
            ("Calendar", "Design review", "Starts in 10 minutes", "com.apple.iCal"),
        ]
        for (index, sample) in samples.enumerated() {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5 + Double(index) * 0.4) {
                AppState.shared.sendTestNotification(makeNotification(
                    appName: sample.0, bundleID: sample.3, title: sample.1, subtitle: "", body: sample.2))
            }
        }
    }
}

/// On macOS 14+ the supported way to open the Settings scene is the `openSettings` action;
/// sending `showSettingsWindow:` no longer works reliably.
@available(macOS 14.0, *)
private struct SettingsMenuButton: View {
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        Button("Settings…") {
            AppActivation.activate()
            openSettings()
            DispatchQueue.main.async { AppActivation.activate() }
        }
        .keyboardShortcut(",")
    }
}
