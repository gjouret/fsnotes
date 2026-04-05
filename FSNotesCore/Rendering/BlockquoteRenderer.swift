//
//  BlockquoteRenderer.swift
//  FSNotesCore
//
//  Renders a Block.blockquote into an NSAttributedString.
//
//  ARCHITECTURAL CONTRACT:
//  - Input: [BlockquoteLine] + body font.
//  - Output: newline-separated lines where each line is visually
//    indented by its nesting level — source `>` markers are
//    CONSUMED by the parser and NEVER reach the rendered output.
//  - Zero `.kern`. Zero clear-color foreground. Idempotent.
//
//  Tracer-bullet rendering: emit TWO spaces of visual indent per
//  `>` level. A future LayoutManager phase will draw a vertical
//  quote bar in the gutter; for the architecture tracer, the
//  invariant is "source `>` markers never appear in rendered output".
//

import Foundation
#if os(OSX)
import AppKit
#else
import UIKit
#endif

public enum BlockquoteRenderer {

    /// Visual indentation (space characters) per `>` level.
    private static let indentPerLevel = 2

    public static func render(
        lines: [BlockquoteLine],
        bodyFont: PlatformFont
    ) -> NSAttributedString {
        let attrs: [NSAttributedString.Key: Any] = [
            .font: bodyFont,
            .foregroundColor: PlatformColor.label
        ]
        let out = NSMutableAttributedString()
        for (idx, qLine) in lines.enumerated() {
            let indent = String(repeating: " ", count: qLine.level * indentPerLevel)
            out.append(NSAttributedString(string: indent, attributes: attrs))
            out.append(InlineRenderer.render(qLine.inline, baseAttributes: attrs))
            if idx < lines.count - 1 {
                out.append(NSAttributedString(string: "\n", attributes: attrs))
            }
        }
        return out
    }
}
