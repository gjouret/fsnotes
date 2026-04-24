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

import Foundation

/// The parsed representation of a markdown document. The single source of
/// truth that feeds the rendering pipeline.
public struct Document: Equatable {
    public var blocks: [Block]
    /// Whether the source file ended with a trailing newline. Carried so
    /// that serialize(parse(x)) == x byte-equal.
    public var trailingNewline: Bool

    /// Link reference definitions collected during parsing. Stored on
    /// the Document so that renderers (e.g. CommonMarkHTMLRenderer) can
    /// resolve reference links when re-parsing heading suffixes.
    /// Not compared for Equatable — structural equality is block-based.
    public var refDefs: [String: (url: String, title: String?)]

    /// Per-block stable identities, aligned 1:1 with `blocks`. Auto-populated
    /// to fresh UUIDs when `blocks` is set via the initializer; callers that
    /// mutate `blocks` directly must keep this in sync via the mutation
    /// helpers below.
    ///
    /// Identities are **ephemeral**: the parser mints new UUIDs on every
    /// parse and they are never serialized to disk — they exist purely to
    /// give the `EditContract` harness a way to verify identity-preserving
    /// operations (a `.replaceBlock` primitive that drops the slot id is a
    /// contract violation).
    ///
    /// Identity is a property of the *slot*, not the content: `replaceBlock`
    /// preserves the id at the affected index; `insertBlock` mints a fresh
    /// id; `deleteBlock` drops the id. Swap preserves both slot ids
    /// in place (contents swap, ids don't travel).
    ///
    /// `Document.==` ignores `blockIds` — equality is content-based.
    public var blockIds: [UUID]

    public init(blocks: [Block] = [], trailingNewline: Bool = true,
                refDefs: [String: (url: String, title: String?)] = [:],
                blockIds: [UUID]? = nil) {
        self.blocks = blocks
        self.trailingNewline = trailingNewline
        self.refDefs = refDefs
        if let blockIds = blockIds {
            precondition(blockIds.count == blocks.count,
                         "Document.init: blockIds.count (\(blockIds.count)) must match blocks.count (\(blocks.count))")
            self.blockIds = blockIds
        } else {
            self.blockIds = blocks.map { _ in UUID() }
        }
    }

    public static func == (lhs: Document, rhs: Document) -> Bool {
        lhs.blocks == rhs.blocks && lhs.trailingNewline == rhs.trailingNewline
    }

    // MARK: - Identity-aware mutations
    //
    // All structural mutations on `Document.blocks` must go through these
    // helpers so that `blockIds` stays aligned. Direct mutation of `blocks`
    // (e.g. `doc.blocks.append(b)`) is a latent bug — it produces a
    // drifted side-table and the `assertContract` invariants will fire.
    //
    // Semantics (see the `blockIds` comment above for the slot-identity
    // model):
    //   - `replaceBlock(at:with:)`    preserves the id at `at`.
    //   - `insertBlock(_:at:id:)`     inserts a fresh id at `at`.
    //   - `appendBlock(_:id:)`        appends a fresh id.
    //   - `removeBlock(at:)`          drops the id at `at`.
    //   - `replaceBlocks(_:with:ids:) replaces the ids in `range` too;
    //                                 fresh ids are minted unless supplied.
    //   - `swapBlocks(_:_:)`          swaps contents only; slot ids stay.
    //   - `mutateBlock(at:_:)`        in-place closure mutation; id preserved.

    /// Replace the block at `index`, preserving its slot identity.
    public mutating func replaceBlock(at index: Int, with block: Block) {
        blocks[index] = block
        // blockIds[index] unchanged — slot identity preserved.
    }

    /// Insert a block at `index`, minting a fresh slot id (or using the
    /// supplied one — primitives that split a block pass the split-half's
    /// precomputed id here).
    public mutating func insertBlock(_ block: Block, at index: Int, id: UUID = UUID()) {
        blocks.insert(block, at: index)
        blockIds.insert(id, at: index)
    }

    /// Append a block, minting a fresh slot id.
    public mutating func appendBlock(_ block: Block, id: UUID = UUID()) {
        blocks.append(block)
        blockIds.append(id)
    }

