//
//  CustomLayoutManager.swift
//  FSNotes
//
//  Created by Oleksandr Hlushchenko on 24.08.2025.
//  Copyright © 2025 Oleksandr Hlushchenko. All rights reserved.
//

import Cocoa

fileprivate extension NSRange {
    /// Clamp range to fit inside given maxRange
    func clamped(to maxRange: NSRange) -> NSRange {
        if maxRange.length == 0 { return NSRange(location: maxRange.location, length: 0) }
        if self.location >= NSMaxRange(maxRange) { return NSRange(location: NSMaxRange(maxRange), length: 0) }
        let start = max(self.location, maxRange.location)
        let end = min(NSMaxRange(self), NSMaxRange(maxRange))
        if end <= start { return NSRange(location: start, length: 0) }
        return NSRange(location: start, length: end - start)
    }
}

class LayoutManager: NSLayoutManager, NSLayoutManagerDelegate {
    weak var processor: TextStorageProcessor?
    
    override init() {
        super.init()
        
        self.allowsNonContiguousLayout = true
    }
    
    required init?(coder: NSCoder) {
        super.init(coder: coder)
        
        self.allowsNonContiguousLayout = true
    }
    
    public var lineHeightMultiple: CGFloat = CGFloat(UserDefaultsManagement.lineHeightMultiple)

    private var defaultFont: NSFont {
        return self.firstTextView?.font ?? NSFont.systemFont(ofSize: NSFont.systemFontSize)
    }

    private func font(for glyphRange: NSRange) -> NSFont {
        guard let textStorage = self.textStorage else {
            return defaultFont
        }

        let characterRange = self.characterRange(forGlyphRange: glyphRange, actualGlyphRange: nil)
        let storageRange = NSRange(location: 0, length: textStorage.length)
        let safeCharRange = characterRange.clamped(to: storageRange)
        guard safeCharRange.length > 0 else {
            return defaultFont
        }

        // O(1) fast path: if the first character's font is normal size, use it.
        // This handles the common case (non-WYSIWYG, or lines not starting with hidden syntax).
        if let firstFont = textStorage.attribute(.font, at: safeCharRange.location, effectiveRange: nil) as? NSFont {
            if firstFont.pointSize >= 4 {
                return firstFont
            }
        }

        // First font is hidden syntax (0.1pt) — the line starts with hidden markdown
        // (e.g., "# " for headers). We must find the LARGEST font in this range to
        // ensure the line fragment height accommodates the actual visible content.
        // Critical for headers: hidden "# " is 0.1pt but the header text is 28pt+.
        var maxFont = defaultFont
        var maxSize = defaultFont.pointSize
        textStorage.enumerateAttribute(.font, in: safeCharRange, options: []) { value, _, _ in
            if let font = value as? NSFont, font.pointSize > maxSize {
                maxSize = font.pointSize
                maxFont = font
            }
        }
        return maxFont
    }
    
    private func hasAttachment(in glyphRange: NSRange) -> (hasAttachment: Bool, maxAttachmentHeight: CGFloat) {
        guard let textStorage = self.textStorage else {
            return (false, 0)
        }
        
        let characterRange = self.characterRange(forGlyphRange: glyphRange, actualGlyphRange: nil)
        let storageRange = NSRange(location: 0, length: textStorage.length)
        let safeCharRange = characterRange.clamped(to: storageRange)
        if safeCharRange.length == 0 {
            return (false, 0)
        }
        
        var maxHeight: CGFloat = 0
        var hasAttachment = false
        
        textStorage.enumerateAttribute(.attachment, in: safeCharRange, options: []) { value, _, _ in
            if let attachment = value as? NSTextAttachment {
                hasAttachment = true
                let attachmentBounds = attachment.bounds
                maxHeight = max(maxHeight, attachmentBounds.height)
            }
        }
        
        return (hasAttachment, maxHeight)
    }

    public func lineHeight(for font: NSFont) -> CGFloat {
        let fontLineHeight = self.defaultLineHeight(for: font)
        let lineHeight = fontLineHeight * lineHeightMultiple
        return lineHeight
    }

    private func isInCodeBlock(characterIndex: Int) -> Bool {
        guard let textStorage = self.textStorage else {
            return false
        }
        
        let ns = textStorage.string as NSString
        let storageFullRange = NSRange(location: 0, length: ns.length)

        if characterIndex < 0 || characterIndex >= NSMaxRange(storageFullRange) {
            return false
        }
        
        guard let codeBlocks = processor?.codeBlockRanges, !codeBlocks.isEmpty else { return false }
        return codeBlocks.contains { NSLocationInRange(characterIndex, $0) }
    }
    
