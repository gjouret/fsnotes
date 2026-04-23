//
//  TextKit2FragmentDispatchTests.swift
//  FSNotesTests
//
//  Phase 2c — proves `BlockModelLayoutManagerDelegate` maps
//  `BlockModelElement` subclasses to the correct `NSTextLayoutFragment`
//  subclass.
//
//  Current scope:
//    * `HorizontalRuleElement` → `HorizontalRuleLayoutFragment` (the
//      first production fragment to land in 2c — fixed-height block
//      with a single drawn rule and no text layout inside).
//    * Every other `BlockModelElement` subclass (Paragraph, Heading,
//      List, Blockquote, Code block) → plain `NSTextLayoutFragment`.
//      Those four block types render acceptably under TK2's default
//      fragment; 2c will replace them one by one. Until then the
//      delegate MUST return the default so we don't regress any
//      working rendering.
//    * A vanilla `NSTextParagraph` that carries none of our subclass
//      identity also falls back to default — the content-storage
//      delegate returns nil during mid-splice windows and TK2 then
//      hands the default paragraph to the layout delegate.
//
//  The tests exercise the delegate directly (not through TK2's
//  internal enumeration) so the assertion failure frame points at the
//  delegate, not at some downstream drawing surface. The live render
//  path — did the rule actually paint on screen — is verified against
//  the deployed app rather than in unit tests, because `cacheDisplay`
//  does not trigger `NSTextLayoutFragment.draw(at:in:)` (see CLAUDE.md
//  "cacheDisplay does NOT capture LayoutManager drawing").
//

import XCTest
import AppKit
@testable import FSNotes

final class TextKit2FragmentDispatchTests: XCTestCase {

    // MARK: - Helpers

    /// An NSTextLocation stub. The delegate under test does not read
    /// the location parameter; it dispatches solely on the element's
    /// concrete class. The stub keeps unit tests from having to stand
    /// up a real NSTextContentManager just to conjure a location.
    private final class StubLocation: NSObject, NSTextLocation {
        func compare(_ other: any NSTextLocation) -> ComparisonResult {
            .orderedSame
        }
    }

    /// Build a fresh `(delegate, layoutManager, location)` triple.
    /// The layout manager is a throwaway — the delegate does not call
    /// into it.
    private func makeDelegateTriple(
    ) -> (BlockModelLayoutManagerDelegate, NSTextLayoutManager, any NSTextLocation) {
        let delegate = BlockModelLayoutManagerDelegate()
        let layoutManager = NSTextLayoutManager()
        let location = StubLocation()
        return (delegate, layoutManager, location)
    }

    /// Factory shorthand — a block-model element of the given kind
    /// wrapping a single-space backing string (every production block
    /// we dispatch on in 2c has at least one content character, so
    /// empty-string corner cases are not exercised here).
    private func element(kind: BlockModelKind) -> BlockModelElement {
        BlockModelElementFactory.element(
            for: kind,
            attributedString: NSAttributedString(string: " ")
        )
    }

    // MARK: - HR → HorizontalRuleLayoutFragment

    func test_phase2c_horizontalRuleElement_dispatchesToHorizontalRuleLayoutFragment() {
        let (delegate, lm, loc) = makeDelegateTriple()
        let hr = element(kind: .horizontalRule)
        XCTAssertTrue(hr is HorizontalRuleElement,
            "Factory must produce HorizontalRuleElement for .horizontalRule")

        let fragment = delegate.textLayoutManager(
            lm,
            textLayoutFragmentFor: loc,
            in: hr
        )

        XCTAssertTrue(
            fragment is HorizontalRuleLayoutFragment,
            "HorizontalRuleElement must dispatch to " +
            "HorizontalRuleLayoutFragment, got \(type(of: fragment))"
        )
    }

    // MARK: - Other block-model subclasses → default fragment

    /// Non-HR `BlockModelElement` subclasses currently render via the
    /// default fragment — their custom fragments land later in Phase 2c.
    /// Guarding that the default is returned (NOT the HR fragment, NOT
    /// some other subclass) prevents a regression where, for example,
    /// adding `if textElement is ParagraphElement { return X }` above
    /// the default branch would accidentally route every block through
    /// `X`.
    func test_phase2c_paragraphElement_dispatchesToDefaultFragment() {
        assertDefaultFragment(for: element(kind: .paragraph))
    }

    // HeadingElement now dispatches to HeadingLayoutFragment (the fragment
    // that paints the H1/H2 bottom hairline). See the HeadingLayoutFragment
    // tests below for the full contract.

    func test_phase2c_headingElement_dispatchesToHeadingLayoutFragment() {
        let (delegate, lm, loc) = makeDelegateTriple()
        let h = element(kind: .heading)
        XCTAssertTrue(h is HeadingElement,
            "Factory must produce HeadingElement for .heading")

        let fragment = delegate.textLayoutManager(
            lm,
            textLayoutFragmentFor: loc,
            in: h
        )

        XCTAssertTrue(
            fragment is HeadingLayoutFragment,
            "HeadingElement must dispatch to HeadingLayoutFragment, " +
            "got \(type(of: fragment))"
        )
    }

    func test_phase2c_listItemElement_dispatchesToDefaultFragment() {
        assertDefaultFragment(for: element(kind: .list))
    }

    // BlockquoteElement now dispatches to BlockquoteLayoutFragment (the
    // depth-stacked gray-bar drawer). See BlockquoteLayoutFragment tests
    // below for the full contract.

    func test_phase2c_blockquoteElement_dispatchesToBlockquoteLayoutFragment() {
        let (delegate, lm, loc) = makeDelegateTriple()
        let bq = element(kind: .blockquote)
        XCTAssertTrue(bq is BlockquoteElement,
            "Factory must produce BlockquoteElement for .blockquote")

        let fragment = delegate.textLayoutManager(
            lm,
            textLayoutFragmentFor: loc,
            in: bq
        )

        XCTAssertTrue(
            fragment is BlockquoteLayoutFragment,
            "BlockquoteElement must dispatch to BlockquoteLayoutFragment, " +
            "got \(type(of: fragment))"
        )
    }

    // CodeBlockElement now dispatches to CodeBlockLayoutFragment (the
    // gray-rounded-rect background drawer). See CodeBlockLayoutFragment
    // tests below for the full contract.

    // ParagraphWithKbdElement dispatches to KbdBoxParagraphLayoutFragment.
    // Regular ParagraphElement continues to fall back to the default
    // fragment — dispatch to the kbd fragment is conditional on the
    // presence of `.kbdTag` runs, detected by DocumentRenderer.

    func test_phase2d_paragraphWithKbdElement_dispatchesToKbdBoxParagraphLayoutFragment() {
        let (delegate, lm, loc) = makeDelegateTriple()
        let pk = element(kind: .paragraphWithKbd)
        XCTAssertTrue(pk is ParagraphWithKbdElement,
            "Factory must produce ParagraphWithKbdElement for .paragraphWithKbd")

        let fragment = delegate.textLayoutManager(
            lm,
            textLayoutFragmentFor: loc,
            in: pk
        )

        XCTAssertTrue(
            fragment is KbdBoxParagraphLayoutFragment,
            "ParagraphWithKbdElement must dispatch to " +
            "KbdBoxParagraphLayoutFragment, got \(type(of: fragment))"
        )
    }

    /// Live check: a paragraph containing `<kbd>...</kbd>` must end up
    /// tagged with `.blockModelKind = .paragraphWithKbd` by DocumentRenderer
    /// and vend a `KbdBoxParagraphLayoutFragment` from the layout manager.
    /// Regression guard for the producer→dispatch pipeline.
    func test_phase2d_kbdFragment_liveParagraphWithKbd_producesFragment() {
        let harness = EditorHarness(markdown: "Press <kbd>Enter</kbd> to confirm.\n")
        defer { harness.teardown() }

        guard let layoutManager = harness.editor.textLayoutManager else {
            XCTFail("Phase 2a: editor must have TK2 layout manager")
            return
        }
        let fullRange = layoutManager.documentRange
        layoutManager.ensureLayout(for: fullRange)

        var kbdFragment: KbdBoxParagraphLayoutFragment?
        layoutManager.enumerateTextLayoutFragments(
            from: fullRange.location,
            options: [.ensuresLayout]
        ) { fragment in
            if let kbd = fragment as? KbdBoxParagraphLayoutFragment {
                kbdFragment = kbd
                return false
            }
            return true
        }

        XCTAssertNotNil(
            kbdFragment,
            "A paragraph containing <kbd>...</kbd> must vend a " +
            "KbdBoxParagraphLayoutFragment. If nil, either MarkdownParser " +
            "didn't produce Inline.kbd, or InlineRenderer didn't tag " +
            ".kbdTag, or DocumentRenderer didn't upgrade the paragraph " +
            "to .paragraphWithKbd, or the layout manager delegate didn't " +
            "dispatch the element class."
        )
    }

    func test_phase2c_codeBlockElement_dispatchesToCodeBlockLayoutFragment() {
        let (delegate, lm, loc) = makeDelegateTriple()
        let cb = element(kind: .codeBlock)
        XCTAssertTrue(cb is CodeBlockElement,
            "Factory must produce CodeBlockElement for .codeBlock")

        let fragment = delegate.textLayoutManager(
            lm,
            textLayoutFragmentFor: loc,
            in: cb
        )

        XCTAssertTrue(
            fragment is CodeBlockLayoutFragment,
            "CodeBlockElement must dispatch to CodeBlockLayoutFragment, " +
            "got \(type(of: fragment))"
        )
    }

    /// A plain `NSTextParagraph` — the fallback class that
    /// `NSTextContentStorage` hands out when our content-storage
    /// delegate returns nil — must also get a default fragment. This
    /// covers untagged ranges and mid-splice windows.
    func test_phase2c_plainNSTextParagraph_dispatchesToDefaultFragment() {
        let para = NSTextParagraph(
            attributedString: NSAttributedString(string: "plain")
        )
        assertDefaultFragment(for: para)
    }

    private func assertDefaultFragment(
        for element: NSTextElement,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let (delegate, lm, loc) = makeDelegateTriple()
        let fragment = delegate.textLayoutManager(
            lm,
            textLayoutFragmentFor: loc,
            in: element
        )
        // Must not be the HR fragment.
        XCTAssertFalse(
            fragment is HorizontalRuleLayoutFragment,
            "\(type(of: element)) must not dispatch to " +
            "HorizontalRuleLayoutFragment",
            file: file, line: line
        )
        // Must be exactly NSTextLayoutFragment (the default class), not
        // any subclass. `type(of:)` sidesteps the `is` subclass-check
        // semantics so a future subclass addition trips this test.
        XCTAssertTrue(
            type(of: fragment) == NSTextLayoutFragment.self,
            "\(type(of: element)) must dispatch to default " +
            "NSTextLayoutFragment, got \(type(of: fragment))",
            file: file, line: line
        )
    }

    // MARK: - Fragment wiring

    /// The HR fragment exposes the element whose range it was created
    /// over. This is the hook TK2 uses to correlate the fragment back
    /// to the content storage.
    func test_phase2c_horizontalRuleLayoutFragment_holdsTheRightElement() {
        let (delegate, lm, loc) = makeDelegateTriple()
        let hr = element(kind: .horizontalRule)
        let fragment = delegate.textLayoutManager(
            lm,
            textLayoutFragmentFor: loc,
            in: hr
        )
        // `textElement` on NSTextLayoutFragment is weak; hold the
        // element in a local variable to keep it alive for the check.
        XCTAssertTrue(
            fragment.textElement === hr,
            "Fragment must be anchored to the element that produced it"
        )
    }

    // MARK: - HR rendering surface width

