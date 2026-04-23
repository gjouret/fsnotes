//
//  InlineRenderer.swift
//  FSNotesCore
//
//  Renders a tree of Inline nodes into an NSAttributedString. This is
//  the inline half of the block renderer: paragraphs, headings, list
//  items, etc. feed their [Inline] payload through here to build the
//  rendered text.
//
//  ARCHITECTURAL CONTRACT:
//  - Input: [Inline] tree + base attributes.
//  - Output: NSAttributedString containing ONLY the rendered text.
//    Zero markdown syntax markers (**bold**, _italic_, `code`, etc.
//    NEVER appear in the output — those markers are consumed by the
//    parser and turned into Inline cases).
//  - Pure function: same input → byte-equal output.
//

import Foundation
#if os(OSX)
import AppKit
#else
import UIKit
#endif

public enum InlineRenderer {

    /// Render an inline tree with the given base attributes.
    ///
    /// - Parameter note: optional note context used to resolve relative
    ///   image/PDF paths. When nil, `.image` inlines fall back to
    ///   rendering their alt text. Defaults to nil so tests that don't
    ///   need attachment rendering stay source-compatible.
    /// - Parameter theme: the active theme. Phase 7.2 consumes
    ///   `theme.typography.subSuperFontSizeMultiplier`,
    ///   `theme.typography.kbdFontSizeMultiplier`, and
    ///   `theme.colors.highlightBackground`. Defaults to `Theme.shared`
    ///   so existing callers stay source-compatible.
    public static func render(
        _ inlines: [Inline],
        baseAttributes: [NSAttributedString.Key: Any],
        note: Note? = nil,
        theme: Theme = .shared
    ) -> NSAttributedString {
        let out = NSMutableAttributedString()
        for inline in inlines {
            out.append(render(inline, baseAttributes: baseAttributes, note: note, theme: theme))
        }
        return out
    }

