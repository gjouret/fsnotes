//
//  TableReaderTests.swift
//  FSNotesTests
//
//  Phase 12.C.5 — Table reader port tests.
//

import XCTest
@testable import FSNotes

final class TableReaderTests: XCTestCase {

    // MARK: - parseRow()

    func test_parseRow_basic() {
        let cells = TableReader.parseRow("| a | b | c |")
        XCTAssertEqual(cells, ["a", "b", "c"])
    }

    func test_parseRow_noOuterPipes() {
        let cells = TableReader.parseRow("a | b | c")
        XCTAssertEqual(cells, ["a", "b", "c"])
    }

    func test_parseRow_emptyCells() {
        let cells = TableReader.parseRow("|  |  |")
        XCTAssertEqual(cells, ["", ""])
    }

    func test_parseRow_trimsWhitespace() {
        let cells = TableReader.parseRow("|   x   |   y   |")
        XCTAssertEqual(cells, ["x", "y"])
    }

    // MARK: - isRow()

    func test_isRow_acceptsLineWithPipe() {
        XCTAssertTrue(TableReader.isRow("a | b"))
        XCTAssertTrue(TableReader.isRow("|"))
    }

    func test_isRow_rejectsLineWithoutPipe() {
        XCTAssertFalse(TableReader.isRow("plain text"))
        XCTAssertFalse(TableReader.isRow(""))
    }

    // MARK: - isSeparator()

    func test_isSeparator_simpleDashes() {
        XCTAssertTrue(TableReader.isSeparator("|---|---|"))
        XCTAssertTrue(TableReader.isSeparator("|---|---|---|"))
    }

    func test_isSeparator_withAlignmentColons() {
        XCTAssertTrue(TableReader.isSeparator("|:---|:---:|---:|"))
    }

    func test_isSeparator_withSpaces() {
        XCTAssertTrue(TableReader.isSeparator("| --- | --- |"))
        XCTAssertTrue(TableReader.isSeparator("| :--- | ---: |"))
    }

    func test_isSeparator_rejectsMissingDashes() {
        // No `-`: not a separator.
        XCTAssertFalse(TableReader.isSeparator("|   |   |"))
    }

    func test_isSeparator_rejectsNonSeparatorChars() {
        XCTAssertFalse(TableReader.isSeparator("|---|abc|"))
    }

    func test_isSeparator_rejectsHeaderLine() {
        XCTAssertFalse(TableReader.isSeparator("| a | b |"))
    }

    func test_isSeparator_rejectsEmptyCells() {
        // Empty cell after trimming: not a separator.
        XCTAssertFalse(TableReader.isSeparator("|---|  |"))
    }

    // MARK: - parseAlignments()

    func test_parseAlignments_allDefault() {
        let aligns = TableReader.parseAlignments("|---|---|---|")
        XCTAssertEqual(aligns, [.none, .none, .none])
    }

    func test_parseAlignments_mixed() {
        // :--- = left, :---: = center, ---: = right, --- = none
        let aligns = TableReader.parseAlignments("|:---|:---:|---:|---|")
        XCTAssertEqual(aligns, [.left, .center, .right, .none])
    }

    // MARK: - read() — mode (a): header on current line

    func test_read_modeA_simpleTable() {
        let lines = ["| a | b |", "|---|---|", "| 1 | 2 |", "after"]
        let r = TableReader.read(
            lines: lines, at: 0, rawBuffer: [],
            trailingNewline: false,
            parseInlines: { [Inline.text($0)] }
        )
        guard let result = r else { return XCTFail("expected match") }
        XCTAssertEqual(result.nextIndex, 3)
        XCTAssertFalse(result.headerFromBuffer)
        guard case .table(let header, let aligns, let rows, let widths) = result.block else {
            return XCTFail("expected table, got \(result.block)")
        }
        XCTAssertEqual(header.count, 2)
        XCTAssertEqual(aligns.count, 2)
        XCTAssertEqual(rows.count, 1)
        XCTAssertNil(widths)
    }

