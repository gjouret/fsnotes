//
//  PDFExporterMeasurementTests.swift
//  FSNotesTests
//
//  Phase 2f.6 — PDF export used-rect measurement under TK2.
//
//  The PDF exporter previously relied on
//  `NSLayoutManager.usedRect(for:)` to size the output PDF. Under TK2
//  the TK1 layout manager is dormant, so that path returns `.zero` and
//  the exporter falls back to a fixed letter-sized rect. That's wrong
//  for any note longer than one page: content past the first ~842pt
//  gets clipped out of the PDF.
//
//  These tests prove that `PDFExporter.measureUsedRect` returns a
//  non-trivial height for a multi-line note whose editor is on TK2.
//

import XCTest
import AppKit
@testable import FSNotes

final class PDFExporterMeasurementTests: XCTestCase {

    /// Contract: under TK2 the used-rect helper returns a non-zero
    /// height and width for a multi-line note. If this fails, the
    /// exporter is still on the TK1-only path and any note longer than
    /// a page will be clipped in the exported PDF.
    func test_phase2f6_pdfExporterUsedRect_nonZeroUnderTK2() {
        // A multi-paragraph note large enough that the used rect must
        // exceed the "blank note" fallback in any sane layout.
        var lines: [String] = []
        for idx in 0..<30 {
            lines.append("Paragraph number \(idx) with enough text to occupy at least one full line in the editor's text container so that wrapping does not collapse the measured height to a trivial value.")
        }
        let markdown = lines.joined(separator: "\n\n")

        let harness = EditorHarness(markdown: markdown)
        defer { harness.teardown() }

        // Phase-2a precondition: the editor must actually be on TK2,
        // otherwise this test silently exercises the TK1 branch and
        // proves nothing about the TK2 migration.
        XCTAssertNotNil(
            harness.editor.textLayoutManager,
            "TK2 precondition: editor.textLayoutManager must be non-nil" +
            " for this test to exercise the TK2 used-rect path."
        )
        // Phase 4.5: `layoutManagerIfTK1` property deleted. The TK1
        // branch of `measureUsedRect` is gone, so being on TK2 is
        // guaranteed by construction — no TK1 accessor to assert
        // against.

        guard let container = harness.editor.textContainer else {
            return XCTFail("editor has no textContainer")
        }

        let rect = PDFExporter.measureUsedRect(
            textView: harness.editor,
            textContainer: container
        )

        XCTAssertGreaterThan(
            rect.height, 50,
            "Phase 2f.6: TK2 used-rect height must exceed 50pt for a" +
            " 30-paragraph note. Got \(rect.height). If zero, the TK2" +
            " branch in measureUsedRect is not populating." +
            " If small (<50pt), only one fragment was measured — check" +
            " the fragment enumeration is walking the full document."
        )
        XCTAssertGreaterThan(
            rect.width, 0,
            "Phase 2f.6: TK2 used-rect width must be positive. Got" +
            " \(rect.width). A zero width means" +
            " `usageBoundsForTextContainer` returned empty *and* the" +
            " fragment union fell through empty — layout never ran."
        )
    }

    /// A blank document must still return an empty-but-safe rect (zero
    /// size is acceptable — the exporter falls back to letter-size).
    /// This guards against the TK2 branch crashing on an empty doc.
    func test_phase2f6_pdfExporterUsedRect_emptyDocReturnsEmptyRect() {
        let harness = EditorHarness(markdown: "")
        defer { harness.teardown() }

        guard let container = harness.editor.textContainer else {
            return XCTFail("editor has no textContainer")
        }

        let rect = PDFExporter.measureUsedRect(
            textView: harness.editor,
            textContainer: container
        )

        // Empty doc may have a zero-height rect or a single-line-height
        // rect depending on how the layout manager handles the trailing
        // empty paragraph. Either is fine — the contract is "doesn't
        // crash, doesn't return garbage".
        XCTAssertGreaterThanOrEqual(rect.height, 0)
        XCTAssertGreaterThanOrEqual(rect.width, 0)
    }
}