    private static func render(
        _ inline: Inline,
        baseAttributes: [NSAttributedString.Key: Any],
        note: Note?,
        theme: Theme = .shared
    ) -> NSAttributedString {
        // Theme-derived sizes. Reading once per inline node keeps the
        // hot path cheap and avoids plumbing individual fields through
        // each branch.
        let baseSize: CGFloat = (baseAttributes[.font] as? PlatformFont)?.pointSize
            ?? theme.typography.bodyFontSize
        let codeMultiplier = theme.typography.inlineCodeSizeMultiplier
        let subSuperMultiplier = theme.typography.subSuperFontSizeMultiplier
        let kbdMultiplier = theme.typography.kbdFontSizeMultiplier

        switch inline {
        case .text(let s):
            return NSAttributedString(string: s, attributes: baseAttributes)
        case .bold(let children, _):
            var attrs = baseAttributes
            attrs[.font] = applyTrait(.bold, to: baseAttributes[.font] as? PlatformFont)
            return render(children, baseAttributes: attrs, note: note, theme: theme)
        case .italic(let children, _):
            var attrs = baseAttributes
            attrs[.font] = applyTrait(.italic, to: baseAttributes[.font] as? PlatformFont)
            return render(children, baseAttributes: attrs, note: note, theme: theme)
        case .strikethrough(let children):
            var attrs = baseAttributes
            attrs[.strikethroughStyle] = NSUnderlineStyle.single.rawValue
            return render(children, baseAttributes: attrs, note: note, theme: theme)
        case .code(let s):
            var attrs = baseAttributes
            attrs[.font] = PlatformFont.monospacedSystemFont(
                ofSize: baseSize * codeMultiplier, weight: .regular
            )
            return NSAttributedString(string: s, attributes: attrs)
        case .math(let content):
            // Inline math: placeholder text with .inlineMathSource marker.
            // The view layer renders via BlockRenderer + MathJax inline mode.
            var attrs = baseAttributes
            let mono = PlatformFont.monospacedSystemFont(ofSize: baseSize, weight: .regular)
            attrs[.font] = PlatformFont.withTraits(font: mono, traits: .italic)
            #if os(OSX)
            attrs[.foregroundColor] = NSColor.systemPurple
            #else
            attrs[.foregroundColor] = UIColor.systemPurple
            #endif
            attrs[.inlineMathSource] = content
            return NSAttributedString(string: content, attributes: attrs)
        case .displayMath(let content):
            // Display math: placeholder text with .displayMathSource marker.
            // The view layer renders via BlockRenderer + MathJax display mode,
            // producing a centered block image (like mermaid but no frame).
            var attrs = baseAttributes
            let mono = PlatformFont.monospacedSystemFont(ofSize: baseSize, weight: .regular)
            attrs[.font] = PlatformFont.withTraits(font: mono, traits: .italic)
            #if os(OSX)
            attrs[.foregroundColor] = NSColor.systemPurple
            #else
            attrs[.foregroundColor] = UIColor.systemPurple
            #endif
            attrs[.displayMathSource] = content
            return NSAttributedString(string: content, attributes: attrs)
        case .link(let text, let rawDest):
            var attrs = baseAttributes
            if let url = URL(string: rawDest) {
                attrs[.link] = url
            }
            return render(text, baseAttributes: attrs, note: note, theme: theme)
        case .image(let alt, let rawDest, let width):
            // Native block-model image rendering. Emit a single
            // NSTextAttachment character with resolved metadata IFF the
            // destination has a renderable extension AND we have a note
            // to resolve the path against. Otherwise fall back to alt
            // text — same as a non-image `.link` would render.
            //
            // The attachment is emitted with placeholder bounds and no
            // loaded image. A post-render hydrator (ImageAttachmentHydrator)
            // walks storage after fill, loads each image async, and
            // updates the attachment's bounds + cell. This keeps
            // InlineRenderer a pure function of (inlines, note) while
            // still producing the attachment character at the correct
            // inline position.
            if let attachmentString = makeImageAttachment(
                alt: alt,
                rawDestination: rawDest,
                width: width,
                baseAttributes: baseAttributes,
                note: note
            ) {
                return attachmentString
            }
            return render(alt, baseAttributes: baseAttributes, note: note, theme: theme)
        case .autolink(let text, let isEmail):
            var attrs = baseAttributes
            let urlString = isEmail ? "mailto:\(text)" : text
            if let url = URL(string: urlString) {
                attrs[.link] = url
            }
            return NSAttributedString(string: text, attributes: attrs)
        case .escapedChar(let ch):
            return NSAttributedString(string: String(ch), attributes: baseAttributes)
        case .lineBreak:
            return NSAttributedString(string: "\n", attributes: baseAttributes)
        case .rawHTML(let html):
            return NSAttributedString(string: html, attributes: baseAttributes)
        case .entity(let raw):
            return NSAttributedString(string: raw, attributes: baseAttributes)
        case .underline(let children):
            var attrs = baseAttributes
            attrs[.underlineStyle] = NSUnderlineStyle.single.rawValue
            return render(children, baseAttributes: attrs, note: note, theme: theme)
        case .highlight(let children):
            var attrs = baseAttributes
            // Phase 7.2: resolve the highlight background from the active
            // theme. The static `highlightColor` below is retained as
            // the converter fallback (and for `TableRenderController`'s
            // attribute-toggle path) but the live render now honors the
            // theme value. Default theme ships `#FFE60080` which matches
            // the static value within the 0.02-per-component tolerance
            // `colorsApproximatelyEqual` uses.
            attrs[.backgroundColor] = theme.colors.highlightBackground
                .resolvedForCurrentAppearance(fallback: Self.highlightColor)
            return render(children, baseAttributes: attrs, note: note, theme: theme)
        case .superscript(let children):
            // Bug #17: <sup>…</sup>. NSAttributedString.Key.superscript
            // takes an Int; positive = superscript, negative = subscript.
            // Shrink the font (Phase 7.2: via
            // `theme.typography.subSuperFontSizeMultiplier`, default 0.75)
            // and shift baseline up so the glyph sits above the baseline
            // (AppKit's .superscript attribute alone does not resize the
            // glyph).
            var attrs = baseAttributes
            attrs[.superscript] = 1
            if let baseFont = attrs[.font] as? PlatformFont {
                attrs[.font] = PlatformFont.systemFont(ofSize: baseFont.pointSize * subSuperMultiplier)
                attrs[.baselineOffset] = baseFont.pointSize * 0.35
            }
            return render(children, baseAttributes: attrs, note: note, theme: theme)
        case .`subscript`(let children):
            // Bug #17: <sub>…</sub>. Mirror of superscript — negative
            // `.superscript` int + negative baseline offset.
            var attrs = baseAttributes
            attrs[.superscript] = -1
            if let baseFont = attrs[.font] as? PlatformFont {
                attrs[.font] = PlatformFont.systemFont(ofSize: baseFont.pointSize * subSuperMultiplier)
                attrs[.baselineOffset] = -baseFont.pointSize * 0.15
            }
            return render(children, baseAttributes: attrs, note: note, theme: theme)
        case .kbd(let children):
            // <kbd>…</kbd> — keyboard-key styling.
            //
            // Apply the same content attributes that source-mode emits
            // via `InlineTagRegistry.buildInlineTagDefinitions` (the kbd
            // entry): monospaced (Phase 7.2:
            // `theme.typography.kbdFontSizeMultiplier`, default 0.85) ×
            // font + a dark-gray foreground. Tag the rendered range with
            // `.kbdTag = true` so `DocumentRenderer` can detect
            // paragraphs that need the `KbdBoxParagraphLayoutFragment`
            // dispatch, and so the fragment itself can find the run at
            // draw time.
            var attrs = baseAttributes
            if let baseFont = attrs[.font] as? PlatformFont {
                attrs[.font] = PlatformFont.monospacedSystemFont(
                    ofSize: baseFont.pointSize * kbdMultiplier,
                    weight: .medium
                )
            }
            attrs[.foregroundColor] = PlatformColor(
                red: 0.333, green: 0.333, blue: 0.333, alpha: 1.0
            )
            attrs[.kbdTag] = true
            return render(children, baseAttributes: attrs, note: note, theme: theme)
        case .wikilink(let target, let display):
            // Wikilink renders as styled clickable text (no [[ ]]
            // brackets in the output). The .link attribute uses the
            // `wiki:` URL scheme so the click handler can dispatch
            // to the wiki-link resolver instead of opening a web URL.
            var attrs = baseAttributes
            let visible = display ?? target
            if let url = URL(string: "wiki:" + (target.addingPercentEncoding(
                withAllowedCharacters: .urlPathAllowed) ?? target)) {
                attrs[.link] = url
            }
            return NSAttributedString(string: visible, attributes: attrs)
        }
    }

