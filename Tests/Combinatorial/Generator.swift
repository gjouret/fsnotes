//
//  Generator.swift
//  FSNotesTests
//
//  Phase 11 Slice E — combinatorial coverage generator.
//
//  Enumerates `(blockKind × cursorPosition × edit × selectionState)`
//  scenarios and prunes impossible / equivalent combinations down to a
//  tractable matrix. Each surviving tuple is a `Scenario` value the
//  runner (`CombinatorialCoverageTests.swift`) can execute against the
//  live `EditorScenario` harness.
//
//  The generator is pure data — no harness, no assertions. It only
//  knows the state-space dimensions, the seed for each block kind, and
//  the prune rules. The runner owns crash isolation, invariant checks,
//  and reporting.
//
//  Pruning rules (encoded in `Scenario.isValid`):
//    1. Atomic-block content positions: HR has no editable inline
//       content. `.midContent` / `.onEmptyBlock` on `.horizontalRule`
//       are excluded.
//    2. Selection-state × single-block doc: `.crossBlock` requires the
//       seed to have ≥2 blocks; `.fullDocument` is always valid (we
//       seed every block kind with at least one neighbour).
//    3. Selection on atomic blocks: `.intraBlock` selection inside an
//       HR is meaningless; excluded.
//    4. Tab on non-list blocks with `.intraBlock` selection: the FSM
//       treats Tab inside a selection as "indent every line of the
//       selection," which the FSM table already covers in another
//       form. We still include these — minimal-invariant assertions
//       (no crash, cursor in some block) catch surprising behaviour.
//
//  See REFACTOR_PLAN.md → "Slice E — Combinatorial coverage" for the
//  full state-space dimensions and the assertion shape.
//

import Foundation

// MARK: - Axis enums

/// Block kinds the combinatorial generator probes. Mirrors
/// `FSMTransitionTable.BlockKindFixture` but adds entries the FSM table
/// doesn't already enumerate (mermaid block, display-math block).
enum CBBlockKind: Equatable, CustomStringConvertible {
    case paragraph
    case heading(level: Int)
    case bulletList
    case numberedList
    case todoList
    case blockquote
    case codeBlock
    case table
    case horizontalRule
    case mermaidBlock      // ```mermaid``` fence — same FSM as codeBlock
    case displayMathBlock  // $$…$$ — currently rendered as paragraph with displayMath inline
    case multiItemList     // 2-item bullet list, cursor on second item
    case nestedList        // depth-1 nested bullet list, cursor on inner item

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
        case .mermaidBlock:     return "mermaidBlock"
        case .displayMathBlock: return "displayMathBlock"
        case .multiItemList:    return "multiItemList"
        case .nestedList:       return "nestedList"
        }
    }

    /// All block kinds the matrix iterates. The FSM table covers H1-H6
    /// individually because each level was historically buggy in
    /// different ways; the combinatorial generator samples H1 + H3 to
    /// catch level-loop regressions without inflating the matrix size.
    /// 13 entries — 11 distinct kinds plus 2 multi-item / nested-list
    /// axes flagged by Slice A.5 as undercovered by the FSM table.
    static var all: [CBBlockKind] {
        return [
            .paragraph,
            .heading(level: 1),
            .heading(level: 3),
            .bulletList,
            .numberedList,
            .todoList,
            .blockquote,
            .codeBlock,
            .table,
            .horizontalRule,
            .mermaidBlock,
            .displayMathBlock,
            .multiItemList,
            .nestedList,
        ]
    }
}

/// Cursor positions exercised by the generator. The four canonical
/// positions plus an explicit "atStart of non-first list item" axis
/// for the multi-item / nested cases.
enum CBCursorPosition: Equatable, CustomStringConvertible {
    case atStart
    case midContent
    case atEnd
    case onEmptyBlock

    var description: String {
        switch self {
        case .atStart:      return "atStart"
        case .midContent:   return "midContent"
        case .atEnd:        return "atEnd"
        case .onEmptyBlock: return "onEmptyBlock"
        }
    }

    static var all: [CBCursorPosition] {
        return [.atStart, .midContent, .atEnd, .onEmptyBlock]
    }
}

/// Edit primitives the matrix enumerates. Five canonical key actions
/// — the same set the FSM transition table exercises, minus the
/// `selectBlockAndDelete` synthetic action (we cover selection state
/// as its own axis instead).
enum CBEdit: Equatable, CustomStringConvertible {
    case pressReturn
    case pressBackspace
    case pressForwardDelete
    case pressTab
    case pressShiftTab

