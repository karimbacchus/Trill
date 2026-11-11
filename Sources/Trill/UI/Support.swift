import SwiftUI
import AppKit
import TrillCore

/// Shared UI state used to hand a selection between windows.
@MainActor
final class UIRouter: ObservableObject {
    static let shared = UIRouter()
    @Published var selectedRuleID: UUID?
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
