//
//  ListRenderer.swift
//  FSNotesCore
//
//  Renders a Block.list into an NSAttributedString.
//
//  ARCHITECTURAL CONTRACT:
//  - Input: [ListItem] tree + body font.
//  - Output: NSAttributedString where each item appears on its own
//    line, prefixed by a VISUAL bullet marker, indented by nesting
//    depth. The source markers (`-`, `*`, `+`, `1.`, `2)`) are
//    CONSUMED by the parser — they do NOT appear in the rendered
//    output. For unordered items we emit a "• " glyph; for ordered
//    items we emit the parsed ordinal as "N. ".
//  - Zero `.kern`. Zero clear-color foreground.
//  - Pure function: same input → byte-equal output.
//
//  Visual indentation is two spaces per nesting level — INDEPENDENT
//  of the source indent. This is intentional: the block model stores
//  the original indent for round-trip serialization, but the renderer
//  normalizes indentation so the displayed output is consistent
//  across mixed-indent source files.
//

import Foundation
#if os(OSX)
import AppKit
#else
import UIKit
#endif

public enum ListRenderer {

    // ── Style constants (all font-relative) ──────────────────────────
    //
    // Every visual dimension scales from bodyFont.pointSize so lists
    // look proportional at any font size.
    //
    // Three independent concerns:
    //   cellScale   — how wide the attachment cell is (controls gap to text)
    //   bulletDraw  — how large bullet glyphs (•◦▪▫) render
    //   numberDraw  — how large ordered markers (1. 2.) render
    //
    // Checkboxes use SF Symbols and scale via checkboxDraw.

    /// Nesting indent as a multiple of bodyFont.pointSize.
    static let indentScale: CGFloat = 1.8

    /// Cell width as a multiple of bodyFont.pointSize.
    /// The gap between glyph and text = cellScale - visual glyph width.
    static let cellScale: CGFloat = 2.0

    /// Bullet shape diameter as a fraction of bodyFont.capHeight.
    /// Shapes are drawn directly via Core Graphics — no font metrics.
    static let bulletSizeScale: CGFloat = 0.7

    /// Font size for ordered markers (1., 2.) as multiple of bodyFont.pointSize.
    /// Numbers fill their em-square, so 1× body size looks natural.
    static let numberDrawScale: CGFloat = 1.0

    /// SF Symbol point size for checkboxes as multiple of bodyFont.pointSize.
    static let checkboxDrawScale: CGFloat = 1.2


    /// Render a list to an attributed string. The output is a
    /// newline-separated sequence of rendered items, with no trailing
    /// newline — callers compose list output with sibling blocks via
    /// the usual block-joining newline.
    public static func render(
        items: [ListItem],
        bodyFont: PlatformFont,
        note: Note? = nil
    ) -> NSAttributedString {
        let out = NSMutableAttributedString()
        renderItems(items, depth: 0, bodyFont: bodyFont, note: note, into: out)
        // Remove the trailing "\n" that the last item appended — the
        // block-join layer owns inter-block separators.
        if out.length > 0, out.string.hasSuffix("\n") {
            out.deleteCharacters(in: NSRange(location: out.length - 1, length: 1))
        }
        return out
    }

