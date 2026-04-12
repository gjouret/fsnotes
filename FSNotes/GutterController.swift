//
//  GutterController.swift
//  FSNotes
//
//  Manages the left-hand gutter (pipe) in the editor: fold/unfold carets,
//  header level badges, mouse hover tracking, and click handling.
//  Extracted from EditTextView to reduce god object size.
//

import Cocoa

class GutterController {

    weak var textView: EditTextView?
    var isMouseInGutter = false

    /// Tracks which code block just had its content copied (for "Copied" feedback).
    private var copiedCodeBlockLocation: Int?
    /// Tracks which table just had its content copied (for "Copied" feedback).
    private var copiedTableLocation: Int?
    private var copiedFeedbackTimer: Timer?

    init(textView: EditTextView) {
        self.textView = textView
    }

    // MARK: - Click Handling

    func handleClick(_ event: NSEvent) -> Bool {
        guard let textView = textView else { return false }
        let point = textView.convert(event.locationInWindow, from: nil)
        let gutterWidth = EditTextView.gutterWidth

        let gutterRight = textView.textContainerInset.width
        let gutterLeft = gutterRight - gutterWidth
        guard point.x >= gutterLeft, point.x < gutterRight else { return false }

        guard let manager = textView.layoutManager,
              let container = textView.textContainer,
              let storage = textView.textStorage,
              let processor = textView.textStorageProcessor else { return false }

        let textPoint = NSPoint(x: textView.textContainerInset.width + 1, y: point.y)
        let charIndex = manager.characterIndex(for: textPoint, in: container,
                                                fractionOfDistanceBetweenInsertionPoints: nil)
        guard charIndex < storage.length else { return false }

        if let blockIdx = processor.headerBlockIndex(at: charIndex) {
            processor.toggleFold(headerBlockIndex: blockIdx, textStorage: storage)
            textView.needsDisplay = true
            return true
        }

        // Try code block copy, then table copy
        if handleCodeBlockCopy(event) { return true }
        return handleTableCopy(event)
    }

    // MARK: - Fold Actions

    func toggleFoldAtCursor() {
        guard let textView = textView,
              let storage = textView.textStorage,
              let processor = textView.textStorageProcessor else { return }
        let cursorPos = textView.selectedRange().location
        if let idx = processor.headerBlockIndex(at: cursorPos) {
            processor.toggleFold(headerBlockIndex: idx, textStorage: storage)
            textView.needsDisplay = true
        }
    }

    /// Fold the header on the cursor line (no-op if not on a header or already folded).
    func foldAtCursor() {
        guard let textView = textView,
              let storage = textView.textStorage,
              let processor = textView.textStorageProcessor else { return }
        let cursorPos = textView.selectedRange().location
        if let idx = processor.headerBlockIndex(at: cursorPos) {
            processor.foldHeader(headerBlockIndex: idx, textStorage: storage)
            textView.needsDisplay = true
        }
    }

    /// Unfold the header on the cursor line (no-op if not on a header or already unfolded).
    func unfoldAtCursor() {
        guard let textView = textView,
              let storage = textView.textStorage,
              let processor = textView.textStorageProcessor else { return }
        let cursorPos = textView.selectedRange().location
        if let idx = processor.headerBlockIndex(at: cursorPos) {
            processor.unfoldHeader(headerBlockIndex: idx, textStorage: storage)
            textView.needsDisplay = true
        }
    }

    func foldAllHeaders() {
        guard let textView = textView,
              let storage = textView.textStorage,
              let processor = textView.textStorageProcessor else { return }
        processor.foldAll(textStorage: storage)
        textView.needsDisplay = true
    }

    func unfoldAllHeaders() {
        guard let textView = textView,
              let storage = textView.textStorage,
              let processor = textView.textStorageProcessor else { return }
        processor.unfoldAll(textStorage: storage)
        textView.needsDisplay = true
    }

    // MARK: - Hover Tracking

    func updateMouseTracking(at point: NSPoint) {
        guard let textView = textView else { return }
        let inGutter = point.x < textView.textContainerInset.width &&
                       point.x >= textView.textContainerInset.width - EditTextView.gutterWidth
        if inGutter != isMouseInGutter {
            isMouseInGutter = inGutter
            textView.needsDisplay = true
        }
    }

    // MARK: - Drawing

