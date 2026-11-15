import SwiftUI
import AppKit
import Combine
import TrillCore

/// The app's scenes. Two `App` types (macOS 15+ and earlier) share them, because `defaultLaunchBehavior`
/// only exists on 15 and a scene builder cannot branch on availability.
struct TrillApp: App {
    @NSApplicationDelegateAdaptor(TrillAppDelegate.self) private var delegate
    var body: some Scene {
        TrillScenes()
        // Never opened before macOS 15; the menu bar label hook does the work there.
        Window("Trill", id: WindowID.host) { HostView() }
            .commands { TrillCommands() }
    }
}

@available(macOS 15.0, *)
struct TrillApp15: App {
    @NSApplicationDelegateAdaptor(TrillAppDelegate.self) private var delegate
    var body: some Scene {
        TrillScenes()
        // Invisible; presented at launch so its view owns the `openWindow` / `openSettings` actions even
        // when the menu bar icon is hidden.
        Window("Trill", id: WindowID.host) { HostView() }
            .defaultLaunchBehavior(.presented)
            .commands { TrillCommands() }
    }
}

private struct TrillScenes: Scene {
    @ObservedObject private var state = AppState.shared

    var body: some Scene {
        MenuBarExtra(isInserted: menuBarIconInserted) {
            MenuBarContent()
        } label: {
            Image(systemName: state.settings.isPaused ? "pause.circle" : "waveform.circle")
                .modifier(LegacyLaunchHook())
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

    /// Without the invisible host window (before macOS 15) nothing could reopen Trill with the icon hidden,
    /// so the icon is then always shown.
    private var menuBarIconInserted: Binding<Bool> {
        Binding(
            get: { state.settings.showMenuBarIcon || !WindowRouter.canHideMenuBarIcon },
            // SwiftUI writes the value back when it first reads it; storing it again would republish the
            // settings and loop, so only real changes (and only where hiding is allowed) are stored.
            set: { newValue in
                guard WindowRouter.canHideMenuBarIcon, state.settings.showMenuBarIcon != newValue else { return }
                state.settings.showMenuBarIcon = newValue
            }
        )
    }
}

enum WindowID {
    static let rules = "rules"
    static let diagnostics = "diagnostics"
    static let host = "host"
}

@MainActor
final class TrillAppDelegate: NSObject, NSApplicationDelegate {
    private var cancellables = Set<AnyCancellable>()

    func applicationWillTerminate(_ notification: Notification) {
        AppState.shared.flushSaves(wait: true)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        AppState.shared.start()
        // A second launch of Trill (see TrillMain) asks this instance to show its Rules window.
        DistributedNotificationCenter.default().addObserver(
            forName: WindowRouter.showRulesNotification, object: WindowRouter.showRulesObject, queue: .main
        ) { _ in
            MainActor.assumeIsolated { WindowRouter.shared.show(WindowID.rules) }
        }
        AppState.shared.$settings
            .map(\.appearance)
            .removeDuplicates()
            .sink { Self.apply(appearance: $0) }
            .store(in: &cancellables)
    }

    /// Finder, Spotlight and Launchpad send this to the running instance. It is what makes a Trill with no
    /// menu bar icon reachable.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        WindowRouter.shared.show(WindowID.rules)
        return false
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

}

struct MenuBarContent: View {
    @ObservedObject private var state = AppState.shared

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
        Button("Rules…") { WindowRouter.shared.show(WindowID.rules) }
        Button("Diagnostics…") { WindowRouter.shared.show(WindowID.diagnostics) }
        Button("Settings…") { WindowRouter.shared.showSettings() }
            .keyboardShortcut(",")
        Divider()
        Button("Quit Trill") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }
}

/// Before macOS 15 there is no invisible host window, so the (always shown) menu bar icon captures
/// `openWindow` instead.
private struct LegacyLaunchHook: ViewModifier {
    @Environment(\.openWindow) private var openWindow

    func body(content: Content) -> some View {
        content.onAppear {
            guard !WindowRouter.canHideMenuBarIcon else { return }
            WindowRouter.shared.attach(openWindow: openWindow)
            WindowRouter.shared.launchOnce()
        }
    }
}

/// App menu additions, so Rules and Diagnostics are reachable from the menu bar of whichever Trill window is
/// active (Settings and Quit are already there).
struct TrillCommands: Commands {
    var body: some Commands {
        CommandGroup(after: .appSettings) {
            Button("Rules…") { WindowRouter.shared.show(WindowID.rules) }
                .keyboardShortcut("r", modifiers: [.command, .shift])
            Button("Diagnostics…") { WindowRouter.shared.show(WindowID.diagnostics) }
                .keyboardShortcut("d", modifiers: [.command, .shift])
        }
    }
}