    // MARK: - Image attachments

    /// File extensions that the block-model renders as native
    /// NSTextAttachment characters. SVG is intentionally excluded —
    /// it needs its own renderer and is deferred.
    public static let renderableImageExtensions: Set<String> = [
        "png", "jpg", "jpeg", "gif", "tiff", "tif", "webp", "heic", "heif", "bmp"
    ]

    /// File extensions rendered as inline PDF viewers (PDFKit).
    public static let renderablePDFExtensions: Set<String> = ["pdf"]

    /// Dimensions of the placeholder emitted at render time — before the
    /// hydrator has had a chance to load the image. The hydrator updates
    /// `attachment.bounds` once the real image dimensions are known.
    /// Choosing a square keeps line-fragment height stable during the
    /// brief window between first render and hydrate.
    public static let imageAttachmentPlaceholderSize = CGSize(width: 1, height: 1)

    /// Build an NSTextAttachment-bearing attributed string for an
    /// `.image` inline — OR return nil to signal that the caller should
    /// fall back to rendering the alt text.
    ///
    /// Returns nil when:
    /// - `note` is nil (InlineRenderer has no way to resolve the path)
    /// - the destination has no extension, or one we don't render natively
    /// - the destination resolves to a remote URL (http/https)
    ///
    /// The returned attachment carries enough metadata for:
    /// - the hydrator to find it and load the image
    /// - `unloadImagesAndFiles` / `restoreRenderedBlocks` to round-trip
    ///   back to `![alt](path)` markdown on save
    private static func makeImageAttachment(
        alt: [Inline],
        rawDestination: String,
        width: Int?,
        baseAttributes: [NSAttributedString.Key: Any],
        note: Note?
    ) -> NSAttributedString? {
        guard let note = note else { return nil }

        // Normalize the destination. CommonMark allows percent-encoded
        // paths and optional title text in quotes; MarkdownParser
        // carries the raw destination as-is, so strip the title and
        // decode percent escapes here.
        let destination = stripDestinationTitle(rawDestination)
        guard !destination.isEmpty else { return nil }

        // Remote URLs (http/https) — create a placeholder attachment
        // and let the hydrator fetch the image asynchronously.
        if destination.hasPrefix("http://") || destination.hasPrefix("https://") {
            guard let url = URL(string: destination) else { return nil }

            let attachment = ImageNSTextAttachment(image: nil, size: imageAttachmentPlaceholderSize)

            let altText = plainText(alt)
            let originalMarkdown = "![\(altText)](\(destination))"

            let result = NSMutableAttributedString(attachment: attachment)
            let range = NSRange(location: 0, length: result.length)
            result.addAttributes(baseAttributes, range: range)
            result.addAttribute(.attachmentUrl, value: url, range: range)
            result.addAttribute(.attachmentPath, value: destination, range: range)
            result.addAttribute(.attachmentTitle, value: altText, range: range)
            result.addAttribute(.renderedBlockOriginalMarkdown, value: originalMarkdown, range: range)
            result.addAttribute(.renderedBlockType, value: RenderedBlockType.image.rawValue, range: range)
            if let w = width, w > 0 {
                result.addAttribute(.renderedImageWidth, value: NSNumber(value: w), range: range)
            }
            return result
        }

        let cleanPath = destination.removingPercentEncoding ?? destination
        let ext = (cleanPath as NSString).pathExtension.lowercased()
        guard !ext.isEmpty else { return nil }

        let isImage = renderableImageExtensions.contains(ext)
        let isPDF = renderablePDFExtensions.contains(ext)
        let isFile = !isImage && !isPDF

        guard let fileURL = note.getAttachmentFileUrl(name: cleanPath),
              FileManager.default.fileExists(atPath: fileURL.path) else {
            return nil
        }

        let attachment: NSTextAttachment
        if isImage {
            attachment = ImageNSTextAttachment(image: nil, size: imageAttachmentPlaceholderSize)
        } else {
            attachment = NSTextAttachment()
            attachment.bounds = NSRect(origin: .zero, size: imageAttachmentPlaceholderSize)
        }

        let altText = plainText(alt)
        let originalMarkdown = "![\(altText)](\(destination))"
        let blockType: RenderedBlockType = isPDF ? .pdf : (isFile ? .file : .image)

        let result = NSMutableAttributedString(attachment: attachment)
        let range = NSRange(location: 0, length: result.length)
        // Paragraph/font context so line fragment metrics are stable
        // until the hydrator replaces the bounds with real dimensions.
        result.addAttributes(baseAttributes, range: range)
        result.addAttribute(.attachmentUrl, value: fileURL, range: range)
        result.addAttribute(.attachmentPath, value: cleanPath, range: range)
        result.addAttribute(.attachmentTitle, value: altText, range: range)
        result.addAttribute(.renderedBlockOriginalMarkdown, value: originalMarkdown, range: range)
        result.addAttribute(.renderedBlockType, value: blockType.rawValue, range: range)
        if isImage, let w = width, w > 0 {
            result.addAttribute(.renderedImageWidth, value: NSNumber(value: w), range: range)
        }

        return result
    }

