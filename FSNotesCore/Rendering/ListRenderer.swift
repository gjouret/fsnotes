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
    //
    // Phase 7.3: values now read from `Theme.shared` instead of being
    // file-local constants. Default-theme values in `BlockStyleTheme.default`
    // match the pre-theme hardcoded constants byte-for-byte.

    /// Nesting indent as a multiple of bodyFont.pointSize. Default = 1.8.
    static var indentScale: CGFloat { Theme.shared.listIndentScale }

    /// Cell width as a multiple of bodyFont.pointSize. Default = 2.0.
    /// The gap between glyph and text = cellScale - visual glyph width.
    static var cellScale: CGFloat { Theme.shared.listCellScale }

    /// Bullet shape diameter as a fraction of bodyFont.capHeight.
    /// Default = 0.7. Shapes are drawn directly via Core Graphics — no
    /// font metrics.
    static var bulletSizeScale: CGFloat { Theme.shared.listBulletSizeScale }

    /// Font size for ordered markers (1., 2.) as multiple of
    /// bodyFont.pointSize. Default = 1.0. Numbers fill their em-square,
    /// so 1× body size looks natural.
    static var numberDrawScale: CGFloat { Theme.shared.listNumberDrawScale }

    /// SF Symbol point size for checkboxes as multiple of
    /// bodyFont.pointSize. Default = 1.2.
    static var checkboxDrawScale: CGFloat { Theme.shared.listCheckboxDrawScale }

    /// Natural line height for `font` as the TK1 typesetter actually
    /// produces it for a line containing a single body-font glyph.
    ///
    /// We measure this by running NSLayoutManager over a one-character
    /// attributed string in the same font, with `lineFragmentPadding = 0`
    /// — matching the configuration used by the live editor. This
    /// matches whatever the typesetter does on the current OS (including
    /// sub-pixel quirks that differ across hosts and Xcode versions),
    /// rather than approximating with font-metric arithmetic.
    ///
    /// Bullet / checkbox attachment cells must use this value or an
    /// empty list item will be ~0.5pt shorter than a populated one,
    /// producing a visible vertical shift when the user types the
    /// first character (Bug 20 vertical component). The simple sum
    /// `ascender + |descender| + leading` under-sums because
    /// macOS system-font `leading` is 0.
    ///
    /// Memoized by `(fontName, pointSize)` key. Every bullet/checkbox
    /// attachment construction calls through here; measuring the
    /// typesetter requires allocating a fresh `NSLayoutManager` +
    /// `NSTextContainer` + `NSTextStorage`, so the cache avoids that
    /// per-bullet overhead in notes with many list items. The cache
    /// key is intentionally coarse — two fonts with the same name and
    /// size have identical metrics on a given platform, and we don't
    /// care about subtle weight/width axis variants for bullet cell
    /// sizing.
    private static let lineHeightCache = NSCache<NSString, NSNumber>()

    static func naturalLineHeight(for font: PlatformFont) -> CGFloat {
        #if os(OSX)
        let key = "\(font.fontName)|\(font.pointSize)" as NSString
        if let cached = lineHeightCache.object(forKey: key) {
            return CGFloat(cached.doubleValue)
        }
        let storage = NSTextStorage(
            attributedString: NSAttributedString(
                string: "X", attributes: [.font: font]
            )
        )
        let layout = NSLayoutManager()
        let container = NSTextContainer(size: CGSize(width: 10000, height: 10000))
        container.lineFragmentPadding = 0
        layout.addTextContainer(container)
        storage.addLayoutManager(layout)
        _ = layout.glyphRange(for: container)
        var effRange = NSRange()
        let rect = layout.lineFragmentRect(forGlyphAt: 0, effectiveRange: &effRange)
        let height = rect.size.height
        lineHeightCache.setObject(NSNumber(value: Double(height)), forKey: key)
        return height
        #else
        return font.ascender + abs(font.descender) + font.leading
        #endif
    }


    /// Render a list to an attributed string. The output is a
    /// newline-separated sequence of rendered items, with no trailing
    /// newline — callers compose list output with sibling blocks via
    /// the usual block-joining newline.
    ///
    /// Phase 7.2: accepts an optional `theme` parameter that gets
    /// forwarded to `InlineRenderer.render` for inline-content
    /// styling. List-level layout constants (indent, cell size, bullet
    /// draw scale) stay in-file for now; Phase 7.3 migrates them.
    public static func render(
        items: [ListItem],
        bodyFont: PlatformFont,
        note: Note? = nil,
        theme: Theme = .shared
    ) -> NSAttributedString {
        let out = NSMutableAttributedString()
        renderItems(items, depth: 0, bodyFont: bodyFont, note: note, theme: theme, into: out)
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
        theme: Theme = .shared,
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
                    out.append(InlineRenderer.render(item.inline, baseAttributes: checkedAttrs, note: note, theme: theme))
                } else {
                    out.append(InlineRenderer.render(item.inline, baseAttributes: attrs, note: note, theme: theme))
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
                out.append(InlineRenderer.render(item.inline, baseAttributes: attrs, note: note, theme: theme))
            }
            // Apply paragraph style to this item's line.
            let lineRange = NSRange(location: lineStart, length: out.length - lineStart)
            out.addAttribute(.paragraphStyle, value: paraStyle, range: lineRange)

            out.append(NSAttributedString(string: "\n", attributes: attrs))
            if !item.children.isEmpty {
                renderItems(item.children, depth: depth + 1,
                            bodyFont: bodyFont, note: note, theme: theme, into: out)
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

    #if os(OSX)
    // Sized blank NSImage used as `NSTextAttachment.image` to suppress
    // AppKit's generic document-icon glyph during the window between
    // TK2's first layout pass and the attachment view provider's
    // loadView completing.
    //
    // Memoized by size: a 500-bullet note with one bullet size would
    // otherwise allocate 500 images + 500 `lockFocus`/`unlockFocus`
    // pairs per render. In practice there are typically only a handful
    // of distinct sizes across a render (bullet cell, checkbox cell,
    // table default) so the cache hit rate is very high.
    //
    // `NSCache` is thread-safe; the helper is called on the main
    // thread during rendering today but we don't rely on that.
    private static let placeholderCache: NSCache<NSValue, NSImage> = {
        let cache = NSCache<NSValue, NSImage>()
        // 64 distinct sizes is far above the realistic working set but
        // well below anything that would matter for memory. NSImage
        // backing a 0×0-to-tens-of-points placeholder is tiny.
        cache.countLimit = 64
        return cache
    }()

    static func transparentPlaceholder(size: CGSize) -> NSImage {
        let key = NSValue(size: size)
        if let cached = placeholderCache.object(forKey: key) {
            return cached
        }
        let image = NSImage(size: size)
        image.lockFocus()
        image.unlockFocus()
        placeholderCache.setObject(image, forKey: key)
        return image
    }

    static func bulletMarkerImage(
        glyph: String,
        size: CGSize,
        bodyPointSize: CGFloat
    ) -> NSImage {
        let pointSize = max(1, bodyPointSize)
        let bodyFont = PlatformFont.systemFont(ofSize: pointSize)
        return NSImage(size: size, flipped: false) { rect in
            let baseline = rect.minY + abs(bodyFont.descender)
            let capCenter = baseline + bodyFont.capHeight / 2

            switch glyph {
            case "\u{2022}", "\u{25E6}", "\u{25AA}", "\u{25AB}":
                let diameter = bodyFont.capHeight * ListRenderer.bulletSizeScale
                let markerRect = NSRect(
                    x: rect.minX,
                    y: capCenter - diameter / 2,
                    width: diameter,
                    height: diameter
                )
                PlatformColor.labelColor.setFill()
                PlatformColor.labelColor.setStroke()
                switch glyph {
                case "\u{2022}":
                    NSBezierPath(ovalIn: markerRect).fill()
                case "\u{25E6}":
                    let path = NSBezierPath(ovalIn: markerRect.insetBy(dx: 0.5, dy: 0.5))
                    path.lineWidth = 1.0
                    path.stroke()
                case "\u{25AA}":
                    NSBezierPath(rect: markerRect).fill()
                default:
                    let path = NSBezierPath(rect: markerRect.insetBy(dx: 0.5, dy: 0.5))
                    path.lineWidth = 1.0
                    path.stroke()
                }
            default:
                let numberFont = PlatformFont.systemFont(
                    ofSize: pointSize * ListRenderer.numberDrawScale,
                    weight: .regular
                )
                let attrs: [NSAttributedString.Key: Any] = [
                    .font: numberFont,
                    .foregroundColor: PlatformColor.labelColor,
                ]
                let y = baseline - abs(numberFont.descender)
                (glyph as NSString).draw(
                    at: NSPoint(x: rect.minX, y: y),
                    withAttributes: attrs
                )
            }
            return true
        }
    }

    static func checkboxMarkerImage(
        checked: Bool,
        size: CGSize,
        bodyPointSize: CGFloat
    ) -> NSImage {
        let pointSize = max(1, bodyPointSize)
        return NSImage(size: size, flipped: false) { rect in
            let bodyFont = PlatformFont.systemFont(ofSize: pointSize)
            let drawSize = pointSize * ListRenderer.checkboxDrawScale
            let symbolName = checked ? "checkmark.square" : "square"
            guard let base = NSImage(
                systemSymbolName: symbolName,
                accessibilityDescription: nil
            ) else {
                return true
            }
            let config = NSImage.SymbolConfiguration(
                pointSize: drawSize,
                weight: .regular
            )
            let image = base.withSymbolConfiguration(config) ?? base
            let baseline = rect.minY + abs(bodyFont.descender)
            let textCenter = baseline + bodyFont.capHeight / 2
            let imageSize = image.size
            let imageRect = NSRect(
                x: rect.minX,
                y: textCenter - imageSize.height / 2,
                width: imageSize.width,
                height: imageSize.height
            )

            image
                .tinted(with: NSColor.secondaryLabelColor)
                .draw(in: imageRect)
            return true
        }
    }
    #endif
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
        // Use NSLayoutManager's defaultLineHeight to match the natural
        // line height of text-bearing lines exactly. On modern macOS
        // the system font's `leading` is 0, so `ascender+|descender|+leading`
        // under-sums by ~0.5pt vs the typesetter's actual line height,
        // causing an empty list item to be ~0.5pt shorter than a
        // populated one (Bug 20 vertical component).
        self.cellHeight = ListRenderer.naturalLineHeight(for: bodyFont)
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
///
/// TK1 path: the attachment is given an `NSTextAttachmentCell` subclass
/// (`BulletAttachmentCell`) via `BulletAttachment.make(...)`, which TK1
/// asks to `draw(withFrame:in:)` at layout time.
///
/// TK2 path: list markers are static, non-interactive graphics. They
/// render through `NSTextAttachment.imageForBounds(...)` using the
/// image assigned by `BulletAttachment.make(...)`, not through an
/// `NSTextAttachmentViewProvider`. Avoiding a hosted subview removes
/// the provider mount/unmount lifecycle that made the active edited
/// line's glyph disappear under TextKit 2.
public class BulletTextAttachment: NSTextAttachment {
    public let glyph: String
    public let glyphSize: CGFloat
    /// Body font point size used by the marker image to size the glyph.
    /// The cellWidth alone is not enough: bullet shapes scale from
    /// `bodyFont.capHeight`, not cell width. Captured at attachment
    /// construction by `BulletAttachment.make(...)`.
    public let bodyPointSize: CGFloat

    public init(glyph: String, size: CGFloat, bodyPointSize: CGFloat = 0) {
        self.glyph = glyph
        self.glyphSize = size
        self.bodyPointSize = bodyPointSize
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

    #if os(OSX)
    /// Static list markers deliberately do not vend TK2 hosted views.
    /// TK2 draws the attachment image directly; TK1 continues through
    /// the `attachmentCell` path.
    public override func viewProvider(
        for parentView: NSView?,
        location: any NSTextLocation,
        textContainer: NSTextContainer?
    ) -> NSTextAttachmentViewProvider? {
        return nil
    }
    #endif
}

public enum BulletAttachment {
    /// Create an attributed string containing a single bullet glyph
    /// attachment character. Cell width = cellScale × font.pointSize.
    /// Cell height = body font line height (ascender + |descender| + leading).
    public static func make(
        glyph: String,
        font: PlatformFont
    ) -> NSAttributedString {
        let cellWidth = font.pointSize * ListRenderer.cellScale
        let cellHeight = ListRenderer.naturalLineHeight(for: font)
        let attachment = BulletTextAttachment(
            glyph: glyph,
            size: cellWidth,
            bodyPointSize: font.pointSize
        )
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
        #if os(OSX)
        attachment.image = ListRenderer.bulletMarkerImage(
            glyph: glyph,
            size: attachment.bounds.size,
            bodyPointSize: font.pointSize
        )
        #endif
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
        // Use NSLayoutManager's defaultLineHeight to match the natural
        // line height of text-bearing lines exactly. `ascender+|descender|+leading`
        // under-sums by ~0.5pt on modern macOS where system-font leading=0,
        // so the checkbox "jumps" down by ~0.5pt when the user types the
        // first char (Bug 20 vertical component).
        self.cellHeight = ListRenderer.naturalLineHeight(for: bodyFont)
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
///
/// Same dual TK1/TK2 contract as `BulletTextAttachment`: the cell serves
/// TK1, while TK2 draws the marker image directly. We deliberately do
/// not vend a view provider for static list markers.
public class CheckboxTextAttachment: NSTextAttachment {
    public let isChecked: Bool
    public let boxSize: CGFloat
    public let bodyPointSize: CGFloat

    public init(checked: Bool, size: CGFloat, bodyPointSize: CGFloat = 0) {
        self.isChecked = checked
        self.boxSize = size
        self.bodyPointSize = bodyPointSize
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

    #if os(OSX)
    /// See `BulletTextAttachment.viewProvider(for:location:textContainer:)`
    /// for the no-provider rationale.
    public override func viewProvider(
        for parentView: NSView?,
        location: any NSTextLocation,
        textContainer: NSTextContainer?
    ) -> NSTextAttachmentViewProvider? {
        return nil
    }
    #endif
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
        let cellHeight = ListRenderer.naturalLineHeight(for: font)
        let attachment = CheckboxTextAttachment(
            checked: checked,
            size: cellWidth,
            bodyPointSize: font.pointSize
        )
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
        #if os(OSX)
        attachment.image = ListRenderer.checkboxMarkerImage(
            checked: checked,
            size: attachment.bounds.size,
            bodyPointSize: font.pointSize
        )
        #endif
        let result = NSMutableAttributedString(attachment: attachment)
        result.addAttribute(.font, value: font, range: NSRange(location: 0, length: result.length))
        return result
    }
}
