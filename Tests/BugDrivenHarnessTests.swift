//
//  BugDrivenHarnessTests.swift
//  FSNotesTests
//
//  Phase 0 bug-driven tests. Each test captures a known live bug in
//  user-visible terms using the EditorHarness. Per REFACTOR_PLAN.md:
//
//      Every known live bug (#22, #35, #36, #39, #40, #41, #47, #60)
//      becomes a harness test. Must FAIL on current code — proves the
//      harness detects real bugs before any fix lands. Each bug-fix
//      in later phases flips its test from FAIL to PASS.
//
//  For bugs whose user-visible symptom + repro is documented in
//  REFACTOR_PLAN.md (#41, #60) we write the failing assertion directly.
//  For bugs whose symptom is not fully retrievable in the text (#22,
//  #35, #36, #39, #40, #47) we leave an XCTSkip with the reason so
//  the skeleton is in place and the skip message tells the reader
//  exactly what additional info is needed from the user.
//

import XCTest
import AppKit
@testable import FSNotes

final class BugDrivenHarnessTests: XCTestCase {

    // MARK: - Bug #60 — Find across table cells

    /// REFACTOR_PLAN.md: "Bug #60 (Find across tables) resolved by
    /// construction — table cell text is now real content in
    /// NSTextContentStorage. NSTextFinder walks it natively."
    ///
    /// Today the table widget renders cell text inside an
    /// NSTextAttachment (`InlineTableView`). Cell text is therefore
    /// NOT a character run in the backing NSTextStorage — instead the
    /// storage contains U+FFFC at the table location. Consequently
    /// `NSTextFinderClient.string` (which NSTextView forwards from
    /// `textStorage.string`) does not contain the searchable cell
    /// content, and Cmd+F cannot find text that lives inside a table.
    ///
    /// This test asserts the user-visible expectation: searchable text
    /// for an editor whose content is a markdown table MUST contain
    /// the cell strings. On current code this FAILS by construction —
    /// the storage contains U+FFFC where the table lives. After the
    /// Phase 2 TextKit 2 + T2 table migration the test flips to PASS.
    func test_bug60_findAcrossTableCells() throws {
        let markdown = """
        | Name | Note |
        | ---  | ---  |
        | Alice | findmeinside |
        | Bob   | plain |
        """
        let harness = EditorHarness(markdown: markdown)
        defer { harness.teardown() }

        Invariants.assertAll(harness)

        // The NSTextFinderClient protocol exposes an optional
        // `string` property; NSTextView's default implementation
        // returns the current textStorage string. That is what
        // `NSTextFinder` searches. We check it directly via the
        // storage because the default textFinder property may be nil
        // in an offscreen borderless window.
        let searchable = harness.editor.textStorage?.string ?? ""

        XCTAssertTrue(
            searchable.contains("findmeinside"),
            "Bug #60: table cell text must appear in the searchable string " +
            "so Cmd+F can find it. Today cell text is rendered inside an " +
            "NSTextAttachment and is not part of textStorage; this test " +
            "is expected to FAIL until the TextKit 2 + T2 table migration " +
            "(Phase 2)."
        )
    }

    // MARK: - Bug #41 — Live cursor matches declared cursor

    /// REFACTOR_PLAN.md Phase 4 exit criterion:
    ///   "Bug #41 passes in harness (live cursor matches declared cursor
    ///    — now that cursor is NSTextLocation-based and element-addressed)"
    ///
    /// User-visible symptom (inferred from the phase-4 description
    /// which ties this to cursor positioning after an edit): after
    /// certain scripted inputs, the editor's selectedRange does not
    /// match the character position the user would expect given the
    /// preceding input sequence.
    ///
    /// The canonical repro we can exercise without manual interaction:
    ///   - Seed "line one\nline two"
    ///   - Place the cursor at location 4 (inside "line")
    ///   - Type "X"
    ///   - Cursor should now be at location 5 (advance by one code unit)
    ///
    /// This test asserts the invariant. If it fails today it surfaces
    /// a cursor-drift bug; if it passes today it gives us a baseline
    /// we can tighten in Phase 4 with a corpus-wide sweep of
    /// post-operation cursor positions.
    func test_harness_canInstantiate() throws {
        // Diagnostic: isolate whether harness init itself crashes.
        let harness = EditorHarness(markdown: "")
        defer { harness.teardown() }
        XCTAssertEqual(harness.contentString, "")
    }