    private static func renderItems(
        _ items: [ListItem],
        depth: Int,
        bodyFont: PlatformFont,
        note: Note? = nil,
        into out: NSMutableAttributedString
    ) {
        let attrs: [NSAttributedString.Key: Any] = [
            .font: bodyFont,
            .foregroundColor: PlatformColor.label
        ]

        // Hanging indent: the glyph attachment sits at firstLineHeadIndent.
        // Text follows immediately after the cell, and headIndent equals
        // firstLineHeadIndent + cellWidth so wrapped lines align exactly
        // with the first-line text. The visual gap between the visible
        // glyph drawing and the text comes from the cell being larger
        // than the drawn glyph (the glyph is centered in its cell).
        let glyphSize = bodyFont.pointSize * cellScale
        let depthIndent = CGFloat(depth + 1) * bodyFont.pointSize * indentScale
        let textIndent = depthIndent + glyphSize
        let paraStyle = NSMutableParagraphStyle()
        paraStyle.firstLineHeadIndent = depthIndent
        paraStyle.headIndent = textIndent

        var ordinal = 0  // Running counter for ordered items at this level

        for item in items {
            let lineStart = out.length
            if let checkbox = item.checkbox {
                // Todo item: render checkbox via NSTextAttachment.
                // No separator char — gap is built into attachment bounds.
                let cbAttachment = CheckboxAttachment.make(
                    checked: checkbox.isChecked,
                    font: bodyFont
                )
                out.append(cbAttachment)
                // Render inline content with strikethrough if checked.
                if checkbox.isChecked {
                    var checkedAttrs = attrs
                    #if os(OSX)
                    checkedAttrs[.strikethroughStyle] = NSUnderlineStyle.single.rawValue
                    checkedAttrs[.foregroundColor] = NSColor.secondaryLabelColor
                    #else
                    checkedAttrs[.strikethroughStyle] = NSUnderlineStyle.single.rawValue
                    checkedAttrs[.foregroundColor] = UIColor.secondaryLabel
                    #endif
                    out.append(InlineRenderer.render(item.inline, baseAttributes: checkedAttrs, note: note))
                } else {
                    out.append(InlineRenderer.render(item.inline, baseAttributes: attrs, note: note))
                }
            } else {
                // Regular list item: render bullet via attachment.
                // No separator char — gap is built into attachment bounds.
                let bulletGlyph: String
                if isOrderedMarker(item.marker) {
                    ordinal += 1
                    bulletGlyph = "\(ordinal)."
                } else {
                    bulletGlyph = visualBullet(for: item.marker, depth: depth)
                }
                let bulletAttachment = BulletAttachment.make(
                    glyph: bulletGlyph,
                    font: bodyFont
                )
                out.append(bulletAttachment)
                out.append(InlineRenderer.render(item.inline, baseAttributes: attrs, note: note))
            }
            // Apply paragraph style to this item's line.
            let lineRange = NSRange(location: lineStart, length: out.length - lineStart)
            out.addAttribute(.paragraphStyle, value: paraStyle, range: lineRange)

            out.append(NSAttributedString(string: "\n", attributes: attrs))
            if !item.children.isEmpty {
                renderItems(item.children, depth: depth + 1,
                            bodyFont: bodyFont, note: note, into: out)
            }
        }
    }

    /// Whether a marker is an ordered list marker (e.g. "1.", "2)").
    public static func isOrderedMarker(_ marker: String) -> Bool {
        return marker != "-" && marker != "*" && marker != "+"
    }

    /// Map an unordered source marker to its visual glyph, varying
    /// by nesting depth:
    ///   depth 0: • (bullet)
    ///   depth 1: ◦ (white bullet)
    ///   depth 2: ▪ (black small square)
    ///   depth 3+: ▫ (white small square), then cycles back
    public static func visualBullet(for marker: String, depth: Int = 0) -> String {
        if marker == "-" || marker == "*" || marker == "+" {
            let bullets = ["\u{2022}", "\u{25E6}", "\u{25AA}", "\u{25AB}"]  // • ◦ ▪ ▫
            return bullets[depth % bullets.count]
        }
        return marker
    }
}

// MARK: - Bullet Attachment

/// Renders a bullet glyph (•, ◦, ▪, ▫, or ordered "1.") as an
/// NSTextAttachment so the glyph can be sized independently of the
/// body font without affecting line height.
#if os(OSX)
private class BulletAttachmentCell: NSTextAttachmentCell {
    let glyph: String
    let cellWidth: CGFloat
    let bodyFont: PlatformFont
    let cellHeight: CGFloat

    init(glyph: String, cellWidth: CGFloat, bodyPointSize: CGFloat) {
        self.glyph = glyph
        self.cellWidth = cellWidth
        self.bodyFont = PlatformFont.systemFont(ofSize: bodyPointSize)
        self.cellHeight = bodyFont.ascender + abs(bodyFont.descender)
        super.init()
    }

    required init(coder: NSCoder) {
        fatalError("init(coder:) not supported")
    }

    override func cellSize() -> NSSize {
        return NSSize(width: cellWidth, height: cellHeight)
    }

    override func cellBaselineOffset() -> NSPoint {
        return NSPoint(x: 0, y: -abs(bodyFont.descender))
    }

