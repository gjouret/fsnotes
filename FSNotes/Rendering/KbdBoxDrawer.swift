//
//  KbdBoxDrawer.swift
//  FSNotes
//
//  Draws a rounded keyboard-key box with shadow for <kbd> tags.
//  Matches MPreview CSS: #fcfcfc bg, #ccc border, #bbb bottom shadow, 3px radius.
//

import Cocoa

struct KbdBoxDrawer: AttributeDrawer {
    let attributeKey: NSAttributedString.Key = .kbdTag

    func draw(value: Any, rect: NSRect, context: CGContext,
              origin: CGPoint, textContainer: NSTextContainer) {
        let kbdRect = CGRect(x: rect.minX + origin.x - 2, y: rect.minY + origin.y - 1,
                             width: rect.width + 4, height: rect.height + 2)
        let cornerRadius: CGFloat = 3
        let path = CGPath(roundedRect: kbdRect, cornerWidth: cornerRadius,
                          cornerHeight: cornerRadius, transform: nil)

        // Background — #fcfcfc
        context.setFillColor(NSColor(red: 0.988, green: 0.988, blue: 0.988, alpha: 1.0).cgColor)
        context.addPath(path)
        context.fillPath()

        // Border — #ccc
        context.setStrokeColor(NSColor(red: 0.8, green: 0.8, blue: 0.8, alpha: 1.0).cgColor)
        context.setLineWidth(1.0)
        context.addPath(path)
        context.strokePath()

        // Bottom shadow — #bbb, inset 1pt each side
        let shadowInset: CGFloat = 1
        let shadowY = kbdRect.maxY + 0.5
        context.setStrokeColor(NSColor(red: 0.733, green: 0.733, blue: 0.733, alpha: 1.0).cgColor)
        context.setLineWidth(1.0)
        context.move(to: CGPoint(x: kbdRect.minX + shadowInset, y: shadowY))
        context.addLine(to: CGPoint(x: kbdRect.maxX - shadowInset, y: shadowY))
        context.strokePath()
    }
}
