//
//  TableLayoutFragmentRenderTests.swift
//  FSNotesTests
//
//  Phase 2e-T2-c — Proves `TableLayoutFragment.layoutFragmentFrame`
//  reports a height that matches `TableGeometry.compute(...).totalHeight`
//  (so TK2 reserves the right vertical space for the grid) and that the
//  fragment's row-count matches the block's header+body shape.
//
//  Snapshot / pixel-level tests are NOT in scope for this slice — drawing
//  correctness is verified against the deployed app. The tests here are
//  pure-function contract checks exercised via the `EditorHarness` with
//  `FeatureFlag.nativeTableElements = true` (the slice's dogfood gate).
//
//  What these tests lock in:
//    1. `layoutFragmentFrame.height` equals `TableGeometry.compute(...).totalHeight`
//       within a half-point tolerance; `.width` equals the container
//       width. Without this override, TK2 measures the separator-encoded
//       backing string as a single line and the table renders clipped.
//    2. Row-count invariants under multiple table shapes (1x5, 4x1, 3x2,
//       10x3) — the fragment's backing `TableElement.block` must carry
//       one header row + N body rows matching the decoded storage.
//
//  Rule-3 compliance: the tests lean on the harness for realism, but the
//  assertions themselves are against value-typed snapshots (CGFloat,
//  Int) — they never poke an `NSWindow`, synthesize mouse events, or
//  otherwise rely on live UI state.
//

import XCTest
import AppKit
@testable import FSNotes

final class TableLayoutFragmentRenderTests: XCTestCase {

    // MARK: - Helpers

    /// Enumerate every `TableLayoutFragment` in the editor's TK2 layout
    /// manager. Returns an empty array if the flag isn't on or the
    /// table path hasn't dispatched.
    private func tableFragments(in editor: EditTextView) -> [TableLayoutFragment] {
        guard let tlm = editor.textLayoutManager else { return [] }
        tlm.ensureLayout(for: tlm.documentRange)
        var out: [TableLayoutFragment] = []
        tlm.enumerateTextLayoutFragments(
            from: tlm.documentRange.location,
            options: [.ensuresLayout]
        ) { fragment in
            if let tf = fragment as? TableLayoutFragment {
                out.append(tf)
            }
            return true
        }
        return out
    }

    /// Pull the `Block.table` backing the fragment's element, so the
    /// test can feed the same input into `TableGeometry.compute(...)`
    /// and compare.
    private func tableBlock(of fragment: TableLayoutFragment) -> Block? {
        guard let element = fragment.textElement as? TableElement else {
            return nil
        }
        return element.block
    }

    private var font: NSFont {
        UserDefaultsManagement.noteFont
            ?? NSFont.systemFont(ofSize: NSFont.systemFontSize)
    }

    // MARK: - T2-c.1: fragment frame matches geometry

    /// A 3-column × 2-body-row table seeded through the harness with the
    /// flag on. The fragment's height must equal
    /// `TableGeometry.compute(...).totalHeight` (±0.5pt — geometry
    /// computes in ceil-heights, the frame return is a direct CGFloat
    /// assignment so no accumulated float drift is expected, but the
    /// tolerance covers any future re-rounding). Width must equal the
    /// container's usable width.
    func test_T2c_fragmentFrame_matchesTableGeometry() throws {

        let markdown = """
        | Name | City | Role |
        | ---  | ---  | ---  |
        | Alice | NYC | Engineer |
        | Bob   | SFO | Designer |
        """

        let harness = EditorHarness(markdown: markdown)
        defer { harness.teardown() }

        let fragments = tableFragments(in: harness.editor)
        guard let fragment = fragments.first else {
            XCTFail(
                "Expected at least one TableLayoutFragment under flag ON; " +
                "got \(fragments.count)"
            )
            return
        }

        guard let block = tableBlock(of: fragment),
              case .table(let header, let alignments, let rows, _, _) = block
        else {
            XCTFail("Fragment's TableElement did not carry a .table block")
            return
        }

        let containerWidth = harness.editor.textLayoutManager?
            .textContainer?.size.width ?? 0
        XCTAssertGreaterThan(
            containerWidth, 0,
            "Container width must be positive for layout to occur"
        )

        let expected = TableGeometry.compute(
            header: header,
            rows: rows,
            alignments: alignments,
            containerWidth: containerWidth,
            font: font
        )

        let frame = fragment.layoutFragmentFrame
        // T2-g: fragment frame adds `handleBarHeight` above the grid
        // to reserve space for the column hover handles.
        let expectedHeight = TableGeometry.handleBarHeight + expected.totalHeight
        XCTAssertEqual(
            frame.height, expectedHeight, accuracy: 0.5,
            "Fragment height must equal handleBarHeight + TableGeometry.totalHeight " +
            "(got \(frame.height), expected \(expectedHeight))"
        )
        XCTAssertEqual(
            frame.width, containerWidth, accuracy: 0.5,
            "Fragment width must equal the text container width " +
            "(got \(frame.width), expected \(containerWidth))"
        )
    }

