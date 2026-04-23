//
//  TableElementEmissionTests.swift
//  FSNotesTests
//
//  Proves the native-cell-text table rendering path emits a flat,
//  separator-encoded attributed string.
//
//  The tests lock in four contracts:
//    1. Storage's `.string` carries cell text in header-then-body
//       order, separated by U+001F (cells) and U+001E (rows). Zero
//       U+FFFC characters.
//    2. Bug #60's search-across-cells assertion passes (the main
//       deliverable of 2e-T2-b).
//    3. The rendered range carries `.blockModelKind = .table.rawValue`.
//    4. The TK2 content-storage delegate returns a `TableElement` for
//       the tagged range.
//

import XCTest
import AppKit
@testable import FSNotes

final class TableElementEmissionTests: XCTestCase {

    // MARK: - Harness-level fixture
    //
    // The harness parses markdown through `MarkdownParser`, installs
    // the projection via `DocumentRenderer.render`, and copies the
    // rendered attributed string into the editor's storage. That means
    // `harness.editor.textStorage` contains the exact output of
    // `TableTextRenderer.render(...)` for the table block.

    private static let harnessMarkdown = """
    | Name | Note |
    | ---  | ---  |
    | Alice | findmeinside |
    | Bob   | plain |
    """

    // MARK: - Native cell-text path

    /// Verify the emitted storage's `.string` contains cell text with
    /// U+001F between cells and U+001E between rows, in header-then-body
    /// order.
    func test_phase2eT2b_flagOn_emitsFlatCellText() throws {

        let harness = EditorHarness(markdown: Self.harnessMarkdown)
        defer { harness.teardown() }

        guard let storage = harness.editor.textStorage else {
            XCTFail("Editor has no textStorage.")
            return
        }

        let string = storage.string

        XCTAssertTrue(
            string.contains("Name"),
            "Flag ON: header cell text must appear in .string."
        )
        XCTAssertTrue(
            string.contains("Alice"),
            "Flag ON: body cell text must appear in .string."
        )
        XCTAssertTrue(
            string.contains("Bob"),
            "Flag ON: body cell text must appear in .string."
        )

        // Cell separator (U+001F) and row separator (U+001E) must both
        // be present (header row has at least 2 cells → at least one
        // cell-sep; header→body + at least one body row → at least one
        // row-sep).
        XCTAssertTrue(
            string.contains("\u{001F}"),
            "Flag ON: U+001F cell separator must be present between cells."
        )
        XCTAssertTrue(
            string.contains("\u{001E}"),
            "Flag ON: U+001E row separator must be present between rows (including header→body boundary)."
        )

        // Order invariant: header appears before body.
        guard let nameIdx = string.range(of: "Name")?.lowerBound,
              let aliceIdx = string.range(of: "Alice")?.lowerBound else {
            XCTFail("Expected both 'Name' and 'Alice' in storage string.")
            return
        }
        XCTAssertLessThan(
            nameIdx, aliceIdx,
            "Header cells must come before body cells in the flat encoding."
        )
    }

    /// Rule-7 grep gate: zero U+FFFC attachment characters inside any
    /// `.blockModelKind = .table` range.
    func test_phase2eT2b_flagOn_tableRangeContainsNoObjectReplacement() throws {

        let harness = EditorHarness(markdown: Self.harnessMarkdown)
        defer { harness.teardown() }

        guard let storage = harness.editor.textStorage else {
            XCTFail("Editor has no textStorage.")
            return
        }

        let fullRange = NSRange(location: 0, length: storage.length)
        var foundFFFCInTableRange = false
        storage.enumerateAttribute(
            .blockModelKind, in: fullRange, options: []
        ) { value, subRange, _ in
            guard let raw = value as? String,
                  raw == BlockModelKind.table.rawValue else { return }
            let slice = (storage.string as NSString).substring(with: subRange)
            if slice.contains("\u{FFFC}") {
                foundFFFCInTableRange = true
            }
        }
        XCTAssertFalse(
            foundFFFCInTableRange,
            "Flag ON: no U+FFFC character must appear inside any .blockModelKind = .table range."
        )
    }

    /// Bug #60 under the flag ON: the searchable text contains cell
    /// content. This is the **main deliverable** of slice 2e-T2-b —
    /// the flag flip is what enables NSTextFinder to see across cells.
    func test_phase2eT2b_flagOn_bug60_findAcrossTableCells() throws {

        let harness = EditorHarness(markdown: Self.harnessMarkdown)
        defer { harness.teardown() }

        let searchable = harness.editor.textStorage?.string ?? ""

        XCTAssertTrue(
            searchable.contains("findmeinside"),
            "Bug #60 (flag ON): cell text must appear in the searchable string. " +
            "This is the native-cell-text path's raison d'être."
        )
    }

    /// The rendered range covering the table carries
    /// `.blockModelKind = .table.rawValue`.
    func test_phase2eT2b_flagOn_blockModelKindIsTable() throws {

        let harness = EditorHarness(markdown: Self.harnessMarkdown)
        defer { harness.teardown() }

        guard let storage = harness.editor.textStorage else {
            XCTFail("Editor has no textStorage.")
            return
        }

        // Find a character we know is inside the table (the literal
        // "Alice") and check its `.blockModelKind`.
        let ns = storage.string as NSString
        let aliceRange = ns.range(of: "Alice")
        guard aliceRange.location != NSNotFound else {
            XCTFail("Harness table did not render 'Alice' into storage.")
            return
        }
        let raw = storage.attribute(
            .blockModelKind,
            at: aliceRange.location,
            effectiveRange: nil
        ) as? String
        XCTAssertEqual(
            raw,
            BlockModelKind.table.rawValue,
            "Flag ON: the table's rendered range must be tagged with .blockModelKind = .table."
        )
    }

    /// The TK2 content-storage delegate returns a `TableElement` for
    /// the tagged range. Mirrors the `TextKit2ElementDispatchTests`
    /// pattern.
    func test_phase2eT2b_flagOn_delegateReturnsTableElement() throws {

        let harness = EditorHarness(markdown: Self.harnessMarkdown)
        defer { harness.teardown() }

        guard let contentStorage =
            harness.editor.textLayoutManager?.textContentManager
                as? NSTextContentStorage else {
            XCTFail("Editor must expose NSTextContentStorage.")
            return
        }
        guard let delegate = harness.editor.blockModelContentDelegate else {
            XCTFail("blockModelContentDelegate must be installed.")
            return
        }
        guard let storage = harness.editor.textStorage else {
            XCTFail("Editor has no textStorage.")
            return
        }

        // Locate the `.blockModelKind = .table` range by enumerating;
        // that's what the content storage would hand to the delegate
        // for the table's paragraph.
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
            XCTFail("No .blockModelKind = .table range found in storage.")
            return
        }

        let paragraph = delegate.textContentStorage(
            contentStorage,
            textParagraphWith: range
        )
        XCTAssertTrue(
            paragraph is TableElement,
            "Flag ON: content-storage delegate must return a TableElement for the .table range, got " +
            "\(paragraph.map { String(describing: type(of: $0)) } ?? "nil")"
        )
    }
}
