import Foundation

public enum QueryParseError: Error, LocalizedError, Equatable {
    case unterminatedQuote
    case unexpectedClosingParen
    case missingClosingParen
    case emptyParentheses
    case missingOperand(after: String)
    case missingValue(field: String)
    case unexpectedOperator(String)

    public var errorDescription: String? {
        switch self {
        case .unterminatedQuote: return "Missing closing quote (\")."
        case .unexpectedClosingParen: return "Unexpected \")\" without a matching \"(\"."
        case .missingClosingParen: return "Missing closing parenthesis \")\"."
        case .emptyParentheses: return "Empty parentheses: put a search term inside \"( )\"."
        case .missingOperand(let op):
            return op.isEmpty ? "Expected a search term." : "Expected a search term after \(op)."
        case .missingValue(let f): return "Expected a value after \"\(f):\"."
        case .unexpectedOperator(let op): return "Unexpected \(op): it needs a search term on its left."
        }
    }
}

public struct QueryExpression: Sendable {
    fileprivate indirect enum Node: Sendable {
        case all
        case term(field: Field, pattern: [String])   // lowercased segments split on "*"
        case not(Node)
        case and([Node])
        case or([Node])
    }
    fileprivate enum Field: Sendable { case any, title, subtitle, body, app }

    fileprivate let root: Node

    public init(parsing source: String) throws {
        var lexer = Lexer(Array(source))
        let tokens = try lexer.run()
        if tokens.isEmpty { root = .all; return }
        var parser = Parser(tokens)
        root = try parser.parseAll()
    }

    public static func validate(_ source: String) -> String? {
        do { _ = try QueryExpression(parsing: source); return nil }
        catch { return (error as? LocalizedError)?.errorDescription ?? "\(error)" }
    }

    public func matches(_ n: CapturedNotification) -> Bool {
        Self.eval(root, Lowered(n))
    }

    private struct Lowered {
        let any, title, subtitle, body, appName, bundle: String
        init(_ n: CapturedNotification) {
            any = n.searchText.lowercased(); title = n.title.lowercased()
            subtitle = n.subtitle.lowercased(); body = n.body.lowercased()
            appName = n.appName.lowercased(); bundle = (n.bundleID ?? "").lowercased()
        }
    }

    private static func eval(_ node: Node, _ n: Lowered) -> Bool {
        switch node {
        case .all: return true
        case .not(let x): return !eval(x, n)
        case .and(let xs): return xs.allSatisfy { eval($0, n) }
        case .or(let xs): return xs.contains { eval($0, n) }
        case .term(let field, let pat):
            switch field {
            case .any: return wildcardContains(n.any, pat)
            case .title: return wildcardContains(n.title, pat)
            case .subtitle: return wildcardContains(n.subtitle, pat)
            case .body: return wildcardContains(n.body, pat)
            case .app: return wildcardContains(n.appName, pat) || wildcardContains(n.bundle, pat)
            }
        }
    }

    /// Substring match where segments must appear in order; "*" separates segments.
    private static func wildcardContains(_ text: String, _ segments: [String]) -> Bool {
        var from = text.startIndex
        for seg in segments where !seg.isEmpty {
            guard let r = text.range(of: seg, range: from..<text.endIndex) else { return false }
            from = r.upperBound
        }
        return true
    }

    // MARK: Lexer

    fileprivate enum Token: Equatable {
        case lparen, rparen, and, or, not
        case term(field: String?, text: String)
    }