    /// Remove the block at `index`, dropping its slot identity.
    public mutating func removeBlock(at index: Int) {
        blocks.remove(at: index)
        blockIds.remove(at: index)
    }

    /// Replace a contiguous range of blocks with a new array. Existing
    /// slot identities in `range` are dropped; the replacement blocks
    /// receive fresh ids unless `ids` is supplied.
    public mutating func replaceBlocks<R: RangeExpression>(
        _ range: R, with newBlocks: [Block], ids: [UUID]? = nil
    ) where R.Bound == Int {
        let ids = ids ?? newBlocks.map { _ in UUID() }
        precondition(ids.count == newBlocks.count,
                     "Document.replaceBlocks: ids.count (\(ids.count)) must match newBlocks.count (\(newBlocks.count))")
        blocks.replaceSubrange(range, with: newBlocks)
        blockIds.replaceSubrange(range, with: ids)
    }

    /// Swap two block slots. Each slot keeps its id; contents swap.
    public mutating func swapBlocks(_ i: Int, _ j: Int) {
        blocks.swapAt(i, j)
        // blockIds left in place — slot identity is positional.
    }

    /// In-place mutation of a single block. Preserves slot identity.
    public mutating func mutateBlock(at index: Int, _ mutate: (inout Block) -> Void) {
        mutate(&blocks[index])
    }