    /// Which shape to draw for unordered bullet glyphs.
    private enum BulletShape {
        case filledCircle   // depth 0: •
        case openCircle     // depth 1: ◦
        case filledSquare   // depth 2: ▪
        case openSquare     // depth 3: ▫
    }

    private var bulletShape: BulletShape? {
        switch glyph {
        case "\u{2022}": return .filledCircle
        case "\u{25E6}": return .openCircle
        case "\u{25AA}": return .filledSquare
        case "\u{25AB}": return .openSquare
        default: return nil
        }
    }

    override func draw(withFrame cellFrame: NSRect, in controlView: NSView?) {
        let baseline = cellFrame.minY + abs(bodyFont.descender)
        let capCenter = baseline + bodyFont.capHeight / 2

        if let shape = bulletShape {
            // Draw shape directly — no font metrics involved.
            let diameter = bodyFont.capHeight * ListRenderer.bulletSizeScale
            let x = cellFrame.minX
            let y = capCenter - diameter / 2
            let rect = NSRect(x: x, y: y, width: diameter, height: diameter)
            let color = PlatformColor.labelColor
            color.setFill()
            color.setStroke()
            switch shape {
            case .filledCircle:
                NSBezierPath(ovalIn: rect).fill()
            case .openCircle:
                let path = NSBezierPath(ovalIn: rect.insetBy(dx: 0.5, dy: 0.5))
                path.lineWidth = 1.0
                path.stroke()
            case .filledSquare:
                NSBezierPath(rect: rect).fill()
            case .openSquare:
                let path = NSBezierPath(rect: rect.insetBy(dx: 0.5, dy: 0.5))
                path.lineWidth = 1.0
                path.stroke()
            }
        } else {
            // Ordered marker (1., 2., etc.) — draw at body font size,
            // baseline-aligned with the body text.
            let numberFont = PlatformFont.systemFont(
                ofSize: bodyFont.pointSize * ListRenderer.numberDrawScale,
                weight: .regular
            )
            let color = PlatformColor.labelColor
            let attrs: [NSAttributedString.Key: Any] = [
                .font: numberFont,
                .foregroundColor: color,
            ]
            let str = glyph as NSString
            let x = cellFrame.minX
            let y = baseline - abs(numberFont.descender)
            str.draw(at: NSPoint(x: x, y: y), withAttributes: attrs)
        }
    }
}
#endif

/// NSTextAttachment subclass with value-based equality so that
/// two renders of the same bullet produce equal attachments (required
/// by the idempotency test).
public class BulletTextAttachment: NSTextAttachment {
    public let glyph: String
    public let glyphSize: CGFloat

    public init(glyph: String, size: CGFloat) {
        self.glyph = glyph
        self.glyphSize = size
        super.init(data: nil, ofType: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) not supported")
    }

    public override func isEqual(_ object: Any?) -> Bool {
        guard let other = object as? BulletTextAttachment else { return false }
        return glyph == other.glyph && glyphSize == other.glyphSize
    }

    public override var hash: Int {
        var h = Hasher()
        h.combine(glyph)
        h.combine(glyphSize)
        return h.finalize()
    }
}

public enum BulletAttachment {
    /// Create an attributed string containing a single bullet glyph
    /// attachment character. Cell width = cellScale × font.pointSize.
    /// Cell height = body font line height (ascender + |descender|).
    public static func make(
        glyph: String,
        font: PlatformFont
    ) -> NSAttributedString {
        let cellWidth = font.pointSize * ListRenderer.cellScale
        let cellHeight = font.ascender + abs(font.descender)
        let attachment = BulletTextAttachment(glyph: glyph, size: cellWidth)
        #if os(OSX)
        let cell = BulletAttachmentCell(
            glyph: glyph,
            cellWidth: cellWidth,
            bodyPointSize: font.pointSize
        )
        attachment.attachmentCell = cell
        #endif
        attachment.bounds = CGRect(
            x: 0, y: -abs(font.descender),
            width: cellWidth, height: cellHeight
        )
        let result = NSMutableAttributedString(attachment: attachment)
        result.addAttribute(.font, value: font, range: NSRange(location: 0, length: result.length))
        return result
    }
}

// MARK: - Checkbox Attachment