    func test_harness_canSeedMarkdown() throws {
        // Diagnostic: isolate whether seeded init crashes.
        let harness = EditorHarness(markdown: "hello")
        defer { harness.teardown() }
        XCTAssertEqual(harness.contentString, "hello")
    }

    func test_bug41_cursorPositionAfterInsert() throws {
        let harness = EditorHarness(markdown: "line one\nline two")
        defer { harness.teardown() }

        Invariants.assertAll(harness)

        harness.moveCursor(to: 4)
        XCTAssertEqual(harness.selectedRange, NSRange(location: 4, length: 0))

        harness.type("X")
        Invariants.assertAll(harness)

        XCTAssertEqual(
            harness.selectedRange,
            NSRange(location: 5, length: 0),
            "Bug #41: cursor should advance by exactly one code unit after " +
            "typing a single character. A drift here indicates the live " +
            "cursor does not match the declared cursor after the edit."
        )
    }

    // MARK: - Bugs pending user-visible repro

    // The following bugs are referenced in REFACTOR_PLAN.md but the
    // plan does not include a user-visible symptom + scripted repro
    // that the harness can drive. Each is present here as a skeleton
    // that the user can flesh out with a description; the skip
    // message records exactly what's needed.

    func test_bug22_pendingRepro() throws {
        throw XCTSkip(
            "Bug #22: REFACTOR_PLAN.md references this bug without a " +
            "user-visible symptom or scripted repro. Please provide: " +
            "(1) a one-line symptom (what the user sees going wrong), " +
            "(2) a repro sequence (seed markdown + scripted input), and " +
            "(3) the expected vs actual observation. Then this test " +
            "becomes an assertion of the expected observation."
        )
    }

    func test_bug35_pendingRepro() throws {
        throw XCTSkip(
            "Bug #35: classed in REFACTOR_PLAN.md as an attribute-" +
            "consistency seam bug (phase 2/3 exit criteria). No user-" +
            "visible symptom retrievable from the plan. Need: symptom, " +
            "repro, expected-vs-actual."
        )
    }

    func test_bug36_pendingRepro() throws {
        throw XCTSkip(
            "Bug #36: classed in REFACTOR_PLAN.md as an attribute-" +
            "consistency seam bug (phase 2/3 exit criteria). No user-" +
            "visible symptom retrievable from the plan. Need: symptom, " +
            "repro, expected-vs-actual."
        )
    }

    func test_bug39_pendingRepro() throws {
        throw XCTSkip(
            "Bug #39: referenced in REFACTOR_PLAN.md end-of-refactor " +
            "criteria without a symptom. A commit ('Fix bugs 88, 75, " +
            "39, 90: code-block escape, wikilinks, paste with " +
            "formatting') mentions a 39 but that was already fixed; " +
            "the #39 in REFACTOR_PLAN.md is presumably a different " +
            "numbering. Need: symptom, repro, expected-vs-actual."
        )
    }

    func test_bug40_pendingRepro() throws {
        throw XCTSkip(
            "Bug #40: REFACTOR_PLAN.md references this bug without a " +
            "user-visible symptom or scripted repro. Need: symptom, " +
            "repro, expected-vs-actual."
        )
    }

    func test_bug47_pendingRepro() throws {
        throw XCTSkip(
            "Bug #47: REFACTOR_PLAN.md references this bug without a " +
            "user-visible symptom or scripted repro. Need: symptom, " +
            "repro, expected-vs-actual."
        )
    }
}
