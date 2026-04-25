//
//  EditorAssertions.swift
//  FSNotesTests
//
//  Phase 11 Slice A — `Then.*` readback namespace.
//
//  Eight essential UI-outcome readbacks. Each readback reads a named
//  user-perceptible artifact (cursor location, fragment class, glyph
//  count, handle alignment, toolbar button state, table-cell content)
//  and returns the parent `EditorAssertions` so chains compose:
//
//      .Then.cursor.isInCell(row: 0, col: 0)
//          .Then.tableContent.cell(0, 0).equals("X")
//
//  Readback inventory (Slice A):
//    1. cursor.isAt(storageOffset:)
//    2. cursor.isInCell(row:col:)
//    3. cursor.visualRect(_:)         (predicate-based)
//    4. toolbar.button(_).isHighlighted / .isOff
//    5. glyphs.bulletCount.equals(_)
//    6. glyphs.checkboxCount.equals(_)
//    7. tableHandle.column(_).alignsWithBoundary
//    8. fragment.atBlock(_).is(_)
//
//  Plus one demo helper used by the demonstration test:
//    - tableContent.cell(_, _).equals(_)
//

import XCTest
import AppKit
@testable import FSNotes

// MARK: - Top-level Then namespace

/// Returned by `EditorScenario.Then`. Holds a back-reference to the
/// scenario so leaf readbacks can read live state. Every leaf method
/// returns `self` so chains can re-enter `.Then.…`.
struct EditorAssertions {
    let scenario: EditorScenario

    /// Re-entry point so readbacks can chain `.Then.x.y(...).Then.a.b(...)`.
    var Then: EditorAssertions { return self }

    // MARK: - Sub-namespaces

    var cursor: CursorAssertions { CursorAssertions(parent: self) }
    var toolbar: ToolbarAssertions { ToolbarAssertions(parent: self) }
    var glyphs: GlyphAssertions { GlyphAssertions(parent: self) }
    var tableHandle: TableHandleAssertions { TableHandleAssertions(parent: self) }
    var fragment: FragmentAssertions { FragmentAssertions(parent: self) }
    var tableContent: TableContentAssertions { TableContentAssertions(parent: self) }
    var block: BlockAssertions { BlockAssertions(parent: self) }
}

// MARK: - Shared TK2 walkers

