//
//  CodeBlockEditToggleOverlay.swift
//  FSNotes
//
//  Phase 8 — Code-Block Edit Toggle — Slice 3.
//
//  Controller that attaches a pool of `CodeBlockEditToggleView` subviews
//  to an `EditTextView` and positions one toggle per visible logical
//  code block at the first fragment's top-right corner. On click, the
//  toggle flips the block's membership in `EditTextView.editingCodeBlocks`
//  and calls `DocumentEditApplier.applyDocumentEdit` with priorDoc ==
//  newDoc but `priorEditingBlocks != newEditingBlocks`, which the
//  Slice-1 `promoteToggledBlocksToModified` pass reifies into a single
//  `.modified` block-level diff.
//
//  Pooled instances: reuse `CodeBlockEditToggleView` subviews across
//  relayouts. Extra pool entries are hidden (removed from the parent
//  view or moved offscreen); shortage grows the pool lazily.
//
//  Scroll / edit notifications trigger a reposition pass. The pass is
//  idempotent: repeated calls with no visible-fragment change redraw
//  nothing.
//

import AppKit

// MARK: - Public entry point

final class CodeBlockEditToggleOverlay {

    // MARK: - Exposed types

    /// Record of one visible code block's toggle-relevant geometry.
    /// `charIndex` is the block's first-fragment start in the content
    /// storage; `topRight` is in the text view's coordinate space (the
    /// coordinate system `editor.addSubview(_:)` uses).
    struct VisibleCodeBlock {
        let charIndex: Int
        let topRight: CGPoint
        /// First fragment's top-Y in the text view's coordinate space
        /// — used as the button's y origin.
        let originY: CGFloat
        /// The `BlockRef` for the block at `charIndex`. Stable across
        /// insert-above structural edits.
        let ref: BlockRef
    }

    // MARK: - Configuration constants

    /// Right-edge inset from the container's right boundary. Mirrors
    /// `CodeBlockLayoutFragment.horizontalBleed` so the button sits
    /// just inside the block's right edge.
    static let rightInset: CGFloat = 8

    /// Top-edge inset from the first fragment's top.
    static let topInset: CGFloat = 4

    /// Button size. Scaled to 20x18pt so the SF Symbol reads clearly
    /// without dominating a 14pt code-font line.
    static let buttonSize: CGSize = CGSize(width: 22, height: 16)

    // MARK: - Private state

    /// The owning text view. Weakly referenced to avoid a retain cycle
    /// when `EditTextView` holds this overlay via `lazy var`.
    private weak var editor: EditTextView?

    /// Reusable pool of toggle views. Indexed by creation order; extra
    /// entries are reused across repositions.
    private var pool: [CodeBlockEditToggleView] = []

    /// Notifications we subscribe to so scroll / edit events trigger
    /// a reposition. We hold the observers to detach on deinit.
    private var notificationObservers: [NSObjectProtocol] = []

    /// Suppress re-entry during `applyToggle` — the applier mutates
    /// storage which posts textDidChange which triggers reposition
    /// which could re-read `editingCodeBlocks` mid-flight.
    private var isApplyingToggle = false

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

    /// Observe scroll + text-content-change so the overlay repositions.
    /// Under TK2 the text view's content is exposed via
    /// `NSTextLayoutManager`; the `NSText.didChangeNotification` fires
    /// on any text edit and is sufficient for keeping positions fresh.
    private func installObservers() {
        let center = NotificationCenter.default

        // Scroll: clip view's bounds change fires on any scroll. We hook
        // the observer lazily — the scroll view may not be installed
        // when the overlay is created. `EditTextView.viewDidMoveToWindow`
        // /`viewDidMoveToSuperview` trigger a second pass via
        // `repositionIfPossible`.
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

        // Text changes.
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

        // Phase 8 / Slice 4: `editingCodeBlocks` changed via the
        // auto-collapse path. `NSText.didChangeNotification` does NOT
        // fire when the applier runs inside a TK2
        // `performEditingTransaction` with no delegate chain, so
        // Slice 4 posts its own notification to keep button `isActive`
        // state in sync with the editor's set.
        let editingToken = center.addObserver(
            forName: EditTextView.editingCodeBlocksDidChangeNotification,
            object: nil, queue: .main
        ) { [weak self] note in
            guard let self = self,
                  let editor = self.editor,
                  (note.object as? EditTextView) === editor
            else { return }
            self.reposition()
        }
        notificationObservers.append(editingToken)

        // Also enable the clip view's boundsDidChange delivery. Without
        // `postsBoundsChangedNotifications = true`, the scroll observer
        // receives nothing.
        if let clip = editor?.enclosingScrollView?.contentView {
            clip.postsBoundsChangedNotifications = true
        }
    }

