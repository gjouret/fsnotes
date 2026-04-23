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

        // Phase 4.6: setter auto-syncs `processor.blocks`.
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

        // Phase 4.6: setter auto-syncs `processor.blocks`.
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

        // Phase 4.6: setter auto-syncs `processor.blocks`.
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

        // Phase 4.6: setter auto-syncs `processor.blocks`.
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

        // Phase 4.6: setter auto-syncs `processor.blocks`.
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

    // MARK: - Slice 4: cursor-leaves auto-collapse

    /// Locate the first code block in the editor's projection and
    /// return `(block, ref, span)`. Helper for the Slice 4 tests.
    private func firstCodeBlock(
        in editor: EditTextView
    ) -> (block: Block, ref: BlockRef, span: NSRange)? {
        guard let proj = editor.documentProjection else { return nil }
        for (i, block) in proj.document.blocks.enumerated() {
            if case .codeBlock = block {
                return (block, BlockRef(block), proj.blockSpans[i])
            }
        }
        return nil
    }

    /// Seed a document with 2 paragraphs + 1 code block. Put the
    /// code block's ref into `editor.editingCodeBlocks` DIRECTLY
    /// (bypassing the UI click). Then move the cursor outside the
    /// code block's span. Slice 4's auto-collapse must remove the
    /// ref — the set ends empty.
    func test_slice4_cursorLeavesBlock_autoCollapses() {
        let markdown = """
        first paragraph

        ```swift
        let x = 1
        ```

        trailing paragraph
        """
        let harness = EditorHarness(markdown: markdown)
        defer { harness.teardown() }
        let editor = harness.editor
        pumpLayout(editor)

        guard let (_, ref, codeSpan) = firstCodeBlock(in: editor) else {
            XCTFail("expected a code block in the projection")
            return
        }

        // Seed the editing set directly — not via click. The applier
        // re-renders with the fenced editing form.
        let overlay = CodeBlockEditToggleOverlay(editor: editor)
        overlay.applyToggle(ref: ref, editor: editor)
        XCTAssertTrue(
            editor.editingCodeBlocks.contains(ref),
            "precondition: ref must be in editingCodeBlocks after seed"
        )

        // Move the cursor to the very start of the document (the
        // first paragraph, well outside the code block).
        editor.setSelectedRange(NSRange(location: 0, length: 0))
        XCTAssertFalse(
            NSLocationInRange(0, codeSpan),
            "precondition: cursor location 0 must be outside the " +
            "code block's span \(codeSpan)"
        )

        // Fire Slice 4.
        editor.collapseEditingCodeBlocksOutsideSelection()

        XCTAssertTrue(
            editor.editingCodeBlocks.isEmpty,
            "after collapse, editingCodeBlocks must be empty — got " +
            "\(editor.editingCodeBlocks.count) refs"
        )
    }

    /// Put the code block's ref into the editing set, then move the
    /// cursor to a position INSIDE the block. The ref must remain.
    func test_slice4_cursorInsideBlock_staysOpen() {
        let markdown = """
        intro

        ```swift
        let x = 1
        let y = 2
        ```

        outro
        """
        let harness = EditorHarness(markdown: markdown)
        defer { harness.teardown() }
        let editor = harness.editor
        pumpLayout(editor)

        guard let (_, ref, _) = firstCodeBlock(in: editor) else {
            XCTFail("expected a code block in the projection")
            return
        }

        // Seed via applyToggle so storage is in fenced editing form
        // (what the selection-observer will see under live use).
        let overlay = CodeBlockEditToggleOverlay(editor: editor)
        overlay.applyToggle(ref: ref, editor: editor)
        XCTAssertTrue(
            editor.editingCodeBlocks.contains(ref),
            "precondition: ref must be in set after seed"
        )

        // After the toggle, re-read the code block's span from the
        // fresh projection (the block's span shifts when toggling
        // bumps its rendered byte length).
        guard let postSpanTuple = firstCodeBlock(in: editor) else {
            XCTFail("expected a code block post-toggle")
            return
        }
        let codeSpan = postSpanTuple.span
        // Place the cursor at the middle of the block — definitely
        // inside its span.
        let mid = codeSpan.location + max(codeSpan.length / 2, 1)
        editor.setSelectedRange(NSRange(location: mid, length: 0))
        XCTAssertTrue(
            NSLocationInRange(mid, codeSpan) || mid == codeSpan.location,
            "precondition: selection \(mid) must lie within codeSpan " +
            "\(codeSpan)"
        )

        editor.collapseEditingCodeBlocksOutsideSelection()

        XCTAssertTrue(
            editor.editingCodeBlocks.contains(ref),
            "cursor inside the block must KEEP the ref in the set — " +
            "got \(editor.editingCodeBlocks.count) refs (expected 1 " +
            "containing the seeded ref)"
        )
    }

    /// Two code blocks both in edit mode. Cursor moved outside both.
    /// A single `collapseEditingCodeBlocksOutsideSelection` call
    /// removes BOTH refs. We count applier invocations by spying on
    /// storage-mutation events: the `NSTextStorage` posts
    /// `didProcessEditingNotification` once per `applyDocumentEdit`
    /// call (because the applier wraps its splice in a single
    /// `performEditingTransaction` on the content storage). A batch
    /// Slice-4 call therefore emits exactly one notification even
    /// though it removes N refs.
    func test_slice4_multipleBlocks_allCollapse() {
        let markdown = """
        ```swift
        let a = 1
        ```

        middle

        ```python
        b = 2
        ```
        """
        let harness = EditorHarness(markdown: markdown)
        defer { harness.teardown() }
        let editor = harness.editor
        pumpLayout(editor)

        guard let proj = editor.documentProjection else {
            XCTFail("expected projection")
            return
        }
        // Collect both code blocks' refs.
        var refs: [BlockRef] = []
        for block in proj.document.blocks {
            if case .codeBlock = block {
                refs.append(BlockRef(block))
            }
        }
        XCTAssertEqual(
            refs.count, 2,
            "precondition: document must have 2 code blocks — got " +
            "\(refs.count)"
        )

        // Seed BOTH directly (bypass applyToggle so we don't count
        // the applier calls from the seed itself toward the collapse-
        // time spy window).
        editor.editingCodeBlocks = Set(refs)

        // Locate the "middle" paragraph's span (the non-code block
        // sandwiched between the two code blocks). Place the cursor
        // inside that paragraph — definitely outside both code blocks.
        var middleSpan: NSRange? = nil
        for (i, block) in proj.document.blocks.enumerated() {
            if case .paragraph = block {
                middleSpan = proj.blockSpans[i]
                break
            }
        }
        guard let mid = middleSpan else {
            XCTFail("precondition: expected a paragraph block")
            return
        }
        editor.setSelectedRange(
            NSRange(location: mid.location + max(mid.length / 2, 1), length: 0)
        )

        // Spy: count didProcessEditingNotification posts during the
        // collapse. One applyDocumentEdit call ≈ one storage
        // transaction ≈ one notification.
        let spyExpect =
            expectation(description: "storage-edit notification")
        spyExpect.expectedFulfillmentCount = 1
        spyExpect.assertForOverFulfill = true
        var notificationCount = 0
        let token = NotificationCenter.default.addObserver(
            forName: NSTextStorage.didProcessEditingNotification,
            object: editor.textStorage, queue: .main
        ) { _ in
            notificationCount += 1
            spyExpect.fulfill()
        }
        defer { NotificationCenter.default.removeObserver(token) }

        editor.collapseEditingCodeBlocksOutsideSelection()

        // Give the spy a brief window to collect.
        wait(for: [spyExpect], timeout: 1.0)

        XCTAssertTrue(
            editor.editingCodeBlocks.isEmpty,
            "both refs must be dropped in ONE batch — got " +
            "\(editor.editingCodeBlocks.count) remaining"
        )
        XCTAssertEqual(
            notificationCount, 1,
            "one batch applyDocumentEdit → exactly one storage " +
            "editing notification, not N=\(refs.count) — got " +
            "\(notificationCount)"
        )
    }

    /// Fire `collapseEditingCodeBlocksOutsideSelection` twice in a
    /// row with the cursor stably INSIDE the block: the second call
    /// must be a pure no-op (no applier invocation, no storage
    /// mutation). Guards the "re-render fires observer → applier →
    /// re-render" infinite loop.
    func test_slice4_noSpuriousReapply_onStableSelection() {
        let markdown = """
        ```swift
        let x = 1
        ```
        """
        let harness = EditorHarness(markdown: markdown)
        defer { harness.teardown() }
        let editor = harness.editor
        pumpLayout(editor)

        guard let (_, ref, _) = firstCodeBlock(in: editor) else {
            XCTFail("expected a code block")
            return
        }

        let overlay = CodeBlockEditToggleOverlay(editor: editor)
        overlay.applyToggle(ref: ref, editor: editor)

        // Re-read the post-toggle span.
        guard let (_, _, codeSpan) = firstCodeBlock(in: editor) else {
            XCTFail("expected a code block post-toggle")
            return
        }
        let mid = codeSpan.location + max(codeSpan.length / 2, 1)
        editor.setSelectedRange(NSRange(location: mid, length: 0))

        // First call: cursor is inside, set unchanged → guard-2 no-op.
        // Second call: same state → same guard-2 no-op.
        var notificationCount = 0
        let token = NotificationCenter.default.addObserver(
            forName: NSTextStorage.didProcessEditingNotification,
            object: editor.textStorage, queue: nil
        ) { _ in notificationCount += 1 }
        defer { NotificationCenter.default.removeObserver(token) }

        editor.collapseEditingCodeBlocksOutsideSelection()
        editor.collapseEditingCodeBlocksOutsideSelection()

        XCTAssertEqual(
            notificationCount, 0,
            "stable selection inside the block must not fire an " +
            "applier call on either invocation — got " +
            "\(notificationCount) storage notifications"
        )
        XCTAssertTrue(
            editor.editingCodeBlocks.contains(ref),
            "ref must remain in the set across two stable-selection " +
            "invocations — got \(editor.editingCodeBlocks.count) refs"
        )
    }

    /// After Slice 3's click path toggles a block OUT of the set,
    /// Slice 4's observer should run and see an empty set → exit via
    /// guard 1 (no applier call). This verifies the two paths don't
    /// fight — the click's own applier call is not duplicated by the
    /// observer.
    func test_slice4_cursorToggleOffViaButton_doesNotRefire_observerApply() {
        let markdown = """
        ```swift
        let x = 1
        ```
        """
        let harness = EditorHarness(markdown: markdown)
        defer { harness.teardown() }
        let editor = harness.editor
        pumpLayout(editor)

        guard let (_, ref, _) = firstCodeBlock(in: editor) else {
            XCTFail("expected a code block")
            return
        }

        let overlay = CodeBlockEditToggleOverlay(editor: editor)
        // Click IN: ref enters set, applier fires once.
        overlay.applyToggle(ref: ref, editor: editor)
        XCTAssertTrue(editor.editingCodeBlocks.contains(ref))

        // Click OUT: ref leaves set, applier fires once (via the
        // Slice 3 click path). After this, `editingCodeBlocks` is
        // empty — the observer should early-return via guard 1.
        overlay.applyToggle(ref: ref, editor: editor)
        XCTAssertFalse(editor.editingCodeBlocks.contains(ref))
        XCTAssertTrue(editor.editingCodeBlocks.isEmpty)

        // Spy window: count applier-driven storage mutations from
        // Slice 4 alone.
        var notificationCount = 0
        let token = NotificationCenter.default.addObserver(
            forName: NSTextStorage.didProcessEditingNotification,
            object: editor.textStorage, queue: nil
        ) { _ in notificationCount += 1 }
        defer { NotificationCenter.default.removeObserver(token) }

        // Fire the observer. Set is empty → guard 1 → no-op.
        editor.collapseEditingCodeBlocksOutsideSelection()

        XCTAssertEqual(
            notificationCount, 0,
            "observer must no-op when editingCodeBlocks is empty — " +
            "Slice 3's click path already handled the exit. Got " +
            "\(notificationCount) spurious storage notifications"
        )
    }
}
