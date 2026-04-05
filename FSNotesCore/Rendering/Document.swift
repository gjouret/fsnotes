//
//  Document.swift
//  FSNotesCore
//
//  Block-model Document — the single source of truth for rendering.
//
//  ARCHITECTURAL CONTRACT:
//  - A Document is parsed from raw markdown once.
//  - Rendering consumes the Document, NOT raw markdown text.
//  - Markdown syntax markers (fences, #, *, -, etc.) exist ONLY inside Block
//    payloads where they are semantically meaningful (e.g. CodeBlock.content
//    is RAW code with no fences). They are NEVER rendered into textStorage.
//  - Round-trip invariant: serialize(parse(markdown)) == markdown, byte-equal.
//
//  This file defines the TRACER-BULLET subset of the full block model: only
//  the block types needed to prove the architecture works end-to-end for
//  code blocks. The full model (headings, lists, inlines, etc.) will be
//  added in later phases.
//

import Foundation

/// The parsed representation of a markdown document. The single source of
/// truth that feeds the rendering pipeline.
public struct Document: Equatable {
    public var blocks: [Block]
    /// Whether the source file ended with a trailing newline. Carried so
    /// that serialize(parse(x)) == x byte-equal.
    public var trailingNewline: Bool

    public init(blocks: [Block] = [], trailingNewline: Bool = true) {
        self.blocks = blocks
        self.trailingNewline = trailingNewline
    }
}

/// Fence style carried on a code block so that round-trip serialization
/// reproduces the original fence exactly. This is orthogonal to rendering
/// (the renderer never consumes these fields) — it is purely a serialize
/// concern.
public struct FenceStyle: Equatable {
    public enum Character: Equatable { case backtick, tilde }
    public let character: Character
    public let length: Int           // >= 3
    /// The original info string as it appeared after the opening fence,
    /// verbatim (leading/trailing whitespace preserved from the source).
    public let infoRaw: String

    public init(character: Character, length: Int, infoRaw: String) {
        self.character = character
        self.length = length
        self.infoRaw = infoRaw
    }

    /// Default fence for synthesized code blocks: ```<lang>
    public static func canonical(language: String?) -> FenceStyle {
        return FenceStyle(character: .backtick, length: 3, infoRaw: language ?? "")
    }
}

/// A top-level block in the document. This is the TRACER-BULLET subset.
/// Additional cases (heading, list, blockquote, inline-bearing paragraph,
/// table, mermaid, math, etc.) are added in later migration phases.
public enum Block: Equatable {
    /// A fenced code block. `content` is the RAW code between the fences
    /// with no fence characters. `language` is the parsed info string
    /// (nil if empty). `fence` records the original fence style so the
    /// block round-trips byte-equal on serialization.
    case codeBlock(language: String?, content: String, fence: FenceStyle)

    /// An ATX heading. `level` is 1–6 (number of leading `#` characters).
    /// `suffix` is everything on the line AFTER the `#` markers, verbatim —
    /// it always begins with a space or is empty, and is preserved exactly
    /// so the block round-trips byte-equal. Inline styling within the
    /// heading is not yet parsed (tracer-bullet scope); the renderer
    /// trims `suffix` to produce the displayed heading text.
    case heading(level: Int, suffix: String)

    /// A paragraph: a run of non-empty lines carrying parsed inline
    /// content. Markers (`**`, `*`) inside the source are CONSUMED by
    /// the parser and represented as Inline.bold / Inline.italic —
    /// they do NOT appear in the rendered string.
    case paragraph(inline: [Inline])

    /// A list (unordered or ordered). Items carry their original
    /// indent/marker/whitespace verbatim for byte-equal round-trip.
    /// Nesting is represented by each item's `children` (siblings at
    /// deeper indentation). Tracer-bullet scope: single-line items —
    /// no lazy continuations, no multi-paragraph items.
    case list(items: [ListItem])

    /// A blockquote: a run of consecutive `>`-prefixed lines. Each
    /// line carries its verbatim prefix (`>`, `> `, `>> `, etc.) so
    /// the block round-trips byte-equal. Tracer-bullet scope: each
    /// line's content is parsed as inlines only — no recursive
    /// block structure inside the quote.
    case blockquote(lines: [BlockquoteLine])

    /// A horizontal rule (thematic break). `character` is the source
    /// character used (`-`, `_`, or `*`) and `length` is the number
    /// of that character in the source line — both preserved for
    /// byte-equal round-trip. The renderer always emits a normalized
    /// visual representation and does NOT read these fields.
    case horizontalRule(character: Character, length: Int)

    /// A literal blank line separating blocks.
    case blankLine
}

/// A single item within a list. Records the exact source prefix
/// (`indent` + `marker` + `afterMarker`) so the item round-trips
/// byte-equal, plus its inline content and any nested sub-items.
///
/// Example: "  - hello" → ListItem(indent: "  ", marker: "-",
/// afterMarker: " ", inline: [.text("hello")], children: []).
public struct ListItem: Equatable {
    public let indent: String        // leading whitespace before marker
    public let marker: String        // "-", "*", "+", "1.", "2)", etc.
    public let afterMarker: String   // whitespace between marker and content
    public let inline: [Inline]      // parsed inline content (no markers)
    public let children: [ListItem]  // nested items at deeper indentation

    public init(
        indent: String,
        marker: String,
        afterMarker: String,
        inline: [Inline],
        children: [ListItem]
    ) {
        self.indent = indent
        self.marker = marker
        self.afterMarker = afterMarker
        self.inline = inline
        self.children = children
    }
}

/// A single line of a blockquote. Records the exact source prefix
/// (a run of `>` optionally separated/trailed by single spaces) so
/// the line round-trips byte-equal, plus its parsed inline content.
public struct BlockquoteLine: Equatable {
    public let prefix: String        // e.g. "> ", ">> ", "> > ", ">"
    public let inline: [Inline]      // parsed inlines (markers consumed)

    public init(prefix: String, inline: [Inline]) {
        self.prefix = prefix
        self.inline = inline
    }

    /// Nesting level: number of `>` characters in the prefix.
    public var level: Int {
        return prefix.filter { $0 == ">" }.count
    }
}

/// An inline run — the leaf content inside a paragraph, heading, list
/// item, etc. Tracer-bullet subset: text + bold + italic (asterisk
/// markers only). Underscore emphasis, code spans, links, images,
/// etc. are added in later phases.
public indirect enum Inline: Equatable {
    case text(String)
    case bold([Inline])       // **…**
    case italic([Inline])     // *…*
    case code(String)         // `…` — content is raw, never parsed
}
