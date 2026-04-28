//
//  CombinatorPrimitivesTests.swift
//  FSNotesTests
//
//  Phase 12.C.1 — Parser combinator infrastructure tests.
//

import XCTest
@testable import FSNotes

final class CombinatorPrimitivesTests: XCTestCase {

    // MARK: - Primitives

    func test_pure_alwaysSucceeds() {
        let p: Parser<Int> = pure(42)
        guard case .success(let v, let r) = p.parse("abc") else {
            return XCTFail("pure should succeed")
        }
        XCTAssertEqual(v, 42)
        XCTAssertEqual(String(r), "abc", "pure consumes nothing")
    }

    func test_fail_alwaysFails() {
        let p: Parser<Int> = fail("nope")
        guard case .failure(let m, let r) = p.parse("abc") else {
            return XCTFail("fail should fail")
        }
        XCTAssertEqual(m, "nope")
        XCTAssertEqual(String(r), "abc", "fail consumes nothing")
    }

    func test_satisfy_consumesOnePredicateMatch() {
        let p = satisfy("digit") { $0.isNumber }
        guard case .success(let v, let r) = p.parse("3abc") else {
            return XCTFail("expected digit match")
        }
        XCTAssertEqual(v, "3")
        XCTAssertEqual(String(r), "abc")
    }

    func test_satisfy_failsOnEmpty() {
        let p = satisfy("anything") { _ in true }
        guard case .failure = p.parse("") else {
            return XCTFail("should fail on empty input")
        }
    }

    func test_char_matchesExact() {
        let p = char("a")
        XCTAssertTrue(p.parse("abc").isSuccess)
        XCTAssertFalse(p.parse("xyz").isSuccess)
    }

    func test_oneOf_matchesAnyInSet() {
        let p = oneOf("xyz")
        XCTAssertTrue(p.parse("yes").isSuccess)
        XCTAssertFalse(p.parse("abc").isSuccess)
    }

    func test_noneOf_matchesAnyOutsideSet() {
        let p = noneOf("xyz")
        XCTAssertTrue(p.parse("abc").isSuccess)
        XCTAssertFalse(p.parse("xyz").isSuccess)
    }

    func test_string_matchesLiteralPrefix() {
        let p = string("hello")
        guard case .success(let v, let r) = p.parse("hello, world") else {
            return XCTFail()
        }
        XCTAssertEqual(v, "hello")
        XCTAssertEqual(String(r), ", world")
        XCTAssertFalse(p.parse("help").isSuccess)
    }

    func test_eof_succeedsOnEmpty() {
        XCTAssertTrue(eof.parse("").isSuccess)
        XCTAssertFalse(eof.parse("x").isSuccess)
    }

    // MARK: - Combinators

    func test_map_transformsValue() {
        let p = char("3").map { _ in 99 }
        guard case .success(let v, _) = p.parse("3x") else { return XCTFail() }
        XCTAssertEqual(v, 99)
    }

    func test_alternative_picksFirstSuccess() {
        let p = char("a") <|> char("b")
        XCTAssertTrue(p.parse("apple").isSuccess)
        XCTAssertTrue(p.parse("banana").isSuccess)
        XCTAssertFalse(p.parse("zebra").isSuccess)
    }

    func test_alternative_backtracksToSecond() {
        // string("foo") consumes nothing on failure (input is preserved
        // because parse closure doesn't mutate). The second alternative
        // should see the original input.
        let p = string("foo") <|> string("bar")
        guard case .success(let v, _) = p.parse("barbaz") else { return XCTFail() }
        XCTAssertEqual(v, "bar")
    }

    func test_seq2_concatenates() {
        let p = seq2(char("a"), char("b"))
        guard case .success(let v, let r) = p.parse("abc") else { return XCTFail() }
        XCTAssertEqual(v.0, "a"); XCTAssertEqual(v.1, "b")
        XCTAssertEqual(String(r), "c")
    }

    func test_then_dropsLeft() {
        let p = then(char("("), char("X"))
        guard case .success(let v, _) = p.parse("(X)") else { return XCTFail() }
        XCTAssertEqual(v, "X")
    }

