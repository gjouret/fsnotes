//
//  AppBridgeImplTests.swift
//  FSNotesTests
//
//  Direct unit tests for the production AppBridge implementation.
//  Each test constructs a real `EditorHarness` (so the editor has a
//  live `documentProjection` + `Note`), wraps it in an `AppBridgeImpl`
//  whose resolver returns a `ViewController`-shaped fake, and exercises
//  the bridge methods end-to-end.
//
//  Routing matrix coverage (mirrors the Phase 3 tool routing matrix):
//    - read-only methods (currentNotePath, editorMode, cursorState,
//      hasUnsavedChanges) on a clean / dirty / closed editor;
//    - notifyFileChanged + requestWriteLock honouring the dirty bit;
//    - appendMarkdown + applyStructuredEdit on a WYSIWYG-open note;
//    - applyFormatting toggling each command via EditingOps;
//    - exportPDF writing a non-empty PDF to disk.
//
//  Why no mock ViewController: AppBridgeImpl reads the editor through
//  `viewController.editor`. We supply a tiny harness-backed shim
//  conforming to a *closure* — `init(resolveViewController:)` accepts
//  any `() -> ViewController?`, so the test can synthesise a vc whose
//  editor is the harness's real editor. Because we never assert on
//  ViewController-level UI (just the editor it owns), this avoids
//  pulling the storyboard into the test bundle.
//

import XCTest
import AppKit
@testable import FSNotes

final class AppBridgeImplTests: XCTestCase {

    // MARK: - Test helpers

    /// Build a bridge that resolves to a one-shot `ViewController`
    /// whose `editor` is the harness's editor. The vc is held by the
    /// closure; nothing else references it, so it lives only as long
    /// as the closure does — which the bridge holds for its lifetime.
    private func makeBridge(harness: EditorHarness) -> (AppBridgeImpl, ViewController) {
        // A bare ViewController is not safe to instantiate (its NIB
        // references many outlets). We create one via the storyboard
        // shape used in production but stop short of view-loading —
        // the bridge only reads `vc.editor`, which we set directly
        // via reflection-free assignment to the `editor` IBOutlet.
        let vc = ViewController()
        // `editor` is an `@IBOutlet var editor: EditTextView!` in the
        // production class; assigning it directly works in unit tests
        // even though the storyboard wiring is bypassed.
        vc.editor = harness.editor
        let bridge = AppBridgeImpl(resolveViewController: { vc })
        return (bridge, vc)
    }

    // MARK: - Read-only methods

    func testCurrentNotePathReturnsOpenNoteURL() {
        let harness = EditorHarness(markdown: "# Hello\n")
        defer { harness.teardown() }
        let (bridge, _) = makeBridge(harness: harness)
        let path = bridge.currentNotePath()
        XCTAssertNotNil(path)
        XCTAssertEqual(path, harness.note.url.standardizedFileURL.path)
    }

    func testCurrentNotePathReturnsNilWhenNoEditor() {
        let bridge = AppBridgeImpl(resolveViewController: { nil })
        XCTAssertNil(bridge.currentNotePath())
    }

    func testEditorModeIsWysiwygForBlockModelEditor() {
        let harness = EditorHarness(markdown: "Hello\n")
        defer { harness.teardown() }
        let (bridge, _) = makeBridge(harness: harness)
        let path = harness.note.url.standardizedFileURL.path
        XCTAssertEqual(bridge.editorMode(for: path), "wysiwyg")
    }

    func testEditorModeNilForUnknownPath() {
        let harness = EditorHarness(markdown: "x\n")
        defer { harness.teardown() }
        let (bridge, _) = makeBridge(harness: harness)
        XCTAssertNil(bridge.editorMode(for: "/nonexistent.md"))
    }

    func testCursorStateMatchesEditorSelection() {
        let harness = EditorHarness(markdown: "Hello\n")
        defer { harness.teardown() }
        harness.editor.setSelectedRange(NSRange(location: 2, length: 3))
        let (bridge, _) = makeBridge(harness: harness)
        let path = harness.note.url.standardizedFileURL.path
        guard let cursor = bridge.cursorState(for: path) else {
            return XCTFail("cursorState returned nil for the open note")
        }
        XCTAssertEqual(cursor.location, 2)
        XCTAssertEqual(cursor.length, 3)
    }

