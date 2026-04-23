//
//  AttributeDrawer.swift
//  FSNotes
//
//  Protocol for custom attribute-based drawing in the editor's
//  NSLayoutManager. Each drawer handles one visual effect (borders,
//  backgrounds, boxes). Adding a new visual = one new file implementing
//  this protocol.
//

import Cocoa

/// Draws a custom visual for ranges with a specific text attribute.
protocol AttributeDrawer {
    /// The attribute key this drawer responds to.
    var attributeKey: NSAttributedString.Key { get }

    /// Draw the visual for one attributed range.
    /// Called once per contiguous range where attributeKey is present.
    func draw(value: Any, rect: NSRect, context: CGContext,
              origin: CGPoint, textContainer: NSTextContainer)
}

/// Shared boilerplate for enumerating an attribute and dispatching to a drawer.
/// Replaces the duplicated guard + enumerate + glyphRange + boundingRect + saveGState pattern.
func drawAttributeRanges(
    drawer: AttributeDrawer,
    forGlyphRange glyphsToShow: NSRange,
    at origin: CGPoint,
    layoutManager: NSLayoutManager,
    textStorage: NSTextStorage,
    textContainer: NSTextContainer,
    context: CGContext
) {
    let visibleCharRange = layoutManager.characterRange(forGlyphRange: glyphsToShow, actualGlyphRange: nil)
    let storageFullRange = NSRange(location: 0, length: textStorage.length)
    let safeRange = visibleCharRange.clamped(to: storageFullRange)
    guard safeRange.length > 0 else { return }

    textStorage.enumerateAttribute(drawer.attributeKey, in: safeRange) { value, range, _ in
        guard value != nil else { return }
        let glyphRange = layoutManager.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
        if glyphRange.length == 0 { return }
        let rect = layoutManager.boundingRect(forGlyphRange: glyphRange, in: textContainer)
        if rect.isEmpty { return }

        context.saveGState()
        drawer.draw(value: value!, rect: rect, context: context, origin: origin, textContainer: textContainer)
        context.restoreGState()
    }
}

// MARK: - Fileprivate NSRange extension

fileprivate extension NSRange {
    func clamped(to maxRange: NSRange) -> NSRange {
        if maxRange.length == 0 { return NSRange(location: maxRange.location, length: 0) }
        if self.location >= NSMaxRange(maxRange) { return NSRange(location: NSMaxRange(maxRange), length: 0) }
        let start = max(self.location, maxRange.location)
        let end = min(NSMaxRange(self), NSMaxRange(maxRange))
        if end <= start { return NSRange(location: start, length: 0) }
        return NSRange(location: start, length: end - start)
    }
}
