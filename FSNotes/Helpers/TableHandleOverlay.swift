//
//  TableHandleOverlay.swift
//  FSNotes
//
//  Phase 2e-T2-g — hover-handle controller for native-cell tables
//  (`TableLayoutFragment`).
//
//  Parallel to `CodeBlockEditToggleOverlay`: owns a pool of lightweight
//  `TableHandleView` subviews of the text view, one per visible
//  `TableLayoutFragment`. Each subview spans the fragment's
//  `layoutFragmentFrame` and intercepts mouse events so we can drive
//  hover state and right-click context menus WITHOUT entangling with
//  the default text-view hit-test.
//
//  Architecture (mirrors rule 2 in CLAUDE.md):
//    * The overlay reads state from the fragment and its backing
//      `TableElement` — it never mutates them from the mouse path.
//    * Structural edits (insert/delete row/column, set alignment) route
//      through the `EditingOps` primitives shipped in T2-g's
//      `EditingOperations.swift` additions. Those return a new
//      `EditResult`; the overlay re-applies it through the editor's
//      existing `applyEditResultWithUndo` hook so undo + splice math
//      stay consistent.
//    * Hover feedback is purely visual — `TableLayoutFragment.setHoverState(_:)`
//      updates an enum; the overlay marks the text view dirty so the
//      fragment repaints.
//
//  What this slice ships:
//    * Hover detection (row/column strip hit) and a visible handle pill.
//    * Right-click (or ctrl-click) context menu with insert/delete/align
//      actions.
//    * Hit-testing of the handle strips without swallowing the
//      text-view's pointer events elsewhere.
//
//  Deferred to a T2-g.4 follow-up (noted in the commit message, not
//  shipped in this slice):
//    * Column drag-resize live preview + persist. The `TableHandleView`
//      currently accepts mouse-down on the top strip as a "start drag"
//      signal; the actual drag loop + persistence ride on top of a
//      `columnWidths` field that isn't yet part of `Block.table`. The
//      overlay stubs the drag entry point and explicitly logs a
//      not-implemented message so the hook is wired but the motion is
//      held for review.
//

import AppKit

final class TableHandleOverlay {

    // MARK: - Exposed records

    /// One visible table's bookkeeping. The overlay assigns one
    /// `TableHandleView` from the pool per record each reposition pass.
    struct VisibleTable {
        let fragment: TableLayoutFragment
        let frame: CGRect  // fragment frame in text-view coords
        let elementStorageStart: Int
        /// Index of the `.table` block in the editor's current
        /// `DocumentProjection.document.blocks`, resolved at
        /// reposition time.
        let blockIndex: Int
    }

    // MARK: - State

    private weak var editor: EditTextView?
    private var pool: [TableHandleView] = []
    private var notificationObservers: [NSObjectProtocol] = []
    private var isApplyingEdit = false

    // MARK: - Init / deinit

    init(editor: EditTextView) {
        self.editor = editor
        installObservers()
    }

    deinit {
        for token in notificationObservers {
            NotificationCenter.default.removeObserver(token)
        }
        notificationObservers.removeAll()
    }

    // MARK: - Notification wiring

    private func installObservers() {
        let center = NotificationCenter.default

        let scrollToken = center.addObserver(
            forName: NSView.boundsDidChangeNotification,
            object: nil, queue: .main
        ) { [weak self] note in
            guard let self = self,
                  let editor = self.editor,
                  let clip = editor.enclosingScrollView?.contentView,
                  (note.object as? NSView) === clip
            else { return }
            self.reposition()
        }
        notificationObservers.append(scrollToken)

        let textToken = center.addObserver(
            forName: NSText.didChangeNotification,
            object: nil, queue: .main
        ) { [weak self] note in
            guard let self = self,
                  let editor = self.editor,
                  (note.object as? NSTextView) === editor
            else { return }
            self.reposition()
        }
        notificationObservers.append(textToken)

        if let clip = editor?.enclosingScrollView?.contentView {
            clip.postsBoundsChangedNotifications = true
        }
    }

