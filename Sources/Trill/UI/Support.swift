import SwiftUI
import AppKit
import TrillCore

/// Shared UI state used to hand a selection between windows.
@MainActor
final class UIRouter: ObservableObject {
    static let shared = UIRouter()
    /// Selecting a rule leaves the "App sounds" pane; `showAppSounds` brings it back.
    @Published var selectedRuleID: UUID? {
        didSet { if selectedRuleID != nil { showAppSounds = false } }
    }
    @Published var showAppSounds = true
    /// `--demo --picker`: open the sound picker on the first app row (screenshots).
    @Published var demoOpenPicker = false
    /// Set when a rule was just created from a template, so its editor focuses the query field.
    @Published var focusQueryRuleID: UUID?
}

enum ActionKind: String, CaseIterable, Identifiable {
    case sound, speak, shortcut, silent
    var id: String { rawValue }

    var title: String {
        switch self {
        case .sound: return "Sound"
        case .speak: return "Speak"
        case .shortcut: return "Shortcut"
        case .silent: return "Silent"
        }
    }

    var symbol: String {
        switch self {
        case .sound: return "speaker.wave.2"
        case .speak: return "text.bubble"
        case .shortcut: return "command"
        case .silent: return "speaker.slash"
        }
    }
}

extension RuleAction {
    var kind: ActionKind {
        switch self {
        case .sound: return .sound
        case .speak: return .speak
        case .shortcut: return .shortcut
        case .silent: return .silent
        }
    }
}

func makeNotification(appName: String = "", bundleID: String? = nil, title: String,
                      subtitle: String = "", body: String = "") -> CapturedNotification {
    CapturedNotification(id: UUID(), date: Date(), appName: appName, bundleID: bundleID,
                         title: title, subtitle: subtitle, body: body)
}

@MainActor
enum AppIcons {
    private static var cache: [String: NSImage] = [:]
    private static let fallback: NSImage = {
        let img = NSWorkspace.shared.icon(for: .applicationBundle)
        return img
    }()

    static func icon(forBundleID id: String) -> NSImage {
        if let hit = cache[id] { return hit }
        var image = fallback
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) {
            image = NSWorkspace.shared.icon(forFile: url.path)
        }
        image.size = NSSize(width: 32, height: 32)
        cache[id] = image
        return image
    }
}

extension AppState {
    /// Short description of what a rule does, for list rows.
    func summary(of action: RuleAction) -> String {
        switch action {
        case .sound(let id): return sound(withID: id)?.name ?? "Missing sound"
        case .speak: return "Speak notification"
        case .shortcut(let name): return name.isEmpty ? "Shortcut" : "Shortcut: \(name)"
        case .silent: return "Silent"
        }
    }

    /// First available sound id from a list of preferred ids, else any sound.
    func soundID(preferring ids: [String]) -> String {
        for id in ids where sound(withID: id) != nil { return id }
        return sounds.first?.id ?? ids.first ?? "system:Glass"
    }
}


// MARK: - App catalog

/// Installed apps, scanned once (the scan walks /Applications) and shared by the UI.
@MainActor
final class AppCatalog: ObservableObject {
    static let shared = AppCatalog()
    @Published private(set) var apps: [AppInfo] = []
    private var observer: NSObjectProtocol?