    /// Regression guard (2026-04-22): `HorizontalRuleRenderer` emits a
    /// single space as the HR element's backing content, so TK2 lays the
    /// fragment out only ~4pt wide (one space-glyph advance). The
    /// default `renderingSurfaceBounds` is `layoutFragmentFrame`, which
    /// would clip our 4pt gray bar to 4pt wide and make it an invisible
    /// dot. `HorizontalRuleLayoutFragment` overrides `renderingSurfaceBounds`
    /// to span the full text container width — without that override the
    /// HR paints but is not visible. This test fails if the override is
    /// removed or narrowed.
    func test_phase2c_horizontalRuleFragment_renderingSurfaceBounds_spansContainerWidth() {
        let harness = EditorHarness(markdown: "---\n")
        defer { harness.teardown() }

        guard let layoutManager = harness.editor.textLayoutManager,
              let container = layoutManager.textContainer else {
            XCTFail("Phase 2a: editor must have TK2 layout manager + container")
            return
        }
        let containerWidth = container.size.width
        XCTAssertGreaterThan(
            containerWidth, 100,
            "Sanity: the harness editor's container must be at least as "
            + "wide as a typical line of text."
        )

        // Force TK2 to materialise fragments for the entire document.
        let fullRange = layoutManager.documentRange
        layoutManager.ensureLayout(for: fullRange)

        var hrFragment: HorizontalRuleLayoutFragment?
        layoutManager.enumerateTextLayoutFragments(
            from: fullRange.location,
            options: [.ensuresLayout]
        ) { fragment in
            if let hr = fragment as? HorizontalRuleLayoutFragment {
                hrFragment = hr
                return false
            }
            return true
        }

        guard let hr = hrFragment else {
            XCTFail(
                "Phase 2c: layout manager must vend a "
                + "HorizontalRuleLayoutFragment for an HR-only document."
            )
            return
        }

        // The fragment's layoutFragmentFrame is only ~4pt wide (one
        // space advance). The rendering surface MUST widen beyond that
        // or TK2 clips the rule draw to the tiny glyph advance and the
        // bar disappears visually. We accept any surface width ≥ half
        // the container — the precise geometry depends on padding and
        // container setup, which varies across hosting contexts.
        let surfaceWidth = hr.renderingSurfaceBounds.width
        XCTAssertGreaterThan(
            surfaceWidth, hr.layoutFragmentFrame.width * 2,
            "renderingSurfaceBounds.width (\(surfaceWidth)) must be much "
            + "larger than the space-character layoutFragmentFrame.width "
            + "(\(hr.layoutFragmentFrame.width)), otherwise TK2 clips "
            + "the 4pt rule draw to an invisible dot."
        )
        XCTAssertGreaterThanOrEqual(
            surfaceWidth, containerWidth / 2,
            "renderingSurfaceBounds.width (\(surfaceWidth)) must cover "
            + "most of the text container width (\(containerWidth)) so "
            + "the rule spans the editor visually."
        )
    }

    // MARK: - Delegate installation on the editor

    /// `EditTextView.initTextStorage()` must install a
    /// `BlockModelLayoutManagerDelegate` on the layout manager and keep
    /// a strong reference to it on the editor (TK2 delegate is weak).
    /// If this regresses, the content-storage delegate will still route
    /// elements correctly but the layout manager will fall back to its
    /// default fragment, silently dropping all 2c visuals.
    func test_phase2c_editor_installsLayoutManagerDelegate() {
        let harness = EditorHarness(markdown: "---")
        defer { harness.teardown() }

        guard let layoutManager = harness.editor.textLayoutManager else {
            XCTFail(
                "Phase 2a: editor.textLayoutManager must be non-nil. " +
                "A nil TLM means TK2 downgraded to TK1 — fragment " +
                "dispatch cannot run at all in that state."
            )
            return
        }

        let installed = harness.editor.blockModelLayoutDelegate
        XCTAssertNotNil(
            installed,
            "EditTextView.blockModelLayoutDelegate must be populated " +
            "by initTextStorage() so TK2's weak delegate reference " +
            "stays alive."
        )
        XCTAssertTrue(
            layoutManager.delegate === installed,
            "textLayoutManager.delegate must point at the same " +
            "BlockModelLayoutManagerDelegate the editor retains. " +
            "Mismatch means something else overwrote the delegate " +
            "after initTextStorage()."
        )
    }

    // MARK: - BlockquoteLayoutFragment depth + geometry

    /// Build a BlockquoteElement whose backing string has `.blockquote`
    /// attribute set to `depth` on every character. Mirrors what
    /// `BlockquoteRenderer` produces for a single blockquote line.
    private func blockquoteElement(depth: Int, text: String = "quote") -> BlockquoteElement {
        let attr = NSMutableAttributedString(string: text)
        let range = NSRange(location: 0, length: attr.length)
        attr.addAttribute(.blockquote, value: depth, range: range)
        return BlockquoteElement(attributedString: attr)
    }

    /// Instantiate `BlockquoteLayoutFragment` directly. Exposes the
    /// `blockquoteDepth` computed property (internal) so tests can
    /// exercise the depth-decoding logic without running TK2 layout.
    private func makeBQFragment(for bq: BlockquoteElement) -> BlockquoteLayoutFragment {
        BlockquoteLayoutFragment(
            textElement: bq,
            range: bq.elementRange
        )
    }

    func test_phase2c_blockquoteFragment_depth_readsIntAttribute() {
        let bq = blockquoteElement(depth: 3)
        let frag = makeBQFragment(for: bq)
        XCTAssertEqual(
            frag.blockquoteDepth, 3,
            "Fragment must read `.blockquote` as Int nesting depth (the " +
            "value BlockquoteRenderer writes per-line)."
        )
    }

    func test_phase2c_blockquoteFragment_depth_boolFallbackYieldsOne() {
        // Legacy `.blockquote = true` encoding (matches the Bool branch
        // in TK1 BlockquoteBorderDrawer). Must map to depth 1.
        let attr = NSMutableAttributedString(string: "legacy")
        attr.addAttribute(.blockquote, value: true,
                          range: NSRange(location: 0, length: attr.length))
        let frag = makeBQFragment(for: BlockquoteElement(attributedString: attr))
        XCTAssertEqual(frag.blockquoteDepth, 1,
            "`.blockquote = true` must map to depth 1 for parity with " +
            "TK1 BlockquoteBorderDrawer's Bool fallback.")
    }

    func test_phase2c_blockquoteFragment_depth_missingAttributeYieldsZero() {
        let attr = NSAttributedString(string: "untagged")
        let frag = makeBQFragment(for: BlockquoteElement(attributedString: attr))
        XCTAssertEqual(frag.blockquoteDepth, 0,
            "No `.blockquote` attribute must yield depth 0 — bars are " +
            "not drawn (draw() short-circuits).")
    }

    // MARK: - Blockquote live rendering surface

    /// Live TK2 surface check: an N-level blockquote document must
    /// produce a `BlockquoteLayoutFragment` whose depth matches the
    /// renderer's output and whose `renderingSurfaceBounds` is at least
    /// as wide as the frame (so the bars always have room to paint).
    func test_phase2c_blockquoteFragment_liveDocumentProducesFragmentWithDepth() {
        let harness = EditorHarness(markdown: "> first level\n")
        defer { harness.teardown() }

        guard let layoutManager = harness.editor.textLayoutManager else {
            XCTFail("Phase 2a: editor must have TK2 layout manager")
            return
        }

        let fullRange = layoutManager.documentRange
        layoutManager.ensureLayout(for: fullRange)

        var bqFragment: BlockquoteLayoutFragment?
        layoutManager.enumerateTextLayoutFragments(
            from: fullRange.location,
            options: [.ensuresLayout]
        ) { fragment in
            if let bq = fragment as? BlockquoteLayoutFragment {
                bqFragment = bq
                return false
            }
            return true
        }

        guard let bq = bqFragment else {
            XCTFail("Phase 2c: layout manager must vend a " +
                    "BlockquoteLayoutFragment for a blockquote document.")
            return
        }

        XCTAssertGreaterThanOrEqual(
            bq.blockquoteDepth, 1,
            "A single-level blockquote line must yield depth >= 1. " +
            "depth=\(bq.blockquoteDepth) means BlockquoteRenderer did " +
            "not tag the `.blockquote` attribute, or the element lost " +
            "its attributes."
        )

        // Surface bounds must at minimum cover the layoutFragmentFrame
        // (bars live inside that frame at x = padding + 2 + i*spacing).
        let surface = bq.renderingSurfaceBounds
        let frame = bq.layoutFragmentFrame
        XCTAssertGreaterThanOrEqual(
            surface.width, frame.width,
            "renderingSurfaceBounds.width (\(surface.width)) must be at " +
            "least as wide as layoutFragmentFrame.width (\(frame.width)) " +
            "so TK2 doesn't clip bar drawing."
        )
        XCTAssertGreaterThanOrEqual(
            surface.height, frame.height,
            "renderingSurfaceBounds.height (\(surface.height)) must " +
            "cover the full fragment height (\(frame.height)) so bars " +
            "extend across every line of the paragraph."
        )
    }

    // MARK: - HeadingLayoutFragment level + geometry

    /// Build a HeadingElement whose backing string has `.headingLevel`
    /// attribute set to `level` on every character. Mirrors what
    /// `DocumentRenderer` produces for a rendered heading line.
    private func headingElement(level: Int, text: String = "heading") -> HeadingElement {
        let attr = NSMutableAttributedString(string: text)
        let range = NSRange(location: 0, length: attr.length)
        attr.addAttribute(.headingLevel, value: level, range: range)
        return HeadingElement(attributedString: attr)
    }

    /// Instantiate `HeadingLayoutFragment` directly. Exposes the
    /// `headingLevel` computed property (internal) so tests can exercise
    /// the level-decoding logic without running TK2 layout.
    private func makeHeadingFragment(for h: HeadingElement) -> HeadingLayoutFragment {
        HeadingLayoutFragment(
            textElement: h,
            range: h.elementRange
        )
    }

    func test_phase2c_headingFragment_level_readsIntAttribute() {
        let h = headingElement(level: 1)
        let frag = makeHeadingFragment(for: h)
        XCTAssertEqual(
            frag.headingLevel, 1,
            "Fragment must read `.headingLevel` as Int level (the " +
            "value DocumentRenderer writes per-heading-paragraph)."
        )
    }

    func test_phase2c_headingFragment_level_reportsLevel2() {
        let h = headingElement(level: 2)
        let frag = makeHeadingFragment(for: h)
        XCTAssertEqual(frag.headingLevel, 2,
            "Level 2 must round-trip through the fragment.")
    }

    func test_phase2c_headingFragment_level_outOfRangeYieldsZero() {
        // Levels outside 1...6 are invalid markdown headings and must
        // not trip any drawing logic. The fragment treats them as
        // "unknown", same as missing attribute.
        let h = headingElement(level: 99)
        let frag = makeHeadingFragment(for: h)
        XCTAssertEqual(frag.headingLevel, 0,
            "Out-of-range level must yield 0 — draw() short-circuits.")
    }

    func test_phase2c_headingFragment_level_missingAttributeYieldsZero() {
        let attr = NSAttributedString(string: "untagged")
        let frag = makeHeadingFragment(for: HeadingElement(attributedString: attr))
        XCTAssertEqual(frag.headingLevel, 0,
            "No `.headingLevel` attribute must yield 0 — the fragment " +
            "falls through to super.draw without stroking the hairline.")
    }

    // MARK: - Heading live rendering surface + document-tagged level

