//
//  MarkdownBlockParser.swift
//  FSNotes
//
//  Source-mode block-based FSM parser for markdown documents.
//  Produces an ordered [MarkdownBlock] array used by the source-mode
//  rendering pipeline (source mode, non-markdown notes) and by
//  fold/unfold operations. The block-model pipeline
//  (Document/DocumentRenderer) is now the source of truth for
//  WYSIWYG rendering.
//

import Foundation

// MARK: - Block Types

public enum MarkdownBlockType: Equatable {
    case paragraph
    case heading(level: Int)            // 1-6, ATX style (# through ######)
    case headingSetext(level: Int)      // 1-2, underline style (=== or ---)
    case codeBlock(language: String?)   // Fenced ``` ... ```
    case blockquote                     // > prefixed lines
    case unorderedList                  // -, *, + items
    case orderedList                    // 1. items
    case todoItem(checked: Bool)        // - [ ] or - [x]
    case horizontalRule                 // ---, ***, ___
    case table                          // | col | col |
    case yamlFrontmatter                // --- yaml ---
    case empty                          // Blank lines
}

// MARK: - Block Render Mode

/// Controls how a block is displayed in the editor.
/// `.source` shows raw markdown text; `.rendered` shows an image or widget.
public enum BlockRenderMode {
    case source     // Show as markdown text (default)
    case rendered   // Show as image/widget (mermaid graphic, table widget, etc.)
}

// MARK: - Block Model

public struct MarkdownBlock {
    public let id: UUID
    public let type: MarkdownBlockType
    public var range: NSRange               // Full range in textStorage (includes syntax)
    public var contentRange: NSRange        // Range of visible content (excludes syntax delimiters)
    public var syntaxRanges: [NSRange]      // Ranges of syntax chars to hide in WYSIWYG
    // Phase 6 Tier B′ Sub-slice 7: per-block `collapsed` and
    // `renderMode` fields both retired. Fold state lives canonically
    // on `TextStorageProcessor.collapsedStorageOffsets`; render-mode
    // state lives on `TextStorageProcessor.renderedStorageOffsets`.
    // Both side-tables are offset-keyed (block.range.location); query
    // via the public `isCollapsed(...)` / `isRendered(...)` APIs.
    /// Original markdown source for blocks whose rendered output differs
    /// from the source (e.g. tables in block-model mode). Used by
    /// renderTables() to parse the table without reading storage.
    public var rawMarkdown: String?

    public init(
        id: UUID = UUID(),
        type: MarkdownBlockType,
        range: NSRange,
        contentRange: NSRange,
        syntaxRanges: [NSRange] = []
    ) {
        self.id = id
        self.type = type
        self.range = range
        self.contentRange = contentRange
        self.syntaxRanges = syntaxRanges
    }
}

// MARK: - Parser FSM States

private enum ParserState {
    case ready
    case inCodeBlock(language: String?, fenceStart: Int, fenceLength: Int)
    case inBlockquote(start: Int)
    case inUnorderedList(start: Int)
    case inOrderedList(start: Int)
    case inTable(start: Int)
    case inYamlFrontmatter(start: Int)
}

// MARK: - Parser

public class MarkdownBlockParser {

    // MARK: - Line Classification

    private enum LineType {
        case empty
        case codeFenceOpen(language: String?, fenceLength: Int)
        case codeFenceClose(fenceLength: Int)
        case heading(level: Int, prefixLength: Int)       // ATX: # through ######
        case setextUnderline(level: Int)                   // === (level 1) or --- (level 2)
        case blockquote                                     // > ...
        case unorderedListItem                              // - , * , +
        case orderedListItem                                // 1. , 2. , etc.
        case todoItem(checked: Bool)                        // - [ ] or - [x]
        case horizontalRule                                 // ---, ***, ___
        case tableLine                                      // | ... |
        case yamlFence                                      // --- at document start/end
        case text                                           // Anything else
    }