    func drawIcons(in dirtyRect: NSRect) {
        guard let textView = textView,
              let storage = textView.textStorage,
              let lm = textView.layoutManager as? LayoutManager,
              let container = textView.textContainer,
              let processor = textView.textStorageProcessor else { return }
        guard !processor.blocks.isEmpty else { return }

        let origin = textView.textContainerOrigin
        let gutterWidth = EditTextView.gutterWidth
        let gutterLeft = origin.x - gutterWidth
        let gutterRight = origin.x

        // Reset clip to include gutter area
        NSGraphicsContext.current?.saveGraphicsState()
        NSBezierPath(rect: textView.bounds).setClip()

        let visibleRect = textView.enclosingScrollView?.contentView.bounds ?? textView.bounds
        let visibleGlyphRange = lm.glyphRange(forBoundingRect: visibleRect, in: container)
        let visibleCharRange = lm.characterRange(forGlyphRange: visibleGlyphRange, actualGlyphRange: nil)

        let cursorParagraphRange: NSRange? = {
            let idx = lm.cursorCharIndex
            guard idx >= 0, idx < storage.length else { return nil }
            return (storage.string as NSString).paragraphRange(for: NSRange(location: idx, length: 0))
        }()

        for block in processor.blocks {
            let level: Int
            switch block.type {
            case .heading(let l): level = l
            case .headingSetext(let l): level = l
            default: continue
            }

            guard NSIntersectionRange(block.range, visibleCharRange).length > 0 else { continue }
            guard block.range.location < storage.length,
                  NSMaxRange(block.range) <= storage.length else { continue }
            if storage.attribute(.foldedContent, at: block.range.location, effectiveRange: nil) != nil { continue }

            let glyphRange = lm.glyphRange(forCharacterRange: block.range, actualCharacterRange: nil)
            if glyphRange.length == 0 { continue }
            let lineFragRect = lm.lineFragmentRect(forGlyphAt: glyphRange.location, effectiveRange: nil)
            if lineFragRect.isEmpty { continue }

            // Use lineFragmentUsedRect for the visual center of the text.
            // lineFragRect includes paragraph spacing which pushes glyphs
            // down relative to the rect's geometric center. usedRect is
            // tighter to the actual glyphs.
            let usedRect = lm.lineFragmentUsedRect(forGlyphAt: glyphRange.location, effectiveRange: nil)
            let midY = usedRect.midY + origin.y

            // Fold caret — only on hover or when collapsed
            let isCollapsed = block.collapsed
            if isMouseInGutter || isCollapsed {
                let caretStr = isCollapsed ? "▶" : "▼"
                let caretFont = NSFont.systemFont(ofSize: 16, weight: .regular)
                let caretAttrs: [NSAttributedString.Key: Any] = [
                    .font: caretFont,
                    .foregroundColor: NSColor(calibratedWhite: 0.55, alpha: 1.0)
                ]
                let caretSize = (caretStr as NSString).size(withAttributes: caretAttrs)
                let caretX = gutterRight - caretSize.width - 4
                let caretY = midY - caretSize.height / 2
                (caretStr as NSString).draw(at: NSPoint(x: caretX, y: caretY), withAttributes: caretAttrs)
            }

            // H-level badge — on hover or when cursor is on this line
            let cursorOnThisLine = cursorParagraphRange.map { NSIntersectionRange($0, block.range).length > 0 } ?? false
            let isEditing = textView.window?.firstResponder === textView
            if isMouseInGutter || (cursorOnThisLine && isEditing) {
                let badge = "H\(level)"
                let badgeAttrs: [NSAttributedString.Key: Any] = [
                    .font: NSFont.systemFont(ofSize: 9, weight: .bold),
                    .foregroundColor: NSColor.gray
                ]
                let badgeSize = (badge as NSString).size(withAttributes: badgeAttrs)
                (badge as NSString).draw(at: NSPoint(x: gutterLeft + 2, y: midY - badgeSize.height / 2), withAttributes: badgeAttrs)
            }

            // "⋯" after collapsed header
            if isCollapsed {
                let ellipsis = " ⋯ "
                let ellipsisAttrs: [NSAttributedString.Key: Any] = [
                    .font: NSFont.systemFont(ofSize: 20, weight: .medium),
                    .foregroundColor: NSColor(calibratedWhite: 0.5, alpha: 1.0),
                    .backgroundColor: NSColor(calibratedWhite: 0.92, alpha: 1.0)
                ]
                let usedRect = lm.lineFragmentUsedRect(forGlyphAt: glyphRange.location, effectiveRange: nil)
                let ellipsisSize = (ellipsis as NSString).size(withAttributes: ellipsisAttrs)
                (ellipsis as NSString).draw(at: NSPoint(x: usedRect.maxX + origin.x + 4, y: midY - ellipsisSize.height / 2), withAttributes: ellipsisAttrs)
            }
        }

        // Code block copy icons — shown on gutter hover
        if isMouseInGutter {
            for block in processor.blocks {
                guard case .codeBlock = block.type, block.renderMode == .source else { continue }
                guard NSIntersectionRange(block.range, visibleCharRange).length > 0 else { continue }
                guard block.range.location < storage.length,
                      NSMaxRange(block.range) <= storage.length else { continue }

                let glyphRange = lm.glyphRange(forCharacterRange: block.range, actualCharacterRange: nil)
                if glyphRange.length == 0 { continue }
                let lineFragRect = lm.lineFragmentRect(forGlyphAt: glyphRange.location, effectiveRange: nil)
                if lineFragRect.isEmpty { continue }

                let midY = lineFragRect.midY + origin.y

                let isCopied = (copiedCodeBlockLocation == block.range.location)
                let iconStr = isCopied ? "\u{2713}" : "\u{2398}" // ✓ or ⎘ (copy)
                let iconAttrs: [NSAttributedString.Key: Any] = [
                    .font: NSFont.systemFont(ofSize: 26, weight: .regular),
                    .foregroundColor: NSColor(calibratedWhite: 0.55, alpha: 1.0)
                ]
                let iconSize = (iconStr as NSString).size(withAttributes: iconAttrs)
                let iconX = gutterRight - iconSize.width - 4
                let iconY = midY - iconSize.height / 2
                (iconStr as NSString).draw(at: NSPoint(x: iconX, y: iconY), withAttributes: iconAttrs)
            }
        }

        // Table copy icons — shown on gutter hover. Tables are rendered as single-char
        // attachments; enumerate attachments with renderedBlockType == "table" in the visible range.
        if isMouseInGutter {
            let tableTypeValue = RenderedBlockType.table.rawValue
            storage.enumerateAttribute(.renderedBlockType, in: visibleCharRange, options: []) { value, range, _ in
                guard let type = value as? String, type == tableTypeValue else { return }
                guard range.location < storage.length else { return }

                let glyphRange = lm.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
                if glyphRange.length == 0 { return }
                let lineFragRect = lm.lineFragmentRect(forGlyphAt: glyphRange.location, effectiveRange: nil)
                if lineFragRect.isEmpty { return }

                // Place icon at top of attachment (aligned with column handles).
                let iconTopY = lineFragRect.minY + origin.y + 4

                let isCopied = (copiedTableLocation == range.location)
                let iconStr = isCopied ? "\u{2713}" : "\u{2398}" // ✓ or ⎘
                let iconAttrs: [NSAttributedString.Key: Any] = [
                    .font: NSFont.systemFont(ofSize: 26, weight: .regular),
                    .foregroundColor: NSColor(calibratedWhite: 0.55, alpha: 1.0)
                ]
                let iconSize = (iconStr as NSString).size(withAttributes: iconAttrs)
                let iconX = gutterRight - iconSize.width - 4
                (iconStr as NSString).draw(at: NSPoint(x: iconX, y: iconTopY), withAttributes: iconAttrs)
            }
        }

        NSGraphicsContext.current?.restoreGraphicsState()
    }

