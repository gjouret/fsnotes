//
//  BulletDrawer.swift
//  FSNotes
//
//  Draws a bullet character (•) at the position of hidden list markers (-, *, +).
//  The original markdown marker stays in storage — this is pure rendering.
//  Uses the same AttributeDrawer protocol as HorizontalRuleDrawer and KbdBoxDrawer.
//

import Cocoa

struct BulletDrawer: AttributeDrawer {
    let attributeKey: NSAttributedString.Key = .bulletMarker

    func draw(value: Any, rect: NSRect, context: CGContext,
              origin: CGPoint, textContainer: NSTextContainer) {
        let fontSize = CGFloat(UserDefaultsManagement.fontSize)
        let bulletFont = NSFont.systemFont(ofSize: fontSize * 0.8)
        let bullet = "\u{2022}" // •

        let attrs: [NSAttributedString.Key: Any] = [
            .font: bulletFont,
            .foregroundColor: NSColor.textColor
        ]

        let bulletSize = (bullet as NSString).size(withAttributes: attrs)

        // Draw bullet centered vertically in the line fragment, at the marker's x position
        let x = rect.minX + origin.x
        let y = rect.midY + origin.y - bulletSize.height / 2

        (bullet as NSString).draw(at: NSPoint(x: x, y: y), withAttributes: attrs)
    }
}