    // MARK: - Reposition

    /// Main entry point. Recomputes visible code blocks, reuses or
    /// spawns pooled views, assigns click handlers, and positions each.
    /// Extra pool entries are hidden.
    func reposition() {
        guard let editor = editor,
              editor.textLayoutManager != nil else {
            hideAll()
            return
        }
        guard let contentStorage =
                editor.textLayoutManager?.textContentManager
                    as? NSTextContentStorage
        else {
            hideAll()
            return
        }

        // Ensure the clip-view post flag is set — `installObservers`
        // may have run before the view was embedded in a scroll view.
        if let clip = editor.enclosingScrollView?.contentView,
           !clip.postsBoundsChangedNotifications {
            clip.postsBoundsChangedNotifications = true
        }

        let visible = visibleFragments(
            in: editor, contentStorage: contentStorage
        )

        // Position / refresh buttons.
        for (i, record) in visible.enumerated() {
            let view = viewAt(index: i, parent: editor)
            let size = Self.buttonSize
            let origin = CGPoint(
                x: record.topRight.x - size.width,
                y: record.originY + Self.topInset
            )
            view.frame = CGRect(origin: origin, size: size)
            view.isActive = editor.editingCodeBlocks.contains(record.ref)
            let ref = record.ref
            view.onClick = { [weak self, weak editor] in
                guard let self = self, let editor = editor else { return }
                self.applyToggle(ref: ref, editor: editor)
            }
            view.isHidden = false
        }

        // Hide overflow pool entries.
        if pool.count > visible.count {
            for i in visible.count..<pool.count {
                pool[i].isHidden = true
                pool[i].onClick = nil
            }
        }
    }

    /// Retrieve the pool entry at `index`, spawning a new view if
    /// needed. Parent is always the text view so the overlay scrolls
    /// with text content.
    private func viewAt(index: Int, parent: EditTextView) -> CodeBlockEditToggleView {
        if index < pool.count {
            let v = pool[index]
            if v.superview !== parent {
                parent.addSubview(v)
            }
            return v
        }
        let v = CodeBlockEditToggleView(frame: .zero)
        parent.addSubview(v)
        pool.append(v)
        return v
    }

    private func hideAll() {
        for v in pool {
            v.isHidden = true
            v.onClick = nil
        }
    }

    // MARK: - Fragment enumeration

    /// Enumerate `CodeBlockLayoutFragment`s and return one record per
    /// LOGICAL code block. Multi-line blocks produce multiple adjacent
    /// fragments; dedupe on the block's first character so one record
    /// anchors at the first fragment's top-right.
    ///
    /// Skips fragments whose first character carries the
    /// `.foldedContent` attribute — folded blocks should not offer a
    /// toggle.
    ///
    /// Exposed for tests.
    func visibleFragments() -> [VisibleCodeBlock] {
        guard let editor = editor,
              let tlm = editor.textLayoutManager,
              let contentStorage =
                tlm.textContentManager as? NSTextContentStorage
        else {
            return []
        }
        return visibleFragments(in: editor, contentStorage: contentStorage)
    }