/// Internal helpers that walk the TK2 layout tree for a specific
/// block. Centralised so each readback below is a thin asserting
/// wrapper, not yet another fragment-enumeration loop.
fileprivate enum AssertionHelpers {

    /// Iterate the layout fragments and pass each (fragment, charIndex)
    /// to `body`. `body` returns `false` to stop early.
    static func enumerateFragments(
        editor: EditTextView,
        body: (NSTextLayoutFragment, Int) -> Bool
    ) {
        guard let tlm = editor.textLayoutManager,
              let cs = tlm.textContentManager as? NSTextContentStorage
        else { return }
        tlm.ensureLayout(for: tlm.documentRange)
        let docStart = cs.documentRange.location
        tlm.enumerateTextLayoutFragments(
            from: tlm.documentRange.location,
            options: [.ensuresLayout]
        ) { fragment in
            guard let er = fragment.textElement?.elementRange else {
                return true
            }
            let charIndex = cs.offset(from: docStart, to: er.location)
            return body(fragment, charIndex)
        }
    }

    /// Locate the layout fragment whose element starts at the same
    /// storage offset as `block[blockIdx]`'s span. Returns the
    /// fragment's class name and the fragment itself.
    static func fragment(
        forBlockIndex blockIdx: Int, in editor: EditTextView
    ) -> NSTextLayoutFragment? {
        guard let projection = editor.documentProjection,
              blockIdx >= 0,
              blockIdx < projection.blockSpans.count
        else { return nil }
        let target = projection.blockSpans[blockIdx].location
        var found: NSTextLayoutFragment? = nil
        enumerateFragments(editor: editor) { fragment, charIndex in
            if charIndex == target {
                found = fragment
                return false
            }
            return true
        }
        return found
    }

    /// Locate the first table block + its fragment + element. Returns
    /// nil if there is no table in the document.
    static func firstTable(
        in editor: EditTextView
    ) -> (blockIdx: Int, span: NSRange, element: TableElement, fragment: TableLayoutFragment)? {
        guard let projection = editor.documentProjection else { return nil }
        var blockIdx: Int? = nil
        for (i, b) in projection.document.blocks.enumerated() {
            if case .table = b { blockIdx = i; break }
        }
        guard let bi = blockIdx,
              bi < projection.blockSpans.count,
              let frag = fragment(forBlockIndex: bi, in: editor)
                as? TableLayoutFragment,
              let el = frag.textElement as? TableElement
        else { return nil }
        return (bi, projection.blockSpans[bi], el, frag)
    }

    /// Recursive subview walk; counts subviews whose class name
    /// matches `name`. Same shape `EditorSnapshot` uses, kept private
    /// to this file so individual readbacks don't reimplement.
    static func countSubviews(named name: String, in root: NSView) -> Int {
        var n = 0
        forEachSubview(in: root) { v in
            if String(describing: type(of: v)) == name { n += 1 }
        }
        return n
    }

    /// Recursive subview walk; collects frames (in `editor` coords)
    /// for every subview whose class name matches `name`.
    static func collectFrames(
        named name: String, in editor: EditTextView
    ) -> [CGRect] {
        var out: [CGRect] = []
        forEachSubview(in: editor) { v in
            if String(describing: type(of: v)) == name {
                let f = v.superview?.convert(v.frame, to: editor) ?? v.frame
                out.append(f)
            }
        }
        return out
    }

    private static func forEachSubview(in root: NSView, _ visit: (NSView) -> Void) {
        var visited = Set<ObjectIdentifier>()
        var queue: [NSView] = root.subviews
        while let v = queue.first {
            queue.removeFirst()
            let key = ObjectIdentifier(v)
            if visited.contains(key) { continue }
            visited.insert(key)
            queue.append(contentsOf: v.subviews)
            visit(v)
        }
    }
}

// MARK: - 1+2+3: Cursor readbacks

struct CursorAssertions {
    let parent: EditorAssertions
    fileprivate var editor: EditTextView { parent.scenario.editor }

    /// Storage-offset readback. Catches selection-state regressions
    /// pure-function tests can't see (selection lives on the editor,
    /// not on `Document`).
    @discardableResult
    func isAt(
        storageOffset: Int,
        file: StaticString = #filePath, line: UInt = #line
    ) -> EditorAssertions {
        let actual = editor.selectedRange().location
        XCTAssertEqual(
            actual, storageOffset,
            "Then.cursor.isAt: expected \(storageOffset), got \(actual).",
            file: file, line: line
        )
        return parent
    }

    /// Resolve the current selection through the table block at
    /// `selectedRange.location` and assert the cursor lives inside
    /// cell `(row, col)`. Catches the Insert-Table → type cell-cursor
    /// mismatch (commit `c08d3ee`).
    @discardableResult
    func isInCell(
        row: Int, col: Int,
        file: StaticString = #filePath, line: UInt = #line
    ) -> EditorAssertions {
        let selLoc = editor.selectedRange().location
        guard let table = AssertionHelpers.firstTable(in: editor) else {
            XCTFail(
                "Then.cursor.isInCell: no table block in document.",
                file: file, line: line
            )
            return parent
        }
        guard NSLocationInRange(selLoc, table.span)
              || selLoc == table.span.location + table.span.length
        else {
            XCTFail(
                "Then.cursor.isInCell: selection \(selLoc) is outside " +
                "the table block span \(table.span.location)..\(table.span.location + table.span.length).",
                file: file, line: line
            )
            return parent
        }
        let elementLocal = selLoc - table.span.location
        // `cellLocation(forOffset:)` treats `offset == cellEnd` as
        // outside the cell; for cursor readbacks a position right
        // after the cell's last typed char belongs to that cell.
        let resolved = table.element.cellLocation(forOffset: elementLocal)
            ?? (elementLocal > 0
                ? table.element.cellLocation(forOffset: elementLocal - 1)
                : nil)
        guard let (r, c) = resolved else {
            XCTFail(
                "Then.cursor.isInCell: selection \(selLoc) (element-local " +
                "\(elementLocal)) doesn't resolve to a cell.",
                file: file, line: line
            )
            return parent
        }
        XCTAssertEqual(
            (r, c).0, row,
            "Then.cursor.isInCell: expected row=\(row), got \(r) (col=\(c)).",
            file: file, line: line
        )
        XCTAssertEqual(
            (r, c).1, col,
            "Then.cursor.isInCell: expected col=\(col), got \(c) (row=\(r)).",
            file: file, line: line
        )
        return parent
    }

