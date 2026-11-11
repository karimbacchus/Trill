import Foundation

public enum RuleEngine {
    /// First enabled rule (in array order) whose appFilter and query match. Invalid queries never match.
    public static func firstMatch(for n: CapturedNotification, in rules: [Rule]) -> Rule? {
        rules.first { $0.isEnabled && matches($0, n) }
    }

    public static func matches(_ rule: Rule, _ n: CapturedNotification) -> Bool {
        if let raw = rule.appFilter {
            let f = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if !f.isEmpty {
                let name = n.appName.lowercased()
                let bid = (n.bundleID ?? "").lowercased()
                if f != name && f != bid { return false }
            }
        }
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