    private func visibleFragments(
        in editor: EditTextView,
        contentStorage: NSTextContentStorage
    ) -> [VisibleCodeBlock] {
        guard let tlm = editor.textLayoutManager,
              let storage = editor.textStorage,
              let projection = editor.documentProjection
        else {
            return []
        }

        let docStart = contentStorage.documentRange.location
        let containerWidth = editor.textContainer?.size.width
            ?? editor.frame.width
        let containerOrigin = editor.textContainerOrigin
        // Container-right x in text-view coords. The text container is
        // offset by `textContainerOrigin.x` and sized to `containerWidth`.
        let containerRightX = containerOrigin.x + containerWidth
            - Self.rightInset

        var out: [VisibleCodeBlock] = []
        var lastBlockStart: Int = -1

        tlm.enumerateTextLayoutFragments(
            from: tlm.documentRange.location,
            options: [.ensuresLayout]
        ) { fragment in
            guard fragment is CodeBlockLayoutFragment else { return true }
            guard let element = fragment.textElement,
                  let elementRange = element.elementRange
            else { return true }

            let charIndex = contentStorage.offset(
                from: docStart, to: elementRange.location
            )
            guard charIndex >= 0, charIndex < storage.length else {
                return true
            }

            // Skip folded blocks.
            if storage.attribute(
                .foldedContent, at: charIndex, effectiveRange: nil
            ) != nil {
                return true
            }

            // Find the block in the projection whose span contains
            // `charIndex`. `blockContaining` returns the block +
            // offset; we only need the block-index here. Falls back to
            // a span scan because blank-line insertion points between
            // blocks return nil.
            let blockIndex: Int
            if let (bIdx, _) = projection.blockContaining(
                storageIndex: charIndex
            ) {
                blockIndex = bIdx
            } else {
                // Fallback: find the span that contains the index.
                var found: Int = -1
                for (i, span) in projection.blockSpans.enumerated() {
                    if NSLocationInRange(charIndex, span) {
                        found = i
                        break
                    }
                }
                guard found >= 0 else { return true }
                blockIndex = found
            }

            guard blockIndex >= 0,
                  blockIndex < projection.document.blocks.count
            else { return true }

            // Only treat actual codeBlock-kind blocks as toggle targets.
            let block = projection.document.blocks[blockIndex]
            switch block {
            case .codeBlock: break
            default: return true
            }

            // Dedupe on the block's first character — multi-paragraph
            // fragments from one block collapse into one toggle.
            let blockSpan = projection.blockSpans[blockIndex]
            if blockSpan.location == lastBlockStart {
                return true
            }
            lastBlockStart = blockSpan.location

            // Only anchor at the fragment whose first char matches the
            // block's span start — earlier fragments from this block
            // (if any) would be skipped by the dedupe, but we ALSO
            // need to skip fragments that don't sit on the block's
            // first character.
            if charIndex != blockSpan.location {
                // This fragment is interior to the block (not its
                // first paragraph). Skip — the first fragment of this
                // block anchors the toggle.
                return true
            }

            let frame = fragment.layoutFragmentFrame
            let originY = frame.minY + containerOrigin.y
            let topRight = CGPoint(
                x: containerRightX,
                y: originY
            )
            out.append(VisibleCodeBlock(
                charIndex: charIndex,
                topRight: topRight,
                originY: originY,
                ref: BlockRef(block)
            ))
            return true
        }
        return out
    }

    // MARK: - Click handler

    /// Toggle the given block's membership in `editingCodeBlocks` and
    /// re-render via `DocumentEditApplier.applyDocumentEdit`. Same
    /// Document on both sides — only the editing set differs. The
    /// `promoteToggledBlocksToModified` post-LCS pass (landed in Slice
    /// 1) picks up the toggled block as `.modified` so the applier
    /// re-renders just that block's span.
    ///
    /// Exposed `internal` (not private) so tests can invoke the click
    /// path without synthesizing an `NSEvent`.
    func applyToggle(ref: BlockRef, editor: EditTextView) {
        guard !isApplyingToggle else { return }
        isApplyingToggle = true
        defer { isApplyingToggle = false }

        guard let projection = editor.documentProjection,
              let tlm = editor.textLayoutManager,
              let contentStorage =
                tlm.textContentManager as? NSTextContentStorage
        else { return }

        let before = editor.editingCodeBlocks
        let after = before.symmetricDifference([ref])
        editor.editingCodeBlocks = after

        // Same Document on both sides — only the editing set flipped.
        let currentDoc = projection.document
        _ = DocumentEditApplier.applyDocumentEdit(
            priorDoc: currentDoc,
            newDoc: currentDoc,
            contentStorage: contentStorage,
            bodyFont: projection.bodyFont,
            codeFont: projection.codeFont,
            note: projection.note,
            priorEditingBlocks: before,
            newEditingBlocks: after
        )

        // Rebuild the projection so subsequent edits render against
        // the new editing set. Projection is immutable; replace with
        // a fresh one whose `rendered.attributed` matches the storage
        // we just wrote.
        let newRendered = DocumentRenderer.render(
            currentDoc,
            bodyFont: projection.bodyFont,
            codeFont: projection.codeFont,
            note: projection.note,
            editingCodeBlocks: after
        )
        editor.documentProjection = DocumentProjection(
            rendered: newRendered,
            bodyFont: projection.bodyFont,
            codeFont: projection.codeFont,
            note: projection.note
        )

        editor.needsDisplay = true
        reposition()
    }
}
