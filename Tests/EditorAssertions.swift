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
//    7. fragment.atBlock(_).is(_)
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

    static func countAttachments(
        containing classNameNeedle: String,
        in editor: EditTextView
    ) -> Int {
        guard let storage = editor.textStorage else { return 0 }
        var n = 0
        storage.enumerateAttribute(
            .attachment,
            in: NSRange(location: 0, length: storage.length),
            options: []
        ) { value, _, _ in
            guard let attachment = value as? NSTextAttachment else { return }
            let name = String(describing: type(of: attachment))
            if name.contains(classNameNeedle) { n += 1 }
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

    /// Assert that the active first responder is the table cell at
    /// `(row, col)`.
    @discardableResult
    func isInCell(
        row: Int, col: Int,
        file: StaticString = #filePath, line: UInt = #line
    ) -> EditorAssertions {
        guard let cell = editor.window?.firstResponder as? TableCellTextView else {
            XCTFail(
                "Then.cursor.isInCell: first responder is not a TableCellTextView.",
                file: file, line: line
            )
            return parent
        }
        XCTAssertEqual(
            cell.cellRow, row,
            "Then.cursor.isInCell: expected row=\(row), got \(cell.cellRow).",
            file: file, line: line
        )
        XCTAssertEqual(
            cell.cellCol, col,
            "Then.cursor.isInCell: expected col=\(col), got \(cell.cellCol).",
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
        if let cell = editor.window?.firstResponder as? TableCellTextView {
            return cell.convert(cell.bounds, to: editor)
        }
        let sel = editor.selectedRange()
        guard let projection = editor.documentProjection,
              let (blockIdx, _) = projection.blockContaining(storageIndex: sel.location)
        else { return nil }
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
        return GlyphCounter(parent: parent, attachmentClassName: "Bullet")
    }
    var checkboxCount: GlyphCounter {
        return GlyphCounter(parent: parent, attachmentClassName: "Checkbox")
    }
}

struct GlyphCounter {
    let parent: EditorAssertions
    let attachmentClassName: String

    /// Counts rendered list marker attachments in storage. Bullets and
    /// checkboxes are image-backed static attachments, not hosted TK2
    /// subviews, so storage is the load-bearing glyph source.
    @discardableResult
    func equals(
        _ expected: Int,
        file: StaticString = #filePath, line: UInt = #line
    ) -> EditorAssertions {
        let actual = AssertionHelpers.countAttachments(
            containing: attachmentClassName,
            in: parent.scenario.editor
        )
        XCTAssertEqual(
            actual, expected,
            "Then.glyphs.\(attachmentClassName).equals: expected \(expected), got \(actual).",
            file: file, line: line
        )
        return parent
    }
}

// MARK: - 7: Fragment dispatch

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
    /// in the document. Row 0 is the header, row r >= 1 is body row
    /// r - 1.
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

// MARK: - Slice F.7 readbacks
//
// Added to support the migration of `UIBugRegressionTests.swift` (~50
// snapshot-based probes) onto the Given/When/Then DSL. Every readback
// below replaces a recurrent `h.snapshot().raw.contains(...)` /
// `assertContains(...)` / `components(separatedBy:).count` shape that
// the probes used directly.
//

extension EditorAssertions {
    /// Fragment-class presence + count readbacks. Replaces
    /// `snap.assertContains("(fragment class=X")` and
    /// `body.components(separatedBy: "(fragment class=X").count - 1`.
    var fragments: FragmentClassAssertions {
        FragmentClassAssertions(parent: self)
    }

    /// Raw snapshot-text readbacks. Used for content presence checks
    /// (Unicode round-trip, link URL preservation, math source
    /// preservation) where structural readbacks would over-promise.
    var snapshot: SnapshotTextAssertions {
        SnapshotTextAssertions(parent: self)
    }

    /// Document-projection block-shape readbacks. Replaces the probe
    /// pattern of digging into `editor.documentProjection?.document.blocks`
    /// and counting by case.
    var document: DocumentAssertions {
        DocumentAssertions(parent: self)
    }
}

extension CursorAssertions {
    /// Assert the live selection has zero length (cursor is collapsed,
    /// not a range). Catches stale-selection bugs that pure-function
    /// tests can't see.
    @discardableResult
    func selectionIsCollapsed(
        file: StaticString = #filePath, line: UInt = #line
    ) -> EditorAssertions {
        let sel = editor.selectedRange()
        if sel.length != 0 {
            XCTFail(
                "Then.cursor.selectionIsCollapsed: expected length 0, " +
                "got \(sel.length) (sel=\(sel)).",
                file: file, line: line
            )
        }
        return parent
    }
}

// MARK: F.7 — Fragment-class assertions

struct FragmentClassAssertions {
    let parent: EditorAssertions
    fileprivate var editor: EditTextView { parent.scenario.editor }

    /// Assert at least one TK2 layout fragment of the named class
    /// exists in the document. Class name is matched with
    /// `String(describing: type(of: fragment))`.
    @discardableResult
    func contains(
        class className: String,
        file: StaticString = #filePath, line: UInt = #line
    ) -> EditorAssertions {
        if classCounts(named: className) == 0 {
            XCTFail(
                "Then.fragments.contains(class: \(className)): " +
                "no fragment of that class found.",
                file: file, line: line
            )
        }
        return parent
    }

    /// Assert NO fragment of the named class exists in the document.
    @discardableResult
    func doesNotContain(
        class className: String,
        file: StaticString = #filePath, line: UInt = #line
    ) -> EditorAssertions {
        let n = classCounts(named: className)
        if n != 0 {
            XCTFail(
                "Then.fragments.doesNotContain(class: \(className)): " +
                "expected 0, got \(n).",
                file: file, line: line
            )
        }
        return parent
    }

    /// Open a count assertion for the named class.
    func countOfClass(_ className: String) -> FragmentClassCountAssertion {
        FragmentClassCountAssertion(parent: parent, className: className)
    }

    fileprivate func classCounts(named className: String) -> Int {
        var n = 0
        AssertionHelpers.enumerateFragments(editor: editor) { fragment, _ in
            if String(describing: type(of: fragment)) == className {
                n += 1
            }
            return true
        }
        return n
    }
}

struct FragmentClassCountAssertion {
    let parent: EditorAssertions
    let className: String

    @discardableResult
    func equals(
        _ expected: Int,
        file: StaticString = #filePath, line: UInt = #line
    ) -> EditorAssertions {
        let actual = FragmentClassAssertions(parent: parent)
            .classCounts(named: className)
        XCTAssertEqual(
            actual, expected,
            "Then.fragments.countOfClass(\(className)).equals: " +
            "expected \(expected), got \(actual).",
            file: file, line: line
        )
        return parent
    }

    @discardableResult
    func isAtLeast(
        _ minimum: Int,
        file: StaticString = #filePath, line: UInt = #line
    ) -> EditorAssertions {
        let actual = FragmentClassAssertions(parent: parent)
            .classCounts(named: className)
        if actual < minimum {
            XCTFail(
                "Then.fragments.countOfClass(\(className)).isAtLeast: " +
                "expected ≥ \(minimum), got \(actual).",
                file: file, line: line
            )
        }
        return parent
    }
}

// MARK: F.7 — Snapshot-text assertions
//
// `EditorSnapshot` flattens the editor state into an S-expression. Most
// content checks have a structural counterpart on `Document`; these
// readbacks are the escape hatch for cases where the assertion is "the
// rendered storage retained this literal substring" — Unicode, URLs,
// math source. Reach for `Then.document` first.

struct SnapshotTextAssertions {
    let parent: EditorAssertions
    fileprivate var editor: EditTextView { parent.scenario.editor }

    @discardableResult
    func contains(
        _ needle: String,
        file: StaticString = #filePath, line: UInt = #line
    ) -> EditorAssertions {
        let raw = EditorSnapshot.emit(from: editor).raw
        if !raw.contains(needle) {
            XCTFail(
                "Then.snapshot.contains: expected to find " +
                "'\(needle)'; not present.\nsnapshot:\n\(raw.prefix(500))",
                file: file, line: line
            )
        }
        return parent
    }

    @discardableResult
    func doesNotContain(
        _ needle: String,
        file: StaticString = #filePath, line: UInt = #line
    ) -> EditorAssertions {
        let raw = EditorSnapshot.emit(from: editor).raw
        if raw.contains(needle) {
            XCTFail(
                "Then.snapshot.doesNotContain: '\(needle)' was " +
                "found.\nsnapshot:\n\(raw.prefix(500))",
                file: file, line: line
            )
        }
        return parent
    }
}

// MARK: F.7 — Document-projection block assertions

struct DocumentAssertions {
    let parent: EditorAssertions
    fileprivate var editor: EditTextView { parent.scenario.editor }

    /// Read the live storage string. Used by tests asserting that
    /// typed/pasted/edited content has reached `NSTextStorage`.
    var storageText: StorageTextAssertion {
        StorageTextAssertion(parent: parent)
    }

    /// Open a count-of-block-kind assertion.
    func blockCount(ofKind kind: BlockKindFixture) -> BlockKindCountAssertion {
        BlockKindCountAssertion(parent: parent, kind: kind)
    }

    /// Total block count.
    var totalBlocks: TotalBlockCountAssertion {
        TotalBlockCountAssertion(parent: parent)
    }
}

struct StorageTextAssertion {
    let parent: EditorAssertions
    fileprivate var editor: EditTextView { parent.scenario.editor }

    @discardableResult
    func contains(
        _ needle: String,
        file: StaticString = #filePath, line: UInt = #line
    ) -> EditorAssertions {
        let s = editor.textStorage?.string ?? ""
        if !s.contains(needle) {
            XCTFail(
                "Then.document.storageText.contains: expected " +
                "'\(needle)'; storage='\(s.prefix(200))'.",
                file: file, line: line
            )
        }
        return parent
    }

    @discardableResult
    func doesNotContain(
        _ needle: String,
        file: StaticString = #filePath, line: UInt = #line
    ) -> EditorAssertions {
        let s = editor.textStorage?.string ?? ""
        if s.contains(needle) {
            XCTFail(
                "Then.document.storageText.doesNotContain: " +
                "'\(needle)' present.\nstorage='\(s.prefix(200))'.",
                file: file, line: line
            )
        }
        return parent
    }
}

struct BlockKindCountAssertion {
    let parent: EditorAssertions
    let kind: BlockKindFixture
    fileprivate var editor: EditTextView { parent.scenario.editor }

    @discardableResult
    func equals(
        _ expected: Int,
        file: StaticString = #filePath, line: UInt = #line
    ) -> EditorAssertions {
        let actual = countMatching()
        XCTAssertEqual(
            actual, expected,
            "Then.document.blockCount(ofKind: \(kind)).equals: " +
            "expected \(expected), got \(actual).",
            file: file, line: line
        )
        return parent
    }

    @discardableResult
    func isAtLeast(
        _ minimum: Int,
        file: StaticString = #filePath, line: UInt = #line
    ) -> EditorAssertions {
        let actual = countMatching()
        if actual < minimum {
            XCTFail(
                "Then.document.blockCount(ofKind: \(kind)).isAtLeast: " +
                "expected ≥ \(minimum), got \(actual).",
                file: file, line: line
            )
        }
        return parent
    }

    private func countMatching() -> Int {
        guard let projection = editor.documentProjection else { return 0 }
        return projection.document.blocks.reduce(0) { acc, block in
            acc + (matches(block) ? 1 : 0)
        }
    }

    private func matches(_ block: Block) -> Bool {
        switch (kind, block) {
        case (.paragraph, .paragraph):           return true
        case (.blockquote, .blockquote):         return true
        case (.codeBlock, .codeBlock):           return true
        case (.table, .table):                   return true
        case (.horizontalRule, .horizontalRule): return true
        case (.blankLine, .blankLine):           return true
        case (.heading(let l), .heading(let bl, _)) where l == bl:
            return true
        case (.heading, .heading):
            return false
        case (.bulletList, .list(let items, _)):
            guard let first = items.first else { return false }
            return first.checkbox == nil &&
                !first.marker.contains(where: { $0.isNumber })
        case (.numberedList, .list(let items, _)):
            guard let first = items.first else { return false }
            return first.marker.contains(where: { $0.isNumber })
        case (.todoList, .list(let items, _)):
            guard let first = items.first else { return false }
            return first.checkbox != nil
        default:
            return false
        }
    }
}

struct TotalBlockCountAssertion {
    let parent: EditorAssertions
    fileprivate var editor: EditTextView { parent.scenario.editor }

    @discardableResult
    func equals(
        _ expected: Int,
        file: StaticString = #filePath, line: UInt = #line
    ) -> EditorAssertions {
        let actual = editor.documentProjection?.document.blocks.count ?? 0
        XCTAssertEqual(
            actual, expected,
            "Then.document.totalBlocks.equals: expected \(expected), " +
            "got \(actual).",
            file: file, line: line
        )
        return parent
    }

    @discardableResult
    func isAtLeast(
        _ minimum: Int,
        file: StaticString = #filePath, line: UInt = #line
    ) -> EditorAssertions {
        let actual = editor.documentProjection?.document.blocks.count ?? 0
        if actual < minimum {
            XCTFail(
                "Then.document.totalBlocks.isAtLeast: expected ≥ " +
                "\(minimum), got \(actual).",
                file: file, line: line
            )
        }
        return parent
    }
}
