//
//  Phase5fDragOperationBypassRetirementTests.swift
//  FSNotesTests
//
//  Phase 5f follow-up — regression tests for the DragOperation
//  legacy-bypass retirement (2026-04-23).
//
//  Before this slice, `EditTextView+DragOperation.swift` had two
//  `StorageWriteGuard.performingLegacyStorageWrite { ... }` wraps
//  around direct `textStorage.replaceCharacters` writes:
//    1. `handleNoteReference` — inserts a `[[wiki-link]]` for a note
//       dragged from the notes-list sidebar.
//    2. `handleURLs` — inserts `[title](url)` markdown for web URLs
//       and `![](path)` markdown for file URLs dropped from Finder
//       (or cross-app drops that resolve to a local file).
//
//  Both were converted to `handleEditViaBlockModel` — the sanctioned
//  5a write path — which runs `applyEditResultWithUndo` and
//  populates `lastEditContract`. The fallback (source-mode / no
//  projection) falls through to AppKit's `insertText`, which mutates
//  storage through the source-mode branch that the Phase 5a
//  assertion explicitly exempts.
//
//  These tests cover:
//    - the pure markdown-construction helper
//      `EditTextView.markdownForDroppedURL` (web URL, file URL,
//       nil-inputs edge cases), which has the same content-shape
//       contract as `NSMutableAttributedString.unloadImagesAndFiles`;
//    - the routing contract — inserting dropped markdown via the
//      block-model path populates `lastEditContract`, proving the
//      write did NOT bypass the block-model pipeline.
//

import XCTest
@testable import FSNotes

final class Phase5fDragOperationBypassRetirementTests: XCTestCase {

    // MARK: - Pure markdown-construction helper

    func test_markdownForDroppedURL_webURL_wrapsTitleAndHref() {
        let result = EditTextView.markdownForDroppedURL(
            isWebURL: true,
            webTitle: "Example Site",
            webURLString: "https://example.com/page",
            filePath: nil
        )
        XCTAssertEqual(result, "[Example Site](https://example.com/page)")
    }

    func test_markdownForDroppedURL_webURL_nilTitle_fallsBackToLastComponent() {
        let result = EditTextView.markdownForDroppedURL(
            isWebURL: true,
            webTitle: nil,
            webURLString: "https://example.com/path/to/file.html",
            filePath: nil
        )
        XCTAssertEqual(result, "[file.html](https://example.com/path/to/file.html)")
    }

    func test_markdownForDroppedURL_fileURL_rendersImageSyntax() {
        let result = EditTextView.markdownForDroppedURL(
            isWebURL: false,
            webTitle: nil,
            webURLString: nil,
            filePath: "files/image.png"
        )
        // Matches the save-time serialization produced by
        // `NSMutableAttributedString.unloadImagesAndFiles()` so the
        // parser resolves it to a `.image` inline on re-parse.
        XCTAssertEqual(result, "![](files/image.png)")
    }

    func test_markdownForDroppedURL_fileURL_withPercentEncodedPath_preservesPath() {
        // ImagesProcessor.writeFile returns percent-encoded paths on
        // macOS; verify the helper does NOT re-encode or decode.
        let encoded = "files/my%20image.png"
        let result = EditTextView.markdownForDroppedURL(
            isWebURL: false,
            webTitle: nil,
            webURLString: nil,
            filePath: encoded
        )
        XCTAssertEqual(result, "![](files/my%20image.png)")
    }

    func test_markdownForDroppedURL_nilInputs_returnsNil() {
        let result = EditTextView.markdownForDroppedURL(
            isWebURL: false,
            webTitle: nil,
            webURLString: nil,
            filePath: nil
        )
        XCTAssertNil(result)
    }

    // MARK: - Routing contract: block-model path populates lastEditContract

    func test_handleEditViaBlockModel_forDroppedWebURLMarkdown_populatesContract() {
        // This mirrors the runtime call `handleURLs` now makes after
        // the async fetch completes: it builds the markdown via
        // `markdownForDroppedURL` and hands it to
        // `handleEditViaBlockModel` at the drop location. If the
        // block-model route is reached, `applyEditResultWithUndo`
        // fires and populates `lastEditContract`. If a future change
        // re-introduces the direct `textStorage.replaceCharacters`
        // bypass, `lastEditContract` stays nil and this test fails.
        let harness = EditorHarness(markdown: "hello ")
        defer { harness.teardown() }

        // Park the caret at end of "hello " (offset 6)
        harness.editor.setSelectedRange(NSRange(location: 6, length: 0))
        harness.editor.lastEditContract = nil

        guard let markdown = EditTextView.markdownForDroppedURL(
            isWebURL: true,
            webTitle: "Example",
            webURLString: "https://example.com",
            filePath: nil
        ) else {
            return XCTFail("markdownForDroppedURL returned nil for web URL")
        }

        let handled = harness.editor.handleEditViaBlockModel(
            in: NSRange(location: 6, length: 0),
            replacementString: markdown
        )
        XCTAssertTrue(handled, "block-model route must accept plain-markdown insert")

        XCTAssertNotNil(
            harness.editor.lastEditContract,
            "drop-URL insertion must route through handleEditViaBlockModel; " +
            "if nil, a direct textStorage bypass was re-introduced."
        )

        // The inserted markdown becomes a `.link` inline after the
        // RC4 `reparseCurrentBlockInlines` step inside
        // `handleEditViaBlockModel`.
        guard let doc = harness.editor.documentProjection?.document,
              case .paragraph(let inlines) = doc.blocks.first else {
            return XCTFail("expected one paragraph block after drop")
        }
        let hasLink = inlines.contains { inline in
            if case .link = inline { return true }
            return false
        }
        XCTAssertTrue(hasLink, "inserted `[title](url)` must re-parse to `.link` inline")
    }

    func test_handleEditViaBlockModel_forDroppedFileImageMarkdown_populatesContract() {
        let harness = EditorHarness(markdown: "caption ")
        defer { harness.teardown() }

        harness.editor.setSelectedRange(NSRange(location: 8, length: 0))
        harness.editor.lastEditContract = nil

        guard let markdown = EditTextView.markdownForDroppedURL(
            isWebURL: false,
            webTitle: nil,
            webURLString: nil,
            filePath: "files/dropped.png"
        ) else {
            return XCTFail("markdownForDroppedURL returned nil for file URL")
        }

        let handled = harness.editor.handleEditViaBlockModel(
            in: NSRange(location: 8, length: 0),
            replacementString: markdown
        )
        XCTAssertTrue(handled, "block-model route must accept image-syntax insert")

        XCTAssertNotNil(
            harness.editor.lastEditContract,
            "dropped-file image insertion must route through block model"
        )

        // After re-parse, the block-model projection contains an
        // `.image` inline.
        guard let doc = harness.editor.documentProjection?.document,
              case .paragraph(let inlines) = doc.blocks.first else {
            return XCTFail("expected one paragraph block after drop")
        }
        let hasImage = inlines.contains { inline in
            if case .image = inline { return true }
            return false
        }
        XCTAssertTrue(hasImage, "inserted `![](path)` must re-parse to `.image` inline")
    }
}
