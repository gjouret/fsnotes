//
//  ParagraphLayoutFragment.swift
//  FSNotesCore
//
//  Bug #51 — minimal NSTextLayoutFragment subclass for plain paragraphs
//  and list items. Exists solely to host the inline-code chrome paint
//  pass: BlockModelLayoutManagerDelegate dispatches `ParagraphElement`
//  and `ListItemElement` to this subclass instead of the default
//  `NSTextLayoutFragment` so any `.inlineCodeRange` runs in those
//  paragraphs get the rounded-rect chrome behind them.
//
//  All other plain-paragraph behaviour is inherited unchanged from
//  `NSTextLayoutFragment.draw` — there is no extra chrome on plain
//  paragraphs themselves.
//

import AppKit

public final class ParagraphLayoutFragment: NSTextLayoutFragment {

    public override func draw(at point: CGPoint, in context: CGContext) {
        InlineCodeChromeDrawer.paint(in: self, at: point, context: context)
        super.draw(at: point, in: context)
    }
}
