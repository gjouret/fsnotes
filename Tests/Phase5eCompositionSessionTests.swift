//
//  Phase5eCompositionSessionTests.swift
//  FSNotesTests
//
//  Phase 5e — pure-function tests for `CompositionSession` and the
//  `compositionAllowsEdit` predicate that the 5a DEBUG assertion
//  consumes.
//
//  These tests do not touch AppKit — they exercise the value type
//  and the pure predicate in isolation. Live editor wiring (setMarkedText
//  override + assertion relaxation) is covered by harness tests in a
//  later commit.
//

import XCTest
@testable import FSNotes

final class Phase5eCompositionSessionTests: XCTestCase {

    // MARK: - CompositionSession.inactive

    func test_inactive_isNotActive() {
        let session = CompositionSession.inactive
        XCTAssertFalse(session.isActive)
        XCTAssertEqual(session.markedRange.length, 0)
        XCTAssertTrue(session.pendingEdits.isEmpty)
    }

    func test_inactive_hasDistantPastStart() {
        XCTAssertEqual(CompositionSession.inactive.sessionStart, .distantPast)
    }

    // MARK: - Equatable

    func test_equatable_twoInactivesMatch() {
        XCTAssertEqual(CompositionSession.inactive, .inactive)
    }

    func test_equatable_differentActiveFlagsDiffer() {
        let a = CompositionSession(
            anchorCursor: DocumentCursor(blockIndex: 0, inlineOffset: 0),
            markedRange: NSRange(location: 0, length: 2),
            isActive: true
        )
        let b = CompositionSession(
            anchorCursor: DocumentCursor(blockIndex: 0, inlineOffset: 0),
            markedRange: NSRange(location: 0, length: 2),
            isActive: false
        )
        XCTAssertNotEqual(a, b)
    }

    // MARK: - compositionAllowsEdit predicate

    func test_predicate_inactiveSession_disallowsAllEdits() {
        let session = CompositionSession.inactive
        let edit = NSRange(location: 0, length: 0)
        XCTAssertFalse(compositionAllowsEdit(editedRange: edit, session: session))

        let edit2 = NSRange(location: 5, length: 3)
        XCTAssertFalse(compositionAllowsEdit(editedRange: edit2, session: session))
    }

    func test_predicate_editInsideMarkedRange_allowed() {
        let session = CompositionSession(
            anchorCursor: DocumentCursor(blockIndex: 0, inlineOffset: 5),
            markedRange: NSRange(location: 5, length: 10),
            isActive: true
        )
        // Identical range
        XCTAssertTrue(compositionAllowsEdit(
            editedRange: NSRange(location: 5, length: 10), session: session))
        // Strictly inside
        XCTAssertTrue(compositionAllowsEdit(
            editedRange: NSRange(location: 6, length: 3), session: session))
        // Point edit at marked start
        XCTAssertTrue(compositionAllowsEdit(
            editedRange: NSRange(location: 5, length: 0), session: session))
        // Point edit at marked end (equal to end — boundary case, allowed)
        XCTAssertTrue(compositionAllowsEdit(
            editedRange: NSRange(location: 15, length: 0), session: session))
    }

    func test_predicate_editOutsideMarkedRange_disallowed() {
        let session = CompositionSession(
            anchorCursor: DocumentCursor(blockIndex: 0, inlineOffset: 5),
            markedRange: NSRange(location: 5, length: 10),
            isActive: true
        )
        // Before marked range
        XCTAssertFalse(compositionAllowsEdit(
            editedRange: NSRange(location: 0, length: 3), session: session))
        // Starts inside, extends past
        XCTAssertFalse(compositionAllowsEdit(
            editedRange: NSRange(location: 10, length: 10), session: session))
        // Wholly after
        XCTAssertFalse(compositionAllowsEdit(
            editedRange: NSRange(location: 20, length: 3), session: session))
        // Starts before marked, ends inside
        XCTAssertFalse(compositionAllowsEdit(
            editedRange: NSRange(location: 4, length: 2), session: session))
    }

    func test_predicate_zeroLengthMarkedRange_activeSession() {
        // Zero-length marked range (transitional abort state) — only
        // a zero-length edit at the same location is permitted.
        let session = CompositionSession(
            anchorCursor: DocumentCursor(blockIndex: 0, inlineOffset: 5),
            markedRange: NSRange(location: 5, length: 0),
            isActive: true
        )
        XCTAssertTrue(compositionAllowsEdit(
            editedRange: NSRange(location: 5, length: 0), session: session))
        XCTAssertFalse(compositionAllowsEdit(
            editedRange: NSRange(location: 5, length: 1), session: session))
    }

    // MARK: - DeferredEdit

    func test_deferredEdit_equatable() {
        let a = DeferredEdit(kind: .editContract(actionName: "Paste"))
        let b = DeferredEdit(kind: .editContract(actionName: "Paste"))
        let c = DeferredEdit(kind: .editContract(actionName: "Save"))
        XCTAssertEqual(a, b)
        XCTAssertNotEqual(a, c)
    }

    func test_deferredEdit_distinctKinds_notEqual() {
        let a = DeferredEdit(kind: .attachmentHydration(range: NSRange(location: 0, length: 1)))
        let b = DeferredEdit(kind: .foldResplice(range: NSRange(location: 0, length: 1)))
        XCTAssertNotEqual(a, b)
    }

    // MARK: - Mutation

    func test_mutation_pendingEditsAppend() {
        var session = CompositionSession.inactive
        XCTAssertTrue(session.pendingEdits.isEmpty)
        session.pendingEdits.append(DeferredEdit(kind: .editContract(actionName: "X")))
        XCTAssertEqual(session.pendingEdits.count, 1)
    }

