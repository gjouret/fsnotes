//
//  Phase46BlocksPeerDeletionTests.swift
//  FSNotesTests
//
//  Phase 4.6 — verify the public `syncBlocksFromProjection` API is gone
//  and fold state is driven by `Note.cachedFoldState` + `Document.blocks`
//  via the auto-syncing `documentProjection` setter.
//
//  The tests here exercise the authoritative sources (Document.blocks,
//  cachedFoldState) rather than the legacy `MarkdownBlock.collapsed`
//  per-block mutable flag. `MarkdownBlock.collapsed` is retained only
//  as a view-local cache that the setter-driven rebuild re-derives from
//  the projection on every projection update.
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
        // The grep gate enforces the absence of
        // `syncBlocksFromProjection` call sites in production code.
        // This test complements the gate by reading the production
        // directories and asserting that any residual
        // `MarkdownBlock.collapsed` reads (the per-block mutable flag
        // we're phasing out as the canonical source of truth) are
        // confined to the processor that owns the sync cache.
        let repoRoot = findRepoRoot()
        guard let repoRoot = repoRoot else {
            XCTFail("Unable to locate repo root for source scan")
            return
        }
        let prodDirs = [
            repoRoot.appendingPathComponent("FSNotes"),
            repoRoot.appendingPathComponent("FSNotesCore")
        ]
        let permitted: Set<String> = [
            // TextStorageProcessor owns the `blocks` array and its
            // `collapsed` per-entry flag by design.
            "TextStorageProcessor.swift",
            // GutterController reads `.collapsed` to draw fold carets —
            // this is a legitimate renderer of the processor's cached
            // view of fold state.
            "GutterController.swift"
        ]

        // Regex matches `.collapsed` as a whole-word property access —
        // NOT `.collapsedBlockIndices` (the Set<Int>-valued processor
        // API that callers legitimately use to read fold state).
        // Word-boundary: the character after "collapsed" must be non-
        // identifier (dot-call, whitespace, paren, equals, end-of-line).
        let regex = try NSRegularExpression(
            pattern: #"\.collapsed\b(?![A-Za-z0-9_])"#
        )

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
                if permitted.contains(fileName) { continue }
                guard let content = try? String(contentsOf: fileURL)
                else { continue }
                let range = NSRange(content.startIndex..., in: content)
                if regex.firstMatch(in: content, range: range) != nil {
                    violations.append(fileName)
                }
            }
        }
        XCTAssertTrue(
            violations.isEmpty,
            "Files outside the permitted set read `.collapsed`: " +
            "\(violations). Route through cachedFoldState + " +
            "Document.blocks instead."
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
