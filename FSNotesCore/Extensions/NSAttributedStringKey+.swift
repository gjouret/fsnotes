//
//  NSAttributedStringKey+.swift
//  FSNotes
//
//  Created by Oleksandr Glushchenko on 10/15/18.
//  Copyright © 2018 Oleksandr Glushchenko. All rights reserved.
//

import Foundation

public enum RenderedBlockType: String {
    case mermaid, math, table, pdf, image, file
}

public extension NSAttributedString.Key {
    static let attachmentSave = NSAttributedString.Key(rawValue: "es.fsnot.attachment.save")
    static let attachmentUrl = NSAttributedString.Key(rawValue: "es.fsnot.attachment.url")
    static let attachmentPath = NSAttributedString.Key(rawValue: "es.fsnot.attachment.path")
    static let attachmentTitle = NSAttributedString.Key(rawValue: "es.fsnot.attachment.title")
    static let tag = NSAttributedString.Key(rawValue: "es.fsnot.tag")
    static let yamlBlock = NSAttributedString.Key(rawValue: "es.fsnot.yaml")
    static let highlight = NSAttributedString.Key(rawValue: "es.fsnot.highlight")
    static let horizontalRule = NSAttributedString.Key(rawValue: "es.fsnot.hr")
    static let blockquote = NSAttributedString.Key(rawValue: "es.fsnot.blockquote")
    static let renderedBlockSource = NSAttributedString.Key(rawValue: "es.fsnot.rendered.source")
    static let renderedBlockType = NSAttributedString.Key(rawValue: "es.fsnot.rendered.type")
    static let renderedBlockRange = NSAttributedString.Key(rawValue: "es.fsnot.rendered.range")
    static let renderedBlockOriginalMarkdown = NSAttributedString.Key(rawValue: "es.fsnot.rendered.original")
    static let bulletMarker = NSAttributedString.Key(rawValue: "es.fsnot.bullet.marker")
    static let checkboxMarker = NSAttributedString.Key(rawValue: "es.fsnot.checkbox.marker")
    static let orderedMarker = NSAttributedString.Key(rawValue: "es.fsnot.ordered.marker")
    static let listDepth = NSAttributedString.Key(rawValue: "es.fsnot.list.depth")
    static let codeFence = NSAttributedString.Key(rawValue: "es.fsnot.code.fence")
    static let kbdTag = NSAttributedString.Key(rawValue: "es.fsnot.kbd")
    /// Bug #51: tags an inline `.code` run so layout fragments can paint
    /// the rounded-rect light-gray chrome behind it. Set by
    /// `InlineRenderer` on every `.code(s)` inline; read by
    /// `ParagraphLayoutFragment` / `HeadingLayoutFragment` /
    /// `BlockquoteLayoutFragment` / `KbdBoxParagraphLayoutFragment` via
    /// the shared `InlineCodeChromeDrawer` helper. Value: singleton
    /// (presence of the key matters, not its value).
    static let inlineCodeRange = NSAttributedString.Key(rawValue: "es.fsnot.inline.code")
    static let foldedContent = NSAttributedString.Key(rawValue: "es.fsnot.folded.content")
    static let inlineMathSource = NSAttributedString.Key(rawValue: "es.fsnot.inline.math")
    static let displayMathSource = NSAttributedString.Key(rawValue: "es.fsnot.display.math")
    /// Optional image width hint from the CommonMark title field
    /// (parsed as `width=N`). When present on an image attachment,
    /// ImageAttachmentHydrator scales the rendered bounds to this
    /// width and derives the height from the natural aspect ratio.
    /// Absent = use natural size clamped to container width.
    /// Value: NSNumber wrapping an Int (points).
    static let renderedImageWidth = NSAttributedString.Key(rawValue: "es.fsnot.rendered.image.width")

    /// Phase 2b: identifies the block-model kind of a paragraph range.
    /// Set by each block renderer in `DocumentRenderer`. Read by the
    /// `NSTextContentStorageDelegate` to dispatch on `NSTextParagraph`
    /// subclass per block type. Value: `BlockModelKind.rawValue` (String).
    static let blockModelKind = NSAttributedString.Key(rawValue: "es.fsnot.blockmodel.kind")

    /// Phase 2c: heading level (1...6) for `.heading` block-model ranges.
    /// Set by `DocumentRenderer` alongside `.blockModelKind = .heading`.
    /// Read by `HeadingLayoutFragment` to decide whether to draw the
    /// H1/H2 bottom hairline. Value: `Int` (1-indexed, matches
    /// `Block.heading(level:suffix:)`).
    static let headingLevel = NSAttributedString.Key(rawValue: "es.fsnot.heading.level")

    /// Phase 4.1: tags a character range as a markdown marker (e.g. the
    /// leading `#` of a heading, the `**` around emphasis, the fence
    /// characters of a code block). `SourceLayoutFragment` reads this to
    /// paint marker runs in a distinct foreground color without mutating
    /// the attributed string's `.foregroundColor` attribute.
    ///
    /// Value is a singleton marker (e.g. `NSNull()`); presence of the
    /// attribute matters, not its value.
    static let markerRange = NSAttributedString.Key(rawValue: "es.fsnot.source.marker")
}

/// Phase 2b: enumeration of block-model block types carried on
/// rendered attributed string ranges via the `.blockModelKind`
/// attribute. The TK2 content-storage delegate uses this to pick the
/// right `NSTextParagraph` subclass per block, which in turn lets
/// Phase 2c's layout fragments route their drawing.
///
/// Mermaid and math are distinct kinds (not just code blocks with a
/// language marker) because their Phase 2c layout fragments reserve
/// bitmap space and draw a rendered image over the source text, which
/// the plain code-block fragment doesn't do.
public enum BlockModelKind: String {
    case paragraph
    case paragraphWithKbd  // paragraph containing one or more .kbdTag runs
    case heading
    case list
    case blockquote
    case codeBlock
    case horizontalRule
    case mermaid
    case math
    /// Paragraph whose sole inline is `Inline.displayMath` — rendered
    /// as a centered pseudo-block equation via `DisplayMathLayoutFragment`.
    /// Paragraphs containing display math PLUS other content do NOT use
    /// this kind; they fall through to `.paragraph` and the display
    /// math stays on the inline attachment path.
    case displayMath
    /// Legacy fallback tag for paragraph-shaped table ranges. The live
    /// macOS table route uses `TableAttachment`, so production rendering
    /// should not emit this kind.
    case table

    /// Paragraph-shaped range rendered by `SourceRenderer` — carries
    /// visible markdown markers (`#`, `**`, fences, `>`, `---`, etc.)
    /// tagged with `.markerRange` and otherwise appears as a plain
    /// paragraph. Live since Phase 4.4 (source mode dispatches to
    /// `SourceLayoutFragment` for paragraphs tagged with this kind).
    case sourceMarkdown
}