    func testHasUnsavedChangesReadsHasUserEdits() {
        let harness = EditorHarness(markdown: "x\n")
        defer { harness.teardown() }
        let (bridge, _) = makeBridge(harness: harness)
        let path = harness.note.url.standardizedFileURL.path
        XCTAssertFalse(bridge.hasUnsavedChanges(path: path))
        harness.editor.hasUserEdits = true
        XCTAssertTrue(bridge.hasUnsavedChanges(path: path))
    }

    // MARK: - Notification + write-lock

    func testRequestWriteLockGrantsForCleanEditor() {
        let harness = EditorHarness(markdown: "x\n")
        defer { harness.teardown() }
        let (bridge, _) = makeBridge(harness: harness)
        let path = harness.note.url.standardizedFileURL.path
        XCTAssertTrue(bridge.requestWriteLock(path: path))
    }

    func testRequestWriteLockDeniesForDirtyOpenEditor() {
        let harness = EditorHarness(markdown: "x\n")
        defer { harness.teardown() }
        harness.editor.hasUserEdits = true
        let (bridge, _) = makeBridge(harness: harness)
        let path = harness.note.url.standardizedFileURL.path
        XCTAssertFalse(bridge.requestWriteLock(path: path))
    }

    func testRequestWriteLockGrantsForUnknownPath() {
        let harness = EditorHarness(markdown: "x\n")
        defer { harness.teardown() }
        let (bridge, _) = makeBridge(harness: harness)
        XCTAssertTrue(bridge.requestWriteLock(path: "/some/closed/note.md"))
    }

    func testNotifyFileChangedNoOpForUnknownPath() {
        let harness = EditorHarness(markdown: "x\n")
        defer { harness.teardown() }
        let (bridge, _) = makeBridge(harness: harness)
        // Just must not crash; assertion is implicit.
        bridge.notifyFileChanged(path: "/some/closed/note.md")
    }

    // MARK: - appendMarkdown

    func testAppendMarkdownAddsBlockToProjection() {
        let harness = EditorHarness(markdown: "First.\n")
        defer { harness.teardown() }
        let (bridge, _) = makeBridge(harness: harness)
        let path = harness.note.url.standardizedFileURL.path

        let outcome = bridge.appendMarkdown(toPath: path, markdown: "Second.")

        guard case .applied = outcome else {
            return XCTFail("expected .applied, got \(outcome)")
        }
        // Projection now has First + (blankLine separator) + Second.
        let proj = harness.editor.documentProjection
        let serialised = MarkdownSerializer.serialize(proj?.document ?? Document(blocks: [], trailingNewline: false))
        XCTAssertTrue(serialised.contains("First."))
        XCTAssertTrue(serialised.contains("Second."))
        // Verify the appended paragraph is actually a paragraph
        // block (count varies because blank-line normalisation may
        // add a separator block).
        let paragraphCount = proj?.document.blocks.filter {
            if case .paragraph = $0 { return true }
            return false
        }.count ?? 0
        XCTAssertEqual(paragraphCount, 2)
    }

    func testAppendMarkdownToEmptyDocument() {
        let harness = EditorHarness(markdown: "")
        defer { harness.teardown() }
        let (bridge, _) = makeBridge(harness: harness)
        let path = harness.note.url.standardizedFileURL.path

        let outcome = bridge.appendMarkdown(toPath: path, markdown: "Hello")

        guard case .applied = outcome else {
            return XCTFail("expected .applied, got \(outcome)")
        }
        let proj = harness.editor.documentProjection
        XCTAssertGreaterThanOrEqual(proj?.document.blocks.count ?? 0, 1)
    }

    func testAppendMarkdownFailsForUnopenNote() {
        let harness = EditorHarness(markdown: "x\n")
        defer { harness.teardown() }
        let (bridge, _) = makeBridge(harness: harness)
        let outcome = bridge.appendMarkdown(toPath: "/wrong/path.md", markdown: "z")
        guard case .failed = outcome else {
            return XCTFail("expected .failed, got \(outcome)")
        }
    }

    // MARK: - applyStructuredEdit