    // MARK: - Full Document Parse

    /// Parse an entire document into blocks. Used on initial load.
    public static func parse(string: NSString) -> [MarkdownBlock] {
        let parser = MarkdownBlockParser()
        return parser.parseDocument(string: string)
    }

    /// Full reparse preserving rendered blocks. Rendered blocks contain attachment
    /// characters that the parser can't handle — they're extracted before parsing
    /// and re-inserted at their correct positions afterward.
    ///
    /// Phase 6 Tier B′ Sub-slice 7.B.1: `renderedOffsets` is the set
    /// of `block.range.location` values that the caller's offset-keyed
    /// side-table marks as `.rendered`. The parser uses this in lieu
    /// of the retired `MarkdownBlock.renderMode` field to identify
    /// blocks that must be skipped + re-injected.
    public static func parsePreservingRendered(
        _ blocks: inout [MarkdownBlock],
        string: NSString,
        renderedOffsets: Set<Int>
    ) {
        let rendered = blocks.filter {
            renderedOffsets.contains($0.range.location)
        }
        blocks = parse(string: string)
        for r in rendered {
            let insertIdx = blocks.firstIndex(where: { $0.range.location > r.range.location }) ?? blocks.endIndex
            blocks.insert(r, at: insertIdx)
        }
    }

    /// Parse a range of the document. Used for incremental updates.
    /// The range should be expanded to full line boundaries before calling.
    public static func parseRange(string: NSString, range: NSRange) -> [MarkdownBlock] {
        let parser = MarkdownBlockParser()
        return parser.parseRegion(string: string, range: range)
    }

    // MARK: - Incremental Update

    /// Adjust existing block ranges after a text edit.
    /// Returns the indices of blocks that need re-parsing.
    ///
    /// Phase 6 Tier B′ Sub-slice 7.B.1: `renderedOffsets` is the
    /// set of `block.range.location` values for blocks the caller
    /// considers `.rendered` (no longer carried on the per-block
    /// field). The lookup happens against each block's pre-shift
    /// offset, which is what the side-table is keyed on.
    public static func adjustBlocks(
        _ blocks: inout [MarkdownBlock],
        forEditAt editLocation: Int,
        delta: Int,
        renderedOffsets: Set<Int>
    ) -> IndexSet {
        var dirtyIndices = IndexSet()

        for i in 0..<blocks.count {
            let block = blocks[i]

            if NSMaxRange(block.range) < editLocation {
                // Block is entirely before the edit — unchanged
                continue
            } else if block.range.location > editLocation {
                // Block is entirely after the edit — shift
                blocks[i].range.location += delta
                blocks[i].contentRange.location += delta
                blocks[i].syntaxRanges = block.syntaxRanges.map {
                    NSRange(location: $0.location + delta, length: $0.length)
                }
            } else {
                // Block contains the edit — dirty (unless rendered: frozen blocks
                // must not be re-parsed since their text is an attachment character)
                blocks[i].range.length = max(0, blocks[i].range.length + delta)
                if !renderedOffsets.contains(block.range.location) {
                    dirtyIndices.insert(i)
                }
            }
        }

        return dirtyIndices
    }