    // MARK: - T2-c.3: row-count matches geometry across shapes

    /// Seed several table shapes and verify `TableGeometry.compute(...)
    /// .rowHeights.count == 1 (header) + rows.count (body)` holds for
    /// each. The backing `TableElement` must report a block whose
    /// row-count matches that shape — if the placeholder decode ever
    /// miscounts rows, the grid will paint the wrong number of stripes
    /// and this test catches it before the user does.
    func test_T2c_rowCount_matchesTableGeometry() throws {

        // (columns, bodyRows) shapes: 1x5, 4x1, 3x2, the standard 2x3.
        // Each is an independent harness instance so the fragment cache
        // stays clean between shapes.
        let shapes: [(cols: Int, rows: Int)] = [(1, 5), (4, 1), (3, 2), (2, 3)]

        for shape in shapes {
            let markdown = makeTableMarkdown(
                cols: shape.cols, bodyRows: shape.rows
            )
            let harness = EditorHarness(markdown: markdown)
            defer { harness.teardown() }

            let fragments = tableFragments(in: harness.editor)
            guard let fragment = fragments.first else {
                XCTFail(
                    "Shape \(shape): expected a TableLayoutFragment, got " +
                    "\(fragments.count)"
                )
                continue
            }

            guard let block = tableBlock(of: fragment),
                  case .table(let header, let alignments, let rows, _, _) = block
            else {
                XCTFail("Shape \(shape): fragment's element did not carry a .table block")
                continue
            }

            // Sanity: the decoded placeholder should have header.count
            // == shape.cols and rows.count == shape.rows. If this drifts,
            // the rest of the grid math is meaningless.
            XCTAssertEqual(
                header.count, shape.cols,
                "Shape \(shape): decoded header column count mismatch"
            )
            XCTAssertEqual(
                rows.count, shape.rows,
                "Shape \(shape): decoded body row count mismatch"
            )

            let containerWidth = harness.editor.textLayoutManager?
                .textContainer?.size.width ?? 0
            let geometry = TableGeometry.compute(
                header: header,
                rows: rows,
                alignments: alignments,
                containerWidth: containerWidth,
                font: font
            )

            XCTAssertEqual(
                geometry.rowHeights.count, 1 + shape.rows,
                "Shape \(shape): rowHeights.count should be 1 (header) + " +
                "\(shape.rows) (body) = \(1 + shape.rows), got " +
                "\(geometry.rowHeights.count)"
            )
            XCTAssertEqual(
                geometry.columnWidths.count, shape.cols,
                "Shape \(shape): columnWidths.count must equal header column count"
            )
        }
    }

    // MARK: - Markdown shape helper

    /// Build a well-formed markdown table with `cols` columns and
    /// `bodyRows` body rows. Cells contain short deterministic text so
    /// layout is stable across runs.
    private func makeTableMarkdown(cols: Int, bodyRows: Int) -> String {
        precondition(cols > 0, "cols must be > 0")
        precondition(bodyRows > 0, "bodyRows must be > 0")

        func row(_ cells: [String]) -> String {
            return "| " + cells.joined(separator: " | ") + " |"
        }

        let headerCells = (0..<cols).map { "Col\($0 + 1)" }
        let dividerCells = Array(repeating: "---", count: cols)
        var lines: [String] = [row(headerCells), row(dividerCells)]
        for r in 0..<bodyRows {
            let bodyCells = (0..<cols).map { c in "r\(r + 1)c\(c + 1)" }
            lines.append(row(bodyCells))
        }
        return lines.joined(separator: "\n")
    }
}
