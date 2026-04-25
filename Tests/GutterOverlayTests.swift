//
//  GutterOverlayTests.swift
//  FSNotesTests
//
//  Phase 2f.2 — TK2 gutter overlay fold-caret tests.
//
//  Under TK1 the gutter used `NSLayoutManager.enumerateLineFragments` to
//  locate heading y-positions. Under TK2 that path is nil; the gutter
//  instead enumerates `HeadingLayoutFragment`s via
//  `NSTextLayoutManager.enumerateTextLayoutFragments`. These tests
//  cover:
//
//  1. `GutterController.visibleHeadingsTK2()` — finds every heading in
//     the document and reports its y-midpoint + start character index.
//  2. Click-on-caret hit testing — simulating a mouse click at the
//     drawn caret's (x, y) toggles the `.foldedContent` attribute on
//     the heading's trailing content range via
//     `TextStorageProcessor.toggleFold`.
//
//  Both tests use the standard `EditorHarness`, which is TK2-native
//  (editor constructed via `init(frame:)` — see `EditTextView.swift`
//  Phase 2a comments).
//

import XCTest
import AppKit
@testable import FSNotes

final class GutterOverlayTests: XCTestCase {

    // MARK: - Fragment discovery

    /// Three ATX headings — one H1, one H2, one H3 — each followed by
    /// a paragraph. The gutter must find 3 heading fragments and the
    /// reported character indexes must each map back to a heading block
    /// via `processor.headerBlockIndex(at:)`.
    func test_phase2f2_gutterFindsHeadingFragmentsUnderTK2() {
        let markdown = """
        # One
        body one

        ## Two
        body two

        ### Three
        body three
        """
        let harness = EditorHarness(markdown: markdown)
        defer { harness.teardown() }

        let editor = harness.editor

        // Sanity: EditorHarness constructs the editor via `init(frame:)`
        // so it must be on TK2. If this ever regresses the test below
        // would be meaningless.
        XCTAssertNotNil(
            editor.textLayoutManager,
            "EditorHarness must yield a TK2 editor for Phase 2f.2 tests"
        )
        // Phase 4.5: `layoutManagerIfTK1` property was deleted along with
        // the custom TK1 `LayoutManager` subclass. The TK2 precondition
        // is now satisfied by construction — no TK1 accessor to assert
        // against.

        // Phase 4.6: the `documentProjection` setter auto-syncs
        // `processor.blocks`. The harness seeds via the setter so
        // fold-state queries (`headerBlockIndex(at:)`) and the gutter
        // caret hit test have a populated block list without any
        // explicit priming here.

        // Force layout so `enumerateTextLayoutFragments(... .ensuresLayout)`
        // has fragments to iterate.
        if let tlm = editor.textLayoutManager {
            tlm.ensureLayout(for: tlm.documentRange)
        }

        let headings = editor.gutterController.visibleHeadingsTK2()
        XCTAssertEqual(
            headings.count, 3,
            "Expected 3 HeadingLayoutFragments; got \(headings.count)"
        )

        // Every heading record's `charIndex` must resolve to a header
        // block via the processor — this is the hook the click path
        // relies on.
        guard let processor = editor.textStorageProcessor else {
            XCTFail("Expected textStorageProcessor to be wired")
            return
        }
        for (i, heading) in headings.enumerated() {
            XCTAssertNotNil(
                processor.headerBlockIndex(at: heading.charIndex),
                "Heading #\(i) at charIndex=\(heading.charIndex) did " +
                "not resolve to a header block"
            )
        }

        // Headings should be in document order (ascending y, ascending
        // charIndex). If the enumeration ever returns them out of order
        // the click hit-test would still work but the draw order would
        // be wrong for overlapping icons — belt and braces.
        for i in 1..<headings.count {
            XCTAssertLessThan(
                headings[i - 1].charIndex, headings[i].charIndex,
                "Headings must be enumerated in document order"
            )
            XCTAssertLessThanOrEqual(
                headings[i - 1].minY, headings[i].minY,
                "Heading y-positions must be monotonically non-decreasing"
            )
        }
    }