    /// Re-parse dirty blocks and their source-mode neighbors, splicing results in.
    /// Rendered blocks are never included in the reparse range (their text is an
    /// attachment character that the parser can't handle).
    ///
    /// Phase 6 Tier B′ Sub-slice 7.B.1: `renderedOffsets` replaces
    /// the retired `MarkdownBlock.renderMode` field for the
    /// neighbour-source-mode test that decides how far to extend the
    /// splice range.
    public static func reparseBlocks(
        _ blocks: inout [MarkdownBlock],
        dirtyIndices: IndexSet,
        string: NSString,
        renderedOffsets: Set<Int>
    ) {
        guard !dirtyIndices.isEmpty else { return }

        // Find the splice range: dirty blocks + one source-mode neighbor on each side.
        guard let firstDirty = dirtyIndices.first, let lastDirty = dirtyIndices.last else { return }

        // Expand to neighbors, but only if they're source-mode blocks
        let prevIsSource = firstDirty > 0
            && !renderedOffsets.contains(blocks[firstDirty - 1].range.location)
        let nextIsSource = lastDirty < blocks.count - 1
            && !renderedOffsets.contains(blocks[lastDirty + 1].range.location)
        let prevIdx = prevIsSource ? firstDirty - 1 : firstDirty
        let nextIdx = nextIsSource ? lastDirty + 1 : lastDirty
        let minIdx = prevIdx
        let maxIdx = nextIdx

        let startLoc = blocks[minIdx].range.location
        let endLoc = min(NSMaxRange(blocks[maxIdx].range), string.length)
        guard startLoc < endLoc else {
            parsePreservingRendered(
                &blocks, string: string, renderedOffsets: renderedOffsets
            )
            return
        }

        let reparseRange = NSRange(location: startLoc, length: endLoc - startLoc)
        let newBlocks = parseRange(string: string, range: reparseRange)

        // Splice: remove old source blocks in [minIdx...maxIdx], insert new ones.
        let replaceRange = minIdx...maxIdx
        blocks.replaceSubrange(replaceRange, with: newBlocks)
    }

    // MARK: - Internal Parsing

    private var state: ParserState = .ready
    private var blocks: [MarkdownBlock] = []
    private var isFirstLine = true

    private func parseDocument(string: NSString) -> [MarkdownBlock] {
        let fullRange = NSRange(location: 0, length: string.length)
        return parseRegion(string: string, range: fullRange)
    }

    private func parseRegion(string: NSString, range: NSRange) -> [MarkdownBlock] {
        state = .ready
        blocks = []
        isFirstLine = (range.location == 0)

        var lineStart = range.location
        let end = NSMaxRange(range)

        while lineStart < end {
            let lineRange = string.paragraphRange(for: NSRange(location: lineStart, length: 0))
            // Clamp to our parse region
            let clampedEnd = min(NSMaxRange(lineRange), end)
            let clampedRange = NSRange(location: lineRange.location, length: clampedEnd - lineRange.location)

            let line = string.substring(with: clampedRange)
            let lineType = classifyLine(line, string: string)

            processLine(lineType: lineType, line: line, lineRange: clampedRange, string: string)

            isFirstLine = false
            lineStart = NSMaxRange(lineRange)
            if lineStart <= lineRange.location { break } // Safety: prevent infinite loop
        }

        // Close any open multi-line block
        closeCurrentBlock(at: end, string: string)

        return blocks
    }

    // MARK: - Line Classification