    /// Predicate-based visual-rect readback. The caller provides a
    /// closure on the rect; this resolves the selection's visual
    /// rect (table-cell rect for table blocks, fragment frame
    /// otherwise) and applies the predicate.
    @discardableResult
    func visualRect(
        _ predicate: (CGRect) -> Bool,
        message: String = "visual rect predicate failed",
        file: StaticString = #filePath, line: UInt = #line
    ) -> EditorAssertions {
        guard let rect = currentRect() else {
            XCTFail(
                "Then.cursor.visualRect: could not derive rect.",
                file: file, line: line
            )
            return parent
        }
        if !predicate(rect) {
            XCTFail(
                "Then.cursor.visualRect: \(message). rect=\(rect).",
                file: file, line: line
            )
        }
        return parent
    }

    private func currentRect() -> CGRect? {
        let sel = editor.selectedRange()
        guard let projection = editor.documentProjection,
              let (blockIdx, _) = projection.blockContaining(storageIndex: sel.location)
        else { return nil }
        // Table cells get their grid-computed rect.
        if case .table = projection.document.blocks[blockIdx],
           let table = AssertionHelpers.firstTable(in: editor),
           let geom = table.fragment.geometryForHandleOverlay() {
            let elementLocal = sel.location - table.span.location
            guard let (row, col) = table.element.cellLocation(forOffset: elementLocal)
                    ?? (elementLocal > 0
                        ? table.element.cellLocation(forOffset: elementLocal - 1)
                        : nil),
                  col < geom.columnWidths.count, row < geom.rowHeights.count
            else { return nil }
            var x = TableGeometry.handleBarWidth
            for c in 0..<col { x += geom.columnWidths[c] }
            var y = TableGeometry.handleBarHeight
            for r in 0..<row { y += geom.rowHeights[r] }
            let origin = table.fragment.layoutFragmentFrame.origin
            return CGRect(
                x: origin.x + x, y: origin.y + y,
                width: geom.columnWidths[col],
                height: geom.rowHeights[row]
            )
        }
        // Default: the fragment containing the selection.
        return AssertionHelpers.fragment(forBlockIndex: blockIdx, in: editor)?
            .layoutFragmentFrame
    }
}

// MARK: - 4: Toolbar readbacks

/// Toolbar button identifier — names the formatting verb backed by
/// an editor inline trait. Slice A covers the trait-backed buttons;
/// non-trait buttons (heading, list, blockquote) come in Slice B.
enum ToolbarButton {
    case bold
    case italic
    case strikethrough
    case code
    case underline
    case highlight

    fileprivate var trait: EditingOps.InlineTrait {
        switch self {
        case .bold:          return .bold
        case .italic:        return .italic
        case .strikethrough: return .strikethrough
        case .code:          return .code
        case .underline:     return .underline
        case .highlight:     return .highlight
        }
    }
}

struct ToolbarAssertions {
    let parent: EditorAssertions
    func button(_ which: ToolbarButton) -> ToolbarButtonAssertion {
        return ToolbarButtonAssertion(parent: parent, button: which)
    }
}

struct ToolbarButtonAssertion {
    let parent: EditorAssertions
    let button: ToolbarButton
    fileprivate var editor: EditTextView { parent.scenario.editor }