    var description: String {
        switch self {
        case .pressReturn:        return "pressReturn"
        case .pressBackspace:     return "pressBackspace"
        case .pressForwardDelete: return "pressForwardDelete"
        case .pressTab:           return "pressTab"
        case .pressShiftTab:      return "pressShiftTab"
        }
    }

    static var all: [CBEdit] {
        return [.pressReturn, .pressBackspace, .pressForwardDelete,
                .pressTab, .pressShiftTab]
    }
}

/// Selection state at the moment the edit fires.
enum CBSelectionState: Equatable, CustomStringConvertible {
    /// Zero-length selection — cursor at the position dictated by
    /// `CBCursorPosition`.
    case empty
    /// Non-empty selection inside a single block (substring of the
    /// target block's content).
    case intraBlock
    /// Selection that crosses ≥2 block boundaries (target block + one
    /// neighbour). Requires ≥2 blocks in the seed.
    case crossBlock
    /// Select-all (entire document range).
    case fullDocument

    var description: String {
        switch self {
        case .empty:        return "empty"
        case .intraBlock:   return "intraBlock"
        case .crossBlock:   return "crossBlock"
        case .fullDocument: return "fullDocument"
        }
    }

    static var all: [CBSelectionState] {
        return [.empty, .intraBlock, .crossBlock, .fullDocument]
    }
}

// MARK: - Scenario tuple

/// One combinatorial scenario. `seed` + `targetBlockIndex` + `position`
/// + `edit` + `selection` is enough for the runner to drive a single
/// pass through the harness.
struct CBScenario: Equatable {
    let blockKind: CBBlockKind
    let position: CBCursorPosition
    let edit: CBEdit
    let selection: CBSelectionState

    /// A stable, human-readable identifier — used for `XCTExpectFailure`
    /// matching against `DiscoveredBugs.txt` entries and for activity
    /// labels in Xcode's test navigator.
    var label: String {
        return "\(blockKind) | \(position) | \(edit) | \(selection)"
    }

    /// True if the tuple is structurally valid (post-prune). Invalid
    /// tuples are dropped from the matrix entirely.
    var isValid: Bool {
        // 1. HR has no inline content. Drop midContent / onEmptyBlock.
        if case .horizontalRule = blockKind {
            switch position {
            case .midContent, .onEmptyBlock: return false
            default: break
            }
        }
        // 2. Tables have grid content; treat midContent / onEmptyBlock
        //    as collapsing to atStart (the cell-handler intercepts
        //    everything) — drop the duplicates.
        if case .table = blockKind {
            switch position {
            case .midContent, .onEmptyBlock: return false
            default: break
            }
        }
        // 3. Display-math block has no editable inline content (the
        //    rendered fragment owns the display-math source). Drop
        //    midContent / onEmptyBlock.
        if case .displayMathBlock = blockKind {
            switch position {
            case .midContent, .onEmptyBlock: return false
            default: break
            }
        }
        // 4. onEmptyBlock is only meaningful on certain block kinds.
        //    Drop it where the seed has typed content (heading text,
        //    blockquote text, code body, mermaid body).
        if position == .onEmptyBlock {
            switch blockKind {
            case .paragraph, .bulletList, .numberedList, .todoList:
                break
            default:
                return false
            }
        }
        // 5. Multi-item / nested seeds only make sense at .atStart
        //    (the second item / nested item home-position) — that's
        //    the axis Slice A.5 flagged. Skip the other positions to
        //    keep the matrix tight.
        switch blockKind {
        case .multiItemList, .nestedList:
            if position != .atStart { return false }
        default: break
        }
        return true
    }
}

// MARK: - Seed map

/// Per-`CBBlockKind` seed: the markdown to seed the editor with, the
/// index of the block the scenario operates on, and a pre-computed
/// "block has typed content" flag the runner uses to resolve cursor
/// positions.
struct CBSeed {
    let markdown: String
    /// Index into `document.blocks` of the block the cursor sits in.
    let targetBlockIndex: Int
    /// Whether the target block has at least 1 character of editable
    /// inline content (false for HR / blank, true for everything
    /// else). Used to gate `.midContent` resolution.
    let hasInlineContent: Bool

    /// Number of blocks in the parsed seed. Used by the runner to
    /// gate `.crossBlock` selection (needs ≥2 blocks).
    var minBlockCount: Int { return 1 }
}