    private func classifyLine(_ line: String, string: NSString? = nil) -> LineType {
        let trimmed = line.trimmingCharacters(in: .newlines)

        // Empty line
        if trimmed.trimmingCharacters(in: .whitespaces).isEmpty {
            return .empty
        }

        // Code fence: ``` or ```language
        if trimmed.hasPrefix("```") {
            let afterFence = String(trimmed.dropFirst(3))
            if afterFence.isEmpty || afterFence.allSatisfy({ $0.isWhitespace }) {
                if case .inCodeBlock = state {
                    return .codeFenceClose(fenceLength: 3)
                } else {
                    return .codeFenceOpen(language: nil, fenceLength: 3)
                }
            }
            // Check if it's a language specifier (no spaces in language name for opening fence)
            if case .inCodeBlock = state {
                return .text // Content inside code block that starts with ```
            }
            let lang = afterFence.trimmingCharacters(in: .whitespaces)
            if !lang.contains(" ") && !lang.contains("`") {
                return .codeFenceOpen(language: lang.isEmpty ? nil : lang, fenceLength: 3)
            }
            return .text
        }

        // Inside a code block, everything is text
        if case .inCodeBlock = state {
            return .text
        }

        // YAML frontmatter fence (--- at document start or to close YAML)
        if trimmed == "---" {
            if isFirstLine && blocks.isEmpty {
                return .yamlFence
            }
            if case .inYamlFrontmatter = state {
                return .yamlFence
            }
            // Could be HR — check below
        }

        // ATX heading: # through ######
        if let level = atxHeadingLevel(trimmed) {
            return .heading(level: level, prefixLength: level + 1) // # + space
        }

        // Setext underline: === or ---  (only if previous block is paragraph).
        // This must be checked before horizontalRule so "Title\n---" is parsed
        // as a heading, not as a paragraph followed by <hr>.
        if isSetextUnderline(trimmed, string: string) {
            return .setextUnderline(level: trimmed.hasPrefix("=") ? 1 : 2)
        }

        // Horizontal rule: 3+ of -, *, or _ (optionally with spaces)
        if isHorizontalRule(trimmed) {
            return .horizontalRule
        }

        // Blockquote: > at start
        if trimmed.hasPrefix(">") {
            return .blockquote
        }

        // Todo item: - [ ] or - [x] or * [ ] etc.
        if let checked = isTodoItem(trimmed) {
            return .todoItem(checked: checked)
        }

        // Unordered list: - , * , + followed by space
        if isUnorderedListItem(trimmed) {
            return .unorderedListItem
        }

        // Ordered list: digits followed by . and space
        if isOrderedListItem(trimmed) {
            return .orderedListItem
        }

        // Table line: starts and ends with |
        let stripped = trimmed.trimmingCharacters(in: .whitespaces)
        if stripped.hasPrefix("|") && stripped.hasSuffix("|") {
            return .tableLine
        }

        return .text
    }

    // MARK: - Line Pattern Helpers

    private func atxHeadingLevel(_ line: String) -> Int? {
        var level = 0
        for ch in line {
            if ch == "#" { level += 1 }
            else if ch == " " && level > 0 { break }
            else { return nil }
        }
        return (level >= 1 && level <= 6) ? level : nil
    }

    private func isHorizontalRule(_ line: String) -> Bool {
        let stripped = line.replacingOccurrences(of: " ", with: "")
        if stripped.count < 3 { return false }
        let first = stripped.first!
        guard first == "-" || first == "*" || first == "_" else { return false }
        return stripped.allSatisfy { $0 == first }
    }

    private func isSetextUnderline(_ line: String, string: NSString? = nil) -> Bool {
        let stripped = line.trimmingCharacters(in: .whitespaces)
        if stripped.count < 2 { return false }
        if stripped.allSatisfy({ $0 == "=" }) { return true }
        // --- could be HR or setext — setext only if previous block is a plain
        // paragraph that doesn't start with emphasis markers (**, *, __, _).
        // A bold paragraph like "**Bold text**\n---" should be paragraph + HR,
        // not a setext H2.
        if stripped.allSatisfy({ $0 == "-" }) {
            if let lastBlock = blocks.last, case .paragraph = lastBlock.type {
                // Check the previous block's content for emphasis markers
                if let str = string {
                    let content = str.substring(with: lastBlock.contentRange)
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    if content.hasPrefix("**") || content.hasPrefix("__") ||
                       content.hasPrefix("*") || content.hasPrefix("_") {
                        return false
                    }
                }
                return true
            }
        }
        return false
    }

    private func isTodoItem(_ line: String) -> Bool? {
        let stripped = line.trimmingCharacters(in: .whitespaces)
        // Raw markdown checkboxes
        if stripped.hasPrefix("- [ ] ") || stripped.hasPrefix("* [ ] ") || stripped.hasPrefix("+ [ ] ") {
            return false
        }
        if stripped.hasPrefix("- [x] ") || stripped.hasPrefix("* [x] ") || stripped.hasPrefix("+ [x] ") ||
           stripped.hasPrefix("- [X] ") || stripped.hasPrefix("* [X] ") || stripped.hasPrefix("+ [X] ") {
            return true
        }
        return nil
    }

