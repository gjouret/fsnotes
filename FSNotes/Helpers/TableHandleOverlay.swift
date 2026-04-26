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
import STTextKitPlus

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

    /// A single global pair of column + row handle chip subviews.
    /// The user can only hover over one cell at a time, so only one
    /// pair needs to exist at any moment. Keying chips per-fragment
    /// produced stale duplicates: TK2 sometimes recreates fragment
    /// instances across layout passes, and each fresh instance got
    /// its own chip pair while old chips lingered as orphan
    /// subviews — visible duplicates AND orphan hit-testers that
    /// intercepted clicks meant for cells. One global pair sidesteps
    /// the whole identity-stability question.
    private var globalChips:
        (col: TableHandleChip, row: TableHandleChip)?

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
        // Hide the global chip pair on any reposition where no
        // tables are visible. (When a table IS visible, the next
        // hover event will repositiopn / unhide them.)
        if visible.isEmpty {
            globalChips?.col.isHidden = true
            globalChips?.row.isHidden = true
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
            let charIndex = NSRange(elementRange.location, in: contentStorage).location
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
    ///
    /// `editor.needsDisplay = true` alone is insufficient — TK2
    /// caches fragment rendering surfaces, and only invalidating
    /// the NSView's dirty rect doesn't force the fragment's
    /// `draw(at:in:)` to re-run. We explicitly invalidate the
    /// fragment's rectangle on the text view and, where available,
    /// nudge the layout manager to re-render the fragment's text
    /// range. Without this, hover handles are painted in the
    /// fragment but the user never sees them (logged symptom:
    /// "TableHandleOverlay.init + installObservers + reposition
    /// all run. Hover events fire and log inTopStrip=true. But
    /// the chrome doesn't appear visually.").
    func updateHover(on fragment: TableLayoutFragment,
                     to state: TableLayoutFragment.HoverState) {
        guard let editor = editor else { return }
        // Store the state on the fragment (still used by tests +
        // menu builder); no fragment redraw needed — chip subviews
        // below do the visual work.
        _ = fragment.setHoverState(state)

        // Lazily create the single global chip pair. The pair stays
        // attached as subviews of the editor; on each hover update
        // we just move/hide them. This mirrors the TK1 `InlineTableView`
        // approach where a `GlassHandleView` subview was repositioned
        // on mouseMoved — `.frame` reassignment marks the dirty rects
        // automatically via NSView's invalidation machinery.
        let chips: (col: TableHandleChip, row: TableHandleChip)
        if let existing = globalChips {
            chips = existing
        } else {
            let col = TableHandleChip(orientation: .horizontal)
            let row = TableHandleChip(orientation: .vertical)
            editor.addSubview(col)
            editor.addSubview(row)
            chips = (col, row)
            globalChips = chips
        }

        let fragFrame = fragment.layoutFragmentFrame
        let origin = editor.textContainerOrigin

        // The fragment draws the grid relative to the LEFT EDGE OF
        // THE CONTAINER, not relative to the fragment's natural-flow
        // origin. From `TableLayoutFragment.draw`:
        //     containerOriginX = point.x - frame.origin.x
        //     gridLeft = containerOriginX + handleBarWidth
        // Translated to editor view coords: gridLeft (editor) =
        //     textContainerOrigin.x + handleBarWidth
        // i.e. NOT offset by `fragFrame.origin.x`. The chip frame
        // must use the same origin or it lands shifted right by the
        // fragment's natural x-offset (the gap left by handle strip
        // + any other paragraph indent).
        func columnRect(col: Int) -> CGRect? {
            guard col >= 0 else { return nil }
            guard let geom = fragment.geometryForHandleOverlay() else {
                return nil
            }
            guard col < geom.columnWidths.count else { return nil }
            var x = TableGeometry.handleBarWidth
            for i in 0..<col { x += geom.columnWidths[i] }
            return CGRect(
                x: origin.x + x,
                y: fragFrame.origin.y + origin.y,
                width: geom.columnWidths[col],
                height: TableGeometry.handleBarHeight
            )
        }
        func rowRect(row: Int) -> CGRect? {
            guard row >= 0 else { return nil }
            guard let geom = fragment.geometryForHandleOverlay() else {
                return nil
            }
            guard row < geom.rowHeights.count else { return nil }
            var y = TableGeometry.handleBarHeight
            for i in 0..<row { y += geom.rowHeights[i] }
            return CGRect(
                x: origin.x,
                y: fragFrame.origin.y + origin.y + y,
                width: TableGeometry.handleBarWidth,
                height: geom.rowHeights[row]
            )
        }

        switch state {
        case .none:
            chips.col.isHidden = true
            chips.row.isHidden = true
        case .column(let c):
            if let r = columnRect(col: c) {
                chips.col.frame = r
                chips.col.index = c
                chips.col.overlay = self
                chips.col.blockIndexRef = blockIndex(for: fragment)
                chips.col.isHidden = false
            }
            chips.row.isHidden = true
        case .row(let r):
            if let rr = rowRect(row: r) {
                chips.row.frame = rr
                chips.row.index = r
                chips.row.overlay = self
                chips.row.blockIndexRef = blockIndex(for: fragment)
                chips.row.isHidden = false
            }
            chips.col.isHidden = true
        case .cell(let c, let r):
            if let cr = columnRect(col: c) {
                chips.col.frame = cr
                chips.col.index = c
                chips.col.overlay = self
                chips.col.blockIndexRef = blockIndex(for: fragment)
                chips.col.isHidden = false
            }
            if let rr = rowRect(row: r) {
                chips.row.frame = rr
                chips.row.index = r
                chips.row.overlay = self
                chips.row.blockIndexRef = blockIndex(for: fragment)
                chips.row.isHidden = false
            }
        }
    }

    /// Resolve the block index for a fragment by matching its
    /// element-range storage offset against the projection's block
    /// spans. Returns -1 if not resolvable; chip right-click
    /// menus use this to target the right table.
    private func blockIndex(for fragment: TableLayoutFragment) -> Int {
        guard let editor = editor,
              let projection = editor.documentProjection,
              let tlm = editor.textLayoutManager,
              let contentStorage = tlm.textContentManager
                as? NSTextContentStorage,
              let elementRange = fragment.textElement?.elementRange
        else { return -1 }
        let charIndex = NSRange(elementRange.location, in: contentStorage).location
        for (i, span) in projection.blockSpans.enumerated() {
            if NSLocationInRange(charIndex, span) ||
                span.location == charIndex {
                return i
            }
        }
        return -1
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

    // MARK: - Bug #36: Drag-reorder (row / column)

    func beginHandleDrag(
        orientation: TableHandleChip.Orientation,
        index: Int,
        blockIndex: Int,
        event: NSEvent
    ) {
        guard let editor = editor,
              let window = event.window ?? editor.window else { return }
        let candidates = visibleTables()
        guard let record = candidates.first(where: { $0.blockIndex == blockIndex })
        else { return }
        let fragment = record.fragment
        guard let geom = fragment.geometryForHandleOverlay() else { return }
        let columnWidths = geom.columnWidths
        let rowHeights = geom.rowHeights
        let frame = record.frame

        let line = NSView()
        line.wantsLayer = true
        line.layer?.backgroundColor = NSColor.controlAccentColor.cgColor
        editor.addSubview(line)
        defer { line.removeFromSuperview() }

        // Bug #47: the fragment's `draw(at:in:)` cancels out its own
        // `layoutFragmentFrame.origin.x` (computes
        // `containerOriginX = point.x - frame.origin.x` then
        // `gridLeft = containerOriginX + handleBarWidth`), so cells paint
        // at view-X = textContainerOrigin.x + handleBarWidth regardless
        // of fragment indent. `sourceRect` / `lineRect` were instead
        // adding `frame.origin.x` on top, which offsets the chip right
        // whenever the fragment has any non-zero x-origin. Mirror
        // `columnRect`'s pattern: use `textContainerOrigin.x`, not
        // `frame.origin.x`. The y-axis is taken from `frame.origin.y`
        // (vertical position is per-fragment and isn't cancelled).
        let containerOrigin = editor.textContainerOrigin

        let sourceHighlight = NSView()
        sourceHighlight.wantsLayer = true
        sourceHighlight.layer?.borderColor = NSColor.controlAccentColor.cgColor
        sourceHighlight.layer?.borderWidth = 2
        sourceHighlight.layer?.backgroundColor =
            NSColor.controlAccentColor.withAlphaComponent(0.08).cgColor
        editor.addSubview(sourceHighlight)
        defer { sourceHighlight.removeFromSuperview() }
        sourceHighlight.frame = sourceRect(
            orientation: orientation, index: index,
            columnWidths: columnWidths, rowHeights: rowHeights,
            frame: frame, containerOriginX: containerOrigin.x
        )

        var targetGap: Int = index
        line.frame = lineRect(
            orientation: orientation, gap: targetGap,
            columnWidths: columnWidths, rowHeights: rowHeights,
            frame: frame, containerOriginX: containerOrigin.x
        )

        var keepTracking = true
        while keepTracking {
            guard let evt = window.nextEvent(
                matching: [.leftMouseDragged, .leftMouseUp]
            ) else { continue }
            if evt.type == .leftMouseUp {
                keepTracking = false
                continue
            }
            let pt = editor.convert(evt.locationInWindow, from: nil)
            switch orientation {
            case .horizontal:
                // Cursor-x relative to the grid's actual painted
                // origin (textContainerOrigin.x + handleBarWidth),
                // not to the fragment's frame origin.
                let gridX = containerOrigin.x + TableGeometry.handleBarWidth
                let cursor = pt.x - gridX
                targetGap = EditingOps.dropGapIndex(
                    segments: columnWidths, cursor: cursor
                )
            case .vertical:
                let gridY = frame.origin.y + TableGeometry.handleBarHeight
                let cursor = pt.y - gridY
                targetGap = EditingOps.dropGapIndex(
                    segments: rowHeights, cursor: cursor
                )
            }
            line.frame = lineRect(
                orientation: orientation, gap: targetGap,
                columnWidths: columnWidths, rowHeights: rowHeights,
                frame: frame, containerOriginX: containerOrigin.x
            )
        }

        let dst = EditingOps.moveDestinationIndex(from: index, gap: targetGap)
        if dst == index { return }
        switch orientation {
        case .horizontal:
            applyEdit(
                blockIndex: blockIndex,
                { projection in
                    try EditingOps.moveTableColumn(
                        blockIndex: blockIndex,
                        from: index, to: dst,
                        in: projection
                    )
                },
                actionName: "Move Table Column"
            )
        case .vertical:
            applyEdit(
                blockIndex: blockIndex,
                { projection in
                    try EditingOps.moveTableRow(
                        blockIndex: blockIndex,
                        from: index, to: dst,
                        in: projection
                    )
                },
                actionName: "Move Table Row"
            )
        }
    }

    /// Bug #47: x-axis uses `containerOriginX + handleBarWidth`, NOT
    /// `frame.origin.x + handleBarWidth`. The fragment's
    /// `draw(at:in:)` cancels out its own `frame.origin.x` so cells
    /// always paint at the container's left edge + handle strip,
    /// regardless of fragment indent. The chip / drag indicator must
    /// follow the same rule. Y-axis stays from `frame.origin.y`
    /// (vertical position IS per-fragment).
    private func sourceRect(
        orientation: TableHandleChip.Orientation,
        index: Int,
        columnWidths: [CGFloat],
        rowHeights: [CGFloat],
        frame: CGRect,
        containerOriginX: CGFloat
    ) -> CGRect {
        let gridLeft = containerOriginX + TableGeometry.handleBarWidth
        let gridTop = frame.origin.y + TableGeometry.handleBarHeight
        let gridHeight = rowHeights.reduce(0, +)
        let gridWidth = columnWidths.reduce(0, +)
        switch orientation {
        case .horizontal:
            guard index >= 0, index < columnWidths.count else { return .zero }
            var x = gridLeft
            for i in 0..<index { x += columnWidths[i] }
            return CGRect(x: x, y: gridTop,
                          width: columnWidths[index], height: gridHeight)
        case .vertical:
            guard index >= 0, index < rowHeights.count else { return .zero }
            var y = gridTop
            for i in 0..<index { y += rowHeights[i] }
            return CGRect(x: gridLeft, y: y,
                          width: gridWidth, height: rowHeights[index])
        }
    }

    private func lineRect(
        orientation: TableHandleChip.Orientation,
        gap: Int,
        columnWidths: [CGFloat],
        rowHeights: [CGFloat],
        frame: CGRect,
        containerOriginX: CGFloat
    ) -> CGRect {
        let gridLeft = containerOriginX + TableGeometry.handleBarWidth
        let gridTop = frame.origin.y + TableGeometry.handleBarHeight
        let gridHeight = rowHeights.reduce(0, +)
        let gridWidth = columnWidths.reduce(0, +)
        let lineThickness: CGFloat = 2
        switch orientation {
        case .horizontal:
            var x = gridLeft
            let safeGap = max(0, min(gap, columnWidths.count))
            for i in 0..<safeGap { x += columnWidths[i] }
            return CGRect(
                x: x - lineThickness / 2,
                y: gridTop,
                width: lineThickness,
                height: gridHeight
            )
        case .vertical:
            var y = gridTop
            let safeGap = max(0, min(gap, rowHeights.count))
            for i in 0..<safeGap { y += rowHeights[i] }
            return CGRect(
                x: gridLeft,
                y: y - lineThickness / 2,
                width: gridWidth,
                height: lineThickness
            )
        }
    }


    /// T2-g.4: persist the column widths produced by a live drag-resize.
    /// Routed through `EditingOps.setTableColumnWidths` so undo / splice
    /// math stay consistent with the other structural primitives.
    func applySetColumnWidths(blockIndex: Int, widths: [CGFloat]) {
        applyEdit(
            blockIndex: blockIndex,
            { projection in
                try EditingOps.setTableColumnWidths(
                    blockIndex: blockIndex,
                    widths: widths,
                    in: projection
                )
            },
            actionName: "Resize Table Column"
        )
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
              case .table(let h, let a, let r, _) =
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
