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
        return false
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

            let midY = lineFragRect.midY + origin.y

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

        NSGraphicsContext.current?.restoreGraphicsState()
    }
}
