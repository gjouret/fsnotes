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
//       sizes the attachment to the same height the shared table
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

    private func rightMouseEvent(at point: NSPoint) -> NSEvent {
        return NSEvent.mouseEvent(
            with: .rightMouseDown,
            location: point,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            eventNumber: 0,
            clickCount: 1,
            pressure: 1
        )!
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

    func test_renderAsAttachment_tagsTableMetadata() {
        let block = sample2x2Block()
        let attr = TableTextRenderer.renderAsAttachment(block: block)

        XCTAssertEqual(
            attr.attribute(.renderedBlockType, at: 0, effectiveRange: nil)
                as? String,
            RenderedBlockType.table.rawValue
        )
        XCTAssertEqual(
            attr.attribute(
                .renderedBlockOriginalMarkdown,
                at: 0,
                effectiveRange: nil
            ) as? String,
            MarkdownSerializer.serializeBlock(block)
        )
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

    // MARK: - 3. attachmentBounds height matches shared table geometry

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

    func test_attachmentBounds_usesWiderProposedLineFragmentWhenContainerWidthIsStale() {
        let block = sample2x2Block()
        let attachment = TableAttachment(block: block)

        // Reproduce first-render timing: the text container can still
        // carry the default 600pt width while TK2 proposes the actual
        // full line fragment for the table. The attachment must take
        // the wider proposed width immediately, not wait for a later
        // focus/layout pass to resize.
        let staleContainer = NSTextContainer(
            size: CGSize(width: 600, height: 1e6)
        )
        let tlm = NSTextLayoutManager()
        tlm.textContainer = staleContainer
        let cs = NSTextContentStorage()
        cs.addTextLayoutManager(tlm)
        cs.textStorage = NSTextStorage(
            attributedString: NSAttributedString(attachment: attachment)
        )
        let docStart = cs.documentRange.location

        guard let provider = attachment.viewProvider(
            for: nil, location: docStart, textContainer: staleContainer
        ) as? TableAttachmentViewProvider else {
            XCTFail("provider"); return
        }
        provider.loadView()

        let bounds = provider.attachmentBounds(
            for: [:],
            location: docStart,
            textContainer: staleContainer,
            proposedLineFragment: CGRect(x: 0, y: 0, width: 800, height: 17),
            position: .zero
        )

        XCTAssertEqual(bounds.width, 800, accuracy: 0.1)
        XCTAssertEqual(attachment.bounds.width, 800, accuracy: 0.1)
        XCTAssertEqual(provider.view?.frame.width ?? 0, 800, accuracy: 0.1)
    }

    func test_containerShowsRowAndColumnHandlesForHoveredCell() {
        let block = sample2x2Block()
        let container = TableContainerView(block: block, containerWidth: 600)

        XCTAssertNil(
            container.debugVisibleHandleRects(),
            "handles should be hidden before hover or focus"
        )

        container.debugSetHandleHover(row: 2, col: 1)

        guard let rects = container.debugVisibleHandleRects(),
              let column = rects.column,
              let row = rects.row,
              case .table(let header, let alignments, let rows, _) = block
        else {
            return XCTFail("hovered cell should expose both row and column handles")
        }

        let g = TableGeometry.compute(
            header: header,
            rows: rows,
            alignments: alignments,
            containerWidth: 600,
            font: UserDefaultsManagement.noteFont,
            columnWidthsOverride: nil
        )

        XCTAssertEqual(column.minY, 0, accuracy: 0.1)
        XCTAssertEqual(column.height, TableGeometry.handleBarHeight, accuracy: 0.1)
        XCTAssertEqual(
            column.minX,
            TableGeometry.handleBarWidth + g.columnWidths[0],
            accuracy: 0.1
        )
        XCTAssertEqual(column.width, g.columnWidths[1], accuracy: 0.1)

        XCTAssertEqual(row.minX, 0, accuracy: 0.1)
        XCTAssertEqual(row.width, TableGeometry.handleBarWidth, accuracy: 0.1)
        XCTAssertEqual(
            row.minY,
            TableGeometry.handleBarHeight + g.rowHeights[0] + g.rowHeights[1],
            accuracy: 0.1
        )
        XCTAssertEqual(row.height, g.rowHeights[2], accuracy: 0.1)
    }

    func test_containerShowsHandlesForFocusedCellAndTracksGeometryUpdates() {
        let initial = sample2x2Block()
        let container = TableContainerView(block: initial, containerWidth: 600)
        container.debugSetHandleFocus(row: 1, col: 0)

        guard let initialRow = container.debugVisibleHandleRects()?.row else {
            return XCTFail("focused cell should show a row handle")
        }

        let taller = Block.table(
            header: cells(["A", "B"]),
            alignments: [.none, .none],
            rows: [
                [
                    TableCell([
                        .text("first line"),
                        .rawHTML("<br>"),
                        .text("second line"),
                        .rawHTML("<br>"),
                        .text("third line")
                    ]),
                    cell("b0")
                ],
                cells(["a1", "b1"])
            ],
            columnWidths: nil
        )
        container.refreshCellContents(newBlock: taller)

        guard let updatedRow = container.debugVisibleHandleRects()?.row,
              case .table(let header, let alignments, let rows, _) = taller
        else {
            return XCTFail("focused handle should survive in-place table refresh")
        }

        let g = TableGeometry.compute(
            header: header,
            rows: rows,
            alignments: alignments,
            containerWidth: 600,
            font: UserDefaultsManagement.noteFont,
            columnWidthsOverride: nil
        )

        XCTAssertGreaterThan(updatedRow.height, initialRow.height)
        XCTAssertEqual(updatedRow.height, g.rowHeights[1], accuracy: 0.1)
    }

    func test_columnHandleContextMenuOffersClearColumn() {
        let block = sample2x2Block()
        let container = TableContainerView(block: block, containerWidth: 600)
        guard case .table(let header, let alignments, let rows, _) = block else {
            return XCTFail("fixture must be a table")
        }
        let g = TableGeometry.compute(
            header: header,
            rows: rows,
            alignments: alignments,
            containerWidth: 600,
            font: UserDefaultsManagement.noteFont,
            columnWidthsOverride: nil
        )
        let point = NSPoint(
            x: TableGeometry.handleBarWidth + g.columnWidths[0] + 1,
            y: 1
        )

        guard let menu = container.menu(
            for: rightMouseEvent(at: container.convert(point, to: nil))
        ),
              let item = menu.items.first(where: { $0.title == "Clear Column" })
        else {
            return XCTFail("column handle should provide a context menu")
        }

        XCTAssertEqual(item.title, "Clear Column")
        var captured: TableContainerView.ClearTarget?
        container.onClearCells = { captured = $0 }
        guard let action = item.action,
              let target = item.target as AnyObject?
        else {
            return XCTFail("Clear Column item should have an action")
        }
        _ = target.perform(action, with: item)
        XCTAssertEqual(captured, .column(1))
    }

    func test_columnHandleSortMenuTogglesDirection() {
        let block = sample2x2Block()
        let container = TableContainerView(block: block, containerWidth: 600)
        guard case .table(let header, let alignments, let rows, _) = block else {
            return XCTFail("fixture must be a table")
        }
        let g = TableGeometry.compute(
            header: header,
            rows: rows,
            alignments: alignments,
            containerWidth: 600,
            font: UserDefaultsManagement.noteFont,
            columnWidthsOverride: nil
        )
        let point = NSPoint(
            x: TableGeometry.handleBarWidth + g.columnWidths[0] + 1,
            y: 1
        )
        let event = rightMouseEvent(at: container.convert(point, to: nil))

        guard let firstMenu = container.menu(for: event),
              let firstSort = firstMenu.items.first(where: {
                  $0.title == "Sort Ascending"
              }),
              let firstAction = firstSort.action,
              let firstTarget = firstSort.target as AnyObject?
        else {
            return XCTFail("column handle should offer Sort Ascending")
        }

        var calls: [(Int, Bool)] = []
        container.onSortColumn = { calls.append(($0, $1)) }
        _ = firstTarget.perform(firstAction, with: firstSort)
        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(calls[0].0, 1)
        XCTAssertEqual(calls[0].1, true)
        XCTAssertEqual(
            container.debugSortIndicator(),
            TableContainerView.DebugSortIndicator(column: 1, ascending: true)
        )

        guard let secondMenu = container.menu(for: event),
              let secondSort = secondMenu.items.first(where: {
                  $0.title == "Sort Descending"
              }),
              let secondAction = secondSort.action,
              let secondTarget = secondSort.target as AnyObject?
        else {
            return XCTFail("second click should offer Sort Descending")
        }
        _ = secondTarget.perform(secondAction, with: secondSort)
        XCTAssertEqual(calls.count, 2)
        XCTAssertEqual(calls[1].0, 1)
        XCTAssertEqual(calls[1].1, false)
        XCTAssertEqual(
            container.debugSortIndicator(),
            TableContainerView.DebugSortIndicator(column: 1, ascending: false)
        )
    }

    func test_rowHandleContextMenuOffersClearRow() {
        let block = sample2x2Block()
        let container = TableContainerView(block: block, containerWidth: 600)
        guard case .table(let header, let alignments, let rows, _) = block else {
            return XCTFail("fixture must be a table")
        }
        let g = TableGeometry.compute(
            header: header,
            rows: rows,
            alignments: alignments,
            containerWidth: 600,
            font: UserDefaultsManagement.noteFont,
            columnWidthsOverride: nil
        )
        let point = NSPoint(
            x: 1,
            y: TableGeometry.handleBarHeight + g.rowHeights[0] + 1
        )

        guard let menu = container.menu(
            for: rightMouseEvent(at: container.convert(point, to: nil))
        ),
              let item = menu.items.first
        else {
            return XCTFail("row handle should provide a context menu")
        }

        XCTAssertEqual(item.title, "Clear Row")
        var captured: TableContainerView.ClearTarget?
        container.onClearCells = { captured = $0 }
        guard let action = item.action,
              let target = item.target as AnyObject?
        else {
            return XCTFail("Clear Row item should have an action")
        }
        _ = target.perform(action, with: item)
        XCTAssertEqual(captured, .row(1))
    }
}