    func test_mutation_markedRangeExtension() {
        var session = CompositionSession(
            anchorCursor: DocumentCursor(blockIndex: 0, inlineOffset: 0),
            markedRange: NSRange(location: 0, length: 2),
            isActive: true
        )
        session.markedRange = NSRange(location: 0, length: 5)
        XCTAssertTrue(compositionAllowsEdit(
            editedRange: NSRange(location: 0, length: 5), session: session))
        XCTAssertFalse(compositionAllowsEdit(
            editedRange: NSRange(location: 0, length: 6), session: session))
    }
}

// MARK: - Live editor composition flow (harness-driven)

final class Phase5eCompositionFlowTests: XCTestCase {

    // MARK: Session lifecycle

    func test_flow_beginComposition_transitionsToActive() {
        let harness = EditorHarness(markdown: "Hello world")
        defer { harness.teardown() }
        XCTAssertFalse(harness.compositionSession.isActive)
        harness.moveCursor(to: 5)
        harness.beginComposition(marked: "か")
        XCTAssertTrue(harness.compositionSession.isActive)
        XCTAssertEqual(harness.compositionSession.markedRange.location, 5)
    }

    func test_flow_updateComposition_extendsMarkedRange() {
        let harness = EditorHarness(markdown: "ABC")
        defer { harness.teardown() }
        harness.moveCursor(to: 3)
        harness.beginComposition(marked: "か")
        let initialLen = harness.compositionSession.markedRange.length
        harness.updateComposition(marked: "かな")
        XCTAssertTrue(harness.compositionSession.isActive)
        XCTAssertGreaterThan(harness.compositionSession.markedRange.length, initialLen)
    }

    // MARK: Commit

    func test_flow_commitComposition_foldsIntoDocument() {
        let harness = EditorHarness(markdown: "Hi")
        defer { harness.teardown() }
        harness.moveCursor(to: 2)
        harness.beginComposition(marked: "か")
        harness.updateComposition(marked: "かな")
        harness.commitComposition(final: "漢字")
        XCTAssertFalse(harness.compositionSession.isActive)
        // Document should reflect the committed text.
        XCTAssertEqual(harness.contentString, "Hi漢字")
    }

    func test_flow_commitComposition_cursorLandsAfterFinal() {
        let harness = EditorHarness(markdown: "Hi")
        defer { harness.teardown() }
        harness.moveCursor(to: 2)
        harness.beginComposition(marked: "か")
        harness.commitComposition(final: "漢")
        // Cursor should be AFTER the committed character.
        let sel = harness.selectedRange
        XCTAssertEqual(sel.length, 0)
        XCTAssertEqual(sel.location, 2 + ("漢" as NSString).length)
    }

    // MARK: Abort

    func test_flow_abortComposition_revertsStorage() {
        let harness = EditorHarness(markdown: "Hi")
        defer { harness.teardown() }
        let originalString = harness.contentString
        harness.moveCursor(to: 2)
        harness.beginComposition(marked: "か")
        harness.updateComposition(marked: "かなa")
        harness.abortComposition()
        XCTAssertFalse(harness.compositionSession.isActive)
        // Storage should match pre-marked state.
        XCTAssertEqual(harness.contentString, originalString)
    }

    // MARK: Commit as single edit

    func test_flow_commit_producesOneContract() {
        let harness = EditorHarness(markdown: "Hi")
        defer { harness.teardown() }
        harness.moveCursor(to: 2)
        // Before composition: clear any prior contract.
        let contractCountBefore = (harness.editor.lastEditContract != nil) ? 1 : 0
        harness.beginComposition(marked: "か")
        harness.updateComposition(marked: "かな")
        harness.updateComposition(marked: "かなs")
        // The marked-text updates should NOT populate lastEditContract —
        // they don't flow through applyEditResultWithUndo.
        XCTAssertEqual((harness.editor.lastEditContract != nil) ? 1 : 0, contractCountBefore)
        harness.commitComposition(final: "漢字")
        // After commit: one new contract.
        XCTAssertNotNil(harness.editor.lastEditContract)
    }

    func test_flow_abort_producesNoContract() {
        let harness = EditorHarness(markdown: "Hi")
        defer { harness.teardown() }
        harness.moveCursor(to: 2)
        harness.editor.lastEditContract = nil
        harness.beginComposition(marked: "か")
        harness.abortComposition()
        // Abort must not register a contract (Document unchanged).
        XCTAssertNil(harness.editor.lastEditContract)
    }

    // MARK: Integration: typing after commit resumes normal path

    func test_flow_typingAfterCommit_normalPath() {
        let harness = EditorHarness(markdown: "Hi")
        defer { harness.teardown() }
        harness.moveCursor(to: 2)
        harness.beginComposition(marked: "か")
        harness.commitComposition(final: "漢")
        // Ordinary typing: must go through the standard insertText path
        // (no composition active), land in Document.
        harness.editor.insertText(" after", replacementRange: harness.editor.selectedRange())
        XCTAssertEqual(harness.contentString, "Hi漢 after")
    }

    // MARK: Anchor cursor captured at session start

    func test_flow_anchorCursor_capturedAtStart() {
        let harness = EditorHarness(markdown: "Hello world")
        defer { harness.teardown() }
        harness.moveCursor(to: 6)
        harness.beginComposition(marked: "か")
        // Anchor cursor should reflect offset 6 in block 0.
        let anchor = harness.compositionSession.anchorCursor
        XCTAssertEqual(anchor.blockPath.first, 0)
        XCTAssertEqual(anchor.inlineOffset, 6)
    }
}