    /// Shows whatever is cached right away; the scan itself runs in the background and the list updates
    /// when it finishes.
    func loadIfNeeded() {
        if observer == nil {
            observer = NotificationCenter.default.addObserver(forName: InstalledApps.didUpdate, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.apps = AppState.shared.installedApps() }
            }
        }
        let cached = AppState.shared.installedApps()
        if cached != apps { apps = cached }
    }

    /// Resolves a rule's app filter (bundle ID or display name) to an installed app.
    func info(forFilter filter: String?) -> AppInfo? {
        guard let f = filter?.trimmingCharacters(in: .whitespaces).lowercased(), !f.isEmpty else { return nil }
        return apps.first { $0.bundleID.lowercased() == f } ?? apps.first { $0.name.lowercased() == f }
    }

    func icon(forFilter filter: String?) -> NSImage {
        if let info = info(forFilter: filter) { return AppIcons.icon(forBundleID: info.bundleID) }
        if let f = filter, f.contains(".") { return AppIcons.icon(forBundleID: f) }
        return AppIcons.icon(forBundleID: "")
    }

    func displayName(forFilter filter: String?) -> String {
        guard let f = filter?.trimmingCharacters(in: .whitespaces), !f.isEmpty else { return "Any app" }
        return info(forFilter: f)?.name ?? f
    }
}

// MARK: - Liquid Glass helpers
//
// Glass belongs to the floating control layer (toolbars, sidebars, floating bars, popovers, key
// buttons), never to content rows. On macOS 26 these use `glassEffect` / `.glass` button styles; on
// earlier systems they fall back to materials and bordered buttons.

private struct GlassCardModifier: ViewModifier {
    let cornerRadius: CGFloat
    let tint: Color?
    let interactive: Bool

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        if #available(macOS 26.0, *) {
            var glass = Glass.regular
            if let tint { glass = glass.tint(tint) }
            if interactive { glass = glass.interactive() }
            return AnyView(content.glassEffect(glass, in: shape))
        } else {
            return AnyView(content
                .background(.regularMaterial, in: shape)
                .overlay(shape.strokeBorder(Color.primary.opacity(0.08)))
                .shadow(color: .black.opacity(0.08), radius: 8, y: 2))
        }
    }
}

private struct GlassButtonModifier: ViewModifier {
    let prominent: Bool

    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            if prominent {
                AnyView(content.buttonStyle(.glassProminent))
            } else {
                AnyView(content.buttonStyle(.glass))
            }
        } else {
            if prominent {
                AnyView(content.buttonStyle(.borderedProminent))
            } else {
                AnyView(content.buttonStyle(.bordered))
            }
        }
    }
}

/// Wraps neighbouring glass elements so they blend and sample the same backdrop (macOS 26+).
struct GlassGroup<Content: View>: View {
    var spacing: CGFloat = 12
    @ViewBuilder var content: () -> Content

    var body: some View {
        if #available(macOS 26.0, *) {
            GlassEffectContainer(spacing: spacing) { content() }
        } else {
            content()
        }
    }
}

extension View {
    /// Floating glass surface (use for bars, banners and popover-like panels, not list content).
    func glassCard(cornerRadius: CGFloat = 18, tint: Color? = nil, interactive: Bool = false) -> some View {
        modifier(GlassCardModifier(cornerRadius: cornerRadius, tint: tint, interactive: interactive))
    }

    /// Glass button style on macOS 26+, bordered earlier. `prominent` is for the one primary action.
    func glassButton(prominent: Bool = false) -> some View {
        modifier(GlassButtonModifier(prominent: prominent))
    }

    /// Quiet container for grouped content. Deliberately not glass.
    func contentCard(padding: CGFloat = 16, cornerRadius: CGFloat = 14) -> some View {
        self.padding(padding)
            .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.06)))
    }

    /// Prominent text-field chrome used for the query and search fields.
    func fieldChrome(isInvalid: Bool = false) -> some View {
        self.padding(.horizontal, 12).padding(.vertical, 9)
            .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(isInvalid ? Color.red.opacity(0.7) : Color.primary.opacity(0.14)))
    }
}

/// Small app icon with rounded-rect fallback, used in rows.
struct AppIconView: View {
    let image: NSImage
    var size: CGFloat = 32
    var body: some View {
        Image(nsImage: image).resizable().interpolation(.high).frame(width: size, height: size)
    }
}

enum SystemLinks {
    static func openNotificationSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension") {
            NSWorkspace.shared.open(url)
        }
    }
}
