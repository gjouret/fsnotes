//
//  ParagraphRenderer.swift
//  FSNotesCore
//
//  Renders a Block.paragraph into an NSAttributedString.
//
//  ARCHITECTURAL CONTRACT:
//  - Input: the paragraph's [Inline] tree.
//  - Output: NSAttributedString built from the inline tree. Zero
//    markdown markers (`**`, `*`) — they are consumed by the parser
//    and represented by Inline.bold / Inline.italic. Zero `.kern`.
//    Zero clear-color foreground.
//  - Pure function: same input → byte-equal output.
//

import Foundation
#if os(OSX)
import AppKit
#else
import UIKit
#endif

public enum ParagraphRenderer {

    /// Render a paragraph's inline tree with the given body font.
    public static func render(
        inline: [Inline],
        bodyFont: PlatformFont
    ) -> NSAttributedString {
        let attrs: [NSAttributedString.Key: Any] = [
            .font: bodyFont,
            .foregroundColor: PlatformColor.label
        ]
        return InlineRenderer.render(inline, baseAttributes: attrs)
    }
}
