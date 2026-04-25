//
//  FSMTransitions.swift
//  FSNotesTests
//
//  Phase 11 Slice A.5 — single source-of-truth FSM transition table.
//
//  Each `FSMTransition` row tabulates one (blockKind, cursorPosition,
//  action) → expectedTransition tuple. The parameterised runner in
//  `FSMTransitionTableTests.swift` drives every row through
//  `EditorScenario` (the Phase 11 Slice A Given/When/Then harness),
//  reads the post-edit `Document`, and asserts the row's expected
//  outcome.
//
//  Bug rows (rows that encode the EXPECTED-AFTER-FIX behaviour for
//  bugs from REFACTOR_PLAN.md Slice B's 31-bug inventory) carry a
//  non-nil `bugId` and are wrapped in `XCTExpectFailure(strict: true)`
//  by the runner — they fail-by-design today and will flip to
//  "unexpectedly passed" → red when the underlying FSM is fixed.
//
//  Schema is intentionally coarse-grained:
//    - `expected` is one of a small enum of structural outcomes
//      (stayInBlock, splitBlock, mergeWithPrevious, exitToBlock,
//       noOp, indent, outdent, insertAtomic, unsupported).
//    - Anything finer (post-edit cursor position, exact suffix text)
//      is encoded in the row's free-form `note` field for human
//      review and asserted by the runner where deterministic.
//
//  Coverage: ~95 rows across paragraph / heading / list (bullet,
//  numbered, todo) / blockquote / codeBlock / table / horizontalRule /
//  blankLine.  Mermaid and display-math rendering paths exist but
//  their FSM behaviour is the same as a code-block (verbatim insert)
//  or atomic block (HR-style) and is sampled rather than enumerated
//  combinatorially — the goal is to lock the SHAPE of the FSM, not
//  to fuzz every possible source-string permutation.
//

import Foundation

// MARK: - Fixture enums

/// Canonical block kinds the FSM table addresses. Mirrors
/// `FSNotesCore.Block` cases at the resolution the FSM cares about
/// (heading levels collapsed to a single fixture; bullet vs numbered
/// vs todo split out because their FSM transitions diverge).
enum BlockKindFixture: Equatable, CustomStringConvertible {
    case paragraph
    case heading(level: Int)
    case bulletList
    case numberedList
    case todoList
    case blockquote
    case codeBlock
    case table
    case horizontalRule
    case blankLine

    var description: String {
        switch self {
        case .paragraph:        return "paragraph"
        case .heading(let l):   return "heading(\(l))"
        case .bulletList:       return "bulletList"
        case .numberedList:     return "numberedList"
        case .todoList:         return "todoList"
        case .blockquote:       return "blockquote"
        case .codeBlock:        return "codeBlock"
        case .table:            return "table"
        case .horizontalRule:   return "horizontalRule"
        case .blankLine:        return "blankLine"
        }
    }
}

/// Where the cursor sits inside the target block before the action.
enum CursorPositionFixture: Equatable, CustomStringConvertible {
    /// Offset 0 of the block's editable inline content.
    case atStart
    /// Strictly between content (some non-zero offset, not at end).
    case midContent
    /// Cursor is past the last typed character of the block.
    case atEnd
    /// Block has zero typed characters (empty list item, empty
    /// paragraph, etc.) and the cursor is at the only valid offset.
    case onEmptyBlock

    var description: String {
        switch self {
        case .atStart:      return "atStart"
        case .midContent:   return "midContent"
        case .atEnd:        return "atEnd"
        case .onEmptyBlock: return "onEmptyBlock"
        }
    }
}

/// Editor-side actions exercised by the table.
enum ActionFixture: Equatable, CustomStringConvertible {
    case pressReturn
    case pressBackspace
    case pressForwardDelete
    case pressTab
    case pressShiftTab
    /// Delete a non-empty selection that fully covers the block.
    /// Used by triple-click + delete (#18).
    case selectBlockAndDelete

    var description: String {
        switch self {
        case .pressReturn:           return "pressReturn"
        case .pressBackspace:        return "pressBackspace"
        case .pressForwardDelete:    return "pressForwardDelete"
        case .pressTab:              return "pressTab"
        case .pressShiftTab:         return "pressShiftTab"
        case .selectBlockAndDelete:  return "selectBlockAndDelete"
        }
    }
}

