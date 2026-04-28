//
//  LinkResolverTests.swift
//  FSNotesTests
//
//  Phase 12.C.6.h — Link-in-link literalization (CommonMark §6.4
//  delimiter-stack algorithm). The spec corpus already pins the
//  end-to-end public-API behaviour for the five resolved cases via
//  `CommonMarkSpecTests.test_links`; these tests pin the resolver
//  directly so a regression in the resolution logic is caught
//  without depending on the rest of the parse pipeline.
//

import XCTest
@testable import FSNotes

final class LinkResolverTests: XCTestCase {

    private typealias Resolved = LinkResolver.ResolvedLink

    private func chars(_ s: String) -> [Character] { Array(s) }

    private func resolve(
        _ s: String,
        refDefs: [String: (url: String, title: String?)] = [:]
    ) -> [Resolved] {
        LinkResolver.resolve(chars: chars(s), codeSpanRanges: [], refDefs: refDefs)
    }

    // MARK: - §6.4 inactivation rule

    /// Spec #518: `[foo [bar](/uri)](/uri)` — the inner link resolves,
    /// the outer brackets become literal because of inactivation.
    func test_spec518_innerWinsOuterLiteralized() {
        let r = resolve("[foo [bar](/uri)](/uri)")
        XCTAssertEqual(r.count, 1)
        XCTAssertEqual(r[0].openCharIdx, 5)
        XCTAssertEqual(r[0].textStart, 6)
        XCTAssertEqual(r[0].textEnd, 9)
        XCTAssertEqual(r[0].dest, "/uri")
        XCTAssertFalse(r[0].isImage)
    }

    /// Spec #519: emphasis around the inner link doesn't unblock the
    /// outer brackets — the outer `[` is still inactive.
    func test_spec519_emphasisDoesNotResurrectOuter() {
        let r = resolve("[foo *[bar [baz](/uri)](/uri)*](/uri)")
        XCTAssertEqual(r.count, 1, "only the innermost link resolves")
        XCTAssertEqual(r[0].textEnd - r[0].textStart, 3, "matches `baz`")
        XCTAssertEqual(r[0].dest, "/uri")
    }

    /// Spec #520: image is `![` not `[`, so its opener stays active
    /// even though an inner `[`-link resolved and inactivated `[`
    /// openers earlier on the stack.
    func test_spec520_imageOpenerNotInactivatedByLink() {
        let r = resolve("![[[foo](uri1)](uri2)](uri3)")
        XCTAssertEqual(r.count, 2, "innermost link + outer image")
        // Sorted by openCharIdx ascending — image first (charIdx=0).
        XCTAssertEqual(r[0].openCharIdx, 0)
        XCTAssertTrue(r[0].isImage)
        XCTAssertEqual(r[0].dest, "uri3")
        // Inner link.
        XCTAssertEqual(r[1].openCharIdx, 3)
        XCTAssertFalse(r[1].isImage)
        XCTAssertEqual(r[1].dest, "uri1")
    }

    /// Spec #532: outer-ref form `[text][ref]` is also subject to
    /// inactivation — the inner inline link resolves first and
    /// inactivates the outer `[`, so the `[ref]` shortcut after the
    /// outer `]` becomes its own resolved ref-link rather than
    /// closing a non-link outer.
    func test_spec532_refLinkAfterInactivatedOuter() {
        let refDefs: [String: (url: String, title: String?)] = [
            "ref": (url: "/uri", title: nil)
        ]
        let r = resolve("[foo [bar](/uri)][ref]", refDefs: refDefs)
        XCTAssertEqual(r.count, 2)
        // Inner inline link.
        XCTAssertEqual(r[0].openCharIdx, 5)
        XCTAssertEqual(r[0].dest, "/uri")
        // Trailing shortcut ref-link `[ref]`.
        XCTAssertEqual(r[1].openCharIdx, 17)
        XCTAssertEqual(r[1].dest, "/uri")
    }

    /// Spec #533: same as #532 with emphasis around the inner link.
    func test_spec533_emphasisAroundInnerRefVariant() {
        let refDefs: [String: (url: String, title: String?)] = [
            "ref": (url: "/uri", title: nil)
        ]
        let r = resolve("[foo *bar [baz][ref]*][ref]", refDefs: refDefs)
        XCTAssertEqual(r.count, 2)
        // First — innermost shortcut ref `[baz][ref]` (openCharIdx=10).
        XCTAssertEqual(r[0].openCharIdx, 10)
        XCTAssertEqual(r[0].dest, "/uri")
        // Trailing shortcut ref `[ref]` after inactivated outer.
        XCTAssertEqual(r[1].openCharIdx, 22)
        XCTAssertEqual(r[1].dest, "/uri")
    }

    // MARK: - Sanity checks (regression floor)