    // MARK: - Click on caret toggles fold

    /// With a single H1 followed by a paragraph, simulate a click at
    /// the caret's (x, y) — the caret x is `textContainerOrigin.x - 4`
    /// ish, y is the heading fragment's midY. The click should route
    /// through `GutterController.handleClick` and flip the heading's
    /// fold state. Verify by reading `.foldedContent` off the storage
    /// at the paragraph below (which becomes folded).
    func test_phase2f2_gutterClickOnCaret_togglesFold() {
        let markdown = """
        # Only
        body text
        """
        let harness = EditorHarness(markdown: markdown)
        defer { harness.teardown() }

        let editor = harness.editor

        guard let tlm = editor.textLayoutManager else {
            XCTFail("Expected TK2 layout manager")
            return
        }

        // Phase 4.6: setter auto-syncs `processor.blocks`; no priming needed.

        tlm.ensureLayout(for: tlm.documentRange)

        let headings = editor.gutterController.visibleHeadingsTK2()
        XCTAssertEqual(headings.count, 1, "Expected 1 heading")
        guard let heading = headings.first else { return }

        // Build a synthetic NSEvent positioned at the gutter caret.
        // The caret x lives between the gutter's left edge and the
        // text container's left edge; any x inside that band should
        // dispatch through `handleClick`. The y must be inside the
        // heading fragment's [minY, maxY] band so
        // `headerBlockIndexForClickYTK2` matches.
        let gutterWidth = EditTextView.gutterWidth
        let containerInsetX = editor.textContainerInset.width
        let clickX = containerInsetX - gutterWidth / 2 // centered in gutter
        let clickY = heading.midY

        // `NSEvent.mouseEvent` wants window coordinates — convert the
        // view-local point up. The editor is parked at origin (0,0)
        // inside a borderless offscreen window by the harness, so the
        // transform is effectively identity, but the conversion keeps
        // the test resilient to any harness change that nudges it.
        let viewPoint = NSPoint(x: clickX, y: clickY)
        let windowPoint = editor.convert(viewPoint, to: nil)

        guard let window = editor.window else {
            XCTFail("Harness editor must have a window")
            return
        }
        guard let event = NSEvent.mouseEvent(
            with: .leftMouseDown,
            location: windowPoint,
            modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: 0,
            clickCount: 1,
            pressure: 1.0
        ) else {
            XCTFail("Could not synthesize mouse event")
            return
        }

        // Before-state: no `.foldedContent` attribute anywhere.
        guard let storage = editor.textStorage else {
            XCTFail("Expected storage")
            return
        }
        let fullRange = NSRange(location: 0, length: storage.length)
        var hadFoldedBefore = false
        storage.enumerateAttribute(.foldedContent, in: fullRange) {
            value, _, _ in
            if value != nil { hadFoldedBefore = true }
        }
        XCTAssertFalse(
            hadFoldedBefore,
            "Freshly-seeded note must not have any .foldedContent"
        )

        // Dispatch the click.
        let handled = editor.gutterController.handleClick(event)
        XCTAssertTrue(
            handled,
            "Gutter caret click must be handled by GutterController"
        )

        // After-state: at least one character in storage must now
        // carry `.foldedContent`. The exact range is a
        // `TextStorageProcessor.toggleFold` contract, not a gutter
        // concern — we just assert that the fold toggle actually fired.
        var hasFoldedAfter = false
        storage.enumerateAttribute(.foldedContent, in: fullRange) {
            value, _, _ in
            if value != nil { hasFoldedAfter = true }
        }
        XCTAssertTrue(
            hasFoldedAfter,
            "Gutter click on fold caret must toggle .foldedContent on " +
            "at least one character of storage"
        )

        // And the heading's block itself must be marked `collapsed`.
        guard let processor = editor.textStorageProcessor else {
            XCTFail("Expected processor")
            return
        }
        guard let blockIdx = processor.headerBlockIndex(at: heading.charIndex) else {
            XCTFail("Expected heading block at charIndex=\(heading.charIndex)")
            return
        }
        XCTAssertTrue(
            processor.blocks[blockIdx].collapsed,
            "Heading block must report collapsed=true after toggle"
        )
    }

