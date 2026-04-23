//
//  CodeBlockEditToggleOverlayTests.swift
//  FSNotesTests
//
//  Phase 8 — Code-Block Edit Toggle — Slice 3 coverage.
//
//  Tests:
//    1. test_slice3_overlay_enumeratesCodeBlockFragments
//       Two code blocks separated by a paragraph → overlay finds two
//       entries, one per code block (fragments from the same logical
//       code block dedupe to one).
//    2. test_slice3_overlay_skipsFoldedBlocks
//       Code block inside a folded heading (storage range carries
//       `.foldedContent`) → overlay returns 0.
//    3. test_slice3_overlay_positionsButtonTopRight
//       Single code block → button's right edge lies at container
//       width minus padding; button y aligns with the first fragment.
//    4. test_slice3_click_togglesEditingBlocksAndReRenders
//       Mermaid block (rendered as attachment by default) → invoking
//       the overlay's click handler adds the block's ref to
//       `editingCodeBlocks`, storage at that block's range no longer
//       contains `\u{FFFC}` and contains "```mermaid\n".
//    5. test_slice3_click_again_togglesBack
//       Second click removes the ref; storage reverts to a single
//       attachment.
//

import XCTest
import AppKit
@testable import FSNotes

final class CodeBlockEditToggleOverlayTests: XCTestCase {

    /// Object-Replacement-Character (`U+FFFC`).
    private static let objectReplacement = "\u{FFFC}"

    // MARK: - Helper

    /// Force layout so `enumerateTextLayoutFragments(.ensuresLayout)`
    /// has fragments to iterate. Mirrors the GutterOverlayTests pattern.
    private func pumpLayout(_ editor: EditTextView) {
        if let tlm = editor.textLayoutManager {
            tlm.ensureLayout(for: tlm.documentRange)
        }
    }

    // MARK: - 1. Enumerate

    /// Two code blocks separated by a paragraph: the overlay must
    /// report two visible records, one per code block. Multi-paragraph
    /// code blocks dedupe to a single record at the first fragment.
    func test_slice3_overlay_enumeratesCodeBlockFragments() {
        let markdown = """
        ```swift
        let x = 1
        let y = 2
        ```

        middle paragraph

        ```python
        print("hi")
        ```
        """
        let harness = EditorHarness(markdown: markdown)
        defer { harness.teardown() }

        if let proj = harness.editor.documentProjection {
            harness.editor.textStorageProcessor?
                .syncBlocksFromProjection(proj)
        }
        pumpLayout(harness.editor)

        let overlay = CodeBlockEditToggleOverlay(editor: harness.editor)
        let visible = overlay.visibleFragments()

        XCTAssertEqual(
            visible.count, 2,
            "Two code blocks with a paragraph between them must " +
            "produce exactly 2 overlay entries — got \(visible.count)"
        )
    }

    // MARK: - 2. Skip folded

    /// A code block inside a folded heading must not produce a toggle.
    /// The fold attribute is set directly on the code block's storage
    /// range to simulate the folded state.
    func test_slice3_overlay_skipsFoldedBlocks() {
        let markdown = """
        # Header

        ```swift
        let x = 1
        ```
        """
        let harness = EditorHarness(markdown: markdown)
        defer { harness.teardown() }
        let editor = harness.editor

        if let proj = editor.documentProjection {
            editor.textStorageProcessor?.syncBlocksFromProjection(proj)
        }
        pumpLayout(editor)

        // Mark the code block's storage range as folded. Under the
        // live app this is set by `TextStorageProcessor.toggleFold`;
        // for this test we apply the attribute directly at the block's
        // first character so the overlay's skip check fires.
        guard let proj = editor.documentProjection,
              let storage = editor.textStorage
        else {
            XCTFail("expected projection + storage")
            return
        }
        // The code block is the second block (index 1 — heading, then
        // codeBlock — though blank lines may intervene).
        var codeBlockSpan: NSRange? = nil
        for (i, block) in proj.document.blocks.enumerated() {
            if case .codeBlock = block {
                codeBlockSpan = proj.blockSpans[i]
                break
            }
        }
        guard let span = codeBlockSpan, span.length > 0 else {
            XCTFail("expected a code block span in the projection")
            return
        }
        storage.beginEditing()
        storage.addAttribute(.foldedContent, value: true, range: span)
        storage.endEditing()

        let overlay = CodeBlockEditToggleOverlay(editor: editor)
        let visible = overlay.visibleFragments()

        XCTAssertEqual(
            visible.count, 0,
            "Folded code block must NOT produce a toggle — got " +
            "\(visible.count) entries"
        )
    }

