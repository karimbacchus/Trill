import Foundation

public enum RuleEngine {
    /// First enabled rule (in array order) whose appFilter and query match. Invalid queries never match.
    ///
    /// `aliases` maps an app filter (bundle ID or name) to other identifiers of the same app (display names,
    /// alternate bundle IDs), so a filter stored as a bundle ID also matches a banner that only has a name.
    public static func firstMatch(for n: CapturedNotification, in rules: [Rule],
                                  aliases: AppAliases? = nil) -> Rule? {
        rules.first { $0.isEnabled && matches($0, n, aliases: aliases) }
    }

    public typealias AppAliases = (String) -> [String]

    /// Index at which a new app default should be inserted: before the first rule with no app filter
    /// (which would shadow it), else at the end.
    public static func defaultInsertionIndex(in rules: [Rule]) -> Int {
        rules.firstIndex { ($0.appFilter ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty } ?? rules.count
    }

    /// App filter test. A filter matches the banner's bundle ID (exact, case-insensitive) or its app name
    /// (exact, ignoring a trailing "(...)", or as a word-boundary prefix), directly or via `aliases`.
    public static func appFilterMatches(_ filter: String, _ n: CapturedNotification, aliases: AppAliases? = nil) -> Bool {
        let f = AppIdentity.normalize(filter)
        if f.isEmpty { return true }
        var candidates = [f]
        if let aliases { candidates += aliases(f).map(AppIdentity.normalize).filter { !$0.isEmpty } }
        let bid = AppIdentity.normalize(n.bundleID ?? "")
        for c in candidates {
            if !bid.isEmpty, c == bid { return true }
            if AppIdentity.nameMatches(filter: c, banner: n.appName) { return true }
        }
        return false
    }

    public static func matches(_ rule: Rule, _ n: CapturedNotification, aliases: AppAliases? = nil) -> Bool {
        if let raw = rule.appFilter, !appFilterMatches(raw, n, aliases: aliases) { return false }
        guard let expr = try? QueryExpression(parsing: rule.query) else { return false }
        return expr.matches(n)
    }

    /// "{app}", "{title}", "{subtitle}", "{body}" substitution (single pass).
    public static func render(template: String, with n: CapturedNotification) -> String {
        let map = ["{app}": n.appName, "{title}": n.title, "{subtitle}": n.subtitle, "{body}": n.body]
        var out = ""
        var rest = Substring(template)
        while let open = rest.firstIndex(of: "{") {
            out += rest[rest.startIndex..<open]
            let tail = rest[open...]
            if let close = tail.firstIndex(of: "}"), let v = map[String(tail[open...close])] {
                out += v
                rest = tail[tail.index(after: close)...]
            } else {
                out.append("{")
                rest = tail.dropFirst()
            }
        }
        out += rest
        return out
    }
}