    // MARK: - Phase 2f.2b — Code block fragment discovery (TK2)

    /// Two fenced code blocks separated by a paragraph. The gutter
    /// must enumerate TWO logical code blocks under TK2 — one per
    /// `processor.blocks` entry — even though each multi-line block
    /// produces multiple adjacent `CodeBlockLayoutFragment`s (TK2
    /// paragraph-splits on `\n`). Each record must carry a
    /// `contentRange` that, when substringed from storage, yields the
    /// exact code text between the fences.
    func test_phase2f2_gutterFindsCodeBlockFragmentsUnderTK2() {
        let markdown = """
        para one

        ```
        alpha
        beta
        ```

        interleaved para

        ```swift
        let x = 1
        ```
        """
        let harness = EditorHarness(markdown: markdown)
        defer { harness.teardown() }

        let editor = harness.editor

        // Sanity: must be on TK2 (EditorHarness uses `init(frame:)`).
        XCTAssertNotNil(
            editor.textLayoutManager,
            "EditorHarness must yield a TK2 editor"
        )
        // Phase 4.5: `layoutManagerIfTK1` property was deleted along with
        // the custom TK1 `LayoutManager` subclass. The TK2 precondition
        // is now satisfied by construction — no TK1 accessor to assert
        // against.

        // Phase 4.6: setter auto-syncs `processor.blocks`; the code-block
        // discovery path picks up the populated list without priming.

        if let tlm = editor.textLayoutManager {
            tlm.ensureLayout(for: tlm.documentRange)
        }

        let codeBlocks = editor.gutterController.visibleCodeBlocksTK2()
        XCTAssertEqual(
            codeBlocks.count, 2,
            "Expected 2 logical code blocks; got \(codeBlocks.count). " +
            "Adjacent CodeBlockLayoutFragments from the SAME block must " +
            "collapse into a single record."
        )

        // The two blocks must be in document order (ascending y AND
        // ascending range.location).
        if codeBlocks.count == 2 {
            XCTAssertLessThan(
                codeBlocks[0].firstLineMinY, codeBlocks[1].firstLineMinY,
                "Code blocks must be enumerated top-to-bottom"
            )
            XCTAssertLessThan(
                codeBlocks[0].range.location, codeBlocks[1].range.location,
                "Code blocks must be enumerated in document order"
            )
        }

        // Each record's `contentRange` must carve out the code text
        // between the fences. Substring it and assert the content.
        guard let storage = editor.textStorage else {
            XCTFail("Expected storage")
            return
        }
        let nsString = storage.string as NSString
        if codeBlocks.count >= 1 {
            let first = codeBlocks[0]
            XCTAssertTrue(
                first.contentRange.location >= 0 &&
                NSMaxRange(first.contentRange) <= storage.length,
                "First code block contentRange must lie within storage"
            )
            let firstContent = nsString.substring(with: first.contentRange)
            XCTAssertTrue(
                firstContent.contains("alpha") && firstContent.contains("beta"),
                "First code block content must carry 'alpha' and 'beta'; " +
                "got \(firstContent.debugDescription)"
            )
        }
        if codeBlocks.count >= 2 {
            let second = codeBlocks[1]
            XCTAssertTrue(
                second.contentRange.location >= 0 &&
                NSMaxRange(second.contentRange) <= storage.length,
                "Second code block contentRange must lie within storage"
            )
            let secondContent = nsString.substring(with: second.contentRange)
            XCTAssertTrue(
                secondContent.contains("let x = 1"),
                "Second code block content must carry 'let x = 1'; got " +
                "\(secondContent.debugDescription)"
            )
        }
    }

