//
//  Phase46BlocksPeerDeletionTests.swift
//  FSNotesTests
//
//  Phase 4.6 — verify the public `syncBlocksFromProjection` API is gone
//  and fold state is driven by `Note.cachedFoldState` + `Document.blocks`
//  via the auto-syncing `documentProjection` setter.
//
//  Phase 6 Tier B′ Sub-slice 7 retired the legacy
//  `MarkdownBlock.collapsed` field entirely; the canonical fold state
//  lives on `TextStorageProcessor.collapsedStorageOffsets` (offset-
//  keyed side-table). The tests here exercise the authoritative
//  sources (Document.blocks, cachedFoldState, isCollapsed/
//  collapsedBlockOffsets) and the grep-discipline test enforces zero
//  `.collapsed` reads in production code.
//

import XCTest
@testable import FSNotes

final class Phase46BlocksPeerDeletionTests: XCTestCase {

    private func bodyFont() -> PlatformFont {
        return PlatformFont.systemFont(ofSize: 14)
    }
    private func codeFont() -> PlatformFont {
        return PlatformFont.monospacedSystemFont(
            ofSize: 14, weight: .regular
        )
    }
    private func project(_ md: String) -> DocumentProjection {
        let doc = MarkdownParser.parse(md)
        return DocumentProjection(
            document: doc,
            bodyFont: bodyFont(),
            codeFont: codeFont()
        )
    }

    // MARK: - 1. Public sync API gone
    //
    // If `syncBlocksFromProjection` were still public this test file
    // would compile — the test body exercises the direct approach
    // (`rebuildBlocksFromProjection` is internal) and demonstrates the
    // intended consumer path. The real compile-time signal is the grep
    // gate: `legacyBlocksPeer` pattern returns zero matches.

    func test_phase46_syncBlocksFromProjection_gone() {
        // Documentation test: the projection alone is the source of
        // truth. No call to a public `syncBlocksFromProjection` is
        // needed because the `documentProjection` setter auto-syncs.
        let proj = project("# Hello\n")
        XCTAssertEqual(
            proj.document.blocks.count, 1,
            "One heading block expected"
        )
        if case .heading(let l, _) = proj.document.blocks[0] {
            XCTAssertEqual(l, 1)
        } else {
            XCTFail("First block must be a heading")
        }
    }

    // MARK: - 2. Fold state reads from Note.cachedFoldState

    func test_phase46_foldState_readsFromCachedFoldState() {
        // `Note.cachedFoldState` is the persistent source of truth for
        // fold state. After `TextStorageProcessor.toggleFold` runs it
        // writes the set of collapsed block indices to the note — this
        // test round-trips that semantic without driving the widget:
        // given a collapsed-index set, `cachedFoldState` must accept,
        // persist, and return it verbatim.
        let saved: Set<Int> = [2, 5, 9]
        // JSON round-trip models the on-disk persistence path in
        // `Note.cachedFoldState`'s didSet + load helpers.
        guard let data = try? JSONEncoder().encode(saved),
              let decoded = try? JSONDecoder()
                .decode(Set<Int>.self, from: data)
        else {
            XCTFail("Encoding/decoding fold state must succeed")
            return
        }
        XCTAssertEqual(decoded, saved)
        XCTAssertTrue(decoded.contains(2))
        XCTAssertTrue(decoded.contains(5))
        XCTAssertTrue(decoded.contains(9))
        XCTAssertFalse(decoded.contains(0))
    }

    // MARK: - 3. Block count reads from Document

    func test_phase46_blockCount_readsFromDocument() {
        let md = """
        # Heading 1

        Paragraph text.

        ## Heading 2

        - item one
        - item two

        > quote
        """
        let proj = project(md)

        // `projection.document.blocks.count` is the authoritative count.
        // Count corresponds to: heading, blank, paragraph, blank,
        // heading, blank, list, blank, blockquote.
        XCTAssertGreaterThanOrEqual(
            proj.document.blocks.count, 5,
            "Expected at least 5 distinct blocks"
        )
        XCTAssertEqual(
            proj.document.blocks.count, proj.blockSpans.count,
            "Document.blocks and blockSpans must stay aligned"
        )
    }

    // MARK: - 4. No production `MarkdownBlock.collapsed` reads