    func testReplaceBlockOnWysiwygNote() {
        let md = """
            # Heading

            First.

            Second.
            """ + "\n"
        let harness = EditorHarness(markdown: md)
        defer { harness.teardown() }
        let (bridge, _) = makeBridge(harness: harness)
        let path = harness.note.url.standardizedFileURL.path

        let request = BridgeEditRequest(
            kind: .replaceBlock(index: 1, markdown: "Replaced.")
        )
        let outcome = bridge.applyStructuredEdit(toPath: path, request: request)

        guard case .applied = outcome else {
            return XCTFail("expected .applied, got \(outcome)")
        }
        let serialised = MarkdownSerializer.serialize(harness.editor.documentProjection!.document)
        XCTAssertTrue(serialised.contains("Replaced."))
        XCTAssertFalse(serialised.contains("First."))
        XCTAssertTrue(serialised.contains("Second."))
    }

    func testInsertBeforeOnWysiwygNote() {
        let md = "# Heading\n\nBody.\n"
        let harness = EditorHarness(markdown: md)
        defer { harness.teardown() }
        let (bridge, _) = makeBridge(harness: harness)
        let path = harness.note.url.standardizedFileURL.path

        let request = BridgeEditRequest(
            kind: .insertBefore(index: 0, markdown: "Preface.")
        )
        let outcome = bridge.applyStructuredEdit(toPath: path, request: request)

        guard case .applied = outcome else {
            return XCTFail("expected .applied, got \(outcome)")
        }
        let serialised = MarkdownSerializer.serialize(harness.editor.documentProjection!.document)
        XCTAssertTrue(serialised.hasPrefix("Preface."))
    }

    func testDeleteBlockOnWysiwygNote() {
        let md = "A.\n\nB.\n\nC.\n"
        let harness = EditorHarness(markdown: md)
        defer { harness.teardown() }
        let (bridge, _) = makeBridge(harness: harness)
        let path = harness.note.url.standardizedFileURL.path

        let request = BridgeEditRequest(kind: .deleteBlock(index: 1))
        let outcome = bridge.applyStructuredEdit(toPath: path, request: request)

        guard case .applied = outcome else {
            return XCTFail("expected .applied, got \(outcome)")
        }
        let serialised = MarkdownSerializer.serialize(harness.editor.documentProjection!.document)
        XCTAssertTrue(serialised.contains("A."))
        XCTAssertFalse(serialised.contains("B."))
        XCTAssertTrue(serialised.contains("C."))
    }

    func testReplaceDocumentOnWysiwygNote() {
        let harness = EditorHarness(markdown: "Old.\n")
        defer { harness.teardown() }
        let (bridge, _) = makeBridge(harness: harness)
        let path = harness.note.url.standardizedFileURL.path

        let request = BridgeEditRequest(
            kind: .replaceDocument(markdown: "# Brand New\n\nFresh.\n")
        )
        let outcome = bridge.applyStructuredEdit(toPath: path, request: request)

        guard case .applied = outcome else {
            return XCTFail("expected .applied, got \(outcome)")
        }
        let serialised = MarkdownSerializer.serialize(harness.editor.documentProjection!.document)
        XCTAssertTrue(serialised.contains("Brand New"))
        XCTAssertTrue(serialised.contains("Fresh."))
        XCTAssertFalse(serialised.contains("Old."))
    }

    func testStructuredEditOutOfBoundsIsFailure() {
        let harness = EditorHarness(markdown: "Only one block.\n")
        defer { harness.teardown() }
        let (bridge, _) = makeBridge(harness: harness)
        let path = harness.note.url.standardizedFileURL.path

        let request = BridgeEditRequest(kind: .deleteBlock(index: 99))
        let outcome = bridge.applyStructuredEdit(toPath: path, request: request)
        guard case .failed = outcome else {
            return XCTFail("expected .failed for out-of-bounds, got \(outcome)")
        }
    }

    // MARK: - applyFormatting

    func testFormattingFailsWithoutOpenNote() {
        let harness = EditorHarness(markdown: "x\n")
        defer { harness.teardown() }
        let (bridge, _) = makeBridge(harness: harness)
        let outcome = bridge.applyFormatting(toPath: "/missing.md", command: .toggleBold)
        guard case .failed = outcome else {
            return XCTFail("expected .failed for closed note, got \(outcome)")
        }
    }