    /// Highlighted == the verb "would be on" if the user committed
    /// typing now. Reads `pendingInlineTraits` (empty-selection case)
    /// then attribute at the selection (non-empty case).
    @discardableResult
    func isHighlighted(
        file: StaticString = #filePath, line: UInt = #line
    ) -> EditorAssertions {
        if !state() {
            XCTFail(
                "Then.toolbar.button(\(button)).isHighlighted: " +
                "expected highlighted, got off. " +
                "pending=\(editor.pendingInlineTraits) sel=\(editor.selectedRange()).",
                file: file, line: line
            )
        }
        return parent
    }

    /// Inverse of `isHighlighted`. A button stuck "on" with no live
    /// trait is the CMD+B-stuck-on bug class (#26).
    @discardableResult
    func isOff(
        file: StaticString = #filePath, line: UInt = #line
    ) -> EditorAssertions {
        if state() {
            XCTFail(
                "Then.toolbar.button(\(button)).isOff: " +
                "expected off, got highlighted. " +
                "pending=\(editor.pendingInlineTraits) sel=\(editor.selectedRange()).",
                file: file, line: line
            )
        }
        return parent
    }

    private func state() -> Bool {
        if editor.pendingInlineTraits.contains(button.trait) { return true }
        let sel = editor.selectedRange()
        guard sel.length > 0,
              let storage = editor.textStorage,
              sel.location < storage.length
        else { return false }
        switch button {
        case .bold:
            let f = storage.attribute(.font, at: sel.location, effectiveRange: nil) as? NSFont
            return f?.fontDescriptor.symbolicTraits.contains(.bold) ?? false
        case .italic:
            let f = storage.attribute(.font, at: sel.location, effectiveRange: nil) as? NSFont
            return f?.fontDescriptor.symbolicTraits.contains(.italic) ?? false
        case .code:
            let f = storage.attribute(.font, at: sel.location, effectiveRange: nil) as? NSFont
            return f?.fontDescriptor.symbolicTraits.contains(.monoSpace) ?? false
        case .strikethrough:
            return ((storage.attribute(.strikethroughStyle, at: sel.location, effectiveRange: nil) as? Int) ?? 0) != 0
        case .underline:
            return ((storage.attribute(.underlineStyle, at: sel.location, effectiveRange: nil) as? Int) ?? 0) != 0
        case .highlight:
            return storage.attribute(.backgroundColor, at: sel.location, effectiveRange: nil) != nil
        }
    }
}

// MARK: - 5+6: Glyph counts

struct GlyphAssertions {
    let parent: EditorAssertions
    var bulletCount: GlyphCounter {
        return GlyphCounter(parent: parent, className: "BulletGlyphView")
    }
    var checkboxCount: GlyphCounter {
        return GlyphCounter(parent: parent, className: "CheckboxGlyphView")
    }
}

struct GlyphCounter {
    let parent: EditorAssertions
    let className: String

    /// Recursive walk over the editor's subview tree; matches subviews
    /// whose class name equals `className`. Catches the bullet/
    /// checkbox-mount-on-fill bug class (view-provider hosts live ≥3
    /// levels deep, so a shallow walk silently misses them).
    @discardableResult
    func equals(
        _ expected: Int,
        file: StaticString = #filePath, line: UInt = #line
    ) -> EditorAssertions {
        let actual = AssertionHelpers.countSubviews(
            named: className, in: parent.scenario.editor
        )
        XCTAssertEqual(
            actual, expected,
            "Then.glyphs.\(className).equals: expected \(expected), got \(actual).",
            file: file, line: line
        )
        return parent
    }
}

// MARK: - 7: Table handle alignment

struct TableHandleAssertions {
    let parent: EditorAssertions
    func column(_ col: Int) -> TableHandleColumnAssertion {
        return TableHandleColumnAssertion(parent: parent, col: col)
    }
}

struct TableHandleColumnAssertion {
    let parent: EditorAssertions
    let col: Int
    fileprivate var editor: EditTextView { parent.scenario.editor }