    private func isUnorderedListItem(_ line: String) -> Bool {
        let stripped = line.trimmingCharacters(in: .whitespaces)
        // Check for marker + space (has content) OR bare marker (empty bullet, e.g. after Return).
        // Storage always contains original markdown markers (no • substitution).
        let hasMarkerWithContent = stripped.hasPrefix("- ") || stripped.hasPrefix("* ") || stripped.hasPrefix("+ ")
        let isBareMarker = stripped == "-" || stripped == "*" || stripped == "+"
        return (hasMarkerWithContent || isBareMarker) &&
               !stripped.hasPrefix("- [ ") && !stripped.hasPrefix("- [x") && !stripped.hasPrefix("- [X")
    }

    private func isOrderedListItem(_ line: String) -> Bool {
        let stripped = line.trimmingCharacters(in: .whitespaces)
        // Match digits followed by . and space
        var i = stripped.startIndex
        while i < stripped.endIndex && stripped[i].isNumber { i = stripped.index(after: i) }
        if i == stripped.startIndex { return false }
        if i < stripped.endIndex && stripped[i] == "." {
            let afterDot = stripped.index(after: i)
            if afterDot < stripped.endIndex && stripped[afterDot] == " " { return true }
            if afterDot == stripped.endIndex { return true }
        }
        return false
    }

    // MARK: - FSM Processing