    // MARK: - Reposition

    /// Main entry point. Walk visible `TableLayoutFragment`s and
    /// attach / move a `TableHandleView` per fragment.
    func reposition() {
        guard let editor = editor,
              editor.textLayoutManager != nil else {
            hideAll()
            return
        }

        if let clip = editor.enclosingScrollView?.contentView,
           !clip.postsBoundsChangedNotifications {
            clip.postsBoundsChangedNotifications = true
        }

        let visible = visibleTables()

        for (i, record) in visible.enumerated() {
            let view = viewAt(index: i, parent: editor)
            view.frame = record.frame
            view.fragment = record.fragment
            view.overlay = self
            view.elementStorageStart = record.elementStorageStart
            view.blockIndex = record.blockIndex
            view.isHidden = false
        }

        if pool.count > visible.count {
            for i in visible.count..<pool.count {
                pool[i].isHidden = true
                pool[i].fragment = nil
                pool[i].overlay = nil
            }
        }
    }

    private func viewAt(index: Int, parent: EditTextView) -> TableHandleView {
        if index < pool.count {
            let v = pool[index]
            if v.superview !== parent {
                parent.addSubview(v)
            }
            return v
        }
        let v = TableHandleView(frame: .zero)
        parent.addSubview(v)
        pool.append(v)
        return v
    }

    private func hideAll() {
        for v in pool {
            v.isHidden = true
            v.fragment = nil
            v.overlay = nil
        }
    }

    // MARK: - Fragment enumeration

    /// Enumerate `TableLayoutFragment`s in the current viewport.
    /// Exposed `internal` for tests.
    func visibleTables() -> [VisibleTable] {
        guard let editor = editor,
              let tlm = editor.textLayoutManager,
              let contentStorage =
                tlm.textContentManager as? NSTextContentStorage,
              let projection = editor.documentProjection
        else {
            return []
        }
        let docStart = contentStorage.documentRange.location
        let containerOrigin = editor.textContainerOrigin

        var out: [VisibleTable] = []
        tlm.enumerateTextLayoutFragments(
            from: tlm.documentRange.location,
            options: [.ensuresLayout]
        ) { fragment in
            guard let tf = fragment as? TableLayoutFragment else {
                return true
            }
            guard let element = tf.textElement as? TableElement,
                  let elementRange = element.elementRange
            else { return true }
            let charIndex = contentStorage.offset(
                from: docStart, to: elementRange.location
            )
            // Resolve the block index.
            var blockIdx = -1
            for (i, span) in projection.blockSpans.enumerated() {
                if NSLocationInRange(charIndex, span) ||
                    span.location == charIndex {
                    blockIdx = i
                    break
                }
            }
            if blockIdx < 0 {
                blockIdx = projection.blockSpans.firstIndex(where: {
                    $0.location == charIndex
                }) ?? -1
            }
            guard blockIdx >= 0,
                  blockIdx < projection.document.blocks.count,
                  case .table = projection.document.blocks[blockIdx]
            else { return true }

            let frame = tf.layoutFragmentFrame
            let tvFrame = CGRect(
                x: frame.origin.x + containerOrigin.x,
                y: frame.origin.y + containerOrigin.y,
                width: frame.width,
                height: frame.height
            )
            out.append(VisibleTable(
                fragment: tf,
                frame: tvFrame,
                elementStorageStart: charIndex,
                blockIndex: blockIdx
            ))
            return true
        }
        return out
    }

    // MARK: - Hover plumbing (called by TableHandleView)

    /// Update the fragment's hover state and redraw.
    func updateHover(on fragment: TableLayoutFragment,
                     to state: TableLayoutFragment.HoverState) {
        if fragment.setHoverState(state) {
            editor?.needsDisplay = true
        }
    }

    // MARK: - Context menu (T2-g.2)

