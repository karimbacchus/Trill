import Foundation

// XCTest and Swift Testing are unavailable with Command Line Tools only, so this tiny
// harness runs the same style of tests. Exits non-zero on any failure.
var failures = 0
var checks = 0

class TestCase {
    required init() {}
}

func fail(_ msg: String, _ line: UInt) { failures += 1; print("  FAIL line \(line): \(msg)") }
func XCTAssertTrue(_ e: @autoclosure () -> Bool, _ m: String = "", line: UInt = #line) { checks += 1; if !e() { fail("expected true \(m)", line) } }
func XCTAssertFalse(_ e: @autoclosure () -> Bool, _ m: String = "", line: UInt = #line) { checks += 1; if e() { fail("expected false \(m)", line) } }
func XCTAssertEqual<T: Equatable>(_ a: @autoclosure () -> T, _ b: @autoclosure () -> T, line: UInt = #line) { checks += 1; let (x, y) = (a(), b()); if x != y { fail("\(x) != \(y)", line) } }
func XCTAssertNil<T>(_ e: @autoclosure () -> T?, line: UInt = #line) { checks += 1; if e() != nil { fail("expected nil", line) } }
func XCTAssertNotNil<T>(_ e: @autoclosure () -> T?, _ m: String = "", line: UInt = #line) { checks += 1; if e() == nil { fail("expected non-nil \(m)", line) } }
func XCTAssertThrowsError<T>(_ e: @autoclosure () throws -> T, _ m: String = "", line: UInt = #line) { checks += 1; if (try? e()) != nil { fail("expected throw \(m)", line) } }

func run<T: TestCase>(_ name: String, _ tests: [(String, (T) -> () throws -> Void)]) {
    for (n, f) in tests {
        let before = failures
        do { try f(T())() } catch { failures += 1; print("  ERROR \(error)") }
        print("\(failures == before ? "ok  " : "FAIL") \(name).\(n)")
    }
}

run("Query", [
    ("emptyMatchesAll", QueryTests.testEmptyMatchesAll), ("bareWord", QueryTests.testBareWordCaseInsensitiveSubstring),
    ("specExamples", QueryTests.testSpecExamples), ("implicitAnd", QueryTests.testImplicitAnd),
    ("precedence", QueryTests.testPrecedence), ("parentheses", QueryTests.testParentheses),
    ("quotes", QueryTests.testQuotes), ("lowercaseKeywords", QueryTests.testLowercaseKeywordsAreWords),
    ("wildcards", QueryTests.testWildcards), ("specialChars", QueryTests.testSpecialCharsOrdinary),
    ("fieldPrefixes", QueryTests.testFieldPrefixes), ("noAppInSearchText", QueryTests.testSearchTextUnprefixedDoesNotMatchApp),
    ("invalid", QueryTests.testInvalid),
])
run("RuleEngine", [
    ("appFilter", RuleEngineTests.testAppFilter), ("queryAndInvalid", RuleEngineTests.testQueryAndInvalid),
    ("orderingAndDisabled", RuleEngineTests.testOrderingAndDisabled), ("render", RuleEngineTests.testRender),
    ("searchText", RuleEngineTests.testSearchText),
])
run("Store", [
    ("roundTrip", StoreTests.testRoundTrip), ("corruptAndTolerant", StoreTests.testCorruptAndTolerantDecoding),
])
print("\(checks) checks, \(failures) failures")
exit(failures == 0 ? 0 : 1)
