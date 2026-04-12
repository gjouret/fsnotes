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
    public static func render(
        _ inlines: [Inline],
        baseAttributes: [NSAttributedString.Key: Any],
        note: Note? = nil
    ) -> NSAttributedString {
        let out = NSMutableAttributedString()
        for inline in inlines {
            out.append(render(inline, baseAttributes: baseAttributes, note: note))
        }
        return out
    }

    private static func render(
        _ inline: Inline,
        baseAttributes: [NSAttributedString.Key: Any],
        note: Note?
    ) -> NSAttributedString {
        switch inline {
        case .text(let s):
            return NSAttributedString(string: s, attributes: baseAttributes)
        case .bold(let children, _):
            var attrs = baseAttributes
            attrs[.font] = applyTrait(.bold, to: baseAttributes[.font] as? PlatformFont)
            return render(children, baseAttributes: attrs, note: note)
        case .italic(let children, _):
            var attrs = baseAttributes
            attrs[.font] = applyTrait(.italic, to: baseAttributes[.font] as? PlatformFont)
            return render(children, baseAttributes: attrs, note: note)
        case .strikethrough(let children):
            var attrs = baseAttributes
            attrs[.strikethroughStyle] = NSUnderlineStyle.single.rawValue
            return render(children, baseAttributes: attrs, note: note)
        case .code(let s):
            var attrs = baseAttributes
            let baseSize = (baseAttributes[.font] as? PlatformFont)?.pointSize ?? 14
            attrs[.font] = PlatformFont.monospacedSystemFont(ofSize: baseSize, weight: .regular)
            return NSAttributedString(string: s, attributes: attrs)
        case .link(let text, let rawDest):
            var attrs = baseAttributes
            if let url = URL(string: rawDest) {
                attrs[.link] = url
            }
            return render(text, baseAttributes: attrs, note: note)
        case .image(let alt, let rawDest):
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
                baseAttributes: baseAttributes,
                note: note
            ) {
                return attachmentString
            }
            return render(alt, baseAttributes: baseAttributes, note: note)
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

        // Remote URLs (http/https) are not hydrated locally — let the
        // alt-text fallback render them as plain text for now. Remote
        // images can be added in a later pass with an async URLSession
        // fetch in the hydrator.
        if destination.hasPrefix("http://") || destination.hasPrefix("https://") {
            return nil
        }

        let cleanPath = destination.removingPercentEncoding ?? destination
        let ext = (cleanPath as NSString).pathExtension.lowercased()
        guard !ext.isEmpty else { return nil }

        let isImage = renderableImageExtensions.contains(ext)
        let isPDF = renderablePDFExtensions.contains(ext)
        guard isImage || isPDF else { return nil }

        guard let fileURL = note.getAttachmentFileUrl(name: cleanPath) else {
            return nil
        }

        let attachment = NSTextAttachment()
        attachment.bounds = NSRect(
            origin: .zero,
            size: imageAttachmentPlaceholderSize
        )

        let altText = plainText(alt)
        let originalMarkdown = "![\(altText)](\(destination))"
        let blockType: RenderedBlockType = isPDF ? .pdf : .image

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
        case .image(let a, _):           a.forEach { plainTextAppend($0, into: &out) }
        case .autolink(let t, _):        out += t
        case .escapedChar(let ch):       out += String(ch)
        case .lineBreak:                 out += " "
        case .rawHTML(let s):            out += s
        case .entity(let s):             out += s
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
        let base = font ?? PlatformFont.systemFont(ofSize: 14)
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
}
