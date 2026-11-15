import SwiftUI
import AppKit
import TrillCore

/// Opens Trill's windows from anywhere (menu bar, reopen events, a second launch) without depending on any
/// particular view being on screen.
///
/// SwiftUI only hands out `OpenWindowAction` / `OpenSettingsAction` through the environment of a view that is
/// currently alive. The menu bar label is not one when the icon is hidden, so on macOS 15+ a tiny
/// invisible `Window` scene (`HostView`, presented at launch with `defaultLaunchBehavior(.presented)`)
/// captures both actions and parks them here. Before macOS 15 the menu bar icon cannot be hidden, so its
/// label view does the capturing instead (see `TrillApp`).
@MainActor
final class WindowRouter {
    static let shared = WindowRouter()

    private var openWindowAction: OpenWindowAction?
    private var openSettingsAction: (() -> Void)?
    private var didScheduleLaunch = false
    private var pendingRules = false

    /// True when the invisible host window exists, which is what makes hiding the menu bar icon safe.
    static var canHideMenuBarIcon: Bool {
        if #available(macOS 15.0, *) { return true }
        return false
    }

    /// Distributed notification a second launch posts so the running instance shows its Rules window.
    /// Scoped to the data directory, like the single-instance lock.
    nonisolated static let showRulesNotification = Notification.Name("com.karimbacchus.trill.showRules")
    nonisolated static var showRulesObject: String { Store.defaultDirectory.path }

    func attach(openWindow: OpenWindowAction) {
        openWindowAction = openWindow
        if pendingRules { pendingRules = false; show(WindowID.rules) }
    }

    func attach(openSettings: @escaping () -> Void) { openSettingsAction = openSettings }

    func show(_ id: String) {
        guard let openWindowAction else {
            if id == WindowID.rules { pendingRules = true }
            return
        }
        AppActivation.activate()
        openWindowAction(id: id)
        DispatchQueue.main.async { AppActivation.activate() }
    }

    func showSettings() {
        AppActivation.activate()
        if let openSettingsAction {
            openSettingsAction()
        } else if !NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil) {
            NSApp.sendAction(Selector(("showPreferencesWindow:")), to: nil, from: nil)
        }
        DispatchQueue.main.async { AppActivation.activate() }
    }

    /// Runs once, as soon as windows can be opened: shows Rules on first run, when the menu bar icon is hidden
    /// (so a cold launch is never invisible), and for `--demo`.
    func launchOnce() {
        guard !didScheduleLaunch else { return }
        didScheduleLaunch = true
        let demo = CommandLine.arguments.contains("--demo")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [self] in
            let state = AppState.shared
            if demo || !state.settings.showMenuBarIcon || state.rules.isEmpty || !state.isAccessibilityTrusted {
                show(WindowID.rules)
            }
            if demo { runDemo() }
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
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { self.showSettings() }
        }
        if !args.contains("--no-diagnostics") { show(WindowID.diagnostics) }
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

/// The invisible window behind `WindowRouter`. It stays ordered out; its view stays alive.
struct HostView: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Color.clear
            .frame(width: 1, height: 1)
            .background(WindowAccessor { window in
                window.alphaValue = 0
                window.ignoresMouseEvents = true
                window.isExcludedFromWindowsMenu = true
                window.collectionBehavior.insert(.transient)
                DispatchQueue.main.async { window.orderOut(nil) }
            })
            .modifier(CaptureOpenSettings())
            .onAppear {
                WindowRouter.shared.attach(openWindow: openWindow)
                WindowRouter.shared.launchOnce()
            }
    }
}

private struct CaptureOpenSettings: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 14.0, *) {
            content.modifier(CaptureOpenSettings14())
        } else {
            content
        }
    }
}

@available(macOS 14.0, *)
private struct CaptureOpenSettings14: ViewModifier {
    @Environment(\.openSettings) private var openSettings
    func body(content: Content) -> some View {
        content.onAppear { WindowRouter.shared.attach(openSettings: { openSettings() }) }
    }
}

/// Gives SwiftUI content access to the `NSWindow` that hosts it. `configure` runs once per window.
struct WindowAccessor: NSViewRepresentable {
    var configure: (NSWindow) -> Void

    final class Coordinator { weak var configured: NSWindow? }
    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async { [weak view] in run(view, context.coordinator) }
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        DispatchQueue.main.async { [weak view] in run(view, context.coordinator) }
    }

    private func run(_ view: NSView?, _ coordinator: Coordinator) {
        guard let window = view?.window, coordinator.configured !== window else { return }
        coordinator.configured = window
        configure(window)
    }
}
