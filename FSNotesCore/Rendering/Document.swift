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

    public init(blocks: [Block] = [], trailingNewline: Bool = true,
                refDefs: [String: (url: String, title: String?)] = [:]) {
        self.blocks = blocks
        self.trailingNewline = trailingNewline
        self.refDefs = refDefs
    }

    public static func == (lhs: Document, rhs: Document) -> Bool {
        lhs.blocks == rhs.blocks && lhs.trailingNewline == rhs.trailingNewline
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
    /// comes from the separator row. The `raw` string preserves the
    /// exact source text for byte-equal round-trip serialization of
    /// tables the user never edits; once a cell is edited, `raw` is
    /// recomputed canonically from the inline trees.
    ///
    /// The refactor from opaque cell strings to inline trees is the
    /// Option C unification described in CLAUDE.md — cell content is
    /// "a paragraph inside a cell, that's all it is." The widget and
    /// the primitives both operate on inline trees; the local
    /// `parseInlineMarkdown` in `InlineTableView` that used to
    /// re-implement inline parsing has been replaced with the real
    /// `InlineRenderer`.
    case table(header: [TableCell], alignments: [TableAlignment], rows: [[TableCell]], raw: String)

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

    public init(
        indent: String,
        marker: String,
        afterMarker: String,
        checkbox: Checkbox? = nil,
        inline: [Inline],
        children: [ListItem],
        blankLineBefore: Bool = false
    ) {
        self.indent = indent
        self.marker = marker
        self.afterMarker = afterMarker
        self.checkbox = checkbox
        self.inline = inline
        self.children = children
        self.blankLineBefore = blankLineBefore
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
    case math(String)                  // $…$ — inline LaTeX math
    case displayMath(String)           // $$…$$ — display LaTeX math
    /// A wikilink: `[[target]]` or `[[target|display]]`. The target is
    /// the note name (resolved by the editor at click time); `display`
    /// is the optional pipe-delimited alt text shown in place of the
    /// target. The brackets do NOT appear in the rendered output —
    /// only the display text (or the target if no display).
    case wikilink(target: String, display: String?)
}