    func testToggleBoldOnSelection() {
        let harness = EditorHarness(markdown: "Hello\n")
        defer { harness.teardown() }
        // Select "Hello" (5 chars).
        harness.editor.setSelectedRange(NSRange(location: 0, length: 5))
        let (bridge, _) = makeBridge(harness: harness)
        let path = harness.note.url.standardizedFileURL.path

        let outcome = bridge.applyFormatting(toPath: path, command: .toggleBold)
        guard case .applied = outcome else {
            return XCTFail("expected .applied, got \(outcome)")
        }
        let serialised = MarkdownSerializer.serialize(harness.editor.documentProjection!.document)
        XCTAssertTrue(serialised.contains("**Hello**"), "got: \(serialised)")
    }

    func testToggleHeadingPromotesParagraph() {
        let harness = EditorHarness(markdown: "Hello\n")
        defer { harness.teardown() }
        harness.editor.setSelectedRange(NSRange(location: 0, length: 0))
        let (bridge, _) = makeBridge(harness: harness)
        let path = harness.note.url.standardizedFileURL.path

        let outcome = bridge.applyFormatting(toPath: path, command: .toggleHeading(level: 2))
        guard case .applied = outcome else {
            return XCTFail("expected .applied, got \(outcome)")
        }
        let serialised = MarkdownSerializer.serialize(harness.editor.documentProjection!.document)
        XCTAssertTrue(serialised.hasPrefix("##"), "expected H2 prefix, got: \(serialised)")
    }

    func testToggleBlockquoteWrapsParagraph() {
        let harness = EditorHarness(markdown: "Hello\n")
        defer { harness.teardown() }
        harness.editor.setSelectedRange(NSRange(location: 0, length: 0))
        let (bridge, _) = makeBridge(harness: harness)
        let path = harness.note.url.standardizedFileURL.path

        let outcome = bridge.applyFormatting(toPath: path, command: .toggleBlockquote)
        guard case .applied = outcome else {
            return XCTFail("expected .applied, got \(outcome)")
        }
        let serialised = MarkdownSerializer.serialize(harness.editor.documentProjection!.document)
        XCTAssertTrue(serialised.contains(">"))
    }

    func testToggleListWrapsParagraph() {
        let harness = EditorHarness(markdown: "Hello\n")
        defer { harness.teardown() }
        harness.editor.setSelectedRange(NSRange(location: 0, length: 0))
        let (bridge, _) = makeBridge(harness: harness)
        let path = harness.note.url.standardizedFileURL.path

        let outcome = bridge.applyFormatting(toPath: path, command: .toggleUnorderedList)
        guard case .applied = outcome else {
            return XCTFail("expected .applied, got \(outcome)")
        }
        let serialised = MarkdownSerializer.serialize(harness.editor.documentProjection!.document)
        XCTAssertTrue(serialised.contains("- Hello"), "got: \(serialised)")
    }

    func testInsertHorizontalRuleAddsHRBlock() {
        let harness = EditorHarness(markdown: "Above.\n\nBelow.\n")
        defer { harness.teardown() }
        // Cursor inside the first paragraph.
        harness.editor.setSelectedRange(NSRange(location: 1, length: 0))
        let (bridge, _) = makeBridge(harness: harness)
        let path = harness.note.url.standardizedFileURL.path

        let outcome = bridge.applyFormatting(toPath: path, command: .insertHorizontalRule)
        guard case .applied = outcome else {
            return XCTFail("expected .applied, got \(outcome)")
        }
        let blocks = harness.editor.documentProjection!.document.blocks
        XCTAssertTrue(blocks.contains(where: {
            if case .horizontalRule = $0 { return true }
            return false
        }), "expected an HR block")
    }

    // MARK: - exportPDF

