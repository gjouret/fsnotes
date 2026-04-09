//
//  TableTextRenderer.swift
//  FSNotesCore
//
//  Renders a Block.table as a single NSTextAttachment character.
//
//  ARCHITECTURAL CONTRACT:
//  - Input: header cells, data rows, raw markdown, body font.
//  - Output: NSAttributedString containing ONE attachment character
//    (TableBlockAttachment). The attachment stores the parsed table
//    data and raw markdown so the app-level code can configure the
//    visual cell (InlineTableView widget) without re-parsing.
//  - Single character output means block spans stay valid — no
//    multi-line text that must be replaced by a post-pass.
//  - Pure function: same input → equal output.
//

import Foundation
#if os(OSX)
import AppKit
#else
import UIKit
#endif

// MARK: - Table Block Attachment

/// NSTextAttachment subclass that carries the parsed table data.
/// The block-model renderer emits this as a single attachment character.
/// The app target configures the visual cell (InlineTableAttachmentCell)
/// after fill — DocumentRenderer (in FSNotesCore) can't reference
/// InlineTableView (in the app target).
public class TableBlockAttachment: NSTextAttachment {
    public let header: [String]
    public let rows: [[String]]
    public let alignments: [TableAlignment]
    public let rawMarkdown: String

    public init(header: [String], rows: [[String]], alignments: [TableAlignment], rawMarkdown: String) {
        self.header = header
        self.rows = rows
        self.alignments = alignments
        self.rawMarkdown = rawMarkdown
        super.init(data: nil, ofType: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) not supported")
    }

    public override func isEqual(_ object: Any?) -> Bool {
        guard let other = object as? TableBlockAttachment else { return false }
        return header == other.header && rows == other.rows
    }

    public override var hash: Int {
        var h = Hasher()
        h.combine(header)
        h.combine(rows)
        return h.finalize()
    }
}

// MARK: - Renderer

public enum TableTextRenderer {

    /// Render a table as a single attachment character.
    /// The attachment stores the parsed data; the app target
    /// configures the visual cell after fillViaBlockModel.
    public static func render(
        header: [String],
        rows: [[String]],
        alignments: [TableAlignment],
        rawMarkdown: String,
        bodyFont: PlatformFont
    ) -> NSAttributedString {
        let attachment = TableBlockAttachment(
            header: header,
            rows: rows,
            alignments: alignments,
            rawMarkdown: rawMarkdown
        )
        // Placeholder bounds — the app target resizes after configuring
        // the InlineTableView cell. Use a reasonable default so the
        // attachment character occupies space.
        attachment.bounds = CGRect(x: 0, y: 0, width: 400, height: 100)

        let result = NSMutableAttributedString(attachment: attachment)
        result.addAttribute(.font, value: bodyFont,
                            range: NSRange(location: 0, length: result.length))
        return result
    }
}