    /// Assert the column-`col` handle chip's `frame.minX` (in editor
    /// coords) is within ±1pt of the geometry-computed column
    /// boundary. Catches the `fragFrame.origin.x` drift class.
    @discardableResult
    func alignsWithBoundary(
        file: StaticString = #filePath, line: UInt = #line
    ) -> EditorAssertions {
        guard let table = AssertionHelpers.firstTable(in: editor),
              let geom = table.fragment.geometryForHandleOverlay()
        else {
            XCTFail(
                "Then.tableHandle.column(\(col)).alignsWithBoundary: " +
                "no table block / no geometry.",
                file: file, line: line
            )
            return parent
        }
        guard col >= 0, col < geom.columnWidths.count else {
            XCTFail(
                "Then.tableHandle.column(\(col)).alignsWithBoundary: " +
                "col out of range (\(geom.columnWidths.count) cols).",
                file: file, line: line
            )
            return parent
        }
        var expectedX = table.fragment.layoutFragmentFrame.origin.x +
            TableGeometry.handleBarWidth
        for c in 0..<col { expectedX += geom.columnWidths[c] }

        let chips = AssertionHelpers.collectFrames(
            named: "TableHandleView", in: editor
        )
        if chips.isEmpty {
            XCTFail(
                "Then.tableHandle.column(\(col)).alignsWithBoundary: " +
                "no TableHandleView subviews mounted.",
                file: file, line: line
            )
            return parent
        }
        let chip = chips.min { abs($0.midX - expectedX) < abs($1.midX - expectedX) }!
        if abs(chip.minX - expectedX) > 1.0 {
            XCTFail(
                "Then.tableHandle.column(\(col)).alignsWithBoundary: " +
                "expected ≈\(expectedX), got chip.minX=\(chip.minX) (Δ=\(chip.minX - expectedX)).",
                file: file, line: line
            )
        }
        return parent
    }
}

// MARK: - 8: Fragment dispatch

struct FragmentAssertions {
    let parent: EditorAssertions
    func atBlock(_ idx: Int) -> FragmentAtBlockAssertion {
        return FragmentAtBlockAssertion(parent: parent, blockIdx: idx)
    }
}

struct FragmentAtBlockAssertion {
    let parent: EditorAssertions
    let blockIdx: Int

    /// Assert the layout-fragment class name for block `idx` matches
    /// `expected`. Catches block-kind → fragment-class dispatch
    /// regressions.
    @discardableResult
    func `is`(
        _ expected: String,
        file: StaticString = #filePath, line: UInt = #line
    ) -> EditorAssertions {
        guard let frag = AssertionHelpers.fragment(
            forBlockIndex: blockIdx, in: parent.scenario.editor
        ) else {
            XCTFail(
                "Then.fragment.atBlock(\(blockIdx)).is: no fragment found.",
                file: file, line: line
            )
            return parent
        }
        let actual = String(describing: type(of: frag))
        XCTAssertEqual(
            actual, expected,
            "Then.fragment.atBlock(\(blockIdx)).is: expected \(expected), got \(actual).",
            file: file, line: line
        )
        return parent
    }
}

// MARK: - Demo helper: tableContent

struct TableContentAssertions {
    let parent: EditorAssertions

    /// Locator for the cell at `(row, col)` of the first table block
    /// in the document. Row indexing matches `TableElement.cellLocation
    /// (forOffset:)`: row 0 is the header, row r ≥ 1 is body row r-1.
    /// This keeps `Then.cursor.isInCell(row: 0, col: 0)` and
    /// `Then.tableContent.cell(0, 0)` referring to the same cell.
    func cell(_ row: Int, _ col: Int) -> TableCellAssertion {
        return TableCellAssertion(parent: parent, row: row, col: col)
    }
}

struct TableCellAssertion {
    let parent: EditorAssertions
    let row: Int
    let col: Int

