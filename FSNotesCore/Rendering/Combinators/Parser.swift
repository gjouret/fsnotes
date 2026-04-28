//
//  Parser.swift
//  FSNotesCore
//
//  Phase 12.C.1 — Parser combinator infrastructure.
//
//  Tiny parser combinator library used by the bucket-by-bucket port
//  of `MarkdownParser` into a declarative grammar (Phase 12.C.2 →
//  12.C.6). Designed to be the smallest sufficient API for CommonMark:
//
//    • Pure value type `Parser<A>` carries a `parse` closure.
//    • Primitives: `char`, `string`, `oneOf`, `satisfy`, `noneOf`,
//      `pure`, `fail`.
//    • Combinators: `map`, `flatMap`, `<|>` (alternative), `<*>` (apply),
//      `seq2`, `between`, `many`, `many1`, `sepBy`, `optional`,
//      `lookahead`, `notFollowedBy`, `eof`.
//    • Substring-backed input so cuts are O(1) (no String slicing copy).
//
//  Why not a third-party combinator pod: every existing Swift combinator
//  library leans on existentials and protocol witnesses, both of which
//  are heavy in Swift. A 250-LoC bespoke library tuned to the
//  CommonMark grammar is faster, debuggable, and removes the dependency
//  surface.
//
//  Tests: `Tests/CombinatorPrimitivesTests.swift` exercises every
//  primitive and combinator against tiny inputs (≈300 LoC).
//

import Foundation

/// Outcome of running a parser on a substring.
public enum ParseResult<A> {
    case success(value: A, remainder: Substring)
    case failure(message: String, remainder: Substring)

    public var value: A? {
        if case .success(let v, _) = self { return v }
        return nil
    }
    public var remainder: Substring {
        switch self {
        case .success(_, let r): return r
        case .failure(_, let r): return r
        }
    }
    public var isSuccess: Bool {
        if case .success = self { return true }
        return false
    }
}

/// Pure value-type parser. `parse` consumes from the front of a
/// substring and returns either `.success(value, remainder)` or
/// `.failure(message, remainder)`. The parser MUST NOT mutate any
/// external state; combinators rely on this purity for backtracking
/// (a failed alternative leaves the input intact, by definition,
/// because no input was consumed).
public struct Parser<A> {
    public let parse: (Substring) -> ParseResult<A>

    public init(_ parse: @escaping (Substring) -> ParseResult<A>) {
        self.parse = parse
    }

    /// Run the parser against a String. Returns `.success` only if
    /// the parser consumed all input AND produced a value; partial
    /// matches return `.failure`. For partial matches use `parse`
    /// directly with `.parse(input[...])`.
    public func parseAll(_ input: String) -> ParseResult<A> {
        let result = self.parse(Substring(input))
        switch result {
        case .success(let v, let r) where r.isEmpty:
            return .success(value: v, remainder: r)
        case .success(_, let r):
            return .failure(message: "unconsumed input: \(r.prefix(20))", remainder: r)
        case .failure:
            return result
        }
    }

    // MARK: - Functor / Monad

    /// Transform the parsed value via a pure function. Failure is
    /// propagated unchanged.
    public func map<B>(_ f: @escaping (A) -> B) -> Parser<B> {
        return Parser<B> { input in
            switch self.parse(input) {
            case .success(let v, let r): return .success(value: f(v), remainder: r)
            case .failure(let m, let r): return .failure(message: m, remainder: r)
            }
        }
    }

    /// Sequence this parser with one that depends on its result.
    /// The classic monadic bind. Use sparingly — `seq2` and `<*>` are
    /// usually clearer.
    public func flatMap<B>(_ f: @escaping (A) -> Parser<B>) -> Parser<B> {
        return Parser<B> { input in
            switch self.parse(input) {
            case .success(let v, let r): return f(v).parse(r)
            case .failure(let m, let r): return .failure(message: m, remainder: r)
            }
        }
    }
}

// MARK: - Primitives

/// Parser that always succeeds with the given value, consuming nothing.
public func pure<A>(_ value: A) -> Parser<A> {
    return Parser { .success(value: value, remainder: $0) }
}

/// Parser that always fails with the given message, consuming nothing.
public func fail<A>(_ message: String) -> Parser<A> {
    return Parser { .failure(message: message, remainder: $0) }
}

/// Match a single Character that satisfies the predicate. Consumes
/// one character on success.
public func satisfy(_ name: String, _ predicate: @escaping (Character) -> Bool) -> Parser<Character> {
    return Parser { input in
        guard let first = input.first, predicate(first) else {
            return .failure(message: "expected \(name)", remainder: input)
        }
        return .success(value: first, remainder: input.dropFirst())
    }
}

/// Match a specific character.
public func char(_ c: Character) -> Parser<Character> {
    return satisfy("'\(c)'") { $0 == c }
}

/// Match any of the given characters.
public func oneOf(_ chars: String) -> Parser<Character> {
    let set = Set(chars)
    return satisfy("one of '\(chars)'") { set.contains($0) }
}

/// Match any character NOT in the given set.
public func noneOf(_ chars: String) -> Parser<Character> {
    let set = Set(chars)
    return satisfy("none of '\(chars)'") { !set.contains($0) }
}

