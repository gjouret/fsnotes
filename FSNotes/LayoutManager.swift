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

    /// Current cursor character index — updated by textViewDidChangeSelection for gutter drawing.
    var cursorCharIndex: Int = 0

    /// Registered attribute-based drawers. Adding a new visual = one new AttributeDrawer file + one entry here.
    static let attributeDrawers: [AttributeDrawer] = [
        HorizontalRuleDrawer(),
        BlockquoteBorderDrawer(),
        KbdBoxDrawer(),
        BulletDrawer(),
    ]
    
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
    
    // MARK: - Fold Gate (single source of truth)

    /// Returns the sub-ranges of `glyphRange` that are NOT folded.
    /// This is the ONE place that decides what is visible. Every rendering
    /// path (drawGlyphs, drawBackground) calls this before drawing.
    private func unfoldedRanges(in glyphRange: NSRange) -> [NSRange] {
        guard let ts = textStorage else { return [glyphRange] }
        let charRange = characterRange(forGlyphRange: glyphRange, actualGlyphRange: nil)
        guard charRange.length > 0 else { return [glyphRange] }

        var result: [NSRange] = []
        var currentStart = glyphRange.location
        ts.enumerateAttribute(.foldedContent, in: charRange) { value, attrCharRange, _ in
            if value != nil {
                let foldedGlyphs = self.glyphRange(forCharacterRange: attrCharRange, actualCharacterRange: nil)
                if currentStart < foldedGlyphs.location {
                    result.append(NSRange(location: currentStart, length: foldedGlyphs.location - currentStart))
                }
                currentStart = NSMaxRange(foldedGlyphs)
            }
        }
        let end = NSMaxRange(glyphRange)
        if currentStart < end {
            result.append(NSRange(location: currentStart, length: end - currentStart))
        }

        return result.isEmpty ? [glyphRange] : result
    }

    override func drawGlyphs(forGlyphRange glyphsToShow: NSRange, at origin: CGPoint) {
        for range in unfoldedRanges(in: glyphsToShow) {
            super.drawGlyphs(forGlyphRange: range, at: origin)
        }
    }

    override func drawBackground(forGlyphRange glyphsToShow: NSRange, at origin: CGPoint) {
        guard let ts = textStorage, glyphsToShow.location + glyphsToShow.length <= numberOfGlyphs,
              numberOfGlyphs > 0, ts.length > 0 else {
            super.drawBackground(forGlyphRange: glyphsToShow, at: origin)
            return
        }

        // Apply fold gate: only draw backgrounds for unfolded ranges
        for range in unfoldedRanges(in: glyphsToShow) {
            drawCodeBlockBackground(forGlyphRange: range, at: origin)
            drawHeaderBottomBorders(forGlyphRange: range, at: origin)

            if NotesTextProcessor.hideSyntax,
               let ctx = NSGraphicsContext.current?.cgContext,
               let tc = textContainers.first {
                for drawer in Self.attributeDrawers {
                    drawAttributeRanges(drawer: drawer, forGlyphRange: range, at: origin,
                                        layoutManager: self, textStorage: ts, textContainer: tc, context: ctx)
                }
            }

            super.drawBackground(forGlyphRange: range, at: origin)
        }
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

    // drawHorizontalRules, drawBlockquoteBorders, drawKbdTags removed —
    // replaced by AttributeDrawer registry (HorizontalRuleDrawer, BlockquoteBorderDrawer, KbdBoxDrawer).

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

        // Collapse folded content to zero height
        if let ts = textStorage {
            let charRange = self.characterRange(forGlyphRange: glyphRange, actualGlyphRange: nil)
            var intersectsFoldedContent = false

            if charRange.length > 0 {
                ts.enumerateAttribute(.foldedContent, in: charRange, options: []) { value, _, stop in
                    if value != nil {
                        intersectsFoldedContent = true
                        stop.pointee = true
                    }
                }
            } else if charRange.location < ts.length,
                      ts.attribute(.foldedContent, at: charRange.location, effectiveRange: nil) != nil {
                intersectsFoldedContent = true
            }

            if intersectsFoldedContent {
                var rect = lineFragmentRect.pointee
                rect.size.height = 0.01
                lineFragmentRect.pointee = rect
                var used = lineFragmentUsedRect.pointee
                used.size.height = 0.01
                lineFragmentUsedRect.pointee = used
                return true
            }
        }

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