    /// Build the column context menu. Called when the user right-clicks
    /// on a top-strip handle for column `col` of the table at
    /// `blockIndex`.
    func makeColumnMenu(blockIndex: Int, col: Int) -> NSMenu {
        let menu = NSMenu()

        let insertLeft = NSMenuItem(
            title: "Insert Column Left",
            action: #selector(TableHandleOverlayMenuBridge.insertColumnLeft(_:)),
            keyEquivalent: ""
        )
        insertLeft.representedObject = MenuPayload(
            overlay: self, blockIndex: blockIndex, primary: col
        )
        menu.addItem(insertLeft)

        let insertRight = NSMenuItem(
            title: "Insert Column Right",
            action: #selector(TableHandleOverlayMenuBridge.insertColumnRight(_:)),
            keyEquivalent: ""
        )
        insertRight.representedObject = MenuPayload(
            overlay: self, blockIndex: blockIndex, primary: col
        )
        menu.addItem(insertRight)

        if columnCount(blockIndex: blockIndex) > 1 {
            menu.addItem(.separator())
            let delete = NSMenuItem(
                title: "Delete Column",
                action: #selector(TableHandleOverlayMenuBridge.deleteColumn(_:)),
                keyEquivalent: ""
            )
            delete.representedObject = MenuPayload(
                overlay: self, blockIndex: blockIndex, primary: col
            )
            menu.addItem(delete)
        }

        menu.addItem(.separator())
        let current = currentAlignment(blockIndex: blockIndex, col: col)
        for (title, align) in [
            ("Align Left", TableAlignment.left),
            ("Align Center", TableAlignment.center),
            ("Align Right", TableAlignment.right)
        ] {
            let item = NSMenuItem(
                title: title,
                action: #selector(TableHandleOverlayMenuBridge.setAlign(_:)),
                keyEquivalent: ""
            )
            item.representedObject = AlignPayload(
                overlay: self,
                blockIndex: blockIndex,
                col: col,
                alignment: align
            )
            if current == align {
                item.state = .on
            }
            menu.addItem(item)
        }

        let bridge = TableHandleOverlayMenuBridge.shared
        for item in menu.items {
            item.target = bridge
        }
        return menu
    }

    /// Build the row context menu. `row == 0` is the header — delete
    /// is disabled.
    func makeRowMenu(blockIndex: Int, row: Int) -> NSMenu {
        let menu = NSMenu()
        let above = NSMenuItem(
            title: "Insert Row Above",
            action: #selector(TableHandleOverlayMenuBridge.insertRowAbove(_:)),
            keyEquivalent: ""
        )
        above.representedObject = MenuPayload(
            overlay: self, blockIndex: blockIndex, primary: row
        )
        menu.addItem(above)

        let below = NSMenuItem(
            title: "Insert Row Below",
            action: #selector(TableHandleOverlayMenuBridge.insertRowBelow(_:)),
            keyEquivalent: ""
        )
        below.representedObject = MenuPayload(
            overlay: self, blockIndex: blockIndex, primary: row
        )
        menu.addItem(below)

        if row > 0 && bodyRowCount(blockIndex: blockIndex) > 1 {
            menu.addItem(.separator())
            let delete = NSMenuItem(
                title: "Delete Row",
                action: #selector(TableHandleOverlayMenuBridge.deleteRow(_:)),
                keyEquivalent: ""
            )
            delete.representedObject = MenuPayload(
                overlay: self, blockIndex: blockIndex, primary: row
            )
            menu.addItem(delete)
        }

        let bridge = TableHandleOverlayMenuBridge.shared
        for item in menu.items {
            item.target = bridge
        }
        return menu
    }

    // MARK: - Structural edits (context-menu action implementations)

    func applyInsertColumnLeft(blockIndex: Int, col: Int) {
        applyEdit(blockIndex: blockIndex) { projection in
            try EditingOps.insertTableColumn(
                blockIndex: blockIndex,
                at: col,
                alignment: .none,
                in: projection
            )
        }
    }