    // MARK: - Drawing
    
    override func drawBackground(forGlyphRange glyphsToShow: NSRange, at origin: CGPoint) {
        // Validate glyph range before any custom drawing — stale block model
        // ranges after note switches can cause out-of-bounds crashes in
        // NSLayoutManager._fillLayoutHoleForCharacterRange.
        guard let ts = textStorage, glyphsToShow.location + glyphsToShow.length <= numberOfGlyphs,
              numberOfGlyphs > 0, ts.length > 0 else {
            super.drawBackground(forGlyphRange: glyphsToShow, at: origin)
            return
        }

        drawCodeBlockBackground(forGlyphRange: glyphsToShow, at: origin)
        drawHorizontalRules(forGlyphRange: glyphsToShow, at: origin)
        drawBlockquoteBorders(forGlyphRange: glyphsToShow, at: origin)
        drawHeaderBottomBorders(forGlyphRange: glyphsToShow, at: origin)

        super.drawBackground(forGlyphRange: glyphsToShow, at: origin)
    }

    override func fillBackgroundRectArray(_ rectArray: UnsafePointer<NSRect>, count rectCount: Int, forCharacterRange charRange: NSRange, color: NSColor) {
        let storageLength = self.textStorage?.length ?? 0
        let storageFullRange = NSRange(location: 0, length: storageLength)
        let safeCharRange = charRange.clamped(to: storageFullRange)
        if color == NSColor.selectedTextBackgroundColor ||
           color == NSColor.unemphasizedSelectedTextBackgroundColor ||
           !isInCodeBlock(characterIndex: safeCharRange.location) {
            super.fillBackgroundRectArray(rectArray, count: rectCount, forCharacterRange: charRange, color: color)
        }
    }
    
    private func drawCodeBlockBackground(forGlyphRange glyphsToShow: NSRange, at origin: CGPoint) {
        guard let textStorage = self.textStorage,
              let context = NSGraphicsContext.current?.cgContext else {
            return
        }

        let storageFullRange = NSRange(location: 0, length: textStorage.length)
        guard let allCodeBlocks = processor?.codeBlockRanges, !allCodeBlocks.isEmpty else { return }
        guard let textContainer = self.textContainers.first else { return }
        
        let visibleCharRange = self.characterRange(forGlyphRange: glyphsToShow, actualGlyphRange: nil)
        let relevantCodeBlocks = allCodeBlocks.filter { codeBlock in
            NSIntersectionRange(codeBlock, visibleCharRange).length > 0
        }
        
        guard !relevantCodeBlocks.isEmpty else { return }
        
        textContainer.lineFragmentPadding = 10
        context.saveGState()
        
        let backgroundColor = NotesTextProcessor.getHighlighter().options.style.backgroundColor.cgColor
        let borderColor = NSColor.lightGray.cgColor
        
        for codeBlockRange in relevantCodeBlocks {  // ← теперь только релевантные блоки!
            let safeCharRange = codeBlockRange.clamped(to: storageFullRange)
            if safeCharRange.length == 0 { continue }
            
            let glyphRange = self.glyphRange(forCharacterRange: safeCharRange, actualCharacterRange: nil)
            if glyphRange.length == 0 { continue }
            
            let boundingRect = self.boundingRect(forGlyphRange: glyphRange, in: textContainer)
            if boundingRect.isEmpty { continue }
            
            // Padding left/right
            let horizontalPadding: CGFloat = 5.0
            let paddedRect = boundingRect
                .insetBy(dx: -horizontalPadding, dy: 0)
                .offsetBy(dx: origin.x, dy: origin.y)
            
            // Round borders
            let radius: CGFloat = 5.0
            let path = CGPath(roundedRect: paddedRect, cornerWidth: radius, cornerHeight: radius, transform: nil)
            
            context.setFillColor(backgroundColor)
            context.addPath(path)
            context.fillPath()
            
            // Border 1px
            context.addPath(path)
            context.setStrokeColor(borderColor)
            context.setLineWidth(1.0)
            context.strokePath()
        }
        
        context.restoreGState()
    }