    private func processLine(lineType: LineType, line: String, lineRange: NSRange, string: NSString) {
        switch state {

        // ── READY STATE ──
        case .ready:
            switch lineType {
            case .empty:
                emitBlock(type: .empty, range: lineRange, contentRange: lineRange)

            case .codeFenceOpen(let lang, let fenceLen):
                state = .inCodeBlock(language: lang, fenceStart: lineRange.location, fenceLength: fenceLen)

            case .yamlFence:
                state = .inYamlFrontmatter(start: lineRange.location)

            case .heading(let level, let prefixLen):
                let syntaxRange = NSRange(location: lineRange.location, length: min(prefixLen, lineRange.length))
                let contentStart = lineRange.location + min(prefixLen, lineRange.length)
                let contentLen = max(0, lineRange.length - prefixLen)
                let contentRange = NSRange(location: contentStart, length: contentLen)
                emitBlock(type: .heading(level: level), range: lineRange, contentRange: contentRange, syntaxRanges: [syntaxRange])

            case .setextUnderline(let level):
                // Convert previous paragraph to heading
                if let lastIdx = blocks.indices.last, case .paragraph = blocks[lastIdx].type {
                    let prevRange = blocks[lastIdx].range
                    let fullRange = NSRange(location: prevRange.location, length: NSMaxRange(lineRange) - prevRange.location)
                    blocks[lastIdx] = MarkdownBlock(type: .headingSetext(level: level), range: fullRange,
                                                     contentRange: prevRange, syntaxRanges: [lineRange])
                } else {
                    // Not preceded by paragraph — treat as HR or text
                    if level == 2 {
                        emitBlock(type: .horizontalRule, range: lineRange, contentRange: lineRange, syntaxRanges: [lineRange])
                    } else {
                        emitBlock(type: .paragraph, range: lineRange, contentRange: lineRange)
                    }
                }

            case .horizontalRule:
                emitBlock(type: .horizontalRule, range: lineRange, contentRange: lineRange, syntaxRanges: [lineRange])

            case .blockquote:
                state = .inBlockquote(start: lineRange.location)

            case .todoItem(let checked):
                // If line starts with attachment char (rendered checkbox), there's no
                // markdown syntax to hide — the attachment IS the rendered form.
                // Only hide syntax for raw markdown "- [ ] ".
                let lineText = string.substring(with: lineRange)
                if lineText.hasPrefix("\u{FFFC}") {
                    // Rendered checkbox: attachment (1 char) + space (1 char) = 2
                    let markerLen = 2
                    let contentStart = lineRange.location + min(markerLen, lineRange.length)
                    let contentLen = max(0, lineRange.length - markerLen)
                    emitBlock(type: .todoItem(checked: checked), range: lineRange,
                             contentRange: NSRange(location: contentStart, length: contentLen),
                             syntaxRanges: [])  // No syntax to hide
                } else {
                    // Raw markdown: [leadingWhitespace] + "- [ ] " (6 chars)
                    // Leading tabs/spaces MUST be part of the hidden syntax range,
                    // otherwise indented todo items leak "]" past the hidden zone.
                    var leadingWS = 0
                    for ch in lineText {
                        if ch == " " || ch == "\t" { leadingWS += 1 } else { break }
                    }
                    let markerLen = leadingWS + 6
                    let syntaxRange = NSRange(location: lineRange.location, length: min(markerLen, lineRange.length))
                    let contentStart = lineRange.location + min(markerLen, lineRange.length)
                    let contentLen = max(0, lineRange.length - markerLen)
                    emitBlock(type: .todoItem(checked: checked), range: lineRange,
                             contentRange: NSRange(location: contentStart, length: contentLen),
                             syntaxRanges: [syntaxRange])
                }

            case .unorderedListItem:
                state = .inUnorderedList(start: lineRange.location)

            case .orderedListItem:
                state = .inOrderedList(start: lineRange.location)

            case .tableLine:
                state = .inTable(start: lineRange.location)

            case .text:
                emitBlock(type: .paragraph, range: lineRange, contentRange: lineRange)

            case .codeFenceClose:
                // Stray closing fence — treat as text
                emitBlock(type: .paragraph, range: lineRange, contentRange: lineRange)
            }

        // ── CODE BLOCK STATE ──
        case .inCodeBlock(let lang, let fenceStart, _):
            switch lineType {
            case .codeFenceClose:
                let fullRange = NSRange(location: fenceStart, length: NSMaxRange(lineRange) - fenceStart)
                // Opening fence line
                let openFenceEnd = string.paragraphRange(for: NSRange(location: fenceStart, length: 0))
                let openFenceRange = NSRange(location: fenceStart, length: openFenceEnd.length)
                // Closing fence line
                let closeFenceRange = lineRange
                // Content is between fences
                let contentStart = NSMaxRange(openFenceRange)
                let contentEnd = lineRange.location
                let contentRange = NSRange(location: contentStart, length: max(0, contentEnd - contentStart))
                emitBlock(type: .codeBlock(language: lang), range: fullRange,
                         contentRange: contentRange, syntaxRanges: [openFenceRange, closeFenceRange])
                state = .ready
            default:
                break // Continue accumulating
            }

        // ── BLOCKQUOTE STATE ──
        case .inBlockquote(let start):
            switch lineType {
            case .blockquote:
                break // Continue accumulating
            default:
                // Close blockquote
                let fullRange = NSRange(location: start, length: lineRange.location - start)
                emitBlockquote(range: fullRange, string: string)
                state = .ready
                // Re-process current line
                processLine(lineType: lineType, line: line, lineRange: lineRange, string: string)
            }

        // ── UNORDERED LIST STATE ──
        case .inUnorderedList(let start):
            switch lineType {
            case .unorderedListItem, .todoItem:
                break // Continue accumulating
            case .empty:
                // Could be loose list — peek ahead
                // For now, close the list
                let fullRange = NSRange(location: start, length: lineRange.location - start)
                emitList(type: .unorderedList, range: fullRange, string: string)
                state = .ready
                processLine(lineType: lineType, line: line, lineRange: lineRange, string: string)
            default:
                let fullRange = NSRange(location: start, length: lineRange.location - start)
                emitList(type: .unorderedList, range: fullRange, string: string)
                state = .ready
                processLine(lineType: lineType, line: line, lineRange: lineRange, string: string)
            }

        // ── ORDERED LIST STATE ──
        case .inOrderedList(let start):
            switch lineType {
            case .orderedListItem:
                break // Continue accumulating
            case .empty:
                let fullRange = NSRange(location: start, length: lineRange.location - start)
                emitList(type: .orderedList, range: fullRange, string: string)
                state = .ready
                processLine(lineType: lineType, line: line, lineRange: lineRange, string: string)
            default:
                let fullRange = NSRange(location: start, length: lineRange.location - start)
                emitList(type: .orderedList, range: fullRange, string: string)
                state = .ready
                processLine(lineType: lineType, line: line, lineRange: lineRange, string: string)
            }

        // ── TABLE STATE ──
        case .inTable(let start):
            switch lineType {
            case .tableLine:
                break // Continue accumulating
            default:
                let fullRange = NSRange(location: start, length: lineRange.location - start)
                emitBlock(type: .table, range: fullRange, contentRange: fullRange)
                state = .ready
                processLine(lineType: lineType, line: line, lineRange: lineRange, string: string)
            }

        // ── YAML FRONTMATTER STATE ──
        case .inYamlFrontmatter(let start):
            switch lineType {
            case .yamlFence:
                let fullRange = NSRange(location: start, length: NSMaxRange(lineRange) - start)
                emitBlock(type: .yamlFrontmatter, range: fullRange, contentRange: fullRange)
                state = .ready
            default:
                break // Continue accumulating
            }
        }
    }