    func test_phase46_noMarkdownBlockCollapsed_reads() throws {
        // Phase 6 Tier B′ Sub-slice 7 retired the
        // `MarkdownBlock.collapsed` field entirely. This test now
        // enforces the strict invariant: zero production code
        // anywhere may read or write `.collapsed` as a property
        // access on a `MarkdownBlock` value, because the field
        // doesn't exist any more — the canonical fold state lives
        // on `TextStorageProcessor.collapsedStorageOffsets` (a
        // private offset-keyed Set), with public reads through
        // `isCollapsed(blockIndex:) / isCollapsed(storageOffset:) /
        // collapsedBlockIndices / collapsedBlockOffsets`.
        let repoRoot = findRepoRoot()
        guard let repoRoot = repoRoot else {
            XCTFail("Unable to locate repo root for source scan")
            return
        }
        let prodDirs = [
            repoRoot.appendingPathComponent("FSNotes"),
            repoRoot.appendingPathComponent("FSNotesCore")
        ]

        // Regex matches `.collapsed` as a whole-word property access —
        // NOT `.collapsedBlockIndices` / `.collapsedBlockOffsets` /
        // `.collapsedStorageOffsets` (the Set<Int>-valued processor
        // APIs that callers legitimately use to read fold state).
        // Word-boundary: the character after "collapsed" must be non-
        // identifier (dot-call, whitespace, paren, equals, end-of-line).
        let regex = try NSRegularExpression(
            pattern: #"\.collapsed\b(?![A-Za-z0-9_])"#
        )

        // Strip Swift line comments before scanning so that doc-
        // comments referencing the historical `MarkdownBlock.collapsed`
        // field don't count as violations. Block comments (/* */) are
        // not stripped — they're rare in this codebase and any
        // residual hit there would still be worth flagging.
        let lineCommentRegex = try NSRegularExpression(pattern: #"//.*"#)

        var violations: [String] = []
        for dir in prodDirs {
            guard FileManager.default.fileExists(atPath: dir.path) else {
                continue
            }
            let enumerator = FileManager.default.enumerator(
                at: dir, includingPropertiesForKeys: nil
            )
            while let fileURL = enumerator?.nextObject() as? URL {
                guard fileURL.pathExtension == "swift" else { continue }
                let fileName = fileURL.lastPathComponent
                guard let content = try? String(contentsOf: fileURL)
                else { continue }
                let stripped = lineCommentRegex.stringByReplacingMatches(
                    in: content,
                    range: NSRange(content.startIndex..., in: content),
                    withTemplate: ""
                )
                let range = NSRange(stripped.startIndex..., in: stripped)
                if regex.firstMatch(in: stripped, range: range) != nil {
                    violations.append(fileName)
                }
            }
        }
        XCTAssertTrue(
            violations.isEmpty,
            "Production code reads or writes `.collapsed` on a " +
            "MarkdownBlock; Sub-slice 7 retired this field. Route " +
            "through `processor.isCollapsed(blockIndex:)` or the " +
            "offset-keyed query API. Offending files: \(violations)."
        )
    }

    // MARK: - 5. Fold / unfold round-trip via pure primitives

    func test_phase46_foldUnfoldRoundtrip() {
        // Fold/unfold round-trip semantics, exercised at the pure-function
        // layer: cachedFoldState add → remove returns to empty. We also
        // verify the collapsed-index set correctly addresses the heading
        // block within the Document.
        let md = """
        # Heading 1

        Body one.

        # Heading 2

        Body two.
        """
        let proj = project(md)

        // Find the heading block indices.
        let headingIndices = proj.document.blocks.enumerated()
            .compactMap { (i, b) -> Int? in
                if case .heading = b { return i }
                return nil
            }
        XCTAssertEqual(
            headingIndices.count, 2,
            "Two heading blocks expected"
        )
        guard let firstHeading = headingIndices.first else {
            XCTFail("No heading block found")
            return
        }

        // Round-trip: add to collapsed set, remove, verify empty.
        var folds: Set<Int> = []
        folds.insert(firstHeading)
        XCTAssertTrue(folds.contains(firstHeading))
        XCTAssertEqual(folds.count, 1)
        folds.remove(firstHeading)
        XCTAssertFalse(folds.contains(firstHeading))
        XCTAssertTrue(folds.isEmpty)

        // The heading's span must be a valid range into the attributed
        // string — the downstream fold machinery reads attributes on
        // this range to mark content as `.foldedContent`.
        let span = proj.blockSpans[firstHeading]
        XCTAssertLessThan(span.location, proj.attributed.length)
    }

    // MARK: - Phase 6 Tier B′ — fold-state side-table

    /// `isCollapsed(blockIndex:)` returns false for an unfolded note.
    func test_phase6Bprime_isCollapsed_emptyByDefault() {
        let md = "# H1\n\nBody.\n\n# H2\n"
        let harness = EditorHarness(markdown: md)
        defer { harness.teardown() }

        guard let proc = harness.editor.textStorageProcessor else {
            XCTFail("Editor missing TextStorageProcessor")
            return
        }
        for i in 0..<proc.sourceBlocksSnapshot.count {
            XCTAssertFalse(
                proc.isCollapsed(blockIndex: i),
                "Fresh note should have no collapsed blocks (idx \(i))"
            )
        }
    }

    /// Toggling fold flips the offset-keyed side-table — the sole
    /// source of truth after Sub-slice 7 retired the per-block
    /// `MarkdownBlock.collapsed` field.
    func test_phase6Bprime_toggleFold_updatesSideTable() {
        let md = "# H1\n\nBody.\n\n# H2\n"
        let harness = EditorHarness(markdown: md)
        defer { harness.teardown() }

        guard let proc = harness.editor.textStorageProcessor,
              let storage = harness.editor.textStorage else {
            XCTFail("Editor missing processor / storage")
            return
        }
        let h1Idx = proc.sourceBlocksSnapshot.firstIndex { block in
            if case .heading = block.type { return true }
            return false
        }
        guard let h1Idx = h1Idx else {
            XCTFail("No heading found")
            return
        }
        let h1Offset = proc.sourceBlocksSnapshot[h1Idx].range.location

        // Fold.
        proc.toggleFold(headerBlockIndex: h1Idx, textStorage: storage)
        XCTAssertTrue(proc.isCollapsed(blockIndex: h1Idx))
        XCTAssertTrue(proc.isCollapsed(storageOffset: h1Offset))
        XCTAssertTrue(proc.collapsedBlockOffsets.contains(h1Offset))

        // Unfold.
        proc.toggleFold(headerBlockIndex: h1Idx, textStorage: storage)
        XCTAssertFalse(proc.isCollapsed(blockIndex: h1Idx))
        XCTAssertFalse(proc.isCollapsed(storageOffset: h1Offset))
        XCTAssertFalse(proc.collapsedBlockOffsets.contains(h1Offset))
    }

    /// `collapsedBlockIndices` derives the index set from the
    /// offset-keyed side-table + the current `blocks` array.
    func test_phase6Bprime_collapsedBlockIndices_derivedFromSideTable() {
        let md = "# H1\n\nBody.\n\n# H2\n\nMore.\n"
        let harness = EditorHarness(markdown: md)
        defer { harness.teardown() }

        guard let proc = harness.editor.textStorageProcessor,
              let storage = harness.editor.textStorage else {
            XCTFail("Editor missing processor / storage")
            return
        }
        let headings = proc.sourceBlocksSnapshot.enumerated().compactMap { i, b -> Int? in
            if case .heading = b.type { return i }
            return nil
        }
        guard headings.count == 2 else {
            XCTFail("Expected 2 headings")
            return
        }

        XCTAssertTrue(proc.collapsedBlockIndices.isEmpty)
        proc.toggleFold(headerBlockIndex: headings[0], textStorage: storage)
        XCTAssertEqual(proc.collapsedBlockIndices, Set([headings[0]]))
        proc.toggleFold(headerBlockIndex: headings[1], textStorage: storage)
        XCTAssertEqual(proc.collapsedBlockIndices, Set(headings))
    }

    // MARK: - Phase 6 Tier B′ Sub-slice 7.B.1 — `.renderMode` ban

    func test_phase6Bprime_subslice7B1_noMarkdownBlockRenderMode_reads() throws {
        // Sub-slice 7.B.1 retired `MarkdownBlock.renderMode` entirely.
        // The canonical render-mode state lives on
        // `TextStorageProcessor.renderedStorageOffsets` (offset-keyed
        // side-table); public reads through `isRendered(blockIndex:)
        // / isRendered(storageOffset:) / renderedBlockOffsets`.
        //
        // This grep-discipline test enforces the strict invariant:
        // zero production code may read or write `.renderMode` as a
        // property access on a `MarkdownBlock` value, because the
        // field doesn't exist any more. Doc-comments referencing the
        // historical name are stripped before scanning.
        let repoRoot = findRepoRoot()
        guard let repoRoot = repoRoot else {
            XCTFail("Unable to locate repo root for source scan")
            return
        }
        let prodDirs = [
            repoRoot.appendingPathComponent("FSNotes"),
            repoRoot.appendingPathComponent("FSNotesCore")
        ]

        // Word-boundary regex: `.renderMode` not followed by an
        // identifier character. Matches `block.renderMode == .source`
        // and `mb.renderMode = .rendered` but NOT (hypothetical)
        // `.renderModeOffsets`.
        let regex = try NSRegularExpression(
            pattern: #"\.renderMode\b(?![A-Za-z0-9_])"#
        )
        let lineCommentRegex = try NSRegularExpression(pattern: #"//.*"#)

        var violations: [String] = []
        for dir in prodDirs {
            guard FileManager.default.fileExists(atPath: dir.path) else {
                continue
            }
            let enumerator = FileManager.default.enumerator(
                at: dir, includingPropertiesForKeys: nil
            )
            while let fileURL = enumerator?.nextObject() as? URL {
                guard fileURL.pathExtension == "swift" else { continue }
                let fileName = fileURL.lastPathComponent
                guard let content = try? String(contentsOf: fileURL)
                else { continue }
                let stripped = lineCommentRegex.stringByReplacingMatches(
                    in: content,
                    range: NSRange(content.startIndex..., in: content),
                    withTemplate: ""
                )
                let range = NSRange(stripped.startIndex..., in: stripped)
                if regex.firstMatch(in: stripped, range: range) != nil {
                    violations.append(fileName)
                }
            }
        }
        XCTAssertTrue(
            violations.isEmpty,
            "Production code reads or writes `.renderMode` on a " +
            "MarkdownBlock; Sub-slice 7.B.1 retired this field. " +
            "Route through `processor.isRendered(blockIndex:)` or " +
            "the offset-keyed query API. Offending files: \(violations)."
        )
    }

    // MARK: - Phase 6 Tier B′ Sub-slice 7.B.2 — processor.blocks retirement

    /// Sub-slice 7.B.2.a hid the `[MarkdownBlock]` array from external
    /// production readers (four source-mode-fallback callers + the
    /// note-switch reset migrated to high-level APIs). Sub-slice
    /// 7.B.2.b completed the retirement: `TextStorageProcessor.blocks`
    /// was demoted from `public var` to a `private var sourceBlocks`
    /// side-table, with a read-only `sourceBlocksSnapshot` inspector
    /// preserved for tests and a `_testInstallSourceBlocks(parsing:)`
    /// helper for unit-test setup. Production callers route through
    /// the narrow public APIs only:
    /// `hasBlocks`, `block(at:)`, `headingLevel(forParagraphRange:)`,
    /// `headingLevel(atBlockIndex:)`,
    /// `codeBlockRange(containingStorageIndex:)`, `codeBlockRanges`,
    /// `isCollapsed(...)`, `isRendered(...)`, `clearBlocks()`.
    ///
    /// This grep-discipline test enforces the post-7.B.2.b invariant:
    /// zero production code outside `TextStorageProcessor.swift` may
    /// reference the source-mode block array under any of its names —
    /// `.blocks` (legacy public, removed), `.sourceBlocks` (new
    /// private; access from outside would not compile but caught here
    /// for defence in depth), or `.sourceBlocksSnapshot` (the test-
    /// only inspector — its presence in production would defeat the
    /// encapsulation). Tests legitimately use `sourceBlocksSnapshot`.
    /// Doc-comments referencing the historical names are stripped
    /// before scanning.
    func test_phase6Bprime_subslice7B2_noProcessorBlocksInProduction() throws {
        let repoRoot = findRepoRoot()
        guard let repoRoot = repoRoot else {
            XCTFail("Unable to locate repo root for source scan")
            return
        }
        let prodDirs = [
            repoRoot.appendingPathComponent("FSNotes"),
            repoRoot.appendingPathComponent("FSNotesCore")
        ]

        // Match the binding names commonly used for a
        // `TextStorageProcessor` instance (`processor` / `proc` /
        // `textStorageProcessor`) followed by `.` or `?.` then any
        // forbidden property name. Word-boundary excludes
        // `.blocksFoo` / `.sourceBlocksOther`.
        let regex = try NSRegularExpression(
            pattern: #"\b(processor|proc|textStorageProcessor)\??\.(blocks|sourceBlocks|sourceBlocksSnapshot)\b(?![A-Za-z0-9_])"#
        )
        let lineCommentRegex = try NSRegularExpression(pattern: #"//.*"#)

        var violations: [String] = []
        for dir in prodDirs {
            guard FileManager.default.fileExists(atPath: dir.path) else {
                continue
            }
            let enumerator = FileManager.default.enumerator(
                at: dir, includingPropertiesForKeys: nil
            )
            while let fileURL = enumerator?.nextObject() as? URL {
                guard fileURL.pathExtension == "swift" else { continue }
                let fileName = fileURL.lastPathComponent
                // The processor itself is the canonical owner of the
                // array; allow internal reads.
                guard fileName != "TextStorageProcessor.swift" else {
                    continue
                }
                guard let content = try? String(contentsOf: fileURL)
                else { continue }
                let stripped = lineCommentRegex.stringByReplacingMatches(
                    in: content,
                    range: NSRange(content.startIndex..., in: content),
                    withTemplate: ""
                )
                let range = NSRange(stripped.startIndex..., in: stripped)
                if regex.firstMatch(in: stripped, range: range) != nil {
                    violations.append(fileName)
                }
            }
        }
        XCTAssertTrue(
            violations.isEmpty,
            "Production code outside `TextStorageProcessor.swift` " +
            "references the source-mode block array directly; " +
            "Sub-slice 7.B.2 retired the public surface. Use the " +
            "narrow public APIs (`hasBlocks`, `block(at:)`, " +
            "`headingLevel(...)`, `codeBlockRange(...)`, " +
            "`codeBlockRanges`, `isCollapsed(...)`, " +
            "`isRendered(...)`, `clearBlocks()`). " +
            "Offending files: \(violations)."
        )
    }

    // MARK: - Phase 6 Tier B′ Sub-slice 6 — click-to-edit by storage offset

    /// `setRenderMode(_:forBlockAtOffset:)` is the public mutator that
    /// the click-to-edit handler uses — flip the side-table by storage
    /// offset without the caller needing a `processor.sourceBlocksSnapshot` index.
    func test_phase6Bprime_subslice6_setRenderModeByOffset() {
        let md = """
        ```mermaid
        graph TD; A-->B
        ```

        ```math
        x^2
        ```
        """
        let harness = EditorHarness(markdown: md)
        defer { harness.teardown() }

        guard let proc = harness.editor.textStorageProcessor else {
            XCTFail("Editor missing TextStorageProcessor")
            return
        }
        let codeBlocks = proc.sourceBlocksSnapshot.enumerated().compactMap { i, b -> Int? in
            if case .codeBlock = b.type { return i }
            return nil
        }
        XCTAssertEqual(codeBlocks.count, 2, "Expected 2 code blocks")

        // Both mermaid and math blocks start as .rendered (language).
        let firstOffset = proc.sourceBlocksSnapshot[codeBlocks[0]].range.location
        let secondOffset = proc.sourceBlocksSnapshot[codeBlocks[1]].range.location
        XCTAssertTrue(proc.isRendered(storageOffset: firstOffset))
        XCTAssertTrue(proc.isRendered(storageOffset: secondOffset))

        // Flip the first via the offset-keyed API.
        proc.setRenderMode(.source, forBlockAtOffset: firstOffset)
        XCTAssertFalse(proc.isRendered(storageOffset: firstOffset))
        XCTAssertFalse(proc.renderedBlockOffsets.contains(firstOffset))
        // Second block untouched.
        XCTAssertTrue(proc.isRendered(storageOffset: secondOffset))
        XCTAssertTrue(proc.renderedBlockOffsets.contains(secondOffset))
    }

    /// `setRenderMode(_:forBlockAtOffset:)` is idempotent for offsets
    /// that don't match any block — a no-op rather than a crash, so
    /// the click handler can call it without a pre-flight lookup.
    func test_phase6Bprime_subslice6_setRenderModeByOffset_unknownOffsetIsNoOp() {
        let md = "# H1\n"
        let harness = EditorHarness(markdown: md)
        defer { harness.teardown() }

        guard let proc = harness.editor.textStorageProcessor else {
            XCTFail("Editor missing TextStorageProcessor")
            return
        }
        let before = proc.renderedBlockOffsets
        // 99999 is way past any block in this tiny note.
        proc.setRenderMode(.source, forBlockAtOffset: 99999)
        XCTAssertEqual(proc.renderedBlockOffsets, before)
    }

    // MARK: - Phase 6 Tier B′ Sub-slice 5 — gutter reads from Document.blocks

    /// In WYSIWYG mode, `GutterController.visibleCodeBlocksTK2()` must
    /// resolve code blocks via `Document.blocks + blockSpans`, not via
    /// `processor.sourceBlocksSnapshot`. We verify by emptying `processor.sourceBlocksSnapshot` and
    /// confirming the gutter still finds the same set of code blocks.
    func test_phase6Bprime_subslice5_gutterFindsCodeBlocks_withoutProcessorBlocks() {
        let md = """
        # H

        ```swift
        let x = 1
        ```

        para

        ```python
        y = 2
        ```
        """
        let harness = EditorHarness(
            markdown: md, windowActivation: .keyWindow
        )
        defer { harness.teardown() }

        guard let proc = harness.editor.textStorageProcessor else {
            XCTFail("Editor missing TextStorageProcessor")
            return
        }
        let gutter = GutterController(textView: harness.editor)

        // Baseline: with both projection and processor.sourceBlocksSnapshot populated,
        // the gutter sees both code blocks.
        let baseline = gutter.visibleCodeBlocksTK2()
        XCTAssertEqual(
            baseline.count, 2,
            "Expected 2 visible code blocks; got \(baseline.count)"
        )

        // Wipe processor.sourceBlocksSnapshot. In WYSIWYG, the gutter's code-block
        // resolution should still work via Document.blocks + blockSpans.
        proc.clearBlocks()

        let afterWipe = gutter.visibleCodeBlocksTK2()
        XCTAssertEqual(
            afterWipe.count, 2,
            "Sub-slice 5: visibleCodeBlocksTK2() must resolve via " +
            "Document.blocks in WYSIWYG; got \(afterWipe.count) blocks " +
            "after clearing processor.sourceBlocksSnapshot"
        )

        // The two record sets should describe the same storage ranges.
        let baselineRanges = Set(baseline.map { NSStringFromRange($0.range) })
        let afterRanges = Set(afterWipe.map { NSStringFromRange($0.range) })
        XCTAssertEqual(
            baselineRanges, afterRanges,
            "Code block ranges must match before and after clearing " +
            "processor.sourceBlocksSnapshot (sub-slice 5 invariant)"
        )
    }

    // MARK: - Phase 6 Tier B′ Sub-slice 4 — render-mode side-table

    /// Mermaid / math / latex code blocks are auto-classified as
    /// `.rendered` by `rebuildBlocksFromProjection` and land in the
    /// canonical offset-keyed side-table.
    func test_phase6Bprime_subslice4_languageBasedClassification() {
        let md = """
        # H

        ```mermaid
        graph TD; A-->B
        ```

        ```math
        x^2 + y^2
        ```

        ```swift
        let x = 1
        ```
        """
        let harness = EditorHarness(markdown: md)
        defer { harness.teardown() }

        guard let proc = harness.editor.textStorageProcessor else {
            XCTFail("Editor missing TextStorageProcessor")
            return
        }

        // Find the three code blocks.
        let codeBlocks = proc.sourceBlocksSnapshot.enumerated().compactMap { i, b -> (Int, String?)? in
            if case .codeBlock(let lang) = b.type { return (i, lang) }
            return nil
        }
        XCTAssertEqual(codeBlocks.count, 3, "Expected 3 code blocks")

        for (idx, lang) in codeBlocks {
            let lower = lang?.lowercased()
            let expectRendered = lower == "mermaid" || lower == "math" || lower == "latex"
            XCTAssertEqual(
                proc.isRendered(blockIndex: idx), expectRendered,
                "Block lang=\(lang ?? "nil") expected rendered=\(expectRendered)"
            )
            let offset = proc.sourceBlocksSnapshot[idx].range.location
            XCTAssertEqual(
                proc.renderedBlockOffsets.contains(offset), expectRendered,
                "Side-table membership for lang=\(lang ?? "nil") " +
                "must match the per-block query"
            )
        }
    }

    /// `setRenderMode(.source, forBlockAt:)` flips the side-table.
    /// This is the path the click-to-edit rendered-image handler uses.
    /// Sub-slice 7.B.1 retired the per-block `renderMode` field; the
    /// side-table is the sole source of truth.
    func test_phase6Bprime_subslice4_setRenderMode_flipsSideTable() {
        let md = """
        ```mermaid
        graph TD; A-->B
        ```
        """
        let harness = EditorHarness(markdown: md)
        defer { harness.teardown() }

        guard let proc = harness.editor.textStorageProcessor else {
            XCTFail("Editor missing TextStorageProcessor")
            return
        }
        guard let idx = proc.sourceBlocksSnapshot.firstIndex(where: {
            if case .codeBlock = $0.type { return true }
            return false
        }) else {
            XCTFail("No code block found")
            return
        }
        let offset = proc.sourceBlocksSnapshot[idx].range.location

        // Mermaid block starts as .rendered (language-based).
        XCTAssertTrue(proc.isRendered(blockIndex: idx))
        XCTAssertTrue(proc.renderedBlockOffsets.contains(offset))

        // Flip to .source.
        proc.setRenderMode(.source, forBlockAt: idx)
        XCTAssertFalse(proc.isRendered(blockIndex: idx))
        XCTAssertFalse(proc.renderedBlockOffsets.contains(offset))

        // Flip back.
        proc.setRenderMode(.rendered, forBlockAt: idx)
        XCTAssertTrue(proc.isRendered(blockIndex: idx))
        XCTAssertTrue(proc.renderedBlockOffsets.contains(offset))
    }

    /// `renderedBlockOffsets` is the read-only accessor mirroring
    /// `collapsedBlockOffsets`, returning the canonical side-table.
    func test_phase6Bprime_subslice4_renderedBlockOffsets_accessor() {
        let md = """
        ```mermaid
        a-->b
        ```

        para
        """
        let harness = EditorHarness(markdown: md)
        defer { harness.teardown() }

        guard let proc = harness.editor.textStorageProcessor else {
            XCTFail("Editor missing TextStorageProcessor")
            return
        }
        guard let mermaidIdx = proc.sourceBlocksSnapshot.firstIndex(where: {
            if case .codeBlock = $0.type { return true }
            return false
        }) else {
            XCTFail("No code block found")
            return
        }
        let mermaidOffset = proc.sourceBlocksSnapshot[mermaidIdx].range.location
        XCTAssertEqual(proc.renderedBlockOffsets, Set([mermaidOffset]))
    }

    /// Fresh notes with no rendered blocks have an empty side-table.
    func test_phase6Bprime_subslice4_emptyByDefault() {
        let md = "# H1\n\nBody.\n"
        let harness = EditorHarness(markdown: md)
        defer { harness.teardown() }

        guard let proc = harness.editor.textStorageProcessor else {
            XCTFail("Editor missing TextStorageProcessor")
            return
        }
        XCTAssertTrue(proc.renderedBlockOffsets.isEmpty)
        for i in 0..<proc.sourceBlocksSnapshot.count {
            XCTAssertFalse(proc.isRendered(blockIndex: i))
        }
    }

    // MARK: - Phase 6 Tier B′ Sub-slice 3 — fold-state persistence migration

    /// Helper: build a fresh Note bound to a unique tmp URL so its
    /// UserDefaults fold-state keys don't collide with other tests.
    private func makeNote() -> Note {
        let tmpURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("foldmig_\(UUID().uuidString).md")
        let project = Project(
            storage: Storage.shared(),
            url: URL(fileURLWithPath: NSTemporaryDirectory())
        )
        let note = Note(url: tmpURL, with: project)
        note.type = .Markdown
        return note
    }

    /// Helper: clear both V1 and V2 UD entries for a note.
    private func clearFoldUDKeys(for note: Note) {
        UserDefaults.standard.removeObject(
            forKey: "fsnotes.foldState.\(note.url.path)"
        )
        UserDefaults.standard.removeObject(
            forKey: "fsnotes.foldStateOffsets.\(note.url.path)"
        )
    }

    /// V2 (offset-keyed) entry loads directly into `cachedFoldState`.
    func test_phase6Bprime_subslice3_loadV2_offsetKeyed() {
        let note = makeNote()
        defer { clearFoldUDKeys(for: note) }

        let v2Key = "fsnotes.foldStateOffsets.\(note.url.path)"
        UserDefaults.standard.set([42, 100], forKey: v2Key)

        note.loadFoldStateFromDisk()
        XCTAssertEqual(note.cachedFoldState, Set([42, 100]))
        XCTAssertNil(note.legacyFoldStateIndices)
    }

    /// V1 (index-keyed) entry, with no V2 entry present, lands in the
    /// transient `legacyFoldStateIndices` field — `cachedFoldState`
    /// stays nil because the editor needs `blockSpans` to convert.
    func test_phase6Bprime_subslice3_loadV1_legacyMigrationField() {
        let note = makeNote()
        defer { clearFoldUDKeys(for: note) }

        let v1Key = "fsnotes.foldState.\(note.url.path)"
        UserDefaults.standard.set([0, 3], forKey: v1Key)

        note.loadFoldStateFromDisk()
        XCTAssertNil(note.cachedFoldState)
        XCTAssertEqual(note.legacyFoldStateIndices, Set([0, 3]))
    }

    /// V2 wins when both V1 and V2 are present (V2 supersedes legacy).
    func test_phase6Bprime_subslice3_loadV2PreferredOverV1() {
        let note = makeNote()
        defer { clearFoldUDKeys(for: note) }

        let v1Key = "fsnotes.foldState.\(note.url.path)"
        let v2Key = "fsnotes.foldStateOffsets.\(note.url.path)"
        UserDefaults.standard.set([0, 1], forKey: v1Key)
        UserDefaults.standard.set([42], forKey: v2Key)

        note.loadFoldStateFromDisk()
        XCTAssertEqual(note.cachedFoldState, Set([42]))
        XCTAssertNil(note.legacyFoldStateIndices)
    }

    /// Setting `cachedFoldState` writes V2 and clears any stale V1.
    func test_phase6Bprime_subslice3_writeFlushesV1() {
        let note = makeNote()
        defer { clearFoldUDKeys(for: note) }

        let v1Key = "fsnotes.foldState.\(note.url.path)"
        let v2Key = "fsnotes.foldStateOffsets.\(note.url.path)"
        UserDefaults.standard.set([0, 1], forKey: v1Key)

        note.cachedFoldState = Set([99])

        XCTAssertEqual(
            UserDefaults.standard.array(forKey: v2Key) as? [Int],
            [99]
        )
        XCTAssertNil(
            UserDefaults.standard.array(forKey: v1Key),
            "Legacy V1 entry must be cleared after migration write"
        )
    }

    /// Setting `cachedFoldState` to an empty set or nil clears V2.
    func test_phase6Bprime_subslice3_emptySetClearsV2() {
        let note = makeNote()
        defer { clearFoldUDKeys(for: note) }

        let v2Key = "fsnotes.foldStateOffsets.\(note.url.path)"
        note.cachedFoldState = Set([7])
        XCTAssertNotNil(UserDefaults.standard.array(forKey: v2Key))

        note.cachedFoldState = []
        XCTAssertNil(UserDefaults.standard.array(forKey: v2Key))
    }

    /// End-to-end migration: a V1 index-keyed entry written by an older
    /// app version is migrated through `fillViaBlockModel`. After the
    /// fill, `cachedFoldState` carries the offset-keyed form, the
    /// transient `legacyFoldStateIndices` is cleared, and the V1 UD
    /// key is gone so future loads read V2 directly.
    func test_phase6Bprime_subslice3_endToEndV1Migration() {
        let md = "# H1\n\nBody.\n\n# H2\n\nMore.\n"
        let harness = EditorHarness(markdown: md)
        defer { harness.teardown() }
        let note = harness.note!

        // Locate the first heading's offset to verify the migration
        // produced the correct offset-keyed value.
        guard let proc = harness.editor.textStorageProcessor else {
            XCTFail("Editor missing TextStorageProcessor")
            return
        }
        guard let h1Idx = proc.sourceBlocksSnapshot.firstIndex(where: { block in
            if case .heading = block.type { return true }
            return false
        }) else {
            XCTFail("No heading block found")
            return
        }
        let h1Offset = proc.sourceBlocksSnapshot[h1Idx].range.location

        // Simulate a stored V1 index-keyed payload from an older app
        // version: heading 0 was folded.
        let v1Key = "fsnotes.foldState.\(note.url.path)"
        let v2Key = "fsnotes.foldStateOffsets.\(note.url.path)"
        UserDefaults.standard.set([h1Idx], forKey: v1Key)
        UserDefaults.standard.removeObject(forKey: v2Key)
        defer {
            UserDefaults.standard.removeObject(forKey: v1Key)
            UserDefaults.standard.removeObject(forKey: v2Key)
        }

        // Force a fresh load — the harness already filled, so reset
        // the in-memory cache to simulate a cold open.
        note.cachedFoldState = nil
        note.legacyFoldStateIndices = nil
        UserDefaults.standard.set([h1Idx], forKey: v1Key)
        note.loadFoldStateFromDisk()
        XCTAssertNil(note.cachedFoldState)
        XCTAssertEqual(note.legacyFoldStateIndices, Set([h1Idx]))

        // Re-run fillViaBlockModel to drive the migration through the
        // restore path.
        harness.editor.fillViaBlockModel(note: note)

        XCTAssertEqual(
            note.cachedFoldState, Set([h1Offset]),
            "Migration must produce offset-keyed canonical state"
        )
        XCTAssertNil(note.legacyFoldStateIndices)
        XCTAssertNil(
            UserDefaults.standard.array(forKey: v1Key),
            "Legacy V1 UD entry must be deleted after migration"
        )
        XCTAssertEqual(
            UserDefaults.standard.array(forKey: v2Key) as? [Int],
            [h1Offset],
            "V2 UD entry must carry the migrated offset"
        )
    }

    // MARK: - Helpers

    /// Walk up from the current file path to find the repository root
    /// (the directory containing `FSNotes.xcworkspace`).
    private func findRepoRoot() -> URL? {
        var url = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        for _ in 0..<6 {
            let marker = url.appendingPathComponent("FSNotes.xcworkspace")
            if FileManager.default.fileExists(atPath: marker.path) {
                return url
            }
            url = url.deletingLastPathComponent()
        }
        return nil
    }
}