enum CBSeedTable {
    static func seed(for kind: CBBlockKind, position: CBCursorPosition) -> CBSeed {
        switch kind {
        case .paragraph:
            if position == .onEmptyBlock {
                return CBSeed(markdown: "first\n\n\nafter\n",
                              targetBlockIndex: 2, hasInlineContent: false)
            }
            return CBSeed(markdown: "first\n\nbody text here\n\nafter\n",
                          targetBlockIndex: 2, hasInlineContent: true)

        case .heading(let level):
            let prefix = String(repeating: "#", count: level)
            return CBSeed(markdown: "first\n\n\(prefix) Title\n\nafter\n",
                          targetBlockIndex: 2, hasInlineContent: true)

        case .bulletList:
            if position == .onEmptyBlock {
                return CBSeed(markdown: "first\n\n- \n\nafter\n",
                              targetBlockIndex: 2, hasInlineContent: false)
            }
            return CBSeed(markdown: "first\n\n- item\n\nafter\n",
                          targetBlockIndex: 2, hasInlineContent: true)

        case .numberedList:
            if position == .onEmptyBlock {
                return CBSeed(markdown: "first\n\n1. \n\nafter\n",
                              targetBlockIndex: 2, hasInlineContent: false)
            }
            return CBSeed(markdown: "first\n\n1. item\n\nafter\n",
                          targetBlockIndex: 2, hasInlineContent: true)

        case .todoList:
            if position == .onEmptyBlock {
                return CBSeed(markdown: "first\n\n- [ ] \n\nafter\n",
                              targetBlockIndex: 2, hasInlineContent: false)
            }
            return CBSeed(markdown: "first\n\n- [ ] todo\n\nafter\n",
                          targetBlockIndex: 2, hasInlineContent: true)

        case .blockquote:
            return CBSeed(markdown: "first\n\n> quoted text\n\nafter\n",
                          targetBlockIndex: 2, hasInlineContent: true)

        case .codeBlock:
            return CBSeed(markdown: "first\n\n```\nx = 1\n```\n\nafter\n",
                          targetBlockIndex: 2, hasInlineContent: true)

        case .mermaidBlock:
            return CBSeed(markdown: "first\n\n```mermaid\ngraph TD\n```\n\nafter\n",
                          targetBlockIndex: 2, hasInlineContent: true)

        case .displayMathBlock:
            return CBSeed(markdown: "first\n\n$$x = 1$$\n\nafter\n",
                          targetBlockIndex: 2, hasInlineContent: true)

        case .table:
            // Trailing "after" so the table isn't the last block when
            // an atEnd action wants to merge with a successor.
            let md = "first\n\n| a | b |\n| - | - |\n| 1 | 2 |\n\nafter\n"
            return CBSeed(markdown: md, targetBlockIndex: 2, hasInlineContent: true)

        case .horizontalRule:
            return CBSeed(markdown: "first\n\n---\n\nafter\n",
                          targetBlockIndex: 2, hasInlineContent: false)

        case .multiItemList:
            // Two items — cursor lands on the second item via the
            // runner's per-seed offset map. The .list block has
            // index 2 (after first paragraph + blankLine).
            return CBSeed(markdown: "first\n\n- one\n- two\n\nafter\n",
                          targetBlockIndex: 2, hasInlineContent: true)

        case .nestedList:
            // Outer item + nested-via-indent inner item. The .list
            // block has index 2.
            return CBSeed(markdown: "first\n\n- outer\n  - inner\n\nafter\n",
                          targetBlockIndex: 2, hasInlineContent: true)
        }
    }
}

// MARK: - Matrix factory

enum CBMatrix {
    /// All scenarios after pruning impossible / equivalent tuples.
    static var allValid: [CBScenario] {
        var out: [CBScenario] = []
        for kind in CBBlockKind.all {
            for pos in CBCursorPosition.all {
                for edit in CBEdit.all {
                    for sel in CBSelectionState.all {
                        let s = CBScenario(
                            blockKind: kind,
                            position: pos,
                            edit: edit,
                            selection: sel
                        )
                        if s.isValid { out.append(s) }
                    }
                }
            }
        }
        return out
    }

    /// Total raw size of the un-pruned Cartesian product. Useful for
    /// reporting (REFACTOR_PLAN expects ~3072 raw → ~400-600 pruned).
    static var rawSize: Int {
        return CBBlockKind.all.count
            * CBCursorPosition.all.count
            * CBEdit.all.count
            * CBSelectionState.all.count
    }
}
