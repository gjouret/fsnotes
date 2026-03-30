//
//  BlockquoteBorderDrawer.swift
//  FSNotes
//
//  Draws nested gray bars for blockquotes. Depth stored as Int in .blockquote attribute.
//

import Cocoa

struct BlockquoteBorderDrawer: AttributeDrawer {
    let attributeKey: NSAttributedString.Key = .blockquote

    func draw(value: Any, rect: NSRect, context: CGContext,
              origin: CGPoint, textContainer: NSTextContainer) {
        let depth: Int
        if let intVal = value as? Int { depth = intVal }
        else if value is Bool { depth = 1 }
        else { return }

        let baseX = origin.x + textContainer.lineFragmentPadding + 2
        let barSpacing: CGFloat = 10

        // MPreview CSS: border-left 4px solid #ddd
        context.setFillColor(NSColor(red: 0.867, green: 0.867, blue: 0.867, alpha: 1.0).cgColor)
        for i in 0..<depth {
            context.fill(CGRect(x: baseX + CGFloat(i) * barSpacing,
                                y: rect.minY + origin.y, width: 4, height: rect.height))
        }
    }
}
