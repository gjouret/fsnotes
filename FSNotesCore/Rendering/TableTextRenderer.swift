//
//  TableTextRenderer.swift
//  FSNotesCore
//
//  Renders a `Block.table` as a single attachment character that hosts
//  the subview-backed table editor.
//
//  ARCHITECTURAL CONTRACT:
//  - Input: header cells, data rows, alignments, raw markdown, body font.
//  - Output: NSAttributedString containing one `U+FFFC`
//    TableAttachment. The attachment carries the authoritative
//    Block.table payload and hosts searchable/editable cell subviews.
//  - Pure function: same input → equal output.
//

import Foundation
#if os(OSX)
import AppKit
#else
import UIKit
#endif

// MARK: - Renderer

public enum TableTextRenderer {

    /// Emits a single-character attributed string (U+FFFC) carrying
    /// a `TableAttachment` that
    /// holds the authoritative `Block.table` payload. The TK2 view
    /// provider on the attachment vends a `TableContainerView` which
    /// paints the cells and (Phase C) hosts per-cell `TableCellTextView`
    /// subviews for editing.
    ///
    #if os(OSX)
    public static func renderAsAttachment(block: Block) -> NSAttributedString {
        guard case .table = block else { return NSAttributedString() }
        let attachment = TableAttachment(block: block)
        let rendered = NSMutableAttributedString(
            attributedString: NSAttributedString(attachment: attachment)
        )
        let range = NSRange(location: 0, length: rendered.length)
        rendered.addAttribute(
            .renderedBlockType,
            value: RenderedBlockType.table.rawValue,
            range: range
        )
        rendered.addAttribute(
            .renderedBlockOriginalMarkdown,
            value: MarkdownSerializer.serializeBlock(block),
            range: range
        )
        return rendered
    }
    #endif

    /// Render a table to an attributed string.
    ///
    /// Emits the subview-backed attachment form on macOS.
    public static func render(
        header: [TableCell],
        rows: [[TableCell]],
        alignments: [TableAlignment],
        rawMarkdown: String,
        bodyFont: PlatformFont,
        columnWidths: [CGFloat]? = nil
    ) -> NSAttributedString {
        #if os(OSX)
        let block: Block = .table(
            header: header,
            alignments: alignments,
            rows: rows,
            columnWidths: columnWidths
        )
        return renderAsAttachment(block: block)
        #else
        // iOS currently has no native-element TK2 path. Return an empty
        // attributed string; iOS rendering is handled by the preview
        // pipeline, not by this function.
        return NSAttributedString()
        #endif
    }
}