    func testExportPDFWritesNonEmptyFile() {
        let harness = EditorHarness(markdown: "# Heading\n\nBody text.\n")
        defer { harness.teardown() }
        let (bridge, _) = makeBridge(harness: harness)
        let path = harness.note.url.standardizedFileURL.path
        let outURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("appbridge-test-\(UUID().uuidString).pdf")
        defer { try? FileManager.default.removeItem(at: outURL) }

        let outcome = bridge.exportPDF(forPath: path, to: outURL)

        guard case .applied = outcome else {
            return XCTFail("expected .applied, got \(outcome)")
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: outURL.path))
        let attr = try? FileManager.default.attributesOfItem(atPath: outURL.path)
        let size = (attr?[.size] as? NSNumber)?.intValue ?? 0
        XCTAssertGreaterThan(size, 0, "exported PDF should not be empty")
    }

    func testExportPDFFailsForUnopenNote() {
        let harness = EditorHarness(markdown: "x\n")
        defer { harness.teardown() }
        let (bridge, _) = makeBridge(harness: harness)
        let outURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("appbridge-fail-\(UUID().uuidString).pdf")
        defer { try? FileManager.default.removeItem(at: outURL) }

        let outcome = bridge.exportPDF(forPath: "/closed.md", to: outURL)
        guard case .failed = outcome else {
            return XCTFail("expected .failed, got \(outcome)")
        }
    }

    // MARK: - IME composition guard
    //
    // Per ARCHITECTURE.md "IME Composition", `compositionSession.isActive`
    // is the single sanctioned exemption to Invariant A — `setMarkedText`
    // writes directly to `NSTextContentStorage` while a CJK / dead-key /
    // emoji-picker session is in flight. If an MCP tool dispatches into
    // the editor during that window, the structural splice races with the
    // IME's marked-range writes and corrupts the composition. Each of the
    // four mutation methods must refuse with `.failed(...)` and leave
    // storage untouched while the session is active.

    /// Activate composition on the harness editor. Mirrors the
    /// `Phase5eCompositionSessionTests` pattern of installing an
    /// `isActive: true` session via the associated-object accessor —
    /// no real `setMarkedText` call needed for guard-level coverage.
    private func activateComposition(on editor: EditTextView, markedRange: NSRange) {
        editor.compositionSession = CompositionSession(
            anchorCursor: DocumentCursor(blockIndex: 0, inlineOffset: 0),
            markedRange: markedRange,
            isActive: true
        )
    }

    func testAppendMarkdownRefusedDuringComposition() {
        let harness = EditorHarness(markdown: "Existing.\n")
        defer { harness.teardown() }
        let (bridge, _) = makeBridge(harness: harness)
        let path = harness.note.url.standardizedFileURL.path
        let snapshotBefore = MarkdownSerializer.serialize(harness.editor.documentProjection!.document)

        activateComposition(on: harness.editor, markedRange: NSRange(location: 0, length: 2))

        let outcome = bridge.appendMarkdown(toPath: path, markdown: "Appended.")
        guard case .failed(let reason) = outcome else {
            return XCTFail("expected .failed during IME composition, got \(outcome)")
        }
        XCTAssertTrue(reason.contains("IME composition"),
                      "refusal reason should mention IME composition; got: \(reason)")
        // Storage is untouched — projection still serialises to the same string.
        let snapshotAfter = MarkdownSerializer.serialize(harness.editor.documentProjection!.document)
        XCTAssertEqual(snapshotBefore, snapshotAfter,
                       "appendMarkdown must not mutate storage during composition")
    }

    func testApplyStructuredEditRefusedDuringComposition() {
        let harness = EditorHarness(markdown: "First.\n\nSecond.\n")
        defer { harness.teardown() }
        let (bridge, _) = makeBridge(harness: harness)
        let path = harness.note.url.standardizedFileURL.path
        let snapshotBefore = MarkdownSerializer.serialize(harness.editor.documentProjection!.document)

        activateComposition(on: harness.editor, markedRange: NSRange(location: 0, length: 1))

        let request = BridgeEditRequest(kind: .replaceBlock(index: 0, markdown: "Replaced."))
        let outcome = bridge.applyStructuredEdit(toPath: path, request: request)
        guard case .failed(let reason) = outcome else {
            return XCTFail("expected .failed during IME composition, got \(outcome)")
        }
        XCTAssertTrue(reason.contains("IME composition"),
                      "refusal reason should mention IME composition; got: \(reason)")
        let snapshotAfter = MarkdownSerializer.serialize(harness.editor.documentProjection!.document)
        XCTAssertEqual(snapshotBefore, snapshotAfter,
                       "applyStructuredEdit must not mutate storage during composition")
    }

    func testApplyFormattingRefusedDuringComposition() {
        let harness = EditorHarness(markdown: "Hello\n")
        defer { harness.teardown() }
        harness.editor.setSelectedRange(NSRange(location: 0, length: 5))
        let (bridge, _) = makeBridge(harness: harness)
        let path = harness.note.url.standardizedFileURL.path
        let snapshotBefore = MarkdownSerializer.serialize(harness.editor.documentProjection!.document)

        activateComposition(on: harness.editor, markedRange: NSRange(location: 0, length: 1))

        let outcome = bridge.applyFormatting(toPath: path, command: .toggleBold)
        guard case .failed(let reason) = outcome else {
            return XCTFail("expected .failed during IME composition, got \(outcome)")
        }
        XCTAssertTrue(reason.contains("IME composition"),
                      "refusal reason should mention IME composition; got: \(reason)")
        let snapshotAfter = MarkdownSerializer.serialize(harness.editor.documentProjection!.document)
        XCTAssertEqual(snapshotBefore, snapshotAfter,
                       "applyFormatting must not mutate storage during composition")
    }

    func testExportPDFRefusedDuringComposition() {
        let harness = EditorHarness(markdown: "# Title\n\nBody.\n")
        defer { harness.teardown() }
        let (bridge, _) = makeBridge(harness: harness)
        let path = harness.note.url.standardizedFileURL.path
        let outURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("appbridge-comp-\(UUID().uuidString).pdf")
        defer { try? FileManager.default.removeItem(at: outURL) }

        activateComposition(on: harness.editor, markedRange: NSRange(location: 0, length: 1))

        let outcome = bridge.exportPDF(forPath: path, to: outURL)
        guard case .failed(let reason) = outcome else {
            return XCTFail("expected .failed during IME composition, got \(outcome)")
        }
        XCTAssertTrue(reason.contains("IME composition"),
                      "refusal reason should mention IME composition; got: \(reason)")
        // PDF export should not have written the file.
        XCTAssertFalse(FileManager.default.fileExists(atPath: outURL.path),
                       "exportPDF must not write a file during composition")
    }

    // Control: with composition NOT active, the same dispatch hits the
    // normal success path. This guards against the refusal helper being
    // accidentally over-eager (e.g. firing when isActive is false).

    func testAppendMarkdownAllowedWhenCompositionInactive() {
        let harness = EditorHarness(markdown: "x\n")
        defer { harness.teardown() }
        let (bridge, _) = makeBridge(harness: harness)
        let path = harness.note.url.standardizedFileURL.path

        XCTAssertFalse(harness.editor.compositionSession.isActive)

        let outcome = bridge.appendMarkdown(toPath: path, markdown: "added")
        guard case .applied = outcome else {
            return XCTFail("expected .applied with no composition, got \(outcome)")
        }
    }

    func testApplyStructuredEditAllowedWhenCompositionInactive() {
        let harness = EditorHarness(markdown: "old\n")
        defer { harness.teardown() }
        let (bridge, _) = makeBridge(harness: harness)
        let path = harness.note.url.standardizedFileURL.path

        let request = BridgeEditRequest(kind: .replaceBlock(index: 0, markdown: "new."))
        let outcome = bridge.applyStructuredEdit(toPath: path, request: request)
        guard case .applied = outcome else {
            return XCTFail("expected .applied with no composition, got \(outcome)")
        }
    }

    func testApplyFormattingAllowedWhenCompositionInactive() {
        let harness = EditorHarness(markdown: "Hello\n")
        defer { harness.teardown() }
        harness.editor.setSelectedRange(NSRange(location: 0, length: 5))
        let (bridge, _) = makeBridge(harness: harness)
        let path = harness.note.url.standardizedFileURL.path

        let outcome = bridge.applyFormatting(toPath: path, command: .toggleBold)
        guard case .applied = outcome else {
            return XCTFail("expected .applied with no composition, got \(outcome)")
        }
    }

    func testExportPDFAllowedWhenCompositionInactive() {
        let harness = EditorHarness(markdown: "Body.\n")
        defer { harness.teardown() }
        let (bridge, _) = makeBridge(harness: harness)
        let path = harness.note.url.standardizedFileURL.path
        let outURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("appbridge-noncomp-\(UUID().uuidString).pdf")
        defer { try? FileManager.default.removeItem(at: outURL) }

        let outcome = bridge.exportPDF(forPath: path, to: outURL)
        guard case .applied = outcome else {
            return XCTFail("expected .applied with no composition, got \(outcome)")
        }
    }
}
