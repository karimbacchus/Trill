import Foundation
import TrillCore

final class QueryTests: TestCase {
    func n(_ title: String = "", sub: String = "", body: String = "", app: String = "Slack", bid: String? = "com.tinyspeck.slackmacgap") -> CapturedNotification {
        CapturedNotification(appName: app, bundleID: bid, title: title, subtitle: sub, body: body)
    }
    func m(_ q: String, _ x: CapturedNotification) -> Bool { try! QueryExpression(parsing: q).matches(x) }

    func testEmptyMatchesAll() {
        XCTAssertTrue(m("", n("x")))
        XCTAssertTrue(m("   ", n()))
    }
    func testBareWordCaseInsensitiveSubstring() {
        XCTAssertTrue(m("DEPLOY", n(body: "Finished deployment")))
        XCTAssertFalse(m("rollback", n(body: "Finished deployment")))
    }
    func testSpecExamples() {
        let prod = n("#prod-web", body: "x"), inc = n("#incident-42"), other = n("#random")
        XCTAssertTrue(m("#prod-* OR #incident-*", prod))
        XCTAssertTrue(m("#prod-* OR #incident-*", inc))
        XCTAssertFalse(m("#prod-* OR #incident-*", other))
        XCTAssertTrue(m("#alerts AND deploy", n("#alerts", body: "deploy done")))
        XCTAssertFalse(m("#alerts AND deploy", n("#alerts", body: "hello")))
        XCTAssertTrue(m("deploy NOT failed", n(body: "deploy ok")))
        XCTAssertFalse(m("deploy NOT failed", n(body: "deploy failed")))
    }
    func testImplicitAnd() {
        XCTAssertTrue(m("foo bar", n("foo", body: "bar")))
        XCTAssertFalse(m("foo bar", n("foo")))
    }
    func testPrecedence() {
        // a OR b AND c  ==  a OR (b AND c)
        XCTAssertTrue(m("a OR b AND c", n("a")))
        XCTAssertFalse(m("a OR b AND c", n("b")))
        XCTAssertTrue(m("a OR b AND c", n("b c")))
        // NOT binds tighter than AND
        XCTAssertTrue(m("NOT a b", n("b")))
        XCTAssertFalse(m("NOT a b", n("a b")))
        XCTAssertTrue(m("NOT NOT a", n("a")))
    }
    func testParentheses() {
        XCTAssertFalse(m("(a OR b) AND c", n("a")))
        XCTAssertTrue(m("(a OR b) AND c", n("b c")))
        XCTAssertTrue(m("a(b)", n("a b")))
        XCTAssertFalse(m("NOT (a OR b)", n("a")))
        XCTAssertTrue(m("NOT (a OR b)", n("z")))
    }
    func testQuotes() {
        XCTAssertTrue(m("\"build failed\"", n(body: "The Build Failed today")))
        XCTAssertFalse(m("\"build failed\"", n(body: "build was failed")))
        XCTAssertTrue(m("\"AND\"", n(body: "salt AND pepper")))
        XCTAssertTrue(m("\"a (b)\"", n(body: "a (b)")))
    }
    func testLowercaseKeywordsAreWords() {
        XCTAssertTrue(m("this and that", n(body: "this and that")))
        XCTAssertFalse(m("this and that", n(body: "this that")))
        XCTAssertTrue(m("not", n(body: "do not")))
        XCTAssertTrue(m("or", n(body: "or")))
    }
    func testWildcards() {
        XCTAssertTrue(m("#prod-*", n("#prod-")))
        XCTAssertTrue(m("a*c", n(body: "xxabbbcxx")))
        XCTAssertFalse(m("a*c", n(body: "cba")))
        XCTAssertTrue(m("*", n("x")))
        XCTAssertTrue(m("pre*mid*post", n(body: "pre.mid.post")))
        XCTAssertFalse(m("pre*mid*post", n(body: "post mid pre")))
        // overlapping must not reuse characters
        XCTAssertFalse(m("ab*ba", n(body: "aba")))
    }
    func testSpecialCharsOrdinary() {
        XCTAssertTrue(m("@karim", n(body: "hi @karim")))
        XCTAssertTrue(m("foo-bar_baz.qux", n(body: "foo-bar_baz.qux")))
    }
    func testFieldPrefixes() {
        let x = n("Deploy", sub: "prod", body: "all green")
        XCTAssertTrue(m("title:deploy", x))
        XCTAssertFalse(m("title:green", x))
        XCTAssertTrue(m("subtitle:prod", x))
        XCTAssertTrue(m("body:green", x))
        XCTAssertFalse(m("body:deploy", x))
        XCTAssertTrue(m("app:slack", x))
        XCTAssertTrue(m("app:tinyspeck", x))
        XCTAssertFalse(m("app:mail", x))
        XCTAssertTrue(m("title:\"dep\" AND body:\"all green\"", x))
        XCTAssertTrue(m("NOT title:foo", x))
        XCTAssertTrue(m("title:dep*", x))
    }
    func testSearchTextUnprefixedDoesNotMatchApp() {
        XCTAssertFalse(m("slack", n("hi")))
    }
    func testInvalid() {
        for q in ["(", ")", "a)", "(a", "()", "a AND", "a OR", "NOT", "OR a", "AND a", "a OR OR b", "a AND OR b",
                  "\"abc", "title:", "(a OR)", "a OR ) b"] {
            XCTAssertThrowsError(try QueryExpression(parsing: q), q)
            XCTAssertNotNil(QueryExpression.validate(q), q)
        }
        XCTAssertNil(QueryExpression.validate("a OR (b AND NOT c)"))
        XCTAssertNil(QueryExpression.validate(""))
        XCTAssertEqual(QueryExpression.validate("\"abc"), QueryParseError.unterminatedQuote.errorDescription)
        XCTAssertFalse(QueryParseError.missingClosingParen.errorDescription!.isEmpty)
    }
}

