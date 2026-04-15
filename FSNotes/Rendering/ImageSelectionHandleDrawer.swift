//
//  ImageSelectionHandleDrawer.swift
//  FSNotes
//
//  Draws the selection ring + 8 resize handles around a currently-
//  selected inline image attachment. Called from LayoutManager.drawBackground
//  when EditTextView.selectedImageRange is non-nil.
//
//  Unlike the existing AttributeDrawers (bullets, HR, blockquote bars),
//  image selection is NOT stored as an attribute — it's ephemeral view
//  state on EditTextView. The LayoutManager reaches the selection via
//  `textContainers.first?.textView as? EditTextView` and passes its range
//  into this drawer.
//
//  Handles: four corners only (top-left, top-right, bottom-right,
//  bottom-left). Edge-midpoint handles were removed — with width-only
//  resize (aspect ratio locked), midpoints added no functionality,
//  they just gave the user more things to misclick.
//

import Cocoa

enum ImageSelectionHandleDrawer {

    /// Handle kind enum — identifies which corner the user grabbed.
    enum Handle: Int {
        case topLeft = 0
        case topRight = 1
        case bottomRight = 2
        case bottomLeft = 3
    }

    /// Side length of each handle square.
    static let handleSize: CGFloat = 8

    /// Extra hit-test slop around a handle so the user doesn't have to
    /// click the 8-pixel square dead-on.
    static let handleHitTolerance: CGFloat = 3

    // MARK: - Drawing

    /// Draw the selection ring and 8 handles around the attachment's
    /// bounding rect.
    ///
    /// - Parameters:
    ///   - layoutManager: the LayoutManager whose glyph rect we query
    ///   - container: the text container that holds the attachment
    ///   - range: character range of the attachment (always length 1)
    ///   - origin: the text container origin relative to the view
    ///             (passed in from drawBackground)
    static func draw(
        in layoutManager: NSLayoutManager,
        container: NSTextContainer,
        range: NSRange,
        origin: CGPoint
    ) {
        // Delegate the geometry to EditTextView.imageAttachmentRect so
        // the draw rect and the mouseDown hit-test rect come from the
        // exact same computation. Any drift would cause the user to
        // click where they see a handle and miss it.
        guard let editor = container.textView as? EditTextView,
              let rect = editor.imageAttachmentRect(forRange: range),
              rect.width > 2, rect.height > 2
        else { return }

        // Selection ring: 2pt accent stroke inset by 1pt so it sits on
        // the image edge rather than outside it.
        let ringRect = rect.insetBy(dx: 1, dy: 1)
        NSColor.controlAccentColor.setStroke()
        let ring = NSBezierPath(rect: ringRect)
        ring.lineWidth = 2
        ring.stroke()

        // Handle squares: filled accent with a white ring for contrast
        // against both light and dark image content.
        for point in handleCenters(for: rect) {
            let handleRect = NSRect(
                x: point.x - handleSize / 2,
                y: point.y - handleSize / 2,
                width: handleSize,
                height: handleSize
            )
            NSColor.white.setFill()
            NSBezierPath(rect: handleRect.insetBy(dx: -1, dy: -1)).fill()
            NSColor.controlAccentColor.setFill()
            NSBezierPath(rect: handleRect).fill()
        }
    }

    // MARK: - Geometry

    /// Return the 4 corner handle center points for a given image
    /// rect, in the same order as the Handle enum raw values.
    static func handleCenters(for rect: NSRect) -> [NSPoint] {
        let left = rect.minX
        let right = rect.maxX
        let top = rect.minY
        let bottom = rect.maxY
        return [
            NSPoint(x: left,  y: top),     // topLeft
            NSPoint(x: right, y: top),     // topRight
            NSPoint(x: right, y: bottom),  // bottomRight
            NSPoint(x: left,  y: bottom),  // bottomLeft
        ]
    }

    /// Hit-test a point against the 8 handles of a given rect.
    /// Returns the Handle kind whose center is within
    /// `handleSize/2 + handleHitTolerance` of the point, or nil.
    static func handle(at point: NSPoint, in rect: NSRect) -> Handle? {
        let threshold = handleSize / 2 + handleHitTolerance
        let t2 = threshold * threshold
        for (i, center) in handleCenters(for: rect).enumerated() {
            let dx = center.x - point.x
            let dy = center.y - point.y
            if dx * dx + dy * dy <= t2 {
                return Handle(rawValue: i)
            }
        }
        return nil
    }
}