    func test_read_modeA_padsShortRow() {
        // Body row has fewer cells than header; reader pads with empty.
        let lines = ["| a | b | c |", "|---|---|---|", "| 1 |"]
        let r = TableReader.read(
            lines: lines, at: 0, rawBuffer: [],
            trailingNewline: false,
            parseInlines: { [Inline.text($0)] }
        )
        guard let result = r else { return XCTFail("expected match") }
        guard case .table(let header, _, let rows, _) = result.block else {
            return XCTFail("expected table")
        }
        XCTAssertEqual(header.count, 3)
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0].count, 3)
    }

    func test_read_modeA_truncatesLongRow() {
        // Body row has more cells than header; reader truncates.
        let lines = ["| a |", "|---|", "| 1 | 2 | 3 |"]
        let r = TableReader.read(
            lines: lines, at: 0, rawBuffer: [],
            trailingNewline: false,
            parseInlines: { [Inline.text($0)] }
        )
        guard let result = r else { return XCTFail("expected match") }
        guard case .table(_, _, let rows, _) = result.block else {
            return XCTFail("expected table")
        }
        XCTAssertEqual(rows[0].count, 1)
    }

    func test_read_modeA_terminatesAtFirstNonRow() {
        let lines = ["| a |", "|---|", "| 1 |", "para"]
        let r = TableReader.read(
            lines: lines, at: 0, rawBuffer: [],
            trailingNewline: false,
            parseInlines: { [Inline.text($0)] }
        )
        guard let result = r else { return XCTFail("expected match") }
        XCTAssertEqual(result.nextIndex, 3)
    }

    func test_read_modeA_returnsNilWhenSeparatorMissing() {
        let lines = ["| a | b |", "not a separator"]
        XCTAssertNil(TableReader.read(
            lines: lines, at: 0, rawBuffer: [],
            trailingNewline: false,
            parseInlines: { [Inline.text($0)] }
        ))
    }

    func test_read_modeA_skipsTrailingSyntheticEmptyAsSeparator() {
        // If the synthetic trailing empty line would be treated as
        // separator, we'd fail to detect; the reader correctly bails.
        let lines = ["| a |", ""]
        XCTAssertNil(TableReader.read(
            lines: lines, at: 0, rawBuffer: [],
            trailingNewline: true,
            parseInlines: { [Inline.text($0)] }
        ))
    }

    // MARK: - read() — mode (b): header buffered as paragraph

    func test_read_modeB_headerFromBuffer() {
        let lines = ["|---|---|", "| 1 | 2 |"]
        let rawBuffer = ["| a | b |"]
        let r = TableReader.read(
            lines: lines, at: 0, rawBuffer: rawBuffer,
            trailingNewline: false,
            parseInlines: { [Inline.text($0)] }
        )
        guard let result = r else { return XCTFail("expected match") }
        XCTAssertTrue(result.headerFromBuffer)
        guard case .table(let header, _, let rows, _) = result.block else {
            return XCTFail("expected table")
        }
        XCTAssertEqual(header.count, 2)
        XCTAssertEqual(rows.count, 1)
    }

    func test_read_modeB_returnsNilWhenBufferHeaderInvalid() {
        // rawBuffer.last has no `|` — not a valid table header.
        let lines = ["|---|"]
        let rawBuffer = ["plain paragraph"]
        XCTAssertNil(TableReader.read(
            lines: lines, at: 0, rawBuffer: rawBuffer,
            trailingNewline: false,
            parseInlines: { [Inline.text($0)] }
        ))
    }

    // MARK: - End-to-end via MarkdownParser.parse

    func test_endToEnd_simpleTable() {
        let doc = MarkdownParser.parse("| a | b |\n|---|---|\n| 1 | 2 |\n")
        XCTAssertEqual(doc.blocks.count, 1)
        guard case .table(let header, _, let rows, _) = doc.blocks[0] else {
            return XCTFail("expected table, got \(doc.blocks)")
        }
        XCTAssertEqual(header.count, 2)
        XCTAssertEqual(rows.count, 1)
    }

    func test_endToEnd_alignments() {
        let doc = MarkdownParser.parse("| a | b | c |\n|:---|:---:|---:|\n| x | y | z |\n")
        guard case .table(_, let aligns, _, _) = doc.blocks[0] else {
            return XCTFail("expected table")
        }
        XCTAssertEqual(aligns, [.left, .center, .right])
    }

    func test_endToEnd_paragraphBeforeHeaderBuffered_modeB() {
        // The header line gets buffered as a paragraph until the
        // separator on the next line triggers mode (b).
        let doc = MarkdownParser.parse("| a | b |\n|---|---|\n| 1 | 2 |\n")
        XCTAssertEqual(doc.blocks.count, 1)
        guard case .table = doc.blocks[0] else {
            return XCTFail("expected table")
        }
    }

    func test_endToEnd_roundTripsBackToInput() {
        let input = "| a | b |\n|---|---|\n| 1 | 2 |\n"
        let doc = MarkdownParser.parse(input)
        let output = MarkdownSerializer.serialize(doc)
        // Round-trip should re-emit a canonical table; columns + rows
        // preserved.
        let reparsed = MarkdownParser.parse(output)
        XCTAssertEqual(reparsed.blocks.count, 1)
        guard case .table(let header, _, let rows, _) = reparsed.blocks[0] else {
            return XCTFail("expected table after round-trip")
        }
        XCTAssertEqual(header.count, 2)
        XCTAssertEqual(rows.count, 1)
    }
}