    // MARK: - Block Emission

    private func emitBlock(type: MarkdownBlockType, range: NSRange, contentRange: NSRange, syntaxRanges: [NSRange] = []) {
        blocks.append(MarkdownBlock(type: type, range: range, contentRange: contentRange, syntaxRanges: syntaxRanges))
    }

    private func emitBlockquote(range: NSRange, string: NSString) {
        // Parse ALL `>` prefixes per line as syntax ranges (supports nested blockquotes).
        // Each `>` (with optional trailing space) is a separate syntax range to hide.
        var syntaxRanges: [NSRange] = []
        var lineStart = range.location
        let end = NSMaxRange(range)

        while lineStart < end {
            let lineRange = string.paragraphRange(for: NSRange(location: lineStart, length: 0))
            let line = string.substring(with: lineRange)
            let trimmed = line.trimmingCharacters(in: .newlines)

            // Count and record all `>` prefixes (with optional spaces between them)
            var pos = 0
            while pos < trimmed.count {
                let idx = trimmed.index(trimmed.startIndex, offsetBy: pos)
                if trimmed[idx] == ">" {
                    // `>` followed by optional space
                    let syntaxLen = (pos + 1 < trimmed.count && trimmed[trimmed.index(after: idx)] == " ") ? 2 : 1
                    syntaxRanges.append(NSRange(location: lineRange.location + pos, length: syntaxLen))
                    pos += syntaxLen
                } else if trimmed[idx] == " " {
                    // Skip leading spaces between `>` markers
                    pos += 1
                } else {
                    break
                }
            }

            lineStart = NSMaxRange(lineRange)
            if lineStart <= lineRange.location { break }
        }

        emitBlock(type: .blockquote, range: range, contentRange: range, syntaxRanges: syntaxRanges)
    }