    /// Assert the cell's raw text (round-trip-safe markdown) equals
    /// `expected`. Reads from `Document.blocks[i].table` value, not
    /// from storage.
    @discardableResult
    func equals(
        _ expected: String,
        file: StaticString = #filePath, line: UInt = #line
    ) -> EditorAssertions {
        guard let projection = parent.scenario.editor.documentProjection else {
            XCTFail(
                "Then.tableContent.cell.equals: no projection.",
                file: file, line: line
            )
            return parent
        }
        var tableBlock: Block? = nil
        for b in projection.document.blocks {
            if case .table = b { tableBlock = b; break }
        }
        guard case .table(let header, _, let rows, _) = tableBlock else {
            XCTFail(
                "Then.tableContent.cell.equals: no table block in document.",
                file: file, line: line
            )
            return parent
        }
        let cell: TableCell?
        if row == 0 {
            cell = (col >= 0 && col < header.count) ? header[col] : nil
        } else if row >= 1, row - 1 < rows.count,
                  col >= 0, col < rows[row - 1].count {
            cell = rows[row - 1][col]
        } else {
            cell = nil
        }
        guard let c = cell else {
            XCTFail(
                "Then.tableContent.cell(\(row), \(col)).equals: " +
                "out of range (\(rows.count) body rows, \(header.count) cols).",
                file: file, line: line
            )
            return parent
        }
        let actual = c.rawText
        XCTAssertEqual(
            actual, expected,
            "Then.tableContent.cell(\(row), \(col)).equals: " +
            "expected '\(expected)', got '\(actual)'.",
            file: file, line: line
        )
        return parent
    }
}

// MARK: - Block kind readback

struct BlockAssertions {
    let parent: EditorAssertions

    /// Locate block `idx` in the live document projection and return a
    /// chained assertion handle. The handle's `.is(_:)` asserts the
    /// block's case discriminator. Reuses the `BlockKindFixture` enum
    /// already defined for the FSM transition table fixture
    /// (`Tests/Fixtures/FSMTransitions.swift`) so cross-block bug tests
    /// (e.g. Bug #18: triple-click paragraph + delete must NOT demote
    /// the list block below — assert `kind(at: 1).is(.bulletList)`)
    /// share the same vocabulary as the per-block FSM coverage.
    func kind(at idx: Int) -> BlockKindAssertion {
        return BlockKindAssertion(parent: parent, blockIdx: idx)
    }
}

struct BlockKindAssertion {
    let parent: EditorAssertions
    let blockIdx: Int

    @discardableResult
    func `is`(
        _ expected: BlockKindFixture,
        file: StaticString = #filePath, line: UInt = #line
    ) -> EditorAssertions {
        guard let projection = parent.scenario.editor.documentProjection else {
            XCTFail(
                "Then.block.kind(at: \(blockIdx)).is: no projection.",
                file: file, line: line
            )
            return parent
        }
        let blocks = projection.document.blocks
        guard blockIdx >= 0, blockIdx < blocks.count else {
            XCTFail(
                "Then.block.kind(at: \(blockIdx)).is: out of range " +
                "(\(blocks.count) blocks).",
                file: file, line: line
            )
            return parent
        }
        let actual = mapBlockToFixture(blocks[blockIdx])
        XCTAssertEqual(
            actual, expected,
            "Then.block.kind(at: \(blockIdx)).is: expected \(expected), " +
            "got \(actual).",
            file: file, line: line
        )
        return parent
    }

    /// Mirrors the FSM-fixture mapping in `FSMTransitionTableTests.blockMatches`:
    /// the `.list` Block case fans out to `.bulletList` / `.numberedList`
    /// / `.todoList` based on the first item's marker shape.
    private func mapBlockToFixture(_ block: Block) -> BlockKindFixture {
        switch block {
        case .paragraph:      return .paragraph
        case .heading(let l, _): return .heading(level: l)
        case .blockquote:     return .blockquote
        case .codeBlock:      return .codeBlock
        case .table:          return .table
        case .horizontalRule: return .horizontalRule
        case .blankLine:      return .blankLine
        case .htmlBlock:      return .paragraph  // FSM fixture has no htmlBlock
        case .list(let items, _):
            guard let first = items.first else { return .bulletList }
            if first.marker.contains(where: { $0.isNumber }) {
                return .numberedList
            }
            // Todo lists carry a `[ ]` / `[x]` checkbox on item content.
            if first.checkbox != nil { return .todoList }
            return .bulletList
        }
    }
}
