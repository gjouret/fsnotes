//
//  TableElementEmissionTests.swift
//  FSNotesTests
//
//  Phase 2e-T2-b — Proves the native-cell-text table rendering path
//  emits a flat, separator-encoded attributed string when
//  `FeatureFlag.nativeTableElements == true`, and that the legacy
//  NSTextAttachment path is unchanged when the flag is off (default).
//
//  The tests lock in five contracts:
//    1. Flag OFF → storage is a single U+FFFC backed by
//       `TableBlockAttachment`; `.string` carries no cell text.
//    2. Flag ON → storage's `.string` carries cell text in
//       header-then-body order, separated by U+001F (cells) and U+001E
//       (rows). Zero U+FFFC characters.
//    3. Flag ON → Bug #60's search-across-cells assertion passes (the
//       main deliverable of 2e-T2-b).
//    4. Flag ON → the rendered range carries
//       `.blockModelKind = .table.rawValue`.
//    5. Flag ON → the TK2 content-storage delegate returns a
//       `TableElement` for the tagged range.
//
//  The tests toggle the flag inside each function with a `defer`
//  restore so a crash mid-test cannot leak the flag state into the
//  rest of the suite.
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

    // MARK: - Flag OFF (legacy attachment path, retained for A/B)

    func test_phase2eT2b_flagOff_emitsAttachment() throws {
        // Phase 2e-T2-f flipped the default to `true`; this test pins
        // the legacy path explicitly so the attachment emission contract
        // stays regression-covered until T2-h deletes the legacy path.
        FeatureFlag.nativeTableElements = false
        defer { FeatureFlag.nativeTableElements = true }

        let harness = EditorHarness(markdown: Self.harnessMarkdown)
        defer { harness.teardown() }

        guard let storage = harness.editor.textStorage else {
            XCTFail("Editor has no textStorage.")
            return
        }

        // Exactly one U+FFFC character in the whole storage (the
        // table attachment character).
        let string = storage.string
        let ffffCount = string.filter { $0 == "\u{FFFC}" }.count
        XCTAssertEqual(
            ffffCount, 1,
            "Flag OFF must emit exactly one U+FFFC attachment character for the table."
        )

        // Cell text MUST NOT appear in the searchable string — that's
        // the entire live Bug #60 symptom. If it does appear here,
        // something has gone wrong before we even enable the flag.
        XCTAssertFalse(
            string.contains("Alice"),
            "Flag OFF: cell text must be hidden behind the attachment, not present in .string."
        )
        XCTAssertFalse(
            string.contains("findmeinside"),
            "Flag OFF: cell text must be hidden behind the attachment."
        )
    }

    // MARK: - Flag ON (native-cell-text path)

    /// Verify the emitted storage's `.string` contains cell text with
    /// U+001F between cells and U+001E between rows, in header-then-body
    /// order.
    func test_phase2eT2b_flagOn_emitsFlatCellText() throws {
        FeatureFlag.nativeTableElements = true
        defer { FeatureFlag.nativeTableElements = true }

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
        FeatureFlag.nativeTableElements = true
        defer { FeatureFlag.nativeTableElements = true }

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
        FeatureFlag.nativeTableElements = true
        defer { FeatureFlag.nativeTableElements = true }

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
        FeatureFlag.nativeTableElements = true
        defer { FeatureFlag.nativeTableElements = true }

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
        FeatureFlag.nativeTableElements = true
        defer { FeatureFlag.nativeTableElements = true }

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