    /// Extract plain text from an inline tree — used to build the `alt`
    /// portion of the round-trip markdown string when an `.image` inline
    /// is rendered as an attachment.
    public static func plainText(_ inlines: [Inline]) -> String {
        var out = ""
        for inline in inlines {
            plainTextAppend(inline, into: &out)
        }
        return out
    }

    private static func plainTextAppend(_ inline: Inline, into out: inout String) {
        switch inline {
        case .text(let s):               out += s
        case .bold(let c, _):            c.forEach { plainTextAppend($0, into: &out) }
        case .italic(let c, _):          c.forEach { plainTextAppend($0, into: &out) }
        case .strikethrough(let c):      c.forEach { plainTextAppend($0, into: &out) }
        case .code(let s):               out += s
        case .link(let t, _):            t.forEach { plainTextAppend($0, into: &out) }
        case .image(let a, _, _):        a.forEach { plainTextAppend($0, into: &out) }
        case .autolink(let t, _):        out += t
        case .escapedChar(let ch):       out += String(ch)
        case .lineBreak:                 out += " "
        case .rawHTML(let s):            out += s
        case .entity(let s):             out += s
        case .underline(let c):          c.forEach { plainTextAppend($0, into: &out) }
        case .highlight(let c):          c.forEach { plainTextAppend($0, into: &out) }
        case .superscript(let c):        c.forEach { plainTextAppend($0, into: &out) }
        case .`subscript`(let c):        c.forEach { plainTextAppend($0, into: &out) }
        case .kbd(let c):                c.forEach { plainTextAppend($0, into: &out) }
        case .math(let s):               out += s
        case .displayMath(let s):        out += s
        case .wikilink(let t, let d):    out += d ?? t
        }
    }