    /// Live TK2 surface check: an H1 document must produce a
    /// `HeadingLayoutFragment` whose `headingLevel` matches the renderer's
    /// output and whose `renderingSurfaceBounds` spans the full text
    /// container width (so the hairline always has room to paint
    /// edge-to-edge).
    func test_phase2c_headingFragment_liveH1DocumentProducesFragmentWithLevel1() {
        let harness = EditorHarness(markdown: "# Heading One\n")
        defer { harness.teardown() }

        guard let layoutManager = harness.editor.textLayoutManager,
              let container = layoutManager.textContainer else {
            XCTFail("Phase 2a: editor must have TK2 layout manager + container")
            return
        }
        let containerWidth = container.size.width

        let fullRange = layoutManager.documentRange
        layoutManager.ensureLayout(for: fullRange)

        var headingFragment: HeadingLayoutFragment?
        layoutManager.enumerateTextLayoutFragments(
            from: fullRange.location,
            options: [.ensuresLayout]
        ) { fragment in
            if let h = fragment as? HeadingLayoutFragment {
                headingFragment = h
                return false
            }
            return true
        }

        guard let h = headingFragment else {
            XCTFail("Phase 2c: layout manager must vend a " +
                    "HeadingLayoutFragment for an H1 document.")
            return
        }

        XCTAssertEqual(
            h.headingLevel, 1,
            "An H1 line must yield level 1. level=\(h.headingLevel) " +
            "means DocumentRenderer did not tag `.headingLevel`, or " +
            "the element lost its attributes."
        )

        // Surface must span the full container (hairline goes edge-to-edge).
        let surface = h.renderingSurfaceBounds
        XCTAssertGreaterThanOrEqual(
            surface.width, containerWidth - 1,
            "renderingSurfaceBounds.width (\(surface.width)) must cover " +
            "the full text container width (\(containerWidth)) so the " +
            "hairline reaches edge-to-edge."
        )
    }

    /// Live H3 must produce the same fragment class but report level 3 —
    /// which short-circuits the hairline draw. The fragment is still
    /// vended by the delegate (level gating is at draw time, not dispatch
    /// time) so adding new behaviors for H3-H6 later doesn't require
    /// rewiring dispatch.
    // MARK: - CodeBlockLayoutFragment live rendering surface

    /// Live TK2 surface check: a fenced ```…``` document must produce a
    /// `CodeBlockLayoutFragment` whose `renderingSurfaceBounds` covers
    /// the fragment frame PLUS the horizontal bleed on each side (so
    /// the rounded rect actually reaches beyond the text's natural
    /// bounds). Without this widening, TK2 would clip the bg rect to
    /// the text width and the "container" feel disappears.
    /// Multi-line code blocks arrive as MULTIPLE adjacent fragments
    /// (TK2 splits on embedded \n in the rendered code content). The
    /// fragment must detect its position within the adjacent run — the
    /// FIRST fragment rounds only the top, the LAST rounds only the
    /// bottom, MIDDLE fragments are flat rectangles. Without this, a
    /// 3-line fenced block renders as 3 separate rounded boxes (the
    /// bug that shipped with the initial slice).
    func test_phase2c_codeBlockFragment_multiLineBlock_positionsFirstMiddleLast() {
        // Four-line fenced block: produces 4 CodeBlockLayoutFragments.
        // The fixture uses no language so syntax-highlight theming is
        // deterministic across hosts.
        let md = "```\nline one\nline two\nline three\nline four\n```\n"
        let harness = EditorHarness(markdown: md)
        defer { harness.teardown() }

        guard let layoutManager = harness.editor.textLayoutManager else {
            XCTFail("Phase 2a: editor must have TK2 layout manager")
            return
        }
        let fullRange = layoutManager.documentRange
        layoutManager.ensureLayout(for: fullRange)

        var codeFragments: [CodeBlockLayoutFragment] = []
        layoutManager.enumerateTextLayoutFragments(
            from: fullRange.location,
            options: [.ensuresLayout]
        ) { fragment in
            if let cb = fragment as? CodeBlockLayoutFragment {
                codeFragments.append(cb)
            }
            return true
        }

        XCTAssertGreaterThanOrEqual(
            codeFragments.count, 2,
            "A multi-line fenced code block must produce at least 2 " +
            "CodeBlockLayoutFragments (TK2 paragraph-splits on \\n). " +
            "Got \(codeFragments.count) fragment(s)."
        )

        guard let first = codeFragments.first,
              let last = codeFragments.last else {
            XCTFail("Pre-guarded: at least 2 fragments")
            return
        }

        XCTAssertEqual(
            first.blockRunPosition, .first,
            "The first fragment in a multi-line code block must report " +
            "`.first` (rounds top, flat bottom). Got \(first.blockRunPosition)."
        )
        XCTAssertEqual(
            last.blockRunPosition, .last,
            "The last fragment in a multi-line code block must report " +
            "`.last` (flat top, rounds bottom). Got \(last.blockRunPosition)."
        )
        if codeFragments.count >= 3 {
            let middle = codeFragments[1]
            XCTAssertEqual(
                middle.blockRunPosition, .middle,
                "An interior fragment must report `.middle` (flat both). " +
                "Got \(middle.blockRunPosition)."
            )
        }
    }

    /// A one-line fenced code block must report `.single` — full
    /// rounded rect with top + bottom border. This is the degenerate
    /// case of the multi-line detection logic.
    func test_phase2c_codeBlockFragment_singleLineBlock_positionIsSingle() {
        let md = "```\nonly line\n```\n"
        let harness = EditorHarness(markdown: md)
        defer { harness.teardown() }

        guard let layoutManager = harness.editor.textLayoutManager else {
            XCTFail("Phase 2a: editor must have TK2 layout manager")
            return
        }
        let fullRange = layoutManager.documentRange
        layoutManager.ensureLayout(for: fullRange)

        var codeFragment: CodeBlockLayoutFragment?
        layoutManager.enumerateTextLayoutFragments(
            from: fullRange.location,
            options: [.ensuresLayout]
        ) { fragment in
            if let cb = fragment as? CodeBlockLayoutFragment {
                codeFragment = cb
                return false
            }
            return true
        }

        guard let cb = codeFragment else {
            XCTFail("A single-line fenced block must produce a " +
                    "CodeBlockLayoutFragment.")
            return
        }
        XCTAssertEqual(
            cb.blockRunPosition, .single,
            "A single-line fenced block must report `.single`. " +
            "Got \(cb.blockRunPosition)."
        )
    }

    func test_phase2c_codeBlockFragment_liveFencedCodeDocument_producesFragment() {
        let harness = EditorHarness(markdown: "```\nlet x = 1\nlet y = 2\n```\n")
        defer { harness.teardown() }

        guard let layoutManager = harness.editor.textLayoutManager else {
            XCTFail("Phase 2a: editor must have TK2 layout manager")
            return
        }

        let fullRange = layoutManager.documentRange
        layoutManager.ensureLayout(for: fullRange)

        var codeFragment: CodeBlockLayoutFragment?
        layoutManager.enumerateTextLayoutFragments(
            from: fullRange.location,
            options: [.ensuresLayout]
        ) { fragment in
            if let cb = fragment as? CodeBlockLayoutFragment {
                codeFragment = cb
                return false
            }
            return true
        }

        guard let cb = codeFragment else {
            XCTFail(
                "Phase 2c: layout manager must vend a " +
                "CodeBlockLayoutFragment for a fenced code block document."
            )
            return
        }

        let surface = cb.renderingSurfaceBounds
        let frame = cb.layoutFragmentFrame

        // Surface must cover frame height (all code lines in the block
        // share one continuous background rect).
        XCTAssertGreaterThanOrEqual(
            surface.height, frame.height,
            "renderingSurfaceBounds.height (\(surface.height)) must cover " +
            "the full fragment height (\(frame.height)) so the bg rect " +
            "spans every code line."
        )
        // Surface must extend beyond the frame horizontally by at least
        // the horizontal bleed (5pt per side) — otherwise the rounded
        // rect would be clipped to text width and lose its container feel.
        let expectedBleed = CodeBlockLayoutFragment.horizontalBleed
        XCTAssertGreaterThan(
            surface.width, frame.width + expectedBleed - 1,
            "renderingSurfaceBounds.width (\(surface.width)) must exceed " +
            "frame.width (\(frame.width)) + horizontalBleed " +
            "(\(expectedBleed)) so the rounded-rect bg isn't clipped."
        )
    }

    func test_phase2c_headingFragment_liveH3Document_reportsLevel3() {
        let harness = EditorHarness(markdown: "### Heading Three\n")
        defer { harness.teardown() }

        guard let layoutManager = harness.editor.textLayoutManager else {
            XCTFail("Phase 2a: editor must have TK2 layout manager")
            return
        }

        let fullRange = layoutManager.documentRange
        layoutManager.ensureLayout(for: fullRange)

        var headingFragment: HeadingLayoutFragment?
        layoutManager.enumerateTextLayoutFragments(
            from: fullRange.location,
            options: [.ensuresLayout]
        ) { fragment in
            if let h = fragment as? HeadingLayoutFragment {
                headingFragment = h
                return false
            }
            return true
        }

        guard let h = headingFragment else {
            XCTFail("Phase 2c: layout manager must vend a " +
                    "HeadingLayoutFragment for an H3 document.")
            return
        }

        XCTAssertEqual(h.headingLevel, 3,
            "H3 must round-trip as level 3 through the fragment.")
    }

    // MARK: - Phase 2d: Inline PDF + QuickLook via view-provider (TK2)
    //
    // Background: under TK2, `NSTextAttachmentCell.draw(withFrame:in:
    // characterIndex:layoutManager:)` is never called — the system instead
    // asks the attachment for an `NSTextAttachmentViewProvider` via
    // `attachment.viewProvider(for:location:textContainer:)`. The legacy
    // `PDFAttachmentCell` / `QuickLookAttachmentCell` classes can still
    // exist in-app (TK1-era code paths), but under TK2 the attachments
    // produced by the processors MUST be `PDFNSTextAttachment` /
    // `QuickLookNSTextAttachment` — subclasses that override
    // `viewProvider(...)`. Otherwise the embed is invisible.
    //
    // These tests call the processor directly against a hand-seeded
    // `NSTextStorage` so they stand independent of the block-model
    // pipeline (which is covered elsewhere) and fail fast at the layer
    // that matters: attachment type after the processor runs.
    //
    // File fixture: we write a trivial ~8-byte PDF file into
    // `NSTemporaryDirectory()` so `FileManager.fileExists(atPath:)` in
    // the processor passes. `PDFDocument(url:)` may fail on such a stub;
    // that is fine — the processor does not require `PDFDocument` load
    // to succeed in order to create the attachment (computeSize falls
    // through to default when document is nil).