    func applyInsertColumnRight(blockIndex: Int, col: Int) {
        applyEdit(blockIndex: blockIndex) { projection in
            try EditingOps.insertTableColumn(
                blockIndex: blockIndex,
                at: col + 1,
                alignment: .none,
                in: projection
            )
        }
    }

    func applyDeleteColumn(blockIndex: Int, col: Int) {
        applyEdit(blockIndex: blockIndex) { projection in
            try EditingOps.deleteTableColumn(
                blockIndex: blockIndex, at: col, in: projection
            )
        }
    }

    func applyInsertRowAbove(blockIndex: Int, row: Int) {
        // row == 0 is the header; "above" the header means "as the
        // first body row" — position 0.
        let position = max(0, row - 1)
        applyEdit(blockIndex: blockIndex) { projection in
            try EditingOps.insertTableRow(
                blockIndex: blockIndex,
                at: position,
                in: projection
            )
        }
    }

    func applyInsertRowBelow(blockIndex: Int, row: Int) {
        // row == 0 → insert at body index 0 (first body row).
        // row == N → insert at body index N (after body[N-1]).
        let position = row
        applyEdit(blockIndex: blockIndex) { projection in
            try EditingOps.insertTableRow(
                blockIndex: blockIndex,
                at: position,
                in: projection
            )
        }
    }

    func applyDeleteRow(blockIndex: Int, row: Int) {
        guard row > 0 else { return }  // header cannot be deleted
        let bodyIndex = row - 1
        applyEdit(blockIndex: blockIndex) { projection in
            try EditingOps.deleteTableRow(
                blockIndex: blockIndex,
                at: bodyIndex,
                in: projection
            )
        }
    }

    func applySetAlignment(blockIndex: Int, col: Int, alignment: TableAlignment) {
        applyEdit(blockIndex: blockIndex) { projection in
            try EditingOps.setTableColumnAlignment(
                blockIndex: blockIndex,
                col: col,
                alignment: alignment,
                in: projection
            )
        }
    }

    /// T2-g.4: persist the column widths produced by a live drag-resize.
    /// Routed through `EditingOps.setTableColumnWidths` so undo / splice
    /// math stay consistent with the other structural primitives.
    func applySetColumnWidths(blockIndex: Int, widths: [CGFloat]) {
        applyEdit(blockIndex: blockIndex, actionName: "Resize Table Column") { projection in
            try EditingOps.setTableColumnWidths(
                blockIndex: blockIndex,
                widths: widths,
                in: projection
            )
        }
    }

    // MARK: - Edit application

    /// Run a pure primitive on the editor's current projection and
    /// apply the resulting `EditResult` via the standard block-model
    /// path. Guarded against re-entry the same way
    /// `CodeBlockEditToggleOverlay.applyToggle` is.
    private func applyEdit(
        blockIndex: Int,
        _ op: (DocumentProjection) throws -> EditResult,
        actionName: String = "Table Edit"
    ) {
        guard !isApplyingEdit else { return }
        guard let editor = editor,
              let projection = editor.documentProjection else {
            return
        }
        isApplyingEdit = true
        defer { isApplyingEdit = false }

        do {
            let result = try op(projection)
            editor.applyEditResultWithUndo(result, actionName: actionName)
            reposition()
        } catch {
            // Pure primitives only throw on out-of-bounds / wrong
            // block type — the overlay's own state should never
            // produce those. Swallow silently (log via bmLog for
            // diagnosis).
            NSLog("[TableHandleOverlay] applyEdit failed: \(error)")
        }
    }

    // MARK: - Block inspection

    private func tableBlock(blockIndex: Int) ->
    (header: [TableCell], alignments: [TableAlignment], rows: [[TableCell]])? {
        guard let editor = editor,
              let projection = editor.documentProjection,
              blockIndex < projection.document.blocks.count,
              case .table(let h, let a, let r, _, _) =
                projection.document.blocks[blockIndex]
        else { return nil }
        return (h, a, r)
    }