    /// Strip an optional CommonMark title from a raw image/link
    /// destination. CommonMark destinations can look like:
    ///   `path/to/foo.png`
    ///   `path/to/foo.png "a title"`
    ///   `<path/to/foo.png> 'a title'`
    /// MarkdownParser preserves the full raw form. For path resolution
    /// we only need the URL portion.
    private static func stripDestinationTitle(_ raw: String) -> String {
        var s = raw.trimmingCharacters(in: .whitespaces)
        // Trim angle brackets if present: <url>
        if s.hasPrefix("<"), let end = s.firstIndex(of: ">") {
            s = String(s[s.index(after: s.startIndex)..<end])
            return s.trimmingCharacters(in: .whitespaces)
        }
        // Split on the first whitespace followed by a quote character.
        // CommonMark titles are always quoted and separated from the URL
        // by at least one space.
        if let spaceIdx = s.firstIndex(where: { $0 == " " || $0 == "\t" }) {
            let afterSpace = s[s.index(after: spaceIdx)...].drop { $0 == " " || $0 == "\t" }
            if let firstCh = afterSpace.first, firstCh == "\"" || firstCh == "'" || firstCh == "(" {
                return String(s[..<spaceIdx]).trimmingCharacters(in: .whitespaces)
            }
        }
        return s
    }

    private enum Trait { case bold, italic }

    private static func applyTrait(_ trait: Trait, to font: PlatformFont?) -> PlatformFont {
        // Defensive fallback: if the caller didn't carry a font on
        // `baseAttributes[.font]`, synthesize one from the shared theme's
        // body font size. This path is effectively unreachable in the
        // live renderer because every render-site populates `.font`, but
        // the Rule-7 grep gate demands no literal size constants in this
        // file.
        let base = font ?? PlatformFont.systemFont(
            ofSize: Theme.shared.typography.bodyFontSize
        )
        #if os(OSX)
        var traits = base.fontDescriptor.symbolicTraits
        switch trait {
        case .bold:   traits.insert(.bold)
        case .italic: traits.insert(.italic)
        }
        let descriptor = base.fontDescriptor.withSymbolicTraits(traits)
        return PlatformFont(descriptor: descriptor, size: base.pointSize) ?? base
        #else
        var traits = base.fontDescriptor.symbolicTraits
        switch trait {
        case .bold:   traits.insert(.traitBold)
        case .italic: traits.insert(.traitItalic)
        }
        let descriptor = base.fontDescriptor.withSymbolicTraits(traits) ?? base.fontDescriptor
        return PlatformFont(descriptor: descriptor, size: base.pointSize)
        #endif
    }

    // MARK: - Inverse: NSAttributedString → [Inline]