/// Renders a checkbox as an NSTextAttachment using SF Symbols so the
/// glyph size doesn't affect line height and the style matches the
/// toolbar icons.
#if os(OSX)
private class CheckboxAttachmentCell: NSTextAttachmentCell {
    let isChecked: Bool
    let cellWidth: CGFloat
    let bodyFont: PlatformFont
    let cellHeight: CGFloat
    let cachedImage: NSImage?

    init(checked: Bool, cellWidth: CGFloat, bodyPointSize: CGFloat) {
        self.isChecked = checked
        self.cellWidth = cellWidth
        self.bodyFont = PlatformFont.systemFont(ofSize: bodyPointSize)
        self.cellHeight = bodyFont.ascender + abs(bodyFont.descender)
        // Pre-render the tinted SF Symbol once instead of every draw call.
        let symbolName = checked ? "checkmark.square" : "square"
        let drawSize = bodyPointSize * ListRenderer.checkboxDrawScale
        if let img = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil) {
            let config = NSImage.SymbolConfiguration(pointSize: drawSize, weight: .regular)
            let configured = img.withSymbolConfiguration(config) ?? img
            self.cachedImage = configured.tinted(with: NSColor.secondaryLabelColor)
        } else {
            self.cachedImage = nil
        }
        super.init()
    }

    required init(coder: NSCoder) {
        fatalError("init(coder:) not supported")
    }

    override func cellSize() -> NSSize {
        return NSSize(width: cellWidth, height: cellHeight)
    }

    override func cellBaselineOffset() -> NSPoint {
        return NSPoint(x: 0, y: -abs(bodyFont.descender))
    }

    override func draw(withFrame cellFrame: NSRect, in controlView: NSView?) {
        guard let tinted = cachedImage else { return }
        let imgSize = tinted.size
        let baseline = cellFrame.minY + abs(bodyFont.descender)
        let textCenter = baseline + bodyFont.capHeight / 2
        let x = cellFrame.minX
        let y = textCenter - imgSize.height / 2
        tinted.draw(in: NSRect(x: x, y: y, width: imgSize.width, height: imgSize.height))
    }
}

private extension NSImage {
    func tinted(with color: NSColor) -> NSImage {
        let img = self.copy() as! NSImage
        img.lockFocus()
        color.set()
        NSRect(origin: .zero, size: img.size).fill(using: .sourceAtop)
        img.unlockFocus()
        img.isTemplate = false
        return img
    }
}
#endif

/// NSTextAttachment subclass with value-based equality so that
/// two renders of the same checkbox produce equal attachments.
public class CheckboxTextAttachment: NSTextAttachment {
    public let isChecked: Bool
    public let boxSize: CGFloat

    public init(checked: Bool, size: CGFloat) {
        self.isChecked = checked
        self.boxSize = size
        super.init(data: nil, ofType: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) not supported")
    }

    public override func isEqual(_ object: Any?) -> Bool {
        guard let other = object as? CheckboxTextAttachment else { return false }
        return isChecked == other.isChecked && boxSize == other.boxSize
    }

    public override var hash: Int {
        var h = Hasher()
        h.combine(isChecked)
        h.combine(boxSize)
        return h.finalize()
    }
}

public enum CheckboxAttachment {
    /// Create an attributed string containing a single checkbox
    /// attachment character. Cell width = cellScale × font.pointSize.
    /// Cell height = body font line height.
    public static func make(
        checked: Bool,
        font: PlatformFont
    ) -> NSAttributedString {
        let cellWidth = font.pointSize * ListRenderer.cellScale
        let cellHeight = font.ascender + abs(font.descender)
        let attachment = CheckboxTextAttachment(checked: checked, size: cellWidth)
        #if os(OSX)
        let cell = CheckboxAttachmentCell(
            checked: checked,
            cellWidth: cellWidth,
            bodyPointSize: font.pointSize
        )
        attachment.attachmentCell = cell
        #endif
        attachment.bounds = CGRect(
            x: 0, y: -abs(font.descender),
            width: cellWidth, height: cellHeight
        )
        let result = NSMutableAttributedString(attachment: attachment)
        result.addAttribute(.font, value: font, range: NSRange(location: 0, length: result.length))
        return result
    }
}