    // MARK: - 3. Position

    /// Single code block: the overlay positions the button such that
    /// its right edge is at the container's right boundary (minus the
    /// configured right inset), and the button's y origin aligns with
    /// the first fragment's top (offset by the top inset).
    func test_slice3_overlay_positionsButtonTopRight() {
        let markdown = """
        ```swift
        let x = 1
        ```
        """
        let harness = EditorHarness(markdown: markdown)
        defer { harness.teardown() }
        let editor = harness.editor

        if let proj = editor.documentProjection {
            editor.textStorageProcessor?.syncBlocksFromProjection(proj)
        }
        pumpLayout(editor)

        let overlay = CodeBlockEditToggleOverlay(editor: editor)
        // Trigger a full reposition to spawn the pooled view into the
        // editor hierarchy.
        overlay.reposition()

        let visible = overlay.visibleFragments()
        XCTAssertEqual(
            visible.count, 1,
            "Single code block must produce exactly one overlay entry"
        )
        guard let record = visible.first else { return }

        // Find the spawned button among the editor's subviews.
        let buttons = editor.subviews.compactMap {
            $0 as? CodeBlockEditToggleView
        }
        XCTAssertEqual(
            buttons.count, 1,
            "reposition() must spawn exactly one toggle view into the " +
            "editor's subviews — got \(buttons.count)"
        )
        guard let button = buttons.first else { return }

        let containerWidth = editor.textContainer?.size.width
            ?? editor.frame.width
        let containerOriginX = editor.textContainerOrigin.x
        let expectedRightX = containerOriginX + containerWidth
            - CodeBlockEditToggleOverlay.rightInset
        let actualRightX = button.frame.origin.x + button.frame.size.width
        XCTAssertEqual(
            actualRightX, expectedRightX, accuracy: 0.5,
            "button's right edge must sit at container-right minus " +
            "rightInset — expected \(expectedRightX), got \(actualRightX)"
        )

        let expectedY = record.originY + CodeBlockEditToggleOverlay.topInset
        XCTAssertEqual(
            button.frame.origin.y, expectedY, accuracy: 0.5,
            "button's y-origin must equal first fragment's originY + " +
            "topInset — expected \(expectedY), got \(button.frame.origin.y)"
        )
    }

    // MARK: - 4. Click toggles + re-renders