final class RuleEngineTests: TestCase {
    let note = CapturedNotification(appName: "Slack", bundleID: "com.tinyspeck.slackmacgap", title: "#alerts", body: "deploy ok")

    func testAppFilter() {
        var r = Rule(name: "r", action: .silent)
        XCTAssertTrue(RuleEngine.matches(r, note))
        r.appFilter = "COM.TinySpeck.slackmacgap"
        XCTAssertTrue(RuleEngine.matches(r, note))
        r.appFilter = "slack"
        XCTAssertTrue(RuleEngine.matches(r, note))
        r.appFilter = "Mail"
        XCTAssertFalse(RuleEngine.matches(r, note))
        r.appFilter = ""
        XCTAssertTrue(RuleEngine.matches(r, note))
    }
    func testQueryAndInvalid() {
        XCTAssertTrue(RuleEngine.matches(Rule(name: "r", query: "deploy", action: .silent), note))
        XCTAssertFalse(RuleEngine.matches(Rule(name: "r", query: "nope", action: .silent), note))
        XCTAssertFalse(RuleEngine.matches(Rule(name: "r", query: "(deploy", action: .silent), note))
    }
    func testOrderingAndDisabled() {
        let a = Rule(name: "a", isEnabled: false, query: "deploy", action: .sound(soundID: "1"))
        let b = Rule(name: "b", query: "deploy", action: .sound(soundID: "2"))
        let c = Rule(name: "c", action: .sound(soundID: "3"))
        XCTAssertEqual(RuleEngine.firstMatch(for: note, in: [a, b, c])?.name, "b")
        XCTAssertEqual(RuleEngine.firstMatch(for: note, in: [c, b, a])?.name, "c")
        XCTAssertNil(RuleEngine.firstMatch(for: note, in: [a]))
        XCTAssertNil(RuleEngine.firstMatch(for: note, in: []))
    }
    func testRender() {
        let x = CapturedNotification(appName: "A", title: "T", subtitle: "S", body: "{title}")
        XCTAssertEqual(RuleEngine.render(template: "{app}|{title}|{subtitle}|{body}|{x}|{", with: x), "A|T|S|{title}|{x}|{")
        XCTAssertEqual(RuleEngine.render(template: "plain", with: x), "plain")
    }
    func testSearchText() {
        XCTAssertEqual(CapturedNotification(title: "a", body: "c").searchText, "a\nc")
    }
}