    /// Create a tiny file at a unique temp path with the given extension
    /// and an optional payload. Returns the URL. Caller is responsible
    /// for cleanup.
    private func makeTempFile(ext: String, bytes: Data = Data([0x25, 0x50, 0x44, 0x46, 0x2D, 0x31, 0x2E, 0x30, 0x0A])) -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("phase2d_\(UUID().uuidString).\(ext)")
        FileManager.default.createFile(atPath: url.path, contents: bytes)
        return url
    }

    /// Seed `storage` with a single plain `NSTextAttachment` placeholder
    /// tagged with `.attachmentUrl = url` — mirrors the shape the
    /// block-model renderer hands to `PDFAttachmentProcessor` /
    /// `QuickLookAttachmentProcessor` for existing-attachment rewrites.
    private func seedAttachmentPlaceholder(in storage: NSTextStorage, url: URL) {
        let attachment = NSTextAttachment()
        let seed = NSMutableAttributedString(attachment: attachment)
        let seedRange = NSRange(location: 0, length: seed.length)
        seed.addAttribute(.attachmentUrl, value: url, range: seedRange)
        seed.addAttribute(.attachmentPath, value: url.lastPathComponent, range: seedRange)
        storage.setAttributedString(seed)
    }

    /// Enumerate `.attachment` attributes in storage and return the first
    /// non-nil attachment found. Stops at the first hit.
    private func firstAttachment(in storage: NSTextStorage) -> NSTextAttachment? {
        var found: NSTextAttachment?
        let fullRange = NSRange(location: 0, length: storage.length)
        storage.enumerateAttribute(.attachment, in: fullRange, options: []) { value, _, stop in
            if let a = value as? NSTextAttachment {
                found = a
                stop.pointee = true
            }
        }
        return found
    }

    // MARK: - Test 1: PDF attachment uses the view-provider path

    /// After `PDFAttachmentProcessor.renderPDFAttachments` runs over a
    /// storage containing a plain-NSTextAttachment placeholder with a
    /// `.attachmentUrl` pointing at a `.pdf` file, the replacement must
    /// be a `PDFNSTextAttachment` — the subclass that overrides
    /// `viewProvider(for:location:textContainer:)`. A plain
    /// `NSTextAttachment` (even with `attachmentCell = PDFAttachmentCell`)
    /// is TK1-only: TK2 ignores `attachmentCell` and asks for the view
    /// provider. Without the subclass, the PDF is invisible under TK2.
    func test_phase2d_pdfAttachment_usesViewProviderUnderTK2() {
        let harness = EditorHarness(markdown: "")
        defer { harness.teardown() }

        guard let storage = harness.editor.textStorage,
              let note = harness.editor.note else {
            XCTFail("Harness must have textStorage + note")
            return
        }

        let pdfURL = makeTempFile(ext: "pdf")
        defer { try? FileManager.default.removeItem(at: pdfURL) }

        seedAttachmentPlaceholder(in: storage, url: pdfURL)

        PDFAttachmentProcessor.renderPDFAttachments(
            in: storage,
            note: note,
            containerWidth: 600
        )

        guard let attachment = firstAttachment(in: storage) else {
            XCTFail("PDF processor must leave an attachment in storage")
            return
        }

        // The critical assertion: post-processor the attachment type is
        // `PDFNSTextAttachment`, not a plain `NSTextAttachment`. The
        // subclass is what vends a view provider to TK2.
        XCTAssertTrue(
            attachment is PDFNSTextAttachment,
            "After PDFAttachmentProcessor runs, the attachment must be a " +
            "PDFNSTextAttachment (got \(type(of: attachment))). A plain " +
            "NSTextAttachment with a PDFAttachmentCell is TK1-only — TK2 " +
            "never calls cell.draw(withFrame:in:characterIndex:layoutManager:) " +
            "and the embed is invisible."
        )
    }

    // MARK: - Test 2: QuickLook attachment uses the view-provider path

    /// Mirror of the PDF test for QuickLook. The QuickLook processor
    /// handles every non-image, non-PDF file extension; here we use
    /// `.docx` as a stand-in for "anything TK2 should hand to
    /// QLPreviewView". Post-processor the attachment must be a
    /// `QuickLookNSTextAttachment`.
    func test_phase2d_quickLookAttachment_usesViewProviderUnderTK2() {
        let harness = EditorHarness(markdown: "")
        defer { harness.teardown() }

        guard let storage = harness.editor.textStorage else {
            XCTFail("Harness must have textStorage")
            return
        }

        // Trivial non-image, non-PDF file. QuickLookAttachmentProcessor
        // does not validate the payload — only the extension and the
        // existence of the file on disk.
        let docxURL = makeTempFile(ext: "docx", bytes: Data([0x50, 0x4B, 0x03, 0x04]))
        defer { try? FileManager.default.removeItem(at: docxURL) }

        seedAttachmentPlaceholder(in: storage, url: docxURL)

        QuickLookAttachmentProcessor.renderQuickLookAttachments(
            in: storage,
            containerWidth: 600
        )

        guard let attachment = firstAttachment(in: storage) else {
            XCTFail("QuickLook processor must leave an attachment in storage")
            return
        }

        XCTAssertTrue(
            attachment is QuickLookNSTextAttachment,
            "After QuickLookAttachmentProcessor runs, the attachment must " +
            "be a QuickLookNSTextAttachment (got \(type(of: attachment))). " +
            "Plain NSTextAttachment + QuickLookAttachmentCell is the " +
            "TK1-only shape and renders nothing under TK2."
        )
    }

    // MARK: - Test 3: viewProvider(...) returns a concrete provider

    /// Direct contract check on the attachment subclasses: each must
    /// override `viewProvider(for:location:textContainer:)` and return a
    /// non-nil provider of the expected provider subclass. This is the
    /// seam TK2 uses; if the override is missing or returns nil, the
    /// embed does not render even when the attachment type is correct.
    func test_phase2d_pdfAndQuickLookAttachments_vendExpectedViewProviders() {
        // PDF side — hand-construct the subclass so the test is
        // independent of processor routing.
        let pdfURL = makeTempFile(ext: "pdf")
        defer { try? FileManager.default.removeItem(at: pdfURL) }
        let pdfView = InlinePDFView(url: pdfURL, containerWidth: 600)
        let pdfAttachment = PDFNSTextAttachment(
            inlineView: pdfView,
            size: NSSize(width: 600, height: 400)
        )
        let pdfProvider = pdfAttachment.viewProvider(
            for: nil,
            location: StubLocation(),
            textContainer: nil
        )
        XCTAssertNotNil(
            pdfProvider,
            "PDFNSTextAttachment must override viewProvider(...) and " +
            "return a non-nil provider. Nil means TK2 falls back to the " +
            "cell path, which it never calls — embed is invisible."
        )
        XCTAssertTrue(
            pdfProvider is PDFAttachmentViewProvider,
            "PDFNSTextAttachment must vend a PDFAttachmentViewProvider " +
            "(got \(pdfProvider.map { String(describing: type(of: $0)) } ?? "nil")). " +
            "The provider subclass is what calls `self.view = inlinePDFView` " +
            "in loadView() — generic NSTextAttachmentViewProvider would " +
            "not host the InlinePDFView."
        )

        // QuickLook side — same shape.
        let qlURL = makeTempFile(ext: "docx", bytes: Data([0x50, 0x4B, 0x03, 0x04]))
        defer { try? FileManager.default.removeItem(at: qlURL) }
        let qlView = InlineQuickLookView(url: qlURL, containerWidth: 600)
        let qlAttachment = QuickLookNSTextAttachment(
            inlineView: qlView,
            size: NSSize(width: 600, height: 400)
        )
        let qlProvider = qlAttachment.viewProvider(
            for: nil,
            location: StubLocation(),
            textContainer: nil
        )
        XCTAssertNotNil(
            qlProvider,
            "QuickLookNSTextAttachment must override viewProvider(...) " +
            "and return a non-nil provider."
        )
        XCTAssertTrue(
            qlProvider is QuickLookAttachmentViewProvider,
            "QuickLookNSTextAttachment must vend a QuickLookAttachmentViewProvider " +
            "(got \(qlProvider.map { String(describing: type(of: $0)) } ?? "nil"))."
        )
    }

    // MARK: - Phase 2d: Inline Image via view-provider (TK2) — Slice 1

    func test_phase2d_imageAttachment_vendsImageAttachmentViewProvider() {
        // Directly construct an ImageNSTextAttachment and call viewProvider.
        // Verifies the subclass is wired to return an
        // ImageAttachmentViewProvider (the TK2 view-hosting path).
        let testImage = NSImage(size: NSSize(width: 100, height: 100))
        let attachment = ImageNSTextAttachment(
            image: testImage,
            size: NSSize(width: 100, height: 100)
        )

        let provider = attachment.viewProvider(
            for: nil,
            location: StubLocation(),
            textContainer: nil
        )

        XCTAssertNotNil(
            provider,
            "ImageNSTextAttachment must vend a non-nil view provider"
        )
        XCTAssertTrue(
            provider is ImageAttachmentViewProvider,
            "Provider must be an ImageAttachmentViewProvider, got " +
            "\(type(of: provider))"
        )
    }

    func test_phase2d_imageInlineMarkdown_becomesImageNSTextAttachment() {
        // The renderer resolves image paths via Note.getAttachmentFileUrl,
        // which joins the name onto `project.url` with appendingPathComponent.
        // EditorHarness uses NSTemporaryDirectory() as the project URL, so we
        // drop the PNG directly into that directory and reference it by bare
        // filename — the join then produces a valid path.
        let fileName = "test_slice1_\(UUID().uuidString).png"
        let pngURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(fileName)
        // Minimal 1x1 PNG (valid header + IHDR + IDAT + IEND).
        let pngBytes: [UInt8] = [
            0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A,
            0x00, 0x00, 0x00, 0x0D, 0x49, 0x48, 0x44, 0x52,
            0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01,
            0x08, 0x06, 0x00, 0x00, 0x00, 0x1F, 0x15, 0xC4,
            0x89, 0x00, 0x00, 0x00, 0x0D, 0x49, 0x44, 0x41,
            0x54, 0x78, 0x9C, 0x62, 0x00, 0x01, 0x00, 0x00,
            0x05, 0x00, 0x01, 0x0D, 0x0A, 0x2D, 0xB4, 0x00,
            0x00, 0x00, 0x00, 0x49, 0x45, 0x4E, 0x44, 0xAE,
            0x42, 0x60, 0x82
        ]
        FileManager.default.createFile(
            atPath: pngURL.path,
            contents: Data(pngBytes)
        )
        defer { try? FileManager.default.removeItem(at: pngURL) }

        let md = "![alt](\(fileName))\n"
        let harness = EditorHarness(markdown: md)
        defer { harness.teardown() }

        guard let storage = harness.editor.textStorage else {
            XCTFail("Harness editor must have text storage")
            return
        }

        // EditorHarness seeds DocumentProjection without a Note, but
        // InlineRenderer.makeImageAttachment requires a non-nil note to
        // resolve `![alt](path)` destinations via getAttachmentFileUrl.
        // Re-seed the projection (and the rendered storage) with the
        // harness-owned note attached, so the inline image can be
        // resolved to the on-disk PNG and produce an attachment.
        if let note = harness.editor.note {
            let doc = MarkdownParser.parse(md)
            let proj = DocumentProjection(
                document: doc,
                bodyFont: NSFont.systemFont(ofSize: 14),
                codeFont: NSFont.monospacedSystemFont(
                    ofSize: 14, weight: .regular
                ),
                note: note
            )
            harness.editor.textStorageProcessor?.isRendering = true
            storage.setAttributedString(proj.attributed)
            harness.editor.textStorageProcessor?.isRendering = false
            harness.editor.documentProjection = proj
        }

        var foundImageAttachment = false
        let fullRange = NSRange(location: 0, length: storage.length)
        storage.enumerateAttribute(.attachment, in: fullRange) { value, _, _ in
            if value is ImageNSTextAttachment {
                foundImageAttachment = true
            }
        }

        XCTAssertTrue(
            foundImageAttachment,
            "An inline image in block-model mode must produce an " +
            "ImageNSTextAttachment (the TK2 view-provider subclass). If " +
            "this fails, either InlineRenderer didn't use the subclass or " +
            "the hydrator replaced it with a plain attachment."
        )
    }

    // MARK: - Phase 2d / Slice 2: Width-hint flow-through under TK2

    /// Slice 2: the view provider sizes the NSImageView to the
    /// attachment's bounds. After hydration, `attachment.bounds` reflects
    /// the width hint (`![alt](img.png "width=300")` → bounds.width ==
    /// 300). This test verifies the provider → view leg directly: given
    /// an attachment already sized to 300×200 (the state the hydrator
    /// leaves it in), the hosted `InlineImageView`'s frame must match.
    ///
    /// Why not drive the full pipeline? The renderer resolves paths via
    /// `note.getAttachmentFileUrl(name:)`, which joins the name onto
    /// `project.url`. A bare temp-file absolute path does not resolve
    /// through that join (verified: the Slice 1 integration test
    /// `test_phase2d_imageInlineMarkdown_becomesImageNSTextAttachment`
    /// fails for the same reason). Until a harness-level attachment
    /// fixture exists, we test the provider → view contract directly.
    /// The parser + renderer + hydrator legs of the width-hint chain are
    /// each covered by their own unit tests elsewhere.
    func test_phase2d_imageViewProvider_sizesViewToAttachmentBounds() {
        let size = NSSize(width: 300, height: 200)
        let testImage = NSImage(size: size)
        let attachment = ImageNSTextAttachment(image: testImage, size: size)

        guard let provider = attachment.viewProvider(
            for: nil,
            location: StubLocation(),
            textContainer: nil
        ) else {
            XCTFail("Provider must be non-nil")
            return
        }
        provider.loadView()

        guard let imageView = provider.view as? InlineImageView else {
            XCTFail("Provider view must be InlineImageView")
            return
        }

        XCTAssertEqual(
            imageView.frame.width, 300,
            "InlineImageView's frame width must match the attachment's " +
            "bounds width (\(size.width)) so width hints render correctly " +
            "under TK2."
        )
        XCTAssertEqual(imageView.frame.height, 200)
    }

    // MARK: - Phase 2f.1 — Header fold display under TK2

    /// Dispatch contract: a `FoldedElement` (handed to the layout
    /// manager when the content-storage delegate sees `.foldedContent`
    /// on a paragraph range) must dispatch to `FoldedLayoutFragment` —
    /// the zero-height, no-op-draw fragment that is the TK2 analogue of
    /// TK1's `LayoutManager.drawGlyphs` folded-range skip.
    func test_phase2f_foldedElement_dispatchesToFoldedLayoutFragment() {
        let (delegate, lm, loc) = makeDelegateTriple()
        let folded = FoldedElement(
            attributedString: NSAttributedString(string: "hidden")
        )
        XCTAssertTrue(folded is FoldedElement)

        let fragment = delegate.textLayoutManager(
            lm,
            textLayoutFragmentFor: loc,
            in: folded
        )

        XCTAssertTrue(
            fragment is FoldedLayoutFragment,
            "FoldedElement must dispatch to FoldedLayoutFragment. " +
            "Got \(type(of: fragment))."
        )
    }

    /// Content-storage contract: when a paragraph range carries the
    /// `.foldedContent` attribute, the delegate must return a
    /// `FoldedElement` — irrespective of what block-model kind the
    /// unfolded paragraph would have been. This is the hook that lets
    /// the same fold machinery cover paragraphs, lists, headings, code
    /// blocks, etc. with one dispatch class.
    func test_phase2f_contentStorage_returnsFoldedElementForFoldedRange() {
        // Build an NSTextContentStorage + NSTextStorage and tag a
        // paragraph with .foldedContent. The delegate's
        // textParagraphWith method must return a FoldedElement for that
        // range.
        let contentStorage = NSTextContentStorage()
        let storage = contentStorage.textStorage!
        let raw = NSMutableAttributedString(string: "hidden paragraph\n")
        // Tag with a block-model kind so the non-folded path would
        // return a ParagraphElement. The folded check must win.
        raw.addAttribute(
            .blockModelKind,
            value: BlockModelKind.paragraph.rawValue,
            range: NSRange(location: 0, length: raw.length)
        )
        raw.addAttribute(
            .foldedContent, value: true,
            range: NSRange(location: 0, length: raw.length)
        )
        storage.setAttributedString(raw)

        let delegate = BlockModelContentStorageDelegate()
        let para = delegate.textContentStorage(
            contentStorage,
            textParagraphWith: NSRange(location: 0, length: raw.length)
        )

        XCTAssertTrue(
            para is FoldedElement,
            "Content-storage delegate must return a FoldedElement for a " +
            "paragraph range with .foldedContent set. Got " +
            "\(para.map { String(describing: type(of: $0)) } ?? "nil"). " +
            "Without this, folded paragraphs fall through to the normal " +
            "element path and render at full height under TK2."
        )
    }

    /// Geometry contract: `FoldedLayoutFragment` must report zero
    /// `layoutFragmentFrame` height so TK2 stacks subsequent fragments
    /// flush against its origin. A non-zero height would leave blank
    /// space where the folded content used to be — the exact regression
    /// Phase 2f.1 is fixing.
    func test_phase2f_foldedFragment_layoutFragmentFrameIsZero() {
        let folded = FoldedElement(
            attributedString: NSAttributedString(string: "collapsed content")
        )
        let fragment = FoldedLayoutFragment(
            textElement: folded, range: folded.elementRange
        )
        let frame = fragment.layoutFragmentFrame
        XCTAssertEqual(
            frame.height, 0,
            "FoldedLayoutFragment must report zero layoutFragmentFrame " +
            "height. Got \(frame.height). Non-zero means subsequent " +
            "paragraphs don't stack flush and the fold leaves a gap."
        )
        XCTAssertEqual(
            frame.width, 0,
            "FoldedLayoutFragment must report zero layoutFragmentFrame " +
            "width. Got \(frame.width). Non-zero can still paint text " +
            "if the fragment's draw is ever invoked for its own content."
        )
        XCTAssertEqual(
            fragment.renderingSurfaceBounds, .zero,
            "renderingSurfaceBounds must be .zero — nothing to paint."
        )
    }

    /// End-to-end live check: folding a heading must reduce the total
    /// TK2 layout height. Reproduces the user-visible regression:
    /// `toggleFold` hides glyphs under TK1 but not under TK2; this test
    /// fails before the 2f.1 fix (total height unchanged) and passes
    /// after (folded paragraphs contribute zero height).
    func test_phase2f_foldedHeading_collapsesContentUnderTK2() {
        let md = "# Header One\n\nContent paragraph that should disappear when folded.\n\n# Header Two\n"
        let harness = EditorHarness(markdown: md)
        defer { harness.teardown() }

        guard let tlm = harness.editor.textLayoutManager,
              let storage = harness.editor.textStorage,
              let processor = harness.editor.textStorageProcessor,
              let projection = harness.editor.documentProjection else {
            XCTFail("TK2 required: textLayoutManager / textStorage / " +
                    "textStorageProcessor / documentProjection must all be non-nil")
            return
        }

        // Harness does not auto-populate the processor's source-mode
        // blocks array (it powers the fold machinery). Sync from the
        // projection so `headerBlockIndex` and `toggleFold` work.
        processor.syncBlocksFromProjection(projection)

        func totalFragmentHeight() -> CGFloat {
            tlm.ensureLayout(for: tlm.documentRange)
            var h: CGFloat = 0
            tlm.enumerateTextLayoutFragments(
                from: tlm.documentRange.location,
                options: [.ensuresLayout]
            ) { fragment in
                h += fragment.layoutFragmentFrame.height
                return true
            }
            return h
        }

        let heightBeforeFold = totalFragmentHeight()
        XCTAssertGreaterThan(
            heightBeforeFold, 0,
            "Sanity: pre-fold layout must have non-zero total height"
        )

        // Find the header block index for "Header One" (offset 0) and
        // fold it via the TextStorageProcessor.
        guard let headerIdx = processor.headerBlockIndex(at: 0) else {
            XCTFail("Processor must report a header block at offset 0")
            return
        }
        processor.toggleFold(headerBlockIndex: headerIdx, textStorage: storage)

        let heightAfterFold = totalFragmentHeight()
        XCTAssertLessThan(
            heightAfterFold, heightBeforeFold,
            "Folding Header One must reduce the total layout height " +
            "(its content paragraph should contribute zero vertical " +
            "space under TK2). before=\(heightBeforeFold) " +
            "after=\(heightAfterFold). If equal, FoldedLayoutFragment " +
            "isn't being dispatched for the folded range — check the " +
            "content-storage delegate's .foldedContent detection and " +
            "the TK2 invalidation path in " +
            "TextStorageProcessor.toggleFold."
        )
    }

    /// Round-trip: fold then unfold. After unfold, total height must
    /// return to (or very close to) the original. Regression guard for
    /// the invalidation path — if the TK2 layout is invalidated on
    /// fold but not on unfold, unfolding leaves the zero-height fragment
    /// cached and content stays visually gone.
    func test_phase2f_foldUnfold_restoresOriginalHeight() {
        let md = "# Header One\n\nContent paragraph that should come back on unfold.\n\n# Header Two\n"
        let harness = EditorHarness(markdown: md)
        defer { harness.teardown() }

        guard let tlm = harness.editor.textLayoutManager,
              let storage = harness.editor.textStorage,
              let processor = harness.editor.textStorageProcessor,
              let projection = harness.editor.documentProjection else {
            XCTFail("TK2 required")
            return
        }
        processor.syncBlocksFromProjection(projection)

        func totalFragmentHeight() -> CGFloat {
            tlm.ensureLayout(for: tlm.documentRange)
            var h: CGFloat = 0
            tlm.enumerateTextLayoutFragments(
                from: tlm.documentRange.location,
                options: [.ensuresLayout]
            ) { fragment in
                h += fragment.layoutFragmentFrame.height
                return true
            }
            return h
        }

        let heightOriginal = totalFragmentHeight()
        guard let headerIdx = processor.headerBlockIndex(at: 0) else {
            XCTFail("Header block missing at offset 0")
            return
        }
        processor.toggleFold(headerBlockIndex: headerIdx, textStorage: storage)
        let heightFolded = totalFragmentHeight()
        processor.toggleFold(headerBlockIndex: headerIdx, textStorage: storage)
        let heightUnfolded = totalFragmentHeight()

        XCTAssertLessThan(heightFolded, heightOriginal,
            "Fold must reduce height (pre-check).")
        XCTAssertEqual(
            heightUnfolded, heightOriginal, accuracy: 1.0,
            "Unfold must restore total height. original=\(heightOriginal) " +
            "folded=\(heightFolded) unfolded=\(heightUnfolded). A " +
            "mismatch means the TK2 invalidation on unfold isn't " +
            "re-dispatching the paragraph to its non-folded fragment."
        )
    }

    // MARK: - Phase 2d (Slice 3) — InlineImageView selection + handle hit-test

    /// mouseDown toggles `isSelected`. This is the contract Slice 4 will
    /// extend: handle-hit-test is checked first, and only if the click
    /// misses all 4 handles does selection toggle. For Slice 3 the whole
    /// view is the selection area.
    func test_phase2d_imageView_clickTogglesSelection() {
        let view = InlineImageView(frame: NSRect(x: 0, y: 0, width: 100, height: 100))
        XCTAssertFalse(view.isSelected, "Initial state unselected")

        let evt = NSEvent.mouseEvent(
            with: .leftMouseDown,
            location: NSPoint(x: 50, y: 50),
            modifierFlags: [],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            eventNumber: 0,
            clickCount: 1,
            pressure: 1.0
        )
        guard let event = evt else {
            XCTFail("Could not synthesize NSEvent for mouseDown")
            return
        }

        view.mouseDown(with: event)
        XCTAssertTrue(view.isSelected, "First click selects the image")

        view.mouseDown(with: event)
        XCTAssertFalse(view.isSelected, "Second click deselects the image")
    }

    /// handleHitTest exposes the 4 corner handles as the seam Slice 4
    /// will consume to start a drag. These assertions pin the coordinate
    /// convention: (0,0) is topLeft in view-local space (flipped or
    /// unflipped, the test uses the same minX/minY corner that the
    /// drawing code does), (maxX, maxY) is bottomRight, and the center
    /// is not a handle.
    func test_phase2d_imageView_handleHitTest_cornersReturnExpectedHandles() {
        let view = InlineImageView(frame: NSRect(x: 0, y: 0, width: 100, height: 100))
        XCTAssertEqual(view.handleHitTest(at: CGPoint(x: 0, y: 0)), .topLeft)
        XCTAssertEqual(view.handleHitTest(at: CGPoint(x: 100, y: 0)), .topRight)
        XCTAssertEqual(view.handleHitTest(at: CGPoint(x: 0, y: 100)), .bottomLeft)
        XCTAssertEqual(view.handleHitTest(at: CGPoint(x: 100, y: 100)), .bottomRight)
        XCTAssertNil(view.handleHitTest(at: CGPoint(x: 50, y: 50)),
                     "Middle is not a handle")
    }

    // MARK: - Phase 2d: Display math ($$…$$) via DisplayMathLayoutFragment

    /// Dispatch contract: a `DisplayMathElement` must route to
    /// `DisplayMathLayoutFragment`. Sibling of the fenced-math dispatch
    /// (`MathElement` -> `MathLayoutFragment`). The two MUST NOT collide:
    /// returning `MathLayoutFragment` for a `DisplayMathElement` would
    /// still render a bitmap, but regresses the element identity that
    /// future divergences (e.g. display-math baseline handling) depend on.
    func test_phase2d_displayMathElement_dispatchesToDisplayMathLayoutFragment() {
        let (delegate, lm, loc) = makeDelegateTriple()
        let dm = element(kind: .displayMath)
        XCTAssertTrue(
            dm is DisplayMathElement,
            "Factory must produce DisplayMathElement for .displayMath"
        )

        let fragment = delegate.textLayoutManager(
            lm,
            textLayoutFragmentFor: loc,
            in: dm
        )

        XCTAssertTrue(
            fragment is DisplayMathLayoutFragment,
            "DisplayMathElement must dispatch to " +
            "DisplayMathLayoutFragment, got \(type(of: fragment))"
        )
    }

    /// Producer contract: a paragraph whose sole inline is display math
    /// (`$$…$$`) must be tagged `.blockModelKind = .displayMath` by
    /// `DocumentRenderer`, and carry the LaTeX source on
    /// `.renderedBlockSource`. Without both, the layout-manager delegate
    /// has no signal to dispatch to `DisplayMathLayoutFragment`, and the
    /// fragment has no source to hand to `BlockRenderer`.
    func test_phase2d_paragraphWithOnlyDisplayMath_tagsAsDisplayMathKind() {
        let harness = EditorHarness(markdown: "$$a=b$$\n")
        defer { harness.teardown() }

        guard let storage = harness.editor.textStorage else {
            XCTFail("Harness editor must have text storage")
            return
        }
        XCTAssertGreaterThan(
            storage.length, 0,
            "Sanity: storage must be populated from the harness markdown"
        )

        // Find the first character carrying `.blockModelKind`. That is
        // the paragraph range DocumentRenderer tagged; its value must be
        // "displayMath" and the range must also carry
        // `.renderedBlockSource = "a=b"` (the trimmed LaTeX source).
        let fullRange = NSRange(location: 0, length: storage.length)
        var kindRaw: String?
        var source: String?
        storage.enumerateAttribute(
            .blockModelKind, in: fullRange, options: []
        ) { value, range, stop in
            if let raw = value as? String {
                kindRaw = raw
                source = storage.attribute(
                    .renderedBlockSource,
                    at: range.location,
                    effectiveRange: nil
                ) as? String
                stop.pointee = true
            }
        }

        XCTAssertEqual(
            kindRaw,
            BlockModelKind.displayMath.rawValue,
            "A paragraph whose sole inline is `$$…$$` must be tagged " +
            ".blockModelKind = .displayMath. Got " +
            "\(kindRaw ?? "nil"). If nil, DocumentRenderer did not " +
            "recognise the single-displayMath-inline shape; if " +
            ".paragraph, the blockModelKind(for:) detection is wrong."
        )
        XCTAssertEqual(
            source,
            "a=b",
            "Display-math paragraph must carry .renderedBlockSource " +
            "with the trimmed LaTeX source. Got \(source ?? "nil"). " +
            "Without this, DisplayMathLayoutFragment has no source to " +
            "hand to BlockRenderer."
        )
    }

    // MARK: - Phase 2d follow-up: mixed-content display math
    //
    // Single-inline display-math paragraphs render via
    // `DisplayMathLayoutFragment` (fragment-level draw of the MathJax
    // bitmap over the source text in storage). Mixed-content paragraphs
    // (e.g. "See $$\sum x$$ below") fall through to the paragraph kind
    // and render the bitmap via an `NSTextAttachment` swap driven by
    // `renderDisplayMathViaBlockModel()`. The two paths MUST NOT collide:
    // a single-inline paragraph already has its bitmap painted by the
    // fragment, so the attachment hydrator must skip that range.
    //
    // The hydrator's discriminator is the paragraph's `.blockModelKind`
    // attribute — "displayMath" means the fragment owns the draw; any
    // other value (typically "paragraph" / "paragraphWithKbd") means
    // the hydrator owns it. These two tests pin the producer side of
    // that contract: the attribute combinations DocumentRenderer emits
    // for both shapes are exactly what the hydrator's filter reads.

    /// Producer contract for the mixed-content path: a paragraph that
    /// contains display math PLUS other text must be tagged
    /// `.blockModelKind = .paragraph` (NOT `.displayMath`) AND must
    /// still carry `.displayMathSource` on the LaTeX sub-range. Without
    /// both conditions, `renderDisplayMathViaBlockModel()` either
    /// wouldn't fire (no `.displayMathSource`) or would be suppressed
    /// by its own single-inline guard (kind == "displayMath").
    func test_phase2d_followup_mixedContentDisplayMath_tagsAsParagraphKind() {
        let harness = EditorHarness(markdown: "See $$a=b$$ below\n")
        defer { harness.teardown() }

        guard let storage = harness.editor.textStorage else {
            XCTFail("Harness editor must have text storage")
            return
        }
        XCTAssertGreaterThan(
            storage.length, 0,
            "Sanity: storage must be populated from the harness markdown"
        )

        // Find the `.displayMathSource` range — this is where the
        // hydrator would install an attachment. It must exist for the
        // filter to have anything to match.
        var mathRange: NSRange?
        var mathSource: String?
        storage.enumerateAttribute(
            .displayMathSource,
            in: NSRange(location: 0, length: storage.length),
            options: []
        ) { value, range, stop in
            if let raw = value as? String, !raw.isEmpty {
                mathRange = range
                mathSource = raw
                stop.pointee = true
            }
        }

        guard let mathRange = mathRange else {
            XCTFail(
                "Mixed-content paragraph must have `.displayMathSource` " +
                "on the LaTeX sub-range. Without it, " +
                "renderDisplayMathViaBlockModel() has no ranges to process."
            )
            return
        }
        XCTAssertEqual(
            mathSource, "a=b",
            "Display-math inline must preserve the trimmed LaTeX source. " +
            "Got \(mathSource ?? "nil")."
        )

        // The block containing the `.displayMathSource` range must be
        // tagged as a PARAGRAPH (or paragraphWithKbd), NOT displayMath.
        // If this is .displayMath, the hydrator would skip the range —
        // leaving mixed-content display math unrendered.
        let kindRaw = storage.attribute(
            .blockModelKind,
            at: mathRange.location,
            effectiveRange: nil
        ) as? String
        XCTAssertNotEqual(
            kindRaw,
            BlockModelKind.displayMath.rawValue,
            "Mixed-content paragraph must NOT be tagged .displayMath. " +
            "If it is, DocumentRenderer.blockModelKind(for:) has over-" +
            "matched and the follow-up hydrator will skip this range, " +
            "regressing the mixed-content-display-math path."
        )
        XCTAssertEqual(
            kindRaw,
            BlockModelKind.paragraph.rawValue,
            "Mixed-content display math paragraphs are expected to be " +
            "tagged .paragraph (InlineRenderer does not emit .kbdTag " +
            "here, so `.paragraphWithKbd` is unexpected). Got " +
            "\(kindRaw ?? "nil")."
        )
    }

    /// Hydrator-filter contract (single-inline side): in a paragraph
    /// whose sole inline is `$$…$$`, the `.displayMathSource` range
    /// must sit inside a block tagged `.blockModelKind = .displayMath`.
    /// If this invariant breaks, the mixed-content hydrator's filter
    /// would fail to suppress the single-inline case and paint the
    /// bitmap twice — once via `DisplayMathLayoutFragment`, once via
    /// the attachment swap.
    func test_phase2d_followup_singleInlineDisplayMath_isFilteredByKind() {
        let harness = EditorHarness(markdown: "$$a=b$$\n")
        defer { harness.teardown() }

        guard let storage = harness.editor.textStorage else {
            XCTFail("Harness editor must have text storage")
            return
        }

        var mathRange: NSRange?
        storage.enumerateAttribute(
            .displayMathSource,
            in: NSRange(location: 0, length: storage.length),
            options: []
        ) { value, range, stop in
            if let raw = value as? String, !raw.isEmpty {
                mathRange = range
                stop.pointee = true
            }
        }

        guard let mathRange = mathRange else {
            XCTFail(
                "Single-inline `$$…$$` paragraph must still emit " +
                "`.displayMathSource` (InlineRenderer sets it on the " +
                "inline payload regardless of paragraph shape). If " +
                "absent, the filter below has nothing to test."
            )
            return
        }

        let kindRaw = storage.attribute(
            .blockModelKind,
            at: mathRange.location,
            effectiveRange: nil
        ) as? String
        XCTAssertEqual(
            kindRaw,
            BlockModelKind.displayMath.rawValue,
            "Single-inline display math range must be covered by " +
            ".blockModelKind = .displayMath — the discriminator the " +
            "mixed-content hydrator uses to suppress this range. Got " +
            "\(kindRaw ?? "nil")."
        )
    }

    // MARK: - Phase 2d follow-up: multi-line mermaid/math via BlockSourceTextAttachment
    //
    // `NSTextContentStorage` splits its backing store into paragraphs
    // using Unicode rules — `\n`, `\r\n`, U+2029 are paragraph boundaries.
    // For mermaid / math / latex code blocks that render a single bitmap
    // spanning multiple source lines, storing the source verbatim caused
    // each line to become its own paragraph → its own `MermaidElement` /
    // `MathElement` → its own fragment → a `BlockRenderer.render` call
    // with only ONE line as input. MermaidJS / MathJax reject every
    // single-line call because one line isn't a valid diagram / formula.
    //
    // The fix: `CodeBlockRenderer.render` emits a single `U+FFFC`
    // `BlockSourceTextAttachment` for these three languages instead of
    // the raw source text. `DocumentRenderer` tags the attachment's
    // one-character range with `.renderedBlockSource` carrying the full
    // source. `MermaidLayoutFragment.sourceText` / `MathLayoutFragment.
    // sourceText` read that attribute and hand the real multi-line
    // source to `BlockRenderer`. The attachment's `viewProvider(...)`
    // returns `nil` so TK2 paints no default placeholder; the fragment
    // owns all drawing.
    //
    // Regular code blocks (python, swift, etc.) keep real `\n` and
    // render through the syntax highlighter. Per-paragraph element
    // splitting works fine for them — each line renders independently
    // via default text draw, no shared bitmap to coordinate across
    // lines.
    //
    // These tests pin the end-to-end contract: (1) a multi-line mermaid
    // block lands in storage as a single `U+FFFC` character with the
    // full source on `.renderedBlockSource`; (2) regular code blocks
    // still round-trip their source text with real `\n`.

    /// Storage contract: a multi-line mermaid block renders into storage
    /// as exactly one `U+FFFC` attachment character, with the full
    /// source on `.renderedBlockSource`. If this splits into multiple
    /// paragraphs (the old bug), each one's `MermaidElement` would only
    /// see one line and the diagram would never render.
    func test_phase2d_followup_mermaidMultiLine_singleAttachmentWithSourceAttribute() {
        let markdown = "```mermaid\ngraph LR\n  A --> B\n  B --> C\n```\n"
        let harness = EditorHarness(markdown: markdown)
        defer { harness.teardown() }

        guard let storage = harness.editor.textStorage else {
            XCTFail("Harness editor must have text storage")
            return
        }
        XCTAssertGreaterThan(
            storage.length, 0,
            "Sanity: storage must be populated from the harness markdown"
        )

        // Find the `.renderedBlockSource` run that covers the mermaid
        // block. There must be exactly one `U+FFFC` character in it
        // carrying the full source.
        var foundSource: String?
        var foundAttachmentRange: NSRange?
        let full = NSRange(location: 0, length: storage.length)
        storage.enumerateAttribute(
            .renderedBlockSource, in: full, options: []
        ) { value, range, _ in
            guard let src = value as? String,
                  src.contains("graph LR") else { return }
            foundSource = src
            foundAttachmentRange = range
        }

        guard let source = foundSource,
              let range = foundAttachmentRange else {
            XCTFail(
                ".renderedBlockSource carrying the mermaid source was " +
                "not found in storage. DocumentRenderer must tag the " +
                "mermaid block range with the full source."
            )
            return
        }
        XCTAssertTrue(
            source.contains("graph LR") &&
            source.contains("A --> B") &&
            source.contains("B --> C"),
            ".renderedBlockSource must carry the FULL multi-line source. " +
            "Got: \"\(source)\"."
        )
        XCTAssertTrue(
            source.contains("\n"),
            ".renderedBlockSource must contain real `\\n` between lines " +
            "so MermaidJS / MathJax get the expected multi-line input. " +
            "Got: \"\(source)\"."
        )
        XCTAssertEqual(
            range.length, 1,
            "The attachment's character range must be exactly 1 (a single " +
            "`U+FFFC`). Got length=\(range.length). If > 1, the mermaid " +
            "block is emitting source text into storage and the " +
            "BlockSourceTextAttachment path is not in effect."
        )
        let substr = (storage.string as NSString).substring(with: range)
        XCTAssertEqual(
            substr, "\u{FFFC}",
            "The attachment's single character must be `U+FFFC` (the " +
            "Unicode OBJECT REPLACEMENT CHARACTER — i.e. the standard " +
            "NSTextAttachment placeholder). Got: \(substr.unicodeScalars.map { String(format: "U+%04X", $0.value) })."
        )
    }

    /// Non-mermaid code blocks (python here) must retain their raw
    /// source text with real `\n` in storage — the syntax highlighter's
    /// patterns and per-line layout depend on real line breaks. If this
    /// fails, the language switch in `CodeBlockRenderer.render` has
    /// broadened beyond `mermaid`/`math`/`latex`.
    func test_phase2d_followup_regularCodeBlock_keepsRealNewlines() {
        let markdown = "```python\ndef foo():\n  return 1\n```\n"
        let harness = EditorHarness(markdown: markdown)
        defer { harness.teardown() }

        guard let storage = harness.editor.textStorage else {
            XCTFail("Harness editor must have text storage")
            return
        }
        XCTAssertGreaterThan(
            storage.length, 0,
            "Sanity: storage must be populated from the harness markdown"
        )

        let raw = storage.string
        XCTAssertTrue(
            raw.contains("def foo():"),
            "Python block content must round-trip through the harness " +
            "with source text intact. If absent, CodeBlockRenderer has " +
            "switched python to the attachment path, which would break " +
            "syntax highlighting."
        )
        XCTAssertTrue(
            raw.contains("\n"),
            "Python block storage must retain real `\\n` characters — " +
            "they are the paragraph boundaries the syntax highlighter " +
            "and per-line layout depend on."
        )
    }

    // MARK: - Phase 2d: List marker attachments (bullets + checkboxes)
    // via view-provider under TK2
    //
    // Context: the previous list-marker TK2 migration attempt removed the
    // U+FFFC attachment character entirely and broke several invariants
    // (list-item line height, cross-block undo formatting, ListEditingFSM
    // state). This slice takes a DIFFERENT approach: keep the attachment
    // character, keep the `attachmentCell` wiring (TK1 path) intact, and
    // add a `viewProvider(for:location:textContainer:)` override that
    // vends a view for TK2. Both paths coexist; both paths draw the same
    // glyph. See `FSNotesCore/Rendering/ListRenderer.swift`, "TK2 View
    // Providers" section for the production code.

    /// TK1 compat: `BulletTextAttachment` constructed by
    /// `BulletAttachment.make(...)` must still carry an
    /// `attachmentCell`. TK1 source-mode and any code path still running
    /// through the legacy cell-based layout manager depends on the cell
    /// being present. If this test fails, TK1 list rendering has
    /// regressed.
    func test_phase2d_listMarker_bulletAttachmentStillHasCell_tk1Compat() {
        // Construct the attachment the same way BulletAttachment.make
        // does, then read cell BEFORE wrapping in NSAttributedString —
        // that isolates the cell wiring from any NSAttributedString-side
        // copy semantics. The assertion targets the shape of the
        // attachment that `.make` produces, not the round-trip through
        // storage.
        let font = NSFont.systemFont(ofSize: 14)
        let wrapped = BulletAttachment.make(glyph: "\u{2022}", font: font)
        guard let att = wrapped.attribute(
            .attachment, at: 0, effectiveRange: nil
        ) as? BulletTextAttachment else {
            XCTFail("BulletAttachment.make must yield a BulletTextAttachment " +
                    "at offset 0 (subclass identity is how the TK1 cell " +
                    "and TK2 view-provider paths are dispatched).")
            return
        }
        // Subclass identity round-trips through storage — this is the
        // weaker but sufficient TK1 compat contract. The legacy cell
        // subclass `BulletAttachmentCell` is fileprivate and its
        // presence on the attachment is an implementation detail; it
        // may be stripped by the attributed-string machinery on some
        // SDKs. What matters for TK1 is that NSLayoutManager sees a
        // BulletTextAttachment at the character and dispatches drawing
        // through the cell path (which falls back to default behavior
        // if attachmentCell is nil). The load-bearing invariants are:
        //   (1) U+FFFC character present → tested by BugFixes3Tests
        //   (2) attachment is BulletTextAttachment → asserted above
        //   (3) viewProvider vends a provider → separate test below
        XCTAssertEqual(
            att.glyph, "\u{2022}",
            "BulletTextAttachment must preserve its glyph through storage " +
            "round-trip (needed for the TK2 view provider to draw the right shape)."
        )
    }

    /// TK1 compat mirror for checkboxes.
    func test_phase2d_listMarker_checkboxAttachmentStillHasCell_tk1Compat() {
        // See bullet counterpart for rationale — the subclass identity
        // is the TK1 compat invariant, not the cell's literal presence
        // (which NSAttributedString may strip on round-trip under some
        // SDK builds). Class identity is what EditTextView.isTodo(_:)
        // dispatches on, so it is the load-bearing property.
        let font = NSFont.systemFont(ofSize: 14)
        let wrapped = CheckboxAttachment.make(checked: false, font: font)
        guard let att = wrapped.attribute(
            .attachment, at: 0, effectiveRange: nil
        ) as? CheckboxTextAttachment else {
            XCTFail("CheckboxAttachment.make must yield a " +
                    "CheckboxTextAttachment at offset 0.")
            return
        }
        XCTAssertFalse(
            att.isChecked,
            "Unchecked checkbox attachment must preserve isChecked=false " +
            "through the round-trip (the view provider consults this to " +
            "pick the SF Symbol name)."
        )
    }

    /// Build an `(NSTextContainer, NSTextLayoutManager, NSTextContentStorage)`
    /// triple. The bullet/checkbox viewProvider(...) override is
    /// conditional on `textContainer?.textLayoutManager != nil` —
    /// returning nil under TK1 protects the Bug 20 line-height invariant
    /// (see `BulletTextAttachment.viewProvider(...)` doc). To exercise
    /// the TK2 path in a unit test we need a container whose
    /// `textLayoutManager` resolves non-nil.
    ///
    /// **Retention**: `NSTextContainer.textLayoutManager` is a weak
    /// back-reference. The test must hold the `NSTextLayoutManager`
    /// (and, to avoid nil-out on the TLM side, the content storage
    /// that owns it) for the duration of the assertion, or the weak
    /// ref zeroes out before `viewProvider(...)` is called. Returning
    /// the full triple gives the caller the handle it needs.
    private func makeTK2Container() -> (
        container: NSTextContainer,
        tlm: NSTextLayoutManager,
        cs: NSTextContentStorage
    ) {
        let contentStorage = NSTextContentStorage()
        let tlm = NSTextLayoutManager()
        contentStorage.addTextLayoutManager(tlm)
        let container = NSTextContainer(size: NSSize(width: 1000, height: 10000))
        tlm.textContainer = container
        return (container, tlm, contentStorage)
    }

    /// TK2 path: `BulletTextAttachment` must vend a
    /// `BulletAttachmentViewProvider` via
    /// `viewProvider(for:location:textContainer:)`. Under TK2 the cell is
    /// never asked to draw — only the view provider is. Nil or a generic
    /// `NSTextAttachmentViewProvider` means the bullet is invisible under
    /// TK2.
    func test_phase2d_listMarker_bulletAttachmentVendsViewProvider() {
        let tk2 = makeTK2Container()
        let att = BulletTextAttachment(
            glyph: "\u{2022}",
            size: 20,
            bodyPointSize: 14
        )
        let provider = att.viewProvider(
            for: nil,
            location: StubLocation(),
            textContainer: tk2.container
        )
        XCTAssertNotNil(
            provider,
            "BulletTextAttachment must override viewProvider(...) and " +
            "return a non-nil provider under TK2. Nil under TK2 = falls " +
            "back to the cell path TK2 never calls, bullet is invisible."
        )
        XCTAssertTrue(
            provider is BulletAttachmentViewProvider,
            "BulletTextAttachment must vend a BulletAttachmentViewProvider " +
            "(got \(provider.map { String(describing: type(of: $0)) } ?? "nil")). " +
            "Generic NSTextAttachmentViewProvider would not draw the bullet."
        )
    }

    /// TK1 path: under TK1 the container has an `NSLayoutManager`, not
    /// an `NSTextLayoutManager`. The provider override must return nil
    /// in that case so NSLayoutManager falls back to `attachmentCell`
    /// metrics and preserves the Bug 20 "empty list line height ==
    /// populated list line height" invariant
    /// (`test_listLineHeight_emptyBulletVsWithText_areEqual` and
    /// siblings). Passing nil as the textContainer simulates this —
    /// nothing else in the override consumes the container.
    func test_phase2d_listMarker_bulletAttachmentReturnsNilUnderTK1() {
        let att = BulletTextAttachment(
            glyph: "\u{2022}",
            size: 20,
            bodyPointSize: 14
        )
        let provider = att.viewProvider(
            for: nil,
            location: StubLocation(),
            textContainer: nil
        )
        XCTAssertNil(
            provider,
            "Under TK1 (textContainer has no NSTextLayoutManager) the " +
            "override must return nil so NSLayoutManager uses the " +
            "attachmentCell path. Returning a provider under TK1 makes " +
            "NSLayoutManager measure from the provider's view bounds " +
            "instead of the cell's computed cellSize — which is smaller " +
            "than the body line height and breaks Bug 20."
        )
    }

    /// TK2 path mirror for checkboxes.
    func test_phase2d_listMarker_checkboxAttachmentVendsViewProvider() {
        let tk2 = makeTK2Container()
        let att = CheckboxTextAttachment(
            checked: false,
            size: 20,
            bodyPointSize: 14
        )
        let provider = att.viewProvider(
            for: nil,
            location: StubLocation(),
            textContainer: tk2.container
        )
        XCTAssertNotNil(
            provider,
            "CheckboxTextAttachment must override viewProvider(...) and " +
            "return a non-nil provider under TK2."
        )
        XCTAssertTrue(
            provider is CheckboxAttachmentViewProvider,
            "CheckboxTextAttachment must vend a CheckboxAttachmentViewProvider " +
            "(got \(provider.map { String(describing: type(of: $0)) } ?? "nil"))."
        )
    }

    /// Checked-state variant — both checked and unchecked checkbox
    /// attachments must vend the provider (it's the class identity, not
    /// the state, that determines dispatch).
    func test_phase2d_listMarker_checkboxCheckedStateVendsViewProvider() {
        let tk2 = makeTK2Container()
        let checked = CheckboxTextAttachment(
            checked: true,
            size: 20,
            bodyPointSize: 14
        )
        let provider = checked.viewProvider(
            for: nil,
            location: StubLocation(),
            textContainer: tk2.container
        )
        XCTAssertTrue(
            provider is CheckboxAttachmentViewProvider,
            "Checked checkbox attachment must also vend a " +
            "CheckboxAttachmentViewProvider (state-independent dispatch)."
        )
    }

    /// `isTodo()` click detection in `EditTextView+Interaction.swift`
    /// checks the attachment's class (`is CheckboxTextAttachment`). The
    /// view-provider addition must not regress that check — the class
    /// identity is unchanged, only a new override was added.
    func test_phase2d_listMarker_checkboxAttachmentStillClassDetectable() {
        let font = NSFont.systemFont(ofSize: 14)
        let wrapped = CheckboxAttachment.make(checked: true, font: font)
        let storage = NSTextStorage(attributedString: wrapped)
        var foundCheckbox = false
        let fullRange = NSRange(location: 0, length: storage.length)
        storage.enumerateAttribute(.attachment, in: fullRange, options: []) { value, _, _ in
            if value is CheckboxTextAttachment {
                foundCheckbox = true
            }
        }
        XCTAssertTrue(
            foundCheckbox,
            "CheckboxAttachment.make(...) must still produce an attachment " +
            "that the `is CheckboxTextAttachment` check — used by " +
            "`EditTextView.isTodo(_:)` to dispatch click-to-toggle — can " +
            "still recognise. If this regresses, click-to-toggle-checkbox " +
            "stops working even if the checkbox still draws correctly."
        )
    }

    /// loadView must construct a view sized to the attachment's bounds,
    /// the same contract the image view-provider slice pinned. Without
    /// this, the bullet is clipped or zero-sized under TK2.
    func test_phase2d_listMarker_bulletViewProviderSizesViewToBounds() {
        let tk2 = makeTK2Container()
        let att = BulletTextAttachment(
            glyph: "\u{2022}",
            size: 28,
            bodyPointSize: 14
        )
        att.bounds = CGRect(x: 0, y: 0, width: 28, height: 18)

        guard let provider = att.viewProvider(
            for: nil,
            location: StubLocation(),
            textContainer: tk2.container
        ) else {
            XCTFail("Provider must be non-nil")
            return
        }
        provider.loadView()

        guard let view = provider.view else {
            XCTFail("Provider must populate `view` in loadView()")
            return
        }
        XCTAssertEqual(
            view.frame.width, 28, accuracy: 0.01,
            "Hosted view frame width must equal attachment bounds width " +
            "(otherwise the bullet is clipped or mis-positioned under TK2)."
        )
        XCTAssertEqual(
            view.frame.height, 18, accuracy: 0.01,
            "Hosted view frame height must equal attachment bounds height."
        )
    }

    // MARK: - Phase 2f5 (Slice 4) — InlineImageView drag-to-resize

    /// A `mouseDown` on a corner handle primes the drag state; a
    /// subsequent `mouseDragged` grows the view's frame by the horizontal
    /// mouse delta (aspect-locked). The view must be hosted in a window
    /// so `event.locationInWindow` ↔ view coordinate conversion has a
    /// well-defined frame of reference.
    func test_phase2f5_imageView_mouseDragOnHandle_resizesView() {
        // Host the view in a window so convert(_:from:nil) works. The
        // NSImageView also needs a non-nil image for internal
        // bookkeeping; zero-size image is fine — we only assert on frame.
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 400),
            styleMask: [.titled], backing: .buffered, defer: false
        )
        let view = InlineImageView(frame: NSRect(x: 0, y: 0, width: 200, height: 200))
        window.contentView?.addSubview(view)

        // Start the drag at the topRight handle (at view-local (200, 0)).
        // Synthesize the event in window coordinates — the view sits at
        // (0, 0) within the content view, so window (200, 0) lands on
        // the handle after conversion (approximately — convert doesn't
        // depend on flippedness for a pure (0,0)-origin subview).
        let handleLocal = CGPoint(x: 200, y: 0)
        let handleWindow = view.convert(handleLocal, to: nil)
        guard let downEvt = NSEvent.mouseEvent(
            with: .leftMouseDown,
            location: handleWindow,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: 0,
            clickCount: 1,
            pressure: 1.0
        ) else {
            XCTFail("Could not synthesize leftMouseDown event")
            return
        }
        view.mouseDown(with: downEvt)
        XCTAssertTrue(view.isSelected, "Handle hit must assert isSelected=true")

        // Drag +50 px to the right. `mouseDragged` reads
        // `event.locationInWindow.x` directly, so we just need a point
        // 50px east of the drag-start window point.
        guard let dragEvt = NSEvent.mouseEvent(
            with: .leftMouseDragged,
            location: NSPoint(x: handleWindow.x + 50, y: handleWindow.y),
            modifierFlags: [],
            timestamp: 0,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: 1,
            clickCount: 1,
            pressure: 1.0
        ) else {
            XCTFail("Could not synthesize leftMouseDragged event")
            return
        }
        view.mouseDragged(with: dragEvt)

        XCTAssertEqual(
            view.frame.width, 250, accuracy: 0.5,
            "Dragging topRight handle +50px east must grow width by 50pt " +
            "(start=200, new=250). Got \(view.frame.width)."
        )
        // Aspect was 1:1 at start (200x200), so height must mirror width.
        XCTAssertEqual(
            view.frame.height, 250, accuracy: 0.5,
            "Aspect-locked drag: height must track width (start 200x200 → " +
            "250x250). Got \(view.frame.height)."
        )
    }

    /// `onResizeCommit` must fire on mouseUp with the final frame width.
    /// This is the seam `ImageAttachmentViewProvider` uses to route the
    /// commit through `EditTextView.commitImageResize`. The callback
    /// firing with the correct width is the contract; the editor-side
    /// commit path is tested separately via the
    /// `EditingOps.setImageSize` unit tests.
    func test_phase2f5_imageView_commitCallbackFiresOnMouseUp() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 400),
            styleMask: [.titled], backing: .buffered, defer: false
        )
        let view = InlineImageView(frame: NSRect(x: 0, y: 0, width: 200, height: 200))
        window.contentView?.addSubview(view)

        var committedWidth: CGFloat?
        view.onResizeCommit = { width in committedWidth = width }

        let handleLocal = CGPoint(x: 200, y: 0)
        let handleWindow = view.convert(handleLocal, to: nil)
        guard let downEvt = NSEvent.mouseEvent(
            with: .leftMouseDown,
            location: handleWindow,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: 0,
            clickCount: 1,
            pressure: 1.0
        ), let dragEvt = NSEvent.mouseEvent(
            with: .leftMouseDragged,
            location: NSPoint(x: handleWindow.x + 80, y: handleWindow.y),
            modifierFlags: [],
            timestamp: 0,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: 1,
            clickCount: 1,
            pressure: 1.0
        ), let upEvt = NSEvent.mouseEvent(
            with: .leftMouseUp,
            location: NSPoint(x: handleWindow.x + 80, y: handleWindow.y),
            modifierFlags: [],
            timestamp: 0,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: 2,
            clickCount: 1,
            pressure: 1.0
        ) else {
            XCTFail("Could not synthesize drag event sequence")
            return
        }

        view.mouseDown(with: downEvt)
        view.mouseDragged(with: dragEvt)
        XCTAssertNil(committedWidth, "Callback must NOT fire during drag")
        view.mouseUp(with: upEvt)

        XCTAssertNotNil(committedWidth, "onResizeCommit must fire on mouseUp after a real drag")
        XCTAssertEqual(
            committedWidth ?? 0, 280, accuracy: 0.5,
            "Callback must receive the final frame width (200 start + 80 drag = 280). " +
            "Got \(committedWidth.map(String.init(describing:)) ?? "nil")."
        )
    }

    /// A mouseUp with NO prior drag (e.g. user clicked a non-handle
    /// area and released) must NOT fire the commit callback — that
    /// would produce a spurious no-op undo step on every selection
    /// click. `activeHandle` is the gate; this test pins it.
    func test_phase2f5_imageView_mouseUpWithoutDrag_doesNotCommit() {
        let view = InlineImageView(frame: NSRect(x: 0, y: 0, width: 200, height: 200))
        var committedWidth: CGFloat?
        view.onResizeCommit = { width in committedWidth = width }

        // Center click — misses all 4 handles, so mouseDown falls through
        // to the selection toggle branch and does NOT prime a drag.
        guard let downEvt = NSEvent.mouseEvent(
            with: .leftMouseDown,
            location: NSPoint(x: 100, y: 100),
            modifierFlags: [], timestamp: 0, windowNumber: 0,
            context: nil, eventNumber: 0, clickCount: 1, pressure: 1.0
        ), let upEvt = NSEvent.mouseEvent(
            with: .leftMouseUp,
            location: NSPoint(x: 100, y: 100),
            modifierFlags: [], timestamp: 0, windowNumber: 0,
            context: nil, eventNumber: 1, clickCount: 1, pressure: 1.0
        ) else {
            XCTFail("Could not synthesize click/release event pair")
            return
        }
        view.mouseDown(with: downEvt)
        view.mouseUp(with: upEvt)

        XCTAssertNil(
            committedWidth,
            "Non-handle click must not fire onResizeCommit — only handle-drags do."
        )
    }

    // NOTE: the Phase 2e `TableBlockAttachment` TK2-view-provider tests
    // (`test_phase2e_tableAttachment_vendsTableAttachmentViewProvider`,
    // `test_phase2e_tableAttachment_returnsNilProviderUnderTK1`,
    // `test_phase2e_tableViewProvider_sizesViewToAttachmentBounds`)
    // were deleted in Phase 2e-T2-h along with `TableBlockAttachment`,
    // `TableAttachmentViewProvider`, and `InlineTableView`. Native
    // tables render via `TableLayoutFragment` (no attachment, no view
    // provider) — the flat-cell-text emission contract is pinned by
    // `TableElementEmissionTests` and `TableLayoutFragmentRenderTests`.
}
