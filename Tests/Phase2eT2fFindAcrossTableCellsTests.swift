//
//  Phase2eT2fFindAcrossTableCellsTests.swift
//  FSNotesTests
//
//  Bug #60 verification — find across table cells.
//
//  Pins the end-to-end Bug #60 invariant: searching for text that
//  spans adjacent cells succeeds because cell content lives in
//  `NSTextContentStorage` as real characters, not behind an
//  `NSTextAttachment` placeholder.
//
//  The "by construction" mechanism: `TableTextRenderer.renderNative`
//  emits cell text separated by U+001F (cell) and U+001E (row). An
//  `NSTextFinder` walking `NSTextView.string` (which forwards from
//  `textStorage.string`) sees those characters natively — it would
//  have to explicitly filter out the separators to miss cell content,
//  which it does not.
//

import XCTest
import AppKit
@testable import FSNotes

final class Phase2eT2fFindAcrossTableCellsTests: XCTestCase {

    // MARK: - Fixture

    private static let tableMarkdown = """
    | Name  | Note         |
    | ---   | ---          |
    | Alice | findmeinside |
    | Bob   | plain        |
    """

    // MARK: - 1. Bug #60 — searchable text contains cell content

    /// The canonical Bug #60 assertion: `textStorage.string` —
    /// which `NSTextFinder` walks via `NSTextFinderClient.string` —
    /// contains text from a cell that would otherwise be hidden behind
    /// an attachment. No flag manipulation: this is the default.
    func test_phase2eT2f_findAcrossTableCells_defaultFlagOn() throws {
        let harness = EditorHarness(markdown: Self.tableMarkdown)
        defer { harness.teardown() }

        let searchable = harness.editor.textStorage?.string ?? ""

        XCTAssertTrue(
            searchable.contains("findmeinside"),
            "Bug #60: cell text must appear in textStorage.string so " +
            "NSTextFinder / Cmd+F finds it. Got: \(searchable.debugDescription)"
        )
        XCTAssertTrue(
            searchable.contains("Alice"),
            "Body cell text must appear in searchable storage."
        )
        XCTAssertTrue(
            searchable.contains("Bob"),
            "Body cell text must appear in searchable storage."
        )
        XCTAssertTrue(
            searchable.contains("Name"),
            "Header cell text must appear in searchable storage."
        )
    }

    // MARK: - 3. No legacy U+FFFC inside the table range

    /// Architectural guard: the default-on native path must not leak
    /// `U+FFFC` attachment characters into storage for the table. If
    /// any U+FFFC slips in, NSTextFinder sees it as a word boundary
    /// and won't find text spanning it (the legacy symptom).
    func test_phase2eT2f_noAttachmentCharInTableStorage() throws {
        let harness = EditorHarness(markdown: Self.tableMarkdown)
        defer { harness.teardown() }

        guard let storage = harness.editor.textStorage else {
            XCTFail("No textStorage on harness editor")
            return
        }
        let s = storage.string
        XCTAssertFalse(
            s.contains("\u{FFFC}"),
            "Phase 2e-T2-f default (flag ON) must render zero U+FFFC " +
            "characters for a pure-table note. Got string: \(s.debugDescription)"
        )
    }

    // MARK: - 4. Cross-cell substring span

    /// Stronger guarantee: substrings that cross cell boundaries are
    /// reachable via `String.range(of:)` too. The native path uses
    /// U+001F as the cell separator; a substring that spans two cells
    /// will include that separator — `NSTextFinder`'s user-visible
    /// "Find" wraps lines but doesn't strip control chars, so this
    /// test pins that the separators are exactly where the renderer
    /// put them.
    func test_phase2eT2f_cellSeparatorsAreU001F() throws {
        let harness = EditorHarness(markdown: Self.tableMarkdown)
        defer { harness.teardown() }

        let s = harness.editor.textStorage?.string ?? ""
        // "Alice" and "findmeinside" are in the same body row, same
        // cell separator (U+001F) apart. The parser trims cell padding,
        // so the encoded cells are the unpadded strings.
        let expected = "Alice\u{001F}findmeinside"
        XCTAssertTrue(
            s.contains(expected),
            "Body row cells must be separated by U+001F. Got: \(s.debugDescription)"
        )

        // Header row ends at U+001E (row separator) before body starts.
        // Parser trims header cell padding too.
        let expectedHeaderEnd = "Note\u{001E}"
        XCTAssertTrue(
            s.contains(expectedHeaderEnd),
            "Header row must end at a U+001E before the first body row. " +
            "Got: \(s.debugDescription)"
        )
    }

    // MARK: - 5. TableElement is the vended NSTextParagraph

    /// End-to-end dispatch check: the content-storage delegate must
    /// vend a `TableElement` for the `.blockModelKind = .table` range.
    /// This is what makes the cell text part of the layout — and
    /// therefore Find-able.
    func test_phase2eT2f_delegateVendsTableElement() throws {
        let harness = EditorHarness(markdown: Self.tableMarkdown)
        defer { harness.teardown() }

        guard let contentStorage =
                harness.editor.textLayoutManager?.textContentManager
                as? NSTextContentStorage,
              let delegate = harness.editor.blockModelContentDelegate,
              let storage = harness.editor.textStorage else {
            XCTFail("Harness missing TK2 content storage / delegate / textStorage")
            return
        }

        var tableRange: NSRange?
        storage.enumerateAttribute(
            .blockModelKind,
            in: NSRange(location: 0, length: storage.length),
            options: []
        ) { value, subRange, stop in
            if let raw = value as? String,
               raw == BlockModelKind.table.rawValue {
                tableRange = subRange
                stop.pointee = true
            }
        }
        guard let range = tableRange else {
            XCTFail("No .blockModelKind = .table range found under default flag.")
            return
        }

        let paragraph = delegate.textContentStorage(
            contentStorage,
            textParagraphWith: range
        )
        XCTAssertTrue(
            paragraph is TableElement,
            "Default flag must dispatch a TableElement for the .table range. Got " +
            "\(paragraph.map { String(describing: type(of: $0)) } ?? "nil")"
        )
    }
}