final class StoreTests: TestCase {
    func testRoundTrip() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("trill-\(UUID().uuidString)/nested")
        defer { try? FileManager.default.removeItem(at: dir.deletingLastPathComponent()) }
        let s = Store(directory: dir)
        XCTAssertEqual(s.loadRules(), [])
        XCTAssertEqual(s.loadSettings(), AppSettings())
        let rules = [Rule(name: "a", appFilter: "Slack", query: "x OR y", action: .speak(voiceID: nil, template: "{title}"), volume: 1.5),
                     Rule(name: "b", action: .shortcut(name: "S")), Rule(name: "c", action: .silent)]
        s.saveRules(rules)
        XCTAssertEqual(Store(directory: dir).loadRules(), rules)
        var set = AppSettings(); set.appearance = .dark; set.isPaused = true
        s.saveSettings(set)
        XCTAssertEqual(s.loadSettings(), set)
        let snd = [Sound(id: "user:1", name: "n", kind: .user, url: s.soundsDirectory.appendingPathComponent("a.wav"))]
        s.saveUserSounds(snd)
        XCTAssertEqual(s.loadUserSounds(), snd)
        XCTAssertTrue(FileManager.default.fileExists(atPath: s.soundsDirectory.path))
    }
    func testCorruptAndTolerantDecoding() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("trill-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data("garbage".utf8).write(to: dir.appendingPathComponent("rules.json"))
        XCTAssertEqual(Store(directory: dir).loadRules(), [])
        let r = try JSONDecoder().decode(Rule.self, from: Data(#"{"name":"x"}"#.utf8))
        XCTAssertTrue(r.isEnabled); XCTAssertEqual(r.volume, 1.0); XCTAssertEqual(r.query, "")
        let st = try JSONDecoder().decode(AppSettings.self, from: Data("{}".utf8))
        XCTAssertEqual(st, AppSettings())
    }
}

final class AppIdentityTests: TestCase {
    let teams = KnownTeams()
    struct KnownTeams {
        let aliases: RuleEngine.AppAliases = { f in
            let group = ["com.microsoft.teams2", "com.microsoft.teams", "microsoft teams"]
            return group.contains(f.lowercased()) ? group : []
        }
    }
    func rule(_ f: String?) -> Rule { Rule(name: "r", appFilter: f, action: .silent) }
    func banner(_ name: String, _ bid: String? = nil) -> CapturedNotification {
        CapturedNotification(appName: name, bundleID: bid, title: "t")
    }

    func testStripAndPrefix() {
        XCTAssertEqual(AppIdentity.stripTrailingParenthetical("Microsoft Teams (work or school)"), "Microsoft Teams")
        XCTAssertEqual(AppIdentity.stripTrailingParenthetical("(x)"), "(x)")
        XCTAssertEqual(AppIdentity.stripTrailingParenthetical("Mail"), "Mail")
        XCTAssertTrue(AppIdentity.isWordPrefix("microsoft teams", of: "microsoft teams (work)"))
        XCTAssertFalse(AppIdentity.isWordPrefix("mail", of: "mailbox"))
        XCTAssertFalse(AppIdentity.isWordPrefix("mail", of: "mail"))
    }
    func testResolveTable() {
        let table = ["microsoft teams": "teams2", "microsoft": "ms", "slack": "slk"]
        XCTAssertEqual(AppIdentity.resolve(name: "Slack", in: table), "slk")
        XCTAssertEqual(AppIdentity.resolve(name: "Microsoft Teams (work or school)", in: table), "teams2")
        XCTAssertEqual(AppIdentity.resolve(name: "Microsoft Teams classic", in: table), "teams2")   // longest prefix
        XCTAssertEqual(AppIdentity.resolve(name: "Microsoft Word", in: table), "ms")
        XCTAssertNil(AppIdentity.resolve(name: "Slacker", in: table))
        XCTAssertNil(AppIdentity.resolve(name: "", in: table))
    }
    func testNameFilterMatchesSuffixedBanner() {
        XCTAssertTrue(RuleEngine.matches(rule("Microsoft Teams"), banner("Microsoft Teams (work or school)")))
        XCTAssertTrue(RuleEngine.matches(rule("microsoft teams (work or school)"), banner("Microsoft Teams (work or school)")))
        XCTAssertTrue(RuleEngine.matches(rule("Mail"), banner("Mail")))
        XCTAssertFalse(RuleEngine.matches(rule("Mail"), banner("Mailbox")))
        XCTAssertFalse(RuleEngine.matches(rule("Teams"), banner("Steams")))
    }
    func testBundleFilterMatchesNameOnlyBannerViaAliases() {
        let r = rule("com.microsoft.teams2")
        let b = banner("Microsoft Teams (work or school)")
        XCTAssertFalse(RuleEngine.matches(r, b))
        XCTAssertTrue(RuleEngine.matches(r, b, aliases: teams.aliases))
        XCTAssertTrue(RuleEngine.matches(r, banner("Microsoft Teams"), aliases: teams.aliases))
        XCTAssertFalse(RuleEngine.matches(r, banner("Slack"), aliases: teams.aliases))
    }
    func testAlternateBundleIDViaAliases() {
        let r = rule("com.microsoft.teams2")
        XCTAssertFalse(RuleEngine.matches(r, banner("", "com.microsoft.teams")))
        XCTAssertTrue(RuleEngine.matches(r, banner("", "com.microsoft.teams"), aliases: teams.aliases))
        XCTAssertTrue(RuleEngine.matches(r, banner("", "COM.Microsoft.Teams2")))
    }
    func testFirstMatchUsesAliases() {
        let a = Rule(name: "teams", appFilter: "com.microsoft.teams2", action: .sound(soundID: "1"))
        let b = Rule(name: "any", action: .sound(soundID: "2"))
        let n = banner("Microsoft Teams (work or school)")
        XCTAssertEqual(RuleEngine.firstMatch(for: n, in: [a, b], aliases: teams.aliases)?.name, "teams")
        XCTAssertEqual(RuleEngine.firstMatch(for: n, in: [a, b])?.name, "any")
    }
    func testDefaultInsertionIndex() {
        let app = Rule(name: "a", appFilter: "x", action: .silent)
        let any = Rule(name: "b", action: .silent)
        let blank = Rule(name: "c", appFilter: "  ", action: .silent)
        XCTAssertEqual(RuleEngine.defaultInsertionIndex(in: []), 0)
        XCTAssertEqual(RuleEngine.defaultInsertionIndex(in: [app, app]), 2)
        XCTAssertEqual(RuleEngine.defaultInsertionIndex(in: [app, any, app]), 1)
        XCTAssertEqual(RuleEngine.defaultInsertionIndex(in: [app, blank]), 1)
    }
}

final class GainTests: TestCase {
    func testUnityIsUntouched() {
        for s: Float in [-1, -0.97, -0.3, 0, 0.5, 0.99, 1] {
            XCTAssertEqual(Gain.apply(s, gain: 1, peak: 1), s)
        }
        XCTAssertEqual(Gain.apply(0.4, gain: 0.5, peak: 1), 0.2)
    }
    func testHeadroomScale() {
        XCTAssertEqual(Gain.headroomScale(gain: 2, peak: 0.25), 2)           // plenty of headroom, no clipping at all
        XCTAssertEqual(Gain.headroomScale(gain: 2, peak: 0.98), 1)           // none
        XCTAssertTrue(abs(Gain.headroomScale(gain: 2, peak: 0.8) - 1.225) < 0.001)
        XCTAssertEqual(Gain.headroomScale(gain: 0.5, peak: 0.8), 0.5)
    }
    func testQuietSoundBoostIsLinear() {
        XCTAssertTrue(abs(Gain.apply(0.2, gain: 2, peak: 0.3) - 0.4) < 0.0001)
    }
    func testSoftClipShape() {
        XCTAssertEqual(Gain.softClip(0.5), 0.5)
        XCTAssertEqual(Gain.softClip(-0.6), -0.6)
        XCTAssertTrue(Gain.softClip(1.0) > 0.6 && Gain.softClip(1.0) < 1.0)
        XCTAssertTrue(Gain.softClip(5) <= 1.0)
        XCTAssertEqual(Gain.softClip(-2), -Gain.softClip(2))
        // monotonic
        var last: Float = -2
        var x: Float = -3
        while x <= 3 { let y = Gain.softClip(x); XCTAssertTrue(y >= last); last = y; x += 0.05 }
    }
    func testLoudBoostIsLouderThanHardClipAndBounded() {
        // A built-in-like sound (peak 0.8) at 200%: louder than at 100%, never above 1.
        let peak: Float = 0.8
        var maxOut: Float = 0
        for i in 0...100 {
            let s = peak * sinf(Float(i) / 100 * .pi)
            let y = Gain.apply(s, gain: 2, peak: peak)
            XCTAssertTrue(abs(y) <= 1)
            maxOut = max(maxOut, abs(y))
        }
        XCTAssertTrue(maxOut > 0.95)
    }
}

final class StoreSafetyTests: TestCase {
    func tempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("trill-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
    func bytes(_ url: URL) -> Data { (try? Data(contentsOf: url)) ?? Data() }
    func rules(_ url: URL) -> [Rule] { (try? JSONDecoder().decode([Rule].self, from: bytes(url))) ?? [] }
    func corruptFiles(_ dir: URL, _ prefix: String) -> [URL] {
        ((try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.lastPathComponent.hasPrefix("\(prefix).corrupt-") }
    }

    func testGarbageFileIsQuarantinedNotDestroyed() throws {
        let dir = try tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        try Data("{ not json".utf8).write(to: dir.appendingPathComponent("rules.json"))
        let s = Store(directory: dir)
        XCTAssertEqual(s.loadRules(), [])
        let copies = corruptFiles(dir, "rules.json")
        XCTAssertEqual(copies.count, 1)
        XCTAssertEqual(bytes(copies[0]), Data("{ not json".utf8))
        s.saveRules([Rule(name: "new", action: .silent)])   // overwrites the original, the copy survives
        XCTAssertEqual(bytes(corruptFiles(dir, "rules.json")[0]), Data("{ not json".utf8))
    }
    func testMissingFileIsNotCorrupt() throws {
        let dir = try tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let s = Store(directory: dir)
        XCTAssertEqual(s.loadRules(), []); XCTAssertEqual(s.loadSettings(), AppSettings())
        XCTAssertEqual(corruptFiles(dir, "rules.json").count, 0)
    }
    func testOneBadRuleDoesNotDropTheRest() throws {
        let dir = try tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let json = """
        [
         {"name":"good1","query":"a","action":{"sound":{"soundID":"system:Glass"}}},
         {"name":"badAction","query":"b","action":{"banana":{}}},
         {"name":"badQuery","query":42,"action":{"silent":{}}},
         {"name":"badFilter","appFilter":{"x":1},"action":{"silent":{}}},
         "not an object",
         {"name":"good2","appFilter":"Slack","action":{"silent":{}}}
        ]
        """
        try Data(json.utf8).write(to: dir.appendingPathComponent("rules.json"))
        let s = Store(directory: dir)
        let rules = s.loadRules()
        XCTAssertEqual(rules.map(\.name), ["good1", "good2"])
        XCTAssertEqual(rules[0].action, .sound(soundID: "system:Glass"))
        XCTAssertEqual(rules[1].appFilter, "Slack")
        XCTAssertEqual(corruptFiles(dir, "rules.json").count, 1)
        // the quarantined copy still holds the bad rules
        XCTAssertTrue(String(decoding: bytes(corruptFiles(dir, "rules.json")[0]), as: UTF8.self).contains("banana"))
    }
    func testBadActionIsNotSilentlySilent() {
        XCTAssertThrowsError(try JSONDecoder().decode(Rule.self, from: Data(#"{"name":"x","action":{"zzz":1}}"#.utf8)))
        XCTAssertThrowsError(try JSONDecoder().decode(Rule.self, from: Data(#"{"name":"x","query":7}"#.utf8)))
        XCTAssertThrowsError(try JSONDecoder().decode(Rule.self, from: Data(#"{"name":"x","appFilter":[]}"#.utf8)))
        XCTAssertNotNil(try? JSONDecoder().decode(Rule.self, from: Data(#"{"name":"x","appFilter":null}"#.utf8)))
    }
    func testBackupOfPreviousContents() throws {
        let dir = try tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let s = Store(directory: dir)
        let v1 = [Rule(name: "one", action: .silent)]
        let v2 = [Rule(name: "two", action: .silent)]
        let v3 = [Rule(name: "three", action: .silent)]
        s.saveRules(v1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appendingPathComponent("rules.json.bak").path))
        s.saveRules(v2)
        let bak = dir.appendingPathComponent("rules.json.bak")
        XCTAssertEqual(rules(bak), v1)
        s.saveRules(v2)   // identical: the backup of v1 is not replaced by a copy of v2
        XCTAssertEqual(rules(bak), v1)
        s.saveRules(v3)
        XCTAssertEqual(rules(bak), v2)
        XCTAssertEqual(s.loadRules(), v3)
    }
    func testCorruptSettingsQuarantined() throws {
        let dir = try tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        try Data("[1,2".utf8).write(to: dir.appendingPathComponent("settings.json"))
        XCTAssertEqual(Store(directory: dir).loadSettings(), AppSettings())
        XCTAssertEqual(corruptFiles(dir, "settings.json").count, 1)
    }
}