    /// Debug invariant: blockIds and blocks must align 1:1. Call sites
    /// can use this in precondition/assert contexts to localize a drift.
    public var isIdAligned: Bool {
        return blockIds.count == blocks.count
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

/// A top-level block in the document.
public enum Block: Equatable {
    /// A fenced code block. `content` is the RAW code between the fences
    /// with no fence characters. `language` is the parsed info string
    /// (nil if empty). `fence` records the original fence style so the
    /// block round-trips byte-equal on serialization.
    case codeBlock(language: String?, content: String, fence: FenceStyle)

    /// An ATX heading. `level` is 1–6 (number of leading `#` characters).
    /// `suffix` is everything on the line AFTER the `#` markers, verbatim —
    /// it always begins with a space or is empty, and is preserved exactly
    /// so the block round-trips byte-equal. The renderer trims `suffix`
    /// to produce the displayed heading text.
    case heading(level: Int, suffix: String)

    /// A paragraph: a run of non-empty lines carrying parsed inline
    /// content. Markers (`**`, `*`) inside the source are CONSUMED by
    /// the parser and represented as Inline.bold / Inline.italic —
    /// they do NOT appear in the rendered string.
    case paragraph(inline: [Inline])

    /// A list (unordered or ordered). Items carry their original
    /// indent/marker/whitespace verbatim for byte-equal round-trip.
    /// Nesting is represented by each item's `children` (siblings at
    /// deeper indentation).
    /// `loose` is true when blank lines separate list items (affects
    /// HTML rendering: loose items are wrapped in `<p>` tags).
    case list(items: [ListItem], loose: Bool = false)

    /// A blockquote: a run of consecutive `>`-prefixed lines. Each
    /// line carries its verbatim prefix (`>`, `> `, `>> `, etc.) so
    /// the block round-trips byte-equal. Each line's content is
    /// parsed as inlines.
    case blockquote(lines: [BlockquoteLine])

    /// A horizontal rule (thematic break). `character` is the source
    /// character used (`-`, `_`, or `*`) and `length` is the number
    /// of that character in the source line — both preserved for
    /// byte-equal round-trip. The renderer always emits a normalized
    /// visual representation and does NOT read these fields.
    case horizontalRule(character: Character, length: Int)

    /// An HTML block: raw HTML content that should be passed through
    /// verbatim. Stored as the raw source lines joined by newlines.
    /// CommonMark defines 7 types of HTML blocks; all are stored the
    /// same way — just the raw source text.
    case htmlBlock(raw: String)

    /// A pipe-delimited markdown table. `header` and `rows` hold
    /// `TableCell` values — each cell is its own inline tree, parsed
    /// and rendered the same way paragraph content is. `alignments`
    /// comes from the separator row. `columnWidths` (T2-g.4) carries
    /// the persisted drag-resize widths when set; when nil, layout
    /// computes widths from cell content.
    ///
    /// Tables serialize canonically: `MarkdownSerializer` emits via
    /// `EditingOps.rebuildTableRaw(header, alignments, rows)` on every
    /// write, regardless of whether the table was edited. Legacy
    /// non-canonical source formatting is rewritten on the first save
    /// of a note that contains tables — this is an accepted trade-off
    /// (see REFACTOR_PLAN Phase 4.2).
    ///
    /// Cell content is "a paragraph inside a cell" — the parser, the
    /// primitives, and the native `TableElement` renderer all operate
    /// on inline trees using the same `InlineRenderer` paragraphs use.
    case table(header: [TableCell], alignments: [TableAlignment], rows: [[TableCell]], columnWidths: [CGFloat]?)

    /// A literal blank line separating blocks.
    case blankLine
}

/// A checkbox on a todo list item. Preserves the exact source text
/// (e.g. `[ ]`, `[x]`, `[X]`) and trailing whitespace for byte-equal
/// round-trip serialization.
public struct Checkbox: Equatable {
    /// The raw checkbox text, e.g. "[ ]", "[x]", "[X]".
    public let text: String
    /// Whitespace between the checkbox and the inline content (usually " ").
    public let afterText: String

    public init(text: String, afterText: String) {
        self.text = text
        self.afterText = afterText
    }

    /// Whether this checkbox is checked.
    public var isChecked: Bool {
        return text.lowercased().contains("x")
    }

    /// Return a toggled copy (checked ↔ unchecked), preserving casing style.
    public func toggled() -> Checkbox {
        let newText: String
        if isChecked {
            newText = text
                .replacingOccurrences(of: "[x]", with: "[ ]")
                .replacingOccurrences(of: "[X]", with: "[ ]")
        } else {
            newText = text.replacingOccurrences(of: "[ ]", with: "[x]")
        }
        return Checkbox(text: newText, afterText: afterText)
    }
}

/// A single item within a list. Records the exact source prefix
/// (`indent` + `marker` + `afterMarker` + optional `checkbox`)
/// so the item round-trips byte-equal, plus its inline content
/// and any nested sub-items.
///
/// Example: "  - hello" → ListItem(indent: "  ", marker: "-",
/// afterMarker: " ", checkbox: nil, inline: [.text("hello")],
/// children: []).
///
/// Example: "- [ ] task" → ListItem(indent: "", marker: "-",
/// afterMarker: " ", checkbox: Checkbox(text: "[ ]", afterText: " "),
/// inline: [.text("task")], children: []).
public struct ListItem: Equatable {
    public let indent: String        // leading whitespace before marker
    public let marker: String        // "-", "*", "+", "1.", "2)", etc.
    public let afterMarker: String   // whitespace between marker and content/checkbox
    public let checkbox: Checkbox?   // nil for regular items, non-nil for todo items
    public let inline: [Inline]      // parsed inline content (no markers)
    public let children: [ListItem]  // nested items at deeper indentation
    /// True if one or more blank lines preceded this item in the source.
    /// Used for tight/loose detection and round-trip serialization.
    public let blankLineBefore: Bool

    /// Blocks that appear *inside* this list item after the initial
    /// inline paragraph — e.g. continuation paragraphs, fenced code
    /// blocks, blockquotes — separated from the first line by a blank
    /// line and indented to the item's content column. Empty for
    /// simple one-line items. When non-empty, the containing list is
    /// automatically "loose". Included in HTML rendering and markdown
    /// serialization; opaque to editor FSMs, which operate on the
    /// first inline line.
    public let continuationBlocks: [Block]

    public init(
        indent: String,
        marker: String,
        afterMarker: String,
        checkbox: Checkbox? = nil,
        inline: [Inline],
        children: [ListItem],
        blankLineBefore: Bool = false,
        continuationBlocks: [Block] = []
    ) {
        self.indent = indent
        self.marker = marker
        self.afterMarker = afterMarker
        self.checkbox = checkbox
        self.inline = inline
        self.children = children
        self.blankLineBefore = blankLineBefore
        self.continuationBlocks = continuationBlocks
    }

    /// Whether this item is a todo (has a checkbox).
    public var isTodo: Bool { return checkbox != nil }

    /// Whether this item is a checked todo.
    public var isChecked: Bool { return checkbox?.isChecked ?? false }
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

/// Column alignment in a markdown table.
public enum TableAlignment: Equatable {
    case left, center, right, none
}

/// A single cell inside a `Block.table`. The cell content is a
/// markdown inline tree — the same `Inline` type that backs the
/// content of a `Block.paragraph`. This is the Option C unification:
/// "a paragraph inside a cell" — cells parse, render, and edit
/// through the same primitives as paragraphs, not through a separate
/// table-specific code path.
///
/// `rawText` is the markdown source for the cell (e.g. `"**foo**"`)
/// and is used during the transition period by widget code that
/// still expects a string-shaped cell. New code should operate on
/// `inline` directly.
public struct TableCell: Equatable {
    /// The parsed inline tree for this cell's content. Empty for an
    /// empty cell.
    public var inline: [Inline]

    public init(_ inline: [Inline]) {
        self.inline = inline
    }

    /// Serialize the inline tree back to markdown source text.
    /// Equivalent to what `MarkdownSerializer.serializeInlines`
    /// produces — a round-trip-safe representation of the cell's
    /// content as a raw markdown string.
    public var rawText: String {
        return MarkdownSerializer.serializeInlines(inline)
    }

    /// Convenience: build a cell directly from raw markdown source.
    /// Parses the string as inline content and wraps the result.
    public static func parsing(_ source: String) -> TableCell {
        return TableCell(MarkdownParser.parseInlines(source, refDefs: [:]))
    }
}

/// The delimiter character used for emphasis markers. Carried on bold/italic
/// so that `_text_` round-trips as `_text_` (not `*text*`).
public enum EmphasisMarker: Equatable {
    case asterisk   // * or **
    case underscore // _ or __
}

/// An inline run — the leaf content inside a paragraph, heading, list
/// item, etc.
public indirect enum Inline: Equatable {
    case text(String)
    case bold([Inline], marker: EmphasisMarker = .asterisk)
    case italic([Inline], marker: EmphasisMarker = .asterisk)
    case strikethrough([Inline])       // ~~…~~
    case code(String)                  // `…` — content is raw, never parsed
    case link(text: [Inline], rawDestination: String)       // [text](url "title")
    /// An inline image: `![alt](url "title")`.
    ///
    /// `rawDestination` holds everything between the parens verbatim
    /// (url + optional title) for byte-identical round-trip fidelity.
    ///
    /// `width` is a convenience field populated by the parser when the
    /// title segment matches `width=N` (possibly prefixed by other
    /// title text — e.g. `"photo from 2024 width=300"`). It is nil when
    /// the image has no size hint; the renderer then falls back to the
    /// natural size clamped to the container width. The field is
    /// strictly a cached parse of the title and MUST stay in sync with
    /// rawDestination — any mutation of one requires rewriting the
    /// other. Use `EditingOps.setImageSize` to mutate both atomically.
    case image(alt: [Inline], rawDestination: String, width: Int?)
    case autolink(text: String, isEmail: Bool)              // <url> or <email>
    case escapedChar(Character)        // \* \[ etc. — literal escaped character
    case lineBreak(raw: String)        // "  \n" or "\\\n" — hard line break
    case rawHTML(String)               // <tag>, </tag>, <!-- -->, etc.
    case entity(String)                // &amp; &#123; &#x1F; — raw entity text
    case underline([Inline])           // <u>…</u>
    case highlight([Inline])           // <mark>…</mark>
    case `superscript`([Inline])       // <sup>…</sup> — Bug #17
    case `subscript`([Inline])         // <sub>…</sub> — Bug #17
    case kbd([Inline])                 // <kbd>…</kbd> — keyboard-key box
    case math(String)                  // $…$ — inline LaTeX math
    case displayMath(String)           // $$…$$ — display LaTeX math
    /// A wikilink: `[[target]]` or `[[target|display]]`. The target is
    /// the note name (resolved by the editor at click time); `display`
    /// is the optional pipe-delimited alt text shown in place of the
    /// target. The brackets do NOT appear in the rendered output —
    /// only the display text (or the target if no display).
    case wikilink(target: String, display: String?)
}
