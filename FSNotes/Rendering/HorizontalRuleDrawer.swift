//
//  HorizontalRuleDrawer.swift
//  FSNotes
//
//  Draws a 4px gray line for horizontal rules (---).
//  Uses lineFragmentRect instead of boundingRect (kern-collapsed text has empty bounds).
//

import Cocoa

struct HorizontalRuleDrawer: AttributeDrawer {
    let attributeKey: NSAttributedString.Key = .horizontalRule

    func draw(value: Any, rect: NSRect, context: CGContext,
              origin: CGPoint, textContainer: NSTextContainer) {
        // For HR, we need lineFragmentRect — boundingRect is empty after kern collapse.
        // The shared dispatcher passes boundingRect. For HR, we'll use the rect.midY
        // as a best-effort vertical center (the range always spans exactly one line).
        let containerWidth = textContainer.size.width
        let padding = textContainer.lineFragmentPadding
        let lineY = rect.midY + origin.y

        // The HR should span from the left padding to the right margin.
        // origin.x is the text container origin; the line starts at
        // origin.x + padding and the right edge is origin.x + containerWidth - padding.
        let startX = origin.x + padding
        let ruleWidth = containerWidth - padding * 2

        // Horizontal rule fill and thickness used by the editor renderer.
        context.setFillColor(NSColor(red: 0.906, green: 0.906, blue: 0.906, alpha: 1.0).cgColor)
        context.fill(CGRect(x: startX, y: lineY - 2, width: ruleWidth, height: 4))
    }
}