    private func emitList(type: MarkdownBlockType, range: NSRange, string: NSString) {
        // For now, emit the entire list as one block
        // The syntax ranges are the list markers (-, *, +, 1., etc.)
        var syntaxRanges: [NSRange] = []
        var lineStart = range.location
        let end = NSMaxRange(range)

        while lineStart < end {
            let lineRange = string.paragraphRange(for: NSRange(location: lineStart, length: 0))
            let line = string.substring(with: lineRange)
            let stripped = line.trimmingCharacters(in: .whitespaces)
            let leadingSpaces = line.prefix(while: { $0 == " " || $0 == "\t" }).count

            if case .unorderedList = type {
                // Find the marker (-, *, +) and space
                if stripped.hasPrefix("- ") || stripped.hasPrefix("* ") || stripped.hasPrefix("+ ") {
                    syntaxRanges.append(NSRange(location: lineRange.location + leadingSpaces, length: 2))
                }
            } else if case .orderedList = type {
                // Find digits + ". "
                var markerLen = 0
                for ch in stripped {
                    if ch.isNumber { markerLen += 1 }
                    else if ch == "." { markerLen += 1; break }
                    else { break }
                }
                if markerLen > 0 {
                    syntaxRanges.append(NSRange(location: lineRange.location + leadingSpaces, length: markerLen + 1)) // +1 for space
                }
            }

            lineStart = NSMaxRange(lineRange)
            if lineStart <= lineRange.location { break }
        }

        emitBlock(type: type, range: range, contentRange: range, syntaxRanges: syntaxRanges)
    }

    private func closeCurrentBlock(at endLocation: Int, string: NSString) {
        switch state {
        case .ready:
            break

        case .inCodeBlock(let lang, let fenceStart, _):
            // Unclosed code block — emit what we have
            let range = NSRange(location: fenceStart, length: endLocation - fenceStart)
            let openFenceEnd = string.paragraphRange(for: NSRange(location: fenceStart, length: 0))
            let contentStart = NSMaxRange(openFenceEnd)
            let contentRange = NSRange(location: contentStart, length: max(0, endLocation - contentStart))
            emitBlock(type: .codeBlock(language: lang), range: range, contentRange: contentRange,
                     syntaxRanges: [NSRange(location: fenceStart, length: openFenceEnd.length)])

        case .inBlockquote(let start):
            let range = NSRange(location: start, length: endLocation - start)
            emitBlockquote(range: range, string: string)

        case .inUnorderedList(let start):
            let range = NSRange(location: start, length: endLocation - start)
            emitList(type: .unorderedList, range: range, string: string)

        case .inOrderedList(let start):
            let range = NSRange(location: start, length: endLocation - start)
            emitList(type: .orderedList, range: range, string: string)

        case .inTable(let start):
            let range = NSRange(location: start, length: endLocation - start)
            emitBlock(type: .table, range: range, contentRange: range)

        case .inYamlFrontmatter(let start):
            let range = NSRange(location: start, length: endLocation - start)
            emitBlock(type: .yamlFrontmatter, range: range, contentRange: range)
        }

        state = .ready
    }

    // MARK: - Query Helpers

    /// Find the block containing the given character index. O(log n) via binary search.
    public static func blockIndex(in blocks: [MarkdownBlock], containing characterIndex: Int) -> Int? {
        var lo = 0, hi = blocks.count - 1
        while lo <= hi {
            let mid = (lo + hi) / 2
            let block = blocks[mid]
            if characterIndex < block.range.location {
                hi = mid - 1
            } else if characterIndex >= NSMaxRange(block.range) {
                lo = mid + 1
            } else {
                return mid
            }
        }
        return nil
    }

    /// Get all blocks that intersect the given range.
    public static func blocks(in allBlocks: [MarkdownBlock], intersecting range: NSRange) -> ArraySlice<MarkdownBlock> {
        guard !allBlocks.isEmpty else { return [] }

        // Find first block that could intersect
        var startIdx = 0
        for (i, block) in allBlocks.enumerated() {
            if NSMaxRange(block.range) > range.location {
                startIdx = i
                break
            }
            if i == allBlocks.count - 1 { return [] }
        }

        // Find last block that intersects
        var endIdx = startIdx
        for i in startIdx..<allBlocks.count {
            if allBlocks[i].range.location >= NSMaxRange(range) { break }
            endIdx = i
        }

        return allBlocks[startIdx...endIdx]
    }
}