/// The structural outcome the FSM should produce. Coarse-grained on
/// purpose — see file header.
enum ExpectedTransition: Equatable, CustomStringConvertible {
    /// Block count and the kind at the cursor's owner index are
    /// preserved (an inline-only edit, e.g. typing a character).
    case stayInBlock
    /// One block becomes two adjacent blocks. The second block has
    /// the given kind; the first keeps the source kind unless the
    /// `firstBecomes` override is set.
    case splitBlock(into: BlockKindFixture, firstBecomes: BlockKindFixture? = nil)
    /// The block at the cursor merges into the previous block (delete
    /// across a block boundary). Final block count = before − 1.
    case mergeWithPrevious
    /// The block transforms into a block of a different kind (no
    /// split, count unchanged). Used for "exit list to paragraph"
    /// and "remove HR/table → empty paragraph."
    case exitToBlock(BlockKindFixture)
    /// The block count and content are unchanged (action is ignored
    /// or the block kind doesn't accept it).
    case noOp
    /// List item moves one level deeper. Block count unchanged; the
    /// containing list's nesting depth increases.
    case indent
    /// List item moves one level shallower (or out of the list
    /// entirely if at depth 0 — see `exitToBlock` for that case).
    case outdent
    /// An atomic block (HR / table) is inserted at the cursor.
    case insertAtomic(BlockKindFixture)
    /// The combination is genuinely unsupported (e.g. mid-content
    /// position inside an HR — HRs have no editable inline content).
    /// The runner skips these rather than asserting. Present in the
    /// table as documentation.
    case unsupported

    var description: String {
        switch self {
        case .stayInBlock:                  return "stayInBlock"
        case .splitBlock(let k, let f):
            if let f = f { return "splitBlock(into: \(k), firstBecomes: \(f))" }
            return "splitBlock(into: \(k))"
        case .mergeWithPrevious:            return "mergeWithPrevious"
        case .exitToBlock(let k):           return "exitToBlock(\(k))"
        case .noOp:                         return "noOp"
        case .indent:                       return "indent"
        case .outdent:                      return "outdent"
        case .insertAtomic(let k):          return "insertAtomic(\(k))"
        case .unsupported:                  return "unsupported"
        }
    }
}

/// Where the cursor lands AFTER the transition. Coarse-grained; the
/// runner asserts these only when the row sets a non-nil value (some
/// rows leave the cursor placement implicit and only the structural
/// expectation matters).
enum CursorPlacementFixture: Equatable, CustomStringConvertible {
    /// Cursor at offset 0 of the newly-inserted block (split / atomic).
    case atStartOfNewBlock
    /// Cursor at end of the previous block (after a merge).
    case atEndOfPreviousBlock
    /// Cursor offset unchanged in storage.
    case preserved
    /// Don't assert cursor placement (row only encodes structure).
    case unchecked

    var description: String {
        switch self {
        case .atStartOfNewBlock:    return "atStartOfNewBlock"
        case .atEndOfPreviousBlock: return "atEndOfPreviousBlock"
        case .preserved:            return "preserved"
        case .unchecked:            return "unchecked"
        }
    }
}

// MARK: - FSMTransition row

/// One row in the FSM transition table.
struct FSMTransition {
    let blockKind: BlockKindFixture
    let cursorPosition: CursorPositionFixture
    let action: ActionFixture
    let expected: ExpectedTransition
    let cursorAfter: CursorPlacementFixture
    let note: String
    /// Slice-B inventory number when this row encodes the
    /// EXPECTED-AFTER-FIX behaviour for a known bug. The runner
    /// wraps such rows in `XCTExpectFailure(strict: true)`.
    let bugId: Int?

    init(
        blockKind: BlockKindFixture,
        cursorPosition: CursorPositionFixture,
        action: ActionFixture,
        expected: ExpectedTransition,
        cursorAfter: CursorPlacementFixture = .unchecked,
        note: String,
        bugId: Int? = nil
    ) {
        self.blockKind = blockKind
        self.cursorPosition = cursorPosition
        self.action = action
        self.expected = expected
        self.cursorAfter = cursorAfter
        self.note = note
        self.bugId = bugId
    }

    /// Compact identifier for failure messages and Xcode's per-row
    /// activity labels.
    var label: String {
        let bug = bugId.map { " #bug\($0)" } ?? ""
        return "\(blockKind) | \(cursorPosition) | \(action) → \(expected)\(bug)"
    }
}

// MARK: - The table

