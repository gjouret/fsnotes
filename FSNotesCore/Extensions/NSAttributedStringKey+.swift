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
/// `table` was added in Phase 2e-T2-b for the native-cell table path.
/// `TableTextRenderer` emits a flat, separator-encoded attributed
/// string tagged with this kind; the TK2 content-storage delegate
/// returns a `TableElement`. Mermaid and math are distinct kinds
/// (not just code blocks with a language marker) because their
/// Phase 2c layout fragments reserve bitmap space and draw a
/// rendered image over the source text, which the plain code-block
/// fragment doesn't do.
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
    /// Phase 2e-T2-b: block-model table rendered as a single flat
    /// attributed string of cell text joined by U+001F / U+001E
    /// separators.
    case table

    /// Paragraph-shaped range rendered by `SourceRenderer` — carries
    /// visible markdown markers (`#`, `**`, fences, `>`, `---`, etc.)
    /// tagged with `.markerRange` and otherwise appears as a plain
    /// paragraph. Live since Phase 4.4 (source mode dispatches to
    /// `SourceLayoutFragment` for paragraphs tagged with this kind).
    case sourceMarkdown
}

/// Phase 2e-T2-b: tags header-row cells inside a `.table`-kinded
/// range so `TableLayoutFragment` can style them differently (bold /
/// separator line) without having to peek at the `TableElement.block`
/// payload on every draw call. Value: `Bool` (`true` on header-cell
/// ranges, attribute absent elsewhere).
public extension NSAttributedString.Key {
    static let tableHeader = NSAttributedString.Key(rawValue: "es.fsnot.table.header")

    /// Phase 2e-T2-e: carries the authoritative `Block.table` value for
    /// a `.table`-kinded range. Set by `TableTextRenderer.renderNative`
    /// on the full range of the emitted separator-encoded cell text;
    /// read by the content-storage delegate when vending a
    /// `TableElement` so the element's `block` payload has accurate
    /// `alignments`, `header`, `rows`, and `raw` (vs. the placeholder
    /// decoded from the flat string, which loses alignments).
    ///
    /// Value: a `TableAuthoritativeBlockBox` wrapper holding the
    /// `Block.table`. The value is wrapped in a reference type so it
    /// can live on an `NSAttributedString` attribute run without
    /// requiring `Block` itself to be Objective-C compatible. The
    /// render path holds a strong reference for the lifetime of the
    /// storage range; the delegate reads it out on element construction.
    ///
    /// Absence of this attribute is tolerated: the delegate falls
    /// back to the placeholder decode path. This preserves flag-off
    /// byte-identical behaviour and keeps edit-reconciliation windows
    /// (where the attribute may briefly be missing mid-splice) safe.
    static let tableAuthoritativeBlock = NSAttributedString.Key(rawValue: "es.fsnot.table.auth")
}

/// Phase 2e-T2-e: boxed `Block.table` for storage on an
/// `NSAttributedString` attribute run. Reference type so the value
/// can be carried on attribute runs without requiring the block to be
/// Objective-C convertible.
///
/// The box is immutable after construction — the render path creates
/// a fresh box on every emission, so stale payloads never appear on a
/// run that's been edited through the cell primitives.
public final class TableAuthoritativeBlockBox {
    public let block: Block
    public init(_ block: Block) {
        self.block = block
    }
}