    /// Convert a rendered `NSAttributedString` back into an inline
    /// tree. This is the inverse of `render(_:baseAttributes:note:)`
    /// and is used by the Stage 3 table-cell editing path: the field
    /// editor's attributed string (which the user types into and
    /// which the toolbar applies attributes to) is walked run-by-run
    /// and re-serialized into `[Inline]` so the primitive can update
    /// the Document.
    ///
    /// Mapping rules (inverse of the `render` match above):
    ///  - Font with bold trait          → `.bold([...])`
    ///  - Font with italic trait        → `.italic([...])`
    ///  - `.strikethroughStyle` present → `.strikethrough([...])`
    ///  - `.underlineStyle` present     → `.underline([...])`
    ///  - `.backgroundColor` matches highlight → `.highlight([...])`
    ///  - Monospaced font               → `.code(String)` (non-nesting)
    ///  - `.link` URL present           → `.link(text: [...], rawDestination: url.absoluteString)`
    ///  - `\n` characters               → `.rawHTML("<br>")`
    ///  - Anything else                 → `.text(String)`
    ///
    /// Trait nesting is canonical outer-to-inner:
    /// `.bold(.italic(.strikethrough(.underline(.highlight(.text)))))`.
    /// Adjacent runs with identical trait sets merge into one text
    /// node. Runs whose traits differ emit the longest common prefix
    /// as outer wrappers, so e.g. a paragraph "bold _italic_ more bold"
    /// round-trips as a single outer `.bold` wrapping three children.
    public static func inlineTreeFromAttributedString(
        _ attributed: NSAttributedString
    ) -> [Inline] {
        let length = attributed.length
        if length == 0 { return [] }

        // Split into spans where newline characters break the string
        // into segments separated by `.rawHTML("<br>")` nodes. Each
        // non-newline segment is converted independently, then joined.
        let nsString = attributed.string as NSString
        var out: [Inline] = []
        var segmentStart = 0
        var i = 0
        while i < length {
            let ch = nsString.character(at: i)
            if ch == 0x0A /* \n */ {
                if i > segmentStart {
                    let segRange = NSRange(location: segmentStart, length: i - segmentStart)
                    let seg = attributed.attributedSubstring(from: segRange)
                    out.append(contentsOf: convertNewlineFreeSegment(seg))
                }
                out.append(.rawHTML("<br>"))
                segmentStart = i + 1
            }
            i += 1
        }
        if segmentStart < length {
            let segRange = NSRange(location: segmentStart, length: length - segmentStart)
            let seg = attributed.attributedSubstring(from: segRange)
            out.append(contentsOf: convertNewlineFreeSegment(seg))
        }
        return out
    }

    // MARK: - Converter internals

    /// Trait set for a single attributed-string run. Equatable so
    /// adjacent runs can be grouped by identical traits.
    private struct RunTraits: Equatable {
        var bold: Bool = false
        var italic: Bool = false
        var strikethrough: Bool = false
        var underline: Bool = false
        var highlight: Bool = false
        var code: Bool = false
        var link: URL? = nil
        /// +1 for <sup>, -1 for <sub>, 0 for neither. Matches the
        /// value of NSAttributedString.Key.superscript which the
        /// render path emits on `.superscript` / `.subscript` nodes.
        var superscriptLevel: Int = 0
    }

