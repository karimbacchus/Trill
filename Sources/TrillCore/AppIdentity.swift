import Foundation

/// Pure helpers for relating the several ways an app is identified: bundle IDs, display names and the
/// suffixed names banners sometimes carry ("Microsoft Teams (work or school)"). No AppKit.
public enum AppIdentity {
    /// Trimmed, lower-cased, whitespace-collapsed.
    public static func normalize(_ s: String) -> String {
        s.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ").lowercased()
    }

    /// "Microsoft Teams (work or school)" -> "Microsoft Teams". Only a trailing "( ... )" group is removed.
    public static func stripTrailingParenthetical(_ s: String) -> String {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        guard t.hasSuffix(")"), let open = t.lastIndex(of: "("), open != t.startIndex else { return t }
        let head = t[..<open].trimmingCharacters(in: .whitespacesAndNewlines)
        return head.isEmpty ? t : head
    }

    /// True when `full` starts with `prefix`, is longer, and the next character is not a letter or digit.
    /// Both arguments are expected to be normalized.
    public static func isWordPrefix(_ prefix: String, of full: String) -> Bool {
        guard !prefix.isEmpty, full.count > prefix.count, full.hasPrefix(prefix) else { return false }
        let next = full[full.index(full.startIndex, offsetBy: prefix.count)]
        return !(next.isLetter || next.isNumber)
    }

    /// Does a rule's app-name filter match a banner's app name? Equal, equal after dropping a trailing
    /// parenthetical, or the filter is a word-boundary prefix of the banner name.
    public static func nameMatches(filter: String, banner: String) -> Bool {
        let f = normalize(filter), b = normalize(banner)
        guard !f.isEmpty, !b.isEmpty else { return false }
        if f == b { return true }
        let stripped = normalize(stripTrailingParenthetical(b))
        if f == stripped { return true }
        return isWordPrefix(f, of: b)
    }

    /// Looks a banner's app name up in a table of normalized name -> value: exact, then with the trailing
    /// parenthetical stripped, then the longest known name that is a word-boundary prefix of the banner name.
    public static func resolve<V>(name: String, in table: [String: V], minimumPrefixLength: Int = 3) -> V? {
        let key = normalize(name)
        guard !key.isEmpty else { return nil }
        if let v = table[key] { return v }
        let stripped = normalize(stripTrailingParenthetical(key))
        if stripped != key, let v = table[stripped] { return v }
        var best: (length: Int, value: V)?
        for (known, value) in table where known.count >= minimumPrefixLength && isWordPrefix(known, of: key) {
            if best == nil || known.count > best!.length { best = (known.count, value) }
        }
        return best?.value
    }
}