    private func drawHorizontalRules(forGlyphRange glyphsToShow: NSRange, at origin: CGPoint) {
        guard NotesTextProcessor.hideSyntax else { return }
        guard let textStorage = self.textStorage,
              let context = NSGraphicsContext.current?.cgContext,
              let textContainer = self.textContainers.first else { return }

        let visibleCharRange = self.characterRange(forGlyphRange: glyphsToShow, actualGlyphRange: nil)
        let storageFullRange = NSRange(location: 0, length: textStorage.length)

        textStorage.enumerateAttribute(.horizontalRule, in: visibleCharRange.clamped(to: storageFullRange)) { value, range, _ in
            guard value != nil else { return }
            let glyphRange = self.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
            if glyphRange.length == 0 { return }

            // Use the line fragment rect (full container width) instead of the
            // bounding rect (which is empty after kern-collapsing the --- text)
            let lineFragmentRect = self.lineFragmentRect(forGlyphAt: glyphRange.location, effectiveRange: nil)
            if lineFragmentRect.isEmpty { return }

            // MPreview CSS: background #e7e7e7, height 4px, margin 16px 0, no inset
            let containerWidth = textContainer.size.width
            let lineY = lineFragmentRect.midY + origin.y
            let padding = textContainer.lineFragmentPadding

            context.saveGState()
            context.setFillColor(NSColor(red: 0.906, green: 0.906, blue: 0.906, alpha: 1.0).cgColor) // #e7e7e7
            context.fill(CGRect(x: origin.x + padding, y: lineY - 2, width: containerWidth - padding * 2, height: 4))
            context.restoreGState()
        }
    }

    private func drawBlockquoteBorders(forGlyphRange glyphsToShow: NSRange, at origin: CGPoint) {
        guard NotesTextProcessor.hideSyntax else { return }
        guard let textStorage = self.textStorage,
              let context = NSGraphicsContext.current?.cgContext,
              let textContainer = self.textContainers.first else { return }

        let visibleCharRange = self.characterRange(forGlyphRange: glyphsToShow, actualGlyphRange: nil)
        let storageFullRange = NSRange(location: 0, length: textStorage.length)

        textStorage.enumerateAttribute(.blockquote, in: visibleCharRange.clamped(to: storageFullRange)) { value, range, _ in
            guard value != nil else { return }
            let glyphRange = self.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
            if glyphRange.length == 0 { return }
            let rect = self.boundingRect(forGlyphRange: glyphRange, in: textContainer)
            if rect.isEmpty { return }

            // MPreview CSS: border-left 4px solid #ddd, padding 0 15px
            let barX = origin.x + textContainer.lineFragmentPadding + 2
            context.saveGState()
            context.setFillColor(NSColor(red: 0.867, green: 0.867, blue: 0.867, alpha: 1.0).cgColor) // #ddd
            context.fill(CGRect(x: barX, y: rect.minY + origin.y, width: 4, height: rect.height))
            context.restoreGState()
        }
    }

    private func drawHeaderBottomBorders(forGlyphRange glyphsToShow: NSRange, at origin: CGPoint) {
        guard NotesTextProcessor.hideSyntax else { return }
        guard let textStorage = self.textStorage,
              let context = NSGraphicsContext.current?.cgContext,
              let textContainer = self.textContainers.first else { return }
        guard let blocks = processor?.blocks, !blocks.isEmpty else { return }

        let visibleCharRange = self.characterRange(forGlyphRange: glyphsToShow, actualGlyphRange: nil)
        let storageFullRange = NSRange(location: 0, length: textStorage.length)
        let safeRange = visibleCharRange.clamped(to: storageFullRange)
        guard safeRange.length > 0 else { return }

        let baseSize = UserDefaultsManagement.noteFont.pointSize

        // Use the block model to find H1/H2 headers
        var drawnHeaderRanges = Set<Int>()  // Track drawn headers by location to avoid duplicates
        for block in blocks {
            let level: Int
            switch block.type {
            case .heading(let l) where l <= 2: level = l
            case .headingSetext(let l) where l <= 2: level = l
            default: continue
            }

            // Only process blocks that intersect the visible range, and skip duplicates
            guard NSIntersectionRange(block.range, safeRange).length > 0 else { continue }
            guard block.range.location < textStorage.length,
                  NSMaxRange(block.range) <= textStorage.length else { continue }
            guard !drawnHeaderRanges.contains(block.range.location) else { continue }
            drawnHeaderRanges.insert(block.range.location)

            let glyphRange = self.glyphRange(forCharacterRange: block.range, actualCharacterRange: nil)
            if glyphRange.length == 0 { continue }

            // Get the line fragment rect for the last glyph in the header paragraph
            let lastGlyphIndex = min(glyphRange.location + glyphRange.length - 1, self.numberOfGlyphs - 1)
            let lineFragRect = self.lineFragmentRect(forGlyphAt: lastGlyphIndex, effectiveRange: nil)
            if lineFragRect.isEmpty { continue }

            // Draw the border line just below the LAST line of the header.
            // Use lastGlyphIndex (not glyphRange.location) to handle wrapped headers.
            let containerWidth = textContainer.size.width
            let usedRect = self.lineFragmentUsedRect(forGlyphAt: lastGlyphIndex, effectiveRange: nil)
            let lineY = usedRect.maxY + origin.y + 1  // 1pt below text bottom

            context.saveGState()
            // #eeeeee = rgb(238,238,238) = 0.933
            context.setStrokeColor(NSColor(red: 0.933, green: 0.933, blue: 0.933, alpha: 1.0).cgColor)
            // CSS "1px" = 0.5pt on Retina displays (thin hairline matching MPreview)
            context.setLineWidth(0.5)
            // Full content width, edge to edge (no lineFragmentPadding inset)
            context.move(to: CGPoint(x: origin.x, y: lineY))
            context.addLine(to: CGPoint(x: origin.x + containerWidth, y: lineY))
            context.strokePath()
            context.restoreGState()
        }
    }