    func test_basicLink_resolves() {
        let r = resolve("[text](url)")
        XCTAssertEqual(r.count, 1)
        XCTAssertEqual(r[0].openCharIdx, 0)
        XCTAssertEqual(r[0].textStart, 1)
        XCTAssertEqual(r[0].textEnd, 5)
        XCTAssertEqual(r[0].endCharIdx, 11)
        XCTAssertEqual(r[0].dest, "url")
        XCTAssertFalse(r[0].isImage)
    }

    func test_basicImage_resolves() {
        let r = resolve("![alt](img.png)")
        XCTAssertEqual(r.count, 1)
        XCTAssertEqual(r[0].openCharIdx, 0)
        XCTAssertEqual(r[0].textStart, 2, "image text starts after `![`")
        XCTAssertEqual(r[0].textEnd, 5, "textEnd is the `]` position")
        XCTAssertEqual(r[0].dest, "img.png")
        XCTAssertTrue(r[0].isImage)
    }

    func test_imageInsideLink_bothResolve() {
        // `[![alt](img)](url)` — the image is `![`, the outer `[`
        // resolves as a link. Image openers don't get inactivated.
        let r = resolve("[![alt](img)](url)")
        XCTAssertEqual(r.count, 2)
        // Sorted by openCharIdx ascending — outer `[` first.
        XCTAssertEqual(r[0].openCharIdx, 0)
        XCTAssertFalse(r[0].isImage)
        XCTAssertEqual(r[0].dest, "url")
        XCTAssertEqual(r[1].openCharIdx, 1)
        XCTAssertTrue(r[1].isImage)
        XCTAssertEqual(r[1].dest, "img")
    }

    func test_unresolvedBrackets_emitNoSpans() {
        XCTAssertEqual(resolve("[just text]").count, 0)
        XCTAssertEqual(resolve("[a][b]").count, 0,
                       "no refdefs → neither full-ref nor shortcut matches")
    }

    func test_shortcutRef_resolves() {
        let refDefs: [String: (url: String, title: String?)] = [
            "foo": (url: "/uri", title: nil)
        ]
        let r = resolve("[foo]", refDefs: refDefs)
        XCTAssertEqual(r.count, 1)
        XCTAssertEqual(r[0].openCharIdx, 0)
        XCTAssertEqual(r[0].endCharIdx, 5)
        XCTAssertEqual(r[0].dest, "/uri")
    }

    /// Spec #568 (already passing as of 12.C.6.e but pinned here for
    /// the resolver directly): a `]` followed by `(...)` that fails
    /// inline-body parsing falls through to the shortcut interpretation.
    func test_spec568_shortcutAfterFailedInlineBody() {
        let refDefs: [String: (url: String, title: String?)] = [
            "foo": (url: "/url1", title: nil)
        ]
        let r = resolve("[foo](not a link)", refDefs: refDefs)
        XCTAssertEqual(r.count, 1)
        XCTAssertEqual(r[0].openCharIdx, 0)
        XCTAssertEqual(r[0].endCharIdx, 5,
                       "shortcut consumes `[foo]` only — `(not a link)` is literal")
    }

    /// `[label]` after `]` rules out shortcut even when the label
    /// doesn't match a refdef — the construct is not a link.
    func test_fullRefMissLabel_doesNotFallToShortcut() {
        let refDefs: [String: (url: String, title: String?)] = [
            "foo": (url: "/uri", title: nil)
        ]
        let r = resolve("[foo][bar]", refDefs: refDefs)
        XCTAssertEqual(r.count, 0,
                       "[foo][bar] with no `bar` refdef is not a link, even though `foo` exists")
    }

    /// Code spans protect their bracket characters.
    func test_codeSpanProtectsBrackets() {
        let s = "[a `]` b](url)"
        let cs = MarkdownParserCodeSpanScanProbe.findRanges(s)
        let r = LinkResolver.resolve(chars: chars(s), codeSpanRanges: cs, refDefs: [:])
        XCTAssertEqual(r.count, 1)
        XCTAssertEqual(r[0].dest, "url")
    }

    /// `\[` and `\]` are escaped — they don't count as bracket delimiters.
    func test_escapedBrackets_doNotCount() {
        let r = resolve(#"\[not a link\]"#)
        XCTAssertEqual(r.count, 0)
    }
}

// Tiny helper to reach the private codeSpan scan from the test target.
// Phase 12.C.6.h tests need exactly the same `codeSpanRanges` shape the
// production tokenizer uses, so we ask `CodeSpanParser` directly.
private enum MarkdownParserCodeSpanScanProbe {
    static func findRanges(_ s: String) -> [(start: Int, end: Int)] {
        let chars = Array(s)
        var out: [(start: Int, end: Int)] = []
        var i = 0
        while i < chars.count {
            if chars[i] == "`", let m = CodeSpanParser.match(chars, from: i) {
                out.append((i, m.endIndex))
                i = m.endIndex
                continue
            }
            i += 1
        }
        return out
    }
}
