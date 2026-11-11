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
