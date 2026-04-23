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
        // BulletDrawer is NOT registered here — it uses lineFragmentRect
        // (boundingRect is empty for kern-collapsed characters).
        // Bullets are drawn in drawBulletMarkers() called from drawBackground().
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

        // Clamp glyphRange to valid glyph count — after edits the
        // layout system can pass ranges that exceed numberOfGlyphs.
        let maxGlyph = numberOfGlyphs
        guard maxGlyph > 0 else { return [] }
        let clampedGlyph = NSRange(
            location: min(glyphRange.location, maxGlyph),
            length: min(glyphRange.length, maxGlyph - min(glyphRange.location, maxGlyph))
        )
        guard clampedGlyph.length > 0 else { return [] }

        let charRange = characterRange(forGlyphRange: clampedGlyph, actualGlyphRange: nil)
        guard charRange.length > 0,
              NSMaxRange(charRange) <= ts.length else { return [] }

        var result: [NSRange] = []
        var currentStart = clampedGlyph.location
        ts.enumerateAttribute(.foldedContent, in: charRange) { value, attrCharRange, _ in
            if value != nil {
                let foldedGlyphs = self.glyphRange(forCharacterRange: attrCharRange, actualCharacterRange: nil)
                if currentStart < foldedGlyphs.location {
                    result.append(NSRange(location: currentStart, length: foldedGlyphs.location - currentStart))
                }
                currentStart = NSMaxRange(foldedGlyphs)
            }
        }
        let end = NSMaxRange(clampedGlyph)
        if currentStart < end {
            result.append(NSRange(location: currentStart, length: end - currentStart))
        }

        return result.isEmpty ? [clampedGlyph] : result
    }

    override func drawGlyphs(forGlyphRange glyphsToShow: NSRange, at origin: CGPoint) {
        for range in unfoldedRanges(in: glyphsToShow) {
            guard range.length > 0,
                  NSMaxRange(range) <= numberOfGlyphs else { continue }
            let cr = characterRange(forGlyphRange: range, actualGlyphRange: nil)
            guard NSMaxRange(cr) <= (textStorage?.length ?? 0) else { continue }
            super.drawGlyphs(forGlyphRange: range, at: origin)

            // Image selection ring + resize handles. Drawn AFTER the
            // attachment cell paints the image so the ring and handles
            // sit on top of the image, not behind it. drawBackground()
            // runs before attachments, so drawing there would bury the
            // overlay under the image bitmap.
            if let editor = self.textContainers.first?.textView as? EditTextView,
               let selRange = editor.selectedImageRange,
               let tc = textContainers.first,
               NSLocationInRange(selRange.location, cr) {
                ImageSelectionHandleDrawer.draw(
                    in: self, container: tc,
                    range: selRange, origin: origin
                )
            }
        }
    }

    static var logFrameCounter = 0

    override func drawBackground(forGlyphRange glyphsToShow: NSRange, at origin: CGPoint) {
        guard let ts = textStorage, glyphsToShow.location + glyphsToShow.length <= numberOfGlyphs,
              numberOfGlyphs > 0, ts.length > 0 else {
            super.drawBackground(forGlyphRange: glyphsToShow, at: origin)
            return
        }

        // Bail out during block-model splice operations — textStorage may
        // be mid-mutation and attribute enumeration would hit stale ranges.
        if let processor = ts.delegate as? TextStorageProcessor, processor.isRendering {
            super.drawBackground(forGlyphRange: glyphsToShow, at: origin)
            return
        }

        // Apply fold gate: only draw backgrounds for unfolded ranges.
        // Each sub-range is re-validated before use — after deletes,
        // the character range backing a glyph range can exceed
        // textStorage.length, causing AppKit's attribute enumeration
        // to trap.
        for range in unfoldedRanges(in: glyphsToShow) {
            // Re-validate: glyph range must map to a valid character range.
            guard range.length > 0,
                  NSMaxRange(range) <= numberOfGlyphs else { continue }
            let charRangeForRange = characterRange(forGlyphRange: range, actualGlyphRange: nil)
            guard charRangeForRange.length > 0,
                  NSMaxRange(charRangeForRange) <= ts.length else { continue }

            drawCodeBlockBackground(forGlyphRange: range, at: origin)
            drawHeaderBottomBorders(forGlyphRange: range, at: origin)

            let blockModelActive = (ts.delegate as? TextStorageProcessor)?.blockModelActive ?? false

            // Blockquote vertical bars: drawn in BOTH source-mode and
            // block-model mode. The block-model renderer sets .blockquote
            // with the nesting depth on rendered blockquote lines.
            if let ctx = NSGraphicsContext.current?.cgContext,
               let tc = textContainers.first {
                let bqDrawer = BlockquoteBorderDrawer()
                drawAttributeRanges(drawer: bqDrawer, forGlyphRange: range, at: origin,
                                    layoutManager: self, textStorage: ts, textContainer: tc, context: ctx)
            }

            // Horizontal rule drawing: needed in BOTH source-mode and block-model
            // mode. The block-model HR renderer sets .horizontalRule on a single
            // space character; the LayoutManager draws the full-width line.
            if let ctx = NSGraphicsContext.current?.cgContext,
               let tc = textContainers.first {
                let hrDrawer = HorizontalRuleDrawer()
                drawAttributeRanges(drawer: hrDrawer, forGlyphRange: range, at: origin,
                                    layoutManager: self, textStorage: ts, textContainer: tc, context: ctx)
            }

            // Source-mode attribute-based drawing: bullets, checkboxes, ordered
            // markers, and other custom attribute drawers. Only needed in source
            // mode — the block-model pipeline renders these inline as text
            // characters, not as LayoutManager-drawn glyphs.
            if NotesTextProcessor.hideSyntax,
               !blockModelActive,
               let ctx = NSGraphicsContext.current?.cgContext,
               let tc = textContainers.first {
                for drawer in Self.attributeDrawers {
                    // Skip blockquote and HR — already drawn above for both modes.
                    if drawer.attributeKey == .blockquote { continue }
                    if drawer.attributeKey == .horizontalRule { continue }
                    drawAttributeRanges(drawer: drawer, forGlyphRange: range, at: origin,
                                        layoutManager: self, textStorage: ts, textContainer: tc, context: ctx)
                }
                drawBulletMarkers(forGlyphRange: range, at: origin, textStorage: ts, context: ctx)
                drawCheckboxMarkers(forGlyphRange: range, at: origin, textStorage: ts, context: ctx)
                drawOrderedMarkers(forGlyphRange: range, at: origin, textStorage: ts, context: ctx)
            }

            super.drawBackground(forGlyphRange: range, at: origin)
        }
    }

    override func fillBackgroundRectArray(_ rectArray: UnsafePointer<NSRect>, count rectCount: Int, forCharacterRange charRange: NSRange, color: NSColor) {
        let storageLength = self.textStorage?.length ?? 0
        let storageFullRange = NSRange(location: 0, length: storageLength)
        let safeCharRange = charRange.clamped(to: storageFullRange)
        let isSelectionColor =
            color == NSColor.selectedTextBackgroundColor ||
            color == NSColor.unemphasizedSelectedTextBackgroundColor

        // Table-attachment selection widening: when the user selects
        // a range that includes a table attachment character, AppKit
        // computes the selection rect from the attachment's own cell
        // size — which for `InlineTableAttachmentCell` stops somewhere
        // inside the last column, not at the text container's right
        // edge. Widen each selection rect that covers a table
        // attachment glyph to fill the full line fragment width.
        // Rects for non-table lines (paragraphs, headings, etc.) are
        // left at their original extents so multi-line selections
        // don't get over-highlighted into the right margin.
        if isSelectionColor,
           rectCount > 0,
           let ts = self.textStorage,
           let tc = self.textContainers.first {
            let fullWidth = tc.size.width
            let padding = tc.lineFragmentPadding
            let widenedWidth = max(0, fullWidth - padding * 2)
            var widened = Array(UnsafeBufferPointer(start: rectArray, count: rectCount))
            var changed = false
            for i in 0..<rectCount {
                let r = widened[i]
                if rectCoversTableAttachment(r, charRange: safeCharRange, in: ts) {
                    widened[i] = NSRect(
                        x: padding,
                        y: r.origin.y,
                        width: max(r.size.width, widenedWidth),
                        height: r.size.height
                    )
                    changed = true
                }
            }
            if changed {
                widened.withUnsafeBufferPointer { buf in
                    super.fillBackgroundRectArray(
                        buf.baseAddress!, count: rectCount,
                        forCharacterRange: charRange, color: color
                    )
                }
                return
            }
        }

        if isSelectionColor || !isInCodeBlock(characterIndex: safeCharRange.location) {
            super.fillBackgroundRectArray(rectArray, count: rectCount, forCharacterRange: charRange, color: color)
        }
    }

    /// True iff the given selection rect covers a line fragment that
    /// contains a table-attachment glyph whose character index falls
    /// within `charRange`. Maps the rect's center point back to a
    /// glyph index, then asks the text storage whether the
    /// underlying character is an `InlineTableAttachmentCell`-backed
    /// attachment.
    private func rectCoversTableAttachment(
        _ rect: NSRect,
        charRange: NSRange,
        in ts: NSTextStorage
    ) -> Bool {
        guard rect.height > 0, rect.width > 0, ts.length > 0 else { return false }
        let nsString = ts.string as NSString
        guard let tc = textContainers.first else { return false }

        // Probe the center of the rect. NSLayoutManager maps the
        // point to the nearest glyph via `glyphIndex(for:in:)`.
        let probe = NSPoint(x: rect.midX, y: rect.midY)
        let glyphIdx = glyphIndex(for: probe, in: tc)
        guard glyphIdx < numberOfGlyphs else { return false }
        let charIdx = characterIndexForGlyph(at: glyphIdx)
        guard charIdx >= 0, charIdx < nsString.length else { return false }
        // The probed character must be within the selection range —
        // otherwise we'd widen the rect based on a glyph that isn't
        // actually being highlighted.
        guard NSLocationInRange(charIdx, charRange) else { return false }
        // And it must be a table attachment specifically.
        guard nsString.character(at: charIdx) == 0xFFFC else { return false }
        guard let att = ts.attribute(.attachment, at: charIdx, effectiveRange: nil) as? NSTextAttachment,
              let cell = att.attachmentCell else { return false }
        return cell is TableAttachmentHosting
    }
    
    /// Bullet glyph for a given nesting depth (0 = top level).
    private static func bulletGlyph(for depth: Int) -> String {
        switch depth {
        case 0:  return "\u{2022}" // •
        case 1:  return "\u{25E6}" // ◦
        case 2:  return "\u{25AA}" // ▪
        default: return "\u{25AB}" // ▫
        }
    }

    /// Fixed gap between a list marker's right edge and the text start (constant across depths).
    private var listMarkerGap: CGFloat { 6 }

    /// Generic list-marker renderer. Tabs-as-metadata model: the marker X position
    /// is computed from `.listDepth` using the SAME slotWidth + depth*listStep
    /// geometry that phase5 encodes in its paragraph tab stops. This keeps the
    /// drawer in sync with phase5 without reading firstLineHeadIndent (which is
    /// now the constant depth-0 slot, not the per-line text indent).
    private func drawListMarkers(forGlyphRange glyphsToShow: NSRange, at origin: CGPoint,
                                 textStorage: NSTextStorage,
                                 attributeKey: NSAttributedString.Key,
                                 render: (Any, NSRect, CGFloat, CGFloat) -> Void) {
        let visibleCharRange = characterRange(forGlyphRange: glyphsToShow, actualGlyphRange: nil)
        let safeRange = NSIntersectionRange(visibleCharRange, NSRange(location: 0, length: textStorage.length))
        guard safeRange.length > 0 else { return }

        let baseSize = UserDefaultsManagement.noteFont.pointSize
        let listStep = baseSize * 4     // must match phase5
        let slotWidth = baseSize * 2    // must match phase5

        textStorage.enumerateAttribute(attributeKey, in: safeRange) { value, range, _ in
            guard let value = value else { return }
            let glyphIdx = self.glyphIndexForCharacter(at: range.location)
            guard glyphIdx < self.numberOfGlyphs else { return }
            let lineRect = self.lineFragmentRect(forGlyphAt: glyphIdx, effectiveRange: nil)
            if lineRect.isEmpty { return }
            let depth = (textStorage.attribute(.listDepth, at: range.location, effectiveRange: nil) as? Int) ?? 0
            let textStartX = origin.x + lineRect.minX + slotWidth + CGFloat(depth) * listStep
            let markerRightX = textStartX - self.listMarkerGap
            // Use the TEXT BASELINE of the marker char, not the line's vertical
            // center — marker glyph fonts can be 2x the text font and must sit on
            // the same baseline as "Level 3a" to look visually aligned.
            // Round to pixel to prevent sub-pixel jitter when paragraph spacing
            // from preceding headers causes fractional baseline shifts.
            let glyphLoc = self.location(forGlyphAt: glyphIdx)
            let baselineY = round(origin.y + lineRect.minY + glyphLoc.y)
            render(value, lineRect, markerRightX, baselineY)
        }
    }

    /// Draw bullet markers at positions where `-` is hidden by syntax hiding.
    private func drawBulletMarkers(forGlyphRange glyphsToShow: NSRange, at origin: CGPoint,
                                    textStorage: NSTextStorage, context: CGContext) {
        let noteFont = UserDefaultsManagement.noteFont
        let bulletFont = NSFont.systemFont(ofSize: noteFont.pointSize * 2)
        let attrs: [NSAttributedString.Key: Any] = [
            .font: bulletFont, .foregroundColor: NSColor.textColor
        ]
        drawListMarkers(forGlyphRange: glyphsToShow, at: origin, textStorage: textStorage,
                        attributeKey: .bulletMarker) { value, _, rightX, baselineY in
            let depth = (value as? Int) ?? 0
            let glyph = Self.bulletGlyph(for: depth) as NSString
            let size = glyph.size(withAttributes: attrs)
            let topY = baselineY - bulletFont.ascender
            context.saveGState()
            glyph.draw(at: NSPoint(x: rightX - size.width, y: topY), withAttributes: attrs)
            context.restoreGState()
        }
    }

    /// Draw task-list checkboxes.
    private func drawCheckboxMarkers(forGlyphRange glyphsToShow: NSRange, at origin: CGPoint,
                                     textStorage: NSTextStorage, context: CGContext) {
        let noteFont = UserDefaultsManagement.noteFont
        let cbFont = NSFont.systemFont(ofSize: noteFont.pointSize * 2.0)
        let attrs: [NSAttributedString.Key: Any] = [
            .font: cbFont, .foregroundColor: NSColor.textColor
        ]
        drawListMarkers(forGlyphRange: glyphsToShow, at: origin, textStorage: textStorage,
                        attributeKey: .checkboxMarker) { value, _, rightX, baselineY in
            guard let checked = value as? Bool else { return }
            let glyph = (checked ? "\u{2611}" : "\u{2610}") as NSString
            let size = glyph.size(withAttributes: attrs)
            let topY = baselineY - cbFont.ascender
            context.saveGState()
            glyph.draw(at: NSPoint(x: rightX - size.width, y: topY), withAttributes: attrs)
            context.restoreGState()
        }
    }

    /// Draw substituted ordered-list markers (1./a./i.).
    private func drawOrderedMarkers(forGlyphRange glyphsToShow: NSRange, at origin: CGPoint,
                                    textStorage: NSTextStorage, context: CGContext) {
        let noteFont = UserDefaultsManagement.noteFont
        let attrs: [NSAttributedString.Key: Any] = [
            .font: noteFont, .foregroundColor: NSColor.textColor
        ]
        drawListMarkers(forGlyphRange: glyphsToShow, at: origin, textStorage: textStorage,
                        attributeKey: .orderedMarker) { value, _, rightX, baselineY in
            guard let markerText = value as? String else { return }
            let ns = markerText as NSString
            let size = ns.size(withAttributes: attrs)
            let topY = baselineY - noteFont.ascender
            context.saveGState()
            ns.draw(at: NSPoint(x: rightX - size.width, y: topY), withAttributes: attrs)
            context.restoreGState()
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
            // CSS "1px" = 0.5pt on Retina displays for a thin hairline.
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
    
    func refreshLayoutSoftly(range: NSRange? = nil) {
        let target: NSRange
        if let r = range {
            target = r
        } else {
            target = NSRange(location: 0, length: textStorage?.length ?? 0)
        }
        invalidateLayout(forCharacterRange: target, actualCharacterRange: nil)

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