    private func columnCount(blockIndex: Int) -> Int {
        return tableBlock(blockIndex: blockIndex)?.header.count ?? 0
    }

    private func bodyRowCount(blockIndex: Int) -> Int {
        return tableBlock(blockIndex: blockIndex)?.rows.count ?? 0
    }

    private func currentAlignment(blockIndex: Int, col: Int) -> TableAlignment {
        guard let t = tableBlock(blockIndex: blockIndex),
              col < t.alignments.count
        else { return .none }
        return t.alignments[col]
    }
}

// MARK: - Menu payloads

/// Bundle passed to menu action selectors via `representedObject`.
/// The selectors are @objc so they can't take Swift enums directly;
/// the payload is a plain class with typed fields.
private final class MenuPayload: NSObject {
    weak var overlay: TableHandleOverlay?
    let blockIndex: Int
    /// Column index for column menus; row index for row menus.
    let primary: Int

    init(overlay: TableHandleOverlay, blockIndex: Int, primary: Int) {
        self.overlay = overlay
        self.blockIndex = blockIndex
        self.primary = primary
    }
}

private final class AlignPayload: NSObject {
    weak var overlay: TableHandleOverlay?
    let blockIndex: Int
    let col: Int
    let alignment: TableAlignment

    init(
        overlay: TableHandleOverlay,
        blockIndex: Int, col: Int,
        alignment: TableAlignment
    ) {
        self.overlay = overlay
        self.blockIndex = blockIndex
        self.col = col
        self.alignment = alignment
    }
}

// MARK: - Menu bridge (shared @objc target)

/// NSMenuItem actions require an `@objc` target. Making
/// `TableHandleOverlay` the target is awkward (overlays come and go);
/// the bridge is a singleton NSObject that forwards menu clicks to the
/// overlay captured in the item's `representedObject`.
@objc
private final class TableHandleOverlayMenuBridge: NSObject {
    static let shared = TableHandleOverlayMenuBridge()

    @objc func insertColumnLeft(_ sender: NSMenuItem) {
        guard let p = sender.representedObject as? MenuPayload,
              let overlay = p.overlay else { return }
        overlay.applyInsertColumnLeft(blockIndex: p.blockIndex, col: p.primary)
    }

    @objc func insertColumnRight(_ sender: NSMenuItem) {
        guard let p = sender.representedObject as? MenuPayload,
              let overlay = p.overlay else { return }
        overlay.applyInsertColumnRight(blockIndex: p.blockIndex, col: p.primary)
    }

    @objc func deleteColumn(_ sender: NSMenuItem) {
        guard let p = sender.representedObject as? MenuPayload,
              let overlay = p.overlay else { return }
        overlay.applyDeleteColumn(blockIndex: p.blockIndex, col: p.primary)
    }

    @objc func insertRowAbove(_ sender: NSMenuItem) {
        guard let p = sender.representedObject as? MenuPayload,
              let overlay = p.overlay else { return }
        overlay.applyInsertRowAbove(blockIndex: p.blockIndex, row: p.primary)
    }

    @objc func insertRowBelow(_ sender: NSMenuItem) {
        guard let p = sender.representedObject as? MenuPayload,
              let overlay = p.overlay else { return }
        overlay.applyInsertRowBelow(blockIndex: p.blockIndex, row: p.primary)
    }

    @objc func deleteRow(_ sender: NSMenuItem) {
        guard let p = sender.representedObject as? MenuPayload,
              let overlay = p.overlay else { return }
        overlay.applyDeleteRow(blockIndex: p.blockIndex, row: p.primary)
    }

    @objc func setAlign(_ sender: NSMenuItem) {
        guard let p = sender.representedObject as? AlignPayload,
              let overlay = p.overlay else { return }
        overlay.applySetAlignment(
            blockIndex: p.blockIndex,
            col: p.col,
            alignment: p.alignment
        )
    }
}
