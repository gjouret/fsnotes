//
//  BlockquoteRenderer.swift
//  FSNotesCore
//
//  Renders a Block.blockquote into an NSAttributedString.
//
//  ARCHITECTURAL CONTRACT:
//  - Input: [BlockquoteLine] + body font.
//  - Output: newline-separated lines where each line has:
//    (a) .blockquote attribute = nesting depth (consumed by BlockquoteLayoutFragment bar drawing)
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

    /// Compute the left indentation needed to clear the vertical bars
    /// drawn by `BlockquoteLayoutFragment` for a given nesting depth.
    /// (The legacy TK1 `BlockquoteBorderDrawer` was deleted in Batch
    /// N+7; the geometry contract below is what the TK2 fragment reads.)
    ///
    /// Phase 7.3: bar geometry reads from `theme.chrome.*` (same fields
    /// consumed by `BlockquoteLayoutFragment`). Default-theme values
    /// match the pre-theme hardcoded constants byte-for-byte, so
    /// `theme: .shared` is a visual no-op. `blockquoteGapAfterBars` is
    /// a flat field on `BlockStyleTheme` (not migrated to nested chrome
    /// in 7.1) — consumed directly here.
    private static func leftIndent(for level: Int, theme: Theme) -> CGFloat {
        guard level > 0 else { return 0 }
        // Bars are drawn at: baseX + i*barSpacing, for i in 0..<level.
        // Rightmost bar right edge = barInitialOffset + (level-1)*barSpacing + barWidth.
        // Add a gap so text doesn't touch the last bar.
        let barInitialOffset = theme.chrome.blockquoteBarInitialOffset
        let barSpacing = theme.chrome.blockquoteBarSpacing
        let barWidth = theme.chrome.blockquoteBarWidth
        let gapAfterBars = theme.blockquoteGapAfterBars
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

            // Tag the rendered line with .blockquote = nesting depth so
            // `BlockquoteLayoutFragment` draws the vertical bars. Also
            // set a paragraph style with left indentation to clear them.
            if lineEnd > lineStart {
                let lineRange = NSRange(location: lineStart, length: lineEnd - lineStart)
                out.addAttribute(.blockquote, value: qLine.level, range: lineRange)

                let indent = leftIndent(for: qLine.level, theme: theme)
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
