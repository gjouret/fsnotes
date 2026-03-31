//
//  FSNTextAttahcmentCell.swift
//  FSNotes
//
//  Created by Олександр Глущенко on 25.11.2020.
//  Copyright © 2020 Oleksandr Glushchenko. All rights reserved.
//

import Cocoa

class FSNTextAttachmentCell: NSTextAttachmentCell {
    let textContainer: NSTextContainer

    init(textContainer: NSTextContainer, image: NSImage) {
        self.textContainer = textContainer
        super.init(imageCell: image)
    }

    required init(coder: NSCoder) {
        self.textContainer = NSTextContainer()
        super.init(coder: coder)
    }

    override func cellSize() -> NSSize {
        let size = super.cellSize()

        if size.height == UserDefaultsManagement.noteFont.getAttachmentHeight() {
            return size
        }

        return NSSize(width: textContainer.size.width, height: size.height)
    }

    override func draw(withFrame cellFrame: NSRect, in controlView: NSView?, characterIndex charIndex: Int, layoutManager: NSLayoutManager) {
        // Don't draw if inside a folded region
        if let ts = layoutManager.textStorage,
           charIndex < ts.length,
           ts.attribute(.foldedContent, at: charIndex, effectiveRange: nil) != nil {
            return
        }
        super.draw(withFrame: cellFrame, in: controlView, characterIndex: charIndex, layoutManager: layoutManager)
    }

    override nonisolated func cellBaselineOffset() -> NSPoint {
        return NSPoint(x: 0, y: -2)
    }
}
