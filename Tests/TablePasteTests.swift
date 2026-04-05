//
//  TablePasteTests.swift
//  FSNotesTests
//
//  Unit tests for TSV and HTML table paste conversion to markdown.
//

import XCTest
@testable import FSNotes

class TablePasteTests: XCTestCase {

    // MARK: - TSV to Markdown

    func test_tsvBasic() {
        let tsv = "Name\tAge\nAlice\t30\nBob\t25"
        let result = EditTextView.tsvToMarkdownTable(tsv)
        XCTAssertNotNil(result)

        let lines = result!.components(separatedBy: "\n").filter { !$0.isEmpty }
        XCTAssertEqual(lines.count, 4) // header + separator + 2 data rows
        XCTAssertTrue(lines[0].contains("Name"))
        XCTAssertTrue(lines[0].contains("Age"))
        XCTAssertTrue(lines[1].contains("---"))
        XCTAssertTrue(lines[2].contains("Alice"))
        XCTAssertTrue(lines[3].contains("Bob"))
    }

    func test_tsvSingleRow() {
        let tsv = "A\tB\tC"
        let result = EditTextView.tsvToMarkdownTable(tsv)
        XCTAssertNotNil(result)

        let lines = result!.components(separatedBy: "\n").filter { !$0.isEmpty }
        XCTAssertEqual(lines.count, 2) // header + separator only
    }

    func test_tsvEmpty() {
        XCTAssertNil(EditTextView.tsvToMarkdownTable(""))
    }

    func test_tsvUnevenColumns() {
        let tsv = "A\tB\tC\n1\t2"
        let result = EditTextView.tsvToMarkdownTable(tsv)
        XCTAssertNotNil(result)

        let lines = result!.components(separatedBy: "\n").filter { !$0.isEmpty }
        // Data row should be padded to 3 columns
        let dataPipes = lines[2].components(separatedBy: "|").count
        let headerPipes = lines[0].components(separatedBy: "|").count
        XCTAssertEqual(dataPipes, headerPipes)
    }

    // MARK: - HTML to Markdown

    func test_htmlBasicTable() {
        let html = "<table><tr><th>Name</th><th>Age</th></tr><tr><td>Alice</td><td>30</td></tr></table>"
        let result = EditTextView.htmlTableToMarkdown(html)
        XCTAssertNotNil(result)

        let lines = result!.components(separatedBy: "\n").filter { !$0.isEmpty }
        XCTAssertEqual(lines.count, 3) // header + separator + 1 data row
        XCTAssertTrue(lines[0].contains("Name"))
        XCTAssertTrue(lines[2].contains("Alice"))
    }

    func test_htmlEntities() {
        let html = "<table><tr><td>A &amp; B</td><td>&lt;tag&gt;</td></tr></table>"
        let result = EditTextView.htmlTableToMarkdown(html)
        XCTAssertNotNil(result)
        XCTAssertTrue(result!.contains("A & B"))
        XCTAssertTrue(result!.contains("<tag>"))
    }

    func test_htmlStripsInnerTags() {
        let html = "<table><tr><td><strong>Bold</strong> text</td></tr></table>"
        let result = EditTextView.htmlTableToMarkdown(html)
        XCTAssertNotNil(result)
        XCTAssertTrue(result!.contains("Bold text"))
        XCTAssertFalse(result!.contains("<strong>"))
    }

    func test_htmlNoTable() {
        let html = "<p>No table here</p>"
        XCTAssertNil(EditTextView.htmlTableToMarkdown(html))
    }

    func test_htmlCaseInsensitive() {
        let html = "<TABLE><TR><TD>Cell</TD></TR></TABLE>"
        let result = EditTextView.htmlTableToMarkdown(html)
        XCTAssertNotNil(result)
        XCTAssertTrue(result!.contains("Cell"))
    }
}
