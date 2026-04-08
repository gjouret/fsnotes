//
//  CommonMarkSpecTests.swift
//  FSNotesTests
//
//  Automated compliance tests against the CommonMark specification.
//  Loads examples from spec-{version}.json (652 examples in v0.31.2),
//  parses each through MarkdownParser, renders to HTML via
//  CommonMarkHTMLRenderer, and compares against the spec's expected output.
//
//  Test structure:
//  - One test method per spec section (26 sections)
//  - Each method runs all examples in that section and reports pass/fail
//  - Sections we fully support assert exact pass counts
//  - Sections we partially support assert minimum pass counts
//  - All results are logged to ~/unit-tests/commonmark-compliance.txt
//
//  Spec version tracking:
//  - specVersion constant tracks which spec version we test against
//  - Bump specVersion and download new spec JSON when CommonMark updates
//  - Review/update expected pass counts after spec version bumps
//

import XCTest
@testable import FSNotes

// MARK: - Spec version tracking

/// Current CommonMark spec version under test.
/// Update this when a newer spec is released, and download the
/// corresponding spec-{version}.json into Tests/CommonMark/.
private let specVersion = "0.31.2"

// MARK: - Test data model

private struct SpecExample: Codable {
    let markdown: String
    let html: String
    let example: Int
    let start_line: Int
    let end_line: Int
    let section: String
}

// MARK: - Test result tracking

private struct SectionResult {
    let section: String
    let total: Int
    let passed: Int
    let failed: Int
    var failures: [(example: Int, expected: String, actual: String)]

    var passRate: String {
        guard total > 0 else { return "N/A" }
        let pct = Double(passed) / Double(total) * 100
        return String(format: "%.0f%%", pct)
    }
}

// MARK: - Test suite

class CommonMarkSpecTests: XCTestCase {

    // MARK: - Shared spec data

    private static var _allExamples: [SpecExample]?