    fileprivate struct Lexer {
        let chars: [Character]
        var i = 0
        init(_ c: [Character]) { chars = c }
        static let fields: Set<String> = ["title", "subtitle", "body", "app"]

        mutating func run() throws -> [Token] {
            var out: [Token] = []
            while i < chars.count {
                let c = chars[i]
                if c.isWhitespace { i += 1; continue }
                if c == "(" { out.append(.lparen); i += 1; continue }
                if c == ")" { out.append(.rparen); i += 1; continue }
                if c == "\"" { out.append(.term(field: nil, text: try quoted())); continue }
                var word = ""
                while i < chars.count, !chars[i].isWhitespace, chars[i] != "(", chars[i] != ")", chars[i] != "\"" {
                    word.append(chars[i]); i += 1
                }
                // Field prefix?
                if word.hasSuffix(":"), Self.fields.contains(String(word.dropLast()).lowercased()) {
                    let f = String(word.dropLast()).lowercased()
                    if i < chars.count, chars[i] == "\"" {
                        out.append(.term(field: f, text: try quoted())); continue
                    }
                    throw QueryParseError.missingValue(field: f)
                }
                if let colon = word.firstIndex(of: ":") {
                    let f = String(word[word.startIndex..<colon]).lowercased()
                    if Self.fields.contains(f) {
                        let rest = String(word[word.index(after: colon)...])
                        out.append(.term(field: f, text: rest)); continue
                    }
                }
                switch word {
                case "AND": out.append(.and)
                case "OR": out.append(.or)
                case "NOT": out.append(.not)
                default: out.append(.term(field: nil, text: word))
                }
            }
            return out
        }

        mutating func quoted() throws -> String {
            i += 1 // opening quote
            var s = ""
            while i < chars.count {
                if chars[i] == "\"" { i += 1; return s }
                s.append(chars[i]); i += 1
            }
            throw QueryParseError.unterminatedQuote
        }
    }

    // MARK: Parser

    fileprivate struct Parser {
        let tokens: [Token]
        var pos = 0
        init(_ t: [Token]) { tokens = t }
        var peek: Token? { pos < tokens.count ? tokens[pos] : nil }

        mutating func parseAll() throws -> Node {
            if peek == .or || peek == .and { throw QueryParseError.unexpectedOperator(peek == .or ? "OR" : "AND") }
            let n = try parseOr()
            if peek == .rparen { throw QueryParseError.unexpectedClosingParen }
            return n
        }

        mutating func parseOr() throws -> Node {
            var parts = [try parseAnd()]
            while peek == .or {
                pos += 1
                if peek == nil || peek == .rparen { throw QueryParseError.missingOperand(after: "OR") }
                if peek == .and || peek == .or { throw QueryParseError.unexpectedOperator(peek == .and ? "AND" : "OR") }
                parts.append(try parseAnd())
            }
            return parts.count == 1 ? parts[0] : .or(parts)
        }

        mutating func parseAnd() throws -> Node {
            var parts = [try parseNot()]
            while let t = peek {
                if t == .and {
                    pos += 1
                    if peek == nil || peek == .rparen { throw QueryParseError.missingOperand(after: "AND") }
                    if peek == .and || peek == .or { throw QueryParseError.unexpectedOperator(peek == .and ? "AND" : "OR") }
                    parts.append(try parseNot())
                } else if t == .or || t == .rparen {
                    break
                } else {
                    parts.append(try parseNot())
                }
            }
            return parts.count == 1 ? parts[0] : .and(parts)
        }

        mutating func parseNot() throws -> Node {
            if peek == .not {
                pos += 1
                if peek == nil || peek == .rparen { throw QueryParseError.missingOperand(after: "NOT") }
                return .not(try parseNot())
            }
            return try parsePrimary()
        }

        mutating func parsePrimary() throws -> Node {
            guard let t = peek else { throw QueryParseError.missingOperand(after: "") }
            switch t {
            case .lparen:
                pos += 1
                if peek == .rparen { throw QueryParseError.emptyParentheses }
                if peek == nil { throw QueryParseError.missingClosingParen }
                let n = try parseOr()
                guard peek == .rparen else { throw QueryParseError.missingClosingParen }
                pos += 1
                return n
            case .term(let f, let text):
                pos += 1
                let field: Field
                switch f {
                case "title": field = .title
                case "subtitle": field = .subtitle
                case "body": field = .body
                case "app": field = .app
                default: field = .any
                }
                let segs = text.lowercased().split(separator: "*", omittingEmptySubsequences: false).map(String.init)
                return .term(field: field, pattern: segs)
            case .rparen: throw QueryParseError.unexpectedClosingParen
            case .and: throw QueryParseError.unexpectedOperator("AND")
            case .or: throw QueryParseError.unexpectedOperator("OR")
            case .not: throw QueryParseError.missingOperand(after: "NOT")
            }
        }
    }
}