    // MARK: - Phase 2f.2b — H-level badges (TK2)
    //
    // The draw path itself is side-effecting (`NSString.draw(at:...)`),
    // so we can't capture a badge directly without an offscreen
    // bitmap. Instead assert on the INPUT state the draw code
    // consumes: under TK2, `visibleHeadingsTK2()` + the `.headingLevel`
    // attribute on storage at each heading's `charIndex` are the
    // sole sources for the badge's level string. If those agree with
    // the seeded markdown levels for every heading on the page, the
    // badge drawing is correct by construction. This mirrors the
    // testing philosophy from CLAUDE.md rule 3 (test pure primitives,
    // not widget side effects).

    func test_phase2f2_gutterRendersHBadges_whenHovered() {
        let markdown = """
        # One
        ## Two
        ### Three
        #### Four
        ##### Five
        ###### Six
        """
        let harness = EditorHarness(markdown: markdown)
        defer { harness.teardown() }

        let editor = harness.editor

        XCTAssertNotNil(editor.textLayoutManager, "Must be TK2")
        // Phase 4.5: `layoutManagerIfTK1` deleted — TK2 precondition is
        // satisfied by construction.

        // Phase 4.6: setter auto-syncs `processor.blocks`; no priming.
        if let tlm = editor.textLayoutManager {
            tlm.ensureLayout(for: tlm.documentRange)
        }

        guard let storage = editor.textStorage else {
            XCTFail("Expected storage")
            return
        }

        // Simulate hover — the draw path only renders badges when the
        // mouse is in the gutter OR the cursor is parked on the
        // heading. Flipping the flag represents "mouse entered the
        // gutter" — no timing dance required.
        editor.gutterController.isMouseInGutter = true

        let headings = editor.gutterController.visibleHeadingsTK2()
        XCTAssertEqual(
            headings.count, 6,
            "Expected 6 heading fragments for H1..H6"
        )

        // For each heading, the `.headingLevel` attribute on storage
        // (set by DocumentRenderer) must match its ordinal position
        // 1..6. The draw code reads EXACTLY this attribute to pick
        // the badge's level string.
        let expectedLevels = [1, 2, 3, 4, 5, 6]
        for (i, heading) in headings.enumerated() {
            XCTAssertTrue(
                heading.charIndex >= 0 &&
                heading.charIndex < storage.length,
                "Heading #\(i) charIndex out of bounds"
            )
            let level = storage.attribute(
                .headingLevel,
                at: heading.charIndex,
                effectiveRange: nil
            ) as? Int
            XCTAssertEqual(
                level, expectedLevels[i],
                "Heading #\(i) must carry `.headingLevel = \(expectedLevels[i])`; " +
                "got \(String(describing: level))"
            )
        }

        // Exercise the draw path end-to-end so a crash or bad
        // attribute access would surface here. We can't inspect the
        // bitmap, but if `drawIcons(in:)` blows up (nil deref, out-
        // of-bounds) the test fails. This also keeps coverage data
        // accurate for the badge branch.
        let rect = editor.bounds
        let bitmap = editor.bitmapImageRepForCachingDisplay(in: rect)
        XCTAssertNotNil(bitmap, "Must be able to allocate a bitmap rep")
        if let bitmap = bitmap {
            editor.cacheDisplay(in: rect, to: bitmap)
        }

        // Double-check the toggle: when hover is off, visibleHeadings
        // still returns the same 6 records — the draw-path branch
        // that HIDES the badge is the `isMouseInGutter` flag, not the
        // enumeration.
        editor.gutterController.isMouseInGutter = false
        XCTAssertEqual(
            editor.gutterController.visibleHeadingsTK2().count, 6,
            "Heading enumeration must be independent of hover state"
        )
    }

    // MARK: - Bug #28 — Folded heading hides table/code-block copy icons