/// Match a literal string. Consumes exactly its length on success.
public func string(_ s: String) -> Parser<String> {
    return Parser { input in
        guard input.hasPrefix(s) else {
            return .failure(message: "expected \"\(s)\"", remainder: input)
        }
        return .success(value: s, remainder: input.dropFirst(s.count))
    }
}

/// Match end of input.
public let eof: Parser<Void> = Parser { input in
    if input.isEmpty {
        return .success(value: (), remainder: input)
    }
    return .failure(message: "expected end of input", remainder: input)
}

// MARK: - Combinators

infix operator <|> : LogicalDisjunctionPrecedence

/// Try `lhs`; if it fails, try `rhs`. Backtracks the input on failure
/// (by virtue of `Parser` not mutating its argument).
public func <|> <A>(lhs: Parser<A>, rhs: Parser<A>) -> Parser<A> {
    return Parser { input in
        let r = lhs.parse(input)
        if r.isSuccess { return r }
        return rhs.parse(input)
    }
}

/// Sequence two parsers, returning a tuple of their results.
public func seq2<A, B>(_ pa: Parser<A>, _ pb: Parser<B>) -> Parser<(A, B)> {
    return pa.flatMap { a in pb.map { b in (a, b) } }
}

/// Sequence three parsers.
public func seq3<A, B, C>(_ pa: Parser<A>, _ pb: Parser<B>, _ pc: Parser<C>) -> Parser<(A, B, C)> {
    return pa.flatMap { a in pb.flatMap { b in pc.map { c in (a, b, c) } } }
}

/// Match `pa`, discard its result, then return `pb`'s result. Useful
/// for skipping markers.
public func then<A, B>(_ pa: Parser<A>, _ pb: Parser<B>) -> Parser<B> {
    return pa.flatMap { _ in pb }
}

/// Match `pa`, then `pb`, return `pa`'s result and discard `pb`'s.
public func thenSkip<A, B>(_ pa: Parser<A>, _ pb: Parser<B>) -> Parser<A> {
    return pa.flatMap { a in pb.map { _ in a } }
}

/// Run a parser between an opening and a closing parser, returning
/// only the inner value. Common idiom for delimited content (`"`text`"`,
/// `(content)`, etc.).
public func between<O, A, C>(_ open: Parser<O>, _ close: Parser<C>, _ inner: Parser<A>) -> Parser<A> {
    return open.flatMap { _ in inner.flatMap { v in close.map { _ in v } } }
}

/// Zero or more occurrences. Always succeeds (with `[]` if no match).
public func many<A>(_ p: Parser<A>) -> Parser<[A]> {
    return Parser { input in
        var values: [A] = []
        var current = input
        while true {
            switch p.parse(current) {
            case .success(let v, let r):
                // Guard against zero-consumption infinite loops:
                // if the parser succeeded without consuming any
                // input, stop. Otherwise we'd spin forever.
                if r.startIndex == current.startIndex { return .success(value: values, remainder: current) }
                values.append(v)
                current = r
            case .failure:
                return .success(value: values, remainder: current)
            }
        }
    }
}

/// One or more occurrences. Fails if zero matches.
public func many1<A>(_ p: Parser<A>) -> Parser<[A]> {
    return p.flatMap { first in many(p).map { rest in [first] + rest } }
}

/// Optional match — wraps `p`'s result in `A?`, returning `nil` on
/// failure. Always succeeds.
public func optional<A>(_ p: Parser<A>) -> Parser<A?> {
    return Parser { input in
        switch p.parse(input) {
        case .success(let v, let r): return .success(value: v as A?, remainder: r)
        case .failure: return .success(value: nil, remainder: input)
        }
    }
}

/// One or more `p` separated by `sep`. The separator's value is
/// discarded; only the `p` values are returned.
public func sepBy1<A, S>(_ p: Parser<A>, _ sep: Parser<S>) -> Parser<[A]> {
    return p.flatMap { first in
        many(then(sep, p)).map { rest in [first] + rest }
    }
}

/// Zero or more `p` separated by `sep`. Always succeeds.
public func sepBy<A, S>(_ p: Parser<A>, _ sep: Parser<S>) -> Parser<[A]> {
    return sepBy1(p, sep) <|> pure([])
}

/// Match `p` without consuming input. Used for predictive parsing
/// (peek). Always returns `p`'s result on success; failure preserved.
public func lookahead<A>(_ p: Parser<A>) -> Parser<A> {
    return Parser { input in
        switch p.parse(input) {
        case .success(let v, _): return .success(value: v, remainder: input)
        case .failure(let m, _): return .failure(message: m, remainder: input)
        }
    }
}

/// Succeeds (consuming nothing) if `p` would FAIL. Used to express
/// "not followed by X" constraints, e.g. ensuring a horizontal rule
/// isn't actually a setext heading underline.
public func notFollowedBy<A>(_ p: Parser<A>) -> Parser<Void> {
    return Parser { input in
        switch p.parse(input) {
        case .success: return .failure(message: "unexpected match", remainder: input)
        case .failure: return .success(value: (), remainder: input)
        }
    }
}