    private static var allExamples: [SpecExample] {
        if let cached = _allExamples { return cached }
        let thisFile = URL(fileURLWithPath: #file)
        let specFile = thisFile.deletingLastPathComponent()
            .appendingPathComponent("spec-\(specVersion).json")
        guard let data = try? Data(contentsOf: specFile) else {
            print("ERROR: Could not read spec file at \(specFile.path)")
            _allExamples = []
            return []
        }
        guard let examples = try? JSONDecoder().decode([SpecExample].self, from: data) else {
            print("ERROR: Could not decode spec JSON")
            _allExamples = []
            return []
        }
        _allExamples = examples
        return examples
    }

    // MARK: - Helpers

    private func examples(for section: String) -> [SpecExample] {
        Self.allExamples.filter { $0.section == section }
    }

    /// Run all examples for a section, return results.
    private func runSection(_ section: String) -> SectionResult {
        let exs = examples(for: section)
        var passed = 0
        var failed = 0
        var failures: [(Int, String, String)] = []

        for ex in exs {
            let doc = MarkdownParser.parse(ex.markdown)
            let actual = CommonMarkHTMLRenderer.render(doc)
            if actual == ex.html {
                passed += 1
            } else {
                failed += 1
                failures.append((ex.example, ex.html, actual))
            }
        }

        return SectionResult(section: section, total: exs.count,
                             passed: passed, failed: failed,
                             failures: failures)
    }

    /// Assert that a section passes at least `minimum` examples.
    /// Reports all failures as test output for debugging.
    private func assertSection(_ section: String,
                               passesAtLeast minimum: Int,
                               file: StaticString = #file,
                               line: UInt = #line) {
        let result = runSection(section)

        // Log failures for debugging
        if !result.failures.isEmpty {
            let failLog = result.failures.prefix(10).map { (ex, expected, actual) in
                """
                  Example \(ex):
                    Expected: \(repr(expected))
                    Got:      \(repr(actual))
                """
            }.joined(separator: "\n")
            let msg = "\(section): \(result.passed)/\(result.total) passed (\(result.passRate))\n\(failLog)"
            if result.failures.count > 10 {
                print(msg + "\n  ... and \(result.failures.count - 10) more")
            } else {
                print(msg)
            }
        }

        XCTAssertGreaterThanOrEqual(
            result.passed, minimum,
            "\(section): expected ≥\(minimum) passing, got \(result.passed)/\(result.total) (\(result.passRate))",
            file: file, line: line
        )
    }

    private func repr(_ s: String) -> String {
        s.replacingOccurrences(of: "\n", with: "\\n")
         .replacingOccurrences(of: "\t", with: "\\t")
    }

    // MARK: - Full compliance report

    /// Runs ALL 652 examples and writes a compliance report.
    /// This test always passes — it's for reporting, not gating.
    func test_00_fullComplianceReport() {
        let sections = [
            "Tabs", "Backslash escapes",
            "Entity and numeric character references",
            "Precedence", "Thematic breaks", "ATX headings",
            "Setext headings", "Indented code blocks",
            "Fenced code blocks", "HTML blocks",
            "Link reference definitions", "Paragraphs",
            "Blank lines", "Block quotes", "List items", "Lists",
            "Inlines", "Code spans",
            "Emphasis and strong emphasis", "Links", "Images",
            "Autolinks", "Raw HTML", "Hard line breaks",
            "Soft line breaks", "Textual content"
        ]

        var totalPassed = 0
        var totalFailed = 0
        var report = """
        CommonMark Spec Compliance Report
        ==================================
        Spec version: \(specVersion)
        Parser: MarkdownParser (FSNotes)
        Date: \(ISO8601DateFormatter().string(from: Date()))

        """

        for section in sections {
            let result = runSection(section)
            totalPassed += result.passed
            totalFailed += result.failed
            let status = result.failed == 0 ? "✅" : (result.passed > 0 ? "⚠️" : "❌")
            report += "\(status) \(section): \(result.passed)/\(result.total) (\(result.passRate))\n"

            if !result.failures.isEmpty {
                let failedExamples = result.failures.prefix(5).map { "    #\($0.example)" }
                report += failedExamples.joined(separator: "\n") + "\n"
                if result.failures.count > 5 {
                    report += "    ... and \(result.failures.count - 5) more\n"
                }
            }
        }

        let totalExamples = totalPassed + totalFailed
        let overallPct = totalExamples > 0
            ? String(format: "%.1f%%", Double(totalPassed) / Double(totalExamples) * 100)
            : "N/A"

        report += """

        Overall: \(totalPassed)/\(totalExamples) (\(overallPct))
        """

        // Write report to disk
        let outputDir = NSHomeDirectory() + "/unit-tests"
        try? FileManager.default.createDirectory(atPath: outputDir,
                                                  withIntermediateDirectories: true)
        let reportPath = "\(outputDir)/commonmark-compliance.txt"
        try? report.write(toFile: reportPath, atomically: true, encoding: .utf8)
        print(report)
        print("Report written to: \(reportPath)")
    }

    // MARK: - Block-level sections

    // MARK: - Block-level sections

    // --- ATX Headings (18 examples) ---
    // We support ATX headings H1-H6 with inline content and closing hashes.
    // Unsupported: backslash escapes in headings, leading-space headings,
    // indented-code-block disambiguation (4+ spaces).
    func test_ATXHeadings() {
        assertSection("ATX headings", passesAtLeast: 15)
    }

    // --- Setext Headings (27 examples) ---
    // We support paragraph + === (H1) or --- (H2) with inline content.
    // Unsupported: multi-line setext content, indented underlines,
    // lazy continuation, emphasis-only disambiguation (partially handled).
    func test_setextHeadings() {
        assertSection("Setext headings", passesAtLeast: 22)
    }

    // --- Thematic Breaks (19 examples) ---
    // We support ---, ___, *** with optional spaces between chars and
    // up to 3 leading spaces. Unsupported: 4-space indent (indented code),
    // HR within list items.
    func test_thematicBreaks() {
        assertSection("Thematic breaks", passesAtLeast: 15)
    }

    // --- Fenced Code Blocks (29 examples) ---
    // Near-complete: fences with info strings, indented open/close (up to
    // 3 spaces), unterminated fences, multi-backtick. Only failing:
    // 4-space-indented fence (indented code block, not supported).
    func test_fencedCodeBlocks() {
        assertSection("Fenced code blocks", passesAtLeast: 28)
    }

    // --- Indented Code Blocks (12 examples) ---
    // Not supported — we don't distinguish 4-space-indented lines as code.
    func test_indentedCodeBlocks() {
        assertSection("Indented code blocks", passesAtLeast: 0)
    }

    // --- Paragraphs (8 examples) ---
    // Basic paragraphs work. Unsupported: leading-space stripping,
    // hard line breaks (trailing spaces), indented code block boundary.
    func test_paragraphs() {
        assertSection("Paragraphs", passesAtLeast: 5)
    }

    // --- Blank Lines (1 example) ---
    func test_blankLines() {
        assertSection("Blank lines", passesAtLeast: 0)
    }

    // --- Block Quotes (25 examples) ---
    // We support basic blockquotes with inner block re-parsing.
    // Unsupported: lazy continuation, nested blockquotes, list interaction.
    func test_blockQuotes() {
        assertSection("Block quotes", passesAtLeast: 17)
    }

    // --- List Items (48 examples) ---
    // We support flat lists with simple inline content, tight/loose
    // detection, empty items, and marker type splitting.
    // Unsupported: nested blocks in list items, continuation paragraphs,
    // complex indentation rules.
    func test_listItems() {
        assertSection("List items", passesAtLeast: 12)
    }

    // --- Lists (26 examples) ---
    // Basic ordered/unordered lists with tight/loose detection.
    // Unsupported: multi-paragraph items, nested blocks.
    func test_lists() {
        assertSection("Lists", passesAtLeast: 9)
    }

    // --- HTML Blocks (44 examples) ---
    // Not supported — HTML blocks are treated as paragraphs.
    func test_HTMLBlocks() {
        assertSection("HTML blocks", passesAtLeast: 40)
    }

    // --- Link Reference Definitions (27 examples) ---
    // First-pass collection in MarkdownParser, consumed lines skipped.
    // Reference links and images resolved in parseInlines.
    func test_linkReferenceDefinitions() {
        assertSection("Link reference definitions", passesAtLeast: 22)
    }

    // MARK: - Inline-level sections

    // --- Code Spans (22 examples) ---
    // Full compliance: multi-backtick, space stripping, newline collapsing,
    // code span precedence over emphasis/links.
    func test_codeSpans() {
        assertSection("Code spans", passesAtLeast: 22)
    }

    // --- Emphasis and Strong Emphasis (132 examples) ---
    // Both * and _ delimiters with full CommonMark delimiter stack
    // algorithm (spec section 6.2). Handles nested emphasis, Rule of 3,
    // underscore word boundaries, mixed nesting. Remaining failures:
    // non-breaking space (U+00A0) not recognized as Unicode whitespace,
    // currency symbols (£, €) not recognized as Unicode punctuation.
    func test_emphasisAndStrongEmphasis() {
        assertSection("Emphasis and strong emphasis", passesAtLeast: 131)
    }

    // --- Links (90 examples) ---
    // Inline links with titles, angle-bracketed destinations, backslash
    // escapes in URLs, reference links (full, collapsed, shortcut).
    func test_links() {
        assertSection("Links", passesAtLeast: 77)
    }

    // --- Images (22 examples) ---
    // Full compliance: inline images with alt text, titles, reference images.
    func test_images() {
        assertSection("Images", passesAtLeast: 22)
    }

    // --- Autolinks (19 examples) ---
    // Near-complete: URI schemes with +/- chars, email autolinks.
    // Remaining: one edge case with rawHTML false positive.
    func test_autolinks() {
        assertSection("Autolinks", passesAtLeast: 18)
    }

    // --- Raw HTML (20 examples) ---
    // Near-complete: proper attribute validation, multiline tags.
    // Remaining: one multiline comment edge case.
    func test_rawHTML() {
        assertSection("Raw HTML", passesAtLeast: 19)
    }

    // MARK: - Other sections

    // --- Tabs (11 examples) ---
    // Minimal tab handling support.
    func test_tabs() {
        assertSection("Tabs", passesAtLeast: 2)
    }

    // --- Backslash Escapes (13 examples) ---
    // Partially handled by our inline parser.
    func test_backslashEscapes() {
        assertSection("Backslash escapes", passesAtLeast: 10)
    }

    // --- Entity and Numeric Character References (17 examples) ---
    // Entity parsing is too permissive: we match any &word; as an entity,
    // but CommonMark requires a fixed list of valid HTML5 entity names.
    // Also, we don't decode entities to Unicode — we pass them verbatim.
    func test_entityReferences() {
        assertSection("Entity and numeric character references", passesAtLeast: 16)
    }

    // --- Precedence (1 example) ---
    // Block-level precedence (e.g., list vs. thematic break).
    func test_precedence() {
        assertSection("Precedence", passesAtLeast: 1)
    }

    // --- Inlines (1 example) ---
    func test_inlines() {
        assertSection("Inlines", passesAtLeast: 1)
    }

    // --- Hard Line Breaks (15 examples) ---
    // Partially supported (trailing spaces, trailing backslash).
    func test_hardLineBreaks() {
        assertSection("Hard line breaks", passesAtLeast: 15)
    }

    // --- Soft Line Breaks (2 examples) ---
    func test_softLineBreaks() {
        assertSection("Soft line breaks", passesAtLeast: 2)
    }

    // --- Textual Content (3 examples) ---
    func test_textualContent() {
        assertSection("Textual content", passesAtLeast: 3)
    }
}