    /// Folding a heading whose section contains a table must remove
    /// that table from `visibleTablesTK2()` so the gutter copy icon
    /// disappears alongside the hidden table content. Pre-fix the
    /// table fragment is enumerated regardless of its `.foldedContent`
    /// attribute and the icon stays drawn over the now-blank fold area.
    func test_bug28_foldedHeader_hidesTableCopyIcon() {
        let markdown = """
        # Heading

        | col1 | col2 |
        |------|------|
        | a    | b    |
        """
        let harness = EditorHarness(markdown: markdown)
        defer { harness.teardown() }

        let editor = harness.editor
        guard let tlm = editor.textLayoutManager,
              let storage = editor.textStorage,
              let processor = editor.textStorageProcessor else {
            XCTFail("Expected TK2 editor with storage + processor")
            return
        }
        tlm.ensureLayout(for: tlm.documentRange)

        // Pre-fold sanity: exactly one table is visible to the gutter.
        let beforeFold = editor.gutterController.visibleTablesTK2()
        XCTAssertEqual(
            beforeFold.count, 1,
            "Pre-fold: expected exactly 1 visible table; got " +
            "\(beforeFold.count)"
        )

        // Fold the H1 heading (block index 0).
        guard let headerIdx = processor.headerBlockIndex(at: 0) else {
            XCTFail("Expected heading at storage offset 0")
            return
        }
        processor.toggleFold(headerBlockIndex: headerIdx, textStorage: storage)
        XCTAssertTrue(
            processor.blocks[headerIdx].collapsed,
            "Heading must be marked collapsed after toggleFold"
        )
        tlm.ensureLayout(for: tlm.documentRange)

        // Post-fold: the table fragment is hidden by `FoldedLayoutFragment`
        // dispatch, so its copy icon must also disappear. Bug #28 — pre-
        // fix this returned 1 (icon still drawn over the blank fold).
        let afterFold = editor.gutterController.visibleTablesTK2()
        XCTAssertEqual(
            afterFold.count, 0,
            "Bug #28: a table inside a folded heading must NOT appear in " +
            "visibleTablesTK2(); got \(afterFold.count) entries — the " +
            "gutter copy icon would draw over the hidden fold area."
        )
    }

    /// Sibling test for code blocks: a fenced code block inside a folded
    /// heading section must not appear in `visibleCodeBlocksTK2()` so
    /// its gutter copy icon disappears with the rest of the section.
    func test_bug28_foldedHeader_hidesCodeBlockCopyIcon() {
        let markdown = """
        # Heading

        ```swift
        let x = 1
        ```
        """
        let harness = EditorHarness(markdown: markdown)
        defer { harness.teardown() }

        let editor = harness.editor
        guard let tlm = editor.textLayoutManager,
              let storage = editor.textStorage,
              let processor = editor.textStorageProcessor else {
            XCTFail("Expected TK2 editor with storage + processor")
            return
        }
        tlm.ensureLayout(for: tlm.documentRange)

        // Pre-fold sanity: exactly one code block is visible.
        let beforeFold = editor.gutterController.visibleCodeBlocksTK2()
        XCTAssertEqual(
            beforeFold.count, 1,
            "Pre-fold: expected exactly 1 visible code block; got " +
            "\(beforeFold.count)"
        )

        // Fold the H1 heading.
        guard let headerIdx = processor.headerBlockIndex(at: 0) else {
            XCTFail("Expected heading at storage offset 0")
            return
        }
        processor.toggleFold(headerBlockIndex: headerIdx, textStorage: storage)
        XCTAssertTrue(processor.blocks[headerIdx].collapsed)
        tlm.ensureLayout(for: tlm.documentRange)

        // Post-fold: code block must be filtered out — its copy icon
        // would otherwise float over the hidden fold area.
        let afterFold = editor.gutterController.visibleCodeBlocksTK2()
        XCTAssertEqual(
            afterFold.count, 0,
            "Bug #28: a code block inside a folded heading must NOT " +
            "appear in visibleCodeBlocksTK2(); got \(afterFold.count)."
        )
    }
}