/// All FSM transition rows. Order is by block kind then by action.
///
/// Rows that encode bugs (`bugId != nil`) document the EXPECTED-after-
/// fix behaviour — the runner wraps them in `XCTExpectFailure` so they
/// fail today and turn red ("unexpectedly passed") once the FSM is
/// fixed.
enum FSMTransitionTable {
    static let all: [FSMTransition] = [

        // MARK: paragraph
        FSMTransition(
            blockKind: .paragraph,
            cursorPosition: .midContent,
            action: .pressReturn,
            expected: .splitBlock(into: .paragraph),
            cursorAfter: .atStartOfNewBlock,
            note: "Return mid-paragraph splits via splitParagraphOnNewline into [paragraph(before), blankLine, paragraph(after)] — last slot is the new paragraph."
        ),
        FSMTransition(
            blockKind: .paragraph,
            cursorPosition: .atEnd,
            action: .pressReturn,
            expected: .splitBlock(into: .blankLine),
            cursorAfter: .atStartOfNewBlock,
            note: "Return at end of paragraph creates [paragraph(before), blankLine] — the trailing slot is a blankLine (becomes paragraph on first typed char)."
        ),
        FSMTransition(
            blockKind: .paragraph,
            cursorPosition: .atStart,
            action: .pressReturn,
            expected: .splitBlock(into: .paragraph, firstBecomes: .blankLine),
            cursorAfter: .atStartOfNewBlock,
            note: "Return at start of paragraph: splitParagraphOnNewline returns [blankLine, paragraph(after)] — leading slot becomes blankLine, trailing slot keeps the original content."
        ),
        FSMTransition(
            blockKind: .paragraph,
            cursorPosition: .onEmptyBlock,
            action: .pressReturn,
            expected: .splitBlock(into: .blankLine, firstBecomes: .blankLine),
            cursorAfter: .atStartOfNewBlock,
            note: "Return on empty paragraph: both halves empty → [blankLine, blankLine]."
        ),
        FSMTransition(
            blockKind: .paragraph,
            cursorPosition: .midContent,
            action: .pressBackspace,
            expected: .stayInBlock,
            cursorAfter: .preserved,
            note: "Backspace mid-paragraph deletes one character; block kind and count unchanged."
        ),
        FSMTransition(
            blockKind: .paragraph,
            cursorPosition: .atStart,
            action: .pressBackspace,
            expected: .mergeWithPrevious,
            cursorAfter: .atEndOfPreviousBlock,
            note: "Backspace at start of paragraph N merges with the preceding context (Slice B #8). Delta is -1 in the simple two-block case, -2 when a blankLine separator sits between the merged paragraphs (the merge consumes the separator to keep serialize→parse round-trip correct: [para a, blankLine, para b] would serialize to \"a\\n\\nb\\n\" and re-parse \"ab\\n\" to one paragraph)."
        ),
        FSMTransition(
            blockKind: .paragraph,
            cursorPosition: .atEnd,
            action: .pressBackspace,
            expected: .stayInBlock,
            note: "Backspace at end of paragraph deletes the last typed character; structure unchanged."
        ),
        FSMTransition(
            blockKind: .paragraph,
            cursorPosition: .atEnd,
            action: .pressForwardDelete,
            expected: .mergeWithPrevious,
            note: "Forward-delete at end of paragraph merges the next block into this one (handled by mergeAdjacentBlocks; the row reuses mergeWithPrevious as the structural shape since count goes from N to N-1)."
        ),
        FSMTransition(
            blockKind: .paragraph,
            cursorPosition: .midContent,
            action: .pressForwardDelete,
            expected: .stayInBlock,
            note: "Forward-delete mid-paragraph removes one character."
        ),
        FSMTransition(
            blockKind: .paragraph,
            cursorPosition: .midContent,
            action: .pressTab,
            expected: .stayInBlock,
            note: "Tab in a paragraph (no list context) inserts indent characters per UserDefaultsManagement.indentUsing — block kind and count unchanged."
        ),
        FSMTransition(
            blockKind: .paragraph,
            cursorPosition: .atEnd,
            action: .selectBlockAndDelete,
            expected: .exitToBlock(.paragraph),
            note: "Selecting exactly the paragraph's span and pressing Delete leaves an empty paragraph in place (block kind preserved, content cleared). Slice B #18's 'demotes list below' bug exercises a different shape — triple-click in NSTextView selects past the block boundary into the trailing separator, which is what corrupts the next block; that case isn't a single-block FSM transition and is covered separately."
        ),

        // MARK: heading
        FSMTransition(
            blockKind: .heading(level: 1),
            cursorPosition: .atEnd,
            action: .pressReturn,
            expected: .splitBlock(into: .paragraph),
            cursorAfter: .atStartOfNewBlock,
            note: "Return at end of H1 creates a paragraph below (Slice B #5)."
        ),
        FSMTransition(
            blockKind: .heading(level: 2),
            cursorPosition: .atEnd,
            action: .pressReturn,
            expected: .splitBlock(into: .paragraph),
            cursorAfter: .atStartOfNewBlock,
            note: "Return at end of H2 creates a paragraph below (Slice B #5 generalized)."
        ),
        FSMTransition(
            blockKind: .heading(level: 3),
            cursorPosition: .atEnd,
            action: .pressReturn,
            expected: .splitBlock(into: .paragraph),
            cursorAfter: .atStartOfNewBlock,
            note: "Return at end of H3 creates a paragraph below."
        ),
        FSMTransition(
            blockKind: .heading(level: 1),
            cursorPosition: .midContent,
            action: .pressReturn,
            expected: .splitBlock(into: .paragraph),
            cursorAfter: .atStartOfNewBlock,
            note: "Return mid-heading splits: heading keeps the prefix, new paragraph holds the suffix."
        ),
        FSMTransition(
            blockKind: .heading(level: 1),
            cursorPosition: .atStart,
            action: .pressReturn,
            expected: .splitBlock(into: .heading(level: 1), firstBecomes: .paragraph),
            cursorAfter: .atStartOfNewBlock,
            note: "Return at start of heading: an empty paragraph appears BEFORE; the heading is preserved (Slice B #6)."
        ),
        FSMTransition(
            blockKind: .heading(level: 1),
            cursorPosition: .midContent,
            action: .pressBackspace,
            expected: .stayInBlock,
            note: "Backspace mid-heading removes one character; heading kind preserved."
        ),
        FSMTransition(
            blockKind: .heading(level: 1),
            cursorPosition: .atStart,
            action: .pressBackspace,
            expected: .exitToBlock(.paragraph),
            note: "Backspace at home position of a heading converts the heading to a paragraph (handleDeleteAtHomeInHeading), block count unchanged."
        ),
        FSMTransition(
            blockKind: .heading(level: 1),
            cursorPosition: .atEnd,
            action: .pressBackspace,
            expected: .stayInBlock,
            note: "Backspace at end of heading deletes the last char."
        ),
        FSMTransition(
            blockKind: .heading(level: 1),
            cursorPosition: .midContent,
            action: .pressTab,
            expected: .stayInBlock,
            note: "Tab inside a heading inserts indent characters; heading kind preserved."
        ),
        FSMTransition(
            blockKind: .heading(level: 1),
            cursorPosition: .midContent,
            action: .pressForwardDelete,
            expected: .stayInBlock,
            note: "Forward-delete mid-heading removes one character."
        ),

        // MARK: bulletList
        FSMTransition(
            blockKind: .bulletList,
            cursorPosition: .atEnd,
            action: .pressReturn,
            expected: .stayInBlock,
            note: "Return at end of a bullet item adds a new sibling item via splitListOnNewline; the containing .list block stays one block (Slice B #7)."
        ),
        FSMTransition(
            blockKind: .bulletList,
            cursorPosition: .midContent,
            action: .pressReturn,
            expected: .stayInBlock,
            note: "Return mid-item: split inside the list block — items array grows by one, .list block count unchanged."
        ),
        FSMTransition(
            blockKind: .bulletList,
            cursorPosition: .onEmptyBlock,
            action: .pressReturn,
            expected: .exitToBlock(.paragraph),
            note: "Return on an empty top-level list item exits the list (FSM .exitToBody). The list block is replaced by an empty paragraph."
        ),
        FSMTransition(
            blockKind: .bulletList,
            cursorPosition: .atStart,
            action: .pressBackspace,
            expected: .exitToBlock(.paragraph),
            note: "Backspace at home position of top-level item exits the list (FSM .exitToBody)."
        ),
        FSMTransition(
            blockKind: .bulletList,
            cursorPosition: .midContent,
            action: .pressBackspace,
            expected: .stayInBlock,
            note: "Backspace mid-content deletes a character; list structure unchanged."
        ),
        FSMTransition(
            blockKind: .bulletList,
            cursorPosition: .atStart,
            action: .pressShiftTab,
            expected: .exitToBlock(.paragraph),
            note: "Shift-Tab at top-level item exits to body (FSM .exitToBody → paragraph)."
        ),
        FSMTransition(
            blockKind: .bulletList,
            cursorPosition: .atStart,
            action: .pressTab,
            expected: .indent,
            note: "Tab on a top-level bullet item demotes one level. With no previous sibling the applier wraps the item under a synthetic empty parent so tree depth still increases (bug #25 single-fix-multiple-rows: same FSM behaviour for bullet, numbered, and todo lists)."
        ),
        // Multi-item bullet list — second item, has previous sibling.
        // Encoded via a custom seed in the runner.

        // MARK: numberedList
        FSMTransition(
            blockKind: .numberedList,
            cursorPosition: .atEnd,
            action: .pressReturn,
            expected: .stayInBlock,
            note: "Return at end of numbered item adds a sibling item; .list block kind preserved."
        ),
        FSMTransition(
            blockKind: .numberedList,
            cursorPosition: .onEmptyBlock,
            action: .pressReturn,
            expected: .exitToBlock(.paragraph),
            note: "Return on empty numbered item exits to body."
        ),
        FSMTransition(
            blockKind: .numberedList,
            cursorPosition: .atStart,
            action: .pressBackspace,
            expected: .exitToBlock(.paragraph),
            note: "Backspace at home of top-level numbered item exits to body."
        ),
        FSMTransition(
            blockKind: .numberedList,
            cursorPosition: .atStart,
            action: .pressTab,
            expected: .indent,
            note: "Tab on a numbered list item demotes one level. With no previous sibling the applier wraps the item under a synthetic empty parent so tree depth still increases (bug #25)."
        ),
        FSMTransition(
            blockKind: .numberedList,
            cursorPosition: .atStart,
            action: .pressShiftTab,
            expected: .exitToBlock(.paragraph),
            note: "Shift-Tab on top-level numbered item exits to body."
        ),
        FSMTransition(
            blockKind: .numberedList,
            cursorPosition: .midContent,
            action: .pressBackspace,
            expected: .stayInBlock,
            note: "Backspace mid-content of numbered item deletes a character; structure unchanged."
        ),

        // MARK: todoList
        FSMTransition(
            blockKind: .todoList,
            cursorPosition: .atEnd,
            action: .pressReturn,
            expected: .stayInBlock,
            note: "Return at end of todo item creates another todo item below (sibling); list block count unchanged."
        ),
        FSMTransition(
            blockKind: .todoList,
            cursorPosition: .onEmptyBlock,
            action: .pressReturn,
            expected: .exitToBlock(.paragraph),
            note: "Return on empty todo item exits to body."
        ),
        FSMTransition(
            blockKind: .todoList,
            cursorPosition: .atStart,
            action: .pressBackspace,
            expected: .exitToBlock(.paragraph),
            note: "Backspace at home of top-level todo exits to body."
        ),
        FSMTransition(
            blockKind: .todoList,
            cursorPosition: .midContent,
            action: .pressBackspace,
            expected: .stayInBlock,
            note: "Backspace mid-todo-content deletes a character; checkbox preserved."
        ),

        // MARK: blockquote
        FSMTransition(
            blockKind: .blockquote,
            cursorPosition: .atEnd,
            action: .pressReturn,
            expected: .stayInBlock,
            note: "Return at end of blockquote line adds a new line WITHIN the same blockquote block via splitBlockquoteOnNewline."
        ),
        FSMTransition(
            blockKind: .blockquote,
            cursorPosition: .midContent,
            action: .pressReturn,
            expected: .stayInBlock,
            note: "Return mid-blockquote-line splits into two lines inside the same block."
        ),
        FSMTransition(
            blockKind: .blockquote,
            cursorPosition: .midContent,
            action: .pressBackspace,
            expected: .stayInBlock,
            note: "Backspace mid-blockquote-line deletes a character; block kind and count preserved."
        ),
        FSMTransition(
            blockKind: .blockquote,
            cursorPosition: .atStart,
            action: .pressBackspace,
            expected: .mergeWithPrevious,
            note: "Backspace at start of a blockquote (with previous block) merges into previous block."
        ),
        FSMTransition(
            blockKind: .blockquote,
            cursorPosition: .midContent,
            action: .pressTab,
            expected: .stayInBlock,
            note: "Tab inside blockquote inserts indent characters; not a list FSM transition."
        ),
        FSMTransition(
            blockKind: .blockquote,
            cursorPosition: .midContent,
            action: .pressForwardDelete,
            expected: .stayInBlock,
            note: "Forward-delete mid-blockquote-line deletes a character."
        ),

        // MARK: codeBlock
        FSMTransition(
            blockKind: .codeBlock,
            cursorPosition: .midContent,
            action: .pressReturn,
            expected: .stayInBlock,
            note: "Return mid-code inserts a literal newline INSIDE the code block; one block, content gains a \\n."
        ),
        FSMTransition(
            blockKind: .codeBlock,
            cursorPosition: .atEnd,
            action: .pressReturn,
            expected: .stayInBlock,
            note: "Return at end of code (content not yet ending in \\n) inserts a newline inside the block."
        ),
        FSMTransition(
            blockKind: .codeBlock,
            cursorPosition: .midContent,
            action: .pressBackspace,
            expected: .stayInBlock,
            note: "Backspace mid-code removes one character from content."
        ),
        FSMTransition(
            blockKind: .codeBlock,
            cursorPosition: .midContent,
            action: .pressTab,
            expected: .stayInBlock,
            note: "Tab in code block inserts indent characters; block kind and count preserved."
        ),
        FSMTransition(
            blockKind: .codeBlock,
            cursorPosition: .midContent,
            action: .pressForwardDelete,
            expected: .stayInBlock,
            note: "Forward-delete in code block removes one character."
        ),

        // MARK: table (atomic — its inline content is a 2D grid, not a
        // simple inline tree). The harness's pressReturn / pressBackspace
        // / pressForwardDelete at the storage offset mapping to the table
        // header / body cells route through cell-aware paths in the
        // production code (`handleTableNavCommand`) when the cell is the
        // first responder. The table-level rows below cover only the
        // block-boundary cases the FSM owns.
        FSMTransition(
            blockKind: .table,
            cursorPosition: .atStart,
            action: .pressReturn,
            expected: .stayInBlock,
            note: "Return inside the table's first cell is consumed by handleTableCellEdit; the table block is unchanged. The pure-function `insertAroundAtomicBlock` would create a paragraph sibling, but the live path routes through the cell intercept first."
        ),
        FSMTransition(
            blockKind: .table,
            cursorPosition: .atEnd,
            action: .pressReturn,
            expected: .stayInBlock,
            note: "Return at end of last table cell is consumed by the cell handler; structure unchanged at this slice (Phase 2e T2-d behaviour)."
        ),
        FSMTransition(
            blockKind: .table,
            cursorPosition: .atStart,
            action: .pressBackspace,
            expected: .stayInBlock,
            note: "Backspace inside the first cell of the table deletes a character within the cell; table block kind and count are unchanged."
        ),
        FSMTransition(
            blockKind: .table,
            cursorPosition: .atEnd,
            action: .selectBlockAndDelete,
            expected: .exitToBlock(.paragraph),
            note: "Selecting the entire table and pressing Delete replaces it with an empty paragraph (atomic-block full-select detection)."
        ),

        // MARK: horizontalRule (atomic — no editable inline content)
        FSMTransition(
            blockKind: .horizontalRule,
            cursorPosition: .atStart,
            action: .pressReturn,
            expected: .insertAtomic(.paragraph),
            note: "Return at start of HR inserts a paragraph before."
        ),
        FSMTransition(
            blockKind: .horizontalRule,
            cursorPosition: .atEnd,
            action: .pressReturn,
            expected: .insertAtomic(.paragraph),
            note: "Return at end of HR inserts a paragraph after."
        ),
        FSMTransition(
            blockKind: .horizontalRule,
            cursorPosition: .atEnd,
            action: .selectBlockAndDelete,
            expected: .exitToBlock(.paragraph),
            note: "Selecting the entire HR and pressing Delete replaces it with an empty paragraph."
        ),
        FSMTransition(
            blockKind: .horizontalRule,
            cursorPosition: .atStart,
            action: .pressBackspace,
            expected: .mergeWithPrevious,
            note: "Backspace at start of HR (with previous block) merges via cross-block delete; HR is consumed."
        ),
        FSMTransition(
            blockKind: .horizontalRule,
            cursorPosition: .midContent,
            action: .pressBackspace,
            expected: .unsupported,
            note: "HRs have no mid-content position; this row exists as documentation."
        ),

        // MARK: blankLine
        FSMTransition(
            blockKind: .blankLine,
            cursorPosition: .onEmptyBlock,
            action: .pressReturn,
            expected: .splitBlock(into: .blankLine, firstBecomes: .blankLine),
            note: "Return on a blank line creates another blank line (insert path produces [.blankLine, .blankLine])."
        ),
        FSMTransition(
            blockKind: .blankLine,
            cursorPosition: .onEmptyBlock,
            action: .pressBackspace,
            expected: .mergeWithPrevious,
            note: "Backspace on a blank line (with previous block) merges via cross-block delete."
        ),

        // MARK: extra heading-level coverage (FSM behaves identically
        // for level 1..6 — sample H4..H6 to lock the level-loop in
        // case anyone special-cases a level)
        FSMTransition(
            blockKind: .heading(level: 4),
            cursorPosition: .atEnd,
            action: .pressReturn,
            expected: .splitBlock(into: .paragraph),
            note: "Return at end of H4 creates a paragraph below."
        ),
        FSMTransition(
            blockKind: .heading(level: 5),
            cursorPosition: .atEnd,
            action: .pressReturn,
            expected: .splitBlock(into: .paragraph),
            note: "Return at end of H5 creates a paragraph below."
        ),
        FSMTransition(
            blockKind: .heading(level: 6),
            cursorPosition: .atEnd,
            action: .pressReturn,
            expected: .splitBlock(into: .paragraph),
            note: "Return at end of H6 creates a paragraph below."
        ),
        FSMTransition(
            blockKind: .heading(level: 2),
            cursorPosition: .midContent,
            action: .pressReturn,
            expected: .splitBlock(into: .paragraph),
            note: "Return mid-H2 splits: H2 keeps the prefix, paragraph holds the suffix."
        ),
        FSMTransition(
            blockKind: .heading(level: 3),
            cursorPosition: .atStart,
            action: .pressReturn,
            expected: .splitBlock(into: .heading(level: 3), firstBecomes: .paragraph),
            note: "Return at start of H3: empty paragraph appears BEFORE; heading is preserved (Slice B #6 generalized)."
        ),
        FSMTransition(
            blockKind: .heading(level: 2),
            cursorPosition: .atStart,
            action: .pressBackspace,
            expected: .exitToBlock(.paragraph),
            note: "Backspace at home of H2 converts to paragraph."
        ),
        FSMTransition(
            blockKind: .heading(level: 6),
            cursorPosition: .atStart,
            action: .pressBackspace,
            expected: .exitToBlock(.paragraph),
            note: "Backspace at home of H6 converts to paragraph."
        ),
        FSMTransition(
            blockKind: .heading(level: 1),
            cursorPosition: .atEnd,
            action: .pressForwardDelete,
            expected: .mergeWithPrevious,
            note: "Forward-delete at end of heading merges the next block into this one."
        ),
        FSMTransition(
            blockKind: .heading(level: 2),
            cursorPosition: .atEnd,
            action: .pressForwardDelete,
            expected: .mergeWithPrevious,
            note: "Forward-delete at end of H2 merges the next block."
        ),

        // MARK: paragraph (extra: forward-delete and selection coverage)
        FSMTransition(
            blockKind: .paragraph,
            cursorPosition: .atStart,
            action: .pressForwardDelete,
            expected: .stayInBlock,
            note: "Forward-delete at start of paragraph removes the first character; structure unchanged."
        ),
        FSMTransition(
            blockKind: .paragraph,
            cursorPosition: .midContent,
            action: .pressShiftTab,
            expected: .stayInBlock,
            note: "Shift-Tab inside a non-list paragraph has no list FSM action — falls through, structure preserved."
        ),

        // MARK: list (extra: depth-1 nested item rows — needs a
        // multi-item seed where the second item has a previous sibling)
        FSMTransition(
            blockKind: .bulletList,
            cursorPosition: .midContent,
            action: .pressBackspace,
            expected: .stayInBlock,
            note: "Backspace mid-content of bullet item (single-item list) deletes a character; list structure unchanged."
        ),
        FSMTransition(
            blockKind: .bulletList,
            cursorPosition: .atEnd,
            action: .pressBackspace,
            expected: .stayInBlock,
            note: "Backspace at end of bullet item removes the last character; list structure unchanged."
        ),
        FSMTransition(
            blockKind: .bulletList,
            cursorPosition: .midContent,
            action: .pressForwardDelete,
            expected: .stayInBlock,
            note: "Forward-delete mid-content of bullet item removes a character."
        ),
        FSMTransition(
            blockKind: .bulletList,
            cursorPosition: .midContent,
            action: .pressTab,
            expected: .stayInBlock,
            note: "Tab mid-content of a single-item bullet list with no previous sibling: FSM noOp returns true (consumed), block unchanged."
        ),
        FSMTransition(
            blockKind: .numberedList,
            cursorPosition: .midContent,
            action: .pressForwardDelete,
            expected: .stayInBlock,
            note: "Forward-delete mid-content of numbered item removes a character."
        ),
        FSMTransition(
            blockKind: .todoList,
            cursorPosition: .midContent,
            action: .pressForwardDelete,
            expected: .stayInBlock,
            note: "Forward-delete mid-content of todo item removes a character."
        ),
        FSMTransition(
            blockKind: .todoList,
            cursorPosition: .atEnd,
            action: .pressBackspace,
            expected: .stayInBlock,
            note: "Backspace at end of todo item removes the last char of inline content; checkbox preserved."
        ),
        FSMTransition(
            blockKind: .todoList,
            cursorPosition: .midContent,
            action: .pressTab,
            expected: .stayInBlock,
            note: "Tab on a single-item todo list with no previous sibling: FSM noOp consumed, structure unchanged."
        ),

        // MARK: blockquote (extra: end-of-content backspace, forward-
        // delete, selection-delete)
        FSMTransition(
            blockKind: .blockquote,
            cursorPosition: .atEnd,
            action: .pressBackspace,
            expected: .stayInBlock,
            note: "Backspace at end of blockquote line deletes the last character; block kind preserved."
        ),
        FSMTransition(
            blockKind: .blockquote,
            cursorPosition: .atEnd,
            action: .pressForwardDelete,
            expected: .mergeWithPrevious,
            note: "Forward-delete at end of blockquote merges the next block in (cross-block delete; count goes from N to N-1)."
        ),

        // MARK: codeBlock (extra: forward-delete, shift-tab)
        FSMTransition(
            blockKind: .codeBlock,
            cursorPosition: .midContent,
            action: .pressShiftTab,
            expected: .stayInBlock,
            note: "Shift-Tab in code block: no list FSM action, falls through; structure preserved."
        ),
        FSMTransition(
            blockKind: .codeBlock,
            cursorPosition: .atStart,
            action: .pressForwardDelete,
            expected: .stayInBlock,
            note: "Forward-delete at start of code block deletes the first character of content."
        ),

        // MARK: table (extra: pressTab inside the table's first cell
        // routes to handleTableNavCommand — the table FSM handles it,
        // not the list FSM. Slice B #30 wraps this as a bug-row.)
        FSMTransition(
            blockKind: .table,
            cursorPosition: .atStart,
            action: .pressTab,
            expected: .stayInBlock,
            note: "Tab inside a table cell: structurally the table block is unchanged whether the cell receives a literal \\t (Slice B #30 bug) or focus moves to the next cell (correct behaviour). Distinguishing the two requires a selection-state assertion, which the FSM table doesn't encode."
        ),

        // MARK: horizontal rule (extra: forward-delete merge case)
        FSMTransition(
            blockKind: .horizontalRule,
            cursorPosition: .atEnd,
            action: .pressForwardDelete,
            expected: .mergeWithPrevious,
            note: "Forward-delete at end of HR merges the next block (cross-block delete consumes the HR's trailing newline boundary)."
        ),

        // MARK: blankLine (extra: forward-delete consumes the next block's leading boundary)
        FSMTransition(
            blockKind: .blankLine,
            cursorPosition: .onEmptyBlock,
            action: .pressForwardDelete,
            expected: .mergeWithPrevious,
            note: "Forward-delete on a blank line merges with the next block."
        ),

        // MARK: paragraph (extra: empty-paragraph variants)
        FSMTransition(
            blockKind: .paragraph,
            cursorPosition: .onEmptyBlock,
            action: .pressBackspace,
            expected: .mergeWithPrevious,
            note: "Backspace on an empty paragraph (with previous block) merges into the previous block."
        ),
    ]

    /// Convenience filter for bug rows.
    static var bugRows: [FSMTransition] {
        all.filter { $0.bugId != nil }
    }

    /// Convenience filter for rows that encode currently-correct
    /// behaviour (the suite expects these to pass green today).
    static var passingRows: [FSMTransition] {
        all.filter { $0.bugId == nil }
    }
}