    /// Convert a segment that contains no newline characters into an
    /// inline tree. Walks runs, computes trait sets, groups adjacent
    /// runs with identical traits, and emits nested inline wrappers.
    private static func convertNewlineFreeSegment(
        _ attributed: NSAttributedString
    ) -> [Inline] {
        if attributed.length == 0 { return [] }

        // Phase 1: collect (text, traits) pairs run by run.
        struct Span {
            let text: String
            let traits: RunTraits
        }
        var spans: [Span] = []
        attributed.enumerateAttributes(
            in: NSRange(location: 0, length: attributed.length),
            options: []
        ) { attrs, range, _ in
            let text = (attributed.string as NSString).substring(with: range)
            let traits = traitsFromAttributes(attrs)
            // Merge with the previous span if traits match — keeps
            // the downstream tree shallow when the attributed string
            // has unnecessary run breaks.
            if let last = spans.last, last.traits == traits {
                spans[spans.count - 1] = Span(text: last.text + text, traits: traits)
            } else {
                spans.append(Span(text: text, traits: traits))
            }
        }
        if spans.isEmpty { return [] }

        // Phase 2: build the inline tree. Code and link traits are
        // "leaf" wrappers — they cannot nest formatting inside, so
        // runs with those traits emit terminal nodes. Other traits
        // wrap each other in canonical outer-to-inner order.
        var result: [Inline] = []
        for span in spans {
            result.append(inlineFromSpan(text: span.text, traits: span.traits))
        }
        // Phase 3: fuse adjacent inline nodes whose outermost wrapper
        // is the same, so that e.g. ".bold(a) .bold(b)" becomes
        // ".bold([a, b])". This preserves the nesting shape the
        // original inline tree had before rendering.
        return fuseAdjacent(result)
    }

    /// Extract a `RunTraits` value from an attribute dictionary. All
    /// trait detection happens here so `convertNewlineFreeSegment`
    /// stays simple.
    private static func traitsFromAttributes(
        _ attrs: [NSAttributedString.Key: Any]
    ) -> RunTraits {
        var t = RunTraits()
        if let font = attrs[.font] as? PlatformFont {
            #if os(OSX)
            let symbolicTraits = font.fontDescriptor.symbolicTraits
            if symbolicTraits.contains(.bold)   { t.bold = true }
            if symbolicTraits.contains(.italic) { t.italic = true }
            if symbolicTraits.contains(.monoSpace) { t.code = true }
            #else
            let symbolicTraits = font.fontDescriptor.symbolicTraits
            if symbolicTraits.contains(.traitBold)      { t.bold = true }
            if symbolicTraits.contains(.traitItalic)    { t.italic = true }
            if symbolicTraits.contains(.traitMonoSpace) { t.code = true }
            #endif
        }
        if let style = attrs[.strikethroughStyle] as? Int, style != 0 {
            t.strikethrough = true
        }
        if let style = attrs[.underlineStyle] as? Int, style != 0 {
            t.underline = true
        }
        if let bg = attrs[.backgroundColor] as? PlatformColor {
            if isHighlightColor(bg) { t.highlight = true }
        }
        if let url = attrs[.link] as? URL {
            t.link = url
        }
        if let sup = attrs[.superscript] as? Int, sup != 0 {
            t.superscriptLevel = sup > 0 ? 1 : -1
        }
        return t
    }

    /// The highlight background color emitted by `render(.highlight)`.
    /// Single source of truth — also consumed by the table cell
    /// formatting toolbar path in `TableRenderController` and by
    /// `isHighlightColor` below.
    public static let highlightColor = PlatformColor(red: 1.0, green: 0.9, blue: 0.0, alpha: 0.5)

    /// True iff `a` and `b` are the same color within a 0.02-per-
    /// component tolerance. The tolerance absorbs the small RGBA
    /// drift that color-space conversions introduce on the way
    /// through AppKit. Used by the converter (highlight detection)
    /// and by `TableRenderController`'s attribute-toggle path.
    public static func colorsApproximatelyEqual(_ a: PlatformColor, _ b: PlatformColor) -> Bool {
        #if os(OSX)
        guard let aRGB = a.usingColorSpace(.sRGB),
              let bRGB = b.usingColorSpace(.sRGB) else { return false }
        let eps: CGFloat = 0.02
        return abs(aRGB.redComponent - bRGB.redComponent) < eps
            && abs(aRGB.greenComponent - bRGB.greenComponent) < eps
            && abs(aRGB.blueComponent - bRGB.blueComponent) < eps
            && abs(aRGB.alphaComponent - bRGB.alphaComponent) < eps
        #else
        var ar: CGFloat = 0, ag: CGFloat = 0, ab: CGFloat = 0, aa: CGFloat = 0
        a.getRed(&ar, green: &ag, blue: &ab, alpha: &aa)
        var br: CGFloat = 0, bg: CGFloat = 0, bb: CGFloat = 0, ba: CGFloat = 0
        b.getRed(&br, green: &bg, blue: &bb, alpha: &ba)
        let eps: CGFloat = 0.02
        return abs(ar - br) < eps && abs(ag - bg) < eps
            && abs(ab - bb) < eps && abs(aa - ba) < eps
        #endif
    }