    func test_thenSkip_dropsRight() {
        let p = thenSkip(char("X"), char(")"))
        guard case .success(let v, _) = p.parse("X)") else { return XCTFail() }
        XCTAssertEqual(v, "X")
    }

    func test_between_dropsBothEdges() {
        let p = between(char("("), char(")"), many1(noneOf(")")).map { String($0) })
        guard case .success(let v, _) = p.parse("(hello)") else { return XCTFail() }
        XCTAssertEqual(v, "hello")
    }

    func test_many_zeroOrMore() {
        let p = many(char("a"))
        guard case .success(let v1, _) = p.parse("") else { return XCTFail() }
        XCTAssertEqual(v1.count, 0)
        guard case .success(let v2, _) = p.parse("aaab") else { return XCTFail() }
        XCTAssertEqual(v2.count, 3)
    }

    func test_many1_oneOrMore_failsOnZero() {
        let p = many1(char("a"))
        XCTAssertFalse(p.parse("bbb").isSuccess)
        guard case .success(let v, _) = p.parse("aab") else { return XCTFail() }
        XCTAssertEqual(v.count, 2)
    }

    func test_many_doesNotInfiniteLoop_onZeroConsumption() {
        // A parser that always succeeds without consuming would loop
        // forever inside `many` if the guard isn't honoured.
        let zero: Parser<Int> = pure(1)
        guard case .success(let v, _) = many(zero).parse("xyz") else { return XCTFail() }
        XCTAssertEqual(v.count, 0, "many on zero-consumption parser must stop, returning empty")
    }

    func test_optional_succeedsEvenOnFailure() {
        let p: Parser<Character?> = optional(char("a"))
        guard case .success(let v1, _) = p.parse("apple") else { return XCTFail() }
        XCTAssertEqual(v1, "a")
        guard case .success(let v2, _) = p.parse("xyz") else { return XCTFail() }
        XCTAssertNil(v2)
    }

    func test_sepBy1_collectsValuesAcrossSeparators() {
        let p = sepBy1(many1(satisfy("alpha") { $0.isLetter }).map { String($0) }, char(","))
        guard case .success(let v, _) = p.parse("a,bc,def") else { return XCTFail() }
        XCTAssertEqual(v, ["a", "bc", "def"])
    }

    func test_sepBy_succeedsOnEmpty() {
        let p = sepBy(char("a"), char(","))
        guard case .success(let v, _) = p.parse("xyz") else { return XCTFail() }
        XCTAssertEqual(v.count, 0)
    }

    func test_lookahead_doesNotConsume() {
        let p = lookahead(string("hello"))
        guard case .success(let v, let r) = p.parse("hello, world") else { return XCTFail() }
        XCTAssertEqual(v, "hello")
        XCTAssertEqual(String(r), "hello, world", "lookahead must not consume")
    }

    func test_notFollowedBy_succeedsWhenPredicateFails() {
        let p = notFollowedBy(char("X"))
        XCTAssertTrue(p.parse("apple").isSuccess)
        XCTAssertFalse(p.parse("Xapple").isSuccess)
    }

    // MARK: - parseAll

    func test_parseAll_failsOnUnconsumedInput() {
        let p = string("hello")
        XCTAssertFalse(p.parseAll("hello, world").isSuccess)
        XCTAssertTrue(p.parseAll("hello").isSuccess)
    }

    // MARK: - Composition smoke test: parse `"key=value"` pairs

    func test_composition_parseKeyValuePair() {
        let key = many1(satisfy("alpha") { $0.isLetter }).map { String($0) }
        let value = many1(satisfy("alphanum") { $0.isLetter || $0.isNumber }).map { String($0) }
        let pair = seq3(key, char("="), value)
        guard case .success(let v, _) = pair.parse("name=test42") else { return XCTFail() }
        XCTAssertEqual(v.0, "name")
        XCTAssertEqual(v.1, "=")
        XCTAssertEqual(v.2, "test42")
    }
}
