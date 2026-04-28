//
//  SubviewTableRenderTests.swift
//  FSNotesTests
//
//  Phase 8 / Subview Tables — A4. Verifies the read-only render
//  pipeline up to and including the view provider:
//
//    1. `TableTextRenderer.renderAsAttachment(block:)` emits a single
//       U+FFFC character carrying a `TableAttachment` whose `block`
//       payload equals the input.
//    2. The attachment's `viewProvider(...)` returns a
//       `TableAttachmentViewProvider` that, after `loadView()`,
//       holds a `TableContainerView`.
//    3. `TableContainerView.totalHeight` matches
//       `handleBarHeight + TableGeometry.compute(...).totalHeight`
//       for the same input — i.e. the provider's `attachmentBounds`
//       sizes the attachment to the same height the native-cell
//       fragment would have used.
//
//  These tests run without an `EditTextView`; they exercise the
//  pure-attachment+provider+container path in isolation. Editing
//  semantics (Phase C) and find aggregation (Phase D) get their own
//  test files.
//

import XCTest
import AppKit
@testable import FSNotes

final class SubviewTableRenderTests: XCTestCase {

    private func cell(_ s: String) -> TableCell { TableCell.parsing(s) }
    private func cells(_ s: [String]) -> [TableCell] { s.map { cell($0) } }

    private func sample2x2Block() -> Block {
        return Block.table(
            header: cells(["A", "B"]),
            alignments: [.none, .none],
            rows: [cells(["a0", "b0"]), cells(["a1", "b1"])],
            columnWidths: nil
        )
    }

    // MARK: - 1. renderAsAttachment shape

    func test_renderAsAttachment_emitsSingleAttachmentChar() {
        let block = sample2x2Block()
        let attr = TableTextRenderer.renderAsAttachment(block: block)

        XCTAssertEqual(attr.length, 1, "expected a single attachment glyph")

        let nsString = attr.string as NSString
        let ch = nsString.character(at: 0)
        XCTAssertEqual(
            ch, 0xFFFC,
            "expected U+FFFC OBJECT REPLACEMENT CHARACTER"
        )

        let attachment = attr.attribute(
            .attachment, at: 0, effectiveRange: nil
        ) as? TableAttachment
        XCTAssertNotNil(
            attachment,
            "U+FFFC must carry a `.attachment` of type TableAttachment"
        )
    }

    func test_renderAsAttachment_carriesBlockPayload() {
        let block = sample2x2Block()
        let attr = TableTextRenderer.renderAsAttachment(block: block)
        guard let attachment = attr.attribute(
            .attachment, at: 0, effectiveRange: nil
        ) as? TableAttachment else {
            XCTFail("missing TableAttachment"); return
        }

        // Verify the carried block is the input — same shape, same
        // cell count.
        guard case .table(
            let header, _, let rows, _
        ) = attachment.block else {
            XCTFail("attachment.block is not .table"); return
        }
        XCTAssertEqual(header.map { $0.rawText }, ["A", "B"])
        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(rows[0].map { $0.rawText }, ["a0", "b0"])
        XCTAssertEqual(rows[1].map { $0.rawText }, ["a1", "b1"])
    }

    // MARK: - 2. View provider lifecycles a TableContainerView

    func test_attachment_viewProvider_returnsContainerView() {
        let block = sample2x2Block()
        let attachment = TableAttachment(block: block)

        // Provide a minimal text container; TK2 normally provides one
        // when laying out the attachment in a real document.
        let container = NSTextContainer(
            size: CGSize(width: 600, height: 1e6)
        )
        let tlm = NSTextLayoutManager()
        tlm.textContainer = container
        let cs = NSTextContentStorage()
        cs.addTextLayoutManager(tlm)
        cs.textStorage = NSTextStorage(
            attributedString: NSAttributedString(attachment: attachment)
        )

        guard let provider = attachment.viewProvider(
            for: nil,
            location: cs.documentRange.location,
            textContainer: container
        ) else {
            XCTFail("viewProvider returned nil"); return
        }
        XCTAssertTrue(
            provider is TableAttachmentViewProvider,
            "expected TableAttachmentViewProvider"
        )
        provider.loadView()
        XCTAssertNotNil(provider.view, "provider.view nil after loadView")
        XCTAssertTrue(
            provider.view is TableContainerView,
            "provider.view should be a TableContainerView"
        )
    }

    // MARK: - 3. attachmentBounds height matches native-cell geometry

    func test_attachmentBounds_matchesTableGeometryHeight() {
        let block = sample2x2Block()
        let attachment = TableAttachment(block: block)

        // Wire a real layout manager + content storage so the
        // provider has a non-nil text container width to read.
        let container = NSTextContainer(
            size: CGSize(width: 600, height: 1e6)
        )
        let tlm = NSTextLayoutManager()
        tlm.textContainer = container
        let cs = NSTextContentStorage()
        cs.addTextLayoutManager(tlm)
        cs.textStorage = NSTextStorage(
            attributedString: NSAttributedString(attachment: attachment)
        )
        let docStart = cs.documentRange.location

        guard let provider = attachment.viewProvider(
            for: nil, location: docStart, textContainer: container
        ) as? TableAttachmentViewProvider else {
            XCTFail("provider"); return
        }
        provider.loadView()

        let bounds = provider.attachmentBounds(
            for: [:],
            location: docStart,
            textContainer: container,
            proposedLineFragment: CGRect(x: 0, y: 0, width: 600, height: 17),
            position: .zero
        )

        // Expected height: handleBarHeight + TableGeometry.compute height.
        guard case .table(let header, let alignments, let rows, _) = block
        else { XCTFail("not a table"); return }
        let g = TableGeometry.compute(
            header: header,
            rows: rows,
            alignments: alignments,
            containerWidth: 600,
            font: UserDefaultsManagement.noteFont,
            columnWidthsOverride: nil
        )
        let expectedHeight = TableGeometry.handleBarHeight + g.totalHeight
        XCTAssertEqual(
            bounds.height, expectedHeight,
            accuracy: 1.0,
            "attachmentBounds height should match TableGeometry total + handleBar"
        )
        XCTAssertEqual(
            bounds.width, 600,
            accuracy: 1.0,
            "attachmentBounds width should equal text container width"
        )
    }
}