    /// Mermaid block: default render emits an attachment (U+FFFC).
    /// Invoking the overlay's click path for that block's ref must
    /// insert the ref into `editor.editingCodeBlocks` AND the storage
    /// at the block's range must lose the attachment and contain the
    /// raw fenced source (```mermaid\n).
    func test_slice3_click_togglesEditingBlocksAndReRenders() {
        let markdown = """
        ```mermaid
        graph LR
          A-->B
        ```
        """
        let harness = EditorHarness(markdown: markdown)
        defer { harness.teardown() }
        let editor = harness.editor

        if let proj = editor.documentProjection {
            editor.textStorageProcessor?.syncBlocksFromProjection(proj)
        }
        pumpLayout(editor)

        // Locate the mermaid block's ref (content-hash keyed).
        guard let proj = editor.documentProjection,
              let block = proj.document.blocks.first(where: {
                  if case .codeBlock(let lang, _, _) = $0 {
                      return lang?.lowercased() == "mermaid"
                  }
                  return false
              })
        else {
            XCTFail("expected a mermaid code block")
            return
        }
        let ref = BlockRef(block)

        // Sanity: default (non-editing) storage carries exactly one
        // U+FFFC attachment character.
        let preClickStr = editor.textStorage?.string ?? ""
        let preAttachmentCount = preClickStr
            .components(separatedBy: Self.objectReplacement).count - 1
        XCTAssertEqual(
            preAttachmentCount, 1,
            "pre-click storage must contain one U+FFFC attachment " +
            "(mermaid block rendered as bitmap); got \(preAttachmentCount)"
        )

        // Invoke the click path.
        let overlay = CodeBlockEditToggleOverlay(editor: editor)
        overlay.applyToggle(ref: ref, editor: editor)

        // The editor's editingCodeBlocks set contains the ref.
        XCTAssertTrue(
            editor.editingCodeBlocks.contains(ref),
            "after click, editingCodeBlocks must contain the mermaid " +
            "block's ref"
        )

        // Storage at the block's range now shows the raw fenced source.
        let postClickStr = editor.textStorage?.string ?? ""
        XCTAssertFalse(
            postClickStr.contains(Self.objectReplacement),
            "post-click storage must not contain any U+FFFC attachment — " +
            "got \(postClickStr.debugDescription)"
        )
        XCTAssertTrue(
            postClickStr.contains("\u{0060}\u{0060}\u{0060}mermaid\n"),
            "post-click storage must contain raw ```mermaid\\n opener — " +
            "got \(postClickStr.debugDescription)"
        )
        XCTAssertTrue(
            postClickStr.contains("graph LR"),
            "post-click storage must contain the raw mermaid source — " +
            "got \(postClickStr.debugDescription)"
        )
    }

    // MARK: - 5. Click-again toggles back

    /// Second click restores the original rendered form: storage no
    /// longer contains the raw fences and again holds exactly one
    /// attachment character. The ref is removed from the set.
    func test_slice3_click_again_togglesBack() {
        let markdown = """
        ```mermaid
        graph LR
          A-->B
        ```
        """
        let harness = EditorHarness(markdown: markdown)
        defer { harness.teardown() }
        let editor = harness.editor

        if let proj = editor.documentProjection {
            editor.textStorageProcessor?.syncBlocksFromProjection(proj)
        }
        pumpLayout(editor)

        guard let proj = editor.documentProjection,
              let block = proj.document.blocks.first(where: {
                  if case .codeBlock(let lang, _, _) = $0 {
                      return lang?.lowercased() == "mermaid"
                  }
                  return false
              })
        else {
            XCTFail("expected a mermaid code block")
            return
        }
        let ref = BlockRef(block)
        let overlay = CodeBlockEditToggleOverlay(editor: editor)

        // First click — enters editing form.
        overlay.applyToggle(ref: ref, editor: editor)
        XCTAssertTrue(
            editor.editingCodeBlocks.contains(ref),
            "first click must toggle the ref INTO the set"
        )

        // Second click — exits editing form.
        overlay.applyToggle(ref: ref, editor: editor)
        XCTAssertFalse(
            editor.editingCodeBlocks.contains(ref),
            "second click must toggle the ref OUT of the set"
        )

        // Storage must match the original rendered form: no fences, one
        // U+FFFC attachment character.
        let finalStr = editor.textStorage?.string ?? ""
        XCTAssertFalse(
            finalStr.contains("\u{0060}\u{0060}\u{0060}mermaid"),
            "after toggle-back, storage must not contain raw ```mermaid " +
            "fence — got \(finalStr.debugDescription)"
        )
        let finalAttachmentCount = finalStr
            .components(separatedBy: Self.objectReplacement).count - 1
        XCTAssertEqual(
            finalAttachmentCount, 1,
            "after toggle-back, storage must contain exactly one U+FFFC " +
            "attachment — got \(finalAttachmentCount)"
        )
    }
}