    private static func isHighlightColor(_ color: PlatformColor) -> Bool {
        return colorsApproximatelyEqual(color, highlightColor)
    }

    /// Build a single inline node from a run's text + traits. Leaf
    /// wrappers (code, link) terminate the recursion; container
    /// wrappers (bold → italic → strike → underline → highlight) are
    /// applied in canonical order.
    private static func inlineFromSpan(text: String, traits: RunTraits) -> Inline {
        // Code is a leaf trait — it stores a String directly and
        // cannot host other inline formatting. If a run has code +
        // other traits, code wins and the others are dropped, which
        // matches CommonMark semantics (inline code is verbatim).
        if traits.code {
            return .code(text)
        }
        // Link is a wrapper whose inner content can still carry
        // bold/italic/etc. Peel off the link trait and recurse.
        if let url = traits.link {
            var inner = traits
            inner.link = nil
            let innerNode = inlineFromSpan(text: text, traits: inner)
            return .link(text: [innerNode], rawDestination: url.absoluteString)
        }
        // Canonical wrapping order: sup/sub outermost (HTML tag), then
        // bold, italic, strike, underline, highlight. Innermost is
        // `.text(text)`. Ordering sup/sub outside bold matches markdown
        // conventions like `<sup>**x**</sup>`.
        var node: Inline = .text(text)
        if traits.highlight     { node = .highlight([node]) }
        if traits.underline     { node = .underline([node]) }
        if traits.strikethrough { node = .strikethrough([node]) }
        if traits.italic        { node = .italic([node]) }
        if traits.bold          { node = .bold([node]) }
        if traits.superscriptLevel ==  1 { node = .superscript([node]) }
        if traits.superscriptLevel == -1 { node = .`subscript`([node]) }
        return node
    }

    /// Fuse adjacent siblings whose outermost wrapper matches, so
    /// that a sequence `[.bold([.text("a")]), .bold([.text("b")])]`
    /// collapses to `[.bold([.text("a"), .text("b")])]`. Applied
    /// recursively to the children of the fused wrapper so nested
    /// shapes (bold containing italic) round-trip correctly.
    private static func fuseAdjacent(_ nodes: [Inline]) -> [Inline] {
        var out: [Inline] = []
        for node in nodes {
            guard let last = out.last else {
                out.append(node)
                continue
            }
            if let fused = fuseIfSameShape(last, node) {
                out.removeLast()
                out.append(fused)
            } else {
                out.append(node)
            }
        }
        return out
    }

    /// If `a` and `b` have the same outermost wrapper kind, return a
    /// new wrapper whose children are the concatenation of theirs
    /// (recursively fused). Otherwise return nil.
    private static func fuseIfSameShape(_ a: Inline, _ b: Inline) -> Inline? {
        switch (a, b) {
        case (.bold(let ac, let am), .bold(let bc, let bm)) where am == bm:
            return .bold(fuseAdjacent(ac + bc), marker: am)
        case (.italic(let ac, let am), .italic(let bc, let bm)) where am == bm:
            return .italic(fuseAdjacent(ac + bc), marker: am)
        case (.strikethrough(let ac), .strikethrough(let bc)):
            return .strikethrough(fuseAdjacent(ac + bc))
        case (.underline(let ac), .underline(let bc)):
            return .underline(fuseAdjacent(ac + bc))
        case (.highlight(let ac), .highlight(let bc)):
            return .highlight(fuseAdjacent(ac + bc))
        case (.superscript(let ac), .superscript(let bc)):
            return .superscript(fuseAdjacent(ac + bc))
        case (.`subscript`(let ac), .`subscript`(let bc)):
            return .`subscript`(fuseAdjacent(ac + bc))
        case (.text(let a1), .text(let a2)):
            return .text(a1 + a2)
        default:
            return nil
        }
    }
}