    public func layoutManager(
            _ layoutManager: NSLayoutManager,
            shouldSetLineFragmentRect lineFragmentRect: UnsafeMutablePointer<NSRect>,
            lineFragmentUsedRect: UnsafeMutablePointer<NSRect>,
            baselineOffset: UnsafeMutablePointer<CGFloat>,
            in textContainer: NSTextContainer,
            forGlyphRange glyphRange: NSRange) -> Bool {

        // Get the font for the current range of glyphs
        let currentFont = font(for: glyphRange)
        let fontLineHeight = layoutManager.defaultLineHeight(for: currentFont)
        let standardLineHeight = fontLineHeight * lineHeightMultiple

        let attachmentInfo = hasAttachment(in: glyphRange)

        var finalLineHeight: CGFloat
        var baselineNudge: CGFloat

        if attachmentInfo.hasAttachment && attachmentInfo.maxAttachmentHeight > 0 {
            if attachmentInfo.maxAttachmentHeight > standardLineHeight {
                finalLineHeight = attachmentInfo.maxAttachmentHeight
                baselineNudge = 0
            } else {
                finalLineHeight = standardLineHeight
                let extraSpace = finalLineHeight - fontLineHeight
                baselineNudge = extraSpace * 0.5
            }
        } else {
            finalLineHeight = standardLineHeight
            let extraSpace = finalLineHeight - fontLineHeight
            baselineNudge = extraSpace * 0.5
        }

        var rect = lineFragmentRect.pointee
        // CRITICAL: use max() to preserve paragraph spacing that NSLayoutManager added.
        // Setting height = finalLineHeight directly discards paragraphSpacing/paragraphSpacingBefore.
        rect.size.height = max(ceil(finalLineHeight), rect.size.height)

        var usedRect = lineFragmentUsedRect.pointee
        // Keep usedRect at least as tall as the font line height, but do NOT
        // inflate it to match lineFragmentRect (which includes paragraph spacing).
        // This way: lineFragmentRect drives layout spacing, usedRect drives glyph area.
        usedRect.size.height = max(ceil(finalLineHeight), ceil(usedRect.size.height))

        lineFragmentRect.pointee = rect
        lineFragmentUsedRect.pointee = usedRect
        baselineOffset.pointee = baselineOffset.pointee + baselineNudge

        return true
    }
    
    func refreshLayoutSoftly() {
        invalidateLayout(forCharacterRange: NSRange(location: 0, length: textStorage?.length ?? 0),
                                actualCharacterRange: nil)
                
        textContainers.forEach { container in
            container.textView?.needsDisplay = true
        }
    }
    
    override func setExtraLineFragmentRect(
        _ fragmentRect: NSRect,
        usedRect: NSRect,
        textContainer container: NSTextContainer) {
        
        var fontToUse: NSFont

        if let textStorage = self.textStorage, textStorage.length > 0 {
            let lastIndex = textStorage.length - 1
            let attributes = textStorage.attributes(at: lastIndex, effectiveRange: nil)
            let nsString = textStorage.string as NSString
            let lastCharIsNewline = nsString.character(at: lastIndex) == 0x0A // '\n'

            if !lastCharIsNewline, let font = attributes[.font] as? NSFont {
                fontToUse = font
            } else {
                fontToUse = UserDefaultsManagement.noteFont
            }
        } else {
            fontToUse = UserDefaultsManagement.noteFont
        }
        
        let lineHeight = self.lineHeight(for: fontToUse)
        
        var fragmentRect = fragmentRect
        fragmentRect.size.height = ceil(lineHeight)
        var usedRect = usedRect
        usedRect.size.height = ceil(lineHeight)

        super.setExtraLineFragmentRect(fragmentRect,
            usedRect: usedRect,
            textContainer: container)
    }
}