    // MARK: - Code Block Copy

    func handleCodeBlockCopy(_ event: NSEvent) -> Bool {
        guard let textView = textView else { return false }
        let point = textView.convert(event.locationInWindow, from: nil)
        let gutterWidth = EditTextView.gutterWidth

        let gutterRight = textView.textContainerInset.width
        let gutterLeft = gutterRight - gutterWidth
        guard point.x >= gutterLeft, point.x < gutterRight else { return false }

        guard let manager = textView.layoutManager,
              let container = textView.textContainer,
              let storage = textView.textStorage,
              let processor = textView.textStorageProcessor else { return false }

        let origin = textView.textContainerOrigin
        let textPoint = NSPoint(x: textView.textContainerInset.width + 1, y: point.y)
        let charIndex = manager.characterIndex(for: textPoint, in: container,
                                                fractionOfDistanceBetweenInsertionPoints: nil)
        guard charIndex < storage.length else { return false }

        for block in processor.blocks {
            guard case .codeBlock = block.type, block.renderMode == .source else { continue }
            guard NSLocationInRange(charIndex, block.range) else { continue }

            // Check if click is on the first line (where the icon is drawn)
            let glyphRange = manager.glyphRange(forCharacterRange: block.range, actualCharacterRange: nil)
            if glyphRange.length == 0 { continue }
            let lineFragRect = manager.lineFragmentRect(forGlyphAt: glyphRange.location, effectiveRange: nil)
            let iconY = lineFragRect.midY + origin.y
            guard abs(point.y - iconY) < lineFragRect.height / 2 else { continue }

            // Extract content (between fences, excluding delimiters)
            let maxLen = storage.length
            let loc = min(block.contentRange.location, maxLen)
            let len = min(block.contentRange.length, maxLen - loc)
            let safeRange = NSRange(location: loc, length: len)
            let codeText = (storage.string as NSString).substring(with: safeRange)

            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(codeText, forType: .string)

            // Show "Copied" feedback
            copiedCodeBlockLocation = block.range.location
            textView.needsDisplay = true
            copiedFeedbackTimer?.invalidate()
            copiedFeedbackTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: false) { [weak self] _ in
                self?.copiedCodeBlockLocation = nil
                self?.textView?.needsDisplay = true
            }
            return true
        }
        return false
    }

    // MARK: - Table Copy

    func handleTableCopy(_ event: NSEvent) -> Bool {
        guard let textView = textView else { return false }
        let point = textView.convert(event.locationInWindow, from: nil)
        let gutterWidth = EditTextView.gutterWidth

        let gutterRight = textView.textContainerInset.width
        let gutterLeft = gutterRight - gutterWidth
        guard point.x >= gutterLeft, point.x < gutterRight else { return false }

        guard let manager = textView.layoutManager,
              let container = textView.textContainer,
              let storage = textView.textStorage else { return false }

        let origin = textView.textContainerOrigin
        let textPoint = NSPoint(x: textView.textContainerInset.width + 1, y: point.y)
        let charIndex = manager.characterIndex(for: textPoint, in: container,
                                                fractionOfDistanceBetweenInsertionPoints: nil)
        guard charIndex < storage.length else { return false }

        let tableTypeValue = RenderedBlockType.table.rawValue
        guard let type = storage.attribute(.renderedBlockType, at: charIndex, effectiveRange: nil) as? String,
              type == tableTypeValue,
              let markdown = storage.attribute(.renderedBlockOriginalMarkdown, at: charIndex, effectiveRange: nil) as? String else {
            return false
        }

        // Verify the click is near the top of the attachment (where the icon is drawn).
        var effective = NSRange(location: 0, length: 0)
        _ = storage.attribute(.renderedBlockType, at: charIndex, effectiveRange: &effective)
        let glyphRange = manager.glyphRange(forCharacterRange: effective, actualCharacterRange: nil)
        guard glyphRange.length > 0 else { return false }
        let lineFragRect = manager.lineFragmentRect(forGlyphAt: glyphRange.location, effectiveRange: nil)
        let iconTopY = lineFragRect.minY + origin.y + 4
        // ~30-pixel tall hitbox around the icon (icon is 26pt tall).
        guard point.y >= iconTopY - 4, point.y <= iconTopY + 30 else { return false }

        guard let data = TableUtility.parse(markdown: markdown) else { return false }

        // Build TSV
        var tsvLines: [String] = [data.headers.joined(separator: "\t")]
        for row in data.rows { tsvLines.append(row.joined(separator: "\t")) }
        let tsv = tsvLines.joined(separator: "\n")

        // Build HTML
        func escape(_ s: String) -> String {
            return s.replacingOccurrences(of: "&", with: "&amp;")
                    .replacingOccurrences(of: "<", with: "&lt;")
                    .replacingOccurrences(of: ">", with: "&gt;")
        }
        var html = "<table>"
        html += "<thead><tr>" + data.headers.map { "<th>" + escape($0) + "</th>" }.joined() + "</tr></thead>"
        html += "<tbody>"
        for row in data.rows {
            html += "<tr>" + row.map { "<td>" + escape($0) + "</td>" }.joined() + "</tr>"
        }
        html += "</tbody></table>"

        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(tsv, forType: .string)
        NSPasteboard.general.setString(tsv, forType: NSPasteboard.PasteboardType(rawValue: "public.utf8-tab-separated-values-text"))
        NSPasteboard.general.setString(html, forType: .html)

        // Show "Copied" feedback
        copiedTableLocation = effective.location
        textView.needsDisplay = true
        copiedFeedbackTimer?.invalidate()
        copiedFeedbackTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: false) { [weak self] _ in
            self?.copiedTableLocation = nil
            self?.textView?.needsDisplay = true
        }
        return true
    }
}
