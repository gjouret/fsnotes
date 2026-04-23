//
//  BlockquoteRenderer.swift
//  FSNotesCore
//
//  Renders a Block.blockquote into an NSAttributedString.
//
//  ARCHITECTURAL CONTRACT:
//  - Input: [BlockquoteLine] + body font.
//  - Output: newline-separated lines where each line has:
//    (a) .blockquote attribute = nesting depth (for LayoutManager bar drawing)
//    (b) .paragraphStyle with left indentation to clear the vertical bars
//    Source `>` markers are CONSUMED by the parser and NEVER
//    reach the rendered output.
//  - Zero `.kern`. Zero clear-color foreground. Idempotent.
//

import Foundation
#if os(OSX)
import AppKit
#else
import UIKit
#endif

public enum BlockquoteRenderer {

    /// Must match BlockquoteBorderDrawer's barSpacing (10pt per bar).
    /// Offset = initial padding (2pt before first bar) + depth * barSpacing + gap after last bar.
    private static let barInitialOffset: CGFloat = 2
    private static let barSpacing: CGFloat = 10
    private static let barWidth: CGFloat = 4
    private static let gapAfterBars: CGFloat = 4

    /// Compute the left indentation needed to clear the vertical bars
    /// drawn by BlockquoteBorderDrawer for a given nesting depth.
    private static func leftIndent(for level: Int) -> CGFloat {
        // Bars are drawn at: baseX + i*barSpacing, for i in 0..<level.
        // Rightmost bar right edge = barInitialOffset + (level-1)*barSpacing + barWidth.
        // Add a gap so text doesn't touch the last bar.
        guard level > 0 else { return 0 }
        return barInitialOffset + CGFloat(level - 1) * barSpacing + barWidth + gapAfterBars
    }

    public static func render(
        lines: [BlockquoteLine],
        bodyFont: PlatformFont,
        note: Note? = nil,
        theme: Theme = .shared
    ) -> NSAttributedString {
        let attrs: [NSAttributedString.Key: Any] = [
            .font: bodyFont,
            .foregroundColor: PlatformColor.label
        ]
        let lineSpacing = CGFloat(UserDefaultsManagement.editorLineSpacing)
        let out = NSMutableAttributedString()
        for (idx, qLine) in lines.enumerated() {
            let lineStart = out.length
            out.append(InlineRenderer.render(qLine.inline, baseAttributes: attrs, note: note, theme: theme))
            let lineEnd = out.length

            // Tag the rendered line with .blockquote = nesting depth so that
            // BlockquoteBorderDrawer in LayoutManager draws the vertical bars.
            // Also set a paragraph style with left indentation to clear the bars.
            if lineEnd > lineStart {
                let lineRange = NSRange(location: lineStart, length: lineEnd - lineStart)
                out.addAttribute(.blockquote, value: qLine.level, range: lineRange)

                let indent = leftIndent(for: qLine.level)
                let paraStyle = NSMutableParagraphStyle()
                paraStyle.headIndent = indent
                paraStyle.firstLineHeadIndent = indent
                paraStyle.lineSpacing = lineSpacing
                out.addAttribute(.paragraphStyle, value: paraStyle, range: lineRange)
            }

            if idx < lines.count - 1 {
                out.append(NSAttributedString(string: "\n", attributes: attrs))
            }
        }
        return out
    }
}
