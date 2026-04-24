//
//  TableHandleChip.swift
//  FSNotes
//
//  A single column- or row-handle chip subview of the editor. The
//  `TableHandleOverlay` creates one chip pair per visible table
//  (column + row) and repositions them on every `updateHover(...)`.
//  Matches the TK1 `GlassHandleView` approach: because the chips
//  are real `NSView` subviews, AppKit invalidates their dirty rect
//  automatically on `.frame` reassignment — no TK2 fragment
//  redraw gymnastics needed for mouse-tracking.
//
//  Drawing is pure `draw(_:)`: a rectangular fill (translucent
//  separator) plus a centered `⠿` (BRAILLE PATTERN DOTS-123456)
//  grabber glyph. The glyph's point size scales with the smaller
//  of the chip's width/height so both thin-row and thin-column
//  cases render legibly.
//
//  Hit-testing: the chip is hit-testable over its entire bounds,
//  which is what lets the user drag-grab or right-click it. The
//  chip forwards right-click to the owning `TableHandleOverlay`.
//

import AppKit

final class TableHandleChip: NSView {

    enum Orientation {
        case horizontal // column handle (top strip, wide)
        case vertical   // row handle (left strip, tall)
    }

    let orientation: Orientation
    var index: Int = -1
    weak var overlay: TableHandleOverlay?
    /// Block index of the owning table in the editor's projection.
    /// Resolved by the overlay each time it positions this chip so
    /// right-click menus know which table to edit.
    var blockIndexRef: Int = -1

    init(orientation: Orientation) {
        self.orientation = orientation
        super.init(frame: .zero)
        wantsLayer = true
        isHidden = true
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) not supported")
    }

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        let ctx = NSGraphicsContext.current?.cgContext
        guard let ctx = ctx else { return }
        let bg = NSColor.separatorColor.withAlphaComponent(0.35)
        ctx.saveGState()
        ctx.setFillColor(bg.cgColor)
        ctx.fill(bounds)
        ctx.restoreGState()

        // Grip glyph `⠿` (U+283F, six-dot braille grip). Size scales
        // with the smaller dimension so thin strips remain legible.
        let minDim = min(bounds.width, bounds.height)
        let pt = max(10, minDim * 0.8)
        let font = NSFont.systemFont(ofSize: pt, weight: .bold)
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: NSColor.secondaryLabelColor,
        ]
        let grip = NSAttributedString(
            string: "\u{283F}", attributes: attrs
        )
        let size = grip.size()
        let origin = CGPoint(
            x: bounds.midX - size.width / 2,
            y: bounds.midY - size.height / 2
        )
        grip.draw(at: origin)
    }

    // MARK: - Hit-testing + events

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard !isHidden else { return nil }
        let local = convert(point, from: superview)
        return bounds.contains(local) ? self : nil
    }

    override func rightMouseDown(with event: NSEvent) {
        guard let overlay = overlay, blockIndexRef >= 0 else {
            super.rightMouseDown(with: event)
            return
        }
        let menu: NSMenu
        switch orientation {
        case .horizontal:
            menu = overlay.makeColumnMenu(
                blockIndex: blockIndexRef, col: index
            )
        case .vertical:
            menu = overlay.makeRowMenu(
                blockIndex: blockIndexRef, row: index
            )
        }
        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        return nil // suppress system default; we pop menus ourselves
    }
}
