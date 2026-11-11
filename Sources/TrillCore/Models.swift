import Foundation

public struct CapturedNotification: Identifiable, Codable, Hashable, Sendable {
    public var id: UUID
    public var date: Date
    public var appName: String
    public var bundleID: String?
    public var title: String
    public var subtitle: String
    public var body: String

    public init(id: UUID = UUID(), date: Date = Date(), appName: String = "", bundleID: String? = nil,
                title: String = "", subtitle: String = "", body: String = "") {
        self.id = id; self.date = date; self.appName = appName; self.bundleID = bundleID
        self.title = title; self.subtitle = subtitle; self.body = body
    }

    /// Title, subtitle and body joined by "\n" (non-empty parts only).
    public var searchText: String {
        [title, subtitle, body].filter { !$0.isEmpty }.joined(separator: "\n")
    }

    enum CodingKeys: String, CodingKey { case id, date, appName, bundleID, title, subtitle, body }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = (try? c.decodeIfPresent(UUID.self, forKey: .id)) ?? UUID()
        date = (try? c.decodeIfPresent(Date.self, forKey: .date)) ?? Date()
        appName = (try? c.decodeIfPresent(String.self, forKey: .appName)) ?? ""
        bundleID = try? c.decodeIfPresent(String.self, forKey: .bundleID)
        title = (try? c.decodeIfPresent(String.self, forKey: .title)) ?? ""
        subtitle = (try? c.decodeIfPresent(String.self, forKey: .subtitle)) ?? ""
        body = (try? c.decodeIfPresent(String.self, forKey: .body)) ?? ""
    }
}

public enum RuleAction: Codable, Hashable, Sendable {
    case sound(soundID: String)
    case speak(voiceID: String? = nil, template: String = "{title}. {body}")
    case shortcut(name: String)
    case silent
}

public struct Rule: Identifiable, Codable, Hashable, Sendable {
    public var id: UUID
    public var name: String
    public var isEnabled: Bool
    public var appFilter: String?
    public var query: String
    public var action: RuleAction
    public var volume: Double

    public init(id: UUID = UUID(), name: String, isEnabled: Bool = true, appFilter: String? = nil,
                query: String = "", action: RuleAction, volume: Double = 1.0) {
        self.id = id; self.name = name; self.isEnabled = isEnabled; self.appFilter = appFilter
        self.query = query; self.action = action; self.volume = volume
    }

    enum CodingKeys: String, CodingKey { case id, name, isEnabled, appFilter, query, action, volume }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = (try? c.decodeIfPresent(UUID.self, forKey: .id)) ?? UUID()
        name = (try? c.decodeIfPresent(String.self, forKey: .name)) ?? ""
        isEnabled = (try? c.decodeIfPresent(Bool.self, forKey: .isEnabled)) ?? true
        appFilter = try? c.decodeIfPresent(String.self, forKey: .appFilter)
        query = (try? c.decodeIfPresent(String.self, forKey: .query)) ?? ""
        action = (try? c.decodeIfPresent(RuleAction.self, forKey: .action)) ?? .silent
        volume = (try? c.decodeIfPresent(Double.self, forKey: .volume)) ?? 1.0
    }
}

public struct Sound: Identifiable, Codable, Hashable, Sendable {
    public enum Kind: String, Codable, Sendable { case system, builtIn, user }
    public var id: String
    public var name: String
    public var kind: Kind
    public var url: URL
    /// Display group for sounds that ship in a named pack (e.g. "Kenney Interface"); nil otherwise.
    public var group: String?

    public init(id: String, name: String, kind: Kind, url: URL, group: String? = nil) {
        self.id = id; self.name = name; self.kind = kind; self.url = url; self.group = group
    }
}

public enum Appearance: String, Codable, CaseIterable, Sendable { case system, light, dark }

public struct AppSettings: Codable, Hashable, Sendable {
    public var appearance: Appearance
    public var isPaused: Bool

    public init() { appearance = .system; isPaused = false }

    enum CodingKeys: String, CodingKey { case appearance, isPaused }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        appearance = (try? c.decodeIfPresent(Appearance.self, forKey: .appearance)) ?? .system
        isPaused = (try? c.decodeIfPresent(Bool.self, forKey: .isPaused)) ?? false
    }
}
